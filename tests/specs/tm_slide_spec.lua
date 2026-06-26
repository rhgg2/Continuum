-- Slide spec (note macros v1, portamento): pins carrier emission, target='next' resolution, pb clamp + regeneration, G4 round-trip.
-- see design/note-macros.md § Continuous realisation

local t    = require('support')
local util = require('util')

local classic58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }
local DELTA_MSB = 20

local function centsToRaw(cents, pbRange)
  return util.clamp(util.round(cents * 8192 / ((pbRange or 2) * 100)), -8192, 8191)
end
local function carrierVal(cents, pbRange) return (8192 + centsToRaw(cents, pbRange)) / 128 end

local function carriersOf(dump, chan)
  local out = {}
  for _, c in ipairs(dump.ccs) do
    if c.evType == 'cc' and c.cc == DELTA_MSB and c.chan == chan then
      out[#out + 1] = { ppq = c.ppq, val = c.val, shape = c.shape }
    end
  end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
  return out
end
local function carrierAt(dump, chan, ppq)
  for _, c in ipairs(carriersOf(dump, chan)) do if c.ppq == ppq then return c end end
end

-- Carriers at an arbitrary code (carriersOf is pinned to the default 20).
local function codeCarriers(dump, chan, code)
  local out = {}
  for _, c in ipairs(dump.ccs) do
    if c.evType == 'cc' and c.cc == code and c.chan == chan then out[#out + 1] = c end
  end
  return out
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
    name = 'slide emits a glide-in carrier that arrives at the interval and re-centres at the handoff',
    run = function(harness)
      local h = harness.mk()
      addSlidePair(h, 61)            -- +100c, within pbRange 2 (200c ceiling)
      local dump = h.fm:dump()
      local cs   = carriersOf(dump, 1)
      t.truthy(#cs >= 3, 'a glide-in stream is emitted')
      t.eq(carrierAt(dump, 1, 0).val,   carrierVal(0),   'starts flat at centre')
      t.eq(carrierAt(dump, 1, 225).val, carrierVal(100), 'arrives at the +100c interval before the handoff')
      local last = cs[#cs]
      t.eq(last.ppq, 240,           'terminal breakpoint sits at the next-note onset')
      t.eq(last.val, carrierVal(0), 're-centred at the handoff (no residual channel bend)')
    end,
  },

  ----- target='next' resolves the actual next note, detune included

  {
    name = 'slide interval includes the next note detune (wire path)',
    run = function(harness)
      local h = harness.mk()
      addSlidePair(h, 60, 50)       -- same pitch, 50c sharp -> a 50c glide
      t.eq(carrierAt(h.fm:dump(), 1, 225).val, carrierVal(50), 'a 50c-sharp next note yields a 50c glide')
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
      t.eq(carrierAt(h.fm:dump(), 1, 225).val, carrierVal(100),
        'glides to the +100c lane-2 successor, not the +1200c lane-1 decoy')
    end,
  },

  ----- pb clamp + regeneration under a pbRange change

  {
    name = 'slide clamps to the pb ceiling and regenerates when pbRange widens',
    run = function(harness)
      local h = harness.mk()
      addSlidePair(h, 67)           -- +700c
      t.eq(carrierAt(h.fm:dump(), 1, 225).val, carrierVal(200, 2),
        'pbRange 2: the 700c interval clamps to the 200c ceiling')

      h.cm:assign('transient', { pbRange = 12 })
      h.tm:rebuild()
      t.eq(carrierAt(h.fm:dump(), 1, 225).val, carrierVal(700, 12),
        'pbRange 12: the full 700c interval now fits, unclamped')
    end,
  },

  ----- No next note -> no carrier (target='next' cannot resolve)

  {
    name = 'a lone slide host with no following note emits no carrier',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
                      detune = 0, delay = 0, lane = 1,
                      fx = { { kind = 'slide', over = { 1, 2 }, target = 'next' } } })
      h.tm:flush()
      t.eq(#carriersOf(h.fm:dump(), 1), 0, 'no next note: the carrier stays untouched')
    end,
  },

  ----- G4 — round-trip stability (frame / rounding tripwire)

  {
    name = 'G4: slide carrier stream is byte-identical across flush -> rebuild -> flush (swing + delay)',
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

      local before = carriersOf(h.fm:dump(), 1)
      t.truthy(#before > 0, 'carriers present (non-vacuous)')
      h.tm:rebuild(); h.tm:flush()
      t.deepEq(carriersOf(h.fm:dump(), 1), before, 'no carrier churn across the round trip')
    end,
  },

  ----- Parse routing — the carrier never surfaces as a user cc lane

  {
    name = 'slide carrier code is routed out of cc columns (never a visible cc lane)',
    run = function(harness)
      local h = harness.mk()
      addSlidePair(h, 61)
      t.falsy(h.tm:getChannel(1).columns.ccs[DELTA_MSB], 'no cc-20 column built from carrier events')
    end,
  },

  ----- Coexistence — overlapping carriers split, disjoint carriers share (per-target colouring)

  {
    name = 'vibrato and slide on one host take distinct carriers (overlap -> summed at the node)',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
                      detune = 0, delay = 0, lane = 1,
                      fx = { { kind = 'vibrato', period = { 1, 4 }, depth = 30, onset = 0 },
                             { kind = 'slide', over = { 1, 2 }, target = 'next' } } })
      h.tm:addEvent({ evType = 'note', ppq = 240, endppq = 480, chan = 1, pitch = 61, vel = 100,
                      detune = 0, delay = 0, lane = 1 })
      h.tm:flush()

      local cf = h.ds:get('fxCarrier')[1]
      t.eq(#cf, 2, 'two overlapping carriers -> two codes')
      t.truthy(cf[1].code ~= cf[2].code, 'distinct codes the node sums into pb')
      t.eq(cf[1].target, 'pb', 'first carrier targets pitchbend')
      t.eq(cf[2].target, 'pb', 'second carrier targets pitchbend')
      t.truthy(#codeCarriers(h.fm:dump(), 1, cf[1].code) > 0, 'first carrier stream present')
      t.truthy(#codeCarriers(h.fm:dump(), 1, cf[2].code) > 0, 'second carrier stream present')
    end,
  },

  {
    name = 'disjoint vibrato then slide on lane 1 share one carrier code (colour reuse)',
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

      local cf = h.ds:get('fxCarrier')[1]
      t.eq(#cf, 1, 'non-overlapping carriers reuse one code')
      local ppqs = {}
      for _, c in ipairs(codeCarriers(h.fm:dump(), 1, cf[1].code)) do ppqs[c.ppq] = true end
      t.truthy(ppqs[15],  'vibrato extremum rides the shared code')
      t.truthy(ppqs[465], 'slide arrival rides the same code')
    end,
  },

}
