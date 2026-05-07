-- See docs/editCursor.md for the model.

--@map:invariant cursor lives at (row, col, stop) — stop is a char-offset index into col.stopPos, not a part index
--@map:invariant cursorRow is 0-indexed; cursorCol/cursorStop are 1-indexed (Lua-array)
--@map:invariant ec owns no MIDI/take state — pure caret + selection over grid.cols; mutations go via tm/cm
--@map:invariant selection is anchor + cursor; selAnchor is the fixed end, cursor is the moving end; sel is the resolved rect
--@map:invariant sel == nil iff no selection; hasSelection() / region() degenerate-to-cursor is a callsite policy, not stored
--@map:invariant sticky scopes are orthogonal: hBlockScope ∈ {0=free,1=col,2=channel,3=all-cols}, vBlockScope ∈ {0=free,1=beat,2=bar,3=all-rows}
--@map:invariant sticky == any nonzero scope; cursor moves while sticky update sel rather than clearing it
--@map:invariant HBlock=2/3 use sentinel part1=part2='*' that no real part name matches — selectionStopSpan falls through to whole-col
--@map:invariant within a single col, parts order via col.partStart (lower partStart = earlier part); not stop index, since parts may be multi-stop
--@map:invariant moveHook fires after every position-changing operation (clampPos+moveHook are paired)

--@map:shape selection = { row1, row2, col1, col2, part1, part2 }   -- inclusive on both axes; part1/part2 are part names or '*' sentinel
--@map:shape selAnchor = { row, col, stop }                          -- fixed end of an active selection
--@map:shape clip.single = { mode='single', type='note'|'7bit'|'pb', numRows, events=[clipEvent,...] }
--@map:shape clip.multi  = { mode='multi', numRows, startType, cols=[clipColEntry,...] }
--@map:shape clipColEntry = { type, chanDelta, key, events=[clipEvent,...] }   -- key: note=lane-pos, cc=cc#, singleton=nil
--@map:shape clipEvent = source-event minus CLIP_RESERVED, plus { row, [endRow] }   -- row is 0-relative to clip top

loadModule('util')

local function print(...)
  return util.print(...)
end

function newEditCursor(deps)

  ---------- PRIVATE

  local grid     = deps.grid
  local cm       = deps.cm
  local getRPBar = deps.rowPerBar
  local moveHook = deps.moveHook or function () end

  local cursorRow, cursorCol, cursorStop = 0, 1, 1
  local hBlockScope, vBlockScope         = 0, 0
  local sel, selAnchor

  ----- Position

  --@map:contract clamps to grid extents; idempotent; stop clamped against current col's stopPos length so col-changes must precede stop reads
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

  --@map:contract returns first stop whose partAt name matches; used by selection-set and regionStart to land the caret on the part's leading char
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

  --@map:contract pins anchor at current cursor and produces a 1x1 sel; precondition for any selUpdate that follows
  local function selStart()
    selAnchor = { row = cursorRow, col = cursorCol, stop = cursorStop }
    local p = cursorPart()
    sel = { row1 = cursorRow, row2 = cursorRow, col1 = cursorCol, col2 = cursorCol, part1 = p, part2 = p }
  end

  --@map:contract recomputes sel from anchor + cursor + scopes; rows snap to beat/bar under vBlock=1/2; cols expand to channel/all under hBlock=2/3; no-op when selAnchor is nil
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

  --@map:contract drops sel + anchor + both sticky scopes; the only path that turns sticky off without explicit unstick()
  local function selClear()
    sel = nil; selAnchor = nil
    hBlockScope = 0; vBlockScope = 0
  end

  --@map:contract first call seeds anchor and sets scope=1 (col); subsequent cycles 1->2->3->1 (col->channel->all-cols)
  local function cycleHBlock()
    if not isSticky() then
      selAnchor   = { row = cursorRow, col = cursorCol, stop = cursorStop }
      hBlockScope = 1
    else
      hBlockScope = (hBlockScope % 3) + 1
    end
    selUpdate()
  end

  --@map:contract first call seeds anchor and sets scope=1 (beat); subsequent cycles 1->2->3->1 (beat->bar->all-rows); no-op on empty grid
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

  --@map:contract swaps anchor<->cursor on whichever axes aren't scope-locked (vBlock<1 swaps row, hBlock<2 swaps col+stop); no-op without an active selection
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

  --@map:contract selecting=true (or sticky) extends sel; otherwise clears sel before moving; clamps at top/bottom edges (no wrap)
  local function moveRow(n, selecting)
    if selecting or isSticky() then
      if not sel then selStart() end
    else selClear() end
    cursorRow = cursorRow + n
    clampPos(); moveHook()
    if selecting or isSticky() then selUpdate() end
  end

  --@map:contract walks stops within col, crossing into adjacent col at the boundary; stops at first/last col (no wrap); under hBlock>=2 collapses scope to 1 and re-anchors at current cursor first
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

    --@map:contract jumps one col per step, landing on first/last stop of the destination col; under sticky, extends/contracts selection one col per step
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

    --@map:contract jumps one channel per step; non-sticky lands on the first note col of the destination channel (skipping pc/pb sentinels); sticky preserves the raw chan-edge land
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

  ---------- PUBLIC

  local ec = {}

  ----- Position

  function ec:row()           return cursorRow  end
  function ec:col()           return cursorCol  end
  function ec:pos()           return cursorRow, cursorCol, cursorStop end

  --@map:contract any nil arg leaves that axis untouched; clamps and fires moveHook unconditionally
  function ec:setPos(row, col, stop)
    if row  then cursorRow  = row  end
    if col  then cursorCol  = col  end
    if stop then cursorStop = stop end
    clampPos(); moveHook()
  end

  function ec:clampPos()      clampPos() end

  --@map:contract scales cursorRow by newRPB/oldRPB; called by vm when rowPerBeat changes mid-session so caret stays at the same musical time
  function ec:rescaleRow(oldRPB, newRPB)
    cursorRow = math.floor(cursorRow * newRPB / oldRPB)
  end

  function ec:reset()
    cursorRow, cursorCol, cursorStop = 0, 1, 1
    selClear()
  end

  ----- Part & Region

  function ec:cursorPart()    return cursorPart() end
  function ec:hasSelection()  return sel ~= nil end
  function ec:isSticky()      return isSticky() end

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

  --@map:contract installs a selection from a part-typed record; clears sticky scopes; anchor lands at top-left part-start so subsequent extends behave like a fresh drag
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

  --@map:contract shifts both selection rows + anchor + cursor by rowDelta; clamps each independently (selection can compress against the edge while cursor doesn't)
  function ec:shiftSelection(rowDelta)
    local maxRow = grid.numRows - 1
    sel.row1      = util.clamp(sel.row1      + rowDelta, 0, maxRow)
    sel.row2      = util.clamp(sel.row2      + rowDelta, 0, maxRow)
    selAnchor.row = util.clamp(selAnchor.row + rowDelta, 0, maxRow)
    cursorRow     = cursorRow + rowDelta
    clampPos(); moveHook()
  end

  ----- Motion

  --@map:contract advances by cm.advanceBy rows; the per-keystroke auto-step after a write
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

    --@map:contract stamps col.parts/stopPos/partAt/partStart/width derived from col.type + showDelay + trackerMode; ec is the sole writer of these fields, addGridCol never names them
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
end

---------- CLIPBOARD

--@map:invariant clipboard persists via REAPER ExtState under ('rdm','clipboard'), serialised by util.serialise
--@map:invariant clip rows are 0-relative to the clip's top (row=0 is first row of selection); paste re-bases against current cursor row
--@map:invariant single vs multi mode is decided by selected-col count: c1==c2 -> single, otherwise multi
--@map:invariant single.type ∈ { 'note', '7bit', 'pb' } — note/vel split decided at copy by region's part1
--@map:invariant multi.cols carry chanDelta from leftmost source channel; cursor's channel becomes the leftmost destination
--@map:invariant CLIP_RESERVED keys are stripped at copy; CLIP_ARTIFACTS (row/endRow) are stripped at paste; everything else (including custom metadata) round-trips
--@map:invariant velEvent is the only collector that synthesises a clip event rather than cloning the source — vel-mode pastes must not carry note metadata onto cc destinations

-- Reserved keys never carried verbatim through copy/paste: position is
-- rebuilt from `row` at paste, identity is decided by the destination
-- column, REAPER bookkeeping must not round-trip, and the type tag lives on
-- the clip envelope. Everything else — known fields and any future
-- metadata — rides through. Keep this list small and rule-based; do not
-- allowlist event payload.
local CLIP_RESERVED = {
  -- position (rebuilt from row + cursor)
  ppq = true, endppq = true, ppqL = true, endppqL = true,
  -- destination identity
  chan = true, frame = true, lane = true, cc = true,
  -- mm/REAPER bookkeeping
  loc = true, idx = true, uuid = true, uuidIdx = true,
  -- envelope-level
  type = true, msgType = true,
}
-- Clip-only fields stripped before a paste materialises into a write event.
local CLIP_ARTIFACTS = { row = true, endRow = true }

function newClipboard(deps)

  ---------- PRIVATE

  local ec           = deps.ec
  local grid         = deps.grid
  local tm           = deps.tm
  local cm           = deps.cm
  local currentFrame = deps.currentFrame
  local assignTail   = deps.assignTail
  local paFrame      = deps.paFrame
  local getCtx       = deps.getCtx
  local getLength    = deps.getLength

  local function save(clip)
    reaper.SetExtState('rdm', 'clipboard', util.serialise(clip), false)
  end

  local function load()
    local raw = reaper.GetExtState('rdm', 'clipboard')
    if raw == '' then return end
    return util.unserialise(raw)
  end

  --@map:contract returns nil if the resolved selection is empty (no events); single-col emits {mode='single',type,...}, multi-col emits {mode='multi',cols=[...]}
  local function collect()
    local ctx = getCtx()
    local r1, r2, c1, c2, part1 = ec:region()
    local numRows  = r2 - r1 + 1
    local logPerRow = ctx:ppqPerRow()

    -- ppqL is the exact authoring-frame coordinate; dividing it skips the
    -- ppqToRow round-trip's float drift. Fall back to ctx:ppqToRow under the
    -- swing inverse for events that lack a stamp (raw mm reads, pre-authoring).
    local function rowOf(p, pL, chan)
      return (pL and pL / logPerRow or ctx:ppqToRow(p, chan)) - r1
    end

    -- endRow set only when the note ends inside the selection; spanning notes get their tail clamped at paste.
    local function noteEvent(evt, chan, endppq)
      local ce = util.clone(evt, CLIP_RESERVED)
      ce.row = rowOf(evt.ppq, evt.ppqL, chan)
      if util.isNote(evt) and evt.endppq <= endppq then
        ce.endRow = rowOf(evt.endppq, evt.endppqL, chan)
      end
      return ce
    end

    local function scalarEvent(evt, chan)
      local ce = util.clone(evt, CLIP_RESERVED)
      ce.row = rowOf(evt.ppq, evt.ppqL, chan)
      return ce
    end

    -- Scalar abstraction over a note: only `val` carries. A clone would
    -- land the source note's pitch/detune onto a CC paste as bogus metadata.
    local function velEvent(evt, chan)
      return { row = rowOf(evt.ppq, evt.ppqL, chan), val = evt.vel }
    end

    -- Single-column mode
    if c1 == c2 then
      local col = grid.cols[c1]
      if not col then return end
      local startppq, endppq = ctx:rowToPPQ(r1, col.midiChan), ctx:rowToPPQ(r2 + 1, col.midiChan)

      local clipType, events = nil, {}
      local emit
      local chan = col.midiChan
      if col.type == 'note' and part1 == 'pitch' then
        clipType, emit = 'note', function(e) return noteEvent(e, chan, endppq) end
      elseif col.type == 'note' and part1 == 'vel' then
        clipType, emit = '7bit', function(e) return velEvent(e, chan) end
      elseif col.type == 'pb' then
        clipType, emit = 'pb',   function(e) return scalarEvent(e, chan) end
      else
        clipType, emit = '7bit', function(e) return scalarEvent(e, chan) end
      end
      for evt in util.between(col.events, startppq, endppq) do
        util.add(events, emit(evt))
      end

      if #events == 0 then return end
      return { mode = 'single', type = clipType, numRows = numRows, events = events }
    end

    local cols = {}
    local leftChan
    local notePosByChan = {}
    for col in ec:eachSelectedCol() do
      leftChan = leftChan or col.midiChan

      local entry = {
        type = col.type,
        chanDelta = col.midiChan - leftChan,
        events = {},
      }
      if col.type == 'note' then
        local n = notePosByChan[col.midiChan] or 0
        entry.key = n
        notePosByChan[col.midiChan] = n + 1
      elseif col.type == 'cc' then
        entry.key = col.cc
      end

      local chan = col.midiChan
      local startppq, endppq = ctx:rowToPPQ(r1, chan), ctx:rowToPPQ(r2 + 1, chan)
      for evt in util.between(col.events, startppq, endppq) do
        if col.type == 'note' then
          util.add(entry.events, noteEvent(evt, chan, endppq))
        else
          util.add(entry.events, scalarEvent(evt, chan))
        end
      end
      util.add(cols, entry)
    end

    if #cols == 0 then return end
    return { mode = 'multi', numRows = numRows, startType = cols[1].type, cols = cols }
  end

  --@map:contract carry-forward over note-ons in region (clip val updates currentVel, then writes onto next note-ons); pass 2 may emit PA events on sustain rows when cm.polyAftertouch is set
  local function pasteVelocities(events, dstCol, startppq, endppq)
    local last = util.seek(dstCol.events, 'before', startppq)
    local currentVel = last and last.vel or cm:get('defaultVelocity')

    -- Delete existing PA events in the paste region
    for evt in util.between(dstCol.events, startppq, endppq) do
      if evt.type == 'pa' then tm:deleteEvent('pa', evt) end
    end

    -- Pass 1: carry-forward velocities onto note-ons
    local ci = 1
    for evt in util.between(dstCol.events, startppq, endppq) do
      if evt.pitch then
        while ci <= #events and events[ci].ppq <= evt.ppq do
          if events[ci].val > 0 then
            currentVel = util.clamp(events[ci].val, 1, 127)
          end
          ci = ci + 1
        end
        tm:assignEvent('note', evt, { vel = currentVel })
      end
    end

    -- Pass 2: create PA events for clipboard values landing on sustain rows
    if cm:get('polyAftertouch') then
      for _, ce in ipairs(events) do
        local note = util.seek(dstCol.events, 'before', ce.ppq, util.isNote)
        if note and note.endppq > ce.ppq
          and note.ppq ~= ce.ppq then
          tm:addEvent('pa', {
            ppq = ce.ppq, ppqL = ce.ppqL,
            chan = dstCol.midiChan,
            pitch = note.pitch, val = util.clamp(ce.val, 1, 127),
            frame = paFrame(note.frame, dstCol.midiChan),
          })
        end
      end
    end

    tm:flush()
  end

  --@map:contract dispatches by (clip.type, dstCol.type, cursorPart): note->note(pitch), 7bit->note(vel) via pasteVelocities, pb->pb, 7bit->cc/at/pc; mismatched combos silently no-op
  local function pasteSingle(clip)
    local ctx = getCtx()
    local dstCol = grid.cols[ec:col()]
    if not dstCol then return end
    local chan = dstCol.midiChan
    local r = ec:row()
    local startppq = ctx:rowToPPQ(r, chan)
    local endppq = ctx:rowToPPQ(r + clip.numRows, chan)
    local part = ec:cursorPart()
    local logPerRow = ctx:ppqPerRow()
    local capRow = r + clip.numRows  -- logical row of endppq

    -- ppqL rides alongside ppq for authoring-row identity; clone carries payload, identity overlaid below.
    local events = {}
    for _, ce in ipairs(clip.events) do
      local ppq = ctx:rowToPPQ(r + ce.row, chan)
      if ppq >= endppq then goto nextCe end
      local e = util.clone(ce, CLIP_ARTIFACTS)
      e.ppq, e.ppqL = ppq, (r + ce.row) * logPerRow
      if ce.endRow then
        local eRow = math.min(r + ce.endRow, capRow)
        e.endppq  = math.min(ctx:rowToPPQ(r + ce.endRow, chan), endppq)
        e.endppqL = eRow * logPerRow
      end
      util.add(events, e)
      ::nextCe::
    end
    table.sort(events, function(a, b) return a.ppq < b.ppq end)

    if clip.type == 'note' and dstCol.type == 'note' and part == 'pitch' then
      local velList = {}
      for evt in util.between(dstCol.events, startppq, endppq) do
        if evt.pitch and evt.vel > 0 then
          util.add(velList, { ppq = evt.ppq, val = evt.vel })
        end
      end
      local last = util.seek(dstCol.events, 'before', startppq)
      local currentVel = last and last.vel or cm:get('defaultVelocity')

      local lastNote = util.seek(dstCol.events, 'before', startppq, util.isNote)
      local nextNote = util.seek(dstCol.events, 'at-or-after', endppq, util.isNote)
      local nextNotePpq  = nextNote and nextNote.ppq or getLength()
      local nextNotePpqL = nextNote
        and (nextNote.ppqL or ctx:ppqToRow(nextNote.ppq, chan) * logPerRow)
        or getLength()
      local lane = dstCol.lane

      -- Delete in-region events directly: queueDeleteNotes' survivor-extension
      -- fixup is for leaving a hole, but we're filling it. An extended lastNote
      -- would overlap the new notes and force the allocator to spill on rebuild.
      if lastNote and events[1] and lastNote.endppq > events[1].ppq then
        assignTail(lastNote, dstCol.midiChan, events[1].ppq, events[1].ppqL)
      end
      for evt in util.between(dstCol.events, startppq, endppq) do
        tm:deleteEvent(evt.type == 'pa' and 'pa' or 'note', evt)
      end

      local frame = currentFrame(dstCol.midiChan)
      local vi = 1
      for _, e in ipairs(events) do
        while vi <= #velList and velList[vi].ppq <= e.ppq do
          currentVel = util.clamp(velList[vi].val, 1, 127)
          vi = vi + 1
        end
        e.endppq  = e.endppq  or nextNotePpq
        e.endppqL = e.endppqL or nextNotePpqL
        e.chan, e.vel, e.lane, e.frame = dstCol.midiChan, currentVel, lane, frame
        tm:addEvent('note', e)
      end
      tm:flush()
      return
    end

    if clip.type == '7bit' and dstCol.type == 'note' and part == 'vel' then
      pasteVelocities(events, dstCol, startppq, endppq)
      return
    end

    if (clip.type == 'pb' and dstCol.type == 'pb')
    or (clip.type == '7bit' and dstCol.type ~= 'note' and dstCol.type ~= 'pb') then
      for evt in util.between(dstCol.events, startppq, endppq) do
        tm:deleteEvent(dstCol.type, evt)
      end

      local frame = currentFrame(dstCol.midiChan)
      for _, e in ipairs(events) do
        e.chan, e.frame = dstCol.midiChan, frame
        if dstCol.type == 'cc' then e.cc = dstCol.cc end
        tm:addEvent(dstCol.type, e)
      end
      tm:flush()
      return
    end
  end

  --@map:contract resolves each clip col against cursor's chan via chanDelta; out-of-range channels and missing destinations skip silently; bails entirely if startType=='note' but cursor isn't on a note col
  local function pasteMulti(clip)
    local ctx = getCtx()
    local cursor = grid.cols[ec:col()]
    if not cursor then return end
    -- Notes need a note-col home; other parts paste wherever, using cursor's
    -- channel as the anchor.
    if clip.startType == 'note' and cursor.type ~= 'note' then return end

    -- Lazy per-chan lookup: notes by lane (dense), cc by number, singletons by type.
    local chanInfo = {}
    local function infoFor(chan)
      local info = chanInfo[chan]
      if info then return info end
      info = { noteCols = {}, ccCols = {}, other = {} }
      local first, last = grid.chanFirstCol[chan], grid.chanLastCol[chan]
      local lane = 0
      for ci = first or 1, last or 0 do
        local col = grid.cols[ci]
        if col.type == 'note' then
          lane = lane + 1
          info.noteCols[lane] = col
        elseif col.type == 'cc' then
          info.ccCols[col.cc] = col
        else
          info.other[col.type] = col
        end
      end
      chanInfo[chan] = info
      return info
    end

    local cursorNotePos = cursor.lane or 0

    local function resolve(clipCol)
      local chan = cursor.midiChan + clipCol.chanDelta
      if chan < 1 or chan > 16 then return end
      local info = infoFor(chan)

      if clipCol.type == 'note' then
        local base = (clipCol.chanDelta == 0 and cursorNotePos > 0) and cursorNotePos or 1
        local lane = base + clipCol.key
        return { type = 'note', chan = chan, lane = lane, col = info.noteCols[lane] }
      elseif clipCol.type == 'cc' then
        return { type = 'cc', chan = chan, ccNum = clipCol.key, col = info.ccCols[clipCol.key] }
      else
        return { type = clipCol.type, chan = chan, col = info.other[clipCol.type] }
      end
    end

    local cRow = ec:row()
    local logPerRow = ctx:ppqPerRow()
    local capRow = cRow + clip.numRows
    for _, clipCol in ipairs(clip.cols) do
      local r = resolve(clipCol)
      if not r then goto nextCol end
      local dst = r.col
      local startppq = ctx:rowToPPQ(cRow, r.chan)
      local endppq   = ctx:rowToPPQ(capRow, r.chan)

      -- Materialise as in pasteSingle; identity overlaid in the write loop below.
      local events = {}
      for _, ce in ipairs(clipCol.events) do
        local ppq = ctx:rowToPPQ(cRow + ce.row, r.chan)
        if ppq < endppq then
          local e = util.clone(ce, CLIP_ARTIFACTS)
          e.ppq, e.ppqL = ppq, (cRow + ce.row) * logPerRow
          if ce.endRow then
            local eRow = math.min(cRow + ce.endRow, capRow)
            e.endppq  = math.min(ctx:rowToPPQ(cRow + ce.endRow, r.chan), endppq)
            e.endppqL = eRow * logPerRow
          end
          util.add(events, e)
        end
      end
      table.sort(events, function(a, b) return a.ppq < b.ppq end)

      -- Wipe existing events in the paste region. For notes, delete directly
      -- rather than via queueDeleteNotes — its survivor-extension fixup is for
      -- leaving a hole, but we're filling it. An extended last-survivor would
      -- overlap the new notes and force the allocator to spill on rebuild.
      -- Attached PAs cascade-delete with their host note.
      if dst then
        if r.type == 'note' then
          local last = util.seek(dst.events, 'before', startppq, util.isNote)
          if last and events[1] and last.endppq > events[1].ppq then
            assignTail(last, r.chan, events[1].ppq, events[1].ppqL)
          end
          for evt in util.between(dst.events, startppq, endppq, util.isNote) do
            tm:deleteEvent('note', evt)
          end
        else
          for evt in util.between(dst.events, startppq, endppq) do
            tm:deleteEvent(r.type, evt)
          end
        end
      end

      -- End cap for pasted notes that lack an explicit endppq.
      local capPPQ  = endppq
      local capppqL = capRow * logPerRow
      if r.type == 'note' and dst then
        local nn = util.seek(dst.events, 'at-or-after', endppq, util.isNote)
        if nn then
          capPPQ  = math.min(capPPQ, nn.ppq)
          capppqL = math.min(capppqL, nn.ppqL or ctx:ppqToRow(nn.ppq, r.chan) * logPerRow)
        end
      end

      -- Overlay destination identity onto the materialised clones.
      local frame = currentFrame(r.chan)
      for _, e in ipairs(events) do
        e.chan, e.frame = r.chan, frame
        if r.type == 'note' then
          e.endppq  = e.endppq  or capPPQ
          e.endppqL = e.endppqL or capppqL
          e.lane    = r.lane
        elseif r.type == 'cc' then
          e.cc = r.ccNum
        end
        tm:addEvent(r.type, e)
      end
      ::nextCol::
    end
    tm:flush()
  end

  local function pasteClip(clip)
    if clip.mode == 'single' then pasteSingle(clip) else pasteMulti(clip) end
  end

  --@map:contract mutates clip in place; survives both modes; used by duplicate-up at row 0 to keep selection-following behaviour cumulative
  -- A note whose start row falls within the trimmed band is dropped entirely.
  local function trimTop(clip, trim)
    local function filter(events)
      local i = 1
      for _, e in ipairs(events) do
        if e.row >= trim then
          e.row = e.row - trim
          if e.endRow then e.endRow = e.endRow - trim end
          events[i] = e
          i = i + 1
        end
      end
      for j = #events, i, -1 do events[j] = nil end
    end
    clip.numRows = clip.numRows - trim
    if clip.mode == 'single' then
      filter(clip.events)
    else
      for _, c in ipairs(clip.cols) do filter(c.events) end
    end
  end

  ---------- PUBLIC

  local clipboard = {}
  function clipboard:collect()           return collect() end
  function clipboard:copy()              local c = collect(); if c then save(c) end end
  function clipboard:pasteClip(clip)     pasteClip(clip) end
  function clipboard:trimTop(clip, trim) trimTop(clip, trim) end

  function clipboard:registerCommands(scope)
    scope:registerAll{
      copy  = function() local c = collect(); if c then save(c) end; ec:selClear() end,
      paste = function()
        if ec:isSticky() then ec:selClear()
        else local c = load(); if c then pasteClip(c) end
        end
      end,
    }
  end

  return clipboard
end
