# arrangeManager

Project-wide model for the arrange page (`design/arrange.md`). Owns no
state of its own — every read walks REAPER's track/item lists directly,
every write goes through cm. The per-track **slot palette** lives in cm
at the track tier under `arrangeSlots`.

## `trackIdx` is the visible-column index

Every public `trackIdx` (and the `trackIdx` field on take-shapes) is
the 0-based column index into `am:projectTracks()`, not the raw
REAPER track slot. Hidden tracks are filtered out: the shared scratch
track (consulted directly via `scratch.peek`, since `am` parks emptied
slots there itself) and the wiring-owned `newTrack` FX hosts (via the
wiring facade's `isWiringOwnedTrack`). `am` translates column → REAPER
track at the boundary via `visibleTrackOfCol`.

The two indices diverge as soon as REAPER's own "insert new track"
fires — the new track lands at the absolute end of the project,
past the hidden wiring tracks. Holding the conversion inside `am`
keeps the arrange page from ever needing to know the difference.

## A slot outlives its takes

The palette is not a curated set sitting alongside the project items.
It is the project items, grouped by source identity — but a slot is no
longer pruned the instant its last take leaves the grid. Deleting a
slot's **last live instance** parks that item, muted, on the shared
scratch track (`scratch.lua`); the pool and the palette slot stay alive
until an instance is dropped back or the slot is deleted. (Slot rows
carry a `parked` flag for liveness, but the palette does not grey them.)
The one true forever-delete is `deleteSlot`, which removes every live
instance *and* the parked keeper.

The persistence in `arrangeSlots` is an **index-to-id stability map**.
Without it, two reads of the same project could allocate `{p1}` to
slot 0 in frame N and slot 1 in frame N+1 — base62 hotkeys would shift
under the user's fingers. The dict pins indices across reads and
across sessions; live-or-parked takes drive what stays pinned.

`ensureSlots(track)` is the single chokepoint. It walks live takes,
allocates the lowest-free slot for any id not yet in the dict, keeps a
dict entry whose id has a live take **or** a parked keeper (taking the
keeper's name when no live take remains), prunes the rest, and returns
the freshened `(dict, slotForId, firstName, liveIds)` so callers don't
repeat the walk. It is idempotent — a second call in the same frame
performs no writes. Every public read (`projectTracks`, `tracksTakes`,
`trackSlots`, `slotForTake`) routes through it, so the reads always
agree on which slot owns which id.

### Parking

`am:deleteTake` checks whether the item it is about to remove is the
last live instance of its id on the track. If so — and nothing is parked
for that id yet — it `MoveMediaItemToTrack`s the item onto the scratch
track instead of deleting it. The track is hidden and muted, so the
parked item neither sounds nor shows; REAPER keeps the MIDI pool alive
because an item still references it. At most one item is parked per id
(the dedup guard), so re-drop/delete cycles never accumulate copies.

Re-dropping from an emptied slot works because `siblingInstance` falls
back to the parked keeper as the chunk source, so `dropInstance` clones a
fresh pooled instance straight off the park. A slot with neither a live
nor a parked instance is the genuine forever-gone case, reached only
through `deleteSlot`.

`am:mintParkedTake` reaches the same end-state forward: it mints a fresh
slot whose sole instance is born on the scratch track, never grid-placed.
The tracker's new-take and unpooled-duplicate gestures use it to add a
slot the user edits in place and drops onto the grid later. A new MIDI
item already carries its own pool, so the clone is unpooled by
construction.

Per-event metadata follows the pool, not the take (docs/eventMeta.md). The
keeper move (`MoveMediaItemToTrack`) and pooled re-drops keep the same pool
guid, so metadata travels for free. The *unpooled* mints — `mintParkedTake`
and `cloneMidiItem(rePool=true)` — get a fresh guid, so they `eventMeta:copyPool`
the source's blob onto it; `deleteSlot` (the lone forever-delete) `dropPool`s it.

### Renaming and name drift

No slot-name field is stored. The displayed name is whatever the
first-found take with that id is called. Renaming a slot walks every
item on the track and writes `SetTakeName` to each take whose id
matches. cm holds no name. If the user renames a single take
directly in REAPER, the palette will start showing that name once
it's the first-found — accepted drift, in exchange for not
multiplying the staleness problem with a cm cache.

## The id chokepoint

`takeIdOf` is the single function that decides a source's identity:

- **MIDI:** the `POOLEDEVTS` GUID inside the item state chunk. Pooled
  takes share one GUID; that's the whole point of pooling. Reading it
  from the chunk is more expensive than a typed accessor would be, but
  REAPER exposes no typed accessor, and the chunk parse is local.
- **Audio:** the source filename. REAPER doesn't pool audio — two
  audio takes referencing the same file are independent items — so
  filename is the only stable identity we can lean on.

A take whose id can't be derived (no chunk, no source) is skipped
during `ensureSlots`: it neither materialises a slot nor pins one,
and `slotForTake` returns nil for it. Cross-session stability of
MIDI ids is accepted as REAPER's responsibility: the pool GUID is
persisted in the project file, so reload preserves slot identity.

## Why writes go through `ds:assignAt`

The arrange page edits every track's palette, but the bound context
is whatever the tracker page set (typically one focused take, whose
track is just one of the project's). Routing slot writes through the
bound-context `ds:assign` would either require rebinding context to
each track in turn (firing reload churn on every subscriber) or write
to the wrong track. `ds:assignAt(track, 'arrangeSlots', …)` is the
foreign-handle write — it bypasses the bound context and writes that
track's P_EXT directly — and `ds:getAt` is its read counterpart. (Slot
palettes are document data, so they live on `dataStore`, not cm — see
`docs/dataStore.md`.)

## Reswing folded from sequenceManager

The old `sequenceManager` did one job: walk the project, find takes
whose `usedSwings` mentions a name, and re-bind each through
`tm:bindTake(opts.markSwingStale=true)` so its raw events re-realise
under the edited swing composite. That walk is degenerate with the
project-wide take walk that arrangeManager already performs for
discovery, so the two were folded. `takesUsing` and `reswingAll` are
unchanged in semantics; the swing editor was migrated. The
`docs/sequenceManager.md` history is preserved in git
(`git log -- docs/sequenceManager.md`).

The reswing rebind needs the tracker's `tm`, which arrangeManager does
not own (and the lone `am` instance lives on the arrange page, which has
no `tm`). So `reswingAll` does the project walk (`takesUsing`) itself
and hands the affected takes to the **`tracker` facade**'s
`reswingTakes`, which transient-rebinds each through `tm`
(markSwingStale) and restores the bound take. Pure discovery callers
never touch the facade.

## Track ordering — deferred to phase 2

The design notes a "facility to reorder somewhere" beyond REAPER's
natural track order. The plan is a project-tier key
`arrangeTrackOrder = { trackGUID, ... }` — GUIDs not indices, so a
REAPER track move doesn't shuffle the arrange view, and missing
GUIDs (track deleted, new track added) fall through to REAPER order
at the tail. Read via `am:displayOrder()`; write via
`am:reorderTracks(newGuids)`. Both land alongside the UI in phase 2
rather than now — shipping a writer with no reader earns nothing.

## Creation: one round-trip

`createAndDropMidi(trackIdx, qnPos, lengthQN, name)` is the only path
that mints a slot. It allocates the lowest-free index, calls
`CreateNewMIDIItemInProj` (which auto-assigns a fresh `POOLEDEVTS`
GUID), harvests the GUID into the slot dict, names the take, and
returns `(slotIdx, take)`. One round-trip; no "reserve, then drop
later" intermediate state.

This is a deliberate retreat from an earlier two-step lazy-id design.
That design carried a `slot.id == nil` state for slots that hadn't
been dropped yet, and every consumer of the slot dict had to guard
against it. The current model collapses the state: a slot exists only
once an instance has existed (live or parked), so id is always populated.

## Subsequent drops: chunk-clone an existing sibling

`dropInstance(trackIdx, slotIdx, qnPos, lengthQN)` finds a live
sibling instance of the slot, creates another MIDI item, and writes
the sibling's full state chunk onto it — events and `POOLEDEVTS`
guid in one atomic step. REAPER then treats every instance as a
single pool and propagates MIDI edits across them.

The earlier path — create-empty + splice the slot's pool guid over
the fresh one REAPER assigned — looked simpler but wiped the pool:
REAPER syncs the empty events of the freshly-pooled item back across
the existing instances on the next refresh. The chunk-clone path
sidesteps this by seeding the new item populated from the start.

`duplicateTake` (pooled) and `duplicateUnpooledBelow` (fresh pool)
share the same `cloneMidiItem(track, srcItem, qnPos, lengthQN, rePool)`
helper; `rePool=true` rewrites `POOLEDEVTS` to the fresh guid before
the chunk write, then explicitly copies events into the new pool.

MIDI drops resolve their chunk source through `siblingInstance`, which
prefers a live instance on the track and falls back to the slot's parked
keeper. A drop returns nil only when neither exists — a slot with no live
and no parked instance, which `ensureSlots` would already have pruned.

## Audio drops are not pooled

For audio, `dropInstance` creates a fresh `PCM_Source_CreateFromFile`
and wires it onto a new item/take. REAPER does not pool audio, so
two instances of the same audio slot are independent items that
happen to reference the same file. The grouping you see in the
palette is purely a property of the shared filename, which is what
`takeIdOf` returns for audio sources. There is currently no surface
that mints an audio slot — audio creation waits on a file picker.
The `dropInstance` audio branch stays so that audio slots
materialised from pre-existing REAPER items remain droppable.

## Faithful mutators

`moveTake`, `resizeTake`, `dropInstance`, and `duplicateTake` are
unclamped — they pass the requested QN straight to REAPER without
checking for overlap or snapping to grid. Overlap prevention, grid
snap, and the minimum-length floor are owned by the caller.
`freeSpan` and `rangeIsClear` are the reads a caller consults to
decide what placement is legal before invoking a mutator. Abutting
items are legal under the half-open ranges used throughout.

## Natural length and `D_LENGTH`

Each take carries a **natural length** in the cm key
`arrangeNaturalLenQN`; `nil` means `util.OPEN` (grow to fill). What
REAPER actually plays — the item's `D_LENGTH` — is *derived*, never
the natural length verbatim: `D_LENGTH = min(natural, gap-to-next,
source)`. `relayoutTrack` walks the track in `startQN` order and
re-derives `D_LENGTH` for every take after any mutation, so the cap is
always current; the mutators (`moveTake`, `resizeTake`, …) preserve
natural length and lean on relayout to re-derive the playing length.

`relayoutTrack` also runs **per track inside `buildState`** (every
rebuild), not only from the mutators. A source-length change made
elsewhere — Take Properties extending or shrinking a pooled take's MIDI
source — is an external edit `am` never sees as a mutator call; the
build-time pass re-derives `D_LENGTH` for every instance so OPEN siblings
grow/shrink with the source, and a freshly-grown take is re-capped to its
gap rather than overlapping its neighbour (an overlap that would otherwise
make `takeAtCursor` tie and hit the wrong take).

A stored natural that is **≥ the source length** is demoted to
`util.OPEN` on relayout. Pinning a finite cap at-or-above the source
would freeze the take at today's source length; demoting to OPEN lets
future source growth widen the cap automatically.

## State: one build, served until invalidated

Every render read — `projectTracks`, `tracksTakes`, `visibleTakes`,
`trackSlots`, `findTake` — is served from a single in-memory build,
not re-derived per frame. The old per-frame walk hammered REAPER
(ext-state reads, QN conversions, colour reads) dozens of times a
frame; scrolling a large project lagged.

`buildState` walks the project once — one `ensureColours`, one
`ensureSlots` per track — producing track rows, per-column take-shapes,
and per-column slot rows together. `ensureState` rebuilds only when the
state is stale:

- **Our own edits** flag it via `invalidate()`. Every structural
  mutator funnels through `relayoutTrack`, so that one call covers
  move/resize/delete/drop/duplicate; `renameSlot` and `deleteSlot`
  (which skip relayout) call it directly.
- **External edits** (a direct change in REAPER) are caught by polling
  `GetProjectStateChangeCount`; a moved count forces a rebuild. The
  rebuild relayouts every track (above), so a source-length change made
  outside `am` re-derives all dependent `D_LENGTH`s. `setItemQNRange`
  skips no-op writes, so an idempotent rebuild touches nothing and does
  not re-dirty the project.

The count is re-read *after* a build so the build's own ext-state
writes (slot/colour allocation) don't trigger a needless rebuild next
frame. Reads return the live cached tables — callers treat them as
read-only.

## Surface

Discovery: `am:projectTracks`, `am:tracksTakes`, `am:trackSlots`,
`am:slotForTake`, `am:keyForSlot`.

Slot mutation: `am:renameSlot`, `am:deleteSlot` (forever-deletes the
slot — every live instance plus the parked keeper — and returns the
live count).

Placement: `am:createAndDropMidi(trackIdx, qnPos, lengthQN, name) ->
(slotIdx, take)`, `am:dropInstance(trackIdx, slotIdx, qnPos,
lengthQN?)`.

Folded from sequenceManager: `am:takesUsing`, `am:reswingAll`.

Still ahead (per `design/arrange.md`, phases 5–7): `duplicateTake`,
`moveTake`, `resizeTake`, `trimStart`, `trimEnd`, `deleteTake`.
