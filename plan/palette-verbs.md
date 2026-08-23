# Palette verbs — plan

> source: `design/palette-verbs.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — Prune** — landed 2026-08-24, 2 commits; the model now
   sits in docs/arrangeManager.md and docs/arrangePage.md.
2. **Phase 2 — The commit** (§ Bases, § Committing an assignment) —
   `am:tidySlots(trackIdx, assignment)`: members gathered per base,
   ordered by ordinal then slot index, pinned members holding their
   ordinal and the rest taking the lowest free one.  ← in flight
3. **Phase 3 — The editor** (§ The editor) — the seed (bases from the
   distinct roots, ambiguous bases and unnamed slots pinned) and the modal
   kind that shows it: base list above, one row per MIDI slot below with
   its assignment and the name it will get.

Phase 3 has to settle where the seed derivation lives. `am:seedTidy` puts
it under test; the design says only that the editor hands over the
assignment, which the render layer can't be tested through.

## Landed  (newest first; prune below ~4)

- 2026-08-24 arrange: a prune button on the palette, and no per-slot verbs (§ Prune)
- 2026-08-24 am: prune a track's parked slots (§ Prune)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. **`am:tidySlots(trackIdx, assignment)`** — the assignment maps a MIDI
   slot index to a base, an absent slot being pinned. A base's members
   are its assigned slots together with the pinned slots whose root is
   that base, ordered by current ordinal (plain counting as 0) then by
   slot index. A pinned member holds its ordinal; each other member, in
   that order, takes the lowest ordinal no pinned member holds and no
   earlier member took. Ordinal 0 names the base plain, the rest carry
   ` (var N)`. The ordinal rule sits beside `variantFamily`, and the
   id → name write at the foot of `am:renameSlot` is extracted for both
   to use — routing through `renameSlot` itself would reroot a family per
   slot. am wraps no undo block; phase 3's editor commit supplies it.
   Spec in `tests/specs/am_spec.lua`.
