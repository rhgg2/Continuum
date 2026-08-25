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
3. **Phase 3 — Raise and pin** (§ The raise, § The pin) — landed
   2026-08-25; the model now lives in `docs/trackerRender.md` § Palette
   tabs and `docs/trackerPage.md` § The current instance.
4. **Phase 4 — The transport shown** (§ The transport shown) — landed
   2026-08-25 in one commit; the model now lives in
   `docs/trackerRender.md` § The mini-map.
5. **Phase 5 — The transport driven** (§ The transport driven) — the
   gutter press, Esc, and the loop-to-item reversal.  ← in flight
6. **Phase 6 — Travel and chase** (§ The travel, § The chase) — a click
   on a box travels; the follow toggle has the tracker chase the head.

Notes carried into the phases:

- The map takes no keyboard focus ever, so the one-pane-one-focus clamp
  (`trackerRender.lua:624`) covers it unchanged, and phase 6's travel
  click inherits that.
- `drawMapBody` (`trackerRender.lua:573`) only draws — the pane runs no
  mouse pass, so phases 5 and 6 add the first one. Its `qnY` and the
  half-column left margin it lays out (`:580-588`) are what a press
  reads against.
- `loopRangeQN` and `playPositionQN` are on the facade already
  (`arrangePage.lua:69-70`); `setLoopRangeQN` and `clearLoopRange`
  (`arrangeManager.lua:584,599`) want publishing. The clean release
  needs `setEditCursorQN` published too — a fourth call the design's
  count of three misses.
- Arrange holds the gutter-press model whole — `arrangeRender.lua:255-312`
  under the invariant at `:43`, the loop bracket at `:542-558`. But
  `av:gutterLoopCand` snaps to `beatPerRow`, an arrange-view notion the
  map has no equivalent of, so phase 5 needs its own cell snap.
- Esc is free in the tracker scope; region, wiring and arrange each bind
  it within their own (`pageBindings.lua:121,142,190`).
- Phase 5's reversal rewrites `docs/trackerPage.md` § Loop to item, which
  says today that turning the toggle off leaves the loop where it stands.
  No spec pins that. `tracker_page_spec.lua:1298` pins play-head entry
  leaving the loop alone, which the reversal doesn't touch.
- The chase needs no scrolling of its own: with the tracker rebinding to
  whatever the head enters, `tv:mapWindow` pages off the new instance for
  free. The page rule changes only for an instance taller than a page,
  whose tail would otherwise run off the foot.

## Landed  (newest first; prune below ~4)

- 2026-08-25 tracker: drive the transport from the arrange map's gutter (§ The transport driven)
- 2026-08-25 tracker: show the transport on the arrange mini-map (§ The transport shown)
- 2026-08-25 tracker: raise the arrange map when a gesture moves the instance (§ The raise)
- 2026-08-25 tracker: pin the arrange map as the palette default with Alt-M (§ The pin)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)
- **Esc drops the loop** — a `clearLoop` command on Esc in the tracker
  scope clears the project loop and turns loop to item off with it; and
  `tv:setLoopToItem(false)` clears the loop however the toggle is
  dropped, reversing today's rule that it leaves the loop standing. The
  facade gains `clearLoopRange`. Rewrites `docs/trackerPage.md` § Loop
  to item. Spec in `tracker_page_spec`: the toggle off clears, Esc
  clears both, and play-head entry still leaves the loop alone
  (`:1298`).
