-- eventShiftLeft / eventShiftRight -- horizontal move of the cursor
-- event (or an n-row x 1-col selection block) to an adjacent column.
-- Notes step to the next/prev lane that exists, else cross channel
-- (right -> lane 1, left -> the channel's highest lane). Other event
-- types just step channel. All-or-nothing: refuse off the grid edge or
-- onto an occupied destination cell.

local t = require('support')

local function findCol(h, pred)
  for i, col in ipairs(h.vm.grid.cols) do
    if pred(col) then return i, col end
  end
end

local function noteCol(h, chan, lane)
  return findCol(h, function(c)
    return c.type == 'note' and c.midiChan == chan and (c.lane or 1) == lane
  end)
end

local function notesByChanLane(h)
  local out = {}
  for _, n in ipairs(h.fm:dump().notes) do
    out[n.pitch] = { chan = n.chan, lane = n.lane }
  end
  return out
end

local function noteByPitch(h, pitch)
  for _, n in ipairs(h.fm:dump().notes) do
    if n.pitch == pitch then return n end
  end
end

return {

  {
    name = 'note shifts right to the next lane that exists in the channel',
    run = function(harness)
      -- A lane-2 note (row 8) makes chan-1 lane-2 exist but leaves
      -- rows 0..2 free, so the lane-1 note can land there.
      local h = harness.mk{ seed = { notes = {
        { ppq = 0,   endppq = 60,  chan = 1, pitch = 60, vel = 100, lane = 1 },
        { ppq = 480, endppq = 540, chan = 1, pitch = 67, vel = 100, lane = 2 },
      }}}
      h.vm:setGridSize(80, 40)

      h.ec:setPos(0, noteCol(h, 1, 1), 1)
      h.cmgr:invoke('eventShiftRight')

      local by = notesByChanLane(h)
      t.eq(by[60].chan, 1, '60 stays in channel 1')
      t.eq(by[60].lane, 2, '60 moved to lane 2')
      t.eq(by[67].lane, 2, '67 still in lane 2')
    end,
  },

  {
    name = 'note with no further lane crosses to the next channel, lane 1',
    run = function(harness)
      local h = harness.mk{ seed = { notes = {
        { ppq = 0, endppq = 60, chan = 1, pitch = 60, vel = 100, lane = 1 },
      }}}
      h.vm:setGridSize(80, 40)

      h.ec:setPos(0, noteCol(h, 1, 1), 1)
      h.cmgr:invoke('eventShiftRight')

      local by = notesByChanLane(h)
      t.eq(by[60].chan, 2, 'crossed to channel 2')
      t.eq(by[60].lane, 1, 'landed on lane 1')
    end,
  },

  {
    name = 'left is the inverse of right across a channel boundary',
    run = function(harness)
      local h = harness.mk{ seed = { notes = {
        { ppq = 0, endppq = 60, chan = 2, pitch = 60, vel = 100, lane = 1 },
      }}}
      h.vm:setGridSize(80, 40)

      h.ec:setPos(0, noteCol(h, 2, 1), 1)
      h.cmgr:invoke('eventShiftLeft')

      local by = notesByChanLane(h)
      t.eq(by[60].chan, 1, 'crossed back to channel 1')
      t.eq(by[60].lane, 1, 'highest existing lane of channel 1 (only lane 1)')
    end,
  },

  {
    name = 'refuses the move when the destination cell is occupied',
    run = function(harness)
      -- chan-1 60 would cross to chan-2 lane-1, but chan-2 already has
      -- an overlapping note at row 0.
      local h = harness.mk{ seed = { notes = {
        { ppq = 0, endppq = 60, chan = 1, pitch = 60, vel = 100, lane = 1 },
        { ppq = 0, endppq = 60, chan = 2, pitch = 62, vel = 100, lane = 1 },
      }}}
      h.vm:setGridSize(80, 40)

      h.ec:setPos(0, noteCol(h, 1, 1), 1)
      h.cmgr:invoke('eventShiftRight')

      local by = notesByChanLane(h)
      t.eq(by[60].chan, 1, '60 did not move -- destination blocked')
      t.eq(by[62].chan, 2, '62 untouched')
    end,
  },

  {
    name = 'refuses to move off the right edge of the grid',
    run = function(harness)
      local h = harness.mk{ seed = { notes = {
        { ppq = 0, endppq = 60, chan = 16, pitch = 60, vel = 100, lane = 1 },
      }}}
      h.vm:setGridSize(80, 40)

      h.ec:setPos(0, noteCol(h, 16, 1), 1)
      h.cmgr:invoke('eventShiftRight')

      t.eq(notesByChanLane(h)[60].chan, 16, 'still in channel 16')
    end,
  },

  {
    name = 'an n-row x 1-col selection moves as a block and the selection follows',
    run = function(harness)
      local h = harness.mk{ seed = { notes = {
        { ppq = 0,   endppq = 60,  chan = 1, pitch = 60, vel = 100, lane = 1 },
        { ppq = 60,  endppq = 120, chan = 1, pitch = 62, vel = 100, lane = 1 },
        { ppq = 120, endppq = 180, chan = 1, pitch = 64, vel = 100, lane = 1 },
      }}}
      h.vm:setGridSize(80, 40)

      local lane1 = noteCol(h, 1, 1)
      h.ec:setSelection{ row1 = 0, row2 = 2, col1 = lane1, col2 = lane1,
                         part1 = 'pitch', part2 = 'pitch' }
      h.cmgr:invoke('eventShiftRight')

      local by = notesByChanLane(h)
      for _, p in ipairs{ 60, 62, 64 } do
        t.eq(by[p].chan, 2, p .. ' crossed to channel 2')
        t.eq(by[p].lane, 1, p .. ' on lane 1')
      end

      local destCol = noteCol(h, 2, 1)
      local _, _, c1, c2 = h.ec:region()
      t.eq(c1, destCol, 'selection followed to the destination column')
      t.eq(c2, destCol, 'selection still single-column')
      t.eq(h.ec:col(), destCol, 'cursor followed into the destination column')
    end,
  },

  {
    name = 'a multi-column selection is a no-op',
    run = function(harness)
      local h = harness.mk{ seed = { notes = {
        { ppq = 0, endppq = 60, chan = 1, pitch = 60, vel = 100, lane = 1 },
        { ppq = 0, endppq = 60, chan = 1, pitch = 67, vel = 100, lane = 2 },
      }}}
      h.vm:setGridSize(80, 40)

      local lane1 = noteCol(h, 1, 1)
      local lane2 = noteCol(h, 1, 2)
      h.ec:setSelection{ row1 = 0, row2 = 0, col1 = lane1, col2 = lane2,
                         part1 = 'pitch', part2 = 'pitch' }
      h.cmgr:invoke('eventShiftRight')

      local by = notesByChanLane(h)
      t.eq(by[60].chan, 1, '60 unmoved')
      t.eq(by[67].chan, 1, '67 unmoved')
    end,
  },

  {
    name = 'a non-note event just steps to the next channel',
    run = function(harness)
      local h = harness.mk{ seed = { ccs = {
        { ppq = 0, chan = 1, cc = 11, val = 64, evType = 'cc' },
      }}}
      h.vm:setGridSize(80, 40)

      local ci = findCol(h, function(c) return c.type == 'cc' and c.midiChan == 1 end)
      h.ec:setPos(0, ci, 1)
      h.cmgr:invoke('eventShiftRight')

      local moved
      for _, c in ipairs(h.fm:dump().ccs) do
        if c.evType == 'cc' and c.cc == 11 then moved = c end
      end
      t.truthy(moved, 'cc 11 still exists')
      t.eq(moved.chan, 2, 'cc 11 stepped to channel 2')
    end,
  },

  {
    name = "a moved note's tail is truncated, not blocked, by a later destination note",
    run = function(harness)
      -- 60 spans rows 0..2 (ppq 0..180). Dest chan-2 has a note-on at
      -- row 2 (ppq 120) -- outside 60's onset row (0), so the move is
      -- allowed and 60's tail is clipped on rebuild.
      local h = harness.mk{ seed = { notes = {
        { ppq = 0,   endppq = 180, chan = 1, pitch = 60, vel = 100, lane = 1 },
        { ppq = 120, endppq = 180, chan = 2, pitch = 64, vel = 100, lane = 1 },
      }}}
      h.vm:setGridSize(80, 40)

      h.ec:setPos(0, noteCol(h, 1, 1), 1)
      h.cmgr:invoke('eventShiftRight')

      local moved = noteByPitch(h, 60)
      t.eq(moved.chan, 2, '60 crossed to channel 2 (not blocked by the row-2 note)')
      t.truthy(moved.endppq < 180, '60 tail was truncated')
      t.truthy(moved.endppq <= 120, '60 tail clipped at/before the row-2 note-on')
    end,
  },

  {
    name = "a clipped note keeps its full intent ceiling when shifted (clip must not clobber endppqL)",
    run = function(harness)
      -- 60 is an authored note intending a long tail (endppqL 960) but
      -- a same-lane blocker at ppq 480 clips its REALISED note-off in
      -- chan 1. Shifting 60 to empty chan 2 must carry the 960 INTENT,
      -- not the 480 clip: with nothing blocking there it must realise
      -- its full length. The bug is shiftEvents cloning the clipped
      -- column endppq and addEvent stamping it as endppqL, permanently
      -- destroying the intent.
      local h = harness.mk{ seed = { length = 3840, notes = {
        { ppq = 0,   endppq = 960, ppqL = 0,   endppqL = 960,
          chan = 1, pitch = 60, vel = 100, lane = 1, uuid = 1 },
        { ppq = 480, endppq = 600, ppqL = 480, endppqL = 600,
          chan = 1, pitch = 62, vel = 100, lane = 1, uuid = 2 },
      }}}
      h.vm:setGridSize(80, 40)
      t.truthy(noteByPitch(h, 60).endppq <= 480,
               '60 clipped by the same-lane blocker in chan 1')

      h.ec:setPos(0, noteCol(h, 1, 1), 1)
      h.cmgr:invoke('eventShiftRight')   -- 60 -> empty chan 2, lane 1

      local moved = noteByPitch(h, 60)
      t.eq(moved.chan, 2, '60 crossed to channel 2')
      t.eq(moved.endppq, 960,
           'full intent ceiling survived the shift; realises unclipped in the empty channel')
    end,
  },

  {
    name = "refuses when a dest onset sits on a selected-but-empty row",
    run = function(harness)
      -- Selection spans rows 0..6 but only rows 1 and 3 hold notes.
      -- Dest chan-2 has a note-on at row 5 -- a selected row with no
      -- moving note. The old moving-onset band [1,3] missed it; the
      -- selection-extent rule [0,6] must refuse so a repeated shift
      -- can't accumulate overlaps.
      local h = harness.mk{ seed = { notes = {
        { ppq = 60,  endppq = 120, chan = 1, pitch = 60, vel = 100, lane = 1 },
        { ppq = 180, endppq = 240, chan = 1, pitch = 64, vel = 100, lane = 1 },
        { ppq = 300, endppq = 360, chan = 2, pitch = 67, vel = 100, lane = 1 },
      }}}
      h.vm:setGridSize(80, 40)

      local lane1 = noteCol(h, 1, 1)
      h.ec:setSelection{ row1 = 0, row2 = 6, col1 = lane1, col2 = lane1,
                         part1 = 'pitch', part2 = 'pitch' }
      h.cmgr:invoke('eventShiftRight')

      local by = notesByChanLane(h)
      t.eq(by[60].chan, 1, '60 did not move -- dest onset on a selected row')
      t.eq(by[64].chan, 1, '64 did not move')
      t.eq(by[67].chan, 2, '67 (the blocker) untouched')
    end,
  },

  {
    name = "a moving note truncates the tail of an earlier destination note",
    run = function(harness)
      -- Dest chan-2 64 starts at row 0 and sustains to row 4 (ppq 240).
      -- Incoming 60's onset is row 2 (ppq 120) -- outside 64's onset
      -- row, so allowed; 64's tail is clipped back to 60's onset.
      local h = harness.mk{ seed = { notes = {
        { ppq = 120, endppq = 180, chan = 1, pitch = 60, vel = 100, lane = 1 },
        { ppq = 0,   endppq = 240, chan = 2, pitch = 64, vel = 100, lane = 1 },
      }}}
      h.vm:setGridSize(80, 40)

      h.ec:setPos(2, noteCol(h, 1, 1), 1)
      h.cmgr:invoke('eventShiftRight')

      t.eq(noteByPitch(h, 60).chan, 2, '60 crossed to channel 2')
      local victim = noteByPitch(h, 64)
      t.truthy(victim.endppq < 240, "64's tail was truncated")
      t.truthy(victim.endppq <= 120, "64's tail clipped at/before 60's onset")
    end,
  },

}
