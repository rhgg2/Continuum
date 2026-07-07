-- Frecency decays per plugin-use, not per day: each bump advances the fx
-- ident's counter and rebases the param's score against it, so idle
-- wall-clock costs nothing. Pins frecencyOrder (decayed score desc, index
-- tie-break) and the bump arithmetic through cm's global tier.

local t    = require('support')
local util = require('util')

local pa = util.instantiate('paramAutomation', {})

local PARAMS = { { index = 0, name = 'Gain' },
                 { index = 1, name = 'Cutoff' },
                 { index = 2, name = 'Res' } }

local function names(params)
  local out = {}
  for _, prm in ipairs(params) do out[#out + 1] = prm.name end
  return out
end

return {

  {
    name = 'no scores: index order',
    run = function()
      t.deepEq(names(pa.frecencyOrder(PARAMS, nil)), { 'Gain', 'Cutoff', 'Res' })
    end,
  },

  {
    name = 'hot param first; untouched params tie-break by index',
    run = function()
      -- Scores are keyed by param index, not name (identically-named params
      -- must score independently); Res is index 2.
      local order = pa.frecencyOrder(PARAMS,
        { n = 3, params = { [2] = { s = 2, n0 = 3 } } })
      t.deepEq(names(order), { 'Res', 'Gain', 'Cutoff' })
    end,
  },

  {
    name = 'per-use decay: an old pile of bumps loses to recent use',
    run = function()
      -- Cutoff (idx 1) banked 3 points by use 1; Res (idx 2) got 1 point at use 30.
      -- 3 * 0.9^29 ≈ 0.14 < 1 — recency in uses wins.
      local order = pa.frecencyOrder(PARAMS,
        { n = 30, params = { [1] = { s = 3, n0 = 1 }, [2] = { s = 1, n0 = 30 } } })
      t.deepEq(names(order), { 'Res', 'Cutoff', 'Gain' })
    end,
  },

  {
    name = 'same-named params score independently (index-keyed frecency)',
    run = function()
      -- Two 'Freq' params (ReaEQ shape): bumping index 2 must not float index 0.
      local twins = { { index = 0, name = 'Freq' },
                      { index = 1, name = 'Gain' },
                      { index = 2, name = 'Freq' } }
      local order = pa.frecencyOrder(twins,
        { n = 1, params = { [2] = { s = 1, n0 = 1 } } })
      t.deepEq({ order[1].index, order[2].index, order[3].index }, { 2, 0, 1 })
    end,
  },

  {
    name = 'bumpFrecency: counter advances, score decays then +1, params re-sort',
    run = function(harness)
      local h = harness.mk{}
      local r = h.reaper
      local dst = 'dst/track'
      r._state.projectTracks = { dst }
      r._state.trackGuids[dst] = '{DST}'
      r:setTrackFX(dst, { { ident = 'VST3:Synth' } })
      r:setFxGuid(dst, 0, '{FX-synth}')
      r:setFxParamNames('VST3:Synth', { 'Gain', 'Cutoff', 'Res' })

      h.pa:bumpFrecency('{DST}', '{FX-synth}', 2)   -- Res
      h.pa:bumpFrecency('{DST}', '{FX-synth}', 2)

      local f = h.ds:get('paramFrecency')['VST3:Synth']
      t.eq(f.n, 2, 'two uses on the ident')
      t.eq(f.params[2].n0, 2)
      t.truthy(math.abs(f.params[2].s - 1.9) < 1e-9, 'decayed 1×0.9 then +1')

      t.deepEq(names(h.pa:params('{DST}', '{FX-synth}')), { 'Res', 'Gain', 'Cutoff' })
    end,
  },

  {
    name = 'params surface their section name; unreported sections are nil',
    run = function(harness)
      local h = harness.mk{}
      local r = h.reaper
      local dst = 'dst/track'
      r._state.projectTracks = { dst }
      r._state.trackGuids[dst] = '{DST}'
      r:setTrackFX(dst, { { ident = 'VST3:Synth' } })
      r:setFxGuid(dst, 0, '{FX-synth}')
      r:setFxParamNames('VST3:Synth', { 'Gain', 'Cutoff', 'Res' })
      r:setFxParamSections('VST3:Synth', { 'Amp', nil, 'Filter' })

      local byIndex = {}
      for _, prm in ipairs(h.pa:params('{DST}', '{FX-synth}')) do byIndex[prm.index] = prm end
      t.eq(byIndex[0].section, 'Amp')
      t.eq(byIndex[2].section, 'Filter')
      t.truthy(byIndex[1].section == nil, 'unreported section is nil')
    end,
  },

}
