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
   the temper editor entry that authors one. — landed 2026-08-14, two
   commits.
4. **Phase 4 — The solve on a take** (§ What a target is 1–3, 7–10,
   § The command's slots, § What the solver takes 8–14) — the token
   factoriser and the eligibility predicate answered from it, shortlists
   in `tuning.lua` and strands assembled by the command, the target, key,
   sonority-size and harmonic-lock slots on the modal, and the chosen
   candidate seated as `(pitch, detune)`. — landed 2026-08-14, six
   commits.
5. **Phase 5 — Seams** (§ Seams) — the collar as strands of one, and the
   serial sweep across takes in take order.  ← in flight
6. **Phase 6 — The annealer** (§ Solving it 9) — the fallback past the
   stated budget on the state count, which ordinary material does not
   reach.

## Landed  (newest first; prune below ~4)

- 2026-08-14 tuning: offer to widen the window of a class with nowhere to go (§ What the solver takes)
- 2026-08-14 tuning: solve the scope against the target and seat each strand (§ What the solver takes)
- 2026-08-14 tuning: give the retune modal its target, key, size and lock (§ The command's slots)
- 2026-08-14 tuning: group notes into strands by step-class and overlap (§ The strand)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

(empty)
