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

local t = require('support')

local function ppqsOf(mm)
  local out = {}
  for _, n in mm:notes() do out[#out + 1] = n.ppq end
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

}
