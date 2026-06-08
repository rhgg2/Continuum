-- read : wiringSnapshot -> userGraph. Audio routing + CU collapse + gain + full midi-bus
-- walk (fan-in, merge, brackets). Drives wm.readGraph, via wm:targetState or a built snapshot.
local t    = require('support')
local util = require('util')

local CU_IDENT = 'JS:Continuum Utility'

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
    -- Bus-0 phantom fixed ([[project_wiring_read_bus0_bug]]): an audio-only fx compiles with its
    -- midi input disabled (inDisabled), so read recovers no spurious source->fx midi edge.
    name = 'read: audio source -> fx recovers no phantom bus-0 midi',
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
      })
    end,
  },
  {
    -- Cross-track MIDI fan-in: two source tracks midi-send into one consumer, coalescing on
    -- bus 0 (no CU). Hand-built: a consumer fed only by source MIDI collapses onto master.
    name = 'read: two midi sends into one fx recover cross-track fan-in',
    run = function(harness)
      local _, wm = mkWm(harness)
      local midiSend = function() return { to='guid-C', kind='midi', srcChan=0, dstChan=0, pos='preFader' } end
      local snap = {
        ['guid-A'] = { trackKind='sourceTrack', id='guid-A', nchan=2, mainSend={on=false},
                       fx={}, sends={ midiSend() } },
        ['guid-B'] = { trackKind='sourceTrack', id='guid-B', nchan=2, mainSend={on=false},
                       fx={}, sends={ midiSend() } },
        ['guid-C'] = { trackKind='newTrack', id='guid-C', nchan=2, mainSend={on=false}, sends={},
          fx = { { id='g-m', ident='VST:M', ins=0, outs=1, midi={ inBus=0, outBus=0, outDisabled=true } } } },
      }
      local rg = wm.readGraph(snap)
      t.deepEq(nodeKinds(rg),
               { master='master', ['guid-A']='source', ['guid-B']='source', ['g-m']='fx' })
      t.deepEq(edgeSet(rg), {
        'midi guid-A.-->g-m.-',
        'midi guid-B.-->g-m.-',
      })
    end,
  },
  {
    -- Same-track MIDI fan-in: a merge CU unions producer buses 1,2 onto bus 3; collapse
    -- splices it out so read recovers A->C and B->C. Hand-built (compile won't force it).
    name = 'read: same-track merge CU unions two midi producer buses',
    run = function(harness)
      local _, wm = mkWm(harness)
      local mask12 = (1 << 1) | (1 << 2)
      local snap = {
        ['guid-A'] = {
          trackKind = 'sourceTrack', id = 'guid-A', nchan = 8,
          mainSend = { on = false }, sends = {},
          fx = {
            { id='g-A', ident='VST:A', ins=1, outs=1, midi={ inBus=0, outBus=1, outDisabled=false } },
            { id='g-B', ident='VST:B', ins=1, outs=1, midi={ inBus=0, outBus=2, outDisabled=false } },
            { id='cu',  ident=CU_IDENT, ins=32, outs=32,
              params = { mode=1, nPairs=1, gain1=1, audioSum=0, outBus=3,
                         inMask0=mask12, inMask1=0, inMask2=0, inMask3=0 } },
            { id='g-C', ident='VST:C', ins=1, outs=1, midi={ inBus=3, outBus=3, outDisabled=true } },
          },
        },
      }
      local rg = wm.readGraph(snap)
      t.deepEq(nodeKinds(rg),
               { master='master', ['guid-A']='source', ['g-A']='fx', ['g-B']='fx', ['g-C']='fx' })
      t.deepEq(edgeSet(rg), {
        'midi g-A.-->g-C.-',
        'midi g-B.-->g-C.-',
        'midi guid-A.-->g-A.-',
        'midi guid-A.-->g-B.-',
      })
    end,
  },
  {
    -- BusRoute brackets around a non-bus-aware JSFX (bus N≠0) are midi-transparent: read
    -- recovers producer->JSFX through the from/0/to swap. Hand-built (mirrors the DAG spec).
    name = 'read: busRoute brackets are transparent, recover the wrapped JSFX edges',
    run = function(harness)
      local _, wm = mkWm(harness)
      local bracket = function() return { ins=32, outs=32, ident=CU_IDENT,
        pinMaps = { ins={[1]={1}}, outs={[1]={1}} } } end
      local bIn, bOut = bracket(), bracket()
      bIn.id,  bIn.params  = 'bIn',  { mode=0, from=1, to=1 }
      bOut.id, bOut.params = 'bOut', { mode=0, from=1, to=1 }
      local snap = {
        ['guid-a'] = { trackKind='sourceTrack', id='guid-a', nchan=2, mainSend={on=false}, fx={},
                       sends={ { to='guid-c', kind='midi', srcChan=0, dstChan=0, pos='preFader' } } },
        ['guid-b'] = { trackKind='sourceTrack', id='guid-b', nchan=2, mainSend={on=false}, fx={},
                       sends={ { to='guid-c', kind='midi', srcChan=0, dstChan=1, pos='preFader' } } },
        ['guid-c'] = { trackKind='newTrack', id='guid-c', nchan=2, mainSend={on=false}, sends={},
          fx = {
            { id='fxC1', ident='JS:Foo', ins=1, outs=1 },
            bIn,
            { id='fxC2', ident='JS:Bar', ins=1, outs=1 },
            bOut,
          } },
      }
      local rg = wm.readGraph(snap)
      t.deepEq(nodeKinds(rg),
               { master='master', ['guid-a']='source', ['guid-b']='source',
                 fxC1='fx', fxC2='fx' })
      t.deepEq(edgeSet(rg), {
        'midi guid-a.-->fxC1.-',
        'midi guid-b.-->fxC2.-',
      })
    end,
  },
  {
    -- A bus-aware JSFX (ext_midi_bus) escapes the allocator, corrupting its track-set's bus
    -- space; read groups the component and tags it busAware (design § Quarantine). Hand-built.
    name = 'read: a bus-aware fx quarantines its whole component',
    run = function(harness)
      local _, wm = mkWm(harness)
      local snap = {
        ['guid-A'] = { trackKind='sourceTrack', id='guid-A', nchan=2, mainSend={on=false}, sends={},
          fx = {
            { id='g-f', ident='JS:Plain',    ins=1, outs=1 },
            { id='g-b', ident='JS:BusAware', ins=1, outs=1, busAware=true },
          } },
      }
      local rg = wm.readGraph(snap)
      t.eq(rg.nodes['g-b'].busAware, true, 'busAware copied onto the node')
      local byNodes = {}
      for _, c in ipairs(rg.components) do byNodes[table.concat(c.nodes, ',')] = c.reason or false end
      t.deepEq(byNodes, { ['g-b,g-f,guid-A'] = 'busAware' })
    end,
  },
  {
    -- A send cycle (P->Q->P) can't be topo-ordered; read still surfaces both tracks' fx (so the
    -- view can darken them) and classify tags the whole component feedback. Hand-built.
    name = 'read: a send cycle is surfaced and quarantined as feedback',
    run = function(harness)
      local _, wm = mkWm(harness)
      local function looper(to)
        return { trackKind='newTrack', nchan=2, mainSend={on=false},
                 sends={ { to=to, kind='audio', srcChan=0, dstChan=0, pos='postFader' } } }
      end
      local snap = {
        ['guid-P'] = looper('guid-Q'),
        ['guid-Q'] = looper('guid-P'),
      }
      snap['guid-P'].id, snap['guid-Q'].id = 'guid-P', 'guid-Q'
      snap['guid-P'].fx = { { id='fp', ident='VST:F', ins=1, outs=1, pinMaps={ins={[1]={1}}, outs={[1]={1}} } } }
      snap['guid-Q'].fx = { { id='fq', ident='VST:F', ins=1, outs=1, pinMaps={ins={[1]={1}}, outs={[1]={1}} } } }
      local rg = wm.readGraph(snap)
      t.deepEq(nodeKinds(rg), { master='master', fp='fx', fq='fx' })
      local byNodes = {}
      for _, c in ipairs(rg.components) do byNodes[table.concat(c.nodes, ',')] = c.reason or false end
      t.deepEq(byNodes, { ['fp,fq'] = 'feedback' })
    end,
  },
}
