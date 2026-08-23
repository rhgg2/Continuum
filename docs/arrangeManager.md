# arrangeManager

Project-wide model for the arrange page. Owns no
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
back to the parked keeper, and `dropInstance` moves the keeper itself
back onto the grid — a clone would pool across tracks (see § Pools
never span tracks). A slot with neither a live nor a parked instance is
the genuine forever-gone case, reached only through `deleteSlot`.

`am:mintParkedTake` reaches the same end-state forward: it mints a fresh
slot whose sole instance is born on the scratch track, never grid-placed.
The tracker's new take uses it to add a slot the user edits in place and
drops onto the grid later; `am:vary` uses it to fork a placement onto a
slot of its own. A new MIDI item already carries its own pool, so the
clone is unpooled by construction.

Per-event metadata follows the pool, not the take (docs/eventMeta.md). The
keeper move (`MoveMediaItemToTrack`) and pooled re-drops keep the same pool
guid, so metadata travels for free. The one unpooled mint — `mintParkedTake`
— gets a fresh guid, so it `eventMeta:copyPool`s the source's blob onto it;
`deleteSlot` (the lone forever-delete) `dropPool`s it.

### Renaming and name drift

1. No slot-name field is stored, and cm holds no name. The displayed
   name is whatever the first-found take with that id is called.

1. A rename writes `P_NAME` to every take carrying the slot's id — each
   live instance, and the parked keeper where the slot has no live one.
   So a rename never leaves one instance of a pool called something
   else.

1. A rename edits the root. Where the submitted ordinal matches the
   slot's own, the family is renamed with it, each slot keeping its own
   ordinal: `Sausage (var 1)` and `Sausage (var 2)` become `Kenneth (var
   1)` and `Kenneth (var 2)` (§ Variants). A changed ordinal renames that
   one slot, exactly as typed.

1. A family holds one slot with the root plain, and two slots holding it
   plain are namesakes rather than a family. Renaming one of them carries
   the variants and leaves the other where it is, which is also why an
   unnamed slot renames alone.

1. Every rename inside Continuum goes through `am:renameSlot` — the
   arrange palette's, and take properties, which names the slot the
   bound take sits in rather than that take alone. Arrange opens the
   modal on the take under its cursor, so the slot is read off the
   bind, not off the tracker's own selection.

1. If the user renames a single take directly in REAPER, the palette
   will start showing that name once it's the first-found — accepted
   drift, in exchange for not multiplying the staleness problem with a
   cm cache.

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

`duplicateTake` goes through the same `cloneMidiItem` helper: a copy is
another instance of the source's pool, so the chunk carries the events
and the `POOLEDEVTS` guid across untouched.

MIDI drops resolve their chunk source through `siblingInstance`, which
prefers a live instance on the track and falls back to the slot's parked
keeper. A drop returns nil only when neither exists — a slot with no live
and no parked instance, which `ensureSlots` would already have pruned.

### Pools never span tracks

Undo on a MIDI pool spanning tracks obeys a **one-era law** (isolated
2026-07-13; `tests/spikes/spike_pooled_undo_matrix.lua`): after the
pair is created or the project loaded, the first script run's gestures
all mint and restore perfectly; from the next run on, only a run's
first gesture mints — later gestures silently produce no undo point —
until a save+reload grants one more healthy era. Same-track pools are
immune. The matrix harness exonerated everything else we chased on the
way (see this section's git history): chunk reads with either `isundo`
flag, marking discipline, and chunk-stamped vs UI-built construction
all test clean. An identity `SetItemStateChunk` appears to open a
fresh era the way reload does (the old heal in
`spike_pooled_undo_crosstrack.lua` worked this way) — consistent with
the defect being about in-memory- vs chunk-derived item state. In
Continuum the dead era presented as *lumped undo* rather than missing
points: every gesture's P_EXT traffic forced hollow points that popped
without restoring, so N edits rewound on the oldest one. Reported
upstream against REAPER 7.77.

The only cross-track pool arrange ever wanted was scratch keeper ↔ grid
instance, so the rule is structural: unparking **moves** the keeper
back to the grid (`dropInstance`), mirroring how `deleteTake` parks by
moving. A keeper therefore exists only while its slot has no live
instance. Same-track duplicates share pools freely; cross-slot copies
re-pool.

### takeIdOf is memoised

trackerPage rebinds per frame through `am:takeForSlot` →
`siblingInstance` → `takeIdOf`, which used to `GetItemStateChunk` the
bound item every frame; the per-take memo keeps that to one read at
first sight (pool identity is stable for a take's lifetime). Chunk
reads were suspected of poisoning undo capture during the pooled-undo
investigation but were exonerated by the matrix harness — the memo
survives purely as a cost saving (chunk reads are not cheap; cf. the
GetTrackStateChunk lesson).

`invalidate()` drops the memo, so it lasts one build. It began as a
weak-keyed table, which was no protection at all: REAPER hands out
take pointers as *light* userdata, which Lua never collects, so no
entry was ever dropped. A freed take leaves its pointer behind, REAPER
recycles the address for the next take it mints, and the memo then
answers with the dead take's pool guid — the new instance inherits
another slot's identity, colour and metadata. Pointer reuse can only
follow a deletion, and every deletion either calls `invalidate()` or
moves the project state count, so the build boundary is where the memo
has to end.

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
`am:freeSpan` and `am:startIsClear` are the reads a caller consults to
decide what placement is legal before invoking a mutator. Abutting
items are legal under the half-open ranges used throughout.

## The take's window

A take renders a **window** of its source, and two numbers place it.
The **head** is the QN of source skipped before the take starts; the
**natural length** is how much of the source the take wants, measured
from the source origin. What REAPER actually plays — the item's
`D_LENGTH` — is *derived* from both, never either verbatim:
`D_LENGTH = min(natural, source) - head`, capped by the gap to the
next take.

The two numbers have different owners. The natural length is ours, in
the cm key `arrangeNaturalLenQN`, where `nil` means `util.OPEN` (grow
to fill). The head is REAPER's, held as the take's start offset, so
nothing in `ds` mirrors it and an edge dragged in REAPER's own arrange
view is picked up for free.

The **origin** of a take is where source ppq 0 lands in the project,
which makes the head `startQN - originQN`. Reading the origin through
`MIDI_GetProjQNFromPPQPos` is exact under any tempo map, and REAPER
keeps a MIDI take's start offset beat-locked, so a tempo change moves
neither the origin nor the head.

Measuring the natural length from the origin rather than from the
start is what holds a take's end still while its head moves.
Trimming the head by one QN walks the start edge in and shortens the
rendered span by exactly that QN.

The **tail** completes the partition: the source lying past the
rendered end, so head, rendered length and tail sum to the source.
It reaches the grid as `tailQN` on the take shape, which is what the
edge marks count. The tail draws no distinction between source a
neighbour cuts off and source a shorter natural leaves behind — both
are source the window does not show. Audio has neither a head nor a
source window here, so an audio take's tail is measured from its
captured trim instead.

`relayoutTrack` walks the track in `startQN` order and re-derives
`D_LENGTH` for every take after any mutation, so the cap is always
current; the mutators (`moveTake`, `resizeTake`, `trimHead`, …) settle
the stored natural and lean on relayout to re-derive the playing
length.

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

**Splitting** cuts one window into two. The upper half's natural comes
in to the cut; the lower half is a pooled clone placed there, carrying
a head of the same size and the natural the original had. The pair
ends where the whole take did, and the cut needs no free space, since
the lower half fills what the upper gave up. A take its neighbour
already cuts short splits without a special case — the neighbour goes
on cutting the lower half exactly as it cut the whole.

Audio has no head. It carries no ppq frame to read an origin from, so
its origin is its start, and `am:trimHead` refuses it. Its natural
length is the user's trim or loop, captured on first sight rather than
read from the source.

## Rendered span and source span

A take has two extents, and they are routinely different. The **source
span** is the MIDI source's length, which the tracker derives its row
count from; the **rendered span** is the item's `D_LENGTH`, derived
above from the window.

A take whose neighbour starts before its source would end is **cut**:
the tracker draws rows the song never reaches. Natural length makes the
cut ordinary rather than exceptional, since growing a take past its
neighbour stores intent that takes effect when the neighbour moves
away, and takes appended one after another meet it often.

A head cuts the same way at the other end, and the two are
independent: an instance can skip the source's first rows, its last,
or both. Siblings of one slot therefore need not agree about which
rows they play, only about what the rows contain.

The tracker edits the source, so everything `mm` measures runs from
the source origin rather than from the item: a length change ends the
item where the source now ends, and the time-signature scan spans the
whole source, so a marker lying in the head or the tail still reaches
the rows. Measured from the item, both would be out by the head — the
fault the window introduced, since before it every take began at its
origin.

## The append point

The **append point** of a placement is its rendered end. A copy
appended there starts where the sound stops, not where the intent does,
so a take cut short by its neighbour appends at the cut.

A verb appending there needs the **free span** from it to cover what it
is about to place. `am:freeSpan(trackIdx, startQN)` gives that span —
the gap up to the next take's start, unbounded past the last. A shorter
gap would render the copy truncated by its neighbour, which is a
different sound from the one being copied, and pushing the rest of the
track down to make room is a larger change than these verbs carry.

What each verb places is its own. `duplicateBelow` carries the source's
natural length; `newTakeBelow` takes a name and a length from its
caller, and measures the room against that length.

With no room, what the verb does next turns on what it creates.
`newTakeBelow` mints a slot, so it parks it (§ Parking): the item goes
to the scratch track and the palette entry stands without a placement.

`duplicateBelow` places another instance of a slot that already has one,
so it refuses. A parked sibling would show nothing, since the palette
already carries the slot, and it would leave the pool with an item on
scratch that was never a keeper. The palette can therefore always grow,
while the song grows where there is room.

`newTakeBelow` returns `(slotIdx, take)`, as `createAndDropMidi` and
`mintParkedTake` do. Which of the two happened is not a third return:
`am:isParkedTake` reads it off the take.

## Instances of a slot

A slot is the palette entry; an **instance** is one placement of it, an
item at a start QN with a rendered span. Dropping one slot four times
gives four instances of a single pooled source, and a MIDI edit reaches
all four.

`am:seekInstance(take, qn, back)` resolves a position to one instance of
the take's slot: the instance containing `qn`, else the nearest one the
way `back` points, else the nearest the other way. Its second return
says whether the containing case held. It gives nil only where the slot
has no live instance, its take parked on scratch.

At most one instance can contain a position. A pool never spans tracks
(§ Pools never span tracks), so every instance of a slot sits on one
track, and relayout caps each item at the gap to its neighbour, so items
on a track never overlap.

## Variants

1. A **variant slot** is a slot minted from one instance of another
   slot, carrying a copy of that source's events and pool metadata and
   standing in the instance's place. `am:vary(take)` mints it, deletes
   the instance and drops the variant at the vacated start QN,
   returning `(slotIdx, take)`. An edit then reaches that placement
   alone, and the original slot keeps its other instances.

1. The **family** is a slot's name and nothing else records it: the
   slots on a track whose names share a **root**, the name with a
   trailing ` (var N)` removed, one holding the root plain and the rest
   carrying ordinals. A stored parent link would say one
   thing while the palette showed another the moment a take was renamed
   in REAPER, and the name is already the only place a slot's name
   lives (§ Renaming and name drift).

1. A variant's ordinal is the family's highest plus one, so a deleted
   variant keeps its name out of circulation. The scan covers parked
   slots too, since a parked variant still holds its number. A variant
   of a variant joins the same family — varying `Bassline (var 1)`
   gives `Bassline (var 3)` where `(var 2)` stands — since the
   departures from an idea are a list and not a tree.

1. `am:vary` refuses on a slot with fewer than two live instances on
   the track. Nothing propagates from a lone instance, so the fork
   would leave a source nothing else shares. The rule also keeps the
   delete plain: the slot has a sibling, so the item goes rather than
   parking (§ Parking).

1. The variant is minted parked, and `dropInstance` moves its keeper
   onto the grid. The drop names no length, so the keeper carries the
   source's natural length, and relayout caps it at the neighbour just
   as it capped the instance replaced.

1. `am:stepVariant(take, dir)` moves a placement one step along its
   family: the neighbouring slot's instance stands in its place, dropped
   at the same start QN and on the same terms of length. A step back off
   the first of the family does nothing, and a step forward off the last
   varies. A run of forward presses therefore walks the family and mints
   one variant at the end of it — where that variant is the placement's
   only instance, the vary refuses and the walk stops there.

1. The step order is the family in ordinal order, the plain root first.
   Where two slots hold the root plain they are namesakes (§ Renaming and
   name drift): each steps forward into the variants, and a variant has no
   base to step back to. The unnamed slot falls out the same way, sharing
   its empty root with every other, so it steps alone and a forward step
   varies it.

1. Stepping off a variant that holds no other instance parks it rather
   than losing it (§ Parking), and stepping back onto it moves the keeper
   out again. A walk is therefore reversible: the slots a placement has
   passed through survive with their events, whether or not anything
   stands on them.

1. Divergence is structural, so it is a verb pressed once rather than a
   mode left on. One level down a group instance is a table with
   `assigns`, `adds` and `deletes` in it, so `localMode` routes an edit
   into the instance rather than the pattern (`docs/groupManager.md`
   § localMode) and nothing structural happens. A REAPER pool has no
   such layer: two pooled items are one source, and for one of them to
   differ a second source has to exist.

## Transport

`am` is where the stack meets REAPER's transport, all of it in QN: the
edit cursor (`am:editCursorQN`, `am:setEditCursorQN`), the loop range
(`am:loopRangeQN`, `am:setLoopRangeQN`, `am:clearLoopRange`), the play
head (`am:playPositionQN`, nil when the transport is stopped), and
`am:playFromQN`, which seeks and starts playback if it is stopped.

`am:loopTo(loQN, hiQN)` sets the loop range, turns REAPER's repeat on
and moves the edit cursor to `loQN`; a play head already inside the span
is left where it is. The repeat has to go on, since a loop range with
repeat off plays straight through and the loop never comes round.

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

Take mutation: `am:duplicateTake`, `am:moveTake`, `am:resizeTake`,
`am:trimHead`, `am:deleteTake`.
