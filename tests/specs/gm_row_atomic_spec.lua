-- Stage 5: time-topology atomicity (design/group-aware-editing.md decision 4).
-- A row op treats each group instance as a rigid block: an instance wholly past
-- the cut re-anchors as a unit (gm:moveInstance) without touching the shared
-- pattern (which would move the macro in EVERY instance); a cut that strikes an
-- instance's interior refuses the whole op. A column-scoped op that would slice
-- only some of an instance's columns also refuses.
--
-- Two instances of one chan-1 group, members at relative rows 0..1 (ppq 0, 60;
-- resolution 240, rowPerBeat 4 -> 60 ppq/row). Instance 1 anchored at row 0
-- (rows 0..1), instance 2 at ppq 240 (rows 4..5); rows 2..3 are an empty gap.

local t = require('support')

local function noteCol(h, chan)
  for i, col in ipairs(h.vm.grid.cols) do
    if col.type == 'note' and col.midiChan == chan then return i, col end
  end
end

local function ppqsOn(h, chan)
  local out = {}
  for _, n in h.fm:notes() do
    if n.chan == chan and n.evType ~= 'pa' then out[#out + 1] = n.ppq end
  end
  table.sort(out)
  return out
end

local function eq(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

-- chan-1 group, two stacked instances with a two-row gap between them.
local function stackedGroup(harness)
  local h = harness.mk{
    groups = true,
    seed   = { notes = {
      { ppq = 0,  endppq = 60,  chan = 1, pitch = 60, vel = 100 },   -- relative row 0
      { ppq = 60, endppq = 120, chan = 1, pitch = 62, vel = 100 },   -- relative row 1
    } },
  }
  local ci = noteCol(h, 1)
  h.ec:setSelection{ row1 = 0, row2 = 1, col1 = ci, col2 = ci,
                     part1 = 'pitch', part2 = 'pitch' }
  local gid = h.gm:markGroup(h.vm:eventsInRect(h.vm:selectionAsRect()),
                             h.vm:selectionAsRect())
  h.ec:selClear()
  h.gm:newInstance(gid, { ppq = 240, chan = 1 })   -- instance 2, rows 4..5
  h.tm:flush()
  return h, ci
end

return {
  {
    name = 'insertRow past an instance re-anchors it alone; the sibling does not move',
    run = function(harness)
      local h, ci = stackedGroup(harness)
      t.truthy(eq(ppqsOn(h, 1), { 0, 60, 240, 300 }),
               'precondition: two instances, four members')

      h.ec:setPos(3, ci, 1)            -- cursor in the gap, below inst 1, above inst 2
      h.cmgr:invoke('insertRow')

      -- inst 1 (rows 0..1) is wholly above the cut -> untouched; inst 2 shifts
      -- down one row (anchor 240 -> 300). The shared pattern is unchanged, so
      -- inst 1's members stay at ppq 0 and 60.
      t.truthy(eq(ppqsOn(h, 1), { 0, 60, 300, 360 }),
               'inst 1 unmoved, inst 2 re-anchored +1 row, no global propagation')
    end,
  },
  {
    name = 'insertRow inside an instance refuses the whole op',
    run = function(harness)
      local h, ci = stackedGroup(harness)

      h.ec:setPos(1, ci, 1)            -- cut strictly inside inst 1 (rows 0..1)
      h.cmgr:invoke('insertRow')

      t.truthy(eq(ppqsOn(h, 1), { 0, 60, 240, 300 }),
               'no-op: bisected instance refuses, nothing shifted')
    end,
  },
  {
    name = 'deleteRow before an instance re-anchors it up; the sibling does not move',
    run = function(harness)
      local h, ci = stackedGroup(harness)

      h.ec:setPos(2, ci, 1)            -- delete one row in the gap above inst 2
      h.cmgr:invoke('deleteRow')

      -- inst 1 untouched; inst 2 shifts up one row (anchor 240 -> 180).
      t.truthy(eq(ppqsOn(h, 1), { 0, 60, 180, 240 }),
               'inst 1 unmoved, inst 2 re-anchored -1 row')
    end,
  },
  {
    name = 'column-scoped row op refuses when it would slice some of an instance\'s columns',
    run = function(harness)
      -- Region across chan 1+2 (instance occupies both columns), one instance at
      -- rows 0..1. insertRowCol on chan 1 alone would re-anchor the instance but
      -- cover only one of its two columns -> refuse.
      local h = harness.mk{
        groups = true,
        seed   = { notes = {
          { ppq = 0,  endppq = 60,  chan = 1, pitch = 60, vel = 100 },
          { ppq = 60, endppq = 120, chan = 1, pitch = 62, vel = 100 },
        } },
      }
      local ci1 = noteCol(h, 1)
      local ci2 = noteCol(h, 2)
      h.ec:setSelection{ row1 = 0, row2 = 1, col1 = ci1, col2 = ci2,
                         part1 = 'pitch', part2 = 'pitch' }
      h.gm:markGroup(h.vm:eventsInRect(h.vm:selectionAsRect()),
                     h.vm:selectionAsRect())
      h.ec:selClear()
      h.tm:flush()
      t.truthy(eq(ppqsOn(h, 1), { 0, 60 }), 'precondition: one instance, two members')

      h.ec:setPos(0, ci1, 1)
      h.cmgr:invoke('insertRowCol')

      t.truthy(eq(ppqsOn(h, 1), { 0, 60 }),
               'no-op: partial column coverage refuses')
    end,
  },
  {
    name = 'insertRow sliding an instance partly off the take keeps the rows that remain',
    run = function(harness)
      -- Default take is 3840 ppq (64 rows); an instance anchored at 3720 fills
      -- the last two rows. A one-row insert above it re-anchors to 3780: the
      -- top row stays on the take, the bottom row overflows and is withheld.
      local h = harness.mk{
        groups = true,
        seed   = { notes = {
          { ppq = 0,  endppq = 60,  chan = 1, pitch = 60, vel = 100 },
          { ppq = 60, endppq = 120, chan = 1, pitch = 62, vel = 100 },
        } },
      }
      local ci = noteCol(h, 1)
      h.ec:setSelection{ row1 = 0, row2 = 1, col1 = ci, col2 = ci,
                         part1 = 'pitch', part2 = 'pitch' }
      local gid = h.gm:markGroup(h.vm:eventsInRect(h.vm:selectionAsRect()),
                                 h.vm:selectionAsRect())
      h.ec:selClear()
      h.gm:newInstance(gid, { ppq = 3720, chan = 1 })   -- rows 62..63
      h.tm:flush()
      t.truthy(eq(ppqsOn(h, 1), { 0, 60, 3720, 3780 }), 'precondition')

      h.ec:setPos(10, ci, 1)            -- insert above instance 2
      h.cmgr:invoke('insertRow')

      t.truthy(eq(ppqsOn(h, 1), { 0, 60, 3780 }),
               'overflow row (3840) withheld, the remaining row (3780) kept')
      t.eq(#h.gm:eachInstance(), 2, 'the clipped instance still lives')
    end,
  },
  {
    name = 'insertRow shoving an instance entirely off the take deletes it',
    run = function(harness)
      -- A single-row group; the second instance fills the take's last row exactly.
      -- A one-row insert pushes its only row off the end -> the instance is gone.
      local h = harness.mk{
        groups = true,
        seed   = { notes = {
          { ppq = 0, endppq = 60, chan = 1, pitch = 60, vel = 100 },
        } },
      }
      local ci = noteCol(h, 1)
      h.ec:setSelection{ row1 = 0, row2 = 0, col1 = ci, col2 = ci,
                         part1 = 'pitch', part2 = 'pitch' }
      local gid = h.gm:markGroup(h.vm:eventsInRect(h.vm:selectionAsRect()),
                                 h.vm:selectionAsRect())
      h.ec:selClear()
      h.gm:newInstance(gid, { ppq = 3780, chan = 1 })   -- row 63, the last take row
      h.tm:flush()
      t.truthy(eq(ppqsOn(h, 1), { 0, 3780 }), 'precondition: two single-row instances')

      h.ec:setPos(10, ci, 1)
      h.cmgr:invoke('insertRow')

      t.truthy(eq(ppqsOn(h, 1), { 0 }), 'the overflowed instance is gone, the other remains')
      t.eq(#h.gm:eachInstance(), 1, 'instance deleted, not left anchored off the take')
    end,
  },
}
