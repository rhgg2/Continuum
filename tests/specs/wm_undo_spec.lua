local t    = require('support')
local util = require('util')

local function mkWm(harness)
  local h  = harness.mk()
  local rm = util.instantiate('routingManager', { ds = h.ds })
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
  wm:load()
  return h, wm
end

local function seedSource(h, guid)
  local track = { __label = 'src-' .. guid }
  table.insert(h.reaper._state.projectTracks, track)
  h.reaper._state.trackGuids[track] = guid
  return track
end

local function source(guid)
  return { kind='source', trackId=guid, pos={x=0,y=0},
           ports={audio={ins=0,outs=1}, midi={ins=0,outs=1}} }
end

-- Mint an fx on scratch (as wm:addFxNode does) so the node enters the graph with a live
-- guid; reconcile then MOVES it onto its track. Called inside the mutator.
local function mintFx(wm, ident, opts)
  opts = opts or {}
  local r = wm:instantiateFxOnScratch(ident)
  return { kind='fx', fxIdent=ident, fxId=r.fxId, pos={x=0,y=0},
           ports={audio={ins=opts.ins or 1, outs=opts.outs or 1}, midi={ins=0, outs=0}} }
end

local function audioEdge(from, to)
  return { type='audio', from=from, to=to }
end

return {
  {
    name = 'addressing: each newTrack carries its trackKey on its own meta (recovered by snapshot)',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      seedSource(h, 'guid-B')
      wm:enableLive()
      wm:mutate(function(g)
        g.nodes.sA = source('guid-A')
        g.nodes.sB = source('guid-B')
        g.nodes.f  = mintFx(wm, 'JS:foo', { ins=2 })
        util.add(g.edges, { type='audio', from='sA', to='f', toPort=1 })
        util.add(g.edges, { type='audio', from='sB', to='f', toPort=2 })
      end)
      -- The two-source fan-in parks f on a newTrack. Its trackKey rides the track's own meta
      -- (no central map, no scratch mirror); snapshot reads it back to re-key the entry.
      local newTrackKey
      for key, entry in pairs(wm:snapshot()) do
        if entry.trackKind == 'newTrack' then newTrackKey = key end
      end
      t.truthy(newTrackKey, 'snapshot recovered a newTrack keyed from its own meta trackKey')
    end,
  },
  {
    name = 'syncExternal: project state moved under us → reread + fire load',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      wm:enableLive()
      wm:mutate(function(g) g.nodes.s = source('guid-A') end)

      local loadFires = 0
      wm:subscribe('wiringChanged', function(payload)
        if payload.kind == 'load' then loadFires = loadFires + 1 end
      end)
      -- Any external edit (undo/redo or a manual mixer change) moves the project state count.
      h.reaper._state.projStateCount = h.reaper._state.projStateCount + 1
      wm:syncExternal()
      t.eq(loadFires, 1, 'syncExternal fired wiringChanged{kind=load} on the external change')
      t.truthy(wm:graph().nodes['guid-A'], 'graph re-read from REAPER carries the source track')
    end,
  },
  {
    name = 'syncExternal: no-op when the state count has not moved (our writes are baselined)',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      wm:enableLive()
      wm:mutate(function(g) g.nodes.s = source('guid-A') end)
      local loadFires = 0
      wm:subscribe('wiringChanged', function(payload)
        if payload.kind == 'load' then loadFires = loadFires + 1 end
      end)
      wm:syncExternal()
      wm:syncExternal()
      t.eq(loadFires, 0, 'our own apply rebaselined the count; no spurious reread')
    end,
  },
}
