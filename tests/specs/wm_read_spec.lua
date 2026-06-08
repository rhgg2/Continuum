-- read : wiringSnapshot -> userGraph, passes 1-2 (audio routing + source->fx midi relay).
-- Drives wm.readGraph via wm:targetState -- the pure read(compile(g)) round-trip.
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

local function fx(ident, opts)
  opts = opts or {}
  return { kind='fx', fxIdent=ident, fxId=opts.fxId, pos={x=0,y=0},
           ports={audio={ins=opts.ins or 1, outs=opts.outs or 1},
                  midi={ins=1, outs=1}} }
end

-- Compare graph shape without depending on edge order or node table identity.
local function edgeSet(g)
  local out = {}
  for _, e in ipairs(g.edges) do
    local gain = e.ops and e.ops.gain
    out[#out+1] = string.format('%s %s.%s->%s.%s%s',
      e.type, e.from, e.fromPort or '-', e.to, e.toPort or '-',
      gain and (' @' .. gain) or '')
  end
  table.sort(out)
  return out
end
local function nodeKinds(g)
  local out = {}
  for id, n in pairs(g.nodes) do out[id] = n.kind end
  return out
end

return {
  {
    -- Synth has ins=0 so source feeds it MIDI only; outDisabled breaks the chain so f2 gets none.
    -- Clean round-trip: read(compile(g)) == g.
    name = 'read: generator chain s -(midi)-> synth -(audio)-> f2 -> master',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      wm:mutate(function(g)
        g.nodes.s   = source('guid-A')
        g.nodes.syn = fx('VST:Syn', { fxId='g-syn', ins=0, outs=1 })
        g.nodes.f2  = fx('VST:F2',  { fxId='g-f2' })
        util.add(g.edges, { type='midi',  from='s',   to='syn' })
        util.add(g.edges, { type='audio', from='syn', to='f2' })
        util.add(g.edges, { type='audio', from='f2',  to='master' })
      end)
      local rg = wm.readGraph(wm:targetState())
      t.deepEq(nodeKinds(rg),
               { master='master', ['guid-A']='source', ['g-syn']='fx', ['g-f2']='fx' })
      t.deepEq(edgeSet(rg), {
        'audio g-f2.1->master.-',
        'audio g-syn.1->g-f2.1',
        'midi guid-A.-->g-syn.-',
      })
      -- ports recovered from the snapshot ins/outs.
      t.eq(rg.nodes['g-syn'].ports.audio.ins,  0)
      t.eq(rg.nodes['g-syn'].ports.audio.outs, 1)
      t.eq(rg.nodes['g-f2'].ports.audio.ins,   1)
    end,
  },
  {
    -- Two sources sum into one fx on the master track (parent send, pair 1).
    -- No fx on the sources so no midi over-connection. Clean round-trip.
    name = 'read: two sources -> fx -> master (parent-send merge)',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      seedSource(h, 'guid-B')
      wm:mutate(function(g)
        g.nodes.sa = source('guid-A')
        g.nodes.sb = source('guid-B')
        g.nodes.f  = fx('VST:Mix', { fxId='g-f', ins=2, outs=1 })
        util.add(g.edges, { type='audio', from='sa', to='f' })
        util.add(g.edges, { type='audio', from='sb', to='f' })
        util.add(g.edges, { type='audio', from='f',  to='master' })
      end)
      local rg = wm.readGraph(wm:targetState())
      t.deepEq(nodeKinds(rg),
               { master='master', ['guid-A']='source', ['guid-B']='source', ['g-f']='fx' })
      t.deepEq(edgeSet(rg), {
        'audio g-f.1->master.-',
        'audio guid-A.1->g-f.1',
        'audio guid-B.1->g-f.1',
      })
    end,
  },
  {
    -- KNOWN BUG (design § open Q2, [[project_wiring_read_bus0_bug]]): audio-only source
    -- still realises MIDI via bus 0; read faithfully surfaces the phantom edge (compile bug).
    name = 'read: audio source -> fx also recovers the phantom bus-0 midi',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      wm:mutate(function(g)
        g.nodes.s = source('guid-A')
        g.nodes.f = fx('VST:Lin', { fxId='g-f' })
        util.add(g.edges, { type='audio', from='s', to='f' })
        util.add(g.edges, { type='audio', from='f', to='master' })
      end)
      local rg = wm.readGraph(wm:targetState())
      t.deepEq(edgeSet(rg), {
        'audio g-f.1->master.-',
        'audio guid-A.1->g-f.1',
        'midi guid-A.-->g-f.-',   -- phantom: compile over-connected bus 0
      })
    end,
  },
  {
    -- Gained intra-track feeder -> a matrix merge CU (nPairs=1). Collapse splices
    -- it out: the edge reads back with ops.gain, no CU node survives.
    name = 'read: gained s -> f recovers ops.gain, CU collapsed',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      wm:mutate(function(g)
        g.nodes.s = source('guid-A')
        g.nodes.f = fx('VST:F', { fxId='g-f' })
        util.add(g.edges, { type='audio', from='s', to='f', ops={gain=0.5} })
        util.add(g.edges, { type='audio', from='f', to='master' })
      end)
      local rg = wm.readGraph(wm:targetState())
      t.deepEq(nodeKinds(rg),
               { master='master', ['guid-A']='source', ['g-f']='fx' })
      t.deepEq(edgeSet(rg), {
        'audio g-f.1->master.-',
        'audio guid-A.1->g-f.1 @0.5',
        'midi guid-A.-->g-f.-',   -- phantom bus-0 midi (known compile bug)
      })
    end,
  },
  {
    -- Two in-class producers feed master -> an audioSum sum-tree CU. Collapse
    -- recovers both parent-send edges, with the leaf gain on one.
    name = 'read: sum-tree master fan-in collapses, leaf gain recovered',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      wm:mutate(function(g)
        g.nodes.s  = source('guid-A')
        g.nodes.f1 = fx('VST:F1', { fxId='g-f1' })
        g.nodes.f2 = fx('VST:F2', { fxId='g-f2' })
        util.add(g.edges, { type='audio', from='s',  to='f1' })
        util.add(g.edges, { type='audio', from='s',  to='f2' })
        util.add(g.edges, { type='audio', from='f1', to='master', ops={gain=0.7} })
        util.add(g.edges, { type='audio', from='f2', to='master' })
      end)
      local rg = wm.readGraph(wm:targetState())
      t.deepEq(edgeSet(rg), {
        'audio g-f1.1->master.- @0.7',
        'audio g-f2.1->master.-',
        'audio guid-A.1->g-f1.1',
        'audio guid-A.1->g-f2.1',
        'midi guid-A.-->g-f1.-',   -- phantom bus-0 midi; f1 has no midi-out so no relay onward
      })
    end,
  },
}
