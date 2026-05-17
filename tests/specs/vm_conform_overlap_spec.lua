-- vm overlap-geometry carve-out for conform notes. A conform note's
-- STORED tail (endppqL) is an intended overrun: tm owns the realised
-- clip, so vm must (a) not let a conform predecessor's long tail
-- constrain a sibling edit (neighbourEvents/rowBounds), and (b) not
-- shorten a conform note's own planned tail in conformOverlaps.
--
-- Harness identity swing: ppq == ppqL. resolution 240, rpb 4 ->
-- 60 ppq/row. overlapOffset default 1/16 -> lenient 15 ppq.

local t = require('support')

local function byPitch(notes, p)
  for _, n in ipairs(notes) do if n.pitch == p then return n end end
end

return {

  {
    name = 'conform predecessor does not block nudging a later same-col note back',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq = 0,   endppq = 960,  ppqL = 0,   endppqL = 960,
            chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0,
            lane = 1, conform = true },
          { ppq = 960, endppq = 1080, ppqL = 960, endppqL = 1080,
            chan = 1, pitch = 62, vel = 100, detune = 0, delay = 0, lane = 1 },
        } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(16, 1, 1)            -- B's onset row (960 / 60)
      h.cmgr:invoke('nudgeBack')

      local b = byPitch(h.fm:dump().notes, 62)
      t.eq(b.ppq, 900, 'B nudged back a row — conform tail did not raise minRow')
      local a = byPitch(h.fm:dump().notes, 60)
      t.eq(a.endppqL, 960, 'conform stored tail untouched by the sibling edit')
    end,
  },

  {
    name = 'control: a NON-conform predecessor with the same geometry DOES block',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq = 0,   endppq = 960,  ppqL = 0,   endppqL = 960,
            chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0, lane = 1 },
          { ppq = 960, endppq = 1080, ppqL = 960, endppqL = 1080,
            chan = 1, pitch = 62, vel = 100, detune = 0, delay = 0, lane = 1 },
        } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(16, 1, 1)
      h.cmgr:invoke('nudgeBack')

      local b = byPitch(h.fm:dump().notes, 62)
      t.eq(b.ppq, 960, 'non-conform predecessor still clamps the nudge (carve-out is gated)')
    end,
  },

  {
    name = 'conformOverlaps does not shorten a conform note stored tail when it shifts',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq = 60,  endppq = 600, ppqL = 60,  endppqL = 600,
            chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0,
            lane = 1, conform = true },
          { ppq = 120, endppq = 180, ppqL = 120, endppqL = 180,
            chan = 1, pitch = 62, vel = 100, detune = 0, delay = 0, lane = 1 },
        } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(0, 1, 1)
      h.cmgr:invoke('insertRow')       -- shifts A and B forward by a row

      local a = byPitch(h.fm:dump().notes, 60)
      t.eq(a.endppqL, 660, 'conform tail shifted but NOT clipped by conformOverlaps')
      local b = byPitch(h.fm:dump().notes, 62)
      t.eq(b.ppq, 180, 'B shifted forward a row')
      -- tm still realises a short raw note-off (B now blocks at 180).
      t.eq(a.endppq, 180, 'raw note-off remains the realised clip')
    end,
  },
}
