# fx patterns — plan

> source: `design/archive/fx-patterns.md` — synthesis compiled from
> there; don't design here.

## Phases

1. **P1 — gridPane extraction** (§ P1) — grid core + lane strip out of
   trackerRender; bindings shared as `pageBindings.tracker` — landed
2. **P2 — pattern store** (§ Data model) — `fxPatterns` ds key + tm
   `dataChanged` arm — landed (the arm went dead at P3.5 and was
   deleted during P4; `tm_fx_patterns_spec` pins its absence)
3. **P3 — patternEditor** (§ The checkout model / § The mini stack) —
   checkout stack + modal, both kinds, live preview — landed
4. **P3.5 — inline bodies** (§ P3.5) — param stores the body, commit
   via `setFxField`; shared library re-scoped to a copy shelf — landed
5. **P4 — polish** (§ P4) — landed (Mini undo dropped at close)

## Landed (newest first; prune below ~4)

- 2026-07-25 pe: rpb rides the body, seeding the grid at open (§ P4)
- 2026-07-25 pe: shelf delete via a per-row × in the Load picker (§ P4)
- 2026-07-24 gen: chord-stamp kind — a poly chord rebased onto members (§ P4)
- 2026-07-24 pe: add per-kind poly flag for note-pattern lanes (§ P4)

## Now

(empty — closed 2026-07-27. P4's queue ran dry; Mini undo, deprioritised
2026-07-24, was dropped outright at close and is recorded as dropped in
the design doc's § P4.)

## Queued (current phase; one-liners)

(empty — see Now.)
