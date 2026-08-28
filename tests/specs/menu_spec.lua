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
local function fixture()
  local log = {}
  local function logger(name) return function() util.add(log, name) end end
  local mgr = util.instantiate('commandManager', {})
  mgr:installManifest(require('manifest'), img)
  for _, name in ipairs{ 'playPause', 'switchToArrange', 'switchPage' } do
    mgr:register(name, logger(name))
  end
  for _, name in ipairs{ 'quantize', 'playFromCursor' } do
    mgr:scope('tracker'):register(name, logger(name))
  end
  local menu = util.instantiate('menu', { cmgr = mgr })
  mgr:push('tracker')
  return mgr, menu, log
end

return {
  {
    name = 'opening pushes the menu scope over the page, and closing pops it',
    run = function()
      local mgr, menu = fixture()
      t.eq(menu:isOpen(), false, 'the menu starts closed')

      mgr:invoke('openMenu')
      t.eq(menu:isOpen(), true, '/ opens it')
      t.eq(mgr.stack[#mgr.stack], mgr:scope('menu'), 'its scope is on top')
      t.eq(#mgr.stack, 3, 'above global and the page')

      mgr:invoke('closeMenu')
      t.eq(menu:isOpen(), false, 'Esc closes it')
      t.eq(mgr.stack[#mgr.stack], mgr:scope('tracker'), 'the page scope is back on top')
    end,
  },

  {
    -- The point of the modality: while the menu is up a letter means a menu letter, so the
    -- verbs it walks to are unreachable by key and by name alike.
    name = 'a page verb is blocked while the menu is open, and live again after',
    run = function()
      local mgr, _, log = fixture()
      mgr:invoke('quantize')
      t.deepEq(log, { 'quantize' }, 'the page verb fires with the page on top')

      mgr:invoke('openMenu')
      mgr:invoke('quantize')
      t.deepEq(log, { 'quantize' }, 'the modal scope blocks it')
      t.eq(mgr:keysFor('quantize'), nil, 'and no chord reaches it either')

      mgr:invoke('closeMenu')
      mgr:invoke('quantize')
      t.deepEq(log, { 'quantize', 'quantize' }, 'the block lasts exactly as long as the walk')
    end,
  },

  {
    -- Passthrough by group, read off the stack: global's Transport and Pages, and the
    -- tracker's own transport verbs, which only a page scope declares.
    name = 'the transport and the page switchers stay live through the walk',
    run = function()
      local mgr, _, log = fixture()
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
      local mgr = fixture()
      mgr:invoke('closeMenu')
      t.eq(#mgr.stack, 2, 'close does nothing while the menu is closed')

      mgr:invoke('openMenu')
      mgr:invoke('openMenu')
      t.eq(#mgr.stack, 3, 'and open is blocked by the scope it pushed')
    end,
  },
}
