-- See docs/menu.md § The row for the model.
-- @noindex

-- The open menu's row: the level as keycap letters and titles over the body's last
-- row, on the foreground drawlist, wrapping upward where the row is too narrow.

local ImGui   = require 'imgui' '0.10'
local keycaps = require 'keycaps'
local util    = require 'util'

local ctx    = (...).ctx
local chrome = (...).chrome
local menu   = (...).menu

local PAD, ROW_GAP = 6, 2             -- the band's inset; between wrapped lines
local LETTER_GAP, MEMBER_GAP = 6, 18  -- keycap to title; member to member
local HL_PAD = 3                      -- the highlight fill's reach past its member

local menuRender = {}

-- Each member measured as keycap + gap + title, packed greedily into lines of the given
-- width; lines read top to bottom, so an overflowing level grows upward from the floor.
local function layout(caps, members, width)
  local lines, line, cursor = {}, {}, 0
  local limit = width - PAD * 2
  for _, member in ipairs(members) do
    local cluster = caps.cluster({ member.letter })
    local memberW = cluster.width + LETTER_GAP + (ImGui.CalcTextSize(ctx, member.title))
    if #line > 0 and cursor + memberW > limit then
      util.add(lines, line)
      line, cursor = {}, 0
    end
    util.add(line, { member = member, cluster = cluster, w = memberW, x = cursor })
    cursor = cursor + memberW + MEMBER_GAP
  end
  if #line > 0 then util.add(lines, line) end
  return lines
end

-- The cheat-sheet's colours, so a letter reads as a key in both places.
local function menuTheme()
  return { bg     = chrome.colour('help.box'),   border = chrome.colour('help.border'),
           title  = chrome.colour('help.title'), key    = chrome.colour('help.key'),
           label  = chrome.colour('help.desc'),  chip   = chrome.colour('help.chip') }
end

--contract: draws the open menu's level in `width`, standing on `bottom`; closed draws nothing
function menuRender:draw(x, bottom, width)
  if not menu:isOpen() then return end
  local dl    = ImGui.GetForegroundDrawList(ctx)
  local lineH = ImGui.GetTextLineHeight(ctx)
  local caps  = keycaps.new(ctx, dl, menuTheme())
  local lines = layout(caps, menu:level(), width)
  if #lines == 0 then return end

  local top = bottom - PAD * 2 - #lines * lineH - (#lines - 1) * ROW_GAP
  caps.panel(x, top, x + width, bottom)

  local highlight, index, rowY = menu:highlight(), 0, top + PAD
  for _, line in ipairs(lines) do
    for _, placed in ipairs(line) do
      index = index + 1
      local memberX = x + PAD + placed.x
      if index == highlight then
        ImGui.DrawList_AddRectFilled(dl, memberX - HL_PAD, rowY, memberX + placed.w + HL_PAD,
                                     rowY + lineH, chrome.colour('menu.highlight'), keycaps.BOX_R)
      end
      caps.drawCluster(placed.cluster, memberX, rowY)
      ImGui.DrawList_AddText(dl, memberX + placed.cluster.width + LETTER_GAP, rowY,
                             chrome.colour('help.desc'), placed.member.title)
    end
    rowY = rowY + lineH + ROW_GAP
  end
end

return menuRender
