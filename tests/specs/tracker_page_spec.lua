-- Pin-tests for trackerPage's Page interface (bind / unbind / focusState / bind-from-cursor).
-- render / handleInput are stubs wired in step 3 and verified in REAPER, not here.

-- trackerPage requires ImGui at module scope; stub via package.preload before
-- the first require so the module loads cleanly in the pure-Lua harness.

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

-- Capturing fake: stash the last open state so tests can simulate the
-- modal commit by calling fakeModalHost.last.callback(...). registerKind
-- accepts but ignores renderer bodies (no rendering happens here).
local fakeModalHost = {
  last                = nil,
  open                = function(self, state) self.last = state end,
  openPrompt          = function(self, state) self.last = state end,
  openConfirm         = function(self, state) self.last = state end,
  registerKind        = function() end,
  isOpen              = function() return false end,
  wasOpenAtFrameStart = function() return false end,
  reset               = function(self) self.last = nil end,
}

-- The tracker reaches arrange data through this facade. fakeArrange records
-- the nav/CRUD delegations and serves a settable currentTake for bindFromCursor.
local fakeArrange = {}
local function resetArrange()
  fakeArrange.calls = {}
  fakeArrange.currentTake     = function() return nil end
  fakeArrange.currentTrackIdx = function() return 0 end
  fakeArrange.currentSlotIdx  = function() return nil end
  fakeArrange.tracks          = function() return {} end
  fakeArrange.midiSlots       = function() return {} end
  fakeArrange.keyForSlot      = function() return '' end
  fakeArrange.newTakeBelow           = function() fakeArrange.calls.newTakeBelow = true end
  fakeArrange.duplicateUnpooledBelow = function() fakeArrange.calls.dup          = true end
  fakeArrange.gotoTrack = function(d) fakeArrange.calls.gotoTrack = d end
  fakeArrange.gotoTake  = function(d) fakeArrange.calls.gotoTake  = d end
  fakeArrange.pickTrack = function(i) fakeArrange.calls.pickTrack = i end
  fakeArrange.pickTake  = function(i) fakeArrange.calls.pickTake  = i end
end
local fakeFacade = {
  publish = function() end,
  get = function(name) if name == 'arrange' then return fakeArrange end return {} end,
}

local function newTrackerPage(cm, cmgr, chrome, gui)
  fakeModalHost:reset()
  resetArrange()
  return util.instantiate('trackerPage',
    { cm = cm, cmgr = cmgr, chrome = chrome, gui = gui,
      modalHost = fakeModalHost, facade = fakeFacade })
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

  -- In Model B the tracker no longer owns am: the bound take follows the arrange cursor, and
  -- newTakeBelow / dup / nav all delegate to the arrange facade (minting pinned in arrange_page_spec).
  {
    name = 'bindFromCursor binds tm to the arrange cursor take and drops on nil',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 1, poolGuid = '{p1}' })
      local tp = newTrackerPage(h.cm, h.cmgr, nil, {})
      fakeArrange.currentTake = function() return 'tr1/t1' end
      tp:bindFromCursor()
      t.eq(tp:currentTake(), 'tr1/t1', 'bound to the cursor take on change')
      fakeArrange.currentTake = function() return nil end
      tp:bindFromCursor()
      t.eq(tp:currentTake(), nil, 'dropped when the cursor has no take')
    end,
  },

  {
    name = 'newTakeBelow + duplicateUnpooledBelow delegate to the arrange facade',
    run = function(harness)
      local h = harness.mk()
      local tp = newTrackerPage(h.cm, h.cmgr, nil, {})
      h.cmgr:push('tracker')
      h.cmgr:invoke('newTakeBelow')
      t.truthy(fakeArrange.calls.newTakeBelow, 'newTakeBelow routed to arrange')
      h.cmgr:invoke('duplicateUnpooledBelow')
      t.truthy(fakeArrange.calls.dup, 'duplicateUnpooledBelow routed to arrange')
    end,
  },

  {
    name = 'prev/next track + take delegate to arrange cursor nav',
    run = function(harness)
      local h = harness.mk()
      local tp = newTrackerPage(h.cm, h.cmgr, nil, {})
      h.cmgr:push('tracker')
      h.cmgr:invoke('nextTrack'); t.eq(fakeArrange.calls.gotoTrack,  1, 'nextTrack -> gotoTrack(1)')
      h.cmgr:invoke('prevTrack'); t.eq(fakeArrange.calls.gotoTrack, -1, 'prevTrack -> gotoTrack(-1)')
      h.cmgr:invoke('nextTake');  t.eq(fakeArrange.calls.gotoTake,   1, 'nextTake -> gotoTake(1)')
      h.cmgr:invoke('prevTake');  t.eq(fakeArrange.calls.gotoTake,  -1, 'prevTake -> gotoTake(-1)')
    end,
  },
}
