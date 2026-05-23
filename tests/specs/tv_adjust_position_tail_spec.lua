-- Position-nudge round-trip for note tails. adjustPosition shifts the
-- authored ceiling (endppqL) by the same ppq delta as the onset, so a
-- downward move that pushes endppqL past the take length still regrows
-- the tail when the note moves back up. Routing the end through a row
-- (ctx:ppqToRow clamps to numRows) would erase the overshoot and shrink
-- the tail one row per round-trip.

local t    = require('support')
local util = require('util')

local function noteCol(h, chan)
  for i, c in ipairs(h.vm.grid.cols) do
    if c.type == 'note' and c.midiChan == chan then return i end
  end
end

return {

  {
    name = 'tail regrows after a downward-then-upward nudge that overshot the take end',
    run = function(harness)
      -- Take is 3840 ppq @ 60 ppq/row = 64 rows. Note at rows 55..62.
      -- Forward 3 lands endppqL at row 65 (ppq 3900), 60 past the take.
      -- The raw note-off clips at 3840; the authored ceiling persists.
      -- Back 3 must restore endppq to 3720, not 3660 (one row short).
      local h = harness.mk{ seed = { notes = {
        { ppq = 3300, endppq = 3720, chan = 1, pitch = 60, vel = 100, lane = 1 },
      }}}
      h.vm:setGridSize(80, 64)

      h.ec:setPos(55, noteCol(h, 1), 1)
      for _ = 1, 3 do h.cmgr:invoke('nudgeForward') end
      for _ = 1, 3 do h.cmgr:invoke('nudgeBack')    end

      local n = h.fm:dump().notes[1]
      t.eq(n.ppq,    3300, 'onset returned to its starting ppq')
      t.eq(n.endppq, 3720, 'tail regrew to its original endppq')
    end,
  },

  {
    name = 'a util.OPEN tail stays open across a nudge',
    run = function(harness)
      -- An open note has no finite ceiling. The old row-routed shift
      -- collapsed it to numRows+rowDelta worth of ppq -- silently
      -- closing the note. The ppq-delta shift leaves util.OPEN alone.
      local h = harness.mk{ seed = { notes = {
        { ppq = 600, endppq = 3840, ppqL = 600, endppqL = util.OPEN,
          chan = 1, pitch = 60, vel = 100, lane = 1, uuid = 1 },
      }}}
      h.vm:setGridSize(80, 64)

      h.ec:setPos(10, noteCol(h, 1), 1)
      h.cmgr:invoke('nudgeForward')

      local n = h.fm:dump().notes[1]
      t.eq(n.endppqL, util.OPEN, 'authored ceiling still OPEN after the nudge')
    end,
  },

}
