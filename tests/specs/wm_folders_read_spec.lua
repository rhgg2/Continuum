-- read : folder track parents. A foldered child's mainSend lands on its parent (the pair-1
-- summing point), not master; the parent reads as a source node with audio.ins>=1 that sums
-- its children, and the atomic parent send carries all-bus midi as liveness through the pipe.
-- See design/wiring-folders.md § Model + read.
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
    -- The parent send is atomic: the child's bus-0 midi rides the pipe and meets the
    -- parent's synth (a generator listening on bus 0) as a direct edge, alongside the
    -- audio summing edge into the parent node. midi is liveness, not an edge to the parent.
    name = 'folder: parent-send carries midi through the pipe to a parent fx',
    run = function(harness)
      local _, wm = mkWm(harness)
      local p = parent()
      p.fx = { { id='g-syn', ident='VST:Syn', ins=0, outs=1,
                 midi={ inBus=0, outBus=0, inDisabled=false, outDisabled=true },
                 pinMaps={ ins={}, outs={ [1]={1} } } } }
      local snap = {
        ['guid-A'] = withId(child('guid-P'), 'guid-A'),
        ['guid-P'] = withId(p, 'guid-P'),
      }
      local rg = wm.readGraph(snap)
      t.deepEq(edgeSet(rg), {
        'audio g-syn.1->master.-',
        'audio guid-A.1->guid-P.1',
        'midi guid-A.-->g-syn.-',
      })
      t.eq(rg.nodes['guid-P'].ports.midi.ins, 0, 'the pipe is liveness; the parent takes no midi edge')
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
}
