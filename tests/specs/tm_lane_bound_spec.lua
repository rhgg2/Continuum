-- An authored note's lane bound is a function of the authored population alone -- the column's own
-- events together with the parked ones that have left the take. Fx expansion adds derived notes to
-- the channel and the tail walk meets them in the same pass, yet none of them moves an authored
-- note's `endppqC`. See design/lane-bound.md § Two populations.
--
-- What holds it is the region lane allocator: it seeds each lane's occupancy from the spans already
-- sounding there before placing a derived note, so a derived note lands only where its lane has
-- finished. The two cases are the two ways that can go. In the first the allocator does the work --
-- the authored tail reaches into the region's window, so the tiles are pushed off its lane. In the
-- second the tiles do take the authored note's lane, past its ceiling, and the bound stands for the
-- simpler reason that the tail had already ended.
--
-- Each case snapshots every authored note's `endppqC` before the region is assigned and compares
-- after the rebuild, over both halves of the population. The region parks its input note, so the
-- comparison spans the park: parking moves a note between the halves and moves no bound.

local t    = require('support')
local util = require('util')

local arpUp = { { kind = 'arp', period = { 1, 4 }, dir = 'up' } }

local function note(chan, ppq, endppq, pitch, lane)
  return { evType = 'note', ppq = ppq, endppq = endppq, chan = chan, pitch = pitch,
           vel = 100, detune = 0, delay = 0, lane = lane }
end

-- Every authored note on a channel, on-take and parked alike, uuid -> lane bound.
local function boundsOn(h, chan)
  local out = {}
  for _, col in ipairs(h.tm:getChannel(chan).onTake.notes) do
    for _, evt in ipairs(col.events) do out[evt.uuid] = evt.endppqC end
  end
  for _, evt in ipairs(h.tm:getChannel(chan).parked.notes) do out[evt.uuid] = evt.endppqC end
  return out
end

-- The authored note at an onset, wherever the pass left it: on its column or in the stash.
local function authoredAt(h, chan, ppq)
  for _, col in ipairs(h.tm:getChannel(chan).onTake.notes) do
    for _, evt in ipairs(col.events) do if evt.ppq == ppq then return evt end end
  end
  for _, evt in ipairs(h.tm:getChannel(chan).parked.notes) do
    if evt.ppq == ppq then return evt end
  end
end

-- The pass's fx output on a channel, ascending: what the authored population is asserted against.
local function derivedOn(h, chan)
  local out = {}
  for _, n in ipairs(h.fm:dump().notes) do
    if n.chan == chan and n.derived then util.add(out, { ppq = n.ppq, lane = n.lane }) end
  end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
  return out
end

local function lanesWithin(derived, from, to)
  local out = {}
  for _, d in ipairs(derived) do if d.ppq >= from and d.ppq < to then out[d.lane] = true end end
  return out
end

-- One arp region over [960, 1920), fed by the lane-2 note the window covers and parks.
local function region(h)
  h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, ppq = 960, endppq = 1920, fx = arpUp } })
  h.tm:rebuild()
end

return {

  {
    -- The lane-1 tail runs to 1440, well into the region's window, so its lane is occupied where
    -- the arp would otherwise tile. Were the allocator to seed from nothing, the tiles would take
    -- lane 1 at 960 and the tail would read as clipped there -- a derived note deciding an authored
    -- note's bound.
    name = "fx output sounding inside an authored tail leaves the tail's lane bound where it was",
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent(note(1, 0,   1440, 60, 1))   -- the tail the region's output sounds inside
      h.tm:addEvent(note(1, 960, 1200, 67, 2))   -- the region's input, on a lane of its own
      h.tm:flush()

      local before = boundsOn(h, 1)
      t.eq(authoredAt(h, 1, 0).endppqC, 1440,
        'fixture check: the tail sounds to its own ceiling, nothing on its lane clipping it')

      region(h)

      local derived = derivedOn(h, 1)
      t.truthy(#derived > 1, 'precondition: the arp tiles its parked member')
      t.truthy(derived[1].ppq < 1440, 'precondition: it sounds inside the authored tail')
      t.eq(authoredAt(h, 1, 0).endppqC, 1440, 'the tail keeps the bound its own ceiling gave it')
      t.deepEq(boundsOn(h, 1), before,
        'and no authored note on the channel, on take or parked, has moved')
      t.falsy(lanesWithin(derived, 0, 1440)[1],
        'the derived output taking a lane only where the authored population has ended')
    end,
  },

  {
    -- The same fixture with the lane-1 tail ending at 480: its lane is free where the arp tiles, so
    -- the output takes lane 1 and the tail walk meets a derived note as the authored note's lane
    -- successor. It is past the ceiling, so the bound is the ceiling either way.
    name = 'fx output seated on an authored lane past its tail leaves that bound where it was',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent(note(1, 0,   480,  60, 1))
      h.tm:addEvent(note(1, 960, 1200, 67, 2))
      h.tm:flush()

      local before = boundsOn(h, 1)
      t.eq(authoredAt(h, 1, 0).endppqC, 480, 'fixture check: the tail ends well before the window')

      region(h)

      local derived = derivedOn(h, 1)
      t.truthy(#derived > 1, 'precondition: the arp tiles its parked member')
      t.truthy(lanesWithin(derived, 0, math.huge)[1],
        'precondition: the freed lane takes the output, so a derived note is the lane successor')

      t.eq(authoredAt(h, 1, 0).endppqC, 480, 'the tail still ends at its ceiling')
      t.deepEq(boundsOn(h, 1), before,
        'and no authored note on the channel, on take or parked, has moved')
    end,
  },

}
