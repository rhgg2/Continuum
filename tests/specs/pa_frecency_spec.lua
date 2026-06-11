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
      local order = pa.frecencyOrder(PARAMS,
        { n = 3, params = { Res = { s = 2, n0 = 3 } } })
      t.deepEq(names(order), { 'Res', 'Gain', 'Cutoff' })
    end,
  },

  {
    name = 'per-use decay: an old pile of bumps loses to recent use',
    run = function()
      -- Cutoff banked 3 points by use 1; Res got 1 point at use 30.
      -- 3 * 0.9^29 ≈ 0.14 < 1 — recency in uses wins.
      local order = pa.frecencyOrder(PARAMS,
        { n = 30, params = { Cutoff = { s = 3, n0 = 1 }, Res = { s = 1, n0 = 30 } } })
      t.deepEq(names(order), { 'Res', 'Cutoff', 'Gain' })
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

      h.pa:bumpFrecency('{DST}', '{FX-synth}', 'Res')
      h.pa:bumpFrecency('{DST}', '{FX-synth}', 'Res')

      local f = h.cm:get('paramFrecency')['VST3:Synth']
      t.eq(f.n, 2, 'two uses on the ident')
      t.eq(f.params.Res.n0, 2)
      t.truthy(math.abs(f.params.Res.s - 1.9) < 1e-9, 'decayed 1×0.9 then +1')

      t.deepEq(names(h.pa:params('{DST}', '{FX-synth}')), { 'Res', 'Gain', 'Cutoff' })
    end,
  },

}
