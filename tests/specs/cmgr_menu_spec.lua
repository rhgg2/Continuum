-- The menu tree declares the groups a path walks: an ordered list of items, each
-- carrying its title, the letter that reaches it and the line shown while it is
-- highlighted. Pins that install derives a letter from the title and keeps a
-- declared one, that two members of one level sharing a letter raise while the same
-- letter on two levels does not, that a path naming no group raises, that a pathed
-- entry is stamped with the node its path names, and that the real manifest's tree
-- installs, is passed over by the scope walk, and reaches every path declared today.

local t    = require('support')
local util = require('util')

local img = t.imgui()

local function fresh() return util.instantiate('commandManager', {}) end

local function noop() end

-- One tree node in the shape manifest.lua's `item` builds.
local function node(name, letter, children)
  return { name = name, letter = letter, desc = name .. ' commands', children = children or {} }
end

return {
  {
    name = 'install derives a letter from the title, and keeps a declared one',
    run = function()
      local mgr  = fresh()
      local tree = { node('File'), node('Take', 'K') }
      mgr:installTree(tree)
      t.eq(tree[1].letter, 'F', 'File takes the first letter of its title')
      t.eq(tree[2].letter, 'K', 'Take keeps the letter it declares')
    end,
  },

  {
    -- A letter identifies its member uniquely within its level, so a walk needs no
    -- confirmation. A collision is a malformed declaration, and raises at load.
    name = 'two groups sharing a letter within a level raise, naming both',
    run = function()
      local mgr = fresh()
      local ok, err = pcall(function() mgr:installTree({ node('File'), node('FX') }) end)
      t.eq(ok, false, 'a shared letter should raise')
      t.truthy(tostring(err):find('File', 1, true), 'names the member holding the letter')
      t.truthy(tostring(err):find('FX', 1, true),   'names the member claiming it')
    end,
  },

  {
    name = 'the same letter on two levels is no collision',
    run = function()
      local mgr  = fresh()
      local tree = { node('Time', nil, { node('Tempo') }), node('Pitch') }
      mgr:installTree(tree)
      t.eq(tree[1].letter, 'T')
      t.eq(tree[1].children[1].letter, 'T', 'Tempo takes T under Time')
    end,
  },

  {
    name = 'a path naming no group raises, naming the command and the segment',
    run = function()
      local mgr = fresh()
      mgr:registerAll{ quantize = noop }
      mgr:installManifest({ global = { Editing = {
        { name = 'quantize', label = 'Quantize', path = 'Time/Nope' },
      } } }, img)
      local ok, err = pcall(function() mgr:installTree({ node('Time') }) end)
      t.eq(ok, false, 'an unreachable path should raise')
      t.truthy(tostring(err):find('quantize', 1, true), 'names the command')
      t.truthy(tostring(err):find('Nope', 1, true),     'names the segment that resolved to nothing')
    end,
  },

  {
    -- What the menu walks to, and what the cheat-sheet's path chip is rendered from:
    -- the node a path names, reached whatever depth it sits at.
    name = 'a pathed entry is stamped with the node its path names',
    run = function()
      local mgr = fresh()
      mgr:registerAll{ doubleRPB = noop, quit = noop }
      mgr:installManifest({ global = { Global = {
        { name = 'doubleRPB', label = 'Double',  path = 'Time/Rows' },
        { name = 'quit',      label = 'Quit',    path = 'File' },
      } } }, img)
      local rows = node('Rows')
      local tree = { node('File'), node('Time', nil, { rows }) }
      mgr:installTree(tree)
      t.eq(mgr:entry('doubleRPB').node, rows,    'the nested group, by identity')
      t.eq(mgr:entry('quit').node,      tree[1], 'a one-segment path names a top-level group')
    end,
  },

  {
    -- The real declaration: the tree installs against the whole manifest, and every
    -- path lands on the group its last segment names. The scope walk passes the tree
    -- over, since it declares groups rather than commands.
    name = 'the real manifest declares a tree its paths reach',
    run = function()
      local mgr      = fresh()
      local manifest = require('manifest')
      t.truthy(manifest.tree, 'the manifest declares a menu tree')
      mgr:installManifest(manifest, img)
      t.eq(mgr.scopes.tree, nil, 'the tree is not installed as a scope')
      mgr:installTree(manifest.tree)

      local pathed = {}
      for _, entry in pairs(mgr.entries) do
        if entry.path then util.add(pathed, entry) end
      end
      t.truthy(#pathed > 0, 'the manifest declares pathed commands')
      for _, entry in ipairs(pathed) do
        t.eq(entry.node.name, entry.path:match('([^/]+)$'),
             entry.name .. ' resolves to the group its path ends at')
      end
      t.eq(mgr:entry('switchToTracker').node.name, 'Page', 'travel to a page is under Page')
    end,
  },
}
