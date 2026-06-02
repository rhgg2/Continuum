local t    = require('support')
local util = require('util')

-- 3c.4.5 apply round-trip: a midi fan-in to one consumer collapses to a Merge
-- CU on the consumer trackKey. The CU reads the feeder buses (inMask) and rewrites
-- them to a single outBus the consumer reads; its guid is stamped onto the
-- consumer node so reconciles are idempotent and the CU retracts when the
-- fan-in drops back to a single feeder.

local CU_PARAMS = { 'mode', 'gain', 'from', 'nPairs',
  'gain1', 'gain2', 'gain3', 'gain4', 'gain5', 'gain6', 'gain7', 'gain8',
  'gain9', 'gain10', 'gain11', 'gain12', 'gain13', 'gain14', 'gain15', 'gain16',
  'outBus', 'inMask0', 'inMask1', 'inMask2', 'inMask3', 'audioSum', 'to' }

local function mkWm(harness)
  local h  = harness.mk()
  h.reaper:setFxParamNames('JS:Continuum Utility', CU_PARAMS)
  local wm = util.instantiate('wiringManager', { cm = h.cm })
  wm:load()
  return h, wm
end

local function seedSource(h, guid)
  local track = { __label = 'src-' .. guid }
  table.insert(h.reaper._state.projectTracks, track)
  h.reaper._state.trackGuids[track] = guid
  h.cm:writeTrackKey(track, 'wiringTrackKind', 'sourceTrack')
  return track
end

local function source(guid)
  return { kind='source', trackGuid=guid, pos={x=0,y=0},
           ports={audio={ins=0,outs=1}, midi={ins=0,outs=1}} }
end

local function fx(ident)
  return { kind='fx', fxIdent=ident, pos={x=0,y=0},
           ports={audio={ins=1,outs=1}, midi={ins=1,outs=1}} }
end

local function midiEdge(from, to)
  return { type='midi', from=from, to=to }
end

local function apply(wm)
  wm:applyOps(wm:diff(wm:targetState(), wm:snapshot()))
end

-- Walks REAPER's tracks for the wiring newTrack that hosts the merged class.
local function findNewTrack(h)
  for i = 0, h.reaper.CountTracks(0) - 1 do
    local tr = h.reaper.GetTrack(0, i)
    if h.cm:readTrackKey(tr, 'wiringTrackKind') == 'newTrack' then return tr end
  end
end

local function fxAt(h, track, slot)
  local _, ident = h.reaper.TrackFX_GetFXName(track, slot)
  return ident, h.reaper.TrackFX_GetFXGUID(track, slot)
end

local function paramSetsOn(h, track, fxIdx)
  local out = {}
  for _, c in ipairs(h.reaper._state.calls) do
    if c.fn == 'TrackFX_SetParam' and c.track == track and c.fxIdx == fxIdx then
      out[c.paramIdx] = c.value
    end
  end
  return out
end

local function mergeStamp(wm)
  for _, guid in pairs(wm:graph().nodes.fxC.mergeGuids or {}) do return guid end
end

return {
  {
    name = 'merge apply: Merge CU + consumer land on the newTrack',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      seedSource(h, 'guid-B')
      wm:mutate(function(g)
        g.nodes.sA  = source('guid-A')
        g.nodes.sB  = source('guid-B')
        g.nodes.fxC = fx('JS:c')
        util.add(g.edges, midiEdge('sA', 'fxC'))
        util.add(g.edges, midiEdge('sB', 'fxC'))
      end)
      apply(wm)
      local track = findNewTrack(h)
      t.truthy(track, 'newTrack created for fxC class')
      t.eq(h.reaper.TrackFX_GetCount(track), 2, 'Merge CU + fxC')
      local cu,  gCU  = fxAt(h, track, 0)
      local mid, gMid = fxAt(h, track, 1)
      t.eq(cu,  'JS:Continuum Utility', 'slot 0 = Merge CU')
      t.eq(mid, 'JS:c',                 'slot 1 = consumer fx')
      -- slider layout: mode=0, nPairs=3, outBus=20, inMask0=21, audioSum=25.
      local sets = paramSetsOn(h, track, 0)
      t.eq(sets[0],  1, 'merge mode')
      t.eq(sets[3],  1, 'nPairs = 1 (one midi bus)')
      t.eq(sets[21], 3, 'inMask0 covers feeder buses 0 and 1')
      t.eq(sets[20], 0, 'outBus = 0 (consumer reads the boundary bus)')
      t.eq(sets[25], 0, 'audioSum off — matrix-less collapse is midi-only')
      t.eq(mergeStamp(wm), gCU, 'CU guid stamped onto consumer mergeGuids')
      t.eq(wm:graph().nodes.fxC.fxGuid, gMid, 'consumer node guid is the mid slot')
    end,
  },
  {
    name = 'merge apply: idempotent — second reconcile drops no setFXChain op',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      seedSource(h, 'guid-B')
      wm:mutate(function(g)
        g.nodes.sA  = source('guid-A')
        g.nodes.sB  = source('guid-B')
        g.nodes.fxC = fx('JS:c')
        util.add(g.edges, midiEdge('sA', 'fxC'))
        util.add(g.edges, midiEdge('sB', 'fxC'))
      end)
      apply(wm)
      local ops = wm:diff(wm:targetState(), wm:snapshot())
      for _, op in ipairs(ops) do
        t.eq(op.op == 'setFXChain', false,
             'no setFXChain on re-apply; got op=' .. op.op)
      end
    end,
  },
  {
    name = 'merge apply: dropping one feeder retracts the Merge CU on re-apply',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      seedSource(h, 'guid-B')
      wm:mutate(function(g)
        g.nodes.sA  = source('guid-A')
        g.nodes.sB  = source('guid-B')
        g.nodes.fxC = fx('JS:c')
        util.add(g.edges, midiEdge('sA', 'fxC'))
        util.add(g.edges, midiEdge('sB', 'fxC'))
      end)
      apply(wm)
      local track = findNewTrack(h)
      t.eq(h.reaper.TrackFX_GetCount(track), 2, 'Merge CU present after first apply')
      -- Drop the sB feeder: fxC's srcSet shrinks to {sA} so it migrates onto
      -- sA's sourceTrack, fed by source midi on bus 0 — no fan-in, no merge.
      wm:mutate(function(g)
        local newEdges = {}
        for _, e in ipairs(g.edges) do
          if not (e.from == 'sB' and e.to == 'fxC') then util.add(newEdges, e) end
        end
        g.edges = newEdges
      end)
      apply(wm)
      local cuTotal, fxCTotal = 0, 0
      for i = 0, h.reaper.CountTracks(0) - 1 do
        local tr = h.reaper.GetTrack(0, i)
        for s = 0, h.reaper.TrackFX_GetCount(tr) - 1 do
          local _, ident = h.reaper.TrackFX_GetFXName(tr, s)
          if ident == 'JS:Continuum Utility' then cuTotal = cuTotal + 1 end
          if ident == 'JS:c'                 then fxCTotal = fxCTotal + 1 end
        end
      end
      t.eq(cuTotal,  0, 'merge CU gone after sB removed')
      t.eq(fxCTotal, 1, 'consumer fx still live (moved hosts)')
      t.eq(mergeStamp(wm), nil, 'merge stamp cleared')
    end,
  },
}
