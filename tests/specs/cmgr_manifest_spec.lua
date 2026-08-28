-- The manifest declares each command once, under the group it reads in, carrying
-- its label and its keys as binding tokens. Pins that install parses those tokens
-- into the declaring scope's keymap, stamps the group onto the entry, that a
-- keyless entry binds nothing, that declaration order survives within a group,
-- that a name declared twice raises, that a token which does not parse raises,
-- that the surface is the reachable scopes' entries, and that the load-time audit
-- raises in both directions, and on a scope that registers a command while
-- declaring no manifest at all.

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
        global  = { Transport = { { name = 'playPause', label = 'Play / pause', keys = { 'Space' } } } },
        tracker = { Movement  = { { name = 'cursorUp',  label = 'Up',           keys = { 'Up', 'Super+P' } } } },
      }, img)
      t.deepEq(mgr:rootKeymap().playPause, { img.Key_Space })
      mgr:push('tracker')
      t.deepEq(mgr:keysFor('cursorUp'), { img.Key_UpArrow, { img.Key_P, img.Mod_Super } })
    end,
  },

  {
    -- The key an entry is declared under is the cheat-sheet group it belongs to,
    -- and the entry carries it afterwards, whichever scope declared it.
    name = 'install stamps the group onto each entry',
    run = function()
      local mgr = fresh()
      mgr:registerAll{ playPause = noop }
      mgr:scope('tracker'):registerAll{ cursorUp = noop }
      mgr:installManifest({
        global  = { Transport = { { name = 'playPause', label = 'Play / pause' } } },
        tracker = { Movement  = { { name = 'cursorUp',  label = 'Up' } } },
      }, img)
      t.eq(mgr:entry('playPause').group, 'Transport')
      t.eq(mgr:entry('cursorUp').group,  'Movement')
    end,
  },

  {
    name = 'an entry with no keys binds nothing',
    run = function()
      local mgr = fresh()
      mgr:registerAll{ switchPage = noop }
      mgr:installManifest({ global = { Programmatic = { { name = 'switchPage', label = 'Switch to page' } } } }, img)
      t.eq(mgr:rootKeymap().switchPage, nil)
    end,
  },

  {
    name = 'a group is a list, so declaration order survives install',
    run = function()
      local mgr = fresh()
      mgr:registerAll{ undo = noop, redo = noop, quit = noop }
      mgr:installManifest({ global = { Global = {
        { name = 'undo', label = 'Undo' },
        { name = 'redo', label = 'Redo' },
        { name = 'quit', label = 'Quit' },
      } } }, img)
      local names = {}
      for _, entry in ipairs(mgr:scope('global').manifest.Global) do util.add(names, entry.name) end
      t.deepEq(names, { 'undo', 'redo', 'quit' })
    end,
  },

  {
    -- What the cheat-sheet reads: the scopes on the stack, bottom first, and no
    -- scope off it.
    name = 'the surface is the entries of the scopes on the stack',
    run = function()
      local mgr = fresh()
      mgr:registerAll{ quit = noop }
      mgr:scope('tracker'):registerAll{ cursorUp = noop }
      mgr:scope('sample'):registerAll{ slotNext = noop }
      mgr:installManifest({
        global  = { Global   = { { name = 'quit',     label = 'Quit' } } },
        tracker = { Movement = { { name = 'cursorUp', label = 'Up' } } },
        sample  = { Slots    = { { name = 'slotNext', label = 'Next slot' } } },
      }, img)
      mgr:push('tracker')
      local names = {}
      for _, entry in ipairs(mgr:surface()) do util.add(names, entry.name) end
      t.deepEq(names, { 'quit', 'cursorUp' }, 'global then tracker; sample is off the stack')
    end,
  },

  {
    -- The surface answers the same reachability question invoke gates on, so an
    -- open modal scope thins the sheet to what it passes through.
    name = 'a modal scope drops what it does not pass through from the surface',
    run = function()
      local mgr = fresh()
      mgr:registerAll{ quit = noop, undo = noop }
      mgr:scope('menu'):registerAll{ menuEscape = noop }
      mgr:installManifest({
        global = { Global = { { name = 'quit', label = 'Quit' }, { name = 'undo', label = 'Undo' } } },
        menu   = { Menu   = { { name = 'menuEscape', label = 'Close the menu' } } },
      }, img)
      local menu = mgr:scope('menu')
      menu.modal, menu.passthrough = true, { quit = true }
      mgr:push(menu)
      local names = {}
      for _, entry in ipairs(mgr:surface()) do util.add(names, entry.name) end
      t.deepEq(names, { 'quit', 'menuEscape' }, 'undo is blocked, quit passes through')
    end,
  },

  {
    -- Every generated family in the real manifest: its members share a group, and
    -- each member's declared chord is its own base token under one common mask.
    -- That mask is what a family rebind replaces, so a base which does not
    -- re-derive its declared chord would rebind the family onto the wrong keys.
    name = 'a declared family shares a group and one mask over its bases',
    run = function()
      local mgr = fresh()
      mgr:installManifest(require('manifest'), img)
      local families = {}
      for _, scope in pairs(mgr.scopes) do
        for _, entries in pairs(scope.manifest or {}) do
          for _, entry in ipairs(entries) do
            if entry.family then util.bucket(families, entry.family, entry) end
          end
        end
      end
      t.truthy(next(families), 'the manifest declares at least one family')
      for family, members in pairs(families) do
        t.truthy(#members > 1, family.label .. ' has more than one member')
        t.eq(#members, #family.members, family.label .. ' lists every member it stamps')
        local group, mask, shared
        for _, entry in ipairs(members) do
          t.eq(#entry.keys, 1, entry.name .. ' declares one chord')
          local key,     mods  = mgr:keySpec(mgr:specForToken(entry.keys[1], img), img)
          local baseKey, bmods = mgr:keySpec(mgr:specForToken(entry.base, img), img)
          group = group or entry.group
          mask  = mask  or (mods & ~bmods)
          t.eq(entry.group, group, entry.name .. ' reads in its family\'s group')
          t.eq(key, baseKey, entry.name .. ' is declared on its base key')
          t.eq(mods, mask | bmods, entry.name .. ' carries the family mask over its base')
          shared = (shared or ~0) & bmods
        end
        t.eq(shared, 0, family.label .. ' declares its mask, not the bases\' common modifier')
      end
    end,
  },

  {
    name = 'a token that does not parse raises, naming the command',
    run = function()
      local mgr = fresh()
      local ok, err = pcall(function()
        mgr:installManifest({ global = { Global = {
          { name = 'quit', label = 'Quit', keys = { 'Ctrl+Quit' } },
        } } }, img)
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
          global  = { Global = { { name = 'toggleFollowPlay', label = 'Follow play' } } },
          tracker = { Loop   = { { name = 'toggleFollowPlay', label = 'Follow play' } } },
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
        global  = { Global   = { { name = 'quit',     label = 'Quit', keys = { 'Ctrl+Q' } } } },
        tracker = { Movement = { { name = 'cursorUp', label = 'Up' } } },
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
      mgr:installManifest({ global = { Global = { { name = 'phantom', label = 'Phantom' } } } }, img)
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
      mgr:installManifest({ global = { Global = { { name = 'quit', label = 'Quit' } } } }, img)
      local ok, err = pcall(function() mgr:auditManifests() end)
      t.eq(ok, false, 'undeclared registration should raise')
      t.truthy(tostring(err):find('toggleProfiler', 1, true), 'names the command')
    end,
  },
}
