-- pb interpolation across a detune onset (design/archive/pb-interpolation.md, Step 1).
-- A derived absorber seat samples the prevailing authored pb value at its ppq
-- and adds detune, instead of punching the wire down to detune-only. Linear
-- glides land exactly; curved glides densify to a linear polyline; the detune
-- step rides a dual point so it never smears across the curve.

local t    = require('support')
local util = require('util')

-- Matches tm's centsToRaw at the default pbRange (2 semitones = 200 cents).
local function c2r(c) return util.clamp(util.round(c * 8192 / 200), -8192, 8191) end

local function pbWire(dump, chan)
  local out = {}
  for _, c in ipairs(dump.ccs) do
    if c.evType == 'pb' and c.chan == chan then out[#out + 1] = c end
  end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
  return out
end

-- Two sequential lane-1 notes; detune steps 0 -> 50 at the second's onset (ppq 120).
local function twoNotesStepDetune()
  return {
    { ppq = 0,   endppq = 120, chan = 1, pitch = 60, vel = 100, detune = 0,  ppqL = 0,   endppqL = 120 },
    { ppq = 120, endppq = 240, chan = 1, pitch = 62, vel = 100, detune = 50, ppqL = 120, endppqL = 240 },
  }
end

return {

  {
    name = 'linear glide across a detune onset -> seat carries the interpolated value',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = twoNotesStepDetune(),
          ccs = {
            { ppq = 0,   chan = 1, evType = 'pb', val = 0,         cents = 0,   shape = 'linear' },
            { ppq = 240, chan = 1, evType = 'pb', val = c2r(150),  cents = 100, shape = 'linear' },
          },
        },
      }
      local pbs = pbWire(h.fm:dump(), 1)
      t.eq(#pbs, 4, 'real endpoints + dual point at the onset')

      t.eq(pbs[1].ppq, 0);   t.eq(pbs[1].val, 0);        t.falsy(pbs[1].derived)
      t.eq(pbs[2].ppq, 119); t.eq(pbs[2].val, c2r(50));  t.truthy(pbs[2].derived)  -- value 50 + old detune 0
      t.eq(pbs[3].ppq, 120); t.eq(pbs[3].val, c2r(100)); t.truthy(pbs[3].derived)  -- value 50 + new detune 50
      t.eq(pbs[4].ppq, 240); t.eq(pbs[4].val, c2r(150)); t.falsy(pbs[4].derived)
    end,
  },

  {
    name = 'held single pb across a detune onset -> seat keeps the held value (hold-left)',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = twoNotesStepDetune(),
          ccs = {
            { ppq = 0, chan = 1, evType = 'pb', val = c2r(100), cents = 100, shape = 'step' },
          },
        },
      }
      local pbs = pbWire(h.fm:dump(), 1)
      t.eq(#pbs, 2, 'the real pb plus one valued seat at the onset')
      t.eq(pbs[1].ppq, 0);   t.eq(pbs[1].val, c2r(100)); t.falsy(pbs[1].derived)
      t.eq(pbs[2].ppq, 120); t.eq(pbs[2].val, c2r(150)); t.truthy(pbs[2].derived)  -- held 100 + detune 50
    end,
  },

  {
    name = 'curved glide across a detune onset -> densified, endpoints exact, no notch',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = twoNotesStepDetune(),
          ccs = {
            { ppq = 0,   chan = 1, evType = 'pb', val = 0,        cents = 0,   shape = 'slow' },
            { ppq = 240, chan = 1, evType = 'pb', val = c2r(150), cents = 100, shape = 'slow' },
          },
        },
      }
      local pbs = pbWire(h.fm:dump(), 1)

      -- Endpoints are the untouched authored events.
      t.eq(pbs[1].ppq, 0);              t.eq(pbs[1].val, 0);        t.falsy(pbs[1].derived)
      t.eq(pbs[#pbs].ppq, 240);         t.eq(pbs[#pbs].val, c2r(150)); t.falsy(pbs[#pbs].derived)

      -- Grid densification: interior derived seats sample the curve.
      local derived, byPpq = 0, {}
      for _, p in ipairs(pbs) do
        if p.derived then derived = derived + 1 end
        byPpq[p.ppq] = p
      end
      t.truthy(derived >= 7, 'curved segment densified to a linear polyline (grid present)')
      t.truthy(byPpq[8] and byPpq[16], 'grid step is ppqPerQN/CCINTERP (240/32 = 8 ticks)')
      t.falsy(byPpq[4], 'grid is no denser than the CCINTERP points-per-QN spec')
      t.truthy(byPpq[64],  'a grid seat sits on the fixed CCINTERP grid')

      -- Dual point: the detune step is a clean +50c at the onset, riding the curve.
      t.truthy(byPpq[119] and byPpq[120], 'dual point straddles the onset')
      t.eq(byPpq[120].val - byPpq[119].val, c2r(50), 'step is pure detune (50c), not smeared')

      -- No notch: the wire is monotone non-decreasing through the rising curve + step.
      for i = 2, #pbs do
        t.truthy(pbs[i].val >= pbs[i - 1].val, 'monotone across the densified curve')
      end
    end,
  },

  {
    name = 'densified channel: flush -> rebuild -> flush is churn-free (stable grid keys)',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = twoNotesStepDetune(),
          ccs = {
            { ppq = 0,   chan = 1, evType = 'pb', val = 0,        cents = 0,   shape = 'slow' },
            { ppq = 240, chan = 1, evType = 'pb', val = c2r(150), cents = 100, shape = 'slow' },
          },
        },
      }
      local before = pbWire(h.fm:dump(), 1)
      h.tm:rebuild()
      h.tm:flush()
      local after = pbWire(h.fm:dump(), 1)
      t.deepEq(after, before, 'no spurious pb writes on a steady rebuild')
    end,
  },

  {
    name = 'curved authored segment with no interior onset -> untouched, no seats',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100, detune = 0, ppqL = 0, endppqL = 240 },
          },
          ccs = {
            { ppq = 0,   chan = 1, evType = 'pb', val = 0,        cents = 0,   shape = 'slow' },
            { ppq = 240, chan = 1, evType = 'pb', val = c2r(100), cents = 100, shape = 'slow' },
          },
        },
      }
      local pbs = pbWire(h.fm:dump(), 1)
      t.eq(#pbs, 2, 'only the two authored pbs; the native curve is left to REAPER')
      for _, p in ipairs(pbs) do t.falsy(p.derived, 'no derived seats inserted') end
    end,
  },
}
