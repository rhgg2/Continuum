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
   the carry. — landed 2026-09-10, two commits.
5. **Phase 4 — the walk shrinks** (§ The wire pass 3, § Open 4) — the
   derived lane bound comes off `frame.clippedSpanEnd` over the
   population it belongs to, and the lane pass names the bounds it
   moved, so the walk asks only about pitch and raw. The two walks stay
   as they are: the frontier's per-anchor cost halves, and past the cap
   one channel pass still beats a few hundred probes.  ← in flight

## Landed  (newest first; prune below ~4)

- 2026-09-10 tm: bound a derived note through the frame's expression (docs § Tail walk)
- 2026-09-10 tm: the walk takes the lane bound it is given (docs § The lane pass)
- 2026-09-10 tm: bound every lane in one pass (docs § The lane pass)
- 2026-09-09 tm: bound an on-take note through the frame's expression (docs § Lane occupancy)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

- **The walk asks only about pitch.** `boundLanes` (784–804) names the
  authored events whose `endppqC` it moved, over the head pass and the
  park stage's re-run alike, and `rebuildTails` seeds `bound` with them.
  Both walks then drop their same-lane machinery: the linear walk's
  `lastInLane` anchor sweep and the `nearestInLane`/`nextAfterLane`
  state of its backward pass (2019–2047), and the frontier's two lane
  `nearestNote` probes (2224, 2234). The lane question that remains is
  over the pass's derived output alone, which is the small `extras`
  list, so a kept tile whose lane successor moved still re-binds.
  `tm_walk_parity_spec`'s fixture already turns on a note that no seed
  names re-binding; the new spec pins the route directly. Spec: an
  authored note whose lane bound moved under a neighbour's edit takes
  its new wire bound in mm, on both routes. `decisions.md` records the
  walks staying two, retiring § Open 5.

