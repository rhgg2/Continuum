# Arrange mini-map — plan

> source: `docs/trackerPage.md`, `docs/trackerRender.md`,
> `docs/arrangePage.md` — the model the phases below compiled into.

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
6. **Phase 6 — Travel and chase** (§ The travel, § The chase) — landed
   2026-08-25 in two commits; the model now lives in
   `docs/trackerPage.md` § The travel, § The chase and
   `docs/trackerRender.md` § The mini-map.

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

- 2026-08-25 tracker: chase the play head across the bound track's slots (§ The chase)
- 2026-08-25 tracker: travel to the instance a map box is clicked on (§ The travel)
- 2026-08-25 tracker: clear the loop when loop to item drops, and Esc drops it (§ The transport driven)
- 2026-08-25 tracker: drive the transport from the arrange map's gutter (§ The transport driven)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

(empty)
