-- See docs/chrome.md for the model.

--shape: chrome = { colour(name)->u32, pushChromeStyles(), popChromeStyles(), pushChromeWindow(), popChromeWindow(), verticalSeparator(), disabledIf(cond,fn), checkbox(label,v), radio(label,active), headingLabel(text), makeToolbar()->fn(segments), drawPicker(d), libPicker(key, current, excludeOthers?)->items, pickerIsActive()->bool, resetPickerActive(), requestPickerOpen(kind) }
--shape: chrome (shared row primitives) = { fitLabel(text,maxW)->text, rowSelectable(label,sel,flags?)->clicked, treeArrow(open,hasChildren)->prefix }
--shape: pickerSpec = { kind: string, heading: string?, buttonLabel: string, items: [{label, key, group?=int, current?=bool}], onPick: fn(key), width?, minWidth?, maxWidth? }
--shape: palettePaneSpec = { x, y, h, label, draw = fn(childFocused) }
--contract: one chrome instance per coordinator; threaded into every page
--invariant: colour cache lives on the chrome instance and is invalidated on cm:configChanged
local ImGui   = require 'imgui' '0.10'
local painter = require 'painter'

local cm, ctx       = (...).cm, (...).ctx
local uiFontBold    = (...).uiFontBold
local uiSize        = (...).uiSize

local cache = {}
cm:subscribe('configChanged', function() cache = {} end)

--contract: walks colour aliases (see docs/configManager.md) to a terminal atom; outermost alpha override wins; cycles raise with the resolved chain
local function resolve(key)
  local seen, override = {}, nil
  while true do
    if seen[key] then
      seen[#seen+1] = key
      error('colour cycle: ' .. table.concat(seen, ' → '))
    end
    seen[#seen+1] = key; seen[key] = true
    local v = cm:get(key)
    if v == nil then error('unknown colour: ' .. key) end
    if type(v) == 'string' then
      key = v
    elseif type(v[1]) == 'string' then
      key      = v[1]
      override = override or v[2]
    else
      return v[1], v[2], v[3], override or v[4]
    end
  end
end

local function colour(name)
  name = name or 'text'
  if not cache[name] then
    local r, g, b, a = resolve('colour.' .. name)
    cache[name] = ImGui.ColorConvertDouble4ToU32(r, g, b, a)
  end
  return cache[name]
end

-- painter binds colour names through chrome; it touches only colour().
local paintBinder = { colour = colour }

local function pushChromeStyles()
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameBorderSize, 1)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text,           colour('toolbar.text'))
  ImGui.PushStyleColor(ctx, ImGui.Col_Button,         colour('toolbar.button'))
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered,  colour('toolbar.buttonHover'))
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,   colour('toolbar.buttonActive'))
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg,        colour('toolbar.button'))
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, colour('toolbar.buttonHover'))
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive,  colour('toolbar.buttonActive'))
  ImGui.PushStyleColor(ctx, ImGui.Col_CheckMark,      colour('toolbar.checkMark'))
  ImGui.PushStyleColor(ctx, ImGui.Col_SliderGrab,       colour('toolbar.sliderGrab'))
  ImGui.PushStyleColor(ctx, ImGui.Col_SliderGrabActive, colour('toolbar.sliderGrabActive'))
  ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg,        colour('toolbar.popupBg'))
  ImGui.PushStyleColor(ctx, ImGui.Col_Border,         colour('toolbar.buttonBorder'))
  -- Col_InputTextCursor has its own slot; default is invisible against
  -- chrome-styled frame backgrounds, so InputText shows focused but caretless.
  ImGui.PushStyleColor(ctx, ImGui.Col_InputTextCursor, colour('toolbar.text'))
end

local function popChromeStyles()
  ImGui.PopStyleColor(ctx, 13)
  ImGui.PopStyleVar(ctx, 1)
end

-- Floating surfaces fill with editor.bg (opaque); toolbar.bg is 0.5 alpha and would bleed the grid through.
local function pushChromeWindow()
  pushChromeStyles()
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowBorderSize, 1)
  ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg,         colour('editor.bg'))
  ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg,          colour('editor.bg'))
  ImGui.PushStyleColor(ctx, ImGui.Col_TitleBg,          colour('editor.bg'))
  ImGui.PushStyleColor(ctx, ImGui.Col_TitleBgActive,    colour('editor.bg'))
  ImGui.PushStyleColor(ctx, ImGui.Col_TitleBgCollapsed, colour('editor.bg'))
  ImGui.PushStyleColor(ctx, ImGui.Col_Separator,        colour('toolbar.buttonBorder'))
end

local function popChromeWindow()
  ImGui.PopStyleColor(ctx, 6)
  ImGui.PopStyleVar(ctx, 1)
  popChromeStyles()
end

-- reaper-imgui has no Separator(Vertical); draw a 1px vertical line
-- via the window draw list and reserve a Dummy slot so SameLine works.
local function verticalSeparator()
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local h    = ImGui.GetFrameHeight(ctx)
  ImGui.DrawList_AddLine(ImGui.GetWindowDrawList(ctx),
    x, y, x, y + h, colour('separator'), 1)
  ImGui.Dummy(ctx, 1, h)
end

-- RAII wrapper for ImGui.BeginDisabled / EndDisabled: dropping the
-- bracket-match removes a class of mismatched-pop bugs on early return.
local function disabledIf(cond, fn)
  if cond then ImGui.BeginDisabled(ctx) end
  fn()
  if cond then ImGui.EndDisabled(ctx) end
end

-- Compact checkbox / radio for toolbar contexts: zero FramePadding
-- shrinks the box to its glyph; the +3 cursorY nudge re-aligns the
-- small box with framed siblings on the same row.
local function checkbox(label, value)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 0, 0)
  ImGui.SetCursorPosY(ctx, ImGui.GetCursorPosY(ctx) + 3)
  local changed, v = ImGui.Checkbox(ctx, label, value)
  ImGui.PopStyleVar(ctx, 1)
  return changed, v
end

local function radio(label, active)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 0, 0)
  ImGui.SetCursorPosY(ctx, ImGui.GetCursorPosY(ctx) + 3)
  local pressed = ImGui.RadioButton(ctx, label, active)
  ImGui.PopStyleVar(ctx, 1)
  return pressed
end

-- Section label for toolbar segments: bold + uppercase + dimmed so it
-- reads as a heading and not a control. Caller follows with SameLine.
local function headingLabel(text)
  local r, g, b, a = ImGui.ColorConvertU32ToDouble4(colour('toolbar.text'))
  local dim = ImGui.ColorConvertDouble4ToU32(r, g, b, a * 0.55)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, dim)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, text)
  ImGui.PopStyleColor(ctx, 1)
end

--shape: toolbarSegment = { id: string, render: fn, visible?: fn() -> bool }
-- Wraps each segment in BeginGroup/EndGroup so GetItemRectMin/Max measures the whole
-- segment. Caches last-frame width per id; if (lastEnd + sep + cached) overflows the
-- row, the leading SameLine is skipped and ImGui wraps. One-frame slop on size change.
-- Per-segment screen rects, refreshed each frame the toolbar draws; read by
-- the help overlay via chrome.toolbarRects(). One page draws per frame, so a
-- single shared table is correct.
local lastToolbarRects = {}
local function makeToolbar()
  local widths = {}
  return function(segments)
    for k in pairs(lastToolbarRects) do lastToolbarRects[k] = nil end
    local startX = ImGui.GetCursorScreenPos(ctx)
    local availW = ImGui.GetContentRegionAvail(ctx)
    local rightX = startX + availW
    local lastEndX, first = startX, true
    for _, seg in ipairs(segments) do
      if not seg.visible or seg.visible() then
        local cachedW = widths[seg.id] or 0
        if not first then
          local sepW = 12 + 1 + 12
          if lastEndX + sepW + cachedW <= rightX then
            ImGui.SameLine(ctx, 0, 12)
            verticalSeparator()
            ImGui.SameLine(ctx, 0, 12)
          end
        end
        ImGui.BeginGroup(ctx)
        seg.render()
        ImGui.EndGroup(ctx)
        local minX, minY = ImGui.GetItemRectMin(ctx)
        local maxX, maxY = ImGui.GetItemRectMax(ctx)
        widths[seg.id] = maxX - minX
        lastToolbarRects[seg.id] = { x = minX, y = minY, w = maxX - minX, h = maxY - minY }
        lastEndX, first = maxX, false
      end
    end
  end
end

----- Picker (typeahead popup, shared across pages)

-- Per-kind state; popups close on focus loss so a missing entry just
-- means "default empty filter / cursor at top".
local pickerFilter, pickerCursor = {}, {}
local pickerOpenReq = nil   -- kind name; consumed by next drawPicker(kind)
local pickerActive  = false -- frame-scoped: any picker popup live this frame

local function requestPickerOpen(kind) pickerOpenReq = kind end
local function pickerIsActive()        return pickerActive end
local function resetPickerActive()     pickerActive = false end

-- Build the picker-item list for a library-shaped cm key (e.g. 'swings',
-- 'tempers'). Three groups, in order:
--   1. Off    — nil key.
--   2. Project entries (cm.project[key]) — plain label.
--   3. Other entries (anything in the merged view but not in project) —
--      `+` prefix, marking "available but not yet localized to project".
-- excludeOthers is a set of names to filter out of group 3 only — used
-- to hide `id` from the swing picker (already covered by Off).
local function libPicker(key, current, excludeOthers)
  excludeOthers = excludeOthers or {}
  cm:seedGlobalFromDefault(key, excludeOthers)
  local proj   = cm:getAt('project', key) or {}
  local merged = cm:get(key, { mergeTiers = true }) or {}

  local items = { { label = 'Off', key = nil, group = 1, current = current == nil } }

  local projNames = {}
  for k in pairs(proj) do projNames[#projNames+1] = k end
  table.sort(projNames)
  for _, name in ipairs(projNames) do
    items[#items+1] = { label = name, key = name, group = 2, current = current == name }
  end

  local otherNames = {}
  for k in pairs(merged) do
    if not proj[k] and not excludeOthers[k] then
      otherNames[#otherNames+1] = k
    end
  end
  table.sort(otherNames)
  for _, name in ipairs(otherNames) do
    items[#items+1] = { label = '+ ' .. name, key = name, group = 3, current = false }
  end
  return items
end

-- Generic typeahead picker. Enter picks the highlighted match; group
-- separators show only when filter is empty.
local function drawPicker(d)
  local popupId = '##picker_' .. d.kind

  -- Heading inherits the toolbar's outer Col_Text push; no inner push.
  -- Optional: callers that want a section-label register render the
  -- heading themselves via headingLabel and pass heading=nil.
  if d.heading then
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, d.heading .. ':')
    ImGui.SameLine(ctx)
  end

  -- ##d.kind disambiguates the ImGui ID — different pickers may all
  -- show the same buttonLabel once the heading is no longer in the ID.
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
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ButtonTextAlign, 0, 0.5)
  local opening
  if btnW then opening = ImGui.Button(ctx, btnTxt, btnW, 0)
  else         opening = ImGui.Button(ctx, btnTxt) end
  ImGui.PopStyleVar(ctx, 1)
  -- Anchor popup to the button rect; OpenPopup otherwise uses mouse
  -- position, putting a keyboard-triggered popup at the text cursor.
  local btnX = ImGui.GetItemRectMin(ctx)
  local _, btnY = ImGui.GetItemRectMax(ctx)
  if pickerOpenReq == d.kind then
    pickerOpenReq = nil
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
  pickerActive = true   -- block page key dispatch this frame so Enter doesn't leak

  if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
  ImGui.SetNextItemWidth(ctx, 180)
  local prevFilter = pickerFilter[d.kind] or ''
  -- Plain InputText (no EnterReturnsTrue): with that flag, ReaImGui
  -- only commits the buffer on Enter, so the live filter would never
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

  -- On open or filter-change, highlight the current pick if it survived; else top.
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

----- Palette pane (shared right-hand pane: arrange / wiring / tracker / sampler)

-- Pane geometry. HEADER_PAD/HEADER_GAP also size a flanking grid header (see
-- arrangeRender) so the grid and palette dividers line up across PANE_GAP.
local PALETTE_W, PANE_GAP    = 200, 11
local HEADER_PAD, HEADER_GAP = 8, 4

--contract: width of the main pane left of the palette; floors at 120.
local function gridWidth(w) return math.max(120, w - PALETTE_W - PANE_GAP) end

-- Hand-drawn header: centred label + 1px divider at headerH; shares HEADER_PAD/HEADER_GAP
-- with the flanking grid header so the two dividers align across PANE_GAP without measuring.
local function paletteHeader(label)
  local p       = painter.new(ctx, paintBinder, {})
  local ox, oy  = ImGui.GetCursorScreenPos(ctx)
  -- Centre against the FULL pane width: GetContentRegionAvail shrinks by the
  -- scrollbar when the list overflows, which would drift the heading left.
  local avail   = select(1, ImGui.GetContentRegionAvail(ctx))
  local sbw     = ImGui.GetScrollMaxY(ctx) > 0
                  and select(1, ImGui.GetStyleVar(ctx, ImGui.StyleVar_ScrollbarSize)) or 0
  local paneW   = avail + sbw
  local rowH    = math.max(1, ImGui.GetTextLineHeightWithSpacing(ctx))
  local headerH = rowH + HEADER_PAD
  local tw      = p.measure(label)
  p.text(ox + math.floor((paneW - tw) / 2), oy + HEADER_PAD, 'text', label)
  p.segment(ox, oy + headerH, ox + paneW, oy + headerH, 'text', 1)
  ImGui.Dummy(ctx, avail, headerH + HEADER_GAP)
end

--contract: x/y/h are body-window screen coords at the gap's left edge; draw paints the body.
local function palettePane(spec)
  -- vrule on the BODY draw list — it sits in the gap, outside the child.
  local p     = painter.new(ctx, paintBinder, {})
  local lineX = spec.x + math.floor(PANE_GAP / 2)
  p.segment(lineX, spec.y, lineX, spec.y + spec.h, 'text', 1)

  ImGui.SetCursorScreenPos(ctx, spec.x + PANE_GAP, spec.y)
  if ImGui.BeginChild(ctx, '##palettePane', PALETTE_W, spec.h,
                      ImGui.ChildFlags_None, ImGui.WindowFlags_NoNav) then
    local childFocused = ImGui.IsWindowFocused(ctx)
    pushChromeStyles()
    paletteHeader(spec.label)
    spec.draw(childFocused)
    popChromeStyles()
  end
  ImGui.EndChild(ctx)
end

-- Ellipsis-fit to a fixed pane width; no horizontal scroll exists.
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

-- Selectable with hover/active highlight suppressed: only the selected row shows
-- the Col_Header fill. Shared by the tracker palette and the sampler browser/tree.
local function rowSelectable(label, selected, flags)
  local hi = selected and ImGui.GetStyleColor(ctx, ImGui.Col_Header) or 0x00000000
  ImGui.PushStyleColor(ctx, ImGui.Col_HeaderHovered, hi)
  ImGui.PushStyleColor(ctx, ImGui.Col_HeaderActive,  hi)
  local clicked = ImGui.Selectable(ctx, label, selected, flags or 0)
  ImGui.PopStyleColor(ctx, 2)
  return clicked
end

-- ▾ open / ▸ shut tree arrows; a childless node leads with blank cells so its
-- label still aligns under expandable siblings.
local TREE_OPEN, TREE_SHUT = '\xe2\x96\xbe ', '\xe2\x96\xb8 '
local function treeArrow(open, hasChildren)
  if not hasChildren then return '  ' end
  return open and TREE_OPEN or TREE_SHUT
end

return {
  colour             = colour,
  pushChromeStyles   = pushChromeStyles,
  popChromeStyles    = popChromeStyles,
  pushChromeWindow   = pushChromeWindow,
  popChromeWindow    = popChromeWindow,
  verticalSeparator  = verticalSeparator,
  disabledIf         = disabledIf,
  checkbox           = checkbox,
  radio              = radio,
  headingLabel       = headingLabel,
  makeToolbar        = makeToolbar,
  toolbarRects       = function() return lastToolbarRects end,
  drawPicker         = drawPicker,
  libPicker          = libPicker,
  pickerIsActive     = pickerIsActive,
  resetPickerActive  = resetPickerActive,
  requestPickerOpen  = requestPickerOpen,
  gridWidth          = gridWidth,
  paletteHeader      = paletteHeader,
  palettePane        = palettePane,
  fitLabel           = fitLabel,
  rowSelectable      = rowSelectable,
  treeArrow          = treeArrow,
}

