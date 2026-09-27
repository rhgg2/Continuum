-- The pb column is the take's pb intent (docs/trackerManager.md § CC walk): authored pbs alone,
-- projected by the CC walk, each event's `val` its intent in cents. The base voice's detune at a
-- pb's onset is a cue emission stamps on it (docs/trackerManager.md § Two movements), so
-- `val + detune` is the cents it sounds. Absorbers are realisation and live in mm alone.
--
-- Under the default 2-semitone pbRange, 200 cents span 8192 raw, so 50 cents is raw 2048 exactly.

local t = require('support')

local function cents2raw(c) return math.floor(c * 8192 / 200 + 0.5) end

local function lane1Note(ppq, endppq, detune)
  return { ppq = ppq, endppq = endppq, chan = 1, pitch = 60, vel = 100, detune = detune, delay = 0, lane = 1 }
end

local function pbColumn(h, chan)
  return h.tm:getChannel(chan).onTake.pb
end

local function columnPbAt(h, chan, ppq)
  local col = pbColumn(h, chan)
  for _, e in ipairs(col and col.events or {}) do
    if e.ppq == ppq then return e end
  end
end

local function stashPbAt(h, chan, ppq)
  for _, spec in ipairs(h.ds:get('fxParked') or {}) do
    if spec.evType == 'pb' and spec.chan == chan and spec.ppq == ppq then return spec end
  end
end

local function mmPbs(h, chan)
  local out = {}
  for _, c in ipairs(h.fm:dump().ccs) do
    if c.evType == 'pb' and c.chan == chan then out[#out + 1] = c end
  end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
  return out
end

-- An fx seat is markerless: it carries no ppqL.
local function earliestSeat(h, chan)
  for _, c in ipairs(mmPbs(h, chan)) do
    if c.ppqL == nil then return c end
  end
end

-- A depth-0 sine over [120, 360): its contribution is zero, so each seat samples the pb base.
local function zeroSineHost()
  return { evType = 'note', ppq = 120, endppq = 360, chan = 1, pitch = 60, vel = 100,
           detune = 0, delay = 0, lane = 1,
           fx = { { kind = 'sine', period = { 1, 4 }, depth = 0, onset = 0 } } }
end

-- classic, shift 0.08 over a 1 QN tile: logical 120 sits at raw 139, logical 600 at raw 619.
local swungConfig = { project = { swings = { c58 = { factors = {
  { atom = 'classic', shift = 0.08, period = 1 } } } } } }

-- Linear pbs at logical 0 (0c) and 600 (100c) under swing, and the zero-sine host between them.
local function swungRampWithHost(harness)
  local h = harness.mk{ config = swungConfig }
  h.tm:addEvent({ evType = 'pb', ppq = 0,   chan = 1, val = 0,   shape = 'linear' })
  h.tm:addEvent({ evType = 'pb', ppq = 600, chan = 1, val = 100, shape = 'linear' })
  h.tm:flush()
  h.ds:assign('swing', { global = 'c58' })
  h.tm:addEvent(zeroSineHost())
  h.tm:flush()
  return h
end

local function mmPbAtLogical(h, chan, ppqL)
  for _, c in ipairs(mmPbs(h, chan)) do
    if c.ppqL == ppqL then return c end
  end
end

-- A pb-replace region over [0, 240) on chan 1, holding a flat 30c curve.
local function pbReplaceRegion(h)
  local generators = require('generators')
  generators.kinds.flatRep = {
    expand = function(host) return { notes = {}, delta = {
      { ppq = host.window[1], val = 30, shape = 'step' },
      { ppq = host.window[2], val = 0,  shape = 'step' },
    } } end,
    mode = 'replace', dest = 'pb', label = 'FlatRep', defaults = {}, fields = {},
  }
  h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, ppq = 0, endppq = 240,
                               fx = { { kind = 'flatRep' } } } })
  h.tm:rebuild()
  return function() generators.kinds.flatRep = nil end
end

return {

  -- Absorbers and synthesised PCs live in mm alone (§ CC walk): the column holds no
  -- derived pb, so it has nothing to hide.
  {
    name = 'an absorber is in mm and absent from the pb column',
    run = function(harness)
      local h = harness.mk{ seed = { notes = { lane1Note(0, 240, 50) } } }
      h.tm:addEvent({ evType = 'pb', ppq = 480, chan = 1, val = 10 })
      h.tm:flush()

      local absorbers = 0
      for _, c in ipairs(mmPbs(h, 1)) do
        if c.derived == 'absorber' then absorbers = absorbers + 1 end
      end
      t.truthy(absorbers > 0, 'fixture check: the detune onset seats an absorber in mm')

      local col = pbColumn(h, 1)
      t.truthy(col, 'the authored pb keeps a column')
      t.eq(#col.events, 1, 'the column holds the authored pb alone')
      t.eq(col.events[1].ppq, 480, 'at its own row')
      for _, e in ipairs(col.events) do
        t.eq(e.hidden, nil, 'no column event carries a hidden flag')
        t.falsy(e.derived, 'no column event is derived')
      end
    end,
  },

  -- A pb event's `val` is its intent in cents, and `val + detune` is the cents it sounds.
  {
    name = 'an authored pb over a detuned base voice carries its intent as val and the detune as a cue',
    run = function(harness)
      local h = harness.mk{ seed = { notes = { lane1Note(0, 480, 25) } } }
      h.tm:addEvent({ evType = 'pb', ppq = 120, chan = 1, val = 50 })
      h.tm:flush()

      local evt = columnPbAt(h, 1, 120)
      t.truthy(evt, 'the authored pb sits in the column')
      t.eq(evt.val, 50, 'val is the intent in cents')
      t.eq(evt.detune, 25, 'detune is the base voice detune at its onset')
      t.eq(evt.raw, nil, 'the wire value stays in mm')
      t.eq(mmPbs(h, 1)[2].val, cents2raw(75), 'fixture check: the wire sounds val + detune')
    end,
  },

  -- The detune cue follows the base voice; the intent does not. A cue write renews the column,
  -- since tv's cell carry keys on the events table.
  {
    name = 'a base-voice detune edit restamps the pb cue, leaves its intent, and renews the column',
    run = function(harness)
      local h = harness.mk{ seed = { notes = { lane1Note(0, 480, 25) } } }
      h.tm:addEvent({ evType = 'pb', ppq = 120, chan = 1, val = 50 })
      h.tm:flush()
      local before = pbColumn(h, 1).events
      t.eq(columnPbAt(h, 1, 120).detune, 25, 'fixture check: the cue reads the first detune')

      local note = h.tm:getChannel(1).onTake.notes[1].events[1]
      h.tm:assignEvent(note, { detune = 10 })
      h.tm:flush()

      local evt = columnPbAt(h, 1, 120)
      t.eq(evt.detune, 10, 'the cue follows the new detune')
      t.eq(evt.val, 50, 'the intent stands')
      t.truthy(pbColumn(h, 1).events ~= before, 'the column renewed')
    end,
  },

  -- Interval reconstruction covers only the rows the dirt journal names; every other event carries
  -- (design § Reconstruction).
  {
    name = 'an interval pass that names no pb row carries the pb column',
    run = function(harness)
      local h = harness.mk{ seed = { notes = { lane1Note(0, 240, 0) } } }
      h.tm:addEvent({ evType = 'pb', ppq = 480, chan = 1, val = 20 })
      h.tm:addEvent({ evType = 'pb', ppq = 720, chan = 1, val = -20 })
      h.tm:flush()
      local col = pbColumn(h, 1)
      local events, members = col.events, {}
      for i, e in ipairs(events) do members[i] = e end
      t.eq(#members, 2, 'fixture check: both authored pbs are seated')

      h.tm:addEvent({ evType = 'note', ppq = 960, endppq = 1200, chan = 1, pitch = 64, vel = 100,
                      detune = 0, delay = 0, lane = 2 })
      h.tm:flush()

      col = pbColumn(h, 1)
      t.truthy(col.events == events, 'the events table carried')
      for i, e in ipairs(members) do
        t.truthy(col.events[i] == e, 'each event carried by identity')
      end
    end,
  },

  -- A pb or pc column exists when it holds an event or extraColumns asks for it.
  {
    name = 'a pb edit reaches its column event; deleting the last pb drops the column',
    run = function(harness)
      local h = harness.mk{ seed = { notes = { lane1Note(0, 240, 0) } } }
      h.tm:addEvent({ evType = 'pb', ppq = 480, chan = 1, val = 20 })
      h.tm:flush()

      h.tm:assignEvent(columnPbAt(h, 1, 480), { val = 35 })
      h.tm:flush()
      t.eq(columnPbAt(h, 1, 480).val, 35, 'the edit reaches the column event')

      h.tm:deleteEvent(columnPbAt(h, 1, 480))
      h.tm:flush()
      t.eq(#mmPbs(h, 1), 0, 'fixture check: no pb is left in mm')
      t.eq(pbColumn(h, 1), nil, 'no column is left to hold nothing')
    end,
  },

  {
    name = 'deleting the last pb leaves a wanted pb column empty',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { lane1Note(0, 240, 0) } },
        data = { extraColumns = { [1] = { notes = 1, pb = true } } },
      }
      h.tm:addEvent({ evType = 'pb', ppq = 480, chan = 1, val = 20 })
      h.tm:flush()
      t.truthy(columnPbAt(h, 1, 480), 'fixture check: the pb is seated')

      h.tm:deleteEvent(columnPbAt(h, 1, 480))
      h.tm:flush()
      t.deepEq(pbColumn(h, 1).events, {}, 'extraColumns keeps the column, and it holds nothing')
    end,
  },

  -- A foreign pb carries no cents sidecar. Reconstruction derives its intent from its raw value less
  -- the previous emission's base-voice detune at its onset, and writes the cents to mm.
  {
    name = 'a foreign pb gains its intent in mm and in the column on the first pass',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { lane1Note(0, 480, 25) },
          ccs   = { { ppq = 120, chan = 1, evType = 'pb', val = 2048 } },   -- sounds 50c
        },
      }
      local foreign
      for _, c in ipairs(mmPbs(h, 1)) do
        if c.ppq == 120 and not c.derived then foreign = c end
      end
      t.truthy(foreign, 'fixture check: the foreign pb stands in mm')
      t.eq(foreign.cents, 25, 'mm holds its intent: 50c sounding less the 25c detune')
      t.eq(columnPbAt(h, 1, 120).val, 25, 'and the column shows the same intent')
    end,
  },

  ----- Parking: a parked pb is seated in the pb column, flagged
  --
  -- A parked pb stays in the pb column flagged `parked`, as a parked note, pa or cc stays in its own
  -- (docs/trackerManager.md § Lane occupancy). Park and restore flip the seat in place, so the
  -- column is the whole authored pb population, sounding and parked.

  -- The seat keeps its table across the park and the restore, and comes back carrying the intent
  -- it went out with, as both val and cents.
  {
    name = 'a pb parked by a new replace window stays in the column flagged and restores in place',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'pb', ppq = 120, chan = 1, val = 40 })
      h.tm:addEvent({ evType = 'pb', ppq = 480, chan = 1, val = 10 })
      h.tm:flush()
      local before = columnPbAt(h, 1, 120)
      t.truthy(before, 'fixture check: the pb is seated')

      local cleanup = pbReplaceRegion(h)
      local seat = columnPbAt(h, 1, 120)
      t.truthy(seat == before, 'the parked pb keeps its seat in the column')
      t.truthy(seat.parked, 'flagged parked')
      t.falsy(columnPbAt(h, 1, 480).parked, 'the pb outside the window stays unflagged')

      h.ds:assign('fxRegions', {})
      h.tm:rebuild()
      cleanup()
      local evt = columnPbAt(h, 1, 120)
      t.truthy(evt == seat, 'the restore finds the same table')
      t.falsy(evt.parked, 'unflagged')
      t.eq(evt.val, 40, 'with its intent as val')
      t.eq(evt.cents, 40, 'and as cents')
    end,
  },

  -- Park scans every window on a dirty channel, not just a new one: a pb that reaches mm inside a
  -- standing window parks on the pass that seats it.
  {
    name = 'a pb added inside a standing replace window parks',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'pb', ppq = 480, chan = 1, val = 10 })
      h.tm:flush()
      local cleanup = pbReplaceRegion(h)
      t.eq(#require('harness').parkedPbs(h.tm, 1), 0, 'fixture check: the window opened over no pb')

      h.tm:addEvent({ evType = 'pb', ppq = 120, chan = 1, val = 40 })
      h.tm:flush()
      cleanup()
      local seat = columnPbAt(h, 1, 120)
      t.truthy(seat, 'the pb is seated in the column')
      t.truthy(seat.parked, 'flagged parked')
      t.truthy(stashPbAt(h, 1, 120), 'the stash holds it')
      t.eq(mmPbAtLogical(h, 1, 120), nil, 'and mm no longer sounds it')
    end,
  },

  -- detune is a cue emission stamps on a sounding pb, so a parked pb sheds it along with the
  -- realisation frame; its seat and its stash spec alike.
  {
    name = 'a parked pb seat carries no detune cue, nor does its stash spec',
    run = function(harness)
      local h = harness.mk{ seed = { notes = { lane1Note(0, 480, 25) } } }
      h.tm:addEvent({ evType = 'pb', ppq = 120, chan = 1, val = 40 })
      h.tm:flush()
      t.eq(columnPbAt(h, 1, 120).detune, 25, 'fixture check: the pb carries a cue before the window opens')

      local cleanup = pbReplaceRegion(h)
      cleanup()
      local seat = columnPbAt(h, 1, 120)
      t.truthy(seat and seat.parked, 'fixture check: the pb parked in place')
      t.eq(seat.detune, nil, 'the seat has no detune')
      t.eq(seat.cents, nil, 'nor cents')
      local spec = stashPbAt(h, 1, 120)
      t.truthy(spec, 'fixture check: the stash holds the pb')
      t.eq(spec.detune, nil, 'the stash spec has no detune')
    end,
  },

  -- A restored pb sounds again: mm regains it at its intent plus the base voice's detune, and the
  -- seat regains its cue once rebuildPbs has run.
  {
    name = 'a restored pb flips in place, sounds its intent plus detune, and regains its cue',
    run = function(harness)
      local h = harness.mk{ seed = { notes = { lane1Note(0, 480, 25) } } }
      h.tm:addEvent({ evType = 'pb', ppq = 120, chan = 1, val = 40 })
      h.tm:flush()
      local cleanup = pbReplaceRegion(h)
      local seat = columnPbAt(h, 1, 120)
      t.truthy(seat and seat.parked, 'fixture check: the pb parked in place')
      t.eq(mmPbAtLogical(h, 1, 120), nil, 'fixture check: mm lost it')

      h.ds:assign('fxRegions', {})
      h.tm:rebuild()
      cleanup()
      t.truthy(columnPbAt(h, 1, 120) == seat, 'the restore keeps the table')
      t.eq(seat.detune, 25, 'the seat regains its detune cue')
      local wire = mmPbAtLogical(h, 1, 120)
      t.truthy(wire, 'mm regains the pb')
      t.eq(wire.cents, 40, 'its cents are the intent')
      t.eq(wire.val, cents2raw(65), 'its wire value sounds intent plus detune')
    end,
  },

  -- The renewal rule holds for a parked seat (docs/trackerManager.md § Note-lane renewal): a pass
  -- that leaves it parked as it was carries it and its column. An edit to the covering region's fx
  -- seeds dirt at the region's onset, which names the pb row of a seat parked there; the CC walk's
  -- splice of that row must leave the seat, or the stash reseats it as a fresh table.
  {
    name = 'a region edit leaves a pb parked at its onset seated, and the column carried',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'pb', ppq = 0,   chan = 1, val = 40 })
      h.tm:addEvent({ evType = 'pb', ppq = 480, chan = 1, val = 10 })
      h.tm:flush()
      local cleanup = pbReplaceRegion(h)
      local events = pbColumn(h, 1).events
      local seat = columnPbAt(h, 1, 0)
      t.truthy(seat and seat.parked, 'fixture check: the pb at the region onset parked')

      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, ppq = 0, endppq = 240,
                                   fx = { { kind = 'flatRep', level = 2 } } } })
      h.tm:rebuild()
      cleanup()
      t.truthy(columnPbAt(h, 1, 0) == seat, 'the parked seat keeps its table')
      t.truthy(seat.parked, 'still parked')
      t.truthy(pbColumn(h, 1).events == events, 'the column carried')
    end,
  },

  -- A pb column exists when it holds an event, and a parked seat is an event.
  {
    name = 'a channel whose only pb is parked keeps its pb column',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'pb', ppq = 120, chan = 1, val = 40 })
      h.tm:flush()
      local cleanup = pbReplaceRegion(h)
      cleanup()
      t.falsy(((h.ds:get('extraColumns') or {})[1] or {}).pb, 'fixture check: extraColumns asks for no pb column')

      local col = pbColumn(h, 1)
      t.truthy(col, 'the column stands')
      t.eq(#col.events, 1, 'fixture check: it holds one event')
      t.truthy(col.events[1].parked, 'fixture check: which is the parked pb')
      t.truthy(h.tm:authoredPb(1) == col.events, 'tm:authoredPb answers the column')
    end,
  },

  ----- The pb base: fx expansion reads the authored pb curve off the column
  --
  -- A host's pb base is the authored curve over its window (docs/trackerManager.md § Span-covered fx
  -- scans). Its on-take half is the pb column's cover, logical and in cents; the depth-0 sine host
  -- makes each seat a pure sample of it.

  -- The base is logical: under swing the ramp is interpolated between logical onsets. The host's
  -- first seat, logical 120, lies 120/600 of the way along the 0c → 100c ramp, so reads 20c. A
  -- raw-frame slip interpolates 120/619 of the way.
  {
    name = 'a host\'s pb base reads an authored pb\'s val at its logical onset under swing',
    run = function(harness)
      local h = swungRampWithHost(harness)
      local ramp = mmPbAtLogical(h, 1, 600)
      t.truthy(ramp and ramp.ppq ~= 600, 'fixture check: swing moves the ramp\'s raw seat')

      local seat = earliestSeat(h, 1)
      t.truthy(seat, 'fixture check: the host seats pbs')
      t.eq(seat.val, cents2raw(20), 'the first seat samples the ramp at its logical onset')
    end,
  },

  -- A foreign pb's intent is derived on the pass that first sees it, and the base holds it on that
  -- same pass: the host sounds the foreign pb's 100c from the start.
  {
    name = 'a foreign pb enters the base on the pass that derives its cents',
    run = function(harness)
      local h = harness.mk{ seed = {
        notes = { zeroSineHost() },
        ccs   = { { ppq = 0, chan = 1, evType = 'pb', val = 4096 } },   -- sounds 100c
      } }
      local seat = earliestSeat(h, 1)
      t.truthy(seat and seat.ppq > 0, 'fixture check: the host seats pbs apart from the foreign pb')
      t.eq(seat.val, 4096, 'the seat samples the foreign pb\'s intent')
    end,
  },

  -- A gated pass wakes a host whose base an edit changes, though the edit lies outside its window:
  -- the ramp's closing point at 600 bounds the window [120, 360). Doubling it doubles the first seat.
  {
    name = 'an edit to a column pb bounding a host\'s window dirties its base',
    run = function(harness)
      local h = swungRampWithHost(harness)
      h.tm:addEvent({ evType = 'pb', ppq = 900, chan = 1, val = 0, shape = 'linear' })
      h.tm:flush()
      t.eq(earliestSeat(h, 1).val, cents2raw(20), 'fixture check: the first seat reads 20c')

      h.tm:assignEvent(columnPbAt(h, 1, 600), { val = 200 })
      h.tm:flush()
      t.eq(earliestSeat(h, 1).val, cents2raw(40), 'the first seat follows the doubled ramp')
    end,
  },
}
