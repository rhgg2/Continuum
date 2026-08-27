-- The manifest declares each command once, in the order it reads, carrying its
-- label and its keys as binding tokens. Pins that install parses those tokens
-- into the declaring scope's keymap, that a keyless entry binds nothing, that
-- declaration order survives, that a name declared twice raises, that a token
-- which does not parse raises, and that the load-time audit raises in both
-- directions, and on a scope that registers a command while declaring no
-- manifest at all.

local t    = require('support')
local util = require('util')

-- Tokens are parsed against ImGui's constants, so the fake carries the real
-- contiguous key ranges cmgr's token tables walk.
local img = t.imgui()

local function fresh() return util.instantiate('commandManager', {}) end

local function noop() end

return {
  {
    name = 'install parses each entry\'s tokens into its own scope\'s keymap',
    run = function()
      local mgr = fresh()
      mgr:registerAll{ playPause = noop }
      mgr:scope('tracker'):registerAll{ cursorUp = noop }
      mgr:installManifest({
        global  = { { name = 'playPause', label = 'Play / pause', keys = { 'Space' } } },
        tracker = { { name = 'cursorUp',  label = 'Up',           keys = { 'Up', 'Super+P' } } },
      }, img)
      t.deepEq(mgr:rootKeymap().playPause, { img.Key_Space })
      mgr:push('tracker')
      t.deepEq(mgr:keysFor('cursorUp'), { img.Key_UpArrow, { img.Key_P, img.Mod_Super } })
    end,
  },

  {
    name = 'an entry with no keys binds nothing',
    run = function()
      local mgr = fresh()
      mgr:registerAll{ switchPage = noop }
      mgr:installManifest({ global = { { name = 'switchPage', label = 'Switch to page' } } }, img)
      t.eq(mgr:rootKeymap().switchPage, nil)
    end,
  },

  {
    name = 'the scope is a list, so declaration order survives install',
    run = function()
      local mgr = fresh()
      mgr:registerAll{ undo = noop, redo = noop, quit = noop }
      mgr:installManifest({ global = {
        { name = 'undo', label = 'Undo' },
        { name = 'redo', label = 'Redo' },
        { name = 'quit', label = 'Quit' },
      } }, img)
      local names = {}
      for _, entry in ipairs(mgr:scope('global').manifest) do util.add(names, entry.name) end
      t.deepEq(names, { 'undo', 'redo', 'quit' })
    end,
  },

  {
    name = 'a token that does not parse raises, naming the command',
    run = function()
      local mgr = fresh()
      local ok, err = pcall(function()
        mgr:installManifest({ global = {
          { name = 'quit', label = 'Quit', keys = { 'Ctrl+Quit' } },
        } }, img)
      end)
      t.eq(ok, false, 'a malformed token should raise')
      t.truthy(tostring(err):find('quit', 1, true), 'names the command')
      t.truthy(tostring(err):find('Quit', 1, true), 'names the part that failed')
    end,
  },

  {
    name = 'a command declared by two scopes raises at install',
    run = function()
      local mgr = fresh()
      local ok, err = pcall(function()
        mgr:installManifest({
          global  = { { name = 'toggleFollowPlay', label = 'Follow play' } },
          tracker = { { name = 'toggleFollowPlay', label = 'Follow play' } },
        }, img)
      end)
      t.eq(ok, false, 'duplicate declaration should raise')
      t.truthy(tostring(err):find('toggleFollowPlay', 1, true), 'names the command')
    end,
  },

  {
    name = 'audit is quiet when entries and registrations correspond',
    run = function()
      local mgr = fresh()
      mgr:registerAll{ quit = noop }
      mgr:scope('tracker'):registerAll{ cursorUp = noop }
      mgr:installManifest({
        global  = { { name = 'quit',     label = 'Quit', keys = { 'Ctrl+Q' } } },
        tracker = { { name = 'cursorUp', label = 'Up' } },
      }, img)
      mgr:auditManifests()
    end,
  },

  {
    name = 'audit raises on a scope that registers but declares no manifest',
    run = function()
      local mgr = fresh()
      mgr:scope('sample'):registerAll{ slotNext = noop }
      local ok, err = pcall(function() mgr:auditManifests() end)
      t.eq(ok, false, 'an undeclared scope should raise')
      t.truthy(tostring(err):find('sample', 1, true), 'names the scope')
      t.truthy(tostring(err):find('slotNext', 1, true), 'names the command')
    end,
  },

  {
    name = 'audit raises on an entry no scope registers',
    run = function()
      local mgr = fresh()
      mgr:installManifest({ global = { { name = 'phantom', label = 'Phantom' } } }, img)
      local ok, err = pcall(function() mgr:auditManifests() end)
      t.eq(ok, false, 'undeclared body should raise')
      t.truthy(tostring(err):find('phantom', 1, true), 'names the command')
    end,
  },

  {
    name = 'audit raises on a registered command its scope does not declare',
    run = function()
      local mgr = fresh()
      mgr:registerAll{ quit = noop, toggleProfiler = noop }
      mgr:installManifest({ global = { { name = 'quit', label = 'Quit' } } }, img)
      local ok, err = pcall(function() mgr:auditManifests() end)
      t.eq(ok, false, 'undeclared registration should raise')
      t.truthy(tostring(err):find('toggleProfiler', 1, true), 'names the command')
    end,
  },
}
