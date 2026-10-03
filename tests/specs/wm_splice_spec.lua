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
                    ports = { audio = { ins = 0, outs = 1 }, midi = { ins = 0, outs = 1 } } }
  end)
end

local function fxNode(ins, outs, midiIns, midiOuts)
  return { kind = 'fx', fxIdent = 'VST:F', fxDisplay = 'F', pos = { x = 0, y = 0 },
           ports = { audio = { ins = ins, outs = outs },
                     midi  = { ins = midiIns or 0, outs = midiOuts or 0 } } }
end

local function edgeIndex(wm, from, to)
  for i, e in ipairs(wm:graph().edges) do
    if e.from == from and e.to == to then return i end
  end
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
  return edgeIndex(wm, 'guid-s', 'f')
end

-- s --midi--> f, f an instrument out to master; `n` (default midi 1/1, audio 1/1) to the side.
local function seedMidiWireAndNode(wm, n)
  seedSource(wm, 'guid-s')
  wm:mutate(function(g)
    g.nodes.f = fxNode(0, 1, 1, 0)
    g.nodes.n = n or fxNode(1, 1, 1, 1)
    util.add(g.edges, { type = 'midi', from = 'guid-s', to = 'f' })
    util.add(g.edges, { type = 'audio', from = 'f', to = 'master' })
  end)
  return edgeIndex(wm, 'guid-s', 'f')
end

-- The one edge of `type` into and out of `id`.
local function legsAt(wm, id, type)
  local into, outOf
  for _, e in ipairs(wm:graph().edges) do
    if e.type == type and e.to   == id then into  = e end
    if e.type == type and e.from == id then outOf = e end
  end
  return into, outOf
end

local function bare(e)
  return e.fromPort == nil and e.toPort == nil and e.ops == nil
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

  -- MIDI splice: the wire re-points into the node's midi in, and a fresh MIDI leg runs from
  -- its midi out to the old destination. MIDI edges stay bare, as reconstruct reads them back.
  {
    name = 'a MIDI splice re-points the wire through the node with bare MIDI legs',
    run = function(harness)
      local _, wm = mkWm(harness)
      local idx = seedMidiWireAndNode(wm)
      t.truthy(wm:spliceIntoEdge(idx, 'n', { x = 30, y = 40 }), 'splice lands')
      local into, outOf = legsAt(wm, 'n', 'midi')
      t.eq(into.from, 'guid-s', 'upstream end kept')
      t.eq(outOf.to, 'f',       'downstream end re-pointed off the node')
      t.truthy(bare(into),  'the re-pointed wire carries no ports or ops')
      t.truthy(bare(outOf), 'the new leg carries no ports or ops')
      t.falsy(edgeIndex(wm, 'guid-s', 'f'), 'the original wire is gone')
      local g = wm:graph()
      t.eq(g.nodes.n.pos.x, 30, 'node snapped to the given pos')
      t.eq(g.nodes.n.pos.y, 40)
    end,
  },
  {
    name = 'spliceable refuses a MIDI splice when the node\'s midi in or midi out is wired',
    run = function(harness)
      local _, wm = mkWm(harness)
      local idx = seedMidiWireAndNode(wm)
      t.truthy(wm:spliceable(idx, 'n'), 'the free node is spliceable')
      seedSource(wm, 'guid-t')
      wm:mutate(function(g) util.add(g.edges, { type = 'midi', from = 'guid-t', to = 'n' }) end)
      t.falsy(wm:spliceable(idx, 'n'), 'midi in already wired')

      local _, wm2 = mkWm(harness)
      local idx2 = seedMidiWireAndNode(wm2)
      wm2:mutate(function(g)
        g.nodes.g = fxNode(0, 1, 1, 0)
        util.add(g.edges, { type = 'midi', from = 'n', to = 'g' })
      end)
      t.falsy(wm2:spliceable(idx2, 'n'), 'midi out already wired')
    end,
  },
  {
    name = 'spliceable refuses a MIDI splice into a node lacking a midi in or a midi out',
    run = function(harness)
      local _, wm = mkWm(harness)
      local idx = seedMidiWireAndNode(wm)
      wm:mutate(function(g)
        g.nodes.noIn  = fxNode(1, 1, 0, 1)
        g.nodes.instr = fxNode(1, 1, 1, 0)
      end)
      t.falsy(wm:spliceable(idx, 'noIn'),  'no midi in')
      t.falsy(wm:spliceable(idx, 'instr'), 'an instrument has no midi out')
    end,
  },
  {
    name = 'a MIDI-only node splices into a MIDI wire',
    run = function(harness)
      local _, wm = mkWm(harness)
      local idx = seedMidiWireAndNode(wm, fxNode(0, 0, 1, 1))
      t.truthy(wm:spliceIntoEdge(idx, 'n', { x = 0, y = 0 }), 'splice lands')
      local into, outOf = legsAt(wm, 'n', 'midi')
      t.eq(into.from, 'guid-s')
      t.eq(outOf.to, 'f')
    end,
  },
  {
    name = 'the free-port check is per type',
    run = function(harness)
      local _, wm = mkWm(harness)
      local idx = seedWireAndNode(wm)
      wm:mutate(function(g)
        g.nodes.n = fxNode(1, 1, 1, 1)
        g.nodes.g = fxNode(0, 1, 1, 0)
        util.add(g.edges, { type = 'midi', from = 'guid-s', to = 'n' })
        util.add(g.edges, { type = 'midi', from = 'n', to = 'g' })
      end)
      t.truthy(wm:spliceable(idx, 'n'), 'midi in/out wired, audio wire still offered')

      local _, wm2 = mkWm(harness)
      local idx2 = seedMidiWireAndNode(wm2)
      seedSource(wm2, 'guid-t')
      wm2:mutate(function(g)
        util.add(g.edges, { type = 'audio', from = 'guid-t', to = 'n' })
        util.add(g.edges, { type = 'audio', from = 'n', to = 'master' })
      end)
      t.truthy(wm2:spliceable(idx2, 'n'), 'audio pair 1 wired, MIDI wire still offered')
    end,
  },
  {
    name = 'the loop check spans types: a node downstream over audio can\'t splice into MIDI',
    run = function(harness)
      local _, wm = mkWm(harness)
      local idx = seedMidiWireAndNode(wm)
      t.truthy(wm:spliceable(idx, 'n'), 'offered before the audio link')
      wm:mutate(function(g) util.add(g.edges, { type = 'audio', from = 'f', to = 'n' }) end)
      t.falsy(wm:spliceable(idx, 'n'), 'n already reaches downstream of the wire over audio')
    end,
  },
}
