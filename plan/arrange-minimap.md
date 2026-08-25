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
5. **Phase 5 — The transport driven** (§ The transport driven) — landed
   2026-08-25 in two commits; the model now lives in
   `docs/trackerRender.md` § The mini-map and `docs/trackerPage.md`
   § Loop to item.
6. **Phase 6 — Travel and chase** (§ The travel, § The chase) — a click
   on a box travels; the follow toggle has the tracker chase the head.
   ← in flight

Notes carried into the phases:

- The map takes no keyboard focus ever, so the one-pane-one-focus clamp
  (`trackerRender.lua:624`) covers it unchanged, and phase 6's travel
  click inherits that.
- The map's mouse pass lives in `drawMapBody` (`trackerRender.lua:578`),
  which holds the press and reads it against `qnAt`. Phase 6's travel
  click hit-tests the boxes to the right of the margin the transport
  gesture claims.
- The chase needs no scrolling of its own: with the tracker rebinding to
  whatever the head enters, `tv:mapWindow` pages off the new instance for
  free. The page rule changes only for an instance taller than a page,
  whose tail would otherwise run off the foot.

## Landed  (newest first; prune below ~4)

- 2026-08-25 tracker: travel to the instance a map box is clicked on (§ The travel)
- 2026-08-25 tracker: clear the loop when loop to item drops, and Esc drops it (§ The transport driven)
- 2026-08-25 tracker: drive the transport from the arrange map's gutter (§ The transport driven)
- 2026-08-25 tracker: show the transport on the arrange mini-map (§ The transport shown)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

- **The chase** — `trackerFollowPlay`, a global cm key beside
  `trackerLoopToItem`, with `tv:followsPlay`/`tv:setFollowPlay` and a
  toolbar checkbox beside loop to item. On, the entry branch of
  `tv:resolveCurrentInstance` reads whatever placement the head is in on
  the *bound track*, rather than only instances of the bound slot, and
  lands the walk's pair as the travel does. It stays a non-gesture: no
  bracket and no map raise, as entry writes nothing today. Off, entry is
  what it is now; the head in a gap or off the end leaves the tracker
  where it was either way. The entry read needs a facade
  `instanceAt(trackIdx, qn)` over the take enumerator, half-open, in
  `am`, `av` and `arrangePage`. `tv:mapWindow` pages off the play head
  rather than the instance's start while following, so the head stays on
  the page through an instance longer than one; the column still centres
  the bound track. Spec in `tracker_page_spec`: the chase crossing slots
  and holding the track, the toggle off leaving today's behaviour, the
  bracket and the raise staying out, and the window's page off the head.
