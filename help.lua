-- See docs/help.md for the model.
--
-- The F1 keybinding cheat-sheet. Reads live bindings from cmgr and the
-- active page's declared help groups, then draws labelled callouts over the
-- UI: toolbar groups pin a callout beneath their segment (rect supplied by
-- chrome.toolbarRects()); body groups flow into a packed panel inside the
-- grid rect (rect supplied by render code via help:anchor).

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

function help:beginFrame() anchors = {} end

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

local function groupRows(g)
  local rows, keyW = {}, 0
  for _, it in ipairs(g.items) do
    local key = cmgr:keyLabels(it.cmd, ImGui) or EM_DASH
    rows[#rows + 1] = { key = key, label = it.label }
    keyW = math.max(keyW, (ImGui.CalcTextSize(ctx, key)))
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
  local ty = y + PAD
  ImGui.DrawList_AddText(dl, x + PAD, ty, theme.title, g.title)
  ty = ty + lineH + ROW_GAP
  for _, row in ipairs(rows) do
    ImGui.DrawList_AddText(dl, x + PAD, ty, theme.key, row.key)
    ImGui.DrawList_AddText(dl, x + PAD + keyW + KEY_GAP, ty, theme.label, row.label)
    ty = ty + lineH + ROW_GAP
  end
end

local function intersects(a, x, y, w, h)
  return x < a.x + a.w and x + w > a.x and y < a.y + a.h and y + h > a.y
end

-- Slide a box straight down past any already-placed box it would cover, so
-- adjacent toolbar callouts cascade instead of stacking on top of each other.
local function avoid(x, y, w, h, placed)
  local moved = true
  while moved do
    moved = false
    for _, a in ipairs(placed) do
      if intersects(a, x, y, w, h) then y, moved = a.y + a.h + BOX_GAP, true end
    end
  end
  return y
end

function help:draw()
  if not open then return end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then open = false; return end
  local groups = current and pages[current]
  if not groups then return end

  local dl = ImGui.GetForegroundDrawList(ctx)
  local wx, wy = ImGui.GetWindowPos(ctx)
  local ww, wh = ImGui.GetWindowSize(ctx)
  ImGui.DrawList_AddRectFilled(dl, wx, wy, wx + ww, wy + wh, DIM_COL)

  local theme = {
    bg     = chrome.colour('statusBar.bg'),
    border = chrome.colour('text'),
    title  = chrome.colour('text'),
    key    = chrome.colour('text'),
    label  = chrome.colour('statusBar.text'),
  }

  -- Flow groups pack into columns within their anchor rect; a per-anchor
  -- cursor stacks boxes downward, wrapping to a new column on overflow.
  local flow   = {}   -- anchorKey → { x, y, colW }
  local placed = {}   -- every box drawn so far, for collision avoidance

  -- Pins (pinPass=true) place first so the body's flow boxes can dodge any
  -- callout that hangs down into the grid rect.
  local function place(g, pinPass)
    local r = rectFor(g.anchor)
    if not r or (g.place ~= 'flow') ~= pinPass then return end
    local rows, keyW = groupRows(g)
    local w, h, lineH = boxSize(g, rows, keyW)
    if pinPass then
      local x = math.min(r.x, wx + ww - w - 2)
      local y = r.y + r.h + 4
      if y + h > wy + wh then y = r.y - h - 4 end
      y = avoid(x, y, w, h, placed)
      drawBox(dl, g, rows, keyW, x, y, w, h, lineH, theme)
      placed[#placed + 1] = { x = x, y = y, w = w, h = h }
    else
      local fc = flow[g.anchor]
      if not fc then fc = { x = r.x + BOX_GAP, y = r.y + BOX_GAP, colW = 0 }; flow[g.anchor] = fc end
      if fc.y + h > r.y + r.h and fc.y > r.y + BOX_GAP then
        fc.x, fc.y, fc.colW = fc.x + fc.colW + BOX_GAP, r.y + BOX_GAP, 0
      end
      local y = avoid(fc.x, fc.y, w, h, placed)
      drawBox(dl, g, rows, keyW, fc.x, y, w, h, lineH, theme)
      placed[#placed + 1] = { x = fc.x, y = y, w = w, h = h }
      fc.colW = math.max(fc.colW, w)
      fc.y = y + h + BOX_GAP
    end
  end
  for _, g in ipairs(groups) do place(g, true)  end
  for _, g in ipairs(groups) do place(g, false) end
end

return help
