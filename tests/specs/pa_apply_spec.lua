-- pa:apply realises bindings into fakeReaper: a Continuum CC node pinned
-- at the chain head of both ends, filter/listen banks, plink config on
-- the target fx, and a bus-126 midi-only send fanning out. The mirror
-- short-circuit makes a second apply touch nothing; unbinding tears the
-- whole image back down.

local t = require('support')

local AUTO_BUS = 126
local P_SRC, P_DST, P_LISTEN = 16, 32, 48
local P_ASRC, P_ADST = 64, 80

-- Two live tracks: the bound take's own (src) and a target (dst) hosting
-- a synth. projectItems carries the bound take so pa's project-wide
-- binding/allocation scans see it.
local function mkScenario(harness)
  local h = harness.mk{}
  local r = h.reaper
  local src, dst = 'take1/track', 'dst/track'
  r._state.projectTracks = { src, dst }
  r._state.trackGuids[src] = '{SRC}'
  r._state.trackGuids[dst] = '{DST}'
  r._state.projectItems = { { takes = { 'take1' } } }
  r:setTrackFX(dst, { { ident = 'VST3:Synth' } })
  r:setFxGuid(dst, 0, '{FX-synth}')
  return h, r, src, dst
end

local function namedParm(r, track, fxIdx, parm)
  local _, v = r.TrackFX_GetNamedConfigParm(track, fxIdx, parm)
  return v
end

local TARGET = { trackGuid = '{DST}', fxGuid = '{FX-synth}', param = 2, label = 'Cutoff' }

return {

  {
    name = 'automate realises filter, listen, plink, and the bus send',
    run = function(harness)
      local h, r, src, dst = mkScenario(harness)
      local lane = h.pa:automate(1, TARGET)
      t.eq(lane, 119, 'top lane allocated')

      -- source: CC node + filter bank
      t.eq(#r._state.fxByTrack[src], 1, 'CC node added on source')
      t.eq(namedParm(r, src, 0, 'fx_ident'), 'Continuum CC')
      t.eq(r.TrackFX_GetParam(src, 0, P_SRC), 119, 'slot 0 src = (chan-1)*128 + lane')
      t.eq(r.TrackFX_GetParam(src, 0, P_DST), 0,   'slot 0 dst = bus code')
      t.eq(r.TrackFX_GetParam(src, 0, P_SRC + 1), -1, 'slot 1 empty')

      -- target: CC node moved to the chain head, synth shifted up
      t.eq(#r._state.fxByTrack[dst], 2)
      t.eq(namedParm(r, dst, 0, 'fx_ident'), 'Continuum CC', 'CC node at the chain head')
      t.eq(r.TrackFX_GetParam(dst, 0, P_LISTEN), 0, 'slot 0 listens to the bus code')
      t.eq(r.TrackFX_GetParam(dst, 0, P_LISTEN + 1), -1)

      -- plink: synth (now idx 1) param 2 driven by CC value slider 0
      t.eq(namedParm(r, dst, 1, 'param.2.plink.active'), '1')
      t.eq(namedParm(r, dst, 1, 'param.2.plink.effect'), '0')
      t.eq(namedParm(r, dst, 1, 'param.2.plink.param'),  '0')
      t.eq(namedParm(r, dst, 1, 'param.2.mod.active'),   '1')

      -- send: midi-only on the automation bus, both ends
      local sends = r._state.sendsByTrack[src]
      t.eq(#sends, 1, 'one auto send')
      t.eq(sends[1].dst, dst)
      t.eq(sends[1].srcChan, -1, 'midi-only')
      t.eq(sends[1].midiFlags, ((AUTO_BUS + 1) << 14) | ((AUTO_BUS + 1) << 22))
    end,
  },

  {
    name = 'mirror-matching apply is a no-op',
    run = function(harness)
      local h, r, src = mkScenario(harness)
      h.pa:automate(1, TARGET)
      r:clearCalls()
      h.pa:apply()
      t.eq(#r._state.calls, 0, 'no param/parm writes on a clean mirror')
      t.eq(#r._state.fxByTrack[src], 1,    'no duplicate CC node')
      t.eq(#r._state.sendsByTrack[src], 1, 'no duplicate send')
    end,
  },

  {
    name = 'unautomate tears down nodes, plinks, sends, and mirrors',
    run = function(harness)
      local h, r, src, dst = mkScenario(harness)
      local lane = h.pa:automate(1, TARGET)
      h.pa:unautomate(1, lane)

      t.eq(#r._state.fxByTrack[src], 0, 'source CC node removed')
      t.eq(#r._state.fxByTrack[dst], 1, 'only the synth left')
      t.eq(namedParm(r, dst, 0, 'fx_ident'), 'VST3:Synth')
      t.eq(namedParm(r, dst, 0, 'param.2.plink.active'), '0', 'stale plink cleared')
      t.eq(namedParm(r, dst, 0, 'param.2.mod.active'),   '0')
      t.eq(#(r._state.sendsByTrack[src] or {}), 0, 'send removed')
      local _, mirror = r.GetSetMediaTrackInfo_String(src, 'P_EXT:ctm_paramAuto', '', false)
      t.eq(mirror, '', 'mirror cleared')
    end,
  },

  {
    name = 'a baked vibrato carrier configures the add bank, surviving pa unbind',
    run = function(harness)
      local h, r, src = mkScenario(harness)
      -- Carrier on ch 1 (1-indexed): tm writes ds.fxCarrier; pa reads it into the
      -- add bank. asrc = (chan-1)*128 + code = 20, adst = 2048 + (chan-1) = 2048.
      h.ds:assign('fxCarrier', { [1] = { { code = 20, target = 'pb' } } })

      local lane = h.pa:automate(1, TARGET)   -- filter on src, listen on dst

      t.eq(namedParm(r, src, 0, 'fx_ident'), 'Continuum CC', 'CC node on the source')
      t.eq(r.TrackFX_GetParam(src, 0, P_SRC),  119,  'filter slot present')
      t.eq(r.TrackFX_GetParam(src, 0, P_ASRC), 20,   'add asrc = (chan-1)*128 + code')
      t.eq(r.TrackFX_GetParam(src, 0, P_ADST), 2048, 'add adst = 2048 + (chan-1) (pb)')
      t.eq(r.TrackFX_GetParam(src, 0, P_ASRC + 1), -1, 'one carrier — slot 1 empty')

      h.pa:unautomate(1, lane)
      t.eq(#r._state.fxByTrack[src], 1, 'node survives — the add bank still needs it')
      t.eq(namedParm(r, src, 0, 'fx_ident'), 'Continuum CC', 'CC node still at the head')
      t.eq(r.TrackFX_GetParam(src, 0, P_SRC),  -1, 'filter range cleared')
      t.eq(r.TrackFX_GetParam(src, 0, P_ASRC), 20, 'add bank retained')
    end,
  },

  {
    name = 'two carriers on one channel write two add rows summing into the same pb target',
    run = function(harness)
      local h, r, src = mkScenario(harness)
      -- vibrato + slide both bend ch-1 pitch: distinct asrc, shared adst -> the node sums.
      h.ds:assign('fxCarrier', { [1] = { { code = 20, target = 'pb' }, { code = 21, target = 'pb' } } })

      h.pa:automate(1, TARGET)

      t.eq(r.TrackFX_GetParam(src, 0, P_ASRC),     20,   'slot 0 asrc = lower carrier code')
      t.eq(r.TrackFX_GetParam(src, 0, P_ADST),     2048, 'slot 0 adst = ch-1 pb')
      t.eq(r.TrackFX_GetParam(src, 0, P_ASRC + 1), 21,   'slot 1 asrc = higher carrier code')
      t.eq(r.TrackFX_GetParam(src, 0, P_ADST + 1), 2048, 'slot 1 adst = same pb (summed at the node)')
      t.eq(r.TrackFX_GetParam(src, 0, P_ASRC + 2), -1,   'two carriers — slot 2 empty')
    end,
  },

  {
    name = 'ccm: a co-resident claimant keeps the node alive when pa unbinds',
    run = function(harness)
      local h, r, src, dst = mkScenario(harness)
      local lane = h.pa:automate(1, TARGET)

      -- A second claimant (e.g. cv-2's applier) holds dst's node. pa unbinding
      -- clears pa's banks but must not reap a node another producer still claims.
      h.ccm:claim('macro', dst)
      h.pa:unautomate(1, lane)

      t.eq(#r._state.fxByTrack[dst], 2, 'node survives — still claimed')
      t.eq(namedParm(r, dst, 0, 'fx_ident'), 'Continuum CC', 'CC node still at the head')
      t.eq(#r._state.fxByTrack[src], 0, 'source node reaped — pa was its only claim')
    end,
  },

}
