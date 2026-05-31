# arrangeManager

Project-wide model for the arrange page (`design/arrange.md`). Owns no
state of its own — every read walks REAPER's track/item lists directly,
every write goes through cm. The per-track **slot palette** lives in cm
at the track tier under `arrangeSlots`.

## Every grouped take is a slot

The palette is not a curated set sitting alongside the project items.
It is the project items, grouped by source identity. A slot has no
existence apart from at least one take on the grid carrying its id;
the last take to leave takes the slot with it. The biconditional in
one direction: minting a slot means dropping an item. In the other:
deleting the last instance prunes the slot.

The persistence in `arrangeSlots` is an **index-to-id stability map**.
Without it, two reads of the same project could allocate `{p1}` to
slot 0 in frame N and slot 1 in frame N+1 — base62 hotkeys would shift
under the user's fingers. The dict pins indices across reads and
across sessions; the live takes drive what gets pinned.

`ensureSlots(track)` is the single chokepoint. It walks live takes,
allocates the lowest-free slot for any id not yet in the dict,
prunes dict entries whose id has no live take, writes back if
anything changed, and returns the freshened `(dict, slotForId,
firstName)` so callers don't repeat the walk. It is idempotent — a
second call in the same frame performs no writes. Every public read
(`projectTracks`, `tracksTakes`, `trackSlots`, `slotForTake`) routes
through it, so the four reads always agree on which slot owns which
id.

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

## Why writes go through `cm:writeTrackKey`

The arrange page edits every track's palette, but the current cm
context is whatever the tracker page bound (typically a single
focused take, whose track is one of the project's). Routing slot
writes through the existing `cm:set('track', ...)` would either
require setting cm's context to each track in turn (firing reload
churn on every subscriber) or accidentally write to the wrong tier.
`cm:writeTrackKey` is the symmetric counterpart of `readTrackKey`:
it bypasses the cache, writes P_EXT directly, and fires a targeted
`configChanged` carrying an explicit `track` field so subscribers
that care only about the bound track can ignore it.

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

The tm dependency is **optional**: pure discovery callers (the
arrange page in phases 2-5) construct am with `cm` only; the swing
editor's wiring passes both because it needs reswing.

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
when at least one instance exists, so id is always populated.

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

MIDI drops therefore require a live sibling. If a slot somehow
survives in cm without any live instance — only possible between a
delete and the next `ensureSlots` — `dropInstance` returns nil.

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

## Surface

Discovery: `am:projectTracks`, `am:tracksTakes`, `am:trackSlots`,
`am:slotForTake`, `am:keyForSlot`.

Slot mutation: `am:renameSlot`, `am:deleteSlot` (removes every
instance of the slot's source on the track, returns the count).

Placement: `am:createAndDropMidi(trackIdx, qnPos, lengthQN, name) ->
(slotIdx, take)`, `am:dropInstance(trackIdx, slotIdx, qnPos,
lengthQN?)`.

Folded from sequenceManager: `am:takesUsing`, `am:reswingAll`.

Still ahead (per `design/arrange.md`, phases 5–7): `duplicateTake`,
`moveTake`, `resizeTake`, `trimStart`, `trimEnd`, `deleteTake`.
