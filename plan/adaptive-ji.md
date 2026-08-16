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
   displacements clamped to the admissible range.
   — landed 2026-08-16, three commits.
4. **Phase 4 — The facility** (§ The command's slots, § Where it sits
   4, § What reachability spends) — the facility chosen on the retune
   modal with the key slot disabled, the placement branch beside
   `solveToTarget`, each strand seated as `(pitch, detune)` through the
   existing blend, and the refusal the search can raise with the
   widening offered against it.  ← in flight

## Landed  (newest first; prune below ~4)

- 2026-08-16 tuning: choose the retune facility beside the target (§ The command's slots)
- 2026-08-16 tuning: retune a scope by the moves the target holds (§ The target becomes a move set)
- 2026-08-16 sonority: state the winner at the offset its strands settle on (§ Where a placement sits)
- 2026-08-16 sonority: choose the offset by sweeping the root's window (§ What it costs to solve)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

3. The refusal the search can state: `sonority.placeAt` returns the
   onset that emptied, the strand it could not place there and the
   neighbour that strand would have joined, rather than a bare nil; and
   `sonority.solveToMoves` reports the furthest such refusal where every
   offset refused. The budget `placeAt` raises on (`sonority.lua:356`)
   becomes a refusal of the same shape, the design having the search
   refuse there rather than raise (§ What it costs to solve). Spec is a
   bare tritone under a move set holding no `7/5`, in
   `sonority_sweep_spec`.

4. The widening: `tuning.reach` and `tuning.origin` take a widen flag
   and admit the nearest candidates at strain past 1 where the window
   holds none, as `tuning.shortlist` does; `placeAt` and `solveToMoves`
   carry it; `tv:retune`'s widen argument reaches the moves branch; and
   the confirm the command offers names the onset and the interval the
   refusal reported. Spec is the previous item's tritone, placing once
   widened.
