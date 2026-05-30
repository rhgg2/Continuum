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
      t.deepEq(plan['__scratch__'].sends, {})
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
      t.deepEq(plan['guid-s'].sends, {})
      t.deepEq(plan['__scratch__'].sends, {})
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
      t.deepEq(plan['guid-s'].sends, {})
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
      t.deepEq(plan['guid-a'].sends, {})
      t.deepEq(plan['guid-b'].sends, {})
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
      -- fx_a's class (guid-a) sends audio into fx_b's class.
      t.deepEq(plan['guid-a'].sends, { { to = fxbCls, type = 'audio' } })
      t.deepEq(plan['guid-b'].sends, { { to = fxbCls, type = 'audio' } })
    end,
  },
  {
    name = 'multiple audio wires to same target class collapse to one send',
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
      -- guid-a sends to mix's class via two audio wires; collapses to one.
      t.eq(#plan['guid-a'].sends, 1)
      t.eq(plan['guid-a'].sends[1].type, 'audio')
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
      t.deepEq(plan['guid-a'].sends, { { to = compCls, type = 'midi' } })
      t.deepEq(plan['guid-b'].sends, { { to = compCls, type = 'midi' } })
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
      t.deepEq(plan['guid-a'].sends, { { to = fxbCls, type = 'audio', gain = 0.5 } })
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
}
