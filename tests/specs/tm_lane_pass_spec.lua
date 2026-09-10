-- The lane pass and its gate. `boundLanes` walks each dirty channel's lanes at the head of a pass
-- and gives every authored event the lane bound of docs/trackerManager.md § Lane occupancy. Its
-- output carries with the channel frame: a channel the dirt does not name holds the bounds it held,
-- on the same event tables. See docs/trackerManager.md § The lane pass.
--
-- The gate is what these cases probe, from both sides. An edit on a channel runs the pass there
-- again, so a neighbour arriving on a lane moves the bound of whatever it now follows -- the first
-- two cases, once on a parked host's render clip and once on the fx window an on-take host's chain
-- runs in.
--
-- An edit elsewhere leaves the channel clean, and the third case asks what its carried bounds are
-- still for. The fx stage skips the channel, so no derived output reads them; the persisted window
-- census does, since every host of every channel enters it whether its chain ran or not. A bound the
-- carry lost would take that channel out of the baseline the next pass recognises seats against.
--
-- The take length is the one input a lane bound takes from outside its own lane, and it reaches the
-- gate by a different road: length moves only through `mm:setLength`, whose reload dirties every
-- channel. So the last case grows the take and expects a clean channel's OPEN host to follow it.
--
-- A depth-30 sine host seats a pb stream across exactly its window, so the last pb seat tracks the
-- window end. That is the observable cases two to four lean on.

local t    = require('support')
local util = require('util')

local arpUp  = { { kind = 'arp', period = { 1, 4 }, dir = 'up' } }   -- replace-mode: parks its host
local sine30 = { { kind = 'sine', period = { 1, 4 }, depth = 30, onset = 0 } }

local function note(chan, lane, ppq, endppq, pitch, extra)
  local n = { evType = 'note', ppq = ppq, endppq = endppq, chan = chan, pitch = pitch,
              vel = 100, detune = 0, delay = 0, lane = lane }
  for k, v in pairs(extra or {}) do n[k] = v end
  return n
end

-- An OPEN-ended sine host on ch1 lane 1: its pb seats fill its whole window.
local function addVibHost(h)
  h.tm:addEvent(note(1, 1, 0, util.OPEN, 60, { fx = sine30 }))
  h.tm:flush()
end

-- The last pb seat a channel carries: where the chain writing it stopped, and so where its window closed.
local function lastPbSeat(h, chan)
  local last
  for _, c in ipairs(h.fm:dump().ccs) do
    if c.evType == 'pb' and c.chan == chan and (last == nil or c.ppq > last) then last = c.ppq end
  end
  return last
end

local function parkedList(h, chan) return h.tm:getChannel(chan).parked.notes end

local function onTakeAt(h, chan, lane, ppq)
  for _, evt in ipairs(h.tm:getChannel(chan).onTake.notes[lane].events) do
    if evt.ppq == ppq and not evt.derived then return evt end
  end
end

-- A channel's share of the persisted window census, as spans: the baseline the next pass replays.
local function census(h, chan)
  local out = {}
  for _, entry in ipairs(h.ds:get('fxRealisedWindows') or {}) do
    if entry.chan == chan then
      util.add(out, util.key(entry.evType, entry.cc, entry.ppq, entry.endppq))
    end
  end
  table.sort(out)
  return out
end

return {

  {
    -- A self-parking arp host at 480 authored to 720, and a plain note further down its lane at 960,
    -- outside the host's span. The mover lands on 600, inside that span and still clear of the
    -- host's window, so the only thing that moves is the bound under test.
    name = "a neighbour arriving on a host's lane moves the host's render clip",
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent(note(1, 1, 480, 720, 62, { fx = arpUp }))
      h.tm:addEvent(note(1, 1, 960, 1200, 64))
      h.tm:flush()
      t.eq(#parkedList(h, 1), 1, 'fixture check: the arp host parked itself off the take')
      t.eq(parkedList(h, 1)[1].endppqC, 720, 'fixture check: the host sounds to its authored ceiling')

      local mover = onTakeAt(h, 1, 1, 960)
      t.truthy(mover, 'fixture check: the neighbour sits on the lane, clear of the host')

      h.tm:assignEvent(mover, { ppq = 600 })
      h.tm:flush()

      t.eq(#parkedList(h, 1), 1, 'the moved note stayed on the take, nothing new parked')
      t.eq(parkedList(h, 1)[1].endppqC, 600,
           'the bound fell to the onset that arrived inside the span it held')
    end,
  },

  {
    name = "a successor arriving on a host's lane closes its fx window",
    run = function(harness)
      local h = harness.mk()
      addVibHost(h)
      t.truthy(lastPbSeat(h, 1) > 480, 'precondition: the OPEN host seats pb across the whole take')

      h.tm:addEvent(note(1, 1, 480, 540, 64))
      h.tm:flush()

      t.eq(lastPbSeat(h, 1), 479,
           'the window closed on the new lane successor, a tick inside its onset')
    end,
  },

  {
    name = "a clean channel's carried bound still enters the persisted window census",
    run = function(harness)
      local h = harness.mk()
      addVibHost(h)
      local before = census(h, 1)
      t.truthy(#before > 0, 'precondition: the host entered the census on the pass that ran its chain')

      h.tm:addEvent(note(2, 1, 240, 300, 64))
      h.tm:flush()

      t.truthy(onTakeAt(h, 1, 1, 0), 'ch1 carried its host')
      t.deepEq(census(h, 1), before, 'and its window stands in the census, off the bound it carried')
    end,
  },

  {
    name = 'growing the take extends a clean OPEN host window',
    run = function(harness)
      local h = harness.mk()
      addVibHost(h)
      local before = lastPbSeat(h, 1)

      h.tm:setLength(4800)                     -- past the default 3840; the grow reloads wholesale
      h.tm:addEvent(note(2, 1, 240, 300, 64))  -- an unrelated ch2 edit; ch1 must not keep a short bound
      h.tm:flush()

      t.truthy(lastPbSeat(h, 1) > before, 'the OPEN host followed the grown take')
    end,
  },

}
