# chain surface — plan

> source: `design/note-macros-v2.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — per-stage bypass** (§ The chain surface) — `bypass` on the fx entry: the stage folds as its mode's identity and counts as augment for precedence, with the park predicates blind to the flag  ← landed 2026-08-04 (3 commits)
2. **Phase 2 — engine gaps** (§ Known gaps and accepted quirks) — the independent fixes in the runner/park area Phase 1 has just been through: three of the section's five bullets, the other two examined 2026-08-04 and left where they are; promotable out of order  ← landed 2026-08-04 (3 commits)
3. **Phase 3 — patches** (§ The chain surface) — named chains on the shelf idiom `fx-patterns` proved, stamped by copy from the fx tab's action row  — deferred past Phase 4 (2026-08-04)
4. **Phase 4 — chain signature on the grid** (§ The chain surface) — stacked kind glyphs down the region's tail, plus a real glyph vocabulary  ← in flight
5. **Phase 5 — ghost display** (§ Authoring and editing the fx) — derived notes surfaced as non-editable cells in the ghost styling, on while the fx pane holds focus
6. **Phase 6 — scripted kinds pane** (§ The chain surface) — user Lua kinds in a third editor pane on `libraryTreeSpec`, eval-into-registry

## Landed  (newest first; prune below ~4)

- 2026-08-04 generators: a glyph per kind; the fx badge prints what it is handed (§ The chain surface)
- 2026-08-04 design: a straddling member parks whole -- withdrawn, not a gap (§ Known gaps and accepted quirks)
- 2026-08-04 tm: nextSameLaneNote sees parked cells; a region has no lane (§ Known gaps and accepted quirks)
- 2026-08-04 tm: delete fx.rest; the target column is the augment base (§ Continuous cc)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

- **The region's fx cell carries its whole chain, and the tail rows draw
  it.** The view stacks the stages' glyphs in series order down the
  region's rows: stage one stays the badge on the head row, stages two
  onward take the rows below. The per-row list hangs off the tail record
  the view already builds with the region's start and end rows, so the
  cell table keeps one entry per region and the cursor, the selection and
  the window verbs are untouched. A bypassed stage draws dimmed rather
  than accented, matching the fx tab. Where a chain has more stages than
  the region has rows the stack clips at the last row and marks it, so a
  clipped chain doesn't read as a short one. Specs land in
  `tv_fx_region_spec.lua`, which already asserts the badge and the tail:
  series order, the bypass flag, and the clipping.
