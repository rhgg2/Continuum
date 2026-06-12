local t    = require('support')
local util = require('util')

local function mkWm(harness, opts)
  local h  = harness.mk(opts)
  local rm = util.instantiate('routingManager')
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
  return h, wm, rm
end

-- Seed a source node directly (no REAPER track) so wiring/validate tests stay
-- fake-light; deleteBus and validate never touch the source's track.
local function seedSource(wm, id)
  wm:mutate(function(g)
    g.nodes[id] = { kind = 'source', trackId = id, pos = { x = 0, y = 0 },
                    ports = { audio = { ins = 0, outs = 1 }, midi = { ins = 0, outs = 1 } } }
  end)
end

-- Live-harness helpers for the reconcile-driven tests below.
local function seedTrack(h, guid)
  local track = { __label = 'src-' .. guid }
  table.insert(h.reaper._state.projectTracks, track)
  h.reaper._state.trackGuids[track] = guid
end

local function mintFx(wm, ident)
  local r = wm:instantiateFxOnScratch(ident)
  return { kind = 'fx', fxIdent = ident, fxId = r.fxId, pos = { x = 0, y = 0 },
           ports = { audio = { ins = 1, outs = 1 }, midi = { ins = 0, outs = 0 } } }
end

return {
  {
    name = 'addBusNode mints a placed, unwired buss node + decoration record',
    run = function(harness)
      local _, wm, rm = mkWm(harness)
      local id = wm:addBusNode({ x = 40, y = 60 })
      t.eq(id, 'bus-1', 'first buss id')
      local node = wm:graph().nodes[id]
      t.truthy(node,            'buss node present')
      t.eq(node.kind, 'bus')
      t.eq(node.orient, 'V')
      t.eq(node.pos.x, 40); t.eq(node.pos.y, 60)
      t.eq(node.ports.audio.ins,  1, 'one audio in port')
      t.eq(node.ports.audio.outs, 1, 'one audio out port')
      local rec = rm:meta('bus', id)
      t.truthy(rec,            'record persisted to the bus store')
      t.eq(rec.pos.x, 40)
      t.eq(rec.orient, 'V')
    end,
  },
  {
    name = 'buss ids increment and never collide',
    run = function(harness)
      local _, wm = mkWm(harness)
      t.eq(wm:addBusNode({ x = 0, y = 0 }), 'bus-1')
      t.eq(wm:addBusNode({ x = 0, y = 0 }), 'bus-2')
      t.eq(wm:addBusNode({ x = 0, y = 0 }), 'bus-3')
    end,
  },
  {
    name = 'moveNodes persists a buss pos to the bus store (not via persistNodeMeta)',
    run = function(harness)
      local _, wm, rm = mkWm(harness)
      local id = wm:addBusNode({ x = 0, y = 0 })
      wm:moveNodes({ [id] = { x = 120, y = 200 } })
      t.eq(wm:graph().nodes[id].pos.x, 120, 'graph pos updated')
      local rec = rm:meta('bus', id)
      t.eq(rec.pos.x, 120, 'store pos updated')
      t.eq(rec.pos.y, 200)
      t.eq(rec.orient, 'V',  'patch-merge left orient intact')
    end,
  },
  {
    name = 'deleteBus removes the node, its incident edges, and clears the record',
    run = function(harness)
      local _, wm, rm = mkWm(harness)
      local bus = wm:addBusNode({ x = 50, y = 0 })
      seedSource(wm, 'guid-s')
      wm:mutate(function(g)
        util.add(g.edges, { type = 'audio', from = 'guid-s', to = bus })
      end)
      t.truthy(rm:meta('bus', bus), 'record present before delete')
      t.truthy(wm:deleteBus(bus),   'delete reports success')
      t.eq(wm:graph().nodes[bus], nil, 'buss node gone')
      t.eq(rm:meta('bus', bus),   nil, 'record cleared')
      for _, e in ipairs(wm:graph().edges) do
        t.truthy(e.from ~= bus and e.to ~= bus, 'no incident edge survives')
      end
      t.truthy(wm:graph().nodes['guid-s'], 'source survives')
    end,
  },
  {
    name = 'deleteBus refuses a non-buss node',
    run = function(harness)
      local _, wm = mkWm(harness)
      seedSource(wm, 'guid-s')
      t.falsy(wm:deleteBus('guid-s'),       'refuses a source node')
      t.truthy(wm:graph().nodes['guid-s'],  'source untouched')
    end,
  },
  {
    name = 'a wired buss graph passes DAG.validate (source -> bus -> master)',
    run = function(harness)
      local _, wm = mkWm(harness)
      local bus = wm:addBusNode({ x = 50, y = 0 })
      seedSource(wm, 'guid-s')
      local ok, err = wm:mutate(function(g)
        util.add(g.edges, { type = 'audio', from = 'guid-s', to = bus })
        util.add(g.edges, { type = 'audio', from = bus, to = 'master' })
      end)
      t.truthy(ok, 'wired buss validates: ' .. tostring(err and err.code))
    end,
  },
  {
    name = 'live reconcile stamps record.trackId for a matrix buss; sub-threshold clears it',
    run = function(harness)
      local h, wm, rm = mkWm(harness)
      wm.readJSFXContent = function() return 'desc:plain\n@sample\nspl0 *= 1;\n' end
      seedTrack(h, 'guid-A'); seedTrack(h, 'guid-B')
      wm:load()  -- read mints source nodes guid-A/guid-B from the live tracks
      wm:enableLive()
      local bus = wm:addBusNode({ x = 10, y = 20 })
      t.falsy(rm:meta('bus', bus).trackId, 'unwired buss carries no track')
      wm:mutate(function(g)
        g.nodes.f = mintFx(wm, 'JS:foo')
        -- sources feed only the buss: a direct send parallel to a crossing
        -- would pre-merge into a CU the stubbed JSFX scan can't host
        local kept = {}
        for _, e in ipairs(g.edges) do
          if e.to ~= 'master' then util.add(kept, e) end
        end
        g.edges = kept
        util.add(g.edges, { type = 'audio', from = 'guid-A', to = bus })
        util.add(g.edges, { type = 'audio', from = 'guid-B', to = bus })
        util.add(g.edges, { type = 'audio', from = bus, to = 'master' })
        util.add(g.edges, { type = 'audio', from = bus, to = 'f' })
        util.add(g.edges, { type = 'audio', from = 'f', to = 'master' })
      end)
      local rec = rm:meta('bus', bus)
      t.truthy(rec.trackId, 'matrix buss record carries its summing track guid')
      t.eq(rec.orient, 'V', 'stamp patch-merged: rest of record intact')
      -- read back from live routing: the flagged track mints the node under the
      -- synthetic id, decoration from the bus store
      local rg = wm:read()
      t.eq(rg.nodes[bus].kind, 'bus')
      t.eq(rg.nodes[bus].pos.x, 10)
      t.eq(rg.nodes[bus].orient, 'V')
      -- dropping f's leg leaves the buss 2x1 — spliced; the reconcile that
      -- demolishes the track also clears the stamp
      wm:mutate(function(g)
        local kept = {}
        for _, e in ipairs(g.edges) do
          if e.from ~= 'f' and e.to ~= 'f' then util.add(kept, e) end
        end
        g.edges = kept
      end)
      t.falsy(rm:meta('bus', bus).trackId, 'sub-threshold buss record cleared')
      -- and the read mints it back from the record's taps, crossings consumed
      local rg2 = wm:read()
      t.eq(rg2.nodes[bus].kind, 'bus', 'sub-threshold buss minted from taps')
      for _, e in ipairs(rg2.edges) do
        t.truthy(e.to ~= 'master' or e.from == bus,
                 'crossing sends read back as taps, not direct wires')
      end
    end,
  },
  {
    name = 'fan tap pokes ride the splice: 1:1 on the many side, group fader on the lone side',
    run = function(harness)
      local h, wm, rm = mkWm(harness)
      wm.readJSFXContent = function() return 'desc:plain\n@sample\nspl0 *= 1;\n' end
      seedTrack(h, 'guid-A'); seedTrack(h, 'guid-B')
      wm:load()
      wm:enableLive()
      local bus = wm:addBusNode({ x = 0, y = 0 })
      wm:mutate(function(g)
        g.nodes.f = mintFx(wm, 'JS:foo')
        util.add(g.edges, { type = 'audio', from = 'guid-A', to = bus, ops = { gain = 0.5 } })
        util.add(g.edges, { type = 'audio', from = 'guid-B', to = bus })
        util.add(g.edges, { type = 'audio', from = bus, to = 'f', ops = { gain = 0.75 } })
        util.add(g.edges, { type = 'audio', from = 'f', to = 'master' })
      end)
      local idxA, idxLone
      for i, e in ipairs(wm:graph().edges) do
        if e.from == 'guid-A' and e.to == bus then idxA = i end
        if e.from == bus and e.to == 'f' then idxLone = i end
      end
      local pokes = {}
      local realSetSendGain = rm.setSendGain
      rm.setSendGain = function(self, src, dst, gain)
        util.add(pokes, { src = src, gain = gain })
        return realSetSendGain(self, src, dst, gain)
      end
      t.truthy(wm:pokeEdgeGain(idxA, 0.25), 'many-side poke lands')
      t.eq(#pokes, 1, 'exactly its one crossing')
      t.eq(pokes[1].src, 'guid-A')
      t.eq(pokes[1].gain, 0.1875, 'product 0.25 × 0.75')
      pokes = {}
      t.truthy(wm:pokeEdgeGain(idxLone, 0.5), 'lone-side poke is the group fader')
      t.eq(#pokes, 2, 'fans out to every crossing')
      local bySrc = {}
      for _, p in ipairs(pokes) do bySrc[p.src] = p.gain end
      t.eq(bySrc['guid-A'], 0.25, '0.5 tap × 0.5 drag')
      t.eq(bySrc['guid-B'], 0.5,  'unset tap defaults to 1')
      -- commit the lone gain: products mirrored, the next reconcile rewrites nothing
      t.truthy(wm:fastGainCommit(idxLone, 0.5))
      t.eq(rm:meta('bus', bus).outs[1].gain, 0.5, 'tap mirror follows the gain commit')
      t.eq(#wm:diff(wm:targetState(), wm:snapshot()), 0,
           'committed products mirrored into the model')
    end,
  },
  {
    name = 'insertBus re-points the port edges through a new buss + unity trunk',
    run = function(harness)
      local _, wm, rm = mkWm(harness)
      seedSource(wm, 'guid-s')
      seedSource(wm, 'guid-t')
      wm:mutate(function(g)
        g.nodes.f = { kind = 'fx', fxIdent = 'VST:F', pos = { x = 0, y = 0 },
                      ports = { audio = { ins = 1, outs = 1 }, midi = { ins = 0, outs = 0 } } }
        util.add(g.edges, { type = 'audio', from = 'guid-s', to = 'f', ops = { gain = 0.5 } })
        util.add(g.edges, { type = 'audio', from = 'guid-t', to = 'f' })
      end)
      local bus = wm:insertBus{ pos = { x = 5, y = 6 }, orient = 'H',
                                node = 'f', port = 1, dir = 'in' }
      t.eq(bus, 'bus-1')
      local g = wm:graph()
      t.eq(g.nodes[bus].orient, 'H')
      local intoBus, trunk = 0, nil
      for _, e in ipairs(g.edges) do
        if e.to == bus then intoBus = intoBus + 1 end
        if e.from == bus then trunk = e end
      end
      t.eq(intoBus, 2, 'both feeds re-pointed onto the buss')
      t.eq(trunk.to, 'f'); t.eq(trunk.toPort, 1)
      t.falsy(trunk.ops, 'trunk is unity')
      local rec = rm:meta('bus', bus)
      t.deepEq(rec.outs, { { node = 'f', port = 1 } }, 'trunk mirrored as the out tap')
      t.eq(#rec.ins, 2, 'feeds mirrored as in taps')
      t.eq(rec.ins[1].gain, 0.5, 'tap gain rides the mirror')
    end,
  },
  {
    name = 'tap mirror: wiring writes through; a dead node GCs its tap',
    run = function(harness)
      local _, wm, rm = mkWm(harness)
      local bus = wm:addBusNode({ x = 0, y = 0 })
      seedSource(wm, 'guid-s')
      t.deepEq(rm:meta('bus', bus).ins, {}, 'fresh buss has empty taps')
      wm:mutate(function(g)
        util.add(g.edges, { type = 'audio', from = 'guid-s', to = bus, ops = { gain = 0.5 } })
        util.add(g.edges, { type = 'audio', from = bus, to = 'master' })
      end)
      local rec = rm:meta('bus', bus)
      t.deepEq(rec.ins,  { { node = 'guid-s', port = 1, gain = 0.5 } })
      t.deepEq(rec.outs, { { node = 'master', port = 1 } })
      wm:mutate(function(g)
        g.nodes['guid-s'] = nil
        local kept = {}
        for _, e in ipairs(g.edges) do
          if e.from ~= 'guid-s' then util.add(kept, e) end
        end
        g.edges = kept
      end)
      t.deepEq(rm:meta('bus', bus).ins, {}, 'tap died with its node')
    end,
  },
}
