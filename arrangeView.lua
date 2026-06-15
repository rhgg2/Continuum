-- See docs/arrangeView.md for the model.
-- @noindex

--invariant: av owns arrange-page state — cursor, scroll, focus, paletteSlot; arrangePage renders.
--invariant: page builds am and injects it; av owns the ref — all mutations route through av.
--invariant: av speaks no ImGui — modifiers arrive as plain booleans; av works in QN/rows only.
--invariant: cursor/scroll are in-memory module-locals; only beatPerRow persists via cm.
--invariant: cursorRow is integer rows; cursorCol is 0-based track index. qn = row * beatPerRow.
--invariant: gridRows/gridCols set by the page each frame; followViewport runs on every cursor move.
--invariant: av registers arrange-scope command bodies; page owns key bindings and createSlot.
--invariant: focus is a per-session module-local (REAPER take handle). See docs/arrangeView.md.
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

--invariant: cursor-nav steps whole rows/cols; only negative coords clamp. See docs/arrangeView.md.
local function moveCursorBy(dRow, dCol)
  av:setCursor(cursorRow + dRow, cursorCol + dCol)
end

----- Palette navigation — cursor-stepping across tracks/takes
-- Cursor take is source of truth; nav resolves an instance, moves onto its start row. See docs/arrangeView.md § Palette navigation.

local function midiInstances(trackIdx, slotIdx)
  local out = {}
  for _, take in ipairs(am:tracksTakes(trackIdx)) do
    if take.kind == 'midi' and (not slotIdx or take.slotIdx == slotIdx) then
      out[#out + 1] = take
    end
  end
  return out
end

local function midiSlots(trackIdx)
  local out = {}
  for _, slot in ipairs(am:trackSlots(trackIdx)) do
    if slot.kind == 'midi' then out[#out + 1] = slot end
  end
  return out
end

-- dir +1: nearest instance at/after fromQN; dir -1: nearest at/before.
local function nearest(instances, fromQN, dir)
  local best
  for _, take in ipairs(instances) do
    local inDir  = (dir > 0 and take.startQN >= fromQN) or (dir < 0 and take.startQN <= fromQN)
    local closer = not best or (dir > 0 and take.startQN < best.startQN)
                            or (dir < 0 and take.startQN > best.startQN)
    if inDir and closer then best = take end
  end
  return best
end

-- Prefer the travel direction; fall back to the opposite when nothing lies ahead.
local function resolveInstance(instances, fromQN, dir)
  return nearest(instances, fromQN, dir) or nearest(instances, fromQN, -dir)
end

local function gotoInstance(inst)
  if inst then av:setCursor(av:qnToRow(inst.startQN), inst.trackIdx) end
end

-- QN the nav steps from: the cursor take's start, else the bare cursor row.
local function navFromQN()
  local cur = takeAtCursor()
  return cur and cur.startQN or av:rowToQN(cursorRow)
end

----- Take edits — move / resize / delete / dive the focused take

--invariant: nudge steps one row; blocked only when dest start == another take start on the track.
local function nudgeFocused(direction)
  adoptCursor()
  local take = focusedTake()
  if not take then return end
  if am:moveTake(take, direction * av:beatPerRow()) then
    moveCursorBy(direction, 0)
  end
end

--invariant: resize writes natural length (±1 bpr, floored 1 bpr). See docs/arrangeView.md § Resize.
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

--invariant: arrangeDive is MIDI-only; audio/nil focus silently no-ops; dives via switchPage.
local function diveFocused()
  adoptCursor()
  local take = focusedTake()
  if take and take.kind == 'midi' then cmgr:invoke('switchPage', 'tracker') end
end

--invariant: arrangeTakeProperties is MIDI-only; routes the item through the tracker façade.
local function focusedTakeProperties()
  adoptCursor()
  local take = focusedTake()
  if take and take.kind == 'midi' then tracker().openTakeProperties(take.item) end
end

--invariant: duplicateBelow: pooled clone at natural end; focus+cursor advance to copy. MIDI-only.
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

--contract: wheel-driven viewport pan, independent of the cursor; cursor stays put.
--contract: scroll-right stops once the last column is fully visible (maxCol - gridCols + 1).
function av:scrollBy(dRow, dCol)
  scrollRow = math.max(0, scrollRow + dRow)
  local c = math.max(0, scrollCol + dCol)
  if maxCol then c = math.min(c, math.max(0, maxCol - gridCols + 1)) end
  scrollCol = c
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
function av:keyForSlot(slotIdx)   return am:keyForSlot(slotIdx) end
function av:nextFreeSlot(trackIdx) return am:nextFreeSlot(trackIdx) end
function av:editCursorQN()        return am:editCursorQN() end
function av:playPositionQN()      return am:playPositionQN() end
function av:loopRangeQN()         return am:loopRangeQN() end
function av:takesUsing(name)      return am:takesUsing(name) end
function av:reswingAll(name)      return am:reswingAll(name) end

----- Palette navigation — façade-backed cursor stepping

function av:currentTake()      local t = takeAtCursor(); return t and t.take    or nil end
function av:currentSlotIdx()   local t = takeAtCursor(); return t and t.slotIdx or nil end
function av:currentTrackHasTakes() return #midiInstances(cursorCol) > 0 end
function av:midiSlots(trackIdx) return midiSlots(trackIdx) end

--contract: step ±1 track (no skip; may land empty), forward-first resolve onto a take by QN.
function av:gotoTrack(dir)
  self:setMaxCol(#am:projectTracks())
  local track = am:projectTracks()[cursorCol + 1 + dir]
  if not track then return end
  local instances = midiInstances(track.idx)
  if #instances > 0 then
    gotoInstance(resolveInstance(instances, navFromQN(), 1))
  else
    self:setCursor(cursorRow, track.idx)
  end
end

--contract: step ±1 slot on the current track; no-op without a cursor take or its slot.
function av:gotoTake(dir)
  local cur = takeAtCursor(); if not cur or not cur.slotIdx then return end
  local slots = midiSlots(cursorCol)
  local curIdx
  for i, slot in ipairs(slots) do if slot.idx == cur.slotIdx then curIdx = i end end
  local target = curIdx and slots[curIdx + dir]
  if target then gotoInstance(resolveInstance(midiInstances(cursorCol, target.idx), cur.startQN, dir)) end
end

--contract: jump to a track, forward-first resolve from the cursor QN.
function av:pickTrack(trackIdx)
  self:setMaxCol(#am:projectTracks())
  gotoInstance(resolveInstance(midiInstances(trackIdx), navFromQN(), 1))
end

--contract: jump to a slot on the current track, forward-first resolve.
function av:pickTake(slotIdx)
  local cur = takeAtCursor(); if not cur then return end
  gotoInstance(resolveInstance(midiInstances(cursorCol, slotIdx), cur.startQN, 1))
end

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

--contract: returns { startQN, lengthQN, fits }; moved edge snaps to a row box unless snapped=false.
--contract: fits false iff another take starts at startQN; exceptItem excludes the dragged take.
--contract: move/dup ghost = naturalLenQN; resize ghost grows/shrinks from current rendered length.
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

--contract: returns {startQN=press.qn, lengthQN}; end floors to row box if snapped; >=1 row.
function av:createCandidate(press, mouseQN, snapped)
  local bpr   = self:beatPerRow()
  local endQN = math.max(press.qn, mouseQN)
  if snapped then endQN = floorTo(endQN, bpr) end
  return { startQN = press.qn, lengthQN = math.max(bpr, endQN - press.qn) }
end

--contract: move/resize preserves focus; dup shifts focus to new copy. Resize writes natural length.
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
