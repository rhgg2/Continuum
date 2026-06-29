-- Repro: mirrorDuplicate (stamp) must COMMIT its projection before the
-- next user edit. The command flushes after gm:stamp (duplicateDown
-- commits the same way, via pasteClip's flush). Skipping that flush left
-- the sibling add staged in tm until the next edit's flush, where it
-- collided with the origin edit's reproject: the sibling materialised
-- with the OLD value and its proj record went stale, so further edits
-- had no effect ("empty boxes -> fills with A -> no effect").
--
-- This pins the gm + real-tm seam the command drives. It cannot invoke
-- trackerPage's command closure (trackerPage builds its own tm, not the
-- harness's), so it models the fixed command's sequence:
--   stamp -> tm:flush (commit) -> edit -> tm:flush -> edit -> tm:flush
-- and asserts the sibling tracks every origin edit in place.

local t    = require('support')
local util = require('util')

local function noteCol(h, chan)
  for i, col in ipairs(h.vm.grid.cols) do
    if col.type == 'note' and col.midiChan == chan then return i, col end
  end
end

local function chanNotes(h, chan)
  local out = {}
  for _, ev in ipairs(h.tm:getChannel(chan).columns.notes[1].events) do
    if ev.evType ~= 'pa' then
      out[#out + 1] = { ppq = ev.ppq, pitch = ev.pitch, evt = ev }
    end
  end
  return out
end

local function originEvt(h, chan)
  for _, n in ipairs(chanNotes(h, chan)) do
    if n.ppq == 0 then return n.evt end
  end
end

return {
  {
    name = 'a committed stamp tracks repeated origin edits in place (no stale dupe)',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 },
        } },
      }
      local gm = util.instantiate('groupManager', { tm = h.tm, ds = h.ds })

      local ci = noteCol(h, 1)
      h.ec:setSelection{ row1 = 0, row2 = 0, col1 = ci, col2 = ci,
                         part1 = 'pitch', part2 = 'pitch' }
      local rect   = h.vm:selectionAsRect()
      local events = h.vm:eventsInRect(rect)
      t.eq(#events, 1, 'one source event')

      -- mirrorDuplicate body: stamp the copy after the source region,
      -- then commit it (the fix). Anchor = region end, like the command.
      gm:stamp(events, rect, { ppq = rect.ppq + rect.dur, chan = 1 })
      h.tm:flush()

      local committed = chanNotes(h, 1)
      t.eq(#committed, 2, 'the projected copy is committed, not left staged')
      for _, n in ipairs(committed) do
        t.eq(n.pitch, 60, 'both origin and sibling start at pitch 60')
      end

      -- First origin edit: 60 -> 72. Sibling must follow in place.
      gm:assignEvent(originEvt(h, 1).uuid, { pitch = 72 })
      h.tm:flush()
      local after1 = chanNotes(h, 1)
      t.eq(#after1, 2, 'still exactly two notes after the first edit')
      for _, n in ipairs(after1) do
        t.eq(n.pitch, 72, 'origin and sibling both read 72')
      end

      -- Second origin edit: 72 -> 80. Guards the "further edits have no
      -- effect" tail of the bug (stale sibling proj record).
      gm:assignEvent(originEvt(h, 1).uuid, { pitch = 80 })
      h.tm:flush()
      local after2 = chanNotes(h, 1)
      t.eq(#after2, 2, 'still exactly two notes after the second edit')
      for _, n in ipairs(after2) do
        t.eq(n.pitch, 80, 'sibling still live: tracks the second edit too')
      end
    end,
  },
}
