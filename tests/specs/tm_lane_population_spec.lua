-- A lane's authored population is its column: the events on the take and the parked notes that
-- have left it, seated among them and flagged `parked` (docs/trackerManager.md § Lane occupancy).
-- `tm:authoredLanes` is where a renderer asks for it, and it answers with the column's own events
-- table, so parking takes no onset out of the population and adds no second list to merge.
--
-- The order is the column's own. A parked note is spliced at its onset like any other, so the
-- note-before-PA tie-break at a shared onset stands.
--
-- The fixture is three onsets on lane 1: a plain note, then a self-parking arp host (replace mode
-- takes it off the take), then a plain note with a PA riding it at the same onset. The host sits
-- between the other two so that seating it at the head and seating it at its onset differ, and its
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
    name = "a lane's population is its column, parked notes seated at their onsets and flagged",
    run = function(harness)
      local h = lane1(harness)

      local parked = require('harness').parkedNotes(h.tm, 1)
      t.eq(#parked, 1, 'fixture check: the arp host parked itself off the take')
      local written = {}
      for _, n in ipairs(h.fm:dump().notes) do if not n.derived then written[n.ppq] = true end end
      t.truthy(written[0] and written[960] and not written[480],
               'fixture check: of the authored notes, only the plain two are on the take')

      local lane = h.tm:authoredLanes(1)[1]
      t.truthy(lane == h.tm:getChannel(1).onTake.notes[1].events,
               'the lane is answered with its own events table, parked host and all')
      t.deepEq(shapeOf(lane),
               { { ppq = 0, evType = 'note' }, { ppq = 480, evType = 'note' },
                 { ppq = 960, evType = 'note' }, { ppq = 960, evType = 'pa' } },
               'in ppq order, the parked host at its own onset and the PA behind its note')
      local flagged = {}
      for _, e in ipairs(lane) do if e.parked then flagged[#flagged + 1] = e.ppq end end
      t.deepEq(flagged, { 480 }, 'the parked host, and only it, carries the flag')
    end,
  },

  {
    -- A parked event is the visible, editable surface of the note it stands in for, so an edit to
    -- the stash has to reach the lane: the seated event whose spec moved is reseated from the stash.
    name = 'an edit to a parked event reaches the lane it renders on',
    run = function(harness)
      local h = lane1(harness)
      local function parkedInLane()
        for _, e in ipairs(h.tm:authoredLanes(1)[1]) do if e.ppq == 480 then return e end end
      end
      t.eq(parkedInLane().pitch, 62, 'fixture check: the host renders at its authored pitch first')

      h.tm:assignParked(require('harness').parkedNotes(h.tm, 1)[1], { pitch = 67 })
      h.tm:flush()

      t.eq(parkedInLane().pitch, 67, 'the lane shows the edit, not the population it was warmed with')
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
