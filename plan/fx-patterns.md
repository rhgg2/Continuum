# fx patterns — plan

> source: `design/fx-patterns.md` — synthesis compiled from there;
> don't design here.

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
5. **P4 — polish** (§ P4) — queue below ← in flight

## Landed (newest first; prune below ~4)

- 2026-07-25 pe: rpb rides the body, seeding the grid at open (§ P4)
- 2026-07-25 pe: shelf delete via a per-row × in the Load picker (§ P4)
- 2026-07-24 gen: chord-stamp kind — a poly chord rebased onto members (§ P4)
- 2026-07-24 pe: add per-kind poly flag for note-pattern lanes (§ P4)

## Now

(empty — P4's queue is clear. Its only remaining design item is Mini undo, deprioritised 2026-07-24 (value unclear; off the queue but not dropped from the design doc), so the next /plan-next decides whether P4 closes or the programme moves on.)

## Queued (current phase; one-liners)

(empty — see Now.)
