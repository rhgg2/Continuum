-- Phase 5.5: interpolate refuses on aliased selection. cycleShape would
-- write a computed absolute (`shape = ...`) on an aliased child, which
-- assignEvent treats as severance; silently skipping aliased events would
-- produce a misleading curve. Whole command no-ops with a status warning.

local t = require('support')
local util = require('util')

local function findCcCol(grid, ccNum, chan)
  for i, c in ipairs(grid.cols) do
    if c.type == 'cc' and c.cc == ccNum and c.midiChan == chan then
      return i, c
    end
  end
end

local function rootCc(extras)
  local n = { ppq = 0, ppqL = 0, chan = 1, msgType = 'cc', cc = 7, val = 64,
              shape = 'step', uuid = 1 }
  for k, v in pairs(extras or {}) do n[k] = v end
  return n
end

local CFG = { config = { take = { rowPerBeat = 1 } } }

return {
  --------------------------------------------------------------------
  -- Selection covers an aliased child: whole command refused. Spec
  -- preserved (no sever), shape unchanged, one ShowMessageBox.
  --------------------------------------------------------------------
  {
    name = 'interpolate refuses when selection contains an aliased cc; status warning',
    run = function(harness)
      local h = harness.mk(util.assign({
        seed = { ccs = { rootCc{
          aliasCtr = 2,
          children = {
            { id = '1',
              xform = { ppqL = {{'add', 480}}, val = {{'add', 10}} },
              children = {} },
          },
        } } },
      }, CFG))
      h.vm:setGridSize(80, 40)

      local colIdx = findCcCol(h.vm.grid, 7, 1)
      t.truthy(colIdx, 'cc col present')
      -- Root at row 0, alias at ppq=480 → row 2 (rpb=1, res=240).
      h.ec:setSelection{ row1=0, row2=3, col1=colIdx, col2=colIdx,
                         part1='val', part2='val' }
      h.cmgr:invoke('interpolate')

      local msgs = h.reaper._state.messages
      t.eq(#msgs, 1, 'one warning surfaced')
      t.truthy(msgs[1].msg:find('aliased', 1, true), 'message names cause')

      local ccs = h.fm:dump().ccs
      local root
      for _, c in ipairs(ccs) do if c.uuid == 1 then root = c end end
      t.truthy(root)
      t.eq(#root.children, 1, 'still aliased — not severed')
      t.eq(root.shape, 'step', 'root shape unchanged (no plan ran)')
    end,
  },

  --------------------------------------------------------------------
  -- Pure-root selection: regression. Shape on the left endpoint of the
  -- pair cycles (step → linear). Pre-pass empty → plans applied.
  --------------------------------------------------------------------
  {
    name = 'interpolate on plain ccs cycles shape; no warning',
    run = function(harness)
      local h = harness.mk(util.assign({
        seed = { ccs = {
          { ppq =   0, chan = 1, msgType = 'cc', cc = 7, val =  10,
            shape = 'step', uuid = 1 },
          { ppq = 480, chan = 1, msgType = 'cc', cc = 7, val = 100,
            shape = 'step', uuid = 2 },
        } },
      }, CFG))
      h.vm:setGridSize(80, 40)

      local colIdx = findCcCol(h.vm.grid, 7, 1)
      h.ec:setSelection{ row1=0, row2=3, col1=colIdx, col2=colIdx,
                         part1='val', part2='val' }
      h.cmgr:invoke('interpolate')

      t.eq(#h.reaper._state.messages, 0, 'silent on the plain path')
      local ccs = h.fm:dump().ccs
      local first; for _, c in ipairs(ccs) do if c.ppq == 0 then first = c end end
      t.eq(first.shape, 'linear',
           'left endpoint of the pair cycled step → linear')
    end,
  },

  --------------------------------------------------------------------
  -- Cursor on the materialised alias child (no selection): refused.
  -- Pins the no-selection branch's parentUuid check.
  --------------------------------------------------------------------
  {
    name = 'interpolate at cursor on aliased cc cell: refused; status warning',
    run = function(harness)
      local h = harness.mk(util.assign({
        seed = { ccs = { rootCc{
          aliasCtr = 2,
          children = {
            { id = '1',
              xform = { ppqL = {{'add', 480}}, val = {{'add', 10}} },
              children = {} },
          },
        } } },
      }, CFG))
      h.vm:setGridSize(80, 40)

      local colIdx, col = findCcCol(h.vm.grid, 7, 1)
      local aliasRow
      for r, e in pairs(col.cells or {}) do
        if e.parentUuid then aliasRow = r; break end
      end
      t.truthy(aliasRow, 'alias child has a cell at some row')

      h.ec:setPos(aliasRow, colIdx, 1)
      h.cmgr:invoke('interpolate')

      local msgs = h.reaper._state.messages
      t.eq(#msgs, 1, 'one warning surfaced')

      local ccs = h.fm:dump().ccs
      local root; for _, c in ipairs(ccs) do if c.uuid == 1 then root = c end end
      t.eq(#root.children, 1, 'still aliased — not severed')
    end,
  },
}
