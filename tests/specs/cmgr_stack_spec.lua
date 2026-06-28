-- commandManager: scope stack + modal/passthrough resolution.

local t = require('support')
local util = require('util')

local function newCmgr() return util.instantiate('commandManager', { cm = nil }) end

local fakeImGui = { Mod_None = 0, Mod_Ctrl = 4, Mod_Shift = 8 }

local function newModalScope(mgr, passthrough)
  local s = mgr:scope('region')
  s.modal       = true
  s.passthrough = passthrough or {}
  return s
end

local function newSpringScope(mgr, opts)
  local s = mgr:scope('region')
  s.springLoaded = true
  s.redirect     = opts.redirect
  s.keepAlive    = opts.keepAlive
  s.onBail       = opts.onBail
  return s
end

return {
  {
    name = 'push/pop is LIFO; pop asserts top identity',
    run = function()
      local mgr = newCmgr()
      mgr:push('tracker')
      mgr:push('region')
      t.eq(mgr.stack[2].commands, mgr:scope('tracker').commands)
      t.eq(mgr.stack[3].commands, mgr:scope('region').commands)
      mgr:pop('region')
      mgr:pop('tracker')
      t.eq(#mgr.stack, 1, 'global remains at the bottom')
    end,
  },

  {
    name = 'pop of a non-top scope raises',
    run = function()
      local mgr = newCmgr()
      mgr:push('tracker'); mgr:push('region')
      local ok = pcall(function() mgr:pop('tracker') end)
      t.falsy(ok, 'pop of non-top scope should raise')
    end,
  },

  {
    name = 'modal scope without passthrough blocks lower commands',
    run = function()
      local mgr = newCmgr()
      local log = {}
      mgr:scope('tracker'):register('paste', function() log[#log+1] = 'paste' end)
      mgr:push('tracker')
      mgr:invoke('paste'); t.deepEq(log, { 'paste' })

      newModalScope(mgr, {})
      mgr:push('region')
      mgr:invoke('paste'); t.deepEq(log, { 'paste' }, 'modal swallows non-passthrough')
    end,
  },

  {
    name = 'passthrough exempts named commands',
    run = function()
      local mgr = newCmgr()
      local log = {}
      mgr:scope('tracker'):register('cursorUp', function() log[#log+1] = 'up' end)
      mgr:scope('tracker'):register('paste',    function() log[#log+1] = 'paste' end)
      mgr:push('tracker')

      newModalScope(mgr, { cursorUp = true })
      mgr:push('region')

      mgr:invoke('cursorUp')   -- passes through
      mgr:invoke('paste')      -- blocked
      t.deepEq(log, { 'up' })
    end,
  },

  {
    name = 'keysFor honors modal: shadow first, then pass-through, else nil',
    run = function()
      local mgr = newCmgr()
      mgr:bind('quit', { 100 })           -- on global
      mgr:scope('tracker'):bind('cursorUp', { 1 })
      mgr:scope('tracker'):bind('paste',    { 2 })
      mgr:push('tracker')

      newModalScope(mgr, { cursorUp = true })
      mgr:scope('region'):bind('regionCommit', { 99 })
      mgr:push('region')

      t.eq(mgr:keysFor('regionCommit')[1], 99, 'top-scope binding')
      t.eq(mgr:keysFor('cursorUp')[1],     1,  'pass-through reaches tracker')
      t.eq(mgr:keysFor('paste'),           nil,'blocked by modal')
      t.eq(mgr:keysFor('quit'),            nil,'global also blocked')
    end,
  },

  {
    name = 'keychain top-down; modal filters lower keymaps to passthrough names',
    run = function()
      local mgr = newCmgr()
      mgr:bind('quit', { 100 })
      mgr:scope('tracker'):bindAll{
        cursorUp = { 1 },
        paste    = { 2 },
      }
      mgr:push('tracker')

      local k = mgr:keychain()
      t.eq(#k, 2, 'no modal: full stack')
      t.eq(k[1].cursorUp[1], 1)
      t.eq(k[2].quit[1],     100)

      local region = newModalScope(mgr, { cursorUp = true })
      region:bind('regionCommit', { 99 })
      mgr:push('region')

      local k2 = mgr:keychain()
      t.eq(#k2, 3,                       'modal still emits one entry per stack level')
      t.eq(k2[1].regionCommit[1], 99,    'region keymap intact')
      t.eq(k2[2].cursorUp[1],     1,     'tracker filtered: cursorUp survives')
      t.eq(k2[2].paste,           nil,   'tracker filtered: paste stripped')
      t.eq(k2[3].quit,            nil,   'global filtered: quit stripped')
    end,
  },

  {
    name = 'commandAtKey: bare + chord match, mods distinguish, skips exceptName, nil when free',
    run = function()
      local mgr = newCmgr()
      mgr:bind('quit', { 100 })
      mgr:scope('tracker'):bindAll{ cursorUp = { 1 }, paste = { { 2, fakeImGui.Mod_Ctrl } } }
      mgr:push('tracker')

      t.eq(mgr:commandAtKey(1, nil, fakeImGui),                       'cursorUp', 'bare key match')
      t.eq(mgr:commandAtKey({ 2, fakeImGui.Mod_Ctrl }, nil, fakeImGui), 'paste',  'chord match')
      t.eq(mgr:commandAtKey(100, nil, fakeImGui),                     'quit',     'reaches global')
      t.eq(mgr:commandAtKey(1, 'cursorUp', fakeImGui),               nil,        'skips the edited command')
      t.eq(mgr:commandAtKey(2, nil, fakeImGui),                      nil,        'bare 2 != Ctrl+2: free')
      t.eq(mgr:commandAtKey(999, nil, fakeImGui),                    nil,        'unbound chord: free')
    end,
  },

  {
    name = 'commandAtKey: top-down shadowing — top scope wins on a shared key',
    run = function()
      local mgr = newCmgr()
      mgr:bind('globalThing', { 5 })
      mgr:scope('tracker'):bind('trackerThing', { 5 })
      mgr:push('tracker')
      t.eq(mgr:commandAtKey(5, nil, fakeImGui), 'trackerThing', 'top scope shadows global')
    end,
  },

  {
    name = 'commandAtKey: modal-without-passthrough hides a lower binding from conflict',
    run = function()
      local mgr = newCmgr()
      mgr:scope('tracker'):bind('paste', { 2 })
      mgr:push('tracker')
      newModalScope(mgr, {})
      mgr:push('region')
      t.eq(mgr:commandAtKey(2, nil, fakeImGui), nil, 'modal blocks the lower binding')
    end,
  },

  {
    name = 'bindingSite: bound scope when reachable; gate scope when unbound; global for root',
    run = function()
      local mgr = newCmgr()
      mgr:register('quit', function() end)
      mgr:scope('tracker'):register('paste', function() end)
      mgr:scope('tracker'):bind('paste', { 2 })
      mgr:scope('tracker'):register('cursorUp', function() end)   -- registered, never bound
      mgr:push('tracker')

      t.eq(mgr:bindingSite('paste'),    'tracker', 'edit the scope that binds it')
      t.eq(mgr:bindingSite('cursorUp'), 'tracker', 'unbound: edit the gate scope')
      t.eq(mgr:bindingSite('quit'),     'global',  'root command edits global')
    end,
  },

  {
    name = 'mgr.commands is flat; mgr.keymap aliases global keymap',
    run = function()
      local mgr = newCmgr()
      mgr:register('save', function() end)
      mgr:bind    ('save', { 7 })
      t.truthy(mgr.commands.save,                    'mgr.commands carries ungated registrations')
      t.eq    (mgr.keymap.save[1],   7,              'mgr.keymap aliases global.keymap')
      t.eq    (mgr.scopes.global.keymap, mgr.keymap, 'global.keymap is mgr.keymap')
    end,
  },

  ----- spring-loaded scope (region authoring overlay)

  {
    name = 'spring redirect reinterprets a foreign command, stays armed',
    run = function()
      local mgr = newCmgr()
      local log = {}
      mgr:scope('tracker'):register('paste', function() log[#log+1] = 'paste' end)
      mgr:push('tracker')
      local bailed = false
      newSpringScope(mgr, {
        redirect = { paste = function() log[#log+1] = 'instance' end },
        onBail   = function() bailed = true end,
      })
      mgr:push('region')
      mgr:invoke('paste')
      t.deepEq(log, { 'instance' }, 'redirect ran instead of tracker paste')
      t.falsy(bailed, 'redirect does not bail')
      t.eq(mgr.stack[#mgr.stack], mgr:scope('region'), 'still armed')
    end,
  },

  {
    name = 'spring redirect receives the pending prefix (defaults 1)',
    run = function()
      local mgr = newCmgr()
      local got
      mgr:push('tracker')
      newSpringScope(mgr, { redirect = { nudge = function(p) got = p end } })
      mgr:push('region')
      mgr:invoke('nudge')
      t.eq(got, 1, 'prefix defaults to 1')
    end,
  },

  {
    name = 'spring keepAlive command runs and stays armed',
    run = function()
      local mgr = newCmgr()
      local log = {}
      mgr:scope('tracker'):register('cursorUp', function() log[#log+1] = 'up' end)
      mgr:push('tracker')
      local bailed = false
      newSpringScope(mgr, { keepAlive = { cursorUp = true },
                            onBail = function() bailed = true end })
      mgr:push('region')
      mgr:invoke('cursorUp')
      t.deepEq(log, { 'up' }, 'keepAlive command ran')
      t.falsy(bailed, 'keepAlive does not bail')
      t.eq(mgr.stack[#mgr.stack], mgr:scope('region'), 'still armed')
    end,
  },

  {
    name = 'spring foreign command bails then dispatches (execute-through)',
    run = function()
      local mgr = newCmgr()
      local log = {}
      mgr:scope('tracker'):register('someOther', function() log[#log+1] = 'other' end)
      mgr:push('tracker')
      local region
      region = newSpringScope(mgr, {
        onBail = function() mgr:pop(region); log[#log+1] = 'bail' end })
      mgr:push('region')
      mgr:invoke('someOther')
      t.deepEq(log, { 'bail', 'other' }, 'bailed first, then the command ran')
      t.eq(mgr.stack[#mgr.stack], mgr:scope('tracker'), 'scope popped')
    end,
  },

  {
    name = 'spring own command does not auto-bail',
    run = function()
      local mgr = newCmgr()
      local log = {}
      mgr:push('tracker')
      local region
      region = newSpringScope(mgr, {
        onBail = function() log[#log+1] = 'autobail' end })
      region:register('regionBail', function() log[#log+1] = 'ran'; mgr:pop(region) end)
      mgr:push('region')
      mgr:invoke('regionBail')
      t.deepEq(log, { 'ran' }, 'own command ran without auto-bail')
      t.eq(mgr.stack[#mgr.stack], mgr:scope('tracker'), 'its body popped explicitly')
    end,
  },
}
