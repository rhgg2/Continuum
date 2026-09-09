# The lane bound — plan

> source: `design/lane-bound.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 0 — the net** (§ Two populations 4, § The lane pass 1) — the
   specs that make the split legal, written against the code as it
   stands and passing before anything moves: an authored note's lane
   bound is unchanged by the fx output on its channel; a note parked
   this pass leaves a preceding on-take tail in its lane where it was;
   and one fixture run through both the frontier and the linear walk
   gives the same frame. The third closes a standing gap — no spec
   crosses `FRONTIER_SEED_CAP` today. — landed 2026-09-10, three
   commits.
2. **Phase 1 — the lane bound is logical** (§ The lane span 3–4, § The
   wire pass 4) — `boundNote` computes its lane bound from `endppqL`,
   the successor's `ppqL` plus `overlap`, `takeLenL` and a logical
   floor, writes `endppqC` with no conversion, and converts once for the
   wire bound. No code moves; the two implementations become the same
   expression. Red-first: on a swung channel a tail clipped by its lane
   successor bounds exactly at the successor's row, which reads 1139.45
   today (§ Open 3).  ← in flight
3. **Phase 2 — one expression** (§ The lane span 4) —
   `frame.clippedSpanEnd` takes the lane population, `boundNote` calls
   it, and `parkedBoundFor` goes: the parked half arrives through
   `frame.authoredEvents` like the other one.
4. **Phase 3 — the lane pass** (§ The lane pass) — the authored lane
   bounds lift out of the walk into a pass at the head over
   `frame.authoredEvents`. `clipNoteHosts` and the stash render read its
   output. The walk keeps the derived notes.
5. **Phase 4 — the cache dissolves** (§ The lane pass 3) — `clipEnd`,
   its dirt guard and `rebuild.forget` go, the lane pass's output
   carrying with the channel frame. `tm_clip_cache_spec` and
   `tm_fx_window_cache_spec` restate against the carry.
6. **Phase 5 — the walk shrinks** (§ Open 4) — the frontier and linear
   walks reassessed now that the walk asks only about pitch.

## Landed  (newest first; prune below ~4)

- 2026-09-10 tm: pin the frontier and linear walks to the same frame (§ The lane pass)
- 2026-09-09 tm: pin a swung tail's lane bound across its successor parking (§ Two populations)
- 2026-09-09 tm: pin the authored lane bound against the pass's fx output (§ Two populations)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

- **tm: the lane bound is logical.** In `boundNote`
  (`trackerRebuild.lua` 1932–1964) every term of `laneBound` is
  logical: the ceiling is `e.endppqL` with no `fromLogical`, the lane
  clip is `laneAnchor.ppqL + (e.overlap or 0)`, the cap is `takeLenL`
  (`makeTailRules` hoists raw `takeLen` at 1911), and the floor is
  `e.ppqL + 1`. `endppqC` is then `laneBound` itself, dropping the
  `toLogical` round-trip that costs the successor's row under swing.
  The wire bound is the pass's one conversion, `max(e.ppq + 1,
  min(fromLogical(laneBound), pitchNext.ppq))`, rounded as now.
  `parkedBounds` keeps only `ppqL` and `parkedBoundFor` seeks on it
  (`rebuildTails` 2281–2294). Derived notes carry `ppqL` and
  `endppqL` and no `colEvt`, so the one expression covers both
  populations; the logical floor also settles § Open 2, `boundNote`
  now flooring where `frame.clippedSpanEnd` does. Red-first in
  `tm_lane_bound_spec`: on a classic-55 channel a tail clipped by a
  lane successor at logical 1140 bounds at 1140, which reads 1139.45
  today; and a note short enough for the floor to bind on that channel
  takes `ppqL + 1` for its lane bound and `ppq + 1` for its wire
  bound. Restate the two-target block at `docs/trackerManager.md`
  921–941 in logical terms. Fallout to expect: fixtures asserting
  tails on swung or delayed channels, and the three spec fixtures
  writing `overlap`, which the model now measures in logical ticks.
