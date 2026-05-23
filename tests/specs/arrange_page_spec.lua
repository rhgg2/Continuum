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

local function newArrangePage(cm, cmgr, chrome, gui, onDive, onTakeProperties)
  return util.instantiate('arrangePage',
    { cm = cm, cmgr = cmgr, chrome = chrome, gui = gui,
      onDive = onDive, onTakeProperties = onTakeProperties })
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
    name = 'a place-command drop inherits the length of an existing instance',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      -- One three-row instance of the slot, parked clear of the boot
      -- cursor at (0,0) where drop0 lands. srcLen pins the sibling's
      -- source so relayout doesn't stretch the dropped instance past 3.
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 10, len = 3, srcLen = 3, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local _ = newArrangePage(h.cm, h.cmgr, nil, {})
      h.cmgr:push('arrange')
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      am:tracksTakes(0)            -- materialise {p1} into a slot, as a render frame would
      h.cmgr:invoke('drop0')
      local dropped
      for _, tk in ipairs(am:tracksTakes(0)) do
        if tk.startQN == 0 then dropped = tk end
      end
      t.eq(dropped and dropped.lengthQN, 3,
           'dropped instance matches its sibling, not a one-row default')
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
      -- srcLen=8 leaves headroom above the seeded item length so the
      -- grow isn't immediately demoted back to util.OPEN by relayout.
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 2, srcLen = 8, poolGuid = '{p1}' })
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
    name = 'arrangeGrowTake silently no-ops at the take-source length cap',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 2, srcLen = 2, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeGrowTake')
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      t.eq(am:tracksTakes(0)[1].lengthQN, 2, 'grow past source length is a no-op')
    end,
  },

  {
    name = 'arrangeShrinkTake bypasses the source-length cap',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 3, srcLen = 2, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeShrinkTake')
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      t.eq(am:tracksTakes(0)[1].lengthQN, 2, 'shrink still works even when current length already exceeds source')
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
    name = 'arrangeGrowTake against a flush neighbour stores intent; rendered is gap-capped',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 2, srcLen = 8, poolGuid = '{p1}' })
      h.reaper:addItem('tr1', { take = 'tr1/t2', isMidi = true,
                                pos = 2, len = 1, srcLen = 1, poolGuid = '{p2}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeGrowTake')
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      local t1 = am:tracksTakes(0)[1]
      t.eq(t1.lengthQN,    2, 'rendered stuck at the next-take start')
      t.eq(t1.naturalLenQN, 3, 'natural grew — will regrow if t2 moves')
    end,
  },

  {
    name = 'arrangeNudgeForward steps past a neighbour without a start-collision',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      -- Under the natural-length model, the nudge is allowed: t1 lands
      -- at row 1, t2 stays at row 1.5, no start clash. The relayout pass
      -- caps t1's rendered length at 0.5 (gap to t2.start) without
      -- moving anything else.
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 0.3, srcLen = 0.3, poolGuid = '{p1}' })
      h.reaper:addItem('tr1', { take = 'tr1/t2', isMidi = true,
                                pos = 1.5, len = 0.3, srcLen = 0.3, poolGuid = '{p2}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeNudgeForward')
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      t.eq(am:tracksTakes(0)[1].startQN, 1, 'steps forward by one row')
    end,
  },

  {
    name = 'arrangeNudgeForward truncates the displaced take when stepping past',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      -- t1 (3-row) nudges from 0 to 1. t2 at 3.6 is untouched; t1's
      -- rendered length is capped at the gap (3.6 - 1 = 2.6) by
      -- relayout, while its natural length stays at 3.
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 3, srcLen = 3, poolGuid = '{p1}' })
      h.reaper:addItem('tr1', { take = 'tr1/t2', isMidi = true,
                                pos = 3.6, len = 0.3, srcLen = 0.3, poolGuid = '{p2}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeNudgeForward')
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      local t1 = am:tracksTakes(0)[1]
      t.eq(t1.startQN, 1, 'tall take moves forward')
      t.eq(t1.lengthQN, 2.6, 'rendered length capped by next-take start')
      t.eq(t1.naturalLenQN, 3, 'natural length unchanged')
    end,
  },

  {
    name = 'arrangeGrowTake grows natural even when rendered is capped by a neighbour',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      -- Growing t1 raises its natural to 2.5; rendered stays capped at
      -- 2.7 (t2.start). Deleting t2 then exposes the full natural.
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 1.5, srcLen = 8, poolGuid = '{p1}' })
      h.reaper:addItem('tr1', { take = 'tr1/t2', isMidi = true,
                                pos = 2.7, len = 0.2, srcLen = 0.2, poolGuid = '{p2}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeGrowTake')
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      local t1 = am:tracksTakes(0)[1]
      t.eq(t1.naturalLenQN, 2.5, 'natural length grew by one row')
      t.eq(t1.lengthQN, 2.5, 'rendered still fits below the neighbour\'s start')
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
    name = 'kb mutation reselects the take under the cursor',
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
    name = 'kb delete no-ops when the cursor has moved off the focused take',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 1, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.cmgr, nil, {})
      ap:seedCursorFromReaper()      -- cursor and focus on t1
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeCursorDown')   -- cursor moves to empty row 1
      h.cmgr:invoke('arrangeDeleteTake')
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      t.eq(#am:tracksTakes(0), 1, 'delete reselected under cursor (empty), so t1 survives')
    end,
  },

  {
    name = 'kb nudge no-ops when cursor sits on empty space',
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
      h.cmgr:invoke('arrangeCursorDown')   -- cursor leaves the take's row
      h.cmgr:invoke('arrangeNudgeForward')
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      t.eq(am:tracksTakes(0)[1].startQN, 0, 'nudge reselected under empty cursor — no-op')
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

  -- arrangeTakeProperties / arrangeDuplicateBelow / arrangeDuplicateUnpooledBelow:
  -- the keyboard-bound counterparts of the take-props modal and the dup-below
  -- trio. arrangeTakeProperties + arrangeDuplicateUnpooledBelow both route the
  -- target take's item through onTakeProperties so coord can host the modal on
  -- the tracker page's tm/tv. arrangeDuplicateBelow is silent.
  {
    name = 'arrangeTakeProperties routes the focused MIDI take through onTakeProperties',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      local item = h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                             pos = 0, len = 1, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local opened
      local ap = newArrangePage(h.cm, h.cmgr, nil, {}, nil, function(it) opened = it end)
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeTakeProperties')
      t.eq(opened, item, 'onTakeProperties received the focused take item')
    end,
  },

  {
    name = 'arrangeTakeProperties is a no-op on an audio take',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/a1', isMidi = false,
                                pos = 0, len = 1, srcFile = '/snd/a.wav' })
      h.reaper:setProjectTracks{ 'tr1' }
      local opened = false
      local ap = newArrangePage(h.cm, h.cmgr, nil, {}, nil, function() opened = true end)
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeTakeProperties')
      t.eq(opened, false, 'audio take is silently skipped')
    end,
  },

  {
    name = 'arrangeDuplicateBelow drops a pooled clone at the focused take\'s natural end',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 2, srcLen = 2, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeDuplicateBelow')
      local am    = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      local takes = am:tracksTakes(0)
      t.eq(#takes, 2, 'pooled clone added below')
      t.eq(takes[2].startQN, 2, 'clone starts at the source take\'s natural end')
    end,
  },

  {
    name = 'arrangeDuplicateBelow is silent on start-collision and on audio takes',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      -- A flush downstream neighbour shares the natural-end QN — the dup
      -- would collide and is refused silently.
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 2, srcLen = 2, poolGuid = '{p1}' })
      h.reaper:addItem('tr1', { take = 'tr1/t2', isMidi = true,
                                pos = 2, len = 1, srcLen = 1, poolGuid = '{p2}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeDuplicateBelow')
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      t.eq(#am:tracksTakes(0), 2, 'no clone added — destination collided')
    end,
  },

  {
    name = 'arrangeDuplicateUnpooledBelow mints a fresh-pool clone and auto-opens take-props',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 2, srcLen = 2, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local opened
      local ap = newArrangePage(h.cm, h.cmgr, nil, {}, nil, function(it) opened = it end)
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeDuplicateUnpooledBelow')
      local am    = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      local takes = am:tracksTakes(0)
      t.eq(#takes, 2, 'fresh clone added below')
      t.eq(takes[2].startQN, 2, 'clone starts at the source take\'s natural end')
      t.truthy(opened, 'onTakeProperties fired with the new item')
      t.truthy(opened ~= takes[1].item, 'auto-open targets the new take, not the source')
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
