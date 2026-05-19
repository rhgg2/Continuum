-- Universal tail realisation. EVERY note's natural length is logical
-- intent (endppqL, a ceiling; util.OPEN => unbounded; nil => uncached,
-- derive from raw); its raw MIDI note-off is a realised projection tm
-- re-derives every rebuild:
--
--   raw endppq = max(ppqL+1,
--                    min(ceiling,
--                        nextSameLaneOnsetL + (overlap or 0),
--                        nextSamePitchChanWideOnsetL,
--                        takeLenL))
--
--   ceiling = (endppqL == util.OPEN) and inf
--             or (endppqL or toLogical(endppq))
--
-- endppqL is intent: never overwritten from a clipped raw, only
-- backfilled once when absent. A util.OPEN note carries no ceiling
-- (the freshly-placed legato note) and keeps the sentinel. Deleting a
-- blocker grows the raw tail back up to the ceiling (take length when
-- open). There is no `conform` flag: legato is universal, a finite
-- ceiling shorter than every gap is staccato, and `overlap` is the
-- only per-note legato datum (it overruns the next column onset, never
-- the same-pitch MIDI onset).
--
-- Identity swing in the harness (no swing config) => raw == logical,
-- so a note's ppq/endppq equal its ppqL/endppqL on the way in.

local t    = require('support')
local util = require('util')

local function noteByPitch(notes, pitch)
  for _, n in ipairs(notes) do if n.pitch == pitch then return n end end
end

return {

  {
    name = 'open note (no ceiling) clips its raw tail to the next same-lane onset',
    run = function(harness)
      local h = harness.mk{
        seed = { length = 3840, notes = {
          { ppq = 0,   endppq = 3840, ppqL = 0, endppqL = util.OPEN,
            chan = 1, pitch = 60, vel = 100, lane = 1, uuid = 1 },
          { ppq = 480, endppq = 600, ppqL = 480, endppqL = 600,
            chan = 1, pitch = 62, vel = 100, lane = 1, uuid = 2 },
        } },
      }
      local notes = h.fm:dump().notes
      local a = noteByPitch(notes, 60)
      t.eq(a.endppq,  480, 'open tail clipped to the next same-lane onset')
      t.eq(a.endppqL, util.OPEN, 'open note keeps the util.OPEN sentinel, never a finite ceiling')
      t.eq(noteByPitch(notes, 62).endppq, 600, 'the blocking note is untouched')
    end,
  },

  {
    name = 'finite ceiling shorter than the gap is staccato — stays on blocker delete',
    run = function(harness)
      local h = harness.mk{
        seed = { length = 3840, notes = {
          { ppq = 0,   endppq = 240, ppqL = 0,   endppqL = 240,
            chan = 1, pitch = 60, vel = 100, lane = 1, uuid = 1 },
          { ppq = 480, endppq = 600, ppqL = 480, endppqL = 600,
            chan = 1, pitch = 62, vel = 100, lane = 1, uuid = 2 },
        } },
      }
      t.eq(noteByPitch(h.fm:dump().notes, 60).endppq, 240, 'ceiling < gap -> note is its ceiling')

      local blocker = noteByPitch(h.fm:dump().notes, 62)
      h.tm:deleteEvent(blocker)
      h.tm:flush()

      local a = noteByPitch(h.fm:dump().notes, 60)
      t.eq(a.endppq,  240, 'blocker gone but ceiling caps it — does not breathe')
      t.eq(a.endppqL, 240, 'ceiling intact')
    end,
  },

  {
    name = 'finite ceiling longer than the gap clips down, regrows up to the ceiling',
    run = function(harness)
      local h = harness.mk{
        seed = { length = 3840, notes = {
          { ppq = 0,   endppq = 960, ppqL = 0,   endppqL = 960,
            chan = 1, pitch = 60, vel = 100, lane = 1, uuid = 1 },
          { ppq = 480, endppq = 600, ppqL = 480, endppqL = 600,
            chan = 1, pitch = 62, vel = 100, lane = 1, uuid = 2 },
        } },
      }
      t.eq(noteByPitch(h.fm:dump().notes, 60).endppq, 480, 'clipped down to the blocker')

      h.tm:deleteEvent(noteByPitch(h.fm:dump().notes, 62))
      h.tm:flush()

      local a = noteByPitch(h.fm:dump().notes, 60)
      t.eq(a.endppq,  960, 'blocker gone -> regrows up to the ceiling, not past it')
      t.eq(a.endppqL, 960, 'ceiling intact')
    end,
  },

  {
    name = 'overlap overruns the next column onset but never the same-pitch MIDI onset',
    run = function(harness)
      local diffPitch = harness.mk{
        seed = { length = 3840, notes = {
          { ppq = 0,   endppq = 3840, ppqL = 0, endppqL = util.OPEN, overlap = 120,
            chan = 1, pitch = 60, vel = 100, lane = 1, uuid = 1 },
          { ppq = 480, endppq = 600, ppqL = 480, endppqL = 600,
            chan = 1, pitch = 62, vel = 100, lane = 1, uuid = 2 },
        } },
      }
      t.eq(noteByPitch(diffPitch.fm:dump().notes, 60).endppq, 600,
           'overruns the next (different-pitch) column onset by overlap')

      local samePitch = harness.mk{
        seed = { length = 3840, notes = {
          { ppq = 0,   endppq = 3840, ppqL = 0, endppqL = util.OPEN, overlap = 120,
            chan = 1, pitch = 60, vel = 100, lane = 1, uuid = 1 },
          { ppq = 480, endppq = 600, ppqL = 480, endppqL = 600,
            chan = 1, pitch = 60, vel = 100, lane = 1, uuid = 2 },
        } },
      }
      t.eq(noteByPitch(samePitch.fm:dump().notes, 60).endppq, 480,
           'same-pitch MIDI onset is hard physics — overlap cannot cross it')
    end,
  },

  {
    name = 'a trailing open note with no follower clips its raw tail to take length',
    run = function(harness)
      local h = harness.mk{
        seed = { length = 3840, notes = {
          { ppq = 0, endppq = 3840, ppqL = 0, endppqL = util.OPEN,
            chan = 1, pitch = 60, vel = 100, lane = 1, uuid = 1 },
        } },
      }
      t.eq(noteByPitch(h.fm:dump().notes, 60).endppq, 3840,
           'no lane/pitch follower -> take length is the backstop')
    end,
  },

  {
    name = 'a coincident-onset chord-mate is not "following" -> no clip',
    run = function(harness)
      local h = harness.mk{
        seed = { length = 3840, notes = {
          { ppq = 0, endppq = 3840, ppqL = 0, endppqL = util.OPEN,
            chan = 1, pitch = 60, vel = 100, lane = 1, uuid = 1 },
          { ppq = 0, endppq = 480, ppqL = 0, endppqL = 480,
            chan = 1, pitch = 62, vel = 100, lane = 1, uuid = 2 },
        } },
      }
      t.eq(noteByPitch(h.fm:dump().notes, 60).endppq, 3840,
           'chord-mate at the same onset is not a blocker -> take length')
    end,
  },

  {
    name = 'raw note-off is floored at onset+1 (degenerate ceiling)',
    run = function(harness)
      local h = harness.mk{
        seed = { length = 3840, notes = {
          { ppq = 240, endppq = 240, ppqL = 240, endppqL = 240,
            chan = 1, pitch = 60, vel = 100, lane = 1, uuid = 1 } } },
      }
      t.eq(noteByPitch(h.fm:dump().notes, 60).endppq, 241,
           'zero-length ceiling floored to onset+1, never <= onset')
    end,
  },
}
