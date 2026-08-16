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

- 2026-08-16 sonority: name the pair solveToPoints and placeAt (§ Where it sits)
- 2026-08-16 sonority: let a strand wait for the neighbour that places it (§ A strand may wait)
- 2026-08-15 sonority: carry the placement across onsets (§ What it costs to solve)
- 2026-08-15 sonority: place one sonority's strands at a fixed offset (§ A placement is connected)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

2. **The sweep.** `sonority.solveToMoves(strands, n, strength,
   notation, moves)`, standing beside `solveToPoints` and differing
   from it in the candidate model alone. It runs `placeAt` once at each
   of eleven offsets spanning the root strand's own step window — 100¢
   under a 12-EDO notation — keeps the cheapest placement together with
   the offset that found it, and returns nil only where every offset
   refuses. A budget raise inside a pass propagates out of the sweep
   rather than skipping that offset. Spec: a chord with no placement
   where it was written places under the sweep; a sweep at 10¢ returns
   the placement a finer sweep returns; a move set that reaches nothing
   at any offset returns nil.

3. **The exact offset.** The winner's offset is then settled off its
   own strands: the admissible range is the intersection of what each
   strand's window allows, the offset is the mean of their
   displacements clamped to that range, and the pull is re-read there,
   so the cost returned is the cost at the offset returned. `seatOf` is
   private to `tuning.lua`, so this needs a small tuning-side reading of
   a placed strand's displacement and the window halves either side.
   Where a notation's window halves differ the mean is an approximation
   rather than the minimiser, which is what § Where a placement sits
   already says; leave it there. Spec: a I–IV–V–I settles at +4¢ and a
   ii–V–I at +32¢; a placement whose mean falls outside the range clamps
   to the edge; the ii–V–I returns the same answer under a stiffer pull,
   the floor being what the pull cannot spend.
