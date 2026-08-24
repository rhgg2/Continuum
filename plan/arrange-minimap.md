# Arrange mini-map — plan

> source: `design/arrange-minimap.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — The pane** (§ What the tracker may see, § The pane,
   § The mark) — landed 2026-08-24 in three commits; the model now lives
   in `docs/trackerRender.md` § The mini-map and `docs/arrangePage.md`
   § The take enumerator.
2. **Phase 2 — The walk** (§ The walk, § Landing) — Alt-↓ and Alt-↑
   along the track's instances, landing through
   `nameInstance` / `selectSlot`.  ← in flight
3. **Phase 3 — Raise and pin** (§ The raise, § The pin) — Alt-M pins the
   map; instance-moving gestures raise it for one command.

Notes carried into the phases:

- The walk's keys changed from Alt-Tab to Alt-↑/↓ (2026-08-24), and
  `prevTake` / `nextTake` move to Alt-comma and Alt-period — a change
  already sitting uncommitted at `pageBindings.lua:27`.
- `tv:stepVariant` (`trackerView.lua:375`) is the landing model: refuse
  in silence with no current instance, then `selectSlot` for the slot
  stepped onto and `nameInstance` for its placement.
- The spec's fake arrange returns `visibleTakes` in seeding order
  (`tests/specs/tracker_page_spec.lua:114`), so a walk that sorts by
  start can be pinned by seeding out of order.
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

- 2026-08-24 tracker: draw the arrange mini-map (§ The pane)
- 2026-08-24 tracker: a third palette tab for the mini-map (§ The pane)
- 2026-08-24 arrange: publish the take enumerator on the facade (§ What the tracker may see)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. **Walk the track's instances** — `tv:walkInstance(dir)` steps the
   current instance to the previous or next placement on its own track,
   over `arrange().visibleTakes(col, col, 0, huge)` sorted by start. It
   holds at the ends, crosses to no other track, and refuses in silence
   where the tracker is in no instance. Landing follows `tv:stepVariant`:
   `tv:nameInstance(take)` always, `tv:selectSlot(slotIdx)` where the
   stop belongs to another slot, and `ec:setPos(0, 0)` on that crossing
   alone. Commands `prevInstance` / `nextInstance` in trackerRender's
   registry on Alt-↑ / Alt-↓, with `prevTake` / `nextTake` on Alt-comma
   and Alt-period. Docs: a § The walk section in `docs/trackerPage.md`
   beside § Stepping the family. Red-first in
   `tests/specs/tracker_page_spec.lua`, whose fake arrange already seeds
   instances across slots.
