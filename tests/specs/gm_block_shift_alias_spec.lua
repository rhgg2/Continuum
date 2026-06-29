-- Stage 2: the injectivity guard on block shifts (design/group-aware-editing.md
-- decision 3, gm:footprintAliases). A propagating block op must map its
-- footprint onto region slots one-to-one. A block spanning two instances of one
-- group AT THE SAME relative slot aliases -- the re-adds would double-write the
-- shared pattern; refuse it (no-op). Disjoint relative slots stay injective and
-- move freely (precise per-cell, not conservative-by-instance-count).
--
-- Region spans chan 1+2 (so a shift to chan 2 stays IN region -> auto-join, the
-- corrupting path), rows 0..1. Two instances stacked: instance 1 rows 0..1,
-- instance 2 rows 2..3. Shared members at relative rows 0 and 1 on chan 1.
-- Row pitch 60 ppq (resolution 240, rowPerBeat 4).

local t = require('support')

local function noteCol(h, chan)
  for i, col in ipairs(h.vm.grid.cols) do
    if col.type == 'note' and col.midiChan == chan then return i, col end
  end
end

local function allNotes(h)
  local out = {}
  for _, n in h.fm:notes() do
    if n.evType ~= 'pa' then out[#out + 1] = { ppq = n.ppq, chan = n.chan } end
  end
  return out
end

local function notesOn(h, chan)
  local n = 0
  for _, e in ipairs(allNotes(h)) do if e.chan == chan then n = n + 1 end end
  return n
end

-- Region across chan 1+2 rows 0..1; a second instance stacked at rows 2..3;
-- shared members at relative rows 0 and 1 on chan 1 (four notes once projected).
local function twoInstanceGroup(harness)
  local h = harness.mk{
    groups = true,
    seed   = { notes = {
      { ppq = 0,  endppq = 60,  chan = 1, pitch = 60, vel = 100 },   -- relative row 0
      { ppq = 60, endppq = 120, chan = 1, pitch = 62, vel = 100 },   -- relative row 1
    } },
  }
  local ci1, ci2 = noteCol(h, 1), noteCol(h, 2)
  h.ec:setSelection{ row1 = 0, row2 = 1, col1 = ci1, col2 = ci2,
                     part1 = 'pitch', part2 = 'pitch' }
  local gid = h.gm:markGroup(h.vm:eventsInRect(h.vm:selectionAsRect()),
                             h.vm:selectionAsRect())
  h.ec:selClear()
  h.gm:newInstance(gid, { ppq = 120, chan = 1 })   -- second instance, rows 2..3
  h.tm:flush()
  return h, ci1
end

return {
  {
    name = 'aliasing block shift refused: two instances at one slot, no double-write',
    run = function(harness)
      local h, ci1 = twoInstanceGroup(harness)
      t.eq(#allNotes(h), 4, 'precondition: two members across two instances')
      -- chan-1 rows 0..3: relative row 0 covered in BOTH instances (rows 0, 2)
      -- and relative row 1 in both (rows 1, 3) -- every slot aliased.
      h.ec:setSelection{ row1 = 0, row2 = 3, col1 = ci1, col2 = ci1,
                         part1 = 'pitch', part2 = 'pitch' }
      h.cmgr:invoke('eventShiftRight')   -- chan 1 -> chan 2 (in-region)

      t.eq(#allNotes(h), 4, 'no-op: nothing moved, no duplicate materialised')
      t.eq(notesOn(h, 1), 4, 'all members still on chan 1')
      t.eq(notesOn(h, 2), 0, 'nothing landed on chan 2')
    end,
  },
  {
    name = 'disjoint block shift allowed: two instances at different slots move injectively',
    run = function(harness)
      local h, ci1 = twoInstanceGroup(harness)
      -- chan-1 rows 1..2: instance 1's relative row 1 + instance 2's relative
      -- row 0 -- different slots, so the footprint is injective.
      h.ec:setSelection{ row1 = 1, row2 = 2, col1 = ci1, col2 = ci1,
                         part1 = 'pitch', part2 = 'pitch' }
      h.cmgr:invoke('eventShiftRight')   -- chan 1 -> chan 2 (in-region, auto-join)

      t.eq(#allNotes(h), 4, 'moved injectively: still four notes, no duplicate')
      t.eq(notesOn(h, 2), 4, 'both relative slots re-joined on chan 2, propagated to both instances')
      t.eq(notesOn(h, 1), 0, 'chan 1 emptied -- the block was not refused')
    end,
  },
}
