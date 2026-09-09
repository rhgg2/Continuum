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
   expression. — landed 2026-09-10.
3. **Phase 2 — one expression** (§ The lane span 4) —
   `frame.clippedSpanEnd` takes the lane population, `boundNote` calls
   it, and `parkedBoundFor` goes: the parked half arrives through
   `frame.authoredEvents` like the other one.  ← in flight
4. **Phase 3 — the lane pass** (§ The lane pass) — the authored lane
   bounds lift out of the walk into a pass at the head over
   `frame.authoredEvents`. `clipNoteHosts` and the stash render read its
   output. The walk keeps the derived notes.
5. **Phase 4 — the cache dissolves** (§ The lane pass 3) — `clipEnd`,
   its dirt guard and `rebuild.forget` go, the lane pass's output
   carrying with the channel frame. `tm_clip_cache_spec` and
   `tm_fx_window_cache_spec` restate against the carry.
6. **Phase 5 — the walk shrinks** (§ Open 2) — the frontier and linear
   walks reassessed now that the walk asks only about pitch.

## Landed  (newest first; prune below ~4)

- 2026-09-10 tm: give the lane bound its population (§ The lane span)
- 2026-09-10 tm: state the lane bound in the logical frame (§ The lane span)
- 2026-09-10 tm: pin the frontier and linear walks to the same frame (§ The lane pass)
- 2026-09-09 tm: pin a swung tail's lane bound across its successor parking (§ Two populations)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)
- **`boundNote` bounds an on-take note through `frame.clippedSpanEnd`.**
  Its on-take arm of the expression goes, and the subject is the entry's
  column event. `parkedBoundFor` and its `parkedBounds` shim go from
  `rebuildTails` and from both walk signatures; `laneNext` stays for the
  derived notes. Spec: a lane whose successor is parked and one whose
  successor is on take get their bounds by the one route.
