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

- 2026-08-17 sonority: charge a sonority that held a waiter, when it places (§ The candidates)
- 2026-08-17 sonority: walk the onsets carrying capped partial answers (§ The solve)
- 2026-08-17 sonority: derive the walk's terms from the notation (§ The solve)
- 2026-08-17 sonority: relax from a warm start, with strands held (§ The solve)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)
4b. Refuse a wait that resolves to coords the sonority it waited in had
   itself enumerated, so a spelling is enumerated once however long it
   waited. The spec pins the rolled C minor under a set that spells its
   opening pair, where the two roads cost alike.
5. Fill `sonority.solveToMoves`: settle the winner by one joint
   relaxation over its accumulated springs with every strand free, and
   return a tuning in cents per strand, which `trackerView` already
   seats. The stiffness arrives as a parameter, passed the measured
   constant until the next item surfaces it. The spec runs the take end
   to end.
6. Surface the stiffness as a slot beside harmonic lock, offered under
   the moves facility alone and remembered as harmonic lock is; its
   label and range settle when the brief is compiled.
