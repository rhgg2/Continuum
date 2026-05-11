-- commandManager: doBefore/doAfter accept either a single name or a
-- list. The list form is sugar; pin that it composes hooks in order
-- and that the single-name form still works.

local t = require('support')

require('commandManager')

local function fresh()
  local mgr = newCommandManager(nil)
  local log = {}
  mgr:registerAll{
    a = function() log[#log + 1] = 'A' end,
    b = function() log[#log + 1] = 'B' end,
    c = function() log[#log + 1] = 'C' end,
  }
  return mgr, log
end

return {
  {
    name = 'doBefore with a string still wraps a single command',
    run = function()
      local mgr, log = fresh()
      mgr:doBefore('a', function() log[#log + 1] = 'pre' end)
      mgr:invoke('a')
      mgr:invoke('b')
      t.deepEq(log, { 'pre', 'A', 'B' })
    end,
  },

  {
    name = 'doAfter with a list applies the hook to every named command',
    run = function()
      local mgr, log = fresh()
      mgr:doAfter({ 'a', 'b' }, function() log[#log + 1] = 'post' end)
      mgr:invoke('a')
      mgr:invoke('b')
      mgr:invoke('c')
      t.deepEq(log, { 'A', 'post', 'B', 'post', 'C' })
    end,
  },

  {
    name = 'doBefore with a list fires before each named command',
    run = function()
      local mgr, log = fresh()
      mgr:doBefore({ 'a', 'c' }, function() log[#log + 1] = 'pre' end)
      mgr:invoke('a')
      mgr:invoke('b')
      mgr:invoke('c')
      t.deepEq(log, { 'pre', 'A', 'B', 'pre', 'C' })
    end,
  },

  {
    name = 'list form composes with prior single-name wraps',
    run = function()
      local mgr, log = fresh()
      mgr:doAfter('a', function() log[#log + 1] = 'a-after' end)
      mgr:doAfter({ 'a', 'b' }, function() log[#log + 1] = 'shared-after' end)
      mgr:invoke('a')
      mgr:invoke('b')
      -- 'a' carries both wraps (inner 'a-after' set first, outer 'shared-after' stacks);
      -- 'b' carries only the shared one.
      t.deepEq(log, { 'A', 'a-after', 'shared-after', 'B', 'shared-after' })
    end,
  },

  {
    name = 'scope command resolves only when its scope is active',
    run = function()
      local mgr = newCommandManager(nil)
      local log = {}
      mgr:scope('tracker'):register('cursorUp', function() log[#log + 1] = 'tracker' end)
      mgr:invoke('cursorUp')           -- no active scope: miss
      mgr:setActive('tracker')
      mgr:invoke('cursorUp')           -- active: hit
      mgr:setActive(nil)
      mgr:invoke('cursorUp')           -- inactive again: miss
      t.deepEq(log, { 'tracker' })
    end,
  },

  {
    name = 'active scope shadows global; clearing it falls back',
    run = function()
      local mgr = newCommandManager(nil)
      local log = {}
      mgr:register('save', function() log[#log + 1] = 'global' end)
      mgr:scope('tracker'):register('save', function() log[#log + 1] = 'tracker' end)
      mgr:setActive('tracker'); mgr:invoke('save')
      mgr:setActive(nil);       mgr:invoke('save')
      t.deepEq(log, { 'tracker', 'global' })
    end,
  },

  {
    name = 'doAfter on a scope does not leak to global',
    run = function()
      local mgr = newCommandManager(nil)
      local log = {}
      mgr:register('act', function() log[#log + 1] = 'G' end)
      local s = mgr:scope('tracker')
      s:register('act', function() log[#log + 1] = 'S' end)
      s:doAfter('act', function() log[#log + 1] = 'after' end)
      mgr:invoke('act')                -- global: 'G', no after
      mgr:setActive('tracker'); mgr:invoke('act')   -- scope: 'S', then 'after'
      t.deepEq(log, { 'G', 'S', 'after' })
    end,
  },

  {
    name = 'invoke on a global-only name still works regardless of active scope',
    run = function()
      local mgr = newCommandManager(nil)
      local log = {}
      mgr:register('quit', function() log[#log + 1] = 'quit' end)
      mgr:scope('tracker')   -- created, but no shadow
      mgr:setActive('tracker')
      mgr:invoke('quit')
      t.deepEq(log, { 'quit' })
    end,
  },

  {
    name = 'keychain returns active-then-root; root only when no active',
    run = function()
      local mgr = newCommandManager(nil)
      mgr:bind('playPause', { 1 })
      mgr:scope('tracker'):bind('cursorUp', { 2 })

      local k1 = mgr:keychain()
      t.eq(#k1, 1,                "no active scope: only root")
      t.eq(k1[1].playPause[1], 1, "root keymap is the only entry")

      mgr:setActive('tracker')
      local k2 = mgr:keychain()
      t.eq(#k2, 2,                "active scope present: two entries")
      t.eq(k2[1].cursorUp[1],   2, "active first")
      t.eq(k2[2].playPause[1],  1, "root second")
    end,
  },

  {
    name = 'keysFor walks the chain; active shadows root',
    run = function()
      local mgr = newCommandManager(nil)
      mgr:bind('foo', { 1 })
      mgr:bind('bar', { 2 })
      mgr:scope('tracker'):bind('foo', { 99 })
      mgr:setActive('tracker')

      t.eq(mgr:keysFor('foo')[1], 99, "active scope shadows root for 'foo'")
      t.eq(mgr:keysFor('bar')[1], 2,  "falls through to root for 'bar'")
      t.eq(mgr:keysFor('absent'), nil, "absent name returns nil")
    end,
  },

  {
    name = 'prefix: inactive by default; consume returns nil',
    run = function()
      local mgr = newCommandManager(nil)
      t.eq(mgr:isPrefixActive(), false)
      t.eq(mgr:consumePrefix(), nil)
    end,
  },

  {
    name = 'prefix: begin → digits → finish parses integer',
    run = function()
      local mgr = newCommandManager(nil)
      mgr:beginPrefix()
      t.eq(mgr:isPrefixActive(), true)
      mgr:appendPrefix('1'); mgr:appendPrefix('2'); mgr:appendPrefix('0')
      mgr:finishPrefix()
      t.eq(mgr:isPrefixActive(), false)
      t.eq(mgr:consumePrefix(), 120)
      t.eq(mgr:consumePrefix(), nil, 'consume clears')
    end,
  },

  {
    name = 'prefix: fraction a/b parses to a number',
    run = function()
      local mgr = newCommandManager(nil)
      mgr:beginPrefix()
      mgr:appendPrefix('4'); mgr:appendPrefix('/'); mgr:appendPrefix('3')
      mgr:finishPrefix()
      local v = mgr:consumePrefix()
      t.truthy(v); t.truthy(math.abs(v - 4/3) < 1e-12)
    end,
  },

  {
    name = 'prefix: empty buffer at finish yields nil',
    run = function()
      local mgr = newCommandManager(nil)
      mgr:beginPrefix()
      mgr:finishPrefix()
      t.eq(mgr:consumePrefix(), nil)
    end,
  },

  {
    name = 'prefix: cancel discards buffer and any pending',
    run = function()
      local mgr = newCommandManager(nil)
      mgr:beginPrefix(); mgr:appendPrefix('7')
      mgr:cancelPrefix()
      t.eq(mgr:isPrefixActive(), false)
      t.eq(mgr:consumePrefix(), nil)
    end,
  },

  {
    name = 'prefix: only one slash accepted',
    run = function()
      local mgr = newCommandManager(nil)
      mgr:beginPrefix()
      mgr:appendPrefix('1'); mgr:appendPrefix('/')
      mgr:appendPrefix('2'); mgr:appendPrefix('/')   -- second / dropped
      mgr:appendPrefix('3')
      mgr:finishPrefix()
      local v = mgr:consumePrefix()
      t.truthy(v); t.truthy(math.abs(v - 1/23) < 1e-12)
    end,
  },

  {
    name = 'prefix: malformed buffer (e.g. lone slash) finishes to nil',
    run = function()
      local mgr = newCommandManager(nil)
      mgr:beginPrefix(); mgr:appendPrefix('/')
      mgr:finishPrefix()
      t.eq(mgr:consumePrefix(), nil)
    end,
  },

  {
    name = 'prefix: consumePrefixRational returns (n, d) for an integer',
    run = function()
      local mgr = newCommandManager(nil)
      mgr:beginPrefix(); mgr:appendPrefix('5')
      mgr:finishPrefix()
      local n, d = mgr:consumePrefixRational()
      t.eq(n, 5); t.eq(d, 1)
    end,
  },

  {
    name = 'prefix: consumePrefixRational returns (n, d) for a fraction; consume clears',
    run = function()
      local mgr = newCommandManager(nil)
      mgr:beginPrefix(); mgr:appendPrefix('4'); mgr:appendPrefix('/'); mgr:appendPrefix('3')
      mgr:finishPrefix()
      local n, d = mgr:consumePrefixRational()
      t.eq(n, 4); t.eq(d, 3)
      local n2, d2 = mgr:consumePrefixRational()
      t.eq(n2, nil); t.eq(d2, nil)
    end,
  },

  {
    name = 'prefix: consumePrefix and consumePrefixRational both clear all state',
    run = function()
      local mgr = newCommandManager(nil)
      mgr:beginPrefix(); mgr:appendPrefix('7')
      mgr:finishPrefix()
      t.eq(mgr:consumePrefix(), 7)
      local n, d = mgr:consumePrefixRational()
      t.eq(n, nil); t.eq(d, nil)
    end,
  },

  {
    name = 'prefix: consumePrefixRational on empty buffer yields (nil, nil)',
    run = function()
      local mgr = newCommandManager(nil)
      local n, d = mgr:consumePrefixRational()
      t.eq(n, nil); t.eq(d, nil)
    end,
  },

  {
    name = 'keySpec decodes bare key and chord',
    run = function()
      local mgr = newCommandManager(nil)
      local ImGui = { Mod_None = 0, Mod_Ctrl = 4, Mod_Shift = 8 }

      local k, m = mgr:keySpec(42, ImGui)
      t.eq(k, 42, "bare key passes through")
      t.eq(m, 0,  "bare key has Mod_None")

      local k2, m2 = mgr:keySpec({ 7, ImGui.Mod_Ctrl, ImGui.Mod_Shift }, ImGui)
      t.eq(k2, 7,    "chord key extracted")
      t.eq(m2, 4|8,  "chord mods OR'd together")
    end,
  },
}
