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
  g.Key_1 = g.Key_0 + 1
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

-- A generated family as manifest.lua declares one: members sharing a family table,
-- each carrying the unmasked token its declared chord is masked from. The bases
-- mirror the drop family's -- bare digits, a bare letter, then a Shift+letter.
local function installFamily(mgr)
  local family, entries = { label = 'Place slot', members = {} }, {}
  for index, base in ipairs{ '0', '1', 'A', 'Shift+A' } do
    local entry = { name = 'slot' .. (index - 1), label = 'Place slot ' .. (index - 1),
                    keys = { base }, family = family, base = base }
    util.add(family.members, entry); util.add(entries, entry)
  end
  mgr:installManifest({ global = { Slots = entries } }, I)
  return family
end

-- The single chord a family member holds, as (key, mods).
local function chordOf(mgr, name)
  local specs = mgr:keysFor(name)
  t.eq(#specs, 1, name .. ' holds exactly one chord')
  return mgr:keySpec(specs[1], I)
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
    -- A generated family (docs/commandManager.md § Manifest) rebinds whole: the
    -- captured chord's modifiers re-mask every member's own base token, so a member
    -- whose base already carries Shift keeps it under the new mask.
    name = 'rebindFamily re-masks every member from its base token',
    run = function()
      local cm     = fakeCm()
      local mgr    = newCommandManager(cm)
      local family = installFamily(mgr)
      mgr:rebindFamily(family, I.Mod_Alt, I)
      local key, mods = chordOf(mgr, 'slot0')
      t.eq(key, I.Key_0); t.eq(mods, I.Mod_Alt)
      key, mods = chordOf(mgr, 'slot3')
      t.eq(key, I.Key_A)
      t.eq(mods, I.Mod_Alt | I.Mod_Shift, 'the base\'s own Shift survives the mask')
      -- The persisted token is the live spec read back through the codec.
      local back      = mgr:specForToken(cm._store.keyBindings.global.slot3[1], I)
      local key2, m2  = mgr:keySpec(back, I)
      t.eq(key2, key); t.eq(m2, mods, 'persisted as the token for the same chord')
    end,
  },

  {
    -- A family takes a mask only if every chord it would claim is free. Its own
    -- members' chords are vacated by the rebind, so they are not in the way.
    name = 'familyVictim is silent when the whole mask is free',
    run = function()
      local mgr    = newCommandManager(fakeCm())
      local family = installFamily(mgr)
      t.eq(mgr:familyVictim(family, I.Mod_Alt, I), nil, 'Alt is free')
      t.eq(mgr:familyVictim(family, I.Mod_None, I), nil, 'the family may keep the mask it has')
    end,
  },

  {
    name = 'familyVictim names the command holding one of the proposed chords',
    run = function()
      local mgr    = newCommandManager(fakeCm())
      local family = installFamily(mgr)
      mgr:rebind('global', 'undo', { { I.Key_1, I.Mod_Alt } }, I)
      local victim, spec = mgr:familyVictim(family, I.Mod_Alt, I)
      t.eq(victim, 'undo')
      local key, mods = mgr:keySpec(spec, I)
      t.eq(key, I.Key_1); t.eq(mods, I.Mod_Alt, 'the chord reported is the one that collided')
    end,
  },

  {
    -- Shift over these bases folds 'A' and 'Shift+A' onto one chord, so the
    -- collision is inside the proposal rather than against the live keymap.
    name = 'familyVictim catches two members collapsing onto one chord',
    run = function()
      local mgr    = newCommandManager(fakeCm())
      local family = installFamily(mgr)
      local victim, spec = mgr:familyVictim(family, I.Mod_Shift, I)
      t.eq(victim, 'slot2', 'the member that claimed the chord first')
      local key, mods = mgr:keySpec(spec, I)
      t.eq(key, I.Key_A); t.eq(mods, I.Mod_Shift)
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
