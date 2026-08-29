-- Pin-tests for arrangePage's Page interface and arrange-scope edit commands.
-- Cursor mechanics, off-screen no-op, and selection-precedence: arrange_view_spec.

-- arrangePage requires ImGui at module scope; stubbed via package.preload
-- so the module loads in the pure-Lua harness.

local t = require('support')

local fakeImGui = t.imgui()
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
      return {
        openTakeProperties = function(item) captured.props = item end,
        diveTo = function(guid, slotIdx, _, qn)
          captured.dive = { guid = guid, slot = slotIdx, qn = qn }
        end,
      }
    end
    if name == 'wiring' then
      return { isWiringOwnedTrack = function() return false end }
    end
    return {}
  end,
}
local function newArrangePage(cm, ds, cmgr, chrome, gui, help)
  captured.nav, captured.props, captured.dive, captured.facades = nil, nil, nil, {}
  fakeModalHost.last = nil
  cmgr:registerAll{ switchPage = function(_, name) captured.nav = name end }
  local keyQueue = util.instantiate('keyQueue', { ctx = gui and gui.ctx })
  help = help or util.instantiate('help',
    { ctx = gui and gui.ctx, chrome = chrome, cmgr = cmgr, keyQueue = keyQueue })
  return util.instantiate('arrangePage',
    { cm = cm, ds = ds, cmgr = cmgr, chrome = chrome, gui = gui, help = help,
      eventMeta = util.instantiate('eventMeta', { ps = util.instantiate('pextStore') }),
      modalHost = fakeModalHost, facade = fakeFacade })
end

-- Two instances of slot 0, one row each at QN 0 and 1, with rows 0..1 banded.
-- The siblings at QN 10 and 20 are what slots 0 and 1 clone from.
local function twoSelected(h)
  h.cm:set('project', 'arrangeBeatPerRow', 1)
  h.cm:set('project', 'arrangeAdvanceBy', 1)
  h.reaper:setTrackName('tr1', 'Track 1')
  h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                            pos = 10, len = 1, srcLen = 1, poolGuid = '{p1}' })
  h.reaper:addItem('tr1', { take = 'tr1/t2', isMidi = true,
                            pos = 20, len = 2, srcLen = 2, poolGuid = '{p2}' })
  h.reaper:setProjectTracks{ 'tr1' }
  newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
  h.cmgr:push('arrange')
  local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
  am:tracksTakes(0)
  h.cmgr:invoke('drop0')               -- QN 0, cursor to row 1
  h.cmgr:invoke('drop0')               -- QN 1, cursor to row 2
  h.cmgr:invoke('arrangeCursorUp')
  h.cmgr:invoke('arrangeCursorUp')     -- back to row 0, selection cleared
  h.cmgr:invoke('arrangeSelectDown')   -- band over rows 0..1: both takes
  return am
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

  -- The mini-map's window onto the arrangement: the tracker asks the arrange
  -- facade for the instances over a span of columns and QN.
  {
    name = 'the arrange facade enumerates the takes over a span of columns and QN',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:setTrackName('tr2', 'Track 2')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 2, srcLen = 2, poolGuid = '{p1}' })
      h.reaper:addItem('tr1', { take = 'tr1/t2', isMidi = true,
                                pos = 8, len = 2, srcLen = 2, poolGuid = '{p2}' })
      h.reaper:addItem('tr2', { take = 'tr2/t1', isMidi = true,
                                pos = 1, len = 2, srcLen = 2, poolGuid = '{p3}' })
      h.reaper:setProjectTracks{ 'tr1', 'tr2' }
      newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      local arrange = captured.facades.arrange

      local takes = arrange.visibleTakes(0, 1, 0, 4)
      table.sort(takes, function(a, b)
        if a.trackIdx ~= b.trackIdx then return a.trackIdx < b.trackIdx end
        return a.startQN < b.startQN
      end)
      t.eq(#takes, 2, 'both instances meeting the window; the one at QN 8 is out')
      t.eq(takes[1].trackIdx, 0, 'the first from the left-hand column')
      t.eq(takes[1].startQN,  0, 'at its start QN')
      t.eq(takes[2].trackIdx, 1, 'the second from the next column')
      t.eq(takes[2].lengthQN, 2, 'carrying the length the grid paints')
      t.truthy(takes[2].slotIdx, 'and the slot the map takes its colour from')

      t.eq(#arrange.visibleTakes(0, 0, 0, 4), 1, 'the column span bounds the answer')
    end,
  },

  {
    name = 'the arrange facade answers the placement a QN falls in on a track',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 2, srcLen = 2, poolGuid = '{p1}' })
      h.reaper:addItem('tr1', { take = 'tr1/t2', isMidi = true,
                                pos = 2, len = 2, srcLen = 2, poolGuid = '{p2}' })
      h.reaper:setProjectTracks{ 'tr1' }
      newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      local arrange = captured.facades.arrange

      t.eq(arrange.instanceAt(0, 1).take, 'tr1/t1', 'the placement the QN falls inside')
      t.eq(arrange.instanceAt(0, 2).take, 'tr1/t2', 'the span is half-open, so a join belongs to the next')
      t.eq(arrange.instanceAt(0, 8), nil, 'a QN past every placement falls in none')
      t.eq(arrange.instanceAt(1, 1), nil, 'and a track with no placements answers nothing')
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
    -- The load-time check of docs/commandManager.md § Manifest, run against the
    -- page's own registrations: what the arrange scope registers and what
    -- manifest.lua declares are the same set, and every entry has a label.
    name = 'the manifest declares every command the arrange page registers',
    run = function(harness)
      local h = harness.mk()
      newArrangePage(h.cm, h.ds, h.cmgr, nil, {})

      local manifest = require('manifest')
      t.truthy(manifest.arrange, 'the arrange scope declares a manifest')
      h.cmgr:installManifest({ arrange = manifest.arrange }, fakeImGui)

      local scope, declared = h.cmgr:scope('arrange'), {}
      for _, entries in pairs(scope.manifest) do
        for _, entry in ipairs(entries) do
          declared[entry.name] = true
          t.truthy(entry.label, entry.name .. ' carries a label')
        end
      end
      t.deepEq(scope.registered, declared, 'declarations and registrations correspond')
    end,
  },

  {
    -- A placement names a group and nothing else, so one no scope declares draws
    -- no box and says nothing about it.
    name = 'every group the arrange page places is one some scope declares',
    run = function(harness)
      local h, placementsByPage = harness.mk(), {}
      local recorder = { registerPage = function(_, name, p) placementsByPage[name] = p end }
      newArrangePage(h.cm, h.ds, h.cmgr, nil, {}, recorder)

      local declared = {}
      for _, groups in pairs(require('manifest')) do
        for groupName in pairs(groups) do declared[groupName] = true end
      end
      local placements = placementsByPage.arrange
      t.truthy(placements and #placements > 0, 'the page registers its F1 placements')
      for _, placement in ipairs(placements) do
        t.truthy(declared[placement.group], placement.group .. ' is a declared group')
      end
    end,
  },

  {
    -- A bound command in no placed group is reachable only from memory. A keyless
    -- one has no chord to show, so it earns no row; the drop and advance families
    -- are exempt because a generated family earns one row, which is separate work.
    name = 'every bound command on the arrange page has a place on the cheat-sheet',
    run = function(harness)
      local h, placementsByPage = harness.mk(), {}
      local recorder = { registerPage = function(_, name, p) placementsByPage[name] = p end }
      newArrangePage(h.cm, h.ds, h.cmgr, nil, {}, recorder)
      local manifest = require('manifest')

      local placed = {}
      for _, placement in ipairs(placementsByPage.arrange) do placed[placement.group] = true end

      local missing = {}
      for _, scopeName in ipairs({ 'global', 'arrange' }) do
        for groupName, entries in pairs(manifest[scopeName]) do
          for _, entry in ipairs(entries) do
            local generated = entry.name:match('^drop%w$')
                           or entry.name:match('^arrangeAdvanceBy%d$')
            if entry.keys and not placed[groupName] and not generated then
              util.add(missing, entry.name)
            end
          end
        end
      end
      t.deepEq(missing, {}, 'bound commands the cheat-sheet never shows')
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
      newArrangePage(h.cm, h.ds, h.cmgr, nil, {})   -- registers the arrange scope's commands
      h.cmgr:push('arrange')
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      am:tracksTakes(0)               -- materialise {p1} into a slot
      h.cmgr:invoke('drop0')          -- drops at row 0
      -- The page doesn't surface the cursor; observe the advance via a second
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
    name = 'arrangeEdgeDown lengthens the cursor take by one row',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 2, srcLen = 8, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      -- An OPEN take fills its source (8) by build-time relayout, so give it a
      -- finite 2-row natural via resizeTake so the grow has somewhere to go.
      am:resizeTake(am:tracksTakes(0)[1], 2)
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeCursorDown')          -- off the start row, so the tail is armed
      h.cmgr:invoke('arrangeEdgeDown')
      t.eq(am:tracksTakes(0)[1].lengthQN, 3, 'take grew one row')
    end,
  },

  {
    name = 'growing a trimmed take moves its end, leaving the head where it was',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 4, srcLen = 8, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      am:trimHead(am:tracksTakes(0)[1], 2)         -- starts at row 2, skipping two beats
      am:resizeTake(am:tracksTakes(0)[1], 4)       -- four beats from the origin: two rendered
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeCursorDown')
      h.cmgr:invoke('arrangeCursorDown')
      h.cmgr:invoke('arrangeCursorDown')          -- inside the trimmed take, below its start row
      h.cmgr:invoke('arrangeEdgeDown')
      local tk = am:tracksTakes(0)[1]
      t.eq(tk.lengthQN, 3, 'one more row rendered — the end moved, not the start')
      t.eq(tk.startQN,  2, 'the head is untouched by a resize')
      t.eq(tk.originQN, 0, 'and so is the origin')
    end,
  },

  {
    name = 'arrangeEdgeDown silently no-ops at the take-source length cap',
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
      h.cmgr:invoke('arrangeCursorDown')          -- off the start row, so the tail is armed
      h.cmgr:invoke('arrangeEdgeDown')
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      t.eq(am:tracksTakes(0)[1].lengthQN, 2, 'grow past source length is a no-op')
    end,
  },

  {
    name = 'arrangeEdgeUp reduces the cursor take by one row',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 4, srcLen = 8, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      am:resizeTake(am:tracksTakes(0)[1], 3)   -- finite 3-row natural to shrink from
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeCursorDown')          -- off the start row, so the tail is armed
      h.cmgr:invoke('arrangeEdgeUp')
      t.eq(am:tracksTakes(0)[1].lengthQN, 2, 'shrink reduced the take by one row')
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

  -- Ctrl+Delete escalates Delete: not the instance under the cursor but the slot
  -- it belongs to, every instance of it, and the parked copy.
  {
    name = 'deleteSlot forever-deletes the cursor take\'s slot behind a confirm',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 1, poolGuid = '{p1}' })
      h.reaper:addItem('tr1', { take = 'tr1/t2', isMidi = true,
                                pos = 4, len = 1, poolGuid = '{p1}' })
      h.reaper:addItem('tr1', { take = 'tr1/t3', isMidi = true,
                                pos = 8, len = 1, poolGuid = '{p2}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()                    -- cursor on the first {p1} instance
      h.cmgr:push('arrange')
      h.cmgr:invoke('deleteSlot')
      t.truthy(fakeModalHost.last, 'confirm opened before anything is destroyed')
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      t.eq(#am:tracksTakes(0), 3, 'nothing gone while the confirm stands')
      fakeModalHost.last.callback(true)
      t.eq(#am:tracksTakes(0), 1, 'both instances of the cursor slot are gone')
      local slots = am:trackSlots(0)
      t.eq(#slots, 1, 'and the slot itself left the palette')
      t.eq(slots[1].id, '{p2}', 'the other slot untouched')
    end,
  },

  {
    name = 'deleteSlot no-ops with the cursor off every take',
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
      -- Row 1 is the take's bottom-edge row (still on it); row 2 is empty.
      h.cmgr:invoke('arrangeCursorDown')
      h.cmgr:invoke('arrangeCursorDown')
      h.cmgr:invoke('deleteSlot')
      t.eq(fakeModalHost.last, nil, 'no take under the cursor — no confirm, nothing deleted')
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
    name = 'arrangeEdgeDown against a flush neighbour stores intent; rendered is gap-capped',
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
      h.cmgr:invoke('arrangeCursorDown')          -- off the start row, so the tail is armed
      h.cmgr:invoke('arrangeEdgeDown')
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
      t.truthy(captured.dive and captured.dive.guid, 'dive handed the tracker the cursor track')
      t.eq(captured.dive.slot, 0, 'and the slot of the MIDI take under the cursor')
    end,
  },

  {
    name = 'createSlot dives the tracker onto the freshly-minted take',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('createSlot')                 -- opens the create modal
      t.truthy(fakeModalHost.last, 'create modal opened')
      fakeModalHost.last.callback('lead', '2')    -- OK: name + beats
      t.eq(captured.nav, 'tracker', 'create switched to the tracker page')
      t.truthy(captured.dive and captured.dive.guid, 'dive handed the tracker the new take\'s track')
      t.eq(captured.dive.slot, 0, 'and pinned the freshly-minted slot, not a restore')
    end,
  },

  {
    name = 'arrangeDive over an audio take still switches and restores (no take pinned)',
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
      t.eq(captured.nav, 'tracker', 'dive over an audio take still switches and sets the track')
      t.eq(captured.dive.slot, nil, 'no MIDI take under the cursor — take left unchanged (restore)')
    end,
  },

  {
    name = 'arrangeDive over empty space switches and restores',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeDive')
      t.eq(captured.nav, 'tracker', 'empty cursor still switches and sets the track')
      t.eq(captured.dive.slot, nil, 'nothing under the cursor — take left unchanged (restore)')
    end,
  },

  -- The caret QN is the tracker's half of the dive: it becomes a caret row there,
  -- against the take's own origin. Empty space pins no take, so it carries no row.
  {
    name = 'the dive carries the caret QN, and carries none over empty space',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 4, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeCursorDown')
      h.cmgr:invoke('arrangeCursorDown')
      h.cmgr:invoke('arrangeDive')
      t.eq(captured.dive.qn, 2, 'two rows down at a beat a row is two beats in')

      for _ = 1, 3 do h.cmgr:invoke('arrangeCursorDown') end   -- row 5, past the take
      h.cmgr:invoke('arrangeDive')
      t.falsy(captured.dive.qn, 'nothing under the caret — no row to carry')
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
  -- target take's item through the tracker facade, which binds tm to it and
  -- hosts the modal on the tracker page's tm/tv. arrangeDuplicateBelow is silent.
  {
    name = 'arrangeTakeProperties routes the focused MIDI take through the tracker facade',
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
    name = 'arrangeDuplicateBelow drops a pooled clone at the focused take\'s append point',
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
      t.eq(takes[2].startQN, 2, 'clone starts where the source take\'s render ends')
    end,
  },

  {
    name = 'arrangeDuplicateBelow is silent for want of room and on audio takes',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      -- A flush downstream neighbour starts on the append point — no free
      -- span at all, so the dup is refused silently.
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
      t.eq(#am:tracksTakes(0), 2, 'no clone added — no room at the append point')
    end,
  },

  {
    name = 'arrangeNextVariant past the last of the family swaps the target for a fresh variant',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true, pos = 0, len = 2, srcLen = 2,
                                poolGuid = '{p1}', takeName = 'Bass' })
      h.reaper:addItem('tr1', { take = 'tr1/t2', isMidi = true, pos = 2, len = 2, srcLen = 2,
                                poolGuid = '{p1}', takeName = 'Bass' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeNextVariant')
      local am    = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      local takes = am:tracksTakes(0)
      t.eq(#takes, 2, 'the instance was replaced, not added to')
      t.eq(#am:trackSlots(0), 2, 'the palette grew by the variant slot')
      local varied, parent
      for _, take in ipairs(takes) do
        if take.startQN == 0 then varied = take else parent = take end
      end
      t.truthy(varied, 'a take still stands where the source instance did')
      t.truthy(varied.slotIdx ~= parent.slotIdx, 'on a slot of its own')
      t.eq(varied.name, 'Bass (var 1)', 'named from the parent root')

      h.cmgr:invoke('arrangePrevVariant')
      local back
      for _, take in ipairs(am:tracksTakes(0)) do if take.startQN == 0 then back = take end end
      t.eq(back.slotIdx, parent.slotIdx, 'stepping back returns the placement to the parent slot')
      t.eq(#am:trackSlots(0), 2, 'the variant it left stands parked')
    end,
  },

  {
    -- The pooled duplicate leaves the caret on the copy's bottom edge, so takeAtCursor
    -- adopts it and the variant step forks it onto a slot of its own.
    name = 'arrangeDuplicateBelow then arrangeNextVariant forks the copy onto a fresh slot',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true, pos = 0, len = 2, srcLen = 2,
                                poolGuid = '{p1}', takeName = 'Bass' })
      h.reaper:setProjectTracks{ 'tr1' }
      local ap = newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      ap:seedCursorFromReaper()
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeDuplicateBelow')
      h.cmgr:invoke('arrangeNextVariant')
      local am    = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      local takes = am:tracksTakes(0)
      t.eq(#takes, 2, 'the source and its copy')
      local src, copy
      for _, take in ipairs(takes) do
        if take.startQN == 0 then src = take else copy = take end
      end
      t.eq(copy.startQN, 2, 'the copy sits at the append point')
      t.truthy(copy.slotIdx ~= src.slotIdx, 'on a slot of its own -- the fork')
      t.eq(copy.name, 'Bass (var 1)', 'named from the parent root')
      t.eq(#am:trackSlots(0), 2, 'the palette grew by the forked slot')
    end,
  },

  -- Replace mode (Super+U). The two sibling instances parked at QN 10 and 20
  -- are what slots 0 and 1 clone from; everything below QN 10 is the test's.
  {
    name = 'replace mode: a drop swaps the take under the cursor, keeping its start',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.cm:set('project', 'arrangeAdvanceBy', 0)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 10, len = 3, srcLen = 3, poolGuid = '{p1}' })
      h.reaper:addItem('tr1', { take = 'tr1/t2', isMidi = true,
                                pos = 20, len = 2, srcLen = 2, poolGuid = '{p2}' })
      h.reaper:setProjectTracks{ 'tr1' }
      newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      h.cmgr:push('arrange')
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      am:tracksTakes(0)                    -- materialise both pools into slots
      h.cmgr:invoke('drop0')               -- slot 0 lands at row 0, three rows long
      h.cmgr:invoke('arrangeCursorDown')   -- cursor inside it, past its start
      h.cmgr:invoke('arrangeReplaceMode')
      h.cmgr:invoke('drop1')
      local placed = {}
      for _, tk in ipairs(am:tracksTakes(0)) do
        if tk.startQN < 10 then util.add(placed, tk) end
      end
      t.eq(#placed, 1, 'one take on the grid — the replacement stands in the original\'s place')
      t.eq(placed[1].slotIdx,  1, 'it is the slot the drop key names')
      t.eq(placed[1].startQN,  0, 'at the replaced take\'s start, not at the cursor row')
      t.eq(placed[1].lengthQN, 2, 'at slot 1\'s natural length, not the length it replaced')
    end,
  },

  {
    name = 'a replace with a selection held replaces every selected take',
    run = function(harness)
      local h  = harness.mk()
      local am = twoSelected(h)
      h.cmgr:invoke('arrangeReplaceMode')
      h.cmgr:invoke('drop1')
      local placed = {}
      for _, tk in ipairs(am:tracksTakes(0)) do
        if tk.startQN < 10 then util.add(placed, tk) end
      end
      table.sort(placed, function(a, b) return a.startQN < b.startQN end)
      t.eq(#placed, 2, 'both selected takes still stand')
      t.eq(placed[1].slotIdx, 1, 'the first was replaced')
      t.eq(placed[2].slotIdx, 1, 'and so was the second, not just the cursor\'s')
      t.eq(placed[1].startQN, 0, 'each keeps its own start')
      t.eq(placed[2].startQN, 1, 'each keeps its own start')
      t.eq(placed[2].lengthQN, 2, 'the last one runs to slot 1\'s natural length')
    end,
  },

  {
    name = 'the replacements become the selection',
    run = function(harness)
      local h  = harness.mk()
      local am = twoSelected(h)
      h.cmgr:invoke('arrangeReplaceMode')
      h.cmgr:invoke('drop1')
      h.cmgr:invoke('arrangeDeleteTake')   -- acts on the selection, if there is one
      local left = 0
      for _, tk in ipairs(am:tracksTakes(0)) do
        if tk.startQN < 10 then left = left + 1 end
      end
      t.eq(left, 0, 'delete took both replacements — they carried the selection')
    end,
  },

  {
    name = 'a shorter replacement pulls the cursor back inside it',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.cm:set('project', 'arrangeAdvanceBy', 0)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 10, len = 3, srcLen = 3, poolGuid = '{p1}' })
      h.reaper:addItem('tr1', { take = 'tr1/t2', isMidi = true,
                                pos = 20, len = 2, srcLen = 2, poolGuid = '{p2}' })
      h.reaper:setProjectTracks{ 'tr1' }
      newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      h.cmgr:push('arrange')
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      am:tracksTakes(0)
      h.cmgr:invoke('drop0')               -- rows 0..2
      h.cmgr:invoke('arrangeCursorDown')
      h.cmgr:invoke('arrangeCursorDown')   -- cursor on row 2, the last row inside
      h.cmgr:invoke('arrangeReplaceMode')
      h.cmgr:invoke('drop1')               -- two rows: row 2 is now past its end
      h.cmgr:invoke('drop0')               -- places at wherever the cursor now sits
      local starts = {}
      for _, tk in ipairs(am:tracksTakes(0)) do
        if tk.startQN < 10 then util.add(starts, tk.startQN) end
      end
      table.sort(starts)
      t.eq(#starts, 2, 'the replacement and the drop that followed it')
      t.eq(starts[2], 1, 'cursor pulled up to the last row inside the replacement')
    end,
  },

  {
    name = 'replace mode disarms on the drop it reinterprets — the next drop places',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.cm:set('project', 'arrangeAdvanceBy', 0)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 10, len = 3, srcLen = 3, poolGuid = '{p1}' })
      h.reaper:addItem('tr1', { take = 'tr1/t2', isMidi = true,
                                pos = 20, len = 2, srcLen = 2, poolGuid = '{p2}' })
      h.reaper:setProjectTracks{ 'tr1' }
      newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      h.cmgr:push('arrange')
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      am:tracksTakes(0)
      h.cmgr:invoke('drop0')
      h.cmgr:invoke('arrangeCursorDown')
      h.cmgr:invoke('arrangeReplaceMode')
      h.cmgr:invoke('drop1')               -- replaces at QN 0
      h.cmgr:invoke('drop1')               -- disarmed: places at the cursor row
      local placed = {}
      for _, tk in ipairs(am:tracksTakes(0)) do
        if tk.startQN < 10 then util.add(placed, tk) end
      end
      table.sort(placed, function(a, b) return a.startQN < b.startQN end)
      t.eq(#placed, 2, 'the second drop placed rather than replacing')
      t.eq(placed[1].slotIdx, 1, 'the first drop did replace — slot 1 holds QN 0')
      t.eq(placed[2].startQN, 1, 'and the second landed on the cursor row')
    end,
  },

  {
    name = 'a cursor move disarms replace mode',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.cm:set('project', 'arrangeAdvanceBy', 0)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 10, len = 3, srcLen = 3, poolGuid = '{p1}' })
      h.reaper:addItem('tr1', { take = 'tr1/t2', isMidi = true,
                                pos = 20, len = 2, srcLen = 2, poolGuid = '{p2}' })
      h.reaper:setProjectTracks{ 'tr1' }
      newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      h.cmgr:push('arrange')
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      am:tracksTakes(0)
      h.cmgr:invoke('drop0')
      h.cmgr:invoke('arrangeReplaceMode')
      h.cmgr:invoke('arrangeCursorDown')   -- bails the mode
      h.cmgr:invoke('drop1')
      local starts = {}
      for _, tk in ipairs(am:tracksTakes(0)) do
        if tk.startQN < 10 then util.add(starts, tk.startQN) end
      end
      table.sort(starts)
      t.eq(#starts, 2, 'the drop placed at the cursor and left the take at QN 0 standing')
      t.eq(starts[2], 1, 'on the row the cursor had moved to')
    end,
  },

  {
    name = 'a second arrangeReplaceMode disarms — the mode is a toggle',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.cm:set('project', 'arrangeAdvanceBy', 0)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 10, len = 3, srcLen = 3, poolGuid = '{p1}' })
      h.reaper:addItem('tr1', { take = 'tr1/t2', isMidi = true,
                                pos = 20, len = 2, srcLen = 2, poolGuid = '{p2}' })
      h.reaper:setProjectTracks{ 'tr1' }
      newArrangePage(h.cm, h.ds, h.cmgr, nil, {})
      h.cmgr:push('arrange')
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      am:tracksTakes(0)
      h.cmgr:invoke('drop0')
      h.cmgr:invoke('arrangeCursorDown')
      h.cmgr:invoke('arrangeReplaceMode')
      h.cmgr:invoke('arrangeReplaceMode')
      h.cmgr:invoke('drop1')
      local starts = {}
      for _, tk in ipairs(am:tracksTakes(0)) do
        if tk.startQN < 10 then util.add(starts, tk.startQN) end
      end
      table.sort(starts)
      t.eq(#starts, 2, 'the drop placed rather than replacing')
      t.eq(starts[2], 1, 'at the cursor row')
    end,
  },

}
