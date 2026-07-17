-- Pins PA carry across a translation on a SWUNG channel, where raw and logical disagree.
--
-- resizeNote branches on "is this a translation?": carry the PAs, or cull the ones the new
-- logical span excludes. Swing is a periodic warp, so a logical translation is a raw
-- translation only when the note's logical length is a whole number of swing periods --
-- then both endpoints keep their phase and shift by the same amount. At any other length
-- the endpoints warp differently, and a raw-frame gate reads a whole-note move as a resize
-- and culls PAs the move should have carried. see docs/trackerManager.md § PA binding
--
-- tm_pa_attachment_spec's move case runs under identity swing at length 480, so it is
-- doubly blind to this: raw == logical there, and 480 is a period multiple regardless.

local t = require('support')

local classic58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }

-- Host at logical 0, PA at logical 120 (raw 139 under c58). endL picks the length, which is
-- the whole point: 360 is a period and a half, 480 is two periods exactly.
local function swungHostWithPA(harness, endL)
  local h = harness.mk{
    config = {
      project = { swings = { ['c58'] = classic58 } },
      take    = { rowPerBeat = 4 },
    },
  }
  h.ds:assign('swing', { global = 'c58' })
  h.tm:addEvent({ evType = 'note', ppq = 0, endppq = endL, chan = 1, pitch = 60,
                  vel = 100, detune = 0, delay = 0, lane = 1 })
  h.tm:addEvent({ evType = 'pa', ppq = 120, chan = 1, pitch = 60, vel = 70 })
  h.tm:flush()
  return h
end

local function uuidOfNote(mm, chan, pitch)
  for _, n in mm:notes() do
    if n.chan == chan and n.pitch == pitch then return n.uuid end
  end
end

local function paSeats(mm)
  local out = {}
  for _, c in mm:ccsRaw() do
    if c.evType == 'pa' then out[#out + 1] = c.ppqL or c.ppq end
  end
  table.sort(out)
  return out
end

return {

  {
    name = 'a swung host whose length is not a period multiple still carries its PA when moved',
    run = function(harness)
      local h = swungHostWithPA(harness, 360)
      t.deepEq(paSeats(h.fm), { 120 }, 'the PA is on the take to begin with')

      h.tm:assignEvent(uuidOfNote(h.fm, 1, 60), { ppq = 120, endppq = 480 })
      h.tm:flush()

      t.deepEq(paSeats(h.fm), { 240 }, 'the PA rode the translation rather than being culled')
    end,
  },

  {
    name = 'a swung host whose length IS a period multiple carries its PA too',
    run = function(harness)
      local h = swungHostWithPA(harness, 480)

      h.tm:assignEvent(uuidOfNote(h.fm, 1, 60), { ppq = 120, endppq = 600 })
      h.tm:flush()

      -- The case a raw-frame gate gets right by accident: both endpoints share phase, so the
      -- raw deltas match and the translation is visible in either frame.
      t.deepEq(paSeats(h.fm), { 240 }, 'the PA rode the translation')
    end,
  },

}
