# Arrange mini-map — plan

> source: `design/arrange-minimap.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — The pane** (§ What the tracker may see, § The pane,
   § The mark) — the facade enumerator, a third palette tab, and the map
   drawn from take shapes with the current instance marked.  ← in flight
2. **Phase 2 — The walk** (§ The walk, § Landing) — Alt-Tab and
   Alt-Shift-Tab along the track's instances, landing through
   `nameInstance` / `selectSlot`.
3. **Phase 3 — Raise and pin** (§ The raise, § The pin) — Alt-M pins the
   map; instance-moving gestures raise it for one command.

Notes carried into the phases:

- `av:visibleTakes(fromCol, toCol, qnLo, qnHi)` (`arrangeView.lua:652`)
  already answers the enumerator; only the facade table
  (`arrangePage.lua:41`) lacks it.
- The tab machinery is two-valued throughout: `tv:paletteTab` falls back
  fx-else-parameters (`trackerView.lua:3897`), and `docs/trackerRender.md`
  § Palette tabs is written in the two-tab register. The map takes no
  keyboard focus ever, so the one-pane-one-focus clamp
  (`trackerRender.lua:575`) covers it unchanged; only the fallback needs
  widening, and that waits for phase 3's raise.
- Nothing under `tests/` touches the tab machinery today, and no spec
  instantiates `trackerRender` to draw. Geometry goes red-first by
  computing the window on `tv`, where a spec can reach it.
- The window rule, settled 2026-08-24: a fixed map column width and a
  fixed pixels-per-QN (40px and 6px/QN — five columns in the 200px
  pane), the bound track's column centred and clamped at both ends (so a
  track list shorter than the pane's columns left-aligns), time centred
  on the marked instance's midpoint, pulled down to its start when the
  instance outgrows the window and clamped at QN 0, else centred on the
  edit cursor QN. No scroll interaction. The renderer owns the two pixel
  constants and asks `tv` for a window in columns and QN, as `gridPane`
  does with `tv:setGridSize`.
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
