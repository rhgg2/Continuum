local t    = require('support')
local util = require('util')

local FX = { name = 'ReaEQ', ident = 'VST3:ReaEQ (Cockos)' }

local function mkWv(harness)
  local h  = harness.mk()
  local rm = util.instantiate('routingManager')
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
  local wv = util.instantiate('wiringView', { cm = h.cm, wm = wm })
  return h, wv
end

local function fxNodes(g)
  local out = {}
  for id, n in pairs(g.nodes) do
    if n.kind == 'fx' then out[id] = n end
  end
  return out
end

local function fxCount(g)
  local n = 0
  for _ in pairs(fxNodes(g)) do n = n + 1 end
  return n
end

-- The lone source node a generator addFx spawns (read-era id == its track guid).
local function sourceId(wv)
  for id, n in pairs(wv:graph().nodes) do
    if n.kind == 'source' then return id end
  end
end

return {
  {
    name = 'addFx mints a node keyed by its rm fxId, writes logical pos',
    run = function(harness)
      local _, wv = mkWv(harness)
      local id = wv:addFx(12, -34, FX)
      t.truthy(id, 'addFx returns the new node id')
      local n = wv:graph().nodes[id]
      t.truthy(n, 'node present under the returned id')
      t.eq(n.kind, 'fx')
      t.eq(n.fxId, id, 'node id is its fxId (read-era identity)')
      t.eq(n.pos.x, 12)
      t.eq(n.pos.y, -34)
      t.eq(n.fxIdent,   FX.ident, 'ident from picker record')
      t.eq(n.fxDisplay, FX.name,  'display name from picker record')
      t.eq(n.ports.audio.ins,  1, 'stereo in')
      t.eq(n.ports.audio.outs, 1, 'stereo out')
    end,
  },
  {
    name = 'addFx on generator (ins=0) auto-spawns source node, midi edge, and REAPER track',
    run = function(harness)
      local h, wv = mkWv(harness)
      h.reaper:setFxIO('VST3:Massive', { ins = 0, outs = 2 })
      local fxId = wv:addFx(50, -10, { name = 'Massive', ident = 'VST3:Massive' })
      t.truthy(fxId)
      local g = wv:graph()
      t.eq(g.nodes[fxId].kind, 'fx', 'fx node under the returned id')
      local srcId = sourceId(wv)
      t.truthy(srcId, 'a source node spawned alongside the fx')
      t.truthy(g.nodes[srcId].trackId, 'source bound to a track guid')
      t.eq(g.nodes[srcId].trackId, srcId, 'source node id is its track guid')
      t.eq(g.nodes[srcId].displayName, 'Massive', 'source carries fx-name snapshot for the label')
      local sourceView
      for _, nv in ipairs(wv:nodeViews()) do
        if nv.id == srcId then sourceView = nv end
      end
      t.eq(sourceView.label, 'Massive', 'source label reads the live REAPER track name')
      t.eq(sourceView.category, 'source', 'source gets its own colour category')
    end,
  },
  {
    name = 'source label tracks REAPER renames (live, not snapshotted)',
    run = function(harness)
      local h, wv = mkWv(harness)
      h.reaper:setFxIO('VST3:Massive', { ins = 0, outs = 2 })
      wv:addFx(0, 0, { name = 'Massive', ident = 'VST3:Massive' })
      local srcId = sourceId(wv)
      local guid  = wv:graph().nodes[srcId].trackId
      local track
      for i = 0, math.floor(reaper.CountTracks(0)) - 1 do
        local tr = reaper.GetTrack(0, i)
        if reaper.GetTrackGUID(tr) == guid then track = tr end
      end
      reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', 'Renamed', true)
      local sourceView
      for _, nv in ipairs(wv:nodeViews()) do
        if nv.id == srcId then sourceView = nv end
      end
      t.eq(sourceView.label, 'Renamed', 'rename propagates without re-mutating the graph')
    end,
  },
  {
    name = 'addFx on generator pins fx pos, fallback source pos, and a single midi edge',
    run = function(harness)
      local h, wv = mkWv(harness)
      h.reaper:setFxIO('VST3:Massive', { ins = 0, outs = 2 })
      local tracksBefore = reaper.CountTracks(0)
      local fxId = wv:addFx(50, -10, { name = 'Massive', ident = 'VST3:Massive' })
      t.truthy(fxId)
      local g     = wv:graph()
      local srcId = sourceId(wv)
      t.eq(g.nodes[fxId].pos.x, 50);  t.eq(g.nodes[fxId].pos.y, -10)
      t.eq(g.nodes[srcId].pos.x, -90, 'fallback source pos = (fx.x - 140, fx.y)')
      t.eq(g.nodes[srcId].pos.y, -10)
      t.eq(#g.edges, 1)
      t.eq(g.edges[1].type, 'midi')
      t.eq(g.edges[1].from, srcId)
      t.eq(g.edges[1].to,   fxId)
      t.eq(reaper.CountTracks(0), tracksBefore + 2, 'scratch + new source track')
    end,
  },
  {
    name = 'addFx on generator honours opts.sourcePos for the spawned source',
    run = function(harness)
      local h, wv = mkWv(harness)
      h.reaper:setFxIO('VST3:Massive', { ins = 0, outs = 2 })
      t.truthy(wv:addFx(80, 40, { name = 'Massive', ident = 'VST3:Massive' },
                        { sourcePos = { x = 10, y = -5 } }))
      local g     = wv:graph()
      local srcId = sourceId(wv)
      t.eq(g.nodes[srcId].pos.x, 10); t.eq(g.nodes[srcId].pos.y, -5)
    end,
  },
  {
    name = 'successive addFx calls mint distinct ids and leave master alone',
    run = function(harness)
      local _, wv = mkWv(harness)
      local a = wv:addFx(0, 0, FX); local b = wv:addFx(10, 10, FX); local c = wv:addFx(20, 20, FX)
      local g = wv:graph()
      t.eq(fxCount(g), 3,                'three fx nodes')
      t.truthy(g.nodes[a] and g.nodes[b] and g.nodes[c], 'each returned id present')
      t.truthy(a ~= b and b ~= c and a ~= c, 'ids are distinct')
      t.eq(g.nodes.master.kind, 'master', 'master untouched')
    end,
  },
  {
    name = 'moveNodes writes pos for one node via wm:mutate',
    run = function(harness)
      local _, wv = mkWv(harness)
      local id = wv:addFx(0, 0, FX)
      t.truthy(wv:moveNodes{ [id] = { x = 50, y = -25 } })
      local g = wv:graph()
      t.eq(g.nodes[id].pos.x, 50)
      t.eq(g.nodes[id].pos.y, -25)
    end,
  },
  {
    name = 'moveNodes writes several ids atomically in one mutate',
    run = function(harness)
      local _, wv = mkWv(harness)
      local a = wv:addFx(0, 0, FX); local b = wv:addFx(0, 0, FX); local c = wv:addFx(0, 0, FX)
      t.truthy(wv:moveNodes{
        [a] = { x = 10, y = 20 },
        [b] = { x = 30, y = 40 },
        [c] = { x = 50, y = 60 },
      })
      local g = wv:graph()
      t.eq(g.nodes[a].pos.x, 10); t.eq(g.nodes[a].pos.y, 20)
      t.eq(g.nodes[b].pos.x, 30); t.eq(g.nodes[b].pos.y, 40)
      t.eq(g.nodes[c].pos.x, 50); t.eq(g.nodes[c].pos.y, 60)
    end,
  },
  {
    name = 'moveNodes skips missing ids; existing ids still land',
    run = function(harness)
      local _, wv = mkWv(harness)
      local id = wv:addFx(0, 0, FX)
      t.truthy(wv:moveNodes{
        [id]  = { x = 7, y = 8 },
        ghost = { x = 1, y = 2 },
      })
      local g = wv:graph()
      t.eq(g.nodes[id].pos.x, 7)
      t.eq(g.nodes[id].pos.y, 8)
      t.truthy(g.nodes.ghost == nil, 'missing id stayed missing')
    end,
  },
  {
    name = 'moveNodes with empty map is a no-op (mutate still succeeds)',
    run = function(harness)
      local _, wv = mkWv(harness)
      wv:addFx(11, 22, FX)
      local before = wv:graph()
      t.truthy(wv:moveNodes{})
      local after = wv:graph()
      t.deepEq(after.nodes, before.nodes)
    end,
  },
  {
    name = 'listInstalledFX is a passthrough to wm',
    run = function(harness)
      local _, wv = mkWv(harness)
      reaper.EnumInstalledFX = function(i)
        if i == 0 then return true, 'VST3: ReaEQ (Cockos)',   'VST3:ReaEQ (Cockos)'   end
        if i == 1 then return true, 'VST3: ReaComp (Cockos)', 'VST3:ReaComp (Cockos)' end
        return false
      end
      local list = wv:listInstalledFX()
      t.eq(#list, 2)
      t.eq(list[1].name,  'VST3: ReaEQ (Cockos)',   'raw name passes through')
      t.eq(list[2].ident, 'VST3:ReaComp (Cockos)',  'ident untouched')
    end,
  },
  {
    name = 'selection starts empty, setSelection writes the id set',
    run = function(harness)
      local _, wv = mkWv(harness)
      t.deepEq(wv:selection(), {}, 'fresh selection is empty')
      wv:setSelection{ n1 = true, n2 = true }
      t.deepEq(wv:selection(), { n1 = true, n2 = true })
    end,
  },
  {
    name = 'setSelection replaces wholesale (no merge with previous)',
    run = function(harness)
      local _, wv = mkWv(harness)
      wv:setSelection{ n1 = true, n2 = true }
      wv:setSelection{ n3 = true }
      t.deepEq(wv:selection(), { n3 = true }, 'previous ids dropped')
    end,
  },
  {
    name = 'setSelection{} clears',
    run = function(harness)
      local _, wv = mkWv(harness)
      wv:setSelection{ n1 = true }
      wv:setSelection{}
      t.deepEq(wv:selection(), {})
    end,
  },
  {
    name = 'source node exposes midi out but no midi in (never a midi sink)',
    run = function(harness)
      local h, wv = mkWv(harness)
      h.reaper:setFxIO('VST3:Massive', { ins = 0, outs = 2 })
      wv:addFx(0, 0, { name = 'Massive', ident = 'VST3:Massive' })
      local srcId = sourceId(wv)
      local sourceView
      for _, nv in ipairs(wv:nodeViews()) do
        if nv.id == srcId then sourceView = nv end
      end
      t.eq(#sourceView.outs.midi, 1, 'source has one midi out')
      t.eq(#sourceView.ins.midi,  0, 'source has no midi in (no drop-target band)')
    end,
  },
  {
    name = 'setSelection defensive-copies its argument',
    run = function(harness)
      local _, wv = mkWv(harness)
      local input = { n1 = true }
      wv:setSelection(input)
      input.n2 = true                                  -- mutate caller's table after the call
      t.deepEq(wv:selection(), { n1 = true }, 'wv view not aliased to caller table')
    end,
  },
  {
    name = 'wiredPorts on fresh graph is empty for either direction',
    run = function(harness)
      local _, wv = mkWv(harness)
      local id = wv:addFx(0, 0, FX)
      t.deepEq(wv:wiredPorts(id, 'out'), {})
      t.deepEq(wv:wiredPorts(id, 'in'),  {})
    end,
  },
  {
    name = 'wiredPorts("out") reflects fromPort for audio edges sourced on the node',
    run = function(harness)
      local h, wv = mkWv(harness)
      h.reaper:setFxIO('VST3:Wide', { ins = 20, outs = 20 })  -- 10 stereo ports each (pins/2)
      local WIDE = { name = 'Wide', ident = 'VST3:Wide' }
      local a = wv:addFx(0, 0, WIDE); local b = wv:addFx(0, 0, WIDE)
      t.truthy(wv:addWire{ type = 'audio', from = a, to = b, fromPort = 3, toPort = 1 })
      t.truthy(wv:addWire{ type = 'audio', from = a, to = b, fromPort = 7, toPort = 2 })
      t.deepEq(wv:wiredPorts(a, 'out'), { [3] = true, [7] = true })
    end,
  },
  {
    name = 'wiredPorts("in") reflects toPort for audio edges sinking into the node',
    run = function(harness)
      local h, wv = mkWv(harness)
      h.reaper:setFxIO('VST3:Wide', { ins = 20, outs = 20 })  -- 10 stereo ports each
      local WIDE = { name = 'Wide', ident = 'VST3:Wide' }
      local a = wv:addFx(0, 0, WIDE); local b = wv:addFx(0, 0, WIDE)
      t.truthy(wv:addWire{ type = 'audio', from = a, to = b, fromPort = 1, toPort = 5 })
      t.deepEq(wv:wiredPorts(b, 'in'),  { [5] = true })
      t.deepEq(wv:wiredPorts(b, 'out'), {})
    end,
  },
  {
    name = 'wiredPorts ignores midi edges',
    run = function(harness)
      local h, wv = mkWv(harness)
      h.reaper:setFxIO('VST3:Massive', { ins = 0, outs = 2 })
      local fxId = wv:addFx(0, 0, { name = 'Massive', ident = 'VST3:Massive' })  -- fx + source + midi edge
      local srcId = sourceId(wv)
      t.deepEq(wv:wiredPorts(srcId, 'out'), {}, 'midi-only edge contributes no audio port')
      t.deepEq(wv:wiredPorts(fxId,  'in'),  {})
    end,
  },
  {
    name = 'wiredPorts ignores edges incident on other nodes',
    run = function(harness)
      local h, wv = mkWv(harness)
      h.reaper:setFxIO('VST3:Wide', { ins = 20, outs = 20 })  -- 10 stereo ports each
      local WIDE = { name = 'Wide', ident = 'VST3:Wide' }
      local a = wv:addFx(0, 0, WIDE); local b = wv:addFx(0, 0, WIDE); local c = wv:addFx(0, 0, WIDE)
      t.truthy(wv:addWire{ type = 'audio', from = b, to = c, fromPort = 4, toPort = 1 })
      t.deepEq(wv:wiredPorts(a, 'out'), {})
      t.deepEq(wv:wiredPorts(a, 'in'),  {})
    end,
  },
  {
    name = 'wireViews stamps fromKind / fromLabel from the from-node',
    run = function(harness)
      local h, wv = mkWv(harness)
      h.reaper:setFxIO('VST3:Massive', { ins = 0, outs = 2 })
      local genFx = wv:addFx(0, 0, { name = 'Massive', ident = 'VST3:Massive' })  -- fx + source, midi src->genFx
      local srcId = sourceId(wv)
      local fx2   = wv:addFx(60, 0, FX)                                           -- audio-in fx
      t.truthy(wv:addWire{ type = 'audio', from = genFx, to = fx2 })
      local byPair = {}
      for _, w in ipairs(wv:wireViews()) do byPair[w.from .. '->' .. w.to] = w end

      local srcWire = byPair[srcId .. '->' .. genFx]
      t.eq(srcWire.fromKind,  'source',  'source-origin edge stamped fromKind=source')
      t.eq(srcWire.fromLabel, 'Massive', 'fromLabel is the live source track name')

      local fxWire = byPair[genFx .. '->' .. fx2]
      t.eq(fxWire.fromKind,  'fx',       'fx-origin edge stamped fromKind=fx')
      t.eq(fxWire.fromLabel, 'Massive',  'fromLabel mirrors the gen fx display name')
    end,
  },
}
