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
local cm, cmgr, chrome, gui, modalHost, facade, tv =
  (...).cm, (...).cmgr, (...).chrome, (...).gui, (...).modalHost, (...).facade, (...).tv

local function print(...)
  return util.print(...)
end

local painter = require 'painter'

-- The renderer reads arrange (the empty-grid message, nav commands) through
-- this facade; the controller owns the cursor-follow + bind. See docs/trackerPage.md.
local function arrange() return facade.get('arrange') end

---------- PRIVATE

local GUTTER      = 5    -- in grid chars: 3-char row num + spacer + region slot
local HEADER      = 3    -- in grid rows; computeLayout grows it to fit vertical param names

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
local swingEditor = util.instantiate('swingEditor',
  { tv = tv, cm = cm, chrome = chrome, ctx = ctx, facade = facade })
local curveEd      = util.instantiate('curveEditor', { ctx = ctx, chrome = chrome })
local laneConsumed = false
local toolbar                              -- lazy: chrome may be nil at construction in tests

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

  local showDelay  = col and col.showDelay
  local showSample = col and col.trackerMode

  if not evt then
    local s = '···' .. (showSample and ' ··' or '') .. ' ··'
    if showDelay then s = s .. ' ···' end
    return s
  end

  local label
  if evt.type ~= 'pa' then
    label = select(1, tv:noteProjection(evt)) or noteName(evt.pitch)
  end
  local isPA      = evt.type == 'pa'
  local noteTxt   = isPA and '···' or label
  local velTxt    = evt.vel and string.format('%02X', evt.vel) or '··'
  local sampleTxt = showSample and (' ' .. (isPA and '··' or string.format('%02X', evt.sample or 0))) or ''
  local text      = noteTxt .. sampleTxt .. ' ' .. velTxt

  -- Sample digits sit at fixed positions 5,6 (after 'C-4 '). Shadowed
  -- and negative-delay overrides occupy disjoint ranges, so they coexist.
  local overrides
  if showSample and evt.sampleShadowed then
    overrides = { [5] = 'shadowed', [6] = 'shadowed' }
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
      local n = #text
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

-- Offset (in grid cells) of the gap that sits just before the 3 delay
-- digits in a note cell. The * marker is dropped here. Layout: pitch(3)
-- + optional sample(3) + ' ' + vel(2). The next char is the separator
-- space-before-delay -- our marker slot.
local function delayMarkerOffset(col)
  return 3 + (col.trackerMode and 3 or 0) + 1 + 2
end

----- Drawing

-- A cell adapter over the shared painter: methods speak grid CELLS (integer
-- col/row), the painter maps them to screen through one transform. gX/gY are
-- odd integers, so an integer cell already lands on a whole pixel; snap rounds
-- the fractional cases (centred text, the inset cursor box) crisp, the way the
-- old per-call math.floor did. text is monospace by cell, not by glyph advance.
local function printer(ctx, gX, gY, x0, y0)
  local p  = painter.new(ctx, chrome, { ox = x0, oy = y0, sx = gX, sy = gY, snap = true })
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

  function pt:textCentredSmall(x1, x2, y, txt, size, colour)
    p.text(centreX(x1, x2, txt, font, size), y, colour, txt, font, size)
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
    p.line(x + 0.5, y1, x + 0.5, y2 + 1, colour)
  end

  function pt:hLine(x1, x2, y, colour, yOff)
    local ly = y + (yOff or 0)
    p.line(x1, ly, x2 + 1, ly, colour)
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

-- Off=group 1, saved lib=group 2, unseeded preset (+ prefix)=group 3.
local function libPickerItems(current, lib, presets, excludePresets)
  local items = { { label = 'Off', key = nil, group = 1, current = current == nil } }
  local libNames = {}
  for k in pairs(lib) do libNames[#libNames + 1] = k end
  table.sort(libNames)
  for _, name in ipairs(libNames) do
    items[#items + 1] = { label = name, key = name, group = 2, current = current == name }
  end
  local presetNames = {}
  for k in pairs(presets) do
    if not (excludePresets and excludePresets[k]) and not lib[k] then
      presetNames[#presetNames + 1] = k
    end
  end
  table.sort(presetNames)
  for _, name in ipairs(presetNames) do
    items[#items + 1] = { label = '+ ' .. name, key = name, group = 3, current = false }
  end
  return items
end

-- Seed lib if absent before committing to slot.
local pickTemper = util.atomic('Set temper', function(name)
  if name and not cm:get('tempers')[name] then
    tv:setTemper(name, tuning.presets[name])
  end
  tv:setTemperSlot(name)
end)

local pickSwing    = util.atomic('Set swing',        function(name)       tv:setSwingSlot(name)          end)
local pickColSwing = util.atomic('Set column swing', function(chan, name) tv:setColSwingSlot(chan, name) end)

-- 'identity' is the explicit no-swing sentinel (schema default); shown as
-- "Off" in the button, hidden from the picker rows.
local SWING_PRESET_EXCLUDE = { identity = true }

-- Hex stays visible when unassigned so `<`/`>` advertise their step.
-- No "Off" row — every slot is real.
local function drawSampleDropdown()
  local cur     = cm:get('currentSample')
  local entries = cm:get('slotEntries') or {}
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
      local curIdx = arrange().currentTrackIdx()
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
        width       = 160, items = items, onPick = function(idx) arrange().pickTrack(idx) end,
      }
    end,
  },
  {
    id = 'take',
    render = function()
      chrome.headingLabel('Take')
      ImGui.SameLine(ctx, 0, 8)
      local trackIdx = arrange().currentTrackIdx()
      local curSlot  = arrange().currentSlotIdx()
      local items, curName = {}, nil
      for _, slot in ipairs(arrange().midiSlots(trackIdx)) do
        local name = slot.name ~= '' and slot.name or arrange().keyForSlot(slot.idx)
        if slot.idx == curSlot then curName = name end
        items[#items + 1] = { label = name, key = slot.idx, group = 1, current = slot.idx == curSlot }
      end
      chrome.drawPicker {
        kind        = 'take',
        buttonLabel = curName or '\xe2\x80\x94',
        width       = 160, items = items, onPick = function(idx) arrange().pickTake(idx) end,
      }
    end,
  },
  {
    id = 'rowsPerBeat',
    render = function()
      local rowPerBeat = cm:get('rowPerBeat')
      ImGui.AlignTextToFramePadding(ctx)
      chrome.headingLabel('RPB')
      ImGui.SameLine(ctx, 0, 8)
      local textW = ImGui.CalcTextSize(ctx, '32')
      local btnW  = ImGui.GetFrameHeight(ctx)
      ImGui.SetNextItemWidth(ctx, textW + btnW * 2 + 16)
      -- Spinner FramePadding shrinks at 9→10 so the buttons don't
      -- crowd the two-digit field.
      ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, rowPerBeat > 9 and 5 or 8, 3)
      local changed, n = ImGui.InputInt(ctx, '##rpb', rowPerBeat, 1, 4)
      ImGui.PopStyleVar(ctx, 1)
      if changed then tv:setRowPerBeat(util.clamp(n, 1, 32)) end
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
        items       = libPickerItems(cur, cm:get('tempers'), tuning.presets),
        onPick      = pickTemper,
      }
    end,
  },
  {
    id = 'swing',
    render = function()
      chrome.headingLabel('Swing')
      ImGui.SameLine(ctx, 0, 8)
      do
        local cur = cm:get('swing')
        chrome.drawPicker {
          kind        = 'swing', heading = 'Take',
          buttonLabel = cur == 'identity' and 'Off' or cur,
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
        local cur = chan and cm:get('colSwing')[chan] or nil
        chrome.drawPicker {
          kind        = 'colSwing', heading = 'Ch',
          buttonLabel = cur or 'Off',
          width       = 120,
          items       = chrome.libPicker('swings', cur, SWING_PRESET_EXCLUDE),
          onPick      = function(name) pickColSwing(chan, name) end,
        }
      end)
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

-- While the swing editor is open, the tracker body is replaced and
-- only swing-related toolbar segments stay live (the picker is how
-- the user switches what they're editing). Other segments grey out.
local function drawTrackerToolbarBits()
  toolbar = toolbar or chrome.makeToolbar()
  if not swingEditor:isOpen() then return toolbar(toolbarSegments) end
  local wrapped = {}
  for i, seg in ipairs(toolbarSegments) do
    if seg.id == 'swing' then
      wrapped[i] = seg
    else
      wrapped[i] = {
        id = seg.id, visible = seg.visible,
        render = function() chrome.disabledIf(true, seg.render) end,
      }
    end
  end
  toolbar(wrapped)
end

-- Bound cc columns drop the 'CC' label for their param name written
-- vertically; names trim to VNAME_MAX chars so the header stays sane.
local VNAME_MAX = 14

local function vname(label)
  local cut = utf8.offset(label, VNAME_MAX + 1)
  return cut and label:sub(1, cut - 1) or label
end

local function vnameSize() return math.floor(gui.fontSize.ui * 0.8) end

-- Bottom gap under a vertical name, in rows: clear of the grid's top rule
-- with a couple of px of breathing room.
local function vnameGap() return 0.35 + 2 / gridY end

-- Header rows: the tallest vertical name (rotated strip when painter has the
-- LICE path, stacked glyphs otherwise). Tall names may poke into the Ch row.
local function headerRows(cols)
  local maxPx = 0
  for _, col in ipairs(cols) do
    if col.type == 'cc' then
      local binding = tv:paramBinding(col.midiChan, col.cc)
      if binding then
        local label = vname(binding.label)
        local _, stripH = painter.measureRotated(ctx, label, vnameSize())
        maxPx = math.max(maxPx, stripH or (utf8.len(label) or 0) * gui.fontSize.ui)
      end
    end
  end
  return math.max(3, math.ceil(vnameGap() + maxPx / gridY))
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
  HEADER     = headerRows(grid.cols)
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
  local drawList  = ImGui.GetWindowDrawList(ctx)
  local scrollRow = select(1, tv:scroll())
  local numRows   = tv.grid.numRows or 0
  -- rowSpan = rows actually rendered (matches grid below).
  local rowSpan   = math.max(1, math.min(gridHeight, numRows - scrollRow))
  local function rowToX(row) return x0 + (row - scrollRow) / rowSpan * w end

  local pad  = gridY / 2
  local yTop = y0 + pad
  local yBot = y0 + h - pad

  if w > 0 then
    local barCol, beatCol, dividerCol =
      chrome.colour('rowBarStart'), chrome.colour('rowBeat'), chrome.colour('laneRowDivider')
    for row = scrollRow, scrollRow + rowSpan - 1 do
      local x = math.floor(rowToX(row)) + 0.5
      local isBar, isBeat = tv:rowBeatInfo(row)
      if isBar or isBeat then
        local x2 = math.floor(rowToX(row + 1)) + 0.5
        ImGui.DrawList_AddRectFilled(drawList, x, yTop, x2, yBot, isBar and barCol or beatCol)
      end
      ImGui.DrawList_AddLine(drawList, x, yTop, x, yBot, dividerCol, 1)
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
    ImGui.DrawList_AddRect(drawList, x0, yTop, x0 + w, yBot, chrome.colour('rowBeat'), 0, 0, 1)
  end

  ImGui.Dummy(ctx, (totalWidth + GUTTER) * gridX, h)

  local cx, cy = ImGui.GetCursorScreenPos(ctx)
  local rows = cm:get('laneStrip.rows') or 0
  ImGui.SetCursorScreenPos(ctx, px - 2, yTop)
  if ImGui.SmallButton(ctx, '-##laneRows') then
    cm:set('global', 'laneStrip.rows', math.max(LANE_ROW_MIN, rows - 1))
  end
  ImGui.SameLine(ctx, 0, 2)
  if ImGui.SmallButton(ctx, '+##laneRows') then
    cm:set('global', 'laneStrip.rows', math.min(LANE_ROW_MAX, rows + 1))
  end
  ImGui.SetCursorScreenPos(ctx, cx, cy)
end

--contract: assumes computeLayout ran this frame; reads chanX/W/Order, gridOriginX/Y
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
  local screenPainter = painter.new(ctx, chrome, {})

  -- Solo (amber) wins over mute (red): audibility semantic.
  draw:text(-GUTTER, -HEADER, 'Row', 'accent')
  for chan = 1, 16 do
    if chanX[chan] then
      local key = tv:isChannelSoloed(chan) and 'solo'
               or tv:isChannelMuted(chan)  and 'mute'
               or 'accent'
      draw:textCentred(chanX[chan], chanX[chan] + chanW[chan] - 1,
                       -HEADER, 'Ch ' .. chan, key)
    end
  end
  local laneByChan = {}
  for _, col in ipairs(grid.cols) do
    local sub, vertical
    if col.type == 'note' then
      local n = (laneByChan[col.midiChan] or 0) + 1
      laneByChan[col.midiChan] = n
      sub = tostring(n)
    elseif col.type == 'cc' then
      local binding = tv:paramBinding(col.midiChan, col.cc)
      if binding then vertical = vname(binding.label)
      else sub = tostring(col.cc) end
    end
    if col.x then
      local xr = col.x + col.width - 1
      if vertical then
        if not p.textUp((col.x + xr + 1) / 2, -vnameGap(), 'text', vertical, vnameSize()) then
          draw:textVertical(col.x, xr, -vnameGap(), vertical, uiFont, gui.fontSize.ui, 'text')
        end
      else
        draw:textCentred(col.x, xr, -2.1, col.label, 'text')
        if sub then
          draw:textCentredSmall(col.x, xr, -1.2, sub, 14, 'accent')
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
          draw:smallGlyph(col.x + delayMarkerOffset(col), y, '*', 9, textCol)
        end
      end
    end
  end

  if tv:activeTemper() then
    for _, col in ipairs(grid.cols) do
      if col.x and col.type == 'note' and col.cells then
        local x0 = gridOriginX + col.x * gridX
        local x1 = x0 + 3 * gridX
        local cx = (x0 + x1) / 2
        local halfW = (x1 - x0) / 2 - 1
        for y = 0, gridHeight - 1 do
          local row = scrollRow + y
          if row >= numRows then break end
          local evt = col.cells[row]
          if evt and evt.pitch then
            local _, gap, halfGap = tv:noteProjection(evt)
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

-- Pane geometry, mirroring arrange/wiring's body split.
local PALETTE_W  = 200
local PANE_GAP   = 11   -- 1px vrule sits centred here; neither pane edge touches it
local HEADER_PAD = 8
local HEADER_GAP = 4

local function paletteHeader()
  local p       = painter.new(ctx, chrome, {})
  local ox, oy  = ImGui.GetCursorScreenPos(ctx)
  local paneW   = select(1, ImGui.GetContentRegionAvail(ctx))
  local rowH    = math.max(1, ImGui.GetTextLineHeightWithSpacing(ctx))
  local headerH = rowH + HEADER_PAD
  local label   = 'parameters'
  local tw      = p.measure(label)
  p.text(ox + math.floor((paneW - tw) / 2), oy + HEADER_PAD, 'text', label)
  p.line(ox, oy + headerH, ox + paneW, oy + headerH, 'text', 1)
  ImGui.Dummy(ctx, paneW, headerH + HEADER_GAP)
end

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

-- Set by the Add-Column 'automation' option; focuses the find box next frame.
local focusFilterReq = false

local function paletteFilterBox()
  ImGui.SetNextItemWidth(ctx, -1)
  if focusFilterReq then ImGui.SetKeyboardFocusHere(ctx); focusFilterReq = false end
  local changed, text = ImGui.InputTextWithHint(ctx, '##paramFilter', 'find', tv:paletteFilter())
  if changed then tv:setPaletteFilter(text) end
end

-- Ellipsis-fit to the palette's fixed width; no horizontal scroll exists.
local function fitLabel(text, maxW)
  if ImGui.CalcTextSize(ctx, text) <= maxW then return text end
  local keep = #text
  while keep > 1 and ImGui.CalcTextSize(ctx, text:sub(1, keep) .. '…') > maxW do
    keep = keep - 1
  end
  -- don't cut mid utf-8 sequence
  while keep > 1 and (text:byte(keep + 1) or 0) & 0xC0 == 0x80 do keep = keep - 1 end
  return text:sub(1, keep) .. '…'
end

local function paramRow(trackGuid, fxGuid, prm, label)
  local sel     = tv:paletteParam()
  local isSel   = sel and sel.fxGuid == fxGuid and sel.param == prm.index
  label = fitLabel(label, select(1, ImGui.GetContentRegionAvail(ctx)))
  -- ###: ID from the guid alone — with ##, the truncated label is hashed
  -- too, and scrollbar-driven width changes would mint a fresh ID per frame
  local clicked = ImGui.Selectable(ctx, label .. '###p' .. fxGuid .. prm.index, isSel)
  local double  = ImGui.IsItemHovered(ctx) and ImGui.IsMouseDoubleClicked(ctx, 0)
  if clicked or double then
    tv:setPaletteParam{ trackGuid = trackGuid, fxGuid = fxGuid,
                        param = prm.index, label = prm.name }
  end
  if double then tv:automateParam() end
end

-- Only visible rows hit ImGui (500-param plugin = 500 Selectables/frame).
-- One persistent clipper: ReaImGui treats per-frame CreateListClipper as a leak.
local listClipper = nil
local function clippedRows(count, drawRow)
  if not (listClipper and ImGui.ValidatePtr(listClipper, 'ImGui_ListClipper*')) then
    listClipper = ImGui.CreateListClipper(ctx)
  end
  ImGui.ListClipper_Begin(listClipper, count)
  while ImGui.ListClipper_Step(listClipper) do
    local first, last = ImGui.ListClipper_GetDisplayRange(listClipper)
    for i = first + 1, last do drawRow(i) end
  end
end

local function filteredParamRows(rows, needle)
  local matches = {}
  for _, row in ipairs(rows) do
    for _, prm in ipairs(tv:listParams(row.trackGuid, row.fxGuid)) do
      if (row.name .. ' ' .. prm.name):lower():find(needle, 1, true) then
        matches[#matches + 1] = { row = row, prm = prm }
      end
    end
  end
  if #matches == 0 then
    ImGui.TextDisabled(ctx, '(no match)')
    return
  end
  clippedRows(#matches, function(i)
    local m = matches[i]
    -- param first: the fx name is the part that survives truncation worst
    paramRow(m.row.trackGuid, m.row.fxGuid, m.prm, m.prm.name .. ' · ' .. m.row.name)
  end)
end

local openFxReq = nil   -- fxGuid whose subtree the next frame force-opens (learn click)

local function paletteTree()
  local rows = tv:paramTargets()
  if #rows == 0 then
    ImGui.TextDisabled(ctx, '(no fx reachable)')
    return
  end
  local needle = tv:paletteFilter():lower()
  if needle ~= '' then return filteredParamRows(rows, needle) end
  local fpx  = ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
  local btnW = ImGui.CalcTextSize(ctx, 'learn') + fpx * 2
  local heading
  for _, row in ipairs(rows) do
    local section = row.generator and 'generators' or 'fx'
    if section ~= heading then
      heading = section
      ImGui.TextDisabled(ctx, heading)
    end
    if openFxReq == row.fxGuid then
      ImGui.SetNextItemOpen(ctx, true)
      openFxReq = nil
    end
    local availW = select(1, ImGui.GetContentRegionAvail(ctx))
    -- 28px ≈ tree arrow + spacing; keeps the label clear of the button.
    -- ### throughout: label changes each frame (truncation, learn↔stop) → ##-hash alternates open state with scrollbar.
    local open  = ImGui.TreeNode(ctx,
      fitLabel(row.name, availW - btnW - 28) .. '###' .. row.fxGuid)
    local armed = tv:learnFxGuid() == row.fxGuid
    ImGui.SameLine(ctx, availW - btnW)
    if ImGui.SmallButton(ctx, (armed and 'stop' or 'learn') .. '###L' .. row.fxGuid) then
      tv:armLearn(row)
      openFxReq = tv:learnFxGuid()
    end
    if open then
      local params = tv:listParams(row.trackGuid, row.fxGuid)
      clippedRows(#params, function(i)
        paramRow(row.trackGuid, row.fxGuid, params[i], params[i].name)
      end)
      ImGui.TreePop(ctx)
    end
  end
end

-- The 1px vrule + palette child, positioned from the body origin so the split
-- matches arrange/wiring's even though the tracker grid isn't a child window.
local function drawParamPalette(x, y, h)
  local p     = painter.new(ctx, chrome, {})
  local lineX = x + math.floor(PANE_GAP / 2)
  p.line(lineX, y, lineX, y + h, 'text', 1)
  ImGui.SetCursorScreenPos(ctx, x + PANE_GAP, y)
  ImGui.PushFont(ctx, uiFont, gui.fontSize.ui)
  if ImGui.BeginChild(ctx, '##paramPalette', PALETTE_W, h,
                      ImGui.ChildFlags_None, ImGui.WindowFlags_NoNav) then
    chrome.pushChromeStyles()
    paletteHeader()
    paletteActions()
    paletteFilterBox()
    ImGui.Separator(ctx)
    paletteTree()
    chrome.popChromeStyles()
  end
  ImGui.EndChild(ctx)
  ImGui.PopFont(ctx)
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
    local entry = (cm:get('slotEntries') or {})[slot]
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
  cursorUp       = { ImGui.Key_UpArrow,    {ImGui.Key_P, ImGui.Mod_Super} },
  cursorDown     = { ImGui.Key_DownArrow,  {ImGui.Key_N, ImGui.Mod_Super} },
  cursorLeft     = { ImGui.Key_LeftArrow,  {ImGui.Key_B, ImGui.Mod_Super} },
  cursorRight    = { ImGui.Key_RightArrow, {ImGui.Key_F, ImGui.Mod_Super} },
  prevTrack      = { {ImGui.Key_LeftArrow,  ImGui.Mod_Alt} },
  nextTrack      = { {ImGui.Key_RightArrow, ImGui.Mod_Alt} },
  prevTake       = { {ImGui.Key_UpArrow,    ImGui.Mod_Alt} },
  nextTake       = { {ImGui.Key_DownArrow,  ImGui.Mod_Alt} },
  goTop          = { ImGui.Key_Home,       {ImGui.Key_Comma,  ImGui.Mod_Ctrl, ImGui.Mod_Shift} },
  goBottom       = { ImGui.Key_End,        {ImGui.Key_Period, ImGui.Mod_Ctrl, ImGui.Mod_Shift} },
  pageUp         = { ImGui.Key_PageUp },
  pageDown       = { ImGui.Key_PageDown },
  colLeft        = { {ImGui.Key_B, ImGui.Mod_Ctrl} },
  colRight       = { {ImGui.Key_F, ImGui.Mod_Ctrl} },
  channelLeft    = { {ImGui.Key_Tab, ImGui.Mod_Shift} },
  channelRight   = { ImGui.Key_Tab },
  noteOff        = { ImGui.Key_1 },
  shrinkNote     = { {ImGui.Key_UpArrow,  ImGui.Mod_Super, ImGui.Mod_Shift} },
  growNote       = { {ImGui.Key_DownArrow, ImGui.Mod_Super, ImGui.Mod_Shift} },
  nudgeBack      = { {ImGui.Key_UpArrow,   ImGui.Mod_Super} },
  nudgeForward   = { {ImGui.Key_DownArrow,   ImGui.Mod_Super} },
  eventShiftLeft  = {{ImGui.Key_LeftArrow,   ImGui.Mod_Super} },
  eventShiftRight = {{ImGui.Key_RightArrow,   ImGui.Mod_Super} },
  insertRowCol   = { {ImGui.Key_DownArrow, ImGui.Mod_Ctrl} },
  deleteRowCol   = { {ImGui.Key_UpArrow,   ImGui.Mod_Ctrl} },
  addTypedCol    = { {ImGui.Key_RightArrow, ImGui.Mod_Ctrl} },
  hideExtraCol   = { {ImGui.Key_LeftArrow, ImGui.Mod_Ctrl} },
  delete         = { ImGui.Key_Period },
  interpolate    = { {ImGui.Key_I, ImGui.Mod_Ctrl} },
  selectUp       = { {ImGui.Key_UpArrow,    ImGui.Mod_Shift} },
  selectDown     = { {ImGui.Key_DownArrow,  ImGui.Mod_Shift} },
  selectLeft     = { {ImGui.Key_LeftArrow,  ImGui.Mod_Shift} },
  selectRight    = { {ImGui.Key_RightArrow, ImGui.Mod_Shift} },
  cycleBlock     = { {ImGui.Key_Space,       ImGui.Mod_Super} },
  cycleVBlock    = { {ImGui.Key_O,           ImGui.Mod_Super} },
  swapBlockEnds  = { {ImGui.Key_GraveAccent, ImGui.Mod_Ctrl} },
  selectClear    = { {ImGui.Key_G, ImGui.Mod_Super} },
  cut            = { {ImGui.Key_W, ImGui.Mod_Super}, {ImGui.Key_X, ImGui.Mod_Ctrl} },
  copy           = { {ImGui.Key_W, ImGui.Mod_Ctrl},  {ImGui.Key_C, ImGui.Mod_Ctrl} },
  paste          = { {ImGui.Key_Y, ImGui.Mod_Super}, {ImGui.Key_V, ImGui.Mod_Ctrl} },
  duplicateDown  = { {ImGui.Key_D, ImGui.Mod_Ctrl} },
  deleteSel      = { ImGui.Key_Delete },
  nudgeCoarseUp   = { {ImGui.Key_Equal, ImGui.Mod_Ctrl} },
  nudgeCoarseDown = { {ImGui.Key_Minus, ImGui.Mod_Ctrl} },
  nudgeFineUp     = { {ImGui.Key_Equal, ImGui.Mod_Shift} },
  nudgeFineDown   = { {ImGui.Key_Minus, ImGui.Mod_Shift} },
  scaleHalf       = { {ImGui.Key_9, ImGui.Mod_Shift} },  -- '('
  scaleDouble     = { {ImGui.Key_0,  ImGui.Mod_Shift} },  -- ')'
  doubleRPB      = { {ImGui.Key_Equal, ImGui.Mod_Super} },
  halveRPB       = { {ImGui.Key_Minus, ImGui.Mod_Super} },
  setRPB         = { {ImGui.Key_Z,     ImGui.Mod_Super} },
  takeProperties = { {ImGui.Key_Backspace, ImGui.Mod_Super} },
  newTakeBelow           = { {ImGui.Key_Enter, ImGui.Mod_Super} },
  duplicateUnpooledBelow = { {ImGui.Key_Enter, ImGui.Mod_Super, ImGui.Mod_Shift} },
  matchGridToCursor = { {ImGui.Key_G, ImGui.Mod_Super, ImGui.Mod_Shift} },
  groupMark         = { {ImGui.Key_M, ImGui.Mod_Ctrl} },
  groupDuplicate    = { {ImGui.Key_D, ImGui.Mod_Ctrl, ImGui.Mod_Shift} },
  groupPaste        = { {ImGui.Key_V, ImGui.Mod_Ctrl, ImGui.Mod_Shift} },
  groupLocalToggle  = { {ImGui.Key_M, ImGui.Mod_Super} },
  regionEnter       = { {ImGui.Key_R, ImGui.Mod_Super} },
  groupInstPrev     = { ImGui.Key_LeftBracket },
  groupInstNext     = { ImGui.Key_RightBracket },
  inputOctaveUp   = { {ImGui.Key_8, ImGui.Mod_Shift} },
  inputOctaveDown = { ImGui.Key_Slash },
  inputSampleUp   = { {ImGui.Key_Period, ImGui.Mod_Shift} },  -- '>'
  inputSampleDown = { {ImGui.Key_Comma,  ImGui.Mod_Shift} },  -- '<'
  playFromTop    = { ImGui.Key_F6 },
  playFromCursor = { ImGui.Key_F7 },
  openTemperPicker = { {ImGui.Key_T, ImGui.Mod_Super} },
  openSwingPicker  = { {ImGui.Key_S, ImGui.Mod_Super} },
  openSwingEditor  = { {ImGui.Key_E, ImGui.Mod_Super} },
  quantize              = { {ImGui.Key_Q, ImGui.Mod_Ctrl} },
  quantizeKeepRealised  = { {ImGui.Key_Q, ImGui.Mod_Ctrl, ImGui.Mod_Shift} },
}
for i = 0, 9 do
  cmgr:scope('tracker'):bind('advBy' .. i, { {ImGui.Key_0 + i, ImGui.Mod_Ctrl} })
end

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
--contract: no-op when modal open, picker active, or any ImGui item is active
--contract: every fresh press enters; only lastEditKey autorepeats
--contract: scans editKeys per frame; reads ec/grid fresh (editEvent may rebuild)
local function handleKeys(kr)
  if modalHost:isOpen() or chrome.pickerIsActive() then return end
  if ImGui.IsAnyItemActive(ctx) then return end
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

local function openPrompt(title, prompt, callback, resolve)
  modalHost:openPrompt{ title = title, prompt = prompt, callback = callback, resolve = resolve }
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

  ImGui.Text(ctx, 'Item name')
  local rvN, name = ImGui.InputText(ctx, '##takeprops_name', s.nameBuf)
  if rvN then s.nameBuf = name end

  ImGui.Text(ctx, 'Length (beats)')
  -- Appearing frame: the same Enter that opened the popup is still
  -- IsKeyPressed=true this frame. Gate OK/Cancel below so a binding
  -- like Super+Shift+Enter doesn't immediately self-dismiss the modal.
  local appearing = ImGui.IsWindowAppearing(ctx)
  if appearing or s.refocusBeats then
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
             or first == 'a' and (a:sub(2, 2) == 't' and 'at' or 'automation')
             or first == 'd' and 'dly'
             or first == 'p' and (a:sub(2, 2) == 'c' and 'pc' or 'pb')
             or a
  return canon .. digits
end

local function addColumn()
  openPrompt('Add Column', 'note, cc0-127, pb, at, pc, dly, auto', function(typeStr)
    local type, idStr = typeStr:lower():match('^(%a+)(%d*)$')
    if not type then return end
    if type == 'automation' then focusFilterReq = true; return end
    local id = idStr ~= '' and tonumber(idStr) or nil
    if type == 'dly' then tv:showDelay()
    elseif util.oneOf('note cc pb at pc', type) then
      if type == 'cc' and (not id or id < 0 or id > 127) then return end
      tv:addExtraCol(type, id)
    end
  end, resolveColType)
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


local tracker = cmgr:scope('tracker')

tracker:registerAll{
  setRPB = function()
    openPrompt('Rows per beat', '1-32', function(buf)
      local n = tonumber(buf); if n then tv:setRowPerBeat(n) end
    end)
  end,

  takeProperties         = { function() renderer:openTakeProperties{} end, 'Take properties' },
  newTakeBelow           = function() arrange().newTakeBelow() end,
  duplicateUnpooledBelow = { function() arrange().duplicateUnpooledBelow() end, 'Duplicate take (unpooled) below' },

  prevTrack = { function() arrange().gotoTrack(-1) end, 'Previous track' },
  nextTrack = { function() arrange().gotoTrack(1)  end, 'Next track' },
  prevTake  = { function() arrange().gotoTake(-1)  end, 'Previous take' },
  nextTake  = { function() arrange().gotoTake(1)   end, 'Next take' },

  addTypedCol = addColumn,
  hideExtraCol = { removeOrHideCol, 'Hide / remove column' },

  quantize             = { scopedAction('quantize',               'quantize'),             'Quantize' },
  quantizeKeepRealised = { scopedAction('quantize keep realised', 'quantizeKeepRealised'), 'Quantize (keep realised)' },

  openSwingEditor = function() swingEditor:open() end,

  openTemperPicker = function() chrome.requestPickerOpen('temper') end,
  openSwingPicker  = function() chrome.requestPickerOpen('swing')  end,
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

function renderer:renderToolbarBits(_)
  chrome.resetPickerActive()
  drawTrackerToolbarBits()
end

--contract: calls computeLayout twice
--invariant: lane-strip drag callbacks may flush tv.grid.cols and clear col.x
--contract: second pass repopulates layout for drawTracker
function renderer:renderBody(_, w, h, dispatch)
  -- Swing editor commandeers the body region. The editor draws in
  -- chrome/UI register, not the tracker monospace — push uiFont
  -- explicitly so it doesn't inherit the (yet-to-be-pushed) tracker
  -- font. Toolbar stays drawn above with non-swing segments greyed;
  -- dispatcher is gated via focusState so tracker bindings don't
  -- fire underneath.
  if swingEditor:isOpen() then
    -- Dispatch BEFORE render so focusState reads the modal-active flag
    -- while it's still set; render is what clears it on Enter/Cancel.
    -- Same ordering as the main path: dispatch → drawModal.
    if dispatch then dispatch(self:focusState()) end
    ImGui.PushFont(ctx, uiFont, gui.fontSize.ui)
    swingEditor:render(w, h)
    ImGui.PopFont(ctx)
    return
  end
  -- No bound take ⇒ empty grid. Body pushes no Col_Text, so push uiFont +
  -- grid text colour explicitly; still dispatch so global keys fire.
  if #tv.grid.cols == 0 then
    if dispatch then dispatch(self:focusState()) end
    ImGui.PushFont(ctx, uiFont, gui.fontSize.ui)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, chrome.colour('text'))
    ImGui.Text(ctx, arrange().currentTrackHasTakes()
      and 'No take at the cursor.' or 'No MIDI takes on this track.')
    ImGui.PopStyleColor(ctx)
    ImGui.PopFont(ctx)
    return
  end
  local ox, oy = ImGui.GetCursorScreenPos(ctx)
  local gridW  = math.max(120, w - PALETTE_W - PANE_GAP)
  ImGui.PushFont(ctx, font, 15)
  computeLayout(gridW, h)
  drawLaneStrip()
  -- Lane-drag callbacks may rebuild grid.cols; re-layout for drawTracker.
  computeLayout(gridW, h)
  drawTracker()
  ImGui.PopFont(ctx)

  drawParamPalette(ox + gridW, oy, h)
  tv:pollLearn(ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_AnyWindow))

  handleMouse()
  local kr = dispatch and dispatch(self:focusState()) or { commandHeld = {} }
  handleKeys(kr)

  tv:tick()
end

function renderer:renderStatusBar(_)
  drawStatusBar()
end

-- suppressKbd: a popup or modal owns input — dispatcher does nothing.
-- pageSuppressed: a body-region editor (swing, tuning) commandeers the
--   page — dispatcher walks root bindings only, so playPause/quit/undo
--   still fire while page-scoped commands stay quiet.
-- acceptCmds:  the page is visible and nothing inside it is currently
--   consuming a keystroke. We deliberately don't gate on which child
--   window holds focus: a toolbar click leaves the chrome focused
--   transiently, but bound commands should still fire. Anything that
--   genuinely needs the keys (a focused InputText, an active slider,
--   a held button) shows up as IsAnyItemActive.
--shape: focusState = { suppressKbd:bool, pageSuppressed:bool, acceptCmds:bool }
function renderer:focusState()
  if not ctx then return { suppressKbd = false, pageSuppressed = false, acceptCmds = false } end
  local suppressKbd    = modalHost:isOpen() or chrome.pickerIsActive() or swingEditor:modalActive()
  local pageSuppressed = swingEditor:isOpen()
  return {
    suppressKbd    = suppressKbd,
    pageSuppressed = pageSuppressed,
    acceptCmds     = (not suppressKbd) and not ImGui.IsAnyItemActive(ctx),
  }
end

-- The controller closes these take-scoped editors on unbind/dropTake; they
-- live render-side but their lifetime follows the bound take.
function renderer:closeTransients() swingEditor:close() end

return renderer

