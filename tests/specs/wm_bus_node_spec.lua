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
    name = 'live reconcile stamps record.trackId for a matrix buss; inert buss clears it',
    run = function(harness)
      local h, wm, rm = mkWm(harness)
      local function seedTrack(guid)
        local track = { __label = 'src-' .. guid }
        table.insert(h.reaper._state.projectTracks, track)
        h.reaper._state.trackGuids[track] = guid
      end
      seedTrack('guid-A'); seedTrack('guid-B')
      wm:load()  -- read mints source nodes guid-A/guid-B from the live tracks
      wm:enableLive()
      local bus = wm:addBusNode({ x = 10, y = 20 })
      t.falsy(rm:meta('bus', bus).trackId, 'unwired buss carries no track')
      wm:mutate(function(g)
        util.add(g.edges, { type = 'audio', from = 'guid-A', to = bus })
        util.add(g.edges, { type = 'audio', from = 'guid-B', to = bus })
        util.add(g.edges, { type = 'audio', from = bus, to = 'master' })
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
      -- dropping the inputs leaves the buss inert; the reconcile that demolishes
      -- the track also clears the stamp
      wm:mutate(function(g)
        local kept = {}
        for _, e in ipairs(g.edges) do
          if e.to ~= bus then util.add(kept, e) end
        end
        g.edges = kept
      end)
      t.falsy(rm:meta('bus', bus).trackId, 'inert buss record cleared')
    end,
  },
}
