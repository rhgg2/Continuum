# keyQueue — plan

> source: `design/keyQueue.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — The queue** — landed 2026-08-29, 1 commit. The model it
   built now sits in `docs/keyQueue.md`.
2. **Phase 2 — The dispatcher** (§ Claiming) — landed 2026-08-29, 2
   commits. The claim discipline it built now sits in `docs/keyQueue.md`
   § Claiming.
3. **Phase 3 — Note entry** (§ Claiming, § Order) — `gridPane`'s edit-key
   scan takes what it enters, and the `commandHeld` line patching the
   menu's letter fall-through comes out.  ← in flight
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

- 2026-08-29 keyDispatch: the walk takes its press, and consumed goes (design/keyQueue.md § Claiming)
- 2026-08-29 keyDispatch: prefix and letter capture take from the keyQueue (phase 2)
- 2026-08-29 keyQueue: read the frame's key presses into a claimable queue (phase 1)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

- **Note entry takes what it enters** — `gridPane:handleKeys` reads its
  presses from the queue instead of `IsKeyPressed`: the `editKeys` scan,
  the Backspace that steps a chord or value gesture back, and the
  modifier state it tests. An entry marked `repeated` is restored unless
  its key is `lastEditKey`, keeping the rule that only the last key
  typed autorepeats. The `commandHeld` gate goes, and with it the
  parameter, the table `keyDispatch` builds and the line reporting a
  captured letter into it; the `letterCapture` guard stays, since the
  menu's walk owns the keyboard whether or not it took this frame's
  press. Both hosts hand `gridPane` the queue — the tracker page through
  `trackerRender`, the mini editor in `patternEditor` claiming as
  `modal`. Specs: note entry over a fake queue, which nothing covers
  today; `keyDispatch`'s hold cases go. Docs: `trackerPage.md` § Keys.

