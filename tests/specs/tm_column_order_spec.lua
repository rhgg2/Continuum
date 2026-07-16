-- The fx/park subsystem is a logical-frame subsystem: windows, membership and host extents are all
-- grid notions. Columns are logical-born and sortNoteColumn keeps them in grid order, so the array
-- order IS the grid order. The raw frame still diverges -- raw = fromLogical(ppq) + delayToPPQ(delay),
-- so a delay larger than the gap to a lane-mate reorders the lane in raw while the grid order stands.
-- These cases pin that the consumers reading col.events in array order keep picking the *grid*
-- successor: computeFxWindows' host clip, eachWindowNote's onsets[i+1], nextSameLaneNote's
-- strictNextMap.
--
-- Pins the host clip. A vibrato host's window ends at the strict next same-lane onset; that onset is
-- a grid fact, so pulling the successor *earlier in raw* with a negative delay must not change it.
-- The successor carries the delay (not the host) so the host's own seats stay undelayed and the
-- assertion isolates the ordering effect.

local t = require('support')

-- depth 30c, period 1/4 QN; at res 240 one cycle = 60 ticks. see tm_vibrato_spec
local vib30 = { { kind = 'vibrato', period = { 1, 4 }, depth = 30, onset = 0 } }

-- Note-dest kind: an arp region parks the chord it covers (parksNotes true). see tm_regionpark_gating_spec
local arpUp = { { kind = 'arp', period = { 1, 4 }, dir = 'up' } }

-- Host at ppqL 60 authored long (endppqL 240): its window is bounded by the lane successor, not its
-- own tail, so the clip is what the seat stream reveals.
local function host()
  return { evType = 'note', ppq = 60, endppq = 240, chan = 1, pitch = 60,
           vel = 100, detune = 0, delay = 0, lane = 1, fx = vib30 }
end

-- Same lane, one row past the host's authored end is irrelevant -- it sits inside it, so it is the
-- strict next onset and the host's window must stop there.
local function mate(delay)
  return { evType = 'note', ppq = 120, endppq = 180, chan = 1, pitch = 64,
           vel = 100, detune = 0, delay = delay or 0, lane = 1 }
end

local function pbSeatPpqs(h, chan)
  local out = {}
  for _, c in ipairs(h.fm:dump().ccs) do
    if c.evType == 'pb' and c.chan == chan then out[#out + 1] = c.ppq end
  end
  table.sort(out)
  return out
end

local function lastSeat(h, chan)
  local seats = pbSeatPpqs(h, chan)
  return seats[#seats]
end

-- Glide seats in the host window [fromPpq, ..]: excludes the successor's own realised-onset pb
-- baseline, which the delay relocates (raw 48) but which nextSameLaneNote's ordering does not govern.
local function glideSeats(h, chan, fromPpq)
  local out = {}
  for _, c in ipairs(h.fm:dump().ccs) do
    if c.evType == 'pb' and c.chan == chan and c.ppq >= fromPpq then
      out[#out + 1] = { ppq = c.ppq, val = c.val }
    end
  end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
  return out
end

-- A slide host gliding into its lane successor (pitch 61 = +100c). target='next' resolves the
-- successor via nextSameLaneNote's strictNextMap, which reads the column in array order.
local function slideHost()
  return { evType = 'note', ppq = 60, endppq = 240, chan = 1, pitch = 60,
           vel = 100, detune = 0, delay = 0, lane = 1,
           fx = { { kind = 'slide', over = { 1, 2 }, target = 'next' } } }
end
local function slideMate(delay)
  return { evType = 'note', ppq = 120, endppq = 180, chan = 1, pitch = 61,
           vel = 100, detune = 0, delay = delay or 0, lane = 1 }
end

return {
  {
    name = 'control: an fx host window clips at its strict next same-lane onset',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent(host()); h.tm:flush()
      h.tm:addEvent(mate()); h.tm:flush()

      t.eq(lastSeat(h, 1), 120,
        'host window ends at the lane successor (ppqL 120), not its authored end (240)')
    end,
  },

  {
    name = 'a lane successor delayed earlier in raw still bounds the host window',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent(host()); h.tm:flush()
      -- -300 milli-QN at res 240 = -72 ppq: the mate's raw onset (120 - 72 = 48) lands *before* the
      -- host's (60), so a raw-ordered column presents it as a predecessor and the host sees no
      -- successor at all. On the grid it is still the next note in the lane.
      h.tm:addEvent(mate(-300)); h.tm:flush()

      t.eq(lastSeat(h, 1), 120,
        'window still ends at the successor grid onset -- delay must not unbound the host')
    end,
  },

  {
    name = 'slide(target=next) aims at the grid successor, not the raw-next note',
    run = function(harness)
      local ctrl = harness.mk()
      ctrl.tm:addEvent(slideHost()); ctrl.tm:addEvent(slideMate()); ctrl.tm:flush()
      local expected = glideSeats(ctrl, 1, 60)
      t.truthy(#expected > 0, 'the glide seats a pb stream (successor resolved)')

      local h = harness.mk()
      h.tm:addEvent(slideHost())
      -- -300 milli-QN = -72 ppq: the successor's raw onset (48) lands before the host's (60), so a
      -- raw-ordered lane hides it as the successor and the glide collapses to a targetless lone host.
      h.tm:addEvent(slideMate(-300)); h.tm:flush()

      t.deepEq(glideSeats(h, 1, 60), expected,
        'delay reorders raw only -- the grid successor still sets the glide target')
    end,
  },

  {
    name = 'a note delayed out of a window in raw still parks (membership is grid intent)',
    run = function(harness)
      local h = harness.mk()
      -- ppqL 300 sits inside the region [240, 360); +300 milli-QN (+72 ppq) pushes the raw onset to
      -- 372, outside the window in the realisation frame. Park membership is intent -- it still parks.
      h.tm:addEvent({ evType = 'note', ppq = 300, endppq = 420, chan = 1, pitch = 62,
                      vel = 100, detune = 0, delay = 300, lane = 1 })
      h.tm:flush()
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 240, endppq = 360, fx = arpUp } })
      h.tm:rebuild()

      local parked = {}
      for _, spec in ipairs(h.ds:get('fxParked') or {}) do
        if spec.evType == 'note' and spec.chan == 1 then parked[#parked + 1] = spec end
      end
      t.truthy(#parked > 0,
        'the delayed note parks off-take -- covered() keys ppqL (300), not the raw onset (372)')
    end,
  },

  {
    name = 'a note seats before its PA at an equal onset, stably across rebuilds',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 480, chan = 1, pitch = 60, vel = 100 } },
          ccs   = { { ppq = 0, chan = 1, evType = 'pa', pitch = 60, vel = 90 } },
        },
      }
      local events = h.tm:getChannel(1).columns.notes[1].events
      t.eq(#events, 2, 'note and PA share the column')
      t.eq(events[1].evType, 'note', 'note first at the shared onset')
      t.eq(events[2].evType, 'pa', 'its PA rides after it')

      h.tm:assignEvent(events[1], { vel = 101 })
      h.tm:flush()
      events = h.tm:getChannel(1).columns.notes[1].events
      t.eq(events[1].evType, 'note', 'tie order survives an edit rebuild')
      t.eq(events[2].evType, 'pa', 'PA still second')
    end,
  },
}
