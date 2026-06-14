-- read : folder track parents. Child midi takes wire into the parent node; parent emits bus 0
-- from its own take. See design/archive/wiring-folders.md § Model + read.
local t    = require('support')
local util = require('util')
local DAG  = require('DAG')

local function mkWm(harness)
  local h  = harness.mk()
  local rm = util.instantiate('routingManager')
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
  wm:load()
  return h, wm
end

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

-- A foldered source: mainSend lands on `parent` (a parent-send), pair 1, no fx.
local function child(parent)
  return { trackKind='sourceTrack', nchan=2, parent=parent,
           mainSend={ on=true, tgtOffset=0 }, fx={}, sends={} }
end
-- A top-level folder parent main-sending to master.
local function parent()
  return { trackKind='sourceTrack', nchan=2, mainSend={ on=true, tgtOffset=0 }, fx={}, sends={} }
end
-- A plain audio fx with explicit pin maps and midi disabled (no phantom edges).
local function audioFx(id, ident)
  return { id=id, ident=ident, ins=1, outs=1,
           midi={ inBus=0, outBus=0, inDisabled=true, outDisabled=true },
           pinMaps={ ins={ [1]={1} }, outs={ [1]={1} } } }
end
local function withId(entry, id) entry.id = id; return entry end

return {
  {
    -- The starburst: two children sum into their folder parent, which feeds master.
    -- The parent is a source node (audio.ins>=1), not a transparent pass-through.
    name = 'folder: two children sum into the parent, parent feeds master',
    run = function(harness)
      local _, wm = mkWm(harness)
      local snap = {
        ['guid-A'] = withId(child('guid-P'), 'guid-A'),
        ['guid-B'] = withId(child('guid-P'), 'guid-B'),
        ['guid-P'] = withId(parent(), 'guid-P'),
      }
      local rg = wm.readGraph(snap)
      t.deepEq(nodeKinds(rg),
               { master='master', ['guid-A']='source', ['guid-B']='source', ['guid-P']='source' })
      t.deepEq(edgeSet(rg), {
        'audio guid-A.1->guid-P.1',
        'audio guid-B.1->guid-P.1',
        'audio guid-P.1->master.-',
      })
      t.eq(rg.nodes['guid-P'].ports.audio.ins, 1, 'folder parent is a summing input')
    end,
  },
  {
    -- A folder parent hosting fx: the summed children feed the parent node, whose pair-1
    -- output is the fx-chain head; the fx output reaches master. Folders are allowed fx.
    name = 'folder: parent hosting fx reads as source -> fx -> master',
    run = function(harness)
      local _, wm = mkWm(harness)
      local p = parent(); p.fx = { audioFx('g-eq', 'VST:EQ') }
      local snap = {
        ['guid-A'] = withId(child('guid-P'), 'guid-A'),
        ['guid-P'] = withId(p, 'guid-P'),
      }
      local rg = wm.readGraph(snap)
      t.deepEq(nodeKinds(rg),
               { master='master', ['guid-A']='source', ['guid-P']='source', ['g-eq']='fx' })
      t.deepEq(edgeSet(rg), {
        'audio g-eq.1->master.-',
        'audio guid-A.1->guid-P.1',
        'audio guid-P.1->g-eq.1',
      })
    end,
  },
  {
    -- Child tail midi wires into the parent node; the parent re-emits on bus 0 to its generator.
    -- Two hops: child -> parent -> fx. The child needs a midi take to emit.
    name = 'folder: a child tail midi wires into the parent node, then the parent fx',
    run = function(harness)
      local _, wm = mkWm(harness)
      local p = parent()
      p.fx = { { id='g-syn', ident='VST:Syn', ins=0, outs=1,
                 midi={ inBus=0, outBus=0, inDisabled=false, outDisabled=true },
                 pinMaps={ ins={}, outs={ [1]={1} } } } }
      local a = withId(child('guid-P'), 'guid-A'); a.hasMidiTake = true
      local snap = { ['guid-A'] = a, ['guid-P'] = withId(p, 'guid-P') }
      local rg = wm.readGraph(snap)
      t.deepEq(edgeSet(rg), {
        'audio g-syn.1->master.-',
        'audio guid-A.1->guid-P.1',
        'midi guid-A.-->guid-P.-',
        'midi guid-P.-->g-syn.-',
      })
      t.eq(rg.nodes['guid-P'].ports.midi.ins, 1, 'the child tail midi is a wire into the parent node')
    end,
  },
  {
    -- The parent's own midi take: with no midi child, the parent still emits bus 0 from its take,
    -- which its on-track generator reads. An audio-only child sums in but contributes no midi.
    name = 'folder: the parent own midi take emits on bus 0 and feeds a parent fx',
    run = function(harness)
      local _, wm = mkWm(harness)
      local p = parent(); p.hasMidiTake = true
      p.fx = { { id='g-arp', ident='VST:Arp', ins=0, outs=1,
                 midi={ inBus=0, outBus=0, inDisabled=false, outDisabled=true },
                 pinMaps={ ins={}, outs={ [1]={1} } } } }
      local snap = {
        ['guid-A'] = withId(child('guid-P'), 'guid-A'),  -- audio-only child: no midi take
        ['guid-P'] = withId(p, 'guid-P'),
      }
      local rg = wm.readGraph(snap)
      t.deepEq(edgeSet(rg), {
        'audio g-arp.1->master.-',
        'audio guid-A.1->guid-P.1',
        'midi guid-P.-->g-arp.-',
      })
    end,
  },
  {
    -- Wire-before-take: a parent fx reads bus 0 but the parent has no take yet and no midi child.
    -- Must still emit bus 0 so the authored sid->fx edge survives compile (gated on consumer, not just source).
    name = 'folder: a parent fx reading bus 0 wires from the node even with no take',
    run = function(harness)
      local _, wm = mkWm(harness)
      local p = parent()  -- no hasMidiTake, no midi child
      p.fx = { { id='g-arp', ident='VST:Arp', ins=0, outs=1,
                 midi={ inBus=0, outBus=0, inDisabled=false, outDisabled=true },
                 pinMaps={ ins={}, outs={ [1]={1} } } } }
      local snap = {
        ['guid-A'] = withId(child('guid-P'), 'guid-A'),  -- audio-only child: makes guid-P a folderSink
        ['guid-P'] = withId(p, 'guid-P'),
      }
      local rg = wm.readGraph(snap)
      t.deepEq(edgeSet(rg), {
        'audio g-arp.1->master.-',
        'audio guid-A.1->guid-P.1',
        'midi guid-P.-->g-arp.-',
      })
    end,
  },
  {
    -- Conduit overflow: a child's parent-send and an explicit audio send to a sibling track
    -- coexist. Membership and routing decouple — both edges survive.
    name = 'folder: parent-send and an explicit send to a sibling coexist',
    run = function(harness)
      local _, wm = mkWm(harness)
      local a = child('guid-P')
      a.sends = { { to='guid-Q', kind='audio', srcChan=0, dstChan=0, pos='postFader' } }
      local q = { trackKind='newTrack', nchan=2, mainSend={ on=true, tgtOffset=0 }, sends={},
                  fx = { audioFx('g-q', 'VST:Q') } }
      local snap = {
        ['guid-A'] = withId(a, 'guid-A'),
        ['guid-P'] = withId(parent(), 'guid-P'),
        ['guid-Q'] = withId(q, 'guid-Q'),
      }
      local rg = wm.readGraph(snap)
      t.deepEq(edgeSet(rg), {
        'audio g-q.1->master.-',
        'audio guid-A.1->g-q.1',
        'audio guid-A.1->guid-P.1',
        'audio guid-P.1->master.-',
      })
    end,
  },
  {
    -- Nested folders chain through their parents: leaf -> inner -> outer -> master, each
    -- parent a summing source node. Midi liveness flows upward unheard (no fx) — no edges.
    name = 'folder: nested parents chain leaf -> inner -> outer -> master',
    run = function(harness)
      local _, wm = mkWm(harness)
      local snap = {
        ['guid-Leaf']  = withId(child('guid-Inner'), 'guid-Leaf'),
        ['guid-Inner'] = withId(child('guid-Outer'), 'guid-Inner'),
        ['guid-Outer'] = withId(parent(), 'guid-Outer'),
      }
      local rg = wm.readGraph(snap)
      t.deepEq(nodeKinds(rg), { master='master',
               ['guid-Leaf']='source', ['guid-Inner']='source', ['guid-Outer']='source' })
      t.deepEq(edgeSet(rg), {
        'audio guid-Inner.1->guid-Outer.1',
        'audio guid-Leaf.1->guid-Inner.1',
        'audio guid-Outer.1->master.-',
      })
    end,
  },
  {
    -- A foldered child with mainSend off does not feed its parent — membership is structural,
    -- the edge is the mainSend. Its egress is the explicit send instead.
    name = 'folder: a child with mainSend off does not edge into its parent',
    run = function(harness)
      local _, wm = mkWm(harness)
      local b = { trackKind='sourceTrack', nchan=2, parent='guid-P', mainSend={ on=false },
                  fx={}, sends={ { to='guid-Q', kind='audio', srcChan=0, dstChan=0, pos='postFader' } } }
      local q = { trackKind='newTrack', nchan=2, mainSend={ on=true, tgtOffset=0 }, sends={},
                  fx = { audioFx('g-q', 'VST:Q') } }
      local snap = {
        ['guid-A'] = withId(child('guid-P'), 'guid-A'),
        ['guid-B'] = withId(b, 'guid-B'),
        ['guid-P'] = withId(parent(), 'guid-P'),
        ['guid-Q'] = withId(q, 'guid-Q'),
      }
      local rg = wm.readGraph(snap)
      t.deepEq(edgeSet(rg), {
        'audio g-q.1->master.-',
        'audio guid-A.1->guid-P.1',
        'audio guid-B.1->g-q.1',
        'audio guid-P.1->master.-',
      })
    end,
  },
  {
    -- The model change: M.validate already permits an audio edge into any node with ins>=1
    -- (the generic port check). A folder parent is just a source node minted with audio.ins=1.
    name = 'validate: an audio edge into a source with ins>=1 is legal',
    run = function()
      local g = {
        nodes = {
          master = { kind='master', ports={ audio={ins=1,outs=0}, midi={ins=0,outs=0} } },
          p = { kind='source', trackId='guid-P',
                ports={ audio={ins=1,outs=1}, midi={ins=0,outs=0} } },
          c = { kind='source', trackId='guid-C',
                ports={ audio={ins=0,outs=1}, midi={ins=0,outs=1} } },
        },
        edges = {
          { type='audio', from='c', fromPort=1, to='p', toPort=1 },
          { type='audio', from='p', fromPort=1, to='master' },
        },
      }
      t.falsy(DAG.validate(g), 'edge into a source-with-ins validates')
    end,
  },
  {
    -- A non-zero child bus is a distinct stream: it passes through the pipe identity-mapped and
    -- wires DIRECT to the parent fx that reads bus 1 -- not funneled through the parent node.
    name = 'folder: a child bus-1 producer wires direct to the parent fx reading bus 1',
    run = function(harness)
      local _, wm = mkWm(harness)
      local a = child('guid-P')  -- a pure-midi generator emitting on bus 1 (no take)
      a.fx = { { id='g-gen', ident='VST:Gen', ins=0, outs=0,
                 midi={ inBus=0, outBus=1, inDisabled=true, outDisabled=false },
                 pinMaps={ ins={}, outs={} } } }
      local p = parent()  -- a parent fx reading bus 1
      p.fx = { { id='g-arp', ident='VST:Arp', ins=1, outs=1,
                 midi={ inBus=1, outBus=0, inDisabled=false, outDisabled=true },
                 pinMaps={ ins={ [1]={1} }, outs={ [1]={1} } } } }
      local snap = { ['guid-A'] = withId(a, 'guid-A'), ['guid-P'] = withId(p, 'guid-P') }
      local rg = wm.readGraph(snap)
      t.deepEq(edgeSet(rg), {
        'audio g-arp.1->master.-',
        'audio guid-A.1->guid-P.1',
        'audio guid-P.1->g-arp.1',
        'midi g-gen.-->g-arp.-',
      })
    end,
  },
  {
    -- Bus 0 and bus >=1 split at one parent: the take child aggregates into the node (two hops to
    -- the bus-0 fx), while the bus-1 child threads through direct to the bus-1 fx.
    name = 'folder: bus-0 take aggregates via the node, bus-1 stream wires direct',
    run = function(harness)
      local _, wm = mkWm(harness)
      local a = withId(child('guid-P'), 'guid-A'); a.hasMidiTake = true  -- bus-0 take
      local b = child('guid-P')  -- bus-1 generator
      b.fx = { { id='g-gen', ident='VST:Gen', ins=0, outs=0,
                 midi={ inBus=0, outBus=1, inDisabled=true, outDisabled=false },
                 pinMaps={ ins={}, outs={} } } }
      local p = parent()  -- two pure-midi consumers: one on bus 0, one on bus 1
      p.fx = { { id='g-mix', ident='VST:Mix', ins=0, outs=0,
                 midi={ inBus=0, outBus=0, inDisabled=false, outDisabled=true },
                 pinMaps={ ins={}, outs={} } },
               { id='g-fx', ident='VST:Fx', ins=0, outs=0,
                 midi={ inBus=1, outBus=0, inDisabled=false, outDisabled=true },
                 pinMaps={ ins={}, outs={} } } }
      local snap = {
        ['guid-A'] = a,
        ['guid-B'] = withId(b, 'guid-B'),
        ['guid-P'] = withId(p, 'guid-P'),
      }
      local rg = wm.readGraph(snap)
      t.deepEq(edgeSet(rg), {
        'audio guid-A.1->guid-P.1',
        'audio guid-B.1->guid-P.1',
        'audio guid-P.1->master.-',
        'midi g-gen.-->g-fx.-',
        'midi guid-A.-->guid-P.-',
        'midi guid-P.-->g-mix.-',
      })
    end,
  },
}
