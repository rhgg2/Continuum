-- Pin-tests for trackerPage's Page interface (bind / unbind / focusState /
-- bind-from-cursor) and the retune modal's slots, defaults and dispatch.
-- render / handleInput are stubs wired in step 3 and verified in REAPER, not here.

-- trackerPage requires ImGui at module scope; stub via package.preload before
-- the first require so the module loads cleanly in the pure-Lua harness.

local t = require('support')

local n = 0
local fakeImGui = setmetatable({ Mod_None = 0,
  PushFont = function() end, PopFont = function() end,
  PushStyleColor = function() end, PopStyleColor = function() end }, {
  __index = function(tbl, k) n = n + 1; rawset(tbl, k, n); return n end,
})
package.preload['imgui'] = function()
  return function(_) return fakeImGui end
end
-- Earlier specs (patternEditor_*) rebind imgui to their own auto-viv fake (PushFont
-- resolves to a number); drop that cache + imgui-capturing modules so our preload rebinds.
for _, m in ipairs({ 'imgui', 'keyDispatch', 'pageBindings', 'gridPane', 'curveEditor', 'painter' }) do
  package.loaded[m] = nil
end
_G.reaper.ImGui_GetBuiltinPath = function() return '/stub' end

local util   = require('util')
local tuning = require('tuning')

-- Twelve-note quarter-comma meantone MOS: a step's seat carries a detune of
-- its own, so a snap is visible in the cell.
local MEAN = tuning.derive{
  name = 'MEAN', periodPitch = '2/1',
  pitches = { '0.0000', '76.0490', '193.1569', '310.2647', '386.3137', '503.4216',
              '579.4706', '696.5784', '772.6274', '889.7353', '1006.8431', '1082.8921' },
  stepNames = {},
}

-- The 5-limit tonality diamond at odd limit 15: a target whose points leave the
-- tritone of a 12-EDO notation nowhere to go.
local FIVES = tuning.derive(tuning.genDiamond(15, 5))

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

-- tv resolves its (track, slot) selection to a take via this facade.
-- The fake models a settable track/slot world; new-take/dup mint a parked slot via mintParkedTake.
local fakeArrange = {}
local function resetArrange()
  fakeArrange.calls      = {}
  fakeArrange.tracksList = { { idx = 0, guid = '{g0}', name = 'tr1' } }
  fakeArrange.slotsByIdx = { [0] = { { idx = 0, name = '', kind = 'midi' } } }
  fakeArrange.takeByKey  = {}                      -- ['idx:slot'] = take handle
  fakeArrange.tracks          = function() return fakeArrange.tracksList end
  fakeArrange.currentTrackIdx = function() return 0 end
  fakeArrange.trackIdxForGuid = function(g)
    for _, tr in ipairs(fakeArrange.tracksList) do if tr.guid == g then return tr.idx end end
  end
  fakeArrange.trackHandle = function(idx) return fakeArrange.tracksList[idx + 1].name end
  fakeArrange.midiSlots   = function(idx) return fakeArrange.slotsByIdx[idx] or {} end
  fakeArrange.takeForSlot = function(idx, slot) return fakeArrange.takeByKey[idx .. ':' .. slot] end
  fakeArrange.keyForSlot  = function() return '' end
  fakeArrange.nextFreeSlot   = function() return 7 end
  fakeArrange.isParkedTake   = function(take) return take == 'parked7' end
  fakeArrange.ownerTrack     = function(take) return take end
  fakeArrange.mintParkedTake = function(trackIdx, name, beats, src)
    fakeArrange.calls.mint = { trackIdx = trackIdx, name = name, beats = beats, src = src }
    return 7, 'parked7'                            -- the new parked slot, its take on scratch
  end

  -- The placement world tv resolves its current instance against: one record per
  -- instance, and a seek modelling am:seekInstance's contract (am_spec pins the real one).
  fakeArrange.instances = {}     -- { take, trackIdx, slotIdx, startQN, originQN?, lengthQN }
  -- am always carries the source origin; a record that says nothing about a
  -- head reads as an untrimmed instance, whose origin is its start.
  local function instances()
    for _, inst in ipairs(fakeArrange.instances) do inst.originQN = inst.originQN or inst.startQN end
    return fakeArrange.instances
  end
  fakeArrange.playQN    = nil
  fakeArrange.cursorQN  = 0
  fakeArrange.findTake = function(take)
    for _, inst in ipairs(instances()) do
      if inst.take == take then return inst end
    end
  end
  -- The slot a take sits in, live or parked — am scans the slot dicts by take id.
  fakeArrange.slotOfTake = function(take)
    for key, tk in pairs(fakeArrange.takeByKey) do
      if tk == take then
        local trackIdx, slotIdx = key:match('^(%d+):(%d+)$')
        return tonumber(trackIdx), tonumber(slotIdx)
      end
    end
  end
  fakeArrange.renameSlot = function(trackIdx, slotIdx, name)
    fakeArrange.calls.rename = { trackIdx = trackIdx, slotIdx = slotIdx, name = name }
  end
  fakeArrange.deleteSlot = function(trackIdx, slotIdx)
    fakeArrange.calls.deleteSlot = { trackIdx = trackIdx, slotIdx = slotIdx }
  end
  fakeArrange.playPositionQN = function() return fakeArrange.playQN   end
  fakeArrange.editCursorQN   = function() return fakeArrange.cursorQN end
  fakeArrange.playFromQN     = function(qn) fakeArrange.calls.playFrom = qn end
  fakeArrange.loopTo         = function(lo, hi) fakeArrange.calls.loopTo = { lo, hi } end
  fakeArrange.setCursorAt    = function(trackIdx, qn)
    fakeArrange.calls.setCursorAt = { trackIdx, qn }
  end
  fakeArrange.seekInstance = function(take, qn, back)
    local from = fakeArrange.findTake(take); if not from then return end
    local ahead, behind
    for _, inst in ipairs(instances()) do
      if inst.trackIdx == from.trackIdx and inst.slotIdx == from.slotIdx then
        if qn >= inst.startQN and qn < inst.startQN + inst.lengthQN then return inst, true end
        if inst.startQN > qn then
          if not ahead  or inst.startQN < ahead.startQN  then ahead  = inst end
        else
          if not behind or inst.startQN > behind.startQN then behind = inst end
        end
      end
    end
    local first, second = ahead, behind
    if back then first, second = behind, ahead end
    local found = first or second
    if found then return found, false end
  end
end
local fakeWiring = { samplerReachable = function() return false end }
local fakeFacade                        -- named inside its own publish, so declared first
fakeFacade = {
  published = {},
  publish = function(name, tbl) fakeFacade.published[name] = tbl end,
  publishDebug = function() end,
  get = function(name)
    if name == 'arrange' then return fakeArrange end
    if name == 'wiring'  then return fakeWiring  end
    return {}
  end,
}

-- A bind re-keys cm's track tier off the take's own item, so a take named in
-- fakeArrange needs one in the fake project too.
local function seedItems(h, takes, srcLen)
  for i, take in ipairs(takes) do
    h.reaper:addItem('tr1', { take = take, isMidi = true, srcLen = srcLen,
                              pos = i - 1, len = 1, poolGuid = '{p' .. i .. '}' })
  end
end

local function newTrackerPage(cm, ds, cmgr, chrome, gui)
  fakeModalHost:reset()
  resetArrange()
  local help = util.instantiate('help', { ctx = gui and gui.ctx, chrome = chrome, cmgr = cmgr })
  local lib  = util.instantiate('library',
    { cm = cm, synthetic = { swings = { identity = true }, tempers = { ['12EDO'] = true } } })
  return util.instantiate('trackerPage',
    { cm = cm, ds = ds, cmgr = cmgr, chrome = chrome, gui = gui, lib = lib,
      modalHost = fakeModalHost, help = help, facade = fakeFacade })
end

return {
  {
    name = "bind(take) drives cm:setContext via the page's own tm:bindTake",
    run = function(harness)
      local h  = harness.mk()
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
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
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
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
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      local fs = tp:focusState()
      t.eq(fs.suppressKbd, false, "no suppression without a context")
      t.eq(fs.acceptCmds,  false, "no acceptance without a context")
    end,
  },

  -- The tracker owns its (track, slot) selection in cm (decoupled from the arrange cursor); nav
  -- writes that selection via tv. New take grows from the current instance; dup mints parked.
  {
    name = 'bindFromSelection binds tm to the resolved selection take, drops when the track has no slots',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 1, poolGuid = '{p1}' })
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeArrange.takeByKey['0:0'] = 'tr1/t1'
      tp:bindFromSelection()                       -- seeds track 0 / slot 0 from the cursor
      t.eq(tp:currentTake(), 'tr1/t1', 'bound to the resolved selection take')
      fakeArrange.slotsByIdx[0] = {}               -- the slot vanished, none left
      tp:bindFromSelection()
      t.eq(tp:currentTake(), nil, 'dropped when the track has no slots')
    end,
  },

  {
    name = 'with no live instance, the new take mints a parked slot and selects it',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 1, poolGuid = '{p1}' })
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeArrange.takeByKey['0:0'] = 'tr1/t1'
      tp:bindFromSelection()                       -- seed track 0 / slot 0, bind the take
      h.cmgr:push('tracker')

      h.cmgr:invoke('newTakeBelow')                -- opens the name+length modal
      fakeModalHost.last.callback('07', '4')       -- commit the modal
      t.eq(fakeArrange.calls.mint.name,  '07', 'minted with the modal name')
      t.eq(fakeArrange.calls.mint.beats, 4,    'and the modal length')
      t.eq(fakeArrange.calls.mint.src,   nil,  'new take has no clone source')
      t.eq(h.cm:getAt('track', 'trackerSlot'), 7, 'tracker selected the new parked slot')
    end,
  },

  -- Ctrl+Delete forever-deletes the bound slot; the same gesture and the same
  -- confirm as the arrange page's.
  {
    name = 'deleteBoundSlot confirms, then deletes the bound slot through the arrange facade',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 1, poolGuid = '{p1}' })
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeArrange.takeByKey['0:0'] = 'tr1/t1'
      tp:bindFromSelection()                       -- seed track 0 / slot 0, bind the take
      h.cmgr:push('tracker')

      h.cmgr:invoke('deleteBoundSlot')
      t.truthy(fakeModalHost.last, 'confirm opened before anything is destroyed')
      t.eq(fakeArrange.calls.deleteSlot, nil, 'nothing deleted while the confirm stands')
      fakeModalHost.last.callback(false)
      t.eq(fakeArrange.calls.deleteSlot, nil, 'declined — still nothing deleted')

      h.cmgr:invoke('deleteBoundSlot')
      fakeModalHost.last.callback(true)
      t.eq(fakeArrange.calls.deleteSlot.trackIdx, 0, 'deleted on the bound track')
      t.eq(fakeArrange.calls.deleteSlot.slotIdx,  0, 'and the bound slot')
    end,
  },

  -- The name field names the slot, so every instance follows it.
  -- see docs/arrangeManager.md § Renaming and name drift
  {
    name = 'take properties renames the bound take\'s slot, not that one take',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 1, poolGuid = '{p1}' })
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeArrange.takeByKey['0:0'] = 'tr1/t1'
      tp:bindFromSelection()                       -- seed track 0 / slot 0, bind the take
      h.cmgr:push('tracker')

      h.cmgr:invoke('takeProperties')
      local beats = tonumber(fakeModalHost.last.beatsBuf)
      fakeModalHost.last.callback('Kenneth', beats, 'resize')
      local renamed = fakeArrange.calls.rename
      t.eq(renamed.name,     'Kenneth', 'the slot took the submitted name')
      t.eq(renamed.trackIdx, 0,         'on the track the take is on')
      t.eq(renamed.slotIdx,  0,         'and the slot it is in')
    end,
  },

  -- Arrange opens this modal on the take under its own cursor, binding tm off the
  -- tracker's selection. Name and length both read the bound take, so the rename
  -- follows it too. see docs/trackerPage.md § Selection
  {
    name = 'take properties follows the bound take when the tracker sits on another slot',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      seedItems(h, { 'tr1/t1', 'tr1/t2' })
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      util.add(fakeArrange.slotsByIdx[0], { idx = 7, name = '', kind = 'midi' })
      fakeArrange.takeByKey['0:0'] = 'tr1/t1'
      fakeArrange.takeByKey['0:7'] = 'tr1/t2'
      tp:bindFromSelection()                       -- tracker selection: track 0 / slot 0
      h.cmgr:push('tracker')

      tp:bind('tr1/t2')                            -- arrange's route: bind away from the selection
      h.cmgr:invoke('takeProperties')
      fakeModalHost.last.callback('Kenneth', tonumber(fakeModalHost.last.beatsBuf), 'resize')
      local renamed = fakeArrange.calls.rename
      t.eq(renamed.name,    'Kenneth', 'the submitted name landed')
      t.eq(renamed.slotIdx, 7,         "on the bound take's slot, not the tracker's")
    end,
  },

  -- The tracker grows the arrangement from the placement it is in.
  -- see docs/trackerPage.md § New take
  {
    name = 'the new take places below the current instance and becomes current',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      seedItems(h, { 'i0', 'n7' })
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeArrange.takeByKey['0:0'] = 'i0'
      fakeArrange.instances = {
        { take = 'i0', trackIdx = 0, slotIdx = 0, startQN = 0, lengthQN = 4 },
      }
      -- Placing: the slot joins the palette and its take joins the placements, at the append point.
      fakeArrange.newTakeBelow = function(inst, name, beats)
        fakeArrange.calls.below = { take = inst.take, name = name, beats = beats }
        util.add(fakeArrange.slotsByIdx[0], { idx = 7, name = name, kind = 'midi' })
        fakeArrange.takeByKey['0:7'] = 'n7'
        util.add(fakeArrange.instances,
                 { take = 'n7', trackIdx = 0, slotIdx = 7, startQN = 4, lengthQN = 4 })
        return 7, 'n7'
      end
      h.cmgr:push('tracker')
      tp:bindFromSelection()                       -- seed track 0 / slot 0, bind i0

      h.cmgr:invoke('newTakeBelow')                -- opens the name+length modal
      fakeModalHost.last.callback('07', '4')       -- commit the modal
      t.eq(fakeArrange.calls.below.take,  'i0', 'appended below the current instance')
      t.eq(fakeArrange.calls.below.name,  '07', 'with the modal name')
      t.eq(fakeArrange.calls.below.beats, 4,    'and the modal length')
      t.eq(fakeArrange.calls.mint, nil, 'nothing parked — there was room')
      t.eq(h.cm:getAt('track', 'trackerSlot'), 7, 'tracker selected the new slot')

      tp:bindFromSelection()
      h.cmgr:invoke('playFromTop')
      t.eq(fakeArrange.calls.playFrom, 4, 'the placed take is now the current instance')
    end,
  },

  {
    name = 'a new take on a just-selected track parks, rather than appending on the old one',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1', 'tr2' }
      seedItems(h, { 'i0' })
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeArrange.tracksList = {
        { idx = 0, guid = '{g0}', name = 'tr1' },
        { idx = 1, guid = '{g1}', name = 'tr2' },
      }
      fakeArrange.slotsByIdx = { [0] = { { idx = 0, kind = 'midi' } }, [1] = {} }
      fakeArrange.takeByKey['0:0'] = 'i0'
      fakeArrange.instances = {
        { take = 'i0', trackIdx = 0, slotIdx = 0, startQN = 0, lengthQN = 4 },
      }
      fakeArrange.newTakeBelow = function(inst) fakeArrange.calls.below = { take = inst.take } end
      tp:bindFromSelection()                       -- the tracker is inside i0, on track 0

      -- Wiring's entry: select the new track and make its first take there, both
      -- before the next resolve can catch the current instance up with the selection.
      local slot = fakeFacade.published.tracker.selectNewTake('{g1}')
      t.eq(fakeArrange.calls.below, nil, 'no append onto the instance the tracker just left')
      t.eq(slot, 7, 'the take was minted parked instead')
      t.eq(fakeArrange.calls.mint.trackIdx, 1, 'on the track just selected')
    end,
  },

  -- Duplicate below: another placement of the slot already bound, at the append point.
  -- see docs/trackerPage.md § Duplicate below
  {
    name = 'duplicate below appends another instance of the bound slot and makes it current',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      seedItems(h, { 'i0', 'i4' })
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeArrange.takeByKey['0:0'] = 'i0'
      fakeArrange.instances = {
        { take = 'i0', trackIdx = 0, slotIdx = 0, startQN = 0, lengthQN = 4 },
      }
      -- The pooled clone joins the placements of the same slot; the palette is untouched.
      fakeArrange.duplicateBelow = function(inst)
        fakeArrange.calls.dup = { take = inst.take }
        util.add(fakeArrange.instances,
                 { take = 'i4', trackIdx = 0, slotIdx = 0, startQN = 4, lengthQN = 4 })
        return 'i4'
      end
      h.cmgr:push('tracker')
      tp:bindFromSelection()                       -- seed track 0 / slot 0, bind i0
      h.cm:set('global', 'trackerLoopToItem', true)

      h.cmgr:invoke('duplicateBelow')
      t.eq(fakeArrange.calls.dup.take, 'i0', 'duplicated the instance the tracker is in')
      t.eq(fakeArrange.calls.mint, nil, 'nothing joined the palette')
      t.eq(h.cm:getAt('track', 'trackerSlot'), 0, 'and the bound slot is the one it was')

      tp:bindFromSelection()                       -- the next frame's resolve
      t.deepEq(fakeArrange.calls.loopTo, { 4, 8 }, 'the loop moved onto the copy')
      h.cmgr:invoke('playFromTop')
      t.eq(fakeArrange.calls.playFrom, 4, 'which is now the current instance')
    end,
  },

  {
    name = 'duplicate below refuses where the free span falls short',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      seedItems(h, { 'i0' })
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeArrange.takeByKey['0:0'] = 'i0'
      fakeArrange.instances = {
        { take = 'i0', trackIdx = 0, slotIdx = 0, startQN = 0, lengthQN = 4 },
      }
      fakeArrange.duplicateBelow = function() fakeArrange.calls.dup = true end   -- no room
      h.cmgr:push('tracker')
      tp:bindFromSelection()
      h.cm:set('global', 'trackerLoopToItem', true)

      h.cmgr:invoke('duplicateBelow')
      tp:bindFromSelection()
      t.eq(fakeArrange.calls.dup, true, 'the verb ran')
      t.falsy(fakeArrange.calls.loopTo, 'and the refusal left the loop where it was')
      h.cmgr:invoke('playFromTop')
      t.eq(fakeArrange.calls.playFrom, 0, 'the tracker still in the instance it was in')
    end,
  },

  {
    name = 'duplicate below on a slot whose only take is parked does nothing',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      seedItems(h, { 'parked' })
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeArrange.takeByKey['0:0'] = 'parked'       -- bound, but on no placement
      fakeArrange.duplicateBelow = function() fakeArrange.calls.dup = true end
      h.cmgr:push('tracker')
      tp:bindFromSelection()

      h.cmgr:invoke('duplicateBelow')
      t.falsy(fakeArrange.calls.dup, 'no instance to append to, so nothing was placed')
    end,
  },

  -- stepVariant: the current instance moved along its family, varying past the last.
  -- see docs/trackerPage.md § Stepping the family
  {
    name = 'the variant step rebinds the tracker to the slot stepped to and follows its placement',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      seedItems(h, { 'i0', 'v0' })
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeArrange.slotsByIdx[0] = { { idx = 0, name = 'Bassline', kind = 'midi' } }
      fakeArrange.takeByKey['0:0'] = 'i0'
      fakeArrange.instances = {
        { take = 'i0', trackIdx = 0, slotIdx = 0, startQN = 4, lengthQN = 4 },
      }
      -- am:stepVariant drops the neighbour in the instance's place; past the last of
      -- the family that is a fresh variant slot (am_spec pins the real one).
      fakeArrange.stepVariant = function(inst, dir)
        fakeArrange.calls.stepVariant = { take = inst.take, dir = dir }
        fakeArrange.instances = {
          { take = 'v0', trackIdx = 0, slotIdx = 9, startQN = 4, lengthQN = 4 },
        }
        util.add(fakeArrange.slotsByIdx[0], { idx = 9, name = 'Bassline (var 1)', kind = 'midi' })
        fakeArrange.takeByKey['0:9'] = 'v0'
        return 9, 'v0'
      end
      h.cmgr:push('tracker')
      tp:bindFromSelection()                       -- seed track 0 / slot 0, bind i0
      h.cm:set('global', 'trackerLoopToItem', true)

      h.cmgr:invoke('nextVariant')
      t.eq(fakeArrange.calls.stepVariant.take, 'i0', 'stepped the instance the tracker is in')
      t.eq(fakeArrange.calls.stepVariant.dir, 1, 'forward along the family')
      t.eq(h.cm:getAt('track', 'trackerSlot'), 9, 'and selected the slot it landed on')

      tp:bindFromSelection()                       -- the next frame's resolve
      t.eq(tp:currentTake(), 'v0', 'the tracker rebound onto the variant')
      t.deepEq(fakeArrange.calls.loopTo, { 4, 8 }, 'the loop moved onto its placement')
    end,
  },

  {
    name = 'a variant step with the tracker in no instance does nothing',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      seedItems(h, { 'parked' })
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeArrange.takeByKey['0:0'] = 'parked'       -- bound, but on no placement
      fakeArrange.stepVariant = function() fakeArrange.calls.stepVariant = true end
      h.cmgr:push('tracker')
      tp:bindFromSelection()

      h.cmgr:invoke('nextVariant')
      h.cmgr:invoke('prevVariant')
      t.falsy(fakeArrange.calls.stepVariant, 'no instance to step from, in either direction')
    end,
  },

  {
    name = 'prev/next track + take drive the tv selection, not the arrange cursor',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1', 'tr2' }
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeArrange.tracksList = {
        { idx = 0, guid = '{g0}', name = 'tr1' },
        { idx = 1, guid = '{g1}', name = 'tr2' },
      }
      fakeArrange.slotsByIdx = {
        [0] = { { idx = 0, kind = 'midi' }, { idx = 1, kind = 'midi' } },
        [1] = { { idx = 0, kind = 'midi' } },
      }
      h.cmgr:push('tracker')
      tp:bindFromSelection()                 -- seed the selection on track 0
      h.cmgr:invoke('nextTrack')
      t.eq(h.cm:getAt('project', 'trackerTrack'), '{g1}', 'nextTrack moved the selection to track 2')
      h.cmgr:invoke('prevTrack')
      t.eq(h.cm:getAt('project', 'trackerTrack'), '{g0}', 'prevTrack moved it back to track 1')
      h.cmgr:invoke('nextTake')
      t.eq(h.cm:getAt('track', 'trackerSlot'), 1, 'nextTake stepped to the next slot')
      h.cmgr:invoke('prevTake')
      t.eq(h.cm:getAt('track', 'trackerSlot'), 0, 'prevTake stepped back')
    end,
  },

  -- The current instance: which placement of the bound slot the tracker is in.
  -- see docs/trackerPage.md § The current instance.
  -- Each instance take needs a real item, or binding it unbinds cm's track tier.
  {
    name = 'F6 plays from the instance dived into, not the placement the bind resolved',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      seedItems(h, { 'i0', 'i8' })
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeArrange.takeByKey['0:0'] = 'i0'          -- the bind resolves the first instance
      fakeArrange.instances = {
        { take = 'i0', trackIdx = 0, slotIdx = 0, startQN = 0, lengthQN = 4 },
        { take = 'i8', trackIdx = 0, slotIdx = 0, startQN = 8, lengthQN = 4 },
      }
      h.cmgr:push('tracker')
      tp:bindFromSelection()
      fakeFacade.published.tracker.diveTo('{g0}', 0, 'i8')
      tp:bindFromSelection()
      h.cmgr:invoke('playFromTop')
      t.eq(fakeArrange.calls.playFrom, 8, 'F6 played from the dived-into instance')
    end,
  },

  {
    name = 'a dive outranks a play head already sitting in another instance',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      local stack
      local origPublishDebug = fakeFacade.publishDebug
      fakeFacade.publishDebug = function(_, s) stack = s end
      seedItems(h, { 'i0', 'i8' })
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeFacade.publishDebug = origPublishDebug
      fakeArrange.takeByKey['0:0'] = 'i0'
      fakeArrange.instances = {
        { take = 'i0', trackIdx = 0, slotIdx = 0, startQN = 0, lengthQN = 4 },
        { take = 'i8', trackIdx = 0, slotIdx = 0, startQN = 8, lengthQN = 4 },
      }
      fakeArrange.playQN = 1                       -- the play head sits inside i0
      tp:bindFromSelection()
      t.eq(stack.tv:currentInstance().take, 'i0', 'entering i0 made it current')
      fakeFacade.published.tracker.diveTo('{g0}', 0, 'i8')
      tp:bindFromSelection()
      t.eq(stack.tv:currentInstance().take, 'i8', 'the dive named i8 over the sounding i0')
      tp:bindFromSelection()
      t.eq(stack.tv:currentInstance().take, 'i8', 'a stationary play head does not reclaim it')
    end,
  },

  {
    name = 'the play head entering an instance makes it current; leaving one writes nothing',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      local stack
      local origPublishDebug = fakeFacade.publishDebug
      fakeFacade.publishDebug = function(_, s) stack = s end
      seedItems(h, { 'i0', 'i8' })
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeFacade.publishDebug = origPublishDebug
      fakeArrange.takeByKey['0:0'] = 'i0'
      fakeArrange.instances = {
        { take = 'i0', trackIdx = 0, slotIdx = 0, startQN = 0, lengthQN = 4 },
        { take = 'i8', trackIdx = 0, slotIdx = 0, startQN = 8, lengthQN = 4 },
      }
      tp:bindFromSelection()
      t.eq(stack.tv:currentInstance().take, 'i0', 'the seed seek from the edit cursor found i0')
      fakeArrange.playQN = 9
      tp:bindFromSelection()
      t.eq(stack.tv:currentInstance().take, 'i8', 'the play head entered i8')
      fakeArrange.playQN = 20                      -- off the end, into no instance
      tp:bindFromSelection()
      t.eq(stack.tv:currentInstance().take, 'i8', 'leaving leaves the tracker where it was')
    end,
  },

  {
    name = 'a slot change seeks from the outgoing instance, backwards for prevTake',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      local stack
      local origPublishDebug = fakeFacade.publishDebug
      fakeFacade.publishDebug = function(_, s) stack = s end
      seedItems(h, { 'a0', 'a8', 'a16', 'b4', 'b12' })
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeFacade.publishDebug = origPublishDebug
      fakeArrange.slotsByIdx[0] = { { idx = 0, kind = 'midi' }, { idx = 1, kind = 'midi' } }
      fakeArrange.takeByKey['0:0'] = 'a0'
      fakeArrange.takeByKey['0:1'] = 'b4'
      fakeArrange.instances = {
        { take = 'a0',  trackIdx = 0, slotIdx = 0, startQN = 0,  lengthQN = 4 },
        { take = 'a8',  trackIdx = 0, slotIdx = 0, startQN = 8,  lengthQN = 4 },
        { take = 'a16', trackIdx = 0, slotIdx = 0, startQN = 16, lengthQN = 4 },
        { take = 'b4',  trackIdx = 0, slotIdx = 1, startQN = 4,  lengthQN = 4 },
        { take = 'b12', trackIdx = 0, slotIdx = 1, startQN = 12, lengthQN = 4 },
      }
      h.cmgr:push('tracker')
      tp:bindFromSelection()
      fakeFacade.published.tracker.diveTo('{g0}', 0, 'a8')
      tp:bindFromSelection()
      t.eq(stack.tv:currentInstance().take, 'a8', 'dived into the later instance of slot 0')

      h.cmgr:invoke('nextTake')
      tp:bindFromSelection()
      t.eq(stack.tv:currentInstance().take, 'b12',
           'forwards from QN 8 passes b4, which ends there, and reaches b12')

      h.cmgr:invoke('prevTake')
      tp:bindFromSelection()
      t.eq(stack.tv:currentInstance().take, 'a8',
           'prevTake seeks backwards from QN 12, passing over a16 ahead of it')
    end,
  },

  {
    name = 'a slot with no live instance leaves the tracker nowhere, and F6 silent',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      local stack
      local origPublishDebug = fakeFacade.publishDebug
      fakeFacade.publishDebug = function(_, s) stack = s end
      seedItems(h, { 'parked' })
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeFacade.publishDebug = origPublishDebug
      fakeArrange.takeByKey['0:0'] = 'parked'       -- bound, but on no placement
      h.cmgr:push('tracker')
      tp:bindFromSelection()
      t.falsy(stack.tv:currentInstance(), 'a parked slot puts the tracker in no instance')
      h.cmgr:invoke('playFromTop')
      t.falsy(fakeArrange.calls.playFrom, 'F6 has nowhere to play from')
    end,
  },

  -- The play row: a caret on the row the play head occupies, dimmed where the
  -- head is sounding a sibling instance. At 240 ppq and four rows to the beat,
  -- a row is a quarter of a QN.
  {
    name = 'the play row is the head\'s offset into the current instance, in rows',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      local stack
      local origPublishDebug = fakeFacade.publishDebug
      fakeFacade.publishDebug = function(_, s) stack = s end
      seedItems(h, { 'i0', 'i8' })
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeFacade.publishDebug = origPublishDebug
      fakeArrange.takeByKey['0:0'] = 'i0'
      fakeArrange.instances = {
        { take = 'i0', trackIdx = 0, slotIdx = 0, startQN = 0, lengthQN = 4 },
        { take = 'i8', trackIdx = 0, slotIdx = 0, startQN = 8, lengthQN = 4 },
      }
      tp:bindFromSelection()
      t.falsy(stack.tv:playRow(), 'a stopped transport lights no row')

      fakeArrange.playQN = 1.5                     -- an eighth of the way into i0
      tp:bindFromSelection()
      local row, elsewhere = stack.tv:playRow()
      t.eq(row, 6, 'six rows into the instance the head is inside')
      t.falsy(elsewhere, 'which is the instance the tracker is in')

      fakeArrange.playQN = 20                      -- past every instance of the slot
      tp:bindFromSelection()
      t.falsy(stack.tv:playRow(), 'a head in no instance of the slot lights no row')
    end,
  },

  {
    name = 'the play row dims where the head is sounding a sibling instance',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      local stack
      local origPublishDebug = fakeFacade.publishDebug
      fakeFacade.publishDebug = function(_, s) stack = s end
      seedItems(h, { 'i0', 'i8' })
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeFacade.publishDebug = origPublishDebug
      fakeArrange.takeByKey['0:0'] = 'i0'
      fakeArrange.instances = {
        { take = 'i0', trackIdx = 0, slotIdx = 0, startQN = 0, lengthQN = 4 },
        { take = 'i8', trackIdx = 0, slotIdx = 0, startQN = 8, lengthQN = 4 },
      }
      fakeArrange.playQN = 1.5                     -- the head sounds i0
      tp:bindFromSelection()
      fakeFacade.published.tracker.diveTo('{g0}', 0, 'i8')
      tp:bindFromSelection()
      t.eq(stack.tv:currentInstance().take, 'i8', 'the dive pinned the tracker to i8')

      local row, elsewhere = stack.tv:playRow()
      t.eq(row, 6, 'the row the head occupies in the instance it is inside')
      t.truthy(elsewhere, 'dimmed: the placement sounding is not the placement bound')
    end,
  },

  -- The cut: a sixteen-beat source with a neighbour eight beats below renders
  -- half of itself, so the grid's second half is drawn but never heard. Four
  -- rows to the beat puts the line at row 32 of 64.
  {
    name = 'the cut row is where the rendered span stops short of the source',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      local stack
      local origPublishDebug = fakeFacade.publishDebug
      fakeFacade.publishDebug = function(_, s) stack = s end
      seedItems(h, { 'i0', 'i8' }, 16)
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeFacade.publishDebug = origPublishDebug
      fakeArrange.takeByKey['0:0'] = 'i0'
      fakeArrange.instances = {
        { take = 'i0', trackIdx = 0, slotIdx = 0, startQN = 0, lengthQN = 8 },
        { take = 'i8', trackIdx = 0, slotIdx = 0, startQN = 8, lengthQN = 8 },
      }
      tp:bindFromSelection()
      t.eq(stack.tv.grid.numRows, 64, 'the grid draws the whole source')
      t.eq(stack.tv:cutRow(), 32, 'the neighbour cuts the render at eight beats')

      fakeArrange.instances[1].lengthQN = 16          -- the neighbour moved away
      t.falsy(stack.tv:cutRow(), 'a fully rendered span cuts nothing')
    end,
  },

  -- A head trimmed on the arrange page skips the source's first rows: the grid
  -- still draws them, and the window the instance plays starts below them.
  {
    name = 'the play row and the head row count from the source origin, not the start',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      local stack
      local origPublishDebug = fakeFacade.publishDebug
      fakeFacade.publishDebug = function(_, s) stack = s end
      seedItems(h, { 'i0', 'i8' }, 16)
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeFacade.publishDebug = origPublishDebug
      fakeArrange.takeByKey['0:0'] = 'i0'
      -- i0 starts at 8 having skipped its first two beats, so it renders
      -- source beats 2..10 — rows 8..40 of a sixty-four row grid.
      fakeArrange.instances = {
        { take = 'i0', trackIdx = 0, slotIdx = 0, startQN = 8, originQN = 6, lengthQN = 8 },
      }
      fakeArrange.playQN = 8
      tp:bindFromSelection()
      t.eq(stack.tv:playRow(), 8, 'the head enters the grid eight rows down, where the window opens')
      t.eq(stack.tv:headRow(), 8, 'the head row marks the same place')
      t.eq(stack.tv:cutRow(),  40, 'and the cut sits a window below it')

      fakeArrange.instances[1].originQN = 8         -- the head handed back
      t.falsy(stack.tv:headRow(), 'an untrimmed instance marks no head')
    end,
  },

  -- Dive and return (docs/trackerPage.md § The caret across the dive). One
  -- instance, head-trimmed: it starts at 8 having skipped two beats of source,
  -- so it renders source beats 2..10 — rows 8..39 of a sixty-four row grid.
  {
    name = 'a dive carries the arrange QN to the caret row, and the caret hands it back',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      local stack
      local origPublishDebug = fakeFacade.publishDebug
      fakeFacade.publishDebug = function(_, s) stack = s end
      seedItems(h, { 'i0' }, 16)
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeFacade.publishDebug = origPublishDebug
      fakeArrange.takeByKey['0:0'] = 'i0'
      fakeArrange.instances = {
        { take = 'i0', trackIdx = 0, slotIdx = 0, startQN = 8, originQN = 6, lengthQN = 8 },
      }
      tp:bindFromSelection()
      fakeFacade.published.tracker.diveTo('{g0}', 0, 'i0', 10)
      tp:bindFromSelection()
      t.eq(stack.tv:ec():row(), 16, 'four beats past the origin, four rows to the beat')
      t.eq(stack.tv:cursorQN(), 10, 'and the caret hands the same QN back')
    end,
  },

  {
    name = 'a caret outside the rendered span hands back the row the span stops at',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      local stack
      local origPublishDebug = fakeFacade.publishDebug
      fakeFacade.publishDebug = function(_, s) stack = s end
      seedItems(h, { 'i0' }, 16)
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeFacade.publishDebug = origPublishDebug
      fakeArrange.takeByKey['0:0'] = 'i0'
      fakeArrange.instances = {
        { take = 'i0', trackIdx = 0, slotIdx = 0, startQN = 8, originQN = 6, lengthQN = 8 },
      }
      tp:bindFromSelection()
      stack.tv:ec():setPos(50)
      t.eq(stack.tv:cursorQN(), 15.75, 'below the cut: the last row the render reaches')
      stack.tv:ec():setPos(2)
      t.eq(stack.tv:cursorQN(), 8, 'above the head: the row the render opens on')
    end,
  },

  {
    name = 'leaving the tracker puts the arrange caret where the tracker caret is',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      local stack
      local origPublishDebug = fakeFacade.publishDebug
      fakeFacade.publishDebug = function(_, s) stack = s end
      seedItems(h, { 'i0' }, 16)
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeFacade.publishDebug = origPublishDebug
      fakeArrange.takeByKey['0:0'] = 'i0'
      tp:bindFromSelection()
      tp:unbind()
      t.falsy(fakeArrange.calls.setCursorAt, 'a take in no placement moves nothing')

      fakeArrange.instances = {
        { take = 'i0', trackIdx = 0, slotIdx = 0, startQN = 8, originQN = 6, lengthQN = 8 },
      }
      tp:bindFromSelection()
      stack.tv:ec():setPos(20)
      tp:unbind()
      t.deepEq(fakeArrange.calls.setCursorAt, { 0, 11 }, "the instance's track, the caret's QN")
    end,
  },

  -- Loop to item (docs/trackerPage.md § Loop to item): a gesture that moves the
  -- current instance brackets it; the play head entering one does not.
  {
    name = 'with loop to item on, a dive brackets the instance dived into',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      seedItems(h, { 'i0', 'i8' })
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeArrange.takeByKey['0:0'] = 'i0'
      fakeArrange.instances = {
        { take = 'i0', trackIdx = 0, slotIdx = 0, startQN = 0, lengthQN = 4 },
        { take = 'i8', trackIdx = 0, slotIdx = 0, startQN = 8, lengthQN = 4 },
      }
      tp:bindFromSelection()
      t.falsy(fakeArrange.calls.loopTo, 'the toggle is off, so the transport is left alone')

      h.cm:set('global', 'trackerLoopToItem', true)
      fakeFacade.published.tracker.diveTo('{g0}', 0, 'i8')
      tp:bindFromSelection()
      t.deepEq(fakeArrange.calls.loopTo, { 8, 12 }, 'the loop brackets the dived-into span')
    end,
  },

  {
    name = 'the play head entering an instance leaves the loop where it was',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      seedItems(h, { 'i0', 'i8' })
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      h.cm:set('global', 'trackerLoopToItem', true)
      fakeArrange.takeByKey['0:0'] = 'i0'
      fakeArrange.instances = {
        { take = 'i0', trackIdx = 0, slotIdx = 0, startQN = 0, lengthQN = 4 },
        { take = 'i8', trackIdx = 0, slotIdx = 0, startQN = 8, lengthQN = 4 },
      }
      tp:bindFromSelection()
      t.deepEq(fakeArrange.calls.loopTo, { 0, 4 }, 'the seeded instance was bracketed')
      fakeArrange.calls.loopTo = nil
      fakeArrange.playQN = 9
      tp:bindFromSelection()
      t.falsy(fakeArrange.calls.loopTo, 'playing into i8 does not move the loop onto it')
    end,
  },

  {
    name = 'the toggle command brackets the current instance as it comes on',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      seedItems(h, { 'i0', 'i8' })
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeArrange.takeByKey['0:0'] = 'i0'
      fakeArrange.instances = {
        { take = 'i0', trackIdx = 0, slotIdx = 0, startQN = 0, lengthQN = 4 },
        { take = 'i8', trackIdx = 0, slotIdx = 0, startQN = 8, lengthQN = 4 },
      }
      h.cmgr:push('tracker')
      tp:bindFromSelection()

      h.cmgr:invoke('toggleLoopToItem')
      t.truthy(h.cm:get('trackerLoopToItem'), 'the command turned the toggle on')
      t.deepEq(fakeArrange.calls.loopTo, { 0, 4 }, 'coming on brackets the current instance at once')

      fakeArrange.calls.loopTo = nil
      h.cmgr:invoke('toggleLoopToItem')
      t.falsy(h.cm:get('trackerLoopToItem'), 'invoking again turned it off')
      t.falsy(fakeArrange.calls.loopTo, 'going off leaves the loop where it was')
    end,
  },

  {
    name = 'the loop-to-item verb brackets the current instance, toggle or no toggle',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      seedItems(h, { 'i0', 'i8' })
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeArrange.takeByKey['0:0'] = 'i0'
      fakeArrange.instances = {
        { take = 'i0', trackIdx = 0, slotIdx = 0, startQN = 0, lengthQN = 4 },
        { take = 'i8', trackIdx = 0, slotIdx = 0, startQN = 8, lengthQN = 4 },
      }
      h.cmgr:push('tracker')
      tp:bindFromSelection()
      t.falsy(fakeArrange.calls.loopTo, 'the toggle is off, so binding left the transport alone')

      h.cmgr:invoke('loopToItemNow')
      t.deepEq(fakeArrange.calls.loopTo, { 0, 4 }, 'the verb brackets the current instance')
      t.falsy(h.cm:get('trackerLoopToItem'), 'and leaves the toggle where it was')

      fakeArrange.calls.loopTo = nil
      fakeArrange.takeByKey['0:0'] = 'parked'      -- bound, but on no placement
      tp:bindFromSelection()
      h.cmgr:invoke('loopToItemNow')
      t.falsy(fakeArrange.calls.loopTo, 'a parked slot gives the verb nothing to bracket')
    end,
  },

  -- The retune modal (design/adaptive-tuning.md § Where it sits): scope is a
  -- field on the modal, and OK calls the verb the radio names.
  {
    name = 'retune opens on the scope the selection implies and OK snaps that scope',
    run = function(harness)
      local h = harness.mk{ config = { project = { tempers = { MEAN = MEAN }, temper = 'MEAN' } } }
      h.reaper:setProjectTracks{ 'tr1' }
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 1, poolGuid = '{p1}' })
      h.reaper:seedMidi('tr1/t1', { notes = {
        { ppq = 0,   endppq = 60,  chan = 0, pitch = 76, vel = 100 },
        { ppq = 480, endppq = 540, chan = 0, pitch = 76, vel = 100 } } })
      local stack
      local origPublishDebug = fakeFacade.publishDebug
      fakeFacade.publishDebug = function(_, s) stack = s end
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeFacade.publishDebug = origPublishDebug
      fakeArrange.takeByKey['0:0'] = 'tr1/t1'
      tp:bindFromSelection()
      h.cmgr:push('tracker')

      local function notes()
        for _, col in ipairs(stack.tv.grid.cols) do
          if col.midiChan == 1 and col.type == 'note' and col.lane == 1 then return col.events end
        end
      end
      local _, seatDetune = tuning.stepToMidi(MEAN, 5, 5)

      h.cmgr:invoke('retune')
      t.eq(fakeModalHost.last.kind,  'retune', 'the retune modal opened')
      t.eq(fakeModalHost.last.scope, 'all',    'no selection opens on whole take')
      t.eq(fakeModalHost.last.strength, 1,     'the strength dial opens at full')
      t.eq(fakeModalHost.last.target, nil,     'no target is the default, which is the snap')
      t.eq(fakeModalHost.last.key, 1,          'the key opens on the first step of the notation')
      t.eq(fakeModalHost.last.sonoritySize, 5, 'sonority size opens at 5')
      t.eq(fakeModalHost.last.harmonicLock, 1, 'harmonic lock opens at 1')
      t.eq(fakeModalHost.last.purity, 32,      'purity opens at 32')

      stack.tv:ec():setSelection{ row1 = 0, row2 = 0, col1 = 1, col2 = 1,
                                  part1 = 'pitch', part2 = 'pitch' }
      h.cmgr:invoke('retune')
      t.eq(fakeModalHost.last.scope, 'selection', 'a selection opens on Selection')

      fakeModalHost.last.callback{ scope = 'selection', strength = 1 }
      local ns = notes()
      t.truthy(math.abs(ns[1].detune - seatDetune) < 1e-6, 'the selected note took the meantone seat')
      t.eq(ns[2].detune, 0, 'the note outside the selection is untouched')

      h.cmgr:invoke('retune')
      fakeModalHost.last.callback{ scope = 'all', strength = 1 }
      ns = notes()
      t.truthy(math.abs(ns[2].detune - seatDetune) < 1e-6, 'whole take snapped the rest')

      h.cm:set('take', 'retune.target', 'DIA')
      h.cm:set('take', 'retune.key', 20)          -- a step MEAN's twelve do not reach
      h.cmgr:invoke('retune')
      t.eq(fakeModalHost.last.target, 'DIA', 'the modal reopens on the target the take carries')
      t.eq(fakeModalHost.last.key, 12, 'a key past the notation clamps into it')
    end,
  },

  -- The facility is a slot of its own, nothing recovering the reading from the
  -- target object (docs/trackerView.md § Retune): it persists at
  -- take tier as the target and the key do, where the dials beside it do not
  -- (docs/sonority.md § The dials).
  {
    name = 'retune opens on the facility the take carries, its dials on their figures',
    run = function(harness)
      local h = harness.mk{ config = { project = { tempers = { MEAN = MEAN }, temper = 'MEAN' } } }
      h.reaper:setProjectTracks{ 'tr1' }
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 1, poolGuid = '{p1}' })
      h.reaper:seedMidi('tr1/t1', { notes = {
        { ppq = 0, endppq = 60, chan = 0, pitch = 76, vel = 100 } } })
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeArrange.takeByKey['0:0'] = 'tr1/t1'
      tp:bindFromSelection()
      h.cmgr:push('tracker')

      h.cmgr:invoke('retune')
      t.eq(fakeModalHost.last.facility, 'points', 'a take carrying no facility opens on points')
      t.eq(fakeModalHost.last.harmonicLock, 1, 'and harmonic lock on its figure')
      t.eq(fakeModalHost.last.purity, 32, 'purity on its own')

      h.cm:set('take', 'retune.facility', 'moves')
      h.cmgr:invoke('retune')
      t.eq(fakeModalHost.last.facility, 'moves', 'the modal reopens on the facility the take carries')
      t.eq(fakeModalHost.last.harmonicLock, 1, 'harmonic lock standing at 1 under either facility')
      t.eq(fakeModalHost.last.purity, 32, 'and purity at 32, which the moves facility alone reads')

      -- No target is a snap, which reads no facility at all -- the answer still
      -- rides back to the take, so the next open stands where this one did.
      h.cm:set('take', 'retune.facility', nil)
      fakeModalHost.last.callback{ scope = 'all', strength = 1, facility = 'moves' }
      t.eq(h.cm:getAt('take', 'retune.facility'), 'moves', 'OK writes the facility back at take tier')
    end,
  },

  -- A refused solve is offered the widening rather than dropped
  -- (design/adaptive-tuning.md § What the solver takes).
  {
    name = 'a refused retune offers to widen, and the offer taken solves again',
    run = function(harness)
      local h = harness.mk{ config = { project = { tempers = { FIVES = FIVES },
                                                  temper  = '12EDO' } } }
      h.reaper:setProjectTracks{ 'tr1' }
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 1, poolGuid = '{p1}' })
      h.reaper:seedMidi('tr1/t1', { notes = {
        { ppq = 0, endppq = 60, chan = 0, pitch = 62, vel = 100 },
        { ppq = 0, endppq = 60, chan = 0, pitch = 66, vel = 100 } } })
      local stack
      local origPublishDebug = fakeFacade.publishDebug
      fakeFacade.publishDebug = function(_, s) stack = s end
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeFacade.publishDebug = origPublishDebug
      fakeArrange.takeByKey['0:0'] = 'tr1/t1'
      tp:bindFromSelection()
      h.cmgr:push('tracker')

      -- The chord at the top row, as detune by written pitch.
      local function chord()
        local byPitch = {}
        for _, col in ipairs(stack.tv.grid.cols) do
          local e = col.type == 'note' and col.midiChan == 1 and col.cells[0]
          if e then byPitch[e.pitch] = e.detune end
        end
        return byPitch
      end

      h.cmgr:invoke('retune')
      fakeModalHost.last.callback{ scope = 'all', strength = 1, target = 'FIVES',
                                   key = 1, sonoritySize = 5, harmonicLock = 1 }
      local prompt = fakeModalHost.last.prompt
      t.truthy(prompt:find('F#', 1, true), 'the offer names the step with nowhere to go: ' .. prompt)
      t.truthy(prompt:find('FIVES', 1, true), 'and the target that left it there')
      t.eq(chord()[66], 0, 'the refusal itself moved nothing')

      local offer = fakeModalHost.last.callback
      offer(false)
      t.eq(chord()[66], 0, 'declined, the take stands as written')
      offer(true)
      t.eq(chord()[66], nil, 'taken, the tritone leaves F#')
      t.truthy(math.abs(chord()[67] - 1.9550) < 0.01, 'for the 3/2 the D beside it wants')
    end,
  },

  -- The empty grid pushes uiFont and draws one ImGui.Text — capture it. With
  -- slot-recovery there is one empty state only: the track has no MIDI slots.
  {
    name = 'empty grid shows the single no-takes message',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      local fakeChrome = { colour = function() return 0 end }
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, fakeChrome, { fontSize = { ui = 13 } })
      fakeArrange.slotsByIdx[0] = {}        -- the track has no slots
      local origText, shown = rawget(fakeImGui, 'Text')
      fakeImGui.Text = function(_, s) shown = s end

      tp:renderBody(nil, 100, 100, nil)
      t.eq(shown, 'No MIDI takes on this track.', 'single empty-grid message')

      fakeImGui.Text = origText
    end,
  },

  -- The watcher must not read the stack's own writes as external: a tick-time bridge
  -- edit through tm used to trip a spurious reload, which in REAPER wiped the pending
  -- undo capture — see docs/trackerPage.md § External-mutation watcher.
  {
    name = 'an owned tm flush resyncs the watcher baseline; only a foreign write trips the reload',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 1, poolGuid = '{p1}' })
      h.reaper:seedMidi('tr1/t1',
        { notes = { { ppq = 0, endppq = 60, chan = 1, pitch = 60, vel = 100 } } })
      local stack
      local origPublishDebug = fakeFacade.publishDebug
      fakeFacade.publishDebug = function(_, s) stack = s end
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeFacade.publishDebug = origPublishDebug
      fakeArrange.takeByKey['0:0'] = 'tr1/t1'
      tp:bindFromSelection()
      local wholesale = 0
      stack.mm:subscribe('reload', function(d)
        if d and d.wholesale then wholesale = wholesale + 1 end
      end)

      -- Bridge-style tick-time edit: through tm, outside any render pass.
      local first; for _, note in stack.mm:notes() do first = note; break end
      stack.tm:assignEvent(stack.tm:byUuid(first.uuid), { pitch = 67 })
      stack.tm:flush()
      tp:bindFromSelection()
      t.eq(wholesale, 0, 'own write did not read as an external mutation')

      -- A genuinely foreign take write must still trip the watcher.
      h.reaper:seedMidi('tr1/t1',
        { notes = { { ppq = 0, endppq = 60, chan = 1, pitch = 72, vel = 100 } } })
      tp:bindFromSelection()
      t.eq(wholesale, 1, 'foreign write tripped the watcher reload')
    end,
  },

  {
    name = 'bindFromSelection re-keys cm on return from dormancy even when the take is unchanged',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true,
                                pos = 0, len = 1, poolGuid = '{p1}' })
      local tp = newTrackerPage(h.cm, h.ds, h.cmgr, nil, {})
      fakeArrange.takeByKey['0:0'] = 'tr1/t1'
      tp:bindFromSelection()                -- initial bind to the selection take
      tp:unbind()                           -- switch away: cm context cleared, track tier unbound
      local got, errored = {}, false
      h.cm.setContext = function(_, take) got[#got+1] = take end
      local origShow = _G.reaper.ShowConsoleMsg
      _G.reaper.ShowConsoleMsg = function(m)
        if m:find('No track context', 1, true) then errored = true end
      end
      tp:bindFromSelection()                -- return: selection unchanged; must re-key the track tier first
      _G.reaper.ShowConsoleMsg = origShow
      t.eq(got[#got], 'tr1/t1', 're-asserts cm context despite the unchanged take')
      t.eq(errored, false, 'resolveSelectionTake re-keys the track tier before writing trackerSlot')
    end,
  },
}
