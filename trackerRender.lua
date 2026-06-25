-- See docs/trackerPage.md for the model.

--invariant: page is render + input only; tracker state lives in tv/ec/tm, never cached
--invariant: cm/tv read fresh each frame; only ephemeral UI state persists across frames
--invariant: page-persistent state: gridX/Y, dragging, picker*, laneConsumed (modal state lives on modalHost)
--invariant: col.x == nil is the visibility predicate; per-column draws must gate on it
--invariant: cell coords 0-indexed; header rows at -HEADER, row-num gutter at -GUTTER
--invariant: writes go through tv or cmgr commands; page never reaches into tm
local util    = require 'util'
local timing  = require 'timing'
local tuning  = require 'tuning'
local groups = require 'groups'

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'

--contract: trackerPage (the controller) owns the stack + take lifecycle and drives this renderer
--contract: the renderer holds only tv (injected); it never reaches mm/tm/gm
local cm, ds, cmgr, chrome, gui, modalHost, facade, tv, help =
  (...).cm, (...).ds, (...).cmgr, (...).chrome, (...).gui, (...).modalHost, (...).facade, (...).tv, (...).help

local function print(...)
  return util.print(...)
end

local painter = require 'painter'

-- The renderer reads project data (tracks/slots) through the arrange facade;
-- the tracker's selection nav goes straight to tv. See docs/trackerPage.md.
local function arrange() return facade.get('arrange') end

---------- PRIVATE

local GUTTER      = 5    -- in grid chars: 3-char row num + spacer + region slot
local HEADER      = 3    -- header rows, fixed; vertical param names truncate to fit, never grow it

local gridX       = nil
local gridY       = nil
local gridOriginX = 0
local gridOriginY = 0
local gridWidth   = 0
local gridHeight  = 0
local gridPainter = nil   -- cell painter, rebuilt each frame in drawTracker; hit-test reads its fromScreen so draw and hit can't drift

local chanX, chanW, chanOrder, totalWidth = {}, {}, {}, 0

--contract: clears col.x on every col before assigning; off-screen cols stay nil
local function layoutColumns(cols, scrollCol)
  for _, col in ipairs(cols) do col.x = nil end
  local cX, cW, cOrder = {}, {}, {}
  local cx = 0
  for i = scrollCol, #cols do
    local col = cols[i]
    if cx + col.width > gridWidth then break end
    col.x = cx
    local chan = col.midiChan
    if cX[chan] == nil then
      cX[chan] = cx
      util.add(cOrder, chan)
    end
    cW[chan] = (cx + col.width) - cX[chan]
    cx = cx + col.width + 1
  end
  return cX, cW, cOrder, math.max(0, cx - 1)
end

local ctx, font, uiFont = gui.ctx, gui.font, gui.uiFont
local dragging    = false   -- tracker-grid selection drag: click → held → release
local curveEd      = util.instantiate('curveEditor', { ctx = ctx, chrome = chrome, page = 'tracker' })
local laneConsumed = false

-- Group quick-verb state and lifetime moved to trackerView (this page is
-- pure render/UI). The 'region' overlay keymap and the
-- tv:wireGroupLifetime call stay here.
local paintLast   = nil     -- region-paint per-cell debounce

----- Cell renderers

local function renderNote(evt, col, row)
  local function noteName(pitch)
    local NOTE_NAMES = {'C-','C#','D-','D#','E-','F-','F#','G-','G#','A-','A#','B-'}
    local oct = math.floor(pitch / 12) - 1
    local octChar = oct >= 0 and tostring(oct) or 'M'
    return NOTE_NAMES[(pitch % 12) + 1] .. octChar
  end

  local function rightAlign(s, w)
    local pad = w - utf8.len(s)
    return pad > 0 and string.rep(' ', pad) .. s or s
  end

  local showDelay   = col and col.showDelay
  local showSample  = col and col.trackerMode
  local cellWidth   = tv:cellWidth()
  local octaveWidth = tv:octaveWidth()
  local blank      = string.rep('·', cellWidth)   -- cellWidth dots = empty pitch field

  if not evt then
    local s = blank .. (showSample and ' ··' or '') .. ' ··'
    if showDelay then s = s .. ' ···' end
    return s
  end

  local label
  if evt.type ~= 'pa' then
    local note, octave = tv:noteProjection(evt)
    if note then
      -- Both parts right-aligned in their own fields (note field = cellWidth -
      -- octaveWidth) so the separator and octave units keep fixed columns.
      label = rightAlign(note, cellWidth - octaveWidth) .. rightAlign(octave, octaveWidth)
    else
      label = rightAlign(noteName(evt.pitch), cellWidth)
    end
  end
  local isPA      = evt.type == 'pa'
  local noteTxt   = isPA and blank or label
  local velTxt    = evt.vel and string.format('%02X', evt.vel) or '··'
  local sampleTxt = showSample and (' ' .. (isPA and '··' or string.format('%02X', evt.sample or 0))) or ''
  local text      = noteTxt .. sampleTxt .. ' ' .. velTxt

  -- Sample digits at cellWidth+2, +3 (after note label + trailing space).
  -- Shadowed and negative-delay overrides occupy disjoint ranges.
  local overrides
  if showSample and evt.sampleShadowed then
    overrides = { [cellWidth + 2] = 'shadowed', [cellWidth + 3] = 'shadowed' }
  end

  -- delayC is the realised-frame delay; divergence (delay ~= delayC) means
  -- the authored intent couldn't be realised (raw clamped at 0 or by
  -- step 4.8's same-pitch onset floor). tp signals it with a small star.
  local divergent = evt.delayC ~= nil and evt.delayC ~= (evt.delay or 0)

  if showDelay then
    local d = evt.delay or 0
    if d == 0 then
      return text .. ' ···', nil, overrides, divergent
    end
    text = text .. ' ' .. string.format('%03d', math.abs(d))
    if d < 0 then
      local n = utf8.len(text)   -- display columns, not bytes (note label may be multibyte)
      overrides = overrides or {}
      overrides[n-2], overrides[n-1], overrides[n] = 'negative', 'negative', 'negative'
    end
  end
  return text, nil, overrides, divergent
end

local function renderPB(evt)
  if evt and not evt.hidden and evt.val then
    if evt.val < 0 then return string.format('%04d', math.abs(evt.val)), 'negative'
    else return string.format('%04d', math.floor(evt.val)) end
  else return '····' end
end

local function renderCC(evt)
  if evt and evt.val then return string.format('%02X', evt.val)
  else return '··' end
end

local renderFns = {
  note = renderNote,
  pb   = renderPB,
  cc   = renderCC,
  pa   = renderCC,
  at   = renderCC,
  pc   = renderCC,
}

local function renderCell(evt, col, row)
  local fn = renderFns[col.type]
  if fn then return fn(evt, col, row) end
end

-- Offset of the gap before the 3 delay digits in a note cell (* marker slot).
-- Layout: pitch(W) + optional sample(3) + ' ' + vel(2); W = active cellWidth.
local function delayMarkerOffset(col, cellWidth)
  return cellWidth + (col.trackerMode and 3 or 0) + 1 + 2
end

-- The fx badge sits in the pre-vel separator slot -- one column inboard of
-- the delay-marker slot, so the two markers never collide.
local function fxMarkerOffset(col, cellWidth)
  return cellWidth + (col.trackerMode and 3 or 0)
end

----- Drawing

-- A cell adapter over the shared painter: methods speak grid CELLS (integer
-- col/row), the painter maps them to screen through one transform. gX/gY are
-- odd integers, so an integer cell already lands on a whole pixel; snap rounds
-- the fractional cases (centred text, the inset cursor box) crisp, the way the
-- old per-call math.floor did. text is monospace by cell, not by glyph advance.
local function printer(ctx, gX, gY, x0, y0)
  local p  = painter.new(ctx, chrome, { ox = x0, oy = y0, sx = gX, sy = gY, snap = true }, 'tracker')
  local pt = {}

  -- One glyph per cell: advance by a whole cell so the grid stays aligned
  -- regardless of the font's natural glyph advance.
  local function cellText(lx, ly, txt, colour, font, size)
    local i = 0
    for char in txt:gmatch(utf8.charpattern) do
      p.text(lx + i, ly, colour, char, font, size)
      i = i + 1
    end
  end

  -- Logical x that centres txt (measured at font/size) across cells x1..x2.
  local function centreX(x1, x2, txt, font, size)
    return x1 + ((x2 - x1 + 1) - p.measure(txt, font, size) / gX) / 2
  end

  function pt:text(x, y, txt, colour, font)
    cellText(x, y, txt, colour, font, font and 15 or nil)
  end

  function pt:textCentred(x1, x2, y, txt, colour)
    cellText(centreX(x1, x2, txt), y, txt, colour)
  end

  function pt:textCentredSmall(x1, x2, y, txt, size, colour, fnt)
    fnt = fnt or font
    p.text(centreX(x1, x2, txt, fnt, size), y, colour, txt, fnt, size)
  end

  -- A bound cc column's header: the param name one glyph per line, reading
  -- down, bottom-anchored where the horizontal labels sit.
  function pt:textVertical(x1, x2, yBottom, txt, font, size, colour)
    local glyphs = {}
    for char in txt:gmatch(utf8.charpattern) do glyphs[#glyphs + 1] = char end
    for i, char in ipairs(glyphs) do
      p.text(centreX(x1, x2, char, font, size),
             yBottom - (#glyphs - i + 1) * size / gY, colour, char, font, size)
    end
  end

  -- Small glyph centred in a single cell: the * tp drops by a note whose
  -- authored delay could not be realised (delay ~= delayC).
  function pt:smallGlyph(x, y, txt, size, colour)
    local lx = x + (1 - p.measure(txt, font, size) / gX) / 2
    local ly = y + (1 - size / gY) / 2
    p.text(lx, ly, colour, txt, font, size)
  end

  function pt:vLine(x, y1, y2, colour)
    p.segment(x, y1, x, y2 + 1, colour)
  end

  function pt:hLine(x1, x2, y, colour, yOff)
    local ly = y + (yOff or 0)
    p.segment(x1, ly, x2 + 1, ly, colour)
  end

  function pt:box(x1, x2, y1, y2, colour)
    p.fill({ x0 = x1, y0 = y1, x1 = x2 + 1, y1 = y2 + 1 }, colour)
  end

  return pt, p   -- p: the raw painter, for cell-edge strokes and the hit-test inverse
end

--contract: returns 0 when laneStrip.visible is false; layout and draw branch on this
local function laneStripRows()
  if not cm:get('laneStrip.visible') then return 0 end
  return cm:get('laneStrip.rows') or 0
end

-- Localize the picked temper into the project library if absent, so the project
-- carries every temper it references (mirrors swing's setSwingSlot).
local pickTemper = util.atomic('Set temper', function(name)
  if name and not (cm:getAt('project', 'tempers') or {})[name] then
    tv:setTemper(name, tuning.findTemper(name, cm:get('tempers')))
  end
  tv:setTemperSlot(name)
end)

local pickSwing    = util.atomic('Set swing',        function(name)       tv:setSwingSlot(name)          end)
local pickColSwing = util.atomic('Set column swing', function(chan, name) tv:setColSwingSlot(chan, name) end)

-- 'identity' is the explicit no-swing sentinel (schema default); shown as
-- "Off" in the button, hidden from the picker rows.
local SWING_PRESET_EXCLUDE  = { identity = true }
-- 12EDO is the temper floor: shown by name as the active default, hidden from the +preset rows.
local TEMPER_PRESET_EXCLUDE = { ['12EDO'] = true }

-- Hex stays visible when unassigned so `<`/`>` advertise their step.
-- No "Off" row — every slot is real.
local function drawSampleDropdown()
  local cur     = cm:get('currentSample')
  local entries = ds:get('slotEntries') or {}
  local curName = entries[cur] and entries[cur].name
  local indices = {}
  for idx, e in pairs(entries) do
    if e.path then indices[#indices + 1] = idx end
  end
  table.sort(indices)
  local items = {}
  for _, idx in ipairs(indices) do
    items[#items + 1] = {
      label   = string.format('%02X  %s', idx, entries[idx].name or ''),
      key     = idx,
      group   = 1,
      current = idx == cur,
    }
  end
  chrome.drawPicker {
    kind        = 'sample',
    heading     = 'Sample',
    buttonLabel = string.format('%02X', cur) .. (curName and (' ' .. curName) or ''),
    width       = 220,
    items       = items,
    onPick      = util.atomic('Set sample', function(idx) cm:set('take', 'currentSample', idx) end),
  }
end

-- Each render closure reads cm/tv fresh; segments declared once, reused per frame.
--shape: ToolbarSegment = { id, render = fn(), visible? = fn() -> bool }
local toolbarSegments = {
  {
    id = 'track',
    render = function()
      chrome.headingLabel('Track')
      ImGui.SameLine(ctx, 0, 8)
      local curIdx = tv:currentTrackIdx()
      local items, curName = {}, nil
      for _, tr in ipairs(arrange().tracks()) do
        local isCur = tr.idx == curIdx
        if isCur then curName = tr.name end
        items[#items + 1] = {
          label   = tr.name ~= '' and tr.name or ('Track ' .. (tr.idx + 1)),
          key     = tr.idx, group = 1, current = isCur,
        }
      end
      chrome.drawPicker {
        kind        = 'track',
        buttonLabel = (curName and curName ~= '' and curName) or ('Track ' .. (curIdx + 1)),
        width       = 160, items = items, onPick = function(idx) tv:pickTrack(idx) end,
      }
    end,
  },
  {
    id = 'take',
    render = function()
      chrome.headingLabel('Take')
      ImGui.SameLine(ctx, 0, 8)
      local trackIdx = tv:currentTrackIdx()
      local curSlot  = tv:currentSlotIdx()
      local items, curName = {}, nil
      for _, slot in ipairs(arrange().midiSlots(trackIdx)) do
        local name = slot.name ~= '' and slot.name or arrange().keyForSlot(slot.idx)
        if slot.idx == curSlot then curName = name end
        items[#items + 1] = { label = name, key = slot.idx, group = 1, current = slot.idx == curSlot }
      end
      chrome.drawPicker {
        kind        = 'take',
        buttonLabel = curName or '\xe2\x80\x94',
        width       = 160, items = items, onPick = function(idx) tv:pickTake(idx) end,
      }
    end,
  },
  {
    id = 'rowsPerBeat',
    render = function()
      ImGui.AlignTextToFramePadding(ctx)
      chrome.headingLabel('RPB')
      ImGui.SameLine(ctx, 0, 8)
      local changed, n = chrome.numberStepper('rpb', cm:get('rowPerBeat'), { min = 1, max = 32, align = 'center' })
      if changed then tv:setRowPerBeat(n) end
    end,
  },
  {
    id = 'tuning',
    render = function()
      chrome.headingLabel('Tuning')
      ImGui.SameLine(ctx, 0, 8)
      local cur = cm:get('temper')
      chrome.drawPicker {
        kind        = 'temper',
        buttonLabel = cur or 'Off',
        width       = 120,
        items       = chrome.libPicker('tempers', cur, TEMPER_PRESET_EXCLUDE),
        onPick      = pickTemper,
      }
      ImGui.SameLine(ctx, 0, 6)
      if ImGui.Button(ctx, 'edit##editTemper') then cmgr:invoke('editTuning') end
    end,
  },
  {
    id = 'swing',
    render = function()
      chrome.headingLabel('Swing')
      ImGui.SameLine(ctx, 0, 8)
      do
        local cur = (ds:get('swing') or {}).global
        chrome.drawPicker {
          kind        = 'swing', heading = 'Take',
          buttonLabel = (not cur or cur == 'identity') and 'Off' or cur,
          width       = 120,
          items       = chrome.libPicker('swings', cur, SWING_PRESET_EXCLUDE),
          onPick      = pickSwing,
        }
      end
      -- Per-column swing in the same segment; channel from cursor's column.
      local cursorCol = tv.grid.cols[tv:ec():col()]
      local chan      = cursorCol and cursorCol.midiChan
      ImGui.SameLine(ctx, 0, 8)
      chrome.disabledIf(not chan, function()
        local cur = chan and (ds:get('swing') or {})[chan] or nil
        chrome.drawPicker {
          kind        = 'colSwing', heading = 'Ch',
          buttonLabel = cur or 'Off',
          width       = 120,
          items       = chrome.libPicker('swings', cur, SWING_PRESET_EXCLUDE),
          onPick      = function(name) pickColSwing(chan, name) end,
        }
      end)
      ImGui.SameLine(ctx, 0, 8)
      if ImGui.Button(ctx, 'edit##editSwing') then cmgr:invoke('editSwing') end
    end,
  },
  {
    id      = 'sample',
    visible = function() return cm:get('trackerMode') end,
    render  = function() drawSampleDropdown() end,
  },
  {
    id = 'graph',
    render = function()
      chrome.headingLabel('Graph')
      ImGui.SameLine(ctx, 0, 8)
      local cv, newVis = chrome.checkbox('##', cm:get('laneStrip.visible'))
      if cv then cm:set('global', 'laneStrip.visible', newVis) end
    end,
  },
}

-- Bound cc columns drop the 'CC' label for their param name written
-- vertically; names trim to VNAME_MAX chars as a hard upper bound.
local VNAME_MAX = 14

local function vnameSize() return math.floor(gui.fontSize.ui * 0.8) end

-- Bottom gap under a vertical name, in rows: clear of the grid's top rule
-- with a couple of px of breathing room.
local function vnameGap() return 0.35 + 5 / gridY end

-- Rotated param name, trimmed to fit the fixed header. Binary search finds
-- the longest prefix whose rotated strip fits, exact under variable-width fonts.
local function vname(label)
  local cut = utf8.offset(label, VNAME_MAX + 1)
  label = cut and label:sub(1, cut - 1) or label

  local len = utf8.len(label) or #label
  if len == 0 then return label end
  local budget = (HEADER - vnameGap()) * gridY

  local function prefixFitting(n)
    local c = utf8.offset(label, n + 1)
    local s = c and label:sub(1, c - 1) or label
    local _, stripH = painter.measureRotated(ctx, s, vnameSize())
    return (stripH or n * gui.fontSize.ui) <= budget, s
  end

  local full, whole = prefixFitting(len)
  if full then return whole end

  local lo, hi, best = 1, len, nil
  while lo <= hi do
    local mid = (lo + hi) // 2
    local fits, s = prefixFitting(mid)
    if fits then best, lo = s, mid + 1 else hi = mid - 1 end
  end
  return best or (select(2, prefixFitting(1)))
end

--contract: must run before draws reading chanX/chanW/chanOrder/totalWidth/gridHeight
--contract: calls tv:setGridSize so tv scroll math sees the live viewport
local function computeLayout(budgetW, budgetH)
  local grid = tv.grid
  local _, scrollCol = tv:scroll()

  if not gridX then
    local charW, charH = ImGui.CalcTextSize(ctx, 'W')
    gridX = 2 * math.ceil(charW / 2) - 1
    gridY = 2 * math.ceil(charH / 2) - 1
  end

  gridWidth  = math.max(1, math.floor(budgetW / gridX) - GUTTER)
  local laneRows = laneStripRows()
  gridHeight = math.max(1, math.floor(budgetH / gridY) - HEADER - 1 - laneRows)
  tv:setGridSize(gridWidth, gridHeight)

  chanX, chanW, chanOrder, totalWidth = layoutColumns(grid.cols, scrollCol)
end

----- Lane strip

--invariant: lane strip renders only cc/pb/at; other types show as tinted background
local laneRenderable = { cc = true, pb = true, at = true }

local LANE_ROW_MIN = 3
local LANE_ROW_MAX = 32

--contract: publishes laneConsumed=true if curve editor claimed input this frame
--contract: handleMouse short-circuits on laneConsumed
local function drawLaneStrip()

  local laneRows = laneStripRows()
  if laneRows <= 0 then laneConsumed = false; return end

  local px, py    = ImGui.GetCursorScreenPos(ctx)
  local x0        = px + GUTTER * gridX
  local y0        = py
  local w         = totalWidth * gridX
  local h         = laneRows  * gridY
  local p         = painter.new(ctx, chrome, {}, 'tracker')
  local scrollRow = select(1, tv:scroll())
  local numRows   = tv.grid.numRows or 0
  -- rowSpan = rows actually rendered (matches grid below).
  local rowSpan   = math.max(1, math.min(gridHeight, numRows - scrollRow))
  local function rowToX(row) return x0 + (row - scrollRow) / rowSpan * w end

  local pad  = gridY / 2
  local yTop = y0 + pad
  local yBot = y0 + h - pad

  if w > 0 then
    for row = scrollRow, scrollRow + rowSpan - 1 do
      local x = math.floor(rowToX(row))
      local isBar, isBeat = tv:rowBeatInfo(row)
      if isBar or isBeat then
        local x2 = math.floor(rowToX(row + 1))
        p.fill({ x0 = x, y0 = yTop, x1 = x2, y1 = yBot }, isBar and 'rowBarStart' or 'rowBeat')
      end
      p.segment(x, yTop, x, yBot, 'laneRowDivider')
    end
  end

  -- Claim the curve rect as a real item so empty-space drags don't
  -- fall through to the parent window. IsItemActive keeps the strip
  -- "hovered" through a held drag even if the mouse leaves the rect.
  local cbX, cbY = ImGui.GetCursorScreenPos(ctx)
  ImGui.SetCursorScreenPos(ctx, x0, yTop)
  ImGui.InvisibleButton(ctx, '##laneStripHit', math.max(1, w), math.max(1, yBot - yTop))
  local stripHovered = ImGui.IsItemHovered(ctx) or ImGui.IsItemActive(ctx)
  ImGui.SetCursorScreenPos(ctx, cbX, cbY)

  laneConsumed = false
  local colIdx = tv:ec():col()
  local col    = tv.grid.cols[colIdx]
  if w > 0 and col and laneRenderable[col.type] then
    local chan = col.midiChan
    local visible = {}
    for _, evt in ipairs(col.events) do
      if not evt.hidden then util.add(visible, evt) end
    end

    local vMin, vMax
    if col.type == 'pb' then
      local cents = (cm:get('pbRange') or 2) * 100
      vMin, vMax = -cents, cents
    else
      vMin, vMax = 0, 127
    end

    laneConsumed = curveEd:frame {
      rect     = { x0 = x0, yTop = yTop, w = w, h = yBot - yTop },
      vMin = vMin, vMax = vMax,
      tMin = scrollRow, tMax = scrollRow + rowSpan,
      events    = visible,
      tOf       = function(evt) return tv:ppqToRow(evt.ppq, chan) end,
      -- t is in row-space; map fracT back to ppq before sampling so
      -- tv:rowToPPQ's integer rounding doesn't plateau the curve.
      evalCurve = function(A, B, fracT)
        local fracP = A.ppq + fracT * (B.ppq - A.ppq)
        return tv:sampleCurve(A, B, fracP)
      end,
      snap    = function(t) return util.round(t) end,
      hovered = stripHovered,
      dragId  = colIdx,
      colours = {
        axis         = 'laneAxis',
        envelope     = 'laneEnvelope',
        anchor       = 'laneAnchor',
        anchorActive = 'laneAnchorActive',
      },
      callbacks = {
        onMove     = function(idx, newT, newVal) tv:moveLaneEvent(col, idx, newT, newVal) end,
        onMoveFree = function(idx, newT, newVal) tv:moveLaneEvent(col, idx, newT, newVal) end,
        onInsert   = function(t, val) return tv:addLaneEvent(col, colIdx, tv:rowToPPQ(t, chan), val) end,
        onDelete     = function(idx)      tv:deleteLaneEvent(col, idx) end,
        onTension    = function(idx, tau) tv:setLaneTension (col, idx, tau) end,
        onCycleShape = function(idx)      tv:cycleLaneShape (col, idx) end,
      },
    }
  end

  if w > 0 then
    p.stroke({ x0 = x0, y0 = yTop, x1 = x0 + w, y1 = yBot }, 'rowBeat', 1)
  end

  ImGui.Dummy(ctx, (totalWidth + GUTTER) * gridX, h)

  local cx, cy = ImGui.GetCursorScreenPos(ctx)
  local rows = cm:get('laneStrip.rows') or 0
  ImGui.SetCursorScreenPos(ctx, px - 2, yTop)
  chrome.pushChromeStyles()
  if ImGui.SmallButton(ctx, '-##laneRows') then
    cm:set('global', 'laneStrip.rows', math.max(LANE_ROW_MIN, rows - 1))
  end
  ImGui.SameLine(ctx, 0, 2)
  if ImGui.SmallButton(ctx, '+##laneRows') then
    cm:set('global', 'laneStrip.rows', math.min(LANE_ROW_MAX, rows + 1))
  end
  chrome.popChromeStyles()
  ImGui.SetCursorScreenPos(ctx, cx, cy)
end

--contract: assumes computeLayout ran this frame; reads chanX/W/Order, gridOriginX/Y
-- Bottom header row for a note column: one ui-font label per part, centred
-- over that part's char span (PITCH/VEL/DELAY/SAMP). Replaces the old lane number.
local PART_LABEL = { pitch = 'PITCH', sample = 'SAMP', vel = 'VEL', delay = 'DELAY' }

local function notePartHeaders(col)
  local headers, partAt, stopPos = {}, col.partAt, col.stopPos
  local s = 1
  while s <= #partAt do
    local name, e = partAt[s], s
    while e < #partAt and partAt[e + 1] == name do e = e + 1 end
    headers[#headers + 1] = {
      x1 = col.x + stopPos[s], x2 = col.x + stopPos[e], label = PART_LABEL[name],
    }
    s = e + 1
  end
  return headers
end

local function drawTracker()
  local grid = tv.grid
  local ec = tv:ec()
  local cursorRow, cursorCol, cursorStop = ec:pos()
  local scrollRow, scrollCol, lastVisCol = tv:scroll()

  local px, py = ImGui.GetCursorScreenPos(ctx)
  gridOriginX  = px + GUTTER * gridX
  gridOriginY  = py + HEADER * gridY

  local numRows = grid.numRows or 0
  local draw, p = printer(ctx, gridX, gridY, gridOriginX, gridOriginY)
  gridPainter = p
  -- Screen-space painter (identity transform) for draws sized in pixels, not
  -- cells: the tail bracket's arc radius and the temperament rule's tick. Colour
  -- by name like any painter; positions pass straight through unconverted.
  local screenPainter = painter.new(ctx, chrome, {}, 'tracker')

  -- Solo (amber) wins over mute (red): audibility semantic.
  draw:text(-GUTTER, -HEADER, 'Row', 'accent')
  -- Channel banner centres over the note columns only — automation/cc
  -- columns protrude past them and would pull the label off-centre.
  local noteSpan = {}
  for _, col in ipairs(grid.cols) do
    if col.x and col.type == 'note' then
      local span = noteSpan[col.midiChan]
      if span then span.x2 = col.x + col.width - 1
      else noteSpan[col.midiChan] = { x1 = col.x, x2 = col.x + col.width - 1 } end
    end
  end
  for chan = 1, 16 do
    local span = noteSpan[chan]
    if span then
      local key = tv:isChannelSoloed(chan) and 'solo'
               or tv:isChannelMuted(chan)  and 'mute'
               or 'tracker.chanHeader'
      draw:textCentred(span.x1, span.x2, -HEADER, 'Ch ' .. chan, key)
    end
  end
  for _, col in ipairs(grid.cols) do
    if col.x then
      local xr = col.x + col.width - 1
      local binding = col.type == 'cc' and tv:paramBinding(col.midiChan, col.cc)
      if binding then
        local vertical = vname(binding.label)
        if not p.textUp((col.x + xr + 1) / 2, -vnameGap(), 'text', vertical, vnameSize()) then
          draw:textVertical(col.x, xr, -vnameGap(), vertical, uiFont, gui.fontSize.ui, 'text')
        end
      else
        draw:textCentred(col.x, xr, -2.1, col.label, 'text')
        if col.type == 'note' then
          for _, h in ipairs(notePartHeaders(col)) do
            draw:textCentredSmall(h.x1, h.x2, -1.2 + 2 / gridY, h.label, vnameSize(), 'tracker.partHeader', uiFont)
          end
        elseif col.type == 'cc' then
          draw:textCentredSmall(col.x, xr, -1.2 + 2 / gridY, tostring(col.cc), vnameSize(), 'tracker.partHeader', uiFont)
        end
      end
    end
  end

  draw:hLine(-GUTTER, totalWidth - 1, 0, 'text', -0.25)

  -- for i = 1, #chanOrder - 1 do
  --   local chan = chanOrder[i]
  --   draw:vLine(chanX[chan] + chanW[chan], -HEADER, gridHeight - 1, 'separator')
  -- end

  for y = 0, gridHeight - 1 do
    local row = scrollRow + y
    if row >= numRows then break end

    local isBarStart, isBeatStart = tv:rowBeatInfo(row)

    if isBarStart or isBeatStart then
      local style = isBarStart and 'rowBarStart' or 'rowBeat'
      for chan = 1, 16 do
        if chanX[chan] then
          draw:box(chanX[chan], chanX[chan] + chanW[chan] - 1, y, y, style)
        end
      end
    end

    local rowNumCol = (isBeatStart and 'text') or 'inactive'
    draw:text(-GUTTER, y, string.format('%03d', row), rowNumCol)
  end

  -- Mirror regions. Before tails/cells so per-cell text reads over the
  -- wash. A per-group hue washes the whole instance area (membership =
  -- selected streams x time span); overridden/conflicted cells
  -- overpaint a louder state colour. The wash is always on (group viz);
  -- the region-cursor instance's 2px border + the x=-1 cursor gutter
  -- are region-mode affordances, shown only while authoring. Outside
  -- region mode the instance the caret sits inside gets a quieter 1px
  -- border (a "you are here"). A conflicted instance always outlines --
  -- a data problem worth seeing in any mode.
  local logPerRow = tv:logPerRow()
  local cursorPpq = cursorRow * logPerRow
  local inRegion  = tv:ec():isInRegionMode()
  local rc        = inRegion and tv:ec():regionCursor()
  for _, inst in ipairs(tv:eachInstance()) do
    local rect  = inst.rect
    local ppqLo = inst.anchor.ppq
    local ppqHi = ppqLo + rect.dur
    local yLo = math.max(math.floor(ppqLo / logPerRow + 0.5) - scrollRow, 0)
    local yHi = math.min(math.floor(ppqHi / logPerRow + 0.5) - scrollRow, gridHeight)
    if yHi > yLo then
      local baseTint = groups.regionKey(inst.colour, 'tint')
      local xMin, xMax, conflicted, cursorIn
      for x, col in ipairs(grid.cols) do
        if col.x then
          local off, sid = tv:streamRefAt(x, inst.anchor.chan)
          if off and rect.streams[off] and rect.streams[off][sid] then
            local x1, x2 = col.x, col.x + col.width - 1
            xMin = math.min(xMin or x1, x1)
            xMax = math.max(xMax or x2, x2)
            draw:box(x1, x2, yLo, yHi - 1, baseTint)
            for y = yLo, yHi - 1 do
              local evt = col.cells and col.cells[scrollRow + y]
              local st  = evt and evt.uuid and tv:stateOf(evt.uuid)
              if st == 'conflicted' then conflicted = true end
              local key = st and groups.tintKey(st)
              if key then draw:box(x1, x2, y, y, key) end
            end
            if x == cursorCol and cursorPpq >= ppqLo and cursorPpq < ppqHi then
              cursorIn = true
            end
          end
        end
      end
      if xMin then
        local isCursorInst = rc and rc.groupId == inst.groupId
                                and rc.instId == inst.instId
        local plainCursorIn = cursorIn and not inRegion
        if conflicted or isCursorInst or plainCursorIn then
          local outlineName = groups.outlineKey(
            conflicted and 'conflicted' or 'synced', inst.colour)
          p.stroke({ x0 = xMin, y0 = yLo, x1 = xMax + 1, y1 = yHi },
            outlineName, isCursorInst and 2 or 1)
        end
        if inRegion and cursorIn then draw:box(-1, -1, yLo, yHi - 1, baseTint) end
      end
    end
  end

  local viewTop  = scrollRow
  local viewBot  = scrollRow + gridHeight
  for _, col in ipairs(grid.cols) do
    if col.x and col.tails then
      for _, tail in ipairs(col.tails) do
        if tail.endRow > viewTop and tail.startRow < viewBot then
          local y1 = gridOriginY + math.max(tail.startRow - scrollRow, 0) * gridY
          local y2 = gridOriginY + math.min(tail.endRow - scrollRow, gridHeight) * gridY
          local x1 = gridOriginX + col.x * gridX
          local r  = 5
          screenPainter.pathClear()
          screenPainter.pathArcTo(x1, y1 + r, r, 3 * math.pi / 2, math.pi)
          screenPainter.pathLineTo(x1 - r, y1 + r + 1)
          screenPainter.pathLineTo(x1 - r, y2 - r - 1)
          screenPainter.pathArcTo(x1, y2 - r, r, math.pi, math.pi / 2)
          screenPainter.pathStroke('tail', 1.5)
          screenPainter.pathClear()
        end
      end
    end
  end

  local cellWidth = tv:cellWidth()
  for y = 0, gridHeight - 1 do
    local row = scrollRow + y
    if row >= numRows then break end
    for x, col in ipairs(grid.cols) do
      if col.x then
        local evt = col.cells and col.cells[row]
        local ghost = not evt and col.ghosts and col.ghosts[row]
        local text, textCol, overrides, divergent
        if ghost then
          local cellCol
          text, cellCol = renderCell({ val = ghost.val }, col, row)
          textCol = cellCol == 'negative' and 'ghostNegative' or 'ghost'
        else
          text, textCol, overrides, divergent = renderCell(evt, col, row)
          if col.overflow and col.overflow[row] then textCol, overrides = 'overflow', nil end
          textCol = textCol or 'text'
          if textCol == 'text' and col.offGrid and col.offGrid[row] then
            textCol = 'offGrid'
          end
        end
        local muted = tv:isChannelEffectivelyMuted(col.midiChan)
        if muted then textCol, overrides, divergent = 'inactive', nil, false end
        if not text then text = '' end
        local cx, i = col.x, 0
        for ch in text:gmatch(utf8.charpattern) do
          i = i + 1
          local c = (overrides and overrides[i]) or (ch == '·' and 'inactive' or textCol)
          draw:text(cx, y, ch, c)
          cx = cx + 1
        end
        if divergent and col.showDelay then
          draw:smallGlyph(col.x + delayMarkerOffset(col, cellWidth), y, '*', 9, textCol)
        end
        if evt and evt.fx and evt.fx[1] and col.type == 'note' and not muted then
          draw:smallGlyph(col.x + fxMarkerOffset(col, cellWidth), y, '~', 9, 'accent')
        end
      end
    end
  end

  if tv:activeTemper() then
    for _, col in ipairs(grid.cols) do
      if col.x and col.type == 'note' and col.cells then
        local x0 = gridOriginX + col.x * gridX
        local x1 = x0 + cellWidth * gridX
        local cx = (x0 + x1) / 2
        local halfW = (x1 - x0) / 2 - 1
        for y = 0, gridHeight - 1 do
          local row = scrollRow + y
          if row >= numRows then break end
          local evt = col.cells[row]
          if evt and evt.pitch then
            local _, _, gap, halfGap = tv:noteProjection(evt)
            if gap and gap ~= 0 and halfGap > 0 then
              local yTop = gridOriginY + y * gridY + 1
              local offset = util.clamp(gap / halfGap, -1, 1) * halfW
              screenPainter.line(x0, yTop, x1, yTop, 'accent', 1)
              local tickX = cx + offset
              screenPainter.line(tickX, yTop - 1, tickX, yTop + 2, 'accent', 1)
            end
          end
        end
      end
    end
  end

  if ec:hasSelection() then
    local r1, r2, c1i, c2i = ec:region()
    if c2i >= scrollCol and c1i <= lastVisCol then
      local yFrom = math.max(r1 - scrollRow, 0)
      local yTo   = math.min(r2 - scrollRow, gridHeight - 1)
      local c1, c2 = grid.cols[c1i], grid.cols[c2i]
      local s1   = ec:selectionStopSpan(c1i)
      local _,s2 = ec:selectionStopSpan(c2i)
      local x1 = c1.x and c1.x + c1.stopPos[s1]  or 0
      local x2 = c2.x and c2.x + c2.stopPos[s2]  or totalWidth
      draw:box(x1, x2, yFrom, yTo, 'selection')
    end
  end

  local col = grid.cols[cursorCol]
  if col and col.x then
    local stopOffset = (col.stopPos and col.stopPos[cursorStop]) or 0
    local charX = col.x + stopOffset
    local charY = cursorRow - scrollRow
    draw:box(charX, charX, charY+0.1, charY-0.1, 'cursor')
    local evt = col.cells and col.cells[cursorRow]
    local text = renderCell(evt, col, cursorRow)
    local ch = utf8.offset(text, stopOffset + 1) and text:sub(utf8.offset(text, stopOffset + 1), utf8.offset(text, stopOffset + 2) - 1) or ''
    if ch ~= '' then draw:text(charX, charY, ch, 'cursorText') end
  end

  -- Reserve content space so ImGui knows the drawable area
  ImGui.Dummy(ctx, (totalWidth + GUTTER) * gridX, (gridHeight + HEADER) * gridY)
end

----- Param palette

-- Remove the cursor's automation column; confirm first if it holds events.
local function removeAutomation(col)
  if #col.events > 0 then
    modalHost:openConfirm{
      title    = 'Remove automation',
      prompt   = ('Column has %d event%s — delete them with it? (y/n)')
                   :format(#col.events, #col.events == 1 and '' or 's'),
      callback = function(yes) if yes then tv:unautomateParam() end end,
    }
  else
    tv:unautomateParam()
  end
end

local function paletteActions()
  local col   = tv.grid.cols[tv:ec():col()]
  local bound = col and col.type == 'cc' and tv:paramBinding(col.midiChan, col.cc)
  chrome.disabledIf(not tv:paletteParam(), function()
    if ImGui.Button(ctx, 'automate##param') then tv:automateParam() end
  end)
  ImGui.SameLine(ctx, 0, 4)
  chrome.disabledIf(not bound, function()
    if ImGui.Button(ctx, 'remove##param') then removeAutomation(col) end
  end)
end

-- Palette focus tri-state: 'find' | 'tree' | nil (grid). Gates focusState
-- and handleKeys. See docs/trackerRender.md § Param palette — keyboard focus.
local paletteFocus = nil
local focusFindReq = false   -- one-shot: focus the find box next draw
local defocusReq   = false   -- one-shot: park focus on the sink, leaving the find box
local releaseReq   = false   -- one-shot: drop paletteFocus to nil at the sink (Esc/Enter)
local scrollReq    = false   -- one-shot: scroll the cursor row into view next draw

local function paletteFindBox()
  ImGui.SetNextItemWidth(ctx, -1)
  if focusFindReq then ImGui.SetKeyboardFocusHere(ctx); focusFindReq, paletteFocus = false, 'find' end
  local changed, text = ImGui.InputTextWithHint(ctx, '##paramFilter', 'find', tv:paletteFilter())
  if changed then tv:setPaletteFilter(text) end
  return ImGui.IsItemActive(ctx)
end


-- Made on first draw + attached so it outlives the defer cycle. Per-frame
-- creation trips ReaImGui's short-lived guard; module-load faults the test fake.
local paramClipper = nil

-- Ordered render plan: {kind='heading',text} | {kind='fx',row,open} | {kind='param',row,prm}.
-- Non-empty needle prunes to matched subtrees, forced open — see docs/trackerRender.md § Filtering.
local function buildPlan(rows, needle)
  local plan, heading = {}, nil
  for _, row in ipairs(rows) do
    local section = row.generator and 'generators' or 'fx'
    local shown, shownParams, open
    if needle == '' then
      open  = tv:paletteExpanded()[row.fxGuid] or false
      shown = true
      if open then shownParams = tv:listParams(row.trackGuid, row.fxGuid) end
    else
      shownParams = {}
      for _, prm in ipairs(tv:listParams(row.trackGuid, row.fxGuid)) do
        if (row.name .. ' ' .. prm.name):lower():find(needle, 1, true) then
          shownParams[#shownParams + 1] = prm
        end
      end
      shown, open = #shownParams > 0, true
    end
    if shown then
      if section ~= heading then
        heading = section
        plan[#plan + 1] = { kind = 'heading', text = section }
      end
      plan[#plan + 1] = { kind = 'fx', row = row, open = open }
      for _, prm in ipairs(open and shownParams or {}) do
        plan[#plan + 1] = { kind = 'param', row = row, prm = prm }
      end
    end
  end
  return plan
end

-- Navigable rows in display order; headings are skipped, and so are fx rows
-- when filtering — the cursor then visits matched params only.
local function navRows(plan, paramsOnly)
  local nav = {}
  for _, it in ipairs(plan) do
    if it.kind == 'fx' and not paramsOnly then
      nav[#nav + 1] = { fxGuid = it.row.fxGuid, param = nil, item = it, row = it.row }
    elseif it.kind == 'param' then
      nav[#nav + 1] = { fxGuid = it.row.fxGuid, param = it.prm.index, item = it,
                        row = it.row, prm = it.prm }
    end
  end
  return nav
end

local function navIndex(nav, cur)
  if not cur then return nil end
  for i, e in ipairs(nav) do
    if e.fxGuid == cur.fxGuid and e.param == cur.param then return i end
  end
end

local function selectParam(e)
  tv:setPaletteParam{ trackGuid = e.row.trackGuid, fxGuid = e.fxGuid,
                      param = e.prm.index, label = e.prm.name }
end

-- Apply this frame's palette keys to cursor/expansion. Returns true when it
-- changed the focus mode (Tab/Esc/Enter-automate) so the caller skips reconcile.
local function handlePaletteKeys(nav)
  local press = function(k) return ImGui.IsKeyPressed(ctx, k) end
  if press(ImGui.Key_Tab) then
    if paletteFocus == 'find' then paletteFocus, defocusReq = 'tree', true
    else paletteFocus, focusFindReq = 'find', true end
    return true
  end
  if press(ImGui.Key_Escape) then
    -- Defer the focus drop to the sink next frame: keep paletteFocus set
    -- through this frame's focusState so the same Esc isn't dispatched.
    tv:setPaletteFilter(''); defocusReq, releaseReq = true, true
    return true
  end
  if #nav == 0 then return end

  local idx = navIndex(nav, tv:paletteCursor())
  if not idx then idx = 1; tv:setPaletteCursor{ fxGuid = nav[1].fxGuid, param = nav[1].param } end
  -- Up/Down move, clamped — no wrap past the ends. Left/Right drive the tree
  -- unless the find box is editing text. Any move scrolls the cursor in view.
  local treeArrows = paletteFocus == 'tree' or tv:paletteFilter() == ''
  local newIdx = idx
  if press(ImGui.Key_DownArrow) then newIdx = math.min(idx + 1, #nav)
  elseif press(ImGui.Key_UpArrow) then newIdx = math.max(idx - 1, 1)
  elseif treeArrows and press(ImGui.Key_RightArrow) then
    local e = nav[idx]
    if e.param == nil and not e.item.open then tv:setFxExpanded(e.fxGuid, true)
    else newIdx = math.min(idx + 1, #nav) end
  elseif treeArrows and press(ImGui.Key_LeftArrow) then
    local e = nav[idx]
    if e.param == nil and e.item.open then tv:setFxExpanded(e.fxGuid, false)
    elseif e.param ~= nil then
      for j = idx - 1, 1, -1 do
        if nav[j].param == nil then newIdx = j; break end
      end
    end
  end

  local cur = nav[newIdx]
  if newIdx ~= idx then
    scrollReq = true
    tv:setPaletteCursor{ fxGuid = cur.fxGuid, param = cur.param }
    if cur.param then selectParam(cur) end
  end
  if ImGui.GetKeyMods(ctx) == ImGui.Mod_Super and press(ImGui.Key_L) then
    tv:armLearn(cur.row)   -- cur.row is the cursor's fx, whether on it or a child
    if tv:learnFxGuid() then tv:setFxExpanded(cur.row.fxGuid, true) end
  end
  if press(ImGui.Key_Enter) or press(ImGui.Key_KeypadEnter) then
    if cur.param then
      -- Deferred drop (see Esc) so the same Enter doesn't reach the grid.
      selectParam(cur); tv:automateParam()
      tv:setPaletteFilter(''); defocusReq, releaseReq = true, true
      return true
    end
    tv:setFxExpanded(cur.fxGuid, not cur.item.open)
  end
end

-- On a keyboard move, scroll minimally so the just-submitted cursor row stays
-- inside the view; a no-op for mouse moves (scrollReq unset).
local function scrollFollow(onCur)
  if not (scrollReq and onCur) then return end
  scrollReq = false
  local _, rowTop = ImGui.GetItemRectMin(ctx)
  local _, rowBot = ImGui.GetItemRectMax(ctx)
  local _, winTop = ImGui.GetWindowPos(ctx)
  local winBot    = winTop + ImGui.GetWindowHeight(ctx)
  local sY        = ImGui.GetScrollY(ctx)
  if rowTop < winTop then ImGui.SetScrollY(ctx, sY - (winTop - rowTop))
  elseif rowBot > winBot then ImGui.SetScrollY(ctx, sY + (rowBot - winBot)) end
end

local function drawTreeItem(it, cur, showLearn, btnW)
  if it.kind == 'heading' then
    ImGui.TextDisabled(ctx, it.text)
  elseif it.kind == 'fx' then
    local row     = it.row
    local onCur   = cur and cur.fxGuid == row.fxGuid and cur.param == nil
    local availW  = select(1, ImGui.GetContentRegionAvail(ctx))
    local reserve = showLearn and btnW + 28 or 8
    -- AllowOverlap so the learn button drawn on top still takes its clicks.
    local r = chrome.treeRow{ id = 'fx' .. row.fxGuid, label = row.name,
                              hasChildren = true, open = it.open, selected = onCur,
                              reserve = reserve, flags = ImGui.SelectableFlags_AllowOverlap }
    scrollFollow(onCur)
    if r.selected then
      tv:setPaletteCursor{ fxGuid = row.fxGuid, param = nil }
      paletteFocus = 'tree'
    end
    if r.toggled then tv:setFxExpanded(row.fxGuid, not it.open) end
    if showLearn then
      local armed = tv:learnFxGuid() == row.fxGuid
      ImGui.SameLine(ctx, availW - btnW)
      if ImGui.SmallButton(ctx, (armed and 'stop' or 'learn') .. '###L' .. row.fxGuid) then
        tv:armLearn(row)
        if tv:learnFxGuid() then tv:setFxExpanded(row.fxGuid, true) end
      end
    end
  else
    local row   = it.row
    local onCur = cur and cur.fxGuid == row.fxGuid and cur.param == it.prm.index
    -- id from guid+index alone: truncation/width must not remint it.
    local r = chrome.treeRow{ id = 'p' .. row.fxGuid .. it.prm.index, label = it.prm.name,
                              depth = 1, hasChildren = false, selected = onCur,
                              allowDouble = true }
    scrollFollow(onCur)
    if r.selected or r.doubleClicked then
      tv:setPaletteCursor{ fxGuid = row.fxGuid, param = it.prm.index }
      tv:setPaletteParam{ trackGuid = row.trackGuid, fxGuid = row.fxGuid,
                          param = it.prm.index, label = it.prm.name }
      paletteFocus = 'tree'
    end
    if r.doubleClicked then tv:automateParam() end
  end
end

-- Position of the cursor's row in the flat plan, so the clipper can force it
-- in-range for scroll-follow even when it sits just outside the window.
local function planIndexOfCursor(plan, cur)
  if not cur then return nil end
  for i, it in ipairs(plan) do
    local matchFx    = it.kind == 'fx'    and cur.param == nil and it.row.fxGuid == cur.fxGuid
    local matchParam = it.kind == 'param' and it.row.fxGuid == cur.fxGuid and it.prm.index == cur.param
    if matchFx or matchParam then return i end
  end
end

local function drawTree(plan)
  if #plan == 0 then
    ImGui.TextDisabled(ctx, tv:paletteFilter() == '' and '(no fx reachable)' or '(no match)')
    return
  end
  local cur  = tv:paletteCursor()
  local fpx  = ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
  local btnW = ImGui.CalcTextSize(ctx, 'learn') + fpx * 2
  local showLearn = tv:paletteFilter() == ''   -- learn is hidden while filtering

  -- Clip to the visible rows: a fx with hundreds of params must not draw (and
  -- CalcTextSize) every row each frame.
  if not paramClipper then
    paramClipper = ImGui.CreateListClipper(ctx)
    ImGui.Attach(ctx, paramClipper)
  end
  ImGui.ListClipper_Begin(paramClipper, #plan)
  if scrollReq then
    local ci = planIndexOfCursor(plan, cur)
    if ci then ImGui.ListClipper_IncludeItemByIndex(paramClipper, ci - 1) end
  end
  while ImGui.ListClipper_Step(paramClipper) do
    local first, last = ImGui.ListClipper_GetDisplayRange(paramClipper)
    for i = first, last - 1 do
      drawTreeItem(plan[i + 1], cur, showLearn, btnW)
    end
  end
  ImGui.ListClipper_End(paramClipper)
end

-- The 1px vrule + palette child, positioned from the body origin so the split
-- matches arrange/wiring's even though the tracker grid isn't a child window.
local function drawParamPalette(x, y, h)
  chrome.palettePane{
    x = x, y = y, h = h,
    label = 'parameters',
    draw  = function(childFocused)
      paletteActions()
      local findActive = paletteFindBox()
      ImGui.Separator(ctx)

      -- Focus sink: SetKeyboardFocusHere parks here to deactivate the find box
      -- (Tab→tree, Esc/Enter→grid). Kept near the top so scroll never culls it.
      local parking = defocusReq
      if defocusReq then ImGui.SetKeyboardFocusHere(ctx); defocusReq = false end
      if releaseReq then paletteFocus, releaseReq = nil, false end
      ImGui.InvisibleButton(ctx, '##paletteSink', 1, 1)

      local plan = buildPlan(tv:paramTargets(), tv:paletteFilter():lower())
      local focusChanged = paletteFocus and handlePaletteKeys(navRows(plan, tv:paletteFilter() ~= ''))
      drawTree(plan)

      -- Reconcile paletteFocus with ImGui state: find box wins unless parking,
      -- a pane click grabs tree focus, clicking elsewhere releases to the grid.
      if not focusChanged then
        local clicked = ImGui.IsWindowHovered(ctx) and ImGui.IsMouseClicked(ctx, 0)
        if findActive and not parking then paletteFocus = 'find'
        elseif clicked then paletteFocus = paletteFocus or 'tree'
        elseif paletteFocus and not childFocused then paletteFocus = nil end
      end
    end,
  }
end

local function drawStatusBar()
  -- ctx and grid.cols are built together in tv:rebuild; an empty grid
  -- (no take yet on script reopen) means ctx is nil. Match renderBody's
  -- placeholder guard rather than indexing a nil ctx via barBeatSub.
  if #tv.grid.cols == 0 then return end
  local ec = tv:ec()
  local cursorRow, cursorCol = ec:row(), ec:col()
  local rowPerBeat    = cm:get('rowPerBeat')
  local currentOctave = cm:get('currentOctave')
  local advanceBy     = cm:get('advanceBy')
  local sampleSuffix = ''
  if cm:get('trackerMode') then
    local slot  = cm:get('currentSample')
    local entry = (ds:get('slotEntries') or {})[slot]
    local name  = entry and entry.name
    sampleSuffix = string.format(' | Sample: %02X', slot)
                .. (name and (' ' .. name) or '')
  end
  local col      = tv.grid.cols[cursorCol]
  local bar, beat, sub = tv:barBeatSub(cursorRow)
  local colLabel = col and col.label or '?'

  -- statusBar is rendered inside its own chrome BeginChild whose outer
  -- Col_Text push is `statusBar.text`; we just print, no inner push.
  ImGui.Text(ctx, string.format(
    '%s | %d:%d.%d/%d | Octave: %d | Advance: %d%s',
    colLabel, bar, beat, sub, rowPerBeat, currentOctave, advanceBy, sampleSuffix
  ))
end

----- Input

-- Tracker-scope bindings. Globals (playPause, stop) are bound on the
-- root scope by Main(); the dispatcher walks active-then-root.
cmgr:scope('tracker'):bindAll{
  cursorUp               = { ImGui.Key_UpArrow,    {ImGui.Key_P, ImGui.Mod_Super} },
  cursorDown             = { ImGui.Key_DownArrow,  {ImGui.Key_N, ImGui.Mod_Super} },
  cursorLeft             = { ImGui.Key_LeftArrow,  {ImGui.Key_B, ImGui.Mod_Super} },
  cursorRight            = { ImGui.Key_RightArrow, {ImGui.Key_F, ImGui.Mod_Super} },
  prevTrack              = { {ImGui.Key_LeftArrow,  ImGui.Mod_Alt} },
  nextTrack              = { {ImGui.Key_RightArrow, ImGui.Mod_Alt} },
  prevTake               = { {ImGui.Key_UpArrow,    ImGui.Mod_Alt} },
  nextTake               = { {ImGui.Key_DownArrow,  ImGui.Mod_Alt} },
  goTop                  = { ImGui.Key_Home,       {ImGui.Key_Comma,  ImGui.Mod_Ctrl, ImGui.Mod_Shift} },
  goBottom               = { ImGui.Key_End,        {ImGui.Key_Period, ImGui.Mod_Ctrl, ImGui.Mod_Shift} },
  pageUp                 = { ImGui.Key_PageUp },
  pageDown               = { ImGui.Key_PageDown },
  colLeft                = { {ImGui.Key_B, ImGui.Mod_Ctrl} },
  colRight               = { {ImGui.Key_F, ImGui.Mod_Ctrl} },
  channelLeft            = { {ImGui.Key_Tab, ImGui.Mod_Shift} },
  channelRight           = { ImGui.Key_Tab },
  noteOff                = { ImGui.Key_1 },
  shrinkNote             = { {ImGui.Key_UpArrow,  ImGui.Mod_Super, ImGui.Mod_Shift} },
  growNote               = { {ImGui.Key_DownArrow, ImGui.Mod_Super, ImGui.Mod_Shift} },
  nudgeBack              = { {ImGui.Key_UpArrow,   ImGui.Mod_Super} },
  nudgeForward           = { {ImGui.Key_DownArrow,   ImGui.Mod_Super} },
  eventShiftLeft         = {{ImGui.Key_LeftArrow,   ImGui.Mod_Super} },
  eventShiftRight        = {{ImGui.Key_RightArrow,   ImGui.Mod_Super} },
  insertRowCol           = { {ImGui.Key_DownArrow, ImGui.Mod_Ctrl} },
  deleteRowCol           = { {ImGui.Key_UpArrow,   ImGui.Mod_Ctrl} },
  addTypedCol            = { {ImGui.Key_RightArrow, ImGui.Mod_Ctrl} },
  hideExtraCol           = { {ImGui.Key_LeftArrow, ImGui.Mod_Ctrl} },
  delete                 = { ImGui.Key_Period },
  interpolate            = { {ImGui.Key_I, ImGui.Mod_Ctrl} },
  selectUp               = { {ImGui.Key_UpArrow,    ImGui.Mod_Shift} },
  selectDown             = { {ImGui.Key_DownArrow,  ImGui.Mod_Shift} },
  selectLeft             = { {ImGui.Key_LeftArrow,  ImGui.Mod_Shift} },
  selectRight            = { {ImGui.Key_RightArrow, ImGui.Mod_Shift} },
  cycleBlock             = { {ImGui.Key_Space,       ImGui.Mod_Super} },
  cycleVBlock            = { {ImGui.Key_O,           ImGui.Mod_Super} },
  swapBlockEnds          = { {ImGui.Key_GraveAccent, ImGui.Mod_Ctrl} },
  selectClear            = { {ImGui.Key_G, ImGui.Mod_Super} },
  cut                    = { {ImGui.Key_W, ImGui.Mod_Super}, {ImGui.Key_X, ImGui.Mod_Ctrl} },
  copy                   = { {ImGui.Key_W, ImGui.Mod_Ctrl},  {ImGui.Key_C, ImGui.Mod_Ctrl} },
  paste                  = { {ImGui.Key_Y, ImGui.Mod_Super}, {ImGui.Key_V, ImGui.Mod_Ctrl} },
  duplicateDown          = { {ImGui.Key_D, ImGui.Mod_Ctrl} },
  deleteSel              = { ImGui.Key_Delete },
  nudgeCoarseUp          = { {ImGui.Key_Equal, ImGui.Mod_Ctrl} },
  nudgeCoarseDown        = { {ImGui.Key_Minus, ImGui.Mod_Ctrl} },
  nudgeFineUp            = { {ImGui.Key_Equal, ImGui.Mod_Shift} },
  nudgeFineDown          = { {ImGui.Key_Minus, ImGui.Mod_Shift} },
  scaleHalf              = { {ImGui.Key_9, ImGui.Mod_Shift} },  -- '('
  scaleDouble            = { {ImGui.Key_0,  ImGui.Mod_Shift} },  -- ')'
  doubleRPB              = { {ImGui.Key_Equal, ImGui.Mod_Super} },
  halveRPB               = { {ImGui.Key_Minus, ImGui.Mod_Super} },
  setRPB                 = { {ImGui.Key_Z,     ImGui.Mod_Super} },
  takeProperties         = { {ImGui.Key_Backspace, ImGui.Mod_Super} },
  newTakeBelow           = { {ImGui.Key_Enter, ImGui.Mod_Super} },
  duplicateUnpooledBelow = { {ImGui.Key_Enter, ImGui.Mod_Super, ImGui.Mod_Shift} },
  matchGridToCursor      = { {ImGui.Key_M, ImGui.Mod_Super} },
  groupMark              = { {ImGui.Key_M, ImGui.Mod_Ctrl} },
  groupDuplicate         = { {ImGui.Key_D, ImGui.Mod_Ctrl, ImGui.Mod_Shift} },
  groupPaste             = { {ImGui.Key_V, ImGui.Mod_Ctrl, ImGui.Mod_Shift} },
  groupLocalToggle       = { {ImGui.Key_L, ImGui.Mod_Super} },
  regionEnter            = { {ImGui.Key_R, ImGui.Mod_Super} },
  groupInstPrev          = { ImGui.Key_LeftBracket },
  groupInstNext          = { ImGui.Key_RightBracket },
  inputOctaveUp          = { {ImGui.Key_8, ImGui.Mod_Shift} },
  inputOctaveDown        = { ImGui.Key_Slash },
  inputSampleUp          = { {ImGui.Key_Period, ImGui.Mod_Shift} },  -- '>'
  inputSampleDown        = { {ImGui.Key_Comma,  ImGui.Mod_Shift} },  -- '<'
  playFromTop            = { ImGui.Key_F6 },
  playFromCursor         = { ImGui.Key_F7 },
  openTemperPicker       = { {ImGui.Key_T, ImGui.Mod_Super} },
  openSwingPicker        = { {ImGui.Key_S, ImGui.Mod_Super} },
  quantize               = { {ImGui.Key_K, ImGui.Mod_Ctrl} },
  quantizeKeepRealised   = { {ImGui.Key_K, ImGui.Mod_Ctrl, ImGui.Mod_Shift} },
  editNoteFx             = { {ImGui.Key_X, ImGui.Mod_Super} },
}
for i = 0, 9 do
  cmgr:scope('tracker'):bind('advBy' .. i, { {ImGui.Key_0 + i, ImGui.Mod_Ctrl} })
end

----- F1 help manifest — toolbar callouts pinned to their segments, plus a
----- flowed panel of grid/global bindings packed over the grid body.

help:registerPage('tracker', {
  { anchor = 'toolbar.track', place = 'pin', title = 'Track', items = {
    { cmd = 'prevTrack', label = 'Previous track' },
    { cmd = 'nextTrack', label = 'Next track' },
  }},
  { anchor = 'toolbar.take', place = 'pin', title = 'Take', items = {
    { cmd = 'prevTake', label = 'Previous take' },
    { cmd = 'nextTake', label = 'Next take' },
  }},
  { anchor = 'toolbar.rowsPerBeat', place = 'pin', title = 'Rows / beat', items = {
    { cmd = 'doubleRPB', label = 'Double' },
    { cmd = 'halveRPB', label = 'Halve' },
    { cmd = 'setRPB', label = 'Set' },
    { cmd = 'matchGridToCursor', label = 'Match' },
  }},
  { anchor = 'toolbar.tuning', place = 'pin', title = 'Tuning', items = {
    { cmd = 'openTemperPicker', label = 'Pick tuning' },
    { cmd = 'editTuning', label = 'Edit tuning' },
  }},
  { anchor = 'toolbar.swing', place = 'pin', title = 'Swing', items = {
    { cmd = 'openSwingPicker', label = 'Pick swing' },
    { cmd = 'editSwing', label = 'Edit swing' },
  }},
  { anchor = 'toolbar.sample', place = 'pin', title = 'Sample', items = {
    { cmd = 'inputSampleUp', label = 'Sample +' },
    { cmd = 'inputSampleDown', label = 'Sample -' },
  }},
  { anchor = 'body.grid', place = 'flow', title = 'Movement', items = {
    { cmd = 'cursorUp', label = 'Up' },
    { cmd = 'cursorDown', label = 'Down' },
    { cmd = 'cursorLeft', label = 'Left' },
    { cmd = 'cursorRight', label = 'Right' },
    { cmd = 'colLeft', label = 'Column left' },
    { cmd = 'colRight', label = 'Column right' },
    { cmd = 'channelLeft', label = 'Channel left' },
    { cmd = 'channelRight', label = 'Channel right' },
    { cmd = 'goTop', label = 'Top' },
    { cmd = 'goBottom', label = 'Bottom' },
    { cmd = 'pageUp', label = 'Page up' },
    { cmd = 'pageDown', label = 'Page down' },
  }},
  { anchor = 'body.grid', place = 'flow', title = 'Editing', items = {
    { cmd = 'noteOff', label = 'Note off' },
    { cmd = 'delete', label = 'Clear cell' },
    { cmd = 'deleteSel', label = 'Delete selection' },
    { cmd = 'interpolate', label = 'Interpolate' },
    { cmd = 'nudgeBack', label = 'Push back' },
    { cmd = 'nudgeForward', label = 'Push forward' },
    { cmd = 'eventShiftLeft', label = 'Push left' },
    { cmd = 'eventShiftRight', label = 'Push right' },
    { cmd = 'shrinkNote', label = 'Shrink note' },
    { cmd = 'growNote', label = 'Grow note' },
    { cmd = 'nudgeFineUp', label = 'Nudge val +' },
    { cmd = 'nudgeFineDown', label = 'Nudge val -' },
    { cmd = 'nudgeCoarseUp', label = 'Nudge val ++' },
    { cmd = 'nudgeCoarseDown', label = 'Nudge val --' },
    { cmd = 'scaleHalf', label = 'Scale \xc3\x97\xc2\xbd' },
    { cmd = 'scaleDouble', label = 'Scale \xc3\x972' },
    { cmd = 'quantize', label = 'Quantize' },
    { cmd = 'quantizeKeepRealised', label = 'Quantize (keep realised)' },
    { cmd = 'editNoteFx', label = 'Edit note FX' },
  }},
  { anchor = 'body.grid', place = 'flow', title = 'Selection', items = {
    { cmd = 'selectUp', label = 'Select up' },
    { cmd = 'selectDown', label = 'Select down' },
    { cmd = 'selectLeft', label = 'Select left' },
    { cmd = 'selectRight', label = 'Select right' },
    { cmd = 'selectClear', label = 'Clear selection' },
    { cmd = 'cycleBlock', label = 'Cycle selection H' },
    { cmd = 'cycleVBlock', label = 'Cycle selection V' },
    { cmd = 'swapBlockEnds', label = 'Swap block ends' },
    { cmd = 'cut', label = 'Cut' },
    { cmd = 'copy', label = 'Copy' },
    { cmd = 'paste', label = 'Paste' },
    { cmd = 'duplicateDown', label = 'Duplicate' },
  }},
  { anchor = 'body.grid', place = 'flow', title = 'Columns & rows', items = {
    { cmd = 'addTypedCol', label = 'Add column' },
    { cmd = 'hideExtraCol', label = 'Remove column' },
    { cmd = 'insertRowCol', label = 'Insert row' },
    { cmd = 'deleteRowCol', label = 'Delete row' },
  }},
  { anchor = 'body.grid', place = 'flow', title = 'Groups & region', items = {
    { cmd = 'regionEnter', label = 'Region mode' },
    { cmd = 'groupMark', label = 'Mark group' },
    { cmd = 'groupDuplicate', label = 'Duplicate group' },
    { cmd = 'groupPaste', label = 'Paste group' },
    { cmd = 'groupLocalToggle', label = 'Toggle local' },
    { cmd = 'groupInstPrev', label = 'Prev instance' },
    { cmd = 'groupInstNext', label = 'Next instance' },
  }},
  { anchor = 'body.grid', place = 'flow', title = 'Input', items = {
    { cmd = 'inputOctaveUp', label = 'Octave +' },
    { cmd = 'inputOctaveDown', label = 'Octave -' },
  }},
  { anchor = 'body.grid', place = 'flow', title = 'Transport', items = {
    { cmd = 'playPause', label = 'Play / pause' },
    { cmd = 'playFromTop', label = 'Play from top' },
    { cmd = 'playFromCursor', label = 'Play from cursor' },
    { cmd = 'stop', label = 'Stop' },
  }},
  { anchor = 'body.grid', place = 'flow', title = 'Take management', items = {
    { cmd = 'newTakeBelow', label = 'New take' },
    { cmd = 'duplicateUnpooledBelow', label = 'Duplicate (unpooled)' },
    { cmd = 'takeProperties', label = 'Take properties' },
  }},
  { anchor = 'body.grid', place = 'flow', title = 'Global', items = {
    { cmd = 'undo', label = 'Undo' },
    { cmd = 'redo', label = 'Redo' },
    { cmd = 'togglePage', label = 'Switch page' },
    { cmd = 'returnToArrange', label = 'Back to arrange' },
    { cmd = 'beginPrefix', label = 'Numeric prefix' },
    { cmd = 'toggleFxWindows', label = 'Toggle FX windows' },
    { cmd = 'toggleHelp', label = 'This help' },
    { cmd = 'quit', label = 'Quit' },
  }},
})

-- Screen point -> (fractional column, integer row) through the grid painter's
-- inverse, so a click resolves against the exact transform the draw pass used.
local function cellAt(mouseX, mouseY)
  local lx, ly = gridPainter.fromScreen(mouseX, mouseY)
  return lx, math.floor(ly)
end

--contract: returns (col, stop, fracX) or (nil, nil, fracX)
--invariant: fracX is separate so callers distinguish 'past last col' from 'inside col N'
local function nearestStop(mouseX, mouseY)
  local grid = tv.grid
  local fracX = cellAt(mouseX, mouseY)
  local bestCol, bestStop, bestDist = nil, nil, math.huge
  for i, col in ipairs(grid.cols) do
    if col.x then
      for s, pos in ipairs(col.stopPos) do
        local dist = math.abs(fracX - col.x - pos - 0.5)
        if dist < bestDist then
          bestCol, bestStop, bestDist = i, s, dist
        end
      end
    end
  end
  return bestCol, bestStop, fracX
end

--contract: bails if laneConsumed; lane strip wins gestures over the tracker grid
--contract: right-click on channel-label row toggles mute
--contract: click on label rows selects channel/column
--contract: body click moves cursor and arms drag
local function handleMouse()
  if laneConsumed then return end

  local grid = tv.grid
  local ec = tv:ec()
  local cursorRow, cursorCol, cursorStop = ec:pos()
  local scrollRow, scrollCol, lastVisCol = tv:scroll()

  local clicked      = ImGui.IsMouseClicked(ctx, 0)
  local rightClicked = ImGui.IsMouseClicked(ctx, 1)
  local held         = ImGui.IsMouseDown(ctx, 0)

  -- Region sculpt paint: shift-drag adds the column's stream to the
  -- active group, alt-drag removes it; debounced per cell via paintLast.
  local rc = ec:regionCursor()
  if ec:isInRegionMode() and rc and held and ImGui.IsWindowHovered(ctx) then
    local mods = ImGui.GetKeyMods(ctx)
    local add  = (mods & ImGui.Mod_Shift) ~= 0
    local sub  = (mods & ImGui.Mod_Alt)   ~= 0
    if add or sub then
      local mouseX, mouseY = ImGui.GetMousePos(ctx)
      local _, charY = cellAt(mouseX, mouseY)
      if charY >= 0 and charY < gridHeight then
        local col  = nearestStop(mouseX, mouseY)
        local cell = col and (col .. (add and '+' or '-'))
        if col and cell ~= paintLast then
          paintLast = cell
          tv:paintRegionStream(rc.groupId, rc.instId, col, add)
        end
      end
      return
    end
  elseif ec:isInRegionMode() and not held then
    paintLast = nil
  end

  if rightClicked and ImGui.IsWindowHovered(ctx) then
    local mouseX, mouseY = ImGui.GetMousePos(ctx)
    local _, charY = cellAt(mouseX, mouseY)
    local col, _, fracX = nearestStop(mouseX, mouseY)
    if col and charY == -HEADER and fracX >= 0 then
      local last = grid.cols[col]
      if fracX < last.x + last.width + 1 then
        tv:toggleChannelMute(last.midiChan)
      end
    end
    return
  end

  if clicked and ImGui.IsWindowHovered(ctx) then
    local mouseX, mouseY = ImGui.GetMousePos(ctx)
    local _, charY = cellAt(mouseX, mouseY)
    local col, stop, fracX = nearestStop(mouseX, mouseY)
    if not col then return end
    if charY < -HEADER or charY >= gridHeight then return end
    if fracX < 0 then return end
    local last = grid.cols[col]
    if fracX >= last.x + last.width + 1 then return end

    -- Mouse bypasses cmgr's DUP_KEEP sweep, so the cascade lifetime is
    -- enforced here by hand. A plain reposition click is the mouse
    -- equivalent of a cursor move -- DUP_KEEP keeps the run across it,
    -- so don't clear here. Only a genuine RE-selection ends the run:
    -- label-row select, shift-extend (both below) and drag (in the
    -- dragging branch). Mirrors cursor-key behaviour.

    if charY < 0 then
      tv:endReselectCascades()   -- label-row select is a re-selection
      if charY == -HEADER then ec:selectChannel(last.midiChan)
      else ec:selectColumn(col) end
      return
    end

    local shift = ImGui.GetKeyMods(ctx) & ImGui.Mod_Shift ~= 0

    if shift then
      tv:endReselectCascades()   -- shift-extend is a re-selection
      ec:extendTo(scrollRow + charY, col, stop)
    else
      ec:selClear()
      ec:setPos(scrollRow + charY, col, stop)
      dragging = true
    end

  elseif dragging and held then
    local mouseX, mouseY = ImGui.GetMousePos(ctx)
    local fracX, charY = cellAt(mouseX, mouseY)
    local row = scrollRow + charY
    local rightEdge = grid.cols[lastVisCol].x + grid.cols[lastVisCol].width

    local col, stop
    if fracX < 0 then
      col, stop = cursorCol, cursorStop - 1
      if stop < 1 then
        if col > 1 then col = col - 1; stop = #grid.cols[col].stopPos
        else stop = 1 end
      end
    elseif fracX >= rightEdge then
      col, stop = cursorCol, cursorStop + 1
      if stop > #grid.cols[cursorCol].stopPos then
        if col < #grid.cols then col = col + 1; stop = 1
        else stop = #grid.cols[col].stopPos end
      end
    else
      col, stop = nearestStop(mouseX, mouseY)
      if not col then return end
    end

    -- Only start selection once cursor moves to a different position
    if row ~= cursorRow or col ~= cursorCol or stop ~= cursorStop then
      tv:endReselectCascades()   -- drag-select is a new selection
      ec:extendTo(row, col, stop)
    end

  elseif dragging and not held then
    dragging = false
  end

  if ImGui.IsWindowHovered(ctx) then
    local wheel,wheelH  = ImGui.GetMouseWheel(ctx)
    if wheel ~= 0 then
      local n = util.round(math.abs(wheel) / 2)
      if n > 0 then
        local name = wheel > 0 and 'cursorUp' or 'cursorDown'
        for _ = 1, n do cmgr:invoke(name) end
      end
    end
    if wheelH ~= 0 then
      local n = util.round(math.abs(wheelH))
      if n > 0 then
        local name = wheelH > 0 and 'cursorLeft' or 'cursorRight'
        for _ = 1, n do cmgr:invoke(name) end
      end
    end
  end
end

-- Cell edits use the KEY stream (not the OS char queue): IsKeyPressed(repeat)
-- autorepeats every key uniformly; the char queue dropped repeats under macOS.
local editKeys = {}
do
  local function add(key, byte) editKeys[#editKeys + 1] = { key = key, char = byte } end
  for i = 0, 25 do add(ImGui.Key_A + i, string.byte('a') + i) end
  for d = 0, 9 do
    add(ImGui.Key_0 + d,      string.byte('0') + d)
    add(ImGui.Key_Keypad0 + d, string.byte('0') + d)
  end
  add(ImGui.Key_Minus,     string.byte('-'))
  add(ImGui.Key_KeypadSubtract, string.byte('-'))
  add(ImGui.Key_Comma,     string.byte(','))
  add(ImGui.Key_Period,    string.byte('.'))
  add(ImGui.Key_Semicolon, string.byte(';'))
  add(ImGui.Key_Apostrophe, string.byte("'"))
end

-- Only the newest held edit key autorepeats; without this a held chord would
-- re-enter all its keys interleaved (the OS char queue only repeated the last).
local lastEditKey

-- commandHeld gates note entry per key: a key bound to both a command and note
-- entry (e.g. '.' = delete) fires the command; unrelated keys still enter.
--contract: no-op when modal open, picker active, palette focused, or any ImGui item active
--contract: every fresh press enters; only lastEditKey autorepeats
--contract: scans editKeys per frame; reads ec/grid fresh (editEvent may rebuild)
local function handleKeys(kr)
  if modalHost:isOpen() or chrome.pickerIsActive() then return end
  if ImGui.IsAnyItemActive(ctx) or paletteFocus then return end
  local ec = tv:ec()
  local commandHeld = kr.commandHeld

  if ImGui.GetKeyMods(ctx) == ImGui.Mod_None
     and not cmgr:isPrefixActive() and not ec:isInRegionMode() then
    for _, entry in ipairs(editKeys) do
      if not commandHeld[entry.key] then
        local fresh  = ImGui.IsKeyPressed(ctx, entry.key, false)
        local repeated = ImGui.IsKeyPressed(ctx, entry.key, true)
        if fresh or (repeated and entry.key == lastEditKey) then
          if ec:isSticky() then ec:selClear(); break end
          if fresh then lastEditKey = entry.key end
          local row, colIdx, stop = ec:pos()
          local c = tv.grid.cols[colIdx]
          if c then tv:editEvent(c, c.cells and c.cells[row], stop, entry.char) end
        end
      end
    end
  end
end

----- Modal-driven commands

local function openPrompt(title, prompt, callback, resolve, onChord)
  modalHost:openPrompt{ title = title, prompt = prompt, callback = callback, resolve = resolve, onChord = onChord }
end

local function openConfirm(title, callback, prompt)
  modalHost:openConfirm{ title = title, prompt = prompt, callback = callback }
end

-- Custom modal: take properties. Renderer reads/writes per-instance state
-- (s) supplied at open time. Mutating rowsBuf externally is invisible to an
-- active InputText, which caches its own buffer. Bumping rowsGen changes the
-- widget's PushID identity and forces it to re-initialise from rowsBuf;
-- refocusRows then puts the cursor back so the user can keep typing. Both
-- chord and button paths share this so the InputText stays in sync.
modalHost:registerKind('takeProps', function(s, close)
  local function scaleBy(factor)
    local n = tonumber(s.beatsBuf)
    if not n then return end
    local minBeats = 1 / cm:get('rowPerBeat')
    s.beatsBuf     = ('%g'):format(math.max(minBeats, n * factor))
    s.beatsGen     = s.beatsGen + 1
    s.refocusBeats = true
  end
  local function pressedAny(specs)
    if not specs then return false end
    for _, spec in ipairs(specs) do
      local key, mods = cmgr:keySpec(spec, ImGui)
      if ImGui.IsKeyPressed(ctx, key) and ImGui.GetKeyMods(ctx) == mods then return true end
    end
    return false
  end

  if     pressedAny(cmgr:keysFor('doubleRPB')) then scaleBy(2)
  elseif pressedAny(cmgr:keysFor('halveRPB'))  then scaleBy(0.5) end

  -- Appearing frame: Enter is still IsKeyPressed=true — gate OK/Cancel
  -- below so a binding like Super+Shift+Enter doesn't self-dismiss.
  local appearing = ImGui.IsWindowAppearing(ctx)

  ImGui.Text(ctx, 'Item name')
  -- Duplicate paths open with focusName so the clone is named first.
  if appearing and s.focusName then ImGui.SetKeyboardFocusHere(ctx) end
  local rvN, name = ImGui.InputText(ctx, '##takeprops_name', s.nameBuf)
  if rvN then s.nameBuf = name end

  ImGui.Text(ctx, 'Length (beats)')
  if (appearing and not s.focusName) or s.refocusBeats then
    ImGui.SetKeyboardFocusHere(ctx)
    s.refocusBeats = nil
  end
  ImGui.PushID(ctx, s.beatsGen)
  local rvR, beats = ImGui.InputText(ctx, '##takeprops_beats', s.beatsBuf)
  ImGui.PopID(ctx)
  if rvR then s.beatsBuf = beats end
  ImGui.SameLine(ctx); if ImGui.Button(ctx, '\xc3\x97' .. '2') then scaleBy(2)   end  -- ×2
  ImGui.SameLine(ctx); if ImGui.Button(ctx, '\xc3\xb7' .. '2') then scaleBy(0.5) end  -- ÷2

  for i, m in ipairs{ {'resize', 'Resize'}, {'rescale', 'Rescale'}, {'tile', 'Tile'} } do
    if i > 1 then ImGui.SameLine(ctx) end
    if ImGui.RadioButton(ctx, m[2], s.mode == m[1]) then s.mode = m[1] end
  end

  local okPressed     = ImGui.Button(ctx, 'OK')
                     or (not appearing and (ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
                                         or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)))
  ImGui.SameLine(ctx)
  local cancelPressed = ImGui.Button(ctx, 'Cancel')
                     or (not appearing and ImGui.IsKeyPressed(ctx, ImGui.Key_Escape))
  if     okPressed     then close(true, s.nameBuf, tonumber(s.beatsBuf), s.mode)
  elseif cancelPressed then close(false) end
end)

-- Naming convention <base>Selection / <base>All is the contract.
--contract: requires tv to expose both `<base>Selection` and `<base>All` methods
local function scopedAction(title, base)
  return function()
    if tv:ec():hasSelection() then tv[base..'Selection'](tv)
    else openConfirm(title, function(yes) if yes then tv[base..'All'](tv) end end)
    end
  end
end

-- Add-Column type vocabulary. First letter is unique except p (pb/pc):
-- `p`→pb, a following `c`→pc. Digits ride through (only cc takes an id).
local function resolveColType(s)
  local a, digits = s:lower():match('^(%a*)(%d*)$')
  if not a or a == '' then return digits or '' end
  local first = a:sub(1, 1)
  local canon = first == 'n' and 'note'
             or first == 'c' and 'cc'
             or first == 'a' and 'at'
             or first == 'd' and 'dly'
             or first == 'p' and (a:sub(2, 2) == 'c' and 'pc' or 'pb')
             or a
  return canon .. digits
end

local function addColumn()
  -- A second Ctrl-→ (the chord that opened this prompt) dives straight to the
  -- automation palette — 'a' no longer seeds it, so 'a' is free for 'at'.
  local function chordToAutomation()
    if ImGui.GetKeyMods(ctx) == ImGui.Mod_Ctrl
    and ImGui.IsKeyPressed(ctx, ImGui.Key_RightArrow, false) then return 'automation' end
  end
  openPrompt('Add Column', 'note, cc0-127, pb, at, pc, dly — Ctrl-→ for automation', function(typeStr)
    local type, idStr = typeStr:lower():match('^(%a+)(%d*)$')
    if not type then return end
    if type == 'automation' then focusFindReq = true; return end
    local id = idStr ~= '' and tonumber(idStr) or nil
    if type == 'dly' then tv:showDelay()
    elseif util.oneOf('note cc pb at pc', type) then
      if type == 'cc' and (not id or id < 0 or id > 127) then return end
      tv:addExtraCol(type, id)
    end
  end, resolveColType, chordToAutomation)
end

-- Ctrl-Left drops the cursor column: a bound automation (cc) column goes
-- through the remove-automation flow; anything else just hides.
local function removeOrHideCol()
  local col   = tv.grid.cols[tv:ec():col()]
  local bound = col and col.type == 'cc' and tv:paramBinding(col.midiChan, col.cc)
  if bound then removeAutomation(col)
  else tv:hideExtraCol() end
end

-- Forward-declared so the takeProperties command body, registered
-- below, captures the same table the helper installs methods on.
local renderer = {}


----- Note FX editor (retrig + vibrato)

-- Two toggleable sections (one per kind); FX_FIELDS is pure data so a new kind ships a
-- generator + one entry. Cursor: Up/Down pick a row, Left/Right adjust. see design/note-macros.md § UI.
local FX_KINDS    = { 'retrig', 'vibrato' }
local KIND_LABELS = { retrig = 'Retrig', vibrato = 'Vibrato' }
local FX_DEFAULTS = {
  retrig  = { kind = 'retrig',  period = { 1, 4 }, ramp  = 0 },
  vibrato = { kind = 'vibrato', period = { 1, 2 }, depth = 30, onset = 1 },
}

-- Shared QN-fraction period ladder; both kinds tempo-sync the same way.
local PERIODS = { { l = '1/2', v = { 1, 2 } }, { l = '1/3', v = { 1, 3 } },
                  { l = '1/4', v = { 1, 4 } }, { l = '1/6', v = { 1, 6 } },
                  { l = '1/8', v = { 1, 8 } } }

-- widget 'choice': options = {{l,v},...}; Left/Right step the list.
-- widget 'int': a numberStepper; Left/Right adjust by `base`, Ctrl by `coarse`.
local FX_FIELDS = {
  retrig = {
    { field = 'period', label = 'Period', widget = 'choice', options = PERIODS },
    { field = 'ramp',   label = 'Ramp',   widget = 'int', base = 1, coarse = 10, min = -127, max = 127 },
  },
  vibrato = {
    { field = 'period', label = 'Period', widget = 'choice', options = PERIODS },
    { field = 'depth',  label = 'Depth',  widget = 'int', base = 1, coarse = 10, min = 0, max = 200 },  -- cents
    { field = 'onset',  label = 'Onset',  widget = 'int', base = 1, coarse = 4,  min = 0, max = 16 },   -- QN ramp-in
  },
}

local fxEdit do
  local MARK_W, LABEL_W = 16, 64
  local LEGEND = '\xe2\x86\x91\xe2\x86\x93 field    \xe2\x86\x90\xe2\x86\x92 adjust    Del remove    Enter done'

  local function valueEq(a, b)
    if type(a) == 'table' then return type(b) == 'table' and a[1] == b[1] and a[2] == b[2] end
    return a == b
  end
  local function choiceIndex(fd, value)
    for i, o in ipairs(fd.options) do if valueEq(o.v, value) then return i end end
    return 1
  end
  local function choiceLabels(fd)
    local out = {}; for i, o in ipairs(fd.options) do out[i] = o.l end; return out
  end

  -- One row per section header, plus one per field of an active section, in
  -- FX_KINDS order. A header's index is nil when its section is off.
  local function buildRows(fx)
    local rows = {}
    for _, kind in ipairs(FX_KINDS) do
      local idx
      for i, e in ipairs(fx) do if e.kind == kind then idx = i; break end end
      rows[#rows + 1] = { kind = kind, header = true, index = idx }
      if idx then
        for _, fd in ipairs(FX_FIELDS[kind]) do
          rows[#rows + 1] = { kind = kind, fd = fd, index = idx, entry = fx[idx] }
        end
      end
    end
    return rows
  end

  local function mark(focused)
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, focused and '\xe2\x96\xb8' or ' ')   -- ▸ on the cursor row
    ImGui.SameLine(ctx, MARK_W)
  end

  local function drawRow(uuid, rw, focused)
    mark(focused)
    if rw.header then
      local changed, on = chrome.checkbox(KIND_LABELS[rw.kind] .. '##fxk_' .. rw.kind, rw.index ~= nil)
      if changed then tv:setFxKindActive(uuid, FX_DEFAULTS[rw.kind], on) end
      return
    end
    local fd, value = rw.fd, rw.entry[rw.fd.field]
    ImGui.AlignTextToFramePadding(ctx); ImGui.Text(ctx, fd.label)
    ImGui.SameLine(ctx, MARK_W + LABEL_W)
    if fd.widget == 'choice' then
      local pick = chrome.dropdown('fx_' .. rw.kind .. '_' .. fd.field,
                     fd.options[choiceIndex(fd, value)].l, choiceLabels(fd))
      if pick then tv:setFxField(uuid, rw.index, fd.field, fd.options[pick].v) end
    else
      local rv, n = chrome.numberStepper('fx_' .. rw.kind .. '_' .. fd.field, value or 0,
                      { width = 70, min = fd.min, max = fd.max })
      if rv then tv:setFxField(uuid, rw.index, fd.field, n) end
    end
  end

  local function adjustRow(uuid, rw, right, mods)
    if rw.header then
      tv:setFxKindActive(uuid, FX_DEFAULTS[rw.kind], right)
      return
    end
    local fd, value = rw.fd, rw.entry[rw.fd.field]
    if fd.widget == 'choice' then
      local i = util.clamp(choiceIndex(fd, value) + (right and 1 or -1), 1, #fd.options)
      tv:setFxField(uuid, rw.index, fd.field, fd.options[i].v)
    else
      local step = (mods & ImGui.Mod_Ctrl) ~= 0 and fd.coarse or fd.base
      local n = util.clamp((value or 0) + (right and 1 or -1) * step, fd.min, fd.max)
      tv:setFxField(uuid, rw.index, fd.field, n)
    end
  end

  modalHost:registerKind('fxEdit', function(s, close)
    local fx   = tv:noteFx(s.uuid) or {}
    local rows = buildRows(fx)
    s.field    = util.clamp(s.field or 1, 1, #rows)

    ImGui.TextDisabled(ctx, LEGEND)
    ImGui.Spacing(ctx)
    for i, rw in ipairs(rows) do drawRow(s.uuid, rw, i == s.field) end

    ImGui.Spacing(ctx)
    if ImGui.Button(ctx, 'Clear')  then tv:setNoteFx(s.uuid, util.REMOVE);               close(false); return end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, 'Cancel') then tv:setNoteFx(s.uuid, s.snapshot or util.REMOVE); close(false); return end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, 'Done')   then close(false); return end

    if ImGui.IsAnyItemActive(ctx) then return end   -- a focused widget owns the keys
    local press = function(k) return ImGui.IsKeyPressed(ctx, k) end
    if press(ImGui.Key_Escape) then
      tv:setNoteFx(s.uuid, s.snapshot or util.REMOVE); close(false)
    elseif press(ImGui.Key_Enter) or press(ImGui.Key_KeypadEnter) then
      close(false)
    elseif press(ImGui.Key_DownArrow) then s.field = util.clamp(s.field + 1, 1, #rows)
    elseif press(ImGui.Key_UpArrow)   then s.field = util.clamp(s.field - 1, 1, #rows)
    elseif press(ImGui.Key_Delete) or press(ImGui.Key_Backspace) then
      tv:setFxKindActive(s.uuid, FX_DEFAULTS[rows[s.field].kind], false)
    else
      local left, right = press(ImGui.Key_LeftArrow), press(ImGui.Key_RightArrow)
      if left or right then adjustRow(s.uuid, rows[s.field], right, ImGui.GetKeyMods(ctx)) end
    end
  end)

  function fxEdit()
    local note = tv:cursorNote()
    if not note then return end
    modalHost:open{
      kind = 'fxEdit', title = 'Note FX',
      uuid = note.uuid, field = 1,
      snapshot = note.fx and util.deepClone(note.fx) or nil,
      flags = ImGui.WindowFlags_NoNavInputs,
    }
  end
end

-- New take from the tracker: name + length modal, mint a parked slot, select it.
-- Length seeds from / persists to the project-tier newTakeBeats config.
local function openNewTakeModal()
  local trackIdx = tv:currentTrackIdx(); if not trackIdx then return end
  local slot = arrange().nextFreeSlot(trackIdx)
  modalHost:open{
    kind     = 'newTake',
    title    = 'New take',
    nameBuf  = slot and string.format('%02d', slot) or '',
    beatsBuf = tostring(cm:get('newTakeBeats')),
    callback = util.atomic('New take', function(nameBuf, beatsBuf)
      local b = math.max(1e-3, tonumber(beatsBuf) or cm:get('newTakeBeats'))
      cm:set('project', 'newTakeBeats', b)
      tv:newParkedTake(nameBuf, b)
    end),
  }
end

modalHost:registerKind('newTake', function(s, close)
  local appearing = ImGui.IsWindowAppearing(ctx)
  ImGui.Text(ctx, 'Name')
  if appearing then ImGui.SetKeyboardFocusHere(ctx) end
  local rvN, nb = ImGui.InputText(ctx, '##newTakeName', s.nameBuf)
  if rvN then s.nameBuf = nb end
  ImGui.Text(ctx, 'Length (beats)')
  local rvB, bb = ImGui.InputText(ctx, '##newTakeBeats', s.beatsBuf)
  if rvB then s.beatsBuf = bb end
  local ok = ImGui.Button(ctx, 'OK')
              or (not appearing and (ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
                                  or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)))
  ImGui.SameLine(ctx)
  local cancel = ImGui.Button(ctx, 'Cancel')
              or (not appearing and ImGui.IsKeyPressed(ctx, ImGui.Key_Escape))
  if ok then close(true, s.nameBuf, s.beatsBuf)
  elseif cancel then close(false) end
end)

-- Mint the clone, open take-properties focused on name. No rebind: slot selection re-binds
-- to the clone before any commit lands, so the seed and commit both target the clone.
local function duplicateUnpooledTake()
  if tv:duplicateBoundUnpooled() then renderer:openTakeProperties{ focusName = true } end
end

local tracker = cmgr:scope('tracker')

tracker:registerAll{
  setRPB = function()
    openPrompt('Rows per beat', '1-32', function(buf)
      local n = tonumber(buf); if n then tv:setRowPerBeat(n) end
    end)
  end,

  takeProperties         = { function() renderer:openTakeProperties{} end, 'Take properties' },
  newTakeBelow           = { openNewTakeModal, 'New take' },
  duplicateUnpooledBelow = { duplicateUnpooledTake, 'Duplicate take (unpooled)' },

  prevTrack = { function() tv:gotoTrack(-1) end, 'Previous track' },
  nextTrack = { function() tv:gotoTrack(1)  end, 'Next track' },
  prevTake  = { function() tv:gotoTake(-1)  end, 'Previous take' },
  nextTake  = { function() tv:gotoTake(1)   end, 'Next take' },

  addTypedCol = addColumn,
  hideExtraCol = { removeOrHideCol, 'Hide / remove column' },

  quantize             = { scopedAction('quantize',               'quantize'),             'Quantize' },
  quantizeKeepRealised = { scopedAction('quantize keep realised', 'quantizeKeepRealised'), 'Quantize (keep realised)' },

  openTemperPicker = function() chrome.requestPickerOpen('temper') end,
  openSwingPicker  = function() chrome.requestPickerOpen('swing')  end,

  editNoteFx = { fxEdit, 'Edit note FX' },
}

cmgr:doAfter({ 'quantize', 'quantizeKeepRealised' },
             function() tv:ec():unstick() end)

----- Region overlay keymap

-- The 'region' modal overlay + every region verb body live on ec
-- (built at tv construct). The page wires only entry on the tracker
-- scope and the overlay key map; ec owns lifecycle and dispatch.
cmgr:scope('region'):bindAll{
  regionBail         = { ImGui.Key_Escape, {ImGui.Key_R, ImGui.Mod_Super} },
  regionCommit       = { ImGui.Key_Enter, ImGui.Key_KeypadEnter },
  regionNew          = { ImGui.Key_N },
  regionInstance     = { ImGui.Key_I },
  regionPaintExtend  = { ImGui.Key_Equal },
  regionPaintShrink  = { ImGui.Key_Minus },
  regionDrop         = { ImGui.Key_Delete },
  regionNudgeBack    = { {ImGui.Key_UpArrow,   ImGui.Mod_Super} },
  regionNudgeForward = { {ImGui.Key_DownArrow, ImGui.Mod_Super} },
  regionShrink       = { {ImGui.Key_UpArrow,   ImGui.Mod_Super, ImGui.Mod_Shift} },
  regionGrow         = { {ImGui.Key_DownArrow, ImGui.Mod_Super, ImGui.Mod_Shift} },
  regionShrinkStart  = { {ImGui.Key_UpArrow,   ImGui.Mod_Super, ImGui.Mod_Alt} },
  regionGrowStart    = { {ImGui.Key_DownArrow, ImGui.Mod_Super, ImGui.Mod_Alt} },
  regionInstPrev     = { ImGui.Key_LeftBracket },
  regionInstNext     = { ImGui.Key_RightBracket },
  regionPrev         = { {ImGui.Key_Comma,  ImGui.Mod_Shift} },
  regionNext         = { {ImGui.Key_Period, ImGui.Mod_Shift} },
}

-- Group quick-verb bodies + lifetime live on trackerView; install the
-- copy snapshot + clear-on-mutation sweep now that every tracker command
-- (incl. this page's) is registered.
tv:wireGroupLifetime()

---------- PUBLIC

----- Take properties modal helper

-- Shared by the tracker-scope `takeProperties` command and the
-- arrange-scope `arrangeTakeProperties` (which binds tm to its focused
-- take first and supplies an onClose to restore the prior bind). The
-- helper reads name/beats from tp's currently-bound take and applies
-- through tv:applyTakeProperties; callers without a bound take get a
-- no-op-ish modal seeded with 0 beats.
--
-- onClose fires exactly once, after the whole modal chain — including
-- any truncate-confirm follow-up. Two sources of "chain done":
-- the apply path (callback ran, valid input, either direct apply or
-- truncate-confirm resolution) fires onClose at the leaf; the cancel
-- path (modal cancel, or invalid input) fires it via modalHost's own
-- onClose. The `transfer` flag handshake makes these mutually
-- exclusive: once a valid callback starts the apply chain it claims
-- ownership, so modalHost's onClose becomes a no-op.
function renderer:openTakeProperties(args)
  args = args or {}
  local rpb        = cm:get('rowPerBeat')
  local origBeats  = (tv.grid.numRows or 0) / rpb
  local pendingOnClose = true
  local function fireOnClose()
    if not pendingOnClose then return end
    pendingOnClose = false
    if args.onClose then args.onClose() end
  end
  modalHost:open{
    kind     = 'takeProps',
    title    = 'Take properties',
    nameBuf  = tv:takeName() or '',
    beatsBuf = ('%g'):format(origBeats),
    beatsGen = 0,
    mode     = 'resize',
    focusName = args.focusName,
    callback = function(name, beats, mode)
      if not beats or beats <= 0 then return end
      pendingOnClose = false  -- transfer ownership to the apply chain
      -- rescale is the monotone stretch — never deletes events.
      -- resize and tile both fall back to truncation when shrinking.
      if beats < origBeats and mode ~= 'rescale' then
        local txt = ('%g'):format(beats)
        openConfirm('Truncate take',
          function(yes)
            if yes then tv:applyTakeProperties{ name = name, beats = beats, mode = mode } end
            if args.onClose then args.onClose() end
          end,
          ('Truncate to %s beats? Events past beat %s will be deleted. (y/n)'):format(txt, txt))
      else
        tv:applyTakeProperties{ name = name, beats = beats, mode = mode }
        if args.onClose then args.onClose() end
      end
    end,
    onClose = fireOnClose,
  }
end

----- Page interface (rendering only; trackerPage drives lifecycle and the dispatch)

function renderer:toolbarSegments() return toolbarSegments end

--contract: calls computeLayout twice
--invariant: lane-strip drag callbacks may flush tv.grid.cols and clear col.x
--contract: second pass repopulates layout for drawTracker
function renderer:renderBody(_, w, h, dispatch)
  -- No bound take ⇒ empty grid. Body pushes no Col_Text, so push uiFont +
  -- grid text colour explicitly; still dispatch so global keys fire.
  if #tv.grid.cols == 0 then
    if dispatch then dispatch(self:focusState()) end
    ImGui.PushFont(ctx, uiFont, gui.fontSize.ui)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, chrome.colour('text'))
    ImGui.Text(ctx, 'No MIDI takes on this track.')
    ImGui.PopStyleColor(ctx)
    ImGui.PopFont(ctx)
    return
  end
  local ox, oy = ImGui.GetCursorScreenPos(ctx)
  local gridW  = chrome.gridWidth(w)
  ImGui.PushFont(ctx, font, 15)
  computeLayout(gridW, h)
  drawLaneStrip()
  -- Lane-drag callbacks may rebuild grid.cols; re-layout for drawTracker.
  computeLayout(gridW, h)
  drawTracker()
  ImGui.PopFont(ctx)
  -- Full body width (grid + palette) so the cheat-sheet can flow across both.
  help:anchor('body.grid', gridOriginX, gridOriginY, ox + w - gridOriginX, gridHeight * gridY)

  drawParamPalette(ox + gridW, oy, h)
  tv:pollLearn(ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_AnyWindow))

  if not help:wasOpenAtFrameStart() then handleMouse() end
  local kr = dispatch and dispatch(self:focusState()) or { commandHeld = {} }
  if not help:wasOpenAtFrameStart() then handleKeys(kr) end

  tv:tick()
end

function renderer:renderStatusBar(_)
  drawStatusBar()
end

-- suppressKbd: modal/picker owns input. pageSuppressed: unused (swing/temper on own page).
-- acceptCmds: page visible and no item active (toolbar focus is transient; see IsAnyItemActive).
--shape: focusState = { suppressKbd:bool, pageSuppressed:bool, acceptCmds:bool }
function renderer:focusState()
  if not ctx then return { suppressKbd = false, pageSuppressed = false, acceptCmds = false } end
  local suppressKbd = modalHost:isOpen() or chrome.pickerIsActive()
  return {
    suppressKbd    = suppressKbd,
    pageSuppressed = false,
    acceptCmds     = (not suppressKbd) and not ImGui.IsAnyItemActive(ctx) and not paletteFocus,
  }
end

return renderer

