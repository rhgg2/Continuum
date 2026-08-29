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
4. **Phase 4 — Ownership** (§ Ownership) — the cheat sheet, modal, picker
   and status edit own the queue; `suppressKbd`, `pickerIsActive` and
   `statusEditActive` stop being read as gates, the five
   `wasOpenAtFrameStart` guards go, and the direct readers those guards
   never covered come under the same rule.  ← next
5. **Phase 5 — The raising readers** (§ Claiming) — the modal renderers,
   the fx strip and the param palette take rather than poll. With the
   press claimed before what it raises can read, the five `appearing`
   guards, `swallowInput`, `periodSwallow`, `releaseReq` and
   `stripExitReq` come out with them.
6. **Phase 6 — The rest, and the record** — the remaining direct readers
   on the sampler, wiring, arrange and editor pages, the mouse-gesture
   modifier reads moved onto `held`, and the model moved into
   `docs/keyQueue.md` with the drain order written down.

## Landed  (newest first; prune below ~4)

- 2026-08-29 gridPane: note entry takes its presses from the keyQueue (design/keyQueue.md § Claiming)
- 2026-08-29 keyDispatch: the walk takes its press, and consumed goes (design/keyQueue.md § Claiming)
- 2026-08-29 keyDispatch: prefix and letter capture take from the keyQueue (phase 2)
- 2026-08-29 keyQueue: read the frame's key presses into a claimable queue (phase 1)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

(empty — phase 3 is done; run /plan-next to refill from phase 4.)

