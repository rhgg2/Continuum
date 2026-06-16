-- See docs/help.md for the model.
-- F1 cheat-sheet: toolbar groups pin callouts under their segment; body groups flow row-major in the grid rect.

--shape: helpGroup = { anchor, title, place='pin'|'flow', items=[{cmd,label}] }
--invariant: anchors are frame-scoped — cleared each frame, repopulated by render code only while open
--contract: 'toolbar.<id>' anchors resolve through chrome.toolbarRects(); others via help:anchor
local ImGui = require 'imgui' '0.10'

local ctx    = (...).ctx
local chrome = (...).chrome
local cmgr   = (...).cmgr

local pages   = {}    -- pageName → groups
local anchors = {}    -- key → { x, y, w, h }
local current = nil
local open    = false
local openAtStart = false   -- open as of frame start; gates dismissal + page input swallow

local PAD, ROW_GAP, KEY_GAP, BOX_GAP = 6, 2, 12, 8
local DIM_COL = 0x00000099
local EM_DASH = '\xe2\x80\x94'

local help = {}

----------- PUBLIC

function help:registerPage(name, groups) pages[name] = groups end
function help:setPage(name)              current = name end
function help:isOpen()                   return open end
function help:close()                    open = false end

-- Won't open on a page that declared no manifest, so F1 there is inert
-- rather than dimming the screen with nothing to show.
function help:toggle()
  open = (not open) and pages[current] ~= nil or false
end

function help:beginFrame() anchors, openAtStart = {}, open end
function help:wasOpenAtFrameStart() return openAtStart end

function help:anchor(key, x, y, w, h)
  if not open then return end
  anchors[key] = { x = x, y = y, w = w, h = h }
end

----------- DRAW

local function rectFor(key)
  local toolbarId = key:match('^toolbar%.(.+)$')
  if toolbarId then return chrome.toolbarRects()[toolbarId] end
  return anchors[key]
end

-- Each shortcut gets its own keycap chip ('/'-separated for multi-binding cmds);
-- chip width is floored relative to height so a lone glyph (, . `) reads as a key.
local CHIP_PADX, CHIP_R, SEP_GAP, CHIP_MIN_RATIO, CHIP_ALPHA = 4, 3, 4, 0.9, 0xcc
local SEP = '/'
local function withAlpha(rgba, a) return (rgba & 0xFFFFFF00) | a end

local function chipWidth(s, lineH)
  return math.max((ImGui.CalcTextSize(ctx, s)) + CHIP_PADX * 2, lineH * CHIP_MIN_RATIO)
end

local function clusterWidth(keys)
  local lineH = ImGui.GetTextLineHeight(ctx)
  local sepW, w = ImGui.CalcTextSize(ctx, SEP), 0
  for i, s in ipairs(keys) do
    if i > 1 then w = w + SEP_GAP * 2 + sepW end
    w = w + chipWidth(s, lineH)
  end
  return w
end

local function drawCluster(dl, keys, x, ty, lineH, capBg, capLine, keyCol, sepCol)
  local sepW, cur = ImGui.CalcTextSize(ctx, SEP), x
  for i, s in ipairs(keys) do
    if i > 1 then
      ImGui.DrawList_AddText(dl, cur + SEP_GAP, ty, sepCol, SEP)
      cur = cur + SEP_GAP * 2 + sepW
    end
    local cw = chipWidth(s, lineH)
    ImGui.DrawList_AddRectFilled(dl, cur, ty, cur + cw, ty + lineH, capBg, CHIP_R)
    ImGui.DrawList_AddRect(dl, cur, ty, cur + cw, ty + lineH, capLine, CHIP_R)
    local tw = ImGui.CalcTextSize(ctx, s)
    ImGui.DrawList_AddText(dl, cur + (cw - tw) / 2, ty, keyCol, s)
    cur = cur + cw
  end
end

local function groupRows(g)
  local rows, keyW = {}, 0
  for _, it in ipairs(g.items) do
    local keys = cmgr:keyLabelList(it.cmd, ImGui) or { EM_DASH }
    rows[#rows + 1] = { keys = keys, label = it.label }
    keyW = math.max(keyW, clusterWidth(keys))
  end
  return rows, keyW
end

local function boxSize(g, rows, keyW)
  local lineH = ImGui.GetTextLineHeight(ctx)
  local labelW = 0
  for _, row in ipairs(rows) do labelW = math.max(labelW, (ImGui.CalcTextSize(ctx, row.label))) end
  local titleW = ImGui.CalcTextSize(ctx, g.title)
  local w = math.max(titleW, keyW + KEY_GAP + labelW) + PAD * 2
  local h = PAD * 2 + lineH * (#rows + 1) + ROW_GAP * #rows
  return w, h, lineH
end

local function drawBox(dl, g, rows, keyW, x, y, w, h, lineH, theme)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, theme.bg, 4)
  ImGui.DrawList_AddRect(dl, x, y, x + w, y + h, theme.border, 4)
  local capBg   = withAlpha(theme.chip, CHIP_ALPHA)
  local capLine = withAlpha(theme.border, 0x66)
  local sepCol  = theme.key
  local ty = y + PAD
  ImGui.DrawList_AddText(dl, x + PAD, ty, theme.title, g.title)
  ty = ty + lineH + ROW_GAP
  for _, row in ipairs(rows) do
    drawCluster(dl, row.keys, x + PAD, ty, lineH, capBg, capLine, theme.key, sepCol)
    ImGui.DrawList_AddText(dl, x + PAD + keyW + KEY_GAP, ty, theme.label, row.label)
    ty = ty + lineH + ROW_GAP
  end
end

-- Pin callouts sit just under their toolbar segment. Overlapping neighbours are
-- slid to minimise total displacement — isotonic regression. See docs/help.md.
local function placePins(dl, pins, theme, wx, ww, boxes)
  if #pins == 0 then return end
  table.sort(pins, function(a, b) return a.px < b.px end)

  -- Removing each box's cumulative (width+gap) turns the no-overlap constraint
  -- x[i+1] >= x[i]+w[i]+gap into "the reduced positions must be non-decreasing".
  local offset, off, blocks = {}, 0, {}
  for i, p in ipairs(pins) do
    offset[i], off = off, off + p.w + BOX_GAP
    blocks[#blocks + 1] = { sum = p.px - offset[i], count = 1, value = p.px - offset[i] }
    while #blocks > 1 and blocks[#blocks - 1].value > blocks[#blocks].value do
      local last = table.remove(blocks)
      local prev = blocks[#blocks]
      prev.sum, prev.count = prev.sum + last.sum, prev.count + last.count
      prev.value = prev.sum / prev.count
    end
  end

  local xs, i = {}, 0
  for _, b in ipairs(blocks) do
    for _ = 1, b.count do i = i + 1; xs[i] = b.value + offset[i] end
  end

  -- One rigid shift to bring the run on-screen, as close to 0 as fits.
  local L = (wx + 2) - xs[1]
  local R = (wx + ww - 2) - (xs[#xs] + pins[#pins].w)
  local shift = math.max(L, math.min(0, R))

  for idx, p in ipairs(pins) do
    local x = xs[idx] + shift
    drawBox(dl, p.g, p.rows, p.keyW, x, p.y, p.w, p.h, p.lineH, theme)
    boxes[#boxes + 1] = { x = x, y = p.y, w = p.w, h = p.h }
  end
end

local dismissKeyList
local function buildDismissKeys()
  local ks = {}
  local function span(a, b) for k = a, b do ks[#ks + 1] = k end end
  span(ImGui.Key_A, ImGui.Key_Z);           span(ImGui.Key_0, ImGui.Key_9)
  span(ImGui.Key_Keypad0, ImGui.Key_Keypad9); span(ImGui.Key_F1, ImGui.Key_F12)
  for _, k in ipairs {
    ImGui.Key_Enter, ImGui.Key_KeypadEnter, ImGui.Key_Escape, ImGui.Key_Tab,
    ImGui.Key_Backspace, ImGui.Key_Delete, ImGui.Key_Space, ImGui.Key_Insert,
    ImGui.Key_UpArrow, ImGui.Key_DownArrow, ImGui.Key_LeftArrow, ImGui.Key_RightArrow,
    ImGui.Key_Home, ImGui.Key_End, ImGui.Key_PageUp, ImGui.Key_PageDown,
    ImGui.Key_Minus, ImGui.Key_KeypadSubtract, ImGui.Key_Comma, ImGui.Key_Period,
    ImGui.Key_Semicolon, ImGui.Key_Apostrophe, ImGui.Key_Slash,
  } do ks[#ks + 1] = k end
  return ks
end

-- Char queue catches punctuation/layout-specific keys; the explicit list covers
-- the non-printables (and alphanumerics, since the macOS char queue drops some).
local function anyKeyPressed()
  if (ImGui.GetInputQueueCharacter(ctx, 0)) then return true end
  dismissKeyList = dismissKeyList or buildDismissKeys()
  for _, k in ipairs(dismissKeyList) do
    if ImGui.IsKeyPressed(ctx, k) then return true end
  end
  return false
end

local function clickedOutside(boxes)
  if not (ImGui.IsMouseClicked(ctx, 0) or ImGui.IsMouseClicked(ctx, 1)
          or ImGui.IsMouseClicked(ctx, 2)) then return false end
  local mx, my = ImGui.GetMousePos(ctx)
  for _, b in ipairs(boxes) do
    if mx >= b.x and mx <= b.x + b.w and my >= b.y and my <= b.y + b.h then return false end
  end
  return true
end

function help:draw()
  if not open then return end
  local groups = current and pages[current]
  if not groups then return end

  local dl = ImGui.GetForegroundDrawList(ctx)
  local wx, wy = ImGui.GetWindowPos(ctx)
  local ww, wh = ImGui.GetWindowSize(ctx)
  ImGui.DrawList_AddRectFilled(dl, wx, wy, wx + ww, wy + wh, DIM_COL)

  local theme = {
    bg     = chrome.colour('help.box'),
    border = chrome.colour('help.border'),
    title  = chrome.colour('help.title'),
    key    = chrome.colour('help.key'),
    label  = chrome.colour('help.desc'),
    chip   = chrome.colour('help.chip'),
  }

  -- boxes: every drawn rect, for the off-box click test below.
  local boxes = {}

  local pins = {}
  for _, g in ipairs(groups) do
    if g.place ~= 'flow' then
      local r = rectFor(g.anchor)
      if r then
        local rows, keyW = groupRows(g)
        local w, h, lineH = boxSize(g, rows, keyW)
        pins[#pins + 1] = { g = g, rows = rows, keyW = keyW,
                            w = w, h = h, lineH = lineH, px = r.x, y = r.y + r.h + 4 }
      end
    end
  end
  placePins(dl, pins, theme, wx, ww, boxes)

  -- Flow groups fill the grid rect row-major: left to right, wrapping down a
  -- row at the rect's right edge.
  local flow = {}   -- anchorKey → { x, y, rowH }
  for _, g in ipairs(groups) do
    if g.place == 'flow' then
      local r = rectFor(g.anchor)
      if r then
        local rows, keyW = groupRows(g)
        local w, h, lineH = boxSize(g, rows, keyW)
        local fc = flow[g.anchor]
        if not fc then fc = { x = r.x + BOX_GAP, y = r.y + BOX_GAP, rowH = 0 }; flow[g.anchor] = fc end
        if fc.x + w > r.x + r.w and fc.x > r.x + BOX_GAP then
          fc.x, fc.y, fc.rowH = r.x + BOX_GAP, fc.y + fc.rowH + BOX_GAP, 0
        end
        drawBox(dl, g, rows, keyW, fc.x, fc.y, w, h, lineH, theme)
        boxes[#boxes + 1] = { x = fc.x, y = fc.y, w = w, h = h }
        fc.x = fc.x + w + BOX_GAP
        fc.rowH = math.max(fc.rowH, h)
      end
    end
  end

  -- Dismiss on any key or off-box click; gesture is swallowed (coordinator + page both
  -- gate on wasOpenAtFrameStart). Gated so the opening F1 doesn't instantly dismiss.
  if openAtStart and (anyKeyPressed() or clickedOutside(boxes)) then open = false end
end

return help
