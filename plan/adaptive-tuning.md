# Adaptive tuning — plan

> source: `design/adaptive-tuning.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — Snap** (§ First brick 1, § When an adaptive solve exists 5,
   § Strength) — the modal with its scope and strength fields, the
   two-sided window, and every note to its own step through `edit.assign`
   with no solver behind it.  — landed 2026-08-12, five commits.
2. **Phase 2 — The objective** (§ What "in tune" means, § The model,
   § The strand, § What the solver takes, § Solving it, § Harmonic lock)
   — the pure solver module: coords and box score, the sonority walk, the
   DP over strands, and the pull's scale fixed by the dominant-seventh spec.
   ← in flight
3. **Phase 3 — The diamond** (§ The diamond, § What a target is,
   § First brick 7) — the odd-limit generator and its prime filter, and
   the eligibility predicate over a temper's tokens.
4. **Phase 4 — The solve on a take** (§ The command's slots,
   § What the solver takes 8–13) — strands and their shortlists built in
   `tuning.lua`, the target and harmonic-lock slots on the modal, and the
   chosen candidate seated as `(pitch, detune)`.
5. **Phase 5 — Seams** (§ Seams) — the collar as strands of one, and the
   serial sweep across takes in take order.

6. **Phase 6 — The annealer** (§ Solving it 9) — the fallback past the
   stated budget on the state count, which ordinary material does not
   reach.

## Landed  (newest first; prune below ~4)

- 2026-08-13 sonority: the objective over a placement (§ What "in tune" means)
- 2026-08-13 sonority: the walk over strands, one sonority per onset (§ The model)
- 2026-08-13 sonority: the box score over a set of coords (§ What "in tune" means)
- 2026-08-12 tv: undo labels on the verb, not the command (adjacent to § Where it sits)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. **The DP.** `sonority.solve` returns the index per strand minimising
   that cost, by dynamic programming along the onsets (§ Solving it).
   The state carries the chosen candidate of the `n−1` most recently
   distinct step-classes, together with any strand whose strikes are not
   yet spent. An empty shortlist is asserted against, and a state count
   past the stated budget raises (§ What the solver takes). The spec
   pins agreement with exhaustive enumeration on small inputs, that a
   shortlist of one is fixed and still contributes its coords, and that
   holding the ii's D through the V costs the V 0.118 of box
   (§ The strand).

2. **The dominant seventh.** A spec fixes the pull's scale on a
   hand-worked C7 sounding alone (§ First brick). Its shortlists
   are ratio lists written into the spec, so no target mechanism is
   needed to run it. Below a pull of 0.95 the chord takes the otonal
   `4:5:6:7` and above it the Pythagorean `16/9`, trading 0.36 of box
   against 27¢ of fidelity (§ Harmonic lock). Resolving it to F–A–C
   takes the Pythagorean under any pull (§ The model), so the
   calibration chord stands alone.

3. **The walk over what sounds.** `sonority.walk` reads the notes'
   releases and takes everything sounding at an onset together with the
   last `n−1` distinct classes struck before it (§ Open). The extra
   state is bounded by the polyphony rather than by `n`. The item
   carries the measurement that decides it: the state count, and the
   answers moved against the struck-only walk on the same material.
