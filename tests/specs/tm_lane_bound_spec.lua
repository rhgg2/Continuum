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
--
-- The third case turns it around, with the parked half doing the bounding. Its two notes share a
-- lane, so the region's input is the tail's lane successor and parking it must not release the
-- clip. That channel is swung, which puts the successor's row and its raw position at different
-- numbers -- a bound read in the wrong frame lands somewhere else entirely.

local t    = require('support')
local util = require('util')

local arpUp = { { kind = 'arp', period = { 1, 4 }, dir = 'up' } }

-- classic-55: the principal at x=0.5 maps to 0.55 of the period, so logical 1140 realises at 1148.
local c55 = {
  config = { project = { swings = { c55 = {
    factors = { { atom = 'classic', shift = 0.05, period = 1 } } } } } },
  data   = { swing = { global = 'c55' } },
}

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

  {
    -- Both notes on lane 1, so the row-0 tail is clipped by its successor at 1140 well short of
    -- its own ceiling at 1440. The region then parks that successor. The columns no longer carry
    -- it, but the lane geometry still does, so the clip stands exactly where it stood.
    --
    -- This case asserts over the tail alone, where the other two sweep the whole population. The
    -- successor's own bound is written two ways -- through the tail walk's raw round trip on take,
    -- by the stash render once parked -- and under swing those disagree in the last bits. That is
    -- the drift design/lane-bound.md § Open 3 records, and phase 1's business, not this case's.
    name = 'a successor parked this pass keeps bounding the tail before it, on a swung channel',
    run = function(harness)
      local h = harness.mk(c55)
      h.tm:addEvent(note(1, 0,    1440, 60, 1))   -- a ceiling well past its lane successor
      h.tm:addEvent(note(1, 1140, 1320, 67, 1))   -- the region's input, sharing the lane
      h.tm:flush()

      t.eq(#h.tm:getChannel(1).onTake.notes, 1, 'fixture check: one lane, so one note clips the other')
      t.truthy(h.tm:fromLogical(1, 1140) ~= 1140, 'fixture check: the swing bites at the clipping row')

      local clipped = authoredAt(h, 1, 0).endppqC
      t.truthy(clipped < 1440, 'fixture check: the successor clips the tail, its own ceiling never reached')

      region(h)

      local stashed = h.tm:getChannel(1).parked.notes
      t.eq(#stashed, 1, 'precondition: the region parked its input, so the clipping note left the take')
      t.eq(stashed[1].ppq, 1140, 'precondition: and it is the lane successor that left')

      t.eq(authoredAt(h, 1, 0).endppqC, clipped, 'the tail keeps the bound its successor gave it')
      t.eq(stashed[1].endppqC, 1320, 'the successor, off the take, sounds to its own ceiling still')
    end,
  },

}
