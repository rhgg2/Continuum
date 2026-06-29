-- Stage 3: a value edit on a group member rides the leaf-edit facade
-- (cellEdit.assign -> gm:assignEvent) and propagates to every instance; in
-- localMode it stays a per-instance override. Full-stack: real tm/mm/gm/tv,
-- driven by the real nudge command on a selected member cell, as the user would.

local t = require('support')

local function noteCol(h, chan)
  for i, col in ipairs(h.vm.grid.cols) do
    if col.type == 'note' and col.midiChan == chan then return i, col end
  end
end

local function pitchByPpq(h)
  local out = {}
  for _, n in h.fm:notes() do
    if n.evType ~= 'pa' then out[n.ppq] = n.pitch end
  end
  return out
end

-- One seeded note, marked as a group, plus a sibling instance at ppq 960.
-- The selection is left on the origin member cell (part pitch) so the nudge
-- command transposes it through the facade.
local function setup(harness)
  local h = harness.mk{
    groups = true,
    seed   = { notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } } },
  }
  local ci = noteCol(h, 1)
  h.ec:setSelection{ row1 = 0, row2 = 0, col1 = ci, col2 = ci, part1 = 'pitch', part2 = 'pitch' }
  local rect = h.vm:selectionAsRect()
  local gid  = h.gm:markGroup(h.vm:eventsInRect(rect), rect)
  h.gm:newInstance(gid, { ppq = 960, chan = 1 })
  h.tm:flush()
  return h, ci, gid
end

return {
  {
    name = 'a pitch nudge on a synced member propagates to every instance (facade -> gm)',
    run = function(harness)
      local h = setup(harness)
      h.cmgr:invoke('nudgeFineUp')

      local pitch = pitchByPpq(h)
      t.eq(pitch[0],   61, 'origin transposed +1')
      t.eq(pitch[960], 61, 'sibling tracked the edit through the shared pattern')
    end,
  },
  {
    name = 'in localMode the nudge stays a per-instance override (sibling untouched)',
    run = function(harness)
      local h = setup(harness)
      h.gm:setLocalMode(true)
      h.cmgr:invoke('nudgeFineUp')
      h.gm:setLocalMode(false)

      local pitch = pitchByPpq(h)
      t.eq(pitch[0],   61, 'origin transposed locally')
      t.eq(pitch[960], 60, 'sibling unchanged -- the override did not propagate')
    end,
  },
}
