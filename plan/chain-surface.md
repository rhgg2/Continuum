# chain surface — plan

> source: `design/note-macros-v2.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — per-stage bypass** (§ The chain surface) — `bypass` on the fx entry: the stage folds as its mode's identity and counts as augment for precedence, with the park predicates blind to the flag  ← landed 2026-08-04 (3 commits)
2. **Phase 2 — engine gaps** (§ Known gaps and accepted quirks) — the independent fixes in the runner/park area Phase 1 has just been through: three of the section's five bullets, the other two examined 2026-08-04 and left where they are; promotable out of order  ← landed 2026-08-04 (3 commits)
3. **Phase 3 — patches** (§ The chain surface) — named chains on the shelf idiom `fx-patterns` proved, stamped by copy from the fx tab's action row  — deferred past Phase 4 (2026-08-04)
4. **Phase 4 — chain signature on the grid** (§ The chain surface) — stacked kind glyphs down the region's tail, plus a real glyph vocabulary  ← landed 2026-08-05 (2 commits)
5. **Phase 5 — ghost display** (§ Authoring and editing the fx) — derived notes surfaced as non-editable cells in the ghost styling, on while the caret sits on an fx host  ← in flight
6. **Phase 6 — scripted kinds pane** (§ The chain surface) — user Lua kinds in a third editor pane on `libraryTreeSpec`, eval-into-registry

## Landed  (newest first; prune below ~4)

- 2026-08-06 tv: suppress the parked originals while the ghosts are up (§ Authoring and editing the fx)
- 2026-08-06 tv: ghost a chain's derived notes while the caret sits on its host (§ Authoring and editing the fx)
- 2026-08-05 tm: add fxNotes, a windowed accessor for derived note onsets (§ Authoring and editing the fx)
- 2026-08-05 tv: stack the region's chain down its tail rows (§ The chain surface)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. A provisional note column for a derived lane that carries nothing authored — the case an augment chain over an empty span produces, where the ghosts are the only thing there is to see and have nowhere to hang. Its lifecycle is data-derived, on the model of the fx column: it materialises whenever the derived notes need a lane no column covers, and stands empty until the ghosts are on. Deriving it from the caret instead would let the column set shift under the very caret that gates the ghosts, and `ec:col()` is an index. Spec in `vm_grid_spec`.
