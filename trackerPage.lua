-- See docs/trackerPage.md for the model and API reference.

loadModule('util')
loadModule('timing')

local function print(...)
  return util.print(...)
end

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'

function newTrackerPage(vm, cm, cmgr, chrome, ctxArg, fontArg, uiFontArg)

  ---------- PRIVATE

  local GUTTER      = 4    -- in grid chars
  local HEADER      = 3    -- in grid rows

  local gridX       = nil
  local gridY       = nil
  local gridOriginX = 0
  local gridOriginY = 0
  local gridWidth   = 0
  local gridHeight  = 0

  -- Per-frame layout, populated by computeLayout() before any draw routine
  -- that needs it. drawLaneStrip and drawTracker both consume these.
  local chanX, chanW, chanOrder, totalWidth = {}, {}, {}, 0

  -- Pack columns left-to-right starting at scrollCol, fitting as many as
  -- gridWidth allows; sets col.x on visible cols, clears on the rest.
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

  local ctx         = ctxArg
  local font        = fontArg     -- monospace, used inside the tracker grid
  local uiFont      = uiFontArg   -- system sans-serif, used for chrome (toolbar, status, modals, swing editor)
  local dragging    = false   -- tracker-grid selection drag: click → held → release
  local modalState = nil   -- nil = closed, else { title, prompt, callback, buf, kind? }
  local swingEditor = newSwingEditor(vm, cm, chrome, ctxArg)
  local pickerOpenRequest = nil -- 'temper' | 'swing' | nil; consumed next frame by drawSlotPicker
  local pickerFilter = {}       -- kind -> typeahead buffer; reset on each open
  local pickerCursor = {}       -- kind -> 1-based highlight index into filtered matches
  local pickerActive  = false   -- a picker popup owned input this frame; handleKeys must skip

  -- Lane strip delegates all envelope drawing and mouse handling to a
  -- generic curve editor. drawLaneStrip publishes laneConsumed each frame;
  -- handleMouse short-circuits when it's set.
  local curveEd      = newCurveEditor(ctxArg)
  local laneConsumed = false
  local toolbar                              -- lazy: chrome may be nil at construction in tests

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
      label = select(1, vm:noteProjection(evt)) or noteName(evt.pitch)
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

    if showDelay then
      local d = evt.delay or 0
      if d == 0 then
        return text .. ' ···', nil, overrides
      end
      text = text .. ' ' .. string.format('%03d', math.abs(d))
      if d < 0 then
        local n = #text
        overrides = overrides or {}
        overrides[n-2], overrides[n-1], overrides[n] = 'negative', 'negative', 'negative'
      end
    end
    return text, nil, overrides
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

  ----- Drawing

  local function printer(ctx, gX, gY, x0, y0)
    local drawList = ImGui.GetWindowDrawList(ctx)
    local halfW    = math.floor(gX / 2)
    local halfH    = math.floor(gY / 2)

    local pt = {}

    local function drawTextAt(xpos, ypos, txt, c)
      for char in txt:gmatch(utf8.charpattern) do
        ImGui.DrawList_AddText(drawList, xpos, ypos, chrome.colour(c), char)
        xpos = xpos + gX
      end
    end

    function pt:text(x, y, txt, c, font)
      if font then
        ImGui.PushFont(ctx, font, 15)
      end
      drawTextAt(x0 + x * gX, y0 + y * gY - 1, txt, c)
      if font then
        ImGui.PopFont(ctx)
      end
    end

    function pt:textCentred(x1, x2, y, txt, c)
      local textWidth = ImGui.CalcTextSize(ctx, txt)
      local maxWidth  = (x2 - x1 + 1) * gX
      local offset    = math.floor((maxWidth - textWidth) / 2)
      drawTextAt(x0 + x1 * gX + offset, y0 + y * gY, txt, c)
    end

    function pt:textCentredSmall(x1, x2, y, txt, size, c)
      local scale     = size / 15
      local textWidth = ImGui.CalcTextSize(ctx, txt) * scale
      local maxWidth  = (x2 - x1 + 1) * gX
      local xPos = x0 + x1 * gX + math.floor((maxWidth - textWidth) / 2)
      ImGui.DrawList_AddTextEx(drawList, font, size, xPos, y0 + y * gY, chrome.colour(c), txt)
    end

    function pt:vLine(x, y1, y2, c)
      ImGui.DrawList_AddLine(drawList, x0 + x * gX + halfW, y0 + y1 * gY, x0 + x * gX + halfW, y0 + y2 * gY + gY, chrome.colour(c), 1)
    end

    function pt:hLine(x1, x2, y, c, yOff)
      local yPos = y0 + (y + (yOff or 0)) * gY
      ImGui.DrawList_AddLine(drawList, x0 + x1 * gX, yPos, x0 + x2 * gX + gX, yPos, chrome.colour(c), 1)
    end

    function pt:box(x1, x2, y1, y2, c)
      ImGui.DrawList_AddRectFilled(drawList, x0 + x1 * gX, y0 + y1 * gY, x0 + x2 * gX + gX, y0 + y2 * gY + gY, chrome.colour(c))
    end

    return pt
  end

  -- Effective lane-strip row count: 0 when hidden, else the configured size.
  -- Single point of truth for both layout and rendering.
  local function laneStripRows()
    if not cm:get('laneStrip.visible') then return 0 end
    return cm:get('laneStrip.rows') or 0
  end

  -- One picker = a "<heading>:" label followed by a button "<preview> ▾"
  -- that opens a popup containing Off, current library entries, and any
  -- unseeded presets (prefixed '+ '). `onPick(name)` receives nil for Off,
  -- a lib name for a normal entry, or a preset name for an unseeded preset —
  -- the callback is responsible for seeding the lib in that case.
  --
  -- The popup carries a typeahead filter (autofocused on open). Enter
  -- picks the first surviving match; group separators show only when
  -- the filter is empty (groups become incoherent under filtering).
  -- Generic searchable picker: heading + button + popup with InputText
  -- filter, arrow-key nav, group separators, and click-or-Enter commit.
  -- Domain-agnostic — caller supplies the flat item list and the button
  -- label. Each item: { label, key, group=1, current=bool }.
  --
  -- width / minWidth / maxWidth on d control the button width; width=n
  -- pins both bounds. Without any, the button sits at intrinsic width.
  local function drawSlotPicker(d)
    local popupId = '##picker_' .. d.kind

    -- Heading inherits the toolbar's outer Col_Text push (chrome.shade);
    -- no inner push needed.
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, d.heading .. ':  ')
    ImGui.SameLine(ctx)

    -- ##d.kind disambiguates the ImGui ID — different pickers may all show
    -- the same buttonLabel once the heading is no longer part of the ID.
    local btnTxt = d.buttonLabel .. ' \xe2\x96\xbe##' .. d.kind
    local minW, maxW = d.minWidth, d.maxWidth
    if d.width then minW, maxW = d.width, d.width end
    local btnW
    if minW or maxW then
      local tw  = ImGui.CalcTextSize(ctx, btnTxt)
      local fpx = ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
      btnW = tw + fpx * 2
      if minW and btnW < minW then btnW = minW end
      if maxW and btnW > maxW then btnW = maxW end
    end
    local opening
    if btnW then opening = ImGui.Button(ctx, btnTxt, btnW, 0)
    else         opening = ImGui.Button(ctx, btnTxt) end
    -- Anchor popup to the button rect; otherwise OpenPopup uses the mouse
    -- position at call time, which puts a keyboard-triggered popup at the
    -- text cursor instead of under the toolbar.
    local btnX = ImGui.GetItemRectMin(ctx)
    local _, btnY = ImGui.GetItemRectMax(ctx)
    if pickerOpenRequest == d.kind then
      pickerOpenRequest = nil
      opening = true
    end
    if opening then
      pickerFilter[d.kind] = ''
      ImGui.OpenPopup(ctx, popupId)
    end

    ImGui.SetNextWindowPos(ctx, btnX, btnY, ImGui.Cond_Appearing)
    -- NoNav: kill ImGui's built-in keyboard nav highlight on the popup —
    -- otherwise it draws a second cursor that fights ours and steals
    -- arrow keys / character input from the filter InputText.
    if not ImGui.BeginPopup(ctx, popupId, ImGui.WindowFlags_NoNav) then return end
    pickerActive = true  -- block handleKeys this frame so Enter doesn't leak through

    if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
    ImGui.SetNextItemWidth(ctx, 180)
    local prevFilter = pickerFilter[d.kind] or ''
    -- Plain InputText (no EnterReturnsTrue): with that flag, ReaImGui only
    -- commits the buffer back on Enter, so the live filter would never
    -- update during typing. We watch Enter ourselves below.
    local _, filter = ImGui.InputText(ctx, '##filter_' .. d.kind, prevFilter)
    pickerFilter[d.kind] = filter
    local entered = ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
                 or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)
    ImGui.Separator(ctx)

    local lf = filter:lower()
    local matches, currentMatch = {}, nil
    for _, it in ipairs(d.items) do
      if filter == '' or it.label:lower():find(lf, 1, true) then
        matches[#matches + 1] = it
        if it.current then currentMatch = #matches end
      end
    end

    -- Initial highlight: on open or on filter change, jump to the current
    -- pick if it survived; otherwise top of list. Arrow keys then walk
    -- the filtered list with wrap; Enter picks the highlighted match.
    if ImGui.IsWindowAppearing(ctx) or filter ~= prevFilter then
      pickerCursor[d.kind] = currentMatch or 1
    end
    local cursor = pickerCursor[d.kind] or 1
    local n = #matches
    if n > 0 then
      if ImGui.IsKeyPressed(ctx, ImGui.Key_DownArrow) then
        cursor = cursor % n + 1
      elseif ImGui.IsKeyPressed(ctx, ImGui.Key_UpArrow) then
        cursor = (cursor - 2) % n + 1
      end
    end
    cursor = math.min(math.max(cursor, 1), math.max(n, 1))
    pickerCursor[d.kind] = cursor

    if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
      ImGui.CloseCurrentPopup(ctx)
    elseif entered then
      if matches[cursor] then d.onPick(matches[cursor].key) end
      ImGui.CloseCurrentPopup(ctx)
    else
      local lastGroup
      for i, it in ipairs(matches) do
        if filter == '' and lastGroup and lastGroup ~= (it.group or 1) then
          ImGui.Separator(ctx)
        end
        if ImGui.Selectable(ctx, it.label, i == cursor) then d.onPick(it.key) end
        lastGroup = it.group or 1
      end
    end

    ImGui.EndPopup(ctx)
  end

  -- Item builder for the lib+presets+Off picker shape (tempers, swings,
  -- colSwing). Off is group 1; saved lib slots are group 2; preset names
  -- not yet saved get a "+" prefix in group 3.
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

  -- Seed-and-select wrappers: the picker hands us a name and we ensure
  -- the lib has it before committing to the slot.
  local function pickTemper(name)
    if name and not cm:get('tempers')[name] then
      vm:setTemper(name, tuning.presets[name])
    end
    vm:setTemperSlot(name)
  end

  local function pickSwing(name)
    if name and not cm:get('swings')[name] then
      vm:setSwingComposite(name, timing.presets[name])
    end
    vm:setSwingSlot(name)
  end

  local function pickColSwing(chan, name)
    if name and not cm:get('swings')[name] then
      vm:setSwingComposite(name, timing.presets[name])
    end
    vm:setColSwingSlot(chan, name)
  end

  -- Identity composite ('id') is the no-swing default — represented in
  -- the UI as "Off" rather than as a pickable preset row.
  local SWING_PRESET_EXCLUDE = { id = true }

  -- Sample slot picker for tracker mode. Lists only loaded slots
  -- (those that published a name via gmem); selecting one writes
  -- currentSample. The button label shows the current slot's hex
  -- index even when unloaded so users can see what `<` / `>` will
  -- step away from. No "Off" row — every slot is real, not absent.
  local function drawSampleDropdown()
    local cur     = cm:get('currentSample')
    local names   = cm:get('samplerNames') or {}
    local curName = names[cur]
    local indices = {}
    for idx in pairs(names) do indices[#indices + 1] = idx end
    table.sort(indices)
    local items = {}
    for _, idx in ipairs(indices) do
      items[#items + 1] = {
        label   = string.format('%02X  %s', idx, names[idx]),
        key     = idx,
        group   = 1,
        current = idx == cur,
      }
    end
    drawSlotPicker {
      kind        = 'sample',
      heading     = 'Sample',
      buttonLabel = string.format('%02X', cur) .. (curName and (' ' .. curName) or ''),
      width       = 220,
      items       = items,
      onPick      = function(idx) cm:set('take', 'currentSample', idx) end,
    }
  end

  -- Toolbar segments. Order is declaration order; chrome.makeToolbar
  -- emits separators between adjacent segments and wraps a segment to
  -- the next row when it would overflow available width (one-frame slop
  -- on cached width). Each render closure reads cm/vm fresh at call
  -- time, so segments can be declared once and reused per frame.
  local toolbarSegments = {
    {
      id = 'rowsPerBeat',
      render = function()
        local rowPerBeat = cm:get('rowPerBeat')
        ImGui.AlignTextToFramePadding(ctx)
        ImGui.Text(ctx, 'Rows/beat:')
        ImGui.SameLine(ctx, 0, 12)
        local textW = ImGui.CalcTextSize(ctx, '32')
        local btnW  = ImGui.GetFrameHeight(ctx)
        ImGui.SetNextItemWidth(ctx, textW + btnW * 2 + 16)
        -- Spinner FramePadding shrinks at 9→10 so the buttons don't
        -- crowd the two-digit field.
        ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, rowPerBeat > 9 and 5 or 8, 3)
        local changed, n = ImGui.InputInt(ctx, '##rpb', rowPerBeat, 1, 4)
        ImGui.PopStyleVar(ctx, 1)
        if changed then vm:setRowPerBeat(util.clamp(n, 1, 32)) end
      end,
    },
    {
      id = 'graph',
      render = function()
        local cv, newVis = chrome.checkbox('  Graph', cm:get('laneStrip.visible'))
        if cv then cm:set('global', 'laneStrip.visible', newVis) end
      end,
    },
    {
      id = 'tuning',
      render = function()
        local cur = cm:get('temper')
        drawSlotPicker {
          kind        = 'temper', heading = 'Tuning',
          buttonLabel = cur or 'Off',
          items       = libPickerItems(cur, cm:get('tempers'), tuning.presets),
          onPick      = pickTemper,
        }
      end,
    },
    {
      id = 'swing',
      render = function()
        do
          local cur = cm:get('swing')
          drawSlotPicker {
            kind        = 'swing', heading = 'Swing',
            buttonLabel = cur or 'Off',
            items       = libPickerItems(cur, cm:get('swings'),
                                         timing.presets, SWING_PRESET_EXCLUDE),
            onPick      = pickSwing,
          }
        end
        -- Per-column swing rides inside the same segment with a tighter
        -- 8 px gap; channel comes from the cursor's column. Disabled
        -- path triggers if a column ever drops its midiChan.
        local cursorCol = vm.grid.cols[vm:ec():col()]
        local chan      = cursorCol and cursorCol.midiChan
        ImGui.SameLine(ctx, 0, 8)
        chrome.disabledIf(not chan, function()
          local cur = chan and cm:get('colSwing')[chan] or nil
          drawSlotPicker {
            kind        = 'colSwing', heading = 'Ch swing',
            buttonLabel = cur or 'Off',
            items       = libPickerItems(cur, cm:get('swings'),
                                         timing.presets, SWING_PRESET_EXCLUDE),
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
  }

  local function drawTrackerToolbarBits()
    toolbar = toolbar or chrome.makeToolbar()
    toolbar(toolbarSegments)
  end

  -- Establish per-frame layout: char metrics, column packing, and the
  -- integer-row grid height that fits within `budgetH` pixels (the space
  -- the loop has reserved between toolbar and statusBar). Width comes
  -- from the current GetContentRegionAvail; height is explicit so the
  -- caller can carve out a fixed footer first.
  local function computeLayout(budgetW, budgetH)
    local grid = vm.grid
    local _, scrollCol = vm:scroll()

    if not gridX then
      local charW, charH = ImGui.CalcTextSize(ctx, 'W')
      gridX = 2 * math.ceil(charW / 2) - 1
      gridY = 2 * math.ceil(charH / 2) - 1
    end

    gridWidth  = math.max(1, math.floor(budgetW / gridX) - GUTTER)
    -- Lane strip eats a fixed number of rows above the tracker header.
    local laneRows = laneStripRows()
    gridHeight = math.max(1, math.floor(budgetH / gridY) - HEADER - 1 - laneRows)
    vm:setGridSize(gridWidth, gridHeight)

    chanX, chanW, chanOrder, totalWidth = layoutColumns(grid.cols, scrollCol)
  end

  ----- Lane strip

  -- Single horizontal envelope above the grid, mirroring the tracker's
  -- horizontal extent. Renders the column the cursor is currently on if
  -- it's a cc/pb/at; blank background otherwise. Time on x, value on y;
  -- shape (step/linear/curve) honoured between consecutive events.
  local laneRenderable = { cc = true, pb = true, at = true }

  -- Min/max are in *configured* rows. The strip pads a half-row top and
  -- bottom, so visible inner-band height = (rows - 1) gridY. A min of 3
  -- gives the requested 2-row visible floor.
  local LANE_ROW_MIN = 3
  local LANE_ROW_MAX = 32

  local function drawLaneStrip()

    local laneRows = laneStripRows()
    if laneRows <= 0 then laneConsumed = false; return end

    local px, py    = ImGui.GetCursorScreenPos(ctx)
    local x0        = px + GUTTER * gridX
    local y0        = py
    local w         = totalWidth * gridX
    local h         = laneRows  * gridY
    local drawList  = ImGui.GetWindowDrawList(ctx)
    local scrollRow = select(1, vm:scroll())
    local numRows   = vm.grid.numRows or 0
    -- Strip's horizontal extent maps to the rows actually rendered: min of
    -- viewport height and remaining data, matching the grid below.
    local rowSpan   = math.max(1, math.min(gridHeight, numRows - scrollRow))
    local function rowToX(row) return x0 + (row - scrollRow) / rowSpan * w end

    -- Half-row padding top and bottom so anchor dots at the value extremes
    -- have breathing room.
    local pad  = gridY / 2
    local yTop = y0 + pad
    local yBot = y0 + h - pad

    if w > 0 then
      local barCol, beatCol, dividerCol =
        chrome.colour('rowBarStart'), chrome.colour('rowBeat'), chrome.colour('laneRowDivider')
      for row = scrollRow, scrollRow + rowSpan - 1 do
        local x = math.floor(rowToX(row)) + 0.5
        local isBar, isBeat = vm:rowBeatInfo(row)
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
    local colIdx = vm:ec():col()
    local col    = vm.grid.cols[colIdx]
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
        drawList = drawList,
        rect     = { x0 = x0, yTop = yTop, w = w, h = yBot - yTop },
        vMin = vMin, vMax = vMax,
        tMin = scrollRow, tMax = scrollRow + rowSpan,
        events    = visible,
        tOf       = function(evt) return vm:ppqToRow(evt.ppq, chan) end,
        -- t is in row-space; map fracT back to ppq before sampling so
        -- vm:rowToPPQ's integer rounding doesn't plateau the curve.
        evalCurve = function(A, B, fracT)
          local fracP = A.ppq + fracT * (B.ppq - A.ppq)
          return vm:sampleCurve(A, B, fracP)
        end,
        snap    = function(t) return util.round(t) end,
        hovered = stripHovered,
        dragId  = colIdx,
        colours = {
          axis         = chrome.colour('laneAxis'),
          envelope     = chrome.colour('laneEnvelope'),
          anchor       = chrome.colour('laneAnchor'),
          anchorActive = chrome.colour('laneAnchorActive'),
        },
        callbacks = {
          onMove     = function(idx, newT, newVal) vm:moveLaneEvent(col, idx, newT, newVal) end,
          onMoveFree = function(idx, newT, newVal) vm:moveLaneEvent(col, idx, newT, newVal) end,
          onInsert   = function(t, val) return vm:addLaneEvent(col, colIdx, vm:rowToPPQ(t, chan), val) end,
          onDelete     = function(idx)      vm:deleteLaneEvent(col, idx) end,
          onTension    = function(idx, tau) vm:setLaneTension (col, idx, tau) end,
          onCycleShape = function(idx)      vm:cycleLaneShape (col, idx) end,
        },
      }
    end

    if w > 0 then
      ImGui.DrawList_AddRect(drawList, x0, yTop, x0 + w, yBot, chrome.colour('rowBeat'), 0, 0, 1)
    end

    ImGui.Dummy(ctx, (totalWidth + GUTTER) * gridX, h)

    -- Height nudges in the gutter, top-aligned with the strip's visible box.
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

  local function drawTracker()
    local grid = vm.grid
    local ec = vm:ec()
    local cursorRow, cursorCol, cursorStop = ec:pos()
    local scrollRow, scrollCol, lastVisCol = vm:scroll()

    local px, py = ImGui.GetCursorScreenPos(ctx)
    gridOriginX  = px + GUTTER * gridX
    gridOriginY  = py + HEADER * gridY

    local numRows = grid.numRows or 0
    local draw = printer(ctx, gridX, gridY, gridOriginX, gridOriginY)

    -- Solo (amber) wins over mute (red): audibility semantic.
    draw:text(-GUTTER, -HEADER, 'Row', 'accent')
    for chan = 1, 16 do
      if chanX[chan] then
        local key = vm:isChannelSoloed(chan) and 'solo'
                 or vm:isChannelMuted(chan)  and 'mute'
                 or 'accent'
        draw:textCentred(chanX[chan], chanX[chan] + chanW[chan] - 1,
                         -HEADER, 'Ch ' .. chan, key)
      end
    end
    -- laneByChan: per-channel counter so note columns show their lane number.
    local laneByChan = {}
    for _, col in ipairs(grid.cols) do
      local sub
      if col.type == 'note' then
        local n = (laneByChan[col.midiChan] or 0) + 1
        laneByChan[col.midiChan] = n
        sub = tostring(n)
      elseif col.type == 'cc' then
        sub = tostring(col.cc)
      end
      if col.x then
        local xr = col.x + col.width - 1
        draw:textCentred(col.x, xr, -2.1, col.label)
        if sub then
          draw:textCentredSmall(col.x, xr, -1.2, sub, 14, 'accent')
        end
      end
    end

    draw:hLine(-GUTTER, totalWidth - 1, 0, 'text', -0.25)

    for i = 1, #chanOrder - 1 do
      local chan = chanOrder[i]
      draw:vLine(chanX[chan] + chanW[chan], -HEADER, gridHeight - 1, 'separator')
    end

    for y = 0, gridHeight - 1 do
      local row = scrollRow + y
      if row >= numRows then break end

      local isBarStart, isBeatStart = vm:rowBeatInfo(row)

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

    local drawList = ImGui.GetWindowDrawList(ctx)
    local tailBord = chrome.colour('tailBord')
    local viewTop  = scrollRow
    local viewBot  = scrollRow + gridHeight
    for _, col in ipairs(grid.cols) do
      if col.x and col.tails then
        local colPx = gridOriginX + col.x * gridX
        for _, tail in ipairs(col.tails) do
          if tail.endRow > viewTop and tail.startRow < viewBot then
            local y1 = gridOriginY + math.max(tail.startRow - scrollRow, 0) * gridY
            local y2 = gridOriginY + math.min(tail.endRow - scrollRow, gridHeight) * gridY
            local x1 = colPx - 4
            ImGui.DrawList_AddRectFilled(drawList, x1-1, y1-1, x1 + 4, y1+1, tailBord)
            ImGui.DrawList_AddRectFilled(drawList, x1-2, y1, x1, y2, tailBord)
            ImGui.DrawList_AddRectFilled(drawList, x1-1, y2-1, x1 + 4, y2+1, tailBord)
          end
        end
      end
    end

    -- Cells. Dots (·) are always 'inactive' even when the rest of the
    -- cell is active, so split runs on dot boundaries.
    for y = 0, gridHeight - 1 do
      local row = scrollRow + y
      if row >= numRows then break end
      for x, col in ipairs(grid.cols) do
        if col.x then
          local evt = col.cells and col.cells[row]
          local ghost = not evt and col.ghosts and col.ghosts[row]
          local text, textCol, overrides
          if ghost then
            local cellCol
            text, cellCol = renderCell({ val = ghost.val }, col, row)
            textCol = cellCol == 'negative' and 'ghostNegative' or 'ghost'
          else
            text, textCol, overrides = renderCell(evt, col, row)
            if col.overflow and col.overflow[row] then textCol, overrides = 'overflow', nil end
            textCol = textCol or 'text'
            if textCol == 'text' and col.offGrid and col.offGrid[row] then
              textCol = 'offGrid'
            end
          end
          if vm:isChannelEffectivelyMuted(col.midiChan) then textCol, overrides = 'inactive', nil end
          if not text then text = '' end
          local cx, i = col.x, 0
          for ch in text:gmatch(utf8.charpattern) do
            i = i + 1
            local c = (overrides and overrides[i]) or (ch == '·' and 'inactive' or textCol)
            draw:text(cx, y, ch, c)
            cx = cx + 1
          end
        end
      end
    end

    -- Off-grid bars: projection gap between note intent and displayed step.
    -- Drawn only under an active temperament, only for notes with a non-zero gap.
    if vm:activeTemper() then
      local barCol = chrome.colour('accent')
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
              local _, gap, halfGap = vm:noteProjection(evt)
              if gap and gap ~= 0 and halfGap > 0 then
                local yTop = gridOriginY + y * gridY + 1
                local offset = util.clamp(gap / halfGap, -1, 1) * halfW
                ImGui.DrawList_AddLine(drawList, x0, yTop, x1, yTop, barCol, 1)
                local tickX = cx + offset
                ImGui.DrawList_AddLine(drawList, tickX, yTop - 1, tickX, yTop + 2, barCol, 1)
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

  local function drawStatusBar()
    local ec = vm:ec()
    local cursorRow, cursorCol = ec:row(), ec:col()
    local rowPerBeat    = cm:get('rowPerBeat')
    local currentOctave = cm:get('currentOctave')
    local advanceBy     = cm:get('advanceBy')
    local sampleSuffix = ''
    if cm:get('trackerMode') then
      local slot = cm:get('currentSample')
      local name = (cm:get('samplerNames') or {})[slot]
      sampleSuffix = string.format(' | Sample: %02X', slot)
                  .. (name and (' ' .. name) or '')
    end
    local col      = vm.grid.cols[cursorCol]
    local bar, beat, sub = vm:barBeatSub(cursorRow)
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
    goTop          = { ImGui.Key_Home,       {ImGui.Key_Comma,  ImGui.Mod_Ctrl, ImGui.Mod_Shift} },
    goBottom       = { ImGui.Key_End,        {ImGui.Key_Period, ImGui.Mod_Ctrl, ImGui.Mod_Shift} },
    pageUp         = { ImGui.Key_PageUp },
    pageDown       = { ImGui.Key_PageDown },
    colLeft        = { {ImGui.Key_B, ImGui.Mod_Ctrl} },
    colRight       = { {ImGui.Key_F, ImGui.Mod_Ctrl} },
    channelLeft    = { {ImGui.Key_Tab, ImGui.Mod_Shift} },
    channelRight   = { ImGui.Key_Tab },
    noteOff        = { ImGui.Key_1 },
    shrinkNote     = { {ImGui.Key_LeftBracket,  ImGui.Mod_Shift} },
    growNote       = { {ImGui.Key_RightBracket, ImGui.Mod_Shift} },
    nudgeBack      = { ImGui.Key_LeftBracket },
    nudgeForward   = { ImGui.Key_RightBracket },
    insertRowCol   = { {ImGui.Key_DownArrow, ImGui.Mod_Ctrl} },
    deleteRowCol   = { {ImGui.Key_UpArrow,   ImGui.Mod_Ctrl} },
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
    duplicateUp    = { {ImGui.Key_D, ImGui.Mod_Ctrl, ImGui.Mod_Shift} },
    deleteSel      = { ImGui.Key_Delete },
    nudgeCoarseUp   = { {ImGui.Key_Equal, ImGui.Mod_Ctrl} },
    nudgeCoarseDown = { {ImGui.Key_Minus, ImGui.Mod_Ctrl} },
    nudgeFineUp     = { {ImGui.Key_Equal, ImGui.Mod_Shift} },
    nudgeFineDown   = { {ImGui.Key_Minus, ImGui.Mod_Shift} },
    addNoteCol     = { {ImGui.Key_N, ImGui.Mod_Ctrl} },
    addTypedCol    = { {ImGui.Key_T, ImGui.Mod_Ctrl} },
    doubleRPB      = { {ImGui.Key_Equal, ImGui.Mod_Super} },
    halveRPB       = { {ImGui.Key_Minus, ImGui.Mod_Super} },
    setRPB         = { {ImGui.Key_Z,     ImGui.Mod_Super} },
    takeProperties = { {ImGui.Key_Backspace, ImGui.Mod_Ctrl} },
    matchGridToCursor = { {ImGui.Key_M, ImGui.Mod_Super} },
    hideExtraCol   = { {ImGui.Key_H, ImGui.Mod_Ctrl} },
    inputOctaveUp   = { {ImGui.Key_8, ImGui.Mod_Shift} },
    inputOctaveDown = { ImGui.Key_Slash },
    inputSampleUp   = { {ImGui.Key_Period, ImGui.Mod_Shift} },  -- '>'
    inputSampleDown = { {ImGui.Key_Comma,  ImGui.Mod_Shift} },  -- '<'
    loadSampleAtCurrentSlot = { {ImGui.Key_L, ImGui.Mod_Super} },
    playFromTop    = { ImGui.Key_F6 },
    playFromCursor = { ImGui.Key_F7 },
    openTemperPicker = { {ImGui.Key_T, ImGui.Mod_Super} },
    openSwingPicker  = { {ImGui.Key_S, ImGui.Mod_Super} },
    openSwingEditor  = { {ImGui.Key_E, ImGui.Mod_Super} },
    reswing               = { {ImGui.Key_R, ImGui.Mod_Ctrl} },
    quantize              = { {ImGui.Key_Q, ImGui.Mod_Ctrl} },
    quantizeKeepRealised  = { {ImGui.Key_Q, ImGui.Mod_Ctrl, ImGui.Mod_Shift} },
  }
  for i = 0, 9 do
    cmgr:scope('tracker'):bind('advBy' .. i, { {ImGui.Key_0 + i, ImGui.Mod_Ctrl} })
  end

  local function nearestStop(mouseX, mouseY)
    local grid = vm.grid
    local fracX = (mouseX - gridOriginX) / gridX
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


  local function handleMouse()
    if laneConsumed then return end

    local grid = vm.grid
    local ec = vm:ec()
    local cursorRow, cursorCol, cursorStop = ec:pos()
    local scrollRow, scrollCol, lastVisCol = vm:scroll()

    local clicked      = ImGui.IsMouseClicked(ctx, 0)
    local rightClicked = ImGui.IsMouseClicked(ctx, 1)
    local held         = ImGui.IsMouseDown(ctx, 0)

    if rightClicked and ImGui.IsWindowHovered(ctx) then
      local mouseX, mouseY = ImGui.GetMousePos(ctx)
      local charY = math.floor((mouseY - gridOriginY) / gridY)
      local col, _, fracX = nearestStop(mouseX, mouseY)
      if col and charY == -HEADER and fracX >= 0 then
        local last = grid.cols[col]
        if fracX < last.x + last.width + 1 then
          vm:toggleChannelMute(last.midiChan)
        end
      end
      return
    end

    if clicked and ImGui.IsWindowHovered(ctx) then
      local mouseX, mouseY = ImGui.GetMousePos(ctx)
      local charY = math.floor((mouseY - gridOriginY) / gridY)
      local col, stop, fracX = nearestStop(mouseX, mouseY)
      if not col then return end
      if charY < -HEADER or charY >= gridHeight then return end
      if fracX < 0 then return end
      local last = grid.cols[col]
      if fracX >= last.x + last.width + 1 then return end

      if charY < 0 then
        if charY == -HEADER then ec:selectChannel(last.midiChan)
        else ec:selectColumn(col) end
        return
      end

      local shift = ImGui.GetKeyMods(ctx) & ImGui.Mod_Shift ~= 0

      if shift then
        ec:extendTo(scrollRow + charY, col, stop)
      else
        ec:selClear()
        ec:setPos(scrollRow + charY, col, stop)
        dragging = true
      end

    elseif dragging and held then
      local mouseX, mouseY = ImGui.GetMousePos(ctx)
      local charY = math.floor((mouseY - gridOriginY) / gridY)
      local row = scrollRow + charY
      local fracX = (mouseX - gridOriginX) / gridX
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

  -- Char queue + shift-digit are page-internal raw input, not bound
  -- commands. The coordinator's dispatcher has already walked the keymap
  -- by the time we run, and `kr.commandHeld` tells us whether a held
  -- command key would otherwise leak in (IsKeyPressed and the char queue
  -- don't share auto-repeat timing).
  local function handleKeys(kr)
    if modalState or pickerActive then return end
    if ImGui.IsAnyItemActive(ctx) then return end

    local grid = vm.grid
    local ec = vm:ec()
    local cursorRow, cursorCol, cursorStop = ec:pos()
    local commandHeld = kr.commandHeld

    if not commandHeld and ImGui.GetKeyMods(ctx) == ImGui.Mod_None then
        -- Drain the queue: ImGui buffers all chars typed within a frame, so
        -- reading only index 0 drops the rest under fast typing / rollover.
        -- Re-fetch grid + cursor each step: editEvent flushes and may rebuild.
        local i = 0
        while true do
          local rv, char = ImGui.GetInputQueueCharacter(ctx, i)
          if not rv then break end
          if ec:isSticky() then
            ec:selClear()
            break
          end
          local row, colIdx, stop = ec:pos()
          local c = vm.grid.cols[colIdx]
          if c then
            vm:editEvent(c, c.cells and c.cells[row], stop, char)
          end
          i = i + 1
        end
      end

    -- Shift-digit: half-step entry at MSB stops (vel, delay, cc/at/pc).
    -- Overwrites the value with digit in MSB, half-value (8 hex / 5 dec) in LSB.
    if not commandHeld and ImGui.GetKeyMods(ctx) == ImGui.Mod_Shift and not ec:isSticky() then
      local col = grid.cols[cursorCol]
      if col then
        for d = 0, 9 do
          if ImGui.IsKeyPressed(ctx, ImGui.Key_0 + d) then
            local evt = col.cells and col.cells[cursorRow]
            vm:editEvent(col, evt, cursorStop, string.byte('0') + d, true)
            break
          end
        end
      end
    end
  end

  local function drawModal()
    if not modalState then return end
    -- Self-heal: if modalState was set from inside a callback (e.g. takeProps OK
    -- → openConfirm) the OpenPopup queued there can be cancelled by the
    -- enclosing CloseCurrentPopup. Re-open here at the top level.
    if not ImGui.IsPopupOpen(ctx, modalState.title) then
      ImGui.OpenPopup(ctx, modalState.title)
    end
    local center_x, center_y = ImGui.Viewport_GetCenter(ImGui.GetWindowViewport(ctx))
    ImGui.SetNextWindowPos(ctx, center_x, center_y, ImGui.Cond_Appearing, 0.5, 0.5)

    chrome.pushChromeWindow()
    if ImGui.BeginPopupModal(ctx, modalState.title, true, ImGui.WindowFlags_AlwaysAutoResize) then
      ImGui.Text(ctx, modalState.prompt)

      local function close(invoke, ...)
        -- Capture and clear before invoking: the callback may open a follow-up
        -- modal (e.g. takeProps → confirm-on-shrink) by setting modalState
        -- itself, and we mustn't nil that out from under it.
        local cb = modalState.callback
        modalState = nil
        ImGui.CloseCurrentPopup(ctx)
        if invoke and cb then
          local ok, err = pcall(cb, ...)
          if not ok then
            reaper.ShowConsoleMsg('\nModal callback error: ' .. tostring(err) .. '\n')
          end
        end
      end

      if modalState.kind == 'confirm' then
        if ImGui.IsKeyPressed(ctx, ImGui.Key_Y) or ImGui.IsKeyPressed(ctx, ImGui.Key_Enter) then
          close(true, true)
        elseif ImGui.IsKeyPressed(ctx, ImGui.Key_N) or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
          close(true, false)
        end
      elseif modalState.kind == 'takeProps' then
        -- Mutating rowsBuf externally is invisible to an active InputText,
        -- which caches its own buffer. Bumping rowsGen changes the widget's
        -- PushID identity and forces it to re-initialise from rowsBuf;
        -- refocusRows then puts the cursor back so the user can keep typing.
        -- Both chord and button paths share this so the InputText stays
        -- in sync regardless of which one fired.
        local function scaleBy(factor)
          local n = tonumber(modalState.rowsBuf)
          if not n then return end
          modalState.rowsBuf     = tostring(math.max(1, math.floor(n * factor)))
          modalState.rowsGen     = modalState.rowsGen + 1
          modalState.refocusRows = true
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
        local rvN, name = ImGui.InputText(ctx, '##takeprops_name', modalState.nameBuf)
        if rvN then modalState.nameBuf = name end

        ImGui.Text(ctx, 'Length (rows)')
        if ImGui.IsWindowAppearing(ctx) or modalState.refocusRows then
          ImGui.SetKeyboardFocusHere(ctx)
          modalState.refocusRows = nil
        end
        ImGui.PushID(ctx, modalState.rowsGen)
        local rvR, rows = ImGui.InputText(ctx, '##takeprops_rows', modalState.rowsBuf)
        ImGui.PopID(ctx)
        if rvR then modalState.rowsBuf = rows end
        ImGui.SameLine(ctx); if ImGui.Button(ctx, '\xc3\x97' .. '2') then scaleBy(2)   end  -- ×2
        ImGui.SameLine(ctx); if ImGui.Button(ctx, '\xc3\xb7' .. '2') then scaleBy(0.5) end  -- ÷2

        for i, m in ipairs{ {'resize', 'Resize'}, {'rescale', 'Rescale'}, {'tile', 'Tile'} } do
          if i > 1 then ImGui.SameLine(ctx) end
          if ImGui.RadioButton(ctx, m[2], modalState.mode == m[1]) then modalState.mode = m[1] end
        end

        local okPressed     = ImGui.Button(ctx, 'OK')
                           or ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
                           or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)
        ImGui.SameLine(ctx)
        local cancelPressed = ImGui.Button(ctx, 'Cancel')
                           or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape)
        if     okPressed     then close(true, modalState.nameBuf, tonumber(modalState.rowsBuf), modalState.mode)
        elseif cancelPressed then close(false) end
      else
        if ImGui.IsWindowAppearing(ctx) then
          ImGui.SetKeyboardFocusHere(ctx)
        end
        local rv, buf = ImGui.InputText(ctx, '##modal', modalState.buf,
          ImGui.InputTextFlags_EnterReturnsTrue)
        if rv then
          close(true, buf)
        elseif ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
          close(false)
        else
          modalState.buf = buf
        end
      end
      ImGui.EndPopup(ctx)
    else
      modalState = nil
    end
    chrome.popChromeWindow()
  end

  ----- Modal-driven commands

  local function openPrompt(title, prompt, callback)
    modalState = { title = title, prompt = prompt, callback = callback, buf = '' }
    ImGui.OpenPopup(ctx, title)
  end

  local function openConfirm(title, callback, prompt)
    modalState = {
      title    = title,
      prompt   = prompt or ('No selection — ' .. title .. ' whole take? (y/n)'),
      kind     = 'confirm',
      callback = callback,
      buf      = '',
    }
    ImGui.OpenPopup(ctx, title)
  end

  -- Selection → vm:<base>Selection();  no selection → confirm → vm:<base>All().
  -- The naming convention is the contract — keeps the registration tight.
  local function scopedAction(title, base)
    return function()
      if vm:ec():hasSelection() then vm[base..'Selection'](vm)
      else openConfirm(title, function(yes) if yes then vm[base..'All'](vm) end end)
      end
    end
  end

  local tracker = cmgr:scope('tracker')

  tracker:registerAll{
    setRPB = function()
      openPrompt('Rows per beat', '1-32', function(buf)
        local n = tonumber(buf); if n then vm:setRowPerBeat(n) end
      end)
    end,

    takeProperties = function()
      local origRows = vm.grid.numRows or 0
      local title    = 'Take properties'
      modalState = {
        kind     = 'takeProps',
        title    = title,
        nameBuf  = vm:takeName() or '',
        rowsBuf  = tostring(origRows),
        rowsGen  = 0,
        mode     = 'resize',
        callback = function(name, rows, mode)
          if not rows or rows < 1 then return end
          rows = math.floor(rows)
          local apply = function() vm:applyTakeProperties{ name = name, rows = rows, mode = mode } end
          -- rescale is the monotone stretch — never deletes events.
          -- resize and tile both fall back to truncation when shrinking.
          if rows < origRows and mode ~= 'rescale' then
            openConfirm('Truncate take', function(yes) if yes then apply() end end,
              ('Truncate to %d rows? Events past row %d will be deleted. (y/n)')
              :format(rows, rows))
          else
            apply()
          end
        end,
      }
      ImGui.OpenPopup(ctx, title)
    end,

    addTypedCol = function()
      openPrompt('Add Column', 'cc0-127, pb, at, pc, dly', function(typeStr)
        local type, idStr = typeStr:lower():match('^(%a+)(%d*)$')
        if not type then return end
        local id = idStr ~= '' and tonumber(idStr) or nil
        if type == 'dly' then vm:showDelay()
        elseif util.oneOf('cc pb at pc', type) then
          if type == 'cc' and (not id or id < 0 or id > 127) then return end
          vm:addExtraCol(type, id)
        end
      end)
    end,

    reswing              = scopedAction('reswing',                'reswing'),
    quantize             = scopedAction('quantize',               'quantize'),
    quantizeKeepRealised = scopedAction('quantize keep realised', 'quantizeKeepRealised'),

    openSwingEditor = function() swingEditor:open() end,

    openTemperPicker = function() pickerOpenRequest = 'temper' end,
    openSwingPicker  = function() pickerOpenRequest = 'swing'  end,
  }

  tracker:doAfter({ 'reswing', 'quantize', 'quantizeKeepRealised' },
                  function() vm:ec():unstick() end)

  ---------- PUBLIC

  local tp = {}

  function tp:renderToolbarBits(_)
    pickerActive = false
    drawTrackerToolbarBits()
  end

  function tp:renderBody(_, w, h, dispatch)
    if #vm.grid.cols == 0 then
      ImGui.Text(ctx, 'Select a MIDI item to begin.')
      return
    end
    ImGui.PushFont(ctx, font, 15)
    computeLayout(w, h)
    drawLaneStrip()
    -- Lane-strip drag callbacks flush the tracker, replacing vm.grid.cols
    -- with fresh tables that carry no col.x. Re-layout so drawTracker
    -- sees a populated layout on the live cols.
    computeLayout(w, h)
    drawTracker()
    ImGui.PopFont(ctx)

    handleMouse()
    local kr = dispatch and dispatch(self:focusState()) or { commandHeld = false }
    handleKeys(kr)
    drawModal()

    vm:tick()
  end

  function tp:renderStatusBar(_)
    drawStatusBar()
  end

  function tp:renderFloating(_)
    swingEditor:render()
  end

  function tp:bind(take)
    cm:setContext(take)
  end

  function tp:unbind()
    cm:setContext(nil)
  end

  -- suppressKbd: a popup or modal owns input — dispatcher does nothing.
  -- acceptCmds:  the page is visible and nothing inside it is currently
  --   consuming a keystroke. We deliberately don't gate on which child
  --   window holds focus: a toolbar click leaves the chrome focused
  --   transiently, but bound commands should still fire. Anything that
  --   genuinely needs the keys (a focused InputText, an active slider,
  --   a held button) shows up as IsAnyItemActive.
  function tp:focusState()
    if not ctx then return { suppressKbd = false, acceptCmds = false } end
    local suppress = modalState ~= nil or pickerActive
    return {
      suppressKbd = suppress,
      acceptCmds  = (not suppress) and not ImGui.IsAnyItemActive(ctx),
    }
  end

  function tp:handleInput() end
  function tp:save()      end
  function tp:load()      end

  return tp
end
