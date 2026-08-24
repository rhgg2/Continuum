-- The tidy editor's base list, drawn over a fake imgui: does the Add button see what stands
-- in the new-base field? ReaImGui hands a buffer back only on a frame its InputText returns
-- true, so a field flagged EnterReturnsTrue reads blank to every gesture but Enter.
local t    = require('support')
local util = require('util')

-- Constants (Key_*, *Flags_*, StyleVar_*, Col_*) resolve to disjoint numeric ids via the
-- metatable; the functions the modal body calls are set explicitly below.
local fakeImGui = setmetatable({ Mod_None = 0 }, {
  __index = function(tbl, k) local n = rawget(tbl, '##n') or 0; n = n + 1
    rawset(tbl, '##n', n); rawset(tbl, k, n); return n end,
})

-- What the user has typed into the new-base field, the button label reading as pressed,
-- and whether Enter went down in the field this frame.
local typed, clicked, enter = '', nil, false

for _, name in ipairs({ 'AlignTextToFramePadding', 'Text', 'TextDisabled', 'SameLine', 'Separator',
  'PushStyleVar', 'PopStyleVar', 'PushStyleColor', 'PopStyleColor', 'PushFont', 'PopFont',
  'SetNextItemWidth', 'SetCursorPosX', 'EndChild', 'PushID', 'PopID' }) do
  fakeImGui[name] = function() end
end
fakeImGui.GetStyleVar                = function() return 0, 0 end
fakeImGui.GetFrameHeight             = function() return 20 end
fakeImGui.GetFrameHeightWithSpacing  = function() return 24 end
fakeImGui.CalcTextSize               = function() return 20 end
fakeImGui.GetWindowWidth             = function() return 400 end
fakeImGui.IsWindowAppearing          = function() return false end
fakeImGui.IsAnyItemActive            = function() return true end
-- Enter both deactivates the field it lands in and reads as pressed for the frame.
fakeImGui.IsItemDeactivated          = function() return enter end
fakeImGui.IsItemDeactivatedAfterEdit = function() return false end
fakeImGui.IsKeyPressed               = function(_, key) return enter and key == fakeImGui.Key_Enter end
fakeImGui.CreateFunctionFromEEL      = function() return {} end
fakeImGui.Attach                     = function() end
-- The row list is a child window; refusing it leaves the base list as the frame's whole content.
fakeImGui.BeginChild = function() return false end
fakeImGui.Button     = function(_, label) return label == clicked end
-- The rename fields sit untouched, so they return their own text and no change.
fakeImGui.InputText  = function(_, _, value) return false, value end
fakeImGui.InputTextWithHint = function(_, _, _, value, flags)
  local onEnterOnly = flags == fakeImGui.InputTextFlags_EnterReturnsTrue
  local committed   = onEnterOnly and enter or (not onEnterOnly and typed ~= value)
  if committed then return true, typed end
  return false, value
end

package.preload['imgui'] = function() return function(_) return fakeImGui end end
for _, m in ipairs({ 'imgui', 'painter' }) do package.loaded[m] = nil end
_G.reaper.ImGui_GetBuiltinPath = function() return '/stub' end

-- arrangeRender holds chrome for its house widgets; the base list draws none of them.
local fakeChrome = setmetatable({}, { __index = function() return function() end end })

-- Two slots on one track: enough for seedTidy to hand back a base and an assignment.
local tidyItems = {
  { track = 'tr1', name = 'a', pos = 0, takeName = 'Bassline' },
  { track = 'tr1', name = 'b', pos = 4, takeName = 'Bassline (var 3)' },
}

-- Build the tidy modal's body over a real av, and return it with the state openTidyModal seeds.
local function mkTidyModal(harness)
  local h = harness.mk()
  h.cm:set('project', 'arrangeBeatPerRow', 1)
  h.reaper:setTrackName('tr1', 'tr1')
  for _, item in ipairs(tidyItems) do
    h.reaper:addItem(item.track, { take = item.track .. '/' .. item.name, isMidi = true,
      pos = item.pos, len = 1, takeName = item.takeName,
      poolGuid = '{' .. item.track .. item.name .. '}' })
  end
  h.reaper:setProjectTracks({ 'tr1' })
  local em = util.instantiate('eventMeta', { ps = util.instantiate('pextStore') })
  local am = util.instantiate('arrangeManager',
    { cm = h.cm, ds = h.ds, tm = h.tm, eventMeta = em })
  local av = util.instantiate('arrangeView', { cm = h.cm, cmgr = h.cmgr, am = am })

  local kinds = {}
  local modalHost = {
    open         = function() end,
    openConfirm  = function() end,
    openPrompt   = function() end,
    registerKind = function(_, kind, fn) kinds[kind] = fn end,
  }
  util.instantiate('arrangeRender', { cm = h.cm, cmgr = h.cmgr, chrome = fakeChrome,
                                      modalHost = modalHost, av = av })
  local bases, assignment = av:seedTidy(0)
  return kinds.tidyTrack,
         { trackIdx = 0, bases = bases, assignment = assignment, newBase = '' }
end

-- One frame of the modal, with the field holding `text` and `gesture` committing it.
local function drawWith(harness, text, gesture)
  local body, s = mkTidyModal(harness)
  typed, clicked, enter = text, gesture == 'add' and 'Add' or nil, gesture == 'enter'
  body(s, function() end)
  return s
end

local function holds(bases, name)
  for _, base in ipairs(bases) do if base == name then return true end end
  return false
end

return {
  {
    name = 'the Add button appends the base standing in the field',
    run = function(harness)
      local s = drawWith(harness, 'Drums', 'add')
      t.truthy(holds(s.bases, 'Drums'), 'the typed base joined the list')
      t.eq(s.newBase, '', 'and the field is cleared for the next one')
    end,
  },

  {
    name = 'Enter in the field appends it too',
    run = function(harness)
      local s = drawWith(harness, 'Drums', 'enter')
      t.truthy(holds(s.bases, 'Drums'), 'the typed base joined the list')
      t.eq(s.newBase, '', 'and the field is cleared for the next one')
    end,
  },

  {
    name = 'an untouched field adds nothing',
    run = function(harness)
      local s = drawWith(harness, '', 'add')
      t.eq(#s.bases, 1, 'only the seeded base is listed')
    end,
  },
}
