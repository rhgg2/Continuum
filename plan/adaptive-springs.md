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

- 2026-08-17 sonority: the springs alone, seated in member order (§ The model)
- 2026-08-16 sonority: relax the displacements to the objective's optimum (§ The model)
- 2026-08-16 sonority: the springs objective, in its two units (§ The model)
- 2026-08-16 sonority: derive a spelling's springs and box (§ The model)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

3. `sonority.spellings` — the beam over joins, waiting included. Member
   1 anchors at its seat with empty coords; each round joins one
   unplaced member to a placed one by a move, admitting the join where
   the pure position lands within two half-windows of the member's seat,
   and forking a waiting state beside it for the members the caller says
   may wait — the walk knowing which still have an onset to sound
   through. The state carries the running box and mistuning of § The
   candidates 2 as its score, and the round dedupes states by their
   coords assignment, sorts, and cuts to a width the caller states, as
   it states the stiffness. Returns box, springs and the members left
   waiting per survivor, best first; where a member out of waits joins
   nothing, greedy components stand in, the box charged only within a
   component of more than one member and springs only inside a
   component, so a bare tritone under a 5-limit set comes back with no
   spring and no box (§ Open 2). A width of `math.huge` is a full
   enumeration, which is how the spec certifies a beam of twelve at five
   members. This is the design's one hot loop, so nothing per candidate
   that allocates more than the state it keeps. Red-first in
   `sonority_spec` on the rolled minor and on that tritone.
5. `tuning.genTenney(generators, bound)` and its pane entry — a target
   generator holding every interval its stated generating intervals
   compose to within a bound, that bound written as the most complex
   ratio admitted: `3/2 5/4` under `15/8` gives the eleven points
   § Measured takes its figures over, and `45/32` gives nineteen, the
   tritone spellings among them. The entry sits beside the diamond's in
   the temper editor under the diamond's cap on points, and coords come
   back as octave-reduced tokens — the inverse of `tuning.coords`, which
   the repo does not hold yet. Specs in `tuning_spec`; the design is
   `design/adaptive-tuning.md` § The Tenney ball.
