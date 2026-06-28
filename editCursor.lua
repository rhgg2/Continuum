-- See docs/editCursor.md for the model.

--invariant: cursor (row, col, stop); stop indexes col.stopPos (char-offset), not parts
--invariant: cursorRow is 0-indexed; cursorCol/cursorStop are 1-indexed (Lua-array)
--invariant: ec owns caret/selection/clipboard; no MIDI state — mutations go via tm/cm
--invariant: selection = anchor (fixed) + cursor (moving); sel is the resolved rect
--invariant: sel == nil iff no selection
--invariant: region()'s cursor-degenerate fallback is callsite policy, not stored
--invariant: hBlockScope ∈ {0=free, 1=col, 2=channel, 3=all-cols}
--invariant: vBlockScope ∈ {0=free, 1=beat, 2=bar×vBlockBars, 3=all-rows}; scopes are orthogonal
--invariant: sticky == any nonzero scope; moves under sticky update sel, never clear
--invariant: hBlock=2/3 use part1=part2='*'; selectionStopSpan falls through to whole-col
--invariant: parts within a col order by col.partStart, not stop (parts may be multi-stop)
--invariant: moveHook fires after every position change (paired with clampPos)
--shape: selection = { row1, row2, col1, col2, part1, part2 }  -- inclusive both axes
--invariant: sel.part1/part2 are part names, or '*' sentinel under hBlock=2/3
--shape: selAnchor = { row, col, stop }  -- fixed end of an active selection
--shape: clip.single = { mode='single', type, numRows, events=[clipEvent,...] }
--invariant: clip.single.type ∈ {'note', '7bit', 'pb'}
--shape: clip.multi  = { mode='multi', numRows, startType, cols=[clipColEntry,...] }
--shape: clipColEntry = { type, chanDelta, key, events=[clipEvent,...] }
--invariant: clipColEntry.key: note→lane-pos, cc→cc#, nil for singletons
--shape: clipEvent = source-event minus CLIP_RESERVED, plus { row, [endRow] }
--invariant: clipEvent.row is 0-relative to clip top
local util = require 'util'

local deps = ...

---------- PRIVATE

local grid        = deps.grid
local cm          = deps.cm
local cmgr        = deps.cmgr
local getRPBar    = deps.rowPerBar
local logPerRow   = deps.logPerRow   or function () return 1 end
local moveHook    = deps.moveHook    or function () end
local groupBridge = deps.groupBridge

local cursorRow, cursorCol, cursorStop = 0, 1, 1
local hBlockScope, vBlockScope         = 0, 0
local vBlockBars                       = 1   -- bars spanned when vBlockScope == 2
local sel, selAnchor

-- Group authoring overlay (spring-loaded cmgr scope). ec owns push/pop + ephemeral nav cursor
-- (NOT persisted); group store, projection, and persistence are gm's.
local regionCursor                       -- { groupId, instId } | nil
local regionScope, regionPushed

----- Position

--contract: clamps to grid extents; idempotent; stop is bound to the current col's stopPos
--invariant: col-changes must precede stop reads (stop is clamped against the current col)
local function clampPos()
  local maxRow = math.max(0, (grid.numRows or 1) - 1)
  cursorRow = util.clamp(cursorRow, 0, maxRow)
  cursorCol  = util.clamp(cursorCol, 1, #grid.cols)
  cursorStop = util.clamp(cursorStop, 1, #grid.cols[cursorCol].stopPos)
end

----- Parts

local function partAt(col, stop)
  local c = grid.cols[col]
  return c and c.partAt and c.partAt[stop] or 'val'
end

local function cursorPart() return partAt(cursorCol, cursorStop) end

--contract: returns first stop whose partAt name matches; caret lands on part-leading char
local function firstStopForPart(col, part)
  local c = grid.cols[col]
  if not c then return 1 end
  for s, name in ipairs(c.partAt) do
    if name == part then return s end
  end
  return 1
end

----- Selection

local function isSticky() return hBlockScope > 0 or vBlockScope > 0 end

--contract: pins anchor at cursor and produces a 1x1 sel; precondition for selUpdate
local function selStart()
  selAnchor = { row = cursorRow, col = cursorCol, stop = cursorStop }
  local p = cursorPart()
  sel = { row1 = cursorRow, row2 = cursorRow, col1 = cursorCol, col2 = cursorCol, part1 = p, part2 = p }
end

--contract: recomputes sel from anchor + cursor + scopes; no-op if selAnchor is nil
--invariant: vBlock=1/2 snap rows to beat/bar; hBlock=2/3 expand cols to channel/all
local function selUpdate()
  local a = selAnchor
  if not a then return end
  local numRows = grid.numRows or 1

  local r1, r2
  if vBlockScope == 1 or vBlockScope == 2 then
    local unit = vBlockScope == 1 and cm:get('rowPerBeat') or getRPBar()
    local bars = vBlockScope == 2 and vBlockBars or 1
    r1 = math.floor(cursorRow / unit) * unit
    r2 = math.min(r1 + bars * unit - 1, numRows - 1)
  elseif vBlockScope == 3 then
    r1, r2 = 0, numRows - 1
  else
    r1, r2 = a.row, cursorRow
    if r1 > r2 then r1, r2 = r2, r1 end
  end

  local c1, c2, p1, p2
  if hBlockScope == 2 then
    local chan = grid.cols[cursorCol].midiChan
    c1, c2 = grid.chanFirstCol[chan], grid.chanLastCol[chan]
    p1, p2 = '*', '*'
  elseif hBlockScope == 3 then
    c1, c2 = 1, #grid.cols
    p1, p2 = '*', '*'
  else
    c1, c2 = a.col, cursorCol
    p1, p2 = partAt(a.col, a.stop), cursorPart()
    if c1 > c2 then c1, c2, p1, p2 = c2, c1, p2, p1
    elseif c1 == c2 then
      -- normalise so p1 is at-or-before p2 (lower partStart = earlier part)
      local col = grid.cols[c1]
      if col and col.partStart[a.stop] > col.partStart[cursorStop] then
        p1, p2 = p2, p1
      end
    end
  end
  sel = { row1 = r1, row2 = r2, col1 = c1, col2 = c2, part1 = p1, part2 = p2 }
end

--contract: drops sel + anchor + sticky scopes; the only sticky-clear besides unstick()
local function selClear()
  sel = nil; selAnchor = nil
  hBlockScope = 0; vBlockScope = 0
end

--contract: seeds anchor on first engage; cycles channel→all-cols→col
local function cycleHBlock()
  if not isSticky() then
    selAnchor = { row = cursorRow, col = cursorCol, stop = cursorStop }
  end
  if hBlockScope == 2 then
    hBlockScope = 3   -- channel → all columns
  elseif hBlockScope == 3 then
    hBlockScope = 1   -- all columns → single column
  else
    hBlockScope = 2   -- free/col → channel
  end
  selUpdate()
end

--contract: seeds anchor on first engage; beat→bar, each press grows by a bar; no-op on empty grid
local function cycleVBlock()
  if (grid.numRows or 0) == 0 then return end
  if not isSticky() then
    selAnchor = { row = cursorRow, col = cursorCol, stop = cursorStop }
  end
  if vBlockScope == 1 then
    vBlockScope, vBlockBars = 2, 1   -- beat → one bar
  elseif vBlockScope == 2 then
    vBlockBars = vBlockBars + 1      -- grow by a bar
  else
    vBlockScope = 1                  -- free/all-rows → beat
  end
  selUpdate()
end

--contract: swaps anchor↔cursor on scope-unlocked axes; no-op without a selection
--invariant: swapEnds: vBlock<1 swaps row; hBlock<2 swaps col+stop
local function swapEnds()
  if not (sel and selAnchor) then return end
  if vBlockScope < 1 then
    selAnchor.row, cursorRow = cursorRow, selAnchor.row
  end
  if hBlockScope < 2 then
    selAnchor.col,  cursorCol  = cursorCol,  selAnchor.col
    selAnchor.stop, cursorStop = cursorStop, selAnchor.stop
  end
  clampPos(); moveHook()
  selUpdate()
end

----- Movement

--contract: selecting or sticky extends sel; else clears; clamps top/bottom, no wrap
local function moveRow(n, selecting)
  if selecting or isSticky() then
    if not sel then selStart() end
  else selClear() end
  cursorRow = cursorRow + n
  clampPos(); moveHook()
  if selecting or isSticky() then selUpdate() end
end

--contract: walks stops within col, crossing into the adjacent col at the boundary
--contract: no wrap at first/last col; hBlock≥2 collapses scope to 1 and re-anchors
local function moveStop(n, selecting)
  if selecting or isSticky() then
    if not sel then selStart() end
  else selClear() end
  if hBlockScope >= 2 and selAnchor then
    selAnchor.col  = cursorCol
    selAnchor.stop = cursorStop
    hBlockScope    = 1
  end
  local dir = n > 0 and 1 or -1
  for _ = 1, math.abs(n) do
    local s = cursorStop + dir
    if s > #grid.cols[cursorCol].stopPos then
      if cursorCol >= #grid.cols then break end
      cursorCol  = cursorCol + 1
      cursorStop = 1
    elseif s < 1 then
      if cursorCol <= 1 then break end
      cursorCol  = cursorCol - 1
      cursorStop = #grid.cols[cursorCol].stopPos
    else
      cursorStop = s
    end
  end
  clampPos(); moveHook()
  if selecting or isSticky() then selUpdate() end
end

local moveCol, moveChannel do
  local function moveUnit(n, toFirstStop, toLastStop)
    if not isSticky() then selClear() end
    local sgn  = n > 0 and 1 or -1
    local land = sgn > 0 and toLastStop or toFirstStop

    if isSticky() then
      for _ = 1, math.abs(n) do
        local extending = (sgn > 0 and cursorCol >= selAnchor.col)
                       or (sgn < 0 and cursorCol <= selAnchor.col)
        if extending then moveStop(sgn); land()
        else              land();        moveStop(sgn) end
      end
    else
      for _ = 1, math.abs(n) do
        if sgn > 0 then toLastStop();  moveStop(1)
        else            toFirstStop(); moveStop(-1); toFirstStop()
        end
      end
    end
    if isSticky() then selUpdate() end
  end

  --contract: jumps one col, landing on first/last stop; sticky extends/contracts 1 col
  function moveCol(n)
    moveUnit(n,
      function()
        cursorStop = 1
        if isSticky() and cursorCol == selAnchor.col and #grid.cols[cursorCol].parts == 1 then
          moveStop(1)
          cursorStop = #grid.cols[cursorCol].stopPos
        end
      end,
      function()
        cursorStop = #grid.cols[cursorCol].stopPos
        if isSticky() and cursorCol == selAnchor.col and #grid.cols[cursorCol].parts == 1 then
          moveStop(1)
          cursorStop = #grid.cols[cursorCol].stopPos
        end
    end)
  end

  --contract: jumps one channel; non-sticky lands on first note col (skipping pc/pb)
  --contract: sticky preserves the raw chan-edge land
  function moveChannel(n)
    local function chanRange()
      local chan = grid.cols[cursorCol].midiChan
      return grid.chanFirstCol[chan], grid.chanLastCol[chan]
    end
    moveUnit(n,
      function()
        local first, _ = chanRange()
        cursorCol, cursorStop = first, 1
      end,
      function()
        local _, last = chanRange()
        cursorCol  = last
        cursorStop = #grid.cols[cursorCol].stopPos
      end)
    -- pc/pb sit left of the note column, so the raw scroll lands on pc.
    -- Snap forward to the first note column of the landing channel.
    if not isSticky() then
      local first, last = chanRange()
      for ci = first, last do
        if grid.cols[ci].type == 'note' then
          cursorCol, cursorStop = ci, 1
          break
        end
      end
    end
  end
end

----- Regions (group authoring mode)

-- All group geometry/persistence is gm's, reached through the bridge
-- (trackerView's grid<->logical surface). ec never touches gm directly.
local function gmgr() return groupBridge and groupBridge.gm end

-- gm:eachInstance iterates pairs(); sort to a stable (groupId, instId)
-- order so next/prev cycle deterministically.
local function orderedInstances()
  local gm = gmgr(); if not gm then return {} end
  local list = gm:eachInstance()
  table.sort(list, function(a, b)
    if a.groupId ~= b.groupId then return a.groupId < b.groupId end
    return a.instId < b.instId
  end)
  return list
end

local function cursorIndex(list)
  if not regionCursor then return end
  for i, e in ipairs(list) do
    if e.groupId == regionCursor.groupId
       and e.instId == regionCursor.instId then return i end
  end
end

local function currentEntry()
  for _, e in ipairs(orderedInstances()) do
    if regionCursor and e.groupId == regionCursor.groupId
       and e.instId == regionCursor.instId then return e end
  end
end

---------- PUBLIC

local ec = {}

----- Position

function ec:row()           return cursorRow  end
function ec:col()           return cursorCol  end
function ec:pos()           return cursorRow, cursorCol, cursorStop end

--contract: nil arg leaves that axis untouched; clamps and fires moveHook unconditionally
function ec:setPos(row, col, stop)
  if row  then cursorRow  = row  end
  if col  then cursorCol  = col  end
  if stop then cursorStop = stop end
  clampPos(); moveHook()
end

function ec:clampPos()      clampPos() end

--contract: scales cursorRow by newRPB/oldRPB so caret stays at the same musical time
function ec:rescaleRow(oldRPB, newRPB)
  cursorRow = math.floor(cursorRow * newRPB / oldRPB)
end

function ec:reset()
  cursorRow, cursorCol, cursorStop = 0, 1, 1
  selClear()
  regionCursor = nil
end

----- Part & Region

function ec:cursorPart()    return cursorPart() end
function ec:hasSelection()  return sel ~= nil end
function ec:isSticky()      return isSticky() end
function ec:anchorRow()     return selAnchor and selAnchor.row end

function ec:region()
  if sel then
    return sel.row1, sel.row2, sel.col1, sel.col2, sel.part1, sel.part2
  end
  local p = cursorPart()
  return cursorRow, cursorRow, cursorCol, cursorCol, p, p
end

-- Pair so callers can splat: `ec:setPos(row, ec:regionStart())`.
function ec:regionStart()
  if not sel then return cursorCol, cursorStop end
  return sel.col1, firstStopForPart(sel.col1, sel.part1)
end

function ec:eachSelectedCol()
  if not sel then
    local col, ci = grid.cols[cursorCol], cursorCol
    local done = col == nil
    return function()
      if done then return end
      done = true
      return col, ci
    end
  end
  local ci = sel.col1 - 1
  return function()
    ci = ci + 1
    while ci <= sel.col2 do
      local col = grid.cols[ci]
      if col then return col, ci end
      ci = ci + 1
    end
  end
end

--contract: installs sel from part record; clears sticky; anchor at top-left part-start
function ec:setSelection(r)
  sel = { row1 = r.row1, row2 = r.row2, col1 = r.col1, col2 = r.col2,
          part1 = r.part1, part2 = r.part2 }
  selAnchor = { row = r.row1, col = r.col1, stop = firstStopForPart(r.col1, r.part1) }
  hBlockScope, vBlockScope = 0, 0
end

function ec:selectionStopSpan(col)
  if not sel then return nil end
  local c = grid.cols[col]
  if not c then return nil end
  local s1, s2 = 1, #c.stopPos
  if col == sel.col1 then
    for s, name in ipairs(c.partAt) do
      if name == sel.part1 then s1 = s; break end
    end
  end
  if col == sel.col2 then
    for s = #c.partAt, 1, -1 do
      if c.partAt[s] == sel.part2 then s2 = s; break end
    end
  end
  return s1, s2
end

function ec:selClear()  selClear()  end
function ec:unstick()   hBlockScope, vBlockScope = 0, 0 end

-- Mouse shift-click and drag both speak this verb.
function ec:extendTo(row, col, stop)
  if not sel then selStart() end
  self:setPos(row, col, stop)
  selUpdate()
end

--contract: shifts sel rows + anchor + cursor by rowDelta; each axis clamped independently
--invariant: shiftSelection: sel may compress against an edge while cursor doesn't
function ec:shiftSelection(rowDelta)
  local maxRow = grid.numRows - 1
  sel.row1      = util.clamp(sel.row1      + rowDelta, 0, maxRow)
  sel.row2      = util.clamp(sel.row2      + rowDelta, 0, maxRow)
  selAnchor.row = util.clamp(selAnchor.row + rowDelta, 0, maxRow)
  cursorRow     = cursorRow + rowDelta
  clampPos(); moveHook()
end

----- Motion

--contract: advances by cm.advanceBy rows; the per-keystroke auto-step after a write
function ec:advance() moveRow(cm:get('advanceBy')) end

do
  local function selectSpan(scope, col, stop1, stop2)
    cursorCol, cursorStop = col, stop2
    selAnchor = { row = cursorRow, col = col, stop = stop1 }
    hBlockScope, vBlockScope = scope, 3
    selUpdate()
  end

  function ec:selectChannel(chan)
    local first = grid.chanFirstCol[chan]
    if first then selectSpan(2, first, 1, 1) end
  end

  function ec:selectColumn(col)
    local c = grid.cols[col]
    if c then selectSpan(1, col, 1, #c.stopPos) end
  end
end

----- Region mode (group authoring)

function ec:isInRegionMode() return regionPushed == true end
function ec:regionCursor()   return regionCursor end

-- Nav keeps the overlay armed (caret may roam before stamping);
-- every other command bails via onBail (execute-through).
local REGION_KEEPALIVE = {
  cursorUp=true, cursorDown=true, cursorLeft=true, cursorRight=true,
  pageUp=true, pageDown=true, goTop=true, goBottom=true, goLeft=true, goRight=true,
  colLeft=true, colRight=true, channelLeft=true, channelRight=true,
  selectUp=true, selectDown=true, selectLeft=true, selectRight=true, selectClear=true,
  cycleBlock=true, cycleVBlock=true, swapBlockEnds=true,
  regionArm=true,   -- re-pressing \ re-arms at the caret without a bail
}

do
  local function exitMode()
    cmgr:pop(regionScope)
    regionPushed = false
    regionCursor = nil
  end

  local function enterArmed()
    if regionPushed then return end
    cmgr:push(regionScope)
    regionPushed = true
  end

  local function newFromSelection()
    local rect = groupBridge.selectionAsRect()
    if not rect then return end
    local groupId = gmgr():mark(groupBridge.eventsInRect(rect), rect)
    if not groupId then return end
    regionCursor = { groupId = groupId, instId = 1 }
    selClear()
    if groupBridge.commit then groupBridge.commit() end
  end

  -- Clear before staging (gm re-places its own concretes only); stamp a fresh
  -- instance, advance the border. Shared by paste-at-caret and cascade-duplicate.
  local function stampAt(anchor)
    if not (regionCursor and anchor) then return end
    if groupBridge.clearAt then groupBridge.clearAt(regionCursor.groupId, anchor) end
    local instId = gmgr():newInstance(regionCursor.groupId, anchor)
    if instId then regionCursor.instId = instId end
    if groupBridge.commit then groupBridge.commit() end
  end

  local function newInstance() stampAt(groupBridge.cursorAnchor()) end

  -- Cascade: the copy lands one group-length past the armed instance and
  -- the border advances onto it, so repeats lay a run hands-free.
  local function duplicate()
    local cur  = currentEntry()
    local rect = cur and gmgr():groupRect(regionCursor.groupId)
    if not rect then return end
    stampAt({ ppq = cur.anchor.ppq + rect.dur, chan = cur.anchor.chan })
  end

  local function dropInstance()
    if not regionCursor then return end
    local idx = cursorIndex(orderedInstances()) or 1
    gmgr():deleteInstance(regionCursor.groupId, regionCursor.instId)
    local after = orderedInstances()
    local pick  = after[math.min(idx, #after)]
    regionCursor = pick and { groupId = pick.groupId, instId = pick.instId }
                        or nil
  end

  local function moveBy(rowDelta)
    local cur = currentEntry()
    if not cur then return end
    local anchor = { ppq  = cur.anchor.ppq + rowDelta * logPerRow(),
                     chan = cur.anchor.chan }
    if gmgr():moveInstance(regionCursor.groupId, regionCursor.instId, anchor) then
      cursorRow = cursorRow + rowDelta
      clampPos(); moveHook()
    end
  end

  local function resizeBy(edits)
    if not regionCursor then return end
    gmgr():resizeGroup(regionCursor.groupId, regionCursor.instId, edits)
  end

  local function paintCell(on)
    if not regionCursor then return end
    groupBridge.paintStream(regionCursor.groupId, regionCursor.instId,
                            cursorCol, on)
  end

  -- DWIM: a selection seeds a new group; else arm the caret's instance; else nothing.
  -- enterArmed is idempotent: a re-press just re-points the border at the caret.
  function ec:regionArm()
    if sel then
      newFromSelection()
      if regionCursor then enterArmed() end
      return
    end
    local at = groupBridge.instanceAt and groupBridge.instanceAt()
    if not at then return end
    regionCursor = { groupId = at.groupId, instId = at.instId }
    enterArmed()
  end

  -- Leave armed mode without touching the selection (Esc/Enter/note-key execute-through).
  -- regionBail (Super-G) also clears the selection.
  function ec:regionExit() exitMode() end

  -- Built once at instantiate; trackerPage binds keys later. Redirect, keepAlive, and onBail
  -- implement spring-loaded dispatch — see docs/commandManager.md § Spring-loaded scope.
  if cmgr then
    regionScope = cmgr:scope('region')
    regionScope.springLoaded = true
    regionScope.keepAlive    = REGION_KEEPALIVE
    regionScope.onBail       = exitMode
    regionScope.redirect = {
      paste         = newInstance,  groupPaste     = newInstance,
      duplicateDown = duplicate,    groupDuplicate = duplicate,
      delete        = dropInstance, deleteSel      = dropInstance,
      nudgeBack     = function(p) moveBy(-p) end,
      nudgeForward  = function(p) moveBy( p) end,
      growNote      = function(p) resizeBy{ endDelta =  p * logPerRow() } end,
      shrinkNote    = function(p) resizeBy{ endDelta = -p * logPerRow() } end,
    }
    regionScope:registerAll{
      regionExit        = function() ec:regionExit() end,
      regionBail        = function() exitMode(); selClear() end,
      regionPaintExtend = function() paintCell(true)  end,
      regionPaintShrink = function() paintCell(false) end,
    }
  end
end

----- Group-instance hop (editing mode)

-- [ / ] in normal editing jump the caret to the same row offset in the
-- prev/next instance of the group it sits inside. Column is left as-is:
-- "same place" is the relative row; chasing the stream across instances
-- on different channels would be a non-linear column remap, out of scope
-- for this verb. The border feedback is the rendering layer's.
local function hopInstance(step)
  local gm = gmgr(); if not gm then return end
  local at = groupBridge and groupBridge.instanceAt and groupBridge.instanceAt()
  if not at then return end
  local sibs = {}
  for _, e in ipairs(gm:eachInstance()) do
    if e.groupId == at.groupId then sibs[#sibs + 1] = e end
  end
  table.sort(sibs, function(a, b) return a.anchor.ppq < b.anchor.ppq end)
  local i
  for k, e in ipairs(sibs) do if e.instId == at.instId then i = k end end
  local cur, dest = i and sibs[i], i and sibs[i + step]
  if not dest then return end
  local lpr = logPerRow()
  cursorRow = cursorRow
            - math.floor(cur.anchor.ppq  / lpr + 0.5)
            + math.floor(dest.anchor.ppq / lpr + 0.5)
  clampPos(); moveHook()
end

----- Commands

function ec:registerCommands(scope)
  scope:registerAll{
    cursorDown    = function(p) moveRow( p) end,
    cursorUp      = function(p) moveRow(-p) end,
    pageDown      = function(p) moveRow( getRPBar() * p) end,
    pageUp        = function(p) moveRow(-getRPBar() * p) end,
    goTop         = function() moveRow(-cursorRow) end,
    goBottom      = function() moveRow((grid.numRows or 1) - cursorRow) end,
    goLeft        = function() moveCol(-cursorCol) end,
    goRight       = function() moveCol(#grid.cols - cursorCol) end,
    cursorRight   = function(p) moveStop( p) end,
    cursorLeft    = function(p) moveStop(-p) end,
    selectDown    = function(p) moveRow( p, true) end,
    selectUp      = function(p) moveRow(-p, true) end,
    selectRight   = function(p) moveStop( p, true) end,
    selectLeft    = function(p) moveStop(-p, true) end,
    selectClear   = function() selClear() end,
    colRight      = function(p) moveCol( p) end,
    colLeft       = function(p) moveCol(-p) end,
    channelRight  = function(p) moveChannel( p) end,
    channelLeft   = function(p) moveChannel(-p) end,
    cycleBlock    = function() cycleHBlock() end,
    cycleVBlock   = function() cycleVBlock() end,
    swapBlockEnds = function() swapEnds() end,
    groupInstPrev = function(p) for _ = 1, p do hopInstance(-1) end end,
    groupInstNext = function(p) for _ = 1, p do hopInstance( 1) end end,
  }
end

----- Decoration

do
  -- Part primitives: char `width` and `stops` (cursor offsets within the part).
  -- pitch is built per-column in decorateCol (width = active cellWidth, stops {0, width-1}).
  local PARTS = {
    sample = { width = 2, stops = {0, 1}    },   -- 7F (tracker mode)
    vel    = { width = 2, stops = {0, 1}    },   -- 30
    delay  = { width = 3, stops = {0, 1, 2} },   -- 040
    pb     = { width = 4, stops = {0, 1, 2, 3} },
    val    = { width = 2, stops = {0, 1}    },
    fx     = { width = 1, stops = {0}       },   -- one kind glyph (param stops later)
  }

  -- One char of separator between adjacent parts in the rendered cell.
  local function partsFor(type, showDelay, trackerMode)
    if type == 'note' then
      local p = {'pitch'}
      if trackerMode then util.add(p, 'sample') end
      util.add(p, 'vel')
      if showDelay   then util.add(p, 'delay')  end
      return p
    elseif type == 'pb' then
      return {'pb'}
    elseif type == 'fx' then
      return {'fx'}
    else
      return {'val'}
    end
  end

  --contract: derives col part fields from type/showDelay/trackerMode; pitch width = pitchWidth
  --invariant: ec is the sole writer of col.{parts, stopPos, partAt, partStart, width}
  function ec:decorateCol(col, pitchWidth)
    local parts = partsFor(col.type, col.showDelay, col.trackerMode)
    col.parts = parts
    pitchWidth = pitchWidth or 3
    local pitch = { width = pitchWidth, stops = { 0, pitchWidth - 1 } }

    local stopPos, partAt, partStart = {}, {}, {}
    local x = 0
    for _, name in ipairs(parts) do
      local p = name == 'pitch' and pitch or PARTS[name]
      local first = #stopPos + 1
      for _, off in ipairs(p.stops) do
        util.add(stopPos,   x + off)
        util.add(partAt,    name)
        util.add(partStart, first)
      end
      x = x + p.width + 1   -- +1 inter-part separator
    end
    col.stopPos   = stopPos
    col.partAt    = partAt
    col.partStart = partStart
    col.width     = x - 1   -- last separator was speculative
  end
end

return ec
