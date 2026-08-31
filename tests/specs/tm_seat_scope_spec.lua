-- What a dirt seed closes to. Under seed dirt, rebuildPbs gates its work to a set of raw spans:
-- a pb inside one is cloned into the pass and reprojected, and the rest of the channel's pb column
-- carries over from the prior pass. No spans -- ungated -- means the whole channel re-derives.
-- see docs/trackerManager.md § Derivation dirt: the gated spine
--
-- The instrument is table identity. A reprojected cell is a fresh clone of its index entry and a
-- carried one is the prior pass's own table, so identity reads which side of the partition claimed
-- a tick. Every edit here leaves the pb values alone on purpose: the partition is the subject, and
-- a value diff would only restate what identity already says.
--
-- The fixture is three lane-1 notes at 0, 960 and 1920, none of them detuned, and authored pbs at
-- ticks chosen to straddle the span edges: 958/959/960 around the tick below an onset, and
-- 1920/1921 around the onset the span closes on. A settling rebuild leaves every cell fresh, so
-- the baseline carries no identity from the passes that built it.

local t    = require('support')
local util = require('util')

local PB_PPQS   = { 480, 958, 959, 960, 1440, 1920, 1921, 2400 }
local NOTE_PPQS = { 0, 960, 1920 }
local BASE_CENTS = 10

local function note(ppq, pitch, extra)
  local n = { evType = 'note', ppq = ppq, endppq = ppq + 240, chan = 1, pitch = pitch,
              vel = 100, lane = 1, detune = 0, delay = 0 }
  for k, v in pairs(extra or {}) do n[k] = v end
  return n
end

-- Authored through tm, so each event is minted the way an edit mints it.
local function fixture(harness)
  local h = harness.mk{ seed = { length = 4800 } }
  for i, ppq in ipairs(NOTE_PPQS) do h.tm:addEvent(note(ppq, 58 + 2 * i)) end
  for _, ppq in ipairs(PB_PPQS) do
    h.tm:addEvent({ evType = 'pb', ppq = ppq, chan = 1, val = BASE_CENTS, shape = 'step' })
  end
  h.tm:flush()
  h.tm:rebuild(true)
  return h
end

-- The channel's pb column by ppq. No swing here, so a cell's logical ppq is its raw one.
local function column(h)
  local col = h.tm:getChannel(1).columns.pb
  t.truthy(col, 'fixture check: the channel surfaces a pb column')
  local byPpq = {}
  for _, e in ipairs(col.events) do byPpq[e.ppq] = e end
  return byPpq
end

local function noteCell(h, ppq)
  for _, e in ipairs(h.tm:getChannel(1).columns.notes[1].events) do
    if e.ppq == ppq then return e end
  end
  t.truthy(false, 'fixture check: a lane-1 note stands at ' .. ppq)
end

local function mmPb(h, ppq)
  for _, cc in ipairs(h.fm:dump().ccs) do
    if cc.evType == 'pb' and cc.chan == 1 and cc.ppq == ppq then return cc end
  end
end

-- The partition an edit produced: `fresh` names the ppqs expected in scope, every other authored pb
-- must come back as the table the prior pass projected.
local function assertPartition(before, after, fresh, why)
  local inScope = {}
  for _, ppq in ipairs(fresh) do inScope[ppq] = true end
  for _, ppq in ipairs(PB_PPQS) do
    t.truthy(before[ppq] and after[ppq], 'fixture check: a cell at ' .. ppq .. ' on both passes')
    if inScope[ppq] then
      t.truthy(before[ppq] ~= after[ppq], why .. ': ' .. ppq .. ' is in scope, so it reprojects')
    else
      t.eq(after[ppq], before[ppq], why .. ': ' .. ppq .. ' is out of scope, so it carries')
    end
  end
end

return {

  {
    name = 'a lane-1 seed closes to one tick back and forward to the next lane-1 onset',
    run = function(harness)
      local h = fixture(harness)
      local before = column(h)

      h.tm:assignEvent(noteCell(h, 960), { vel = 90 })
      h.tm:flush()

      -- The span is closed at both ends: 959 (a tick under the seed) and 1920 (the next onset) are
      -- in, and 958 and 1921 are the ticks either side of it.
      assertPartition(before, column(h), { 959, 960, 1440, 1920 }, 'lane-1 seed at 960')
    end,
  },

  {
    name = 'a pb seed closes to the gap between the neighbouring authored pbs',
    run = function(harness)
      local h = fixture(harness)
      local before = column(h)

      h.tm:assignEvent(before[1440], { val = BASE_CENTS + 5 })
      h.tm:flush()

      -- 960 and 1920 bound the gap and are in scope with it; 959 and 1921 sit past them.
      assertPartition(before, column(h), { 960, 1440, 1920 }, 'pb seed at 1440')
    end,
  },

  {
    name = "a derived seat does not bound a pb seed's gap: only authored pbs do",
    run = function(harness)
      local h = harness.mk{ seed = { length = 7680 } }
      h.tm:addEvent(note(0, 60))
      h.tm:addEvent(note(1000, 62, { detune = 20 }))
      for _, ppq in ipairs({ 480, 1440, 2400 }) do
        h.tm:addEvent({ evType = 'pb', ppq = ppq, chan = 1, val = BASE_CENTS, shape = 'step' })
      end
      h.tm:flush()
      h.tm:rebuild(true)

      -- The absorber seat between the seed and the pb at 480 is derived output, not authored value.
      local before = column(h)
      t.truthy(before[1000] and before[1000].hidden, 'fixture check: a derived seat sits inside the gap')

      h.tm:assignEvent(before[1440], { val = BASE_CENTS + 5 })
      h.tm:flush()

      local after = column(h)
      t.truthy(after[480] ~= before[480], 'the gap reaches past the seat to the authored pb at 480')
      t.truthy(after[2400] ~= before[2400], 'and forward to the authored pb at 2400')
    end,
  },

  {
    name = 'a seed on a lane other than 1 closes to nothing',
    run = function(harness)
      local h = fixture(harness)
      local before = column(h)

      -- Lane-1 detune drives the pb stream (docs/tuning.md), so a note anywhere else moves no seat
      -- and contributes no span, leaving the whole column carried.
      h.tm:addEvent(note(1440, 65, { lane = 2 }))
      h.tm:flush()

      assertPartition(before, column(h), {}, 'lane-2 seed at 1440')
    end,
  },

  {
    name = 'a seed kind the branches do not recognise ungates the channel',
    run = function(harness)
      local h = fixture(harness)
      local before = column(h)

      -- A param-automation seed carries no lane and an evType outside the cc/at/pc family, so no
      -- branch can close it to a span. The conservative answer is the whole channel.
      h.tm:addEvent({ evType = 'pa', ppq = 1440, chan = 1, pitch = 60, vel = 90 })
      h.tm:flush()

      assertPartition(before, column(h), PB_PPQS, 'unrecognised seed')
    end,
  },

  {
    name = 'wholesale dirt ungates the channel',
    run = function(harness)
      local h = fixture(harness)
      local before = column(h)

      h.tm:rebuild(true)

      assertPartition(before, column(h), PB_PPQS, 'wholesale dirt')
    end,
  },

  {
    name = 'fresh derived lane-1 output ungates the channel',
    run = function(harness)
      -- A plain lane-1 add gates to its own span: the control for the trill below, which differs
      -- only in emitting derived lane-1 notes the absorber pass has never seated.
      local plain = fixture(harness)
      local beforePlain = column(plain)
      plain.tm:addEvent(note(1440, 65))
      plain.tm:flush()
      assertPartition(beforePlain, column(plain), { 1440, 1920 }, 'plain lane-1 add at 1440')

      local h = fixture(harness)
      local before = column(h)
      h.tm:addEvent(note(1440, 65, { fx = { { kind = 'trill', period = { 1, 8 }, cents = 200 } } }))
      h.tm:flush()

      assertPartition(before, column(h), PB_PPQS, 'fresh derived lane-1 output')
    end,
  },

  {
    name = 'the out-of-scope remainder carries verbatim, uuid and realised refreshed from the index',
    run = function(harness)
      -- A value the wire cannot express: were a carried cell re-derived from its raw, the round
      -- trip through centsToRaw would quantise it.
      local FRACTIONAL = 10.37
      local raw = util.round(FRACTIONAL * 8192 / 200)
      t.truthy(raw * 200 / 8192 ~= FRACTIONAL, 'fixture check: the raw window cannot express the value')

      local h = harness.mk{ seed = { length = 7680 } }
      h.tm:addEvent({ evType = 'pb', ppq = 3000, chan = 1, val = FRACTIONAL, shape = 'step' })
      h.tm:addEvent(note(800, 60))
      h.tm:flush()
      -- A detune onset seats an absorber, and the seat projects into the column before the commit
      -- that mints its uuid. see docs/tuning.md § Absorber reconciliation
      h.tm:addEvent(note(1000, 62, { detune = 20 }))
      h.tm:flush()

      local before = column(h)
      t.truthy(before[1000], 'fixture check: the detune onset seats an absorber')
      t.eq(before[1000].uuid, nil, 'fixture check: the fresh seat predates its committed uuid')

      -- A lane-1 add past everything: its span reaches from 4999 rightward, so the seat and the
      -- authored pb both fall outside it.
      h.tm:addEvent(note(5000, 67, { detune = 20 }))
      h.tm:flush()

      local after = column(h)
      t.eq(after[1000], before[1000], 'the out-of-scope seat is the prior pass\'s own table')
      t.eq(after[1000].uuid, mmPb(h, 1000).uuid, 'and its uuid is refreshed from the index')
      t.eq(after[1000].realised, true, 'as is realised, which the fresh projection had not set')
      t.eq(after[3000].val, FRACTIONAL, 'a carried value stands, untouched by a centsToRaw round trip')
    end,
  },

  {
    name = 'the first lane-1 onset is in scope on every gated pass',
    run = function(harness)
      local h = harness.mk{ seed = { length = 7680 } }
      h.tm:addEvent({ evType = 'pb', ppq = 3000, chan = 1, val = BASE_CENTS, shape = 'step' })
      h.tm:addEvent(note(800, 60))
      h.tm:flush()
      h.tm:addEvent(note(1000, 62, { detune = 20 }))
      h.tm:flush()
      h.tm:rebuild(true)

      local before = column(h)
      t.truthy(before[800] and before[3000], 'fixture check: the anchor seat and an authored pb')

      -- Any pass may seat, refresh or retire the anchor at the first lane-1 onset, so its point is
      -- in scope however far away the seed lies.
      h.tm:addEvent(note(5000, 67, { detune = 20 }))
      h.tm:flush()

      local after = column(h)
      t.truthy(after[800] ~= before[800], 'the anchor point reprojects')
      t.eq(after[3000], before[3000], 'while an authored pb as far from the seed carries')
    end,
  },
}
