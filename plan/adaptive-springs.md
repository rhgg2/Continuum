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

(nothing yet)

## Now

(empty — run /plan-next to compile the top Queued item.)

## Queued (current phase; one-liners)

1. **The springs of a spelling.** In `sonority.lua`: from a sonority's
   members, their seats, and a spelling — coords per member relative
   to the first — derive a spring per pair the spelling holds, each
   stating the displacement gap at which the pair sounds pure under
   nearest-octave reduction, with the spelling's box read by
   `sonority.score`; the spec pins a spelled major triad's springs and
   box by hand. The derivation is `beamSpell`'s tail in
   `tests/spikes/springs/springcore.lua`.
2. **The springs objective.** The cost of a choice of spellings at
   given displacements: box summed over the walk, stiffness ×
   mistuning² per spring and strength × displacement² per strand,
   mistuning and displacement both in half-windows (the spike's
   `SC.totalCost`); the spec prices a hand-built two-sonority case
   term by term, and displacements realising every spelling leave the
   springs slack.
3. **Projected relaxation.** Minimise the objective in the
   displacements, each clamped to its strand's window: sweep the
   closed-form coordinate update to a tolerance, as `SC.qpSolve` does;
   the spec pins a hand-solvable pair, a strand pressed to its window
   edge, and a comma loop whose residue spreads across the springs at
   lower cost than leaving one spring to bear it.
