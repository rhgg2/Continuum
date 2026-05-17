-- tv:selectionAsRect / tv:eventsInRect -- the trackerView -> mirror bridge.
-- A selection rectangle becomes a mirror `rect` (logical time span x
-- per-channel streamId set, chanOffset relative to the lowest selected
-- channel). eventsInRect resolves that rect back to the concrete events it
-- contains. streamId is index-free (evType:key), so it survives column
-- reorder -- the column IS the stream.

local t = require('support')

local function noteCol(h, chan)
  for i, col in ipairs(h.vm.grid.cols) do
    if col.type == 'note' and col.midiChan == chan then return i, col end
  end
end

return {
  {
    name = 'single note-col selection -> exact rect shape (logical frame, note:1 stream)',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } } },
      }
      local ci = noteCol(h, 1)
      h.ec:setSelection{ row1 = 0, row2 = 0, col1 = ci, col2 = ci,
                         part1 = 'pitch', part2 = 'pitch' }

      local rect = h.vm:selectionAsRect()
      t.truthy(rect, 'a real selection yields a rect')
      t.eq(rect.ppq, 0)
      t.eq(rect.dur, 60, 'one row = logPerRow (240/4) logical ppq')
      t.eq(rect.chanLo, 1)
      t.deepEq(rect.streams, { [0] = { ['note:1'] = true } })
    end,
  },

  {
    name = 'multi-channel selection -> chanLo is the lowest, offsets relative to it',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq = 0, endppq = 240, chan = 2, pitch = 60, vel = 100 },
          { ppq = 0, endppq = 240, chan = 4, pitch = 64, vel = 100 },
        } },
      }
      local c2 = noteCol(h, 2)
      local c4 = noteCol(h, 4)
      h.ec:setSelection{ row1 = 0, row2 = 3, col1 = c2, col2 = c4,
                         part1 = 'pitch', part2 = 'pitch' }

      local rect = h.vm:selectionAsRect()
      t.eq(rect.chanLo, 2, 'lowest selected channel anchors the rect')
      t.eq(rect.dur, 240, 'four rows of 60')
      t.truthy(rect.streams[0]['note:1'], 'chan 2 -> offset 0')
      t.truthy(rect.streams[1]['note:1'], 'chan 3 -> offset 1')
      t.truthy(rect.streams[2]['note:1'], 'chan 4 -> offset 2')
    end,
  },

  {
    name = 'eventsInRect returns concrete events inside, excludes out-of-time and unselected streams',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq = 0,   endppq = 240, chan = 1, pitch = 60, vel = 100 }, -- in
          { ppq = 480, endppq = 720, chan = 1, pitch = 67, vel = 100 }, -- out of time
          { ppq = 0,   endppq = 240, chan = 2, pitch = 64, vel = 100 }, -- unselected chan
        } },
      }
      local ci = noteCol(h, 1)
      h.ec:setSelection{ row1 = 0, row2 = 3, col1 = ci, col2 = ci,
                         part1 = 'pitch', part2 = 'pitch' }

      local rect = h.vm:selectionAsRect()
      local got = h.vm:eventsInRect(rect)
      t.eq(#got, 1, 'only the in-time event on the selected stream')
      t.eq(got[1].ppq, 0)
      t.eq(got[1].pitch, 60)
    end,
  },

  {
    name = 'no selection -> nil',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } } },
      }
      t.eq(h.vm:selectionAsRect(), nil)
    end,
  },
}
