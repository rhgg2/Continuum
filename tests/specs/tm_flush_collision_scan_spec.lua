-- Pins tm's flush collision scan against COMMITTED notes -- the half that had no
-- coverage, and stayed uncovered through a live regression: loadIndex assigned a
-- global byToken and the scan iterated it empty, so it silently stopped considering
-- any committed note while the suite passed straight over it.
--
-- The dedup case below is the one that pins the scan, and only because of an
-- asymmetry: the walk (voicing.nudgeOnsets) separates but never kills, so it covered
-- the scan's nudge -- which is why that nudge could go -- and cannot cover its dedup.
-- Worse, by separating first the walk defeats mm's dedup backstop too: resolveGroup
-- finds nothing left to collapse at the unwind. This scan is the only thing in the
-- stack that dedups a staged add against a committed one. see docs/trackerManager.md
--
-- The grouping cases (channel, pitch) are parity pins: they were green against the
-- old byUuid+adds sweep before the rawIndex walk replaced it, so they characterise
-- the scan's reach rather than the walk that now implements it.

local t = require('support')
local voicing = require('voicing')   -- the sorted door is this scan's only caller; its pins live here

local function ppqsOf(mm)
  local out = {}
  for _, n in mm:notes() do out[#out + 1] = n.ppq end
  table.sort(out)
  return out
end

-- Seat identity across channels and pitches, where a bare ppq list can't tell two
-- survivors apart.
local function seatsOf(mm)
  local out = {}
  for _, n in mm:notes() do
    out[#out + 1] = string.format('ch%d p%d @%d', n.chan, n.pitch, n.ppq)
  end
  table.sort(out)
  return out
end

-- Seeds bypass addEvent, so ppqL is free of its caller-ppq-is-logical rule.
local function seeded(harness, note)
  return harness.mk{ seed = { notes = { note } } }
end

return {

  -- Not this scan's job any more: its nudge went at 2026-07-17, exactly because the
  -- walk and mm's backstop deliver this anyway. Kept as the pin on that claim -- the
  -- separation must survive the removal. The dedup case below is the scan's own.
  {
    name = 'a staged add colliding with a committed note ends up separated',
    run = function(harness)
      -- Authored at logical 0, delayed a full row (delayToPPQ(1000, 240) = 240): it sounds
      -- at raw 240, the seat the add below is authored on. Distinct voices, one raw onset.
      local h = seeded(harness, { ppq = 240, endppq = 480, ppqL = 0, endppqL = 240,
                                  chan = 1, pitch = 60, vel = 100, lane = 1,
                                  detune = 0, delay = 1000 })

      h.tm:addEvent({ evType = 'note', ppq = 240, endppq = 480,
                      chan = 1, pitch = 60, vel = 100, lane = 1 })
      h.tm:flush()

      t.deepEq(ppqsOf(h.fm), { 240, 241 }, 'both voices survive, separated')
    end,
  },

  {
    name = 'a staged add duplicating a committed note collapses, and no layer below will do it',
    run = function(harness)
      -- Same logical seat and detune, so redundant(): the longer supersedes, the peer dies.
      local h = seeded(harness, { ppq = 0, endppq = 240, ppqL = 0, endppqL = 240,
                                  chan = 1, pitch = 60, vel = 100, lane = 1 })

      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 480,
                      chan = 1, pitch = 60, vel = 100, lane = 1 })
      h.tm:flush()

      -- Without the scan the walk nudges instead of killing, and the duplicate survives at 1.
      t.deepEq(ppqsOf(h.fm), { 0 }, 'the duplicate collapsed -- one voice at the seat')
    end,
  },

  -- The scan walks channels 1..16 rather than sweeping a uuid map, so a loop bound or
  -- a per-channel bucket mistake is invisible on channel 1.
  {
    name = 'the scan reaches a channel other than 1',
    run = function(harness)
      local h = seeded(harness, { ppq = 0, endppq = 240, ppqL = 0, endppqL = 240,
                                  chan = 5, pitch = 60, vel = 100, lane = 1 })

      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 480,
                      chan = 5, pitch = 60, vel = 100, lane = 1 })
      h.tm:flush()

      t.deepEq(seatsOf(h.fm), { 'ch5 p60 @0' }, 'the duplicate collapsed on channel 5')
    end,
  },

  {
    name = 'notes at one onset on distinct pitches do not collide',
    run = function(harness)
      local h = seeded(harness, { ppq = 0, endppq = 240, ppqL = 0, endppqL = 240,
                                  chan = 1, pitch = 60, vel = 100, lane = 1 })

      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240,
                      chan = 1, pitch = 62, vel = 100, lane = 1 })
      h.tm:flush()

      t.deepEq(seatsOf(h.fm), { 'ch1 p60 @0', 'ch1 p62 @0' }, 'both pitches keep the seat')
    end,
  },

  {
    name = 'one pitch on two channels does not collide',
    run = function(harness)
      local h = seeded(harness, { ppq = 0, endppq = 240, ppqL = 0, endppqL = 240,
                                  chan = 1, pitch = 60, vel = 100, lane = 1 })

      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240,
                      chan = 2, pitch = 60, vel = 100, lane = 1 })
      h.tm:flush()

      t.deepEq(seatsOf(h.fm), { 'ch1 p60 @0', 'ch2 p60 @0' }, 'both channels keep the seat')
    end,
  },

  -- The scan feeds resolveSorted a bucket it never sorts, so the two doors must agree.
  {
    name = 'resolveSorted matches resolveGroup on the same notes',
    run = function()
      local function seat(id, ppq, endppqL) return { id = id, ppq = ppq, ppqL = ppq, endppqL = endppqL } end
      local function idsOf(kills)
        local out = {}
        for _, n in ipairs(kills) do out[#out + 1] = n.id end
        table.sort(out)
        return out
      end

      -- 'short' and 'long' share a logical seat and detune, so they are redundant and the
      -- longer supersedes; 'later' stands clear of both.
      local short, long, later = seat('short', 0, 240), seat('long', 0, 480), seat('later', 240, 480)

      t.deepEq(idsOf(voicing.resolveGroup({ long, later, short })), { 'short' }, 'sorting door')
      t.deepEq(idsOf(voicing.resolveSorted({ short, long, later })), { 'short' }, 'sorted door')
    end,
  },

  {
    name = 'a derived note loses its seat from either input order',
    run = function()
      local function idsOf(kills)
        local out = {}
        for _, n in ipairs(kills) do out[#out + 1] = n.id end
        return out
      end
      -- Tied on (ppq, ppqL), so both orders honour resolveSorted's contract -- and the tie is
      -- exactly where index.order may hand it over in either order.
      local authored = { id = 'authored', ppq = 0, ppqL = 0, endppqL = 240 }
      local derived  = { id = 'derived',  ppq = 0, ppqL = 0, endppqL = 960, derived = 'fx' }

      t.deepEq(idsOf(voicing.resolveSorted({ authored, derived })), { 'derived' }, 'authored first')
      t.deepEq(idsOf(voicing.resolveSorted({ derived, authored })), { 'derived' }, 'derived first')
    end,
  },

}
