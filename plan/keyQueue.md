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
5. **Phase 5 — The raising readers** (§ Claiming) — the modal renderers,
   the fx strip and the param palette take rather than poll. With the
   press claimed before what it raises can read, the five `appearing`
   guards, `swallowInput`, `periodSwallow`, `releaseReq` and
   `stripExitReq` come out with them, and the two carried modal gates
   with them.  ← in flight
6. **Phase 6 — The rest, and the record** — the remaining direct readers
   on the sampler, wiring, arrange and editor pages, the mouse-gesture
   modifier reads moved onto `held`, and the model moved into
   `docs/keyQueue.md` with the drain order written down.

## Landed  (newest first; prune below ~4)

- 2026-08-29 patternEditor: drop the input swallow and the picker gate (design/keyQueue.md § Claiming)
- 2026-08-29 tracker: the fx strip claims its keys from the keyQueue (design/keyQueue.md § Claiming)
- 2026-08-29 modalHost: every modal claims commit and cancel through the host (design/keyQueue.md § Claiming)
- 2026-08-29 arrange: the modal renderers claim their keys from the keyQueue (design/keyQueue.md § Claiming)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)
- **The parameter palette takes** — `handlePaletteKeys` claims Tab,
  Escape, the two Super chords and the navigation keys; `releaseReq`
  goes, since a claimed Escape cannot reach the dispatcher later in the
  frame.

