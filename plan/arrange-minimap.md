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
  fixed pixels-per-QN, the bound track's column centred and clamped at
  both ends (so a track list shorter than the pane's columns
  left-aligns), time centred on the marked instance, else on the edit
  cursor QN. No scroll interaction.
- `cmgr` has no after-any-command hook — only `doAfter(names, fn)`
  (`commandManager.lua:154`). Phase 3 needs a fall trigger; the existing
  lapse is anchored to a caret key.
- Design § Open is unresolved: raise suppression while a pane holds keys
  (phase 3), clicking the map to travel and the play head (neither
  phase).

## Landed  (newest first; prune below ~4)

- 2026-08-24 arrange: publish the take enumerator on the facade (§ What the tracker may see)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)
- tracker: a third palette tab — `PALETTE_TABS` (`trackerRender.lua:540`)
  gains the map, with a stub body. The derivation is untouched, so the
  map is reachable only by a tab click, and it never holds focus.
  `docs/trackerRender.md` § Palette tabs corrected to three tabs, its
  two-toggle account left standing. Spec pins that `tv:overrideTab`
  holds the map and lapses it on a caret move.
- tracker: draw the map — the window computed on `tv` from the current
  instance and the track list, the renderer only painting it: one filled
  box per instance in its slot's colour, the current instance in the
  focused fill, nothing else. Spec pins the window's centring, both
  clamps and its QN-to-y.
