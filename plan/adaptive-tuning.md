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

- 2026-08-13 sonority: the box score over a set of coords (§ What "in tune" means)
- 2026-08-12 tv: undo labels on the verb, not the command (adjacent to § Where it sits)
- 2026-08-12 tuning: split noteProjection into label and two-sided deviation (§ The window)
- 2026-08-12 tv: strength dial on the retune modal (§ Strength)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. **The sonority walk.** `sonority.walk` takes the strands and `n`, and
   returns for each onset the last `n` distinct step-classes struck at
   or before it (§ The model). Distinctness is by class, so a repeated
   note and an octave doubling each spend one entry. The spec pins that
   a block chord and an arpeggio of it hand back the same set, and that
   at `n` one above the arity consecutive sonorities still overlap.

2. **The objective over a placement.** `sonority.cost` takes the
   strands, `n`, the pull strength and one candidate index per strand,
   and returns the box summed over the walk's sonorities plus
   `strength × strain²` per strand (§ Harmonic lock). The pull is
   counted once per strand, so an octave doubling changes no answer.
   This scorer is what the next item's spec measures the DP against.

3. **The DP.** `sonority.solve` returns the index per strand minimising
   that cost, by dynamic programming along the onsets (§ Solving it).
   The state carries the chosen candidate of the `n−1` most recently
   distinct step-classes, together with any strand whose strikes are not
   yet spent. An empty shortlist is asserted against, and a state count
   past the stated budget raises (§ What the solver takes). The spec
   pins agreement with exhaustive enumeration on small inputs, that a
   shortlist of one is fixed and still contributes its coords, and that
   holding the ii's D through the V costs the V 0.118 of box
   (§ The strand).

4. **The dominant seventh.** A spec fixes the pull's scale on a
   hand-worked C7 resolving to its tonic (§ First brick). Its shortlists
   are ratio lists written into the spec, so no target mechanism is
   needed to run it. Below a pull of 0.97 the chord takes the otonal
   `4:5:6:7` and above it the Pythagorean `16/9`, trading 0.36 of box
   against 27¢ of fidelity (§ Harmonic lock).
