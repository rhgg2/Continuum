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

(nothing yet)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. Snap the scope onto the notation: `snapToTemperScope(groups)` in
   `trackerView.lua` beside `quantizeScope`, running every note in the scope
   through `tuning.snap` and writing the pair back with `edit.assign`, then
   `tm:flush()`. A note already on its step is not written, and non-note
   events are passed over. `tv:snapToTemperSelection` and
   `tv:snapToTemperAll` take `eventsByCol()` and `allGroups()`; nothing
   reaches them yet, the command that does arriving with the modal below.
   Spec `vm_snap_temper_spec` against the two verbs — an
   off-step note lands on its step's `(pitch, detune)`, a note past the
   half-way point lands on its neighbour, an on-step note is left alone,
   and a selection confines the edit. `docs/trackerView.md` gains the pair
   beside the quantize verbs.

2. The retune modal, opened by Ctrl+T: `modalHost:registerKind('retune',
   …)` in `trackerRender.lua` beside `takeProps`, carrying one field for
   now — scope, as a Selection · Whole take radio opening on Selection
   where there is one — with OK and Cancel. OK calls whichever of the two
   verbs the radio names, and the command registers through `registerAll`'s
   tuple form so either scope is one undo block. This is the modal every
   retuning facility will be reached through (§ Where it sits), so
   `scopedAction` is not in the path: the scope is a field, and OK replaces
   the whole-take confirm. Bound in `pageBindings.tracker`.

3. The strength field beside the scope (§ Strength) — a 0–1 slider opening
   at full strength every time, passed to both verbs, interpolating each
   note from the detune it carries toward the snapped one. Below 1 the note
   is left off its step, so the blended cents are re-seated on the nearest
   semitone rather than kept against the snapped pitch, which plain snap
   never needs because `stepToMidi` seats the pair itself. Spec in
   `vm_snap_temper_spec`: a note 40¢ off its step lands 20¢ off at 0.5, and
   10¢ off when the same command runs again — the broken idempotence, pinned
   as intended rather than tolerated.

4. The window as both half-gaps: `ctx:noteProjection` returns the distance
   to the step below and the step above in place of the smaller of the two
   (`viewContext.lua:39-42`), which is the two-sided window of § The
   window. Its one consumer, the deviation tick in `gridPane.lua:793-796`,
   then normalises by the side the note moved, so a note 38¢ below C in a
   twelve-note quarter-comma meantone stops painting as though it sat at
   the edge of a window that reaches 58.6¢ on that side. Spec in
   `view_context_spec`: both halves at 50¢ under 12EDO, restating the
   existing case, and +38.0¢ / −58.6¢ under the meantone MOS.
