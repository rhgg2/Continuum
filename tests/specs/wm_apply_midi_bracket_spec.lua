local t    = require('support')
local util = require('util')

-- 3c.3a.2 apply round-trip: non-bus-aware JSFX whose midi input arrives on
-- bus N≠0 has BusPark + BusRestore CU bridges spliced around it on the host
-- track, with their guids stamped back onto the consumer node so subsequent
-- reconciles read them as target.fxGuid (idempotent).

local function mkWm(harness)
  local h  = harness.mk()
  h.reaper:setFxParamNames('JS:Continuum Utility', { 'mode', 'gain', 'bus' })
  local wm = util.instantiate('wiringManager', { cm = h.cm })
  wm:load()
  return h, wm
end

local function seedSource(h, guid)
  local track = { __label = 'src-' .. guid }
  table.insert(h.reaper._state.projectTracks, track)
  h.reaper._state.trackGuids[track] = guid
  h.cm:writeTrackKey(track, 'wiringHostKind', 'sourceTrack')
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
    if h.cm:readTrackKey(tr, 'wiringHostKind') == 'newTrack' then return tr end
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

return {
  {
    name = 'bracket apply: BusSwap + consumer + BusSwap land on the newTrack',
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
      t.eq(h.reaper.TrackFX_GetCount(track), 3, 'BusSwap + fxC + BusSwap')
      local in0, gIn   = fxAt(h, track, 0)
      local mid, gMid  = fxAt(h, track, 1)
      local out, gOut  = fxAt(h, track, 2)
      t.eq(in0, 'JS:Continuum Utility', 'slot 0 = BusSwap CU (in)')
      t.eq(mid, 'JS:c',                  'slot 1 = consumer fx')
      t.eq(out, 'JS:Continuum Utility', 'slot 2 = BusSwap CU (out)')
      -- params pushed: mode=2 (busSwap) and bus=1 on both brackets.
      local inSets  = paramSetsOn(h, track, 0)
      local outSets = paramSetsOn(h, track, 2)
      t.eq(inSets[0],  2, 'in bracket: busSwap mode')
      t.eq(inSets[2],  1, 'in bracket: bus = 1 (sB receiver claim)')
      t.eq(outSets[0], 2, 'out bracket: busSwap mode')
      t.eq(outSets[2], 1, 'out bracket: bus = 1')
      local node = wm:graph().nodes.fxC
      t.eq(node.midiInBracketGuid,  gIn,  'bracketIn guid stamped onto consumer')
      t.eq(node.midiOutBracketGuid, gOut, 'bracketOut guid stamped onto consumer')
      t.eq(node.fxGuid, gMid, 'consumer node guid still the mid slot')
    end,
  },
  {
    name = 'bracket apply: idempotent — second reconcile drops no setFXChain op',
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
    name = 'bracket apply: dropping one sender removes the brackets on re-apply',
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
      t.eq(h.reaper.TrackFX_GetCount(track), 3, 'brackets present after first apply')
      -- Drop the sB feeder so fxC's only input is sA on bus 0 → bracket no longer needed.
      wm:mutate(function(g)
        local newEdges = {}
        for _, e in ipairs(g.edges) do
          if not (e.from == 'sB' and e.to == 'fxC') then util.add(newEdges, e) end
        end
        g.edges = newEdges
      end)
      apply(wm)
      -- fxC's srcSet shrinks to {sA} so it migrates onto sA's sourceTrack;
      -- count total CU + fxC instances across the project to assert structurally.
      local cuTotal, fxCTotal = 0, 0
      for i = 0, h.reaper.CountTracks(0) - 1 do
        local tr = h.reaper.GetTrack(0, i)
        for s = 0, h.reaper.TrackFX_GetCount(tr) - 1 do
          local _, ident = h.reaper.TrackFX_GetFXName(tr, s)
          if ident == 'JS:Continuum Utility' then cuTotal = cuTotal + 1 end
          if ident == 'JS:c'                 then fxCTotal = fxCTotal + 1 end
        end
      end
      t.eq(cuTotal,  0, 'brackets gone after sB removed')
      t.eq(fxCTotal, 1, 'consumer fx still live (moved hosts)')
      t.eq(wm:graph().nodes.fxC.midiInBracketGuid,  nil, 'bracketIn stamp cleared')
      t.eq(wm:graph().nodes.fxC.midiOutBracketGuid, nil, 'bracketOut stamp cleared')
    end,
  },
}
