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
   — landed 2026-08-13, seven commits.
3. **Phase 3 — The diamond** (§ The diamond, § What a target is 4–5,
   § First brick 7) — the odd-limit generator with its prime filter, and
   the temper editor entry that authors one. ← in flight
4. **Phase 4 — The solve on a take** (§ What a target is 1–3,
   § The command's slots, § What the solver takes 8–13) — the token
   factoriser and the eligibility predicate answered from it, strands and
   their shortlists built in `tuning.lua`, the target and harmonic-lock
   slots on the modal, and the chosen candidate seated as
   `(pitch, detune)`.
5. **Phase 5 — Seams** (§ Seams) — the collar as strands of one, and the
   serial sweep across takes in take order.

6. **Phase 6 — The annealer** (§ Solving it 9) — the fallback past the
   stated budget on the state count, which ordinary material does not
   reach.

## Landed  (newest first; prune below ~4)

- 2026-08-13 sonority: the sonority holds every class still sounding (§ The model)
- 2026-08-13 sonority: the pull's scale fixed on the dominant seventh (§ Harmonic lock)
- 2026-08-13 sonority: the exact solve by DP along the onsets (§ Solving it)
- 2026-08-13 sonority: the objective over a placement (§ What "in tune" means)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

- `tuning.genDiamond(oddLimit, primeLimit)`: the double loop over the odd
  numbers up to the odd limit, keeping the coprime pairs and reducing each
  ratio into the octave, returning the generators' usual
  `{ pitches, periodPitch = '2/1', periodAsStep = true }`. The prime limit
  filters in the same pass rather than in a second generator, so the
  5-limit at odd limit 15 is the 15-diamond less every point with a factor
  above 5. The spec pins the point counts — 19 at 9, 29 at 11, 49 at 15, 95
  at 21, and 13 for the 5-limit at 15 — and the tritone hole that last one
  leaves (§ What the solver takes 13).

- The diamond in the temper editor, so no new mechanism authors a target
  (§ What a target is 4): a `GEN_KINDS` entry with odd-limit and prime-limit
  fields (`temperEditor.lua:571`), its `genState` defaults, a
  `drawDiamondFields` in the house pattern of the other five, and a
  `buildGen` branch validating both as whole numbers with the usual inline
  error strings (`temperEditor.lua:706`, `:754`).
