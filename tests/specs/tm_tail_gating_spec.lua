-- Phase A of the dirt spine (design/dirty-channels.md § Scheme): the tail walk's clip/nudge
-- is gated per dirty channel. An open note clips its raw tail to the next same-lane onset,
-- realised under swing -- so a swing change must reseat that clip. Swing dirt is config, not
-- carried by the mm reload payload; markSwingStale feeds the spine (A1), and the tail gate must
-- honour it or the clipped tail wrongly keeps its old seat. This pins that on the tail path.

local t    = require('support')
local util = require('util')

local classic58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }

local function noteByPitch(notes, pitch)
  for _, n in ipairs(notes) do if n.pitch == pitch then return n end end
end

return {
  {
    name = 'swing change reseats an open tail through the dirtyChans gate',
    run = function(harness)
      -- Open note (pitch 60) clips to the next same-lane onset (blocker at logical 120, a
      -- mid-tile peak at res 240). Both seed internal under identity swing; turning swing on
      -- displaces the blocker (c58: logical 120 -> raw 139), so the open tail must re-clip.
      local h = harness.mk{
        seed = { length = 3840, notes = {
          { ppq = 0,   endppq = 3840, ppqL = 0,   endppqL = util.OPEN,
            chan = 1, pitch = 60, vel = 100, lane = 1, uuid = 1 },
          { ppq = 120, endppq = 200, ppqL = 120, endppqL = 200,
            chan = 1, pitch = 62, vel = 100, lane = 1, uuid = 2 },
        } },
        config = { project = { swings = { c58 = classic58 } } },
      }
      local before = noteByPitch(h.fm:dump().notes, 60).endppq
      t.eq(before, 120, 'open tail clipped to the blocker under identity swing')

      -- Turn swing on: dataChanged -> global nil->c58 -> markSwingStale(nil) -> dirtyChan(nil).
      -- The gate lets chan 1 through, so the blocker reseats and the open tail re-clips to it.
      h.ds:assign('swing', { global = 'c58' })

      local after = noteByPitch(h.fm:dump().notes, 60).endppq
      t.eq(after, util.round(h.tm:fromLogical(1, 120)),
        'open tail re-clipped to the c58 realisation of the blocker')
      t.truthy(after ~= before, 'the reseat actually moved the clip off the identity seat')
    end,
  },
}
