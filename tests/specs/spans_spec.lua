-- The half-open span algebra lifted out of trackerManager, where it scopes the
-- fx-region folds, the cc and pb augment passes and the detune seat walk. A
-- span is a pair { lo, hi } standing for the ticks lo <= t < hi; a span set is
-- a list of disjoint ascending spans, which is what spans.merge produces and
-- what everything else consumes.
--
-- Half-openness is where the module's two halves part company. Merging joins
-- spans that touch, because [0,10) and [10,20) between them cover [0,20) with
-- no tick missing; the two overlap predicates reject that same pair, because no
-- tick lies in both. The rest is arithmetic on the convention: clipping meets a
-- span with each scope, subtraction takes the complement within the span, and
-- the two partition it exactly.

local t = require('support')
local util = require('util')
local spans = require('spans')

-- The oracle: a span set as the set of integer ticks it covers, counted one at a
-- time, independent of the interval arithmetic under test.
local function ticksOf(set)
  local covered = {}
  for _, span in ipairs(set) do
    for tick = span[1], span[2] - 1 do covered[tick] = true end
  end
  return covered
end

return {
  {
    -- The three things merging does, in one unsorted input: two spans that
    -- overlap join, two that touch join, and a gap between them survives as a
    -- boundary. Sorting is the merge's own, so the input arrives out of order.
    name = 'spans: overlap and adjacency join, and gaps split',
    run = function()
      local merged = spans.merge({ { 10, 20 }, { 0, 5 }, { 5, 8 }, { 18, 30 }, { 40, 45 } })
      t.deepEq(merged, { { 0, 8 }, { 10, 30 }, { 40, 45 } })
    end,
  },
  {
    -- The result is the caller's to mutate. Production passes windows off live
    -- records, so a merge that carried one of them through by reference would
    -- let a later clip rewrite the record it came from.
    name = 'spans: merging copies, so no input span is aliased into the result',
    run = function()
      local inputs = { { 0, 10 }, { 5, 20 }, { 30, 40 } }
      local before = util.deepClone(inputs)
      local merged = spans.merge(inputs)
      t.eq(#merged, 2, 'the first two inputs must actually have joined')
      for _, span in ipairs(merged) do span[1], span[2] = -1, -1 end
      t.deepEq(inputs, before, 'mutating the result reached back into an input span')
    end,
  },
  {
    -- Where the halves part. A touch is a join to the merge and a miss to both
    -- predicates; one tick of genuine overlap flips both predicates back.
    name = 'spans: a touch joins under merge and separates under the overlap predicates',
    run = function()
      t.deepEq(spans.merge({ { 0, 10 }, { 10, 20 } }), { { 0, 20 } })
      t.falsy(spans.intersects({ { 0, 10 } }, { 10, 20 }), 'a scope ending where the window opens')
      t.falsy(spans.intersects({ { 20, 30 } }, { 10, 20 }), 'a scope opening where the window ends')
      t.eq(#spans.overlapping({ { window = { 0, 10 } } }, { 10, 20 }), 0)
      t.truthy(spans.intersects({ { 0, 11 } }, { 10, 20 }))
      t.eq(#spans.overlapping({ { window = { 0, 11 } } }, { 10, 20 }), 1)
    end,
  },
  {
    -- Clipping meets the span with each scope in turn and keeps the non-empty
    -- meets. It does not coalesce: two adjacent scopes clip to two adjacent
    -- spans, and the emission sites downstream depend on that granularity. A scope touching an edge meets the span in no
    -- tick at all, so it contributes nothing -- not a span of zero width, which
    -- would put an emission site on an edge that belongs to its neighbour.
    name = 'spans: clipping meets the span with every scope and drops the empty meets',
    run = function()
      local scopes = { { 0, 5 }, { 0, 10 }, { 10, 12 }, { 20, 40 }, { 25, 40 }, { 60, 70 } }
      local clipped = spans.clip({ 5, 25 }, scopes)
      t.deepEq(clipped, { { 5, 10 }, { 10, 12 }, { 20, 25 } })
      for _, span in ipairs(clipped) do t.truthy(span[1] < span[2], 'a clipped span with no width') end
    end,
  },
  {
    -- Subtraction is the complement of clipping within the span: every tick of
    -- the span lands in exactly one of the two results, and neither reaches
    -- outside it. The configurations cover the arrangements a scope set can
    -- take against a span, and the same sweep pins the predicate against the
    -- clip -- a scope set intersects the span iff clipping it yields something.
    name = 'spans: clipping and subtraction partition the span, tick for tick',
    run = function()
      local span = { 10, 30 }
      local configurations = {
        {},                          -- no scopes at all
        { { 0, 5 } },                -- wholly outside
        { { 12, 15 } },              -- interior
        { { 0, 12 }, { 25, 40 } },   -- both edges, a gap between
        { { 10, 30 } },              -- exact cover
        { { 0, 40 } },               -- swallowed
        { { 12, 15 }, { 15, 18 } },  -- adjacent scopes
      }
      local sawClipped, sawRest = 0, 0
      for _, scopes in ipairs(configurations) do
        local inClip = ticksOf(spans.clip(span, scopes))
        local inRest = ticksOf(spans.subtract(span, scopes))
        for tick = 0, 40 do
          local hits = (inClip[tick] and 1 or 0) + (inRest[tick] and 1 or 0)
          t.eq(hits, (tick >= span[1] and tick < span[2]) and 1 or 0, 'tick ' .. tick)
        end
        t.eq(spans.intersects(scopes, span), next(inClip) ~= nil)
        if next(inClip) then sawClipped = sawClipped + 1 end
        if next(inRest) then sawRest = sawRest + 1 end
      end
      t.truthy(sawClipped > 0, 'no configuration clipped to anything')
      t.truthy(sawRest > 0, 'no configuration left a remainder')
    end,
  },
  {
    -- An absent scope set is the unclaimed target: the gate reads a scope table
    -- that may not be there, and absent is empty, not unscoped.
    name = 'spans: an absent scope set clips to nothing and subtracts to the whole span',
    run = function()
      t.deepEq(spans.clip({ 0, 10 }, nil), {})
      t.deepEq(spans.subtract({ 0, 10 }, nil), { { 0, 10 } })
      t.falsy(spans.intersects(nil, { 0, 10 }))
    end,
  },
  {
    -- The two adaptors read .window off each record. Merging windows answers
    -- fresh spans, so mutating them leaves the records alone; overlapping
    -- answers the records themselves, in the bucket's order, since the caller
    -- wants what the window belongs to.
    name = 'spans: the bucket adaptors read the window off each record',
    run = function()
      local a, b, c = { window = { 0, 10 } }, { window = { 8, 12 } }, { window = { 30, 40 } }
      t.deepEq(spans.mergeWindows({ a, b, c }), { { 0, 12 }, { 30, 40 } })
      for _, span in ipairs(spans.mergeWindows({ a, b, c })) do span[1], span[2] = -1, -1 end
      t.deepEq(a.window, { 0, 10 }, 'merging windows aliased a record\'s own window')
      local hits = spans.overlapping({ a, b, c }, { 11, 35 })
      t.eq(#hits, 2, 'the record ending at 10 must fall outside a window opening at 11')
      t.eq(hits[1], b)
      t.eq(hits[2], c)
    end,
  },
}
