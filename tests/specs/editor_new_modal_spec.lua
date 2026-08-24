-- The swing and temper editors' New modal, drawn over a fake imgui: does the Create button
-- see the name standing in the field? ReaImGui hands a buffer back only on a frame the call
-- returns true, so a field flagged EnterReturnsTrue reads blank to every gesture but Enter.
-- Fake-imgui recipe from temperEditor_tree_spec.
local t      = require('support')
local util   = require('util')
local tuning = require('tuning')

local fakeImGui = setmetatable({ Mod_None = 0 }, {
  __index = function(tbl, k) local n = rawget(tbl, '##n') or 0; n = n + 1
    rawset(tbl, '##n', n); rawset(tbl, k, n); return n end,
})

-- What the user has typed into the name field, the button label reading as pressed, and
-- whether Enter went down in the field this frame.
local typed, clicked, enter = '', nil, false

for _, name in ipairs({ 'AlignTextToFramePadding', 'Text', 'TextColored', 'SameLine',
  'SetNextItemWidth', 'SetKeyboardFocusHere', 'PushID', 'PopID' }) do
  fakeImGui[name] = function() end
end
fakeImGui.IsWindowAppearing = function() return false end
fakeImGui.Button            = function(_, label) return label == clicked end
-- Enter both deactivates the field it lands in and reads as pressed for the frame.
fakeImGui.IsItemDeactivated = function() return enter end
fakeImGui.IsKeyPressed      = function(_, key) return enter and key == fakeImGui.Key_Enter end
fakeImGui.InputText = function(_, _, value, flags)
  local onEnterOnly = flags == fakeImGui.InputTextFlags_EnterReturnsTrue
  local committed   = onEnterOnly and enter or (not onEnterOnly and typed ~= value)
  if committed then return true, typed end
  return false, value
end

package.preload['imgui'] = function() return function(_) return fakeImGui end end
for _, m in ipairs({ 'imgui', 'painter', 'swingEditor', 'temperEditor' }) do
  package.loaded[m] = nil
end
_G.reaper.ImGui_GetBuiltinPath = function() return '/stub' end

-- Both editors hold chrome for house widgets; the New modal draws none of them.
local fakeChrome = setmetatable({}, { __index = function() return function() end end })
local fakeFacade = { get = function() return {} end, publish = function() end }

-- Both editors, over one harness, returning the modal bodies they registered.
local function mkEditors(harness)
  local h = harness.mk()
  local kinds = {}
  local lib = util.instantiate('library', { cm = h.cm,
    synthetic   = { swings = { identity = true }, tempers = { ['12EDO'] = true } },
    libraryForm = { tempers = tuning.unrooted } })
  local deps = { cm = h.cm, ds = h.ds, chrome = fakeChrome, ctx = {},
                 gui = { fontSize = { ui = 12 } }, facade = fakeFacade, lib = lib,
                 modalHost = { open         = function() end,
                               openConfirm  = function() end,
                               registerKind = function(_, kind, fn) kinds[kind] = fn end } }
  util.instantiate('swingEditor', deps)
  util.instantiate('temperEditor', deps)
  return kinds
end

-- One frame of a New modal, with the field holding `text` and `gesture` confirming it.
local function create(harness, kind, text, gesture)
  typed, clicked, enter = text, gesture == 'button' and 'Create' or nil, gesture == 'enter'
  local s, closed = { buf = '' }, nil
  mkEditors(harness)[kind](s, function(ok, name) closed = { ok = ok, name = name } end)
  return closed, s
end

return {
  {
    name = 'the Create button names the new swing from the field',
    run = function(harness)
      local closed = create(harness, 'swingNew', 'Groove', 'button')
      t.eq(closed and closed.name, 'Groove', 'the modal closed on the typed name')
    end,
  },

  {
    name = 'Enter in the field names it too',
    run = function(harness)
      local closed = create(harness, 'swingNew', 'Groove', 'enter')
      t.eq(closed and closed.name, 'Groove', 'the modal closed on the typed name')
    end,
  },

  {
    name = 'the Create button names the new temper from the field',
    run = function(harness)
      local closed = create(harness, 'temperNew', 'Squiggle', 'button')
      t.eq(closed and closed.name, 'Squiggle', 'the modal closed on the typed name')
    end,
  },

  {
    name = 'Enter in the field names the temper too',
    run = function(harness)
      local closed = create(harness, 'temperNew', 'Squiggle', 'enter')
      t.eq(closed and closed.name, 'Squiggle', 'the modal closed on the typed name')
    end,
  },

  {
    name = 'an empty field asks for a name rather than closing',
    run = function(harness)
      local closed, s = create(harness, 'swingNew', '', 'button')
      t.eq(closed, nil, 'the modal stayed open')
      t.eq(s.err, 'Name required.')
    end,
  },
}
