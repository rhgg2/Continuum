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
   ← in flight
2. **Phase 2 — The placement** (§ A placement is a tree, § Coords
   accumulate along it, § What it costs to solve) — the search at a
   fixed offset: entries carrying a tuning with the coords that reached
   it, keyed by those coords, each strand born at an onset attaching by
   a move to one already placed.
   - gated on § Open 1: whether this is `sonority.lua` or a module of
     its own, and what is left pinnable on its own (§ What the solver
     loses).
3. **Phase 3 — The offset** (§ Where a placement sits, § What
   reachability spends) — the window as a joint constraint, eleven
   passes over 100¢, and the winner's exact offset from the mean of its
   displacements clamped to the admissible range.
4. **Phase 4 — The facility** (§ The command's slots, § Where it sits
   4) — the facility chosen on the retune modal with the key slot
   disabled, the placement branch beside `solveToTarget`, and each
   strand seated as `(pitch, detune)` through the existing blend.
   - gated on § Open 2: what the command does with a chord the move set
     misspells.

## Landed  (newest first; prune below ~4)

- 2026-08-15 tuning: reach the candidates one move from a placed strand (§ A placement is a tree)
- 2026-08-15 tuning: read a ratio temper as a move set (§ Where a move set comes from)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)
