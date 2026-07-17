-- pa:params must resolve fx wherever the cone-walk row places them — including
-- the master track. wm:paramTargets resolves rows via rm's locateFx (which
-- checks master), so a master-hosted bus fx yields a row; pa:params must be
-- able to fetch its names too, or the palette shows an empty subtree.

local t    = require('support')

return {
  {
    name = 'params resolve for fx on a regular non-first track',
    run = function(harness)
      local h = harness.mk{}
      local r = h.reaper
      local own, other = 'own/track', 'other/track'
      r._state.projectTracks = { own, other }
      r._state.trackGuids[own]   = '{OWN}'
      r._state.trackGuids[other] = '{OTHER}'
      r:setTrackFX(other, { { ident = 'VST3:EQ' } })
      r:setFxGuid(other, 0, '{FX-other}')
      r:setFxParamNames('VST3:EQ', { 'Freq', 'Q', 'BandGain' })

      local got = {}
      for _, p in ipairs(h.pa:params('{OTHER}', '{FX-other}')) do got[#got+1] = p.name end
      t.deepEq(got, { 'Freq', 'Q', 'BandGain' })
    end,
  },

  {
    name = 'params resolve for fx on the master track',
    run = function(harness)
      local h = harness.mk{}
      local r = h.reaper
      r._state.projectTracks = { 'src/track' }
      r._state.trackGuids['src/track'] = '{SRC}'
      r._state.trackGuids[r._state.master] = '{MASTER}'
      r:setTrackFX(r._state.master, { { ident = 'VST3:Limiter' } })
      r:setFxGuid(r._state.master, 0, '{FX-master}')
      r:setFxParamNames('VST3:Limiter', { 'Threshold', 'Ceiling' })

      local got = {}
      for _, p in ipairs(h.pa:params('{MASTER}', '{FX-master}')) do got[#got+1] = p.name end
      t.deepEq(got, { 'Threshold', 'Ceiling' }, 'master-hosted fx names resolve')
    end,
  },
}
