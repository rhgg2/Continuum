-- arrangeView: in-memory cursor/scroll + persisted beatPerRow, mirroring
-- the trackerView/editCursor split (cursor is transient, density persists).

local t    = require('support')
local util = require('util')

local function mkAv(harness)
  local h  = harness.mk()
  local av = util.instantiate('arrangeView', { cm = h.cm })
  return h, av
end

return {
  {
    name = 'cursor defaults to (0,0); setCursor clamps negatives and floors',
    run = function(harness)
      local _, av = mkAv(harness)
      t.eq(av:cursorRow(), 0); t.eq(av:cursorCol(), 0)
      av:setCursor(5.7, 3.4)
      t.eq(av:cursorRow(), 5); t.eq(av:cursorCol(), 3)
      av:setCursor(-1, -2)
      t.eq(av:cursorRow(), 0); t.eq(av:cursorCol(), 0)
    end,
  },

  {
    name = 'scroll defaults to (0,0); setGridSize alone does not move scroll',
    run = function(harness)
      local _, av = mkAv(harness)
      av:setGridSize(20, 4)
      local sr, sc = av:scroll()
      t.eq(sr, 0); t.eq(sc, 0)
    end,
  },

  {
    name = 'cursor moving below the visible band scrolls down to follow',
    run = function(harness)
      local _, av = mkAv(harness)
      av:setGridSize(10, 4)
      av:setCursor(15, 0)
      local sr = av:scroll()
      t.eq(sr, 6, 'scroll snaps to keep cursor on the last visible row (15 - 10 + 1)')
    end,
  },

  {
    name = 'cursor moving above the visible band scrolls up to follow',
    run = function(harness)
      local _, av = mkAv(harness)
      av:setGridSize(10, 4)
      av:setCursor(20, 0)
      av:setCursor(2, 0)
      local sr = av:scroll()
      t.eq(sr, 2, 'scroll catches up to the cursor when cursor jumps above the band')
    end,
  },

  {
    name = 'horizontal follow tracks cursorCol against gridCols',
    run = function(harness)
      local _, av = mkAv(harness)
      av:setGridSize(10, 3)
      av:setCursor(0, 7)
      local _, sc = av:scroll()
      t.eq(sc, 5, '7 - 3 + 1 = 5; cursor sits on rightmost visible col')
      av:setCursor(0, 1)
      _, sc = av:scroll()
      t.eq(sc, 1, 'cursor jumping left pulls scroll left')
    end,
  },

  {
    name = 'setGridSize shrinking the viewport re-follows the cursor in place',
    run = function(harness)
      local _, av = mkAv(harness)
      av:setGridSize(20, 8)
      av:setCursor(15, 6)
      local sr, sc = av:scroll()
      t.eq(sr, 0); t.eq(sc, 0)
      av:setGridSize(4, 2)
      sr, sc = av:scroll()
      t.eq(sr, 12, '15 - 4 + 1')
      t.eq(sc, 5,  '6 - 2 + 1')
    end,
  },

  {
    name = 'beatPerRow defaults to cm value; setter clamps minimum',
    run = function(harness)
      local h, av = mkAv(harness)
      t.eq(av:beatPerRow(), 4, 'cm default')
      av:setBeatPerRow(8)
      t.eq(av:beatPerRow(), 8)
      t.eq(h.cm:get('arrangeBeatPerRow'), 8, 'persists at project tier')
      av:setBeatPerRow(0)
      t.eq(av:beatPerRow(), 1/4, 'clamped to minimum 1/4')
    end,
  },

  {
    name = 'qnToRow / rowToQN are inverses through beatPerRow',
    run = function(harness)
      local _, av = mkAv(harness)
      av:setBeatPerRow(4)
      t.eq(av:qnToRow(16), 4)
      t.eq(av:rowToQN(4), 16)
      av:setBeatPerRow(8)
      t.eq(av:qnToRow(16), 2)
      t.eq(av:rowToQN(2), 16)
    end,
  },
}
