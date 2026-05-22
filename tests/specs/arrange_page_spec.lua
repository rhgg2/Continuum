-- Pin-tests for arrangePage's Page interface (bind / unbind / focusState).
-- The arrange-scope cursor commands are 4-line closures over av:setCursor;
-- av's cursor mechanics are pinned in arrange_view_spec, and the closures
-- are inspectable in source. Render methods pull in ImGui and are
-- exercised manually in REAPER.
--
-- arrangePage requires ImGui at module scope; stub via package.preload
-- before the first require so the module loads in the pure-Lua harness.

local t = require('support')

local n = 0
local fakeImGui = setmetatable({ Mod_None = 0 }, {
  __index = function(tbl, k) n = n + 1; rawset(tbl, k, n); return n end,
})
package.preload['imgui'] = function()
  return function(_) return fakeImGui end
end
_G.reaper.ImGui_GetBuiltinPath = function() return '/stub' end

local util = require('util')

local function newArrangePage(cm, cmgr, chrome, gui)
  return util.instantiate('arrangePage',
    { cm = cm, cmgr = cmgr, chrome = chrome, gui = gui })
end

return {
  {
    name = 'bind / unbind are no-ops — arrange page never re-keys cm',
    run = function(harness)
      local h  = harness.mk()
      local _  = newArrangePage(h.cm, h.cmgr, nil, {})
      local calls = 0
      h.cm.setTrack   = function() calls = calls + 1 end
      h.cm.setContext = function() calls = calls + 1 end
      local ap = newArrangePage(h.cm, h.cmgr, nil, {})
      ap:bind(); ap:bind('ignored'); ap:unbind()
      t.eq(calls, 0, 'no cm re-key from bind/unbind')
    end,
  },

  {
    name = 'focusState before any render returns both bits false',
    run = function(harness)
      local h  = harness.mk()
      local ap = newArrangePage(h.cm, h.cmgr, nil, {})
      local fs = ap:focusState()
      t.eq(fs.suppressKbd, false, 'no suppression without a context')
      t.eq(fs.acceptCmds,  false, 'no acceptance without a context')
    end,
  },

  {
    name = 'arrange-scope is registered at module load (cursorRight invokable)',
    run = function(harness)
      local h = harness.mk()
      local _ = newArrangePage(h.cm, h.cmgr, nil, {})
      h.cmgr:push('arrange')
      local ok = pcall(function() h.cmgr:invoke('cursorRight') end)
      t.eq(ok, true, 'cursorRight is bound under the arrange scope')
    end,
  },

  {
    name = 'arrange-scope place commands are registered (drop0/dropA/dropZ invokable)',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:setProjectTracks{ 'tr1' }
      local _ = newArrangePage(h.cm, h.cmgr, nil, {})
      h.cmgr:push('arrange')
      for _, name in ipairs{ 'drop0', 'drop9', 'dropa', 'dropz', 'dropA', 'dropZ' } do
        local ok = pcall(function() h.cmgr:invoke(name) end)
        t.eq(ok, true, name .. ' is bound under the arrange scope')
      end
    end,
  },

  {
    name = 'arrangeNudgeForward moves the take under the cursor by one row',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 1, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local _ = newArrangePage(h.cm, h.cmgr, nil, {})
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeNudgeForward')
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      t.eq(am:tracksTakes(0)[1].startQN, 1, 'take advanced one row')
    end,
  },

  {
    name = 'arrangeGrowTake lengthens the take under the cursor by one row',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 2, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local _ = newArrangePage(h.cm, h.cmgr, nil, {})
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeGrowTake')
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      t.eq(am:tracksTakes(0)[1].lengthQN, 3, 'take grew one row')
    end,
  },

  {
    name = 'arrangeDeleteTake removes the take under the cursor',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 1, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local _ = newArrangePage(h.cm, h.cmgr, nil, {})
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeDeleteTake')
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      t.eq(#am:tracksTakes(0), 0, 'no takes left')
    end,
  },

  {
    name = 'arrangeNudgeForward is a no-op when the next row is occupied',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 1, poolGuid = '{p1}' })
      h.reaper:addItem('tr1', { take = 'tr1/t2', isMidi = true,
                                pos = 1, len = 1, poolGuid = '{p2}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local _ = newArrangePage(h.cm, h.cmgr, nil, {})
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeNudgeForward')
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      t.eq(am:tracksTakes(0)[1].startQN, 0, 'blocked take stays put')
    end,
  },

  {
    name = 'arrangeNudgeBack is a no-op when the take is already at row 0',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 1, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local _ = newArrangePage(h.cm, h.cmgr, nil, {})
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeNudgeBack')
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      t.eq(am:tracksTakes(0)[1].startQN, 0, 'cannot nudge below 0')
    end,
  },

  {
    name = 'arrangeGrowTake is a no-op when the next row is occupied',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 2, poolGuid = '{p1}' })
      h.reaper:addItem('tr1', { take = 'tr1/t2', isMidi = true,
                                pos = 2, len = 1, poolGuid = '{p2}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local _ = newArrangePage(h.cm, h.cmgr, nil, {})
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeGrowTake')
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      t.eq(am:tracksTakes(0)[1].lengthQN, 2, 'blocked grow leaves length unchanged')
    end,
  },

  {
    name = 'arrangeNudgeForward refuses an inhabited row even when no overlap would result',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      -- Two sub-row takes: moving t1 into row 1 would not overlap t2,
      -- but row 1 already holds t2's start, so the nudge is refused.
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 0.3, poolGuid = '{p1}' })
      h.reaper:addItem('tr1', { take = 'tr1/t2', isMidi = true,
                                pos = 1.5, len = 0.3, poolGuid = '{p2}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local _ = newArrangePage(h.cm, h.cmgr, nil, {})
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeNudgeForward')
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      t.eq(am:tracksTakes(0)[1].startQN, 0, 'stays put — destination row is inhabited')
    end,
  },

  {
    name = 'arrangeGrowTake refuses growth into a row box another take inhabits',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      -- Growing t1 reaches QN 2.5 — clear of t2 at 2.7, no overlap — but
      -- 2.5 lies in row 2, the box t2 starts in, so the grow is refused.
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 1.5, poolGuid = '{p1}' })
      h.reaper:addItem('tr1', { take = 'tr1/t2', isMidi = true,
                                pos = 2.7, len = 0.2, poolGuid = '{p2}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local _ = newArrangePage(h.cm, h.cmgr, nil, {})
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeGrowTake')
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      t.eq(am:tracksTakes(0)[1].lengthQN, 1.5, 'stays put: grow would enter the neighbour row box')
    end,
  },
}
