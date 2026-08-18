# Adaptive just intonation — plan

> source: `design/archive/adaptive-ji.md` — closed 2026-08-16, superseded
> by `design/archive/adaptive-springs.md`, which retires the lattice
> search. Phase 1's move set stays in the tree; phases 2 and 3 are removed
> (`sonority`'s placement and sweep, `tuning.reach`/`origin`), and phase 4
> stopped at the facility choice, which stands, `sonority.solveToMoves`
> having been stubbed there for the springs solve to fill.

## Phases

1. **Phase 1 — The move set** (§ Where a move set comes from, § What
   makes the candidate set finite) — a ratio temper read as moves and
   their inversions, octave-free Tenney height and the complexity
   bound, and the candidates one move reaches from a placed strand.
   — landed 2026-08-15, two commits. `tuning.moves` and `tuning.height`
   survive into the springs model; `tuning.reach` and `tuning.origin`
   were removed with the search.
2. **Phase 2 — The placement** (§ A placement is connected, § Coords
   accumulate along moves, § A strand may wait, § What it costs to
   solve) — the search at a fixed offset: entries carrying a tuning
   with the coords that reached it, keyed by those coords, each strand
   joining a placed neighbour by a move, at its own onset or waiting
   for a later one.
   — landed 2026-08-16, three commits; retired and removed 2026-08-16.
3. **Phase 3 — The offset** (§ Where a placement sits, § What
   reachability spends) — the window as a joint constraint, eleven
   passes over 100¢, and the winner's exact offset from the mean of its
   displacements clamped to the admissible range.
   — landed 2026-08-16, three commits; retired and removed 2026-08-16.
4. **Phase 4 — The facility** (§ The command's slots, § Where it sits
   4, § What reachability spends) — the facility chosen on the retune
   modal with the key slot disabled, the placement branch beside
   `solveToTarget`, each strand seated as `(pitch, detune)` through the
   existing blend, and the refusal the search can raise with the
   widening offered against it.
   — stopped 2026-08-16 with the facility choice landed, two commits;
   the queued remainder died with the search.

## Landed  (newest first; prune below ~4)

- 2026-08-16 tuning: choose the retune facility beside the target (§ The command's slots)
- 2026-08-16 tuning: retune a scope by the moves the target holds (§ The target becomes a move set)
- 2026-08-16 sonority: state the winner at the offset its strands settle on (§ Where a placement sits)
- 2026-08-16 sonority: choose the offset by sweeping the root's window (§ What it costs to solve)
