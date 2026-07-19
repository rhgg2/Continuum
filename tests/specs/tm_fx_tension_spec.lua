-- Bezier tension through fx windows. The continuous bases feeding fx expansion
-- (pbBaseFor/ccBasesFor) must carry authored tension: in-window folds interpolate
-- via mm:interpolate, and a dropped tension silently re-shapes the curve, skewing
-- every derived seat under the window. Depth-0 vibrato / scale-0 lfo make the fx
-- contribution exactly zero, so each seat is a pure sample of the authored base.

local t    = require('support')
local util = require('util')

-- Matches tm's centsToRaw at the default pbRange (2 semitones = 200 cents).
local function c2r(c) return util.clamp(util.round(c * 8192 / 200), -8192, 8191) end

local function byPpq(dump, pred)
  local out = {}
  for _, c in ipairs(dump.ccs) do
    if pred(c) then out[c.ppq] = c end
  end
  return out
end

-- The slice edge channelStreams synthesizes: value sampled at the window bound, shape and
-- tension carried from the governing point (the curve re-anchors at the edge).
local function sliceEdge(fm, govern, target, ppq)
  return { ppq = ppq, val = fm:interpolate(govern, target, ppq, 'val'),
           shape = govern.shape, tension = govern.tension }
end

return {

  ----- pb: the authored base pick (on-take pbs outside the window govern the slice)

  {
    name = 'authored bezier pb governs an fx window: seats sample the tensioned curve',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq = 0,   chan = 1, evType = 'pb', val = 0,        cents = 0,   shape = 'bezier', tension = 0.9 },
            { ppq = 480, chan = 1, evType = 'pb', val = c2r(100), cents = 100, shape = 'linear' },
          },
        },
      }
      h.tm:addEvent({ evType = 'note', ppq = 120, endppq = 360, chan = 1, pitch = 60, vel = 100,
                      detune = 0, delay = 0, lane = 1,
                      fx = { { kind = 'vibrato', period = { 1, 4 }, depth = 0, onset = 0 } } })
      h.tm:flush()

      local pbs = byPpq(h.fm:dump(), function(c) return c.evType == 'pb' and c.chan == 1 end)
      t.eq(pbs[0].tension, 0.9, 'precondition: the authored bezier keeps its tension on the wire')

      local govern = { ppq = 0,   val = 0,   shape = 'bezier', tension = 0.9 }
      local target = { ppq = 480, val = 100 }
      local e120 = sliceEdge(h.fm, govern, target, 120)
      local e360 = sliceEdge(h.fm, govern, target, 360)
      t.truthy(pbs[120] and pbs[135], 'seats at the window start and the first vibrato extremum')
      t.eq(pbs[120].val, c2r(e120.val), 'window-start seat samples the tensioned curve')
      t.eq(pbs[135].val, c2r(h.fm:interpolate(e120, e360, 135, 'val')),
        'in-window seat interpolates with the tension riding the slice edge')
    end,
  },

  ----- cc: both picks -- the on-take column (bp before the window) and the parked cell (bp inside)

  {
    name = 'authored bezier ccs govern an lfo window: column and parked picks keep tension',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq = 0,   chan = 1, evType = 'cc', cc = 1, val = 0,   shape = 'bezier', tension = 0.9 },
            { ppq = 240, chan = 1, evType = 'cc', cc = 1, val = 100, shape = 'bezier', tension = -0.9 },
            { ppq = 480, chan = 1, evType = 'cc', cc = 1, val = 0,   shape = 'linear' },
          },
        },
      }
      -- The bp at 240 parks (route-by-window), so [120,240) reads the column pick and
      -- [240,360) the parked pick.
      h.tm:addEvent({ evType = 'note', ppq = 120, endppq = 360, chan = 1, pitch = 60, vel = 100,
                      detune = 0, delay = 0, lane = 1,
                      fx = { { kind = 'lfo', period = { 1, 4 }, centre = 0, scale = 0,
                               pattern = { kind = 'curve', lengthPpq = 60,
                                           points = { { ppq = 0, val = 0, shape = 'linear' } } } } } })
      h.tm:flush()

      local cc1 = byPpq(h.fm:dump(), function(c) return c.evType == 'cc' and c.cc == 1 and c.chan == 1 end)
      t.eq(cc1[0].tension, 0.9, 'precondition: the authored bezier keeps its tension on the wire')

      local first  = { ppq = 0,   val = 0,   shape = 'bezier', tension = 0.9 }
      local middle = { ppq = 240, val = 100, shape = 'bezier', tension = -0.9 }
      local last   = { ppq = 480, val = 0 }
      local e120 = sliceEdge(h.fm, first,  middle, 120)
      local e360 = sliceEdge(h.fm, middle, last,   360)
      local function ccRound(v) return util.clamp(util.round(v), 0, 127) end
      t.truthy(cc1[180] and cc1[300], 'seats at the lfo cycle points inside each segment')
      t.eq(cc1[180].val, ccRound(h.fm:interpolate(e120, middle, 180, 'val')),
        'column-picked bezier governs [120,240): tension rides the fold')
      t.eq(cc1[300].val, ccRound(h.fm:interpolate(middle, e360, 300, 'val')),
        'parked bezier governs [240,360): tension survives the park pick')
    end,
  },
}
