-- Shift a note INTO a region (the add.member arm: gm:addEvent). A move whose
-- destination falls in a region auto-joins that group's shared pattern
-- (decision 2, global): the moved event propagates to every instance. Covers
-- the three destinations the dispatch is generic over -- into a group, from
-- one group to another, from one instance to another -- all in global mode.
-- Row pitch is 60 ppq (resolution 240, rowPerBeat 4): a 2-row region spans
-- ppq 0..120, so row 1 (ppq 60) is an empty in-region cell to receive a move.

local t = require('support')

local function noteCol(h, chan, lane)
  for i, col in ipairs(h.vm.grid.cols) do
    if col.type == 'note' and col.midiChan == chan
       and (lane == nil or (col.lane or 1) == lane) then return i, col end
  end
end

local function allNotes(h)
  local out = {}
  for _, n in h.fm:notes() do
    if n.evType ~= 'pa' then
      out[#out + 1] = { ppq = n.ppq, chan = n.chan, pitch = n.pitch }
    end
  end
  return out
end

local function noteAt(h, chan, ppq)
  for _, n in ipairs(allNotes(h)) do
    if n.chan == chan and n.ppq == ppq then return n end
  end
end

-- The grid row of the cell at colIx with the given ppq (ppq/row is not fixed).
local function rowOfPpq(h, colIx, ppq)
  for row, evt in pairs(h.vm.grid.cols[colIx].cells) do
    if evt.ppq == ppq then return row end
  end
end

-- Mark grid rows [r1,r2] of one note column as a region; returns the groupId.
local function markRows(h, ci, r1, r2)
  h.ec:setSelection{ row1 = r1, row2 = r2, col1 = ci, col2 = ci,
                     part1 = 'pitch', part2 = 'pitch' }
  local gid = h.gm:markGroup(h.vm:eventsInRect(h.vm:selectionAsRect()),
                             h.vm:selectionAsRect())
  h.ec:selClear()
  return gid
end

return {
  {
    name = 'move a standalone INTO a group: adopted + propagates to every instance',
    run = function(harness)
      local h = harness.mk{
        groups = true,
        seed   = { notes = {
          { ppq = 0,  endppq = 60,  chan = 1, pitch = 60, vel = 100 },  -- group seed
          { ppq = 60, endppq = 120, chan = 2, pitch = 64, vel = 100 },  -- standalone
        } },
      }
      local ci1 = noteCol(h, 1)
      local gid = markRows(h, ci1, 0, 1)             -- region chan 1, ppq 0..120
      h.gm:newInstance(gid, { ppq = 960, chan = 1 }) -- second instance, member at ppq 960
      h.tm:flush()

      local ci2 = noteCol(h, 2)
      h.ec:setPos(rowOfPpq(h, ci2, 60), ci2)         -- caret on the standalone
      h.cmgr:invoke('eventShiftLeft')                -- chan 2 -> chan 1, into the empty in-region cell

      t.eq(#allNotes(h), 4, 'standalone gone; the moved-in member now lives in both instances')
      t.falsy(noteAt(h, 2, 60), 'the standalone left its slot')
      t.truthy(noteAt(h, 1, 0),  'instance 1 keeps its original member')
      t.truthy(noteAt(h, 1, 60), 'instance 1 gained the moved-in member')
      t.truthy(noteAt(h, 1, 960),  'instance 2 keeps its original member')
      t.truthy(noteAt(h, 1, 1020), 'instance 2 gained the moved-in member -- the adopt propagated')
    end,
  },
  {
    name = 'move a member from one group to another: leaves A, joins B, propagates in B',
    run = function(harness)
      local h = harness.mk{
        groups = true,
        seed   = { notes = {
          { ppq = 0,  endppq = 60,  chan = 1, pitch = 60, vel = 100 },  -- group A member
          { ppq = 60, endppq = 120, chan = 2, pitch = 64, vel = 100 },  -- group B member (leaves ppq 0 empty)
        } },
      }
      local ci1, ci2 = noteCol(h, 1), noteCol(h, 2)
      markRows(h, ci1, 0, 1)                            -- group A: chan 1, member at ppq 0
      local gidB = markRows(h, ci2, 0, 1)               -- group B: chan 2, member at ppq 60
      h.gm:newInstance(gidB, { ppq = 960, chan = 2 })   -- B's second instance
      h.tm:flush()

      h.ec:setPos(rowOfPpq(h, ci1, 0), ci1)             -- caret on A's member
      h.cmgr:invoke('eventShiftRight')                  -- chan 1 -> chan 2, into B's empty cell

      t.eq(#allNotes(h), 4, 'A emptied; B now carries two members across two instances')
      t.falsy(noteAt(h, 1, 0),    'the member left group A')
      t.truthy(noteAt(h, 2, 0),   'it joined group B, instance 1')
      t.truthy(noteAt(h, 2, 60),  "B's original member is untouched")
      t.truthy(noteAt(h, 2, 960), 'the join propagated to B instance 2')
    end,
  },
  {
    name = 'move a member from one instance to another: lands in the sibling, shared globally',
    run = function(harness)
      local h = harness.mk{
        groups = true,
        seed   = { notes = {
          { ppq = 60, endppq = 120, chan = 1, pitch = 60, vel = 100 },  -- shared member (ppq 0 empty)
        } },
      }
      local ci1 = noteCol(h, 1)
      local gid = markRows(h, ci1, 0, 1)                -- region chan 1, shared member at ppq 60
      h.gm:newInstance(gid, { ppq = 0, chan = 2 })      -- second instance on chan 2, same rows
      h.tm:flush()

      -- Give instance 1 a local-only add at its empty ppq-0 cell; instance 2's
      -- ppq-0 cell stays empty (the move's destination).
      h.gm:setLocalMode(true)
      h.tm:addEvent{ evType = 'note', chan = 1, ppq = 0, endppq = 60, pitch = 67, vel = 100, lane = 1 }
      h.tm:flush()
      h.gm:setLocalMode(false)

      h.ec:setPos(rowOfPpq(h, ci1, 0), ci1)             -- caret on instance 1's local add
      h.cmgr:invoke('eventShiftRight')                  -- chan 1 -> chan 2: into instance 2's empty cell

      local ci2 = noteCol(h, 2)
      t.truthy(ci2, 'instance 2 lives on chan 2')
      t.truthy(noteAt(h, 2, 0),  'the move landed in instance 2')
      t.truthy(noteAt(h, 1, 0),  'and -- global -- materialised back in instance 1 as a shared member')
      t.eq(#allNotes(h), 4, 'shared member at ppq 0 and ppq 60, across both instances')
    end,
  },
}
