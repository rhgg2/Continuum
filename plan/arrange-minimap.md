# Arrange mini-map — plan

> source: `design/arrange-minimap.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — The pane** (§ What the tracker may see, § The pane,
   § The mark) — landed 2026-08-24 in three commits; the model now lives
   in `docs/trackerRender.md` § The mini-map and `docs/arrangePage.md`
   § The take enumerator.
2. **Phase 2 — The walk** (§ The walk, § Landing) — landed 2026-08-24;
   the model now lives in `docs/trackerPage.md` § The walk.
3. **Phase 3 — Raise and pin** (§ The raise, § The pin) — Alt-M pins the
   map; instance-moving gestures raise it for one command.  ← in flight

Notes carried into the phases:

- The raise is written at one site, `tv:nameInstance`
  (`trackerView.lua:253`), so every gesture that names an instance
  raises the map — the dive included, through the tracker facade.
- The map takes no keyboard focus ever, so the one-pane-one-focus clamp
  (`trackerRender.lua:624`) covers it unchanged.
- `cmgr` has no after-any-command hook — only `doAfter(names, fn)`
  (`commandManager.lua:154`) — so the fall rides a command serial rather
  than a wrap.
- Design § Open is unresolved on clicking the map to travel and on the
  play head; neither belongs to a phase. Raise suppression under palette
  focus was struck: `focusState.acceptCmds` (`trackerRender.lua:1832`)
  already blocks every tracker command while a pane holds the keyboard.

## Landed  (newest first; prune below ~4)

- 2026-08-25 tracker: pin the arrange map as the palette default with Alt-M (§ The pin)
- 2026-08-24 am: a drop opens the whole pool, not a sibling's window (polish over § The walk)
- 2026-08-24 tracker: page the mini-map's window instead of centring it (polish over § The pane)
- 2026-08-24 tracker/arrange: land a track step on the nearest placement; delete the instance (polish over § The walk)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. **The raise** — `cmgr` gains a monotonic command serial, and the tab
   override carries a serial anchor as well as its caret one, lapsing
   when either moves. `tv:nameInstance` raises the map by writing an
   override anchored to the serial, so a gesture that names an instance
   shows the map until the next command, and the most recent of a raise
   and a click wins. (design § The raise)
