-- Chrome-level pin for drawPicker's group headings over groups it was left to *infer* from the items
-- (libPicker's shape; picker_tiers_spec covers groups a caller declares). An item's `groupLabel`
-- announces the tier its group was drawn from, above that group's first row, so the two levels a
-- library-shaped catalogue saves into are on screen rather than inferred from the `+` prefix. A
-- group without a label (Off) announces nothing. Recipe from picker_create_spec, extended to record
-- the popup body in submission order.
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

-- The popup body in submission order: one entry per heading, row or rule.
local filterText, pressed, body = '', {}, {}
for _, name in ipairs({ 'AlignTextToFramePadding', 'Text', 'SameLine', 'PushStyleVar', 'PopStyleVar',
  'PushStyleColor', 'PopStyleColor', 'OpenPopup', 'SetNextWindowPos', 'SetKeyboardFocusHere',
  'SetNextItemWidth', 'Attach', 'EndPopup', 'CloseCurrentPopup', 'PushID', 'PopID',
  'SetNextWindowSizeConstraints', 'SetCursorPosY', 'Dummy' }) do
  fakeImGui[name] = function() end
end
fakeImGui.Button                = function() return true end   -- always "opening" so the popup runs
fakeImGui.GetItemRectMin        = function() return 0, 0 end
fakeImGui.GetItemRectMax        = function() return 0, 0 end
fakeImGui.GetStyleVar           = function() return 8, 4 end   -- window padding / item spacing
fakeImGui.GetCursorPosY         = function() return 0 end
fakeImGui.GetContentRegionAvail = function() return 200, 200 end
fakeImGui.GetCursorScreenPos    = function() return 0, 0 end
fakeImGui.GetTextLineHeight     = function() return 13 end
fakeImGui.CalcTextSize          = function() return 7, 13 end
fakeImGui.BeginPopup            = function() return true end
fakeImGui.IsWindowAppearing     = function() return true end
fakeImGui.CreateFunctionFromEEL = function() return {} end
fakeImGui.ColorConvertDouble4ToU32 = function() return 0 end   -- the popup pushes its own ink
fakeImGui.InputText             = function() return true, filterText end
fakeImGui.IsKeyPressed          = function(_, k) return pressed[k] == true end
fakeImGui.GetKeyMods            = function() return 0 end
fakeImGui.IsAnyItemActive       = function() return false end
fakeImGui.Separator             = function() body[#body + 1] = { rule = true } end
fakeImGui.TextDisabled          = function(_, label) body[#body + 1] = { heading = label } end
fakeImGui.Selectable            = function(_, label, selected)
  body[#body + 1] = { row = label, selected = selected }
  return false
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

-- Off carries no label; the two tiers below it do, as libPicker stamps them.
local SHELF = {
  { label = 'Off',       group = 1 },
  { label = 'wobble',    key = 'wobble',  group = 2, groupLabel = 'Project' },
  { label = 'thump',     key = 'thump',   group = 2, groupLabel = 'Project' },
  { label = '+ shimmer', key = 'shimmer', group = 3, groupLabel = 'Library' },
}

-- One picker frame under filter `text`, with `key` pressed if given; returns the body it drew.
local function frame(chrome, text, key)
  filterText, body = text or '', {}
  pressed = key and { [key] = true } or {}
  kq:fill('picker')
  chrome.drawPicker{ kind = 'test', buttonLabel = 'load', items = SHELF, onPick = function() end }
  return body
end

-- The headings drawn, in order.
local function headings(drawn)
  local out = {}
  for _, e in ipairs(drawn) do if e.heading then out[#out + 1] = e.heading end end
  return out
end

-- Index of the first entry naming `label`, whichever kind it is.
local function indexOf(drawn, label)
  for i, e in ipairs(drawn) do if e.heading == label or e.row == label then return i end end
end

return {
  {
    name = 'each labelled group announces its tier, once, above its first row',
    run = function(harness)
      local drawn = frame(mkChrome(harness.mk()))
      t.deepEq(headings(drawn), { 'Project', 'Library' }, 'both tiers named, in the order they are drawn')
      t.truthy(indexOf(drawn, 'Project') < indexOf(drawn, 'wobble'),
               'the Project heading precedes the first project row')
      t.truthy(indexOf(drawn, 'thump') < indexOf(drawn, 'Library'),
               'and the last project row precedes the Library heading')
    end,
  },

  {
    name = 'the group with no label announces nothing',
    run = function(harness)
      local drawn = frame(mkChrome(harness.mk()))
      t.eq(headings(drawn)[1], 'Project', 'the first heading belongs to the group below Off')
      t.truthy(indexOf(drawn, 'Off') < indexOf(drawn, 'Project'),
               'so Off leads the list under no heading of its own')
    end,
  },

  {
    name = 'the headings survive a filter, so a match still says which tier it came from',
    run = function(harness)
      local drawn = frame(mkChrome(harness.mk()), 'm')
      t.deepEq(headings(drawn), { 'Project', 'Library' }, 'a match keeps the tier it was drawn from')
      t.truthy(indexOf(drawn, 'thump') < indexOf(drawn, 'Library'),
               'each under its own, Off having dropped out of the matches entirely')
      local rules = 0
      for _, e in ipairs(drawn) do if e.rule then rules = rules + 1 end end
      t.eq(rules, 1, 'only the rule under the filter box: a heading divides as well as it names')
    end,
  },

  {
    -- IsWindowAppearing is true on every frame here, which parks the cursor at row 1 before
    -- the arrow moves it, so one frame shows the move.
    name = 'a DownArrow the picker claims walks the highlight down a row',
    run = function(harness)
      local function highlighted(drawn)
        for _, e in ipairs(drawn) do if e.selected then return e.row end end
      end
      local chrome = mkChrome(harness.mk())
      t.eq(highlighted(frame(chrome)), 'Off', 'the cursor parks on the first row')
      t.eq(highlighted(frame(chrome, nil, fakeImGui.Key_DownArrow)), 'wobble',
           'DownArrow moves it to the second')
    end,
  },
}
