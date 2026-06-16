-- Touch-learn through the real tv + pa stack: arming floats the fx ui
-- (remembering whether pa floated it), a stale pre-arm touch never
-- selects, a fresh touch selects + hoists without writing frecency, and
-- focus regain after a loss cancels and pops the window back down.

local t = require('support')

local NOTE = { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
               detune = 0, delay = 0, lane = 1 }

local ROW = { trackGuid = '{DST}', fxGuid = '{FX-synth}', name = 'Synth' }

local function mkScenario(harness)
  local h = harness.mk{ seed = { notes = { NOTE } } }
  local r = h.reaper
  local src, dst = 'take1/track', 'dst/track'
  r._state.projectTracks = { src, dst }
  r._state.trackGuids[src] = '{SRC}'
  r._state.trackGuids[dst] = '{DST}'
  r._state.projectItems = { { takes = { 'take1' } } }
  r:setTrackFX(dst, { { ident = 'VST3:Synth' } })
  r:setFxGuid(dst, 0, '{FX-synth}')
  r:setFxParamNames('VST3:Synth', { 'Gain', 'Cutoff', 'Res' })
  return h, r, src, dst
end

local function shows(r, flag)
  local n = 0
  for _, c in ipairs(r._state.calls) do
    if c.fn == 'TrackFX_Show' and c.showFlag == flag then n = n + 1 end
  end
  return n
end

return {

  {
    name = 'arm floats the fx ui; re-arm toggles off and pops it down',
    run = function(harness)
      local h, r = mkScenario(harness)
      h.vm:armLearn(ROW)
      t.eq(h.vm:learnFxGuid(), '{FX-synth}')
      t.eq(shows(r, 3), 1, 'floated')
      h.vm:armLearn(ROW)
      t.falsy(h.vm:learnFxGuid(), 're-arm toggles off')
      t.eq(shows(r, 2), 1, 'popped back down')
    end,
  },

  {
    name = 'an fx the user already floated stays up on cancel',
    run = function(harness)
      local h, r, _, dst = mkScenario(harness)
      r.TrackFX_Show(dst, 0, 3)   -- user floated it themselves
      r:clearCalls()
      h.vm:armLearn(ROW)
      h.vm:cancelLearn()
      t.eq(shows(r, 2), 0, 'no hide issued')
    end,
  },

  {
    name = 'stale pre-arm touch never selects; fresh touch selects + hoists, no frecency',
    run = function(harness)
      local h, r, _, dst = mkScenario(harness)
      r._state.lastTouched = { track = dst, fxIdx = 0, param = 1 }
      h.vm:armLearn(ROW)
      h.vm:pollLearn(true)
      t.falsy(h.vm:paletteParam(), 'baseline ignored')

      r._state.lastTouched = { track = dst, fxIdx = 0, param = 2 }
      h.vm:pollLearn(true)
      local sel = h.vm:paletteParam()
      t.truthy(sel, 'fresh touch selects')
      t.eq(sel.param, 2)
      t.eq(sel.label, 'Res')

      local order = {}
      for _, prm in ipairs(h.vm:listParams('{DST}', '{FX-synth}')) do
        order[#order + 1] = prm.name
      end
      t.deepEq(order, { 'Res', 'Gain', 'Cutoff' }, 'hoisted to top')
      t.falsy(next(h.ds:get('paramFrecency') or {}), 'touch does not write frecency')
    end,
  },

  {
    name = 'focus regain after a loss cancels and unfloats',
    run = function(harness)
      local h, r = mkScenario(harness)
      h.vm:armLearn(ROW)
      h.vm:pollLearn(true)    -- still home after arming: stays armed
      t.truthy(h.vm:learnFxGuid())
      h.vm:pollLearn(false)   -- user in the fx window
      h.vm:pollLearn(true)    -- back in continuum
      t.falsy(h.vm:learnFxGuid())
      t.eq(shows(r, 2), 1, 'window popped down')
    end,
  },

  {
    name = 'automateParam bumps frecency and ends the learn',
    run = function(harness)
      local h, r, _, dst = mkScenario(harness)
      h.vm:setGridSize(80, 40)
      h.ec:setPos(0, 1, 1)
      h.vm:armLearn(ROW)
      r._state.lastTouched = { track = dst, fxIdx = 0, param = 2 }
      h.vm:pollLearn(true)
      h.vm:automateParam()
      t.truthy(h.vm:paramBinding(1, 119), 'bound at the top lane')
      t.falsy(h.vm:learnFxGuid(), 'learn cancelled')
      t.eq(h.ds:get('paramFrecency')['VST3:Synth'].n, 1, 'one bump')
    end,
  },

}
