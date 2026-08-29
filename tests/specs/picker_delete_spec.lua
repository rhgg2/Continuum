-- Chrome-level pin for drawPicker's onDelete hook (fx-patterns P4). Real chrome over a fake imgui:
-- a keyed row grows a trailing × whose first click only arms the row (red, with a trailing '?'), and
-- only a second click on that same row fires onDelete. Recipe from picker_create_spec, with an
-- InvisibleButton that recognises a queued row and a draw list that records what the × was drawn in.
local t = require('support')

-- Constants (Key_*, *Flags_*, StyleVar_*) resolve to disjoint numeric ids via the metatable; the
-- functions drawPicker calls are set explicitly below.
local fakeImGui = setmetatable({ Mod_None = 0 }, {
  __index = function(tbl, k) local n = rawget(tbl, '##n') or 0; n = n + 1
    rawset(tbl, '##n', n); rawset(tbl, k, n); return n end,
})

-- keyQueue enumerates the Key_* names the shim table holds, once, as it loads; the metatable
-- above mints them on touch, so mint every key the picker acts on before that.
for _, name in ipairs({ 'Enter', 'KeypadEnter', 'Escape',
                        'UpArrow', 'DownArrow', 'LeftArrow', 'RightArrow' }) do
  local _ = fakeImGui['Key_' .. name]
end

-- Buttons drawn this frame, in row order: one entry per ×, carrying the ink its diagonals used.
local drawnButtons, clickRow = {}, nil
for _, name in ipairs({ 'AlignTextToFramePadding', 'Text', 'SameLine', 'PushStyleVar', 'PopStyleVar',
  'PushStyleColor', 'PopStyleColor', 'OpenPopup', 'SetNextWindowPos', 'SetKeyboardFocusHere',
  'SetNextItemWidth', 'Attach', 'Separator', 'EndPopup', 'CloseCurrentPopup',
  'PushID', 'PopID', 'SetNextWindowSizeConstraints', 'SetCursorPosY', 'Dummy' }) do
  fakeImGui[name] = function() end
end
fakeImGui.Button                = function() return true end   -- always "opening" so the popup runs
fakeImGui.GetItemRectMin        = function() return 0, 0 end
fakeImGui.GetItemRectMax        = function() return 0, 0 end
fakeImGui.GetStyleVar           = function() return 8, 4 end   -- window padding / item spacing
fakeImGui.GetCursorPosY         = function() return 0 end
fakeImGui.GetContentRegionAvail = function() return 200, 200 end
fakeImGui.GetTextLineHeight     = function() return 13 end
fakeImGui.CalcTextSize          = function() return 7, 13 end
fakeImGui.GetWindowPos          = function() return 0, 0 end
fakeImGui.GetCursorScreenPos    = function() return 0, 0 end
fakeImGui.GetWindowDrawList     = function() return {} end
fakeImGui.BeginPopup            = function() return true end
fakeImGui.IsWindowAppearing     = function() return false end   -- appearing disarms; stay open
fakeImGui.IsItemHovered         = function() return false end
fakeImGui.CreateFunctionFromEEL = function() return {} end
fakeImGui.InputText             = function() return true, '' end
fakeImGui.IsKeyPressed          = function() return false end   -- no Enter: the row loop runs
fakeImGui.GetKeyMods            = function() return 0 end
fakeImGui.IsAnyItemActive       = function() return false end
fakeImGui.Selectable            = function() return false end
fakeImGui.ColorConvertDouble4ToU32 = function(r, g, b) return math.floor(r * 255) * 65536
                                                            + math.floor(g * 255) * 256
                                                            + math.floor(b * 255) end
fakeImGui.InvisibleButton       = function(_, label)
  drawnButtons[#drawnButtons + 1] = { label = label }
  return clickRow ~= nil and label:match('##del(%d+)$') == tostring(clickRow)
end
-- Each × is two diagonals; the first records the ink for the button just submitted. An armed row
-- follows them with a '?', which lands on the same entry.
fakeImGui.DrawList_AddLine      = function(_, _, _, _, _, colour)
  local last = drawnButtons[#drawnButtons]
  last.ink = last.ink or colour
end
fakeImGui.DrawList_AddText      = function(_, _, _, _, text)
  drawnButtons[#drawnButtons].text = text
end

package.preload['imgui'] = function() return function(_) return fakeImGui end end
for _, m in ipairs({ 'imgui', 'painter', 'chrome' }) do package.loaded[m] = nil end
_G.reaper.ImGui_GetBuiltinPath = function() return '/stub' end

local util = require('util')

-- The picker owns the keyboard while its popup is up, so the frame's queue is filled as one.
local kq = util.instantiate('keyQueue', { ctx = {} })

local function mkChrome(h)
  local lib = util.instantiate('library', { cm = h.cm, synthetic = {} })
  return util.instantiate('chrome', { cm = h.cm, ctx = {}, uiSize = 12, lib = lib, keyQueue = kq })
end

local SHELF = { { label = 'lead', key = 'lead' }, { label = 'bass', key = 'bass' } }

-- One Load picker frame, clicking the trailing × on row `click` (nil: click nothing).
-- Returns the key onDelete fired with, and the buttons drawn this frame.
local function frame(chrome, click, noDelete)
  clickRow, drawnButtons = click, {}
  kq:fill('picker')
  local deleted
  local spec = { kind = 'test', buttonLabel = 'Load', items = SHELF, onPick = function() end }
  if not noDelete then spec.onDelete = function(key) deleted = key end end
  chrome.drawPicker(spec)
  return deleted, drawnButtons
end

return {
  {
    name = 'the first click arms the row: no delete, and its × changes ink',
    run = function(harness)
      local chrome = mkChrome(harness.mk())
      t.eq(frame(chrome, 1), nil, 'one click does not fire onDelete')

      local _, buttons = frame(chrome, nil)
      t.eq(#buttons, 2, 'both keyed rows carry a ×')
      t.truthy(buttons[1].ink ~= buttons[2].ink, 'the armed row is drawn in a different ink')
      t.eq(buttons[1].text, '?', 'the armed row asks for confirmation')
      t.eq(buttons[2].text, nil, 'the untouched row shows its × alone')
    end,
  },

  {
    name = 'a second click on the armed row fires onDelete with its key',
    run = function(harness)
      local chrome = mkChrome(harness.mk())
      frame(chrome, 1)
      t.eq(frame(chrome, 1), 'lead', 'the second click deleted the armed row')
    end,
  },

  {
    name = 'arming a different row disarms the first',
    run = function(harness)
      local chrome = mkChrome(harness.mk())
      frame(chrome, 1)
      t.eq(frame(chrome, 2), nil, 'clicking another row arms it rather than deleting')
      t.eq(frame(chrome, 1), nil, 'the first row went back to unarmed')
    end,
  },

  {
    name = 'a picker without onDelete draws no buttons at all',
    run = function(harness)
      local _, buttons = frame(mkChrome(harness.mk()), nil, true)
      t.eq(#buttons, 0, 'the other call sites keep their plain rows')
    end,
  },
}
