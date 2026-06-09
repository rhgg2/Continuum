local t    = require('support')
local util = require('util')

local function mkWm(harness)
  local h  = harness.mk()
  local rm = util.instantiate('routingManager')
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
           ports={audio={ins=opts.ins or 1, outs=opts.outs or 1}, midi={ins=1, outs=1}} }
end

local function audioEdge(from, to)
  return { type='audio', from=from, to=to }
end

local function scratchOf(h, wm)
  local id = wm:scratchId()
  for _, tr in ipairs(h.reaper._state.projectTracks) do
    if h.reaper.GetTrackGUID(tr) == id then return tr end
  end
end

return {
  {
    name = 'undo: applyOps mirrors the wiringTracks addressing onto scratch P_EXT',
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
      -- The graph lives in REAPER routing; only the trackKey→id addressing rides scratch P_EXT.
      -- The two-source fan-in parks f on a newTrack, so wiringTracks carries that key.
      local tracks = h.cm:readTrackKey(scratchOf(h, wm), 'wiringTracks')
      t.truthy(tracks and next(tracks), 'scratch P_EXT carries the wiringTracks mirror')
    end,
  },
  {
    name = 'undo: scratch P_EXT diverges → pollUndo re-reads REAPER and fires load',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      wm:enableLive()
      wm:mutate(function(g) g.nodes.s = source('guid-A') end)

      -- Simulate REAPER undo rewinding the addressing mirror: the scratch chunk changes,
      -- which is what pollUndo detects.
      h.cm:writeTrackKey(scratchOf(h, wm), 'wiringTracks', { ['x|y'] = 'guid-z' })

      local loadFires = 0
      wm:subscribe('wiringChanged', function(payload)
        if payload.kind == 'load' then loadFires = loadFires + 1 end
      end)
      wm:pollUndo()
      t.eq(loadFires, 1, 'pollUndo fired wiringChanged{kind=load} on divergence')
      t.truthy(wm:graph().nodes['guid-A'], 'graph re-read from REAPER carries the source track')
    end,
  },
  {
    name = 'undo: pollUndo is no-op when scratch matches lastScratchRaw',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      wm:enableLive()
      wm:mutate(function(g) g.nodes.s = source('guid-A') end)
      local loadFires = 0
      wm:subscribe('wiringChanged', function(payload)
        if payload.kind == 'load' then loadFires = loadFires + 1 end
      end)
      wm:pollUndo()
      wm:pollUndo()
      t.eq(loadFires, 0, 'steady state: no spurious load fires')
    end,
  },
  {
    name = 'undo: scratch track deletion → pollUndo clears handle + fires load',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      wm:enableLive()
      wm:mutate(function(g) g.nodes.s = source('guid-A') end)
      local scratch = scratchOf(h, wm)
      t.truthy(scratch, 'scratch exists post-apply')

      -- External deletion (manual delete in REAPER, or undo past scratch creation).
      for i, tr in ipairs(h.reaper._state.projectTracks) do
        if tr == scratch then table.remove(h.reaper._state.projectTracks, i); break end
      end

      local loadFires = 0
      wm:subscribe('wiringChanged', function(payload)
        if payload.kind == 'load' then loadFires = loadFires + 1 end
      end)
      wm:pollUndo()
      t.eq(loadFires, 1, 'fired load on scratch loss so live mode reconciles + recreates scratch')
    end,
  },
}
