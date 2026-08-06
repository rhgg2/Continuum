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

- 2026-08-06 tv: show a provisional note column for a chain's derived lanes (§ The chain surface)
- 2026-08-06 tv: suppress the parked originals while the ghosts are up (§ Authoring and editing the fx)
- 2026-08-06 tv: ghost a chain's derived notes while the caret sits on its host (§ Authoring and editing the fx)
- 2026-08-05 tm: add fxNotes, a windowed accessor for derived note onsets (§ Authoring and editing the fx)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. Provisional columns for a chain's **continuous** targets. A pb or cc chain on a channel with nothing authored on that target has no column at all, so there is nowhere to author the base an augment sums onto and no sign on the grid that the target is claimed. The lifecycle is the note case's, but the target set must come from the settled census rather than from the emission: emission is gated, so a kept producer's target vanishes and returns with the dirt — `tm_gate_parity_spec` catches exactly this. Leaves untouched the separate question of whether the seated curve shows in the column.
