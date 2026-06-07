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

local function fx(ident)
  return { kind='fx', fxIdent=ident, pos={x=0,y=0},
           ports={audio={ins=1,outs=1}, midi={ins=1,outs=1}} }
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
    name = 'undo: applyOps mirrors wiringGraph onto scratch P_EXT',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      wm:enableLive()
      wm:mutate(function(g)
        g.nodes.s = source('guid-A')
        g.nodes.f = fx('JS:foo')
        util.add(g.edges, audioEdge('s', 'f'))
        util.add(g.edges, audioEdge('f', 'master'))
      end)
      local mirrored = h.cm:readTrackKey(scratchOf(h, wm), 'wiringGraph')
      t.truthy(mirrored, 'scratch P_EXT carries wiringGraph')
      t.truthy(mirrored.nodes.f, 'mirror has the fx node')
      t.truthy(mirrored.nodes.f.fxId, 'mirror includes stamped fxId')
    end,
  },
  {
    name = 'undo: scratch P_EXT rewinds → pollUndo restores project tier and fires load',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      wm:enableLive()
      -- Pre-undo state: graph has just source.
      wm:mutate(function(g) g.nodes.s = source('guid-A') end)
      local preUndoGraph = util.deepClone(h.cm:readTrackKey(scratchOf(h, wm), 'wiringGraph'))

      -- Extend the graph (this is the "gesture" the user will then undo).
      wm:mutate(function(g)
        g.nodes.f = fx('JS:foo')
        util.add(g.edges, audioEdge('s', 'f'))
        util.add(g.edges, audioEdge('f', 'master'))
      end)
      t.truthy(wm:graph().nodes.f, 'gesture landed')

      -- Simulate REAPER undo: scratch P_EXT rewinds to its pre-gesture content.
      -- (In production, Undo_BeginBlock captures the P_EXT change inside the
      -- applyOps block, and cmd-Z rewinds it.)
      h.cm:writeTrackKey(scratchOf(h, wm), 'wiringGraph', preUndoGraph)

      local loadFires = 0
      wm:subscribe('wiringChanged', function(payload)
        if payload.kind == 'load' then loadFires = loadFires + 1 end
      end)
      wm:pollUndo()
      t.eq(loadFires, 1, 'pollUndo fired wiringChanged{kind=load}')
      t.eq(wm:graph().nodes.f, nil, 'graph no longer carries the undone fx node')
      t.truthy(wm:graph().nodes.s,   'graph still carries pre-gesture source')
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
