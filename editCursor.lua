-- See docs/editCursor.md for the model.

--invariant: cursor lives at (row, col, stop) — stop is a char-offset index into col.stopPos, not a part index
--invariant: cursorRow is 0-indexed; cursorCol/cursorStop are 1-indexed (Lua-array)
--invariant: ec owns caret, selection, and clipboard; no MIDI event state — MIDI mutations go via tm/cm
--invariant: selection is anchor + cursor; selAnchor is the fixed end, cursor is the moving end; sel is the resolved rect
--invariant: sel == nil iff no selection; hasSelection() / region() degenerate-to-cursor is a callsite policy, not stored
--invariant: sticky scopes are orthogonal: hBlockScope ∈ {0=free,1=col,2=channel,3=all-cols}, vBlockScope ∈ {0=free,1=beat,2=bar,3=all-rows}
--invariant: sticky == any nonzero scope; cursor moves while sticky update sel rather than clearing it
--invariant: HBlock=2/3 use sentinel part1=part2='*' that no real part name matches — selectionStopSpan falls through to whole-col
--invariant: within a single col, parts order via col.partStart (lower partStart = earlier part); not stop index, since parts may be multi-stop
--invariant: moveHook fires after every position-changing operation (clampPos+moveHook are paired)
--shape: selection = { row1, row2, col1, col2, part1, part2 }   -- inclusive on both axes; part1/part2 are part names or '*' sentinel
--shape: selAnchor = { row, col, stop }                          -- fixed end of an active selection
--shape: clip.single = { mode='single', type='note'|'7bit'|'pb', numRows, events=[clipEvent,...] }
--shape: clip.multi  = { mode='multi', numRows, startType, cols=[clipColEntry,...] }
--shape: clipColEntry = { type, chanDelta, key, events=[clipEvent,...] }   -- key: note=lane-pos, cc=cc#, singleton=nil
--shape: clipEvent = source-event minus CLIP_RESERVED, plus { row, [endRow] }   -- row is 0-relative to clip top
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
local sel, selAnchor

-- Region authoring mode: a modal cmgr overlay. ec owns only the
-- push/pop lifecycle + this ephemeral nav cursor (NOT persisted); the
-- group store/projection/persistence is gm's.
local regionCursor                       -- { groupId, instId } | nil
local regionScope, regionPushed

----- Position

--contract: clamps to grid extents; idempotent; stop clamped against current col's stopPos length so col-changes must precede stop reads
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

--contract: returns first stop whose partAt name matches; used by selection-set and regionStart to land the caret on the part's leading char
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

--contract: pins anchor at current cursor and produces a 1x1 sel; precondition for any selUpdate that follows
local function selStart()
  selAnchor = { row = cursorRow, col = cursorCol, stop = cursorStop }
  local p = cursorPart()
  sel = { row1 = cursorRow, row2 = cursorRow, col1 = cursorCol, col2 = cursorCol, part1 = p, part2 = p }
end

--contract: recomputes sel from anchor + cursor + scopes; rows snap to beat/bar under vBlock=1/2; cols expand to channel/all under hBlock=2/3; no-op when selAnchor is nil
local function selUpdate()
  local a = selAnchor
  if not a then return end
  local numRows = grid.numRows or 1

  local r1, r2
  if vBlockScope == 1 or vBlockScope == 2 then
    local unit = vBlockScope == 1 and cm:get('rowPerBeat') or getRPBar()
    r1 = math.floor(cursorRow / unit) * unit
    r2 = math.min(r1 + unit - 1, numRows - 1)
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

--contract: drops sel + anchor + both sticky scopes; the only path that turns sticky off without explicit unstick()
local function selClear()
  sel = nil; selAnchor = nil
  hBlockScope = 0; vBlockScope = 0
end

--contract: first call seeds anchor and sets scope=1 (col); subsequent cycles 1->2->3->1 (col->channel->all-cols)
local function cycleHBlock()
  if not isSticky() then
    selAnchor   = { row = cursorRow, col = cursorCol, stop = cursorStop }
    hBlockScope = 1
  else
    hBlockScope = (hBlockScope % 3) + 1
  end
  selUpdate()
end

--contract: first call seeds anchor and sets scope=1 (beat); subsequent cycles 1->2->3->1 (beat->bar->all-rows); no-op on empty grid
local function cycleVBlock()
  if (grid.numRows or 0) == 0 then return end
  if not isSticky() then
    selAnchor   = { row = cursorRow, col = cursorCol, stop = cursorStop }
    vBlockScope = 1
  else
    vBlockScope = (vBlockScope % 3) + 1
  end
  selUpdate()
end

--contract: swaps anchor<->cursor on whichever axes aren't scope-locked (vBlock<1 swaps row, hBlock<2 swaps col+stop); no-op without an active selection
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

--contract: selecting=true (or sticky) extends sel; otherwise clears sel before moving; clamps at top/bottom edges (no wrap)
local function moveRow(n, selecting)
  if selecting or isSticky() then
    if not sel then selStart() end
  else selClear() end
  cursorRow = cursorRow + n
  clampPos(); moveHook()
  if selecting or isSticky() then selUpdate() end
end

--contract: walks stops within col, crossing into adjacent col at the boundary; stops at first/last col (no wrap); under hBlock>=2 collapses scope to 1 and re-anchors at current cursor first
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

  --contract: jumps one col per step, landing on first/last stop of the destination col; under sticky, extends/contracts selection one col per step
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

  --contract: jumps one channel per step; non-sticky lands on the first note col of the destination channel (skipping pc/pb sentinels); sticky preserves the raw chan-edge land
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

-- Install the instance's cells as the live selection (caret at its
-- top-left, via the bridge) and point the region cursor at it.
local function snapToInstance(entry)
  regionCursor = { groupId = entry.groupId, instId = entry.instId }
  groupBridge.instanceSelection(entry.groupId, entry.instId)
end

---------- PUBLIC

local ec = {}

----- Position

function ec:row()           return cursorRow  end
function ec:col()           return cursorCol  end
function ec:pos()           return cursorRow, cursorCol, cursorStop end

--contract: any nil arg leaves that axis untouched; clamps and fires moveHook unconditionally
function ec:setPos(row, col, stop)
  if row  then cursorRow  = row  end
  if col  then cursorCol  = col  end
  if stop then cursorStop = stop end
  clampPos(); moveHook()
end

function ec:clampPos()      clampPos() end

--contract: scales cursorRow by newRPB/oldRPB; called by vm when rowPerBeat changes mid-session so caret stays at the same musical time
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

--contract: installs a selection from a part-typed record; clears sticky scopes; anchor lands at top-left part-start so subsequent extends behave like a fresh drag
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

--contract: shifts both selection rows + anchor + cursor by rowDelta; clamps each independently (selection can compress against the edge while cursor doesn't)
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

----- Region mode

function ec:isInRegionMode() return regionPushed == true end
function ec:regionCursor()   return regionCursor end

-- Nav verbs fall through the modal overlay to tracker/global below;
-- everything else is gated so a stray edit can't escape region mode.
local REGION_PASSTHROUGH = {
  cursorUp=true, cursorDown=true, cursorLeft=true, cursorRight=true,
  pageUp=true, pageDown=true, goTop=true, goBottom=true, goLeft=true, goRight=true,
  colLeft=true, colRight=true, channelLeft=true, channelRight=true,
  selectUp=true, selectDown=true, selectLeft=true, selectRight=true, selectClear=true,
  cycleBlock=true, cycleVBlock=true, swapBlockEnds=true,
}

do
  local function exitMode()
    cmgr:pop(regionScope)
    regionPushed = false
    regionCursor = nil
  end

  --contract: idempotent while pushed; seeds the nav cursor from gm's
  --          active group's first instance if one is set.
  function ec:enterRegionMode()
    if regionPushed then return end
    cmgr:push(regionScope)
    regionPushed = true
    local gm = gmgr()
    local active = gm and gm:activeGroup()
    if not active then return end
    for _, e in ipairs(orderedInstances()) do
      if e.groupId == active then
        regionCursor = { groupId = e.groupId, instId = e.instId }
        return
      end
    end
  end

  local function newFromSelection()
    local rect = groupBridge.selectionAsRect()
    if not rect then return end
    local groupId = gmgr():mark(groupBridge.eventsInRect(rect), rect)
    if not groupId then return end
    regionCursor = { groupId = groupId, instId = 1 }
    selClear()
  end

  local function newInstance()
    if not regionCursor then return end
    local anchor = groupBridge.cursorAnchor()
    if not anchor then return end
    local instId = gmgr():newInstance(regionCursor.groupId, anchor)
    if instId then regionCursor.instId = instId end
  end

  local function dropInstance()
    if not regionCursor then return end
    local at = cursorIndex(orderedInstances()) or 1
    gmgr():deleteInstance(regionCursor.groupId, regionCursor.instId)
    local after = orderedInstances()
    local pick  = after[math.min(at, #after)]
    regionCursor = pick and { groupId = pick.groupId, instId = pick.instId }
                        or nil
  end

  local function cycle(step)
    local list = orderedInstances()
    if #list == 0 then return end
    local at = cursorIndex(list) or (step > 0 and 0 or #list + 1)
    snapToInstance(list[util.clamp(at + step, 1, #list)])
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

  local function commit()
    if regionCursor then
      groupBridge.instanceSelection(regionCursor.groupId, regionCursor.instId)
    end
    exitMode()
  end

  -- Built once at instantiate; trackerPage binds keys on this same
  -- scope later (shared registry). Without cmgr region mode errors
  -- loudly if entered -- intentional, like the tracker scope.
  if cmgr then
    regionScope = cmgr:scope('region')
    regionScope.modal       = true
    regionScope.passthrough = REGION_PASSTHROUGH
    regionScope:registerAll{
      regionBail         = exitMode,
      regionCommit       = commit,
      regionNew          = newFromSelection,
      regionInstance     = newInstance,
      regionDrop         = dropInstance,
      regionNext         = function() cycle( 1) end,
      regionPrev         = function() cycle(-1) end,
      regionNudgeForward = function() moveBy( 1) end,
      regionNudgeBack    = function() moveBy(-1) end,
      regionGrow         = function() resizeBy{ endDelta   =  logPerRow() } end,
      regionShrink       = function() resizeBy{ endDelta   = -logPerRow() } end,
      regionGrowStart    = function() resizeBy{ startDelta = -logPerRow() } end,
      regionShrinkStart  = function() resizeBy{ startDelta =  logPerRow() } end,
    }
  end
end

----- Commands

function ec:registerCommands(scope)
  scope:registerAll{
    cursorDown    = function() moveRow(1) end,
    cursorUp      = function() moveRow(-1) end,
    pageDown      = function() moveRow(getRPBar()) end,
    pageUp        = function() moveRow(-getRPBar()) end,
    goTop         = function() moveRow(-cursorRow) end,
    goBottom      = function() moveRow((grid.numRows or 1) - cursorRow) end,
    goLeft        = function() moveCol(-cursorCol) end,
    goRight       = function() moveCol(#grid.cols - cursorCol) end,
    cursorRight   = function() moveStop(1) end,
    cursorLeft    = function() moveStop(-1) end,
    selectDown    = function() moveRow(1, true) end,
    selectUp      = function() moveRow(-1, true) end,
    selectRight   = function() moveStop(1, true) end,
    selectLeft    = function() moveStop(-1, true) end,
    selectClear   = function() selClear() end,
    colRight      = function() moveCol(1) end,
    colLeft       = function() moveCol(-1) end,
    channelRight  = function() moveChannel(1) end,
    channelLeft   = function() moveChannel(-1) end,
    cycleBlock    = function() cycleHBlock() end,
    cycleVBlock   = function() cycleVBlock() end,
    swapBlockEnds = function() swapEnds() end,
  }
end

----- Decoration

do
  -- Part primitives: char `width` and `stops` (cursor offsets within the
  -- part). pitch's middle char ('-' between letter and octave) is
  -- skipped — width 3, only 2 stops.
  local PARTS = {
    pitch  = { width = 3, stops = {0, 2}    },   -- C-4
    sample = { width = 2, stops = {0, 1}    },   -- 7F (tracker mode)
    vel    = { width = 2, stops = {0, 1}    },   -- 30
    delay  = { width = 3, stops = {0, 1, 2} },   -- 040
    pb     = { width = 4, stops = {0, 1, 2, 3} },
    val    = { width = 2, stops = {0, 1}    },
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
    else
      return {'val'}
    end
  end

  --contract: stamps col.parts/stopPos/partAt/partStart/width derived from col.type + showDelay + trackerMode; ec is the sole writer of these fields, addGridCol never names them
  function ec:decorateCol(col)
    local parts = partsFor(col.type, col.showDelay, col.trackerMode)
    col.parts = parts

    local stopPos, partAt, partStart = {}, {}, {}
    local x = 0
    for _, name in ipairs(parts) do
      local p = PARTS[name]
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
