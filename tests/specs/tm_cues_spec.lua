-- No cue reaches mm or the stash. A cue is a field emission derives and carries on an authored
-- event -- `delayC`, `endppqC`, `sampleShadowed` and `parked` on every kind, and `detune` on a pb
-- -- so it is realisation's, and nothing a caller hands back through a write door may persist it.
-- (docs/trackerManager.md § Two movements)
--
-- Cues reach the doors because the view relocates a cell by cloning its column event (minus
-- `committed`) and adding the clone: the clone carries whatever emission stamped on the seat. So
-- `tm:addEvent`, `tm:assignEvent` and `tm:assignParked` shed every cue, and park sheds them from both
-- the stash spec and the seat it flips in place.
--
-- The set is keyed by the event's kind: a pb's `detune` is emission's cue (the lane-1 note's detune
-- it realises under), but a note's `detune` is authored and rides every write and every park.
--
-- Assertions name the cue fields rather than asking tm which fields are cues, so a change to the
-- set is a change these cases see.

local t = require('support')
local generators = require('generators')
local util = require('util')

local arpRegion = { { uuid = 'fxr-1', chan = 1, ppq = 0, endppq = 240,
                      fx = { { kind = 'arp', period = { 1, 4 }, dir = 'up' } } } }

local function note(ppq, extra)
  return util.assign({ evType = 'note', ppq = ppq, endppq = ppq + 240, chan = 1, pitch = 60,
                       vel = 100, detune = 0, delay = 0, lane = 1 }, extra)
end

local function colNote(h) return h.tm:getChannel(1).onTake.notes[1].events[1] end

local function mmNotes(h) return h.fm:dump().notes end

-- The authored pbs in mm: absorbers are emission's own seats, not the event under test.
local function mmPbs(h)
  local out = {}
  for _, c in ipairs(h.fm:dump().ccs) do
    if c.evType == 'pb' and not c.derived then out[#out + 1] = c end
  end
  return out
end

local function stashed(h, evType)
  local out = {}
  for _, spec in ipairs(h.ds:get('fxParked') or {}) do
    if spec.evType == evType then out[#out + 1] = spec end
  end
  return out
end

-- The view's relocation: the seat cloned minus `committed`, moved, the original deleted and the
-- clone added.
local function relocate(h, evt, ppq, endppq, deleteDoor, exclude)
  local moved = util.clone(evt, exclude or { committed = true })
  moved.ppq, moved.endppq = ppq, endppq
  deleteDoor(h.tm, evt)
  h.tm:addEvent(moved)
  h.tm:flush()
end

-- A lane-1 note carrying authored detune and delay, so its seat carries delayC and endppqC.
local function detunedNote(harness)
  local h = harness.mk()
  h.tm:addEvent(note(0, { detune = 50, delay = 30 }))
  h.tm:flush()
  return h
end

-- A plain lane-1 note parked by an arp region over 0-240, seated flagged in its lane.
local function parkedNote(harness, extra)
  local h = harness.mk()
  h.tm:addEvent(note(0, extra))
  h.tm:flush()
  h.ds:assign('fxRegions', arpRegion)
  h.tm:rebuild()
  local parked = require('harness').parkedNotes(h.tm, 1)
  t.eq(#parked, 1, 'fixture check: the region parked the note')
  return h, parked[1]
end

return {

  {
    name = 'a relocated on-take note reaches mm without its cues',
    run = function(harness)
      local h = detunedNote(harness)
      local seat = colNote(h)
      t.truthy(seat.delayC ~= nil and seat.endppqC ~= nil, 'fixture check: the seat carries its cues')

      relocate(h, seat, 960, 1200, h.tm.deleteEvent)

      local notes = mmNotes(h)
      t.eq(#notes, 1, 'fixture check: the relocated note alone is in mm')
      t.eq(notes[1].delayC, nil, 'mm holds no delayC')
      t.eq(notes[1].endppqC, nil, 'mm holds no endppqC')
      t.eq(notes[1].detune, 50, 'the authored detune rides the write')
      t.eq(notes[1].delay, 30, 'the authored delay rides the write')
    end,
  },

  {
    name = "a relocated on-take pb reaches mm without emission's detune",
    run = function(harness)
      local h = detunedNote(harness)
      h.tm:addEvent({ evType = 'pb', ppq = 480, chan = 1, val = 20 })
      h.tm:flush()
      local seat
      for _, evt in ipairs(h.tm:authoredPb(1)) do if evt.ppq == 480 then seat = evt end end
      t.eq(seat and seat.detune, 50, "fixture check: the pb's seat carries the note's detune")

      relocate(h, seat, 1440, nil, h.tm.deleteEvent)

      local pbs = mmPbs(h)
      t.eq(#pbs, 1, 'fixture check: the relocated pb alone is authored in mm')
      t.eq(pbs[1].ppq, 1440, 'fixture check: at its new onset')
      t.eq(pbs[1].detune, nil, 'mm holds no detune on the pb')
    end,
  },

  {
    name = 'an assign carrying a cue writes none of it',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent(note(0))
      h.tm:flush()

      h.tm:assignEvent(colNote(h), { vel = 90, delayC = 5 })
      h.tm:flush()

      local notes = mmNotes(h)
      t.eq(notes[1].vel, 90, 'fixture check: the assign landed')
      t.eq(notes[1].delayC, nil, 'mm holds no delayC')
    end,
  },

  {
    name = 'a parked note relocated onto the take arrives without parked or endppqC',
    run = function(harness)
      local h, seat = parkedNote(harness)
      t.truthy(seat.endppqC ~= nil, 'fixture check: the parked seat carries endppqC')

      relocate(h, seat, 960, 1200, h.tm.deleteParked, { committed = true, uuid = true })

      local notes = mmNotes(h)
      t.eq(#notes, 1, 'fixture check: the relocated note alone is in mm')
      t.eq(notes[1].ppq, 960, 'fixture check: at its new onset, outside the region')
      t.eq(notes[1].parked, nil, 'mm holds no parked flag')
      t.eq(notes[1].endppqC, nil, 'mm holds no endppqC')
    end,
  },

  {
    -- The pb-replace region parks the authored pb at 120; the lane-1 note under it detunes by 50,
    -- so the pb's seat carried a non-zero detune before the park. The pb sits inside the window
    -- rather than on its onset: a pb at the onset is reseated fresh from mm, cue-free, before park
    -- reads it, and the case would hold with no shed at all.
    name = 'a parked pb carries no cue into the stash, and its seat no detune',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent(note(0, { detune = 50 }))
      h.tm:addEvent({ evType = 'pb', ppq = 120, chan = 1, val = 40 })
      h.tm:flush()
      local before = h.tm:authoredPb(1)[1]
      t.eq(before and before.detune, 50, "fixture check: the pb's seat carries the note's detune")

      generators.kinds.rep = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 50, shape = 'step' },
          { ppq = host.window[2], val = 0,  shape = 'step' } } } end,
        mode = 'replace', dest = 'pb', label = 'Rep', defaults = {}, fields = {},
      }
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, ppq = 0, endppq = 240,
                                   fx = { { kind = 'rep' } } } })
      h.tm:rebuild()

      local specs, seats = stashed(h, 'pb'), require('harness').parkedPbs(h.tm, 1)
      t.eq(#specs, 1, 'fixture check: the pb is stashed')
      t.eq(#seats, 1, 'fixture check: and seated parked')
      t.eq(specs[1].detune, nil, 'the stash spec holds no detune')
      t.eq(specs[1].parked, nil, 'the stash spec holds no parked flag')
      t.eq(seats[1].parked, true, 'the seat is flagged parked')
      t.eq(seats[1].detune, nil, 'the seat holds no detune')
      generators.kinds.rep = nil
    end,
  },

  {
    name = 'a parked assign carrying a cue stashes none of it',
    run = function(harness)
      local h, seat = parkedNote(harness)

      h.tm:assignParked(seat, { vel = 90, endppqC = 5, delayC = 5 })
      h.tm:flush()

      local specs = stashed(h, 'note')
      t.eq(#specs, 1, 'fixture check: the note is stashed')
      t.eq(specs[1].vel, 90, 'fixture check: the assign landed')
      t.eq(specs[1].endppqC, nil, 'the stash spec holds no endppqC')
      t.eq(specs[1].delayC, nil, 'the stash spec holds no delayC')
    end,
  },

  {
    name = "a parked note's authored detune survives into the stash",
    run = function(harness)
      local h = parkedNote(harness, { detune = 50 })

      local specs = stashed(h, 'note')
      t.eq(#specs, 1, 'fixture check: the note is stashed')
      t.eq(specs[1].detune, 50, 'the stash spec keeps the authored detune')
    end,
  },

}
