-- See docs/arrangeView.md for the model.
-- @noindex

--invariant: arrangeView owns the arrange page's state and every operation on it — cursor, scroll, focus, paletteSlot, plus the operations that mutate them (cursor nav with focus adoption, drag commit, the take edits). arrangePage renders and reads input; it holds none of this state.
--invariant: av builds and owns am, and is the only module that speaks to am — arrangePage runs every project query and every mutation through av, never am directly.
--invariant: av speaks no ImGui — input modifiers (the Shift snap) arrive as plain booleans from the page; av deals only in QN / row numbers.
--invariant: mirrors trackerView's viewport pattern. Cursor (row, col) and scroll (row, col) are in-memory module-locals; only beatPerRow persists via cm. Re-opening a project lands cursor at (0, 0); density is restored.
--invariant: row/col addressing — cursorRow is integer rows; cursorCol is the project track index (0-based). One row spans `beatPerRow` beats of QN, so qn ↔ row is `qn / beatPerRow` ↔ `row * beatPerRow`.
--invariant: gridRows / gridCols are visible cell counts set by the page each frame via setGridSize; followViewport runs on every cursor mutation so the cursor stays in the visible band.
--invariant: av registers the arrange-scope command bodies in cmgr:scope('arrange'); the page owns the key bindings (it holds the ImGui key constants) and the createSlot command (it drives the page's modal).
--invariant: focus is a per-session module-local — the REAPER take handle the edit commands act on. av resolves it through am (focusedTake self-heals to nil when the take is gone). Cursor nav never changes focus; each kb mutation reselects the take under the cursor (adoptCursor), so an empty cell is a no-op. Mouse press on a take sets focus directly.
--invariant: paletteSlot is a per-session module-local pointer (0..61 or nil) — the slot the palette has focused for rename/delete; doesn't persist, nothing to do with cursorCol.

local util = require 'util'

local cm, cmgr, onDive, onTakeProperties =
  (...).cm, (...).cmgr, (...).onDive, (...).onTakeProperties

local am = util.instantiate('arrangeManager', { cm = cm })

local av = {}

local cursorRow, cursorCol = 0, 0
local scrollRow, scrollCol = 0, 0
local gridRows, gridCols   = 0, 0
-- Upper clamp for cursorCol — the page pushes the live track count each
-- frame. Nil means unbounded (initial frame before the page has drawn).
local maxCol      = nil
local paletteSlot = nil
local focus       = nil

local DRAG_EDGE_PX = 5    -- end-edge grab band for a resize hit-test
local PAGE_ROWS    = 16   -- PageUp / PageDown cursor step

----- Viewport follow

-- Keep the cursor in the visible band, biased to the leading edge: if the
-- cursor leaves on either side, scroll just enough to bring it back in.
local function followViewport()
  if gridRows > 0 then
    scrollRow = util.clamp(scrollRow,
                           math.max(0, cursorRow - gridRows + 1), cursorRow)
  end
  if gridCols > 0 then
    scrollCol = util.clamp(scrollCol,
                           math.max(0, cursorCol - gridCols + 1), cursorCol)
  end
end

----- Geometry

local function roundTo(v, step) return math.floor(v / step + 0.5) * step end
local function floorTo(v, step) return math.floor(v / step) * step end

----- Cursor + focus operations

-- The take under the cursor's one-row box, by largest QN overlap.
-- Bottom-edge rule: a cursor sitting exactly on a take's end-edge row
-- (contributes no overlap to the half-open box) still counts as on
-- that take, unless another take starts at the same QN. Pairs with
-- advanceCursorPastNewTake so chained drops walk a column.
local function takeAtCursor()
  local boxTop = av:rowToQN(cursorRow)
  local boxBot = boxTop + av:beatPerRow()
  local eps    = 1e-6
  local best, bestOverlap = nil, 0
  local bottomEdge, startsHere = nil, false
  for _, t in ipairs(am:tracksTakes(cursorCol)) do
    local endQN   = t.startQN + t.lengthQN
    local overlap = math.min(endQN, boxBot) - math.max(t.startQN, boxTop)
    if overlap > bestOverlap then best, bestOverlap = t, overlap end
    if math.abs(t.startQN - boxTop) < eps then startsHere = true end
    if math.abs(endQN      - boxTop) < eps then bottomEdge = t end
  end
  if best then return best end
  return (not startsHere) and bottomEdge or nil
end

-- Cursor advance after a fresh take lands: cursorRow += lengthRows. The
-- bottom-edge rule in takeAtCursor means a chained Super-D / drop-key
-- still adopts the just-placed take.
local function advanceCursorPastNewTake(rawTake)
  if not rawTake then return end
  local take = am:findTake(rawTake)
  if not take then return end
  local rows = math.max(1, math.floor(take.lengthQN / av:beatPerRow() + 0.5))
  av:setCursor(cursorRow + rows, cursorCol)
end

-- The stored focus handle resolved to a live take-shape. Self-heals: a
-- handle whose take is gone (deleted here or in REAPER) clears focus.
local function focusedTake()
  if not focus then return nil end
  local take = am:findTake(focus)
  if not take then focus = nil end
  return take
end

-- Reselect the take under the cursor as focus — the kb-mutation entry
-- gesture. An empty cell clears focus, so the mutation no-ops.
local function adoptCursor()
  local under = takeAtCursor()
  focus = under and under.take or nil
end

--invariant: arrange-scope cursor-nav steps by whole rows/cols — arrows ±1, PageUp/Down ±PAGE_ROWS, Home to row 0, End to the row of the project's last take end (am:projectEndQN). Only negative coords clamp (in setCursor), so PageDown / End / the wheel may sit the cursor on empty rows past the last take.
local function moveCursorBy(dRow, dCol)
  av:setCursor(cursorRow + dRow, cursorCol + dCol)
end

----- Take edits — move / resize / delete / dive the focused take

--invariant: nudge steps by one row; blocked only when the destination start coincides with another take's start. Later takes truncate earlier ones in the rendered frame (see arrangeManager's natural-length model), so passing through a neighbour is allowed — am:moveTake handles the relayout.
local function nudgeFocused(direction)
  adoptCursor()
  local take = focusedTake()
  if not take then return end
  if am:moveTake(take, direction * av:beatPerRow()) then
    moveCursorBy(direction, 0)
  end
end

--invariant: resize writes a numeric natural length (±1 bpr from the current rendered length, floored at 1 bpr). The relayout pass caps it against source and the next take, and demotes any natural ≥ source back to util.OPEN — so grow past the source cap is a self-healing no-op, and grow past a neighbour stores intent that takes effect when the neighbour moves away.
local function resizeFocused(direction)
  adoptCursor()
  local take = focusedTake()
  if not take then return end
  local bpr       = av:beatPerRow()
  local newNatural = math.max(bpr, take.lengthQN + direction * bpr)
  am:resizeTake(take, newNatural)
  -- A shrink that ate the row the cursor sat on pulls the cursor
  -- back to the take's new last row; otherwise the cursor stays put.
  if direction < 0 then
    local endRow = (take.startQN + newNatural) / bpr
    if cursorRow >= endRow then moveCursorBy(-1, 0) end
  end
end

local function deleteFocused()
  adoptCursor()
  local take = focusedTake()
  if take then am:deleteTake(take) end
end

--invariant: arrangeDive acts on the focused take and is MIDI-only — audio takes have no tracker representation, so dive over an audio take is a silent no-op, as is dive with nothing focused. Routes through the onDive callback so coord owns the page swap.
local function diveFocused()
  adoptCursor()
  local take = focusedTake()
  if take and take.kind == 'midi' then onDive(take.item) end
end

--invariant: arrangeTakeProperties opens the takeProps modal on the focused take. MIDI-only — audio takes have no editable name/beats here. Routes through onTakeProperties so continuum can do the tm-bind-and-restore dance.
local function focusedTakeProperties()
  adoptCursor()
  local take = focusedTake()
  if take and take.kind == 'midi' then onTakeProperties(take.item) end
end

--invariant: arrangeDuplicateBelow drops a pooled clone at the focused take's natural end, shifts focus to the new copy, and advances the cursor by the new take's row count. MIDI-only; silent on collision or audio. The new take keeps the source's pool guid — the "another copy please" gesture.
local function duplicateFocusedBelow()
  adoptCursor()
  local take = focusedTake()
  if not take then return end
  local newTake = am:duplicateBelow(take)
  if newTake then
    av:setFocus(newTake)
    advanceCursorPastNewTake(newTake)
  end
end

local function duplicateUnpooledFocusedBelow()
  adoptCursor()
  local take = focusedTake()
  if not take then return end
  local newTake = am:duplicateUnpooledBelow(take)
  if newTake then
    av:setFocus(newTake)
    advanceCursorPastNewTake(newTake)
    onTakeProperties(reaper.GetMediaItemTake_Item(newTake))
  end
end

--invariant: drop0..dropZ place a fresh instance at the cursor and advance cm.arrangeAdvanceBy rows.
--invariant: arrangeAdvanceBy0..9 (Ctrl+digit) set the advance step.
--invariant: drop on an empty slot is a no-op; new takes inherit the slot's instance length.
local function dropAt(slotIdx)
  if am:dropInstance(cursorCol, slotIdx, av:rowToQN(cursorRow)) then
    moveCursorBy(cm:get('arrangeAdvanceBy'), 0)
  end
end

local function deleteFocusedAndAdvance()
  deleteFocused()
  moveCursorBy(cm:get('arrangeAdvanceBy'), 0)
end

----- Loop + transport — REAPER loop range and playback, driven from the cursor

--invariant: setLoopStart/End move one loop endpoint to cursorQN; never inverts the range.
--invariant: with no loop yet, defaults are {qn, projectEnd} (start) and {0, qn} (end).
local function setLoopStartHere()
  local qn = av:rowToQN(cursorRow)
  local _, hi = am:loopRangeQN()
  if hi and qn >= hi then return end
  am:setLoopRangeQN(qn, hi or am:projectEndQN())
end

local function setLoopEndHere()
  local qn = av:rowToQN(cursorRow)
  local lo = am:loopRangeQN()
  if lo and qn <= lo then return end
  am:setLoopRangeQN(lo or 0, qn)
end

local function playFromCursor()
  am:playFromQN(av:rowToQN(cursorRow))
end

local function clearLoop() am:clearLoopRange() end

----------- PUBLIC

----- View state — cursor, scroll, focus, density

function av:cursorRow()   return cursorRow end
function av:cursorCol()   return cursorCol end
function av:scroll()      return scrollRow, scrollCol end
function av:focus()       return focus end
function av:paletteSlot() return paletteSlot end

--contract: clamps negative coords to 0; clamps cursorCol to maxCol if set; no row upper bound.
function av:setCursor(row, col)
  cursorRow = math.max(0, math.floor(row))
  local c = math.max(0, math.floor(col))
  if maxCol then c = math.min(c, maxCol) end
  cursorCol = c
  followViewport()
end

--contract: stores an opaque take handle or nil; av resolves it via am at edit-command time.
function av:setFocus(handle) focus = handle end

--contract: setPaletteSlot(nil) clears; numeric values clamp into 0..61 (the base62 slot range).
function av:setPaletteSlot(idx)
  paletteSlot = idx and math.max(0, math.min(61, math.floor(idx))) or nil
end

function av:beatPerRow()     return cm:get('arrangeBeatPerRow') end
function av:setBeatPerRow(v) cm:set('project', 'arrangeBeatPerRow', math.max(1/4, v)) end
function av:qnToRow(qn)  return qn / self:beatPerRow() end
function av:rowToQN(row) return row * self:beatPerRow() end

--contract: the page hands over the visible cell counts each frame so followViewport has live bounds.
function av:setGridSize(rows, cols)
  gridRows = math.max(0, math.floor(rows))
  gridCols = math.max(0, math.floor(cols))
  followViewport()
end

--contract: page pushes live track count each frame; setCursor clamps cursorCol to it.
function av:setMaxCol(n) maxCol = n and math.max(0, math.floor(n) - 1) or nil end

----- Project data — proxied from am so the page holds no am reference

function av:projectTracks()       return am:projectTracks() end
function av:tracksTakes(trackIdx) return am:tracksTakes(trackIdx) end
function av:trackSlots(trackIdx)  return am:trackSlots(trackIdx) end
function av:keyForSlot(slotIdx)   return am:keyForSlot(slotIdx) end
function av:nextFreeSlot(trackIdx) return am:nextFreeSlot(trackIdx) end
function av:editCursorQN()        return am:editCursorQN() end
function av:playPositionQN()      return am:playPositionQN() end
function av:loopRangeQN()         return am:loopRangeQN() end

----- Transport — gutter mouse drives the REAPER edit cursor / loop range

function av:setEditCursorQN(qn)    am:setEditCursorQN(qn) end
function av:setLoopRangeQN(lo, hi) am:setLoopRangeQN(lo, hi) end
function av:clearLoopRange()       am:clearLoopRange() end

----- Grid mouse — hit-test, in-flight drag geometry, commit

--contract: returns take, mode='resizeEnd' within DRAG_EDGE_PX of the end edge, else 'move'. nil if no hit.
--contract: end-edge band clamps to half the take so short takes stay movable; qnPerPx scales px→QN.
function av:hitTake(trackIdx, qn, qnPerPx)
  for _, take in ipairs(am:tracksTakes(trackIdx)) do
    local endQN = take.startQN + take.lengthQN
    if qn >= take.startQN and qn < endQN then
      local edgeQN = math.min(DRAG_EDGE_PX * qnPerPx, take.lengthQN / 2)
      return take, (qn >= endQN - edgeQN) and 'resizeEnd' or 'move'
    end
  end
  return nil
end

--contract: returns { startQN, lengthQN, fits }; moved edge snaps to a row box unless snapped=false.
--contract: fits is false iff another take on this track starts at startQN — under the natural-length model, the only forbidden configuration is two takes sharing a start. exceptItem excludes the dragged take itself (or nothing on press.duplicate, where the original stays put).
--contract: move/duplicate ghost length = take.naturalLenQN (the take's full extent, ignoring downstream truncation) so the in-flight preview shows what the take would render to once dropped. Resize ghost length grows/shrinks from the current rendered length.
function av:dragCandidate(press, mouseQN, snapped)
  local take = press.take
  local bpr  = self:beatPerRow()
  local startQN, lengthQN = take.startQN, take.lengthQN
  if press.mode == 'resizeEnd' then
    lengthQN = take.lengthQN + (mouseQN - press.qn)
    if snapped then lengthQN = roundTo(startQN + lengthQN, bpr) - startQN end
    lengthQN = math.max(bpr, lengthQN)
  else
    startQN  = take.startQN + (mouseQN - press.qn)
    if snapped then startQN = roundTo(startQN, bpr) end
    startQN  = math.max(0, startQN)
    lengthQN = take.naturalLenQN
  end
  local exceptItem = press.duplicate and nil or take.item
  return {
    startQN = startQN, lengthQN = lengthQN,
    fits = am:startIsClear(take.trackIdx, startQN, exceptItem),
  }
end

--contract: returns { loQN, hiQN } floored to row boxes unless snapped=false; widens to ≥1 row.
function av:gutterLoopCand(press, mouseQN, snapped)
  local bpr  = self:beatPerRow()
  local loQN = math.max(0, math.min(press.qn, mouseQN))
  local hiQN = math.max(press.qn, mouseQN)
  if snapped then loQN = floorTo(loQN, bpr); hiQN = floorTo(hiQN, bpr) end
  if hiQN <= loQN then hiQN = loQN + bpr end
  return { loQN = loQN, hiQN = hiQN }
end

--contract: returns { startQN=press.qn, lengthQN }; end floors to a row box unless snapped=false; ≥1 row.
function av:createCandidate(press, mouseQN, snapped)
  local bpr   = self:beatPerRow()
  local endQN = math.max(press.qn, mouseQN)
  if snapped then endQN = floorTo(endQN, bpr) end
  return { startQN = press.qn, lengthQN = math.max(bpr, endQN - press.qn) }
end

--contract: move/resize preserves the focus handle; duplicate shifts focus to the new copy. Resize writes natural length — the relayout pass caps the rendered length.
function av:commitDrag(press, cand)
  local label = press.mode == 'resizeEnd' and 'Resize take'
             or press.duplicate          and 'Duplicate take'
             or                              'Move take'
  util.atomic(label, function()
    local take = press.take
    if press.mode == 'resizeEnd' then
      am:resizeTake(take, cand.lengthQN)
    elseif press.duplicate then
      local copy = am:duplicateTake(take, cand.startQN)
      if copy then focus = copy end   -- am hands back a bare take handle
    else
      am:moveTake(take, cand.startQN - take.startQN)
    end
  end)()
end

----- Slot operations — the page's modal commits these

function av:renameSlot(trackIdx, slotIdx, name)
  am:renameSlot(trackIdx, slotIdx, name)
end

--contract: mints a MIDI slot via am, palette-focuses it, dives into it; nil if am refused.
function av:createSlot(trackIdx, qnPos, lengthQN, name)
  local slotIdx, take = am:createAndDropMidi(trackIdx, qnPos, lengthQN, name)
  if slotIdx then
    self:setPaletteSlot(slotIdx)
    onDive(reaper.GetMediaItemTake_Item(take))
  end
  return slotIdx
end

function av:deleteSlot(trackIdx, slotIdx)
  am:deleteSlot(trackIdx, slotIdx)
  self:setPaletteSlot(nil)
end

----- Boot + reveal — the page interface delegates here

--contract: positions cursor on the take wrapping `reaperTake` and focuses it; no-op if not on grid.
function av:revealTake(reaperTake)
  local take = am:findTake(reaperTake)
  if take then
    focus = reaperTake
    self:setCursor(self:qnToRow(take.startQN), take.trackIdx)
  end
end

--contract: seeds cursor/focus from am:initialCursor (first selected take, else edit cursor).
function av:seedCursor()
  local trackIdx, qn = am:initialCursor()
  self:setCursor(self:qnToRow(qn), trackIdx)
  adoptCursor()
end

----------- COMMANDS

-- cmgr:scope is idempotent — page addresses the same scope.
local arrange = cmgr:scope('arrange')

arrange:registerAll {
  arrangeCursorUp     = function() moveCursorBy(-1, 0) end,
  arrangeCursorDown   = function() moveCursorBy( 1, 0) end,
  arrangeCursorLeft   = function() moveCursorBy( 0, -1) end,
  arrangeCursorRight  = function() moveCursorBy( 0,  1) end,
  arrangePageUp       = function() moveCursorBy(-PAGE_ROWS, 0) end,
  arrangePageDown     = function() moveCursorBy( PAGE_ROWS, 0) end,
  arrangeHome         = function() av:setCursor(0, cursorCol) end,
  arrangeEnd          = function() av:setCursor(av:qnToRow(am:projectEndQN()), cursorCol) end,
  arrangeNudgeBack    = { function() nudgeFocused(-1) end, 'Nudge take back'    },
  arrangeNudgeForward = { function() nudgeFocused( 1) end, 'Nudge take forward' },
  arrangeShrinkTake   = { function() resizeFocused(-1) end, 'Shrink take' },
  arrangeGrowTake     = { function() resizeFocused( 1) end, 'Grow take'   },
  arrangeDeleteTake             = { deleteFocused,                  'Delete take' },
  arrangeDeleteAdvance          = { deleteFocusedAndAdvance,        'Delete take and advance' },
  arrangeDive                   = diveFocused,
  arrangeTakeProperties         = focusedTakeProperties,
  arrangeDuplicateBelow         = { duplicateFocusedBelow,          'Duplicate pooled take' },
  arrangeDuplicateUnpooledBelow = { duplicateUnpooledFocusedBelow,  'Duplicate take' },
  arrangeSetLoopStart           = { setLoopStartHere,               'Set loop start at cursor' },
  arrangeSetLoopEnd             = { setLoopEndHere,                 'Set loop end at cursor' },
  arrangePlayFromCursor         = { playFromCursor,                 'Play from cursor' },
  arrangeClearLoop              = { clearLoop,                      'Clear loop range' },
}

-- arrangeAdvanceBy is project-wide and distinct from tracker's take-tier
-- advanceBy, so the two pages don't shadow each other.
for i = 0, 9 do
  arrange:register('arrangeAdvanceBy' .. i,
    function() cm:set('project', 'arrangeAdvanceBy', i) end)
end

local placeCmds = {}
for i = 0, 61 do
  placeCmds['drop' .. am:keyForSlot(i)] = { function() dropAt(i) end, 'Place pooled take' }
end
arrange:registerAll(placeCmds)

return av
