-- Note macros v2: region hosts. The N=0 vibrato carrier proves the generator-side substrate
-- (ds, 4.6 producer split, reconcile, G4 round-trip). see design/note-macros-v2.md
local t          = require('support')
local util       = require('util')
local generators = require('generators')

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

----- Arp (A3): replace parks members off the take; augment keeps them sounding

local arpUp = { { kind = 'arp', period = { 1, 4 }, dir = 'up' } }   -- step 60 at res 240

local function addNote(h, over)
  local n = { evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
              vel = 100, detune = 0, delay = 0, lane = 1 }
  for k, v in pairs(over or {}) do n[k] = v end
  h.tm:addEvent(n); h.tm:flush()
end

local function injectArp(h, over)
  local region = { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240, fx = arpUp }
  for k, v in pairs(over or {}) do region[k] = v end
  h.ds:assign('fxRegions', { region })
  h.tm:rebuild()
end

-- Derived notes the region produced -- routed out of columns, tagged with the region
-- uuid. Sorted by onset then lane; identity swing, so ppq == the logical step time.
local function derivedNotes(h)
  local out = {}
  for _, n in ipairs(h.fm:dump().notes) do
    if n.evType == 'note' and n.derived == 'fxr-1' then
      out[#out + 1] = { ppq = n.ppq, pitch = n.pitch, lane = n.lane }
    end
  end
  table.sort(out, function(a, b)
    if a.ppq ~= b.ppq then return a.ppq < b.ppq end
    return a.lane < b.lane
  end)
  return out
end

local function field(ns, k) local v = {} for i, n in ipairs(ns) do v[i] = n[k] end return v end

-- Authored (non-derived) note pitches still sounding in the take, sorted. Empty when a
-- replace region has parked the whole chord off-take.
local function authoredPitches(h)
  local out = {}
  for _, n in ipairs(h.fm:dump().notes) do
    if n.evType == 'note' and not n.derived then out[#out + 1] = n.pitch end
  end
  table.sort(out)
  return out
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

  ----- Replace (default): members park off the take; the arp is the sole sounding voice

  {
    name = 'replace: arp over a held triad packs into lane 1; the chord parks off the take',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, lane = 1 })
      addNote(h, { pitch = 64, lane = 2 })
      addNote(h, { pitch = 67, lane = 3 })
      injectArp(h)
      local ns = derivedNotes(h)
      t.deepEq(field(ns, 'pitch'), { 60, 64, 67, 60 }, 'ascending cycle through the triad')
      t.deepEq(field(ns, 'lane'),  { 1, 1, 1, 1 },
        'members are parked, so no lane is occupied -- the voice packs into lane 1')
      t.deepEq(authoredPitches(h), {}, 'the chord is parked off the take -- only the arp sounds')
    end,
  },

  {
    name = 'replace: arp samples the playing notes continuously, with no collision nudge',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, ppq = 0,   endppq = 240, lane = 1 })   -- sounds throughout
      addNote(h, { pitch = 67, ppq = 120, endppq = 240, lane = 2 })   -- enters mid-window
      injectArp(h)
      local ns = derivedNotes(h)
      t.deepEq(field(ns, 'ppq'),   { 0, 60, 120, 180 },
        'one hit per step from the window start -- the parked C no longer collides at ppq 0')
      t.deepEq(field(ns, 'pitch'), { 60, 60, 60, 67 },
        '67 is silent until 120; the first two steps are 60, the cycle reaches it once it sounds')
    end,
  },

  {
    name = 'replace: a parked member tail is realised against its same-lane successor',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, ppq = 0,   endppq = 240, lane = 1 })   -- authored overlap...
      addNote(h, { pitch = 64, ppq = 120, endppq = 240, lane = 1 })   -- ...clips 60 to [0,120)
      injectArp(h)
      t.deepEq(field(derivedNotes(h), 'pitch'), { 60, 60, 64, 64 },
        '60 realises to [0,120) against its lane successor, so 64 sounds alone from 120 -- not a 60/64 cycle')
    end,
  },

  {
    name = 'replace husk (no kinds) parks nothing -- its members keep sounding',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, lane = 1 })
      injectArp(h, { fx = {} })   -- a replace region with no generator: an inert husk
      t.deepEq(authoredPitches(h), { 60 }, 'the covered note is not parked -- nothing replaces it')
    end,
  },

  {
    name = 'replace: removing the region restores the parked chord to the take',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, lane = 1 })
      addNote(h, { pitch = 64, lane = 2 })
      addNote(h, { pitch = 67, lane = 3 })
      injectArp(h)
      t.deepEq(authoredPitches(h), {}, 'chord parked while the region is present')
      t.deepEq(field(derivedNotes(h), 'lane'), { 1, 1, 1, 1 },
        'parking frees lanes 1-3, so the arp packs to lane 1 -- the same-pitch nudge dissolves')

      h.ds:assign('fxRegions', {})
      h.tm:rebuild()
      t.deepEq(authoredPitches(h), { 60, 64, 67 }, 'the chord is restored to the take')
      t.eq(#derivedNotes(h), 0, 'no arp survives the region removal')
    end,
  },

  {
    name = 'G4: replace arp + parked chord are byte-identical across rebuild -> flush',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, lane = 1 })
      addNote(h, { pitch = 64, lane = 2 })
      addNote(h, { pitch = 67, lane = 3 })
      injectArp(h)
      local before = derivedNotes(h)
      t.eq(#before, 4, 'derived present (non-vacuous)')
      h.tm:rebuild(); h.tm:flush()
      t.deepEq(derivedNotes(h),    before, 'no derived churn across the round trip')
      t.deepEq(authoredPitches(h), {},     'the chord stays parked across the round trip')
    end,
  },

  ----- Augment by kind: a continuous region leaves its members sounding (no parking)

  {
    name = 'augment by kind: a continuous (vibrato) region leaves its covered notes sounding',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, ppq = 0, endppq = 240, lane = 1 })
      injectRegion(h)   -- vibrato over [0,240) covers the note -- augment, so it is not parked
      t.deepEq(authoredPitches(h), { 60 }, 'the covered note keeps sounding -- a continuous kind augments')
      t.truthy(#carriersOf(h.fm:dump(), 1) > 0, 'and the vibrato carrier is present over the span')
    end,
  },

  ----- Discrete N=0: an arp over a silent span is rest, not a stuck voice

  {
    name = 'arp over a span with no sounding notes emits nothing',
    run = function(harness)
      local h = harness.mk()
      injectArp(h)
      t.eq(#derivedNotes(h), 0, 'no members -> no derived notes (every step rests)')
    end,
  },

  ----- A4: the producer exposes the windowed channel as typed input streams

  {
    name = 'fx region: the producer hands the generator notes/pas/ccs/ats input streams',
    run = function(harness)
      local h = harness.mk()
      -- A covered note (so a PA can ride its column) plus authored cc / channel-AT / poly-AT in
      -- the window. Identity swing in the harness, so ppq == ppqL.
      addNote(h, { pitch = 60, ppq = 0, endppq = 240, lane = 1 })
      h.tm:addEvent({ evType = 'cc', ppq = 60,  chan = 1, cc = 74, val = 50 })
      h.tm:addEvent({ evType = 'at', ppq = 180, chan = 1, val = 33 })
      h.tm:addEvent({ evType = 'pa', ppq = 120, chan = 1, pitch = 60, vel = 77 })
      h.tm:flush()

      -- A spec-only capture kind: augment (parks nothing), records the host it is handed.
      local captured
      generators.kinds.capture = {
        expand = function(host) captured = host; return { notes = {}, delta = {} } end,
        mode = 'augment', dest = 'pb', label = 'Capture', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240,
                                   fx = { { kind = 'capture' } } } })
      h.tm:rebuild()
      generators.kinds.capture = nil   -- restore before asserting (generators is a shared module)

      t.truthy(captured, 'the capture kind ran and recorded its host')
      t.deepEq(captured.pas, { { ppqL = 120, pitch = 60, vel = 77 } }, 'the PA rides into host.pas')
      t.deepEq(captured.ccs[74], { { ppqL = 60, val = 50 } }, 'authored cc 74 buckets into host.ccs')
      t.deepEq(captured.ats, { { ppqL = 180, val = 33 } }, 'channel aftertouch into host.ats')
      t.deepEq(field(captured.notes, 'pitch'), { 60 }, 'the covered note is the membership (host.notes)')
    end,
  },

  {
    name = 'fx region: host.pb carries authored pb breakpoints, excluding absorber fakes',
    run = function(harness)
      local h = harness.mk()
      addNote(h)   -- lane-1 note 60 over [0,240); its presence makes I2a seat an absorber fake at ppq 0
      h.tm:addEvent({ evType = 'pb', ppq = 60, chan = 1, val = 50 })   -- val is cents (the um is cents-native)
      h.tm:flush()

      local captured
      generators.kinds.capture = {
        expand = function(host) captured = host; return { notes = {}, delta = {} } end,
        mode = 'augment', dest = 'pb', label = 'Capture', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240,
                                   fx = { { kind = 'capture' } } } })
      h.tm:rebuild()
      generators.kinds.capture = nil

      t.truthy(captured, 'the capture kind ran and recorded its host')
      t.deepEq(captured.pb, { { ppqL = 60, cents = 50 } },
        'the authored pb breakpoint rides into host.pb; the absorber fake at ppq 0 is excluded')
    end,
  },

}
