-- The lotus menu as a scope. Opening pushes a modal cmgr scope, so a letter typed during
-- the walk cannot reach a page verb, and closing pops it. What survives the walk is
-- declared by group: the transport, because Continuum is played while it is edited, and
-- the page switchers, because travel is not a menu letter. The set is built from the
-- stack at the moment the menu opens, so the tracker's own transport verbs pass through
-- while the tracker is showing. The close verb is registered on the menu's own scope, so
-- the gate is its own guard — Esc reaches it only while the menu is up, and the open verb
-- is blocked by the scope it pushed. See design/lotus-menu.md § What stays live.

local t    = require('support')
local util = require('util')

local img = t.imgui()

-- A cmgr carrying the real manifest, stub bodies for the verbs the cases invoke, and the
-- menu built over it, with the tracker page on the stack. Each body logs its name, so a
-- gated-out invoke reads as silence rather than as a return value.
local function fixture(page)
  local log = {}
  local function logger(name) return function() util.add(log, name) end end
  local mgr      = util.instantiate('commandManager', {})
  local manifest = require('manifest')
  mgr:installManifest(manifest, img)
  mgr:installTree(manifest.tree)
  for _, name in ipairs{ 'playPause', 'switchToArrange', 'switchPage' } do
    mgr:register(name, logger(name))
  end
  for _, name in ipairs{ 'quantize', 'playFromCursor' } do
    mgr:scope('tracker'):register(name, logger(name))
  end
  local menu = util.instantiate('menu', { cmgr = mgr })
  mgr:push(page)
  return mgr, menu, log
end

-- One tree node in the shape manifest.lua's `item` builds.
local function node(name, children)
  return { name = name, desc = name .. ' commands', children = children or {} }
end

-- A synthetic surface for the rules a level obeys whatever is declared: one global verb two
-- levels down, one page verb at the top. The real manifest carries no witness for these, so
-- re-cutting a path there moves nothing here.
local function synthetic()
  local mgr = util.instantiate('commandManager', {})
  mgr:register('editSwing', function() end)
  mgr:scope('page'):register('addColumn', function() end)
  mgr:installManifest({
    global = { Swing  = { { name = 'editSwing', label = 'Edit swing', path = 'Grid/Swing/Edit' } } },
    page   = { Column = { { name = 'addColumn', label = 'Add column', path = 'Column/Add'     } } },
  }, img)
  mgr:installTree{ node('Grid', { node('Swing') }), node('Column') }
  return mgr, util.instantiate('menu', { cmgr = mgr })
end

local function titles(members)
  local out = {}
  for _, m in ipairs(members) do util.add(out, m.title or m.name) end
  return out
end

local function named(members, title)
  for _, m in ipairs(members) do if m.title == title then return m end end
end

-- The position a member holds in its level, named by a group's title or by the entry a
-- leaf carries, so a re-cut path moves nothing here.
local function indexOf(members, wanted)
  for i, m in ipairs(members) do
    if m.title == wanted or m.entry == wanted then return i end
  end
end

-- Right from the first member, which is where every level opens.
local function highlightTo(mgr, index)
  for _ = 2, index do mgr:invoke('menuRight') end
end

return {
  {
    name = 'opening pushes the menu scope over the page, and closing pops it',
    run = function()
      local mgr, menu = fixture('tracker')
      t.eq(menu:isOpen(), false, 'the menu starts closed')

      mgr:invoke('openMenu')
      t.eq(menu:isOpen(), true, '/ opens it')
      t.eq(mgr.stack[#mgr.stack], mgr:scope('menu'), 'its scope is on top')
      t.eq(#mgr.stack, 3, 'above global and the page')

      mgr:invoke('menuBack')
      t.eq(menu:isOpen(), false, 'Esc closes it')
      t.eq(mgr.stack[#mgr.stack], mgr:scope('tracker'), 'the page scope is back on top')
    end,
  },

  {
    -- The point of the modality: while the menu is up a letter means a menu letter, so the
    -- verbs it walks to are unreachable by key and by name alike.
    name = 'a page verb is blocked while the menu is open, and live again after',
    run = function()
      local mgr, _, log = fixture('tracker')
      mgr:invoke('quantize')
      t.deepEq(log, { 'quantize' }, 'the page verb fires with the page on top')

      mgr:invoke('openMenu')
      mgr:invoke('quantize')
      t.deepEq(log, { 'quantize' }, 'the modal scope blocks it')
      t.eq(mgr:keysFor('quantize'), nil, 'and no chord reaches it either')

      mgr:invoke('menuBack')
      mgr:invoke('quantize')
      t.deepEq(log, { 'quantize', 'quantize' }, 'the block lasts exactly as long as the walk')
    end,
  },

  {
    -- Passthrough by group, read off the stack: global's Transport and Pages, and the
    -- tracker's own transport verbs, which only a page scope declares.
    name = 'the transport and the page switchers stay live through the walk',
    run = function()
      local mgr, _, log = fixture('tracker')
      mgr:invoke('openMenu')

      for _, name in ipairs{ 'playPause', 'playFromCursor', 'switchToArrange', 'switchPage' } do
        mgr:invoke(name)
      end
      t.deepEq(log, { 'playPause', 'playFromCursor', 'switchToArrange', 'switchPage' },
               'transport and travel reach their bodies with the menu open')
      t.truthy(mgr:keysFor('playPause'), 'and Space still reaches play')
    end,
  },

  {
    name = 'each verb is guarded by the scope it is registered on',
    run = function()
      local mgr = fixture('tracker')
      mgr:invoke('menuBack')
      t.eq(#mgr.stack, 2, 'close does nothing while the menu is closed')

      mgr:invoke('openMenu')
      mgr:invoke('openMenu')
      t.eq(#mgr.stack, 3, 'and open is blocked by the scope it pushed')
    end,
  },

  {
    -- A level is what the menu offers at the node the path names. Its members are the
    -- node's child groups and the entries stamped with it, and each carries the letter
    -- that reaches it, the title it reads under, and a line of description.
    name = 'the top level holds the reachable groups and the leaves of one-segment paths',
    run = function()
      local mgr, menu = fixture('tracker')
      mgr:invoke('openMenu')
      local top = menu:level()
      t.truthy(#top > 6, 'the tracker offers a row of groups')

      local grid = named(top, 'Grid')
      t.truthy(grid, 'the grid verbs are the tracker\'s to reach')
      t.eq(grid.node, mgr.tree[7], 'a group member carries the tree\'s own node')
      t.eq(grid.node.name, 'Grid', 'which is the one the title names')
      t.eq(grid.letter, grid.node.letter, 'the letter that descends into it')
      t.eq(grid.desc,   grid.node.desc,   'and the line shown while it is highlighted')

      local help = named(top, 'Help')
      t.truthy(help, 'the one-segment path is a leaf of the top level')
      t.eq(help.entry, mgr:entry('toggleHelp'), 'a leaf member carries the entry its letter invokes')
      t.eq(help.letter, 'H', 'reached by the letter its title gives')
      t.eq(help.desc, mgr:entry('toggleHelp').label, 'and reading under its cheat-sheet label')
    end,
  },

  {
    -- Occupancy, over a surface of the spec's own: a group is a member of its level where
    -- it or any descendant holds a reachable entry. Grid holds no verb of its own here and
    -- stands on the global two levels down, while Column waits for the page that declares
    -- it.
    name = 'a group is a member where it or a descendant holds a reachable entry',
    run = function()
      local mgr, menu = synthetic()
      mgr:invoke('openMenu')
      t.deepEq(titles(menu:level()), { 'Grid' }, 'with the page off the stack the global verb\'s group stands alone')
      menu:press('G')
      t.deepEq(titles(menu:level()), { 'Swing' }, 'Grid keeps the child that holds the verb')
      menu:press('S')
      t.deepEq(titles(menu:level()), { 'Edit' }, 'whose own level holds the leaf')

      menu:close()
      mgr:push('page')
      mgr:invoke('openMenu')
      t.deepEq(titles(menu:level()), { 'Grid', 'Column' },
               'and the page\'s group joins the level while the page is on the stack')
    end,
  },

  {
    -- Reachability over the real declaration: what one page offers is what the scopes on
    -- the stack declare, so each page reaches its own groups and none of the others'.
    name = 'a level omits what the stack cannot reach',
    run = function()
      local mgr, menu = fixture('sample')
      mgr:invoke('openMenu')
      local top = menu:level()
      t.truthy(named(top, 'Sample'), 'the sampler reaches its own group')
      t.eq(named(top, 'Column'), nil, 'and not the column verbs, which the tracker declares')
      t.eq(named(top, 'Mirror'), nil, 'nor the mirror verbs')

      local other, tracker = fixture('tracker')
      other:invoke('openMenu')
      t.truthy(named(tracker:level(), 'Column'), 'the tracker reaches what the sampler does not')
      t.eq(named(tracker:level(), 'Sample'), nil, 'and not the sampler\'s own group')
    end,
  },

  {
    -- The order a level reads in: its groups as the tree declares them, then its leaves
    -- by title, since the surface unions two scopes and the manifest fixes no order
    -- across them.
    name = 'a level lists its groups in tree order, then its leaves by title',
    run = function()
      local mgr, menu = fixture('tracker')
      mgr:invoke('openMenu')
      local grid = named(menu:level(), 'Grid')
      menu:press(grid.letter)

      local members, groups, leaves, lastGroup, firstLeaf = menu:level(), {}, {}, 0, nil
      for i, m in ipairs(members) do
        if m.node then util.add(groups, m.title); lastGroup = i
        else           util.add(leaves, m.title); firstLeaf = firstLeaf or i end
      end
      t.truthy(#groups > 1 and #leaves > 1, 'the grid level holds groups and leaves alike')
      t.truthy(lastGroup < firstLeaf, 'every group comes before every leaf')

      local declared = {}
      for _, child in ipairs(grid.node.children) do util.add(declared, child.name) end
      t.deepEq(groups, declared, 'the groups read in the order the tree declares them')

      local sorted = util.clone(leaves)
      table.sort(sorted)
      t.deepEq(leaves, sorted, 'and the leaves by title')
    end,
  },

  {
    -- Why the surface is snapshotted: the menu's own modality hides all but the
    -- passthrough set, so a level read live would hold nothing to walk to.
    name = 'the level is read from the surface the menu snapshotted as it opened',
    run = function()
      local mgr, menu = fixture('tracker')
      mgr:invoke('openMenu')
      local grid, liveUnderGrid = named(menu:level(), 'Grid'), false
      t.truthy(grid, 'the level offers the grid verbs')
      local live = mgr:surface()
      t.truthy(#live > 0, 'the transport and the page switchers stay on the live surface')
      for _, entry in ipairs(live) do
        if entry.node == grid.node then liveUnderGrid = true end
      end
      t.eq(liveUnderGrid, false, 'while the modality hides the grid verbs from it')

      mgr:invoke('menuBack')
      t.deepEq(menu:level(), {}, 'and a closed menu holds no level')
    end,
  },

  {
    -- The walk itself: a group's letter descends, a leaf's closes the menu and then
    -- invokes, and a letter no member takes is dropped. /GQ is the tracker's quantize.
    -- The close precedes the invoke, so the command is gated by the ordinary stack — a
    -- leaf invoked from inside the walk would reach nothing, and the log would be empty.
    name = 'a letter descends into a group, and invokes a leaf',
    run = function()
      local mgr, menu, log = fixture('tracker')
      mgr:invoke('openMenu')

      menu:press('G')
      t.deepEq(titles(menu:path()), { 'Grid' }, 'the group letter descends into it')
      menu:press('Z')
      t.deepEq(titles(menu:path()), { 'Grid' }, 'a letter no member takes is dropped')

      menu:press('Q')
      t.deepEq(log, { 'quantize' }, 'the leaf letter invokes its command')
      t.eq(menu:isOpen(), false, 'and the menu is closed behind it')
    end,
  },

  {
    -- Esc unwinds the path the menu holds, one level at a time, and closes from the top.
    -- One scope covers a walk of any depth, so the unwind is the menu's own bookkeeping.
    name = 'Esc pops one level, and closes the menu from the top',
    run = function()
      local mgr, menu = fixture('tracker')
      mgr:invoke('openMenu')
      menu:press('G')
      menu:press('S')
      t.deepEq(titles(menu:path()), { 'Grid', 'Scale' }, 'two levels down')

      mgr:invoke('menuBack')
      t.deepEq(titles(menu:path()), { 'Grid' }, 'Esc pops one level')
      t.eq(menu:isOpen(), true, 'and leaves the menu up')

      mgr:invoke('menuBack')
      t.deepEq(titles(menu:path()), {}, 'the second pop is back at the top level')
      t.eq(menu:isOpen(), true, 'still up')

      mgr:invoke('menuBack')
      t.eq(menu:isOpen(), false, 'and Esc from the top closes the menu')
    end,
  },

  {
    -- The slash is the rational's bar and the menu key at once, so a prefix pending when
    -- the menu opens is neither frozen nor cleared. The leaf freezes it instead, exactly
    -- where a chord's key would: ⌘U 4 / V R S sets rows per beat to 4.
    name = 'a pending prefix survives the walk, and the leaf takes it',
    run = function()
      local mgr, menu, log = fixture('tracker')
      local seen
      mgr:scope('tracker'):register('setRPB', function(n) util.add(log, 'setRPB'); seen = n end)

      mgr:beginPrefix(); mgr:appendPrefix('4'); mgr:appendPrefix('/')
      mgr:invoke('openMenu')
      t.eq(mgr:isPrefixActive(), true, 'opening the menu neither freezes nor clears the buffer')

      for _, letter in ipairs{ 'V', 'R', 'S' } do menu:press(letter) end
      t.deepEq(log, { 'setRPB' }, 'the leaf the path names ran')
      t.eq(seen, 4, 'taking the pending prefix as its first argument')
      t.eq(mgr:isPrefixActive(), false, 'and the buffer is spent')
    end,
  },

  {
    -- The digit's route back out: a digit typed after the slash means the rational, so key
    -- dispatch calls the dismissal the menu's scope declares beside its letter sink.
    name = 'the scope declares a dismissal that closes the walk outright',
    run = function()
      local mgr, menu = fixture('tracker')
      mgr:invoke('openMenu')
      menu:press('G')
      t.eq(#menu:path(), 1, 'a walk one level down')

      mgr:scope('menu').dismiss()
      t.eq(menu:isOpen(), false, 'the dismissal closes it from any depth')
      t.eq(mgr.stack[#mgr.stack], mgr:scope('tracker'), 'and the page scope is back on top')
    end,
  },

  {
    -- How a letter arrives: the menu's scope declares the sink key dispatch offers a bare
    -- letter to, and the sink is the top scope's alone, so nothing captures a letter until
    -- the menu is open. See docs/commandManager.md § Scope stack.
    name = 'the open menu is what captures a letter',
    run = function()
      local mgr, menu = fixture('tracker')
      t.eq(mgr:letterCapture(), nil, 'with the page on top no scope captures letters')

      mgr:invoke('openMenu')
      local capture = mgr:letterCapture()
      t.truthy(capture, 'the open menu takes them')
      capture('G')
      t.deepEq(titles(menu:path()), { 'Grid' }, 'and hands each one to the walk')

      mgr:invoke('menuBack')
      mgr:invoke('menuBack')
      t.eq(mgr:letterCapture(), nil, 'a closed menu captures nothing again')
    end,
  },

  {
    -- The second route through a level, for a path not known by heart. The level draws as
    -- one row, so Left and Right run along it, and either end joins the other.
    name = 'the highlight moves along the level, and wraps at either end',
    run = function()
      local mgr, menu = fixture('tracker')
      mgr:invoke('openMenu')
      local top = menu:level()
      t.truthy(#top > 2, 'the top level holds a row to move along')
      t.eq(menu:highlight(), 1, 'the walk opens on the first member')

      mgr:invoke('menuRight')
      t.eq(menu:highlight(), 2, 'Right moves along the row')
      mgr:invoke('menuLeft')
      mgr:invoke('menuLeft')
      t.eq(menu:highlight(), #top, 'and Left off the front wraps to the last member')
      mgr:invoke('menuRight')
      t.eq(menu:highlight(), 1, 'as Right off the end wraps to the first')
    end,
  },

  {
    -- Enter is the letter's equal: it descends on a group and invokes on a leaf, so the same
    -- walk taken either way reaches the same command. /GQ is the tracker's quantize.
    name = 'Enter takes the highlight, doing what that member\'s letter would',
    run = function()
      local mgr, menu, log = fixture('tracker')
      mgr:invoke('openMenu')
      menu:press('G')
      menu:press('Q')
      t.deepEq(log, { 'quantize' }, 'the letters reach the leaf')

      mgr:invoke('openMenu')
      highlightTo(mgr, indexOf(menu:level(), 'Grid'))
      mgr:invoke('menuEnter')
      t.deepEq(titles(menu:path()), { 'Grid' }, 'Enter on a group descends into it')
      t.eq(menu:highlight(), 1, 'and the level below opens on its first member')

      highlightTo(mgr, indexOf(menu:level(), mgr:entry('quantize')))
      mgr:invoke('menuEnter')
      t.deepEq(log, { 'quantize', 'quantize' }, 'Enter on a leaf invokes what its letter did')
      t.eq(menu:isOpen(), false, 'and the menu is closed behind it')
    end,
  },

  {
    -- What the unwind restores: a descent marks the level it leaves with the member it was
    -- taken through, so stepping back up the path lands the highlight where the eye left it,
    -- whether the descent was by letter or by Enter.
    name = 'an unwind returns the highlight to the member it descended through',
    run = function()
      local mgr, menu = fixture('tracker')
      mgr:invoke('openMenu')
      local top  = menu:level()
      local grid = indexOf(top, 'Grid')
      t.truthy(grid > 1, 'the group is not the one the walk opens on')

      menu:press('G')
      t.eq(menu:highlight(), 1, 'the descent opens on the first member below')
      mgr:invoke('menuRight')
      mgr:invoke('menuBack')
      t.deepEq(titles(menu:level()), titles(top), 'the unwind is back at the level it came from')
      t.eq(menu:highlight(), grid, 'with the highlight on the group it descended through')

      mgr:invoke('menuEnter')
      t.deepEq(titles(menu:path()), { 'Grid' }, 'which Enter descends into again')
      t.eq(menu:highlight(), 1, 'from the first member, the mark below being spent')
    end,
  },

  {
    -- The prefix is the leaf's, whichever route reaches it: moving the highlight neither
    -- freezes nor spends the buffer, and Enter freezes it exactly where a letter does.
    name = 'the highlight keys leave a pending prefix for the leaf Enter reaches',
    run = function()
      local mgr, menu, log = fixture('tracker')
      local seen
      mgr:scope('tracker'):register('setRPB', function(n) util.add(log, 'setRPB'); seen = n end)

      mgr:beginPrefix(); mgr:appendPrefix('4'); mgr:appendPrefix('/')
      mgr:invoke('openMenu')
      menu:press('V')
      menu:press('R')
      highlightTo(mgr, indexOf(menu:level(), mgr:entry('setRPB')))
      t.eq(mgr:isPrefixActive(), true, 'moving the highlight leaves the buffer open')

      mgr:invoke('menuEnter')
      t.deepEq(log, { 'setRPB' }, 'Enter reached the leaf the path names')
      t.eq(seen, 4, 'taking the pending prefix as its first argument')
      t.eq(mgr:isPrefixActive(), false, 'and the buffer is spent')
    end,
  },
}
