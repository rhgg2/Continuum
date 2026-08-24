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
4. **Phase 4 — The transport shown** (§ The transport shown) — the
   play-head line and the loop bracket.  ← next
5. **Phase 5 — The transport driven** (§ The transport driven) — the
   gutter press, Esc, and the loop-to-item reversal.
6. **Phase 6 — Travel and chase** (§ The travel, § The chase) — a click
   on a box travels; the follow toggle has the tracker chase the head.

Notes carried into the phases:

- The raise is written at one site, the `gesture` flag at the tail of
  `tv:resolveCurrentInstance` (`trackerView.lua:290`), which already
  marks "the current instance moved by a gesture" for loop to item. It
  runs outside any command, so the serial it anchors to is settled: the
  dive raises through its `switchPage`, and the slot step, which names
  no instance, raises too.
- The map takes no keyboard focus ever, so the one-pane-one-focus clamp
  (`trackerRender.lua:624`) covers it unchanged.
- `cmgr` has no after-any-command hook — only `doAfter(names, fn)`
  (`commandManager.lua:154`) — so the fall rides a command serial rather
  than a wrap.
- Raise suppression under palette focus was struck: `focusState.acceptCmds`
  (`trackerRender.lua:1832`) already blocks every tracker command while a
  pane holds the keyboard.
- `drawMapBody` (`trackerRender.lua:573`) only draws — the pane runs no
  mouse pass, so phases 5 and 6 add the first one. Its `qnY` and its
  third-column gutter (`:583`, today holding nothing but the grid's
  overrun) are the space phase 4 draws into.
- The three loop calls live on am (`arrangeManager.lua:578-601`) and want
  publishing; `playPositionQN` is already on the facade
  (`arrangePage.lua:69`) and tv already reads it (`trackerView.lua:268`).
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

- 2026-08-25 tracker: raise the arrange map when a gesture moves the instance (§ The raise)
- 2026-08-25 tracker: pin the arrange map as the palette default with Alt-M (§ The pin)
- 2026-08-24 am: a drop opens the whole pool, not a sibling's window (polish over § The walk)
- 2026-08-24 tracker: page the mini-map's window instead of centring it (polish over § The pane)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

- publish `loopRangeQN` on the arrange facade
- draw the play head across the map at its QN
- draw the loop range as a bracket down the map's gutter
