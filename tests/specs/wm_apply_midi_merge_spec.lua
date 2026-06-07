local t    = require('support')
local util = require('util')

-- 3c.4.5 apply round-trip: midi fan-in from two same-track producers. see docs/wiringManager.md § Merge CU

local CU_PARAMS = { 'mode', 'gain', 'from', 'nPairs',
  'gain1', 'gain2', 'gain3', 'gain4', 'gain5', 'gain6', 'gain7', 'gain8',
  'gain9', 'gain10', 'gain11', 'gain12', 'gain13', 'gain14', 'gain15', 'gain16',
  'outBus', 'inMask0', 'inMask1', 'inMask2', 'inMask3', 'audioSum', 'to' }

local function mkWm(harness)
  local h  = harness.mk()
  h.reaper:setFxParamNames('JS:Continuum Utility', CU_PARAMS)
  local rm = util.instantiate('routingManager')
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
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

-- First slot on `track` whose fx ident matches, or nil.
local function slotOf(h, track, ident)
  for s = 0, h.reaper.TrackFX_GetCount(track) - 1 do
    if (select(2, h.reaper.TrackFX_GetFXName(track, s))) == ident then return s end
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
    name = 'merge apply: two same-track producers into one consumer mint a Merge CU',
    run = function(harness)
      local h, wm = mkWm(harness)
      local trackA = seedSource(h, 'guid-A')
      wm:mutate(function(g)
        g.nodes.sA   = source('guid-A')
        g.nodes.fxP1 = fx('JS:p1')
        g.nodes.fxP2 = fx('JS:p2')
        g.nodes.fxC  = fx('JS:c')
        util.add(g.edges, midiEdge('sA',   'fxP1'))
        util.add(g.edges, midiEdge('sA',   'fxP2'))
        util.add(g.edges, midiEdge('fxP1', 'fxC'))
        util.add(g.edges, midiEdge('fxP2', 'fxC'))
      end)
      apply(wm)
      -- Two intra producers, the Merge CU unioning them, then the consumer.
      t.eq(h.reaper.TrackFX_GetCount(trackA), 4, 'fxP1 + fxP2 + Merge CU + fxC')
      local cuSlot  = slotOf(h, trackA, 'JS:Continuum Utility')
      local fxCSlot = slotOf(h, trackA, 'JS:c')
      t.truthy(cuSlot and fxCSlot, 'CU and consumer present')
      t.truthy(cuSlot < fxCSlot, 'CU precedes the consumer')
      local _, gCU  = fxAt(h, trackA, cuSlot)
      local _, gMid = fxAt(h, trackA, fxCSlot)
      -- slider layout: mode=0, nPairs=3, outBus=20, inMask0=21, audioSum=25.
      local sets = paramSetsOn(h, trackA, cuSlot)
      t.eq(sets[0],  1, 'merge mode')
      t.eq(sets[3],  1, 'nPairs = 1 (one midi bus)')
      t.eq(sets[21], 3, 'inMask0 covers the two producer buses')
      t.eq(sets[20], 0, 'outBus = 0 (consumer reads the boundary bus)')
      t.eq(sets[25], 0, 'audioSum off — matrix-less collapse is midi-only')
      t.eq(mergeStamp(wm), gCU, 'CU guid stamped onto consumer mergeGuids')
      t.eq(wm:graph().nodes.fxC.fxGuid, gMid, 'consumer node guid is the consumer slot')
    end,
  },
  {
    name = 'merge apply: idempotent — second reconcile drops no setFXChain op',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      seedSource(h, 'guid-B')
      wm:mutate(function(g)
        g.nodes.sA   = source('guid-A')
        g.nodes.fxP1 = fx('JS:p1')
        g.nodes.fxP2 = fx('JS:p2')
        g.nodes.fxC  = fx('JS:c')
        util.add(g.edges, midiEdge('sA',   'fxP1'))
        util.add(g.edges, midiEdge('sA',   'fxP2'))
        util.add(g.edges, midiEdge('fxP1', 'fxC'))
        util.add(g.edges, midiEdge('fxP2', 'fxC'))
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
    name = 'merge apply: dropping a feeder retracts the Merge CU on re-apply',
    run = function(harness)
      local h, wm = mkWm(harness)
      local trackA = seedSource(h, 'guid-A')
      wm:mutate(function(g)
        g.nodes.sA   = source('guid-A')
        g.nodes.fxP1 = fx('JS:p1')
        g.nodes.fxP2 = fx('JS:p2')
        g.nodes.fxC  = fx('JS:c')
        util.add(g.edges, midiEdge('sA',   'fxP1'))
        util.add(g.edges, midiEdge('sA',   'fxP2'))
        util.add(g.edges, midiEdge('fxP1', 'fxC'))
        util.add(g.edges, midiEdge('fxP2', 'fxC'))
      end)
      apply(wm)
      t.truthy(slotOf(h, trackA, 'JS:Continuum Utility'), 'Merge CU present after first apply')
      -- Drop fxP2's feed: fxC keeps a single feeder, so the union CU retracts.
      wm:mutate(function(g)
        local newEdges = {}
        for _, e in ipairs(g.edges) do
          if not (e.from == 'fxP2' and e.to == 'fxC') then util.add(newEdges, e) end
        end
        g.edges = newEdges
      end)
      apply(wm)
      local cuTotal = 0
      for s = 0, h.reaper.TrackFX_GetCount(trackA) - 1 do
        if (select(2, h.reaper.TrackFX_GetFXName(trackA, s))) == 'JS:Continuum Utility' then
          cuTotal = cuTotal + 1
        end
      end
      t.eq(cuTotal, 0, 'merge CU gone after the feeder dropped')
      t.truthy(slotOf(h, trackA, 'JS:c'), 'consumer fx still live')
      t.eq(mergeStamp(wm), nil, 'merge stamp cleared')
    end,
  },
}
