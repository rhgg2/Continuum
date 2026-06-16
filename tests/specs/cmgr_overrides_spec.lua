-- commandManager binding overrides (step 0): the token codec and the
-- persist/reload plumbing behind clickable keybinding customisation.
-- Tokens are the stable ASCII on-disk form ('Ctrl+Z'); rebind writes both
-- the live keymap and the persisted tokens, loadOverrides reads them back.

local t    = require('support')
local util = require('util')

local function newCommandManager(cm)
  return util.instantiate('commandManager', { cm = cm })
end

-- One deterministic fake ImGui, reused across tests: token tables are built
-- lazily from the first ImGui seen by an mgr instance, so the integer
-- assignments must stay stable. Disjoint blocks keep base+offset keys
-- (A.., 0.., Keypad0..) from colliding with the named keys.
local I = (function()
  local g = { Mod_None = 0, Mod_Ctrl = 0x1000, Mod_Shift = 0x2000, Mod_Alt = 0x4000, Mod_Super = 0x8000 }
  g.Key_A, g.Key_0, g.Key_Keypad0 = 100, 200, 300
  for i = 1, 12 do g['Key_F' .. i] = 400 + i end
  local named = { 'Space', 'Enter', 'KeypadEnter', 'Escape', 'Tab', 'Backspace',
    'Delete', 'Insert', 'Home', 'End', 'PageUp', 'PageDown', 'UpArrow', 'DownArrow',
    'LeftArrow', 'RightArrow', 'Comma', 'Period', 'Slash', 'Semicolon', 'Apostrophe',
    'Minus', 'Equal', 'LeftBracket', 'RightBracket', 'GraveAccent', 'Backslash',
    'KeypadSubtract' }
  for i, nm in ipairs(named) do g['Key_' .. nm] = 500 + i end
  g.Key_Z = g.Key_A + 25
  g.Key_Y = g.Key_A + 24
  return g
end)()

-- Deep-copy at the boundary mirrors the real configManager contract, so a test
-- can't accidentally rely on aliasing cm's internal state.
local function fakeCm(initial)
  local function deep(v)
    if type(v) ~= 'table' then return v end
    local r = {}; for k, x in pairs(v) do r[k] = deep(x) end; return r
  end
  local store = { keyBindings = deep(initial or {}) }
  return {
    get = function(_, key) return deep(store[key]) end,
    set = function(_, _level, key, value) store[key] = deep(value) end,
    _store = store,
  }
end

return {
  {
    name = 'token codec round-trips bare / modified / multi-mod / keypad / punctuation',
    run = function()
      local mgr = newCommandManager(nil)
      local function roundtrip(spec, expect)
        local tok = mgr:tokenForSpec(spec, I)
        t.eq(tok, expect, 'spec encodes to expected token')
        local back = mgr:specForToken(tok, I)
        local k1, m1 = mgr:keySpec(spec, I)
        local k2, m2 = mgr:keySpec(back, I)
        t.eq(k2, k1, 'key round-trips'); t.eq(m2, m1, 'mods round-trip')
      end
      roundtrip(I.Key_Space, 'Space')
      roundtrip({ I.Key_Z, I.Mod_Ctrl }, 'Ctrl+Z')
      roundtrip({ I.Key_Z, I.Mod_Ctrl, I.Mod_Shift }, 'Ctrl+Shift+Z')
      roundtrip(I.Key_KeypadEnter, 'KeypadEnter')
      roundtrip(I.Key_Comma, 'Comma')
    end,
  },

  {
    name = 'specForToken reports unknown key and unknown modifier',
    run = function()
      local mgr = newCommandManager(nil)
      local spec, err = mgr:specForToken('Ctrl+Zz', I)
      t.eq(spec, nil); t.truthy(err:find('unknown key'))
      spec, err = mgr:specForToken('Bogus+Z', I)
      t.eq(spec, nil); t.truthy(err:find('unknown modifier'))
    end,
  },

  {
    name = 'rebind updates the live keymap and persists tokens',
    run = function()
      local cm  = fakeCm()
      local mgr = newCommandManager(cm)
      mgr:rebind('global', 'undo', { { I.Key_Z, I.Mod_Ctrl } }, I)
      local specs = mgr:keysFor('undo')
      t.truthy(specs, 'binding is live on the keymap')
      local k, m = mgr:keySpec(specs[1], I)
      t.eq(k, I.Key_Z); t.eq(m, I.Mod_Ctrl)
      t.deepEq(cm._store.keyBindings.global.undo, { 'Ctrl+Z' }, 'persisted as a token')
    end,
  },

  {
    name = 'rebind to an empty list explicitly unbinds and persists the empty array',
    run = function()
      local cm  = fakeCm()
      local mgr = newCommandManager(cm)
      mgr:rebind('global', 'undo', {}, I)
      t.eq(#mgr:keysFor('undo'), 0, 'no live bindings remain')
      t.deepEq(cm._store.keyBindings.global.undo, {}, 'empty array persisted')
    end,
  },

  {
    name = 'loadOverrides re-applies persisted tokens onto a fresh manager',
    run = function()
      local cm   = fakeCm()
      local mgr1 = newCommandManager(cm)
      mgr1:rebind('global', 'undo', { { I.Key_Z, I.Mod_Ctrl } }, I)

      local mgr2 = newCommandManager(cm)
      t.eq(mgr2:keysFor('undo'), nil, 'fresh manager has no binding before load')
      mgr2:loadOverrides(I)
      local specs = mgr2:keysFor('undo')
      t.truthy(specs, 'binding survives the reload')
      local k, m = mgr2:keySpec(specs[1], I)
      t.eq(k, I.Key_Z); t.eq(m, I.Mod_Ctrl)
    end,
  },

  {
    name = 'loadOverrides skips malformed tokens, keeps the good ones, tolerates unknown scopes',
    run = function()
      local cm = fakeCm{
        nonsuch = { foo  = { 'Ctrl+Z' } },                       -- unknown scope: ignored
        global  = { undo = { 'Ctrl+Z', 'Ctrl+Zz', 'Bogus+Y', 'Ctrl+Y' } },
      }
      local mgr = newCommandManager(cm)
      mgr:loadOverrides(I)                                        -- must not raise
      local specs = mgr:keysFor('undo')
      t.eq(#specs, 2, 'two good tokens kept; bad key + bad mod dropped')
    end,
  },
}
