-- See docs/chrome.md for the model.

--shape: chrome = { colour(name, scope?)->u32, pushChromeStyles(), popChromeStyles(), pushChromeWindow(), popChromeWindow(), verticalSeparator(), disabledIf(cond,fn), row(h?,fn), checkbox(label,v), radio(label,active), headingLabel(text), screenPainter()->painter}
--shape: chrome (pickers) = { makeToolbar()->fn(segments), drawPicker(d), libPicker(key, current, excludeOthers?)->items, pickerIsActive()->bool, resetPickerActive(), requestPickerOpen(kind) }
--shape: chrome (shared row primitives) = { rowSelectable(label,sel,flags?)->clicked, treeRow(opts)->{toggled,selected,doubleClicked}, numberStepper(id,value,opts)->changed,value }
--shape: pickerSpec = { kind: string, heading: string?, buttonLabel: string, items: [{label, key, group?=int, current?=bool}], onPick: fn(key), onCancel?: fn(), onCreate?: fn(text), onDelete?: fn(key), placement?: 'above', width?, minWidth?, maxWidth?, flat?: bool }
--shape: palettePaneSpec = { x, y, h, label | {tabs=[{key,label}], activeTab, onTab}, draw = fn(childFocused) }
--contract: one chrome instance per coordinator; threaded into every page
--invariant: colour cache lives on the chrome instance and is invalidated on cm:configChanged
local ImGui   = require 'imgui' '0.10'
local painter = require 'painter'

local cm, ctx, lib  = (...).cm, (...).ctx, (...).lib

local chrome = {}

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

-- Namespaces a colour name to a full cm key, then caches by that key.
-- Bare names bind to the caller's page if that role exists, else global.
local NS = { global = true, tracker = true, sampler = true,
             wiring = true, arrange = true, chrome = true }
local function scopedKey(name, scope)
  if NS[name:match('^(%a+)%.') or ''] then return 'colour.' .. name end
  local own = 'colour.' .. scope .. '.' .. name
  if cm:isDeclared(own) then return own end
  return 'colour.global.' .. name
end

function chrome.colour(name, scope)
  local key = scopedKey(name or 'text', scope or 'chrome')
  if not cache[key] then
    local r, g, b, a = resolve(key)
    cache[key] = ImGui.ColorConvertDouble4ToU32(r, g, b, a)
  end
  return cache[key]
end

-- painter binds colour names through chrome; it touches only colour().
local paintBinder = { colour = chrome.colour }

-- Identity-transform painter over the current window's draw list: screen coords, chrome's
-- palette. Build one per draw fn — the draw list is captured now, so call it in the target window.
function chrome.screenPainter() return painter.new(ctx, paintBinder, {}) end

function chrome.pushChromeStyles()
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameBorderSize, 0)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameRounding, 1)
  -- With the border gone the fill bleeds into the 1px ring it used to occupy;
  -- trim a px per axis so framed widgets keep their old footprint.
  local fpx, fpy = ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, fpx - 1, fpy - 1)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text,           chrome.colour('toolbar.text'))
  ImGui.PushStyleColor(ctx, ImGui.Col_Button,         chrome.colour('toolbar.button'))
  -- Hover holds the resting fill for buttons and frame bgs; active toggle buttons
  -- re-flatten at each site, while a button press still darkens via ButtonActive.
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered,  chrome.colour('toolbar.button'))
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,   chrome.colour('toolbar.buttonActive'))
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg,        chrome.colour('toolbar.button'))
  -- Frame bg flat on hover AND press — slider tracks/inputs never highlight;
  -- a slider's only feedback is the grab (Col_SliderGrab / SliderGrabActive).
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, chrome.colour('toolbar.button'))
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive,  chrome.colour('toolbar.button'))
  ImGui.PushStyleColor(ctx, ImGui.Col_CheckMark,      chrome.colour('toolbar.checkMark'))
  ImGui.PushStyleColor(ctx, ImGui.Col_SliderGrab,       chrome.colour('toolbar.sliderGrab'))
  ImGui.PushStyleColor(ctx, ImGui.Col_SliderGrabActive, chrome.colour('toolbar.sliderGrabActive'))
  ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg,        chrome.colour('toolbar.popupBg'))
  ImGui.PushStyleColor(ctx, ImGui.Col_Border,         chrome.colour('toolbar.buttonBorder'))
  -- Col_InputTextCursor has its own slot; default is invisible against
  -- chrome-styled frame backgrounds, so InputText shows focused but caretless.
  ImGui.PushStyleColor(ctx, ImGui.Col_InputTextCursor, chrome.colour('toolbar.text'))
  -- ImGui's stock Col_TextSelectedBg is a bright blue that clashes with the
  -- parchment chrome; ride the cool-blue alt ramp instead.
  ImGui.PushStyleColor(ctx, ImGui.Col_TextSelectedBg, chrome.colour('toolbar.textSelection'))
  -- Selectable / list-row highlight (Col_Header family) also defaults to stock
  -- blue; ride the same alt ramp so every chrome selection reads as one blue.
  ImGui.PushStyleColor(ctx, ImGui.Col_Header,        chrome.colour('toolbar.selectedRow'))
  ImGui.PushStyleColor(ctx, ImGui.Col_HeaderHovered, chrome.colour('toolbar.selectedRow'))
  ImGui.PushStyleColor(ctx, ImGui.Col_HeaderActive,  chrome.colour('toolbar.selectedRow'))
end

function chrome.popChromeStyles()
  ImGui.PopStyleColor(ctx, 17)
  ImGui.PopStyleVar(ctx, 3)
end

-- Floating surfaces fill with editor.bg (opaque); toolbar.bg is 0.5 alpha and would bleed the grid through.
function chrome.pushChromeWindow()
  chrome.pushChromeStyles()
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowBorderSize, 1)
  ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg,         chrome.colour('editor.bg'))
  ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg,          chrome.colour('editor.bg'))
  ImGui.PushStyleColor(ctx, ImGui.Col_TitleBg,          chrome.colour('editor.bg'))
  ImGui.PushStyleColor(ctx, ImGui.Col_TitleBgActive,    chrome.colour('editor.bg'))
  ImGui.PushStyleColor(ctx, ImGui.Col_TitleBgCollapsed, chrome.colour('editor.bg'))
  ImGui.PushStyleColor(ctx, ImGui.Col_Separator,        chrome.colour('toolbar.buttonBorder'))
end

function chrome.popChromeWindow()
  ImGui.PopStyleColor(ctx, 6)
  ImGui.PopStyleVar(ctx, 1)
  chrome.popChromeStyles()
end

-- reaper-imgui has no Separator(Vertical); draw a 1px vertical rule via the window draw
-- list and reserve a Dummy slot so SameLine works. see docs/chrome.md § Vertical separator
function chrome.verticalSeparator()
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local h    = ImGui.GetFrameHeight(ctx)
  ImGui.DrawList_AddRectFilled(ImGui.GetWindowDrawList(ctx),
    x, y, x + 1, y + h, chrome.colour('separator'))
  ImGui.Dummy(ctx, 1, h)
end

-- RAII wrapper for ImGui.BeginDisabled / EndDisabled: dropping the
-- bracket-match removes a class of mismatched-pop bugs on early return.
function chrome.disabledIf(cond, fn)
  if cond then ImGui.BeginDisabled(ctx) end
  fn()
  if cond then ImGui.EndDisabled(ctx) end
end

-- Fixed-height row: run `fn`, then snap the cursor to exactly `h` below the row's
-- top so subsequent rows land at a deterministic Y regardless of widget heights.
function chrome.row(h, fn)
  if type(h) == 'function' then h, fn = nil, h end
  local gapY   = select(2, ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing))
  h = h or (ImGui.GetFrameHeight(ctx) + gapY)
  local x, top = ImGui.GetCursorPosX(ctx), ImGui.GetCursorPosY(ctx)
  fn()
  ImGui.SetCursorPos(ctx, x, top + h)
end

-- Compact (zero-padding) control — checkbox / radio — vertically centered in the
-- ambient framed-row height; measured from GetFrameHeight, not a fixed nudge.
local function compactControl(draw)
  local frameH = ImGui.GetFrameHeight(ctx)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 0, 0)
  ImGui.SetCursorPosY(ctx, ImGui.GetCursorPosY(ctx) + (frameH - ImGui.GetFrameHeight(ctx)) / 2)
  local a, b = draw()
  ImGui.PopStyleVar(ctx, 1)
  return a, b
end

function chrome.checkbox(label, value)
  return compactControl(function() return ImGui.Checkbox(ctx, label, value) end)
end

function chrome.radio(label, active)
  return compactControl(function() return ImGui.RadioButton(ctx, label, active) end)
end

-- InputInt/-Double flanked by hold-repeat -/+ buttons; -/+ drawn as rects not glyphs. See docs/chrome.md § numberStepper.
--   opts = { min?, max?, step?=1, onStep?=fn(value,dir)->value, width?, digits?=2, format?, align? }
local BOX_PAD = 3
function chrome.numberStepper(id, value, opts)
  opts = opts or {}
  local digits = opts.digits or 2
  local fmt    = opts.format
  local btnSz  = ImGui.GetFrameHeight(ctx)
  local innerX = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemInnerSpacing)
  local _, fpy = ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)

  local function clamp(v)
    if opts.min and v < opts.min then return opts.min end
    if opts.max and v > opts.max then return opts.max end
    return v
  end

  local boxW  = opts.width or (ImGui.CalcTextSize(ctx, string.rep('0', digits)) + 8)
  local inset = BOX_PAD
  if opts.align == 'center' then
    local shown = fmt and string.format(fmt, value) or tostring(value)
    inset = math.max(BOX_PAD, math.floor((boxW - ImGui.CalcTextSize(ctx, shown)) / 2))
  end
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, inset, fpy)
  ImGui.SetNextItemWidth(ctx, boxW)
  local changed, n
  if fmt then changed, n = ImGui.InputDouble(ctx, '##' .. id, value, 0, 0, fmt)
  else        changed, n = ImGui.InputInt(ctx, '##' .. id, value, 0, 0) end
  ImGui.PopStyleVar(ctx, 1)
  if changed then n = clamp(n) end

  ImGui.PushItemFlag(ctx, ImGui.ItemFlags_ButtonRepeat, true)
  local arm = math.max(2, math.floor(btnSz * 0.18))   -- -/+ arm reach; bar = 2*arm+1 px (odd), 1px thick
  local function stepBtn(dir, isPlus)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, btnSz / 2, fpy)
    ImGui.SameLine(ctx, 0, innerX)
    local pressed = ImGui.Button(ctx, '##' .. id .. dir, btnSz, btnSz)
    ImGui.PopStyleVar(ctx, 1)
    local x0, y0 = ImGui.GetItemRectMin(ctx)
    local x1, y1 = ImGui.GetItemRectMax(ctx)
    local cx, cy = math.floor((x0 + x1) / 2), math.floor((y0 + y1) / 2)
    local col, dl = ImGui.GetColor(ctx, ImGui.Col_Text), ImGui.GetWindowDrawList(ctx)
    ImGui.DrawList_AddRectFilled(dl, cx - arm, cy, cx + arm + 1, cy + 1, col)
    if isPlus then ImGui.DrawList_AddRectFilled(dl, cx, cy - arm, cx + 1, cy + arm + 1, col) end
    if pressed then
      n = opts.onStep and opts.onStep(value, dir) or clamp(value + dir * (opts.step or 1))
      changed = true
    end
  end
  stepBtn(-1, false)
  stepBtn(1, true)
  ImGui.PopItemFlag(ctx)
  return changed, n
end

-- House-style dropdown: button + popup of `items`. Width fits the widest entry
-- so columns stay aligned across rows. Returns the picked 1-based index, else nil.
local DROP_ARROW = ' \xe2\x96\xbe'   -- ' ▾'
function chrome.dropdown(id, current, items)
  local widest = 0
  for _, it in ipairs(items) do
    local tw = ImGui.CalcTextSize(ctx, it .. DROP_ARROW)
    if tw > widest then widest = tw end
  end
  local padX = ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
  local btnW = widest + padX * 2
  if ImGui.Button(ctx, current .. DROP_ARROW .. '##' .. id, btnW) then
    ImGui.OpenPopup(ctx, id .. '_popup')
  end
  local x = ImGui.GetItemRectMin(ctx)
  local _, y = ImGui.GetItemRectMax(ctx)
  ImGui.SetNextWindowPos(ctx, x, y, ImGui.Cond_Appearing)
  ImGui.SetNextWindowSize(ctx, btnW, 0)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_PopupBorderSize, 0)   -- flat menu, no outline
  local picked
  if ImGui.BeginPopup(ctx, id .. '_popup', ImGui.WindowFlags_NoNav) then
    for idx, it in ipairs(items) do
      if ImGui.Selectable(ctx, it, it == current) then picked = idx end
    end
    ImGui.EndPopup(ctx)
  end
  ImGui.PopStyleVar(ctx, 1)
  return picked
end

-- Section label for toolbar segments: bold + uppercase + dimmed so it
-- reads as a heading and not a control. Caller follows with SameLine.
function chrome.headingLabel(text)
  local r, g, b, a = ImGui.ColorConvertU32ToDouble4(chrome.colour('toolbar.text'))
  local dim = ImGui.ColorConvertDouble4ToU32(r, g, b, a * 0.55)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, dim)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, text)
  ImGui.PopStyleColor(ctx, 1)
end

-- Picker-open request state, hoisted above the toolbar: layout peeks it to
-- re-expand a collapsed segment hosting the requested kind. Consumed in § Picker.
local pickerOpenReq  = nil   -- kind name; consumed by next drawPicker(kind)
local pickerOpenSeed = nil   -- initial filter text for a request-driven open (type-to-open)

--shape: toolbarSegment = { id: string, heading?: string (presence = collapsible), render: fn, visible?: fn() -> bool, pickers?: [kind] }
-- see docs/chrome.md § Toolbar layout
local lastToolbarRects = {}
--invariant: one page draws per frame; cleared at next toolbar() start — no cross-page collision.
local toolbarWidths = {}
local toolbarLines  = 1   -- wrapped-row count from the last toolbar() draw
local resetPending  = false
-- Deferred: the switcher lives in the toolbar, so setActive fires mid-render — clearing
-- now would unwrap this frame's later segments. Clear at the next toolbar() start instead.
function chrome.resetToolbar() resetPending = true end

function chrome.toolbarRects()     return lastToolbarRects end
function chrome.toolbarLineCount() return toolbarLines end

-- A segment with a summary is collapsible; folded ids persist in config.
local function setCollapsed(id, on)
  local set = cm:get('toolbar.collapsed') or {}
  set[id] = on or nil
  cm:set('global', 'toolbar.collapsed', set)
end

-- headingLabel that toggles: a leading triangle discloses the folded state.
-- ▸/▾ advance differently, so the triangle gets a fixed cell — no 1px heading shift.
local function disclosureHeading(text, collapsed)
  local collapsedW = ImGui.CalcTextSize(ctx, '\xe2\x96\xb8')
  local expandedW  = ImGui.CalcTextSize(ctx, '\xe2\x96\xbe')
  local cellW      = math.max(collapsedW, expandedW)
  local startX     = ImGui.GetCursorPosX(ctx)
  ImGui.BeginGroup(ctx)
  chrome.headingLabel(collapsed and '\xe2\x96\xb8' or '\xe2\x96\xbe')
  ImGui.SameLine(ctx)
  ImGui.SetCursorPosX(ctx, startX + cellW + 4)
  chrome.headingLabel(text)
  ImGui.EndGroup(ctx)
  if ImGui.IsItemHovered(ctx) then ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_Hand) end
  return ImGui.IsItemClicked(ctx)
end

local function drawSegment(seg, collapsed)
  ImGui.BeginGroup(ctx)
  if seg.heading then
    if disclosureHeading(seg.heading, collapsed) then setCollapsed(seg.id, not collapsed) end
    if not collapsed then
      ImGui.SameLine(ctx, 0, 8)
      seg.render()
    end
  else
    seg.render()
  end
  ImGui.EndGroup(ctx)
end

function chrome.makeToolbar()
  -- Hidden Alpha-0 pass to pre-populate widths when the cache is cold (post-reset).
  -- Without it the cold row lays out flat and AutoResizeY jumps the body one frame later.
  local function measureWidths(segments, collapsed)
    local x, y = ImGui.GetCursorScreenPos(ctx)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_Alpha, 0)
    local first = true
    for _, seg in ipairs(segments) do
      if not seg.visible or seg.visible() then
        if not first then ImGui.SameLine(ctx) end
        drawSegment(seg, collapsed[seg.id])
        local minX = ImGui.GetItemRectMin(ctx)
        local maxX = ImGui.GetItemRectMax(ctx)
        toolbarWidths[seg.id] = maxX - minX
        first = false
      end
    end
    ImGui.PopStyleVar(ctx, 1)
    ImGui.SetCursorScreenPos(ctx, x, y)
  end
  -- Cold = a visible segment we have no width for yet (fresh page, or post-reset).
  local function anyUncached(segments)
    for _, seg in ipairs(segments) do
      if (not seg.visible or seg.visible()) and not toolbarWidths[seg.id] then return true end
    end
    return false
  end
  -- A pending keyboard picker request must not die against a folded host segment.
  local function expandPendingHosts(segments, collapsed)
    for _, seg in ipairs(segments) do
      if collapsed[seg.id] and seg.pickers then
        for _, kind in ipairs(seg.pickers) do
          if kind == pickerOpenReq then
            collapsed[seg.id] = nil
            setCollapsed(seg.id, false)
          end
        end
      end
    end
  end
  return function(segments)
    if resetPending then
      for k in pairs(toolbarWidths) do toolbarWidths[k] = nil end
      resetPending = false
    end
    local collapsed = cm:get('toolbar.collapsed') or {}
    if pickerOpenReq then expandPendingHosts(segments, collapsed) end
    if anyUncached(segments) then measureWidths(segments, collapsed) end
    for k in pairs(lastToolbarRects) do lastToolbarRects[k] = nil end
    local startX = ImGui.GetCursorScreenPos(ctx)
    local availW = ImGui.GetContentRegionAvail(ctx)
    local rightX = startX + availW
    local lastEndX, first, lines = startX, true, 1
    for _, seg in ipairs(segments) do
      if not seg.visible or seg.visible() then
        local cachedW = toolbarWidths[seg.id] or 0
        if not first then
          local sepW = 12 + 1 + 12
          if lastEndX + sepW + cachedW <= rightX then
            ImGui.SameLine(ctx, 0, 12)
            chrome.verticalSeparator()
            ImGui.SameLine(ctx, 0, 12)
          else
            lines = lines + 1   -- segment wrapped to a new row
          end
        end
        drawSegment(seg, collapsed[seg.id])
        local minX, minY = ImGui.GetItemRectMin(ctx)
        local maxX, maxY = ImGui.GetItemRectMax(ctx)
        toolbarWidths[seg.id] = maxX - minX
        lastToolbarRects[seg.id] = { x = minX, y = minY, w = maxX - minX, h = maxY - minY }
        lastEndX, first = maxX, false
      end
    end
    toolbarLines = lines
  end
end

----- Picker (typeahead popup, shared across pages)

-- Per-kind state; popups close on focus loss so a missing entry just
-- means "default empty filter / cursor at top".
local pickerFilter, pickerCursor = {}, {}
local pickerDeleting = {}    -- per kind: the row key whose delete button has been clicked once
local pickerActive   = false -- frame-scoped: any picker popup live this frame
-- EEL callback: drops SetKeyboardFocusHere's select-all so a seeded filter
-- appends instead of being overwritten by the next keystroke. Attached lazily.
local clearSelCb     = nil

function chrome.requestPickerOpen(kind, seed) pickerOpenReq, pickerOpenSeed = kind, seed end
function chrome.pickerIsActive()        return pickerActive end
function chrome.resetPickerActive()     pickerActive = false end

-- Sentinel key for drawPicker's synthetic '+ new' row (see onCreate handling below).
local CREATE = {}

-- Build the picker-item list for a library-shaped cm key (e.g. 'swings',
-- 'tempers'); groups, modified badge, excludeOthers — see docs/chrome.md § Picker.
function chrome.libPicker(key, current, excludeOthers)
  excludeOthers = excludeOthers or {}
  local proj   = cm:getAt('project', key) or {}
  local merged = cm:get(key, { mergeTiers = true }) or {}

  local items = { { label = 'Off', key = nil, group = 1, current = current == nil } }

  local projNames = {}
  for k in pairs(proj) do projNames[#projNames+1] = k end
  table.sort(projNames)
  for _, name in ipairs(projNames) do
    local label = lib.modified(key, name) and (name .. ' \xe2\x80\xa2') or name
    items[#items+1] = { label = label, key = name, group = 2, current = current == name }
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

-- Two-press row delete: first click arms (turns the × red, no undo past this point), second
-- fires. See docs/chrome.md § Picker for the full rationale and the glyph/hit-box mechanics.
local DEL_GLYPH = 9   -- px across the drawn ×

-- The '?' slot is always reserved, so arming never shifts the ×. Placement has two gotchas
-- (SameLine's offset base, the Selectable's extended rect) -- see docs/chrome.md § Picker.
local function deleteRowButton(kind, key, id, rowLeft, rowW)
  local armed = pickerDeleting[kind] == key
  local side  = math.max(DEL_GLYPH + 4, ImGui.GetTextLineHeight(ctx))
  local boxW  = side + ImGui.CalcTextSize(ctx, '?')
  local winX  = ImGui.GetWindowPos(ctx)

  ImGui.SameLine(ctx, rowLeft - winX + rowW - boxW)
  local clicked = ImGui.InvisibleButton(ctx, '##del' .. id, boxW, side)

  local x0, y0 = ImGui.GetItemRectMin(ctx)
  local _,  y1 = ImGui.GetItemRectMax(ctx)
  local cx, cy = math.floor(x0 + side / 2), math.floor((y0 + y1) / 2)
  local r      = DEL_GLYPH // 2
  local ink    = 'picker.remove'
  if armed then ink = 'picker.removeArmed'
  elseif ImGui.IsItemHovered(ctx) then ink = 'text' end
  local p = chrome.screenPainter()
  p.line(cx - r, cy - r, cx + r, cy + r, ink, 1)
  p.line(cx - r, cy + r, cx + r, cy - r, ink, 1)
  -- The '?' rides the row font, so it need not match the hand-sized × exactly. Its ink sits high in
  -- the text box (no descender), so centring the box leaves it above the ×'s middle: nudge it down.
  if armed then
    p.text(x0 + side, math.floor(cy - ImGui.GetTextLineHeight(ctx) / 2) + 1, ink, '?')
  end

  if not clicked then return false end
  pickerDeleting[kind] = (not armed) and key or nil
  return armed
end

-- Generic typeahead picker. Enter picks the highlighted match; group
-- separators show only when filter is empty.
function chrome.drawPicker(d)
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
  if d.flat then ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x00000000) end   -- transparent rest; hover/active still give feedback
  local opening
  if btnW then opening = ImGui.Button(ctx, btnTxt, btnW, 0)
  else         opening = ImGui.Button(ctx, btnTxt) end
  if d.flat then ImGui.PopStyleColor(ctx, 1) end
  ImGui.PopStyleVar(ctx, 1)
  -- Anchor popup to the button rect; OpenPopup otherwise uses mouse
  -- position, putting a keyboard-triggered popup at the text cursor.
  local btnX, btnTop = ImGui.GetItemRectMin(ctx)
  local _, btnBot    = ImGui.GetItemRectMax(ctx)
  local fromReq = false
  if pickerOpenReq == d.kind then
    pickerOpenReq = nil
    opening, fromReq = true, true
  end
  if opening then
    pickerFilter[d.kind] = (fromReq and pickerOpenSeed) or ''
    if fromReq then pickerOpenSeed = nil end
    ImGui.OpenPopup(ctx, popupId)
  end

  -- placement='above' anchors the popup's bottom to the button's top (pivotY=1) so it grows
  -- upward -- for pickers docked near the window's bottom edge, where opening below would clip.
  if d.placement == 'above' then ImGui.SetNextWindowPos(ctx, btnX, btnTop, ImGui.Cond_Appearing, 0, 1)
  else                           ImGui.SetNextWindowPos(ctx, btnX, btnBot, ImGui.Cond_Appearing) end
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
  if not clearSelCb then
    clearSelCb = ImGui.CreateFunctionFromEEL('InputTextCallback_ClearSelection();')
    ImGui.Attach(ctx, clearSelCb)
  end
  local _, filter = ImGui.InputText(ctx, '##filter_' .. d.kind, prevFilter,
    ImGui.InputTextFlags_CallbackAlways, clearSelCb)
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

  -- onCreate: a non-empty filter with no exact item match earns a synthetic '+ new' row so Enter
  -- creates instead of overwrites. see docs/chrome.md § Picker
  if d.onCreate and filter ~= '' then
    local exact = false
    for _, it in ipairs(matches) do
      if it.label:lower() == lf then exact = true; break end
    end
    if not exact then
      table.insert(matches, 1, { label = '+ new: ' .. filter, key = CREATE })
      if currentMatch then currentMatch = currentMatch + 1 end
    end
  end

  -- On open or filter-change, highlight the current pick if it survived; else top, and disarm any
  -- delete: everything but a second click on the same row counts as a change of mind.
  if ImGui.IsWindowAppearing(ctx) or filter ~= prevFilter then
    pickerCursor[d.kind]   = currentMatch or 1
    pickerDeleting[d.kind] = nil
  end
  local cursor = pickerCursor[d.kind] or 1
  local n = #matches
  if n > 0 then
    if ImGui.IsKeyPressed(ctx, ImGui.Key_DownArrow) or ImGui.IsKeyPressed(ctx, ImGui.Key_RightArrow) then
      cursor = cursor % n + 1
    elseif ImGui.IsKeyPressed(ctx, ImGui.Key_UpArrow) or ImGui.IsKeyPressed(ctx, ImGui.Key_LeftArrow) then
      cursor = (cursor - 2) % n + 1
    end
  end
  cursor = math.min(math.max(cursor, 1), math.max(n, 1))
  pickerCursor[d.kind] = cursor

  local function choose(it)
    if it.key == CREATE then d.onCreate(filter) else d.onPick(it.key) end
  end

  if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
    if d.onCancel then d.onCancel() end
    ImGui.CloseCurrentPopup(ctx)
  elseif entered then
    if matches[cursor] then choose(matches[cursor]) end
    ImGui.CloseCurrentPopup(ctx)
  else
    local lastGroup
    -- Content left and full row width, for placing a trailing delete button; constant down the list.
    local rowLeft = ImGui.GetCursorScreenPos(ctx)
    local rowW    = ImGui.GetContentRegionAvail(ctx)
    for i, it in ipairs(matches) do
      if filter == '' and lastGroup and lastGroup ~= (it.group or 1) then
        ImGui.Separator(ctx)
      end
      local deletable = d.onDelete and it.key ~= nil and it.key ~= CREATE
      -- Without AllowOverlap the full-width Selectable swallows the clicks aimed at the delete
      -- button drawn over it: the later item only gets hover priority once the earlier one yields.
      local flags = deletable and ImGui.SelectableFlags_AllowOverlap or nil
      if ImGui.Selectable(ctx, it.label, i == cursor, flags) then choose(it) end
      if deletable and deleteRowButton(d.kind, it.key, i, rowLeft, rowW) then d.onDelete(it.key) end
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
function chrome.gridWidth(w) return math.max(120, w - PALETTE_W - PANE_GAP) end

-- Hand-drawn header: centred label + 1px divider at headerH; shares HEADER_PAD/HEADER_GAP
-- with the flanking grid header so dividers align across PANE_GAP. Returns divider screen-y.
function chrome.paletteHeader(label)
  local p       = chrome.screenPainter()
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
  return oy + headerH
end

-- Tabbed header: equal-width cells, active in text ink, rest dimmed (palette.tabInactive).
-- Dividers run the full header height with a bottom gap; a click fires onTab(key).
local function paletteTabsHeader(tabs, activeKey, onTab)
  local p       = chrome.screenPainter()
  local ox, oy  = ImGui.GetCursorScreenPos(ctx)
  local avail   = select(1, ImGui.GetContentRegionAvail(ctx))
  local sbw     = ImGui.GetScrollMaxY(ctx) > 0
                  and select(1, ImGui.GetStyleVar(ctx, ImGui.StyleVar_ScrollbarSize)) or 0
  local paneW   = avail + sbw
  local rowH    = math.max(1, ImGui.GetTextLineHeightWithSpacing(ctx))
  local headerH = rowH + HEADER_PAD
  local cellW   = paneW / #tabs
  for i, tab in ipairs(tabs) do
    local ink = (tab.key == activeKey) and 'text' or 'palette.tabInactive'
    local tw  = p.measure(tab.label)
    local cx  = ox + (i - 1) * cellW
    p.text(cx + math.floor((cellW - tw) / 2), oy + HEADER_PAD, ink, tab.label)
    if i > 1 then p.segment(math.floor(cx), oy, math.floor(cx), oy + headerH - HEADER_GAP, 'text', 1) end
    ImGui.SetCursorScreenPos(ctx, cx, oy)
    if ImGui.InvisibleButton(ctx, '##ptab_' .. tab.key, cellW, headerH) and onTab then onTab(tab.key) end
  end
  p.segment(ox, oy + headerH, ox + paneW, oy + headerH, 'text', 1)
  ImGui.SetCursorScreenPos(ctx, ox, oy)
  ImGui.Dummy(ctx, avail, headerH + HEADER_GAP)
  return oy + headerH
end

--contract: x/y/h are body-window screen coords at the gap's left edge; draw paints the body.
function chrome.palettePane(spec)
  -- vrule on the BODY draw list — it sits in the gap, outside the child.
  local p     = chrome.screenPainter()
  local lineX = spec.x + math.floor(PANE_GAP / 2)
  p.segment(lineX, spec.y, lineX, spec.y + spec.h, 'text', 1)

  ImGui.SetCursorScreenPos(ctx, spec.x + PANE_GAP, spec.y)
  if ImGui.BeginChild(ctx, '##palettePane', PALETTE_W, spec.h,
                      ImGui.ChildFlags_None, ImGui.WindowFlags_NoNav) then
    local childFocused = ImGui.IsWindowFocused(ctx)
    chrome.pushChromeStyles()
    if spec.tabs then paletteTabsHeader(spec.tabs, spec.activeTab, spec.onTab)
    else              chrome.paletteHeader(spec.label) end
    spec.draw(childFocused)
    chrome.popChromeStyles()
  end
  ImGui.EndChild(ctx)
end

-- Ellipsis-fit to a fixed pane width; no horizontal scroll exists. Private: the
-- trees fit their own labels, and no caller outside chrome has wanted it.
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
function chrome.rowSelectable(label, selected, flags)
  local hi = selected and ImGui.GetStyleColor(ctx, ImGui.Col_Header) or 0x00000000
  ImGui.PushStyleColor(ctx, ImGui.Col_HeaderHovered, hi)
  ImGui.PushStyleColor(ctx, ImGui.Col_HeaderActive,  hi)
  local clicked = ImGui.Selectable(ctx, label, selected, flags or 0)
  ImGui.PopStyleColor(ctx, 2)
  return clicked
end

-- Gutter + nesting metrics shared by every tree (sampler folders, fx palette,
-- swing/tuning library). Owned here so no caller can drift them out of step.
local TREE_INDENT, ARROW_GUTTER = 12, 14
local CHIP_OPEN, CHIP_SHUT = '\xe2\x96\xbe', '\xe2\x96\xb8'   -- ▾ / ▸

-- One tree row, sampler-tree style: a draw-list chip in a fixed gutter (never
-- highlighted), then a selectable label; the row owns its nesting indent.
--contract: chip toggles; body click selects and toggles a parent; allowDouble suppresses both
--contract: childless rows show blank gutter so labels align across depths
--contract: nesting indent = opts.indent (px) if set, else depth × TREE_INDENT
function chrome.treeRow(opts)
  local indent = opts.indent or (opts.depth or 0) * TREE_INDENT
  if indent > 0 then ImGui.Indent(ctx, indent) end

  local availW  = select(1, ImGui.GetContentRegionAvail(ctx))
  local rowH    = ImGui.GetTextLineHeight(ctx)
  local x, y    = ImGui.GetCursorScreenPos(ctx)
  local chipHit = ImGui.InvisibleButton(ctx, '##chip' .. opts.id, ARROW_GUTTER, rowH)
  if opts.hasChildren then
    ImGui.DrawList_AddText(ImGui.GetWindowDrawList(ctx), x + 2, y, chrome.colour('text'),
                           opts.open and CHIP_OPEN or CHIP_SHUT)
  end
  ImGui.SameLine(ctx, 0, 0)

  local flags = opts.flags or 0
  if opts.allowDouble then flags = flags | ImGui.SelectableFlags_AllowDoubleClick end
  local label   = fitLabel(opts.label, availW - ARROW_GUTTER - (opts.reserve or 8))
  local clicked = chrome.rowSelectable(label .. '###tr' .. opts.id, opts.selected, flags)
  local double  = clicked and opts.allowDouble and ImGui.IsMouseDoubleClicked(ctx, 0) or false
  local bodySel = clicked and not double

  if indent > 0 then ImGui.Unindent(ctx, indent) end
  return {
    toggled       = opts.hasChildren and (chipHit or bodySel) or false,
    selected      = bodySel,
    doubleClicked = double,
  }
end

-- Non-selectable tree heading (fx-section labels, group dividers): a dimmed label.
--contract: gutter=true aligns text with a same-depth row label, not its chip; else flush indent
function chrome.treeHeading(opts)
  local indent = (opts.depth or 0) * TREE_INDENT + (opts.gutter and ARROW_GUTTER or 0)
  if indent > 0 then ImGui.Indent(ctx, indent) end
  ImGui.TextDisabled(ctx, opts.text)
  if indent > 0 then ImGui.Unindent(ctx, indent) end
end

return chrome

