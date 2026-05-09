-- When a flush we just made produces an over-threshold lane overlap on
-- the requested lane, lane allocation must keep the overlap (not bump
-- the note silently to a sibling lane) and emit a console warning.
-- "Silent bump" can only mean external mutation or a bug in our edit
-- path; surfacing the bug case is what this spec pins.

local t = require('support')

return {
  {
    name = 'over-threshold overlap from our own flush: kept in lane, warning logged',
    run = function(harness)
      -- Two notes on chan 1, lane 1, different pitches, no overlap.
      -- overlapOffset default 1/16 × 240 ppq = 15 ppq lenient threshold.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0,   endppq = 100, ppqL = 0,   endppqL = 100,
              chan = 1, pitch = 60, vel = 100, lane = 1, uuid = 101 },
            { ppq = 200, endppq = 400, ppqL = 200, endppqL = 400,
              chan = 1, pitch = 62, vel = 100, lane = 1, uuid = 102 },
          },
        },
      }

      -- Capture warnings from util.print without losing the original
      -- (other code paths may emit unrelated messages we don't care about).
      local warned = {}
      local origPrint = util.print
      util.print = function(...)
        local s = table.concat({...}, '\t')
        warned[#warned + 1] = s
      end

      -- Extend the pitch-60 note to 350: now overlaps the pitch-62 note
      -- by 150 ppq, far above the 15-ppq lenient threshold.
      local col = h.tm:getChannel(1).columns.notes[1]
      local first
      for _, e in ipairs(col.events) do
        if e.pitch == 60 then first = e end
      end
      t.truthy(first, 'pitch-60 note present pre-flush')

      h.tm:assignEvent('note', first, { endppq = 350 })
      h.tm:flush()

      util.print = origPrint

      -- Both notes still in lane 1: the bump was suppressed.
      local notes = h.fm:dump().notes
      local byPitch = {}
      for _, n in ipairs(notes) do byPitch[n.pitch] = n end
      t.eq(byPitch[60].lane, 1, 'extended note kept in requested lane 1')
      t.eq(byPitch[62].lane, 1, 'sibling not bumped to lane 2')

      -- The overlap is visible in the rebuilt column.
      local laneOne = h.tm:getChannel(1).columns.notes[1].events
      local seen60, seen62 = false, false
      for _, e in ipairs(laneOne) do
        if e.pitch == 60 then seen60 = true end
        if e.pitch == 62 then seen62 = true end
      end
      t.truthy(seen60 and seen62, 'both notes co-resident in lane 1')

      -- A warning was surfaced naming the chan/lane and both pitches.
      local hit
      for _, s in ipairs(warned) do
        if s:find('lane overlap kept', 1, true) then hit = s end
      end
      t.truthy(hit, 'lane-overlap warning emitted: ' .. tostring(#warned) .. ' message(s)')
      t.truthy(hit and hit:find('chan=1') and hit:find('lane=1'),
               'warning names chan/lane')
      t.truthy(hit and hit:find('pitch=60') and hit:find('pitch=62'),
               'warning names both pitches')
    end,
  },

  {
    name = 'overlap untraceable to our flush: bump still happens (no warning)',
    run = function(harness)
      -- Same geometry as above, but seeded already-overlapping. No flush
      -- has touched these notes — pendingFlushUuids is nil at the
      -- harness's initial rebuild, so attribution fails and the
      -- allocator falls through to its existing bump behaviour.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0,   endppq = 350, ppqL = 0,   endppqL = 350,
              chan = 1, pitch = 60, vel = 100, lane = 1, uuid = 201 },
            { ppq = 200, endppq = 400, ppqL = 200, endppqL = 400,
              chan = 1, pitch = 62, vel = 100, lane = 1, uuid = 202 },
          },
        },
      }

      local notes = h.fm:dump().notes
      local byPitch = {}
      for _, n in ipairs(notes) do byPitch[n.pitch] = n end
      t.eq(byPitch[60].lane, 1, 'first note stays in lane 1')
      t.eq(byPitch[62].lane, 2, 'sibling bumped to lane 2 (no attribution)')
    end,
  },
}
