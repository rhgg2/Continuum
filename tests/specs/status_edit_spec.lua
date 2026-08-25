-- Chrome-level pin for the status bar's editable cells: a segment carrying `set` draws as a
-- control rather than text, and both routes into it — the wheel and the InputText — commit
-- through `set` clamped to the declared range. Real chrome over a fake imgui; recipe from
-- picker_create_spec, with the item, wheel and cursor calls a cell makes added.
local t = require('support')

-- Constants (Key_*, *Flags_*, StyleVar_*) resolve to disjoint numeric ids via the metatable;
-- the functions a status cell calls are set explicitly below.
local fakeImGui = setmetatable({ Mod_None = 0 }, {
  __index = function(tbl, k) local n = rawget(tbl, '##n') or 0; n = n + 1
    rawset(tbl, '##n', n); rawset(tbl, k, n); return n end,
})

-- Mouse and keyboard for the frame about to be drawn, plus the hit rects it claimed.
local frame = { wheel = 0, hovered = false, clicked = false, text = '', pressed = {}, hits = {} }

for _, name in ipairs({ 'AlignTextToFramePadding', 'Text', 'SameLine', 'PushStyleVar', 'PopStyleVar',
  'PushStyleColor', 'PopStyleColor', 'SetCursorScreenPos', 'SetNextItemWidth', 'SetKeyboardFocusHere',
  'Attach', 'Function_SetValue', 'DrawList_AddRectFilled', 'GetWindowDrawList', 'Dummy' }) do
  fakeImGui[name] = function() end
end
fakeImGui.GetCursorScreenPos       = function() return 0, 0 end
fakeImGui.GetFrameHeight           = function() return 20 end
fakeImGui.GetStyleVar              = function() return 8, 4 end
fakeImGui.CalcTextSize             = function(_, s) return 7 * #s, 13 end
fakeImGui.GetStyleColor            = function() return 0 end
fakeImGui.ColorConvertU32ToDouble4 = function() return 1, 1, 1, 1 end
fakeImGui.ColorConvertDouble4ToU32 = function() return 0 end
fakeImGui.CreateFunctionFromEEL    = function() return {} end
-- A button reports its click on release, which is when the cell opens its edit.
fakeImGui.InvisibleButton          = function(_, id) frame.hits[#frame.hits + 1] = id; return frame.clicked end
fakeImGui.IsItemHovered            = function() return frame.hovered end
fakeImGui.IsItemActive             = function() return true end
fakeImGui.IsItemDeactivated        = function() return false end
fakeImGui.GetMouseWheel            = function() return frame.wheel, 0 end
fakeImGui.IsKeyPressed             = function(_, k) return frame.pressed[k] == true end
-- EnterReturnsTrue: the field reports a commit only on Enter.
fakeImGui.InputText                = function() return frame.pressed[fakeImGui.Key_Enter] == true, frame.text end

package.preload['imgui'] = function() return function(_) return fakeImGui end end
for _, m in ipairs({ 'imgui', 'painter', 'chrome' }) do package.loaded[m] = nil end
_G.reaper.ImGui_GetBuiltinPath = function() return '/stub' end

local util = require('util')

local function mkChrome(h)
  local lib = util.instantiate('library', { cm = h.cm, synthetic = {} })
  return util.instantiate('chrome', { cm = h.cm, ctx = {}, uiSize = 12, lib = lib })
end

-- A one-cell bar over a value the test can watch. `edit` selects the number behaviour.
local function mkBar(harness, value, edit)
  local chrome = mkChrome(harness.mk())
  local box    = { v = value }
  local segs   = { { id = 'rpb', label = 'RPB', width = 60, format = '%g',
                     get = function() return box.v end,
                     set = function(n) box.v = n end,
                     edit = edit } }
  local draw   = chrome.makeStatusBar()
  frame.wheel, frame.hovered, frame.clicked, frame.pressed = 0, false, false, {}
  return chrome, box, function() draw(segs) end
end

return {
  {
    name = 'the wheel over a number cell steps by `step` and stops at the declared bounds',
    run = function(harness)
      local _, box, draw = mkBar(harness, 4, { kind = 'number', min = 1, max = 6 })
      frame.hovered, frame.wheel = true, 1
      draw()
      t.eq(box.v, 3, 'a notch away from the reader steps down by one')
      frame.wheel = 3
      draw()
      t.eq(box.v, 1, 'three more stop at the min')
      frame.wheel = -9
      draw()
      t.eq(box.v, 6, 'a long scroll the other way stops at the max')
    end,
  },

  {
    name = 'part notches accumulate; the wheel only steps on a whole one',
    run = function(harness)
      local _, box, draw = mkBar(harness, 4, { kind = 'number', min = 1, max = 32 })
      frame.hovered, frame.wheel = true, 0.4
      draw()
      t.eq(box.v, 4, 'a part notch does not step')
      frame.wheel = 0.7
      draw()
      t.eq(box.v, 3, 'the part notches accumulate into one step')
    end,
  },

  {
    name = "step='x2' doubles and halves rather than adding",
    run = function(harness)
      local _, box, draw = mkBar(harness, 4, { kind = 'number', min = 0.25, step = 'x2' })
      frame.hovered, frame.wheel = true, 2
      draw()
      t.eq(box.v, 1, 'two notches halve twice')
      frame.wheel = -3
      draw()
      t.eq(box.v, 8, 'three the other way double three times')
      frame.wheel = 6
      draw()
      t.eq(box.v, 0.25, 'halving stops at the min')
    end,
  },

  {
    name = 'a display-only cell claims no hit rect; an editable one does',
    run = function(harness)
      local chrome = mkChrome(harness.mk())
      local draw   = chrome.makeStatusBar()
      frame.hits, frame.hovered, frame.wheel = {}, false, 0
      draw({ { id = 'at', label = 'At', width = 60, get = function() return '1:1.0' end } })
      t.eq(#frame.hits, 0, 'a cell without `set` stays plain text')
      draw({ { id = 'rpb', label = 'RPB', width = 60, get = function() return 4 end,
               set = function() end, edit = { kind = 'number', min = 1, max = 32 } } })
      t.eq(#frame.hits, 1, 'a cell with `set` claims its rect')
    end,
  },

  {
    name = "a cell's declared width is its value box; the label sits to its left",
    run = function(harness)
      local chrome = mkChrome(harness.mk())
      local draw   = chrome.makeStatusBar()
      frame.hovered, frame.wheel = false, 0
      draw({ { id = 'at', label = 'At', width = 60, get = function() return '1:1.0' end } })
      -- The fake measures text at 7px a character, so 'At' takes 14 and the gap 6.
      t.eq(chrome.statusRects().at.w, 80, 'the recorded rect spans label, gap and value box')
    end,
  },

  {
    name = 'a click opens the edit; Enter commits the typed value, clamped',
    run = function(harness)
      local chrome, box, draw = mkBar(harness, 4, { kind = 'number', min = 1, max = 6 })
      frame.hovered, frame.clicked = true, true
      draw()
      t.eq(chrome.statusEditActive(), true, 'the click opened the edit')
      t.eq(box.v, 4, 'opening the edit sets nothing')
      frame.clicked, frame.text = false, '99'
      frame.pressed = { [fakeImGui.Key_Enter] = true }
      draw()
      t.eq(box.v, 6, 'Enter commits the typed value clamped to the max')
      t.eq(chrome.statusEditActive(), false, 'the edit closed')
    end,
  },

  {
    name = 'Esc leaves the value alone and closes the edit',
    run = function(harness)
      local chrome, box, draw = mkBar(harness, 4, { kind = 'number', min = 1, max = 6 })
      frame.hovered, frame.clicked = true, true
      draw()
      frame.clicked, frame.text = false, '2'
      frame.pressed = { [fakeImGui.Key_Escape] = true }
      draw()
      t.eq(box.v, 4, 'the typed value is dropped')
      t.eq(chrome.statusEditActive(), false, 'the edit closed')
    end,
  },
}
