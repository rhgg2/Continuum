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

- 2026-08-06 tv: ghost a chain's derived notes while the caret sits on its host (§ Authoring and editing the fx)
- 2026-08-05 tm: add fxNotes, a windowed accessor for derived note onsets (§ Authoring and editing the fx)
- 2026-08-05 tv: stack the region's chain down its tail rows (§ The chain surface)
- 2026-08-04 generators: a glyph per kind; the fx badge prints what it is handed (§ The chain surface)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. Parked cells drop out of their columns while the ghosts are showing, so the grid shows the realisation rather than both pictures of it at once. The suppression rides the same per-frame overlay the ghosts do — a `hidden` half beside the notes half — rather than the placement pass, which the caret cannot reach without a rebuild. That also keeps `col.cells` intact, so nothing that resolves an event through a cell loses its footing while the ghosts are up. The exception is the cell the caret is resolving its host from: a note hosting a replace chain parks itself, and the caret sitting on it is the very thing that turned the ghosts on, so hiding it would take away both the host and any way to edit the note. That cell stays visible, and its row shows no ghost because a real cell wins. Spec in `tv_fx_region_spec`, next to the parked-cell rendering tests.
2. A provisional note column for a derived lane that carries nothing authored — the case an augment chain over an empty span produces, where the ghosts are the only thing there is to see and have nowhere to hang. Its lifecycle is data-derived, on the model of the fx column: it materialises whenever the derived notes need a lane no column covers, and stands empty until the ghosts are on. Deriving it from the caret instead would let the column set shift under the very caret that gates the ghosts, and `ec:col()` is an index. Spec in `vm_grid_spec`.
