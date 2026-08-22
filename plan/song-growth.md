# Song growth — plan

> source: `design/song-growth.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — The current instance** (§ The tracker remembers its instance,
   § Rendered span and source span, § Loop to item) — the tracker remembers
   which instance of the bound slot it is in, written by the dive, by the play
   head entering one, and by a seek on slot change; F6 is its first consumer
   and loop to item its second. — landed 2026-08-22, four commits plus
   the docs transfer.
2. **Phase 2 — What the grid draws** (§ What the grid draws) — the play-row
   caret from `(playQN − instanceStartQN)` over `ppqPerRow`, and the cut line
   where the rendered span ends before the source does.  ← in flight
3. **Phase 3 — again** (§ again) — a pooled instance appended at the current
   instance's rendered end, refused unless the free span covers the natural
   length; one atomic block, rebind, loop follows.
4. **Phase 4 — vary** (§ vary) — the current instance replaced by an instance
   of a fresh variant slot named `<parent> (var N)`; refused on a slot with one
   instance; one atomic block, rebind.

## Landed  (newest first; prune below ~4)

- 2026-08-22 tracker, arrange: loop to item as a pressed verb (§ Loop to item)
- 2026-08-22 tracker: surface loop to item as a toggle command and checkbox (§ Loop to item)
- 2026-08-22 tracker: loop to item brackets the instance a gesture moves to (§ Loop to item)
- 2026-08-22 tracker: remember which instance of the bound slot we are in (§ The tracker remembers its instance)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. **The play row.** `tv:playRow()` gives the row the play head occupies
   inside the current instance: the QN offset `playQN − instance.startQN`,
   converted to logical ppq through the take's resolution and divided by
   `ctx:ppqPerRow()`. It is nil when the transport is stopped, when there
   is no current instance, and when the play head lies outside that
   instance's rendered span. `drawTracker` paints a one-pixel yellow line
   at the top edge of that row, across the full width of the grid pane,
   gutter included, above the row backgrounds. The yellow sits inline at
   a `colour.*` role, as the edit cursor's does. Spec in
   `tests/specs/tracker_page_spec.lua`: the row for a play head part-way
   into the second instance, nil when stopped, nil when the head is in
   another instance.

1. **The cut.** `tv:cutRow()` gives the row where the current instance's
   rendered span ends, when it ends before the source does — the
   rendered `lengthQN` through the same QN → row conversion, nil when
   the row falls at or past `grid.numRows` and nil with no current
   instance. `drawTracker` paints a one-pixel grey dotted line there,
   spanning the grid columns only, so the gutter and the lane strip stay
   clear. Spec: a cut instance's row against a neighbour eight beats
   below a sixteen-beat source, and no row where the neighbour is far
   enough away.
