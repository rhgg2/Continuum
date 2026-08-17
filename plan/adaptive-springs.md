# Adaptive just intonation by springs — plan

> source: `design/adaptive-springs.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — The relaxation** (§ The model) — box, pull and springs
   as a box-constrained quadratic in the displacements; projected
   relaxation given a choice of spellings
   — landed 2026-08-16, three commits.
2. **Phase 2 — The spellings** (§ The candidates) — beam over joins by
   one move, a member free to wait for one it sounds with, scored by box
   plus zero-displacement mistuning; the reach an author states as a
   Tenney ball ← in flight
3. **Phase 3 — The walk** (§ The solve) — capped partial answers merged
   on visible cents, a sonority scored when its last member places; one
   joint relaxation settles the winner, filling `sonority.solveToMoves`

## Landed  (newest first; prune below ~4)

- 2026-08-17 tuning: the Tenney ball, as a target generator and a pane (§ The Tenney ball)
- 2026-08-17 sonority: enumerate the spellings by a beam over joins (§ The candidates)
- 2026-08-17 sonority: the springs alone, seated in member order (§ The model)
- 2026-08-16 sonority: relax the displacements to the objective's optimum (§ The model)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

(empty)
