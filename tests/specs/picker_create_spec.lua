-- Chrome-level pin for drawPicker's onCreate hook (fx-patterns P4). Real chrome over a fake imgui:
-- a non-empty filter with no exact item match prepends a create row whose Enter fires onCreate; a
-- filter equal to an existing item label suppresses that row so Enter overwrites via onPick. Recipe
-- from libpicker_badge_spec, extended with InputText/IsKeyPressed/Selectable.
local t = require('support')

-- `createLabel` is the hook a picker uses when it can only build from text it can read: it names the
-- create row, withholds it by returning nil, and may say which block it belongs in -- for groups that
-- sort a list rather than name a destination. The fx strip's Period picker is the caller.

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

local filterText, pressed, drawnRows = '', {}, {}
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
fakeImGui.GetContentRegionAvail = function() return 200, 200 end
fakeImGui.GetCursorPosY         = function() return 0 end
fakeImGui.GetCursorScreenPos    = function() return 0, 0 end   -- the row list places its delete column from this
fakeImGui.BeginPopup            = function() return true end
fakeImGui.IsWindowAppearing     = function() return true end
fakeImGui.CreateFunctionFromEEL = function() return {} end
fakeImGui.ColorConvertDouble4ToU32 = function() return 0 end   -- the popup pushes its own ink
fakeImGui.InputText             = function() return true, filterText end
fakeImGui.IsKeyPressed          = function(_, k) return pressed[k] == true end
fakeImGui.GetKeyMods            = function() return 0 end
fakeImGui.IsAnyItemActive       = function() return false end
fakeImGui.Selectable            = function(_, label) drawnRows[#drawnRows + 1] = label; return false end
fakeImGui.TextDisabled          = function(_, label) drawnRows[#drawnRows + 1] = '# ' .. label end   -- a group heading, marked

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

-- The same two names under declared groups, for the question of which block a create row leads.
local GROUPS  = { { key = 'a', label = 'Alpha' }, { key = 'b', label = 'Beta' } }
local GROUPED = { { label = 'lead', key = 'lead', group = 'a' },
                  { label = 'bass', key = 'bass', group = 'b' } }

-- Draw one Save picker frame with filter `text` and `key` pressed (Enter by default); return
-- which of the three callbacks fired.
local function drawWith(chrome, text, key, createLabel)
  filterText = text
  pressed = { [key or fakeImGui.Key_Enter] = true }
  kq:fill('picker')
  local created, picked, cancelled
  chrome.drawPicker{ kind = 'test', buttonLabel = 'Save', items = SHELF, createLabel = createLabel,
    onPick   = function(k) picked = k end,
    onCreate = function(txt) created = txt end,
    onCancel = function() cancelled = true end }
  return created, picked, cancelled
end

-- Draw one frame with nothing pressed, so the row list itself draws rather than the Enter branch;
-- return the labels it drew.
local function rowsWith(chrome, text, createLabel)
  filterText, pressed, drawnRows = text, {}, {}
  kq:fill('picker')
  chrome.drawPicker{ kind = 'test', buttonLabel = 'Save', items = SHELF, createLabel = createLabel,
    onPick = function() end, onCreate = function() end }
  return drawnRows
end

-- The same, over the grouped shelf: headings come back marked, so the list shows placement.
local function groupedRowsWith(chrome, text, createLabel)
  filterText, pressed, drawnRows = text, {}, {}
  kq:fill('picker')
  chrome.drawPicker{ kind = 'test', buttonLabel = 'Save', items = GROUPED, groups = GROUPS,
    createLabel = createLabel, onPick = function() end, onCreate = function() end }
  return drawnRows
end

return {
  {
    name = 'a non-exact filter prepends a create row; Enter fires onCreate with the filter',
    run = function(harness)
      local created, picked = drawWith(mkChrome(harness.mk()), 'new')
      t.eq(created, 'new', 'onCreate fired with the typed filter')
      t.eq(picked, nil, 'onPick did not fire')
    end,
  },

  {
    name = 'a filter equal to an existing label suppresses the create row; Enter overwrites via onPick',
    run = function(harness)
      local created, picked = drawWith(mkChrome(harness.mk()), 'lead')
      t.eq(picked, 'lead', 'onPick fired with the existing name')
      t.eq(created, nil, 'onCreate did not fire')
    end,
  },

  {
    name = 'createLabel names the create row; a picker without one keeps the default label',
    run = function(harness)
      local chrome = mkChrome(harness.mk())
      t.deepEq(rowsWith(chrome, 'new'), { '+ new: new' },
        'no item matches "new", so the create row is the whole list, under its default label')
      t.deepEq(rowsWith(chrome, 'new', function(text) return text:upper() end), { 'NEW' },
        "the caller's label stands in its place")
    end,
  },

  {
    name = 'a nil from createLabel withholds the create row, so there is nothing to commit',
    run = function(harness)
      local chrome = mkChrome(harness.mk())
      local offered = {}
      local rows = rowsWith(chrome, 'new', function(text) offered[#offered + 1] = text; return nil end)
      t.deepEq(offered, { 'new' }, 'the filter reached createLabel, so the row was decided on')
      t.deepEq(rows, {}, 'and no row was drawn')
      t.eq(drawWith(chrome, 'new', nil, function() return nil end), nil,
        'Enter has no create row to fire onCreate from either')
    end,
  },

  {
    name = 'the create row leads the names it partly matched, so Enter cannot overwrite one',
    run = function(harness)
      t.deepEq(rowsWith(mkChrome(harness.mk()), 'lea'), { '+ new: lea', 'lead' },
        'a partial match draws both rows, the create row first -- and the cursor parks on row 1')
    end,
  },

  {
    name = 'a create row leads every block, where nothing says which block it belongs to',
    run = function(harness)
      t.deepEq(groupedRowsWith(mkChrome(harness.mk()), 'new'),
        { '# Alpha', '+ new: new', '# Beta', '+ new: new' },
        'a group is a destination by default, so each offers to create into itself')
    end,
  },

  {
    name = 'a group from createLabel places the create row in that block alone',
    run = function(harness)
      t.deepEq(groupedRowsWith(mkChrome(harness.mk()), 'new', function(text) return text:upper(), 'b' end),
        { '# Beta', 'NEW' },
        'the row leads the block it was placed in, and the block left empty drops out')
    end,
  },

  {
    name = 'the picker claims the Enter it acts on, so no reader after it sees the press',
    run = function(harness)
      local created = drawWith(mkChrome(harness.mk()), 'new')
      t.eq(created, 'new', 'the frame acted on an Enter, so there was one to claim')
      t.eq(kq:take(fakeImGui.Key_Enter, 0, 'picker'), nil, 'and the queue no longer holds it')
    end,
  },

  {
    name = 'Escape cancels the picker, and its press leaves the queue too',
    run = function(harness)
      local created, picked, cancelled =
        drawWith(mkChrome(harness.mk()), 'new', fakeImGui.Key_Escape)
      t.eq(cancelled, true, 'onCancel fired')
      t.eq(created, nil, 'nothing was created')
      t.eq(picked, nil, 'and nothing picked')
      t.eq(kq:takeAny('picker'), nil, 'the Escape was claimed, leaving the queue empty')
    end,
  },
}
