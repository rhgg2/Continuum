-- localMode read-only guard: with the caret over bare grid (no instance under it),
-- the leaf-edit facade refuses mutations, so a real nudge command is a no-op. With
-- localMode off the same command applies -- proving it is the guard, not the wiring.
-- Full-stack: real tm/mm/gm/tv driven by the nudge command, as the user would.

local t = require('support')

local function noteCol(h, chan)
  for i, col in ipairs(h.vm.grid.cols) do
    if col.type == 'note' and col.midiChan == chan then return i, col end
  end
end

local function rowOfPpq(col, ppq)
  for row, evt in pairs(col.cells) do
    if evt.ppq == ppq then return row end
  end
end

local function pitchByPpq(h)
  local out = {}
  for _, n in h.fm:notes() do
    if n.evType ~= 'pa' then out[n.ppq] = n.pitch end
  end
  return out
end

-- Origin note at ppq 0 marked as a group with a sibling instance at 960; a plain
-- note at 1920 sits outside every instance. Returns h, the note col index, and the
-- plain note's grid row.
local function setup(harness)
  local h = harness.mk{
    groups = true,
    seed   = { notes = {
      { ppq = 0,    endppq = 240,  chan = 1, pitch = 60, vel = 100 },
      { ppq = 1920, endppq = 2160, chan = 1, pitch = 72, vel = 100 },
    } },
  }
  local ci = noteCol(h, 1)
  h.ec:setSelection{ row1 = 0, row2 = 0, col1 = ci, col2 = ci, part1 = 'pitch', part2 = 'pitch' }
  local rect = h.vm:selectionAsRect()
  local gid  = h.gm:markGroup(h.vm:eventsInRect(rect), rect)
  h.gm:newInstance(gid, { ppq = 960, chan = 1 })
  h.tm:flush()

  local _, col = noteCol(h, 1)
  return h, ci, rowOfPpq(col, 1920)
end

local function selectPlain(h, ci, row)
  h.ec:setSelection{ row1 = row, row2 = row, col1 = ci, col2 = ci, part1 = 'pitch', part2 = 'pitch' }
end

return {
  {
    name = 'localMode blocks an edit whose caret is over bare grid (no active instance)',
    run = function(harness)
      local h, ci, plainRow = setup(harness)
      selectPlain(h, ci, plainRow)
      h.gm:setLocalMode(true)
      h.cmgr:invoke('nudgeFineUp')
      h.gm:setLocalMode(false)

      t.eq(pitchByPpq(h)[1920], 72, 'plain note untouched -- the guard refused the edit')
    end,
  },
  {
    name = 'with localMode off the same edit applies (proves it is the guard)',
    run = function(harness)
      local h, ci, plainRow = setup(harness)
      selectPlain(h, ci, plainRow)
      h.cmgr:invoke('nudgeFineUp')

      t.eq(pitchByPpq(h)[1920], 73, 'plain note transposed -- editable when not in localMode')
    end,
  },
}
