local t    = require('support')
local util = require('util')

local function mkWm(harness)
  local h  = harness.mk()
  local wm = util.instantiate('wiringManager', { cm = h.cm })
  return h, wm
end

-- Seed a tagged source track on the project; returns the track + its GUID.
-- guid arg is the literal guid string fakeReaper will report for the track.
local function seedSourceTrack(h, guid)
  local track = { __label = 'src:' .. guid }
  local list  = h.reaper._state.projectTracks
  list[#list+1] = track
  h.reaper._state.trackGuids[track] = guid
  h.cm:writeTrackKey(track, 'wiringHostKind', 'sourceTrack')
  return track
end

local function seedNewTrack(h, guid, classKey)
  local track = { __label = 'new:' .. guid }
  local list  = h.reaper._state.projectTracks
  list[#list+1] = track
  h.reaper._state.trackGuids[track] = guid
  h.cm:writeTrackKey(track, 'wiringHostKind', 'newTrack')
  h.cm:writeTrackKey(track, 'wiringClass',    classKey)
  return track
end

-- Add an fx with a known guid to a track. Returns the fxIdx.
local function seedFx(h, track, ident, fxGuid)
  local idx = h.reaper.TrackFX_AddByName(track, ident, false, -1)
  h.reaper:setFxGuid(track, idx, fxGuid)
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
      t.eq(snap['__scratch__'].hostKind, 'scratch')
      t.deepEq(snap['__scratch__'].fxOrder, {})
      t.eq(snap['__scratch__'].mainSend, false)
      t.deepEq(snap['__scratch__'].sends, {})
    end,
  },
  {
    name = 'sourceTrack: classKey is the track guid, mainSend defaults true (REAPER parity)',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      local track = seedSourceTrack(h, 'guid-A')
      local snap  = wm:snapshot()
      t.truthy(snap['guid-A'],            'entry under track-guid classKey')
      t.eq(snap['guid-A'].hostKind, 'sourceTrack')
      t.eq(snap['guid-A'].trackGuid, 'guid-A')
      t.eq(snap['guid-A'].mainSend, true)
      t.deepEq(snap['guid-A'].fxOrder, {})
      t.deepEq(snap['guid-A'].sends, {})
    end,
  },
  {
    name = 'fxOrder only includes FX whose guid is in the user graph',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      local track = seedSourceTrack(h, 'guid-A')
      seedFx(h, track, 'JS:owned',   '{FX-1}')
      seedFx(h, track, 'JS:foreign', '{FX-foreign}')
      -- Seed user graph with a node carrying fxGuid='{FX-1}' only.
      wm:mutate(function(g)
        g.nodes['s'] = { kind='source', trackGuid='guid-A', pos={x=0,y=0}, ports={audio={ins=0,outs=1},midi={ins=0,outs=1}} }
        g.nodes['f'] = { kind='fx', fxIdent='JS:owned', fxGuid='{FX-1}',
                         pos={x=0,y=0}, ports={audio={ins=1,outs=1},midi={ins=1,outs=1}} }
      end)
      local snap = wm:snapshot()
      t.eq(#snap['guid-A'].fxOrder, 1, 'foreign FX excluded')
      t.eq(snap['guid-A'].fxOrder[1].fxGuid, '{FX-1}')
      t.eq(snap['guid-A'].fxOrder[1].ident,  'JS:owned')
    end,
  },
  {
    name = 'CU instance registered via node.midiInBracketGuid appears in fxOrder',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      local track = seedSourceTrack(h, 'guid-A')
      seedFx(h, track, 'JS:owned',             '{FX-1}')
      seedFx(h, track, 'JS:Continuum Utility', '{CU-1}')
      h.reaper:setFxParamNames('JS:Continuum Utility', { 'mode', 'from', 'to' })
      local ok, err = wm:mutate(function(g)
        g.nodes['s'] = { kind='source', trackGuid='guid-A', pos={x=0,y=0}, ports={audio={ins=0,outs=1},midi={ins=0,outs=1}} }
        g.nodes['f'] = { kind='fx', fxIdent='JS:owned', fxGuid='{FX-1}', midiInBracketGuid='{CU-1}',
                         pos={x=0,y=0}, ports={audio={ins=1,outs=1},midi={ins=1,outs=1}} }
        util.add(g.edges, { type='audio', from='s', to='f', ops={gain=0.5} })
        util.add(g.edges, { type='audio', from='f', to='master' })
      end)
      t.truthy(ok, 'mutate ok: ' .. tostring(err and err.code))
      local snap = wm:snapshot()
      t.eq(#snap['guid-A'].fxOrder, 2, 'fx + CU both surface')
      local idents = {}
      for _, e in ipairs(snap['guid-A'].fxOrder) do idents[e.ident] = e.fxGuid end
      t.eq(idents['JS:owned'],             '{FX-1}')
      t.eq(idents['JS:Continuum Utility'], '{CU-1}')
    end,
  },
  {
    name = 'sends to a managed dst surface as {to=classKey, type=audio|midi}; foreign dst dropped',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      local src = seedSourceTrack(h, 'guid-A')
      local dst = seedSourceTrack(h, 'guid-B')
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
        kinds[s.type] = true
      end
      t.truthy(kinds.audio and kinds.midi, 'both send types preserved')
    end,
  },
  {
    name = 'newTrack host: classKey comes from wiringClass key (multi-guid)',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      seedNewTrack(h, 'guid-mix', 'guid-A|guid-B')
      local snap = wm:snapshot()
      t.truthy(snap['guid-A|guid-B'],            'entry under multi-guid classKey')
      t.eq(snap['guid-A|guid-B'].hostKind, 'newTrack')
      t.eq(snap['guid-A|guid-B'].trackGuid, 'guid-mix')
    end,
  },
  {
    name = 'B_MAINSEND=0 round-trips as mainSend=false',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      local track = seedSourceTrack(h, 'guid-A')
      h.reaper.SetMediaTrackInfo_Value(track, 'B_MAINSEND', 0)
      local snap = wm:snapshot()
      t.eq(snap['guid-A'].mainSend, false)
    end,
  },
  {
    name = 'audio send D_VOL round-trips as send gain; midi send carries none',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      local src = seedSourceTrack(h, 'guid-A')
      local dst = seedSourceTrack(h, 'guid-B')
      h.reaper:addSend(src, dst, { type = 'audio', gain = 0.5 })
      h.reaper:addSend(src, dst, { type = 'midi'  })
      local snap = wm:snapshot()
      for _, s in ipairs(snap['guid-A'].sends) do
        if s.type == 'audio' then t.eq(s.gain, 0.5) end
        if s.type == 'midi'  then t.eq(s.gain, nil, 'midi send has no gain') end
      end
    end,
  },
  {
    name = 'track D_VOL round-trips as mainSendGain',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      local track = seedSourceTrack(h, 'guid-A')
      h.reaper.SetMediaTrackInfo_Value(track, 'D_VOL', 0.25)
      local snap = wm:snapshot()
      t.eq(snap['guid-A'].mainSendGain, 0.25)
    end,
  },
  {
    name = 'I_NCHAN round-trips as nchan',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      local track = seedSourceTrack(h, 'guid-A')
      h.reaper.SetMediaTrackInfo_Value(track, 'I_NCHAN', 6)
      local snap = wm:snapshot()
      t.eq(snap['guid-A'].nchan, 6)
    end,
  },
  {
    name = 'C_MAINSEND_OFFS round-trips as mainSendOffs (only when mainSend=true)',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      local track = seedSourceTrack(h, 'guid-A')
      h.reaper.SetMediaTrackInfo_Value(track, 'C_MAINSEND_OFFS', 2)
      local snap = wm:snapshot()
      t.eq(snap['guid-A'].mainSendOffs, 2)
      h.reaper.SetMediaTrackInfo_Value(track, 'B_MAINSEND', 0)
      snap = wm:snapshot()
      t.eq(snap['guid-A'].mainSend,     false)
      t.eq(snap['guid-A'].mainSendOffs, nil, 'absent when mainSend=false')
    end,
  },
  {
    name = 'pin maps round-trip via pinMaps[fxGuid]; disconnected ports dropped',
    run = function(harness)
      local h, wm = mkWm(harness)
      wm:load()
      local track = seedSourceTrack(h, 'guid-A')
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
        g.nodes['s'] = { kind='source', trackGuid='guid-A', pos={x=0,y=0}, ports={audio={ins=0,outs=1},midi={ins=0,outs=1}} }
        g.nodes['f'] = { kind='fx', fxIdent='JS:owned', fxGuid='{FX-1}',
                         pos={x=0,y=0}, ports={audio={ins=1,outs=1},midi={ins=1,outs=1}} }
      end)
      local snap = wm:snapshot()
      local pm = snap['guid-A'].pinMaps['{FX-1}']
      t.truthy(pm,             'pinMaps entry present')
      t.deepEq(pm.ins[1], {2}, 'input port 1 → pair 2')
      t.eq(pm.ins[2],     nil, 'input port 2 disconnected dropped')
      t.eq(pm.outs[1],    nil, 'output port 1 disconnected dropped')
      t.deepEq(pm.outs[2], {1}, 'output port 2 → pair 1')
    end,
  },
}
