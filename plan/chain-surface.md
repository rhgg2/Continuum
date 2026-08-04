# chain surface — plan

> source: `design/note-macros-v2.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — per-stage bypass** (§ The chain surface) — `bypass` on the fx entry: the stage folds as its mode's identity and counts as augment for precedence, with the park predicates blind to the flag  ← landed 2026-08-04 (3 commits)
2. **Phase 2 — engine gaps** (§ Known gaps and accepted quirks) — the independent fixes in the runner/park area Phase 1 has just been through: three of the section's five bullets, the other two examined 2026-08-04 and left where they are; promotable out of order  ← in flight
3. **Phase 3 — patches** (§ The chain surface) — named chains on the shelf idiom `fx-patterns` proved, stamped by copy from the fx tab's action row
4. **Phase 4 — chain signature on the grid** (§ The chain surface) — stacked kind glyphs down the region's tail, plus a real glyph vocabulary
5. **Phase 5 — ghost display** (§ Authoring and editing the fx) — derived notes surfaced as non-editable cells in the ghost styling, on while the fx pane holds focus
6. **Phase 6 — scripted kinds pane** (§ The chain surface) — user Lua kinds in a third editor pane on `libraryTreeSpec`, eval-into-registry

## Landed  (newest first; prune below ~4)

- 2026-08-04 tm: delete fx.rest; the target column is the augment base (§ Continuous cc)
- 2026-08-04 tv: bypass a stage from the fx tab -- byp button and Super+B (§ The chain surface)
- 2026-08-03 generators: a bypassed stage yields precedence, folding as a zero augment (§ The chain surface)
- 2026-08-03 tm: bypassed fx stage folds as the identity, keeping ownership (§ The chain surface)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. **Teach `nextSameLaneNote` to see parked cells.** It seeks only in the
   lane's on-take column and then confirms the host is seated there
   (`trackerManager.lua:3417`), so a self-parked host has no successor and a
   `target='next'` slide emits nothing — `[trill, slide]` gives the trill
   alone. Union the lane's parked cells (`channels[chan].parked`, which carry
   `lane` and a logical `ppq`) into both the seek and the seat check. The same
   change settles the converse: an on-take host whose successor was parked by a
   region currently slides to the note *after* the region, which is a wrong
   interval rather than a missing one. Spec home
   `tests/specs/tm_fx_region_spec.lua`, red-first on a self-parked
   `[trill, slide]` host.
2. **Split a member that straddles the window's end edge.** `covered()`
   (`trackerManager.lua:2832`) is onset-based, so a note whose onset falls
   inside the window parks whole and its sounding tail past the region's end
   goes silent with it. The covered head should park as it does now, with the
   remainder from the window end still sounding. The ownership fork is open and
   belongs to the brief: either the park pass owns the remainder and re-derives
   it each rebuild, reconciled like a derived spec and dropped on restore, or
   the take is genuinely split at park time and restore rejoins head and
   remainder. Design § *Parked editing*'s uuid rule — a restore keeps the
   original, a relocation sheds it — constrains the second. Spec home
   `tests/specs/tm_fx_region_spec.lua`, alongside the parked-tail realisation
   cases at `:390` and `:481`.
