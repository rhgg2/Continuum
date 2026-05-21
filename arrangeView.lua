-- See docs/arrangeView.md for the model.
-- @noindex

--invariant: mirrors trackerView's viewport pattern. Cursor (row, col) and scroll (row, col) are in-memory module-locals; only beatPerRow persists via cm. Re-opening a project lands cursor at (0, 0); density is restored.
--invariant: row/col addressing — cursorRow is integer rows; cursorCol is the project track index (0-based). One row spans `beatPerRow` beats of QN, so qn ↔ row is `qn / beatPerRow` ↔ `row * beatPerRow`.
--invariant: gridRows / gridCols are visible cell counts set by the page each frame via setGridSize; followViewport runs on every cursor mutation so the cursor stays in the visible band.
--invariant: av speaks no REAPER / ImGui / am — bounds (track count, project end row) come from callers when relevant.
--invariant: paletteSlot is a per-session module-local pointer (0..61 or nil) — which slot the right-side palette has focused for rename/delete; doesn't persist (cursor-like), nothing to do with cursorCol.

local util = require 'util'

local cm = (...).cm

local av = {}

local cursorRow, cursorCol = 0, 0
local scrollRow, scrollCol = 0, 0
local gridRows, gridCols   = 0, 0
-- Upper clamp for cursorCol — the page pushes the live track count
-- each frame. Nil means unbounded (initial frame before the page has
-- drawn).
local maxCol = nil
local paletteSlot = nil

----- Viewport follow

-- Keep the cursor in the visible band, biased to the leading edge: if the
-- cursor leaves on either side, scroll just enough to bring it back in.
local function followViewport()
  if gridRows > 0 then
    scrollRow = util.clamp(scrollRow,
                           math.max(0, cursorRow - gridRows + 1),
                           cursorRow)
  end
  if gridCols > 0 then
    scrollCol = util.clamp(scrollCol,
                           math.max(0, cursorCol - gridCols + 1),
                           cursorCol)
  end
end

----------- PUBLIC

function av:cursorRow() return cursorRow end
function av:cursorCol() return cursorCol end

--contract: setCursor clamps negative coords to 0 and (for cursorCol) at maxCol if the page has pushed one; row upper-bound clamp is still the caller's job until project-end is wired
function av:setCursor(row, col)
  cursorRow = math.max(0, math.floor(row))
  local c = math.max(0, math.floor(col))
  if maxCol then c = math.min(c, maxCol) end
  cursorCol = c
  followViewport()
end

function av:scroll() return scrollRow, scrollCol end

--contract: page hands over the visible cell counts each frame so followViewport has live bounds
function av:setGridSize(rows, cols)
  gridRows = math.max(0, math.floor(rows))
  gridCols = math.max(0, math.floor(cols))
  followViewport()
end

--contract: page pushes the live track count each frame so cursorCol upper-clamps without av needing to call am
function av:setMaxCol(n) maxCol = n and math.max(0, math.floor(n) - 1) or nil end

function av:paletteSlot() return paletteSlot end

--contract: setPaletteSlot(nil) clears; numeric values clamp into 0..61 (the base36 slot range)
function av:setPaletteSlot(idx)
  if idx == nil then paletteSlot = nil; return end
  paletteSlot = math.max(0, math.min(61, math.floor(idx)))
end

function av:beatPerRow()    return cm:get('arrangeBeatPerRow') end
function av:setBeatPerRow(v) cm:set('project', 'arrangeBeatPerRow', math.max(1/4, v)) end

function av:qnToRow(qn)  return qn / self:beatPerRow() end
function av:rowToQN(row) return row * self:beatPerRow() end

return av
