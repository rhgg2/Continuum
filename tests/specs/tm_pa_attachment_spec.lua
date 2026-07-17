-- Pins PA attachment as an INTENT relation, tested in the logical frame.
--
-- A PA carries its own ppqL and reswings from it (rebuild's CC walk), exactly like a
-- note -- it is not slaved to its host's raw onset. So attachment must be tested on
-- the logical seat: test the raw window instead and any realisation-only shift of the
-- host (a delay, a same-pitch nudge) silently detaches its PAs, and um then declines
-- to move or cull them with their host. see docs/trackerManager.md § PA binding
--
-- Delay is the cheap reachable case; the same hole opens under the tail walk's nudge.

local t = require('support')

local function uuidOfNote(mm, chan, pitch)
  for _, n in mm:notes() do
    if n.chan == chan and n.pitch == pitch then return n.uuid end
  end
end

local function pasOf(mm)
  local out = {}
  for _, c in mm:ccsRaw() do
    if c.evType == 'pa' then out[#out + 1] = c.ppq end
  end
  table.sort(out)
  return out
end

-- Host authored at logical 0 but delayed a full row (delayToPPQ(1000, 240) = 240), so it
-- sounds at raw 240 -- past the PA it owns. Raw-frame attachment cannot see the pair.
local function delayedHostWithPA(harness)
  local h = harness.mk()
  h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 480, chan = 1, pitch = 60,
                  vel = 100, detune = 0, delay = 1000, lane = 1 })
  h.tm:addEvent({ evType = 'pa', ppq = 120, chan = 1, pitch = 60, vel = 70 })
  h.tm:flush()
  return h
end

return {

  {
    name = 'a delayed host still owns the PA at its logical seat: deleting it culls the PA',
    run = function(harness)
      local h = delayedHostWithPA(harness)
      t.deepEq(pasOf(h.fm), { 120 }, 'the PA is on the take to begin with')

      h.tm:deleteEvent(uuidOfNote(h.fm, 1, 60))
      h.tm:flush()

      t.deepEq(pasOf(h.fm), {}, 'the PA died with its host rather than orphaning')
    end,
  },

  {
    name = 'moving a delayed host carries its PA, in both frames',
    run = function(harness)
      local h = delayedHostWithPA(harness)

      -- Logical 0 -> 240: a whole-note shift, so the PA rides it rather than being culled.
      h.tm:assignEvent(uuidOfNote(h.fm, 1, 60), { ppq = 240, endppq = 720 })
      h.tm:flush()

      t.deepEq(pasOf(h.fm), { 360 }, 'the PA moved with its host')
      local pa
      for _, c in h.fm:ccsRaw() do if c.evType == 'pa' then pa = c end end
      t.eq(pa.ppqL, 360, "the PA's logical seat moved too -- raw and intent stay in step")
    end,
  },

}
