-- Sharp edges for the seed-driven tail walk (design/interval-dirt.md § Phase 4.75).
--
-- Each case asserts the production tails directly. Three shapes the rest of the
-- suite never exercises:
--
--   1. a same-tick pile-up whose separation cascades from a single add seed;
--   2. an open note behind dirt, shielded and unshielded by a same-lane note
--      (the § Span-staleness lane shield: binding the nearest same-lane
--      predecessor of the seed subsumes the old intersects() span term);
--   3. an insertion landing inside another note's overlap margin.

local t    = require('support')
local util = require('util')

local function noteByPitch(notes, pitch)
  for _, n in ipairs(notes) do if n.pitch == pitch then return n end end
end

local function pitchRaws(h, pitch)
  local out = {}
  for _, n in h.fm:notes() do if n.pitch == pitch then out[#out + 1] = n.ppq end end
  table.sort(out)
  return out
end

-- Every column row a pitch stands on, across the channel's note lanes.
local function pitchRows(h, pitch)
  local out = {}
  for _, col in ipairs(h.tm:getChannel(1).onTake.notes) do
    for _, e in ipairs(col.events) do
      if e.pitch == pitch then out[#out + 1] = e.ppq end
    end
  end
  table.sort(out)
  return out
end

-- Four pitch-60 voices on one tick, each landing in its own flush, so each add
-- settles against the already-separated pile below it.
local function pileUp(h)
  for lane = 1, 4 do
    h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                    vel = 100, detune = (lane - 1) * 20, delay = 0, lane = lane })
    h.tm:flush()
  end
  t.deepEq(pitchRaws(h, 60), { 0, 1, 2, 3 }, 'the pile-up separated one tick apart')
end

return {

  {
    name = 'a single add seed cascades the whole same-tick pile-up apart',
    run = function(harness)
      local h = harness.mk{ seed = { length = 3840 } }

      -- Three pitch-60 voices dropped on one tick. Distinct detune keeps them
      -- from deduping, so settlement separates them to 0, 1, 2.
      for lane = 1, 3 do
        h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                        vel = 100, detune = (lane - 1) * 20, delay = 0, lane = lane })
      end
      h.tm:flush()
      t.deepEq(pitchRaws(h, 60), { 0, 1, 2 }, 'the initial pile-up settled')

      -- A fourth voice on the same tick: the ONE add seed must cascade the
      -- settlement through the already-settled notes to make room.
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                      vel = 100, detune = 60, delay = 0, lane = 4 })
      h.tm:flush()
      t.deepEq(pitchRaws(h, 60), { 0, 1, 2, 3 },
        'the seed reached past its own onset and pushed the whole column along')
    end,
  },

  {
    name = 'a collision nudge is our own write, not a foreign raw edit',
    run = function(harness)
      local h = harness.mk{ seed = { length = 3840 } }
      pileUp(h)

      -- Past EPS the raw no longer agrees with the row, but the disagreement is
      -- ours: every voice still belongs on the row it was authored at.
      t.deepEq(pitchRows(h, 60), { 0, 0, 0, 0 },
        'the nudged voices hold the authored row')
    end,
  },

  {
    name = 'a seed-capped flush re-derives the pile-up without restamping it',
    run = function(harness)
      local h = harness.mk{ seed = { length = 3840 } }
      pileUp(h)

      -- One flush past dirt's seed cap collapses the channel to wholesale. The
      -- seeds are still ours, so the re-derive must seat the pile where it was.
      for i = 1, 70 do
        h.tm:addEvent({ evType = 'note', ppq = 480 * i, endppq = 480 * i + 240, chan = 1,
                        pitch = 72, vel = 100, detune = 0, delay = 0, lane = 1 })
      end
      h.tm:flush()

      t.deepEq(pitchRaws(h, 60), { 0, 1, 2, 3 }, 'the pile-up survived the re-derive')
      t.deepEq(pitchRows(h, 60), { 0, 0, 0, 0 },
        'and every voice kept the row it was authored at')
    end,
  },

  {
    name = 'deleting a blocker regrows the open note behind it — no shield',
    run = function(harness)
      local h = harness.mk{
        seed = { length = 3840, notes = {
          { ppq = 0,   endppq = 3840, ppqL = 0, endppqL = util.OPEN,
            chan = 1, pitch = 60, vel = 100, lane = 1, uuid = 1 },
          { ppq = 480, endppq = 600, ppqL = 480, endppqL = 600,
            chan = 1, pitch = 62, vel = 100, lane = 1, uuid = 2 },
        } },
      }
      t.eq(noteByPitch(h.fm:dump().notes, 60).endppq, 480, 'clipped to the blocker')

      h.tm:deleteEvent(noteByPitch(h.fm:dump().notes, 62))
      h.tm:flush()

      -- The delete seed sits at 480; the nearest same-lane predecessor is the
      -- open note, so the walk binds and regrows it to take length.
      t.eq(noteByPitch(h.fm:dump().notes, 60).endppq, 3840,
        'blocker gone, nothing between -> regrows to take length')
    end,
  },

  {
    name = 'a same-lane shield leaves the open note untouched when dirt lands beyond it',
    run = function(harness)
      local h = harness.mk{
        seed = { length = 3840, notes = {
          { ppq = 0,   endppq = 3840, ppqL = 0,   endppqL = util.OPEN,
            chan = 1, pitch = 60, vel = 100, lane = 1, uuid = 1 },
          { ppq = 240, endppq = 360, ppqL = 240, endppqL = 360,
            chan = 1, pitch = 64, vel = 100, lane = 1, uuid = 2 },   -- the shield
          { ppq = 480, endppq = 600, ppqL = 480, endppqL = 600,
            chan = 1, pitch = 62, vel = 100, lane = 1, uuid = 3 },   -- the dirt-to-be
        } },
      }
      t.eq(noteByPitch(h.fm:dump().notes, 60).endppq, 240, 'clipped to the nearer shield')

      h.tm:deleteEvent(noteByPitch(h.fm:dump().notes, 62))
      h.tm:flush()

      -- The delete seed sits at 480, but the nearest same-lane predecessor is
      -- the shield at 240, not the open note. Binding the shield subsumes the
      -- span term: the open note is never touched and holds its clip.
      t.eq(noteByPitch(h.fm:dump().notes, 60).endppq, 240,
        'shielded -> the walk binds the shield, the open note stays clipped')
    end,
  },

  {
    name = 'an insertion inside the overlap margin re-clips the overlapping tail',
    run = function(harness)
      local h = harness.mk{
        seed = { length = 3840, notes = {
          { ppq = 0,   endppq = 3840, ppqL = 0, endppqL = util.OPEN, overlap = 120,
            chan = 1, pitch = 60, vel = 100, lane = 1, uuid = 1 },
          { ppq = 480, endppq = 600, ppqL = 480, endppqL = 600,
            chan = 1, pitch = 62, vel = 100, lane = 1, uuid = 2 },
        } },
      }
      t.eq(noteByPitch(h.fm:dump().notes, 60).endppq, 600,
        'overruns the different-pitch column onset by the overlap margin')

      -- A same-pitch voice inside [480, 600): the hard MIDI onset the overlap
      -- cannot cross. The add seed at 540 must bind the overlapping note (its
      -- nearest same-pitch predecessor) and re-clip it.
      h.tm:addEvent({ evType = 'note', ppq = 540, endppq = 700, chan = 1, pitch = 60,
                      vel = 100, detune = 0, delay = 0, lane = 2 })
      h.tm:flush()
      t.eq(noteByPitch(h.fm:dump().notes, 60).endppq, 540,
        'clipped back to the inserted same-pitch onset inside the margin')
    end,
  },

}
