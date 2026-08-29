# keyQueue — plan

> source: `design/keyQueue.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — The queue** — landed 2026-08-29, 1 commit. The model it
   built now sits in `docs/keyQueue.md`.
2. **Phase 2 — The dispatcher** (§ Claiming) — `keyDispatch` takes from
   the queue for prefix capture, the letter sink and the keychain walk.
   `consumed` and the claim half of `commandHeld` go; `held` serves the
   chord half.  ← in flight
3. **Phase 3 — Note entry** (§ Claiming, § Order) — `gridPane`'s edit-key
   scan takes what it enters, and the `commandHeld` line patching the
   menu's letter fall-through comes out.
4. **Phase 4 — Ownership** (§ Ownership) — the cheat sheet, modal, picker
   and status edit own the queue; `suppressKbd`, `pickerIsActive` and
   `statusEditActive` stop being read as gates, the five
   `wasOpenAtFrameStart` guards go, and the direct readers those guards
   never covered come under the same rule.
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

- 2026-08-29 keyDispatch: prefix and letter capture take from the keyQueue (phase 2)
- 2026-08-29 keyQueue: read the frame's key presses into a claimable queue (phase 1)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

- **The keychain walk takes, and `consumed` goes.** The walk takes the
  press that selects a command before it invokes, so a command raising
  a modal or a picker hands it a queue the press has left; a command
  returning false hands the entry back with `keyQueue:restore(entry)`,
  which returns it to the head. `keyQueue:held` builds the chord half
  of `commandHeld`, which stays the whole of the return. The mini
  pattern editor's Esc/Enter fallback takes those keys instead of
  gating on `consumed`; its `swallowInput` and `pendingAction` wait for
  phase 5.

