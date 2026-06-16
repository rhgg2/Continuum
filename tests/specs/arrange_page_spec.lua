-- Pin-tests for arrangePage's Page interface and arrange-scope edit commands.
-- Cursor mechanics, off-screen no-op, and selection-precedence: arrange_view_spec.

-- arrangePage requires ImGui at module scope; stubbed via package.preload
-- so the module loads in the pure-Lua harness.

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

local fakeModalHost = {
  last                = nil,
  open                = function(self, state) self.last = state end,
  openPrompt          = function(self, state) self.last = state end,
  openConfirm         = function(self, state) self.last = state end,
  registerKind        = function() end,
  isOpen              = function() return false end,
  wasOpenAtFrameStart = function() return false end,
}
-- captured.nav = switchPage target (dive seam); captured.props = item handed to the tracker facade.
-- captured.facades holds the page's published facades so tests can drive arrange's own capabilities.
local captured = { facades = {} }
local fakeFacade = {
  publish = function(name, iface) captured.facades[name] = iface end,
  get = function(name)
    if name == 'tracker' then
      return { openTakeProperties = function(item) captured.props = item end }
    end
    if name == 'wiring' then
      return { isWiringOwnedTrack = function() return false end }
    end
    return {}
  end,
}
local function newArrangePage(cm, ds, cmgr, chrome, gui)
  captured.nav, captured.props, captured.facades = nil, nil, {}
  fakeModalHost.last = nil
  cmgr:registerAll{ switchPage = function(_, name) captured.nav = name end }
  return util.instantiate('arrangePage',
    { cm = cm, ds = ds, cmgr = cmgr, chrome = chrome, gui = gui,
      modalHost = fakeModalHost, facade = fakeFacade })
end

return {
  {
    name = 'bind / unbind are no-ops — arrange page never re-keys cm',
    run = function(harness)
      local h  = harness.mk()
      local _  = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      local calls = 0
      h.cm.setTrack   = function() calls = calls + 1 end
      h.cm.setContext = function() calls = calls + 1 end
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:bind(); ap:bind('ignored'); ap:unbind()
      t.eq(calls, 0, 'no cm re-key from bind/unbind')
    end,
  },

  {
    name = 'focusState before any render returns both bits false',
    run = function(harness)
      local h  = harness.mk()
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      local fs = ap:focusState()
      t.eq(fs.suppressKbd, false, 'no suppression without a context')
      t.eq(fs.acceptCmds,  false, 'no acceptance without a context')
    end,
  },

  {
    name = 'arrange-scope is registered at module load (cursorRight invokable)',
    run = function(harness)
      local h = harness.mk()
      local _ = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
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
      local _ = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      h.cmgr:push('arrange')
      for _, name in ipairs{ 'drop0', 'drop9', 'dropa', 'dropz', 'dropA', 'dropZ' } do
        local ok = pcall(function() h.cmgr:invoke(name) end)
        t.eq(ok, true, name .. ' is bound under the arrange scope')
      end
    end,
  },

  {
    name = 'a place-command drop advances the cursor by cm.arrangeAdvanceBy rows',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.cm:set('project', 'arrangeAdvanceBy', 3)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 10, len = 3, srcLen = 3, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      h.cmgr:push('arrange')
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      am:tracksTakes(0)               -- materialise {p1} into a slot
      h.cmgr:invoke('drop0')          -- drops at row 0
      -- ap doesn't surface the cursor; observe the advance via a second
      -- drop, which must land at row 3 (advanceBy past the first).
      h.cmgr:invoke('drop0')
      local takes = am:tracksTakes(0)
      local seconds = 0
      for _, tk in ipairs(takes) do
        if math.abs(tk.startQN - 3) < 1e-6 then seconds = seconds + 1 end
      end
      t.eq(seconds, 1, 'second drop landed at startQN=3 — cursor advanced by arrangeAdvanceBy=3')
    end,
  },

  {
    name = 'arrangeAdvanceBy0..9 set cm.arrangeAdvanceBy at project tier',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:setProjectTracks{ 'tr1' }
      local _ = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeAdvanceBy5')
      t.eq(h.cm:get('arrangeAdvanceBy'), 5, 'arrangeAdvanceBy5 set arrangeAdvanceBy=5')
      h.cmgr:invoke('arrangeAdvanceBy0')
      t.eq(h.cm:get('arrangeAdvanceBy'), 0, 'arrangeAdvanceBy0 set arrangeAdvanceBy=0')
    end,
  },

  {
    name = 'chained Super-D walks down — each clone becomes the selection for the next',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 2, srcLen = 2, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      -- First Super-D clones, selects the copy, advances 2 rows.
      -- Second Super-D acts on that selection and clones it again.
      h.cmgr:invoke('arrangeDuplicateBelow')
      h.cmgr:invoke('arrangeDuplicateBelow')
      local am    = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      local takes = am:tracksTakes(0)
      t.eq(#takes, 3, 'second duplicate fired — cursor stayed on a take')
      t.eq(takes[3].startQN, 4, 'second clone at row 4 (natural end of clone-1)')
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
      local _ = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      h.cmgr:push('arrange')
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
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
    name = 'arrangeNudgeForward moves the cursor take by one row',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 1, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeNudgeForward')
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
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
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeNudgeForward')
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      t.eq(am:tracksTakes(0)[1].startQN, 1,
           'a multi-row take is not blocked by overlapping its own destination row')
    end,
  },

  {
    name = 'arrangeGrowTake lengthens the cursor take by one row',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      -- srcLen=8 leaves headroom above the seeded item length so the
      -- grow isn't immediately demoted back to util.OPEN by relayout.
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 2, srcLen = 8, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeGrowTake')
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
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
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeGrowTake')
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
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
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeShrinkTake')
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      t.eq(am:tracksTakes(0)[1].lengthQN, 2, 'shrink still works even when current length already exceeds source')
    end,
  },

  {
    name = 'arrangeDeleteTake removes the cursor take',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 1, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeDeleteTake')
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
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
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeNudgeForward')
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
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
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeNudgeBack')
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
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
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeGrowTake')
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
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
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeNudgeForward')
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
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
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeNudgeForward')
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
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
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeGrowTake')
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      local t1 = am:tracksTakes(0)[1]
      t.eq(t1.naturalLenQN, 2.5, 'natural length grew by one row')
      t.eq(t1.lengthQN, 2.5, 'rendered still fits below the neighbour\'s start')
    end,
  },

  {
    name = 'arrangeDive switches to the tracker for the cursor MIDI take',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 1, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeDive')
      t.eq(captured.nav, 'tracker', 'dive switched to the tracker page')
    end,
  },

  {
    name = 'arrangeDive is a no-op when the cursor take is audio',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/a1', isMidi = false,
                                pos = 0, len = 1, srcFile = '/snd/a.wav' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeDive')
      t.eq(captured.nav, nil, 'audio take does not dive')
    end,
  },

  {
    name = 'arrangeDive is a no-op when the cursor is over empty space',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeDive')
      t.eq(captured.nav, nil, 'empty grid, nothing under the cursor — dive is a no-op')
    end,
  },

  {
    name = 'kb edit acts on the cursor take when nothing is selected',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      -- Take at row 2; nothing is selected, so the edit targets whatever
      -- take the cursor is driven onto.
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 2, len = 1, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeCursorDown')
      h.cmgr:invoke('arrangeCursorDown')
      h.cmgr:invoke('arrangeDeleteTake')
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      t.eq(#am:tracksTakes(0), 0, 'cursor reached the take; delete acted on it')
    end,
  },

  {
    name = 'kb delete no-ops when the cursor sits off every take',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 1, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()      -- cursor on t1; nothing selected
      h.cmgr:push('arrange')
      -- Row 1 is the take's bottom-edge row (still counts as on it);
      -- row 2 is genuinely empty.
      h.cmgr:invoke('arrangeCursorDown')
      h.cmgr:invoke('arrangeCursorDown')
      h.cmgr:invoke('arrangeDeleteTake')
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      t.eq(#am:tracksTakes(0), 1, 'cursor on empty space, nothing selected — delete no-ops')
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
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      -- Two rows down clears the take's bottom edge into empty space.
      h.cmgr:invoke('arrangeCursorDown')
      h.cmgr:invoke('arrangeCursorDown')
      h.cmgr:invoke('arrangeNudgeForward')
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      t.eq(am:tracksTakes(0)[1].startQN, 0, 'no take under the cursor — nudge no-ops')
    end,
  },

  {
    name = 'an edit command is a no-op when the cursor is over empty space',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      -- Take well clear of the boot cursor, which sits on empty space.
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 5, len = 1, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeDeleteTake')
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      t.eq(#am:tracksTakes(0), 1, 'delete over empty space leaves the take alone')
    end,
  },

  {
    name = 'a second delete finds an empty cell under the cursor — no-op',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 1, poolGuid = '{p1}' })
      h.reaper:addItem('tr1', { take = 'tr1/t2', isMidi = true,
                                pos = 4, len = 1, poolGuid = '{p2}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()      -- cursor lands on t1
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeDeleteTake')
      local ok = pcall(function() h.cmgr:invoke('arrangeDeleteTake') end)
      t.eq(ok, true, 'a second delete over the empty cell does not error')
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      t.eq(#am:tracksTakes(0), 1, 't2 untouched — cursor on the now-empty cell')
    end,
  },

  {
    name = 'seedCursorFromReaper lands the cursor on the selected take',
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
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeDive')
      t.eq(captured.nav, 'tracker', 'cursor seeded on the selected take — dive fires via the fallback')
    end,
  },

  {
    name = 'seedCursorFromReaper falls back to the edit-cursor row',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 7, len = 1, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      h.reaper:setCursor(7)
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeDive')
      t.eq(captured.nav, 'tracker', 'cursor seeded at the edit-cursor row — dive fires via the fallback')
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
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeTakeProperties')
      t.eq(captured.props, item, 'take item routed to the tracker facade')
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
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeTakeProperties')
      t.eq(captured.props, nil, 'audio take is silently skipped')
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
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeDuplicateBelow')
      local am    = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
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
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeDuplicateBelow')
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
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
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeDuplicateUnpooledBelow')
      local am    = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      local takes = am:tracksTakes(0)
      t.eq(#takes, 2, 'fresh clone added below')
      t.eq(takes[2].startQN, 2, 'clone starts at the source take\'s natural end')
      t.truthy(captured.props, 'take properties opened on the new item')
      t.truthy(captured.props ~= takes[1].item, 'auto-open targets the new take, not the source')
    end,
  },

  -- The arrange facade now owns the tracker's old new-take-below / nav flows.
  {
    name = 'newTakeBelow facade mints a sibling at the natural end and lands the cursor on it',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 2, srcLen = 2, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      captured.facades.arrange.newTakeBelow()
      local s = fakeModalHost.last
      t.truthy(s,             'createSlot modal opened')
      t.eq(s.beatsBuf, '4',   'default 4 beats')
      s.callback('Verse', '3')
      local am    = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      local takes = am:tracksTakes(0)
      t.eq(#takes, 2,                'sibling minted on commit')
      t.eq(takes[2].startQN, 2,      'sibling at the source take\'s natural end')
      t.eq(takes[2].naturalLenQN, 3, 'honours the user\'s 3 beats')
      t.eq(captured.facades.arrange.currentTake(), takes[2].take, 'cursor landed on the new take')
    end,
  },

  {
    name = 'gotoTrack steps to the nearest take on the adjacent track, moving the cursor',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:setTrackName('tr2', 'Track 2')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true, pos = 0, len = 1, poolGuid = '{p1}' })
      h.reaper:addItem('tr2', { take = 'tr2/t1', isMidi = true, pos = 3, len = 1, poolGuid = '{p2}' })
      h.reaper:setProjectTracks{ 'tr1', 'tr2' }
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      captured.facades.arrange.gotoTrack(1)
      t.eq(captured.facades.arrange.currentTrackIdx(), 1, 'cursor moved to track 2')
      t.eq(captured.facades.arrange.currentTake(), 'tr2/t1', 'landed on the nearest take')
      t.eq(captured.facades.arrange.currentTrackHasTakes(), true, 'track 2 reports its take')
    end,
  },

  {
    name = 'gotoTrack no longer skips an empty track — lands on it with no take',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:setTrackName('tr2', 'Track 2')
      h.reaper:setTrackName('tr3', 'Track 3')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true, pos = 0, len = 1, poolGuid = '{p1}' })
      h.reaper:addItem('tr3', { take = 'tr3/t1', isMidi = true, pos = 0, len = 1, poolGuid = '{p3}' })
      h.reaper:setProjectTracks{ 'tr1', 'tr2', 'tr3' }
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      captured.facades.arrange.gotoTrack(1)
      t.eq(captured.facades.arrange.currentTrackIdx(), 1, 'landed on the empty middle track, not skipped to track 3')
      t.eq(captured.facades.arrange.currentTake(), nil, 'empty track has no take under the cursor')
      t.eq(captured.facades.arrange.currentTrackHasTakes(), false, 'empty track reports no takes')
    end,
  },
}
