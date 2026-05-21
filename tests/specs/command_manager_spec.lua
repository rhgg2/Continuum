-- commandManager: doBefore/doAfter accept either a single name or a
-- list. The list form is sugar; pin that it composes hooks in order
-- and that the single-name form still works.

local t = require('support')
local util = require('util')

local function newCommandManager(cm)
  return util.instantiate('commandManager', { cm = cm })
end

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
    name = 'scope command resolves only when its scope is pushed',
    run = function()
      local mgr = newCommandManager(nil)
      local log = {}
      mgr:scope('tracker'):register('cursorUp', function() log[#log + 1] = 'tracker' end)
      mgr:invoke('cursorUp')           -- not pushed: miss
      mgr:push('tracker')
      mgr:invoke('cursorUp')           -- pushed: hit
      mgr:pop('tracker')
      mgr:invoke('cursorUp')           -- popped: miss
      t.deepEq(log, { 'tracker' })
    end,
  },

  {
    name = 'doAfter composes inside the scope gate — off-stack invoke fires neither orig nor after',
    run = function()
      local mgr = newCommandManager(nil)
      local log = {}
      mgr:scope('tracker'):register('act', function() log[#log + 1] = 'act' end)
      mgr:doAfter('act', function() log[#log + 1] = 'after' end)
      mgr:invoke('act')                          -- off-stack: gated, no fire
      mgr:push('tracker'); mgr:invoke('act')     -- on-stack: act + after
      t.deepEq(log, { 'act', 'after' })
    end,
  },

  {
    name = 'invoke on a global-only name still works regardless of pushed scope',
    run = function()
      local mgr = newCommandManager(nil)
      local log = {}
      mgr:register('quit', function() log[#log + 1] = 'quit' end)
      mgr:push('tracker')              -- created, but no shadow
      mgr:invoke('quit')
      t.deepEq(log, { 'quit' })
    end,
  },

  {
    name = 'keychain returns top-down; global-only when nothing pushed',
    run = function()
      local mgr = newCommandManager(nil)
      mgr:bind('playPause', { 1 })
      mgr:scope('tracker'):bind('cursorUp', { 2 })

      local k1 = mgr:keychain()
      t.eq(#k1, 1,                "nothing pushed: only global")
      t.eq(k1[1].playPause[1], 1, "global keymap is the only entry")

      mgr:push('tracker')
      local k2 = mgr:keychain()
      t.eq(#k2, 2,                "tracker pushed: two entries")
      t.eq(k2[1].cursorUp[1],   2, "top first")
      t.eq(k2[2].playPause[1],  1, "global last")
    end,
  },

  {
    name = 'keysFor walks the stack; upper shadows global',
    run = function()
      local mgr = newCommandManager(nil)
      mgr:bind('foo', { 1 })
      mgr:bind('bar', { 2 })
      mgr:scope('tracker'):bind('foo', { 99 })
      mgr:push('tracker')

      t.eq(mgr:keysFor('foo')[1], 99, "upper scope shadows global for 'foo'")
      t.eq(mgr:keysFor('bar')[1], 2,  "falls through to global for 'bar'")
      t.eq(mgr:keysFor('absent'), nil, "absent name returns nil")
    end,
  },

  {
    name = 'prefix: inactive by default; invoke passes default 1',
    run = function()
      local mgr = newCommandManager(nil)
      local seen
      mgr:register('probe', function(p) seen = p end)
      t.eq(mgr:isPrefixActive(), false)
      mgr:invoke('probe')
      t.eq(seen, 1, 'invoke defaults prefix to 1 when nothing pending')
    end,
  },

  {
    name = 'prefix: begin → digits → finish → invoke passes integer',
    run = function()
      local mgr = newCommandManager(nil)
      local seen
      mgr:register('probe', function(p) seen = p end)
      mgr:beginPrefix()
      t.eq(mgr:isPrefixActive(), true)
      mgr:appendPrefix('1'); mgr:appendPrefix('2'); mgr:appendPrefix('0')
      mgr:finishPrefix()
      t.eq(mgr:isPrefixActive(), false)
      mgr:invoke('probe')
      t.eq(seen, 120)
      mgr:invoke('probe')
      t.eq(seen, 1, 'invoke clears state — next call sees the default')
    end,
  },

  {
    name = 'prefix: fraction a/b passes as a number',
    run = function()
      local mgr = newCommandManager(nil)
      local seen
      mgr:register('probe', function(p) seen = p end)
      mgr:beginPrefix()
      mgr:appendPrefix('4'); mgr:appendPrefix('/'); mgr:appendPrefix('3')
      mgr:finishPrefix()
      mgr:invoke('probe')
      t.truthy(seen); t.truthy(math.abs(seen - 4/3) < 1e-12)
    end,
  },

  {
    name = 'prefix: empty buffer at finish yields default 1 at invoke',
    run = function()
      local mgr = newCommandManager(nil)
      local seen
      mgr:register('probe', function(p) seen = p end)
      mgr:beginPrefix()
      mgr:finishPrefix()
      mgr:invoke('probe')
      t.eq(seen, 1)
    end,
  },

  {
    name = 'prefix: cancel discards buffer and any pending',
    run = function()
      local mgr = newCommandManager(nil)
      local seen
      mgr:register('probe', function(p) seen = p end)
      mgr:beginPrefix(); mgr:appendPrefix('7')
      mgr:cancelPrefix()
      t.eq(mgr:isPrefixActive(), false)
      mgr:invoke('probe')
      t.eq(seen, 1)
    end,
  },

  {
    name = 'prefix: only one slash accepted',
    run = function()
      local mgr = newCommandManager(nil)
      local seen
      mgr:register('probe', function(p) seen = p end)
      mgr:beginPrefix()
      mgr:appendPrefix('1'); mgr:appendPrefix('/')
      mgr:appendPrefix('2'); mgr:appendPrefix('/')   -- second / dropped
      mgr:appendPrefix('3')
      mgr:finishPrefix()
      mgr:invoke('probe')
      t.truthy(seen); t.truthy(math.abs(seen - 1/23) < 1e-12)
    end,
  },

  {
    name = 'prefix: malformed buffer (e.g. lone slash) defaults to 1',
    run = function()
      local mgr = newCommandManager(nil)
      local seen
      mgr:register('probe', function(p) seen = p end)
      mgr:beginPrefix(); mgr:appendPrefix('/')
      mgr:finishPrefix()
      mgr:invoke('probe')
      t.eq(seen, 1)
    end,
  },

  {
    name = 'prefix: prefixRational returns (n, d) for an integer inside invoke',
    run = function()
      local mgr = newCommandManager(nil)
      local sn, sd
      mgr:register('probe', function() sn, sd = mgr:prefixRational() end)
      mgr:beginPrefix(); mgr:appendPrefix('5')
      mgr:finishPrefix()
      mgr:invoke('probe')
      t.eq(sn, 5); t.eq(sd, 1)
    end,
  },

  {
    name = 'prefix: prefixRational returns (n, d) for a fraction; invoke clears',
    run = function()
      local mgr = newCommandManager(nil)
      local sn, sd
      mgr:register('probe', function() sn, sd = mgr:prefixRational() end)
      mgr:beginPrefix(); mgr:appendPrefix('4'); mgr:appendPrefix('/'); mgr:appendPrefix('3')
      mgr:finishPrefix()
      mgr:invoke('probe')
      t.eq(sn, 4); t.eq(sd, 3)
      mgr:invoke('probe')
      t.eq(sn, nil); t.eq(sd, nil, 'state cleared at end of first invoke')
    end,
  },

  {
    name = 'prefix: prefixRational on empty buffer yields (nil, nil)',
    run = function()
      local mgr = newCommandManager(nil)
      local n, d = mgr:prefixRational()
      t.eq(n, nil); t.eq(d, nil)
    end,
  },

  {
    name = 'prefix: beginPrefix-via-invoke leaves the buffer active',
    run = function()
      local mgr = newCommandManager(nil)
      mgr:register('begin', function() mgr:beginPrefix() end)
      mgr:invoke('begin')
      t.eq(mgr:isPrefixActive(), true, 'invoke must not clear state a command just opened')
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
