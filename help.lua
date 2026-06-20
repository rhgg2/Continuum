-- See docs/help.md for the model.
-- F1 cheat-sheet: toolbar groups pin callouts under their segment; body groups flow row-major in the grid rect.

--shape: helpGroup = { anchor, title, place='pin'|'flow', items=[{cmd,label}] }
--invariant: anchors are frame-scoped — cleared each frame, repopulated by render code only while open
--invariant: edit state (editing/capturing/conflict) resets on overlay close or page change
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
local EM_DASH = '\xe2\x80\x94'

-- Edit-mode state: `editing` = cmd whose row shows ✕/+; `capturing` awaits a chord;
-- `conflict` = active collision prompt; `hits`/`conflictHits` per-frame click maps. See docs/help.md § Editing.
local editing, capturing, conflict, hits, conflictHits = nil, nil, nil, nil, nil
local function resetEdit() editing, capturing, conflict = nil, nil, nil end

local help = {}

----------- PUBLIC

function help:registerPage(name, groups) pages[name] = groups end
function help:setPage(name)              current = name; resetEdit() end
function help:isOpen()                   return open end
function help:close()                    open = false; resetEdit() end

-- Won't open on a page that declared no manifest, so F1 there is inert
-- rather than dimming the screen with nothing to show.
function help:toggle()
  open = (not open) and pages[current] ~= nil or false
  if not open then resetEdit() end
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
local CAPTURE_GLYPH = '\xe2\x80\xa6'   -- … (chip cue while capturing a replacement)
local TAG_SYM, TAG_PAD, ADD_GAP = 7, 1, 9   -- tag symbol px (odd -> centred +); moat inside the 1px border; gap before + tag
local function withAlpha(rgba, a) return (rgba & 0xFFFFFF00) | a end

-- Side of a square edit-tag box: the symbol plus a 2px moat and the 1px border.
local function tagSide() return TAG_SYM + (TAG_PAD + 1) * 2 end

-- Lay out a shortcut's chips ('/'-separated, one per binding) into geometry for
-- drawCluster: total width + each chip's {w, cells}; word runs share one cell, symbols one each.
local function layoutCluster(keys, withAdd)
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
  if withAdd then total = total + ADD_GAP + tagSide() end   -- room for the trailing + tag
  return { width = total, chips = chips }
end

-- Pixel-crisp 1px border (painter.border's 4-strip technique) on the foreground
-- drawlist the overlay uses: painter binds to the window drawlist, behind the dim.
local function crispBorder(x0, y0, x1, y1, colour)
  ImGui.DrawList_AddRectFilled(dl, x0,     y0,     x1,     y0 + 1, colour)
  ImGui.DrawList_AddRectFilled(dl, x0,     y1 - 1, x1,     y1,     colour)
  ImGui.DrawList_AddRectFilled(dl, x0,     y0,     x0 + 1, y1,     colour)
  ImGui.DrawList_AddRectFilled(dl, x1 - 1, y0,     x1,     y1,     colour)
end

-- Square edit tag at (cx, cy): fill + 1px border, symbol in a 2px moat (+ as
-- 1px strips, x as diagonal). `captureHere` highlights; `hit` rect filled here.
local function drawTag(cx, cy, symbol, ink, captureHere, hit)
  local side   = tagSide()
  local x0, y0 = math.floor(cx - side / 2 + 0.5), math.floor(cy - side / 2 + 0.5)
  local x1, y1 = x0 + side, y0 + side
  ImGui.DrawList_AddRectFilled(dl, x0, y0, x1, y1, theme.tag)
  crispBorder(x0, y0, x1, y1, captureHere and theme.title or theme.tagBorder)
  local colour = captureHere and theme.title or ink
  -- Symbol pixel box: side TAG_SYM, equal inset (1px border + moat) on every edge.
  local inset    = TAG_PAD + 1
  local sx0, sy0 = x0 + inset, y0 + inset
  local sx1, sy1 = sx0 + TAG_SYM, sy0 + TAG_SYM
  if symbol == 'x' then                              -- inclusive endpoints stay inside the box
    ImGui.DrawList_AddLine(dl, sx0, sy0, sx1 - 1, sy1 - 1, colour, 1)
    ImGui.DrawList_AddLine(dl, sx0, sy1 - 1, sx1 - 1, sy0, colour, 1)
  else                                               -- 1px strips through the centre pixel (TAG_SYM odd)
    local midX, midY = sx0 + (TAG_SYM - 1) // 2, sy0 + (TAG_SYM - 1) // 2
    ImGui.DrawList_AddRectFilled(dl, midX, sy0, midX + 1, sy1, colour)
    ImGui.DrawList_AddRectFilled(dl, sx0, midY, sx1, midY + 1, colour)
  end
  hit.x, hit.y, hit.w, hit.h = x0, y0, side, side
  util.add(hits, hit)
end

-- Records a click hit per chip; in edit mode also draws the ✕ corner tags and the
-- trailing + tag, each with its own hit. See docs/help.md § Editing.
local function drawCluster(cluster, x, y, cmd, specs)
  local sepW, cursorX = ImGui.CalcTextSize(ctx, SEP), x
  local isEditing = cmd == editing
  local isCapture = capturing ~= nil and capturing.cmd == cmd
  for index, chip in ipairs(cluster.chips) do
    if index > 1 then
      ImGui.DrawList_AddText(dl, cursorX + SEP_GAP, y, theme.key, SEP)
      cursorX = cursorX + SEP_GAP * 2 + sepW
    end
    local spec = specs[index]
    local x2   = cursorX + chip.w
    local captureHere = isCapture and spec ~= nil and spec == capturing.replace
    ImGui.DrawList_AddRectFilled(dl, cursorX, y, x2, y + lineH, capBg, CHIP_R)
    ImGui.DrawList_AddRect(dl, cursorX, y, x2, y + lineH, captureHere and theme.title or capLine, CHIP_R)
    if captureHere then
      local glyphW = ImGui.CalcTextSize(ctx, CAPTURE_GLYPH)
      ImGui.DrawList_AddText(dl, cursorX + (chip.w - glyphW) / 2, y, theme.title, CAPTURE_GLYPH)
    else
      local glyphX = cursorX + CHIP_PADX_OUTER
      for _, cell in ipairs(chip.cells) do
        local textW = ImGui.CalcTextSize(ctx, cell.text)
        ImGui.DrawList_AddText(dl, glyphX + (cell.w - textW) / 2, y, theme.key, cell.text)
        glyphX = glyphX + cell.w
      end
    end
    util.add(hits, { x = cursorX, y = y, w = chip.w, h = lineH, kind = 'chip', cmd = cmd, spec = spec })
    if isEditing and spec ~= nil then
      drawTag(x2+2, y, 'x', theme.remove, false, { kind = 'remove', cmd = cmd, spec = spec })
    end
    cursorX = x2
  end
  if isEditing then
    drawTag(cursorX + ADD_GAP + tagSide() / 2, y + lineH / 2, '+', theme.add,
            isCapture and capturing.replace == nil, { kind = 'add', cmd = cmd })
  end
end

-- A group's box geometry in one pass: rows (each with a laid-out cluster) plus the
-- box w/h, sized to the wider of the title vs the shortcut column + widest label.
local function layoutBox(group)
  local rows, keyW, labelW = {}, 0, 0
  for _, item in ipairs(group.items) do
    local editingRow = item.cmd == editing
    local labels  = cmgr:keyLabelList(item.cmd, ImGui)
    local cluster = layoutCluster(labels or (editingRow and {} or { EM_DASH }), editingRow)
    util.add(rows, { cluster = cluster, label = item.label,
                     cmd = item.cmd, specs = cmgr:keysFor(item.cmd) or {} })
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
    drawCluster(row.cluster, x + PAD, rowY, row.cmd, row.specs)
    ImGui.DrawList_AddText(dl, x + PAD + box.keyW + KEY_GAP, rowY, theme.label, row.label)
    rowY = rowY + lineH + ROW_GAP
  end
end

-- A command's human label from the current page's manifest, else its raw name (a
-- victim may live on another scope/page, where no manifest label is to hand).
local function cmdLabel(cmd)
  for _, group in ipairs(current and pages[current] or {}) do
    for _, item in ipairs(group.items) do
      if item.cmd == cmd then return item.label end
    end
  end
  return cmd
end

local PROMPT_PAD, BTN_PADX, BTN_GAP, LINE_GAP = 10, 10, 8, 4

-- Centred modal for a chord collision. Warn phase offers Cancel/Reassign; recover
-- phase narrates the victim's loss while pollCapture claims a new chord for it.
local function drawConflict(winX, winY, winW, winH)
  conflictHits = {}
  local chord = cmgr:keyLabel(conflict.spec, ImGui)
  local warn  = conflict.phase == 'warn'
  local line1, line2, buttons
  if warn then
    line1   = chord .. '  is  ' .. cmdLabel(conflict.victim)
    line2   = 'Reassign to ' .. cmdLabel(conflict.cmd) .. '?'
    buttons = { { kind = 'cancel', text = 'Cancel' }, { kind = 'reassign', text = 'Reassign' } }
  else
    line1   = cmdLabel(conflict.victim) .. '  lost  ' .. chord
    line2   = 'Press a new chord  ' .. EM_DASH .. '  Esc leaves it unbound'
    buttons = {}
  end

  local w1, w2 = ImGui.CalcTextSize(ctx, line1), ImGui.CalcTextSize(ctx, line2)
  local btnH, btnW, totalBtnW = lineH + 6, {}, 0
  for i, button in ipairs(buttons) do
    btnW[i]   = ImGui.CalcTextSize(ctx, button.text) + BTN_PADX * 2
    totalBtnW = totalBtnW + btnW[i] + (i > 1 and BTN_GAP or 0)
  end
  local boxW = math.max(w1, w2, totalBtnW) + PROMPT_PAD * 2
  local boxH = PROMPT_PAD + lineH + LINE_GAP + lineH
             + (#buttons > 0 and PROMPT_PAD + btnH or 0) + PROMPT_PAD
  local x0   = math.floor(winX + (winW - boxW) / 2)
  local y0   = math.floor(winY + (winH - boxH) / 2)
  local x1, y1 = x0 + boxW, y0 + boxH

  ImGui.DrawList_AddRectFilled(dl, x0, y0, x1, y1, theme.bg, BOX_R)
  ImGui.DrawList_AddRect(dl, x0, y0, x1, y1, theme.border, BOX_R)
  local rowY = y0 + PROMPT_PAD
  ImGui.DrawList_AddText(dl, x0 + (boxW - w1) / 2, rowY, theme.title, line1)
  rowY = rowY + lineH + LINE_GAP
  ImGui.DrawList_AddText(dl, x0 + (boxW - w2) / 2, rowY, theme.label, line2)

  local btnY, bx = y1 - PROMPT_PAD - btnH, x0 + math.floor((boxW - totalBtnW) / 2)
  for i, button in ipairs(buttons) do
    local bw = btnW[i]
    ImGui.DrawList_AddRectFilled(dl, bx, btnY, bx + bw, btnY + btnH, capBg, CHIP_R)
    ImGui.DrawList_AddRect(dl, bx, btnY, bx + bw, btnY + btnH, capLine, CHIP_R)
    local tw = ImGui.CalcTextSize(ctx, button.text)
    ImGui.DrawList_AddText(dl, bx + (bw - tw) / 2, btnY + 3, theme.title, button.text)
    util.add(conflictHits, { x = bx, y = btnY, w = bw, h = btnH, kind = button.kind })
    bx = bx + bw + BTN_GAP
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
    ImGui.Key_Minus, ImGui.Key_KeypadSubtract, ImGui.Key_Equal, ImGui.Key_Comma,
    ImGui.Key_Period, ImGui.Key_Semicolon, ImGui.Key_Apostrophe, ImGui.Key_Slash,
    ImGui.Key_LeftBracket, ImGui.Key_RightBracket, ImGui.Key_GraveAccent, ImGui.Key_Backslash,
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

local function insideAnyBox(mouseX, mouseY)
  for _, box in ipairs(boxes) do
    if mouseX >= box.x and mouseX <= box.x + box.w
       and mouseY >= box.y and mouseY <= box.y + box.h then return true end
  end
  return false
end

----------- EDIT MODE

-- A pressed non-modifier key plus the live modifier mask, as a cmgr keyspec.
local function buildSpec(key, mods)
  if mods == ImGui.Mod_None then return key end
  local spec = { key }
  for _, mod in ipairs{ ImGui.Mod_Ctrl, ImGui.Mod_Shift, ImGui.Mod_Alt, ImGui.Mod_Super } do
    if (mods & mod) ~= 0 then spec[#spec + 1] = mod end
  end
  return spec
end

-- Rewrites cmd's bindings: drop `drop` (a spec ref, or nil), append `add` (or nil).
local function rebindWithout(cmd, drop, add)
  local specs = {}
  for _, spec in ipairs(cmgr:keysFor(cmd) or {}) do
    if spec ~= drop then specs[#specs + 1] = spec end
  end
  if add then specs[#specs + 1] = add end
  cmgr:rebind(cmgr:bindingSite(cmd), cmd, specs, ImGui)
end

-- Drops every binding of cmd whose chord matches spec, then rebinds. The victim's
-- stored ref isn't the captured one, so match by resolved key+mods, not identity.
local function dropChord(cmd, spec)
  local key, mods = cmgr:keySpec(spec, ImGui)
  local kept = {}
  for _, bound in ipairs(cmgr:keysFor(cmd) or {}) do
    local boundKey, boundMods = cmgr:keySpec(bound, ImGui)
    if not (boundKey == key and boundMods == mods) then kept[#kept + 1] = bound end
  end
  cmgr:rebind(cmgr:bindingSite(cmd), cmd, kept, ImGui)
end

-- A captured chord that collides with a reachable command opens the warn prompt;
-- a free chord binds straight away. See docs/help.md § Editing.
local function commitCapture(spec)
  local cmd, replace = capturing.cmd, capturing.replace
  capturing = nil
  local victim = cmgr:commandAtKey(spec, cmd, ImGui)
  if victim then
    conflict = { phase = 'warn', cmd = cmd, victim = victim, spec = spec, replace = replace }
  else
    rebindWithout(cmd, replace, spec)
    editing, conflict = cmd, nil
  end
end

-- Reassign: strip the chord from the victim, give it to cmd, then drop the victim
-- into a recovery capture so it can claim a new chord (Esc leaves it unbound).
local function reassign()
  local cmd, victim, spec, replace = conflict.cmd, conflict.victim, conflict.spec, conflict.replace
  dropChord(victim, spec)
  rebindWithout(cmd, replace, spec)
  editing, capturing = victim, { cmd = victim }
  conflict = { phase = 'recover', victim = victim, spec = spec }
end

local function pollCapture()
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then capturing, conflict = nil, nil; return end
  dismissKeyList = dismissKeyList or buildDismissKeys()
  local mods = ImGui.GetKeyMods(ctx)
  for _, key in ipairs(dismissKeyList) do
    if key ~= ImGui.Key_Escape and ImGui.IsKeyPressed(ctx, key) then
      commitCapture(buildSpec(key, mods))
      return
    end
  end
end

-- ✕ sits atop its chip, so a remove hit wins over the chip hit it overlaps.
local function hitAt(mouseX, mouseY)
  local rank, best = { remove = 3, add = 2, chip = 1 }, nil
  for _, hit in ipairs(hits) do
    if mouseX >= hit.x and mouseX <= hit.x + hit.w
       and mouseY >= hit.y and mouseY <= hit.y + hit.h
       and (not best or rank[hit.kind] > rank[best.kind]) then best = hit end
  end
  return best
end

-- Warn-phase input: Esc/Cancel abandons untouched, Enter or the Reassign button
-- commits. Off-button clicks are swallowed (modal), never dismissing the sheet.
local function handleConflict()
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then conflict = nil; return end
  local accept = ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
              or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)
  if not accept and ImGui.IsMouseClicked(ctx, 0) then
    local mouseX, mouseY = ImGui.GetMousePos(ctx)
    for _, hit in ipairs(conflictHits) do
      if mouseX >= hit.x and mouseX <= hit.x + hit.w
         and mouseY >= hit.y and mouseY <= hit.y + hit.h then
        if hit.kind == 'cancel' then conflict = nil; return end
        accept = true
      end
    end
  end
  if accept then reassign() end
end

local function handleClicks()
  if not (ImGui.IsMouseClicked(ctx, 0) or ImGui.IsMouseClicked(ctx, 1)
          or ImGui.IsMouseClicked(ctx, 2)) then return end
  local mouseX, mouseY = ImGui.GetMousePos(ctx)
  local hit = hitAt(mouseX, mouseY)
  if hit then
    if     hit.kind == 'remove' then rebindWithout(hit.cmd, hit.spec)
    elseif hit.kind == 'add'    then editing, capturing = hit.cmd, { cmd = hit.cmd }
    elseif editing == hit.cmd   then capturing = { cmd = hit.cmd, replace = hit.spec }
    else                             editing = hit.cmd end
  elseif not insideAnyBox(mouseX, mouseY) then
    open = false; resetEdit()
  end
end

function help:draw()
  if not open then return end
  local groups = current and pages[current]
  if not groups then return end

  dl    = ImGui.GetForegroundDrawList(ctx)
  lineH = ImGui.GetTextLineHeight(ctx)
  local winX, winY = ImGui.GetWindowPos(ctx)
  local winW, winH = ImGui.GetWindowSize(ctx)
  ImGui.DrawList_AddRectFilled(dl, winX, winY, winX + winW, winY + winH, chrome.colour('help.dim'))

  theme = {
    bg     = chrome.colour('help.box'),
    border = chrome.colour('help.border'),
    title  = chrome.colour('help.title'),
    key    = chrome.colour('help.key'),
    label  = chrome.colour('help.desc'),
    chip   = chrome.colour('help.chip'),
    remove = chrome.colour('help.remove'),
    add    = chrome.colour('help.add'),
    tag       = chrome.colour('help.tag'),
    tagBorder = chrome.colour('help.tagBorder'),
  }
  capBg   = withAlpha(theme.chip, CHIP_ALPHA)
  capLine = withAlpha(theme.border, 0x66)
  boxes   = {}   -- every drawn rect, for the off-box click test below
  hits    = {}   -- per-frame click map (chips, ✕, +); rebuilt by drawCluster

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
  if conflict then drawConflict(winX, winY, winW, winH) end

  -- A conflict prompt is modal; else edit mode owns the keyboard (capture chords, Esc
  -- steps out); else any key / off-box click dismisses. See docs/help.md § Editing.
  if conflict and conflict.phase == 'warn' then
    handleConflict()
  elseif capturing then
    pollCapture()
  elseif editing and ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
    editing = nil
  else
    handleClicks()
    if openAtStart and not editing and anyKeyPressed() then open = false end
  end
end

return help
