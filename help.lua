-- See docs/help.md for the model.
-- F1 cheat-sheet: toolbar groups pin callouts under their segment; body groups flow row-major in the grid rect.

--shape: helpGroup = { anchor, title, place='pin'|'flow', items=[{cmd,label}] }
--invariant: anchors are frame-scoped — cleared each frame, repopulated by render code only while open
--contract: 'toolbar.<id>' anchors resolve through chrome.toolbarRects(); others via help:anchor
local ImGui = require 'imgui' '0.10'
local util  = require 'util'

local ctx    = (...).ctx
local chrome = (...).chrome
local cmgr   = (...).cmgr

local pages   = {}    -- pageName → groups
local anchors = {}    -- key → { x, y, w, h }
local current = nil
local open    = false
local openAtStart = false   -- open as of frame start; gates dismissal + page input swallow

local PAD, ROW_GAP, KEY_GAP, BOX_GAP = 6, 2, 12, 8
local PIN_GAP, WIN_MARGIN, BOX_R = 4, 2, 4   -- pin drop below segment; window-edge inset; box corner radius
local DIM_COL = 0x00000077
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

-- Per-frame draw state: set at the top of help:draw, read by the helpers below.
local dl, lineH, theme, capBg, capLine, boxes

local function rectFor(key)
  local toolbarId = key:match('^toolbar%.(.+)$')
  if toolbarId then return chrome.toolbarRects()[toolbarId] end
  return anchors[key]
end

-- Each shortcut gets its own keycap chip ('/'-separated for multi-binding cmds);
-- symbol glyphs are floored to a square (so , . ` read as keys), word labels stay natural.
local CHIP_PADX_INNER, CHIP_PADX_OUTER, CHIP_R, SEP_GAP, CHIP_MIN_RATIO, CHIP_ALPHA = 0, 2, 3, 4, 0.9, 0xcc
local SEP = '/'
local function withAlpha(rgba, a) return (rgba & 0xFFFFFF00) | a end

-- Lay out a shortcut's chips ('/'-separated, one per binding) into geometry for
-- drawCluster: total width + each chip's {w, cells}; word runs share one cell, symbols one each.
local function layoutCluster(keys)
  local sepW, chips, total = ImGui.CalcTextSize(ctx, SEP), {}, 0
  for index, chord in ipairs(keys) do
    local cells, chipW, run = {}, CHIP_PADX_OUTER * 2, nil
    local function cell(text)
      local cellW = math.max((ImGui.CalcTextSize(ctx, text)) + CHIP_PADX_INNER, lineH * CHIP_MIN_RATIO)
      util.add(cells, { text = text, w = cellW })
      chipW = chipW + cellW
    end
    for _, code in utf8.codes(chord) do
      local glyph = utf8.char(code)
      if #glyph == 1 and glyph:match('%w') then
        run = (run or '') .. glyph
      else
        if run then cell(run); run = nil end
        cell(glyph)
      end
    end
    if run then cell(run) end
    util.add(chips, { w = chipW, cells = cells })
    total = total + chipW + (index > 1 and SEP_GAP * 2 + sepW or 0)
  end
  return { width = total, chips = chips }
end

local function drawCluster(cluster, x, y)
  local sepW, cursorX = ImGui.CalcTextSize(ctx, SEP), x
  for index, chip in ipairs(cluster.chips) do
    if index > 1 then
      ImGui.DrawList_AddText(dl, cursorX + SEP_GAP, y, theme.key, SEP)
      cursorX = cursorX + SEP_GAP * 2 + sepW
    end
    ImGui.DrawList_AddRectFilled(dl, cursorX, y, cursorX + chip.w, y + lineH, capBg, CHIP_R)
    ImGui.DrawList_AddRect(dl, cursorX, y, cursorX + chip.w, y + lineH, capLine, CHIP_R)
    local glyphX = cursorX + CHIP_PADX_OUTER
    for _, cell in ipairs(chip.cells) do
      local textW = ImGui.CalcTextSize(ctx, cell.text)
      ImGui.DrawList_AddText(dl, glyphX + (cell.w - textW) / 2, y, theme.key, cell.text)
      glyphX = glyphX + cell.w
    end
    cursorX = cursorX + chip.w
  end
end

-- A group's box geometry in one pass: rows (each with a laid-out cluster) plus the
-- box w/h, sized to the wider of the title vs the shortcut column + widest label.
local function layoutBox(group)
  local rows, keyW, labelW = {}, 0, 0
  for _, item in ipairs(group.items) do
    local cluster = layoutCluster(cmgr:keyLabelList(item.cmd, ImGui) or { EM_DASH })
    util.add(rows, { cluster = cluster, label = item.label })
    keyW   = math.max(keyW, cluster.width)
    labelW = math.max(labelW, (ImGui.CalcTextSize(ctx, item.label)))
  end
  local titleW = ImGui.CalcTextSize(ctx, group.title)
  local w = math.max(titleW, keyW + KEY_GAP + labelW) + PAD * 2
  local h = PAD * 2 + lineH * (#rows + 1) + ROW_GAP * #rows
  return { title = group.title, rows = rows, keyW = keyW, w = w, h = h }
end

local function drawBox(box, x, y)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + box.w, y + box.h, theme.bg, BOX_R)
  ImGui.DrawList_AddRect(dl, x, y, x + box.w, y + box.h, theme.border, BOX_R)
  local rowY = y + PAD
  ImGui.DrawList_AddText(dl, x + PAD, rowY, theme.title, box.title)
  rowY = rowY + lineH + ROW_GAP
  for _, row in ipairs(box.rows) do
    drawCluster(row.cluster, x + PAD, rowY)
    ImGui.DrawList_AddText(dl, x + PAD + box.keyW + KEY_GAP, rowY, theme.label, row.label)
    rowY = rowY + lineH + ROW_GAP
  end
end

-- Pin callouts sit just under their toolbar segment. Overlapping neighbours are
-- slid to minimise total displacement — isotonic regression. See docs/help.md.
local function placePins(pins, winX, winW)
  if #pins == 0 then return end
  table.sort(pins, function(pinA, pinB) return pinA.wantX < pinB.wantX end)

  -- Removing each box's cumulative (width+gap) turns the no-overlap constraint
  -- x[i+1] >= x[i]+w[i]+gap into "the reduced positions must be non-decreasing".
  local offset, runWidth, blocks = {}, 0, {}
  for index, pin in ipairs(pins) do
    offset[index], runWidth = runWidth, runWidth + pin.box.w + BOX_GAP
    util.add(blocks, { sum = pin.wantX - offset[index], count = 1, value = pin.wantX - offset[index] })
    while #blocks > 1 and blocks[#blocks - 1].value > blocks[#blocks].value do
      local last = table.remove(blocks)
      local prev = blocks[#blocks]
      prev.sum, prev.count = prev.sum + last.sum, prev.count + last.count
      prev.value = prev.sum / prev.count
    end
  end

  local xs, index = {}, 0
  for _, block in ipairs(blocks) do
    for _ = 1, block.count do index = index + 1; xs[index] = block.value + offset[index] end
  end

  -- One rigid shift to bring the run on-screen, as close to 0 as fits.
  local leftShift  = (winX + WIN_MARGIN) - xs[1]
  local rightShift = (winX + winW - WIN_MARGIN) - (xs[#xs] + pins[#pins].box.w)
  local shift = math.max(leftShift, math.min(0, rightShift))

  for i, pin in ipairs(pins) do
    local x = xs[i] + shift
    drawBox(pin.box, x, pin.top)
    util.add(boxes, { x = x, y = pin.top, w = pin.box.w, h = pin.box.h })
  end
end

-- Flow groups fill their grid rect row-major: left to right, wrapping down a row
-- at the rect's right edge. Each anchor rect carries its own cursor.
local function placeFlow(flows)
  local cursors = {}   -- anchorKey → { x, y, rowH }
  for _, flow in ipairs(flows) do
    local rect, box = flow.rect, flow.box
    local cursor = cursors[flow.anchor]
    if not cursor then
      cursor = { x = rect.x + BOX_GAP, y = rect.y + BOX_GAP, rowH = 0 }
      cursors[flow.anchor] = cursor
    end
    if cursor.x + box.w > rect.x + rect.w and cursor.x > rect.x + BOX_GAP then
      cursor.x, cursor.y, cursor.rowH = rect.x + BOX_GAP, cursor.y + cursor.rowH + BOX_GAP, 0
    end
    drawBox(box, cursor.x, cursor.y)
    util.add(boxes, { x = cursor.x, y = cursor.y, w = box.w, h = box.h })
    cursor.x = cursor.x + box.w + BOX_GAP
    cursor.rowH = math.max(cursor.rowH, box.h)
  end
end

local dismissKeyList
local function buildDismissKeys()
  local keys = {}
  local function span(from, to) for key = from, to do util.add(keys, key) end end
  span(ImGui.Key_A, ImGui.Key_Z);           span(ImGui.Key_0, ImGui.Key_9)
  span(ImGui.Key_Keypad0, ImGui.Key_Keypad9); span(ImGui.Key_F1, ImGui.Key_F12)
  for _, key in ipairs {
    ImGui.Key_Enter, ImGui.Key_KeypadEnter, ImGui.Key_Escape, ImGui.Key_Tab,
    ImGui.Key_Backspace, ImGui.Key_Delete, ImGui.Key_Space, ImGui.Key_Insert,
    ImGui.Key_UpArrow, ImGui.Key_DownArrow, ImGui.Key_LeftArrow, ImGui.Key_RightArrow,
    ImGui.Key_Home, ImGui.Key_End, ImGui.Key_PageUp, ImGui.Key_PageDown,
    ImGui.Key_Minus, ImGui.Key_KeypadSubtract, ImGui.Key_Comma, ImGui.Key_Period,
    ImGui.Key_Semicolon, ImGui.Key_Apostrophe, ImGui.Key_Slash,
  } do util.add(keys, key) end
  return keys
end

-- Char queue catches punctuation/layout-specific keys; the explicit list covers
-- the non-printables (and alphanumerics, since the macOS char queue drops some).
local function anyKeyPressed()
  if (ImGui.GetInputQueueCharacter(ctx, 0)) then return true end
  dismissKeyList = dismissKeyList or buildDismissKeys()
  for _, key in ipairs(dismissKeyList) do
    if ImGui.IsKeyPressed(ctx, key) then return true end
  end
  return false
end

local function clickedOutside()
  if not (ImGui.IsMouseClicked(ctx, 0) or ImGui.IsMouseClicked(ctx, 1)
          or ImGui.IsMouseClicked(ctx, 2)) then return false end
  local mouseX, mouseY = ImGui.GetMousePos(ctx)
  for _, box in ipairs(boxes) do
    if mouseX >= box.x and mouseX <= box.x + box.w
       and mouseY >= box.y and mouseY <= box.y + box.h then return false end
  end
  return true
end

function help:draw()
  if not open then return end
  local groups = current and pages[current]
  if not groups then return end

  dl    = ImGui.GetForegroundDrawList(ctx)
  lineH = ImGui.GetTextLineHeight(ctx)
  local winX, winY = ImGui.GetWindowPos(ctx)
  local winW, winH = ImGui.GetWindowSize(ctx)
  ImGui.DrawList_AddRectFilled(dl, winX, winY, winX + winW, winY + winH, DIM_COL)

  theme = {
    bg     = chrome.colour('help.box'),
    border = chrome.colour('help.border'),
    title  = chrome.colour('help.title'),
    key    = chrome.colour('help.key'),
    label  = chrome.colour('help.desc'),
    chip   = chrome.colour('help.chip'),
  }
  capBg   = withAlpha(theme.chip, CHIP_ALPHA)
  capLine = withAlpha(theme.border, 0x66)
  boxes   = {}   -- every drawn rect, for the off-box click test below

  -- One pass lays out every visible group's box; pins then place collision-avoided
  -- under their segment, flow boxes wrap within their grid rect.
  local pins, flows = {}, {}
  for _, group in ipairs(groups) do
    local rect = rectFor(group.anchor)
    if rect then
      local box = layoutBox(group)
      if group.place == 'flow' then
        util.add(flows, { box = box, rect = rect, anchor = group.anchor })
      else
        util.add(pins, { box = box, wantX = rect.x, top = rect.y + rect.h + PIN_GAP })
      end
    end
  end
  placePins(pins, winX, winW)
  placeFlow(flows)

  -- Dismiss on any key or off-box click; gesture is swallowed (coordinator + page both
  -- gate on wasOpenAtFrameStart). Gated so the opening F1 doesn't instantly dismiss.
  if openAtStart and (anyKeyPressed() or clickedOutside()) then open = false end
end

return help
