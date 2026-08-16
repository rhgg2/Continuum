# Adaptive just intonation by springs — plan

> source: `design/adaptive-springs.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — The relaxation** (§ The model) — box, pull and springs
   as a box-constrained quadratic in the displacements; projected
   relaxation given a choice of spellings
   — landed 2026-08-16, three commits.
2. **Phase 2 — The spellings** (§ The candidates) — beam over joins
   with composed moves, scored by box plus zero-displacement mistuning
   ← in flight
3. **Phase 3 — The walk** (§ The solve) — capped partial answers
   merged on visible cents; one joint relaxation settles the winner,
   filling `sonority.solveToMoves`

## Landed  (newest first; prune below ~4)

- 2026-08-16 sonority: relax the displacements to the objective's optimum (§ The model)
- 2026-08-16 sonority: the springs objective, in its two units (§ The model)
- 2026-08-16 sonority: derive a spelling's springs and box (§ The model)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. `sonority.springs` returns its spring list alone, and takes its
   seats in member order. The box leaves the record, being
   `sonority.score(spelling)` and nothing besides, and the beam of item
   3 will hold it; the seats join `members` and `spelling` as a third
   member-parallel array, so a call keys one way and only the springs
   it returns carry strand indices, as the passage-wide displacement
   and window vectors do. Green-first, pinning `sonority_spec`'s two
   hand-worked spellings and the objective case that reads `box`.
2. `tuning.composed(moves)` — a move set closed under one
   composition: every move, plus every ordered pair's product, deduped
   by coords with the height read off the composed coords. A set
   holding `5/4` and `3/2` thereby holds `6/5`, which is how a C minor
   triad spells its E♭ below the G, and the height prices the reach.
   Spec in `tuning_spec` against the 5-limit set.
3. `sonority.spellings` — the beam over joins. Member 1 anchors at its
   seat with empty coords; each round joins one unplaced member to a
   placed one by a move, admitting the join where the pure position
   lands within two half-windows of the member's seat; the state
   carries the running box and mistuning of § The candidates 2 as its
   score, and the round dedupes states by their coords assignment,
   sorts, and cuts to a width the caller states, as it states the
   stiffness. Returns box and springs per survivor, best first. A width
   of `math.huge` is a full enumeration, which is how the spec
   certifies a beam of twelve at five members. This is the design's one
   hot loop, so nothing per candidate that allocates more than the
   state it keeps.
4. The fallback where no spelling joins the whole sonority: greedy
   components, the box charged only within a component of more than one
   member, springs only inside a component. A bare tritone under a
   5-limit set comes back with no spring and no box, which § Open 2
   holds open as an account of refusal. Red-first in `sonority_spec` on
   that tritone.
