-- keyDispatch: the prefix-capture + keychain walk extracted from coordinator
-- (design/fx-patterns.md P3 step a). Now an importable module the fx-pattern
-- mini modal reuses, so pin the dispatch contract directly: consume/first-hit,
-- commandHeld hold-tracking, the acceptCmds gate, prefix capture + finish,
-- false-declines, and the pageSuppressed root narrowing.

local t    = require('support')
local util = require('util')

-- Controllable fake ImGui: a test sets which keys are pressed/held + the mod
-- mask, then reads back what the walk did.
local fakeImGui = { Mod_None = 0, Mod_Ctrl = 1, Mod_Super = 2, Mod_Shift = 4, Mod_Alt = 8,
                    Key_Slash = 200, Key_Escape = 201,
                    Key_A = 300, Key_B = 301, Key_C = 302, Key_D = 303, Key_E = 304 }
for d = 0, 9 do fakeImGui['Key_' .. d] = 100 + d end

local pressed, down, curMods = {}, {}, 0
function fakeImGui.GetKeyMods(_)      return curMods            end
function fakeImGui.IsKeyPressed(_, k) return pressed[k] == true end
function fakeImGui.IsKeyDown(_, k)    return down[k]    == true end

-- A pressed key is also down; `down` alone models a hold with no fresh press.
local function setKeys(opts)
  pressed, down, curMods = {}, {}, opts.mods or 0
  for _, k in ipairs(opts.pressed or {}) do pressed[k] = true; down[k] = true end
  for _, k in ipairs(opts.down    or {}) do down[k] = true end
end

_G.reaper.ImGui_GetBuiltinPath = _G.reaper.ImGui_GetBuiltinPath or function() return '/stub' end

-- Rebind imgui to ours before loading keyDispatch: earlier specs' module-load
-- preloads cache a different fake, so nil both and re-require (curveEditor idiom).
local function loadKD()
  package.preload['imgui'] = function() return function(_) return fakeImGui end end
  package.loaded['imgui']       = nil
  package.loaded['keyDispatch'] = nil
  return require('keyDispatch')
end

-- Fresh real cmgr with commands bound to bare (Mod_None) keys; the returned log
-- records which bodies ran and the last prefix arg one received.
local function freshCmgr()
  local cmgr = util.instantiate('commandManager', { cm = nil })
  local log  = { fired = {}, arg = nil }
  cmgr:registerAll{
    alpha   = function()  log.fired[#log.fired + 1] = 'alpha'   end,
    beta    = function()  log.fired[#log.fired + 1] = 'beta'    end,
    counted = function(n) log.fired[#log.fired + 1] = 'counted'; log.arg = n end,
    decline = function()  log.fired[#log.fired + 1] = 'decline'; return false end,
  }
  cmgr:bind('alpha',   { fakeImGui.Key_A })
  cmgr:bind('beta',    { fakeImGui.Key_B })
  cmgr:bind('counted', { fakeImGui.Key_C })
  cmgr:bind('decline', { fakeImGui.Key_D })
  return cmgr, log
end

return {
  {
    name = 'a pressed bound key fires its command, consumes, and reports as held',
    run = function()
      local cmgr, log = freshCmgr()
      local kd = loadKD()
      setKeys{ pressed = { fakeImGui.Key_A } }
      local r = kd.dispatchKeys({ acceptCmds = true }, cmgr, {})
      t.eq(r.consumed, true, 'a pressed bound key consumes')
      t.deepEq(log.fired, { 'alpha' }, "only the pressed key's command fires")
      t.eq(r.commandHeld[fakeImGui.Key_A], true, 'the down bound key is reported held')
    end,
  },

  {
    name = 'acceptCmds=false short-circuits: nothing dispatched',
    run = function()
      local cmgr, log = freshCmgr()
      local kd = loadKD()
      setKeys{ pressed = { fakeImGui.Key_A } }
      local r = kd.dispatchKeys({ acceptCmds = false }, cmgr, {})
      t.eq(r.consumed, false, 'suppressed dispatch never consumes')
      t.deepEq(log.fired, {}, 'no command runs while suppressed')
    end,
  },

  {
    name = 'a held (not freshly pressed) bound key reports in commandHeld but does not fire',
    run = function()
      local cmgr, log = freshCmgr()
      local kd = loadKD()
      setKeys{ down = { fakeImGui.Key_A } }
      local r = kd.dispatchKeys({ acceptCmds = true }, cmgr, {})
      t.eq(r.consumed, false, 'holding without a fresh press does not consume')
      t.eq(r.commandHeld[fakeImGui.Key_A], true, 'held bound key still reported for note-entry gating')
      t.deepEq(log.fired, {}, 'no command fired on a mere hold')
    end,
  },

  {
    name = 'a digit while a prefix is open is captured, not dispatched',
    run = function()
      local cmgr, log = freshCmgr()
      local kd = loadKD()
      cmgr:beginPrefix()
      setKeys{ pressed = { fakeImGui.Key_5 } }
      local r = kd.dispatchKeys({ acceptCmds = true }, cmgr, {})
      t.eq(r.consumed, true, 'the digit is consumed by prefix capture')
      t.eq(cmgr:isPrefixActive(), true, 'prefix stays open across a digit')
      t.deepEq(log.fired, {}, 'no command dispatched while accumulating')
    end,
  },

  {
    name = 'with a prefix open, a bound key freezes the prefix, dispatches, and clears it',
    run = function()
      local cmgr, log = freshCmgr()
      local kd = loadKD()
      cmgr:beginPrefix()
      setKeys{ pressed = { fakeImGui.Key_5 } }
      kd.dispatchKeys({ acceptCmds = true }, cmgr, {})   -- accumulate '5'
      setKeys{ pressed = { fakeImGui.Key_C } }
      local r = kd.dispatchKeys({ acceptCmds = true }, cmgr, {})
      t.eq(r.consumed, true, 'the bound key dispatches through the frozen prefix')
      t.deepEq(log.fired, { 'counted' }, 'the prefixed command fired once')
      t.eq(cmgr:isPrefixActive(), false, 'prefix state cleared after the prefixed invoke')
    end,
  },

  {
    name = 'a command returning false declines: not consumed, key released from commandHeld',
    run = function()
      local cmgr, log = freshCmgr()
      local kd = loadKD()
      setKeys{ pressed = { fakeImGui.Key_D } }
      local r = kd.dispatchKeys({ acceptCmds = true }, cmgr, {})
      t.eq(r.consumed, false, 'a command returning false declines the dispatch')
      t.eq(r.commandHeld[fakeImGui.Key_D], nil, 'the declined key is released from commandHeld')
      t.deepEq(log.fired, { 'decline' }, 'the body still ran')
    end,
  },

  {
    name = 'pageSuppressed narrows the walk to root: page bindings die, globals live',
    run = function()
      local cmgr, log = freshCmgr()
      local page = cmgr:scope('page')
      page:register('pageOnly', function() log.fired[#log.fired + 1] = 'pageOnly' end)
      page:bind('pageOnly', { fakeImGui.Key_E })
      cmgr:push(page)
      local kd = loadKD()

      setKeys{ pressed = { fakeImGui.Key_E } }
      t.eq(kd.dispatchKeys({ acceptCmds = true }, cmgr, {}).consumed, true, 'page command reachable normally')
      t.deepEq(log.fired, { 'pageOnly' }, 'page command fired without suppression')

      log.fired = {}
      setKeys{ pressed = { fakeImGui.Key_E } }
      t.eq(kd.dispatchKeys({ acceptCmds = true, pageSuppressed = true }, cmgr, {}).consumed, false,
           'page binding is invisible when page-suppressed')
      setKeys{ pressed = { fakeImGui.Key_A } }
      kd.dispatchKeys({ acceptCmds = true, pageSuppressed = true }, cmgr, {})
      t.deepEq(log.fired, { 'alpha' }, 'global binding still fires under pageSuppressed')
    end,
  },
}
