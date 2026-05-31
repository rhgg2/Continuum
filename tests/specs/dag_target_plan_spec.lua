local t   = require('support')
local DAG = require('DAG')

local function source(id, guid)
  return id, { kind = 'source', trackGuid = guid or 'guid-' .. id,
               pos = { x = 0, y = 0 },
               ports = { audio = { ins = 0, outs = 1 },
                         midi  = { ins = 0, outs = 1 } } }
end

local function fx(id, opts)
  opts = opts or {}
  return id, { kind = 'fx', pos = { x = 0, y = 0 },
               fxIdent   = opts.ident   or 'JS:test',
               fxDisplay = opts.display or 'FX',
               ports = { audio = { ins  = opts.ins  or 1,
                                   outs = opts.outs or 1 },
                         midi  = { ins = 1, outs = 1 } } }
end

local function master(opts)
  opts = opts or {}
  return 'master', { kind = 'master', pos = { x = 0, y = 0 },
                     ports = { audio = { ins = opts.ins or 1, outs = 0 },
                               midi  = { ins = 0, outs = 0 } } }
end

local function mk(nodes, edges)
  if not nodes.master then
    local k, v = master(); nodes[k] = v
  end
  return { nodes = nodes, edges = edges or {}, nextId = 1 }
end

local function planOf(g)
  return DAG.compile(g):targetPlan()
end

return {
  {
    name = 'empty graph: only master, plan is empty (master implicit, no scratch needed)',
    run = function()
      local plan = planOf(mk({}))
      t.eq(next(plan), nil)
    end,
  },
  {
    name = 'source + master, no edges: source-track entry only, master implicit',
    run = function()
      local ns = {}
      local k, v = source('s', 'guid-s'); ns[k] = v
      local plan = planOf(mk(ns))
      t.eq(plan['guid-s'].hostKind,  'sourceTrack')
      t.eq(plan['guid-s'].trackGuid, 'guid-s')
      t.deepEq(plan['guid-s'].fxOrder, {})
      t.eq(plan['guid-s'].mainSend, false)
      t.eq(plan[''],          nil)
      t.eq(plan['__scratch__'], nil)
    end,
  },
  {
    name = 'inert fx alone: parks on scratch',
    run = function()
      local ns = {}
      local k, v = fx('orphan'); ns[k] = v
      local plan = planOf(mk(ns))
      t.eq(plan['__scratch__'].hostKind, 'scratch')
      t.deepEq(plan['__scratch__'].fxOrder, { 'orphan' })
      t.eq(plan['__scratch__'].mainSend, false)
      t.deepEq(plan['__scratch__'].outWires, {})
    end,
  },
  {
    name = 'multiple inert fx coexist on scratch (sorted by id)',
    run = function()
      local ns = {}
      local k,  v  = fx('b'); ns[k]  = v
      local k2, v2 = fx('a'); ns[k2] = v2
      local k3, v3 = fx('c'); ns[k3] = v3
      local plan = planOf(mk(ns))
      t.deepEq(plan['__scratch__'].fxOrder, { 'a', 'b', 'c' })
    end,
  },
  {
    name = 'inert fx + active source path: scratch and source-track coexist independently',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('f');               ns[k2] = v2
      local k3, v3 = fx('orphan');          ns[k3] = v3
      local plan = planOf(mk(ns, {
        { type = 'audio', from = 's', to = 'f' },
        { type = 'audio', from = 'f', to = 'master' },
      }))
      t.eq(plan['guid-s'].hostKind, 'sourceTrack')
      t.deepEq(plan['guid-s'].fxOrder, { 'f' })
      t.eq(plan['guid-s'].mainSend, true)
      t.eq(plan['__scratch__'].hostKind, 'scratch')
      t.deepEq(plan['__scratch__'].fxOrder, { 'orphan' })
    end,
  },
  {
    name = 'wire from inert fx to live class produces no send (inert vertex carries no signal)',
    run = function()
      -- orphan has audio out into fx_a (sourced by s). orphan stays inert
      -- (srcSet={}; it has no inputs). The orphan->fx_a conn is dropped.
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('fx_a', { ins = 2 }); ns[k2] = v2
      local k3, v3 = fx('orphan'); ns[k3] = v3
      local plan = planOf(mk(ns, {
        { type = 'audio', from = 's',      to = 'fx_a', toPort = 1 },
        { type = 'audio', from = 'orphan', to = 'fx_a', toPort = 2 },
        { type = 'audio', from = 'fx_a',   to = 'master' },
      }))
      -- orphan is in the inert pool, parked on scratch.
      t.deepEq(plan['__scratch__'].fxOrder, { 'orphan' })
      -- The orphan->fx_a wire produces no send entry anywhere.
      t.deepEq(plan['guid-s'].outWires, {})
      t.deepEq(plan['__scratch__'].outWires, {})
    end,
  },
  {
    name = 'source -> fx -> master: one class on source track, fxOrder=[f], mainSend=true',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('f');               ns[k2] = v2
      local plan = planOf(mk(ns, {
        { type = 'audio', from = 's', to = 'f' },
        { type = 'audio', from = 'f', to = 'master' },
      }))
      t.eq(plan['guid-s'].hostKind,  'sourceTrack')
      t.eq(plan['guid-s'].trackGuid, 'guid-s')
      t.deepEq(plan['guid-s'].fxOrder, { 'f' })
      t.eq(plan['guid-s'].mainSend, true)
      t.deepEq(plan['guid-s'].outWires, {})
    end,
  },
  {
    name = 'two-source fanin: mix+master share class, mix lands on REAPER master',
    run = function()
      local ns = {}
      local k,  v  = source('s1', 'guid-a'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-b'); ns[k2] = v2
      local k3, v3 = fx('mix', { ins = 2 }); ns[k3] = v3
      local plan = planOf(mk(ns, {
        { type = 'audio', from = 's1',  to = 'mix', toPort = 1 },
        { type = 'audio', from = 's2',  to = 'mix', toPort = 2 },
        { type = 'audio', from = 'mix', to = 'master' },
      }))
      -- The master-hosted class is keyed by the sentinel '__master__', not
      -- its merged srcSet — wm:snapshot can't tag the REAPER master with a
      -- project-scoped class, so both sides agree on a stable host key.
      t.eq(plan['guid-a|guid-b'], nil, 'merged-srcSet key vacated for sentinel')
      t.eq(plan['__master__'].hostKind, 'master')
      t.deepEq(plan['__master__'].fxOrder, { 'mix' })
      -- Sources fold their audio-to-master into mainSend, not regular sends.
      t.eq(plan['guid-a'].mainSend, true)
      t.eq(plan['guid-b'].mainSend, true)
      t.deepEq(plan['guid-a'].outWires, {})
      t.deepEq(plan['guid-b'].outWires, {})
    end,
  },
  {
    name = 'inter-class send between two managed tracks (non-master target)',
    run = function()
      -- s1 -> fx_a (own class with s1, host=sourceTrack)
      -- s2 -> fx_b (own class with s2)
      -- fx_a -> fx_b means class(fx_a)={g1}, class(fx_b)={g1,g2}; inter-class
      -- audio. fx_b's class has no master -> newTrack. So {g1} sends to {g1|g2}.
      local ns = {}
      local k,  v  = source('s1', 'guid-a'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-b'); ns[k2] = v2
      local k3, v3 = fx('fx_a');             ns[k3] = v3
      local k4, v4 = fx('fx_b', { ins = 2 }); ns[k4] = v4
      local plan = planOf(mk(ns, {
        { type = 'audio', from = 's1',   to = 'fx_a' },
        { type = 'audio', from = 's2',   to = 'fx_b', toPort = 1 },
        { type = 'audio', from = 'fx_a', to = 'fx_b', toPort = 2 },
      }))
      local fxbCls = 'guid-a|guid-b'
      t.eq(plan[fxbCls].hostKind, 'newTrack')
      t.deepEq(plan[fxbCls].fxOrder, { 'fx_b' })
      t.eq(plan[fxbCls].mainSend, false)
      -- outWires carry producer/consumer node ids + ports so the allocator
      -- can plan channel pairs and pin maps on each side.
      t.deepEq(plan['guid-a'].outWires,
               { { from = 'fx_a', fromPort = 1, to = fxbCls,
                   toNode = 'fx_b', toPort = 2, type = 'audio' } })
      t.deepEq(plan['guid-b'].outWires,
               { { from = 's2', fromPort = 1, to = fxbCls,
                   toNode = 'fx_b', toPort = 1, type = 'audio' } })
    end,
  },
  {
    name = 'multiple audio wires to same target class: outWires has one entry per wire (no collapse)',
    run = function()
      -- s1 -> fx (2 outs, both feed mix)
      -- s2 -> mix (so mix class differs from fx class)
      local ns = {}
      local k,  v  = source('s1', 'guid-a'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-b'); ns[k2] = v2
      local k3, v3 = fx('splitter', { outs = 2 }); ns[k3] = v3
      local k4, v4 = fx('mix', { ins = { 'L','R','L','R' } }); ns[k4] = v4
      local plan = planOf(mk(ns, {
        { type = 'audio', from = 's1',       to = 'splitter' },
        { type = 'audio', from = 's2',       to = 'mix', toPort = 1 },
        { type = 'audio', from = 'splitter', to = 'mix', toPort = 2, fromPort = 1 },
        { type = 'audio', from = 'splitter', to = 'mix', toPort = 2, fromPort = 2 },
      }))
      -- splitter's two wires surface as distinct outWires keyed on fromPort;
      -- DAG.allocate decides collapse via channel assignment.
      local ws = plan['guid-a'].outWires
      t.eq(#ws, 2)
      t.eq(ws[1].from, 'splitter'); t.eq(ws[1].fromPort, 1)
      t.eq(ws[2].from, 'splitter'); t.eq(ws[2].fromPort, 2)
      t.eq(ws[1].toNode, 'mix');    t.eq(ws[1].toPort, 2)
      t.eq(ws[2].toNode, 'mix');    t.eq(ws[2].toPort, 2)
    end,
  },
  {
    name = 'intra-class fxOrder is topological (CU then downstream fx)',
    run = function()
      -- source -> fx_a with gain op; lower inserts CU between them.
      -- All in same class; fxOrder should be [_cu_1, fx_a] (CU upstream of fx_a).
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('fx_a');            ns[k2] = v2
      local plan = planOf(mk(ns, {
        { type = 'audio', from = 's',    to = 'fx_a', ops = { gain = 0.5 } },
        { type = 'audio', from = 'fx_a', to = 'master' },
      }))
      local order = plan['guid-s'].fxOrder
      t.eq(#order, 2)
      t.eq(order[1], '_cu_1')
      t.eq(order[2], 'fx_a')
    end,
  },
  {
    name = 'midi inter-class between two managed tracks: regular send',
    run = function()
      -- s1 -> synthA (midi) -> midiCompressor <- synthB <- s2
      local ns = {}
      local k,  v  = source('s1', 'guid-a');               ns[k]  = v
      local k2, v2 = source('s2', 'guid-b');               ns[k2] = v2
      local k3, v3 = fx('synthA', { ins = 0, outs = 1 }); ns[k3] = v3
      local k4, v4 = fx('synthB', { ins = 0, outs = 1 }); ns[k4] = v4
      local k5, v5 = fx('midiComp', { ins = 0, outs = 0 }); ns[k5] = v5
      local plan = planOf(mk(ns, {
        { type = 'midi',  from = 's1',     to = 'synthA' },
        { type = 'midi',  from = 's2',     to = 'synthB' },
        { type = 'midi',  from = 'synthA', to = 'midiComp' },
        { type = 'midi',  from = 'synthB', to = 'midiComp' },
      }))
      local compCls = 'guid-a|guid-b'
      t.eq(plan[compCls].hostKind, 'newTrack')
      t.deepEq(plan[compCls].fxOrder, { 'midiComp' })
      t.deepEq(plan['guid-a'].outWires,
               { { from = 'synthA', to = compCls, toNode = 'midiComp', type = 'midi' } })
      t.deepEq(plan['guid-b'].outWires,
               { { from = 'synthB', to = compCls, toNode = 'midiComp', type = 'midi' } })
    end,
  },
  {
    name = 'gain on an inter-class wire folds onto the send (no CU in fxOrder)',
    run = function()
      local ns = {}
      local k,  v  = source('s1', 'guid-a');   ns[k]  = v
      local k2, v2 = source('s2', 'guid-b');   ns[k2] = v2
      local k3, v3 = fx('fx_a');               ns[k3] = v3
      local k4, v4 = fx('fx_b', { ins = 2 });  ns[k4] = v4
      local plan = planOf(mk(ns, {
        { type = 'audio', from = 's1',   to = 'fx_a' },
        { type = 'audio', from = 's2',   to = 'fx_b', toPort = 1 },
        { type = 'audio', from = 'fx_a', to = 'fx_b', toPort = 2, ops = { gain = 0.5 } },
      }))
      local fxbCls = 'guid-a|guid-b'
      -- Folded boundary CU bypassed: outWire.from is fx_a (the real producer
      -- upstream of the CU), not the folded CU node id.
      t.deepEq(plan['guid-a'].outWires,
               { { from = 'fx_a', fromPort = 1, to = fxbCls,
                   toNode = 'fx_b', toPort = 2, type = 'audio', gain = 0.5 } })
      t.deepEq(plan['guid-a'].fxOrder, { 'fx_a' }, 'gain CU folded out of fxOrder')
    end,
  },
  {
    name = 'gain on the sole wire to master folds onto mainSendGain (no CU)',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('fx_a');            ns[k2] = v2
      local plan = planOf(mk(ns, {
        { type = 'audio', from = 's',    to = 'fx_a' },
        { type = 'audio', from = 'fx_a', to = 'master', ops = { gain = 0.25 } },
      }))
      t.eq(plan['guid-s'].mainSend, true)
      t.eq(plan['guid-s'].mainSendGain, 0.25)
      t.deepEq(plan['guid-s'].fxOrder, { 'fx_a' }, 'gain CU folded out of fxOrder')
    end,
  },
  {
    name = 'two wires to master from one class keep their CU (one fader, two gains)',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('fx_1');            ns[k2] = v2
      local k3, v3 = fx('fx_2');            ns[k3] = v3
      local plan = planOf(mk(ns, {
        { type = 'audio', from = 's',    to = 'fx_1' },
        { type = 'audio', from = 's',    to = 'fx_2' },
        { type = 'audio', from = 'fx_1', to = 'master', ops = { gain = 0.5 } },
        { type = 'audio', from = 'fx_2', to = 'master' },
      }))
      t.eq(plan['guid-s'].mainSend, true)
      t.eq(plan['guid-s'].mainSendGain, nil, 'multi-path → no native fold')
      local hasCu = false
      for _, id in ipairs(plan['guid-s'].fxOrder) do
        if id:match('^_cu_') then hasCu = true end
      end
      t.truthy(hasCu, 'gain CU retained in fxOrder')
    end,
  },

  {
    name = 'absorb: single audio parent (extra src via midi) → B hosts on guid-s1, midi send retargets',
    run = function()
      -- B terminal (outs=0) keeps its class newTrack-eligible (not master-hosted).
      local ns = {}
      local k,  v  = source('s1', 'guid-s1'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-s2'); ns[k2] = v2
      local k3, v3 = fx('B', { ins = 1, outs = 0 }); ns[k3] = v3
      local plan = planOf(mk(ns, {
        { type = 'audio', from = 's1', to = 'B' },
        { type = 'midi',  from = 's2', to = 'B' },
      }))
      t.eq(plan['guid-s1|guid-s2'], nil, 'absorbed class has no plan entry')
      t.eq(plan['guid-s1'].hostKind, 'sourceTrack')
      t.deepEq(plan['guid-s1'].fxOrder, { 'B' })
      t.deepEq(plan['guid-s2'].outWires,
               { { from = 's2', to = 'guid-s1', toNode = 'B', type = 'midi' } })
    end,
  },

  {
    name = 'absorb: primary override picks host even with two audio parents',
    run = function()
      local ns = {}
      local k,  v  = source('s1', 'guid-s1'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-s2'); ns[k2] = v2
      local k3, v3 = fx('B', { ins = 2, outs = 0 }); ns[k3] = v3
      local plan = planOf(mk(ns, {
        { type = 'audio', from = 's1', to = 'B', toPort = 1, primary = true },
        { type = 'audio', from = 's2', to = 'B', toPort = 2 },
      }))
      t.eq(plan['guid-s1|guid-s2'], nil)
      t.deepEq(plan['guid-s1'].fxOrder, { 'B' })
      t.deepEq(plan['guid-s2'].outWires,
               { { from = 's2', fromPort = 1, to = 'guid-s1',
                   toNode = 'B', toPort = 2, type = 'audio' } })
    end,
  },

  {
    name = 'absorb: chain through two hops lands on terminal source host',
    run = function()
      -- mixB terminal (outs=0) keeps the chain's classes newTrack-eligible.
      local ns = {}
      local k1, v1 = source('s', 'guid-s'); ns[k1] = v1
      local k2, v2 = source('t', 'guid-t'); ns[k2] = v2
      local k3, v3 = source('u', 'guid-u'); ns[k3] = v3
      local k4, v4 = fx('mixA', { ins = 2, outs = 1 }); ns[k4] = v4
      local k5, v5 = fx('mixB', { ins = 2, outs = 0 }); ns[k5] = v5
      local plan = planOf(mk(ns, {
        { type = 'audio', from = 's',    to = 'mixA', toPort = 1, primary = true },
        { type = 'audio', from = 't',    to = 'mixA', toPort = 2 },
        { type = 'audio', from = 'mixA', to = 'mixB', toPort = 1, primary = true },
        { type = 'audio', from = 'u',    to = 'mixB', toPort = 2 },
      }))
      t.eq(plan['guid-s|guid-t'],        nil)
      t.eq(plan['guid-s|guid-t|guid-u'], nil)
      t.eq(plan['guid-s'].hostKind, 'sourceTrack')
      t.deepEq(plan['guid-s'].fxOrder, { 'mixA', 'mixB' })
      t.deepEq(plan['guid-t'].outWires,
               { { from = 't', fromPort = 1, to = 'guid-s',
                   toNode = 'mixA', toPort = 2, type = 'audio' } })
      t.deepEq(plan['guid-u'].outWires,
               { { from = 'u', fromPort = 1, to = 'guid-s',
                   toNode = 'mixB', toPort = 2, type = 'audio' } })
    end,
  },

  {
    name = 'absorb: gain on now-intra-host wire stays CU (no send to fold onto)',
    run = function()
      local ns = {}
      local k,  v  = source('s1', 'guid-s1'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-s2'); ns[k2] = v2
      local k3, v3 = fx('B', { ins = 2, outs = 0 }); ns[k3] = v3
      local plan = planOf(mk(ns, {
        { type = 'audio', from = 's1', to = 'B', toPort = 1, primary = true,
          ops = { gain = 0.5 } },
        { type = 'audio', from = 's2', to = 'B', toPort = 2 },
      }))
      local order = plan['guid-s1'].fxOrder
      t.eq(#order, 2, 'CU + B')
      t.eq(order[1], '_cu_1')
      t.eq(order[2], 'B')
    end,
  },

  {
    name = 'absorb: master-hosted class never absorbed even with single audio parent',
    run = function()
      -- master's class has 1 audio parent → absorption() proposes a host, but
      -- master-hosted classes are exempt and keep the '__master__' entry.
      local ns = {}
      local k,  v  = source('s1', 'guid-s1'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-s2'); ns[k2] = v2
      local k3, v3 = fx('A');                 ns[k3] = v3
      local plan = planOf(mk(ns, {
        { type = 'audio', from = 's1', to = 'A' },
        { type = 'audio', from = 'A',  to = 'master' },
        { type = 'midi',  from = 's2', to = 'master' },
      }))
      t.eq(plan['__master__'].hostKind, 'master')
      t.eq(plan['guid-s1|guid-s2'], nil, 'master-hosted vacates merged key for sentinel')
      t.eq(plan['guid-s1'].mainSend, true)
      t.eq(plan['guid-s2'].mainSend, true, 'midi to master-hosted lifts parent send')
      t.deepEq(plan['guid-s1'].fxOrder, { 'A' })
      t.deepEq(plan['guid-s2'].outWires, {})
    end,
  },

  {
    name = 'absorb: source-hosted class is never the absorbee (its host is the source track)',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('f');               ns[k2] = v2
      local plan = planOf(mk(ns, {
        { type = 'audio', from = 's', to = 'f' },
        { type = 'audio', from = 'f', to = 'master' },
      }))
      t.eq(plan['guid-s'].hostKind, 'sourceTrack')
      t.deepEq(plan['guid-s'].fxOrder, { 'f' })
      t.eq(plan['guid-s'].mainSend, true)
    end,
  },

  {
    name = 'absorb: capacityErrors reports host classKey after intra-host merge',
    run = function()
      -- 65 audio wires sit inside the absorbed class {s1,s2}; post-fix they
      -- belong to host guid-s1, which is what the error must key on.
      local ns = {}
      local k1, v1 = source('s1', 'guid-s1');         ns[k1] = v1
      local k2, v2 = source('s2', 'guid-s2');         ns[k2] = v2
      local k3, v3 = fx('B', { ins = 1, outs = 1 }); ns[k3] = v3
      local k4, v4 = fx('D', { ins = 1, outs = 64 }); ns[k4] = v4
      local k5, v5 = fx('E', { ins = 64, outs = 0 }); ns[k5] = v5
      local edges = {
        { type = 'audio', from = 's1', to = 'B' },
        { type = 'midi',  from = 's2', to = 'B' },
        { type = 'audio', from = 'B',  to = 'D' },
      }
      for p = 1, 64 do
        edges[#edges+1] = { type = 'audio', from = 'D', to = 'E',
                            fromPort = p, toPort = p }
      end
      local cx   = DAG.compile(mk(ns, edges))
      local errs = cx:capacityErrors()
      t.eq(#errs, 1)
      t.eq(errs[1].classKey, 'guid-s1', 'capacity error keyed by host, not absorbed-class key')
      t.eq(errs[1].kind, 'audio')
    end,
  },

  {
    name = 'absorb: send from another non-host class retargets to host classKey',
    run = function()
      -- midfx (in class {s3}) sends audio into B's absorbed class — must
      -- retarget to guid-s1 (B's host), not the merged-class key.
      local ns = {}
      local k1, v1 = source('s1', 'guid-s1'); ns[k1] = v1
      local k2, v2 = source('s2', 'guid-s2'); ns[k2] = v2
      local k3, v3 = source('s3', 'guid-s3'); ns[k3] = v3
      local k4, v4 = fx('midfx');                       ns[k4] = v4
      local k5, v5 = fx('B', { ins = 2, outs = 0 });    ns[k5] = v5
      local plan = planOf(mk(ns, {
        { type = 'audio', from = 's1',    to = 'B', toPort = 1, primary = true },
        { type = 'midi',  from = 's2',    to = 'B' },
        { type = 'audio', from = 's3',    to = 'midfx' },
        { type = 'audio', from = 'midfx', to = 'B', toPort = 2 },
      }))
      t.eq(plan['guid-s1|guid-s2|guid-s3'], nil, 'absorbed class vacated')
      t.deepEq(plan['guid-s1'].fxOrder, { 'B' })
      t.deepEq(plan['guid-s2'].outWires,
               { { from = 's2', to = 'guid-s1', toNode = 'B', type = 'midi' } })
      t.deepEq(plan['guid-s3'].outWires,
               { { from = 'midfx', fromPort = 1, to = 'guid-s1',
                   toNode = 'B', toPort = 2, type = 'audio' } })
    end,
  },

  -- intraConns: anchors track-IO and per-FX-pin context for the allocator.
  --   * source -> fx     = track input pair -> fx input pin
  --   * fx     -> fx     = intra-class chain conn
  --   * fx     -> master = host's audio output pair -> REAPER master input
  -- Folded CUs (gain bridges on inter-host wires) never appear; the inter-host
  -- conn carries the gain via outWires.gain instead.

  {
    name = 'intraConns: source -> fx and fx -> master both anchor track-IO sides',
    run = function()
      -- Lone-source rule: master shares the source's class, so the host is
      -- source-hosted and both s->f and f->master are intra-host anchors.
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('f');               ns[k2] = v2
      local plan = planOf(mk(ns, {
        { type = 'audio', from = 's', to = 'f' },
        { type = 'audio', from = 'f', to = 'master' },
      }))
      t.deepEq(plan['guid-s'].intraConns, {
        { from = 'f', fromPort = 1, to = 'master', toPort = 1, type = 'audio' },
        { from = 's', fromPort = 1, to = 'f',      toPort = 1, type = 'audio' },
      })
    end,
  },

  {
    name = 'intraConns: fx -> fx chain conn carries both port indices',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s');                       ns[k]  = v
      local k2, v2 = fx('a', { outs = 2 });                       ns[k2] = v2
      local k3, v3 = fx('b', { ins = 2, outs = 0 });              ns[k3] = v3
      local plan = planOf(mk(ns, {
        { type = 'audio', from = 's', to = 'a' },
        { type = 'audio', from = 'a', to = 'b', fromPort = 1, toPort = 1 },
        { type = 'audio', from = 'a', to = 'b', fromPort = 2, toPort = 2 },
      }))
      local ic = plan['guid-s'].intraConns
      -- Sort is by (from, fromPort, to, toPort, type) so 'a' precedes 's'.
      t.eq(#ic, 3, 'a->b(1,1), a->b(2,2), s->a')
      t.eq(ic[1].from, 'a'); t.eq(ic[1].fromPort, 1); t.eq(ic[1].toPort, 1)
      t.eq(ic[2].from, 'a'); t.eq(ic[2].fromPort, 2); t.eq(ic[2].toPort, 2)
      t.eq(ic[3].from, 's'); t.eq(ic[3].to, 'a')
    end,
  },

  {
    name = 'intraConns: fx -> master inside master-hosted class anchors track-output',
    run = function()
      local ns = {}
      local k,  v  = source('s1', 'guid-a');   ns[k]  = v
      local k2, v2 = source('s2', 'guid-b');   ns[k2] = v2
      local k3, v3 = fx('mix', { ins = 2 });   ns[k3] = v3
      local plan = planOf(mk(ns, {
        { type = 'audio', from = 's1',  to = 'mix', toPort = 1 },
        { type = 'audio', from = 's2',  to = 'mix', toPort = 2 },
        { type = 'audio', from = 'mix', to = 'master' },
      }))
      -- Sources s1/s2 are in their own classes; wires to mix lift to mainSend.
      -- Only mix->master is intra-host on the master-hosted class.
      t.deepEq(plan['__master__'].intraConns, {
        { from = 'mix', fromPort = 1, to = 'master', toPort = 1, type = 'audio' },
      })
      t.eq(plan['guid-a'].mainSend, true, 'source->mix lifts to mainSend')
      t.eq(plan['guid-b'].mainSend, true, 'source->mix lifts to mainSend')
    end,
  },

  {
    name = 'intraConns: folded boundary gain CU never appears',
    run = function()
      local ns = {}
      local k,  v  = source('s1', 'guid-a');             ns[k]  = v
      local k2, v2 = source('s2', 'guid-b');             ns[k2] = v2
      local k3, v3 = fx('fx_a');                         ns[k3] = v3
      local k4, v4 = fx('fx_b', { ins = 2 });            ns[k4] = v4
      local plan = planOf(mk(ns, {
        { type = 'audio', from = 's1',   to = 'fx_a' },
        { type = 'audio', from = 's2',   to = 'fx_b', toPort = 1 },
        { type = 'audio', from = 'fx_a', to = 'fx_b', toPort = 2, ops = { gain = 0.5 } },
      }))
      for _, c in ipairs(plan['guid-a'].intraConns) do
        t.eq(c.from:match('^_cu_'), nil, 'no folded CU as intraConn from')
        t.eq(c.to  :match('^_cu_'), nil, 'no folded CU as intraConn to')
      end
      t.deepEq(plan['guid-a'].intraConns,
               { { from = 's1', fromPort = 1, to = 'fx_a', toPort = 1, type = 'audio' } })
    end,
  },

  {
    name = 'intraConns: un-folded gain CU on intra-host wire is included',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('fx_1');            ns[k2] = v2
      local k3, v3 = fx('fx_2');            ns[k3] = v3
      local plan = planOf(mk(ns, {
        { type = 'audio', from = 's',    to = 'fx_1', ops = { gain = 0.5 } },
        { type = 'audio', from = 's',    to = 'fx_2' },
        { type = 'audio', from = 'fx_1', to = 'master' },
        { type = 'audio', from = 'fx_2', to = 'master' },
      }))
      local cuId = nil
      for _, id in ipairs(plan['guid-s'].fxOrder) do
        if id:match('^_cu_') then cuId = id end
      end
      t.truthy(cuId, 'gain CU retained in fxOrder (no fold)')
      local sawSToCu, sawCuToFx1, sawFx1ToMaster, sawFx2ToMaster = false, false, false, false
      for _, c in ipairs(plan['guid-s'].intraConns) do
        if c.from == 's'    and c.to == cuId    then sawSToCu = true end
        if c.from == cuId   and c.to == 'fx_1'  then sawCuToFx1 = true end
        if c.from == 'fx_1' and c.to == 'master' then sawFx1ToMaster = true end
        if c.from == 'fx_2' and c.to == 'master' then sawFx2ToMaster = true end
      end
      t.truthy(sawSToCu,         's -> CU intraConn present')
      t.truthy(sawCuToFx1,       'CU -> fx_1 intraConn present')
      t.truthy(sawFx1ToMaster,   'fx_1 -> master intraConn present')
      t.truthy(sawFx2ToMaster,   'fx_2 -> master intraConn present')
    end,
  },
}
