# Adaptive just intonation by springs — plan

> source: `design/adaptive-springs.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — The relaxation** (§ The model) — box, pull and springs
   as a box-constrained quadratic in the displacements; projected
   relaxation given a choice of spellings  ← in flight
2. **Phase 2 — The spellings** (§ The candidates) — beam over joins
   with composed moves, scored by box plus zero-displacement mistuning
3. **Phase 3 — The walk** (§ The solve) — capped partial answers
   merged on visible cents; one joint relaxation settles the winner,
   filling `sonority.solveToMoves`

## Landed  (newest first; prune below ~4)

- 2026-08-16 sonority: relax the displacements to the objective's optimum (§ The model)
- 2026-08-16 sonority: the springs objective, in its two units (§ The model)
- 2026-08-16 sonority: derive a spelling's springs and box (§ The model)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

(empty — the phase's items are all compiled.)
