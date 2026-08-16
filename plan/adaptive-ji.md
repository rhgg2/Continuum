# Adaptive just intonation — plan

> source: `design/adaptive-ji.md` — synthesis compiled from there;
> don't design here. It rides behind the command
> `plan/adaptive-tuning.md` phase 4 built, and exchanges only the
> candidate model.

## Phases

1. **Phase 1 — The move set** (§ Where a move set comes from, § What
   makes the candidate set finite) — a ratio temper read as moves and
   their inversions, octave-free Tenney height and the complexity
   bound, and the candidates one move reaches from a placed strand.
   — landed 2026-08-15, two commits.
2. **Phase 2 — The placement** (§ A placement is connected, § Coords
   accumulate along moves, § A strand may wait, § What it costs to
   solve) — the search at a fixed offset: entries carrying a tuning
   with the coords that reached it, keyed by those coords, each strand
   joining a placed neighbour by a move, at its own onset or waiting
   for a later one.
   — landed 2026-08-16, three commits.
3. **Phase 3 — The offset** (§ Where a placement sits, § What
   reachability spends) — the window as a joint constraint, eleven
   passes over 100¢, and the winner's exact offset from the mean of its
   displacements clamped to the admissible range.  ← in flight
4. **Phase 4 — The facility** (§ The command's slots, § Where it sits
   4) — the facility chosen on the retune modal with the key slot
   disabled, the placement branch beside `solveToTarget`, and each
   strand seated as `(pitch, detune)` through the existing blend.
   - gated on § Open 1: what the command does with a chord the move set
     misspells.

## Landed  (newest first; prune below ~4)

- 2026-08-16 sonority: state the winner at the offset its strands settle on (§ Where a placement sits)
- 2026-08-16 sonority: choose the offset by sweeping the root's window (§ What it costs to solve)
- 2026-08-16 sonority: name the pair solveToPoints and placeAt (§ Where it sits)
- 2026-08-16 sonority: let a strand wait for the neighbour that places it (§ A strand may wait)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

(empty — phase 3 has nothing left to compile.)
