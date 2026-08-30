-- The breakpoint-curve algebra lifted out of trackerManager and midiManager, where it values a
-- generator's stream, slices a base curve to a window, and meets the end of a half-open window.
--
-- A curve is a list of breakpoints ascending in ppq, and the shape on a breakpoint governs the
-- segment leaving it (REAPER's convention). So a segment is read from its left point, and the
-- shapes are all normalised the same way: each is a rise from 0 to 1 across the segment's span,
-- which is what lets the cases below compare a shape against the chord without restating it.
--
-- The window rules are the other half. A window [sL, eL) is half-open, so eL belongs to whatever
-- follows; a producer's close owns the tick eL-1 and its material stops at eL-2, which keeps a
-- closing control point from being overwritten by the last thing the stage emitted.

local t = require('support')
local curves = require('curves')

-- Bezier solves its x by twenty bisections, so a bezier claim is met to about 1e-6 and no closer.
local function near(actual, expected, msg, tolerance)
  if math.abs(actual - expected) > (tolerance or 1e-9) then
    t.eq(actual, expected, msg)   -- equal enough to pass, else report through eq's diff
  end
end

-- The rise of one segment as a fraction, sampled tick by tick across its span. The segment runs
-- 0 -> 10 over 100 ticks, so the chord through it is the fraction tick/100.
local function sweep(shape, tension)
  local A = { ppq = 0, val = 0, shape = shape, tension = tension }
  local B = { ppq = 100, val = 10 }
  local rise = {}
  for tick = 0, 100 do rise[tick] = curves.interpolate(A, B, tick) / 10 end
  return rise
end

local EASED = { 'linear', 'slow', 'fast-start', 'fast-end', 'bezier' }

return {
  {
    -- Every shape but step is a rise: it leaves the left value, reaches the right one, and never
    -- turns back or overshoots on the way. That is what the emission sites downstream assume when
    -- they round and clamp a sampled value into their own units.
    name = 'curves: every eased shape rises monotonically from one breakpoint to the next',
    run = function()
      for _, shape in ipairs(EASED) do
        local rise = sweep(shape)
        near(rise[0], 0, shape .. ' leaves the left breakpoint')
        near(rise[100], 1, shape .. ' arrives at the right breakpoint')
        local moved = false
        for tick = 1, 100 do
          t.truthy(rise[tick] >= rise[tick - 1] - 1e-12, shape .. ' turned back at tick ' .. tick)
          t.truthy(rise[tick] >= -1e-12 and rise[tick] <= 1 + 1e-12,
            shape .. ' left the segment at tick ' .. tick)
          if rise[tick] > rise[tick - 1] then moved = true end
        end
        t.truthy(moved, shape .. ' never moved at all')
      end
    end,
  },
  {
    -- The shape is read off the left breakpoint alone, so a step segment holds its value however
    -- the right one is shaped, and holds it right up to the right breakpoint's own tick -- the
    -- next segment takes over there. A pair with no span between them has no fraction to sample,
    -- and answers the left value too.
    name = 'curves: the segment is read from its left breakpoint',
    run = function()
      local step   = { ppq = 0, val = 3, shape = 'step' }
      local plain  = { ppq = 0, val = 3 }
      local curved = { ppq = 100, val = 9, shape = 'bezier', tension = 0.5 }
      for _, A in ipairs({ step, plain }) do
        for _, tick in ipairs({ 0, 1, 50, 99, 100 }) do
          t.eq(curves.interpolate(A, curved, tick), 3, 'a held segment moved at tick ' .. tick)
        end
      end
      t.eq(curves.interpolate({ ppq = 40, val = 3, shape = 'linear' }, { ppq = 40, val = 9 }, 40), 3,
        'a segment of no span has no fraction to sample')
    end,
  },
  {
    -- Two streams share the algebra: cc and pb values ride in `val`, and the authored cents the pb
    -- seating reads ride in `cents`. The field selects which one is interpolated, and a breakpoint
    -- missing it reads as zero, so a stream can start from an unwritten point.
    name = 'curves: the field names which stream is interpolated',
    run = function()
      local A = { ppq = 0, val = 10, cents = 100, shape = 'linear' }
      local B = { ppq = 100, val = 20, cents = 200 }
      t.eq(curves.interpolate(A, B, 50), 15, 'val is the default stream')
      t.eq(curves.interpolate(A, B, 50, 'cents'), 150, 'cents is the pb seating\'s stream')
      t.eq(curves.interpolate({ ppq = 0, shape = 'linear' }, B, 50), 10, 'an unwritten point reads as zero')
    end,
  },
  {
    -- The three named eases bend the chord the way their names claim, measured against the chord
    -- the spec computes for itself. Slow eases at both ends, so it is symmetric about the midpoint
    -- and crosses there; fast-start is ahead of the chord throughout; fast-end behind it.
    name = 'curves: the named eases bend the chord in the direction they claim',
    run = function()
      local slow, fastStart, fastEnd = sweep('slow'), sweep('fast-start'), sweep('fast-end')
      near(slow[50], 0.5, 'slow crosses the chord at the midpoint')
      for tick = 1, 99 do
        local chord = tick / 100
        near(slow[tick] + slow[100 - tick], 1, 'slow is asymmetric at tick ' .. tick)
        t.truthy(fastStart[tick] > chord, 'fast-start fell behind the chord at tick ' .. tick)
        t.truthy(fastEnd[tick] < chord, 'fast-end ran ahead of the chord at tick ' .. tick)
      end
      t.truthy(slow[25] < 0.25 and slow[75] > 0.75, 'slow did not ease at its ends')
    end,
  },
  {
    -- Bezier is the one shape carrying a parameter. At zero tension it is the symmetric S; the
    -- sign of the tension picks which side of the chord the whole interior falls, and raising the
    -- magnitude pushes it further from the chord until the clamp at one stops it.
    name = 'curves: bezier tension chooses a side of the chord and how far from it',
    run = function()
      local flat, positive, negative = sweep('bezier', 0), sweep('bezier', 0.5), sweep('bezier', -0.5)
      for tick = 1, 99 do
        local chord = tick / 100
        near(flat[tick] + flat[100 - tick], 1, 'zero tension is asymmetric at tick ' .. tick, 1e-5)
        t.truthy(positive[tick] < chord, 'positive tension rose above the chord at tick ' .. tick)
        t.truthy(negative[tick] > chord, 'negative tension fell below the chord at tick ' .. tick)
      end
      local previous
      for _, tension in ipairs({ 0, 0.25, 0.5, 0.75, 1 }) do
        local rise = sweep('bezier', tension)
        near(rise[0], 0, 'tension moved the left breakpoint')
        near(rise[100], 1, 'tension moved the right breakpoint')
        if previous then t.truthy(rise[50] < previous, 'more tension did not bow the curve further') end
        previous = rise[50]
      end
      near(sweep('bezier', 4)[50], previous, 'tension beyond one is the same curve as one')
    end,
  },
  {
    -- A whole curve is held both ways: before its first breakpoint it reads the first value, after
    -- its last it reads the last, and an empty curve reads zero. Within, it is the bounding pair
    -- interpolated -- so a step segment holds until the point that ends it.
    name = 'curves: a curve is held before its first breakpoint and after its last',
    run = function()
      local curve = { { ppq = 100, val = 4, shape = 'linear' },
                      { ppq = 200, val = 8, shape = 'step' },
                      { ppq = 300, val = 2 } }
      t.eq(curves.eval({}, 50), 0, 'an empty curve reads zero')
      t.eq(curves.eval(curve, 0), 4, 'before the first breakpoint')
      t.eq(curves.eval(curve, 100), 4, 'on the first breakpoint')
      t.eq(curves.eval(curve, 150), 6, 'the linear segment interpolates')
      t.eq(curves.eval(curve, 250), 8, 'the step segment holds')
      t.eq(curves.eval(curve, 300), 2, 'on the last breakpoint')
      t.eq(curves.eval(curve, 9999), 2, 'past the last breakpoint')
    end,
  },
  {
    -- Slicing answers the same curve over a narrower span. The base is the oracle: every tick of
    -- the slice reads what the base reads there, whether the edges land mid-segment or on a
    -- breakpoint, and the authored points between the edges survive as themselves.
    name = 'curves: a slice reads what the base reads, tick for tick',
    run = function()
      local base = { { ppq = 0, val = 0, shape = 'linear' },
                     { ppq = 100, val = 10, shape = 'step' },
                     { ppq = 200, val = 4, shape = 'linear' },
                     { ppq = 400, val = 0 } }
      t.deepEq(curves.slice({}, 30, 170), {}, 'an empty base slices to nothing')
      for _, edges in ipairs({ { 30, 170 }, { 0, 400 }, { 100, 200 }, { 150, 151 } }) do
        local sliced = curves.slice(base, edges[1], edges[2])
        t.eq(sliced[1].ppq, edges[1], 'the slice opens on its start')
        t.eq(sliced[#sliced].ppq, edges[2], 'the slice closes on its end')
        for tick = edges[1], edges[2] do
          near(curves.eval(sliced, tick), curves.eval(base, tick),
            'slice disagreed with the base at tick ' .. tick)
        end
      end
      local sliced = curves.slice(base, 30, 170)
      t.eq(#sliced, 3, 'the breakpoint between the edges survives')
      t.eq(sliced[2], base[2], 'and survives as the authored point itself')
    end,
  },
  {
    -- An edge landing mid-segment carries the shape and tension of the point governing it, so the
    -- slice keeps interpolating the way the base did rather than falling back to a straight line.
    name = 'curves: a slice edge carries the shape governing it',
    run = function()
      local base = { { ppq = 0, val = 0, shape = 'bezier', tension = 0.5 },
                     { ppq = 100, val = 10 } }
      local sliced = curves.slice(base, 25, 75)
      t.eq(sliced[1].shape, 'bezier', 'the entering edge dropped the shape')
      t.eq(sliced[1].tension, 0.5, 'the entering edge dropped the tension')
      local before = curves.slice(base, -50, 50)
      t.eq(before[1].shape, 'step', 'an edge before the curve starts holds what it finds')
    end,
  },
  {
    -- The close owns the tick eL-1: it lands inside the half-open window, so no close ever falls
    -- on the boundary row, and it displaces anything the stage put on that tick. A window with no
    -- room for a tick before its end takes no close at all.
    name = 'curves: the close owns the tick before the window ends',
    run = function()
      local pts = curves.closeAtWindowEnd({ { ppq = 100, val = 1 } }, 7, 0, 480)
      t.eq(#pts, 2)
      t.deepEq(pts[2], { ppq = 479, val = 7, shape = 'step' }, 'the close is a step on eL-1')
      local displaced = curves.closeAtWindowEnd({ { ppq = 479, val = 1, shape = 'linear' } }, 7, 0, 480)
      t.eq(#displaced, 1, 'two points cannot share the closing tick')
      t.eq(displaced[1].val, 7, 'and the close is the one that stands')
      local narrow = { { ppq = 100, val = 1 } }
      t.eq(curves.closeAtWindowEnd(narrow, 7, 100, 101), narrow, 'a window with no room takes no close')
      t.eq(#narrow, 1)
    end,
  },
  {
    -- A stage's material stops at eL-2, the last tick that is not the close's. Anything at or past
    -- it collapses onto that tick, latest wins, and the collapse copies rather than moving the
    -- point it came from. A window too narrow to hold even that tick keeps nothing.
    name = 'curves: material folds onto the tick before the close\'s',
    run = function()
      local source = { { ppq = 100, val = 1 }, { ppq = 470, val = 2 },
                       { ppq = 478, val = 3 }, { ppq = 479, val = 4 }, { ppq = 600, val = 5 } }
      local folded = curves.foldIntoWindow(source, 0, 480)
      t.eq(#folded, 3, 'everything at or past eL-2 is one point')
      t.eq(folded[1], source[1], 'a point inside the window passes through as itself')
      t.deepEq({ folded[3].ppq, folded[3].val }, { 478, 5 }, 'the last arrival owns the tick')
      t.eq(source[5].ppq, 600, 'folding moved the point it copied')
      t.deepEq(curves.foldIntoWindow(source, 100, 101), {}, 'a window with no material tick keeps nothing')
    end,
  },
  {
    -- The two rules compose into the shape a window emits: the material folded first, then the
    -- close. Nothing reaches eL, exactly one point sits on the closing tick and it is the close's,
    -- and the material that was pushed up against it still stands one tick below.
    name = 'curves: folded material and the close leave the window with room for both',
    run = function()
      local sL, eL = 240, 480
      local pts = curves.foldIntoWindow({ { ppq = 300, val = 1 }, { ppq = 479, val = 3 },
                                          { ppq = 700, val = 4 } }, sL, eL)
      pts = curves.closeAtWindowEnd(pts, 9, sL, eL)
      local onClose, onLast = 0, 0
      for _, p in ipairs(pts) do
        t.truthy(p.ppq >= sL and p.ppq < eL, 'a point left the window at ppq ' .. p.ppq)
        if p.ppq == eL - 1 then onClose = onClose + 1 end
        if p.ppq == eL - 2 then onLast = onLast + 1 end
      end
      t.eq(onClose, 1, 'exactly one point closes the window')
      t.eq(onLast, 1, 'the folded material stands a tick below the close')
      t.eq(pts[#pts].val, 9, 'and the close is last')
    end,
  },
}
