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
-- A button reports its click on release, which is when the cell opens its edit. `clickId`
-- aims the click at one button, for a cell that claims several.
fakeImGui.InvisibleButton          = function(_, id, w, h)
  frame.hits[#frame.hits + 1] = { id = id, w = w, h = h }
  if frame.clickId then return id == frame.clickId end
  return frame.clicked
end
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
  frame.wheel, frame.hovered, frame.clicked, frame.clickId, frame.pressed = 0, false, false, nil, {}
  return chrome, box, function() draw(segs) end
end

-- A flags cell over three booleans the test can watch. Labels of three lengths, so a
-- per-token width is distinguishable from a shared one.
local FLAGS = { 'Loop', 'Follow', 'Graph' }
local function mkFlags(harness)
  local chrome = mkChrome(harness.mk())
  local box    = { Loop = false, Follow = false, Graph = false }
  local items  = {}
  for _, name in ipairs(FLAGS) do
    items[#items + 1] = { label = name,
                          get = function() return box[name] end,
                          set = function(v) box[name] = v end }
  end
  local segs = { { id = 'modes', edit = { kind = 'flags', items = items } } }
  local draw = chrome.makeStatusBar()
  frame.wheel, frame.hovered, frame.clicked, frame.clickId, frame.pressed = 0, false, false, nil, {}
  return chrome, box, function() frame.hits = {}; draw(segs) end
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

  {
    name = 'a click on a flag token flips that flag and leaves its neighbours alone',
    run = function(harness)
      local _, box, draw = mkFlags(harness)
      draw()
      frame.clickId = '##status_modes_Follow'
      draw()
      t.eq(box.Follow, true, 'the token clicked went on')
      t.eq(box.Loop,   false, 'the token to its left is untouched')
      t.eq(box.Graph,  false, 'the token to its right is untouched')
      draw()
      t.eq(box.Follow, false, 'a second click flips it back')
    end,
  },

  {
    name = 'each flag token claims its own hit rect, sized to its own label',
    run = function(harness)
      local _, _, draw = mkFlags(harness)
      draw()
      t.eq(#frame.hits, 3, 'one rect per token')
      -- The fake measures text at 7px a character; the fake FramePadding is 8 a side, its
      -- WindowPadding 4, and a frame 20 tall.
      for i, name in ipairs(FLAGS) do
        t.eq(frame.hits[i].id, '##status_modes_' .. name, 'tokens claim in declared order')
        t.eq(frame.hits[i].w, 7 * #name + 16, 'the token is its label plus padding')
        t.eq(frame.hits[i].h, 20 + 8, "the token takes the band's pad above and below it")
      end
    end,
  },

  {
    name = "a flags cell's recorded rect spans every token and the gaps between them",
    run = function(harness)
      local chrome, _, draw = mkFlags(harness)
      draw()
      local tokens = 0
      for _, hit in ipairs(frame.hits) do tokens = tokens + hit.w end
      local slack = chrome.statusRects().modes.w - tokens
      -- Measured, not declared: the cell spans its tokens plus one gap between each pair.
      t.eq(slack >= 0, true, 'the cell is at least as wide as the tokens it claimed')
      t.eq(slack % (#FLAGS - 1), 0, 'the slack divides evenly into the gaps')
    end,
  },

  {
    name = 'a lit token has the footprint of an unlit one, so toggling never reflows the row',
    run = function(harness)
      local chrome, box, draw = mkFlags(harness)
      draw()
      local dark = {}
      for i, hit in ipairs(frame.hits) do dark[i] = hit.w end
      local darkSpan = chrome.statusRects().modes.w
      box.Loop, box.Follow, box.Graph = true, true, true
      draw()
      t.eq(#frame.hits, #dark, 'the same tokens are claimed')
      for i, hit in ipairs(frame.hits) do t.eq(hit.w, dark[i], 'each token holds its width') end
      t.eq(chrome.statusRects().modes.w, darkSpan, 'and so the cell spans the same')
    end,
  },
}
