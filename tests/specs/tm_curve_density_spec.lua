-- Curve density: what the fold puts on the wire *between* breakpoints. The sum of two curves has no
-- single-breakpoint representation, so it is sampled onto the ccGridStep lattice; a curve that is the
-- only thing moving across a segment does have one, and rides out as its own breakpoint. That second
-- rule only holds if the fold's segments are independent of how the dirt sliced the channel, which is
-- why foldChains folds over its records' extent. see docs/generators.md § Multiplicity

local t = require('support')

-- depth 30c, period 1/4 QN: at res 240 one cycle is 60 ticks, so the macro's own breakpoints are the
-- extrema at 15, 45, 75, ... plus 0 and the terminal re-centre, folded one tick inside the span end.
local sine30 = { { kind = 'sine', period = { 1, 4 }, depth = 30, onset = 0 } }

local function note(ppq, endppq, pitch, lane, fx)
  return { evType = 'note', ppq = ppq, endppq = endppq, chan = 1, pitch = pitch,
           vel = 100, detune = 0, delay = 0, lane = lane, fx = fx }
end

local function pbSeats(h, lo, hi)
  local out = {}
  for _, c in ipairs(h.fm:dump().ccs) do
    if c.evType == 'pb' and c.chan == 1 and c.ppq >= lo and c.ppq < hi then
      out[#out + 1] = { ppq = c.ppq, val = c.val, shape = c.shape }
    end
  end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
  return out
end

local function ppqsOf(seats)
  local out = {}
  for _, s in ipairs(seats) do out[#out + 1] = s.ppq end
  return out
end

-- Two continuous producers whose windows overlap on [120, 240): sine A alone before it, both across
-- it, sine B alone after. One fixture covers all three of the fold's cases.
local function overlappingPair(h)
  h.tm:addEvent(note(0,   240, 60, 1, sine30))
  h.tm:addEvent(note(120, 360, 67, 2, sine30))
  h.tm:flush()
end

return {

  ----- A lone curve is representable, so it stays its own breakpoints

  {
    name = 'a lone curve seats its own breakpoints, not a lattice sampling of them',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent(note(0, 240, 60, 1, sine30))
      h.tm:flush()

      local seats = pbSeats(h, 0, 1000)
      t.deepEq(ppqsOf(seats), { 0, 15, 45, 75, 105, 135, 165, 195, 225, 239 },
        'the macro\'s own extrema, and nothing between them')
      for i = 1, #seats - 1 do
        t.eq(seats[i].shape, 'slow', 'the seat carries the macro\'s own shape, not a polyline leg')
      end
      t.eq(seats[#seats].shape, 'step', 'the terminal re-centre, folded one tick inside the span end')
    end,
  },

  ----- A sum of two curves is not representable, so it is sampled

  {
    name = 'a sum of two curves has no breakpoint representation, so it densifies',
    run = function(harness)
      local h = harness.mk()
      overlappingPair(h)

      local overlap = pbSeats(h, 120, 240)
      -- The two macros contribute 5 breakpoints of their own across here (120, 135, 165, 195, 225);
      -- anything past that is the lattice, which is the whole point.
      t.truthy(#overlap > 8, 'the overlap is sampled, not left to the constituents\' breakpoints')
      for _, s in ipairs(overlap) do
        t.eq(s.shape, 'linear', 'a sampled sum is a polyline -- no curved seat can stand for it')
      end

      -- Past the overlap only sine B moves, so its own segments come back: the first is truncated by
      -- the cut at 240 and is sampled, the whole ones after it are not.
      local after = pbSeats(h, 240, 360)
      t.eq(after[#after].shape, 'step', 'the window closes with its re-centre, folded one tick inside')
      t.eq(after[#after - 1].shape, 'slow', 'a whole segment of the surviving curve rides out verbatim')
    end,
  },

  ----- The segments must not depend on how the dirt sliced the channel

  {
    name = 'the seats do not depend on how the dirt sliced the channel',
    run = function(harness)
      local h = harness.mk()
      overlappingPair(h)

      -- An edit inside sine A's window seeds dirt there and leaves sine B's exclusive range kept, so
      -- the gated pass folds a different span from the full re-derive below.
      h.tm:addEvent(note(60, 180, 72, 3))
      h.tm:flush()
      local gated = pbSeats(h, 0, 1000)
      t.truthy(#gated > 0, 'seats present (non-vacuous)')

      h.tm:rebuild(true)
      t.deepEq(pbSeats(h, 0, 1000), gated,
        'a full re-derive lands on the same seats as the gated pass that kept half the channel')
    end,
  },

}
