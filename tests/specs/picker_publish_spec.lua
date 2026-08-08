-- Chrome-level pin for drawPicker's onPublish hook (chain surface). Real chrome over a fake imgui:
-- a row the item list marks `publishable` grows a trailing ↑, placed left of the ×, two-press as the
-- × is -- and the two share one armed slot per picker kind, so arming either disarms the other.
-- Recipe from picker_delete_spec, with an InvisibleButton answering to both tags and a SameLine that
-- records the offset each button was placed at.
local t = require('support')

-- Constants (Key_*, *Flags_*, StyleVar_*) resolve to disjoint numeric ids via the metatable; the
-- functions drawPicker calls are set explicitly below.
local fakeImGui = setmetatable({ Mod_None = 0 }, {
  __index = function(tbl, k) local n = rawget(tbl, '##n') or 0; n = n + 1
    rawset(tbl, '##n', n); rawset(tbl, k, n); return n end,
})

-- Buttons drawn this frame, in submission order: the label identifies tag and row, `ink` is what the
-- glyph's first stroke used, and `x` the offset SameLine placed the box at.
local drawnButtons, clickLabel, lastOffset = {}, nil, nil
for _, name in ipairs({ 'AlignTextToFramePadding', 'Text', 'PushStyleVar', 'PopStyleVar',
  'PushStyleColor', 'PopStyleColor', 'OpenPopup', 'SetNextWindowPos', 'SetKeyboardFocusHere',
  'SetNextItemWidth', 'Attach', 'Separator', 'EndPopup', 'CloseCurrentPopup' }) do
  fakeImGui[name] = function() end
end
fakeImGui.Button                = function() return true end   -- always "opening" so the popup runs
fakeImGui.SameLine              = function(_, offset) lastOffset = offset end
fakeImGui.GetItemRectMin        = function() return 0, 0 end
fakeImGui.GetItemRectMax        = function() return 0, 0 end
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
fakeImGui.Selectable            = function() return false end
fakeImGui.ColorConvertDouble4ToU32 = function(r, g, b) return math.floor(r * 255) * 65536
                                                            + math.floor(g * 255) * 256
                                                            + math.floor(b * 255) end
fakeImGui.InvisibleButton       = function(_, label)
  drawnButtons[#drawnButtons + 1] = { label = label, x = lastOffset }
  return label == clickLabel
end
-- The first stroke of a glyph records the ink for the button just submitted (the × has two, the ↑
-- three). An armed row follows them with a '?', which lands on the same entry.
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

local function mkChrome(h)
  local lib = util.instantiate('library', { cm = h.cm, synthetic = {} })
  return util.instantiate('chrome', { cm = h.cm, ctx = {}, uiSize = 12, lib = lib })
end

-- Row 1 has somewhere to publish to; row 2 is the library's own copy, or a pristine shadow of it.
local SHELF = { { label = 'lead', key = 'lead', publishable = true },
                { label = 'bass', key = 'bass' } }

-- One Load picker frame, clicking the button tagged `click` ('pub1', 'del2', ...; nil clicks
-- nothing). Returns what fired -- { action, key } -- and the buttons drawn this frame.
local function frame(chrome, click, opts)
  opts = opts or {}
  clickLabel, drawnButtons, lastOffset = click and ('##' .. click) or nil, {}, nil
  local fired
  local spec = { kind = 'test', buttonLabel = 'Load', items = SHELF, onPick = function() end }
  if not opts.noDelete then
    spec.onDelete = function(key) fired = { action = 'delete', key = key } end
  end
  if not opts.noPublish then
    spec.onPublish = function(key) fired = { action = 'publish', key = key } end
  end
  chrome.drawPicker(spec)
  return fired, drawnButtons
end

local function buttonAt(buttons, tag)
  for _, b in ipairs(buttons) do if b.label == '##' .. tag then return b end end
end

return {
  {
    name = 'only a publishable row grows a ↑',
    run = function(harness)
      local _, buttons = frame(mkChrome(harness.mk()), nil)
      t.truthy(buttonAt(buttons, 'pub1'), 'the publishable row carries a ↑')
      t.eq(buttonAt(buttons, 'pub2'), nil, 'the row with nowhere to publish to carries none')
      t.truthy(buttonAt(buttons, 'del2'), 'though it keeps its ×')
    end,
  },

  {
    name = 'the first click arms the ↑ and the second publishes the row',
    run = function(harness)
      local chrome = mkChrome(harness.mk())
      t.eq(frame(chrome, 'pub1'), nil, 'one click publishes nothing')

      local _, buttons = frame(chrome, nil)
      t.eq(buttonAt(buttons, 'pub1').text, '?', 'the armed ↑ asks for confirmation')
      t.truthy(buttonAt(buttons, 'pub1').ink ~= buttonAt(buttons, 'del1').ink,
               'and is drawn in the armed ink, where the × beside it rests')

      local fired = frame(chrome, 'pub1')
      t.eq(fired and fired.action, 'publish', 'the second click published')
      t.eq(fired and fired.key, 'lead', 'with the row\'s key')
    end,
  },

  {
    name = 'a picker without onPublish draws no ↑ even on a publishable row',
    run = function(harness)
      local _, buttons = frame(mkChrome(harness.mk()), nil, { noPublish = true })
      t.eq(buttonAt(buttons, 'pub1'), nil, 'the other call sites offer no publish')
      t.truthy(buttonAt(buttons, 'del1'), 'and keep the × they had')
    end,
  },

  {
    name = 'the ↑ sits left of the ×, which keeps the flush-right slot',
    run = function(harness)
      local _, buttons = frame(mkChrome(harness.mk()), nil)
      t.truthy(buttonAt(buttons, 'pub1').x < buttonAt(buttons, 'del1').x,
               'the ↑ is inset by a button width, the × is not')
    end,
  },

  {
    name = 'the two glyphs share one armed slot, so arming either disarms the other',
    run = function(harness)
      local chrome = mkChrome(harness.mk())
      frame(chrome, 'del1')
      t.eq(frame(chrome, 'pub1'), nil, 'arming the ↑ fires nothing')
      t.eq(frame(chrome, 'del1'), nil, 'and the × it disarmed only re-arms on the next click')
      t.eq(frame(chrome, 'del1').action, 'delete', 'the click after that deletes')
    end,
  },
}
