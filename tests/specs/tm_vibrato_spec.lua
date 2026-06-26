-- Note macros, v1: vibrato (continuous). Toy carrier fixed at cc=20.
-- Pins carrier emission (cents -> 14-bit pb units), G4 round-trip, G2 both
-- directions, regeneration under pbRange, lane-1-only, and routing-out.
-- see design/archive/note-macros.md § Continuous realisation

local t    = require('support')
local util = require('util')

local classic58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }
local DELTA_MSB = 20

-- depth 30c, period 1/4 QN: at res 240 one cycle = 60 ticks; breakpoints at
-- sine extrema => peak at ppqL 15, trough at 45; stream anchored 0 at both ends.
local vib30 = { { kind = 'vibrato', period = { 1, 4 }, depth = 30, onset = 0 } }

local function centsToRaw(cents, pbRange)
  return util.round(cents * 8192 / ((pbRange or 2) * 100))
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

-- Carriers at an arbitrary cc code (carriersOf is pinned to the default 20).
local function codeCarriers(dump, chan, code)
  local out = {}
  for _, c in ipairs(dump.ccs) do
    if c.evType == 'cc' and c.cc == code and c.chan == chan then
      out[#out + 1] = { ppq = c.ppq, val = c.val, shape = c.shape }
    end
  end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
  return out
end

local function addVibHost(h, over)
  local note = { evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                 vel = 100, detune = 0, delay = 0, lane = 1, fx = vib30 }
  for k, v in pairs(over or {}) do note[k] = v end
  h.tm:addEvent(note)
  h.tm:flush()
end

return {

  ----- Emission: cents -> 14-bit pb units, carried as fixed-point

  {
    name = 'vibrato emits carrier ccs at cc=20 carrying 14-bit pb units (cents -> fixed-point)',
    run = function(harness)
      local h = harness.mk()
      addVibHost(h)
      local dump = h.fm:dump()
      local cs   = carriersOf(dump, 1)
      t.truthy(#cs >= 8, 'a multi-breakpoint carrier stream is emitted')
      for _, c in ipairs(cs) do t.eq(c.shape, 'slow', 'breakpoints are slow-shaped (half-cosine bridge)') end
      t.eq(carrierAt(dump, 1, 0).val,  carrierVal(0),   'zero crossing -> 8192/128')
      t.eq(carrierAt(dump, 1, 15).val, carrierVal(30),  'peak  -> +depth cents in pb units')
      t.eq(carrierAt(dump, 1, 45).val, carrierVal(-30), 'trough -> -depth cents in pb units')
    end,
  },

  ----- Window end re-centres the channel-wide carrier (no residual bend)

  {
    name = 'vibrato carrier returns to centre at the window end (no residual channel bend)',
    run = function(harness)
      local h = harness.mk()
      addVibHost(h)
      local cs   = carriersOf(h.fm:dump(), 1)
      local last = cs[#cs]
      t.eq(last.ppq, 240, 'terminal breakpoint sits at the host window end')
      t.eq(last.val, carrierVal(0), 'terminal value is centre -- delta 0, carrier re-centred')
    end,
  },

  ----- Take start re-centres the carrier (CC chase is safe across loop/seek)

  {
    name = 'carrier is anchored to centre at take start (chase-safe before the first host)',
    run = function(harness)
      local h = harness.mk()
      addVibHost(h, { ppq = 120, endppq = 240 })
      local first = carriersOf(h.fm:dump(), 1)[1]
      t.eq(first.ppq, 0, 'a centre anchor precedes the host window at take start')
      t.eq(first.val, carrierVal(0), 'take-start anchor is centre (delta 0)')
    end,
  },

  ----- G4 — round-trip stability (FIRST: frame/rounding tripwire)

  {
    name = 'G4: vibrato carrier stream is byte-identical across flush -> rebuild -> flush (swing + delay)',
    run = function(harness)
      local h = harness.mk{
        config = { project = { swings = { ['c58'] = classic58 } } },
        data   = { swing = { global = 'c58' } },
      }
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                      vel = 100, detune = 0, delay = 500, lane = 1, fx = vib30 })
      h.tm:flush()

      local before = carriersOf(h.fm:dump(), 1)
      t.truthy(#before > 0, 'carriers present (non-vacuous)')
      h.tm:rebuild()
      h.tm:flush()
      local after = carriersOf(h.fm:dump(), 1)
      t.deepEq(after, before, 'no carrier churn across the round trip')
    end,
  },

  ----- G4-float — carrier churn guard (the canon the structural fxKey has)
  -- REAPER cc ppq is float; predicted is int. Without canon() they stringify apart, rewrites whole stream. floatPpq makes fake mm mirror REAPER so the skew bites.

  {
    name = 'G4-float: a no-change rebuild re-adds no carrier events (carrier key canon)',
    run = function(harness)
      local h = harness.mk{ floatPpq = true }
      addVibHost(h)
      t.truthy(#carriersOf(h.fm:dump(), 1) > 0, 'carriers present (non-vacuous)')

      -- Count carrier-code adds across one steady-state rebuild: churn re-adds the
      -- whole stream, the fix re-adds nothing.
      local carrierAdds, realAdd = 0, h.fm.add
      h.fm.add = function(self, t)
        if t and t.evType == 'cc' and t.cc == DELTA_MSB then carrierAdds = carrierAdds + 1 end
        return realAdd(self, t)
      end

      h.tm:rebuild()
      t.eq(carrierAdds, 0, 'steady-state rebuild rewrites no carriers (no float-ppq churn)')
    end,
  },

  ----- G2 — both directions

  {
    name = 'G2: fx present yields carriers; fx removed leaves none after reconcile',
    run = function(harness)
      local h = harness.mk()
      addVibHost(h)
      t.truthy(#carriersOf(h.fm:dump(), 1) > 0, 'carriers present with fx')

      local hostEvt = h.tm:getChannel(1).columns.notes[1].events[1]
      h.tm:assignEvent(hostEvt, { fx = util.REMOVE })
      h.tm:flush()
      t.eq(#carriersOf(h.fm:dump(), 1), 0, 'no carrier survives fx removal')
    end,
  },

  ----- Regeneration — the single cents->raw site re-runs under config change

  {
    name = 'regeneration: a pbRange change rescales carrier values (cents -> raw at flush)',
    run = function(harness)
      local h = harness.mk()
      addVibHost(h)
      t.eq(carrierAt(h.fm:dump(), 1, 15).val, carrierVal(30, 2), 'peak under pbRange 2')

      h.cm:assign('transient', { pbRange = 4 })
      h.tm:rebuild()
      t.eq(carrierAt(h.fm:dump(), 1, 15).val, carrierVal(30, 4),
        'wider pb range -> smaller raw delta for the same cents')
    end,
  },

  ----- Any lane — a continuous gesture bends the channel pb regardless of host lane

  {
    name = 'vibrato on a higher lane emits a carrier (channel-wide gesture, lane-blind)',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                      vel = 100, detune = 0, delay = 0, lane = 1 })
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 67,
                      vel = 100, detune = 0, delay = 0, lane = 2, fx = vib30 })
      h.tm:flush()
      t.truthy(#carriersOf(h.fm:dump(), 1) > 0, 'a higher-lane vibrato still bends the channel pb')
    end,
  },

  ----- Parse routing — the carrier never surfaces as a user cc lane

  {
    name = 'carrier code is routed out of cc columns (never a visible cc lane)',
    run = function(harness)
      local h = harness.mk()
      addVibHost(h)
      local ccCols = h.tm:getChannel(1).columns.ccs
      t.falsy(ccCols[DELTA_MSB], 'no cc-20 column built from carrier events')
    end,
  },

  ----- Relocation -- a cc column on the carrier code shifts it to the next free pair

  {
    name = 'relocation: a cc column authored on the carrier code shifts the carrier off it',
    run = function(harness)
      local h = harness.mk()
      addVibHost(h)
      t.truthy(#carriersOf(h.fm:dump(), 1) > 0, 'carrier parks at the coldest code (20)')

      -- Author an (empty) cc-20 column: the relocation signal, ahead of any event.
      h.ds:assign('extraColumns', { [1] = { notes = 1, ccs = { [20] = true } } })
      h.tm:rebuild()

      t.eq(#codeCarriers(h.fm:dump(), 1, 20), 0, 'carrier vacated the now-authored code 20')
      local at21 = codeCarriers(h.fm:dump(), 1, 21)
      t.truthy(#at21 > 0, 'carrier relocated to the next free pair (21)')

      -- G4 still holds at the relocated code.
      h.tm:rebuild(); h.tm:flush()
      t.deepEq(codeCarriers(h.fm:dump(), 1, 21), at21, 'relocated carrier is stable across the round trip')
    end,
  },

}
