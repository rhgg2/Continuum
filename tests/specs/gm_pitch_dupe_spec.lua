-- Repro: a pitch edit on the origin instance must UPDATE the sibling's
-- note in place, not leave a stale old-pitch note beside a new one.
-- Rides the REAL tm flush seam (gm subscribes to h.tm preflush/postflush).

local t    = require('support')
local util = require('util')

local function noteCol(h, chan)
  for i, col in ipairs(h.vm.grid.cols) do
    if col.type == 'note' and col.midiChan == chan then return i, col end
  end
end

local function chanNotes(h, chan)
  local ch = h.tm:getChannel(chan)
  local out = {}
  for _, ev in ipairs(ch.columns.notes[1].events) do
    if ev.evType ~= 'pa' then
      out[#out + 1] = { ppq = ev.ppq, pitch = ev.pitch }
    end
  end
  return out
end

return {
  {
    name = 'origin pitch edit updates the sibling note in place (no stale dupe)',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 },
        } },
      }
      local gm = util.instantiate('groupManager', { tm = h.tm, cm = h.cm })

      local ci = noteCol(h, 1)
      h.ec:setSelection{ row1 = 0, row2 = 0, col1 = ci, col2 = ci,
                         part1 = 'pitch', part2 = 'pitch' }
      local rect   = h.vm:selectionAsRect()
      local events = h.vm:eventsInRect(rect)
      t.eq(#events, 1, 'one source event')

      local gid = gm:markGroup(events, rect)
      gm:newInstance(gid, { ppq = 960, chan = 1 })
      h.tm:flush()

      local before = chanNotes(h, 1)
      t.eq(#before, 2, 'origin + one sibling copy after newInstance')

      -- Real pitch edit on the origin note (vm path: assignEvent{pitch}).
      h.tm:assignEvent(events[1], { pitch = 72 })
      h.tm:flush()

      local after = chanNotes(h, 1)
      t.eq(#after, 2, 'still exactly two notes (no stale dupe)')
      for _, n in ipairs(after) do
        t.eq(n.pitch, 72, 'both origin and sibling now read pitch 72')
      end
    end,
  },
}
