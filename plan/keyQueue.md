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

- 2026-08-30 keyQueue: document the drain order and the guards (design/keyQueue.md § Order, § What guards, and what claims)
- 2026-08-30 keyQueue: the mouse gestures read modifiers through the queue (design/keyQueue.md § Hold and repeat)
- 2026-08-30 wiring: the gesture cancel claims its Escape (design/keyQueue.md § Claiming)
- 2026-08-30 wiring: the fx picker owns the key queue (design/keyQueue.md § Claiming, § Ownership)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

(empty)

