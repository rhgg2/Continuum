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
   Tenney ball — landed 2026-08-17, three commits.
3. **Phase 3 — The walk** (§ The solve) — capped partial answers merged
   on visible cents, a sonority scored when its last member places; one
   joint relaxation settles the winner, filling `sonority.solveToMoves`,
   and the stiffness surfaces as a dial beside harmonic lock
   — landed 2026-08-18, six commits.
4. **Phase 4 — Waiting in the beam** (§ The candidates) — waiting decided
   per member inside one beam rather than enumerated as a set outside it,
   the cut running within a waiting count, and one anchor to a waiting
   set — landed 2026-08-18, one commit.

## Landed  (newest first; prune below ~4)

- 2026-08-18 sonority: refuse an extension that cannot survive the cut before it is relaxed (§ The solve)
- 2026-08-18 sonority: tie an answer's settled onsets once, not once per spelling (§ The solve)
- 2026-08-18 sonority: charge what has stopped once, and merge on what still moves (§ The solve)
- 2026-08-18 sonority: charge the onsets the walk has closed once (§ The solve)
- 2026-08-18 sonority: key an answer by position and join its parts from a list (§ The solve)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

(empty)
