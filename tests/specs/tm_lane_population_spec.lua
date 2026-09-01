-- A lane's authored population is its on-take events together with the parked ones that have left
-- the take (docs/trackerManager.md § Lane occupancy), and `tm:authoredLanes` is where a renderer
-- asks for it. Parking takes no onset out of the population, so the lane reads the same either way.
--
-- The order is the column's own. A parked event merges into the on-take order rather than being
-- appended and the whole re-sorted, so the note-before-PA tie-break at a shared onset survives the
-- merge -- which a ppq-only sort over the concatenation does not guarantee.
--
-- The fixture is three onsets on lane 1: a plain note, then a self-parking arp host (replace mode
-- takes it off the take), then a plain note with a PA riding it at the same onset. The host sits
-- between the other two so that merging it at the head and merging it at its onset differ, and its
-- window closes at the next onset on its lane, so neither neighbour is drawn into it.

local t = require('support')

local arpUp = { { kind = 'arp', period = { 1, 4 }, dir = 'up' } }   -- replace-mode: parks its host

-- (ppq, evType) of each entry: what the population is, without the fields a renderer reads.
local function shapeOf(events)
  local out = {}
  for _, e in ipairs(events) do out[#out + 1] = { ppq = e.ppq, evType = e.evType } end
  return out
end

local function lane1(harness)
  local h = harness.mk()
  h.tm:addEvent{ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                 vel = 100, detune = 0, delay = 0, lane = 1 }
  h.tm:addEvent{ evType = 'note', ppq = 480, endppq = 720, chan = 1, pitch = 62,
                 vel = 100, detune = 0, delay = 0, lane = 1, fx = arpUp }
  h.tm:addEvent{ evType = 'note', ppq = 960, endppq = 1200, chan = 1, pitch = 64,
                 vel = 100, detune = 0, delay = 0, lane = 1 }
  h.tm:addEvent{ evType = 'pa', ppq = 960, chan = 1, pitch = 64, vel = 90 }
  h.tm:flush()
  return h
end

return {

  {
    name = "a lane's population is its on-take events and its parked ones, in the column's order",
    run = function(harness)
      local h = lane1(harness)

      local onTake = h.tm:getChannel(1).onTake.notes[1].events
      local parked = h.tm:getChannel(1).parked.notes
      t.eq(#parked, 1, 'fixture check: the arp host parked itself off the take')
      t.eq(#onTake, 3, 'fixture check: the two plain notes and the PA stand on the take')

      local lanes = h.tm:authoredLanes(1)
      t.deepEq(shapeOf(lanes[1]),
               { { ppq = 0, evType = 'note' }, { ppq = 480, evType = 'note' },
                 { ppq = 960, evType = 'note' }, { ppq = 960, evType = 'pa' } },
               'both halves, in ppq order, the parked host at its own onset and the PA behind its note')

      -- The merge adds and does not reorder: strip the parked entries and the on-take order stands.
      local byUuid = {}
      for _, e in ipairs(parked) do byUuid[e] = true end
      local kept = {}
      for _, e in ipairs(lanes[1]) do if not byUuid[e] then kept[#kept + 1] = e end end
      t.deepEq(shapeOf(kept), shapeOf(onTake), "the on-take order is untouched by the merge")
    end,
  },

  {
    -- A parked event is the visible, editable surface of the note it stands in for, so an edit to
    -- the stash has to reach the lane. The union being memoised, this is the read that would go
    -- stale first. (It does not distinguish which of the memo's two keys does the invalidating:
    -- a parked edit dirties the channel, which mints the on-take column afresh regardless.)
    name = 'an edit to a parked event reaches the lane it renders on',
    run = function(harness)
      local h = lane1(harness)
      local function parkedInLane()
        for _, e in ipairs(h.tm:authoredLanes(1)[1]) do if e.ppq == 480 then return e end end
      end
      t.eq(parkedInLane().pitch, 62, 'fixture check: the host renders at its authored pitch first')

      h.tm:assignParked(h.tm:getChannel(1).parked.notes[1], { pitch = 67 })
      h.tm:flush()

      t.eq(parkedInLane().pitch, 67, 'the lane shows the edit, not the population it was warmed with')
    end,
  },

  {
    name = 'a lane holding nothing parked answers with its own column, so the cell carry stands',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent{ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                     vel = 100, detune = 0, delay = 0, lane = 1 }
      h.tm:flush()

      t.eq(#h.tm:getChannel(1).parked.notes, 0, 'fixture check: nothing parked on the channel')
      t.truthy(h.tm:authoredLanes(1)[1] == h.tm:getChannel(1).onTake.notes[1].events,
               'the lane is answered with its own events table, not a copy of it')
    end,
  },

  {
    name = 'every parked host is reachable, whichever channel it sits on',
    run = function(harness)
      local h = harness.mk()
      for chan = 1, 2 do
        h.tm:addEvent{ evType = 'note', ppq = 0, endppq = 240, chan = chan, pitch = 60,
                       vel = 100, detune = 0, delay = 0, lane = 1, fx = arpUp }
        h.tm:flush()
      end

      local chans = {}
      for evt in h.tm:eachParkedHost() do chans[#chans + 1] = evt.chan end
      t.deepEq(chans, { 1, 2 }, 'both hosts come back, in channel order, each naming its own channel')
    end,
  },

}
