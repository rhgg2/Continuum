-- The manifest declares each command once, carrying its label and its keys.
-- Pins that install writes those keys into the declaring scope's keymap, that
-- a keyless entry binds nothing, that a name declared twice raises, and that
-- the load-time audit raises in both directions while passing over a scope
-- the manifest does not declare.

local t    = require('support')
local util = require('util')

-- Keyspecs are opaque to everything under test here, so plain strings stand
-- in for ImGui key constants.
local function fresh() return util.instantiate('commandManager', {}) end

local function noop() end

return {
  {
    name = 'install writes each entry\'s keys into its own scope\'s keymap',
    run = function()
      local mgr = fresh()
      mgr:registerAll{ playPause = noop }
      mgr:scope('tracker'):registerAll{ cursorUp = noop }
      mgr:installManifest{
        global  = { playPause = { label = 'Play / pause', keys = { 'Space' } } },
        tracker = { cursorUp  = { label = 'Up',           keys = { 'Up', 'Ctrl+P' } } },
      }
      t.deepEq(mgr:rootKeymap().playPause, { 'Space' })
      mgr:push('tracker')
      t.deepEq(mgr:keysFor('cursorUp'), { 'Up', 'Ctrl+P' })
    end,
  },

  {
    name = 'an entry with no keys binds nothing',
    run = function()
      local mgr = fresh()
      mgr:registerAll{ switchPage = noop }
      mgr:installManifest{ global = { switchPage = { label = 'Switch to page' } } }
      t.eq(mgr:rootKeymap().switchPage, nil)
    end,
  },

  {
    name = 'a command declared by two scopes raises at install',
    run = function()
      local mgr = fresh()
      local ok, err = pcall(function()
        mgr:installManifest{
          global  = { toggleFollowPlay = { label = 'Follow play' } },
          tracker = { toggleFollowPlay = { label = 'Follow play' } },
        }
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
      -- Undeclared scope: its registrations are nobody's business yet.
      mgr:scope('tracker'):registerAll{ cursorUp = noop }
      mgr:installManifest{ global = { quit = { label = 'Quit', keys = { 'Ctrl+Q' } } } }
      mgr:auditManifests()
    end,
  },

  {
    name = 'audit raises on an entry no scope registers',
    run = function()
      local mgr = fresh()
      mgr:installManifest{ global = { phantom = { label = 'Phantom' } } }
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
      mgr:installManifest{ global = { quit = { label = 'Quit' } } }
      local ok, err = pcall(function() mgr:auditManifests() end)
      t.eq(ok, false, 'undeclared registration should raise')
      t.truthy(tostring(err):find('toggleProfiler', 1, true), 'names the command')
    end,
  },
}
