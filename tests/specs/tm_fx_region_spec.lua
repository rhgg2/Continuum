-- Note macros v2: region hosts. The N=0 sine pb seat stream proves the generator-side substrate
-- (ds, 4.6 producer split, reconcile, G4 round-trip). see docs/generators.md
local t          = require('support')
local util       = require('util')
local generators = require('generators')

-- depth 30c, period 1/4 QN: at res 240 one cycle = 60 ticks; sine extrema at
-- ppq 15 (peak) / 45 (trough); stream anchored 0 at both window ends.
local sine30 = { { kind = 'sine', period = { 1, 4 }, depth = 30, onset = 0 } }

local function centsToRaw(cents, pbRange)
  return util.round(cents * 8192 / ((pbRange or 2) * 100))
end

local function rawToCents(raw, pbRange)
  return util.round(raw * (pbRange or 2) * 100 / 8192)
end

-- A seat is recognized purely by region membership, on pb and cc alike: anything inside a live region's
-- span, half-open (as production's covered()). The close folds to endppq-1, so the end row is never
-- seat territory. see docs/generators.md § Route-by-window
local function inLiveRegion(h, chan, ppq)
  for _, r in ipairs(h.ds:get('fxRegions') or {}) do
    if r.chan == chan and ppq >= r.startppq and ppq < r.endppq then return true end
  end
  return false
end

-- An authored pb on the wire: one no live pb window covers (a covered pb is a seat). `val` is raw
-- (centsToRaw of wire-cents + detune); `cents` the persisted intent. nil while a window parks it off.
local function authoredPb(h, chan, ppq)
  for _, c in ipairs(h.fm:dump().ccs) do
    if c.evType == 'pb' and c.chan == chan and c.ppq == ppq and not inLiveRegion(h, chan, ppq) then return c end
  end
end

-- The seated curve of a pb-replace region, hidden from columns. Seats are markerless -- there is no
-- marker to filter on; the live window IS their identity. Recognized purely by region membership.
local function derivedPbs(h, chan)
  local out = {}
  for _, c in ipairs(h.fm:dump().ccs) do
    if c.evType == 'pb' and c.chan == chan and inLiveRegion(h, chan, c.ppq) then out[#out + 1] = c end
  end
  return out
end

local function derivedPb(h, chan, ppq)
  for _, c in ipairs(derivedPbs(h, chan)) do if c.ppq == ppq then return c end end
end

-- The wire record at a ppq, window-blind. An authored pb carries a cents sidecar and a logical seat;
-- a generated one has neither -- so this is what tells absorption from survival on a boundary row.
local function wirePb(h, chan, ppq)
  for _, c in ipairs(h.fm:dump().ccs) do
    if c.evType == 'pb' and c.chan == chan and c.ppq == ppq then return c end
  end
end

-- The cc / pb slice of the unified fxParked off-take stash.
local function stashOfType(h, evType)
  local out = {}
  for _, s in ipairs(h.ds:get('fxParked') or {}) do
    if s.evType == evType then out[#out + 1] = s end
  end
  return out
end

-- The seated replace curve on a cc target, hidden from columns. Seats are markerless -- the live region
-- span IS their identity; the authored cc it covers is parked off-take.
local function fillRecords(h, chan, cc)
  local out = {}
  for _, c in ipairs(h.fm:dump().ccs) do
    if c.evType == 'cc' and c.cc == cc and c.chan == chan and inLiveRegion(h, chan, c.ppq) then
      out[#out + 1] = c
    end
  end
  return out
end
local function fillsOf(h, chan, cc)
  local out = {}
  for _, c in ipairs(fillRecords(h, chan, cc)) do
    out[#out + 1] = { ppq = c.ppq, val = c.val, shape = c.shape }
  end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
  return out
end
local function ccFillAt(h, chan, cc, ppq)
  for _, c in ipairs(fillsOf(h, chan, cc)) do if c.ppq == ppq then return c end end
end

-- A non-derived authored cc on the take, outside any live cc-replace window (an in-window cc is a
-- markerless seat, not authored); nil once a window parks the authored cc off.
local function authoredCC(h, chan, cc, ppq)
  for _, c in ipairs(h.fm:dump().ccs) do
    if c.evType == 'cc' and c.cc == cc and c.chan == chan and c.ppq == ppq
       and not c.derived and not inLiveRegion(h, chan, ppq) then return c end
  end
end

-- A region is channel x ppq span + fx; no host note. Inject via ds, then rebuild.
local function injectRegion(h, over)
  local region = { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240, fx = sine30 }
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
      out[#out + 1] = { ppq = n.ppq, pitch = n.pitch, lane = n.lane, vel = n.vel }
    end
  end
  table.sort(out, function(a, b)
    if a.ppq ~= b.ppq then return a.ppq < b.ppq end
    return a.lane < b.lane
  end)
  return out
end

-- The identity an expanded producer carries: its stored region's uuid, qualified by the channel it
-- landed on. see design/global-fx-column.md § Derived identity is stable
local function expanded(uuid, chan) return util.key(uuid, chan) end

-- The notes one producer put on one channel, sorted by onset then lane. A global region's producers
-- differ per channel, so the read names both.
local function derivedFor(h, chan, uuid)
  local out = {}
  for _, n in ipairs(h.fm:dump().notes) do
    if n.evType == 'note' and n.chan == chan and n.derived == uuid then
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

-- The note pitches standing in a channel's note columns -- what the grid shows, as against
-- fm:dump()'s wire content. Note columns also carry re-projected pa cells, so filter on evType.
local function columnPitches(h, chan)
  local out = {}
  for _, col in ipairs(h.tm:getChannel(chan).columns.notes or {}) do
    for _, e in ipairs(col.events) do
      if e.evType == 'note' then out[#out + 1] = e.pitch end
    end
  end
  table.sort(out)
  return out
end

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

-- Every pb standing on the wire in a ppq span, in cents, sorted. Read straight off the dump: the
-- seat helpers above key on a live window, and freeze is the verb that takes the window away.
local function wirePbs(h, chan, fromPpq, toPpq)
  local out = {}
  for _, c in ipairs(h.fm:dump().ccs) do
    if c.evType == 'pb' and c.chan == chan and c.ppq >= fromPpq and c.ppq <= toPpq then
      out[#out + 1] = { ppq = c.ppq, cents = rawToCents(c.val) }
    end
  end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
  return out
end

-- A pb-replace stage seating a crowded collinear ramp: RAMP_N breakpoints 4 cents apart, every one
-- 'linear', so a tolerance of 3 cents may drop the whole interior. sine30 offers the thinner nothing
-- -- its 'slow' extrema are hard keeps. Registers the kind; the caller clears it after the freeze.
local RAMP_N = 25
local function denseRamp()
  generators.kinds.denseRamp = {
    expand = function(stream)
      local startL, endL, delta = stream.window[1], stream.window[2], {}
      for i = 0, RAMP_N - 1 do
        util.add(delta, { ppq = startL + (endL - startL) * i / (RAMP_N - 1),
                          val = i * 4, shape = 'linear' })
      end
      return { notes = {}, delta = delta }
    end,
    mode = 'replace', dest = 'pb', label = 'Dense Ramp', defaults = {}, fields = {},
  }
  return { { kind = 'denseRamp' } }
end

-- A pb-replace stage seating distinguishable values on the window's last two ticks, so both compete for
-- the one tick material may hold once the close takes its own. Steps 40 cents apart:
-- neither is droppable inside tolerance. Registers the kind; the caller clears it after the freeze.
local function edgePair()
  generators.kinds.edgePair = {
    expand = function(stream)
      local startL, endL = stream.window[1], stream.window[2]
      return { notes = {}, delta = {
        { ppq = startL,   val = 0,  shape = 'step' },
        { ppq = endL - 1, val = 40, shape = 'step' },
        { ppq = endL,     val = 80, shape = 'step' },
      } }
    end,
    mode = 'replace', dest = 'pb', label = 'Edge Pair', defaults = {}, fields = {},
  }
  return { { kind = 'edgePair' } }
end

return {

  ----- N=0 -- a region with no host note still seats the channel pb stream

  {
    name = 'fx region (N=0): sine over a span seats a free-LFO pb stream with no host note',
    run = function(harness)
      local h = harness.mk()
      injectRegion(h)
      local seats = derivedPbs(h, 1)
      t.truthy(#seats >= 8, 'a densified pb seat stream is emitted from the region alone')
      t.eq(derivedPb(h, 1, 0).val,  centsToRaw(0),   'zero crossing -> centre')
      t.eq(derivedPb(h, 1, 15).val, centsToRaw(30),  'peak  -> +depth cents')
      t.eq(derivedPb(h, 1, 45).val, centsToRaw(-30), 'trough -> -depth cents')
      t.falsy(anyNoteOnChan(h, 1), 'no host note exists -- the LFO is sourced purely by the region')
    end,
  },

  ----- Window end: every target is handed back before it exits (pb to centre, cc to its own stream)

  {
    name = 'fx region: pb seats re-centre the channel at the region window end',
    run = function(harness)
      local h = harness.mk()
      injectRegion(h)
      local seats = derivedPbs(h, 1)
      table.sort(seats, function(a, b) return a.ppq < b.ppq end)
      local last = seats[#seats]
      t.eq(last.ppq, 239, 'terminal seat folds one tick inside the region window end')
      t.eq(last.val, centsToRaw(0), 'terminal value is centre -- no residual channel bend')
    end,
  },

  {
    name = 'fx region (cc augment): the window end hands the target back to its authored base',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'cc', ppq = 0, chan = 1, cc = 10, val = 20 }); h.tm:flush()
      generators.kinds.ccCap = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 0,  shape = 'step' },
          { ppq = 60,             val = 30, shape = 'step' },
          { ppq = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'augment', dest = 10, label = 'CcCap', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240,
                                   fx = { { kind = 'ccCap' } } } })
      h.tm:rebuild()
      generators.kinds.ccCap = nil

      local fills = fillsOf(h, 1, 10)
      local last  = fills[#fills]
      t.eq(last.ppq, 239, 'the closing seat folds one tick inside the window end')
      t.eq(last.val, 20,  'and returns the target to its authored base -- no residual macro offset')
    end,
  },

  {
    name = 'fx region (cc replace): the window end hands the target back to the stream it took over',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'cc', ppq = 0, chan = 1, cc = 10, val = 20 }); h.tm:flush()
      generators.kinds.ccRep = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 100, shape = 'step' },
        } } end,
        mode = 'replace', dest = 10, label = 'CcRep', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240,
                                   fx = { { kind = 'ccRep' } } } })
      h.tm:rebuild()
      generators.kinds.ccRep = nil

      local fills = fillsOf(h, 1, 10)
      t.eq(fills[1].val, 100, 'the replace curve owns the window interior outright')
      local last = fills[#fills]
      t.eq(last.ppq, 239, 'the closing seat folds one tick inside the window end')
      t.eq(last.val, 20,  'and restores the authored value the region took over')
    end,
  },

  ----- G4 -- round-trip stability

  {
    name = 'G4: region pb seat stream is byte-identical across rebuild -> flush',
    run = function(harness)
      local h = harness.mk()
      injectRegion(h)
      local function sig()
        local out = {}
        for _, c in ipairs(derivedPbs(h, 1)) do out[#out + 1] = { ppq = c.ppq, val = c.val, shape = c.shape } end
        table.sort(out, function(a, b) return a.ppq < b.ppq end)
        return out
      end
      local before = sig()
      t.truthy(#before > 0, 'seats present (non-vacuous)')
      h.tm:rebuild(); h.tm:flush()
      t.deepEq(sig(), before, 'no seat churn across the round trip')
    end,
  },

  ----- G2 -- region removal leaves no pb seat

  {
    name = 'G2: removing the region leaves no pb seat after reconcile',
    run = function(harness)
      local h = harness.mk()
      injectRegion(h)
      local function allPb()
        local n = 0
        for _, c in ipairs(h.fm:dump().ccs) do if c.evType == 'pb' and c.chan == 1 then n = n + 1 end end
        return n
      end
      t.truthy(allPb() > 0, 'seats present with the region')

      h.ds:assign('fxRegions', {})
      h.tm:rebuild()
      t.eq(allPb(), 0, 'no seat survives region removal')
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
    -- A PA rides its host note: when a region parks the host, the PA parks off-take (silent -- stale
    -- PA against a fresh derived stream is meaningless), stashed for unpark, still shown in host lane.
    name = 'replace: a PA under the parked host parks off-take with it, restores on unpark',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, lane = 1 })
      h.tm:addEvent{ evType = 'pa', ppq = 120, chan = 1, pitch = 60, vel = 64, lane = 1, rpb = 2 }
      h.tm:flush()
      injectArp(h)

      local function takePAs()
        local out = {}
        for _, c in ipairs(h.fm:dump().ccs) do if c.evType == 'pa' then out[#out + 1] = c end end
        return out
      end
      local function colPAs()
        local out = {}
        for _, col in ipairs(h.tm:getChannel(1).columns.notes) do
          for _, e in ipairs(col.events) do if e.evType == 'pa' then out[#out + 1] = e end end
        end
        return out
      end

      t.eq(#takePAs(), 0, 'the parked PA left the take -- it no longer sounds against the derived stream')
      local parked = stashOfType(h, 'pa')
      t.eq(#parked, 1, 'the PA rode into the fxParked stash')
      t.eq(parked[1].vel, 64, 'its pressure rode the park')
      t.eq(parked[1].rpb, 2,  'its rpb metadata rode the park')
      t.eq(#colPAs(), 1, 'the parked PA still displays in the host note column')

      h.ds:assign('fxRegions', {})
      h.tm:rebuild()
      local restored = takePAs()
      t.eq(#restored, 1, 'the PA returned to the take on unpark')
      t.eq(restored[1].rpb, 2, 'rpb survived the park round-trip')
      t.eq(#stashOfType(h, 'pa'), 0, 'the stash is empty once the host is back on-take')
    end,
  },

  ----- Phase A: generator output is self-sufficient of mm array order (design/archive/deferred-reindex.md)

  {
    name = 'two rebuilds over an arp region allocate byte-identical derived notes + lanes',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, lane = 1 })
      addNote(h, { pitch = 64, lane = 2 })
      addNote(h, { pitch = 67, lane = 3 })
      injectArp(h)
      local first = derivedNotes(h)
      t.eq(#first, 4, 'arp cycles the triad -- four derived hits')
      h.tm:rebuild()
      local second = derivedNotes(h)
      t.deepEq(second, first, 'a second rebuild is byte-identical -- generator order self-sufficient')
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

  ----- The fx chain: stages fold into the stream in series; order is semantic

  {
    name = 'chain [arp, velPattern]: the pattern accents the arp steps',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, lane = 1 })
      addNote(h, { pitch = 64, lane = 2 })
      addNote(h, { pitch = 67, lane = 3 })
      injectArp(h, { fx = { { kind = 'arp', period = { 1, 4 }, dir = 'up' },
                            { kind = 'velPattern', pattern = { 100, 50 } } } })
      local ns = derivedNotes(h)
      t.deepEq(field(ns, 'pitch'), { 60, 64, 67, 60 },   'the arp itself is unchanged')
      t.deepEq(field(ns, 'vel'),   { 100, 50, 100, 50 }, 'velPattern re-velocities the arp notes per step')
    end,
  },

  {
    name = 'chain [velPattern, arp]: the chord takes the pattern first, the arp reads the folded stream',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, lane = 1 })
      addNote(h, { pitch = 64, lane = 2 })
      addNote(h, { pitch = 67, lane = 3 })
      injectArp(h, { fx = { { kind = 'velPattern', pattern = { 80 } },
                            { kind = 'arp', period = { 1, 4 }, dir = 'up' } } })
      local ns = derivedNotes(h)
      t.deepEq(field(ns, 'pitch'), { 60, 64, 67, 60 }, 'arp cycles the re-velocitied chord')
      t.deepEq(field(ns, 'vel'),   { 80, 80, 80, 80 },
        'the whole chord took step 1 of the pattern before the arp sampled it -- order is semantic')
    end,
  },

  {
    name = 'velPattern alone owns the note stream: the chord parks and re-emits re-velocitied',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, lane = 1 })
      addNote(h, { pitch = 64, lane = 2 })
      injectArp(h, { fx = { { kind = 'velPattern', pattern = { 80 } } } })
      t.deepEq(authoredPitches(h), {}, 'a note-dest chain parks its membership -- ownership, not kind')
      local ns = derivedNotes(h)
      t.deepEq(field(ns, 'pitch'), { 60, 64 }, 'the chain output is the chord itself, re-emitted derived')
      t.deepEq(field(ns, 'vel'),   { 80, 80 }, 'one onset -> the whole chord shares pattern step 1')
    end,
  },

  {
    name = 'bypass: a bypassed stage stays in the chain and contributes nothing',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, lane = 1 })
      addNote(h, { pitch = 64, lane = 2 })
      addNote(h, { pitch = 67, lane = 3 })
      injectArp(h, { fx = { { kind = 'arp', period = { 1, 4 }, dir = 'up' },
                            { kind = 'velPattern', pattern = { 100, 50 }, bypass = true } } })
      local ns = derivedNotes(h)
      t.deepEq(field(ns, 'pitch'), { 60, 64, 67, 60 }, 'the live stage still runs')
      t.deepEq(field(ns, 'vel'),   { 100, 100, 100, 100 },
        'the arp keeps its own velocities -- the bypassed pattern folded nothing in')
    end,
  },

  {
    name = 'bypass: a fully bypassed chain still parks its chord and re-seats it verbatim',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, lane = 1 })
      addNote(h, { pitch = 64, lane = 2 })
      addNote(h, { pitch = 67, lane = 3 })
      injectArp(h, { fx = { { kind = 'arp', period = { 1, 4 }, dir = 'up', bypass = true } } })
      t.deepEq(authoredPitches(h), {},
        'the park predicates ignore the flag -- bypass changes the realisation, never the authored notes')
      local ns = derivedNotes(h)
      t.deepEq(field(ns, 'pitch'), { 60, 64, 67 }, 'the parked chord is re-seated as the chain output')
      t.deepEq(field(ns, 'ppq'),   { 0, 0, 0 },    're-seated verbatim: one onset, not the arp cycle')
    end,
  },

  {
    name = 'replace: a parked member tail is clipped by an on-take note after the region',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, ppq = 0,   endppq = 480, lane = 1 })   -- covered -> parks; authored tail 480
      addNote(h, { pitch = 60, ppq = 240, endppq = 480, lane = 1 })   -- past the window -> stays on the take
      injectArp(h, { endppq = 120 })                                  -- region covers only [0,120)
      local parked
      for _, m in ipairs(h.tm:getChannel(1).parked) do
        if m.pitch == 60 and m.ppq == 0 then parked = m end
      end
      t.truthy(parked, 'the note at onset 0 is parked off the take')
      t.eq(parked.endppqC, 240,
        'the parked tail is clipped by the following on-take note at 240, not left running to its authored ceiling')
    end,
  },

  {
    name = 'replace: a parked member tail is clipped by a parked note in a later region',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, ppq = 0,   endppq = 480, lane = 1 })   -- parked by region A; authored tail 480
      addNote(h, { pitch = 60, ppq = 240, endppq = 480, lane = 1 })   -- parked by region B
      h.ds:assign('fxRegions', {
        { uuid = 'fxr-a', chan = 1, startppq = 0,   endppq = 120, fx = arpUp },
        { uuid = 'fxr-b', chan = 1, startppq = 240, endppq = 360, fx = arpUp },
      })
      h.tm:rebuild()
      local parked
      for _, m in ipairs(h.tm:getChannel(1).parked) do
        if m.pitch == 60 and m.ppq == 0 then parked = m end
      end
      t.truthy(parked, 'the note at onset 0 is parked by region A')
      t.eq(parked.endppqC, 240,
        'region A parked tail is clipped by the region-B parked note at 240')
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

  ----- Parked specs are logical-only and carry the identity the backing addresses by

  {
    name = 'park identity (note): render cell carries chan+uuid; the fxParked stash is logical-only',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, lane = 1 })
      injectArp(h)
      local parked = h.tm:getChannel(1).parked
      t.eq(#parked, 1, 'the covered note parks')
      t.eq(parked[1].chan, 1, 'the render cell knows its channel (the backing addresses by it)')
      t.truthy(parked[1].uuid, 'the render cell carries the durable note uuid')
      local stash = h.ds:get('fxParked')
      t.eq(stash[1].ppq, 0, 'the stash keeps the logical onset')
      t.eq(stash[1].endppq, 240, 'and the authored ceiling -- both in the logical frame')
      t.eq(stash[1].uuid, parked[1].uuid, 'stash and render cell share the durable uuid')
    end,
  },

  {
    name = 'park round-trip carries arbitrary authored metadata, not just whitelisted fields',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, lane = 1, glide = 42 })   -- glide: an authored field no park whitelist names
      injectArp(h)
      t.eq(h.ds:get('fxParked')[1].glide, 42, 'park keeps the authored field in the stash')

      h.ds:assign('fxRegions', {})
      h.tm:rebuild()
      local restored
      for _, n in ipairs(h.fm:dump().notes) do if not n.derived then restored = n end end
      t.eq(restored and restored.glide, 42, 'unpark restores the authored field to the take')
    end,
  },

  {
    name = 'park identity (cc): render cell carries chan+ppq; the fxParkedCC stash is logical-only',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'cc', ppq = 60, chan = 1, cc = 74, val = 30 }); h.tm:flush()
      generators.kinds.ccRep = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 100, shape = 'step' },
        } } end,
        mode = 'replace', dest = 74, label = 'CcRep', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240,
                                   fx = { { kind = 'ccRep' } } } })
      h.tm:rebuild()
      generators.kinds.ccRep = nil
      local parked = h.tm:getChannel(1).parkedCC
      t.eq(#parked, 1, 'the covered cc parks')
      t.eq(parked[1].chan, 1, 'the render cell knows its channel')
      t.eq(parked[1].ppq, 60, 'the render cell carries the logical onset (the backing key)')
      local stash = stashOfType(h, 'cc')
      t.eq(stash[1].ppq, 60, 'the stash keeps the logical onset')
    end,
  },

  ----- Parked edits stage on tm and ride flush (no inline ds write)

  {
    name = 'assignParked (note): edit a parked pitch -> stash updated, still parked, renders the new pitch',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, lane = 1 })
      injectArp(h)
      h.tm:assignParked(h.tm:getChannel(1).parked[1], { pitch = 67 }); h.tm:flush()
      local parked = h.tm:getChannel(1).parked
      t.eq(#parked, 1, 'still parked under the region')
      t.eq(parked[1].pitch, 67, 'the render cell shows the edited pitch')
      t.eq(h.ds:get('fxParked')[1].pitch, 67, 'the stash carries the edit')
      t.deepEq(authoredPitches(h), {}, 'still off the take -- editing did not unpark it')
    end,
  },

  {
    name = 'deleteParked (note): a parked note leaves the stash and is not restored while still covered',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, lane = 1 })
      injectArp(h)
      h.tm:deleteParked(h.tm:getChannel(1).parked[1]); h.tm:flush()
      t.eq(#h.tm:getChannel(1).parked, 0, 'the parked note is gone from the render union')
      t.falsy(h.ds:get('fxParked'), 'the stash empties -- no parked notes remain')
      t.deepEq(authoredPitches(h), {}, 'deleting a parked note does not resurrect it on the take')
    end,
  },

  {
    name = 'addParked (note): typing into a replace window stashes a logical spec (minted uuid), off the take',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, lane = 1 })
      injectArp(h)
      h.tm:addParked({ evType = 'note', chan = 1, lane = 1, ppq = 120, endppq = 240,
                       pitch = 72, vel = 100, detune = 0, delay = 0 })
      h.tm:flush()
      local stash = h.ds:get('fxParked')
      t.eq(#stash, 2, 'the authored 60 and the typed 72 both sit in the stash')
      local typed
      for _, s in ipairs(stash) do if s.pitch == 72 then typed = s end end
      t.truthy(typed, 'the typed note is stashed')
      t.eq(typed.uuid, 'fxp-1', 'a window-authored parked note mints an fxp uuid')
      t.eq(typed.ppq, 120, 'the stashed spec keeps the logical onset it was typed at')
      t.deepEq(authoredPitches(h), {}, 'the typed note never enters the take -- it is parked')
      local pitches = {}
      for _, m in ipairs(h.tm:getChannel(1).parked) do pitches[#pitches + 1] = m.pitch end
      table.sort(pitches)
      t.deepEq(pitches, { 60, 72 }, 'both parked notes render')
    end,
  },

  {
    name = 'parked cc: assignParked then deleteParked edits the off-take cc stash symmetrically',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'cc', ppq = 60, chan = 1, cc = 74, val = 30 }); h.tm:flush()
      generators.kinds.ccRep = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 100, shape = 'step' },
        } } end,
        mode = 'replace', dest = 74, label = 'CcRep', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240,
                                   fx = { { kind = 'ccRep' } } } })
      h.tm:rebuild()

      h.tm:assignParked(h.tm:getChannel(1).parkedCC[1], { val = 81 }); h.tm:flush()
      t.eq(stashOfType(h, 'cc')[1].val, 81, 'the cc stash carries the edited value')
      t.eq(h.tm:getChannel(1).parkedCC[1].val, 81, 'the render cell shows the edit')

      h.tm:deleteParked(h.tm:getChannel(1).parkedCC[1]); h.tm:flush()
      generators.kinds.ccRep = nil
      t.eq(#h.tm:getChannel(1).parkedCC, 0, 'the parked cc is gone from the render union')
      t.eq(#stashOfType(h, 'cc'), 0, 'the cc stash empties')
    end,
  },

  {
    -- The stash is one flat evType-tagged list, so a (chan, cc, ppq) key alone reaches across types:
    -- a pb edit at a note's onset resolved to the note, and its delete ate the note instead.
    name = 'parked pb sharing a ppq with a parked note edits and deletes independently of it',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, lane = 1 })                                          -- ppq 0
      h.tm:addEvent({ evType = 'pb', ppq = 0, chan = 1, val = 40 }); h.tm:flush()   -- same ppq
      generators.kinds.pbRep = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 50, shape = 'step' },
        } } end,
        mode = 'replace', dest = 'pb', label = 'PbRep', defaults = {}, fields = {},
      }
      injectArp(h, { fx = { arpUp[1], { kind = 'pbRep' } } })
      t.eq(#stashOfType(h, 'note'), 1, 'the note parked')
      t.eq(#stashOfType(h, 'pb'), 1, 'and the coincident pb parked alongside it')

      h.tm:assignParked(h.tm:getChannel(1).parkedPb[1], { val = -40 }); h.tm:flush()
      t.eq(stashOfType(h, 'pb')[1].val, -40, 'the edit landed on the pb')
      t.eq(stashOfType(h, 'note')[1].pitch, 60, 'the note at the same ppq is untouched')
      t.falsy(stashOfType(h, 'note')[1].val, 'and did not absorb the pb-shaped update')

      h.tm:deleteParked(h.tm:getChannel(1).parkedPb[1]); h.tm:flush()
      generators.kinds.pbRep = nil
      t.eq(#stashOfType(h, 'pb'), 0, 'the pb left the stash')
      t.eq(#stashOfType(h, 'note'), 1, 'the note at the same ppq stayed parked')
    end,
  },

  {
    -- Two hosts in different lanes, each with a PA at the same onset. A PA's identity is (chan, pitch,
    -- ppq) all the way down -- mm keys its dedupe on pitch and has no lane -- so the park key needs
    -- pitch to tell these apart. Lane would invent a distinction the take cannot hold.
    name = 'parked PAs sharing a ppq across lanes are addressed by pitch, not by onset alone',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, lane = 1 })
      addNote(h, { pitch = 67, lane = 2 })
      h.tm:addEvent{ evType = 'pa', ppq = 120, chan = 1, pitch = 60, vel = 64, lane = 1, rpb = 2 }
      h.tm:addEvent{ evType = 'pa', ppq = 120, chan = 1, pitch = 67, vel = 90, lane = 2, rpb = 2 }
      h.tm:flush()
      injectArp(h)

      local function stashPA(pitch)
        for _, spec in ipairs(stashOfType(h, 'pa')) do if spec.pitch == pitch then return spec end end
      end
      local function parkedCell(pitch)
        for _, cell in ipairs(h.tm:getChannel(1).parkedPA) do if cell.pitch == pitch then return cell end end
      end
      t.eq(#stashOfType(h, 'pa'), 2, 'both PAs parked with their hosts')

      -- Edit both, so the case bites whichever way the stash happens to be ordered.
      h.tm:assignParked(parkedCell(60), { vel = 100 }); h.tm:flush()
      t.eq(stashPA(60).vel, 100, 'the edit landed on the pitch-60 PA')
      t.eq(stashPA(67).vel, 90,  'its same-onset neighbour in the other lane is untouched')

      h.tm:assignParked(parkedCell(67), { vel = 111 }); h.tm:flush()
      t.eq(stashPA(67).vel, 111, 'the other lane edits independently')
      t.eq(stashPA(60).vel, 100, 'leaving the first PA where it was')

      h.tm:deleteParked(parkedCell(67)); h.tm:flush()
      t.eq(#stashOfType(h, 'pa'), 1, 'one PA left the stash')
      t.eq(stashPA(60) and stashPA(60).vel, 100, 'and the survivor is the other lane\'s, intact')
    end,
  },

  {
    -- Restore lands on a ppq the fill already seats. mm addresses by uuid, so the two are distinct
    -- events: the fill reconcile deletes the seat and the restored authored cc stands.
    name = 'shrinking a cc-replace window restores the authored cc value, not the fill it sat under',
    run = function(harness)
      local h = harness.mk()
      -- Two authored cc74 inside the window; values distinct from the 100 fill.
      h.tm:addEvent({ evType = 'cc', ppq = 60,  chan = 1, cc = 74, val = 30 }); h.tm:flush()
      h.tm:addEvent({ evType = 'cc', ppq = 180, chan = 1, cc = 74, val = 45 }); h.tm:flush()

      -- Replace curve seating a breakpoint every 60t (val 100) -- so each authored ppq sits under a fill seat.
      generators.kinds.ccRep = {
        expand = function(host)
          local delta = {}
          for ppq = host.window[1], host.window[2] - 1, 60 do
            delta[#delta + 1] = { ppq = ppq, val = 100, shape = 'step' }
          end
          return { notes = {}, delta = delta }
        end,
        mode = 'replace', dest = 74, label = 'CcRep', defaults = {}, fields = {},
      }

      -- Grow: window covers both authored cc; both park off-take.
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240,
                                   fx = { { kind = 'ccRep' } } } })
      local grown = {}
      for _, s in ipairs(stashOfType(h, 'cc')) do grown[s.ppq] = s.val end

      -- Shrink so cc74@180 falls outside (restored); cc74@60 stays covered (parked).
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 120,
                                   fx = { { kind = 'ccRep' } } } })
      generators.kinds.ccRep = nil   -- generators is shared: restore before asserting

      t.eq(grown[60],  30, 'cc74@60 parked with its authored value')
      t.eq(grown[180], 45, 'cc74@180 parked with its authored value')

      local restored = authoredCC(h, 1, 74, 180)
      t.truthy(restored, 'cc74@180 restored to the take once outside the window')
      t.eq(restored.val, 45, 'the restored cc keeps its authored value, not the fill (100) it sat under')

      local stillParked = stashOfType(h, 'cc')
      t.eq(#stillParked, 1, 'cc74@60 stays parked under the shrunk window')
      t.eq(stillParked[1].ppq, 60, 'the still-covered cc is the one left parked')
    end,
  },

  {
    name = 'one flush, one rebuild: a parked edit + a normal note land together (the multi-select guard)',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, lane = 1 })
      injectArp(h)
      local rebuilds = 0
      h.tm:subscribe('rebuild', function() rebuilds = rebuilds + 1 end)
      h.tm:assignParked(h.tm:getChannel(1).parked[1], { pitch = 67 })
      h.tm:addEvent({ evType = 'note', ppq = 300, endppq = 480, chan = 1, pitch = 50,
                      vel = 100, detune = 0, delay = 0, lane = 1 })
      h.tm:flush()
      t.eq(rebuilds, 1, 'a single flush drives exactly one rebuild -- the staged parked edit is not discarded')
      t.eq(h.tm:getChannel(1).parked[1].pitch, 67, 'the parked edit landed')
      t.deepEq(authoredPitches(h), { 50 }, 'the normal note landed on the take in the same flush')
    end,
  },

  {
    name = 'parked-only flush drives exactly one rebuild (no mm round-trip)',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, lane = 1 })
      injectArp(h)
      local rebuilds, postflushes = 0, 0
      h.tm:subscribe('rebuild', function() rebuilds = rebuilds + 1 end)
      h.tm:subscribe('postflush', function() postflushes = postflushes + 1 end)
      h.tm:assignParked(h.tm:getChannel(1).parked[1], { pitch = 67 }); h.tm:flush()
      t.eq(rebuilds, 1, 'a parked-only flush still rebuilds exactly once')
      t.eq(postflushes, 1, 'flush has one exit, so postflush fires exactly once')
      t.eq(h.tm:getChannel(1).parked[1].pitch, 67, 'the edit is visible after the rebuild')
    end,
  },

  {
    name = 'fxParked dataChanged (undo rewind) rebuilds the grid',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, lane = 1 })
      injectArp(h)
      local rebuilds = 0
      h.tm:subscribe('rebuild', function() rebuilds = rebuilds + 1 end)
      h.ds:assign('fxParked', {})   -- an undo rewind arrives as a bare fxParked change
      t.eq(rebuilds, 1, 'a bare fxParked change triggers one rebuild so the grid re-derives')
    end,
  },

  {
    name = 'an error escaping the parked flush leaves later ds changes still rebuilding',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, lane = 1 })
      injectArp(h)
      local boom = function(change) if change.name == 'fxParked' then error('subscriber blew up') end end
      h.ds:subscribe('dataChanged', boom)
      h.tm:assignParked(h.tm:getChannel(1).parked[1], { pitch = 67 })
      local ok = pcall(function() h.tm:flush() end)
      t.falsy(ok, 'the subscriber error propagates out of flush')
      h.ds:unsubscribe('dataChanged', boom)
      local rebuilds = 0
      h.tm:subscribe('rebuild', function() rebuilds = rebuilds + 1 end)
      h.ds:assign('fxParked', {})
      t.eq(rebuilds, 1, 'the suppression came back down, so a later ds change still rebuilds')
    end,
  },

  ----- Augment by kind: a continuous region leaves its members sounding (no parking)

  {
    name = 'augment by kind: a continuous (sine) region leaves its covered notes sounding',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, ppq = 0, endppq = 240, lane = 1 })
      injectRegion(h)   -- sine over [0,240) covers the note -- augment, so it is not parked
      t.deepEq(authoredPitches(h), { 60 }, 'the covered note keeps sounding -- a continuous kind augments')
      t.truthy(#derivedPbs(h, 1) > 0, 'and the sine pb seats are present over the span')
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
      -- the window. Identity swing in the harness, so raw == logical.
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
      t.deepEq(captured.pas, { { ppq = 120, pitch = 60, vel = 77 } }, 'the PA rides into host.pas')
      t.deepEq(captured.ccs[74], { { ppq = 0,   val = 50, shape = 'step' },
                                   { ppq = 60,  val = 50, shape = 'step' },
                                   { ppq = 240, val = 50, shape = 'step' } },
        'authored cc 74 buckets into host.ccs as an absolute curve with entering/closing edge values')
      t.deepEq(captured.ats, { { ppq = 180, val = 33 } }, 'channel aftertouch into host.ats')
      t.deepEq(field(captured.notes, 'pitch'), { 60 }, 'the covered note is the membership (host.notes)')
    end,
  },

  {
    name = 'fx region: an OPEN member clips to the next same-lane onset, not the window end',
    run = function(harness)
      local h = harness.mk()
      -- First note is OPEN, successor at ppq 120: membersOf must clip the OPEN tail to 120,
      -- else the generator sees a phantom [0,240) overlapping [120,240).
      addNote(h, { pitch = 60, ppq = 0,   endppq = util.OPEN })
      addNote(h, { pitch = 67, ppq = 120, endppq = 240 })

      local captured
      generators.kinds.capture = {
        expand = function(host) captured = host; return { notes = {}, delta = {} } end,
        mode = 'augment', dest = 'pb', label = 'Capture', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240,
                                   fx = { { kind = 'capture' } } } })
      h.tm:rebuild()
      generators.kinds.capture = nil

      t.truthy(captured, 'the capture kind ran')
      local byPitch = {}
      for _, n in ipairs(captured.notes) do byPitch[n.pitch] = n end
      t.eq(byPitch[60].endppq, 120, 'the OPEN member clips to the next same-lane onset')
      t.eq(byPitch[67].endppq, 240, 'the trailing member fills to the window end')
    end,
  },

  {
    name = 'fx region: host.pb carries authored pb breakpoints, excluding absorber fakes',
    run = function(harness)
      local h = harness.mk()
      addNote(h)   -- lane-1 note 60 over [0,240); its presence makes I2a seat an absorber fake at ppq 0
      h.tm:addEvent({ evType = 'pb', ppq = 60, chan = 1, val = 50 })   -- val is cents (the um is cents-native)
      h.tm:flush()

      -- A cc-dest probe: host.pb is built independent of the kind's dest, so a cc-augment capture reads
      -- the authored pb without a pb window parking it off (a pb-dest kind would park it, emptying host.pb).
      local captured
      generators.kinds.capture = {
        expand = function(host) captured = host; return { notes = {}, delta = {} } end,
        mode = 'augment', dest = 10, label = 'Capture', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240,
                                   fx = { { kind = 'capture' } } } })
      h.tm:rebuild()
      generators.kinds.capture = nil

      t.truthy(captured, 'the capture kind ran and recorded its host')
      t.deepEq(captured.pb, { { ppq = 0,   val = 50, shape = 'step' },
                              { ppq = 60,  val = 50, shape = 'step' },
                              { ppq = 240, val = 50, shape = 'step' } },
        'the authored pb rides into host.pb as an absolute cents curve; the absorber fake is excluded')
    end,
  },

  ----- Continuous pb replace: the absolute curve is seated on the base lane as derived pbs -- no carrier

  {
    name = 'fx region: pb replace seats the absolute curve on the base lane, no carrier',
    run = function(harness)
      local h = harness.mk()
      -- Authored base: 0c at ppq 0, 40c at ppq 120. No notes -> detune 0, so the seated wire is the
      -- absolute curve untouched. (val is cents.)
      h.tm:addEvent({ evType = 'pb', ppq = 0,   chan = 1, val = 0 })
      h.tm:addEvent({ evType = 'pb', ppq = 120, chan = 1, val = 40 })
      h.tm:flush()

      -- A spec-only replace kind: an absolute +50c step curve returning to 0c at the window end.
      generators.kinds.capRep = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 50, shape = 'step' },
          { ppq = 60,             val = 50, shape = 'step' },
          { ppq = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'replace', dest = 'pb', label = 'CapRep', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240,
                                   fx = { { kind = 'capRep' } } } })
      h.tm:rebuild()
      generators.kinds.capRep = nil

      -- Authored pbs inside the window park off-take (exclusive ownership), so the curve is realised
      -- purely by derived seats; the authored breakpoints stay visible via the parkedPb render union.
      t.falsy(authoredPb(h, 1, 0),   'the authored base at the window start parked off the take')
      t.falsy(authoredPb(h, 1, 120), 'the authored pb mid-window parked off the take')
      t.eq(derivedPb(h, 1, 0).val,   centsToRaw(50), 'a derived seat carries the curve at the window start (50c)')
      t.eq(derivedPb(h, 1, 60).val,  centsToRaw(50), 'a derived seat carries the curve mid-window')
      t.eq(derivedPb(h, 1, 239).val, centsToRaw(40), 'the close hands the channel back to the authored base the region parked')
      local at120
      for _, p in ipairs(h.tm:getChannel(1).parkedPb) do if p.ppq == 120 then at120 = p end end
      t.eq(at120 and at120.val, 40, 'the authored 40c stays visible via the parkedPb render union')
    end,
  },

  {
    name = 'bypass: a bypassed pb-replace stage parks its window and re-seats the authored base',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'pb', ppq = 0,   chan = 1, val = 0 })
      h.tm:addEvent({ evType = 'pb', ppq = 120, chan = 1, val = 40 })
      h.tm:flush()

      generators.kinds.capRep = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 50, shape = 'step' },
          { ppq = 60,             val = 50, shape = 'step' },
          { ppq = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'replace', dest = 'pb', label = 'CapRep', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240,
                                   fx = { { kind = 'capRep', bypass = true } } } })
      h.tm:rebuild()
      generators.kinds.capRep = nil

      t.falsy(authoredPb(h, 1, 0),   'parkWindows ignores the flag -- the authored pb still parks off-take')
      t.eq(derivedPb(h, 1, 0).val,   0,               'the seat carries the authored base, not the curve (0c)')
      t.eq(derivedPb(h, 1, 120).val, centsToRaw(40), 'and the base breakpoint at 120 (40c)')
    end,
  },

  {
    name = 'fx region: pb replace with no authored base seats the curve verbatim',
    run = function(harness)
      local h = harness.mk()
      generators.kinds.capRep = {
        expand = function(host)
          return { notes = {}, delta = {
            { ppq = host.window[1], val = 50, shape = 'step' },
            { ppq = host.window[2], val = 0,  shape = 'step' },
          } }
        end,
        mode = 'replace', dest = 'pb', label = 'CapRep', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240,
                                   fx = { { kind = 'capRep' } } } })
      h.tm:rebuild()
      generators.kinds.capRep = nil

      t.eq(derivedPb(h, 1, 0).val,   centsToRaw(50), 'seated at the curve start (50c)')
      t.eq(derivedPb(h, 1, 239).val, 0,              'seat re-centres one tick inside the window end')
    end,
  },

  ----- C2: continuous stages fold in-chain -- order is load-bearing on the pb channel too

  {
    name = 'fx chain (continuous): [replace, augment] -- the augment stage wobbles the replaced curve',
    run = function(harness)
      local h = harness.mk()
      -- capRep replaces the pb channel with a flat 50c curve; bump augments +20c over [60,120).
      generators.kinds.capRep = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 50, shape = 'step' },
          { ppq = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'replace', dest = 'pb', label = 'CapRep', defaults = {}, fields = {},
      }
      generators.kinds.bump = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 0,  shape = 'step' },
          { ppq = 60,             val = 20, shape = 'step' },
          { ppq = 120,            val = 0,  shape = 'step' },
        } } end,
        mode = 'augment', dest = 'pb', label = 'Bump', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240,
                                   fx = { { kind = 'capRep' }, { kind = 'bump' } } } })
      h.tm:rebuild()
      generators.kinds.capRep, generators.kinds.bump = nil, nil

      t.eq(derivedPb(h, 1, 0).val,   centsToRaw(50), 'the replaced curve seats at the window start')
      t.eq(derivedPb(h, 1, 60).val,  centsToRaw(70), 'the augment delta folds onto the replaced curve (50c + 20c)')
      t.eq(derivedPb(h, 1, 120).val, centsToRaw(50), 'the delta releases back to the replaced curve')
      t.eq(derivedPb(h, 1, 239).val, 0,              'the terminal seat re-centres one tick inside the window end')
    end,
  },

  {
    name = 'fx chain (continuous): [augment, replace] -- the replace stage overwrites the folded stream',
    run = function(harness)
      local h = harness.mk()
      generators.kinds.bump = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 0,  shape = 'step' },
          { ppq = 60,             val = 20, shape = 'step' },
          { ppq = 120,            val = 0,  shape = 'step' },
        } } end,
        mode = 'augment', dest = 'pb', label = 'Bump', defaults = {}, fields = {},
      }
      generators.kinds.capRep = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 50, shape = 'step' },
          { ppq = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'replace', dest = 'pb', label = 'CapRep', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240,
                                   fx = { { kind = 'bump' }, { kind = 'capRep' } } } })
      h.tm:rebuild()
      generators.kinds.capRep, generators.kinds.bump = nil, nil

      t.eq(derivedPb(h, 1, 0).val, centsToRaw(50), 'the replace curve owns the window start')
      t.falsy(derivedPb(h, 1, 60), 'the earlier augment bump is overwritten -- no seat survives at 60')
      t.eq(derivedPb(h, 1, 239).val, 0, 'the terminal seat re-centres one tick inside the window end')
    end,
  },

  ----- Cross-chain: overlapping regions on one target layer by storage order (painter)

  {
    name = 'fx region (pb): two overlapping replace regions -- later storage wins pointwise, not summed',
    run = function(harness)
      local h = harness.mk()
      generators.kinds.capA = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 30, shape = 'step' },
          { ppq = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'replace', dest = 'pb', label = 'CapA', defaults = {}, fields = {},
      }
      generators.kinds.capB = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 60, shape = 'step' },
          { ppq = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'replace', dest = 'pb', label = 'CapB', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', {
        { uuid = 'r1', chan = 1, startppq = 0, endppq = 240, fx = { { kind = 'capA' } } },
        { uuid = 'r2', chan = 1, startppq = 0, endppq = 240, fx = { { kind = 'capB' } } },
      })
      h.tm:rebuild()
      generators.kinds.capA, generators.kinds.capB = nil, nil

      t.eq(derivedPb(h, 1, 0).val, centsToRaw(60),
        'r2 is later in storage -> its 60c curve wins; the additive fold would give 90c')
    end,
  },

  {
    name = 'fx region (pb): a later replace region wipes an earlier augment (storage = precedence)',
    run = function(harness)
      local h = harness.mk()
      generators.kinds.bump = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 0,  shape = 'step' },
          { ppq = 60,             val = 20, shape = 'step' },
          { ppq = 120,            val = 0,  shape = 'step' },
        } } end,
        mode = 'augment', dest = 'pb', label = 'Bump', defaults = {}, fields = {},
      }
      generators.kinds.capRep = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 50, shape = 'step' },
          { ppq = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'replace', dest = 'pb', label = 'CapRep', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', {
        { uuid = 'r1', chan = 1, startppq = 0, endppq = 240, fx = { { kind = 'bump' } } },
        { uuid = 'r2', chan = 1, startppq = 0, endppq = 240, fx = { { kind = 'capRep' } } },
      })
      h.tm:rebuild()
      generators.kinds.bump, generators.kinds.capRep = nil, nil

      t.eq(derivedPb(h, 1, 0).val, centsToRaw(50), 'the later replace owns the wire from the start')
      t.falsy(derivedPb(h, 1, 60),
        'the earlier +20c augment is wiped -- no seat at 60; the additive fold would seat 70c there')
    end,
  },

  {
    name = 'bypass: a bypassed replace stage yields precedence -- the earlier chain keeps the overlap',
    run = function(harness)
      local h = harness.mk()
      -- The authored base is load-bearing: a bypassed chain re-seats it, and the fold skips a record
      -- whose curve is empty, so with no base under the overlap a replace record has nothing to paint
      -- with and the case passes either way.
      h.tm:addEvent({ evType = 'pb', ppq = 0,   chan = 1, val = 0 })
      h.tm:addEvent({ evType = 'pb', ppq = 120, chan = 1, val = 40 })
      h.tm:flush()

      generators.kinds.capA = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 30, shape = 'step' },
          { ppq = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'replace', dest = 'pb', label = 'CapA', defaults = {}, fields = {},
      }
      generators.kinds.capRep = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 50, shape = 'step' },
          { ppq = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'replace', dest = 'pb', label = 'CapRep', defaults = {}, fields = {},
      }

      -- One fixture, rebuilt twice: the flag is the only thing that moves between the two readings.
      local function layer(bypass)
        h.ds:assign('fxRegions', {
          { uuid = 'r1', chan = 1, startppq = 0, endppq = 240, fx = { { kind = 'capA' } } },
          { uuid = 'r2', chan = 1, startppq = 0, endppq = 240, fx = { { kind = 'capRep', bypass = bypass } } },
        })
        h.tm:rebuild()
      end

      layer(true)
      local bypassedHead, bypassedMid = derivedPb(h, 1, 0).val, derivedPb(h, 1, 120).val
      layer(false)
      local liveHead = derivedPb(h, 1, 0).val
      generators.kinds.capA, generators.kinds.capRep = nil, nil

      t.eq(bypassedHead, centsToRaw(30), "r1's curve owns the overlap -- r2 folds as a zero augment")
      t.eq(bypassedMid,  centsToRaw(30),
        'and at the base breakpoint: 30c, not the 40c a replace record carrying the base would paint')
      t.eq(liveHead, centsToRaw(50),
        'flag off, same fixture: the later replace wins again -- the demotion is the flag, not a relaxed layering')
    end,
  },

  {
    name = 'fx region (pb): overlapping replace regions with differing windows -- each owns its exclusive tail',
    run = function(harness)
      local h = harness.mk()
      -- r1 [120,360) at 30c, r2 [0,240) at 60c (later storage) wins the overlap [120,240); r1's exclusive
      -- tail [240,360) must survive at 30c, not be wiped by r2's whole curve. see docs/generators.md § Multiplicity
      generators.kinds.capA = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 30, shape = 'step' },
          { ppq = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'replace', dest = 'pb', label = 'CapA', defaults = {}, fields = {},
      }
      generators.kinds.capB = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 60, shape = 'step' },
          { ppq = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'replace', dest = 'pb', label = 'CapB', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', {
        { uuid = 'r1', chan = 1, startppq = 120, endppq = 360, fx = { { kind = 'capA' } } },
        { uuid = 'r2', chan = 1, startppq = 0,   endppq = 240, fx = { { kind = 'capB' } } },
      })
      h.tm:rebuild()
      generators.kinds.capA, generators.kinds.capB = nil, nil

      t.eq(derivedPb(h, 1, 0).val,   centsToRaw(60), 'r2 owns its exclusive head [0,120) at 60c')
      t.eq(derivedPb(h, 1, 120).val, centsToRaw(60), 'in the overlap r2 (later storage) wins -- 60c, not 30c')
      t.eq(derivedPb(h, 1, 240).val, centsToRaw(30), "r1's exclusive tail [240,360) survives at 30c, not wiped")
      t.eq(derivedPb(h, 1, 359).val, 0,              'the terminal seat re-centres one tick inside the merged-span end')
    end,
  },

  {
    name = 'fx region (cc): two overlapping replace regions -- later storage wins, not the additive fold',
    run = function(harness)
      local h = harness.mk()
      generators.kinds.ccA = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 30, shape = 'step' },
          { ppq = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'replace', dest = 10, label = 'CcA', defaults = {}, fields = {},
      }
      generators.kinds.ccB = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 90, shape = 'step' },
          { ppq = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'replace', dest = 10, label = 'CcB', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', {
        { uuid = 'r1', chan = 1, startppq = 0, endppq = 240, fx = { { kind = 'ccA' } } },
        { uuid = 'r2', chan = 1, startppq = 0, endppq = 240, fx = { { kind = 'ccB' } } },
      })
      h.tm:rebuild()
      generators.kinds.ccA, generators.kinds.ccB = nil, nil

      t.eq(ccFillAt(h, 1, 10, 0).val, 90,
        'r2 (90) wins as later storage; the additive fold over rest 64 would give 56')
    end,
  },

  {
    name = 'fx region (cc augment): overlapping differing windows -- each augment folds only in its own window',
    run = function(harness)
      local h = harness.mk()
      -- r1 [0,240) peaks +40 at 60; r2 [120,360) peaks +10 at 180. Overlap [120,240) sums both; each
      -- exclusive tail carries only its own delta (base rest 64). see docs/generators.md § Multiplicity
      generators.kinds.ccA = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 0,  shape = 'step' },
          { ppq = 60,             val = 40, shape = 'step' },
          { ppq = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'augment', dest = 10, label = 'CcA', defaults = {}, fields = {},
      }
      generators.kinds.ccB = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 0,  shape = 'step' },
          { ppq = 180,            val = 10, shape = 'step' },
          { ppq = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'augment', dest = 10, label = 'CcB', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', {
        { uuid = 'r1', chan = 1, startppq = 0,   endppq = 240, fx = { { kind = 'ccA' } } },
        { uuid = 'r2', chan = 1, startppq = 120, endppq = 360, fx = { { kind = 'ccB' } } },
      })
      h.tm:rebuild()
      generators.kinds.ccA, generators.kinds.ccB = nil, nil

      t.eq(ccFillAt(h, 1, 10, 60).val,  104, 'r1 exclusive head: rest 64 + macroA 40')
      t.eq(ccFillAt(h, 1, 10, 180).val, 114, 'overlap: rest 64 + macroA 40 (held) + macroB 10')
      t.eq(ccFillAt(h, 1, 10, 240).val, 74,  'r2 exclusive tail seats at 240: rest 64 + macroB 10 -- macroA no longer folds')
    end,
  },

  {
    name = 'fx region (pb): differing-window overlap seats are byte-stable across a no-change rebuild',
    run = function(harness)
      local h = harness.mk()
      -- the sub-split emits seats at interior cut boundaries (240) the same-window path never produced;
      -- pin that the reconcile/addressing layer matches them across a steady-state rebuild (G4 for sub-splits).
      generators.kinds.capA = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 30, shape = 'step' },
          { ppq = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'replace', dest = 'pb', label = 'CapA', defaults = {}, fields = {},
      }
      generators.kinds.capB = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 60, shape = 'step' },
          { ppq = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'replace', dest = 'pb', label = 'CapB', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', {
        { uuid = 'r1', chan = 1, startppq = 120, endppq = 360, fx = { { kind = 'capA' } } },
        { uuid = 'r2', chan = 1, startppq = 0,   endppq = 240, fx = { { kind = 'capB' } } },
      })
      h.tm:rebuild()
      local before = derivedPbs(h, 1)
      table.sort(before, function(a, b) return a.ppq < b.ppq end)
      t.truthy(#before >= 3, 'sub-split seats present (head, overlap, tail, terminal)')

      local adds, realAdd = 0, h.fm.add
      h.fm.add = function(self, e)
        if e and e.evType == 'pb' then adds = adds + 1 end
        return realAdd(self, e)
      end
      h.tm:rebuild()
      h.fm.add = realAdd
      generators.kinds.capA, generators.kinds.capB = nil, nil

      t.eq(adds, 0, 'steady-state rebuild re-seats no pb across the differing-window overlap')
      local after = derivedPbs(h, 1)
      table.sort(after, function(a, b) return a.ppq < b.ppq end)
      t.eq(#after, #before, 'seat count is stable across the round trip')
      for i, pb in ipairs(after) do
        t.eq(pb.ppq, before[i].ppq, 'seat ppq stable')
        t.eq(pb.val, before[i].val, 'seat val stable')
      end
    end,
  },

  {
    name = 'fx region: pb replace rides the curve over the detune -- I1 holds',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { detune = 25 })                                    -- lane-1 detune seats under the curve
      h.tm:addEvent({ evType = 'pb', ppq = 60, chan = 1, val = 40 }) -- authored automation in the window
      h.tm:flush()

      generators.kinds.capRep = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 30, shape = 'step' },
          { ppq = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'replace', dest = 'pb', label = 'CapRep', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240,
                                   fx = { { kind = 'capRep' } } } })
      h.tm:rebuild()
      generators.kinds.capRep = nil

      -- The wire is curve + detune (I1): the 30c curve rides on the 25c detune. The authored pb
      -- parks off-take (the curve owns the wire) and stays visible via parkedPb.
      t.falsy(authoredPb(h, 1, 60), 'the authored pb parked off the take')
      t.eq(derivedPb(h, 1, 0).val,   centsToRaw(55), 'the seat at the window start carries curve 30c + detune 25c')
      -- The region parks the authored 40c, so handing back detune alone would let the fx suppress an
      -- authored value past its own end. The close is the wire as it reads with no region at all.
      t.eq(derivedPb(h, 1, 239).val, centsToRaw(65), 'the close hands back authored 40c + detune 25c (I1)')
      t.eq(h.tm:getChannel(1).parkedPb[1].val, 40, 'the authored 40c stays visible via the parkedPb render union')
    end,
  },

  {
    name = 'fx region: removing a pb replace region restores the authored wire',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'pb', ppq = 120, chan = 1, val = 40 }); h.tm:flush()
      generators.kinds.capRep = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 50, shape = 'step' },
          { ppq = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'replace', dest = 'pb', label = 'CapRep', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240,
                                   fx = { { kind = 'capRep' } } } })
      h.tm:rebuild()
      -- While the region is present the authored pb parks off-take (the curve owns the wire) and
      -- stays visible via parkedPb; removing the region restores it to the take.
      t.falsy(authoredPb(h, 1, 120), 'the authored pb parks while the region is present')
      t.eq(h.tm:getChannel(1).parkedPb[1].val, 40, 'its 40c stays visible via the parkedPb render union')

      h.ds:assign('fxRegions', {})
      h.tm:rebuild()
      generators.kinds.capRep = nil
      t.eq(authoredPb(h, 1, 120).val, centsToRaw(40),
        'the authored wire (40c) is restored once the region is gone')
      t.eq(#h.tm:getChannel(1).parkedPb, 0, 'and the parkedPb render set empties')
    end,
  },

  {
    name = 'fx region: pb replace densifies a curved segment split by a detune onset',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 62, ppq = 120, detune = 20, lane = 1 })   -- a lone detune onset at ppq 120
      h.tm:flush()

      -- A single 'slow' segment 0c -> 60c across the window; the onset at 120 splits it, so the
      -- segment densifies to a linear polyline on the CCINTERP grid (step 8 at res 240 / interp 32).
      generators.kinds.capRep = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 0,  shape = 'slow' },
          { ppq = host.window[2], val = 60, shape = 'slow' },
        } } end,
        mode = 'replace', dest = 'pb', label = 'CapRep', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240,
                                   fx = { { kind = 'capRep' } } } })
      h.tm:rebuild()
      generators.kinds.capRep = nil

      local interior = false
      for _, c in ipairs(derivedPbs(h, 1)) do
        if c.ppq > 0 and c.ppq < 119 then interior = true break end
      end
      t.truthy(interior, 'the curved segment is subdivided by grid seats -- densified, not two bps')

      -- Endpoints exact; the interior tracks the slow shape (30c at the midpoint).
      t.eq(derivedPb(h, 1, 0).val,   centsToRaw(0),  'start seat exact (0c, detune 0)')
      t.eq(derivedPb(h, 1, 238).val, centsToRaw(80), 'the curve reaches its full 60c + 20c detune on the last tick material holds')
      t.eq(derivedPb(h, 1, 239).val, centsToRaw(20), 'and the close hands back detune alone -- 60c does not outlive the window')

      -- The detune step rides a dual point at the onset: same curve value, detune jumps 0 -> 20. The
      -- closing control point folds to 238 (239 is the close's), so the segment spans [0,238] and its
      -- interior runs a fraction ahead of the authored [0,240] geometry -- 30.4c at 119, not a round 30c.
      t.eq(derivedPb(h, 1, 119).val, 1244, 'just-before the onset: curve only, detune 0')
      t.eq(derivedPb(h, 1, 120).val, 1244 + centsToRaw(20), 'at the onset: the same curve value + detune 20 -- the step is exact')
    end,
  },

  ----- Markerless seats: a dense in-window curve costs zero eventMeta (§ Route-by-window)

  {
    name = 'fx region: a dense pb replace curve seats markerless -- no uuid, no metadata sidecar',
    run = function(harness)
      local h = harness.mk()
      -- A 12-segment step curve across the window: every breakpoint seats, so a dense curve. Were the
      -- seats marked (derived/cents), each would mint a uuid + eventMeta row -- the explosion we retire.
      generators.kinds.capDense = {
        expand = function(host)
          local delta, span = {}, host.window[2] - host.window[1]
          for i = 0, 12 do
            delta[#delta + 1] = { ppq = host.window[1] + span * i // 12,
                                  val = (i % 2 == 0) and 40 or -40, shape = 'step' }
          end
          return { notes = {}, delta = delta }
        end,
        mode = 'replace', dest = 'pb', label = 'CapDense', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240,
                                   fx = { { kind = 'capDense' } } } })
      h.tm:rebuild()
      generators.kinds.capDense = nil

      -- Detection is region-based (derivedPbs); the assertion is that those seats carry no metadata.
      local seats = derivedPbs(h, 1)
      t.truthy(#seats >= 12, 'the dense curve realises many seats')
      for _, s in ipairs(seats) do
        t.eq(s.plain, true, 'every seat is markerless -- plain means no eventMeta sidecar')
      end
    end,
  },

  {
    name = 'fx region: removing a pb replace region sweeps its seats, leaving only the restored authored pb',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'pb', ppq = 130, chan = 1, val = 40 }); h.tm:flush()  -- authored, off a seat grid point
      generators.kinds.capDense = {
        expand = function(host)
          local delta, span = {}, host.window[2] - host.window[1]
          for i = 0, 12 do
            delta[#delta + 1] = { ppq = host.window[1] + span * i // 12,
                                  val = (i % 2 == 0) and 40 or -40, shape = 'step' }
          end
          return { notes = {}, delta = delta }
        end,
        mode = 'replace', dest = 'pb', label = 'CapDense', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240,
                                   fx = { { kind = 'capDense' } } } })
      h.tm:rebuild()
      t.truthy(#derivedPbs(h, 1) >= 12, 'the dense curve seated many markerless seats while present')
      t.falsy(authoredPb(h, 1, 130), 'the authored pb parked off the take while the region was present')

      h.ds:assign('fxRegions', {})   -- forward removal: enqueues the sweep, restores the parked authored
      h.tm:rebuild()
      generators.kinds.capDense = nil

      local pbs = {}
      for _, c in ipairs(h.fm:dump().ccs) do
        if c.evType == 'pb' and c.chan == 1 then pbs[#pbs + 1] = c end
      end
      t.eq(#pbs, 1,                  'every seat is swept -- only the restored authored pb remains on the wire')
      t.eq(pbs[1].ppq, 130,         'and it is the authored breakpoint, back at its ppq')
      t.eq(pbs[1].val, centsToRaw(40), 'restored at its authored value')
    end,
  },

  -- The end row belongs to whatever is authored on it, not to the region: the re-centre seat folds at
  -- endppq-1, so every pb span is half-open and nothing on the boundary can read as a seat.
  {
    name = 'fx region (pb): the window end row is not seat territory -- an authored pb on it survives',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'pb', ppq = 300, chan = 1, val = 200 }); h.tm:flush()
      injectRegion(h, { endppq = 240 })
      t.eq(wirePb(h, 1, 300).cents, 200, 'authored beyond the region, untouched')

      injectRegion(h, { endppq = 300 })   -- the end lands exactly on the authored breakpoint
      local onEdge = wirePb(h, 1, 300)
      t.truthy(onEdge, 'the end landing on it does not absorb it')
      t.eq(onEdge.cents, 200, 'its authored cents sidecar stands')
      t.eq(onEdge.ppqL, 300, 'and its logical seat -- an absorbed pb loses ppqL and stops being editable')

      injectRegion(h, { endppq = 360 })   -- a later window change sweeps seats; an absorbed pb would go with them
      t.eq(wirePb(h, 1, 300).plain, true, 'genuinely covered now: what stands there is a generated seat')
      t.eq(#stashOfType(h, 'pb'), 1, 'and the authored breakpoint parked off-take, not swept into the void')
      t.eq(stashOfType(h, 'pb')[1].val, 200, 'with its authored cents intact')
    end,
  },

  ----- Continuous cc replace: park the authored cc off-take, write the generated curve direct (no node)

  {
    name = 'fx region (cc replace): the generated curve lands on the target cc lane; no carrier',
    run = function(harness)
      local h = harness.mk()
      -- Authored cc 74 inside the window: parked off-take by the replace region.
      h.tm:addEvent({ evType = 'cc', ppq = 60,  chan = 1, cc = 74, val = 30 })
      h.tm:addEvent({ evType = 'cc', ppq = 120, chan = 1, cc = 74, val = 90 })
      h.tm:flush()

      generators.kinds.ccRep = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 100, shape = 'step' },
          { ppq = 120,            val = 20,  shape = 'step' },
        } } end,
        mode = 'replace', dest = 74, label = 'CcRep', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240,
                                   fx = { { kind = 'ccRep' } } } })
      h.tm:rebuild()
      generators.kinds.ccRep = nil

      -- The curve is written verbatim onto cc 74 -- no transport encoding.
      t.eq(ccFillAt(h, 1, 74, 0).val,   100, 'curve start lands on the target cc lane')
      t.eq(ccFillAt(h, 1, 74, 120).val, 20,  'curve mid lands on the target cc lane')
      -- The authored cc the window covers is parked off-take.
      t.falsy(authoredCC(h, 1, 74, 60),  'authored cc at 60 is parked off-take')
      t.falsy(authoredCC(h, 1, 74, 120), 'authored cc at 120 is parked off-take')
    end,
  },

  {
    name = 'fx region (cc replace): removing the region restores the parked cc and drops the fill',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'cc', ppq = 60, chan = 1, cc = 74, val = 30 }); h.tm:flush()
      generators.kinds.ccRep = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 100, shape = 'step' },
        } } end,
        mode = 'replace', dest = 74, label = 'CcRep', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240,
                                   fx = { { kind = 'ccRep' } } } })
      h.tm:rebuild()
      generators.kinds.ccRep = nil
      t.truthy(ccFillAt(h, 1, 74, 0), 'the fill is present while the region is')
      t.falsy(authoredCC(h, 1, 74, 60), 'the authored cc is parked while the region is present')

      h.ds:assign('fxRegions', {})
      h.tm:rebuild()
      t.falsy(ccFillAt(h, 1, 74, 0), 'no fill survives the region removal')
      t.eq(authoredCC(h, 1, 74, 60).val, 30, 'the authored cc is restored to the take')
      local cc74 = {}
      for _, c in ipairs(h.fm:dump().ccs) do
        if c.evType == 'cc' and c.cc == 74 and c.chan == 1 then cc74[#cc74 + 1] = c end
      end
      t.eq(#cc74, 1, 'the swept seats leave the take -- only the restored authored cc remains')
    end,
  },

  {
    name = 'G4 (cc replace): the fill is byte-identical and re-adds nothing across a no-change rebuild',
    run = function(harness)
      local h = harness.mk()
      generators.kinds.ccRep = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 100, shape = 'step' },
          { ppq = 120,            val = 20,  shape = 'step' },
        } } end,
        mode = 'replace', dest = 74, label = 'CcRep', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240,
                                   fx = { { kind = 'ccRep' } } } })
      h.tm:rebuild()
      local before = fillsOf(h, 1, 74)
      t.truthy(#before > 0, 'fill present (non-vacuous)')

      local adds, realAdd = 0, h.fm.add
      h.fm.add = function(self, e)
        if e and e.evType == 'cc' and e.cc == 74 then adds = adds + 1 end
        return realAdd(self, e)
      end
      h.tm:rebuild()
      h.fm.add = realAdd
      generators.kinds.ccRep = nil
      t.eq(adds, 0, 'steady-state rebuild rewrites no fill events')
      t.deepEq(fillsOf(h, 1, 74), before, 'the fill is byte-identical across the round trip')
    end,
  },

  {
    name = 'cc replace: a dense fill curve seats markerlessly (no uuid, no eventMeta)',
    run = function(harness)
      local h = harness.mk()
      generators.kinds.ccDense = {
        expand = function()
          local d = {}
          for i = 0, 11 do d[#d + 1] = { ppq = i * 20, val = i * 8, shape = 'linear' } end
          return { notes = {}, delta = d }
        end,
        mode = 'replace', dest = 74, label = 'CcDense', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240,
                                   fx = { { kind = 'ccDense' } } } })
      h.tm:rebuild()
      generators.kinds.ccDense = nil
      local seats = fillRecords(h, 1, 74)
      t.truthy(#seats >= 12, 'every breakpoint seats on the target lane')
      for _, s in ipairs(seats) do
        t.eq(s.plain, true, 'a fill seat is markerless -- no sidecar, no eventMeta')
      end
    end,
  },

  ----- Continuous cc augment: base + macros sum offline into markerless seats on the target lane

  {
    name = 'fx region (cc augment): un-automated target seats base(rest) + macro, markerless, off columns',
    run = function(harness)
      local h = harness.mk()
      generators.kinds.ccCap = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 0,  shape = 'step' },
          { ppq = 60,             val = 30, shape = 'step' },
          { ppq = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'augment', dest = 10, label = 'CcCap', defaults = {}, fields = {},   -- pan, default rest 64
      }
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240,
                                   fx = { { kind = 'ccCap' } } } })
      h.tm:rebuild()
      generators.kinds.ccCap = nil

      t.eq(ccFillAt(h, 1, 10, 0).val,  64, 'no authored automation -> base is the default rest (64) + macro 0')
      t.eq(ccFillAt(h, 1, 10, 60).val, 94, 'at the macro peak the seat is rest 64 + delta 30')
      for _, s in ipairs(fillRecords(h, 1, 10)) do
        t.eq(s.plain, true, 'an augment seat is markerless -- no sidecar, no eventMeta')
      end
      t.falsy(h.tm:getChannel(1).columns.ccs[10], 'the summed seats are routed out of columns -- off-screen')
    end,
  },

  {
    name = 'fx region (cc augment): over authored automation the seat is authored-base + macro',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'cc', ppq = 0, chan = 1, cc = 10, val = 20 }); h.tm:flush()
      generators.kinds.ccCap = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 0,  shape = 'step' },
          { ppq = 60,             val = 30, shape = 'step' },
          { ppq = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'augment', dest = 10, label = 'CcCap', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240,
                                   fx = { { kind = 'ccCap' } } } })
      h.tm:rebuild()
      generators.kinds.ccCap = nil

      t.eq(ccFillAt(h, 1, 10, 0).val,  20, 'authored cc 20 becomes the held base; macro adds 0 at the start')
      t.eq(ccFillAt(h, 1, 10, 60).val, 50, 'held base 20 + macro delta 30 at the peak')
      t.falsy(authoredCC(h, 1, 10, 0), 'the authored cc is parked off-take -- the sum owns the lane')
    end,
  },

  {
    name = 'fx region (cc augment): a value authored before the window governs as the base',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'cc', ppq = 0, chan = 1, cc = 10, val = 100 }); h.tm:flush()
      generators.kinds.ccCap = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 0,  shape = 'step' },
          { ppq = 180,            val = 10, shape = 'step' },
          { ppq = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'augment', dest = 10, label = 'CcCap', defaults = {}, fields = {},   -- pan, default rest 64
      }
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 120, endppq = 240,
                                   fx = { { kind = 'ccCap' } } } })
      h.tm:rebuild()
      generators.kinds.ccCap = nil

      t.eq(ccFillAt(h, 1, 10, 120).val, 100, 'the governing authored value, not ccDefaultRest 64, is the base')
      t.eq(ccFillAt(h, 1, 10, 180).val, 110, 'governing base 100 + macro delta 10 at the peak')
      t.truthy(authoredCC(h, 1, 10, 0), 'the authored cc stays on the take -- it lies outside the window')
    end,
  },

  {
    name = 'fx region (cc augment): two overlapping regions sum every stream (N-stream regression guard)',
    run = function(harness)
      local h = harness.mk()
      generators.kinds.ccA = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 0,  shape = 'step' },
          { ppq = 60,             val = 40, shape = 'step' },
          { ppq = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'augment', dest = 10, label = 'CcA', defaults = {}, fields = {},
      }
      generators.kinds.ccB = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 0,  shape = 'step' },
          { ppq = 60,             val = 10, shape = 'step' },
          { ppq = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'augment', dest = 10, label = 'CcB', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', {
        { uuid = 'r1', chan = 1, startppq = 0, endppq = 240, fx = { { kind = 'ccA' } } },
        { uuid = 'r2', chan = 1, startppq = 0, endppq = 240, fx = { { kind = 'ccB' } } },
      })
      h.tm:rebuild()
      generators.kinds.ccA, generators.kinds.ccB = nil, nil

      t.eq(ccFillAt(h, 1, 10, 60).val, 114, 'overlap sums rest 64 + macroA 40 + macroB 10 -- no stream dropped')
      t.eq(ccFillAt(h, 1, 10, 0).val,  64,  'both macros anchor 0 at the window edge -> base rest alone')
    end,
  },

  {
    -- The window diff is what has to notice: the old target's window vanishes and a new one appears
    -- in the same rebuild, so restore and park have to both land off one reconcile.
    name = 'fx region (cc): retargeting a stage restores the old controller and parks the new one',
    run = function(harness)
      local h = harness.mk()
      local function ccsOn(cc)
        local out = {}
        for _, c in ipairs(h.fm:dump().ccs) do
          if c.evType == 'cc' and c.chan == 1 and c.cc == cc then out[#out + 1] = c end
        end
        return out
      end
      local pan = { kind = 'sine', period = { 1, 2 }, depth = 32, dest = 10 }
      h.tm:addEvent({ evType = 'cc', ppq = 60, chan = 1, cc = 10, val = 30 }); h.tm:flush()
      h.tm:addEvent({ evType = 'cc', ppq = 60, chan = 1, cc = 1,  val = 20 }); h.tm:flush()

      injectRegion(h, { fx = { pan } })
      local parked = stashOfType(h, 'cc')
      t.eq(#parked, 1, 'the covered cc10 parks off-take')
      t.eq(parked[1].cc, 10, 'and it is the pan controller that parked')
      t.eq(#ccsOn(1), 1, 'the mod wheel is untouched -- no window covers it')

      injectRegion(h, { fx = { generators.retarget(pan, 1) } })
      local swapped = stashOfType(h, 'cc')
      t.eq(#swapped, 1, 'exactly one cc is parked after the swap')
      t.eq(swapped[1].cc, 1, "cc1 parks in cc10's place")
      local restored = ccsOn(10)
      t.eq(#restored, 1, 'cc10 carries only its authored event again -- its seats are gone')
      t.eq(restored[1].val, 30, 'and it comes back with the value it was authored at')
      t.truthy(#ccsOn(1) > 1, 'while the pan curve now seats on the mod wheel')
    end,
  },

  {
    name = 'note-host augment (cc): a sounding note drives summed seats like a degenerate region',
    run = function(harness)
      local h = harness.mk()
      generators.kinds.ccCap = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 0,  shape = 'step' },
          { ppq = 60,             val = 25, shape = 'step' },
          { ppq = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'augment', dest = 10, label = 'CcCap', defaults = {}, fields = {},
      }
      -- The note carries its own fx: an augment host stays on the take (unparked) and drives cc over its span.
      local function seatMap()
        local m = {}
        for _, c in ipairs(h.fm:dump().ccs) do
          if c.evType == 'cc' and c.cc == 10 and c.chan == 1 then m[c.ppq] = c.val end
        end
        return m
      end
      addNote(h, { pitch = 60, ppq = 0, endppq = 240, lane = 1, fx = { { kind = 'ccCap' } } })

      local seat = seatMap()
      t.deepEq(authoredPitches(h), { 60 }, 'the augment host keeps sounding -- it is not parked')
      t.eq(seat[0],  64, 'the note-host window seats base rest 64 + macro 0 at the start')
      t.eq(seat[60], 89, 'and rest 64 + macro delta 25 at the peak')

      h.tm:rebuild()   -- kind still registered: seats must be recognized, re-summed, not swept or duplicated
      generators.kinds.ccCap = nil
      t.eq(seatMap()[60], 89, 'the summed seat is stable across a no-change rebuild')
    end,
  },

  ----- Parked members bound a preceding on-take tail (symmetric to realiseParked's bounds)

  {
    name = 'replace: a preceding on-take tail clips at the parked chord onset, not past it',
    run = function(harness)
      local h = harness.mk()
      -- A voice on lane 2 running into the region; before the region it clips at 240 against its
      -- lane successor. The successor is the retrig host -- parking it must not free the clip.
      addNote(h, { pitch = 62, ppq = 0,   endppq = 480, lane = 2 })   -- note A: authored ceiling 480
      addNote(h, { pitch = 60, ppq = 240, endppq = 480, lane = 2 })   -- host inside the region
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 240, endppq = 480,
                                   fx = { { kind = 'retrig', period = { 1, 4 }, ramp = 0 } } } })
      h.tm:rebuild()
      local a
      for _, evt in ipairs(h.tm:getChannel(1).columns.notes[2].events) do
        if evt.pitch == 62 then a = evt end
      end
      t.truthy(a, 'note A is on the take, lane 2')
      t.eq(a.endppqC, 240, 'note A clips at the parked host onset (240), not its authored ceiling (480)')
    end,
  },

  {
    name = 'replace: a derived tile is not truncated by a parked member it replaced',
    run = function(harness)
      local h = harness.mk()
      -- Two consecutive lane-1 notes; both park. A parked member onsets at 90, mid-way through the
      -- second tile [60,120). The tile must reach 120 -- a non-sounding parked note cannot cut it.
      addNote(h, { pitch = 60, ppq = 0,  endppq = 90,  lane = 1 })
      addNote(h, { pitch = 62, ppq = 90, endppq = 240, lane = 1 })
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240,
                                   fx = { { kind = 'retrig', period = { 1, 4 }, ramp = 0 } } } })
      h.tm:rebuild()
      local tileAt60
      for _, n in ipairs(h.fm:dump().notes) do
        if n.derived == 'fxr-1' and n.ppq == 60 then tileAt60 = n end
      end
      t.truthy(tileAt60, 'the retrig tile at onset 60 exists')
      t.eq(tileAt60.endppq, 120, 'the tile spans its full step to 120, not clipped to the parked onset 90')
    end,
  },

  ----- Parked-host continuous windows: deleting a self-parked fx host sweeps its seats

  {
    name = 'deleting a self-parked [trill, sine] host leaves no orphaned pb seats',
    run = function(harness)
      local h = harness.mk()
      -- trill (note-replace) self-parks the host; sine (pb-augment) seats a pb stream over the
      -- parked window. The chain is on the note's own fx, so it parks with no take round-trip.
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                      vel = 100, detune = 0, delay = 0, lane = 1,
                      fx = { { kind = 'trill', period = { 1, 4 }, cents = 200 },
                             { kind = 'sine', period = { 1, 4 }, depth = 30, onset = 0 } } })
      h.tm:flush()
      local function allPbs()
        local out = {}
        for _, c in ipairs(h.fm:dump().ccs) do
          if c.evType == 'pb' and c.chan == 1 then out[#out + 1] = c end
        end
        return out
      end
      t.truthy(#allPbs() > 0, 'the parked host seats a sine pb stream')
      t.eq(#h.tm:getChannel(1).parked, 1, 'the trill host is parked off-take')

      h.tm:rebuild()   -- settle: parked host is now off-take when the window set is recomputed

      h.tm:deleteParked(h.tm:getChannel(1).parked[1]); h.tm:flush()
      t.falsy(h.ds:get('fxParked'), 'the parked host is gone from the stash')
      t.eq(#allPbs(), 0, 'no sine seat orphans as an authored pb after the host is deleted')
    end,
  },

  {
    -- Removing the last note-dest kind un-parks the host, but a surviving continuous kind still governs
    -- its cc target and must persist its window. see docs/generators.md § Route-by-window
    name = 'removing the note kind from a self-parked [sine, trill] host keeps its authored cc parked',
    run = function(harness)
      local h = harness.mk()
      -- Authored cc10 the augment parks; values distinct from the sine output so a stray restore shows.
      h.tm:addEvent({ evType = 'cc', ppq = 60,  chan = 1, cc = 10, val = 20 });  h.tm:flush()
      h.tm:addEvent({ evType = 'cc', ppq = 180, chan = 1, cc = 10, val = 100 }); h.tm:flush()

      -- Note-host: sine (cc10-augment) parks the authored cc and seats a derived stream over the window.
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
                      detune = 0, delay = 0, lane = 1,
                      fx = { { kind = 'sine', period = { 1, 4 }, depth = 32, dest = 10 } } })
      h.tm:flush()
      local uuid = h.tm:getChannel(1).columns.notes[1].events[1].uuid
      t.truthy(uuid, 'the on-take host carries a uuid')
      t.eq(#stashOfType(h, 'cc'), 2, 'sine parks both authored cc off-take')

      -- The realised cc10 (on-take derived seats) + the parked authored stash, as an order-stable
      -- fingerprint. Add-then-remove trill is a round-trip: this must return to its pre-trill value.
      local function ccFingerprint()
        local seats = {}
        for _, c in ipairs(h.fm:dump().ccs) do
          if c.evType == 'cc' and c.cc == 10 and c.chan == 1 then
            seats[#seats + 1] = { ppq = c.ppq, val = c.val }
          end
        end
        table.sort(seats, function(a, b)
          if a.ppq ~= b.ppq then return a.ppq < b.ppq end
          return a.val < b.val
        end)
        local parked = {}
        for _, s in ipairs(stashOfType(h, 'cc')) do parked[#parked + 1] = { ppq = s.ppq, val = s.val } end
        table.sort(parked, function(a, b) return a.ppq < b.ppq end)
        return { seats = seats, parked = parked }
      end
      local baseline = ccFingerprint()
      t.eq(#baseline.parked, 2, 'both authored cc parked in the baseline')

      -- Add trill: the host now self-parks as a note; the sine cc window must persist.
      h.vm:addFxStage(uuid, { kind = 'trill', period = { 1, 4 }, cents = 200 })
      t.eq(#h.tm:getChannel(1).parked, 1, 'the host self-parks once a note-replace kind joins the chain')
      t.eq(#stashOfType(h, 'cc'), 2, 'the authored cc stay parked under the persisting sine window')

      -- Remove trill: the host un-parks as a note; sine still governs cc10, so its window must
      -- persist -- the authored cc carry forward parked, not restore onto the take under the seats.
      local fx = h.vm:noteFx(uuid); local trillIdx
      for i, e in ipairs(fx) do if e.kind == 'trill' then trillIdx = i end end
      h.vm:removeFxStage(uuid, trillIdx)

      t.deepEq(ccFingerprint(), baseline, 'the cc realisation round-trips: seats + parked stash unchanged')
    end,
  },

  {
    -- The placement fixpoint's one-step closure: continuous membership reads post-settlement windows,
    -- so a window widened by a same-pass note park parks its exposed cc now, not after the next
    -- same-channel dirt. see docs/trackerManager.md § The placement fixpoint
    name = 'a same-pass note park widens a surviving host window and parks the exposed authored cc',
    run = function(harness)
      local h = harness.mk()
      -- Plain successor on the host's lane: it clips the host's sine window to [0, 240).
      addNote(h, { ppq = 240, endppq = 480, pitch = 64 })
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 960, chan = 1, pitch = 60, vel = 100,
                      detune = 0, delay = 0, lane = 1,
                      fx = { { kind = 'sine', period = { 1, 4 }, depth = 32, dest = 10 } } })
      h.tm:flush()
      -- Authored cc10 in the span the successor hides: outside [0, 240), inside [0, 960).
      -- Identified by uuid, since the augment's fill seats fold the authored base val back in.
      h.tm:addEvent({ evType = 'cc', ppq = 480, chan = 1, cc = 10, val = 3 }); h.tm:flush()
      local authoredUuid
      for _, c in ipairs(h.fm:dump().ccs) do
        if c.evType == 'cc' and c.cc == 10 and c.ppq == 480 then authoredUuid = c.uuid end
      end
      t.truthy(authoredUuid, 'the authored cc landed on the take')
      t.eq(#stashOfType(h, 'cc'), 0, 'the clipped window reaches no authored cc')

      -- The region parks the successor; with its onset gone the host window widens to its
      -- authored ceiling in the same pass, so the exposed cc must park in this rebuild.
      injectArp(h, { startppq = 240, endppq = 480 })
      local stash = stashOfType(h, 'cc')
      t.eq(#stash, 1, 'the exposed authored cc parks in the same pass')
      t.eq(stash[1].ppq, 480, 'the parked spec is the exposed cc')
      for _, c in ipairs(h.fm:dump().ccs) do
        t.truthy(c.uuid ~= authoredUuid, 'the authored cc left the take; only fill seats remain')
      end
    end,
  },

  ----- Freeze to raw: the region's output becomes plain authored MIDI and the region goes

  {
    name = 'freeze: the derived chord is promoted to authored, and region + stash go with it',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, lane = 1 })
      addNote(h, { pitch = 64, lane = 2 })
      addNote(h, { pitch = 67, lane = 3 })
      injectArp(h)
      t.eq(#derivedNotes(h), 4, 'the arp seats four steps over the parked triad')
      t.deepEq(authoredPitches(h), {}, 'and the triad itself is off the take')

      t.truthy(h.tm:freezeEligible('fxr-1'), 'the eligibility map agrees nothing refuses this')
      t.truthy(h.tm:freezeRegion('fxr-1'), 'the freeze reports success')

      t.deepEq(authoredPitches(h), { 60, 60, 64, 67 }, 'the derived steps are authored MIDI now')
      t.eq(#derivedNotes(h), 0, 'nothing on the take still carries the region tag')
      t.deepEq(columnPitches(h, 1), { 60, 60, 64, 67 },
        'and they are in the grid, not merely on the wire')
      t.falsy(h.ds:get('fxRegions'),  'the region is gone -- nil, not an empty array')
      t.falsy(h.ds:get('fxParked'),   'its parked members are destroyed with it')
      t.falsy(h.ds:get('prevWindows'),'and its windows leave the recognition baseline')
    end,
  },

  {
    name = 'freeze: the standing reconcile does not restore the destroyed members',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, lane = 1 })
      addNote(h, { pitch = 64, lane = 2 })
      injectArp(h)
      t.truthy(h.tm:freezeRegion('fxr-1'))

      h.tm:rebuild(true)   -- takeChanged: a whole re-derive, where rebuild(nil) would short-circuit
      t.deepEq(authoredPitches(h), { 60, 60, 64, 64 }, 'the promoted notes stand')
      t.eq(#derivedNotes(h), 0, 'nothing re-derives -- there is no region left to produce it')
      t.falsy(h.ds:get('fxParked'), 'and the park reconcile has nothing to restore')
    end,
  },

  {
    name = 'freeze: the seated pb curve stands as authored automation',
    run = function(harness)
      local h = harness.mk()
      injectRegion(h)
      local function byPpq(a, b) return a.ppq < b.ppq end
      local function wireSeats()
        local out = {}
        for _, c in ipairs(h.fm:dump().ccs) do
          if c.evType == 'pb' and c.chan == 1 then out[#out + 1] = c.ppq end
        end
        table.sort(out)
        return out
      end
      -- A live seat is raw-only on the wire -- markerless, no cents sidecar (it is RAM-only, lost on
      -- a take round-trip). Freeze hands it to the pb pass, which authors the cents from that raw.
      local before, beforeSeats = {}, wireSeats()
      for _, c in ipairs(derivedPbs(h, 1)) do
        before[#before + 1] = { ppq = c.ppq, val = rawToCents(c.val) }
      end
      table.sort(before, byPpq)
      t.truthy(#before > 0, 'the region seated a pb curve')
      t.falsy(h.tm:getChannel(1).columns.pb, 'live, the seats are wire-only -- off screen')

      t.truthy(h.tm:freezeRegion('fxr-1'))

      -- The seat helpers at the head of this file recognise a seat by live window membership, and
      -- freeze removes the window -- so this reads the column and the wire directly.
      local col = h.tm:getChannel(1).columns.pb
      t.truthy(col, 'frozen, the curve comes on screen as authored automation')
      local after = {}
      for _, e in ipairs(col.events) do after[#after + 1] = { ppq = e.ppq, val = e.val } end
      table.sort(after, byPpq)
      t.deepEq(after, before, 'every breakpoint stands unchanged, in the cents it was authored in')
      t.deepEq(wireSeats(), beforeSeats, 'and the same breakpoints still sound')
    end,
  },

  {
    name = 'freeze: a promoted note keeps the tail the walk clipped for it',
    run = function(harness)
      local h = harness.mk()
      -- A stage may emit past its own window (chordStamp does, off the trigger's ceiling), so this
      -- one runs onto a lane an authored note occupies after the region.
      generators.kinds.overrun = {
        expand = function(stream) return { notes = {
          { ppq = stream.window[1], endppq = 480, pitch = 60, vel = 100, detune = 0 },
        }, delta = {} } end,
        mode = 'replace', dest = 'note', label = 'Overrun', defaults = {}, fields = {},
      }
      addNote(h, { pitch = 60, ppq = 0,   endppq = 120, lane = 2 })   -- the region's member
      addNote(h, { pitch = 62, ppq = 240, endppq = 480, lane = 1 })   -- past the window, on lane 1
      injectArp(h, { endppq = 120, fx = { { kind = 'overrun' } } })

      local function pitch60()
        for _, n in ipairs(h.fm:dump().notes) do if n.pitch == 60 then return n end end
      end
      t.eq(pitch60().endppq, 240, 'derived, it reaches the walk as an extra and clips at lane 1')

      t.truthy(h.tm:freezeRegion('fxr-1'))
      generators.kinds.overrun = nil
      -- Promotion swaps which door the note enters the tail walk by -- extras, to the raw index
      -- under walkable(). A promoted note that lost its ppqL would read as foreign MIDI and be
      -- walked by neither, and its tail would spring back to the authored 480.
      t.eq(pitch60().endppq, 240, 'promoted, it enters by the index instead and the clip stands')
    end,
  },

  {
    name = 'freeze: the whole projection rides one flush and one rebuild',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, lane = 1 })
      injectArp(h)
      local rebuilds = 0
      h.tm:subscribe('rebuild', function() rebuilds = rebuilds + 1 end)
      h.tm:freezeRegion('fxr-1')
      t.eq(rebuilds, 1, 'one rebuild -- a half-frozen region would be a third event lifecycle')
    end,
  },

  {
    name = 'freeze (mixed chain): the arp is authored and the cc seats keep their column',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, lane = 1 })
      addNote(h, { pitch = 64, lane = 2 })
      generators.kinds.ccRep = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 100, shape = 'step' },
        } } end,
        mode = 'replace', dest = 74, label = 'CcRep', defaults = {}, fields = {},
      }
      injectArp(h, { fx = { arpUp[1], { kind = 'ccRep' } } })
      t.falsy(h.tm:getChannel(1).columns.ccs[74], 'live, the seat is routed out of columns')

      -- The stub stays registered across the call: freeze recomputes the windows to drop, and
      -- parkWindows skips a stage whose kind is nil -- the cc window would outlive its region.
      t.truthy(h.tm:freezeRegion('fxr-1'))
      generators.kinds.ccRep = nil

      t.deepEq(authoredPitches(h), { 60, 60, 64, 64 }, 'the arp output is authored')
      local col = h.tm:getChannel(1).columns.ccs[74]
      t.truthy(col and #col.events > 0, 'and the cc seats stand in the column, not just on the take')
    end,
  },

  ----- Freeze to raw: a note host freezes through the same core, parked or on the take

  {
    name = 'freeze (parked host): the trill output is authored and the host leaves the stash',
    run = function(harness)
      local h = harness.mk()
      -- trill (note-replace) self-parks the host; sine (pb-augment) seats a pb stream over the parked
      -- window, so one freeze must convert both arms of the chain.
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                      vel = 100, detune = 0, delay = 0, lane = 1,
                      fx = { { kind = 'trill', period = { 1, 4 }, cents = 200 },
                             { kind = 'sine', period = { 1, 4 }, depth = 30, onset = 0 } } })
      h.tm:flush()
      h.tm:rebuild()   -- settle: the host is off-take when the window set is recomputed
      -- No region here, so the seat helpers at the head of this file cannot see these seats: live they
      -- are wire-only, and coming on screen is exactly what freezing them means.
      local function pbSeats()
        local out = {}
        for _, c in ipairs(h.fm:dump().ccs) do
          if c.evType == 'pb' and c.chan == 1 then out[#out + 1] = c.ppq end
        end
        table.sort(out)
        return out
      end
      local before = pbSeats()
      t.truthy(#before > 0, 'the parked host seats a sine pb stream')
      t.falsy(h.tm:getChannel(1).columns.pb, 'live, the seats are wire-only -- off screen')

      local uuid = h.tm:getChannel(1).parked[1].uuid
      t.truthy(h.tm:freezeRegion(uuid), 'the freeze reports success')

      t.truthy(#authoredPitches(h) > 0, 'the trill output stands as authored notes')
      t.falsy(h.ds:get('fxParked'), 'the host leaves the stash -- nil, not an empty array')
      t.eq(#h.tm:getChannel(1).parked, 0, 'and nothing is parked off-take any more')
      t.truthy(h.tm:getChannel(1).columns.pb, 'the pb curve comes on screen as authored automation')
      t.deepEq(pbSeats(), before, 'and the same breakpoints still sound')

      h.tm:rebuild(true)   -- takeChanged: a whole re-derive, where rebuild(nil) would short-circuit
      t.truthy(#authoredPitches(h) > 0, 'the promoted notes stand')
      t.falsy(h.ds:get('fxParked'), 'and the standing reconcile has nothing to restore')
    end,
  },

  {
    name = 'freeze (on-take host): the cc curve is authored and the host keeps its note',
    run = function(harness)
      local h = harness.mk()
      -- Authored cc10 the sine augment parks; values distinct from its output so a stray restore shows.
      h.tm:addEvent({ evType = 'cc', ppq = 60,  chan = 1, cc = 10, val = 20 });  h.tm:flush()
      h.tm:addEvent({ evType = 'cc', ppq = 180, chan = 1, cc = 10, val = 100 }); h.tm:flush()
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
                      detune = 0, delay = 0, lane = 1,
                      fx = { { kind = 'sine', period = { 1, 4 }, depth = 32, dest = 10 } } })
      h.tm:flush()
      local uuid = h.tm:getChannel(1).columns.notes[1].events[1].uuid
      t.eq(#stashOfType(h, 'cc'), 2, 'sine parks both authored cc off-take')
      -- The authored cc parked out of it, so the column shell stands empty rather than vanishing.
      local live = h.tm:getChannel(1).columns.ccs[10]
      t.eq(#(live and live.events or {}), 0, 'live, nothing on cc10 is on screen -- seats and authored both off')

      t.truthy(h.tm:freezeRegion(uuid), 'the freeze reports success')

      t.deepEq(authoredPitches(h), { 60 }, 'a continuous-only host keeps its note on the take')
      local rec = h.tm:byUuid(uuid)
      t.truthy(rec, 'the host is still indexed')
      t.falsy(rec.fx, 'but carries no chain -- freeze took it')
      t.falsy(h.ds:get('fxParked'), 'the authored cc it parked are destroyed with the window')
      t.falsy(h.ds:get('prevWindows'), 'and its window leaves the recognition baseline')
      local col = h.tm:getChannel(1).columns.ccs[10]
      t.truthy(col and #col.events > 0, 'the cc seats stand in the column as authored automation')
    end,
  },

  {
    -- assembleParkWindows runs every parked note spec carrying fx, so a continuous-only host parked by
    -- *another* live region still produces. see design/archive/fx-freeze.md § Freeze to raw
    name = 'freeze (host parked by a region): the chain goes, the note stays parked',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
                      detune = 0, delay = 0, lane = 1, fx = sine30 })
      h.tm:flush()
      injectArp(h)   -- note-replace over the same span: the region parks the sine host
      t.eq(#h.tm:getChannel(1).parked, 1, 'the region parks the host off-take')
      local uuid = h.tm:getChannel(1).parked[1].uuid

      t.truthy(h.tm:freezeRegion(uuid), 'the freeze reports success')

      local specs = stashOfType(h, 'note')
      t.eq(#specs, 1, 'the host is still parked -- the region that parks it is untouched')
      t.eq(specs[1].uuid, uuid, 'and it is the same note spec')
      t.falsy(specs[1].fx, 'stripped of the chain freeze took')
      t.eq(#(h.ds:get('fxRegions') or {}), 1, 'the region survives the freeze')
      t.truthy(#derivedNotes(h) > 0, 'and still produces its arp output')
      t.truthy(h.tm:getChannel(1).columns.pb, 'the sine curve is authored automation now')
    end,
  },

  {
    name = 'freeze declines on a plain note and changes nothing',
    run = function(harness)
      local h = harness.mk()
      addNote(h)
      injectRegion(h)   -- a live region over the same span must not be swept by a miss
      local uuid = h.tm:getChannel(1).columns.notes[1].events[1].uuid
      t.falsy(h.tm:freezeEligible(uuid), 'no chain: absent from the producer census, absent from the map')
      t.falsy(h.tm:freezeRegion(uuid), 'a note carrying no chain is not a host')
      t.deepEq(authoredPitches(h), { 60 }, 'the note stands')
      t.eq(#(h.ds:get('fxRegions') or {}), 1, 'and so does the region')
    end,
  },

  ----- The producer census: prevWindows carries one entry per producer

  {
    -- The persisted window set is the seat-recognition baseline and the freeze gates' census both, so a
    -- producer counted twice keeps an entry alive after its own freeze. see design/archive/fx-freeze.md
    name = 'park windows: a self-parking note host contributes one window, not two',
    run = function(harness)
      local h = harness.mk()
      -- trill (note-replace) self-parks the host: its cell leaves columns at once, but the fx-host
      -- index names it until the tail-walk commit, so the census has to be told about the park.
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                      vel = 100, detune = 0, delay = 0, lane = 1,
                      fx = { { kind = 'trill', period = { 1, 4 }, cents = 200 },
                             { kind = 'sine', period = { 1, 4 }, depth = 30, onset = 0 } } })
      h.tm:flush()
      h.tm:rebuild()   -- settle: the host is off-take when the window set is recomputed
      t.eq(#h.tm:getChannel(1).parked, 1, 'the trill parks its own host')

      local windows = h.ds:get('prevWindows') or {}
      t.eq(#windows, 1, 'one producer, one entry')
      t.eq(windows[1] and windows[1].evType, 'pb', 'the sine arm -- a note host seats no note window')
      t.eq(windows[1] and windows[1].id, h.tm:getChannel(1).parked[1].uuid,
           "stamped with its producer's identity")
    end,
  },

  {
    -- The same stale fact the census guarded against, at a reader that doesn't: fx expansion enumerates
    -- a self-parking host twice, and foldChains sums the two pb curves (`sine` folds as augment).
    name = 'park windows: a self-parking note host runs its chain once, not twice',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                      vel = 100, detune = 0, delay = 0, lane = 1,
                      fx = { { kind = 'trill', period = { 1, 4 }, cents = 200 },
                             { kind = 'sine', period = { 1, 4 }, depth = 30, onset = 0 } } })
      h.tm:flush()
      h.tm:rebuild()

      -- Every pb on the wire is a chain seat: the trill parks the host, so nothing authored survives
      -- to be read as one, and a note host's seats sit in no fxRegion for derivedPbs to find.
      local peak = 0
      for _, c in ipairs(h.fm:dump().ccs) do
        if c.evType == 'pb' and c.chan == 1 then peak = math.max(peak, math.abs(c.val)) end
      end
      t.eq(peak, centsToRaw(30), 'the chain runs once: the sine peaks at its authored depth')
    end,
  },

  ----- Global regions: channel 0 expands into a producer on every channel

  {
    -- A chan-0 region is stored once and runs sixteen times: the head snapshot the pipeline takes
    -- replaces it with one ordinary region per channel. see design/global-fx-column.md § Expansion
    name = 'global region: one stored region runs a chain on every channel it reaches',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { chan = 1, pitch = 60 })
      addNote(h, { chan = 7, pitch = 67 })
      h.ds:assign('fxRegions', { { uuid = 'fxr-g', chan = 0, startppq = 0, endppq = 240, fx = arpUp } })
      h.tm:rebuild()

      t.deepEq(field(derivedFor(h, 1, expanded('fxr-g', 1)), 'pitch'), { 60, 60, 60, 60 },
               'channel 1 runs the global chain over its own member')
      t.deepEq(field(derivedFor(h, 7, expanded('fxr-g', 7)), 'pitch'), { 67, 67, 67, 67 },
               'and channel 7 over its own')
      t.deepEq(authoredPitches(h), {}, 'each channel parks its own chord under the replace chain')
    end,
  },

  {
    -- The persisted window set is the seat-recognition baseline, so an expanded producer's identity
    -- has to survive a rebuild unchanged. see design/global-fx-column.md § Derived identity is stable
    name = 'global region: sixteen producers in the window set, with stable derived identities',
    run = function(harness)
      local h = harness.mk()
      addNote(h)
      h.ds:assign('fxRegions', { { uuid = 'fxr-g', chan = 0, startppq = 0, endppq = 240, fx = arpUp } })
      h.tm:rebuild()

      local windows = h.ds:get('prevWindows') or {}
      t.eq(#windows, 16, 'one note window per expanded producer')
      local ids, chans = {}, {}
      for _, w in ipairs(windows) do ids[w.id] = true; chans[w.chan] = true end
      t.truthy(ids[expanded('fxr-g', 1)] and ids[expanded('fxr-g', 16)],
               'each stamped with the identity its own channel derives')
      t.falsy(ids['fxr-g'], 'the stored uuid names no producer of its own')
      t.falsy(chans[0], 'and nothing runs on channel 0')

      addNote(h, { chan = 2, pitch = 64 })   -- fresh dirt: channel 2 re-derives from the same region
      h.tm:rebuild()
      t.deepEq(h.ds:get('prevWindows'), windows, 'a second rebuild derives the same identities')
    end,
  },

  {
    -- Storage order is precedence among chains overlapping on one channel, and the expansion emits a
    -- channel's own regions before the producers expanded onto it, whatever order storage holds them
    -- in. see design/global-fx-column.md § Precedence
    name = 'global region: a global chain packs after a channel region stored before it',
    run = function(harness)
      local h = harness.mk()
      addNote(h)
      -- Two note-replace chains, each stamping a pitch of its own: both park the member, so the lane
      -- each lands on is the order the two producers were emitted in.
      local function stamp(pitch)
        return { expand = function(stream)
                   return { notes = { { ppq = stream.window[1], endppq = stream.window[2],
                                        pitch = pitch, vel = 100, detune = 0 } }, delta = {} }
                 end,
                 mode = 'replace', dest = 'note', label = 'Stamp', defaults = {}, fields = {} }
      end
      generators.kinds.stampG, generators.kinds.stampC = stamp(72), stamp(74)
      h.ds:assign('fxRegions', {
        { uuid = 'fxr-g', chan = 0, startppq = 0, endppq = 240, fx = { { kind = 'stampG' } } },
        { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240, fx = { { kind = 'stampC' } } },
      })
      h.tm:rebuild()
      generators.kinds.stampG, generators.kinds.stampC = nil, nil

      t.deepEq(field(derivedFor(h, 1, 'fxr-1'), 'lane'), { 1 },
               "the channel's own chain takes the free lane")
      t.deepEq(field(derivedFor(h, 1, expanded('fxr-g', 1)), 'lane'), { 2 },
               'and the global chain packs after it')
    end,
  },

  {
    -- The stored region carries the intent, so the edit arrives on channel 0; dirt seeded there
    -- reaches no derivation and the pass falls to the rebuild(∅) gate.
    -- see design/global-fx-column.md § An edit reaches sixteen channels
    name = 'global region: editing the region re-derives every channel it reaches',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { chan = 7, pitch = 67 })
      h.ds:assign('fxRegions', { { uuid = 'fxr-g', chan = 0, startppq = 0, endppq = 240, fx = arpUp } })
      h.tm:rebuild()
      t.eq(#derivedFor(h, 7, expanded('fxr-g', 7)), 4, 'the chain runs the full window on channel 7')

      h.ds:assign('fxRegions', { { uuid = 'fxr-g', chan = 0, startppq = 0, endppq = 120, fx = arpUp } })
      h.tm:rebuild()
      t.eq(#derivedFor(h, 7, expanded('fxr-g', 7)), 2, 'and halving its window reaches channel 7 too')
    end,
  },

  ----- Freeze gates: refusals computed over the producer census, by owner identity

  {
    -- Same target, overlapping windows: freezing either would leave the other's producer standing
    -- over raw output it did not make. Refusal is silent. see design/archive/fx-freeze.md § Eligibility gates
    name = 'freeze gate (overlapping regions): neither freezes, and nothing changes',
    run = function(harness)
      local h = harness.mk()
      addNote(h)   -- a member both arps park, so each region has real output at stake
      h.ds:assign('fxRegions', {
        { uuid = 'fxr-1', chan = 1, startppq = 0,   endppq = 240, fx = arpUp },
        { uuid = 'fxr-2', chan = 1, startppq = 120, endppq = 360, fx = arpUp },
      })
      h.tm:rebuild()
      local regions, windows, parked =
        h.ds:get('fxRegions'), h.ds:get('prevWindows'), h.ds:get('fxParked')

      t.falsy(h.tm:freezeEligible('fxr-1'), 'the map refuses the earlier region')
      t.falsy(h.tm:freezeEligible('fxr-2'), 'and the later')
      t.falsy(h.tm:freezeRegion('fxr-1'), 'the earlier region is refused')
      t.falsy(h.tm:freezeRegion('fxr-2'), 'and so is the later one')

      t.deepEq(h.ds:get('fxRegions'), regions, 'both regions stand')
      t.deepEq(h.ds:get('prevWindows'), windows, 'the recognition baseline is untouched')
      t.deepEq(h.ds:get('fxParked'), parked, 'and nothing left the stash')
    end,
  },

  {
    -- Two chord-mates carrying the same pb chain hold identical windows, so each sits inside the
    -- other's: the fold is mutual, and neither can go first.
    name = 'freeze gate (identical-window neighbour): mutual same-target overlap refuses both',
    run = function(harness)
      local h = harness.mk()
      for lane, pitch in ipairs({ 60, 67 }) do
        h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = pitch,
                        vel = 100, detune = 0, delay = 0, lane = lane, fx = sine30 })
        h.tm:flush()
      end
      local lanes = h.tm:getChannel(1).columns.notes
      t.eq(#(h.ds:get('prevWindows') or {}), 2, 'two on-take hosts, two identical pb windows')

      t.falsy(h.tm:freezeEligible(lanes[1].events[1].uuid), 'the map refuses the first host')
      t.falsy(h.tm:freezeEligible(lanes[2].events[1].uuid), 'and its chord-mate')
      t.falsy(h.tm:freezeRegion(lanes[1].events[1].uuid), 'the first host is refused')
      t.falsy(h.tm:freezeRegion(lanes[2].events[1].uuid), 'and so is its chord-mate')

      t.eq(#(h.ds:get('prevWindows') or {}), 2, 'both baseline entries stand')
      for lane = 1, 2 do
        t.truthy(h.tm:getChannel(1).columns.notes[lane].events[1].fx, 'each host keeps its chain')
      end
    end,
  },

  {
    -- The re-centre folds at endppq-1, so abutting pb windows no longer share a boundary seat: coverage
    -- is half-open for pb exactly as for cc, and abutting is genuinely disjoint on both.
    name = 'freeze gate (abutting windows): neither pb nor cc refuses -- no boundary seat is shared',
    run = function(harness)
      local h = harness.mk()
      h.ds:assign('fxRegions', {
        { uuid = 'fxr-1', chan = 1, startppq = 0,   endppq = 240, fx = sine30 },
        { uuid = 'fxr-2', chan = 1, startppq = 240, endppq = 480, fx = sine30 },
      })
      h.tm:rebuild()
      t.truthy(h.tm:freezeEligible('fxr-1'), 'the map clears the earlier pb region')
      t.truthy(h.tm:freezeEligible('fxr-2'), 'and the later -- abutting windows do not overlap')
      t.truthy(h.tm:freezeRegion('fxr-1'), 'and the freeze goes through')

      local sineCc = { { kind = 'sine', period = { 1, 4 }, depth = 32, dest = 10 } }
      local h2 = harness.mk()
      h2.ds:assign('fxRegions', {
        { uuid = 'fxr-1', chan = 1, startppq = 0,   endppq = 240, fx = sineCc },
        { uuid = 'fxr-2', chan = 1, startppq = 240, endppq = 480, fx = sineCc },
      })
      h2.tm:rebuild()
      t.truthy(h2.tm:freezeEligible('fxr-1'), 'the map clears both abutting cc regions')
      t.truthy(h2.tm:freezeEligible('fxr-2'), 'cc coverage is half-open, so neither refuses')
      t.truthy(h2.tm:freezeRegion('fxr-1'), 'abutting cc windows are disjoint, so the freeze runs')
    end,
  },

  {
    -- The region's note window covers the host's onset, so freezing the region would leave the
    -- host's producer running over raw arp notes. Freezing the host first is the recourse.
    name = 'freeze gate (covered fx host): the region waits for the host it parks',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
                      detune = 0, delay = 0, lane = 1, fx = sine30 })
      h.tm:flush()
      injectArp(h)   -- note-replace over the same span: the region parks the sine host
      local uuid = h.tm:getChannel(1).parked[1].uuid

      t.falsy(h.tm:freezeEligible('fxr-1'), 'the map refuses the covering region')
      t.truthy(h.tm:freezeEligible(uuid), 'but clears the covered host itself')
      t.falsy(h.tm:freezeRegion('fxr-1'), 'refused while it covers a producing host')

      t.truthy(h.tm:freezeRegion(uuid), "the host freezes -- its own pb window overlaps nobody's")
      t.falsy(stashOfType(h, 'note')[1].fx, 'and stays parked, stripped of the chain')
      t.truthy(h.tm:freezeEligible('fxr-1'), "the host's freeze-rebuild moved the map")
      t.truthy(h.tm:freezeRegion('fxr-1'), 'with no producer left under it, the region freezes')
    end,
  },

  {
    -- A note-dest host presents no window of its own (its note arm is suppressed), so no other
    -- producer can refuse it: the inverse gate asks whether a neighbour's note window covers it.
    name = 'freeze gate (inverse): a note-dest host under a region note window is refused',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
                      detune = 0, delay = 0, lane = 1,
                      fx = { { kind = 'trill', period = { 1, 4 }, cents = 200 } } })
      h.tm:flush()
      h.tm:rebuild()   -- settle: the trill parks its own host
      local uuid = h.tm:getChannel(1).parked[1].uuid
      injectArp(h, { startppq = 120, endppq = 360 })

      t.falsy(h.tm:freezeEligible(uuid), 'the map refuses the note-dest host under the note window')
      t.falsy(h.tm:freezeRegion(uuid), 'the trill host is refused')
      t.truthy(stashOfType(h, 'note')[1].fx, 'and keeps its chain, still parked')
    end,
  },

  {
    -- Freeze drops the frozen producer's own baseline entries by their stamped id: a same-target
    -- neighbour whose window is disjoint keeps its entry and its curve. see design/archive/fx-freeze.md
    name = 'freeze (disjoint same-target neighbour): the survivor keeps its window and its curve',
    run = function(harness)
      local h = harness.mk()
      h.ds:assign('fxRegions', {
        { uuid = 'fxr-1', chan = 1, startppq = 0,   endppq = 240, fx = sine30 },
        { uuid = 'fxr-2', chan = 1, startppq = 480, endppq = 720, fx = sine30 },
      })
      h.tm:rebuild()
      t.eq(#(h.ds:get('prevWindows') or {}), 2, 'two producers, two pb windows on the same target')

      t.truthy(h.tm:freezeEligible('fxr-1'), 'disjoint windows: the map clears the freeze')
      t.truthy(h.tm:freezeRegion('fxr-1'), 'the freeze reports success')

      local baseline = h.ds:get('prevWindows') or {}
      t.eq(#baseline, 1, "only the frozen producer's window leaves the baseline")
      t.eq(baseline[1] and baseline[1].id, 'fxr-2',
           "the surviving entry carries the neighbour's identity, not just its value")
      t.falsy(h.ds:get('fxParked'), "the survivor's window is not newly created, so it sweeps nothing")
      t.truthy(#derivedPbs(h, 1) > 0, 'and its curve still sounds')
    end,
  },

  {
    -- The partition is by producer, not by window value: a chain's own two pb windows are both
    -- `mine`, and mine is never held against itself.
    name = 'freeze gate (two stages, one target): a chain does not refuse itself',
    run = function(harness)
      local h = harness.mk()
      injectRegion(h, { fx = { sine30[1],
                               { kind = 'sine', period = { 1, 2 }, depth = 20, onset = 0 } } })
      t.eq(#(h.ds:get('prevWindows') or {}), 2, 'one producer, two pb windows')
      t.truthy(h.tm:freezeEligible('fxr-1'), 'mine is never held against itself in the map either')
      t.truthy(h.tm:freezeRegion('fxr-1'), 'its own windows are not a neighbour')
    end,
  },

  {
    -- The census's three arms all answer "what is committed", while freeze's own closing flush commits
    -- whatever was staged: an unflushed host is invisible to the gate and then minted by the freeze,
    -- landing a live window over the seats just frozen. Freeze settles first.
    -- see design/archive/fx-freeze.md § Eligibility gates
    name = 'freeze gate (staged host pending): freeze settles the take before reading the census',
    run = function(harness)
      local h = harness.mk()
      injectRegion(h)   -- pb region [0,240) on chan 1
      -- Staged and deliberately not flushed: a chord-mate carrying the same chain, so once it is
      -- committed the two hold identical pb windows and refuse each other.
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 67, vel = 100,
                      detune = 0, delay = 0, lane = 2, fx = sine30 })

      -- Pinned seam, not an aspiration: the map reads the last rebuild's census, where the staged
      -- host does not exist, while the verb settles first and sees it. In exactly this divergence the
      -- verb's flush lands the pending op inside its undo block, so the block is non-empty anyway.
      t.truthy(h.tm:freezeEligible('fxr-1'), 'the staged neighbour is invisible to the map')
      t.falsy(h.tm:freezeRegion('fxr-1'), 'the pending host is a same-target neighbour: refused')

      t.eq(#(h.ds:get('fxRegions') or {}), 1, 'the region stands')
      t.eq(#h.tm:getChannel(1).columns.notes[2].events, 1, 'and the staged host is on the take')
    end,
  },

  {
    -- Rebuild output, not a cache with invalidation: the map is replaced wholesale at each rebuild's
    -- coherence point, so it moves exactly when the census can. see design/archive/fx-freeze.md § Eligibility gates
    name = 'freeze eligibility: the map moves with rebuild',
    run = function(harness)
      local h = harness.mk()
      h.ds:assign('fxRegions', {
        { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240, fx = sine30 },
        { uuid = 'fxr-2', chan = 1, startppq = 0, endppq = 240, fx = sine30 },
      })
      h.tm:rebuild()
      t.falsy(h.tm:freezeEligible('fxr-1'), 'identical windows refuse mutually')
      t.falsy(h.tm:freezeEligible('fxr-2'), 'in both directions')

      h.ds:assign('fxRegions', {
        { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240, fx = sine30 },
      })
      h.tm:rebuild()
      t.truthy(h.tm:freezeEligible('fxr-1'), "the survivor's map entry flips on the next rebuild")
    end,
  },

  {
    -- The rect a freeze-to-group mint would claim: the producer's own span, and one streamId per
    -- stream its output actually stands on. see design/archive/fx-freeze.md § Freeze to group
    name = 'freeze rect: the footprint of a mixed note-and-curve output',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, lane = 1 })
      addNote(h, { pitch = 64, lane = 2 })   -- covered by the window, but nothing is produced onto it
      injectArp(h, { fx = { arpUp[1], sine30[1] } })

      t.deepEq(h.tm:freezeRect('fxr-1'),
        { ppq = 0, dur = 240, chanLo = 1,
          streams = { [0] = { ['note:1'] = true, ['pb:0'] = true } } },
        'the lane the derived notes landed on plus the pb target, and lane 2 absent')
    end,
  },

  {
    name = 'freeze rect: a continuous-only host claims no note lane',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { fx = sine30 })
      local uuid = h.tm:getChannel(1).columns.notes[1].events[1].uuid

      t.deepEq(h.tm:freezeRect(uuid),
        { ppq = 0, dur = 240, chanLo = 1, streams = { [0] = { ['pb:0'] = true } } },
        'the host stays authored rather than becoming output, so its own lane is not in the rect')
    end,
  },

  {
    name = 'freeze rect: nil for a uuid that is not a producer',
    run = function(harness)
      local h = harness.mk()
      addNote(h)
      injectRegion(h)   -- a live producer over the same span must not answer for the note
      local uuid = h.tm:getChannel(1).columns.notes[1].events[1].uuid
      t.falsy(h.tm:freezeRect(uuid), 'a plain note has no footprint to claim')
    end,
  },

  {
    -- Rebuild output, not a cache with invalidation -- the same standing as the eligibility map.
    name = 'freeze rect: the map moves with rebuild',
    run = function(harness)
      local h = harness.mk()
      injectRegion(h)
      t.truthy(h.tm:freezeRect('fxr-1'), 'the live producer has a rect')

      h.ds:assign('fxRegions', util.REMOVE)
      h.tm:rebuild()
      t.falsy(h.tm:freezeRect('fxr-1'), 'and it is gone on the rebuild that drops the producer')
    end,
  },

  ----- Freeze to group: the conversion thins its curves, then hands back the mint material

  {
    -- The thin runs inside freeze's own staging block, so what it drops is never authored at all and
    -- the closing rebuild back-derives cents on the survivors alone. see design/archive/fx-freeze.md § Freeze to group
    name = 'freeze to group: the dense curve re-seats sparse in one flush',
    run = function(harness)
      local h = harness.mk()
      injectRegion(h, { fx = denseRamp() })
      local before = wirePbs(h, 1, 0, 240)
      t.eq(#before, RAMP_N + 1, 'the ramp seats a breakpoint every 10 ticks, and tm closes above them')

      local rebuilds = 0
      h.tm:subscribe('rebuild', function() rebuilds = rebuilds + 1 end)
      t.truthy(h.tm:freezeToGroup('fxr-1'), 'the freeze reports its members')
      generators.kinds.denseRamp = nil

      t.eq(rebuilds, 1, 'one rebuild -- the thin rides the conversion rather than a pass of its own')
      -- Every seat is inside the window to begin with, where the rect a mint claims can cover it --
      -- freeze moves nothing. see docs/generators.md § Route-by-window
      t.deepEq(wirePbs(h, 1, 0, 240), { before[1], before[RAMP_N], before[RAMP_N + 1] },
        'a collinear run inside tolerance comes back as its endpoints, plus the close that breaks the run')
    end,
  },

  {
    -- Two curve points can want the one tick material may hold. The fold collapses them there rather
    -- than doubling up, below tm's close. see docs/generators.md § Route-by-window
    name = 'freeze to group: material at the fold line collapses onto one tick, below the close',
    run = function(harness)
      local h = harness.mk()
      injectRegion(h, { fx = edgePair() })
      local members = h.tm:freezeToGroup('fxr-1')
      generators.kinds.edgePair = nil
      t.truthy(members, 'the freeze reports its members')

      t.deepEq(wirePbs(h, 1, 230, 240), { { ppq = 238, cents = 80 }, { ppq = 239, cents = 0 } },
        'one pb on the fold line carrying the later of the two, and tm\'s close on the tick above it')
      local atDest
      for _, m in ipairs(members) do if m.ppq == 238 then atDest = m end end
      t.truthy(atDest, 'and the collapsed seat is group material')
    end,
  },

  {
    -- gm mints from column events: authored frame, no raw sidecar. A member carrying ppqL would put
    -- the group's offsets in raw ticks against a logical anchor. see design/archive/fx-freeze.md § Freeze to group
    name = 'freeze to group: the members come back in the authored frame',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, lane = 1 })
      addNote(h, { pitch = 64, lane = 2 })
      -- Lane-1 detune landing on the window's closing edge: the absorber it seats is realisation,
      -- hidden from the column, and must not cross into the group.
      addNote(h, { pitch = 67, lane = 1, ppq = 240, endppq = 480, detune = 25 })
      injectArp(h, { fx = { arpUp[1], denseRamp()[1] } })

      local members = h.tm:freezeToGroup('fxr-1')
      generators.kinds.denseRamp = nil
      t.truthy(members, 'the freeze hands back its members')

      local notes, curve = {}, {}
      for _, m in ipairs(members) do
        t.falsy(m.ppqL, 'no member carries the raw sidecar')
        if m.pitch then notes[#notes + 1] = m else curve[#curve + 1] = m end
      end
      local pitches = {}
      for _, n in ipairs(notes) do pitches[#pitches + 1] = n.pitch end
      t.deepEq(pitches, { 60, 64, 60, 64 }, 'the promoted arp notes are members')

      local col = h.tm:getChannel(1).columns.pb
      local live, hiddenInWindow = {}, 0
      for _, e in ipairs(col.events) do
        live[e] = true
        if e.hidden and e.ppq >= 0 and e.ppq <= 240 then hiddenInWindow = hiddenInWindow + 1 end
      end
      t.truthy(hiddenInWindow > 0, 'the detune seats an absorber inside the window bounds')
      t.eq(#curve, 3, 'and the curve members are the thinned survivors alone')
      for _, m in ipairs(curve) do t.truthy(live[m], 'each member is the live column event itself') end
    end,
  },

  {
    -- The discriminator between a durable member and a seat: a seat reaches the take as markerless
    -- native MIDI, and mm re-mints its uuid in RAM on every load. see design/archive/fx-freeze.md § Freeze to group
    name = 'freeze to group: a surviving breakpoint keeps its identity across a take reload',
    run = function(harness)
      local h = harness.mk()
      injectRegion(h, { fx = denseRamp() })
      local members = h.tm:freezeToGroup('fxr-1')
      generators.kinds.denseRamp = nil
      t.truthy(members and members[1], 'the freeze hands back its members')
      local uuid  = members[1].uuid
      local cents = h.tm:byUuid(uuid).cents

      h.tm:reloadFromReaper()

      local entry = h.tm:byUuid(uuid)
      t.truthy(entry, 'the member uuid resolves against the reloaded take')
      t.eq(entry.cents, cents, 'and still carries the cents the freeze authored')
    end,
  },

  {
    -- The bounded thin bites only where something genuinely dense stands: a curved point governs a
    -- segment no chord can stand in for, so it is a hard keep.
    name = 'freeze to group: a curved macro freezes exact',
    run = function(harness)
      local h = harness.mk()
      injectRegion(h)   -- sine30: 'slow' extrema, every one of them a hard keep
      local before = wirePbs(h, 1, 0, 240)
      local members = h.tm:freezeToGroup('fxr-1')
      t.truthy(members, 'the freeze reports its members')
      -- Verbatim bar the closing seat, which the conversion pulls inside the window.
      local expected = util.deepClone(before)
      expected[#expected].ppq = 239
      t.deepEq(wirePbs(h, 1, 0, 240), expected, 'a curved stream has nothing the thinner may drop')
      t.eq(#members, #before, 'and every breakpoint comes back as a member')
      local shapes = {}
      for _, m in ipairs(members) do shapes[m.shape] = (shapes[m.shape] or 0) + 1 end
      t.eq(shapes.slow, #members - 1, 'each keeps the curve shape it was authored with')
      t.eq(shapes.step, 1, 'bar the closed window\'s terminal re-centre, which is a step by construction')
    end,
  },

  {
    name = 'freeze to group declines on a plain note and changes nothing',
    run = function(harness)
      local h = harness.mk()
      addNote(h)
      injectRegion(h)   -- a live region over the same span must not be swept by a miss
      local uuid = h.tm:getChannel(1).columns.notes[1].events[1].uuid
      t.falsy(h.tm:freezeToGroup(uuid), 'a note carrying no chain is not a host')
      t.deepEq(authoredPitches(h), { 60 }, 'the note stands')
      t.eq(#(h.ds:get('fxRegions') or {}), 1, 'and so does the region')
    end,
  },

}
