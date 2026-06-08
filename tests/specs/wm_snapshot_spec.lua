local t    = require('support')
local util = require('util')

local function mkWm(harness)
  local h  = harness.mk()
  local rm = util.instantiate('routingManager')
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
  return h, wm
end

-- Seed a source track + its graph node (production pairs them 1:1, so snapshot derives
-- source identity from the node). guid is the literal guid fakeReaper reports.
local function seedSourceTrack(h, wm, guid)
  local track = { __label = 'src:' .. guid }
  local list  = h.reaper._state.projectTracks
  list[#list+1] = track
  h.reaper._state.trackGuids[track] = guid
  wm:mutate(function(g)
    g.nodes['src::' .. guid] = { kind='source', trackId=guid, pos={x=0,y=0},
                                 ports={audio={ins=0,outs=1}, midi={ins=0,outs=1}} }
  end)
  return track
end

-- newTracks have no graph node — their id lives in the wiringTracks map under trackKey.
local function seedNewTrack(h, guid, trackKey)
  local track = { __label = 'new:' .. guid }
  local list  = h.reaper._state.projectTracks
  list[#list+1] = track
  h.reaper._state.trackGuids[track] = guid
  local wt = h.cm:get('wiringTracks') or {}
  wt[trackKey] = guid
  h.cm:set('project', 'wiringTracks', wt)
  return track
end

-- Add an fx with a known guid to a track. Returns the fxIdx.
local function seedFx(h, track, ident, fxId)
  local idx = h.reaper.TrackFX_AddByName(track, ident, false, -1)
  h.reaper:setFxGuid(track, idx, fxId)
  return idx
end

return {
  {
    name = 'empty project: snapshot only carries the scratch entry',
    run = function(harness)
      local _, wm = mkWm(harness)
      wm:load()  -- creates the scratch track
      local snap = wm:snapshot()
      t.truthy(snap['__scratch__'],            'scratch entry present')
      t.eq(snap['__scratch__'].trackKind, 'scratch')
      t.deepEq(snap['__scratch__'].fx, {})
      t.eq(snap['__scratch__'].mainSend.on, false)
      t.deepEq(snap['__scratch__'].sends, {})
    end,
  },
  {
    name = 'sourceTrack: trackKey is the track guid, mainSend defaults on (REAPER parity)',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      local track = seedSourceTrack(h, wm, 'guid-A')
      local snap  = wm:snapshot()
      t.truthy(snap['guid-A'],            'entry under track-guid trackKey')
      t.eq(snap['guid-A'].trackKind, 'sourceTrack')
      t.eq(snap['guid-A'].id, 'guid-A')
      t.eq(snap['guid-A'].mainSend.on, true)
      t.deepEq(snap['guid-A'].fx, {})
      t.deepEq(snap['guid-A'].sends, {})
    end,
  },
  {
    -- snapshot probes JSFX descs so read can quarantine a bus-aware fx; only true is stamped.
    name = 'fx: a bus-aware JSFX is stamped busAware, a plain one is not',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      local track = seedSourceTrack(h, wm, 'guid-A')
      seedFx(h, track, 'JS:BusAware', '{FX-b}')
      seedFx(h, track, 'JS:Plain',    '{FX-p}')
      wm:mutate(function(g)
        g.nodes['fb'] = { kind='fx', fxIdent='JS:BusAware', fxId='{FX-b}',
                          pos={x=0,y=0}, ports={audio={ins=1,outs=1},midi={ins=1,outs=1}} }
        g.nodes['fp'] = { kind='fx', fxIdent='JS:Plain', fxId='{FX-p}',
                          pos={x=0,y=0}, ports={audio={ins=1,outs=1},midi={ins=1,outs=1}} }
      end)
      wm.readJSFXContent = function(_, ident)
        return ident == 'JS:BusAware' and 'desc:B\next_midi_bus = 1\n' or 'desc:P\n@sample\n'
      end
      local fxBy = {}
      for _, e in ipairs(wm:snapshot()['guid-A'].fx) do fxBy[e.id] = e end
      t.eq(fxBy['{FX-b}'].busAware, true, 'bus-aware fx stamped')
      t.eq(fxBy['{FX-p}'].busAware, nil,  'plain fx left unstamped')
    end,
  },
  {
    name = 'fx only includes FX whose guid is in the user graph',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      local track = seedSourceTrack(h, wm, 'guid-A')
      seedFx(h, track, 'JS:owned',   '{FX-1}')
      seedFx(h, track, 'JS:foreign', '{FX-foreign}')
      -- Seed user graph with a node carrying fxId='{FX-1}' only.
      wm:mutate(function(g)
        g.nodes['f'] = { kind='fx', fxIdent='JS:owned', fxId='{FX-1}',
                         pos={x=0,y=0}, ports={audio={ins=1,outs=1},midi={ins=1,outs=1}} }
      end)
      local snap = wm:snapshot()
      t.eq(#snap['guid-A'].fx, 1, 'foreign FX excluded')
      t.eq(snap['guid-A'].fx[1].id,    '{FX-1}')
      t.eq(snap['guid-A'].fx[1].ident, 'JS:owned')
    end,
  },
  {
    name = 'CU instance registered via node.midiInBracketGuid appears in fx',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      local track = seedSourceTrack(h, wm, 'guid-A')
      seedFx(h, track, 'JS:owned',             '{FX-1}')
      seedFx(h, track, 'JS:Continuum Utility', '{CU-1}')
      h.reaper:setFxParamNames('JS:Continuum Utility', { 'mode', 'from', 'to' })
      local ok, err = wm:mutate(function(g)
        g.nodes['f'] = { kind='fx', fxIdent='JS:owned', fxId='{FX-1}', midiInBracketGuid='{CU-1}',
                         pos={x=0,y=0}, ports={audio={ins=1,outs=1},midi={ins=1,outs=1}} }
        util.add(g.edges, { type='audio', from='src::guid-A', to='f', ops={gain=0.5} })
        util.add(g.edges, { type='audio', from='f', to='master' })
      end)
      t.truthy(ok, 'mutate ok: ' .. tostring(err and err.code))
      local snap = wm:snapshot()
      t.eq(#snap['guid-A'].fx, 2, 'fx + CU both surface')
      local idents = {}
      for _, e in ipairs(snap['guid-A'].fx) do idents[e.ident] = e.id end
      t.eq(idents['JS:owned'],             '{FX-1}')
      t.eq(idents['JS:Continuum Utility'], '{CU-1}')
    end,
  },
  {
    name = 'sends to a managed dst surface as {to=trackKey, kind=audio|midi}; foreign dst dropped',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      local src = seedSourceTrack(h, wm, 'guid-A')
      local dst = seedSourceTrack(h, wm, 'guid-B')
      local foreign = { __label = 'foreign' }
      h.reaper._state.projectTracks[#h.reaper._state.projectTracks+1] = foreign
      h.reaper._state.trackGuids[foreign] = 'guid-foreign'
      h.reaper:addSend(src, dst,     { type = 'audio' })
      h.reaper:addSend(src, foreign, { type = 'audio' })
      h.reaper:addSend(src, dst,     { type = 'midi'  })
      local snap = wm:snapshot()
      t.eq(#snap['guid-A'].sends, 2, 'foreign-dst send dropped')
      local kinds = {}
      for _, s in ipairs(snap['guid-A'].sends) do
        t.eq(s.to, 'guid-B')
        kinds[s.kind] = true
      end
      t.truthy(kinds.audio and kinds.midi, 'both send kinds preserved')
    end,
  },
  {
    name = 'newTrack trackKey: trackKey comes from wiringTrack key (multi-guid)',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      seedNewTrack(h, 'guid-mix', 'guid-A|guid-B')
      local snap = wm:snapshot()
      t.truthy(snap['guid-A|guid-B'],            'entry under multi-guid trackKey')
      t.eq(snap['guid-A|guid-B'].trackKind, 'newTrack')
      t.eq(snap['guid-A|guid-B'].id, 'guid-mix')
    end,
  },
  {
    name = 'B_MAINSEND=0 round-trips as mainSend.on=false',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      local track = seedSourceTrack(h, wm, 'guid-A')
      h.reaper.SetMediaTrackInfo_Value(track, 'B_MAINSEND', 0)
      local snap = wm:snapshot()
      t.eq(snap['guid-A'].mainSend.on, false)
    end,
  },
  {
    name = 'audio send D_VOL round-trips as send gain; midi send carries none',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      local src = seedSourceTrack(h, wm, 'guid-A')
      local dst = seedSourceTrack(h, wm, 'guid-B')
      h.reaper:addSend(src, dst, { type = 'audio', gain = 0.5 })
      h.reaper:addSend(src, dst, { type = 'midi'  })
      local snap = wm:snapshot()
      for _, s in ipairs(snap['guid-A'].sends) do
        if s.kind == 'audio' then t.eq(s.gain, 0.5) end
        if s.kind == 'midi'  then t.eq(s.gain, nil, 'midi send has no gain') end
      end
    end,
  },
  {
    name = 'send I_SENDMODE=1 round-trips as pos=preFx; pre/post-FX coexist on same channels',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      local src = seedSourceTrack(h, wm, 'guid-A')
      local dst = seedSourceTrack(h, wm, 'guid-B')
      h.reaper:addSend(src, dst, { type = 'audio' })
      h.reaper:addSend(src, dst, { type = 'audio' })
      h.reaper.SetTrackSendInfo_Value(src, 0, 0, 'I_SENDMODE', 1)
      h.reaper.SetTrackSendInfo_Value(src, 0, 1, 'I_SENDMODE', 3)
      local byPos = {}
      for _, s in ipairs(wm:snapshot()['guid-A'].sends) do
        byPos[s.pos] = true
      end
      t.truthy(byPos.preFx,    'pre-FX send surfaces pos=preFx')
      t.truthy(byPos.preFader, 'post-FX send surfaces pos=preFader')
    end,
  },
  {
    name = 'track D_VOL round-trips as mainSend.gain',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      local track = seedSourceTrack(h, wm, 'guid-A')
      h.reaper.SetMediaTrackInfo_Value(track, 'D_VOL', 0.25)
      local snap = wm:snapshot()
      t.eq(snap['guid-A'].mainSend.gain, 0.25)
    end,
  },
  {
    name = 'I_NCHAN round-trips as nchan',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      local track = seedSourceTrack(h, wm, 'guid-A')
      h.reaper.SetMediaTrackInfo_Value(track, 'I_NCHAN', 6)
      local snap = wm:snapshot()
      t.eq(snap['guid-A'].nchan, 6)
    end,
  },
  {
    name = 'C_MAINSEND_OFFS round-trips as mainSend.tgtOffset',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      local track = seedSourceTrack(h, wm, 'guid-A')
      h.reaper.SetMediaTrackInfo_Value(track, 'C_MAINSEND_OFFS', 2)
      local snap = wm:snapshot()
      t.eq(snap['guid-A'].mainSend.tgtOffset, 2)
      h.reaper.SetMediaTrackInfo_Value(track, 'B_MAINSEND', 0)
      snap = wm:snapshot()
      t.eq(snap['guid-A'].mainSend.on, false)
    end,
  },
  {
    name = 'C_MAINSEND_NCH round-trips as mainSend.nchan',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      local track = seedSourceTrack(h, wm, 'guid-A')
      h.reaper.SetMediaTrackInfo_Value(track, 'C_MAINSEND_NCH', 2)
      local snap = wm:snapshot()
      t.eq(snap['guid-A'].mainSend.nchan, 2)
      h.reaper.SetMediaTrackInfo_Value(track, 'B_MAINSEND', 0)
      snap = wm:snapshot()
      t.eq(snap['guid-A'].mainSend.on, false)
    end,
  },
  {
    name = 'pin maps round-trip nested on fx[i].pinMaps; disconnected ports dropped',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      local track = seedSourceTrack(h, wm, 'guid-A')
      h.reaper:setFxIO('JS:owned', { ins = 4, outs = 4 })
      local fxIdx = seedFx(h, track, 'JS:owned', '{FX-1}')
      -- in port 1 (pins 0,1) → pair 2 (channels 2,3); in port 2 disconnected.
      h.reaper.TrackFX_SetPinMappings(track, fxIdx, 0, 0, 1 << 2, 0)
      h.reaper.TrackFX_SetPinMappings(track, fxIdx, 0, 1, 1 << 3, 0)
      h.reaper.TrackFX_SetPinMappings(track, fxIdx, 0, 2, 0, 0)
      h.reaper.TrackFX_SetPinMappings(track, fxIdx, 0, 3, 0, 0)
      -- out port 1 disconnected; out port 2 → pair 1.
      h.reaper.TrackFX_SetPinMappings(track, fxIdx, 1, 0, 0, 0)
      h.reaper.TrackFX_SetPinMappings(track, fxIdx, 1, 1, 0, 0)
      h.reaper.TrackFX_SetPinMappings(track, fxIdx, 1, 2, 1 << 0, 0)
      h.reaper.TrackFX_SetPinMappings(track, fxIdx, 1, 3, 1 << 1, 0)
      wm:mutate(function(g)
        g.nodes['f'] = { kind='fx', fxIdent='JS:owned', fxId='{FX-1}',
                         pos={x=0,y=0}, ports={audio={ins=1,outs=1},midi={ins=1,outs=1}} }
      end)
      local snap = wm:snapshot()
      local pm = snap['guid-A'].fx[1].pinMaps
      t.truthy(pm,             'pinMaps entry present')
      t.deepEq(pm.ins[1], {2}, 'input port 1 → pair 2')
      t.eq(pm.ins[2],     nil, 'input port 2 disconnected dropped')
      t.eq(pm.outs[1],    nil, 'output port 1 disconnected dropped')
      t.deepEq(pm.outs[2], {1}, 'output port 2 → pair 1')
    end,
  },
}
