# Palette verbs — plan

> source: `design/palette-verbs.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — Prune** (§ Prune) — `am:pruneSlots` deleting every slot
   whose row carries `parked`, `av:pruneSlots` clearing the palette focus,
   and the palette button behind a confirm naming the count.  ← in flight
2. **Phase 2 — The commit** (§ Bases, § Committing an assignment) —
   `am:tidySlots(trackIdx, assignment)`: members gathered per base,
   ordered by ordinal then slot index, pinned members holding their
   ordinal and the rest taking the lowest free one; one undo block.
3. **Phase 3 — The editor** (§ The editor) — the seed (bases from the
   distinct roots, ambiguous bases and unnamed slots pinned) and the modal
   kind that shows it: base list above, one row per MIDI slot below with
   its assignment and the name it will get.

Phase 3 has to settle where the seed derivation lives. `am:seedTidy` puts
it under test; the design says only that the editor hands over the
assignment, which the render layer can't be tested through.

## Landed  (newest first; prune below ~4)

(nothing yet)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. `am:pruneSlots(trackIdx)` forever-deletes every slot row carrying
   `parked` — the keeper item off scratch, a MIDI slot's pool metadata,
   the dict entry — and returns how many went; red-first in `am_spec.lua`
   over a track holding a live slot, a parked MIDI slot and a parked audio
   slot.
2. `av:pruneSlots(trackIdx)` clears the palette focus when the focused
   slot was among the pruned, and the palette grows a `prune` button,
   disabled with nothing parked, opening a confirm that names the count.
