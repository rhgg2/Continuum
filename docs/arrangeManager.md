# arrangeManager

Project-wide model for the arrange page (`design/arrange.md`). Owns no
state of its own — every read walks REAPER's track/item lists directly,
every write goes through cm. The per-track **slot palette** lives in cm
at the track tier under `arrangeSlots`.

## Why slot identity is derived per frame

A take's "which slot is this an instance of?" is not stored on the take.
It is rederived each frame from `takeIdOf(take)`, then joined against
the per-track `arrangeSlots` dictionary. Two consequences:

- A take whose underlying source no longer matches any slot in the
  dictionary becomes an **orphan**: rendered, editable, but absent from
  the palette. The user sees it on the grid; the palette doesn't know
  about it. This is by design — the palette is the user's curated set,
  not the union of everything REAPER happens to hold.
- Renaming a slot is realised by walking every item on the track and
  writing `SetTakeName` to each take whose id matches. cm holds no
  name; the name is whatever the takes happen to say (first-found
  wins). Drift is accepted: if the user renames a single take in
  REAPER, the palette will start showing that name once it's the
  first-found.

This trades a small surface (no slot-name field, no cache invalidation
on rename) for an accepted drift mode. The alternative — caching names
in cm — multiplies the staleness problem instead of resolving it.

## The id chokepoint

`takeIdOf` is the single function that decides a source's identity:

- **MIDI:** the `POOLEDEVTS` GUID inside the item state chunk. Pooled
  takes share one GUID; that's the whole point of pooling. Reading it
  from the chunk is more expensive than a typed accessor would be, but
  REAPER exposes no typed accessor, and the chunk parse is local.
- **Audio:** the source filename. REAPER doesn't pool audio — two
  audio takes referencing the same file are independent items — so
  filename is the only stable identity we can lean on.

A take whose id can't be derived (no chunk, no source) is treated as
an orphan; nothing else fails. Phase 1 leaves the cross-session
stability of MIDI ids as accepted: REAPER's pool GUID is in fact
persisted in the project file, so reload preserves it; in-session
re-creation does not.

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

## Why MIDI slots are lazy-id

A REAPER pool GUID only exists once a source exists. `newMidiSlot`
can't generate the GUID up front — there's nothing to belong to a
pool of one. So a fresh slot is reserved with `id = nil`. The first
`dropInstance` calls `CreateNewMIDIItemInProj`, lets REAPER pick a
GUID, reads it back out of the item state chunk, and writes it into
the slot dict. Every subsequent drop reads `slot.id`, builds an item
chunk with that GUID in the `POOLEDEVTS` line, and `SetItemStateChunk`s
it back — REAPER then treats the items as one pool, so edits
propagate.

The alternative (eager: create a parked item just to harvest the
GUID) was rejected: a visible-but-zero-length stub on every track is
worse than a sometimes-nil slot id. Callers that already hold a GUID
(tests, future re-import paths) pass it via `opts.id` to skip the
harvest.

A consequence of nil ids: `tracksTakes`, `trackSlots`, `slotForTake`,
`deleteSlot(removeInstances=true)`, and `renameSlot` all guard against
nil before comparing or removing — a lazy slot must never match an
orphan take whose own id-derivation happened to return nil.

## Audio drops are not pooled

`dropInstance` for audio creates a fresh `PCM_Source_CreateFromFile`
and wires it onto a new item/take. REAPER does not pool audio, so
two instances of the same audio slot are independent items that
happen to reference the same file. The grouping you see in the
palette is purely a property of the shared filename, which is what
`takeIdOf` returns for audio sources.

## Surface

Discovery: `am:projectTracks`, `am:tracksTakes`, `am:trackSlots`,
`am:slotForTake`, `am:keyForSlot`.

Slot management: `am:newMidiSlot`, `am:newAudioSlot`, `am:deleteSlot`,
`am:renameSlot`.

Placement: `am:dropInstance(trackIdx, slotIdx, qnPos, lengthQN?)`.

Folded from sequenceManager: `am:takesUsing`, `am:reswingAll`.

Still ahead (per `design/arrange.md`, phases 5–7): `duplicateTake`,
`moveTake`, `resizeTake`, `trimStart`, `trimEnd`, `deleteTake`.
