-- Stage 4a full-stack: typed create / delete on a member rides the leaf-edit facade
-- (-> gm:addEvent/gm:deleteEvent), real tm/mm/gm/tv. Region spans ppq 0..120; row 1 (ppq 60) is an empty in-region cell.

local t = require('support')

local function noteCol(h, chan)
  for i, col in ipairs(h.vm.grid.cols) do
    if col.type == 'note' and col.midiChan == chan then return i, col end
  end
end

local function allNotes(h)
  local out = {}
  for _, n in h.fm:notes() do
    if n.evType ~= 'pa' then out[#out + 1] = { ppq = n.ppq, chan = n.chan, pitch = n.pitch } end
  end
  return out
end

local function noteAt(h, chan, ppq)
  for _, n in ipairs(allNotes(h)) do
    if n.chan == chan and n.ppq == ppq then return n end
  end
end

-- Seed one member at ppq 0, mark rows 0-1 of its column as a region, and add a
-- sibling instance at ppq 240 (rows 4-5). Returns the harness and column index.
local function setup(harness)
  local h = harness.mk{
    groups = true,
    seed   = { notes = { { ppq = 0, endppq = 60, chan = 1, pitch = 60, vel = 100 } } },
  }
  local ci = noteCol(h, 1)
  h.ec:setSelection{ row1 = 0, row2 = 1, col1 = ci, col2 = ci, part1 = 'pitch', part2 = 'pitch' }
  local rect = h.vm:selectionAsRect()
  local gid  = h.gm:markGroup(h.vm:eventsInRect(rect), rect)
  h.ec:selClear()
  h.gm:newInstance(gid, { ppq = 240, chan = 1 })
  h.tm:flush()
  return h, ci
end

return {
  {
    name = 'typed create inside a region auto-joins the pattern and propagates to every instance',
    run = function(harness)
      local h, ci = setup(harness)
      h.ec:setPos(1, ci)   -- row 1 = ppq 60, an empty in-region cell of the origin
      h.vm:editEvent(h.vm.grid.cols[ci], nil, 1, string.byte('z'), false)

      t.truthy(noteAt(h, 1, 60),  'the typed note landed at the origin cell')
      t.truthy(noteAt(h, 1, 300), 'and propagated to the sibling instance (240 + 60)')
    end,
  },
  {
    name = 'delete of a synced member propagates: every instance loses it',
    run = function(harness)
      local h, ci = setup(harness)
      h.ec:setPos(0, ci)   -- row 0 = ppq 0, the seeded member
      h.cmgr:invoke('delete')

      t.eq(#allNotes(h), 0, 'both the origin member and the sibling projection are gone')
    end,
  },
  {
    name = 'in localMode a typed create stays a per-instance add (sibling untouched)',
    run = function(harness)
      local h, ci = setup(harness)
      h.gm:setLocalMode(true)
      h.ec:setPos(1, ci)
      h.vm:editEvent(h.vm.grid.cols[ci], nil, 1, string.byte('z'), false)
      h.gm:setLocalMode(false)

      t.truthy(noteAt(h, 1, 60), 'the local add is visible at the origin')
      t.falsy(noteAt(h, 1, 300), 'but did not propagate to the sibling')
    end,
  },
}
