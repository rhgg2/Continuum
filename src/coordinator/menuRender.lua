-- See docs/menu.md § The row for the model.
-- @noindex

-- The open menu's row: level strip on the body's last row, preview above it.
-- See docs/menu.md § The row.

local ImGui   = require 'imgui' '0.10'
local keycaps = require 'keycaps'
local util    = require 'util'

local ctx    = (...).ctx
local chrome = (...).chrome
local menu   = (...).menu

local PAD, ROW_GAP = 9, 8             -- the strip's inset; between wrapped lines
local LETTER_GAP, MEMBER_GAP = 4, 12  -- keycap to title; member to member
local HL_PAD_X, HL_PAD_Y = 3, 3       -- the highlight fill's reach past its member
local PREVIEW_WASH = 0.45             -- the preview's chips: keys not pressable from here

local menuRender = {}

--shape: item = { title, cluster?, w, x } -- one drawn member, placed by pack

-- Measured items packed greedily into lines of the given width; lines read top to bottom,
-- so an overflowing line grows upward from the floor.
local function pack(items, width)
  local lines, line, cursor = {}, {}, 0
  local limit = width - PAD * 2
  for _, item in ipairs(items) do
    if #line > 0 and cursor + item.w > limit then
      util.add(lines, line)
      line, cursor = {}, 0
    end
    item.x = cursor
    util.add(line, item)
    cursor = cursor + item.w + MEMBER_GAP
  end
  if #line > 0 then util.add(lines, line) end
  return lines
end

-- A line of members: each letter in the caps it was given, its title beside it.
local function memberItems(caps, members)
  local items = {}
  for _, member in ipairs(members) do
    local cluster = caps.cluster({ member.letter })
    util.add(items, { title = member.title, cluster = cluster,
                      w = cluster.width + LETTER_GAP + (ImGui.CalcTextSize(ctx, member.title)) })
  end
  return items
end

-- What the line above the level holds: a highlighted group's own members, in washed caps
-- since their letters are not pressable yet, or a highlighted leaf's description alone.
local function previewItems(caps, member)
  if not member then return {} end
  if not member.node then
    return { { title = member.desc, w = (ImGui.CalcTextSize(ctx, member.desc)) } }
  end
  return memberItems(caps, menu:lookahead())
end

-- A plain band to the window's margins, ruled along its top edge. ReaImGui's AddLine is
-- anti-aliased with no per-call toggle, so a 1px filled rect stands in for the rule (masterMix's idiom).
local function strip(dl, x0, top, x1, bottom)
  ImGui.DrawList_AddRectFilled(dl, x0, top, x1, bottom, chrome.colour('help.box'))
  local rule = chrome.colour('menu.rule')
  ImGui.DrawList_AddRectFilled(dl, x0, top,        x1, top + 1, rule)
end

-- The cheat-sheet's colours, so a letter reads as a key in both places.
local function menuTheme()
  return { bg     = chrome.colour('help.box'),   border = chrome.colour('help.border'),
           title  = chrome.colour('help.title'), key    = chrome.colour('help.key'),
           label  = chrome.colour('help.desc'),  chip   = chrome.colour('help.chip') }
end

-- A member as drawn: its keycap, then its title. An item with no keycap is a description,
-- which opens at the member column.
local function drawItem(dl, caps, item, x, y)
  local titleX = x
  if item.cluster then
    caps.drawCluster(item.cluster, x, y)
    titleX = x + item.cluster.width + LETTER_GAP
  end
  ImGui.DrawList_AddText(dl, titleX, y, chrome.colour('help.desc'), item.title)
end

--contract: draws the open menu's level and its preview on a `width` strip standing on `bottom`
function menuRender:draw(x, bottom, width)
  if not menu:isOpen() then return end
  local dl    = ImGui.GetForegroundDrawList(ctx)
  local lineH = ImGui.GetTextLineHeight(ctx)
  local caps    = keycaps.new(ctx, dl, menuTheme())
  local washed  = keycaps.new(ctx, dl, menuTheme(), PREVIEW_WASH)
  local members, highlight = menu:level(), menu:highlight()
  local levelLines = pack(memberItems(caps, members), width)
  if #levelLines == 0 then return end
  local previewLines = pack(previewItems(washed, members[highlight]), width)

  local count = #levelLines + #previewLines
  local top   = bottom - PAD * 2 - count * lineH - (count - 1) * ROW_GAP
  strip(dl, x, top, x + width, bottom)

  local rowY = top + PAD
  for _, line in ipairs(previewLines) do
    for _, item in ipairs(line) do drawItem(dl, washed, item, x + PAD + item.x, rowY) end
    rowY = rowY + lineH + ROW_GAP
  end

  local index = 0
  for _, line in ipairs(levelLines) do
    for _, item in ipairs(line) do
      index = index + 1
      local memberX = x + PAD + item.x
      if index == highlight then
        ImGui.DrawList_AddRectFilled(dl, memberX - HL_PAD_X, rowY - HL_PAD_Y,
                                     memberX + item.w + HL_PAD_X, rowY + lineH + HL_PAD_Y,
                                     chrome.colour('menu.highlight'), keycaps.BOX_R)
      end
      drawItem(dl, caps, item, memberX, rowY)
    end
    rowY = rowY + lineH + ROW_GAP
  end
end

return menuRender
