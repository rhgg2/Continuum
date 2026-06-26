-- Note macros, v2: region hosts (Track A1). The N=0 case -- an fxRegion
-- carrying a continuous fx (vibrato) emits a channel-wide pb carrier with NO
-- host note. Proves the generator-side region substrate end to end through the
-- existing carrier path: region storage (ds), the 4.6 producer split,
-- reconcile, and G4 round-trip stability. see design/note-macros-v2.md
local t    = require('support')
local util = require('util')

local DELTA_MSB = 20   -- coldest carrier code; no authored cc columns here

-- depth 30c, period 1/4 QN: at res 240 one cycle = 60 ticks; sine extrema at
-- ppqL 15 (peak) / 45 (trough); stream anchored 0 at both window ends.
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

-- A region is channel x ppq span + fx; no host note. Inject via ds, then rebuild.
local function injectRegion(h, over)
  local region = { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240, fx = vib30 }
  for k, v in pairs(over or {}) do region[k] = v end
  h.ds:assign('fxRegions', { region })
  h.tm:rebuild()
end

local function anyNoteOnChan(h, chan)
  for _, col in ipairs(h.tm:getChannel(chan).columns.notes or {}) do
    if #col.events > 0 then return true end
  end
  return false
end

return {

  ----- N=0 -- a region with no host note still drives the channel pb carrier

  {
    name = 'fx region (N=0): vibrato over a span emits a free-LFO carrier with no host note',
    run = function(harness)
      local h = harness.mk()
      injectRegion(h)
      local dump = h.fm:dump()
      local cs   = carriersOf(dump, 1)
      t.truthy(#cs >= 8, 'a multi-breakpoint carrier stream is emitted from the region alone')
      t.eq(carrierAt(dump, 1, 0).val,  carrierVal(0),   'zero crossing -> centre')
      t.eq(carrierAt(dump, 1, 15).val, carrierVal(30),  'peak  -> +depth cents')
      t.eq(carrierAt(dump, 1, 45).val, carrierVal(-30), 'trough -> -depth cents')
      t.falsy(anyNoteOnChan(h, 1), 'no host note exists -- the LFO is sourced purely by the region')
    end,
  },

  ----- Window end re-centres (channel-wide carrier, region-sourced)

  {
    name = 'fx region: carrier returns to centre at the region window end',
    run = function(harness)
      local h = harness.mk()
      injectRegion(h)
      local cs   = carriersOf(h.fm:dump(), 1)
      local last = cs[#cs]
      t.eq(last.ppq, 240, 'terminal breakpoint sits at the region window end')
      t.eq(last.val, carrierVal(0), 'terminal value is centre -- no residual channel bend')
    end,
  },

  ----- G4 -- round-trip stability

  {
    name = 'G4: region carrier stream is byte-identical across rebuild -> flush',
    run = function(harness)
      local h = harness.mk()
      injectRegion(h)
      local before = carriersOf(h.fm:dump(), 1)
      t.truthy(#before > 0, 'carriers present (non-vacuous)')
      h.tm:rebuild(); h.tm:flush()
      t.deepEq(carriersOf(h.fm:dump(), 1), before, 'no carrier churn across the round trip')
    end,
  },

  ----- G4-float -- carrier churn guard for a region source (canon path)

  {
    name = 'G4-float: a no-change rebuild re-adds no carriers for a region source',
    run = function(harness)
      local h = harness.mk{ floatPpq = true }
      injectRegion(h)
      t.truthy(#carriersOf(h.fm:dump(), 1) > 0, 'carriers present (non-vacuous)')

      local adds, realAdd = 0, h.fm.add
      h.fm.add = function(self, e)
        if e and e.evType == 'cc' and e.cc == DELTA_MSB then adds = adds + 1 end
        return realAdd(self, e)
      end
      h.tm:rebuild()
      t.eq(adds, 0, 'steady-state rebuild rewrites no carriers (no float-ppq churn)')
    end,
  },

  ----- G2 -- region removal leaves no carrier

  {
    name = 'G2: removing the region leaves no carrier after reconcile',
    run = function(harness)
      local h = harness.mk()
      injectRegion(h)
      t.truthy(#carriersOf(h.fm:dump(), 1) > 0, 'carriers present with the region')

      h.ds:assign('fxRegions', {})
      h.tm:rebuild()
      t.eq(#carriersOf(h.fm:dump(), 1), 0, 'no carrier survives region removal')
    end,
  },

}
