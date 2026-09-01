-- A take-length change re-resolves the swing composite, so it is a swing change.
-- The composite's ramps run to the take's end (docs/timing.md § Boundary clip), so
-- moving that end moves every raw seat near it. The rebuild rule reads a raw/logical
-- disagreement on a channel that is not swing-stale as an external raw edit and lets
-- ppqL follow raw (docs/timing.md § Rebuild rule), so a resize that failed to mark the
-- channels stale would rewrite authored logical onsets from stale realisations.
--
-- Real tm, real cm, one channel. The swing is deliberately steep (a fifth of a tile) so
-- the displacement clears the 1 ppq tolerance the rebuild rule allows.

local t = require('support')

-- classic, shift 0.2 over a 1 QN tile: at 240 ppq/QN the peak displacement is 48 ppq.
local steep = { factors = { { atom = 'classic', shift = 0.2, period = 1 } } }

-- 1900 is not a tile boundary, so its ramp-off catches onsets the old composite carried
-- past it; a boundary target would clip to the same place under either length.
local NEW_END = 1900

local function noteByPitch(notes, pitch)
  for _, n in ipairs(notes) do if n.pitch == pitch then return n end end
end

-- One note just inside the shrink target, authored on its logical onset. 60 ppq of tail so
-- the note straddles the new end and the shrink clamps rather than kills it.
local function seeded(harness)
  return harness.mk{
    seed = { length = 3840, resolution = 240, notes = {
      { ppq = 1899, endppq = 1959, ppqL = 1899, endppqL = 1959,
        chan = 1, pitch = 60, vel = 100, lane = 1, uuid = 1 },
    } },
    config = { project = { swings = { steep = steep } } },
  }
end

return {
  {
    name = 'a shrink under swing keeps the authored logical onset and reseats raw inside the new end',
    run = function(harness)
      local h = seeded(harness)
      -- Swing on through the production path: dataChanged marks all 16 stale and the reseat
      -- carries the note's realisation off its logical onset.
      h.ds:assign('swing', { global = 'steep' })

      local before = noteByPitch(h.fm:dump().notes, 60)
      t.eq(before.ppqL, 1899, 'precondition: the authored logical onset stands under the reseat')
      t.truthy(before.ppq > NEW_END,
        'precondition: the old composite seats the note past the shrink target')

      h.tm:setLength(NEW_END)

      local after = noteByPitch(h.fm:dump().notes, 60)
      t.eq(after.ppqL, 1899, 'the resize leaves the authored logical onset where it was')
      t.truthy(after.ppq <= NEW_END,
        'the raw seat re-derives under the new length, inside the new take end')
    end,
  },

  {
    name = 'the shrink flush projects under the pending end',
    run = function(harness)
      -- mm's resize runs last, so the flush's rebuild sees a take that still runs to the old end
      -- while deriving against the new one. The pass reads its projection off the pending end,
      -- which is the only moment the two lengths differ; the rebuild signal samples it.
      local h = seeded(harness)
      h.ds:assign('swing', { global = 'steep' })

      local pending
      h.tm:subscribe('rebuild', function()
        if h.tm:length() == NEW_END and h.fm:length() > NEW_END then
          pending = h.tm:fromLogical(1, 1899)
        end
      end)

      h.tm:setLength(NEW_END)

      t.truthy(pending, 'precondition: a rebuild ran while the resize was still pending')
      t.truthy(pending <= NEW_END,
        'the pass projects through the composite resolved over the pending end')
    end,
  },

  {
    name = 'the same shrink under identity swing moves nothing',
    run = function(harness)
      -- The swing is what makes the case above bite: with the frames equal there is no
      -- displacement to re-derive, and the note keeps both seats across the resize.
      local h = seeded(harness)
      h.tm:rebuild()

      h.tm:setLength(NEW_END)

      local after = noteByPitch(h.fm:dump().notes, 60)
      t.eq(after.ppqL, 1899, 'logical onset untouched')
      t.eq(after.ppq, 1899, 'raw seat untouched')
    end,
  },
}
