-- The fx document under the length verbs. A length verb rewrites logical time, and three keys hold
-- logical time no take walk reaches: `fxRegions`, the `fxParked` stash, and the `fxRealisedWindows`
-- census. Left unmapped they part company with the notes around them -- the take stretches, shrinks
-- or loops, and the fx document stays where it was.
-- see docs/trackerManager.md § Length operations
--
-- Each case asserts on the authored span and on the derived output together, since the output is
-- what the author hears: a region whose span did not move keeps deriving at the old rows.

local t    = require('support')
local util = require('util')

local arpUp = { { kind = 'arp', period = { 1, 4 }, dir = 'up' } }

local function hostNote(chan, ppq, endppq)
  return { evType = 'note', ppq = ppq, endppq = endppq, chan = chan, pitch = 60,
           vel = 100, detune = 0, delay = 0, lane = 1 }
end

local function regionOf(h, uuid)
  for _, r in ipairs(h.ds:get('fxRegions') or {}) do
    if r.uuid == uuid then return r end
  end
end

local function parkedNotesOn(h, chan)
  local out = {}
  for _, spec in ipairs(h.ds:get('fxParked') or {}) do
    if spec.evType == 'note' and spec.chan == chan then util.add(out, spec) end
  end
  return out
end

-- The derived onsets on a channel, ascending: an arp region's tiles are its whole visible output.
local function derivedOnsets(h, chan)
  local out = {}
  for _, n in ipairs(h.fm:dump().notes) do
    if n.chan == chan and n.derived then util.add(out, n.ppq) end
  end
  table.sort(out)
  return out
end

local function lastOf(list) return list[#list] end

return {

  {
    -- A stretch scales the logical frame, so a region's span scales with it and its arp fills the
    -- doubled span. The control is the region's own output: unmapped, the region keeps deriving
    -- across the first quarter of the take while everything authored around it has doubled.
    name = 'rescale scales an fx region, its parked host and its derived output',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent(hostNote(1, 0, 240))
      h.tm:addEvent(hostNote(1, 960, 1200))   -- an unregioned control: it doubles by the take walk
      h.tm:flush()
      h.ds:assign('fxRegions',
        { { uuid = 'fxr-1', chan = 1, ppq = 0, endppq = 240, fx = arpUp } })
      h.tm:rebuild()

      local before = derivedOnsets(h, 1)
      t.truthy(#before > 1, 'precondition: the arp seats more than one tile in the region')
      t.truthy(lastOf(before) < 240, 'precondition: its output lies inside the authored span')

      h.tm:rescaleLength(h.fm:length() * 2)

      local region = regionOf(h, 'fxr-1')
      t.eq(region.ppq, 0,   'the region onset scales')
      t.eq(region.endppq,   480, 'and so does its ceiling -- the span doubled with the take')

      local parked = parkedNotesOn(h, 1)
      t.eq(#parked, 1, 'precondition: the region still parks its one covered host')
      t.eq(parked[1].endppq, 480, 'the parked host ceiling scales, so host and region still agree')

      local after = derivedOnsets(h, 1)
      t.truthy(lastOf(after) >= 240,
        'the arp fills the doubled region -- output past the old ceiling')
      t.truthy(lastOf(after) < 480, 'and stays inside the new one')
    end,
  },

  {
    -- A shrink is not a scaling, so the map clips where it cannot scale: a region straddling the new
    -- end keeps the part of its span that survives, and one wholly past it goes with the notes it
    -- covered. Left behind, a region past the end keeps deriving -- output on a take too short to
    -- hold it.
    name = 'a shrink clips a straddling fx region and drops one past the new end',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent(hostNote(1, 0,    240))
      h.tm:addEvent(hostNote(1, 1800, 2040))   -- straddles the shrink at 1920
      h.tm:addEvent(hostNote(1, 2400, 2640))   -- wholly past it
      h.tm:flush()
      h.ds:assign('fxRegions', {
        { uuid = 'fxr-clear',   chan = 1, ppq = 0,    endppq = 240,  fx = arpUp },
        { uuid = 'fxr-astride', chan = 1, ppq = 1800, endppq = 2040, fx = arpUp },
        { uuid = 'fxr-past',    chan = 1, ppq = 2400, endppq = 2640, fx = arpUp } })
      h.tm:rebuild()

      t.eq(#parkedNotesOn(h, 1), 3, 'precondition: each region parks the host it covers')
      t.truthy(lastOf(derivedOnsets(h, 1)) >= 2400,
        'precondition: the far region derives output beyond the shrink')

      h.tm:setLength(1920)

      t.eq(regionOf(h, 'fxr-clear').endppq, 240, 'a region clear of the new end is untouched')
      t.eq(regionOf(h, 'fxr-astride').endppq, 1920, 'a straddling region clips to the new end')
      t.eq(regionOf(h, 'fxr-past'), nil, 'a region wholly past it goes')

      local parked = parkedNotesOn(h, 1)
      t.eq(#parked, 2, 'and takes its parked host with it, as the shrink takes an on-take note')

      t.truthy(lastOf(derivedOnsets(h, 1)) < 1920,
        'nothing derives past the new end -- no region is left there to derive it')
    end,
  },

}
