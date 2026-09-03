-- The take-tier clip cache: an event's clipped span end -- an fx host's window end, a parked note's
-- render clip -- computed once and reused for as long as the rebuild's dirt cannot have moved it.
-- Reuse asks the journal two questions: does the channel's dirt name this event, and does a seeded
-- row fall inside the cached span. See docs/trackerManager.md § Lane occupancy.
--
-- The span question is the one with teeth, and this is the first fixture to reach it. A move seeds
-- both seats it held, and the flush's dedup keeps the vacated one, carrying the arrival row onto it
-- (§ Interval seeds). Reading the snapshot row alone therefore misses a neighbour that moved *into*
-- a cached span, and the event holds a clip its lane no longer supports.
--
-- The fixture is tm_parked_carry_spec's: a self-parking arp host at 480 on chan 1 lane 1, authored
-- to 720, with a plain note further down the same lane at 960 -- outside the host's span, so the
-- first pass caches the clip at the host's own ceiling. The mover then lands exactly on the new
-- clip, which keeps it clear of the host's window and on the take, so the only thing that moved is
-- the number under test.

local t = require('support')

local arpUp = { { kind = 'arp', period = { 1, 4 }, dir = 'up' } }   -- replace-mode: parks its host

local function note(ppq, pitch, extra)
  local n = { evType = 'note', ppq = ppq, endppq = ppq + 240, chan = 1, pitch = pitch,
              vel = 100, detune = 0, delay = 0, lane = 1 }
  for k, v in pairs(extra or {}) do n[k] = v end
  return n
end

local function parkedList(h) return h.tm:getChannel(1).parked.notes end

return {
  {
    name = 'a neighbour moved into a cached span reclips it',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent(note(480, 62, { fx = arpUp }))
      h.tm:addEvent(note(960, 64))
      h.tm:flush()
      t.eq(#parkedList(h), 1, 'fixture check: the arp host parked itself off the take')
      t.eq(parkedList(h)[1].endppqC, 720, 'fixture check: the host clips at its authored ceiling')

      local mover
      for _, e in ipairs(h.tm:getChannel(1).onTake.notes[1].events) do
        if e.ppq == 960 and not e.derived then mover = e end
      end
      t.truthy(mover, 'fixture check: the neighbour sits on the lane, clear of the cached span')

      h.tm:assignEvent(mover, { ppq = 600 })
      h.tm:flush()

      t.eq(#parkedList(h), 1, 'the moved note stayed on the take, nothing new parked')
      t.eq(parkedList(h)[1].endppqC, 600,
           'the clip fell to the onset that moved into the cached span')
    end,
  },
}
