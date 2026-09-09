# The lane bound — plan

> source: `design/lane-bound.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 0 — the net** (docs § Lane occupancy, § The lane pass 1) — the
   specs that make the split legal, written against the code as it
   stands and passing before anything moves: an authored note's lane
   bound is unchanged by the fx output on its channel; a note parked
   this pass leaves a preceding on-take tail in its lane where it was;
   and one fixture run through both the frontier and the linear walk
   gives the same frame. The third closes a standing gap — no spec
   crosses `FRONTIER_SEED_CAP` today. — landed 2026-09-10, three
   commits.
2. **Phase 1 — the lane bound is logical** (docs § Tail walk, § The
   wire pass 4) — `boundNote` computes its lane bound from `endppqL`,
   the successor's `ppqL` plus `overlap`, `takeLenL` and a logical
   floor, writes `endppqC` with no conversion, and converts once for the
   wire bound. No code moves; the two implementations become the same
   expression. — landed 2026-09-10.
3. **Phase 2 — one expression** (docs § Lane occupancy) —
   `frame.clippedSpanEnd` takes the lane population, `boundNote` calls
   it, and `parkedBoundFor` goes: the parked half arrives through
   `frame.authoredEvents` like the other one. — landed 2026-09-09, two
   commits.
4. **Phase 3 — the lane pass** (§ The lane pass) — the authored lane
   bounds lift out of the walk into a pass at the head over
   `frame.authoredEvents`. `clipNoteHosts` and the stash render read its
   output, and the walk keeps the derived notes. `clipEnd`, its dirt
   guard and `rebuild.forget` go with it: the pass is gated on channel
   dirt and its output carries with the channel frame, so
   `tm_clip_cache_spec` and `tm_fx_window_cache_spec` restate against
   the carry.  ← in flight
5. **Phase 4 — the walk shrinks** (§ Open 2) — the frontier and linear
   walks reassessed now that the walk asks only about pitch.

## Landed  (newest first; prune below ~4)

- 2026-09-09 tm: bound an on-take note through the frame's expression (docs § Lane occupancy)
- 2026-09-09 tm: give the lane bound its population (docs § Lane occupancy)
- 2026-09-10 tm: state the lane bound in the logical frame (docs § Tail walk)
- 2026-09-10 tm: pin the frontier and linear walks to the same frame (§ The lane pass)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

- **tm: one pass for the lane bounds.** A new stage between the stash
  render and the window census (`trackerRebuild.lua` 819–828,
  1466–1510) walks each dirty channel's lanes over
  `frame.authoredEvents(chan, lane)`, hoisting `takeLenL` once per
  channel, and gives every event its `endppqC` through
  `frame.clippedSpanEnd` — `frame.setEvent` for a column event, direct
  assign plus the list shed for a parked render event, as `clipParked`
  does at 804–817. `clipParked` goes. `clipNoteHosts` narrows to
  gathering each channel's fx hosts, the `index.fxHosts` seek and the
  `walkChannel` fallback a wholesale-dirty channel needs (1471–1502),
  and reads `evt.endppqC` for the clip `buildFxWindows` takes at 1432.
  `clipEnd`, its per-uuid dirt guard and `rebuild.forget` go (151–169;
  the call site is `trackerManager.lua` 1817), the channel gate
  standing in for them: a channel the pass has not dirtied carries its
  column events and its parked lists, and their bounds ride along (docs
  § Note-lane renewal). Restate `tm_clip_cache_spec` and
  `tm_fx_window_cache_spec` against that carry — a neighbour moving
  into a host's span moves its clip, since the move dirties the
  channel; a clean channel's bounds stand. Hazard: `renderUnion` mints
  a fresh render event for a note the park stage parks this pass
  (940–960), which is after the new stage has run, so establish where
  that event's bound comes from before the next pass's head.

- **tm: the walk takes the lane bound it is given.** `boundNote`
  (`trackerRebuild.lua` 1936–1963) stops computing an authored note's
  lane bound: a seated note reads `e.colEvt.endppqC`, the head pass's
  write, and the derived branch (1941–1944) and the wire conversion
  (1951–1957) stand as they are. The `endppqC` write-through at 1960
  goes with the computation; the `endppq` write at 1961 stays, being
  the authored ceiling the column displays. The restore path is the one
  event the head pass bounded on a table the walk does not read:
  `rebuildRegionPark` re-enters a restored note as a fresh column event
  (940–948) whose provisional raw end the comment there leaves to
  `boundNote`, so the restore carries the bound its parked render event
  was given. Red-first: a note restored this pass draws at its lane
  bound rather than its authored ceiling. Fallout to expect: fixtures
  leaning on the walk to bound a note the head pass did not reach — a
  clean channel, or a note seated after the census.
