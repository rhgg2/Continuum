-- The pb column is the take's pb intent (docs/trackerManager.md § CC walk): authored pbs alone,
-- projected by the CC walk, each event's `val` its intent in cents. The base voice's detune at a
-- pb's onset is a cue emission stamps on it (design/intent-emission.md § Emission's output), so
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

local function mmPbs(h, chan)
  local out = {}
  for _, c in ipairs(h.fm:dump().ccs) do
    if c.evType == 'pb' and c.chan == chan then out[#out + 1] = c end
  end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
  return out
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

  -- Absorbers and synthesised PCs live in mm alone (§ Emission's output): the column holds no
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

  -- Until the stash seat takes pbs into the pb column (plan phase 3), a parked pb is off-take: it
  -- leaves the column as it parks and returns as it restores.
  {
    name = 'a pb parked by a new replace window leaves the column and returns with its intent',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'pb', ppq = 120, chan = 1, val = 40 })
      h.tm:addEvent({ evType = 'pb', ppq = 480, chan = 1, val = 10 })
      h.tm:flush()
      t.truthy(columnPbAt(h, 1, 120), 'fixture check: the pb is seated')

      local cleanup = pbReplaceRegion(h)
      t.eq(#h.tm:getChannel(1).parked.pb, 1, 'fixture check: the window parked the pb')
      t.eq(columnPbAt(h, 1, 120), nil, 'the parked pb left the column')

      h.ds:assign('fxRegions', {})
      h.tm:rebuild()
      cleanup()
      local evt = columnPbAt(h, 1, 120)
      t.truthy(evt, 'the restored pb is back in the column')
      t.eq(evt.val, 40, 'with its intent')
    end,
  },
}
