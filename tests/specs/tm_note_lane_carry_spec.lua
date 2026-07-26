-- tv's cell carry keys on a note lane's `events` table identity (trackerView's prevBuilt), so a
-- lane whose contents did not change must keep that table across a rebuild, and a lane whose
-- contents did change must swap it. exciseNotes used to re-clone every lane of an interval-dirty
-- channel, so a one-note edit made tv re-place the whole channel. This pins the shed in both
-- directions, including the tail walk's reach into a lane no seed covered.

local t = require('support')

local function note(ppq, pitch, lane, extra)
  local n = { evType = 'note', ppq = ppq, endppq = ppq + 60, chan = 1, pitch = pitch,
              vel = 100, detune = 0, delay = 0, lane = lane }
  for k, v in pairs(extra or {}) do n[k] = v end
  return n
end

local function laneEvents(h, lane)
  return h.tm:getChannel(1).columns.notes[lane].events
end

-- chan 1 holding one note in lane 1 (row 0) and one in lane 2 (row 960), with both lanes'
-- events tables captured by identity. The edit each case then makes seeds row 240 only.
local function twoLanes(harness)
  local h = harness.mk{}
  h.tm:addEvent(note(0, 60, 1))
  h.tm:addEvent(note(960, 62, 2))
  h.tm:flush()
  t.eq(#laneEvents(h, 1), 1, 'lane 1 seated its note')
  t.eq(#laneEvents(h, 2), 1, 'lane 2 seated its note')
  return h, laneEvents(h, 1), laneEvents(h, 2)
end

return {
  {
    name = 'a lane the edit never touched keeps its events table',
    run = function(harness)
      local h, _, lane2 = twoLanes(harness)

      h.tm:addEvent(note(240, 61, 1)); h.tm:flush()

      t.truthy(laneEvents(h, 2) == lane2, 'the untouched lane carries its events table')
    end,
  },
  {
    name = 'the edited lane sheds its events table',
    run = function(harness)
      local h, lane1 = twoLanes(harness)

      h.tm:addEvent(note(240, 61, 1)); h.tm:flush()

      t.eq(#laneEvents(h, 1), 2, 'lane 1 took the new note')
      t.truthy(laneEvents(h, 1) ~= lane1, 'the lane that gained a cell shed its events table')
    end,
  },
  {
    name = 'a nudge sheds the neighbour lane no seed covered',
    run = function(harness)
      -- The lane-2 note sits at logical row 60 with a one-row negative delay, so its raw onset is
      -- 0. Adding a same-pitch note at row 0 collides on raw (distinct ppqL, so the flush scan
      -- separates rather than kills); the tail walk nudges the lane-2 note a tick forward, moving
      -- its delayC. Row 60 is never seeded, so that lane's membership never changes -- the content
      -- write is the only reason it has to shed.
      local h = harness.mk{}
      h.tm:addEvent(note(60, 60, 2, { delay = -250 }))
      h.tm:flush()

      local lane2 = laneEvents(h, 2)
      t.eq(#lane2, 1, 'lane 2 seated the delayed note')
      local delayed = lane2[1]
      t.eq(delayed.ppq, 60, 'the cell is logical: row 60')
      local delayCBefore = delayed.delayC

      h.tm:addEvent(note(0, 60, 1)); h.tm:flush()

      t.truthy(delayed.delayC ~= delayCBefore,
               'the tail walk moved the carried cell delayC from ' .. tostring(delayCBefore))
      t.truthy(laneEvents(h, 2) ~= lane2, 'the nudged lane shed its events table')
    end,
  },
}
