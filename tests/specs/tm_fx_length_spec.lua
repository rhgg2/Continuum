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

-- Onset order, the stash keeping none of its own: a case naming a spec positionally means the nth
-- parked cell down the channel.
local function parkedNotesOn(h, chan)
  local out = {}
  for _, spec in ipairs(h.ds:get('fxParked') or {}) do
    if spec.evType == 'note' and spec.chan == chan then util.add(out, spec) end
  end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
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

local function within(list, from, to)
  local out = {}
  for _, v in ipairs(list) do if v >= from and v < to then util.add(out, v) end end
  return out
end

local function shiftedBy(list, delta)
  local out = {}
  for _, v in ipairs(list) do util.add(out, v + delta) end
  return out
end

local function regionsOn(h, chan)
  local out = {}
  for _, r in ipairs(h.ds:get('fxRegions') or {}) do
    if r.chan == chan then util.add(out, r) end
  end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
  return out
end

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

  {
    -- A tile loops the intent, so a region and the hosts it parks come round again at each offset --
    -- the copies being fresh records, since nothing links a region to the one it was copied from.
    -- The census does not tile: a tiled region's seats do not exist yet, and an absent entry is the
    -- true statement that the take carries none there.
    name = 'a tile loops the fx regions and the stash with the take',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent(hostNote(1, 0, 240))
      h.tm:addEvent(hostNote(1, 960, 1200))   -- an unregioned control: the take walk loops it
      h.tm:flush()
      h.ds:assign('fxRegions',
        { { uuid = 'fxr-1', chan = 1, ppq = 0, endppq = 240, fx = arpUp } })
      h.tm:rebuild()

      local oldPpq = h.fm:length()
      local source = derivedOnsets(h, 1)
      t.truthy(#source > 1, 'precondition: the arp seats more than one tile in the region')

      h.tm:tileLength(oldPpq * 2)

      local regions = regionsOn(h, 1)
      t.eq(#regions, 2, 'the region comes round again in the second copy')
      t.eq(regions[2].ppq,    oldPpq,       'the copy sits one period on')
      t.eq(regions[2].endppq, oldPpq + 240, 'carrying its span with it')
      t.truthy(regions[2].uuid ~= regions[1].uuid, 'and holding an id of its own')
      t.eq(regions[2].fx[1].kind, 'arp', 'the chain copies with the region')

      local parked = parkedNotesOn(h, 1)
      t.eq(#parked, 2, 'the host the region parks comes round with it')
      t.eq(parked[2].ppq, oldPpq, 'parked where the copied region covers it')
      t.truthy(parked[2].uuid ~= parked[1].uuid, 'under an id of its own, the take holding neither')

      -- The take walk copies authored events only. Were it to copy derived ones too, the copies
      -- would land inside the copied region's live window and stand alongside what it derives.
      local after = derivedOnsets(h, 1)
      t.deepEq(within(after, 0, 240), source, 'the first copy derives what it always did')
      t.deepEq(within(after, oldPpq, oldPpq + 240), shiftedBy(source, oldPpq),
        'and the second derives the same, one period on')
    end,
  },

  {
    -- A tile need not divide, and the last copy is then a partial one. It maps like any other, so a
    -- region astride the new end clips to it and one whose onset is past it never lands -- the same
    -- verdict the take walk passes on the notes beside them.
    name = 'a partial tile clips the region astride the new end and drops one past it',
    run = function(harness)
      local h = harness.mk()
      for _, ppq in ipairs({ 0, 1800, 3000 }) do
        h.tm:addEvent(hostNote(1, ppq, ppq + 240))
      end
      h.tm:flush()
      h.ds:assign('fxRegions', {
        { uuid = 'fxr-early',   chan = 1, ppq = 0,    endppq = 240,  fx = arpUp },
        { uuid = 'fxr-astride', chan = 1, ppq = 1800, endppq = 2040, fx = arpUp },
        { uuid = 'fxr-past',    chan = 1, ppq = 3000, endppq = 3240, fx = arpUp } })
      h.tm:rebuild()

      local oldPpq = h.fm:length()   -- 3840; the copy lands at +3840 and the take ends at 5760
      local newPpq = oldPpq * 1.5
      t.eq(#regionsOn(h, 1), 3, 'precondition: three regions in the source copy')

      h.tm:tileLength(newPpq)

      local regions = regionsOn(h, 1)
      t.eq(#regions, 5, 'two of the three come round; the third has nowhere to land')
      t.eq(regions[4].ppq,    oldPpq,        'the early region copies whole')
      t.eq(regions[4].endppq, oldPpq + 240,  'span and all')
      t.eq(regions[5].ppq,    oldPpq + 1800, 'the next one lands astride the new end')
      t.eq(regions[5].endppq, newPpq,        'and clips to it')

      local parked = parkedNotesOn(h, 1)
      t.eq(#parked, 5, 'the hosts they park come round with them, and the third host likewise does not')
      t.eq(parked[5].endppq, newPpq, 'the astride host clips where its region does')

      t.truthy(lastOf(derivedOnsets(h, 1)) < newPpq, 'nothing derives past the new end')
    end,
  },

}
