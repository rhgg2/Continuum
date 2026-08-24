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
--invariant: a Shift+arrow band lasts until the first command that isn't a Shift+arrow.
--invariant: replace mode lasts until the drop it reinterprets, or the first other command.
--invariant: paletteSlot is per-session (0..61 or nil) — palette's highlighted row; not cursorCol.

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
-- The cell a Shift+arrow selection run started from, in cursor coordinates;
-- nil between runs, since every other cursor move or selection drops it.
local selAnchor   = nil  -- { row, col } | nil
local bandArmed   = false   -- the band's spring-loaded scope is on the cmgr stack
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
    if take then util.add(live, take); util.add(kept, handle) end
  end
  selection = kept
  return live
end

local function setSelection(handles)
  local kept = {}
  for _, handle in ipairs(handles or {}) do
    if handle then util.add(kept, handle) end
  end
  selection = kept
  selAnchor = nil
end

local function selectionIndex(handle)
  for i, held in ipairs(selection) do if held == handle then return i end end
end

-- Takes whose span intersects a { colLo, colHi, qnLo, qnHi } rect, in the fractional-column
-- × QN space both selection gestures sweep; a column counts if the rect overlaps its band.
local function takesInRect(rect)
  local takes, set = {}, {}
  for trackIdx = math.max(0, math.floor(rect.colLo)), math.floor(rect.colHi) do
    if trackIdx < rect.colHi and trackIdx + 1 > rect.colLo then
      for _, take in ipairs(am:tracksTakes(trackIdx)) do
        if take.startQN < rect.qnHi and take.startQN + take.lengthQN > rect.qnLo then
          util.add(takes, take.take)
          set[take.take] = true
        end
      end
    end
  end
  return takes, set
end

-- The rect an anchor cell and the cursor cell span: both end cells covered
-- whole, whichever way round the run went.
local function rectFromAnchor(anchor)
  local bpr = av:beatPerRow()
  return { colLo = math.min(anchor.col, cursorCol),
           colHi = math.max(anchor.col, cursorCol) + 1,
           qnLo  =  math.min(anchor.row, cursorRow)      * bpr,
           qnHi  = (math.max(anchor.row, cursorRow) + 1) * bpr }
end

-- While a band is up this spring-loaded scope rides the cmgr stack, so the first
-- command that isn't a Shift+arrow bails it. See docs/arrangeView.md § Keyboard selection.
local selectScope = cmgr:scope('arrangeSelect')
selectScope.springLoaded = true
selectScope.keepAlive    = { arrangeSelectUp   = true, arrangeSelectDown  = true,
                             arrangeSelectLeft = true, arrangeSelectRight = true }

-- Popped only where the scope is known to be on top — cmgr's bail and the page
-- leaving; a click clears the anchor and lets the next command pop what is left.
local function disarmBand()
  selAnchor = nil
  if bandArmed then bandArmed = false; cmgr:pop(selectScope) end
end
selectScope.onBail = disarmBand

--invariant: Shift+arrow moves the cursor and selects the takes the anchor→cursor rect covers.
--invariant: the anchor lasts only a Shift+arrow run; any other cursor move or selection drops it.
local function selectBy(dRow, dCol)
  local anchor = selAnchor or { row = cursorRow, col = cursorCol }
  av:setCursor(cursorRow + dRow, cursorCol + dCol)   -- clamps, and drops the anchor
  setSelection(takesInRect(rectFromAnchor(anchor)))
  selAnchor = anchor   -- re-pinned last: setCursor and setSelection each dropped it
  if not bandArmed then bandArmed = true; cmgr:push(selectScope) end
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

--invariant: bare cursor nav clears the selection; an edit's own cursor move keeps it.
local function navCursorTo(row, col)
  av:setCursor(row, col)
  setSelection {}
end

local function navCursorBy(dRow, dCol)
  navCursorTo(cursorRow + dRow, cursorCol + dCol)
end

-- Every row Tab stops on in a column: each instance's start, and the first free
-- row after it. The set collapses the two where takes abut.
local function stopRows(trackIdx)
  local stops = {}
  for _, take in ipairs(am:tracksTakes(trackIdx)) do
    stops[math.floor(av:qnToRow(take.startQN))] = true
    stops[math.floor(av:qnToRow(take.startQN + take.lengthQN))] = true
  end
  return stops
end

--invariant: drop-seek lands on the nearest stop row past the cursor in its column; the ends hold.
local function seekDrop(dir)
  local best
  for row in pairs(stopRows(cursorCol)) do
    if (row - cursorRow) * dir > 0 and (not best or (row - best) * dir < 0) then best = row end
  end
  if best then navCursorTo(best, cursorCol) end
end

-- MIDI slots on a track — for the tracker's pickers/nav via the arrange facade.
local function midiSlots(trackIdx)
  local out = {}
  for _, slot in ipairs(am:trackSlots(trackIdx)) do
    if slot.kind == 'midi' then util.add(out, slot) end
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

-- The target whose start row the caret stands on, if any. That row is the one
-- place the head is armed, and only that take's move carries the caret along.
local function armedByCursor(takes)
  local cursorQN = av:rowToQN(cursorRow)
  for _, take in ipairs(takes) do
    if math.abs(take.startQN - cursorQN) < 1e-6 then return take end
  end
end

-- The start edge walks and the end holds, so the rendered length moves the other way —
-- floored at one row, since a take that renders nothing is gone from the grid undeleted.
local function moveHeads(takes, armed, direction)
  local bpr, plan = av:beatPerRow(), {}
  for _, take in ipairs(takes) do
    if take.lengthQN - direction * bpr >= bpr then
      util.add(plan, { take = take, headQN = take.startQN - take.originQN + direction * bpr })
    end
  end
  local caretFollows = false
  util.atomic('Trim heads', function()
    for _, p in ipairs(plan) do
      local moved = am:trimHead(p.take, p.headQN)
      if p.take == armed then caretFollows = moved end
    end
  end)()
  if caretFollows then moveCursorBy(direction, 0) end
end

-- Natural is measured from the source origin, so a head rides along and the
-- edge that moves is the end.
local function moveTails(takes, direction)
  local bpr = av:beatPerRow()
  local function renderedAfter(take) return math.max(bpr, take.lengthQN + direction * bpr) end
  util.atomic('Resize takes', function()
    for _, take in ipairs(takes) do
      am:resizeTake(take, take.startQN - take.originQN + renderedAfter(take))
    end
  end)()
  -- A single shrink that ate the cursor's row pulls the cursor back a row, but never onto
  -- the start row (which would arm the head); multi-selection edits leave the cursor alone.
  if #takes == 1 and direction < 0 then
    local take   = takes[1]
    local endRow = (take.startQN + renderedAfter(take)) / bpr
    if cursorRow >= endRow then
      av:setCursor(math.max(take.startQN / bpr + 1, cursorRow - 1), cursorCol)
    end
  end
end

--invariant: caret on a target's start row moves the head, else the tail. See docs/arrangeView.md
--invariant: resize writes natural length (±1 bpr, floored 1 bpr); a head move floors the same way
local function resizeSelected(direction)
  local takes = actionTargets()
  if #takes == 0 then return end
  local armed = armedByCursor(takes)
  if armed then moveHeads(takes, armed, direction)
  else          moveTails(takes, direction) end
end

-- One take, cut where the caret stands. The caret holds, which puts it on the
-- lower half's start row, so the seam just made is the armed edge.
local function splitAtCursor()
  local take = singleTarget()
  if not take then return end
  am:splitTake(take, av:rowToQN(cursorRow))
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
--invariant: a take under the cursor carries the cursor QN over; empty space carries no row
local function diveSelected()
  local tr = am:projectTracks()[cursorCol + 1]
  if not tr then return end
  local cur     = takeAtCursor()
  local slotIdx = cur and cur.kind == 'midi' and cur.slotIdx or nil
  tracker().diveTo(tr.guid, slotIdx, slotIdx and cur.take or nil,
                   slotIdx and av:rowToQN(cursorRow) or nil)
  cmgr:invoke('switchPage', 'tracker')
end

--invariant: arrangeTakeProperties is MIDI-only + single-target; routes via the tracker façade.
local function selectedTakeProperties()
  local take = singleTarget()
  if take and take.kind == 'midi' then tracker().openTakeProperties(take.item) end
end

--invariant: duplicateBelow: single-target clone at append point; caret advances, selection clears.
-- Nothing is selected afterwards, so the caret alone carries a run of presses down the track.
local function duplicateSelectedBelow()
  local take = singleTarget()
  if not take then return end
  local newTake = am:duplicateBelow(take)
  if not newTake then return end
  setSelection {}
  advanceCursorPastNewTake(newTake)
end

--invariant: stepVariant: single-target MIDI; the neighbour stands in source's place, unselected.
-- The source take is gone, so its handle prunes itself from the selection on the next read.
local function stepVariantOfSelected(dir)
  local take = singleTarget()
  if take then am:stepVariant(take, dir) end
end

--invariant: drop0..dropZ place a fresh instance at the cursor and advance the caret past it.
--invariant: arrangeAdvanceBy0..9 (Ctrl+digit) set the step; arrangeAdvanceMode (Ctrl-`) picks it.
--invariant: drop on an empty slot is a no-op; new takes arrive at the slot's full pool length.
--invariant: drop over a take starting at the cursor overwrites it; drops never stack.
local function dropAt(slotIdx)
  local placed = am:dropInstance(cursorCol, slotIdx, av:rowToQN(cursorRow))
  if not placed then return end
  if cm:get('arrangeAdvanceByLength') then
    advanceCursorPastNewTake(placed)
  else
    moveCursorBy(cm:get('arrangeAdvanceBy'), 0)
  end
end

-- The fixed step stands behind the toggle, so Ctrl-` reads back as whatever Ctrl+digit last set.
local function toggleAdvanceByLength()
  cm:set('project', 'arrangeAdvanceByLength', not cm:get('arrangeAdvanceByLength'))
end

local function deleteSelectedAndAdvance()
  deleteSelected()
  moveCursorBy(cm:get('arrangeAdvanceBy'), 0)
end

-- The retreat is measured before the delete, over the takes it spares: the caret
-- lands on a start row that survives the gesture, not the one it stood on.
local function deleteSelectedAndRetreat()
  local takes = actionTargets()
  if #takes == 0 then return end
  local going = {}
  for _, take in ipairs(takes) do going[take.take] = true end
  local best
  for _, take in ipairs(am:tracksTakes(cursorCol)) do
    local row = math.floor(av:qnToRow(take.startQN))
    if not going[take.take] and row < cursorRow and (not best or row > best) then best = row end
  end
  deleteSelected()
  if best then navCursorTo(best, cursorCol) end
end

----- Replace mode — the drop keys, reinterpreted onto the take under the cursor

-- While armed this spring-loaded scope rides the cmgr stack, redirecting every drop key;
-- anything else — a cursor move included — bails it. See docs/arrangeView.md § Replace mode.
local replaceScope = cmgr:scope('arrangeReplace')
replaceScope.springLoaded = true
replaceScope.keepAlive    = { arrangeReplaceMode = true }
local replaceArmed = false

local function disarmReplace()
  if replaceArmed then replaceArmed = false; cmgr:pop(replaceScope) end
end
replaceScope.onBail = disarmReplace

--invariant: arrangeReplaceMode is a toggle — pressing it while armed disarms.
local function toggleReplaceMode()
  if replaceArmed then return disarmReplace() end
  replaceArmed = true
  cmgr:push(replaceScope)
end

-- A shorter replacement can leave the cursor past its end. Pull it back to the last row inside,
-- never down, from a cursor that sat on the take replaced, its end row included.
local function pullCursorInside(replaced, rawTake)
  local take = rawTake and am:findTake(rawTake)
  if not take then return end
  local cursorQN = av:rowToQN(cursorRow)
  if cursorQN < replaced.startQN
     or cursorQN > replaced.startQN + replaced.lengthQN then return end
  local lastRow = math.ceil(av:qnToRow(take.startQN + take.lengthQN)) - 1
  if cursorRow > lastRow then av:setCursor(lastRow, cursorCol) end
end

--invariant: a drop while armed stands the slot in for every action target.
--invariant: each replacement keeps its target's start; each arrives at its own natural length.
--invariant: a held selection passes to the replacements; a cursor-driven replace selects nothing.
--invariant: a lone replacement pulls the cursor in. The drop disarms either way.
-- Nothing clears what a newcomer overlaps — relayout truncates it at the next take's start.
local function replaceAt(slotIdx)
  local held  = #selectedTakes() > 0
  local takes = actionTargets()
  disarmReplace()
  local placed = {}
  for _, take in ipairs(takes) do
    util.add(placed, am:dropInstance(take.trackIdx, slotIdx, take.startQN))
  end
  if #placed == 0 then return end
  if #placed == 1 then pullCursorInside(takes[1], placed[1]) end
  if held then setSelection(placed) end
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

-- Targets like the take verbs do, so a held selection brackets the block it covers.
-- see docs/arrangeView.md § Loop to item
local function loopToTargets()
  local takes = actionTargets()
  if #takes == 0 then return end
  local loQN, hiQN = math.huge, -math.huge
  for _, take in ipairs(takes) do
    loQN = math.min(loQN, take.startQN)
    hiQN = math.max(hiQN, take.startQN + take.lengthQN)
  end
  am:loopTo(loQN, hiQN)
end

----------- PUBLIC

----- View state — cursor, scroll, focus, density

function av:cursorRow()   return cursorRow end
function av:cursorCol()   return cursorCol end
function av:scroll()      return scrollRow, scrollCol end
function av:focus()       return selection[1] end
function av:paletteSlot() return paletteSlot end

--contract: the take shape under the grid cursor; nil over empty space.
function av:cursorTake() return takeAtCursor() end

--contract: the slot index of the take under the grid cursor; nil over empty space.
function av:cursorSlot()
  local take = takeAtCursor()
  return take and take.slotIdx or nil
end

--contract: parks the cursor on the row holding a project QN, in that track's column
-- The tracker speaks QN on the way back from a dive; the row is av's to work out.
function av:setCursorAt(trackIdx, qn) self:setCursor(self:qnToRow(qn), trackIdx) end

--contract: clamps negative coords to 0; clamps cursorCol to maxCol if set; no row upper bound.
function av:setCursor(row, col)
  cursorRow = math.max(0, math.floor(row))
  local c = math.max(0, math.floor(col))
  if maxCol then c = math.min(c, maxCol) end
  cursorCol = c
  selAnchor = nil   -- a bare cursor move ends any Shift+arrow run
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
    if handle and not selectionIndex(handle) then util.add(selection, handle) end
  end
end

--contract: toggleSelected adds the handle if absent, removes it if present.
function av:toggleSelected(handle)
  local i = selectionIndex(handle)
  if i then table.remove(selection, i) else util.add(selection, handle) end
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

--contract: the standing Shift+arrow rect as {colLo,colHi,qnLo,qnHi}; nil when no band is up.
function av:selectBand() return selAnchor and rectFromAnchor(selAnchor) or nil end

--contract: takes the band down and pops its scope; the page calls this on unbind.
function av:dropBand() disarmBand() end

--contract: true while replace mode is armed — the status bar's only reader.
function av:replaceArmed() return replaceArmed end

--contract: disarms replace mode and pops its scope; the page calls this on unbind.
function av:dropReplaceMode() disarmReplace() end

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
  if selAnchor then selAnchor.row = math.floor(selAnchor.row * old / v + 0.5) end
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
function av:mintParkedTake(trackIdx, name, lengthQN, srcTake)
  return am:mintParkedTake(trackIdx, name, lengthQN, srcTake)
end
function av:newTakeBelow(take, name, lengthQN)
  return am:newTakeBelow(take, name, lengthQN)
end
function av:duplicateBelow(take) return am:duplicateBelow(take) end
function av:stepVariant(take, dir) return am:stepVariant(take, dir) end
function av:deleteTake(take)   return am:deleteTake(take) end
function av:isParkedTake(take) return am:isParkedTake(take) end
function av:ownerTrack(take)   return am:ownerTrack(take) end
function av:dropSlot(trackIdx, slotIdx, qnPos) return am:dropInstance(trackIdx, slotIdx, qnPos) end
function av:hasPlacedTakes()   return am:hasPlacedTakes() end
function av:editCursorQN()        return am:editCursorQN() end
function av:playPositionQN()      return am:playPositionQN() end
function av:playFromQN(qn)        return am:playFromQN(qn) end
function av:findTake(take)        return am:findTake(take) end
function av:slotOfTake(take)      return am:slotOfTake(take) end
function av:seekInstance(take, qn, back) return am:seekInstance(take, qn, back) end
function av:loopRangeQN()         return am:loopRangeQN() end
function av:takesUsing(name)      return am:takesUsing(name) end
function av:reswingAll(name)      return am:reswingAll(name) end
function av:tempersInUse()        return am:tempersInUse() end

function av:midiSlots(trackIdx) return midiSlots(trackIdx) end

function av:seedTidy(trackIdx) return am:seedTidy(trackIdx) end

-- The tidy editor's rows, in slot order. See docs/arrangePage.md § The tidy editor.
--shape: tidyRow = { idx, key, name, base?, preview } -- no base means pinned, and preview is then name
function av:tidyRows(trackIdx, assignment)
  local names, rows = am:tidyNames(trackIdx, assignment), {}
  for _, slot in ipairs(midiSlots(trackIdx)) do
    util.add(rows, { idx     = slot.idx,
                     key     = am:keyForSlot(slot.idx),
                     name    = slot.name,
                     base    = assignment[slot.idx],
                     preview = names[slot.idx] })
  end
  return rows
end

-- The base list's own edits, mutating the (bases, assignment) pair the modal holds.
local function trimmed(name) return (name or ''):match('^%s*(.-)%s*$') end
local function baseAt(bases, name)
  for i, base in ipairs(bases) do if base == name then return i end end
end

--contract: appends the trimmed name; a blank one or a name already listed adds nothing
function av:tidyAddBase(bases, name)
  name = trimmed(name)
  if name == '' or baseAt(bases, name) then return end
  util.add(bases, name)
end

--contract: the base's members follow the new name, merging into it if the list holds it
function av:tidyRenameBase(bases, assignment, from, to)
  to = trimmed(to)
  local at = baseAt(bases, from)
  if not at or to == '' or to == from then return end
  table.remove(bases, at)
  if not baseAt(bases, to) then table.insert(bases, at, to) end
  for idx, base in pairs(assignment) do
    if base == from then assignment[idx] = to end
  end
end

--contract: the entry goes and its members leave the assignment, pinning the names they hold
function av:tidyDropBase(bases, assignment, name)
  local at = baseAt(bases, name)
  if not at then return end
  table.remove(bases, at)
  for idx, base in pairs(assignment) do
    if base == name then assignment[idx] = nil end
  end
end

----- Transport — gutter mouse drives the REAPER edit cursor / loop range

function av:setEditCursorQN(qn)    am:setEditCursorQN(qn) end
function av:setLoopRangeQN(lo, hi) am:setLoopRangeQN(lo, hi) end
function av:loopTo(loQN, hiQN)     am:loopTo(loQN, hiQN) end
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
    util.add(ghosts, { take = take, startQN = take.startQN + deltaQN, lengthQN = take.naturalLenQN })
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
  local startQN = take.startQN
  local lengthQN
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
  local rect = { colLo = math.min(press.mcol, mcol), colHi = math.max(press.mcol, mcol),
                 qnLo  = math.min(press.qn,   mqn),  qnHi  = math.max(press.qn,   mqn) }
  rect.takes, rect.set = takesInRect(rect)
  return rect
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
        if copy then util.add(copies, copy) end
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

--contract: mints a MIDI slot via am, palette-focuses it, dives the tracker; nil if am refused.
function av:createSlot(trackIdx, qnPos, lengthQN, name)
  local slotIdx, take = am:createAndDropMidi(trackIdx, qnPos, lengthQN, name)
  if slotIdx then
    self:setPaletteSlot(slotIdx)
    self:setCursor(self:qnToRow(qnPos), trackIdx)
    local tr = am:projectTracks()[trackIdx + 1]
    if tr then tracker().diveTo(tr.guid, slotIdx, take, qnPos) end
    cmgr:invoke('switchPage', 'tracker')
  end
  return slotIdx
end

function av:deleteSlot(trackIdx, slotIdx)
  am:deleteSlot(trackIdx, slotIdx)
  self:setPaletteSlot(nil)
end

--contract: renames in place, so every slot stands and the palette focus holds
function av:tidySlots(trackIdx, assignment) am:tidySlots(trackIdx, assignment) end

--contract: forever-deletes the track's parked slots; drops the palette focus if its slot went too
function av:pruneSlots(trackIdx)
  am:pruneSlots(trackIdx)
  local stands = false
  for _, slot in ipairs(am:trackSlots(trackIdx)) do
    if slot.idx == paletteSlot then stands = true end
  end
  if not stands then self:setPaletteSlot(nil) end
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
  arrangeCursorUp     = function() navCursorBy(-1, 0) end,
  arrangeCursorDown   = function() navCursorBy( 1, 0) end,
  arrangeCursorLeft   = function() navCursorBy( 0, -1) end,
  arrangeCursorRight  = function() navCursorBy( 0,  1) end,
  arrangePageUp       = function() navCursorBy(-PAGE_ROWS, 0) end,
  arrangePageDown     = function() navCursorBy( PAGE_ROWS, 0) end,
  arrangeHome         = function() navCursorTo(0, cursorCol) end,
  arrangeEnd          = function() navCursorTo(av:qnToRow(am:projectEndQN()), cursorCol) end,
  arrangeNextDrop     = function() seekDrop( 1) end,
  arrangePrevDrop     = function() seekDrop(-1) end,
  arrangeSelectUp     = function() selectBy(-1,  0) end,
  arrangeSelectDown   = function() selectBy( 1,  0) end,
  arrangeSelectLeft   = function() selectBy( 0, -1) end,
  arrangeSelectRight  = function() selectBy( 0,  1) end,
  arrangeNudgeBack    = { function() nudgeSelected(-1) end, 'Nudge take back'    },
  arrangeNudgeForward = { function() nudgeSelected( 1) end, 'Nudge take forward' },
  arrangeEdgeUp       = { function() resizeSelected(-1) end, 'Move edge up'   },
  arrangeEdgeDown     = { function() resizeSelected( 1) end, 'Move edge down' },
  arrangeSplit                  = { splitAtCursor,                  'Split take' },
  arrangeDeleteTake             = { deleteSelected,                 'Delete take' },
  arrangeDeleteAdvance          = { deleteSelectedAndAdvance,       'Delete take and advance' },
  arrangeDeleteRetreat          = { deleteSelectedAndRetreat,       'Delete take and retreat' },
  arrangeDive                   = diveSelected,
  arrangeTakeProperties         = selectedTakeProperties,
  arrangeDuplicateBelow         = { duplicateSelectedBelow,         'Duplicate take' },
  arrangePrevVariant            = { function() stepVariantOfSelected(-1) end, 'Previous variant' },
  arrangeNextVariant            = { function() stepVariantOfSelected( 1) end, 'Next variant' },
  arrangeReplaceMode            = toggleReplaceMode,
  arrangeAdvanceMode            = toggleAdvanceByLength,
  arrangeClearSelection         = { function() setSelection {} end, 'Clear selection' },
  arrangeSetLoopStart           = { setLoopStartHere,               'Set loop start at cursor' },
  arrangeSetLoopEnd             = { setLoopEndHere,                 'Set loop end at cursor' },
  arrangeLoopToItem             = loopToTargets,
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

-- One base62 loop mints both readings of a drop key: the place command the arrange scope
-- registers, and the replace body the armed overlay redirects to — with its own undo label.
local placeCmds, replaceCmds = {}, {}
for i = 0, 61 do
  local name = 'drop' .. am:keyForSlot(i)
  placeCmds[name]   = { function() dropAt(i) end, 'Place pooled take' }
  replaceCmds[name] = util.atomic('Replace take', function() replaceAt(i) end)
end
arrange:registerAll(placeCmds)
replaceScope.redirect = replaceCmds

return av
