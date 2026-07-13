-- Pins the tail-clip gate (design/dirty-channels.md § Scheme) against its two dirt sources:
-- swing reseat and take-length resize. See docs/trackerManager.md § Derivation dirt, § Length operations.

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

  {
    name = 'external take-length grow re-derives tails on channels with no edits',
    run = function(harness)
      -- Two OPEN tails, one per channel, both filling the take. mm:setLength is called direct,
      -- so tm learns of the resize the only way an arrange-side drag lets it: a wholesale reload.
      local h = harness.mk{
        seed = { length = 3840, notes = {
          { ppq = 0, endppq = 3840, ppqL = 0, endppqL = util.OPEN,
            chan = 1, pitch = 60, vel = 100, lane = 1, uuid = 1 },
          { ppq = 0, endppq = 3840, ppqL = 0, endppqL = util.OPEN,
            chan = 2, pitch = 64, vel = 100, lane = 1, uuid = 2 },
        } },
      }
      h.tm:rebuild()   -- consume the seed's dirt: every channel is now clean, so the gate is armed

      h.fm:setLength(32)   -- 32 QN = 7680 ppq

      t.eq(h.fm:length(), 7680, 'take grew')
      local notes = h.fm:dump().notes
      t.eq(noteByPitch(notes, 60).endppq, 7680, 'chan 1 tail regrew to the new take end')
      t.eq(noteByPitch(notes, 64).endppq, 7680, 'chan 2 tail regrew to the new take end')
    end,
  },

  {
    name = 'setLength shrink clips an OPEN tail without concreting its endppqL',
    run = function(harness)
      local h = harness.mk{
        seed = { length = 3840, notes = {
          { ppq = 0, endppq = 3840, ppqL = 0, endppqL = util.OPEN,
            chan = 1, pitch = 60, vel = 100, lane = 1, uuid = 1 },
        } },
      }
      t.eq(noteByPitch(h.fm:dump().notes, 60).endppq, 3840, 'open tail fills the take')

      h.tm:setLength(1920)

      t.eq(h.fm:length(), 1920, 'take shrank')
      local clipped = noteByPitch(h.fm:dump().notes, 60)
      t.eq(clipped.endppq,  1920,      'realised tail clipped to the new end')
      t.eq(clipped.endppqL, util.OPEN, 'authored OPEN ceiling survives the shrink')

      -- The whole point of preserving the sentinel: a re-grow reopens the tail.
      h.tm:setLength(3840)
      t.eq(noteByPitch(h.fm:dump().notes, 60).endppq, 3840, 'tail regrows to the restored end')
    end,
  },
}
