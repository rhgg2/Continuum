-- Pin-tests for trackerPage's Page interface (bind / unbind / focusState).
-- render / handleInput / save / load are stubs wired in step 3 and
-- verified in REAPER rather than here.
--
-- trackerPage requires ImGui at module scope.  We stub it via
-- package.preload before the first require so the module loads cleanly
-- in the pure-Lua harness.

local t = require('support')
local fs = require('fs')

local n = 0
local fakeImGui = setmetatable({ Mod_None = 0 }, {
  __index = function(tbl, k) n = n + 1; rawset(tbl, k, n); return n end,
})
package.preload['imgui'] = function()
  return function(_) return fakeImGui end
end
_G.reaper.ImGui_GetBuiltinPath = function() return '/stub' end

local util = require('util')
local fakeModalHost = {
  open         = function() end,
  openPrompt   = function() end,
  openConfirm  = function() end,
  registerKind = function() end,
  isOpen       = function() return false end,
}
local function newTrackerPage(cm, cmgr, chrome, gui)
  return util.instantiate('trackerPage',
    { cm = cm, cmgr = cmgr, chrome = chrome, gui = gui, modalHost = fakeModalHost })
end

return {
  {
    name = "bind(take) drives cm:setContext via the page's own tm:bindTake",
    run = function(harness)
      local h  = harness.mk()
      local tp = newTrackerPage(h.cm, h.cmgr, nil, {})
      local got = {}
      h.cm.setContext = function(_, take) got[#got+1] = take end
      tp:bind('take99')
      t.eq(got[#got], 'take99', "page now owns cm context for its stack")
    end,
  },
  {
    name = "unbind() drives cm:setContext(nil) via the page's own tm:bindTake",
    run = function(harness)
      local h  = harness.mk()
      local tp = newTrackerPage(h.cm, h.cmgr, nil, {})
      local calls, lastTake = 0, 'sentinel'
      h.cm.setContext = function(_, take) calls = calls + 1; lastTake = take end
      tp:unbind()
      t.eq(calls, 1, "unbind invoked setContext exactly once")
      t.eq(lastTake, nil, "with nil")
    end,
  },
  {
    name = "focusState before any render returns both bits false",
    run = function(harness)
      local h  = harness.mk()
      local tp = newTrackerPage(h.cm, h.cmgr, nil, {})
      local fs = tp:focusState()
      t.eq(fs.suppressKbd, false, "no suppression without a context")
      t.eq(fs.acceptCmds,  false, "no acceptance without a context")
    end,
  },

  -- newTakeBelow / duplicateUnpooledBelow: tracker back-ports of the arrange
  -- dup-below trio. Both mint a sibling at the bound take's natural end and
  -- rebind tm to the new take. The pooled variant is intentionally absent.
  {
    name = 'newTakeBelow mints an empty sibling at natural end and rebinds tm',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 2, srcLen = 2, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local tp = newTrackerPage(h.cm, h.cmgr, nil, {})
      tp:bind('tr1/t1')
      h.cmgr:push('tracker')
      h.cmgr:invoke('newTakeBelow')
      local am    = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      local takes = am:tracksTakes(0)
      t.eq(#takes, 2, 'sibling minted')
      t.eq(takes[2].startQN, 2, 'sibling starts at the source take\'s natural end')
      t.truthy(tp:currentTake() ~= 'tr1/t1', 'tm rebound away from the source take')
      t.eq(tp:currentTake(), takes[2].take, 'tm now bound to the new sibling')
    end,
  },

  {
    name = 'duplicateUnpooledBelow mints a fresh-pool clone and rebinds tm',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 2, srcLen = 2, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local tp = newTrackerPage(h.cm, h.cmgr, nil, {})
      tp:bind('tr1/t1')
      h.cmgr:push('tracker')
      h.cmgr:invoke('duplicateUnpooledBelow')
      local am    = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      local takes = am:tracksTakes(0)
      t.eq(#takes, 2, 'fresh clone added below')
      t.eq(takes[2].startQN, 2, 'clone starts at the source take\'s natural end')
      t.eq(tp:currentTake(), takes[2].take, 'tm now bound to the clone')
    end,
  },

  {
    name = 'newTakeBelow + duplicateUnpooledBelow are silent on start-collision',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 2, srcLen = 2, poolGuid = '{p1}' })
      h.reaper:addItem('tr1', { take = 'tr1/t2', isMidi = true,
                                pos = 2, len = 1, srcLen = 1, poolGuid = '{p2}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local tp = newTrackerPage(h.cm, h.cmgr, nil, {})
      tp:bind('tr1/t1')
      h.cmgr:push('tracker')
      h.cmgr:invoke('newTakeBelow')
      h.cmgr:invoke('duplicateUnpooledBelow')
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      t.eq(#am:tracksTakes(0), 2, 'destination collided — no take added')
      t.eq(tp:currentTake(), 'tr1/t1', 'tm stays on the source take')
    end,
  },
}
