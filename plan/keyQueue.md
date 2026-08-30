# keyQueue — plan

> source: `design/keyQueue.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — The queue** — landed 2026-08-29, 1 commit. The model it
   built now sits in `docs/keyQueue.md`.
2. **Phase 2 — The dispatcher** (§ Claiming) — landed 2026-08-29, 2
   commits. The claim discipline it built now sits in `docs/keyQueue.md`
   § Claiming.
3. **Phase 3 — Note entry** (§ Claiming, § Order) — landed 2026-08-29, 1
   commit. The scan's claims and its decline path now sit in
   `docs/trackerPage.md` § Keys.
4. **Phase 4 — Ownership** (§ Ownership) — landed 2026-08-29, 4 commits.
   The rule it built now sits in `docs/keyQueue.md` § Ownership. Mouse
   readers keep their own guards, so the three cheat-sheet ones stay;
   the two modal gates on `focusState` pass to phase 5, where the
   renderers that make them redundant land.
5. **Phase 5 — The raising readers** (§ Claiming) — landed 2026-08-30,
   5 commits. The modal renderers, the fx strip and the param palette
   take rather than poll, and the `appearing` guards, `swallowInput`,
   `periodSwallow`, `releaseReq` and the two carried modal gates came
   out with them. `stripExitReq` stayed: the strip's mid-draw mouse
   exits fire while the rest of the draw still reads the focus.
6. **Phase 6 — The rest, and the record** ← in flight — the remaining
   direct readers on the sampler, wiring, arrange and editor pages, the
   mouse-gesture modifier reads moved onto `held`, and the model moved
   into `docs/keyQueue.md` with the drain order written down.

## Landed  (newest first; prune below ~4)

- 2026-08-30 editor, sampler: the page Escapes claim from the keyQueue (design/keyQueue.md § Claiming)
- 2026-08-30 tracker: the palette pane owns the key queue (design/keyQueue.md § Claiming, § Ownership)
- 2026-08-29 patternEditor: drop the input swallow and the picker gate (design/keyQueue.md § Claiming)
- 2026-08-29 tracker: the fx strip claims its keys from the keyQueue (design/keyQueue.md § Claiming)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

- **wiring: the fx popup owns the queue.** The wiring page answers
  `keyboardOwner` with `picker` while `popups.fx` is up, and the
  popup's Enter, keypad Enter, Up, Down and Escape claim under that
  name. The name now covers any picker popup, and `docs/keyQueue.md` §
  Ownership says so. `wr:focusState` drops its `popups.fx` clause. The
  popup's arrow navigation is dead today — the fill's live-field claim
  takes the arrows on an unowned frame — and ownership restores it.

- **wiring: the gesture cancel claims.** The draft-cancelling Escape in
  `wiringRender.renderBody` claims, so the Esc-bound
  `wiringClearSelection` no longer runs on the same press by accident.

- **the mouse gestures read modifiers through the queue.** Six
  `GetKeyMods` sites move to `keyQueue:mods()`: gridPane's region paint
  and shift-extend, the tracker mini-map's snap, arrange's snap and its
  click modifiers, wiring's shift-clear and curveEditor's free-drag.
  `curveEditor` and `gridPane` need `keyQueue` threaded to them.

- **the record.** `docs/keyQueue.md` gains § Order — the drain order as
  a property of the call graph — and the distinction between a guard
  deciding whether a reader is asked and a claim removing a press.
  `design/keyQueue.md` collapses to pointers, less its Open item on
  `pageSuppressed`.

