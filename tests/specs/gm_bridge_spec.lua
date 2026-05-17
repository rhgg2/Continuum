-- Repro: the live tv -> gm bridge. selectionAsRect + eventsInRect feed
-- gm:mark / gm:stamp with REAL trackerView column events (not the
-- hand-built {chan=1,...} the gm unit specs use). Pins the seam that
-- crashed in REAPER ("arithmetic on nil field 'chan'").

local t    = require('support')
local util = require('util')

local function noteCol(h, chan)
  for i, col in ipairs(h.vm.grid.cols) do
    if col.type == 'note' and col.midiChan == chan then return i, col end
  end
end

return {
  {
    name = 'gm:mark accepts real eventsInRect output (chan present on tv col events)',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 },
        } },
      }
      local ci = noteCol(h, 1)
      h.ec:setSelection{ row1 = 0, row2 = 3, col1 = ci, col2 = ci,
                         part1 = 'pitch', part2 = 'pitch' }

      local rect   = h.vm:selectionAsRect()
      local events = h.vm:eventsInRect(rect)
      t.eq(#events, 1, 'one event in the rect')
      t.truthy(events[1].chan, 'tv col event carries chan')

      local gm = util.instantiate('groupManager', { tm = h.tm, cm = h.cm })
      local gid  = gm:mark(events, rect)
      t.truthy(gid, 'mark returned a group id')
    end,
  },
  {
    name = 'gm:stamp (mirrorDuplicate path) accepts real rect + cursor anchor',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 },
        } },
      }
      local ci = noteCol(h, 1)
      h.ec:setSelection{ row1 = 0, row2 = 3, col1 = ci, col2 = ci,
                         part1 = 'pitch', part2 = 'pitch' }
      local rect   = h.vm:selectionAsRect()
      local events = h.vm:eventsInRect(rect)

      h.ec:setPos(8, ci, 1)            -- cursor below the selection
      local anchor = h.vm:cursorAnchor()
      t.truthy(anchor and anchor.chan, 'cursor anchor carries chan')

      local gm = util.instantiate('groupManager', { tm = h.tm, cm = h.cm })
      local gid, iid = gm:stamp(events, rect, anchor)
      t.truthy(gid and iid, 'stamp seeded a group and an instance')
    end,
  },
}
