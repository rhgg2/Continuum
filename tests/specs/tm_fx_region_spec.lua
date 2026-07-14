-- Note macros v2: region hosts. The N=0 vibrato pb seat stream proves the generator-side substrate
-- (ds, 4.6 producer split, reconcile, G4 round-trip). see design/note-macros-v2.md
local t          = require('support')
local util       = require('util')
local generators = require('generators')

-- depth 30c, period 1/4 QN: at res 240 one cycle = 60 ticks; sine extrema at
-- ppqL 15 (peak) / 45 (trough); stream anchored 0 at both window ends.
local vib30 = { { kind = 'vibrato', period = { 1, 4 }, depth = 30, onset = 0 } }

local function centsToRaw(cents, pbRange)
  return util.round(cents * 8192 / ((pbRange or 2) * 100))
end

-- A seat is recognized purely by region membership: any pb inside a live region's span (bounds
-- inclusive of endppq, so the terminal re-centre seat counts). see design/note-macros-v2.md § Route-by-window
local function inPbWindow(h, chan, ppq)
  for _, r in ipairs(h.ds:get('fxRegions') or {}) do
    if r.chan == chan and ppq >= r.startppq and ppq <= r.endppq then return true end
  end
  return false
end

-- An authored pb on the wire: one no live pb window covers (a covered pb is a seat). `val` is raw
-- (centsToRaw of wire-cents + detune); `cents` the persisted intent. nil while a window parks it off.
local function authoredPb(h, chan, ppq)
  for _, c in ipairs(h.fm:dump().ccs) do
    if c.evType == 'pb' and c.chan == chan and c.ppq == ppq and not inPbWindow(h, chan, ppq) then return c end
  end
end

-- The pb column projects intent: the event's `val` is the authored cents (stays visible even when
-- a replace region overwrites the wire).
local function colPbCents(h, chan, ppq)
  for _, e in ipairs((h.tm:getChannel(chan).columns.pb or {}).events or {}) do
    if e.ppq == ppq then return e.val end
  end
end

-- The seated curve of a pb-replace region, hidden from columns. Seats are markerless -- there is no
-- marker to filter on; the live window IS their identity. Recognized purely by region membership.
local function derivedPbs(h, chan)
  local out = {}
  for _, c in ipairs(h.fm:dump().ccs) do
    if c.evType == 'pb' and c.chan == chan and inPbWindow(h, chan, c.ppq) then out[#out + 1] = c end
  end
  return out
end

local function derivedPb(h, chan, ppq)
  for _, c in ipairs(derivedPbs(h, chan)) do if c.ppq == ppq then return c end end
end

-- The cc / pb slice of the unified fxParked off-take stash.
local function stashOfType(h, evType)
  local out = {}
  for _, s in ipairs(h.ds:get('fxParked') or {}) do
    if s.evType == evType then out[#out + 1] = s end
  end
  return out
end

-- Half-open region membership on a channel (matches production's covered()): a cc-replace seat lives
-- in [startppq, endppq). see design/note-macros-v2.md § Route-by-window
local function inCcSpan(h, chan, ppq)
  for _, r in ipairs(h.ds:get('fxRegions') or {}) do
    if r.chan == chan and ppq >= r.startppq and ppq < r.endppq then return true end
  end
  return false
end

-- The seated replace curve on a cc target, hidden from columns. Seats are markerless -- the live region
-- span IS their identity; the authored cc it covers is parked off-take.
local function fillRecords(h, chan, cc)
  local out = {}
  for _, c in ipairs(h.fm:dump().ccs) do
    if c.evType == 'cc' and c.cc == cc and c.chan == chan and inCcSpan(h, chan, c.ppq) then
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
       and not c.derived and not inCcSpan(h, chan, ppq) then return c end
  end
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
      out[#out + 1] = { ppq = n.ppq, pitch = n.pitch, lane = n.lane, vel = n.vel }
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

  ----- N=0 -- a region with no host note still seats the channel pb stream

  {
    name = 'fx region (N=0): vibrato over a span seats a free-LFO pb stream with no host note',
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

  ----- Window end re-centres (channel-wide, region-sourced)

  {
    name = 'fx region: pb seats re-centre the channel at the region window end',
    run = function(harness)
      local h = harness.mk()
      injectRegion(h)
      local seats = derivedPbs(h, 1)
      table.sort(seats, function(a, b) return a.ppq < b.ppq end)
      local last = seats[#seats]
      t.eq(last.ppq, 240, 'terminal seat sits at the region window end (closed span)')
      t.eq(last.val, centsToRaw(0), 'terminal value is centre -- no residual channel bend')
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

  ----- B3 step 2: parked specs are logical-only and carry the identity the backing addresses by

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
      t.eq(stash[1].ppqL, 0, 'the stash keeps the logical onset')
      t.eq(stash[1].ppq, nil, 'the stash drops realised ppq -- logical-only')
      t.eq(stash[1].endppq, nil, 'the stash drops realised endppq -- logical-only')
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
    name = 'park identity (cc): render cell carries chan+ppqL; the fxParkedCC stash is logical-only',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'cc', ppq = 60, chan = 1, cc = 74, val = 30 }); h.tm:flush()
      generators.kinds.ccRep = {
        expand = function(host) return { notes = {}, delta = {
          { ppqL = host.window[1], val = 100, shape = 'step' },
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
      t.eq(parked[1].ppqL, 60, 'the render cell carries the logical onset (the backing key)')
      local stash = stashOfType(h, 'cc')
      t.eq(stash[1].ppqL, 60, 'the stash keeps the logical onset')
      t.eq(stash[1].ppq, nil, 'the stash drops realised ppq -- logical-only')
    end,
  },

  ----- B3 step 3: parked edits stage on tm and ride flush (no inline ds write)

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
      h.tm:addParked({ evType = 'note', chan = 1, lane = 1, ppqL = 120, endppqL = 240,
                       pitch = 72, vel = 100, detune = 0, delay = 0 })
      h.tm:flush()
      local stash = h.ds:get('fxParked')
      t.eq(#stash, 2, 'the authored 60 and the typed 72 both sit in the stash')
      local typed
      for _, s in ipairs(stash) do if s.pitch == 72 then typed = s end end
      t.truthy(typed, 'the typed note is stashed')
      t.eq(typed.uuid, 'fxp-1', 'a window-authored parked note mints an fxp uuid')
      t.eq(typed.ppq, nil, 'the stashed spec stays logical-only')
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
          { ppqL = host.window[1], val = 100, shape = 'step' },
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
    -- Restore lands on a ppq the fill already seats; cc's ppq-token key means a naive add collides,
    -- and the fill reconcile then deletes the restored event by that shared token.
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
          for ppqL = host.window[1], host.window[2] - 1, 60 do
            delta[#delta + 1] = { ppqL = ppqL, val = 100, shape = 'step' }
          end
          return { notes = {}, delta = delta }
        end,
        mode = 'replace', dest = 74, label = 'CcRep', defaults = {}, fields = {},
      }

      -- Grow: window covers both authored cc; both park off-take.
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240,
                                   fx = { { kind = 'ccRep' } } } })
      local grown = {}
      for _, s in ipairs(stashOfType(h, 'cc')) do grown[s.ppqL] = s.val end

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
      t.eq(stillParked[1].ppqL, 60, 'the still-covered cc is the one left parked')
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
      local rebuilds = 0
      h.tm:subscribe('rebuild', function() rebuilds = rebuilds + 1 end)
      h.tm:assignParked(h.tm:getChannel(1).parked[1], { pitch = 67 }); h.tm:flush()
      t.eq(rebuilds, 1, 'a parked-only flush still rebuilds exactly once')
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

  ----- Augment by kind: a continuous region leaves its members sounding (no parking)

  {
    name = 'augment by kind: a continuous (vibrato) region leaves its covered notes sounding',
    run = function(harness)
      local h = harness.mk()
      addNote(h, { pitch = 60, ppq = 0, endppq = 240, lane = 1 })
      injectRegion(h)   -- vibrato over [0,240) covers the note -- augment, so it is not parked
      t.deepEq(authoredPitches(h), { 60 }, 'the covered note keeps sounding -- a continuous kind augments')
      t.truthy(#derivedPbs(h, 1) > 0, 'and the vibrato pb seats are present over the span')
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
      t.deepEq(captured.ccs[74], { { ppqL = 0,   val = 50, shape = 'step' },
                                   { ppqL = 60,  val = 50, shape = 'step' },
                                   { ppqL = 240, val = 50, shape = 'step' } },
        'authored cc 74 buckets into host.ccs as an absolute curve with entering/closing edge values')
      t.deepEq(captured.ats, { { ppqL = 180, val = 33 } }, 'channel aftertouch into host.ats')
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
      t.eq(byPitch[60].endppqL, 120, 'the OPEN member clips to the next same-lane onset')
      t.eq(byPitch[67].endppqL, 240, 'the trailing member fills to the window end')
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
      t.deepEq(captured.pb, { { ppqL = 0,   val = 50, shape = 'step' },
                              { ppqL = 60,  val = 50, shape = 'step' },
                              { ppqL = 240, val = 50, shape = 'step' } },
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
          { ppqL = host.window[1], val = 50, shape = 'step' },
          { ppqL = 60,             val = 50, shape = 'step' },
          { ppqL = host.window[2], val = 0,  shape = 'step' },
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
      t.eq(derivedPb(h, 1, 240).val, 0,              'the terminal seat re-centres at the window end')
      local at120
      for _, p in ipairs(h.tm:getChannel(1).parkedPb) do if p.ppqL == 120 then at120 = p end end
      t.eq(at120 and at120.val, 40, 'the authored 40c stays visible via the parkedPb render union')
    end,
  },

  {
    name = 'fx region: pb replace with no authored base seats the curve verbatim',
    run = function(harness)
      local h = harness.mk()
      generators.kinds.capRep = {
        expand = function(host)
          return { notes = {}, delta = {
            { ppqL = host.window[1], val = 50, shape = 'step' },
            { ppqL = host.window[2], val = 0,  shape = 'step' },
          } }
        end,
        mode = 'replace', dest = 'pb', label = 'CapRep', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240,
                                   fx = { { kind = 'capRep' } } } })
      h.tm:rebuild()
      generators.kinds.capRep = nil

      t.eq(derivedPb(h, 1, 0).val,   centsToRaw(50), 'seated at the curve start (50c)')
      t.eq(derivedPb(h, 1, 240).val, 0,              'seat re-centres at the window end')
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
          { ppqL = host.window[1], val = 50, shape = 'step' },
          { ppqL = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'replace', dest = 'pb', label = 'CapRep', defaults = {}, fields = {},
      }
      generators.kinds.bump = {
        expand = function(host) return { notes = {}, delta = {
          { ppqL = host.window[1], val = 0,  shape = 'step' },
          { ppqL = 60,             val = 20, shape = 'step' },
          { ppqL = 120,            val = 0,  shape = 'step' },
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
      t.eq(derivedPb(h, 1, 240).val, 0,              'the terminal seat re-centres at the window end')
    end,
  },

  {
    name = 'fx chain (continuous): [augment, replace] -- the replace stage overwrites the folded stream',
    run = function(harness)
      local h = harness.mk()
      generators.kinds.bump = {
        expand = function(host) return { notes = {}, delta = {
          { ppqL = host.window[1], val = 0,  shape = 'step' },
          { ppqL = 60,             val = 20, shape = 'step' },
          { ppqL = 120,            val = 0,  shape = 'step' },
        } } end,
        mode = 'augment', dest = 'pb', label = 'Bump', defaults = {}, fields = {},
      }
      generators.kinds.capRep = {
        expand = function(host) return { notes = {}, delta = {
          { ppqL = host.window[1], val = 50, shape = 'step' },
          { ppqL = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'replace', dest = 'pb', label = 'CapRep', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240,
                                   fx = { { kind = 'bump' }, { kind = 'capRep' } } } })
      h.tm:rebuild()
      generators.kinds.capRep, generators.kinds.bump = nil, nil

      t.eq(derivedPb(h, 1, 0).val, centsToRaw(50), 'the replace curve owns the window start')
      t.falsy(derivedPb(h, 1, 60), 'the earlier augment bump is overwritten -- no seat survives at 60')
      t.eq(derivedPb(h, 1, 240).val, 0, 'the terminal seat re-centres at the window end')
    end,
  },

  ----- Cross-chain: overlapping regions on one target layer by storage order (painter)

  {
    name = 'fx region (pb): two overlapping replace regions -- later storage wins pointwise, not summed',
    run = function(harness)
      local h = harness.mk()
      generators.kinds.capA = {
        expand = function(host) return { notes = {}, delta = {
          { ppqL = host.window[1], val = 30, shape = 'step' },
          { ppqL = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'replace', dest = 'pb', label = 'CapA', defaults = {}, fields = {},
      }
      generators.kinds.capB = {
        expand = function(host) return { notes = {}, delta = {
          { ppqL = host.window[1], val = 60, shape = 'step' },
          { ppqL = host.window[2], val = 0,  shape = 'step' },
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
          { ppqL = host.window[1], val = 0,  shape = 'step' },
          { ppqL = 60,             val = 20, shape = 'step' },
          { ppqL = 120,            val = 0,  shape = 'step' },
        } } end,
        mode = 'augment', dest = 'pb', label = 'Bump', defaults = {}, fields = {},
      }
      generators.kinds.capRep = {
        expand = function(host) return { notes = {}, delta = {
          { ppqL = host.window[1], val = 50, shape = 'step' },
          { ppqL = host.window[2], val = 0,  shape = 'step' },
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
    name = 'fx region (pb): overlapping replace regions with differing windows -- each owns its exclusive tail',
    run = function(harness)
      local h = harness.mk()
      -- r1 [120,360) at 30c, r2 [0,240) at 60c (later storage) wins the overlap [120,240); r1's exclusive
      -- tail [240,360) must survive at 30c, not be wiped by r2's whole curve. see design/note-macros-v2.md § The fx chain
      generators.kinds.capA = {
        expand = function(host) return { notes = {}, delta = {
          { ppqL = host.window[1], val = 30, shape = 'step' },
          { ppqL = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'replace', dest = 'pb', label = 'CapA', defaults = {}, fields = {},
      }
      generators.kinds.capB = {
        expand = function(host) return { notes = {}, delta = {
          { ppqL = host.window[1], val = 60, shape = 'step' },
          { ppqL = host.window[2], val = 0,  shape = 'step' },
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
      t.eq(derivedPb(h, 1, 360).val, 0,              'the terminal seat re-centres at the merged-span end')
    end,
  },

  {
    name = 'fx region (cc): two overlapping replace regions -- later storage wins, not the additive fold',
    run = function(harness)
      local h = harness.mk()
      generators.kinds.ccA = {
        expand = function(host) return { notes = {}, delta = {
          { ppqL = host.window[1], val = 30, shape = 'step' },
          { ppqL = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'replace', dest = 10, label = 'CcA', defaults = {}, fields = {},
      }
      generators.kinds.ccB = {
        expand = function(host) return { notes = {}, delta = {
          { ppqL = host.window[1], val = 90, shape = 'step' },
          { ppqL = host.window[2], val = 0,  shape = 'step' },
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
      -- exclusive tail carries only its own delta (base rest 64). see design/note-macros-v2.md § The fx chain
      generators.kinds.ccA = {
        expand = function(host) return { notes = {}, delta = {
          { ppqL = host.window[1], val = 0,  shape = 'step' },
          { ppqL = 60,             val = 40, shape = 'step' },
          { ppqL = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'augment', dest = 10, label = 'CcA', defaults = {}, fields = {},
      }
      generators.kinds.ccB = {
        expand = function(host) return { notes = {}, delta = {
          { ppqL = host.window[1], val = 0,  shape = 'step' },
          { ppqL = 180,            val = 10, shape = 'step' },
          { ppqL = host.window[2], val = 0,  shape = 'step' },
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
      -- pin that the reconcile/token layer matches them across a steady-state rebuild (G4 for sub-splits).
      generators.kinds.capA = {
        expand = function(host) return { notes = {}, delta = {
          { ppqL = host.window[1], val = 30, shape = 'step' },
          { ppqL = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'replace', dest = 'pb', label = 'CapA', defaults = {}, fields = {},
      }
      generators.kinds.capB = {
        expand = function(host) return { notes = {}, delta = {
          { ppqL = host.window[1], val = 60, shape = 'step' },
          { ppqL = host.window[2], val = 0,  shape = 'step' },
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
          { ppqL = host.window[1], val = 30, shape = 'step' },
          { ppqL = host.window[2], val = 0,  shape = 'step' },
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
      t.eq(derivedPb(h, 1, 240).val, centsToRaw(25), 'curve re-centres to detune-only at the window end (I1)')
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
          { ppqL = host.window[1], val = 50, shape = 'step' },
          { ppqL = host.window[2], val = 0,  shape = 'step' },
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
          { ppqL = host.window[1], val = 0,  shape = 'slow' },
          { ppqL = host.window[2], val = 60, shape = 'slow' },
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
      t.eq(derivedPb(h, 1, 240).val, centsToRaw(80), 'end seat exact (60c curve + 20c detune)')

      -- The detune step rides a dual point at the onset: same 30c curve value, detune jumps 0 -> 20.
      t.eq(derivedPb(h, 1, 119).val, centsToRaw(30), 'just-before the onset: 30c curve, detune 0')
      t.eq(derivedPb(h, 1, 120).val, centsToRaw(50), 'at the onset: 30c curve, detune 20 -- the step')
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
            delta[#delta + 1] = { ppqL = host.window[1] + span * i // 12,
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
        t.eq(s.uuid, nil, 'every seat is markerless -- no uuid means no eventMeta sidecar')
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
            delta[#delta + 1] = { ppqL = host.window[1] + span * i // 12,
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
          { ppqL = host.window[1], val = 100, shape = 'step' },
          { ppqL = 120,            val = 20,  shape = 'step' },
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
          { ppqL = host.window[1], val = 100, shape = 'step' },
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
          { ppqL = host.window[1], val = 100, shape = 'step' },
          { ppqL = 120,            val = 20,  shape = 'step' },
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
          for i = 0, 11 do d[#d + 1] = { ppqL = i * 20, val = i * 8, shape = 'linear' } end
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
        t.eq(s.uuid, nil, 'a fill seat is markerless -- no uuid, no eventMeta sidecar')
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
          { ppqL = host.window[1], val = 0,  shape = 'step' },
          { ppqL = 60,             val = 30, shape = 'step' },
          { ppqL = host.window[2], val = 0,  shape = 'step' },
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
        t.eq(s.uuid, nil, 'an augment seat is markerless -- no uuid, no eventMeta sidecar')
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
          { ppqL = host.window[1], val = 0,  shape = 'step' },
          { ppqL = 60,             val = 30, shape = 'step' },
          { ppqL = host.window[2], val = 0,  shape = 'step' },
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
    name = 'fx region (cc augment): two overlapping regions sum every stream (N-stream regression guard)',
    run = function(harness)
      local h = harness.mk()
      generators.kinds.ccA = {
        expand = function(host) return { notes = {}, delta = {
          { ppqL = host.window[1], val = 0,  shape = 'step' },
          { ppqL = 60,             val = 40, shape = 'step' },
          { ppqL = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'augment', dest = 10, label = 'CcA', defaults = {}, fields = {},
      }
      generators.kinds.ccB = {
        expand = function(host) return { notes = {}, delta = {
          { ppqL = host.window[1], val = 0,  shape = 'step' },
          { ppqL = 60,             val = 10, shape = 'step' },
          { ppqL = host.window[2], val = 0,  shape = 'step' },
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
    name = 'fx region (cc augment): region.fx.rest overrides the default resting base',
    run = function(harness)
      local h = harness.mk()
      generators.kinds.ccCap = {
        expand = function(host) return { notes = {}, delta = {
          { ppqL = host.window[1], val = 0,  shape = 'step' },
          { ppqL = 60,             val = 10, shape = 'step' },
          { ppqL = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'augment', dest = 10, label = 'CcCap', defaults = {}, fields = {},   -- pan, default rest 64
      }
      local fx = { { kind = 'ccCap' } }; fx.rest = 100
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240, fx = fx } })
      h.tm:rebuild()
      generators.kinds.ccCap = nil

      t.eq(ccFillAt(h, 1, 10, 0).val,  100, 'region.fx.rest (100) overrides ccDefaultRest[10] (64) as the base')
      t.eq(ccFillAt(h, 1, 10, 60).val, 110, 'the override base 100 + macro delta 10 at the peak')
    end,
  },

  {
    name = 'note-host augment (cc): a sounding note drives summed seats like a degenerate region',
    run = function(harness)
      local h = harness.mk()
      generators.kinds.ccCap = {
        expand = function(host) return { notes = {}, delta = {
          { ppqL = host.window[1], val = 0,  shape = 'step' },
          { ppqL = 60,             val = 25, shape = 'step' },
          { ppqL = host.window[2], val = 0,  shape = 'step' },
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
    name = 'deleting a self-parked [trill, vibrato] host leaves no orphaned pb seats',
    run = function(harness)
      local h = harness.mk()
      -- trill (note-replace) self-parks the host; vibrato (pb-augment) seats a pb stream over the
      -- parked window. The chain is on the note's own fx, so it parks with no take round-trip.
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                      vel = 100, detune = 0, delay = 0, lane = 1,
                      fx = { { kind = 'trill', period = { 1, 4 }, step = 2 },
                             { kind = 'vibrato', period = { 1, 4 }, depth = 30, onset = 0 } } })
      h.tm:flush()
      local function allPbs()
        local out = {}
        for _, c in ipairs(h.fm:dump().ccs) do
          if c.evType == 'pb' and c.chan == 1 then out[#out + 1] = c end
        end
        return out
      end
      t.truthy(#allPbs() > 0, 'the parked host seats a vibrato pb stream')
      t.eq(#h.tm:getChannel(1).parked, 1, 'the trill host is parked off-take')

      h.tm:rebuild()   -- settle: parked host is now off-take when the window set is recomputed

      h.tm:deleteParked(h.tm:getChannel(1).parked[1]); h.tm:flush()
      t.falsy(h.ds:get('fxParked'), 'the parked host is gone from the stash')
      t.eq(#allPbs(), 0, 'no vibrato seat orphans as an authored pb after the host is deleted')
    end,
  },

  {
    -- Removing the last note-dest kind un-parks the host, but a surviving continuous kind still governs
    -- its cc target and must persist its window. see design/note-macros-v2.md § Route-by-window
    name = 'removing the note kind from a self-parked [autopan, trill] host keeps its authored cc parked',
    run = function(harness)
      local h = harness.mk()
      -- Authored cc10 the augment parks; values distinct from the autopan output so a stray restore shows.
      h.tm:addEvent({ evType = 'cc', ppq = 60,  chan = 1, cc = 10, val = 20 });  h.tm:flush()
      h.tm:addEvent({ evType = 'cc', ppq = 180, chan = 1, cc = 10, val = 100 }); h.tm:flush()

      -- Note-host: autopan (cc10-augment) parks the authored cc and seats a derived stream over the window.
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
                      detune = 0, delay = 0, lane = 1,
                      fx = { { kind = 'autopan', period = { 1, 4 }, depth = 32 } } })
      h.tm:flush()
      local uuid = h.tm:getChannel(1).columns.notes[1].events[1].uuid
      t.truthy(uuid, 'the on-take host carries a uuid')
      t.eq(#stashOfType(h, 'cc'), 2, 'autopan parks both authored cc off-take')

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
        for _, s in ipairs(stashOfType(h, 'cc')) do parked[#parked + 1] = { ppqL = s.ppqL, val = s.val } end
        table.sort(parked, function(a, b) return a.ppqL < b.ppqL end)
        return { seats = seats, parked = parked }
      end
      local baseline = ccFingerprint()
      t.eq(#baseline.parked, 2, 'both authored cc parked in the baseline')

      -- Add trill: the host now self-parks as a note; the autopan cc window must persist.
      h.vm:addFxStage(uuid, { kind = 'trill', period = { 1, 4 }, step = 2 })
      t.eq(#h.tm:getChannel(1).parked, 1, 'the host self-parks once a note-replace kind joins the chain')
      t.eq(#stashOfType(h, 'cc'), 2, 'the authored cc stay parked under the persisting autopan window')

      -- Remove trill: the host un-parks as a note; autopan still governs cc10, so its window must
      -- persist -- the authored cc carry forward parked, not restore onto the take under the seats.
      local fx = h.vm:noteFx(uuid); local trillIdx
      for i, e in ipairs(fx) do if e.kind == 'trill' then trillIdx = i end end
      h.vm:removeFxStage(uuid, trillIdx)

      t.deepEq(ccFingerprint(), baseline, 'the cc realisation round-trips: seats + parked stash unchanged')
    end,
  },

}
