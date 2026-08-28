-- The menu tree declares the groups a path walks, and a path names its leaf: every
-- segment but the last names a group, and the last is the entry's menu title, from
-- which its letter derives. Pins that a group's letter comes from its title and a
-- leaf's from its menu title, that a declared letter wins over either, that groups
-- and leaves share one namespace per level while two levels are independent, that
-- two scopes never stacked together may reuse a letter while a page scope colliding
-- with global raises, that a path naming no group raises, and that the real manifest
-- installs with every path reaching the level it reads in.

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
    name = 'install derives a group letter from the title, and keeps a declared one',
    run = function()
      local mgr  = fresh()
      local tree = { node('File'), node('Take', 'K') }
      mgr:installTree(tree)
      t.eq(tree[1].letter, 'F', 'File takes the first letter of its title')
      t.eq(tree[2].letter, 'K', 'Take keeps the letter it declares')
    end,
  },

  {
    -- The path's last segment is what the menu shows and what the letter comes from,
    -- so a leaf reads as one word where the cheat-sheet's label is a phrase.
    name = 'a leaf takes its title and letter from the last segment, a declared letter winning',
    run = function()
      local mgr = fresh()
      mgr:registerAll{ copy = noop, cut = noop }
      mgr:installManifest({ global = { Selection = {
        { name = 'copy', label = 'Copy', path = 'Edit/Copy' },
        { name = 'cut',  label = 'Cut',  path = 'Edit/Cut', letter = 'X' },
      } } }, img)
      mgr:installTree({ node('Edit') })
      t.eq(mgr:entry('copy').title,  'Copy', 'the menu title is the last segment')
      t.eq(mgr:entry('copy').letter, 'C',    'and the letter its first character')
      t.eq(mgr:entry('cut').letter,  'X',    'a declared letter wins over the derived one')
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
    -- Groups and leaves are members of one level alike: a letter typed there reaches
    -- either, so the two share a namespace.
    name = 'a group and a leaf sharing a letter within a level raise, naming both',
    run = function()
      local mgr = fresh()
      mgr:registerAll{ vary = noop }
      mgr:installManifest({ global = { Take = {
        { name = 'vary', label = 'Next variant / vary', path = 'Take/Vary' },
      } } }, img)
      local tree = { node('Take', nil, { node('Variant') }) }
      local ok, err = pcall(function() mgr:installTree(tree) end)
      t.eq(ok, false, 'a leaf colliding with a sibling group should raise')
      t.truthy(tostring(err):find('Variant', 1, true), 'names the group')
      t.truthy(tostring(err):find('Vary', 1, true),    'names the leaf')
    end,
  },

  {
    name = 'the same letter on two levels is no collision',
    run = function()
      local mgr  = fresh()
      mgr:registerAll{ retune = noop }
      mgr:installManifest({ global = { Editing = {
        { name = 'retune', label = 'Retune', path = 'Tuning/Retune' },
      } } }, img)
      local tree = { node('Tuning', nil, { node('Tempo') }), node('Row') }
      mgr:installTree(tree)
      t.eq(tree[1].children[1].letter, 'T', 'Tempo takes T under Tuning')
      t.eq(mgr:entry('retune').letter, 'R', 'and Retune R, though Row holds R above')
    end,
  },

  {
    -- Reachability decides what a level holds: two page scopes are never on the stack
    -- together, so the same letter under one node is two menus, not one collision.
    name = 'two page scopes may reuse a letter, while a collision with global raises',
    run = function()
      local mgr = fresh()
      mgr:installManifest({
        tracker = { Take  = { { name = 'takeProperties',
                                label = 'Take properties', path = 'Take/Properties' } } },
        arrange = { Takes = { { name = 'arrangeTakeProperties',
                                label = 'Take properties', path = 'Take/Properties' } } },
      }, img)
      mgr:installTree({ node('Take') })
      t.eq(mgr:entry('takeProperties').letter, 'P', 'both pages reach Properties by P')

      local other = fresh()
      other:installManifest({
        global  = { Global = { { name = 'quit',  label = 'Quit',  path = 'File/Quit' } } },
        tracker = { Global = { { name = 'pinMap', label = 'Pin the map', path = 'File/Quiet' } } },
      }, img)
      local ok, err = pcall(function() other:installTree({ node('File') }) end)
      t.eq(ok, false, 'a page scope colliding with global should raise')
      t.truthy(tostring(err):find('Quit', 1, true),  'names the global leaf')
      t.truthy(tostring(err):find('Quiet', 1, true), 'names the page leaf')
    end,
  },

  {
    name = 'a path naming no group raises, naming the command and the segment',
    run = function()
      local mgr = fresh()
      mgr:registerAll{ quantize = noop }
      mgr:installManifest({ global = { Editing = {
        { name = 'quantize', label = 'Quantize', path = 'Grid/Nope/Quantize' },
      } } }, img)
      local ok, err = pcall(function() mgr:installTree({ node('Grid') }) end)
      t.eq(ok, false, 'an unreachable path should raise')
      t.truthy(tostring(err):find('quantize', 1, true), 'names the command')
      t.truthy(tostring(err):find('Nope', 1, true),     'names the segment that resolved to nothing')
    end,
  },

  {
    -- What the menu walks: the level a leaf reads in, which for a one-segment path is
    -- the top level itself.
    name = 'a pathed entry is stamped with the node it reads under',
    run = function()
      local mgr = fresh()
      mgr:registerAll{ doubleRPB = noop, toggleHelp = noop }
      mgr:installManifest({ global = { Global = {
        { name = 'doubleRPB',  label = 'Double',    path = 'View/Rows/Double', letter = '=' },
        { name = 'toggleHelp', label = 'This help', path = 'Help' },
      } } }, img)
      local rows = node('Rows')
      local tree = { node('View', nil, { rows }) }
      mgr:installTree(tree)
      t.eq(mgr:entry('doubleRPB').node,   rows, 'the nested group, by identity')
      t.eq(mgr:entry('doubleRPB').letter, '=',  'a declared letter need not be alphabetic')
      t.eq(mgr:entry('toggleHelp').node,  nil,  'a one-segment path is a leaf of the top level')
    end,
  },

  {
    -- The real declaration: the tree installs against the whole manifest, every path
    -- lands under the group its penultimate segment names, and the scope walk passes
    -- the tree over, since it declares groups rather than commands.
    name = 'the real manifest declares a tree its paths reach',
    run = function()
      local mgr      = fresh()
      local manifest = require('manifest')
      t.truthy(manifest.tree, 'the manifest declares a menu tree')
      mgr:installManifest(manifest, img)
      t.eq(mgr.scopes.tree, nil, 'the tree is not installed as a scope')
      mgr:installTree(manifest.tree)

      local pathed, top = {}, 0
      for _, entry in pairs(mgr.entries) do
        if entry.path then util.add(pathed, entry) end
      end
      t.truthy(#pathed > 20, 'the manifest declares a pathed surface')
      for _, entry in ipairs(pathed) do
        local parent = entry.path:match('([^/]+)/[^/]+$')
        t.eq(entry.node and entry.node.name, parent,
             entry.name .. ' reads under the group its path names')
        t.eq(entry.title, entry.path:match('([^/]+)$'), entry.name .. ' is titled by its last segment')
        if not parent then top = top + 1 end
      end
      t.truthy(top > 0, 'and at least one leaf sits at the top level')
      t.eq(mgr:entry('switchToTracker').node.name, 'Jump', 'travel to a page is under Jump')
      t.eq(mgr:entry('quantize').letter, 'Q', 'quantize is reached by Q under Grid')
    end,
  },
}
