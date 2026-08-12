# Adaptive tuning — plan

> source: `design/adaptive-tuning.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — Snap** (§ First brick 1, § When an adaptive solve exists 5,
   § Strength) — the modal with its scope and strength fields, the
   two-sided window, and every note to its own step through `edit.assign`
   with no solver behind it.  ← in flight
2. **Phase 2 — The objective** (§ What "in tune" means, § The model,
   § The strand, § What the solver takes, § Solving it, § Harmonic lock)
   — the pure solver module: coords and box score, the sonority walk, the
   DP over strands, and the pull's scale fixed by the dominant-seventh spec.
3. **Phase 3 — The diamond** (§ The diamond, § What a target is,
   § First brick 7) — the odd-limit generator and its prime filter, and
   the eligibility predicate over a temper's tokens.
4. **Phase 4 — The solve on a take** (§ The command's slots,
   § What the solver takes 8–13) — strands and their shortlists built in
   `tuning.lua`, the target and harmonic-lock slots on the modal, and the
   chosen candidate seated as `(pitch, detune)`.
5. **Phase 5 — Seams** (§ Seams) — the collar as strands of one, and the
   serial sweep across takes in take order.

## Landed  (newest first; prune below ~4)

- 2026-08-12 tv: strength dial on the retune modal (§ Strength)
- 2026-08-12 tracker: the retune modal on Ctrl+T (§ Where it sits)
- 2026-08-12 Snap the scope onto the notation (§ First brick 1)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. The window as both half-gaps: `ctx:noteProjection` returns the distance
   to the step below and the step above in place of the smaller of the two
   (`viewContext.lua:39-42`), which is the two-sided window of § The
   window. Its one consumer, the deviation tick in `gridPane.lua:793-796`,
   then normalises by the side the note moved, so a note 38¢ below C in a
   twelve-note quarter-comma meantone stops painting as though it sat at
   the edge of a window that reaches 58.6¢ on that side. Spec in
   `view_context_spec`: both halves at 50¢ under 12EDO, restating the
   existing case, and +38.0¢ / −58.6¢ under the meantone MOS.

2. The quantize undo label, which today wraps nothing on the whole-take path
   — adjacent to this phase rather than of it, found while compiling item 1.
   `quantize` and `quantizeKeepRealised` register with `registerAll`'s tuple
   form (`trackerRender.lua:1450-1451`), so the atomic block wraps
   `scopedAction`, which only opens a confirm; the edit lands frames later in
   its callback, outside the block. Move the label onto the two `tv:quantize*`
   verbs, so both scopes carry it, and drop the tuple.
