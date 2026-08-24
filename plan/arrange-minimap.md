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

- The gestures phase 3 raises the map for are `duplicateBelow`,
  `stepVariant`, `stepInstance` and the dive — the verbs that write
  `tv:nameInstance` (`trackerView.lua:253`).
- The tab machinery is two-valued in its fallback: `tv:paletteTab`
  (`trackerView.lua:3921`) falls back fx-else-parameters. The map takes
  no keyboard focus ever, so the one-pane-one-focus clamp
  (`trackerRender.lua:624`) covers it unchanged; only the fallback needs
  widening, and that waits for phase 3's raise.
- `cmgr` has no after-any-command hook — only `doAfter(names, fn)`
  (`commandManager.lua:154`). Phase 3 needs a fall trigger; the existing
  lapse is anchored to a caret key.
- Design § Open is unresolved: raise suppression while a pane holds keys
  (phase 3), clicking the map to travel and the play head (neither
  phase).

## Landed  (newest first; prune below ~4)

- 2026-08-24 tracker/arrange: land a track step on the nearest placement; delete the instance (polish over § The walk)
- 2026-08-24 tracker: walk the track's instances with Alt-up/down (§ The walk)
- 2026-08-24 tracker: draw the arrange mini-map (§ The pane)
- 2026-08-24 tracker: a third palette tab for the mini-map (§ The pane)
- 2026-08-24 arrange: publish the take enumerator on the facade (§ What the tracker may see)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

(empty)
