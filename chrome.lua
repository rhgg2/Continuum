-- See docs/chrome.md for the model.

--shape: chrome = { colour(name, scope?)->u32, pushChromeStyles(), popChromeStyles(), pushChromeWindow(), popChromeWindow(), verticalSeparator(colour?), disabledIf(cond,fn), row(h?,fn), checkbox(label,v), radio(label,active), headingLabel(text, dimBy?), dimText(alpha)->u32, screenPainter()->painter}
--shape: chrome (pickers) = { makeToolbar()->fn(segments), drawPicker(d), libPicker(d)->items, pickerIsActive()->bool, resetPickerActive(), requestPickerOpen(kind) }
--shape: chrome (status bar) = { makeStatusBar()->fn(segments), statusRects()->{id->rect}, statusEditActive()->bool }
--shape: libPickerSpec = { key: string, current?: any, excludeOthers?: {name->true}, off?: bool = true }
--shape: chrome (shared row primitives) = { rowSelectable(label,sel,flags?)->clicked, treeRow(opts)->{toggled,selected,doubleClicked}, numberStepper(id,value,opts)->changed,value }
--shape: pickerSpec = { kind: string, heading: string?, buttonLabel: string, items: [{label, key, group?, groupLabel?: string, current?=bool, tier?='project'|'global'}], groups?: [{key, label?}], onPick: fn(key, tier), onCancel?: fn(), onCreate?: fn(text, group), createLabel?: fn(text)->label|nil, group?, onDelete?: fn(key, tier), placement?: 'above', width?, minWidth?, maxWidth?, flat?: bool }
--shape: palettePaneSpec = { x, y, h, label | {tabs=[{key,label}], activeTab, onTab}, draw = fn(childFocused) }
--contract: one chrome instance per coordinator; threaded into every page
--contract: the picker and an open status field claim their keys under 'picker' and 'statusEdit'
--contract: see docs/keyQueue.md § Ownership
--invariant: colour cache lives on the chrome instance and is invalidated on cm:configChanged
local ImGui   = require 'imgui' '0.10'
local painter = require 'painter'
local util    = require 'util'

local cm, ctx, lib, keyQueue = (...).cm, (...).ctx, (...).lib, (...).keyQueue

local chrome = {}

local cache = {}
cm:subscribe('configChanged', function() cache = {} end)

--contract: walks colour aliases (see docs/configManager.md) to a terminal atom; outermost alpha override wins; cycles raise with the resolved chain
local function resolve(key)
  local seen, override = {}, nil
  while true do
    if seen[key] then
      util.add(seen, key)
      error('colour cycle: ' .. table.concat(seen, ' → '))
    end
    util.add(seen, key); seen[key] = true
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

-- Per-takeId fill pair { fill, focusFill } off colourIdx; focus brightens to read without losing hue.
-- Shared by the arrange grid and the tracker's mini-map, so a slot's colour means one thing across the two.
local SLOT_FILL_ALPHA = 1
local slotFillCache = {}
function chrome.slotFill(colourIdx, focused)
  if colourIdx == nil then
    return focused and 'arrange.orphanFocusFill' or 'arrange.orphanFill'
  end
  local pair = slotFillCache[colourIdx]
  if not pair then
    pair = {
      painter.hue(colourIdx, 0.08, 0.77, SLOT_FILL_ALPHA),
      painter.hue(colourIdx, 0.1,  0.84, SLOT_FILL_ALPHA),
    }
    slotFillCache[colourIdx] = pair
  end
  return focused and pair[2] or pair[1]
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

-- The ambient text colour at a fraction of its alpha, so chrome on either band takes its
-- ink from whichever it sits in, rather than a fixed swatch that can only suit one of them.
function chrome.dimText(alpha)
  local r, g, b, a = ImGui.ColorConvertU32ToDouble4(ImGui.GetStyleColor(ctx, ImGui.Col_Text))
  return ImGui.ColorConvertDouble4ToU32(r, g, b, a * alpha)
end

-- reaper-imgui has no Separator(Vertical); draw a 1px vertical rule via the window draw
-- list and reserve a Dummy slot so SameLine works. see docs/chrome.md § Vertical separator
function chrome.verticalSeparator(colour)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local h    = ImGui.GetFrameHeight(ctx)
  ImGui.DrawList_AddRectFilled(ImGui.GetWindowDrawList(ctx),
    x, y, x + 1, y + h, colour or chrome.colour('separator'))
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
  -- The box is cut for the widest entry, so a centred label would drift with the
  -- current value's length. Left-align it, as the picker's own button reads.
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ButtonTextAlign, 0, 0.5)
  local open = ImGui.Button(ctx, current .. DROP_ARROW .. '##' .. id, btnW)
  ImGui.PopStyleVar(ctx, 1)
  if open then ImGui.OpenPopup(ctx, id .. '_popup') end
  local x = ImGui.GetItemRectMin(ctx)
  local _, y = ImGui.GetItemRectMax(ctx)
  ImGui.SetNextWindowPos(ctx, x, y, ImGui.Cond_Appearing)
  ImGui.SetNextWindowSize(ctx, btnW, 0)
  -- A hairline one zone down from the fill, so the list reads as a surface of its
  -- own rather than bleeding into whatever it covers.
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_PopupBorderSize, 1)
  ImGui.PushStyleColor(ctx, ImGui.Col_Border, chrome.colour('toolbar.popupBorder'))
  local picked
  if ImGui.BeginPopup(ctx, id .. '_popup', ImGui.WindowFlags_NoNav) then
    for idx, it in ipairs(items) do
      if ImGui.Selectable(ctx, it, it == current) then picked = idx end
    end
    ImGui.EndPopup(ctx)
  end
  ImGui.PopStyleColor(ctx, 1)
  ImGui.PopStyleVar(ctx, 1)
  return picked
end

-- Section label for toolbar and status segments: dimmed so it reads as a heading, not a
-- control. Caller follows with SameLine; the dim rides ambient Col_Text so it suits both bands.
function chrome.headingLabel(text, dimBy)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, chrome.dimText(dimBy or 0.55))
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
-- The shared `separator` swatch also draws grid lines and table borders; the toolbar's own
-- rules want more weight than those, so they take the band's ink like the status bar's do.
local TOOLBAR_RULE_DIM = 0.18
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
            chrome.verticalSeparator(chrome.dimText(TOOLBAR_RULE_DIM))
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

----- Status bar

-- Ellipsis-fit to a fixed width; no horizontal scroll exists. Private: the status cells and
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

--shape: statusSegment = { id: string, label?: string, width: px (the value box; the label sits to its left; omitted by a flags cell, which measures its own), get: fn() -> value, format?: string | fn(v) -> string, visible?: fn() -> bool, edit?: numberEdit | pickEdit | flagsEdit — presence makes the cell a control, set?: fn(v) — the writer for number and pick }
--shape: numberEdit = { kind = 'number', min?, max?, step? = 1 | 'x2' (halve/double), format? }
--shape: pickEdit = { kind = 'pick', items: fn() -> pickerItems }
--shape: flagsEdit = { kind = 'flags', items: [{ label: string, get: fn() -> bool, set: fn(bool) }] — each flag carries its own pair, so the cell needs no get/set }
-- see docs/chrome.md § Status bar layout, § Editing a status cell
local lastStatusRects = {}
local STATUS_GAP, STATUS_LABEL_GAP = 8, 6   -- either side of the rule; between label and value
-- The bar's text sits four ramp zones off its ground, against the toolbar's
-- seven, so its labels and rules dim less before they stop reading.
local STATUS_LABEL_DIM, STATUS_RULE_DIM = 0.75, 0.45
-- The open number edit: the cell's id, the buffer, selectTo's arming count (see
-- § Opening a field with a selection) and the first-frame focus grab. nil when none is open.
local statusEdit  = nil
-- Wheel notches tallied against the cell under the pointer; a trackpad sends fractions.
local statusWheel = { id = nil, accum = 0 }

function chrome.statusRects() return lastStatusRects end

--contract: true while a status cell holds an open field; the next fill hands it the keyboard
function chrome.statusEditActive() return statusEdit ~= nil end

local function statusText(seg)
  local v = seg.get()
  if type(seg.format) == 'function' then return seg.format(v) end
  if type(seg.format) == 'string'   then return string.format(seg.format, v) end
  return tostring(v)
end

-- The buffer a click opens with: the number under its own format, so a cell whose
-- display carries more than the number still edits as one.
local function editText(seg)
  local fmt = seg.edit.format or (type(seg.format) == 'string' and seg.format)
  return fmt and string.format(fmt, seg.get()) or tostring(seg.get())
end

local function clampTo(v, edit)
  if edit.min and v < edit.min then return edit.min end
  if edit.max and v > edit.max then return edit.max end
  return v
end

-- One wheel notch: ±step, or a halving/doubling for the zoom-like fields, whose
-- useful range is multiplicative.
local function stepped(v, dir, edit)
  if edit.step == 'x2' then return clampTo(dir > 0 and v * 2 or v / 2, edit) end
  return clampTo(v + dir * (edit.step or 1), edit)
end

-- Whole notches over the hovered cell. Trackpads send fractions, so the part notch is
-- tallied against the cell it fell on and dropped when the pointer reaches another.
local function wheelNotches(id)
  if statusWheel.id ~= id then statusWheel.id, statusWheel.accum = id, 0 end
  local whole, frac = math.modf(statusWheel.accum + ImGui.GetMouseWheel(ctx))
  statusWheel.accum = frac
  return whole
end

-- The hit box takes the band's padding above and below the cell, so a pointer flung at
-- a bottom-edge bar lands on the control, not beside it — docs/chrome.md § Editing a status cell.
local function bandHit(y, h)
  local _, padY = ImGui.GetStyleVar(ctx, ImGui.StyleVar_WindowPadding)
  return y - padY, h + padY * 2
end

-- An editable cell wears a well one zone off the band, so the box marks what can be
-- changed rather than decorating the row. One colour, hovered or not: on a row of
-- adjacent boxes a shade that follows the pointer reads as flicker.
local function statusWell(x, y, w, h)
  ImGui.DrawList_AddRectFilled(ImGui.GetWindowDrawList(ctx), x, y, x + w, y + h,
    chrome.colour('statusBar.well'),
    ImGui.GetStyleVar(ctx, ImGui.StyleVar_FrameRounding))
end

-- Resting number cell: the rect takes both the click that opens the edit and the wheel
-- that steps without one; release timing is explained in docs/chrome.md § Editing a status cell.
local function numberCell(seg, x, y, w, h)
  local hitY, hitH = bandHit(y, h)
  ImGui.SetCursorScreenPos(ctx, x, hitY)
  local clicked = ImGui.InvisibleButton(ctx, '##status_' .. seg.id, w, hitH)
  local hovered = ImGui.IsItemHovered(ctx)
  if clicked then
    local text = editText(seg)
    statusEdit = { id = seg.id, text = text, selectTo = #text, focus = true }
  elseif hovered then
    local notches = wheelNotches(seg.id)
    if notches ~= 0 then
      local v, dir = seg.get(), notches > 0 and -1 or 1
      for _ = 1, math.abs(notches) do v = stepped(v, dir, seg.edit) end
      seg.set(v)
    end
  end
  statusWell(x, y, w, h)
  local padX = ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
  ImGui.SetCursorScreenPos(ctx, x + padX, y)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, fitLabel(statusText(seg), w - padX * 2))
end

-- The open edit, in the rect the well held, so nothing moves on the transition. Enter
-- commits through `set`; Esc and any other loss of the field cancel.
local function numberEdit(seg, x, y, w)
  ImGui.SetCursorScreenPos(ctx, x, y)
  ImGui.SetNextItemWidth(ctx, w)
  if statusEdit.focus then ImGui.SetKeyboardFocusHere(ctx); statusEdit.focus = nil end
  local selFlags, selCb = 0, nil
  if statusEdit.selectTo then selFlags, selCb = chrome.selectTo(statusEdit.selectTo) end
  -- The band's ink is white, so the selection goes dark; ImGui's stock blue is a
  -- translucent wash that all but vanishes on the well.
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg,        chrome.colour('statusBar.well'))
  ImGui.PushStyleColor(ctx, ImGui.Col_TextSelectedBg, chrome.colour('statusBar.textSelection'))
  local committed, text = ImGui.InputText(ctx, '##statusEdit_' .. seg.id, statusEdit.text,
    ImGui.InputTextFlags_EnterReturnsTrue | selFlags, selCb)
  ImGui.PopStyleColor(ctx, 2)
  if statusEdit.selectTo and ImGui.IsItemActive(ctx) then statusEdit.selectTo = nil end
  if committed then
    local v = tonumber(text)
    if v then seg.set(clampTo(v, seg.edit)) end
    statusEdit = nil
  elseif keyQueue:take(ImGui.Key_Escape, keyQueue:frameMods(), 'statusEdit')
      or ImGui.IsItemDeactivated(ctx) then
    statusEdit = nil
  else
    statusEdit.text = text
  end
end

-- A pick cell hands its rect to the picker, which draws its own button: the well arrives
-- as that button's fill, and the popup grows upward off a bar pinned to the window foot.
local PICK_ARROW = ' \xe2\x96\xbe'
local function pickCell(seg, x, y, w)
  local padX = ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
  ImGui.SetCursorScreenPos(ctx, x, y)
  ImGui.PushStyleColor(ctx, ImGui.Col_Button,        chrome.colour('statusBar.well'))
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, chrome.colour('statusBar.well'))
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,  chrome.colour('statusBar.well'))
  chrome.drawPicker{
    kind        = 'status_' .. seg.id,
    buttonLabel = fitLabel(statusText(seg), w - padX * 2 - ImGui.CalcTextSize(ctx, PICK_ARROW)),
    width       = w, placement = 'above',
    items       = seg.edit.items(),
    onPick      = function(key) seg.set(key) end,
  }
  ImGui.PopStyleColor(ctx, 3)
end

-- Self-naming tokens over one cell: a lit one wears the well, an unlit one dim text in
-- the same footprint, so toggling never reflows the row — docs/chrome.md § Editing a status cell.
local FLAG_GAP = 4
local function flagsCell(seg, x, y, h)
  local padX, used = ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding), 0
  for i, flag in ipairs(seg.edit.items) do
    if i > 1 then used = used + FLAG_GAP end
    local w, fx, on = ImGui.CalcTextSize(ctx, flag.label) + padX * 2, x + used, flag.get()
    local hitY, hitH = bandHit(y, h)
    ImGui.SetCursorScreenPos(ctx, fx, hitY)
    if ImGui.InvisibleButton(ctx, '##status_' .. seg.id .. '_' .. flag.label, w, hitH) then
      flag.set(not on)
    end
    if on then statusWell(fx, y, w, h) end
    ImGui.SetCursorScreenPos(ctx, fx + padX, y)
    if on then
      ImGui.AlignTextToFramePadding(ctx)
      ImGui.Text(ctx, flag.label)
    else
      chrome.headingLabel(flag.label, STATUS_LABEL_DIM)
    end
    used = used + w
  end
  return used
end

-- Dimmed label, then the value in a box of exactly `width`, ellipsis-fitted into it. An
-- `edit` kind makes that box a control. Returns the whole cell's width, label included.
local function drawStatusCell(seg, x, y, h)
  local used = 0
  if seg.label then
    ImGui.SetCursorScreenPos(ctx, x, y)
    chrome.headingLabel(seg.label, STATUS_LABEL_DIM)
    used = ImGui.CalcTextSize(ctx, seg.label) + STATUS_LABEL_GAP
  end
  local vx = x + used
  -- A flags cell measures its own static labels, so it declares no width.
  if seg.edit and seg.edit.kind == 'flags' then return used + flagsCell(seg, vx, y, h) end
  local vw = seg.width
  if not seg.edit then
    ImGui.SetCursorScreenPos(ctx, vx, y)
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, fitLabel(statusText(seg), vw))
  elseif seg.edit.kind == 'pick'                then pickCell(seg, vx, y, vw)
  elseif statusEdit and statusEdit.id == seg.id then numberEdit(seg, vx, y, vw)
  else                                               numberCell(seg, vx, y, vw, h)
  end
  return used + vw
end

function chrome.makeStatusBar()
  return function(segments)
    for k in pairs(lastStatusRects) do lastStatusRects[k] = nil end
    local x0, y0 = ImGui.GetCursorScreenPos(ctx)
    local h, x, first = ImGui.GetFrameHeight(ctx), x0, true
    local editDrawn = false
    -- ImGui rings the focused item with the nav cursor. On a row of one-datum cells that
    -- reads as a stray box around whatever was last clicked, so the bar draws without it.
    ImGui.PushStyleColor(ctx, ImGui.Col_NavCursor, 0x00000000)
    for _, seg in ipairs(segments) do
      if not seg.visible or seg.visible() then
        if not first then
          ImGui.SetCursorScreenPos(ctx, x + STATUS_GAP, y0)
          chrome.verticalSeparator(chrome.dimText(STATUS_RULE_DIM))
          x = x + STATUS_GAP * 2 + 1
        end
        local cellW = drawStatusCell(seg, x, y0, h)
        if statusEdit and statusEdit.id == seg.id then editDrawn = true end
        lastStatusRects[seg.id] = { x = x, y = y0, w = cellW, h = h }
        x, first = x + cellW, false
      end
    end
    ImGui.PopStyleColor(ctx, 1)
    -- A page switch or a cell turning invisible takes its open edit with it; else the
    -- gate on page keys would stay shut with nothing on screen holding it.
    if statusEdit and not editDrawn then statusEdit = nil end
  end
end

----- Text-field selection

-- One EEL instance for every caller: selEnd is set immediately before the
-- InputText that consumes it. see docs/chrome.md § Opening a field with a selection
local selectCb = nil

--contract: (flags, callback) for one InputText, opening it with [0, n) selected
function chrome.selectTo(n)
  if not selectCb then
    selectCb = ImGui.CreateFunctionFromEEL('SelectionStart = 0; SelectionEnd = selEnd; CursorPos = selEnd;')
    ImGui.Attach(ctx, selectCb)
  end
  ImGui.Function_SetValue(selectCb, 'selEnd', n)
  return ImGui.InputTextFlags_CallbackAlways, selectCb
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
local BULLET = ' \xe2\x80\xa2'   -- trailing mark on a project entry that has diverged from its source

-- Build the picker-item list for a library-shaped cm key (e.g. 'swings',
-- 'tempers'); groups, modified badge, excludeOthers — see docs/chrome.md § Picker.
function chrome.libPicker(d)
  local key, current = d.key, d.current
  local excludeOthers = d.excludeOthers or {}
  local proj   = cm:getAt('project', key) or {}
  local merged = cm:get(key, { mergeTiers = true }) or {}

  local items = {}
  -- A catalogue you read *from* offers Off; one you write *into* has nothing to turn off.
  -- No groupLabel: Off is no tier, and a heading over a single row is noise.
  if d.off ~= false then
    util.add(items, { label = 'Off', key = nil, group = 1, current = current == nil })
  end

  local projNames = {}
  for k in pairs(proj) do util.add(projNames, k) end
  table.sort(projNames)
  for _, name in ipairs(projNames) do
    local label = lib.modified(key, name) and (name .. BULLET) or name
    util.add(items, { label = label, key = name, group = 2, groupLabel = 'Project',
                      current = current == name, tier = 'project' })
  end

  local otherNames = {}
  for k in pairs(merged) do
    if not proj[k] and not excludeOthers[k] then
      util.add(otherNames, k)
    end
  end
  table.sort(otherNames)
  for _, name in ipairs(otherNames) do
    -- Always the library tier, never the factory one -- a merged name the library lacks is a seeded
    -- row that was deleted; see docs/chrome.md § Picker for why 'global' names it, not 'factory'.
    util.add(items, { label = '+ ' .. name, key = name, group = 3, groupLabel = 'Library',
                      current = false, tier = 'global' })
  end
  return items
end

-- The two tiers of a by-copy catalogue, in the order they are drawn. Callers pass this as the
-- picker's `groups`, so a tier standing empty still shows and can still be created into.
chrome.tierGroups = { { key = 'project', label = 'Project' },
                      { key = 'global',  label = 'Library'  } }

-- Build the picker-item list for a catalogue held by *copy* (`fxPatches`): both tiers in full, so
-- a name held twice draws under each heading. See docs/chrome.md § Picker.
--contract: project entries then library entries, each sorted; a divergent project copy is badged
function chrome.tierPicker(d)
  local key   = d.key
  local names = lib.names(key)
  local items = {}
  for _, name in ipairs(names.project) do
    local label = lib.modified(key, name) and (name .. BULLET) or name
    util.add(items, { label = label, key = name, group = 'project', tier = 'project' })
  end
  for _, name in ipairs(names.library) do
    util.add(items, { label = name, key = name, group = 'global', tier = 'global' })
  end
  return items
end

-- Two-press row delete: first click arms (turns the × red, no undo past this point), second
-- fires. See docs/chrome.md § Picker for the full rationale and the glyph/hit-box mechanics.
local DEL_GLYPH = 9   -- px across the drawn ×

-- The box the button takes: the square side, and the width including the reserved '?' slot.
local function rowButtonBox()
  local side = math.max(DEL_GLYPH + 4, ImGui.GetTextLineHeight(ctx))
  return side, side + ImGui.CalcTextSize(ctx, '?')
end

-- The '?' slot is always reserved, so arming never shifts the ×. Placement has two gotchas
-- (SameLine's offset base, the Selectable's extended rect) -- see docs/chrome.md § Picker.
local function rowButton(kind, key, id, rowLeft, rowW)
  local armed      = pickerDeleting[kind] == key
  local side, boxW = rowButtonBox()
  local winX       = ImGui.GetWindowPos(ctx)

  ImGui.SameLine(ctx, rowLeft - winX + rowW - boxW)
  local clicked = ImGui.InvisibleButton(ctx, '##del' .. id, boxW, side)

  local x0, y0 = ImGui.GetItemRectMin(ctx)
  local _,  y1 = ImGui.GetItemRectMax(ctx)
  local cx, cy = math.floor(x0 + side / 2), math.floor((y0 + y1) / 2)
  local r      = DEL_GLYPH // 2
  local ink    = 'picker.remove'
  if armed then ink = 'picker.armed'
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

-- Groups a caller did not declare: one per distinct `group` in item order, taking its heading from
-- the first item carrying one. See docs/chrome.md § Picker.
local DEFAULT_GROUP = 1
local function inferGroups(items)
  local out, seen = {}, {}
  for _, it in ipairs(items) do
    local k = it.group or DEFAULT_GROUP
    if not seen[k] then seen[k] = true; util.add(out, { key = k, label = it.groupLabel }) end
  end
  if #out == 0 then util.add(out, { key = DEFAULT_GROUP }) end
  return out
end

-- Px the filter's rule lifts out of ImGui's default gap, which hangs it nearer the first row than
-- the field it divides from.
local DIVIDER_LIFT = 1

-- 'No maximum' for a size constraint; a zero max is taken literally and collapses the window.
local FLT_MAX = 3.4028234663852886e38

-- A picker opens from the toolbar or from the status bar, two grounds with opposite ink,
-- so its popup carries its own; see docs/chrome.md § Editing a status cell for why.
local POPUP_INK = {
  PopupBg         = 'toolbar.popupBg',
  Text            = 'toolbar.text',
  InputTextCursor = 'toolbar.text',
  FrameBg         = 'toolbar.button',
  FrameBgHovered  = 'toolbar.button',
  FrameBgActive   = 'toolbar.button',
  Header          = 'toolbar.selectedRow',
  HeaderHovered   = 'toolbar.selectedRow',
  HeaderActive    = 'toolbar.selectedRow',
  TextSelectedBg  = 'toolbar.textSelection',
}

local function pushPopupInk()
  local n = 0
  for slot, name in pairs(POPUP_INK) do
    ImGui.PushStyleColor(ctx, ImGui['Col_' .. slot], chrome.colour(name))
    n = n + 1
  end
  return n
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
  local btnX, btnTop     = ImGui.GetItemRectMin(ctx)
  local btnRight, btnBot = ImGui.GetItemRectMax(ctx)
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
  -- The popup is the button's own drawer, so it starts at the button's width; a zero max leaves the
  -- auto-fit free to grow it for a label too long to sit in that.
  ImGui.SetNextWindowSizeConstraints(ctx, btnRight - btnX, 0, FLT_MAX, FLT_MAX)
  -- Field, rule and rows all sit on the work rect (see below), where the rows used to bleed half an
  -- item spacing past it: take that off the horizontal padding so the list runs where it always did.
  local spacingX, spacingY = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing)
  local padX, padY         = ImGui.GetStyleVar(ctx, ImGui.StyleVar_WindowPadding)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, padX + 1 - spacingX / 2, padY)
  -- The fill is taken at Begin, so the ink goes on before it, not inside the body.
  local inkPushes = pushPopupInk()
  -- NoNav: kill ImGui's built-in keyboard nav highlight on the popup —
  -- otherwise it draws a second cursor that fights ours and steals
  -- arrow keys / character input from the filter InputText.
  local open = ImGui.BeginPopup(ctx, popupId, ImGui.WindowFlags_NoNav)
  ImGui.PopStyleVar(ctx, 1)
  if not open then ImGui.PopStyleColor(ctx, inkPushes); return end
  pickerActive = true   -- the coordinator reads this at the next frame's fill, handing us the keyboard

  -- No horizontal item spacing: a Selectable's rect is otherwise extended half a spacing past the
  -- content edge on each side, standing the rows wider than the filter field and its rule.
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, 0, spacingY)

  if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
  ImGui.SetNextItemWidth(ctx, (ImGui.GetContentRegionAvail(ctx)))
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
  ImGui.SetCursorPosY(ctx, ImGui.GetCursorPosY(ctx) - DIVIDER_LIFT)
  ImGui.Separator(ctx)

  -- The popup body, in the order it draws: one block per group, each with its heading, optional
  -- create row, then matching items; `rows` is the flat cursor domain over that order. See docs/chrome.md § Picker.
  local lf = filter:lower()
  -- The create row's label and the block it leads, unless the caller names them -- a nil label there
  -- withholds the row, a nil group leaves it leading every block. see docs/chrome.md § Picker
  local createLabel, createGroup = '+ new: ' .. filter, nil
  if d.createLabel then createLabel, createGroup = d.createLabel(filter) end
  local blocks, rows, currentRow = {}, {}, nil
  for _, g in ipairs(d.groups or inferGroups(d.items)) do
    local block, matched, exact = { key = g.key, label = g.label, rows = {} }, {}, false
    for _, it in ipairs(d.items) do
      if (it.group or DEFAULT_GROUP) == g.key
         and (filter == '' or it.label:lower():find(lf, 1, true)) then
        util.add(matched, it)
        if it.label:lower() == lf then exact = true end
      end
    end
    local function addRow(r)
      util.add(rows, r); r.index = #rows; util.add(block.rows, r)
    end
    -- The create row leads its group: were it to trail, three letters and Enter would land on the
    -- first name they partly matched and overwrite it.
    if d.onCreate and createLabel and filter ~= '' and not exact
       and (createGroup == nil or createGroup == g.key) then
      addRow{ create = g.key, label = createLabel }
    end
    for _, it in ipairs(matched) do
      addRow{ item = it, label = it.label }
      if it.current then currentRow = #rows end
    end
    -- A declared group stands even when empty -- that is how a tier holding nothing still shows, and
    -- can still be created into. An inferred one is its items, so it never is.
    if #block.rows > 0 or (d.groups and filter == '') then util.add(blocks, block) end
  end

  -- On open or filter-change, highlight the current pick if it survived; else top, and disarm any
  -- armed delete: everything but a second click on the same row counts as a change of mind.
  if ImGui.IsWindowAppearing(ctx) or filter ~= prevFilter then
    pickerCursor[d.kind]   = currentRow or 1
    pickerDeleting[d.kind] = nil
  end
  local cursor = pickerCursor[d.kind] or 1
  local n = #rows
  local mods = keyQueue:frameMods()
  if n > 0 then
    if keyQueue:take(ImGui.Key_DownArrow, mods, 'picker')
       or keyQueue:take(ImGui.Key_RightArrow, mods, 'picker') then
      cursor = cursor % n + 1
    elseif keyQueue:take(ImGui.Key_UpArrow, mods, 'picker')
        or keyQueue:take(ImGui.Key_LeftArrow, mods, 'picker') then
      cursor = (cursor - 2) % n + 1
    end
  end
  cursor = math.min(math.max(cursor, 1), math.max(n, 1))
  pickerCursor[d.kind] = cursor

  -- A row is a create row or an item row; the group it sits in is the tier either one acts on.
  local function choose(r)
    if r.create then d.onCreate(filter, r.create) else d.onPick(r.item.key, r.item.tier) end
  end

  if keyQueue:take(ImGui.Key_Escape, mods, 'picker') then
    if d.onCancel then d.onCancel() end
    ImGui.CloseCurrentPopup(ctx)
  elseif keyQueue:take(ImGui.Key_Enter, mods, 'picker')
      or keyQueue:take(ImGui.Key_KeypadEnter, mods, 'picker') then
    if rows[cursor] then choose(rows[cursor]) end
    ImGui.CloseCurrentPopup(ctx)
  else
    -- Hand the rule's lifted pixel back, so only the rule moved. It belongs to this branch: a cursor
    -- moved with no item after it faults at EndPopup, and the two branches above draw nothing.
    ImGui.SetCursorPosY(ctx, ImGui.GetCursorPosY(ctx) + DIVIDER_LIFT)
    -- Content left and full row width, for placing a trailing delete button; constant down the list.
    local rowLeft = ImGui.GetCursorScreenPos(ctx)
    local rowW    = ImGui.GetContentRegionAvail(ctx)
    for bi, block in ipairs(blocks) do
      -- A heading divides as well as names, so only an unlabelled group needs a rule above it.
      if bi > 1 and not block.label then ImGui.Separator(ctx) end
      if block.label then ImGui.TextDisabled(ctx, block.label) end
      -- A name held in two tiers draws two rows under one label, and every group's create row reads
      -- alike: scope each block's ids by its group, as the editor's library tree scopes its leaves.
      ImGui.PushID(ctx, tostring(block.key))
      for _, r in ipairs(block.rows) do
        local deletable = d.onDelete and r.item and r.item.key ~= nil
        -- Without AllowOverlap the full-width Selectable swallows the clicks aimed at the delete
        -- button drawn over it: the later item only gets hover priority once the earlier one yields.
        local flags = deletable and ImGui.SelectableFlags_AllowOverlap or nil
        if ImGui.Selectable(ctx, r.label, r.index == cursor, flags) then choose(r) end
        if deletable and rowButton(d.kind, r.item.key, r.index, rowLeft, rowW) then
          d.onDelete(r.item.key, r.item.tier)
        end
      end
      ImGui.PopID(ctx)
    end
    -- ImGui measures content from a row's text, not the highlight, which runs half a spacing past
    -- its foot: plant a zero-height item there, or the bottom margin comes up short of the sides.
    ImGui.SetCursorPosY(ctx, ImGui.GetCursorPosY(ctx) - spacingY // 2)
    ImGui.Dummy(ctx, 0, 0)
  end

  ImGui.PopStyleVar(ctx, 1)
  ImGui.PopStyleColor(ctx, inkPushes)
  ImGui.EndPopup(ctx)
end

----- Palette pane (shared right-hand pane: arrange / wiring / tracker / sampler)

-- Pane geometry. HEADER_PAD/HEADER_GAP also size a flanking grid header (see arrangeRender)
-- so the dividers line up — until arrange's band grows for a wrapped track name.
local PALETTE_W, PANE_GAP    = 200, 11
local HEADER_PAD, HEADER_GAP = 8, 4

--contract: width of the main pane left of the palette; floors at 120.
function chrome.gridWidth(w) return math.max(120, w - PALETTE_W - PANE_GAP) end

-- Hand-drawn header: centred label + 1px divider at headerH; shares HEADER_PAD/HEADER_GAP
-- with the flanking grid header. Returns divider screen-y.
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

