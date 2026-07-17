-- Slide spec (portamento, continuous pb-augment): the glide-in curve sums onto the authored pb base
-- and seats a markerless pb stream on the base lane. see design/note-macros-v2.md § Continuous pb

local t    = require('support')
local util = require('util')

local classic58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }

local function centsToRaw(cents, pbRange)
  return util.clamp(util.round(cents * 8192 / ((pbRange or 2) * 100)), -8192, 8191)
end

-- pb-augment seats a summed stream on the base lane (markerless, no carrier). A seat carries a raw
-- pb `val` (centsToRaw of summed cents + detune); densified linear between feature points.
local function pbSeatsOf(dump, chan)
  local out = {}
  for _, c in ipairs(dump.ccs) do
    if c.evType == 'pb' and c.chan == chan then
      out[#out + 1] = { ppq = c.ppq, val = c.val, shape = c.shape, plain = c.plain }
    end
  end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
  return out
end
local function pbSeatAt(dump, chan, ppq)
  for _, c in ipairs(pbSeatsOf(dump, chan)) do if c.ppq == ppq then return c end end
end

-- A slide host (pitch 60, lane 1) gliding into a following lane-1 note. The host
-- window ends at that next note's onset (240), so snap 15 -> arrival at ppq 225.
local function addSlidePair(h, nextPitch, nextDetune)
  h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
                  detune = 0, delay = 0, lane = 1,
                  fx = { { kind = 'slide', over = { 1, 2 }, target = 'next' } } })
  h.tm:addEvent({ evType = 'note', ppq = 240, endppq = 480, chan = 1, pitch = nextPitch, vel = 100,
                  detune = nextDetune or 0, delay = 0, lane = 1 })
  h.tm:flush()
end

return {

  ----- Glide-in emission: arrives at the interval, re-centres at the handoff

  {
    name = 'slide seats a glide-in pb stream that arrives at the interval and re-centres at the handoff',
    run = function(harness)
      local h = harness.mk()
      addSlidePair(h, 61)            -- +100c, within pbRange 2 (200c ceiling)
      local dump  = h.fm:dump()
      local seats = pbSeatsOf(dump, 1)
      t.truthy(#seats >= 3, 'a glide-in seat stream is emitted')
      for _, s in ipairs(seats) do t.eq(s.plain, true, 'seats are markerless (route-by-window)') end
      t.eq(pbSeatAt(dump, 1, 0).val,   centsToRaw(0),   'starts flat at centre')
      t.eq(pbSeatAt(dump, 1, 225).val, centsToRaw(100), 'arrives at the +100c interval before the handoff')
      local last = seats[#seats]
      t.eq(last.ppq, 240,           'terminal seat sits at the next-note onset (closed span)')
      t.eq(last.val, centsToRaw(0), 're-centred at the handoff (no residual channel bend)')
    end,
  },

  ----- target='next' resolves the actual next note, detune included

  {
    name = 'slide interval includes the next note detune (wire path)',
    run = function(harness)
      local h = harness.mk()
      addSlidePair(h, 60, 50)       -- same pitch, 50c sharp -> a 50c glide
      t.eq(pbSeatAt(h.fm:dump(), 1, 225).val, centsToRaw(50), 'a 50c-sharp next note yields a 50c glide')
    end,
  },

  ----- target='next' resolves the host's own lane, not lane 1

  {
    name = 'slide target=next resolves the next note in the host lane, not lane 1',
    run = function(harness)
      local h = harness.mk()
      -- Host on lane 2; a nearer lane-1 note must NOT be chosen as "next".
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
                      detune = 0, delay = 0, lane = 2,
                      fx = { { kind = 'slide', over = { 1, 2 }, target = 'next' } } })
      h.tm:addEvent({ evType = 'note', ppq = 240, endppq = 480, chan = 1, pitch = 72, vel = 100,
                      detune = 0, delay = 0, lane = 1 })   -- decoy: +1200c if lane-1 were probed
      h.tm:addEvent({ evType = 'note', ppq = 240, endppq = 480, chan = 1, pitch = 61, vel = 100,
                      detune = 0, delay = 0, lane = 2 })   -- the real same-lane next: +100c
      h.tm:flush()
      t.eq(pbSeatAt(h.fm:dump(), 1, 225).val, centsToRaw(100),
        'glides to the +100c lane-2 successor, not the +1200c lane-1 decoy')
    end,
  },

  ----- pb clamp + regeneration under a pbRange change

  {
    name = 'slide clamps to the pb ceiling and regenerates when pbRange widens',
    run = function(harness)
      local h = harness.mk()
      addSlidePair(h, 67)           -- +700c
      t.eq(pbSeatAt(h.fm:dump(), 1, 225).val, centsToRaw(200, 2),
        'pbRange 2: the 700c interval clamps to the 200c ceiling')

      h.cm:assign('transient', { pbRange = 12 })
      h.tm:rebuild()
      t.eq(pbSeatAt(h.fm:dump(), 1, 225).val, centsToRaw(700, 12),
        'pbRange 12: the full 700c interval now fits, unclamped')
    end,
  },

  ----- No next note -> no seats (target='next' cannot resolve)

  {
    name = 'a lone slide host with no following note emits no pb seats',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
                      detune = 0, delay = 0, lane = 1,
                      fx = { { kind = 'slide', over = { 1, 2 }, target = 'next' } } })
      h.tm:flush()
      t.eq(#pbSeatsOf(h.fm:dump(), 1), 0, 'no next note: no seats')
    end,
  },

  ----- G4 — round-trip stability (frame / rounding tripwire)

  {
    name = 'G4: slide pb seat stream is byte-identical across flush -> rebuild -> flush (swing + delay)',
    run = function(harness)
      local h = harness.mk{
        config = { project = { swings = { ['c58'] = classic58 } } },
        data   = { swing = { global = 'c58' } },
      }
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
                      detune = 0, delay = 500, lane = 1,
                      fx = { { kind = 'slide', over = { 1, 2 }, target = 'next' } } })
      h.tm:addEvent({ evType = 'note', ppq = 240, endppq = 480, chan = 1, pitch = 61, vel = 100,
                      detune = 0, delay = 500, lane = 1 })
      h.tm:flush()

      local before = pbSeatsOf(h.fm:dump(), 1)
      t.truthy(#before > 0, 'seats present (non-vacuous)')
      h.tm:rebuild(); h.tm:flush()
      t.deepEq(pbSeatsOf(h.fm:dump(), 1), before, 'no seat churn across the round trip')
    end,
  },

  ----- Projection — the derived seats never surface as an editable cc lane

  {
    name = 'slide seats never surface as a visible cc column',
    run = function(harness)
      local h = harness.mk()
      addSlidePair(h, 61)
      t.falsy(next(h.tm:getChannel(1).columns.ccs or {}), 'no carrier cc column (carrier retired)')
    end,
  },

  ----- N-stream overlap — vibrato and slide on one host sum into one pb stream

  {
    name = 'vibrato and slide on one host sum into a single pb seat stream (N-stream overlap)',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
                      detune = 0, delay = 0, lane = 1,
                      fx = { { kind = 'vibrato', period = { 1, 4 }, depth = 30, onset = 0 },
                             { kind = 'slide', over = { 1, 2 }, target = 'next' } } })
      h.tm:addEvent({ evType = 'note', ppq = 240, endppq = 480, chan = 1, pitch = 61, vel = 100,
                      detune = 0, delay = 0, lane = 1 })
      h.tm:flush()

      local dump = h.fm:dump()
      t.truthy(#pbSeatsOf(dump, 1) > 0, 'one summed seat stream, not two carriers')
      t.eq(pbSeatAt(dump, 1, 15).val,  centsToRaw(30), 'at the vibrato extremum the slide is still 0 -> +30')
      t.eq(pbSeatAt(dump, 1, 225).val, centsToRaw(70), 'slide +100 and vibrato -30 sum to +70 at the arrival')
    end,
  },

  ----- Disjoint windows each seat their own pb span

  {
    name = 'disjoint vibrato and slide windows each seat their own pb span',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
                      detune = 0, delay = 0, lane = 1,
                      fx = { { kind = 'vibrato', period = { 1, 4 }, depth = 30, onset = 0 } } })
      h.tm:addEvent({ evType = 'note', ppq = 240, endppq = 480, chan = 1, pitch = 62, vel = 100,
                      detune = 0, delay = 0, lane = 1,
                      fx = { { kind = 'slide', over = { 1, 2 }, target = 'next' } } })
      h.tm:addEvent({ evType = 'note', ppq = 480, endppq = 720, chan = 1, pitch = 64, vel = 100,
                      detune = 0, delay = 0, lane = 1 })
      h.tm:flush()

      local dump = h.fm:dump()
      t.eq(pbSeatAt(dump, 1, 15).val, centsToRaw(30), 'the vibrato window seats +30 at its extremum')
      t.truthy(pbSeatAt(dump, 1, 465),                'the slide window seats its arrival at ppq 465')
    end,
  },

}
