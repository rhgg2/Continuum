# dirt owns the row questions — plan

> no design doc: one phase, and what it changes in the model belongs in
> `docs/trackerManager.md` § Lane occupancy and § Interval seeds.

## Phases

1. **Phase 1 — the row questions move to dirt** — the journal answers
   `names`, `covers` and `touches` over its own seeds, and the four
   readings of the seed list in `trackerRebuild.lua` give way to them.
   ← in flight

## Rests on

1. A seed's logical row cannot move after the flush that filed it. The
   pipeline's one mid-pass onset move is `settleOnset`'s same-pitch
   separation, which writes raw `ppq` and carries the shift on `delayC`;
   it reads `ppqL` as unchanged truth to compute that shift. Under
   interval dirt every seeded note carries a `ppqL`, so no seeded row
   moves.

1. The `index.byUuid` lookup in `seedRowsFor` is therefore recoverable
   information, not a live read: it buys back the row that `flushDirt`'s
   keep-first dedup discarded. Folding that row onto the kept seat at
   flush leaves dirt closed over its own state, so a memo on the rows is
   invalidated by `add` alone.

1. `clipEnd` today tests `s.ppqL` and no more, so it misses a neighbour
   moved *into* a cached span and strands a stale clip — the vacated
   snapshot is the only row the journal kept. Phase 1 fixes this by
   construction.

1. The suite runs 10758 `seedRowsFor` calls over 18354 seeds, each with
   a lookup, against 2284 `clipEnd` calls. One sorted array per dirty
   channel retires all of them, and makes `touches` a binary search, so
   the cached path stops costing more than the recompute it avoids.

## Landed  (newest first; prune below ~4)

- 2026-09-02 dirt: the journal answers covers and touches over its own seeds (design/decisions.md 2026-09-02)
- 2026-09-02 dirt: a seed carries every row its uuid held during the flush (design/decisions.md 2026-09-02)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

- tm: the clip cache reseeks a neighbour moved into its span — the
  journal gains `names`, and `clipEnd` asks it and `touches`, with a spec
  over the move.
