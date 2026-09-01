-- The parked half of a channel is subject to the same renewal rule as the on-take half
-- (docs/trackerManager.md § Note-lane renewal): the list changes identity iff its contents
-- changed. tv's cell carry keys on the table `tm:authoredLanes` hands back, so a parked-bearing
-- lane whose population held must hand back the same table across a rebuild, or it re-places every
-- pass -- which is what it did before renderUnion reconciled, since it minted all sixteen lists
-- afresh whether or not anything parked.
--
-- `endppqC` is the reason the rule is about contents and not about the stash: the clip is derived
-- after installation from the lane's strict-next onset, so it can move with the parked spec
-- standing still. Case 3 is that case.
--
-- The fixture is a self-parking arp host at 480 on chan 1 lane 1, alone on its lane, and a plain
-- note on chan 2 -- a second channel to dirty, so a pass can run without touching chan 1.

local t = require('support')

local arpUp = { { kind = 'arp', period = { 1, 4 }, dir = 'up' } }   -- replace-mode: parks its host

local function note(ppq, pitch, chan, extra)
  local n = { evType = 'note', ppq = ppq, endppq = ppq + 240, chan = chan, pitch = pitch,
              vel = 100, detune = 0, delay = 0, lane = 1 }
  for k, v in pairs(extra or {}) do n[k] = v end
  return n
end

local function parkedList(h) return h.tm:getChannel(1).parked.notes end

-- chan 1 holds one parked host, chan 2 one plain note; the parked list is returned by identity.
local function parkedHost(harness)
  local h = harness.mk()
  h.tm:addEvent(note(480, 62, 1, { fx = arpUp }))
  h.tm:addEvent(note(0, 60, 2))
  h.tm:flush()
  t.eq(#parkedList(h), 1, 'fixture check: the arp host parked itself off the take')
  return h, parkedList(h)
end

return {

  {
    name = 'a pass that leaves the parked population alone keeps the list and its events',
    run = function(harness)
      local h, parked = parkedHost(harness)
      local host = parked[1]

      h.tm:addEvent(note(960, 64, 2)); h.tm:flush()

      t.truthy(parkedList(h) == parked, 'the parked list carried across the pass')
      t.truthy(parkedList(h)[1] == host, 'and so did the event in it')
    end,
  },

  {
    name = 'a lane holding a parked event answers with the same population table across a pass',
    run = function(harness)
      local h = parkedHost(harness)
      local lane = h.tm:authoredLanes(1)[1]
      t.eq(#lane, 1, 'fixture check: the lane reads as its parked host alone')

      h.tm:addEvent(note(960, 64, 2)); h.tm:flush()

      t.truthy(h.tm:authoredLanes(1)[1] == lane, "the union carried, so tv's cell carry stands")
    end,
  },

  {
    name = 'a parked population that changed sheds the list',
    run = function(harness)
      local h, parked = parkedHost(harness)

      h.tm:assignParked(parked[1], { pitch = 67 }); h.tm:flush()

      t.eq(parkedList(h)[1].pitch, 67, 'fixture check: the edit reached the parked event')
      t.truthy(parkedList(h) ~= parked, 'the list that took an edit shed its table')
    end,
  },

  {
    -- The new note lands at the host's own authored ceiling, so no window covers it and it stays on
    -- the take: the parked population is untouched. What moves is the host's clip, from its authored
    -- endppq down to its lane's new strict-next onset -- a content change the stash cannot see.
    name = 'a parked event whose clip moved sheds the list, though its spec stood still',
    run = function(harness)
      local h, parked = parkedHost(harness)
      local host = parked[1]
      t.eq(host.endppqC, 720, 'fixture check: the host clips at its authored ceiling')

      h.tm:addEvent(note(600, 64, 1)); h.tm:flush()

      t.eq(#parkedList(h), 1, 'fixture check: the added note stayed on the take, nothing new parked')
      t.eq(parkedList(h)[1].endppqC, 600, 'the clip fell to the lane\'s new strict-next onset')
      t.truthy(parkedList(h) ~= parked, 'the list whose clip moved shed its table')
    end,
  },

}
