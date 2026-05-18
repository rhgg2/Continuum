-- A duplicate / groupDuplicate run is meant to die on any real edit:
-- the keep-sets only spare navigation. But the keep-set doBefore
-- sweeps fire on cmgr dispatch, and typed entry does NOT go through
-- cmgr -- trackerPage's char drain calls tv:editEvent straight. So a
-- committed keystroke used to leave the run token alive and the next
-- duplicate press silently continued the cascade. tv:editEvent's
-- commit now ends every cascade by hand. Real trackerView (+ real
-- groupManager for the group case) via harness.mk -- the wired path.

local t = require('support')

local function noteCol(h, chan)
  for i, col in ipairs(h.vm.grid.cols) do
    if col.type == 'note' and col.midiChan == chan then return i, col end
  end
end

local function pitch60Ppqs(h)
  local out = {}
  for _, n in ipairs(h.fm:dump().notes) do
    if n.pitch == 60 then out[#out + 1] = n.ppq end
  end
  table.sort(out)
  return out
end

local function noteAt(h, ppq)
  for _, n in ipairs(h.fm:dump().notes) do
    if n.ppq == ppq then return n end
  end
end

return {
  {
    name = 'a typed note edit cancels the plain duplicate cascade',
    run = function(harness)
      -- rowPerBeat 4, res 240 -> 60 ppq/row. Note at row 4 (ppq 240).
      local h = harness.mk{ seed = { notes = {
        { ppq = 240, endppq = 300, chan = 1, pitch = 60, vel = 100 },
      } } }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(4, 1, 1)
      h.ec:extendTo(4, 1, 1)             -- a real 1-row selection (seed)

      h.cmgr:invoke('duplicateDown')     -- copy at row 5 (ppq 300); run live
      t.truthy(noteAt(h, 300), 'first duplicate placed a copy (cascade seeded)')

      h.ec:selClear(); h.ec:setPos(8, 1, 1)  -- mouse-style move: run survives
      h.vm:editEvent(h.vm.grid.cols[1], nil, 1, string.byte('z'), false)
      t.truthy(noteAt(h, 480), 'typed note committed at the cursor (ppq 480)')

      local before = pitch60Ppqs(h)
      h.cmgr:invoke('duplicateDown')     -- must be a no-op: token cleared
      t.deepEq(pitch60Ppqs(h), before,
               'no continuation copy -- the edit ended the cascade')
    end,
  },

  {
    name = 'a typed note edit cancels the groupDuplicate cascade',
    run = function(harness)
      local h = harness.mk{ groups = true, seed = { notes = {
        { ppq = 0, endppq = 60, chan = 1, pitch = 60, vel = 100 },
      } } }
      local ci = noteCol(h, 1)
      h.ec:setSelection{ row1 = 0, row2 = 0, col1 = ci, col2 = ci,
                         part1 = 'pitch', part2 = 'pitch' }

      h.cmgr:invoke('groupDuplicate')    -- group instance at row 1 (ppq 60)
      t.truthy(noteAt(h, 60), 'first groupDuplicate projected a copy (run seeded)')

      h.ec:selClear(); h.ec:setPos(10, ci, 1)  -- mouse-style move
      h.vm:editEvent(h.vm.grid.cols[ci], nil, 1, string.byte('z'), false)
      t.truthy(noteAt(h, 600), 'typed note committed at the cursor (ppq 600)')

      local before = pitch60Ppqs(h)
      h.cmgr:invoke('groupDuplicate')    -- must be a no-op: token cleared
      t.deepEq(pitch60Ppqs(h), before,
               'no continuation instance -- the edit ended the cascade')
    end,
  },
}
