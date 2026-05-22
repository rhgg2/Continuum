-- Pin-tests for arrangePage's Page interface (bind / unbind / focusState)
-- and the arrange-scope edit commands. Edit commands act on the focused
-- take, not the cursor cell; tests seed focus the way boot does, via
-- seedCursorFromReaper, or move it with the cursor-nav commands. av's
-- cursor mechanics are pinned in arrange_view_spec. Render methods (and
-- mouse focus) pull in ImGui and are exercised manually in REAPER.
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

local function newArrangePage(cm, cmgr, chrome, gui, onDive)
  return util.instantiate('arrangePage',
    { cm = cm, cmgr = cmgr, chrome = chrome, gui = gui, onDive = onDive })
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
    name = 'arrangeNudgeForward moves the focused take by one row',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 1, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeNudgeForward')
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      t.eq(am:tracksTakes(0)[1].startQN, 1, 'take advanced one row')
    end,
  },

  {
    name = 'arrangeNudgeForward moves a take taller than one row',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 3, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeNudgeForward')
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      t.eq(am:tracksTakes(0)[1].startQN, 1,
           'a multi-row take is not blocked by overlapping its own destination row')
    end,
  },

  {
    name = 'arrangeGrowTake lengthens the focused take by one row',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 2, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeGrowTake')
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      t.eq(am:tracksTakes(0)[1].lengthQN, 3, 'take grew one row')
    end,
  },

  {
    name = 'arrangeDeleteTake removes the focused take',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 1, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
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
      local ap = newArrangePage(h.cm, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
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
      local ap = newArrangePage(h.cm, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
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
      local ap = newArrangePage(h.cm, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
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
      local ap = newArrangePage(h.cm, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeNudgeForward')
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      t.eq(am:tracksTakes(0)[1].startQN, 0, 'stays put — destination row is inhabited')
    end,
  },

  {
    name = 'arrangeNudgeForward refuses a tall take entering a row another take occupies',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      -- t1's off-grid length leaves it occupying part of row 2; nudged
      -- down its body reaches into row 3, where t2 sits. The exact QN
      -- ranges never touch (so freeSpan's raw bound permits the step)
      -- and row 3 is not t1's cursor-neighbour row — only freeSpan
      -- quantised to row boxes catches the co-tenancy.
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 2.5, poolGuid = '{p1}' })
      h.reaper:addItem('tr1', { take = 'tr1/t2', isMidi = true,
                                pos = 3.6, len = 0.3, poolGuid = '{p2}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeNudgeForward')
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      t.eq(am:tracksTakes(0)[1].startQN, 0, 'tall take stays put — row 3 is already occupied')
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
      local ap = newArrangePage(h.cm, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeGrowTake')
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      t.eq(am:tracksTakes(0)[1].lengthQN, 1.5, 'stays put: grow would enter the neighbour row box')
    end,
  },

  {
    name = 'arrangeDive routes the focused MIDI take through onDive',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      local item = h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                             pos = 0, len = 1, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local dived
      local ap = newArrangePage(h.cm, h.cmgr, nil, {}, function(it) dived = it end)
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeDive')
      t.eq(dived, item, 'onDive received the focused take item')
    end,
  },

  {
    name = 'arrangeDive is a no-op when the focused take is audio',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/a1', isMidi = false,
                                pos = 0, len = 1, srcFile = '/snd/a.wav' })
      h.reaper:setProjectTracks{ 'tr1' }
      local dived = false
      local ap = newArrangePage(h.cm, h.cmgr, nil, {}, function() dived = true end)
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeDive')
      t.eq(dived, false, 'audio take does not dive')
    end,
  },

  {
    name = 'arrangeDive is a no-op when nothing is focused',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:setProjectTracks{ 'tr1' }
      local dived = false
      local ap = newArrangePage(h.cm, h.cmgr, nil, {}, function() dived = true end)
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeDive')
      t.eq(dived, false, 'empty grid focuses nothing — dive is a no-op')
    end,
  },

  {
    name = 'keyboard nav adopts the take the cursor lands on as the focus',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      -- Take at row 2; the boot cursor sits at (0,0) over empty space,
      -- so nothing is focused until the cursor is driven onto the take.
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 2, len = 1, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeCursorDown')
      h.cmgr:invoke('arrangeCursorDown')
      h.cmgr:invoke('arrangeDeleteTake')
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      t.eq(#am:tracksTakes(0), 0, 'cursor reached the take, focused it, delete removed it')
    end,
  },

  {
    name = 'focus persists when the cursor moves on across empty space',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 1, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.cmgr, nil, {})
      ap:seedCursorFromReaper()      -- focuses t1 under the boot cursor
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeCursorDown')   -- cursor moves to empty row 1
      h.cmgr:invoke('arrangeDeleteTake')
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      t.eq(#am:tracksTakes(0), 0, 'delete still hit t1 — focus held while the cursor moved off')
    end,
  },

  {
    name = 'nudge moves the focused take even when the cursor sits on another row',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 1, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.cmgr, nil, {})
      ap:seedCursorFromReaper()      -- focuses t1
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeCursorDown')   -- cursor leaves the take's row
      h.cmgr:invoke('arrangeNudgeForward')
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      t.eq(am:tracksTakes(0)[1].startQN, 1, 'nudge acted on focus, not the empty cursor cell')
    end,
  },

  {
    name = 'an edit command is a no-op when nothing is focused',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      -- Take well clear of the boot cursor, so seeding focuses nothing.
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 5, len = 1, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeDeleteTake')
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      t.eq(#am:tracksTakes(0), 1, 'delete with no focus leaves the take alone')
    end,
  },

  {
    name = 'deleting the focused take clears focus — a second delete is a no-op',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 1, poolGuid = '{p1}' })
      h.reaper:addItem('tr1', { take = 'tr1/t2', isMidi = true,
                                pos = 4, len = 1, poolGuid = '{p2}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.cmgr, nil, {})
      ap:seedCursorFromReaper()      -- focuses t1
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeDeleteTake')
      local ok = pcall(function() h.cmgr:invoke('arrangeDeleteTake') end)
      t.eq(ok, true, 'a second delete on the now-stale handle does not error')
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      t.eq(#am:tracksTakes(0), 1, 't2 untouched — focus cleared, did not jump to it')
    end,
  },

  {
    name = 'seedCursorFromReaper focuses the selected take',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:setTrackName('tr2', 'Track 2')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 1, poolGuid = '{p1}' })
      local item2 = h.reaper:addItem('tr2', { take = 'tr2/t1', isMidi = true,
                                              pos = 5, len = 1, poolGuid = '{p2}' })
      h.reaper:setProjectTracks{ 'tr1', 'tr2' }
      h.reaper.SetMediaItemSelected(item2, true)
      local dived
      local ap = newArrangePage(h.cm, h.cmgr, nil, {}, function(it) dived = it end)
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeDive')
      t.eq(dived, item2, 'focus seeded on the selected take — dive lands on it')
    end,
  },

  {
    name = 'seedCursorFromReaper falls back to the edit-cursor row',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      local item = h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                             pos = 7, len = 1, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      h.reaper:setCursor(7)
      local dived
      local ap = newArrangePage(h.cm, h.cmgr, nil, {}, function(it) dived = it end)
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeDive')
      t.eq(dived, item, 'focus seeded at the edit-cursor row — dive lands on the take there')
    end,
  },

  {
    name = 'revealTake focuses the take wrapping a REAPER take handle',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      local item = h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                             pos = 3, len = 1, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local dived
      local ap = newArrangePage(h.cm, h.cmgr, nil, {}, function(it) dived = it end)
      ap:revealTake('tr1/t1')
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeDive')
      t.eq(dived, item, 'take revealed and focused — dive lands on it')
    end,
  },
}
