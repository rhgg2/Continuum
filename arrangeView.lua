-- See docs/arrangeView.md for the model.
-- @noindex

--invariant: av owns arrange-page state — cursor, scroll, selection, paletteSlot; page renders.
--invariant: page builds am and injects it; av owns the ref — all mutations route through av.
--invariant: av speaks no ImGui — modifiers arrive as plain booleans; av works in QN/rows only.
--invariant: cursor/scroll are in-memory module-locals; only beatPerRow persists via cm.
--invariant: cursorRow is integer rows; cursorCol is 0-based track index. qn = row * beatPerRow.
--invariant: gridRows/gridCols set by the page each frame; followViewport runs on every cursor move.
--invariant: av registers arrange-scope command bodies; page owns key bindings and createSlot.
--invariant: selection is a per-session set of take handles; setFocus/focus are single-element.
--invariant: paletteSlot is per-session (0..61 or nil) — palette rename/delete; not cursorCol.

local util = require 'util'

local cm, cmgr, facade, am = (...).cm, (...).cmgr, (...).facade, (...).am

local function tracker() return facade.get('tracker') end

local av = {}

local cursorRow, cursorCol = 0, 0
local scrollRow, scrollCol = 0, 0
local gridRows, gridCols   = 0, 0
-- Upper clamp for cursorCol — the page pushes the live track count each
-- frame. Nil means unbounded (initial frame before the page has drawn).
local maxCol      = nil
local paletteSlot = nil
local selection   = {}   -- ordered set of opaque take handles (the selection)
-- Play-head follow: suspended by a manual wheel-pan, re-armed on the next
-- play-start or transport seek. lastPlayRow drives the seek-discontinuity test.
local followSuspended = false
local lastPlayRow     = nil
local FOLLOW_TOP_LEAD    = 1  -- head lands this many rows below the top after a flip
local FOLLOW_BOTTOM_LEAD = 1  -- flip once the head reaches this many rows from the bottom

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
-- Bottom-edge rule: end-edge row counts as on the take unless another starts there. See docs/arrangeView.md.
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

-- Cursor advance after a fresh take lands: cursorRow += lengthRows.
-- The bottom-edge rule in takeAtCursor means a chained drop still adopts the just-placed take.
local function advanceCursorPastNewTake(rawTake)
  if not rawTake then return end
  local take = am:findTake(rawTake)
  if not take then return end
  local rows = math.max(1, math.floor(take.lengthQN / av:beatPerRow() + 0.5))
  av:setCursor(cursorRow + rows, cursorCol)
end

-- Live takes for the selected handles, in selection order. Self-heals:
-- handles whose take is gone (deleted here or in REAPER) are pruned.
local function selectedTakes()
  local live, kept = {}, {}
  for _, handle in ipairs(selection) do
    local take = am:findTake(handle)
    if take then live[#live + 1] = take; kept[#kept + 1] = handle end
  end
  selection = kept
  return live
end

local function setSelection(handles)
  local kept = {}
  for _, handle in ipairs(handles or {}) do
    if handle then kept[#kept + 1] = handle end
  end
  selection = kept
end

local function selectionIndex(handle)
  for i, held in ipairs(selection) do if held == handle then return i end end
end

-- Wheel-pan moves the viewport without the caret; gridRows/gridCols 0
-- (first frame) means no measured band yet, so the caret counts as on-screen.
local function cursorOnScreen()
  if gridRows == 0 or gridCols == 0 then return true end
  return cursorRow >= scrollRow and cursorRow < scrollRow + gridRows
     and cursorCol >= scrollCol and cursorCol < scrollCol + gridCols
end

-- Edit targets: the selection if held, else the cursor take (unselected)
-- when on-screen. Empty (no-op) when nothing's held and the cursor is off.
local function actionTargets()
  local selected = selectedTakes()
  if #selected > 0 then return selected end
  if not cursorOnScreen() then return {} end
  local take = takeAtCursor()
  return take and { take } or {}
end

local function singleTarget()
  local takes = actionTargets()
  return #takes == 1 and takes[1] or nil
end

--invariant: cursor-nav steps whole rows/cols; only negative coords clamp. See docs/arrangeView.md.
local function moveCursorBy(dRow, dCol)
  av:setCursor(cursorRow + dRow, cursorCol + dCol)
end

-- MIDI slots on a track — for the tracker's pickers/nav via the arrange facade.
local function midiSlots(trackIdx)
  local out = {}
  for _, slot in ipairs(am:trackSlots(trackIdx)) do
    if slot.kind == 'midi' then out[#out + 1] = slot end
  end
  return out
end

----- Take edits — move / resize / delete / dive the action targets
--invariant: edit cmds target via actionTargets; off-screen + nothing selected = no-op.

-- Pre-check group at deltaQN: every destination start must be clear.
-- excludeMembers=true for a move (they vacate); false for a duplicate.
local function groupFits(takes, deltaQN, excludeMembers)
  local mine = {}
  if excludeMembers then for _, take in ipairs(takes) do mine[take.item] = true end end
  for _, take in ipairs(takes) do
    local destQN = take.startQN + deltaQN
    if destQN < 0 then return false end
    for _, other in ipairs(am:tracksTakes(take.trackIdx)) do
      if not mine[other.item] and math.abs(other.startQN - destQN) < 1e-6 then
        return false
      end
    end
  end
  return true
end

-- Apply a uniform shift in travel order so a contiguous block never collides
-- with an as-yet-unmoved member: forward → highest start first, back → lowest.
local function moveTakesBy(takes, deltaQN)
  table.sort(takes, function(lhs, rhs)
    if deltaQN > 0 then return lhs.startQN > rhs.startQN end
    return lhs.startQN < rhs.startQN
  end)
  for _, take in ipairs(takes) do am:moveTake(take, deltaQN) end
end

--invariant: nudge steps one row, all-or-nothing; refused if any selected dest start is occupied.
local function nudgeSelected(direction)
  local takes = actionTargets()
  if #takes == 0 then return end
  local deltaQN = direction * av:beatPerRow()
  if not groupFits(takes, deltaQN, true) then return end
  util.atomic('Nudge takes', function() moveTakesBy(takes, deltaQN) end)()
  if #takes == 1 then moveCursorBy(direction, 0) end
end

--invariant: resize writes natural length (±1 bpr, floored 1 bpr). See docs/arrangeView.md § Resize.
local function resizeSelected(direction)
  local takes = actionTargets()
  if #takes == 0 then return end
  local bpr = av:beatPerRow()
  util.atomic('Resize takes', function()
    for _, take in ipairs(takes) do
      am:resizeTake(take, math.max(bpr, take.lengthQN + direction * bpr))
    end
  end)()
  -- A single shrink that ate the cursor's row pulls the cursor back a row;
  -- multi-selection edits leave the cursor where it is.
  if #takes == 1 and direction < 0 then
    local take   = takes[1]
    local endRow = (take.startQN + math.max(bpr, take.lengthQN + direction * bpr)) / bpr
    if cursorRow >= endRow then moveCursorBy(-1, 0) end
  end
end

local function deleteSelected()
  local takes = actionTargets()
  if #takes == 0 then return end
  util.atomic('Delete takes', function()
    for _, take in ipairs(takes) do am:deleteTake(take) end
  end)()
  setSelection {}
end

--invariant: dive follows the grid cursor: track ← cursor; take ← cursor or else restore
local function diveSelected()
  local tr = am:projectTracks()[cursorCol + 1]
  if not tr then return end
  local cur     = takeAtCursor()
  local slotIdx = cur and cur.kind == 'midi' and cur.slotIdx or nil
  tracker().diveTo(tr.guid, slotIdx)
  cmgr:invoke('switchPage', 'tracker')
end

--invariant: arrangeTakeProperties is MIDI-only + single-target; routes via the tracker façade.
local function selectedTakeProperties()
  local take = singleTarget()
  if take and take.kind == 'midi' then tracker().openTakeProperties(take.item) end
end

--invariant: duplicateBelow: single-target clone at natural end; focus+cursor advance. MIDI-only.
local function duplicateSelectedBelow()
  local take = singleTarget()
  if not take then return end
  local newTake = am:duplicateBelow(take)
  if newTake then
    av:setFocus(newTake)
    advanceCursorPastNewTake(newTake)
  end
end

local function duplicateUnpooledSelectedBelow()
  local take = singleTarget()
  if not take then return end
  local newTake = am:duplicateUnpooledBelow(take)
  if newTake then
    av:setFocus(newTake)
    advanceCursorPastNewTake(newTake)
    tracker().openTakeProperties(reaper.GetMediaItemTake_Item(newTake))
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

local function deleteSelectedAndAdvance()
  deleteSelected()
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
function av:focus()       return selection[1] end
function av:paletteSlot() return paletteSlot end

--contract: clamps negative coords to 0; clamps cursorCol to maxCol if set; no row upper bound.
function av:setCursor(row, col)
  cursorRow = math.max(0, math.floor(row))
  local c = math.max(0, math.floor(col))
  if maxCol then c = math.min(c, maxCol) end
  cursorCol = c
  followViewport()
end

--contract: wheel-driven viewport pan, independent of the cursor; cursor stays put.
--contract: scroll-right stops once the last column is fully visible (maxCol - gridCols + 1).
function av:scrollBy(dRow, dCol)
  followSuspended = true   -- a manual pan suspends play-follow until stop/seek
  scrollRow = math.max(0, scrollRow + dRow)
  local c = math.max(0, scrollCol + dCol)
  if maxCol then c = math.min(c, math.max(0, maxCol - gridCols + 1)) end
  scrollCol = c
end

function av:followsPlay()     return cm:get('arrangeFollowPlay') end
function av:setFollowPlay(on)  cm:set('global', 'arrangeFollowPlay', not not on) end

--contract: no-op unless follow is on and transport runs; boundary-scrolls play head into view.
--contract: a manual scrollBy suspends follow until the next play-start or a transport seek.
function av:followPlay()
  if not cm:get('arrangeFollowPlay') then return end
  local qn = am:playPositionQN()
  if not qn then
    lastPlayRow, followSuspended = nil, false   -- stopped: re-arm for the next play
    return
  end
  local playRow = math.floor(self:qnToRow(qn))
  local started = lastPlayRow == nil
  local seeked  = lastPlayRow and gridRows > 0
                  and (playRow < lastPlayRow or playRow >= lastPlayRow + gridRows)
  if started or seeked then followSuspended = false end
  lastPlayRow = playRow
  if followSuspended or gridRows == 0 then return end
  local bandTop = scrollRow + FOLLOW_TOP_LEAD
  local bandBot = scrollRow + gridRows - 1 - FOLLOW_BOTTOM_LEAD
  if playRow < bandTop or playRow > bandBot then
    scrollRow = math.max(0, playRow - FOLLOW_TOP_LEAD)
  end
end

--contract: setFocus(h) makes {h} the selection (nil clears); focus() returns the first handle.
function av:setFocus(handle) setSelection(handle and { handle } or {}) end

--contract: isSelected(handle) → true iff that handle is currently selected (no liveness check).
function av:isSelected(handle) return selectionIndex(handle) ~= nil end

--contract: addToSelection unions handles in (already-present and nil handles skipped).
function av:addToSelection(handles)
  for _, handle in ipairs(handles or {}) do
    if handle and not selectionIndex(handle) then selection[#selection + 1] = handle end
  end
end

--contract: toggleSelected adds the handle if absent, removes it if present.
function av:toggleSelected(handle)
  local i = selectionIndex(handle)
  if i then table.remove(selection, i) else selection[#selection + 1] = handle end
end

--contract: selectionSet() = {[handle]=true} of live selected takes, for the renderer's highlight.
function av:selectionSet()
  local set = {}
  for _, take in ipairs(selectedTakes()) do set[take.take] = true end
  return set
end

--contract: setSelection replaces the selection with the handle list (nils filtered); [] clears.
function av:setSelection(handles) setSelection(handles) end
function av:clearSelection()      setSelection {} end

--contract: setPaletteSlot(nil) clears; numeric values clamp into 0..61 (the base62 slot range).
function av:setPaletteSlot(idx)
  paletteSlot = idx and math.max(0, math.min(61, math.floor(idx))) or nil
end

function av:beatPerRow() return cm:get('arrangeBeatPerRow') end
--contract: clamps to [1/4, 64]; rescales cursorRow to hold its QN, so zoom anchors on the cursor.
function av:setBeatPerRow(v)
  v = util.clamp(v, 1/4, 64)
  local old = cm:get('arrangeBeatPerRow')
  if v == old then return end
  cursorRow = math.floor(cursorRow * old / v + 0.5)
  cm:set('project', 'arrangeBeatPerRow', v)
  followViewport()
end
function av:qnToRow(qn)  return qn / self:beatPerRow() end
function av:rowToQN(row) return row * self:beatPerRow() end

--contract: page hands over visible cell counts each frame; follows cursor only on resize.
function av:setGridSize(rows, cols)
  local r, c = math.max(0, math.floor(rows)), math.max(0, math.floor(cols))
  if r ~= gridRows or c ~= gridCols then
    gridRows, gridCols = r, c
    followViewport()
  end
end

--contract: page pushes live track count each frame; setCursor clamps cursorCol to it.
function av:setMaxCol(n) maxCol = n and math.max(0, math.floor(n) - 1) or nil end

----- Project data — proxied from am so the page holds no am reference

function av:projectTracks()       return am:projectTracks() end
function av:tracksTakes(trackIdx) return am:tracksTakes(trackIdx) end
function av:columnChanRange(c)    return am:columnChanRange(c) end
function av:visibleTakes(fromCol, toCol, qnLo, qnHi)
  return am:visibleTakes(fromCol, toCol, qnLo, qnHi)
end
function av:trackSlots(trackIdx)  return am:trackSlots(trackIdx) end
function av:takeForSlot(trackIdx, slotIdx) return am:takeForSlot(trackIdx, slotIdx) end
function av:trackIdxForGuid(guid) return am:trackIdxForGuid(guid) end
function av:trackHandle(trackIdx) return am:trackHandle(trackIdx) end
function av:keyForSlot(slotIdx)   return am:keyForSlot(slotIdx) end
function av:nextFreeSlot(trackIdx) return am:nextFreeSlot(trackIdx) end
function av:editCursorQN()        return am:editCursorQN() end
function av:playPositionQN()      return am:playPositionQN() end
function av:loopRangeQN()         return am:loopRangeQN() end
function av:takesUsing(name)      return am:takesUsing(name) end
function av:reswingAll(name)      return am:reswingAll(name) end

function av:midiSlots(trackIdx) return midiSlots(trackIdx) end

--contract: dest for a new take below the cursor take; nil if no cursor take or start unclear.
function av:newTakeBelowParams()
  local cur = takeAtCursor(); if not cur then return nil end
  local destQN = cur.startQN + cur.naturalLenQN
  if not am:startIsClear(cur.trackIdx, destQN) then return nil end
  return { trackIdx = cur.trackIdx, destQN = destQN }
end

--contract: mint a MIDI take at (trackIdx,destQN) and land the cursor on it; nil if am refused.
function av:createTakeBelow(trackIdx, destQN, beats, name)
  local _, newTake = am:createAndDropMidi(trackIdx, destQN, beats, name)
  if newTake then self:setCursor(self:qnToRow(destQN), trackIdx) end
  return newTake
end

----- Transport — gutter mouse drives the REAPER edit cursor / loop range

function av:setEditCursorQN(qn)    am:setEditCursorQN(qn) end
function av:setLoopRangeQN(lo, hi) am:setLoopRangeQN(lo, hi) end
function av:clearLoopRange()       am:clearLoopRange() end

----- Grid mouse — hit-test, in-flight drag geometry, commit

--contract: returns take, mode='resizeEnd' within DRAG_EDGE_PX of end, else 'move'; nil if no hit.
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

-- Group drag: one deltaQN from the grabbed take's snapped destination, applied
-- to every member. fits excludes members on move (they vacate), not on dup.
local function groupDragCandidate(press, mouseQN, snapped)
  local takes   = selectedTakes()
  local bpr     = av:beatPerRow()
  local deltaQN = mouseQN - press.qn
  if snapped then deltaQN = roundTo(press.take.startQN + deltaQN, bpr) - press.take.startQN end
  local minStart = math.huge
  for _, take in ipairs(takes) do minStart = math.min(minStart, take.startQN) end
  deltaQN = math.max(deltaQN, -minStart)   -- clamp so the earliest member stays ≥ 0
  local ghosts = {}
  for _, take in ipairs(takes) do
    ghosts[#ghosts + 1] =
      { take = take, startQN = take.startQN + deltaQN, lengthQN = take.naturalLenQN }
  end
  return { ghosts = ghosts, deltaQN = deltaQN,
           fits = groupFits(takes, deltaQN, not press.duplicate) }
end

--contract: returns { ghosts={{take,startQN,lengthQN},…}, fits }; one ghost per selected member.
--contract: fits false iff any ghost's destination start is occupied.
--contract: move/dup ghost = naturalLenQN; resize ghost grows/shrinks from current rendered length.
function av:dragCandidate(press, mouseQN, snapped)
  if press.group then return groupDragCandidate(press, mouseQN, snapped) end
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
    ghosts = { { take = take, startQN = startQN, lengthQN = lengthQN } },
    fits   = am:startIsClear(take.trackIdx, startQN, exceptItem),
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

--contract: returns {startQN=press.qn, lengthQN}; end floors to row box if snapped; >=1 row.
function av:createCandidate(press, mouseQN, snapped)
  local bpr   = self:beatPerRow()
  local endQN = math.max(press.qn, mouseQN)
  if snapped then endQN = floorTo(endQN, bpr) end
  return { startQN = press.qn, lengthQN = math.max(bpr, endQN - press.qn) }
end

--contract: takes intersecting the free press/drag rect (colFrac x QN); returns bounds + handles.
function av:lassoCandidate(press, mcol, mqn)
  local colLo, colHi = math.min(press.mcol, mcol), math.max(press.mcol, mcol)
  local qnLo,  qnHi  = math.min(press.qn,   mqn),  math.max(press.qn,   mqn)
  local takes, set = {}, {}
  for trackIdx = math.max(0, math.floor(colLo)), math.floor(colHi) do
    if trackIdx < colHi and trackIdx + 1 > colLo then
      for _, take in ipairs(am:tracksTakes(trackIdx)) do
        if take.startQN < qnHi and take.startQN + take.lengthQN > qnLo then
          takes[#takes + 1] = take.take
          set[take.take]    = true
        end
      end
    end
  end
  return { colLo = colLo, colHi = colHi, qnLo = qnLo, qnHi = qnHi,
           takes = takes, set = set }
end

-- Commit a group drag: move all members by deltaQN (travel-ordered) or
-- duplicate each at its shifted start and reselect the copies.
local function commitGroupDrag(press, cand)
  local takes = selectedTakes()
  if press.duplicate then
    util.atomic('Duplicate takes', function()
      local copies = {}
      for _, take in ipairs(takes) do
        local copy = am:duplicateTake(take, take.startQN + cand.deltaQN)
        if copy then copies[#copies + 1] = copy end
      end
      setSelection(copies)
    end)()
  else
    util.atomic('Move takes', function() moveTakesBy(takes, cand.deltaQN) end)()
  end
end

--contract: group drag moves/dups the whole selection; single drag keeps focus, dup reselects copy.
function av:commitDrag(press, cand)
  if press.group then return commitGroupDrag(press, cand) end
  local take  = press.take
  local ghost = cand.ghosts[1]
  local label = press.mode == 'resizeEnd' and 'Resize take'
             or press.duplicate          and 'Duplicate take'
             or                              'Move take'
  util.atomic(label, function()
    if press.mode == 'resizeEnd' then
      am:resizeTake(take, ghost.lengthQN)
    elseif press.duplicate then
      local copy = am:duplicateTake(take, ghost.startQN)
      if copy then setSelection { copy } end   -- am hands back a bare take handle
    else
      am:moveTake(take, ghost.startQN - take.startQN)
    end
  end)()
end

----- Slot operations — the page's modal commits these

function av:renameSlot(trackIdx, slotIdx, name)
  am:renameSlot(trackIdx, slotIdx, name)
end

--contract: mints a MIDI slot via am, palette-focuses it, dives into it; nil if am refused.
function av:createSlot(trackIdx, qnPos, lengthQN, name)
  local slotIdx = am:createAndDropMidi(trackIdx, qnPos, lengthQN, name)
  if slotIdx then
    self:setPaletteSlot(slotIdx)
    self:setCursor(self:qnToRow(qnPos), trackIdx)
    cmgr:invoke('switchPage', 'tracker')
  end
  return slotIdx
end

function av:deleteSlot(trackIdx, slotIdx)
  am:deleteSlot(trackIdx, slotIdx)
  self:setPaletteSlot(nil)
end

----- Boot + reveal — the page interface delegates here

--contract: seeds the cursor from am:initialCursor (selected take, else edit cursor); no selection.
function av:seedCursor()
  local trackIdx, qn = am:initialCursor()
  self:setCursor(self:qnToRow(qn), trackIdx)
  setSelection {}
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
  arrangeNudgeBack    = { function() nudgeSelected(-1) end, 'Nudge take back'    },
  arrangeNudgeForward = { function() nudgeSelected( 1) end, 'Nudge take forward' },
  arrangeShrinkTake   = { function() resizeSelected(-1) end, 'Shrink take' },
  arrangeGrowTake     = { function() resizeSelected( 1) end, 'Grow take'   },
  arrangeDeleteTake             = { deleteSelected,                 'Delete take' },
  arrangeDeleteAdvance          = { deleteSelectedAndAdvance,       'Delete take and advance' },
  arrangeDive                   = diveSelected,
  arrangeTakeProperties         = selectedTakeProperties,
  arrangeDuplicateBelow         = { duplicateSelectedBelow,         'Duplicate pooled take' },
  arrangeDuplicateUnpooledBelow = { duplicateUnpooledSelectedBelow, 'Duplicate take' },
  arrangeClearSelection         = { function() setSelection {} end, 'Clear selection' },
  arrangeSetLoopStart           = { setLoopStartHere,               'Set loop start at cursor' },
  arrangeSetLoopEnd             = { setLoopEndHere,                 'Set loop end at cursor' },
  arrangePlayFromCursor         = { playFromCursor,                 'Play from cursor' },
  arrangeClearLoop              = { clearLoop,                      'Clear loop range' },
  arrangeZoomIn                 = { function() av:setBeatPerRow(av:beatPerRow() / 2) end, 'Zoom in (halve beats/row)'  },
  arrangeZoomOut                = { function() av:setBeatPerRow(av:beatPerRow() * 2) end, 'Zoom out (double beats/row)' },
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
