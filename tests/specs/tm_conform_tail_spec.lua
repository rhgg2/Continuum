-- conform-flag tail realisation. A `conform` note's natural length is
-- the logical truth (endppqL); its raw MIDI note-off is a realised
-- projection that tm clips, every rebuild, to the first thing that
-- would block it in this instance:
--
--   raw endppq = max(ppqL+1,
--                    min(endppqL, nextSameLaneOnset, nextSamePitchChanWideOnset))
--
-- endppqL is NEVER overwritten -> editing commands keep seeing the
-- natural length, and deleting the blocker grows the raw tail back.
-- Non-conform notes are untouched by this pass.
--
-- Identity swing in the harness (no swing config) => raw == logical,
-- so a note's ppq/endppq equal its ppqL/endppqL on the way in.

local t = require('support')

local function noteByPitch(notes, pitch)
  for _, n in ipairs(notes) do if n.pitch == pitch then return n end end
end

return {

  {
    name = 'conform note clips raw endppq to next same-lane onset; endppqL natural',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq = 0,   endppq = 960, ppqL = 0,   endppqL = 960,
            chan = 1, pitch = 60, vel = 100, lane = 1, uuid = 1, conform = true },
          { ppq = 480, endppq = 600, ppqL = 480, endppqL = 600,
            chan = 1, pitch = 62, vel = 100, lane = 1, uuid = 2 },
        } },
      }
      local notes = h.fm:dump().notes
      local c = noteByPitch(notes, 60)
      t.truthy(c, 'conform note present')
      t.eq(c.endppq,  480, 'raw note-off clipped to the next same-lane onset')
      t.eq(c.endppqL, 960, 'endppqL stays the natural length')
      local other = noteByPitch(notes, 62)
      t.eq(other.endppq, 600, 'the blocking note is itself untouched')
    end,
  },

  {
    name = 'non-conform note in the same geometry is NOT clipped',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq = 0,   endppq = 960, ppqL = 0,   endppqL = 960,
            chan = 1, pitch = 60, vel = 100, lane = 1, uuid = 1 },
          { ppq = 480, endppq = 600, ppqL = 480, endppqL = 600,
            chan = 1, pitch = 62, vel = 100, lane = 1, uuid = 2 },
        } },
      }
      local c = noteByPitch(h.fm:dump().notes, 60)
      t.eq(c.endppq,  960, 'no conform flag -> tail unclipped')
      t.eq(c.endppqL, 960, 'endppqL unchanged')
    end,
  },

  {
    name = 'clearSameKey truncates a conform peer: raw clips, endppqL stays natural',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { { ppq = 0, endppq = 480, ppqL = 0, endppqL = 480,
                             chan = 1, pitch = 60, vel = 100, uuid = 1,
                             lane = 1, conform = true } } },
      }
      h.tm:addEvent({ evType = 'note', ppq = 240, endppq = 480,
                      ppqL = 240, endppqL = 480,
                      chan = 1, pitch = 60, vel = 100, lane = 1 })
      h.tm:flush()

      local first
      for _, n in ipairs(h.fm:dump().notes) do if n.ppq == 0 then first = n end end
      t.truthy(first, 'conform peer survived')
      t.eq(first.endppq,  240, 'raw note-off clipped for MIDI legality')
      t.eq(first.endppqL, 480, 'endppqL NOT stamped to selfPpqL (conform carve-out)')
    end,
  },

  {
    name = 'deleting the blocker grows the conform raw tail back to endppqL',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq = 0,   endppq = 960, ppqL = 0,   endppqL = 960,
            chan = 1, pitch = 60, vel = 100, lane = 1, uuid = 1, conform = true },
          { ppq = 480, endppq = 600, ppqL = 480, endppqL = 600,
            chan = 1, pitch = 62, vel = 100, lane = 1, uuid = 2 },
        } },
      }
      t.eq(noteByPitch(h.fm:dump().notes, 60).endppq, 480, 'clipped while blocked')

      local blocker
      for _, n in ipairs(h.fm:dump().notes) do if n.pitch == 62 then blocker = n end end
      h.tm:deleteEvent(blocker)
      h.tm:flush()

      local c = noteByPitch(h.fm:dump().notes, 60)
      t.eq(c.endppq,  960, 'blocker gone -> raw tail back to natural')
      t.eq(c.endppqL, 960, 'endppqL was the natural length all along')
    end,
  },

  {
    name = 'a coincident-onset lane peer does NOT clip (strictly-after semantics)',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq = 0, endppq = 960, ppqL = 0, endppqL = 960,
            chan = 1, pitch = 60, vel = 100, lane = 1, uuid = 1, conform = true },
          { ppq = 0, endppq = 480, ppqL = 0, endppqL = 480,
            chan = 1, pitch = 62, vel = 100, lane = 1, uuid = 2 },
        } },
      }
      local c = noteByPitch(h.fm:dump().notes, 60)
      t.eq(c.endppq,  960, 'chord-mate at the same onset is not "following" -> no clip')
      t.eq(c.endppqL, 960, 'endppqL natural')
    end,
  },

  {
    name = 'a trailing conform note with no follower clips its raw tail to take length',
    run = function(harness)
      local h = harness.mk{
        seed = { length = 3840, notes = {
          { ppq = 0, endppq = 5000, ppqL = 0, endppqL = 5000,
            chan = 1, pitch = 60, vel = 100, lane = 1, uuid = 1, conform = true },
        } },
      }
      local c = noteByPitch(h.fm:dump().notes, 60)
      t.eq(c.endppq,  3840, 'no lane/pitch follower -> take length is the backstop')
      t.eq(c.endppqL, 5000, 'endppqL stays the natural length')
    end,
  },

  {
    name = 'conform raw note-off is floored at onset+1 (degenerate natural length)',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { { ppq = 240, endppq = 240, ppqL = 240, endppqL = 240,
                             chan = 1, pitch = 60, vel = 100, lane = 1,
                             uuid = 1, conform = true } } },
      }
      local c = noteByPitch(h.fm:dump().notes, 60)
      t.eq(c.endppq, 241, 'zero natural length floored to onset+1, never <= onset')
    end,
  },
}
