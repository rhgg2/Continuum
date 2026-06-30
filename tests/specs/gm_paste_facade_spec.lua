-- Stage 6 full-stack: paste routes its clear+write through the leaf facade, so a
-- paste into a group region auto-joins + propagates, an overwrite rewrites every
-- instance, and an aliasing paste is refused in global mode. Real tm/mm/gm/tv;
-- fake REAPER. see design/group-aware-editing.md § Stages (6).

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

-- Region spans ppq 0..120 (rows 0-1) on chan 1, member at ppq 0; a sibling
-- instance sits `sibPpq` later. Returns the harness and chan-1 note column index.
local function setup(harness, sibPpq, extraSeed)
  local notes = { { ppq = 0, endppq = 60, chan = 1, pitch = 60, vel = 100 } }
  if extraSeed then notes[#notes + 1] = extraSeed end
  local h = harness.mk{ groups = true, seed = { notes = notes } }
  local ci = noteCol(h, 1)
  h.ec:setSelection{ row1 = 0, row2 = 1, col1 = ci, col2 = ci, part1 = 'pitch', part2 = 'pitch' }
  local rect = h.vm:selectionAsRect()
  local gid  = h.gm:markGroup(h.vm:eventsInRect(rect), rect)
  h.ec:selClear()
  h.gm:newInstance(gid, { ppq = sibPpq, chan = 1 })
  h.tm:flush()
  return h, ci
end

return {
  {
    name = 'paste into a region auto-joins the pattern and propagates to every instance',
    run = function(harness)
      local h, ci = setup(harness, 240)
      h.ec:setPos(0, ci, 1)        -- on the member, pitch stop
      h.cmgr:invoke('copy')
      h.ec:setPos(1, ci, 1)        -- row 1 = ppq 60, an empty in-region cell
      h.cmgr:invoke('paste')

      t.truthy(noteAt(h, 1, 60),  'pasted note landed at the origin cell')
      t.truthy(noteAt(h, 1, 300), 'and propagated to the sibling instance (240 + 60)')
    end,
  },
  {
    name = 'paste overwriting a member rewrites the shared slot for every instance',
    run = function(harness)
      -- chan-2 source note (no group) carries a distinct pitch to paste over the member.
      local h, ci = setup(harness, 240, { ppq = 0, endppq = 60, chan = 2, pitch = 72, vel = 100 })
      local cj = noteCol(h, 2)
      h.ec:setPos(0, cj, 1)
      h.cmgr:invoke('copy')
      h.ec:setPos(0, ci, 1)        -- over the region member at ppq 0
      h.cmgr:invoke('paste')

      t.eq(noteAt(h, 1, 0).pitch,   72, 'origin slot now carries the pasted pitch')
      t.eq(noteAt(h, 1, 240).pitch, 72, 'and the clear+add both propagated to the sibling')
    end,
  },
  {
    name = 'in localMode a paste into a region stays a per-instance add (sibling untouched)',
    run = function(harness)
      local h, ci = setup(harness, 240)
      h.ec:setPos(0, ci, 1)
      h.cmgr:invoke('copy')
      h.gm:setLocalMode(true)
      h.ec:setPos(1, ci, 1)
      h.cmgr:invoke('paste')

      t.truthy(noteAt(h, 1, 60), 'pasted note landed locally at the origin')
      t.falsy(noteAt(h, 1, 300), 'sibling untouched in localMode')
    end,
  },
  {
    name = 'a paste whose footprint spans two instances of one group is refused (global)',
    run = function(harness)
      -- Adjacent sibling at ppq 120 (rows 2-3); a 4-row paste at row 0 covers both.
      local h, ci = setup(harness, 120, { ppq = 0, endppq = 60, chan = 2, pitch = 72, vel = 100 })
      local cj = noteCol(h, 2)
      h.ec:setSelection{ row1 = 0, row2 = 3, col1 = cj, col2 = cj, part1 = 'pitch', part2 = 'pitch' }
      h.cmgr:invoke('copy')

      local before = #allNotes(h)
      h.ec:setPos(0, ci, 1)
      h.cmgr:invoke('paste')
      t.eq(#allNotes(h), before, 'aliasing paste refused: nothing written')
    end,
  },
  {
    name = 'a paste landing wholly inside one instance is allowed (precision, not over-refusal)',
    run = function(harness)
      local h, ci = setup(harness, 120, { ppq = 0, endppq = 60, chan = 2, pitch = 72, vel = 100 })
      local cj = noteCol(h, 2)
      h.ec:setSelection{ row1 = 0, row2 = 1, col1 = cj, col2 = cj, part1 = 'pitch', part2 = 'pitch' }
      h.cmgr:invoke('copy')

      h.ec:setPos(0, ci, 1)        -- footprint rows 0-1, only the origin instance
      h.cmgr:invoke('paste')
      t.eq(noteAt(h, 1, 0).pitch,   72, 'paste landed, overwriting the origin member')
      t.eq(noteAt(h, 1, 120).pitch, 72, 'and propagated to the adjacent sibling')
    end,
  },
}
