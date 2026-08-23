local t    = require('support')
local util = require('util')

local function mkWm(harness, opts)
  local h  = harness.mk(opts)
  local rm = util.instantiate('routingManager', { ds = h.ds })
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
  return h, wm, rm
end

-- Source node seeded directly (no REAPER track): splice never touches a track.
local function seedSource(wm, id)
  wm:mutate(function(g)
    g.nodes[id] = { kind = 'source', trackId = id, pos = { x = 0, y = 0 },
                    ports = { audio = { ins = 0, outs = 1 }, midi = { ins = 0, outs = 0 } } }
  end)
end

local function fxNode(ins, outs)
  return { kind = 'fx', fxIdent = 'VST:F', fxDisplay = 'F', pos = { x = 0, y = 0 },
           ports = { audio = { ins = ins, outs = outs }, midi = { ins = 0, outs = 0 } } }
end

-- s --0.5--> f, with a free 1x1 fx node `n` off to the side.
local function seedWireAndNode(wm)
  seedSource(wm, 'guid-s')
  wm:mutate(function(g)
    g.nodes.f = fxNode(1, 1)
    g.nodes.n = fxNode(1, 1)
    util.add(g.edges, { type = 'audio', from = 'guid-s', to = 'f', ops = { gain = 0.5 } })
    util.add(g.edges, { type = 'audio', from = 'f', to = 'master' })
  end)
  for i, e in ipairs(wm:graph().edges) do
    if e.from == 'guid-s' and e.to == 'f' then return i end
  end
end

return {
  {
    name = 'spliceIntoEdge re-points the wire through the node and snaps its pos',
    run = function(harness)
      local _, wm = mkWm(harness)
      local idx = seedWireAndNode(wm)
      t.truthy(wm:spliceIntoEdge(idx, 'n', { x = 30, y = 40 }), 'splice lands')
      local g = wm:graph()
      local intoN, outOfN
      for _, e in ipairs(g.edges) do
        if e.to == 'n'   then intoN  = e end
        if e.from == 'n' then outOfN = e end
      end
      t.eq(intoN.from, 'guid-s', 'upstream end kept')
      t.eq(intoN.toPort, 1,      'lands on audio pair 1')
      t.eq(outOfN.to, 'f',       'downstream end re-pointed off the node')
      t.eq(outOfN.fromPort, 1,   'leaves from audio pair 1')
      t.eq(g.nodes.n.pos.x, 30,  'node snapped to the given pos')
      t.eq(g.nodes.n.pos.y, 40)
      for _, e in ipairs(g.edges) do
        t.truthy(not (e.from == 'guid-s' and e.to == 'f'), 'the original wire is gone')
      end
    end,
  },
  {
    name = 'the wire gain rides the input side; the output leg is unity',
    run = function(harness)
      local _, wm = mkWm(harness)
      local idx = seedWireAndNode(wm)
      wm:spliceIntoEdge(idx, 'n', { x = 0, y = 0 })
      for _, e in ipairs(wm:graph().edges) do
        if e.to   == 'n' then t.eq(e.ops.gain, 0.5, 'gain kept upstream of the splice') end
        if e.from == 'n' then t.falsy(e.ops,        'output leg is unity') end
      end
    end,
  },
  {
    name = 'spliceable refuses a node with no free audio pair 1',
    run = function(harness)
      local _, wm = mkWm(harness)
      local idx = seedWireAndNode(wm)
      t.truthy(wm:spliceable(idx, 'n'), 'the free node is spliceable')
      wm:mutate(function(g)
        util.add(g.edges, { type = 'audio', from = 'n', fromPort = 1, to = 'master' })
      end)
      t.falsy(wm:spliceable(idx, 'n'), 'out pair 1 already wired')
    end,
  },
  {
    name = 'spliceable refuses a node without both an audio in and an out pair',
    run = function(harness)
      local _, wm = mkWm(harness)
      local idx = seedWireAndNode(wm)
      wm:mutate(function(g) g.nodes.gen = fxNode(0, 1) end)
      t.falsy(wm:spliceable(idx, 'gen'), 'a generator has no audio in')
      t.falsy(wm:spliceable(idx, 'master'), 'master has no audio out')
    end,
  },
  {
    name = 'spliceable refuses an end of the wire and a splice that would close a loop',
    run = function(harness)
      local _, wm = mkWm(harness)
      local idx = seedWireAndNode(wm)
      t.falsy(wm:spliceable(idx, 'f'), 'the wire\'s own consumer')
      wm:mutate(function(g)
        g.nodes.d = fxNode(2, 1)
        util.add(g.edges, { type = 'audio', from = 'f', to = 'd', toPort = 2 })
      end)
      t.falsy(wm:spliceable(idx, 'd'), 'd is already downstream of the wire')
    end,
  },
  {
    name = 'spliceIntoEdge refuses what spliceable refuses, leaving the graph alone',
    run = function(harness)
      local _, wm = mkWm(harness)
      local idx = seedWireAndNode(wm)
      local before = wm:graph()
      local ok, err = wm:spliceIntoEdge(idx, 'f', { x = 30, y = 40 })
      t.falsy(ok, 'refused')
      t.eq(err.code, 'not_spliceable')
      t.truthy(util.deepEq(wm:graph(), before), 'graph untouched')
    end,
  },
}
