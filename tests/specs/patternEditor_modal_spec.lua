-- design/fx-patterns.md P3 step d: the modal editing surface. Pins that launch
-- raises the modal + sweeps on close, that the mini cmgr dispatches the editing
-- subset onto the checkout (a whitelisted command edits it, an excluded chord is
-- inert), and that an unconsumed Esc closes. Drives the real handleInput pass
-- against a controllable imgui; no grid draw.

local t       = require('support')
local util    = require('util')
local scratch = require('scratch')

-- Controllable imgui: the walk reads IsKeyPressed/IsKeyDown/GetKeyMods; mouse and
-- hover read false so handleMouse no-ops headless. Auto-viv assigns a stable id to
-- every Key_/Mod_ on first touch, so pageBindings and the test share ids by identity.
local nextId = 100
local fakeImGui = setmetatable({ Mod_None = 0 }, {
  __index = function(tbl, k) nextId = nextId + 1; rawset(tbl, k, nextId); return nextId end,
})
_G.reaper.ImGui_GetBuiltinPath = _G.reaper.ImGui_GetBuiltinPath or function() return '/stub' end

local pressed, down, curMods = {}, {}, 0
fakeImGui.GetKeyMods      = function() return curMods end
fakeImGui.IsKeyPressed    = function(_, k) return pressed[k] == true end
fakeImGui.IsKeyDown       = function(_, k) return down[k] == true end
fakeImGui.IsMouseClicked  = function() return false end
fakeImGui.IsMouseDown     = function() return false end
fakeImGui.IsWindowHovered = function() return false end
fakeImGui.IsAnyItemActive = function() return false end   -- no toolbar widget active headless
fakeImGui.GetWindowViewport   = function() return 0 end
fakeImGui.Viewport_GetWorkSize = function() return 1200, 800 end
-- pe:launch sizes the modal via gridPane:heightForRows -> ensureCellSize, which pushes the
-- grid font and measures a glyph; stub the font/style calls the auto-viv would hand back numbers.
fakeImGui.PushFont     = function() end
fakeImGui.PopFont      = function() end
fakeImGui.CalcTextSize = function() return 8, 14 end
fakeImGui.GetStyleVar  = function() return 4, 4 end

local function setKeys(keys, mods)
  pressed, down, curMods = {}, {}, mods or 0
  for _, k in ipairs(keys or {}) do pressed[k] = true; down[k] = true end
end

local fakeChrome = setmetatable({}, { __index = function() return function() end end })
local fakeGui    = { ctx = {}, font = 'grid', uiFont = 'ui', fontSize = { ui = 13 } }

-- Capture the open state so a test can invoke onClose the way modalHost would.
local function newModalHost()
  local mh = { kinds = {}, last = nil }
  function mh:registerKind(kind, render) self.kinds[kind] = render end
  function mh:open(state) self.last = state end
  return mh
end

local function loadPE(deps)
  package.preload['imgui'] = function() return function(_) return fakeImGui end end
  for _, m in ipairs({ 'imgui', 'keyDispatch', 'pageBindings', 'curveEditor', 'painter' }) do
    package.loaded[m] = nil
  end
  return util.instantiate('patternEditor', deps)
end

local fakeFacade = { get = function(name)
  if name == 'arrange' then
    return { ownerTrack = function(take) return reaper.GetMediaItemTake_Track(take) end }
  end
end }

local NOTES_BODY = {
  kind = 'notes', lengthPpq = 960,
  specs = {
    { lane = 1, ppq = 0,   endppq = 240, pitch = 60, vel = 100, detune = 0, delay = 0 },
    { lane = 1, ppq = 240, endppq = 480, pitch = 64, vel = 100, detune = 0, delay = 0 },
  },
}

local function noop() end

local function withEditor(harness)
  local h  = harness.mk()
  local mh = newModalHost()
  local pe = loadPE{ facade = fakeFacade, chrome = fakeChrome, gui = fakeGui, modalHost = mh }
  return h, pe, mh
end

return {
  {
    name = 'launch mints a checkout and raises the modal; onClose sweeps it',
    run = function(harness)
      local _, pe, mh = withEditor(harness)
      local strack = scratch.track()
      local before = reaper.CountTrackMediaItems(strack)

      pe:launch(NOTES_BODY, noop)
      t.truthy(pe:isOpen(), 'the editor is open after launch')
      t.eq(mh.last and mh.last.kind, 'patternEditor', 'launch raised the pattern-editor modal')
      t.eq(reaper.CountTrackMediaItems(strack), before + 1, 'a checkout is parked on scratch')

      mh.last.onClose()                       -- modalHost pcalls onClose on every dismissal
      t.eq(pe:isOpen(), false, 'onClose swept the checkout')
      t.eq(reaper.CountTrackMediaItems(strack), before, 'the checkout item is deleted')
    end,
  },

  {
    name = 'a whitelisted key dispatches on the mini cmgr; an excluded chord is inert',
    run = function(harness)
      local _, pe = withEditor(harness)
      pe:open(NOTES_BODY, noop)

      -- Super+X (editNoteFx) is excluded, so it is unbound on the mini cmgr and the
      -- walk does not consume it. Note-mutating effects need a prior draw to size the
      -- grid, so consumption is the headless seam for "bound + dispatched".
      setKeys({ fakeImGui.Key_X }, fakeImGui.Mod_Super)
      t.eq(pe:handleInput(function() end).consumed, false, 'an excluded command is inert')

      -- '.' (delete) is whitelisted -> bound + dispatched -> consumed.
      setKeys({ fakeImGui.Key_Period }, fakeImGui.Mod_None)
      t.eq(pe:handleInput(function() end).consumed, true, 'a whitelisted command dispatches')
    end,
  },

  {
    name = 'the chord gesture is gated off the pattern surface',
    run = function(harness)
      local _, pe = withEditor(harness)
      local writeThroughs = 0
      pe:open(NOTES_BODY, function() writeThroughs = writeThroughs + 1 end)

      -- gridPane registers letters as Key_A + offset; mirror that arithmetic so
      -- the auto-viv fake hands both sides the same id.
      local function letterKey(ch)
        return fakeImGui.Key_A + (string.byte(ch) - string.byte('a'))
      end

      -- Control: plain note entry writes through, so the seam observes edits.
      setKeys({ letterKey('x') }, fakeImGui.Mod_None)
      pe:handleInput(function() end)
      t.truthy(writeThroughs > 0, 'plain note entry writes through (control)')

      -- The same surface with Shift held must be inert: the pattern editor
      -- instantiates gridPane with chordEntry = false.
      writeThroughs = 0
      setKeys({ letterKey('c') }, fakeImGui.Mod_Shift)
      pe:handleInput(function() end)
      t.eq(writeThroughs, 0, 'Shift+notechar wrote nothing through')
    end,
  },

  {
    name = 'an unconsumed Esc closes the modal',
    run = function(harness)
      local _, pe = withEditor(harness)
      pe:open(NOTES_BODY, noop)
      local closedWith
      setKeys({ fakeImGui.Key_Escape }, fakeImGui.Mod_None)
      pe:handleInput(function(invoke) closedWith = invoke end)
      t.eq(closedWith, false, 'Esc invoked close(false)')
    end,
  },
}
