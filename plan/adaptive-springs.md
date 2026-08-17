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
   and the stiffness surfaces as a dial beside harmonic lock ← in flight

## Landed  (newest first; prune below ~4)

- 2026-08-17 sonority: relax from a warm start, with strands held (§ The solve)
- 2026-08-17 tuning: the Tenney ball, as a target generator and a pane (§ The Tenney ball)
- 2026-08-17 sonority: enumerate the spellings by a beam over joins (§ The candidates)
- 2026-08-17 sonority: the springs alone, seated in member order (§ The model)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

2. Derive the walk's inputs from the notation: a seat and a window per
   strand, and per onset the members in the shape `sonority.spellings`
   takes, with `mayWait` true for a member that has a later onset to
   sound through. A member the sonority holds by recency has stopped,
   so it is joined to and does not itself wait.
3. Walk the onsets carrying capped partial answers. Each carried answer
   is extended by every spelling of the onset and relaxed over the
   strands the onset sounds; its cost is taken over the springs
   accumulated so far plus the box each spelling charged; two answers
   merge where the strands the future can still see agree on cents
   rounded to half a cent, and the carried set is cut to its cap. The
   spec pins the ii–V–I against what an exhaustive search over its
   spelling lists returns.
4. Charge a sonority holding a waiting member when its last member
   places, and enforce that a wait resolves only to coords no earlier
   sonority could have offered. The spec pins the rolled C minor landing
   where the struck chord lands.
5. Fill `sonority.solveToMoves`: settle the winner by one joint
   relaxation over its accumulated springs with every strand free, and
   return a tuning in cents per strand, which `trackerView` already
   seats. The stiffness arrives as a parameter, passed the measured
   constant until the next item surfaces it. The spec runs the take end
   to end.
6. Surface the stiffness as a slot beside harmonic lock, offered under
   the moves facility alone and remembered as harmonic lock is; its
   label and range settle when the brief is compiled.
