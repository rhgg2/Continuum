-- The fold that sits on top of the curve algebra: parallel chain records over one output target,
-- each carrying a window, a curve and a mode, folded into the points a channel finally emits.
--
-- The model is docs/generators.md § Multiplicity. An augment contributes its base-relative delta and
-- sums commutatively; a replace has no commutative fold, so it layers, and storage order is the
-- precedence. Records with differing edges sub-split at every edge, so between consecutive cuts the
-- active set is constant and an exclusive tail keeps its own curve.
--
-- The fold runs over the covering records' own extent and then selects the emission from that. A
-- gated rebuild re-derives a sub-range while the rest of the channel's seats stand, so the two have
-- to agree point for point -- which they only do while the range under repair cannot decide where
-- the segments fall. The cases below drive all of this from lists of points, with no rebuild.

local t      = require('support')
local curves = require('curves')

local GRID = 240   -- the densify step in ticks: a sixteenth at 960 ppq

-- A held curve: one value across [lo, hi], step-shaped so nothing interpolates.
local function flat(val, lo, hi)
  return { { ppq = lo, val = val, shape = 'step' }, { ppq = hi, val = val, shape = 'step' } }
end

local function rec(mode, lo, hi, curve)
  return { window = { lo, hi }, curve = curve, mode = mode }
end

local function ppqsOf(pts)
  local out = {}
  for _, point in ipairs(pts) do out[#out + 1] = point.ppq end
  return out
end

local function valsOf(pts)
  local out = {}
  for _, point in ipairs(pts) do out[#out + 1] = point.val end
  return out
end

-- The points of `pts` falling in the half-open [lo, hi) -- what a caller keeps of a full derive.
local function within(pts, lo, hi)
  local out = {}
  for _, point in ipairs(pts) do
    if point.ppq >= lo and point.ppq < hi then out[#out + 1] = point end
  end
  return out
end

return {
  {
    -- One covering record has nothing to fold against, so the fold hands back the record's own curve
    -- table: unclipped, and not a copy. That is what lets a same-window replace reach the wire
    -- verbatim, with no synthetic edge point where the fold would otherwise cut. The clip is the
    -- caller's, and both emission sites in trackerManager do it as they convert each point.
    name = 'curve fold: a lone covering record folds to its own curve, unclipped',
    run = function()
      local only = rec('replace', 0, 1000, flat(20, 0, 1000))
      local out  = curves.foldChains({ only }, { 200, 400 }, {}, GRID)
      t.truthy(rawequal(out, only.curve), 'the lone record folded to a curve of its own')
      t.deepEq(ppqsOf(out), { 0, 1000 }, 'both authored points survive')
      t.eq(#within(out, 200, 400), 0, 'the selecting span held none of them to begin with')
    end,
  },
  {
    -- Two records over one window fold left to right, a painter's algorithm. A replace layers over
    -- whatever stands, so it wins where it comes last; where it comes first, the augment behind it
    -- sums onto the replace's curve instead of onto the base. The two orders therefore disagree, and
    -- that disagreement is the model's claim that storage order is the precedence.
    name = 'curve fold: storage order decides between a replace and an augment',
    run = function()
      local augment = rec('augment', 0, 1000, flat(5, 0, 1000))
      local replace = rec('replace', 0, 1000, flat(20, 0, 1000))
      local layered = curves.foldChains({ augment, replace }, { 0, 1000 }, {}, GRID)
      local summed  = curves.foldChains({ replace, augment }, { 0, 1000 }, {}, GRID)
      t.truthy(#layered > 0 and #summed > 0, 'both orders emitted something to compare')
      t.eq(layered[1].val, 20, 'the replace, folded last, layers over the augment')
      t.eq(summed[1].val, 25, 'the augment, folded last, sums onto the replace')
    end,
  },
  {
    -- Records whose windows differ cut the fold at every edge. Here one augment holds +5 from 0 and a
    -- second holds +3 from 500, so the three sub-spans read 5, 8 and 3: the overlap sums both, and
    -- the tail past the first record's end keeps the second's curve alone.
    name = 'curve fold: records with differing edges sub-split at the edges',
    run = function()
      local early = rec('augment', 0, 1000, flat(5, 0, 1000))
      local late  = rec('augment', 500, 1500, flat(3, 500, 1500))
      local out   = curves.foldChains({ early, late }, { 0, 1500 }, {}, GRID)
      t.deepEq(ppqsOf(out), { 0, 500, 1000 }, 'one point per sub-span, at its left edge')
      t.deepEq(valsOf(out), { 5, 8, 3 }, 'the first alone, then both, then the second alone')
    end,
  },
  {
    -- Each sub-span is half-open, so a cut inside the fold belongs to the sub-span opening on it and
    -- appears once. The extent's own right edge has no sub-span to its right, and the record closing
    -- there does return the target to what it was, so the last sub-span keeps its closing point --
    -- which lands outside the half-open span, for the caller to keep or clip as its own end.
    name = 'curve fold: an interior cut is emitted once, and the last sub-span keeps its close',
    run = function()
      local early = rec('augment', 0, 1000, flat(5, 0, 1000))
      local late  = rec('replace', 500, 1500, flat(3, 500, 1500))
      local out   = curves.foldChains({ early, late }, { 0, 1500 }, {}, GRID)
      t.deepEq(ppqsOf(out), { 0, 500, 1000, 1500 }, 'one point per cut, and the extent closes')
      t.deepEq(valsOf(out), { 5, 3, 3, 3 }, 'the augment alone, then the replace layered over it')
    end,
  },
  {
    -- A chain that owns a target but emits nothing leaves an empty curve behind. The base below is a
    -- pair of seats reading zero, which is what an earlier pass leaves once its material is gone:
    -- nothing anywhere is non-zero, so the fold empties and the seats are swept. Both routes have to
    -- do it: records sharing a window fold whole, records with differing windows fold per sub-span. A
    -- base carrying a value is the counterpart: the records own nothing, so what stands is the base,
    -- and it survives untouched.
    name = 'curve fold: records with no material sweep to empty over an all-zero base',
    run = function()
      local silent = rec('augment', 0, 1000, {})
      local also   = rec('replace', 0, 1000, {})
      local later  = rec('augment', 500, 1500, {})
      t.eq(#flat(0, 0, 1000), 2, 'the base being swept holds seats to sweep')
      t.eq(#curves.foldChains({ silent, also }, { 0, 1000 }, flat(0, 0, 1000), GRID), 0,
        'whole-span fold empties')
      t.eq(#curves.foldChains({ silent, later }, { 0, 1500 }, flat(0, 0, 1500), GRID), 0,
        'sub-split fold empties')
      local heldWhole = curves.foldChains({ silent, also }, { 0, 1000 }, flat(7, 0, 1000), GRID)
      local heldSub   = curves.foldChains({ silent, later }, { 0, 1500 }, flat(7, 0, 1500), GRID)
      t.truthy(#heldWhole > 0 and #heldSub > 0, 'a base with a value is not swept by either route')
      for _, pts in ipairs({ heldWhole, heldSub }) do
        for _, point in ipairs(pts) do t.eq(point.val, 7, 'every emitted point still reads the base') end
      end
    end,
  },
  {
    -- The gated case. A curved augment runs the whole window and a second augment joins it halfway,
    -- so the sum is curved and no single breakpoint carries it: the fold densifies onto the grid.
    -- Where that lattice starts is then the whole question. Re-deriving the interior range [600, 900)
    -- has to land on the same ticks as a derive of the whole thing, because the points on either side
    -- of it are standing seats from the earlier pass. Folding over the records' extent is what makes
    -- it so; anchored at the range instead, the lattice would restart at 600 and every point in the
    -- repaired range would miss the seats it has to meet. The second range below closes on a tick the
    -- full derive holds, and the range is half-open, so that point belongs to the seats standing to
    -- its right and the repair must leave it alone.
    name = 'curve fold: a re-derived range agrees with the full derive point for point',
    run = function()
      local curved = rec('augment', 0, 1000, { { ppq = 0, val = 0, shape = 'slow' }, { ppq = 1000, val = 10 } })
      local joins  = rec('augment', 500, 1500, flat(3, 500, 1500))
      local recs   = { curved, joins }
      local full   = curves.foldChains(recs, { 0, 1500 }, {}, GRID)
      for _, range in ipairs({ { 600, 900 }, { 500, 980 } }) do
        local repair = curves.foldChains(recs, range, {}, GRID)
        local kept   = within(full, range[1], range[2])
        t.truthy(#kept > 0, 'the full derive put a point inside the range under repair')
        t.deepEq(ppqsOf(repair), ppqsOf(kept), 'the repair lands on the ticks the full derive holds')
        t.deepEq(valsOf(repair), valsOf(kept), 'and reads the same values there')
      end
      t.truthy(#within(full, 980, 981) == 1, 'the second range closes on a tick the derive holds')
    end,
  },
  {
    -- Underneath the fold, the summation. A curved segment has no exact representation as a sum, so
    -- it is sampled onto the grid -- but only where it has to be. A sole mover across the whole
    -- segment is representable as itself, so it passes through with its shape and tension intact and
    -- no sampling at all; add a second mover and neither one's shape describes the sum, so the
    -- segment is emitted as grid-spaced linear points. see docs/generators.md § Multiplicity
    name = 'curve fold: a sole curved mover keeps its segment, two movers densify onto the grid',
    run = function()
      local curved = { { ppq = 0, val = 0, shape = 'bezier', tension = 0.3 }, { ppq = 1000, val = 10 } }
      local sole   = curves.sumStreams({}, { curved }, { 0, 1000 }, GRID)
      t.eq(#sole, 1, 'the segment needed no sampling')
      t.eq(sole[1].shape, 'bezier', 'and carries its own shape')
      t.eq(sole[1].tension, 0.3, 'and its tension with it')
      local ramp   = { { ppq = 0, val = 0, shape = 'linear' }, { ppq = 1000, val = 4 } }
      local summed = curves.sumStreams(ramp, { curved }, { 0, 1000 }, GRID)
      t.deepEq(ppqsOf(summed), { 0, 240, 480, 720, 960 }, 'sampled onto the grid, half-open at 1000')
      for _, point in ipairs(summed) do t.eq(point.shape, 'linear', 'each sample joins the next') end
    end,
  },
}
