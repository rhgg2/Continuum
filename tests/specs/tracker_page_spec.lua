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
  fakeArrange.isParkedTake   = function() return false end
  fakeArrange.ownerTrack     = function(take) return take end
  fakeArrange.mintParkedTake = function(trackIdx, name, beats, src)
    fakeArrange.calls.mint = { trackIdx = trackIdx, name = name, beats = beats, src = src }
    return 7                                       -- the new parked slot
  end
end
local fakeWiring = { samplerReachable = function() return false end }
local fakeFacade = {
  publish = function() end,
  publishDebug = function() end,
  get = function(name)
    if name == 'arrange' then return fakeArrange end
    if name == 'wiring'  then return fakeWiring  end
    return {}
  end,
}

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
  -- writes that selection via tv. newTakeBelow / dup mint a slot parked on scratch and select it.
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
    name = 'newTakeBelow + duplicateUnpooledBelow mint a parked slot on scratch and select it',
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
      t.eq(fakeArrange.calls.mint.name, '07', 'minted with the modal name')
      t.eq(fakeArrange.calls.mint.src,  nil,  'new take has no clone source')
      t.eq(h.cm:getAt('track', 'trackerSlot'), 7, 'tracker selected the new parked slot')

      h.cmgr:invoke('duplicateUnpooledBelow')      -- clones the bound take, opens take-properties
      t.eq(fakeArrange.calls.mint.src, 'tr1/t1', 'dup passed the bound take as clone source')
      t.eq(h.cm:getAt('track', 'trackerSlot'), 7, 'tracker selected the new parked slot')
      t.eq(fakeModalHost.last.focusName, true, 'dup opens take-properties focused on the name field')
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
  -- target object (design/adaptive-ji.md § The command's slots): it persists at
  -- take tier as the target and the key do, and harmonic lock opens on its figure.
  {
    name = 'retune opens on the facility the take carries, harmonic lock on its figure',
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
      t.eq(fakeModalHost.last.harmonicLock, 1, 'and harmonic lock on the points figure')

      h.cm:set('take', 'retune.facility', 'moves')
      h.cmgr:invoke('retune')
      t.eq(fakeModalHost.last.facility, 'moves', 'the modal reopens on the facility the take carries')
      t.eq(fakeModalHost.last.harmonicLock, 1.5, 'and harmonic lock on the placement figure')

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
