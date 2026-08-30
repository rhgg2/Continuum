# trackerManager: the algebra and the engine — plan

> source: `design/tracker-manager-split.md` — synthesis compiled from
> there; don't design here.

## Phases

1. **Phase 1 — the algebra leaves** (§ Phase 1) — `spans.lua` and
   `curves.lua`, the two seeks to `util`, and the fold tested against a
   list of points rather than a rebuild.  ← in flight
2. **Phase 2 — the dirt spine** (§ Phase 2) — `dirt.lua` with one join
   verb, collapsing the three hand-written joins and fixing the two that
   are wrong.
3. **Phase 3 — pb at its seam** (§ What the specs hold 4) — coverage of
   `rebuildPbs`'s keep/live split, `pbScope` gating, and the seating ↔
   synthesis seam, before anything moves.
4. **Phase 4 — the seams drawn in place** (§ Phase 3 3–10) — the frame as
   a handle carrying its seven operations, index and stager as door
   tables, the fx maps returned rather than assigned, and `forget()` on
   the take-tier path; all still inside tm.
5. **Phase 5 — the engine leaves** (§ Phase 3 1–2, 11–17, § Open) —
   `trackerRebuild.lua` and its eight dependencies, with `tm` named as
   what it actually is.

## Landed  (newest first; prune below ~4)

(nothing yet)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. **The seeks join `util`.** `firstAfter` and `firstAtOrAfter` become
   `util.firstAfter` and `util.firstAtOrAfter`, beside `util.seek` and
   `util.insertSorted` which share their shape; tm's two dozen call sites
   repoint. A spec covers the empty list, both boundaries, a run of equal
   ppq, and the past-the-end index each returns.

1. **`spans.lua`.** The six span-set names — `mergeSpans`,
   `mergeWindows`, `overlapping`, `spanSetIntersects`, `clipToSpanSet`,
   `subtractSpanSet` — move to a module whose only requirement is `util`.
   A spec covers adjacency joining and gaps splitting, that no input span
   is aliased into a merge, half-openness at both edges, and subtraction
   as the complement of clipping within one span.

1. **`curves.lua` takes interpolation and the point level.**
   `curveSample` and `mm:interpolate` move from midiManager to
   `curves.interpolate`, and `mm:interpolate` delegates so its other
   callers are untouched; `evalCurve`, `sliceCurve`, `isCurved`,
   `anyNonZero`, `closeAtWindowEnd` and `foldIntoWindow` follow. The
   module requires `util` and `spans`. A spec drives the five shapes and
   bezier tension directly, and holds the two half-open edge rules: the
   close owns tick `eL-1`, and material folds onto `eL-2`.

1. **The fold joins it.** `sumStreams` and the four private helpers —
   `negated`, `foldWhole`, `chainCuts`, `foldSub` — move behind
   `foldChains`. `ccGridStep` stays in tm as configuration, and the
   densify step passes as a parameter through `sumStreams`, `foldWhole`,
   `foldSub` and `foldChains`. A spec exercises the fold against lists of
   points: a single covering record verbatim, a replace against an add,
   sub-splitting at record edges, the all-flat sweep to empty, and the
   extent-then-select emission that keeps a kept range agreeing with a
   full re-derive.

The two citations naming these as trackerManager's —
`docs/trackerManager.md` on `evalCurve`/`sliceCurve` and on `foldChains`
— repoint with the commits that move them.
