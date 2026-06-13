local t   = require('support')
local DAG = require('DAG')

local function source(id, guid)
  return id, { kind = 'source', trackId = guid or 'guid-' .. id,
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

local function tracksOf(g)
  return DAG.targetTracks(DAG.compile(g))
end

-- The merge CUs of a tracks entry as {id, node} pairs (synthNodes is cuId-keyed).
local function cuEntries(entry)
  local out = {}
  for id, sn in pairs(entry.synthNodes or {}) do out[#out + 1] = { id = id, node = sn } end
  return out
end

return {
  {
    name = 'empty graph: only master, tracks is empty (master implicit, no scratch needed)',
    run = function()
      local tracks = tracksOf(mk({}))
      t.eq(next(tracks), nil)
    end,
  },
  {
    name = 'source + master, no edges: source-track entry only, master implicit',
    run = function()
      local ns = {}
      local k, v = source('s', 'guid-s'); ns[k] = v
      local tracks = tracksOf(mk(ns))
      t.eq(tracks['guid-s'].trackKind,  'sourceTrack')
      t.eq(tracks['guid-s'].trackId, 'guid-s')
      t.deepEq(tracks['guid-s'].fxOrder, {})
      t.eq(tracks['guid-s'].mainSend, false)
      t.eq(tracks[''],          nil)
      t.eq(tracks['__scratch__'], nil)
    end,
  },
  {
    name = 'inert fx alone: parks on scratch',
    run = function()
      local ns = {}
      local k, v = fx('orphan'); ns[k] = v
      local tracks = tracksOf(mk(ns))
      t.eq(tracks['__scratch__'].trackKind, 'scratch')
      t.deepEq(tracks['__scratch__'].fxOrder, { 'orphan' })
      t.eq(tracks['__scratch__'].mainSend, false)
      t.deepEq(tracks['__scratch__'].outWires, {})
    end,
  },
  {
    name = 'multiple inert fx coexist on scratch (sorted by id)',
    run = function()
      local ns = {}
      local k,  v  = fx('b'); ns[k]  = v
      local k2, v2 = fx('a'); ns[k2] = v2
      local k3, v3 = fx('c'); ns[k3] = v3
      local tracks = tracksOf(mk(ns))
      t.deepEq(tracks['__scratch__'].fxOrder, { 'a', 'b', 'c' })
    end,
  },
  {
    name = 'inert fx + active source path: scratch and source-track coexist independently',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('f');               ns[k2] = v2
      local k3, v3 = fx('orphan');          ns[k3] = v3
      local tracks = tracksOf(mk(ns, {
        { type = 'audio', from = 's', to = 'f' },
        { type = 'audio', from = 'f', to = 'master' },
      }))
      t.eq(tracks['guid-s'].trackKind, 'sourceTrack')
      t.deepEq(tracks['guid-s'].fxOrder, { 'f' })
      t.eq(tracks['guid-s'].mainSend, true)
      t.eq(tracks['__scratch__'].trackKind, 'scratch')
      t.deepEq(tracks['__scratch__'].fxOrder, { 'orphan' })
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
      local tracks = tracksOf(mk(ns, {
        { type = 'audio', from = 's',      to = 'fx_a', toPort = 1 },
        { type = 'audio', from = 'orphan', to = 'fx_a', toPort = 2 },
        { type = 'audio', from = 'fx_a',   to = 'master' },
      }))
      -- orphan is in the inert pool, parked on scratch.
      t.deepEq(tracks['__scratch__'].fxOrder, { 'orphan' })
      -- The orphan->fx_a wire produces no send entry anywhere.
      t.deepEq(tracks['guid-s'].outWires, {})
      t.deepEq(tracks['__scratch__'].outWires, {})
    end,
  },
  {
    name = 'source -> fx -> master: one class on source track, fxOrder=[f], mainSend=true',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('f');               ns[k2] = v2
      local tracks = tracksOf(mk(ns, {
        { type = 'audio', from = 's', to = 'f' },
        { type = 'audio', from = 'f', to = 'master' },
      }))
      t.eq(tracks['guid-s'].trackKind,  'sourceTrack')
      t.eq(tracks['guid-s'].trackId, 'guid-s')
      t.deepEq(tracks['guid-s'].fxOrder, { 'f' })
      t.eq(tracks['guid-s'].mainSend, true)
      t.deepEq(tracks['guid-s'].outWires, {})
    end,
  },
  {
    name = 'two-source fanin: mix+master share class, mix lands on REAPER master',
    run = function()
      local ns = {}
      local k,  v  = source('s1', 'guid-a'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-b'); ns[k2] = v2
      local k3, v3 = fx('mix', { ins = 2 }); ns[k3] = v3
      local tracks = tracksOf(mk(ns, {
        { type = 'audio', from = 's1',  to = 'mix', toPort = 1 },
        { type = 'audio', from = 's2',  to = 'mix', toPort = 2 },
        { type = 'audio', from = 'mix', to = 'master' },
      }))
      -- The master-hosted class is keyed by the sentinel '__master__', not
      -- its merged srcSet — wm:snapshot can't tag the REAPER master with a
      -- project-scoped class, so both sides agree on a stable trackKey key.
      t.eq(tracks[t.key('guid-a', 'guid-b')], nil, 'merged-srcSet key vacated for sentinel')
      t.eq(tracks['__master__'].trackKind, 'master')
      t.deepEq(tracks['__master__'].fxOrder, { 'mix' })
      -- Sources fold their audio-to-master into mainSend, not regular sends.
      t.eq(tracks['guid-a'].mainSend, true)
      t.eq(tracks['guid-b'].mainSend, true)
      t.deepEq(tracks['guid-a'].outWires, {})
      t.deepEq(tracks['guid-b'].outWires, {})
    end,
  },
  {
    name = 'inter-class send between two managed tracks (non-master target)',
    run = function()
      -- s1 -> fx_a (own class with s1, trackKey=sourceTrack)
      -- s2 -> fx_b (own class with s2)
      -- fx_a -> fx_b means class(fx_a)={g1}, class(fx_b)={g1,g2}; inter-class
      -- audio. fx_b's class has no master -> newTrack. So {g1} sends to {g1|g2}.
      local ns = {}
      local k,  v  = source('s1', 'guid-a'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-b'); ns[k2] = v2
      local k3, v3 = fx('fx_a');             ns[k3] = v3
      local k4, v4 = fx('fx_b', { ins = 2 }); ns[k4] = v4
      local tracks = tracksOf(mk(ns, {
        { type = 'audio', from = 's1',   to = 'fx_a' },
        { type = 'audio', from = 's2',   to = 'fx_b', toPort = 1 },
        { type = 'audio', from = 'fx_a', to = 'fx_b', toPort = 2 },
      }))
      local fxbCls = t.key('guid-a', 'guid-b')
      t.eq(tracks[fxbCls].trackKind, 'newTrack')
      t.deepEq(tracks[fxbCls].fxOrder, { 'fx_b' })
      t.eq(tracks[fxbCls].mainSend, false)
      -- outWires carry producer/consumer node ids + ports so the allocator
      -- can tracks channel pairs and pin maps on each side.
      t.deepEq(tracks['guid-a'].outWires,
               { { from = 'fx_a', fromPort = 1, to = fxbCls,
                   toNode = 'fx_b', toPort = 2, type = 'audio' } })
      t.deepEq(tracks['guid-b'].outWires,
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
      local tracks = tracksOf(mk(ns, {
        { type = 'audio', from = 's1',       to = 'splitter' },
        { type = 'audio', from = 's2',       to = 'mix', toPort = 1 },
        { type = 'audio', from = 'splitter', to = 'mix', toPort = 2, fromPort = 1 },
        { type = 'audio', from = 'splitter', to = 'mix', toPort = 2, fromPort = 2 },
      }))
      -- splitter's two wires surface as distinct outWires keyed on fromPort;
      -- DAG.allocate decides collapse via channel assignment.
      local ws = tracks['guid-a'].outWires
      t.eq(#ws, 2)
      t.eq(ws[1].from, 'splitter'); t.eq(ws[1].fromPort, 1)
      t.eq(ws[2].from, 'splitter'); t.eq(ws[2].fromPort, 2)
      t.eq(ws[1].toNode, 'mix');    t.eq(ws[1].toPort, 2)
      t.eq(ws[2].toNode, 'mix');    t.eq(ws[2].toPort, 2)
    end,
  },
  {
    -- A producer fanning to two co-trackKey consumers reaches each via that consumer's
    -- own merge CU, so the cross-trackKey outWires differ in toNode — never identical.
    name = 'fan-out to co-trackKey consumers: outWires stay distinct (no identical sends)',
    run = function()
      local ns = {}
      local k,  v  = source('s1', 'guid-a'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-b'); ns[k2] = v2
      local k3, v3 = fx('p');  ns[k3] = v3   -- producer on s1's class
      local k4, v4 = fx('c1'); ns[k4] = v4   -- c1/c2 form their own class via s2 fan-in
      local k5, v5 = fx('c2'); ns[k5] = v5
      local tracks = tracksOf(mk(ns, {
        { type = 'midi', from = 's1', to = 'p'  },
        { type = 'midi', from = 'p',  to = 'c1' },
        { type = 'midi', from = 'p',  to = 'c2' },
        { type = 'midi', from = 's2', to = 'c1' },
        { type = 'midi', from = 's2', to = 'c2' },
      }))
      local seen = {}
      for _, ow in ipairs(tracks['guid-a'].outWires) do
        local key = ow.from .. '|' .. (ow.fromPort or 0) .. '|' .. ow.to
                  .. '|' .. ow.toNode .. '|' .. (ow.toPort or 0) .. '|' .. ow.type
        t.eq(seen[key], nil, 'duplicate outWire: ' .. key)
        seen[key] = true
      end
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
      local tracks = tracksOf(mk(ns, {
        { type = 'audio', from = 's',    to = 'fx_a', ops = { gain = 0.5 } },
        { type = 'audio', from = 'fx_a', to = 'master' },
      }))
      local order = tracks['guid-s'].fxOrder
      t.eq(#order, 2)
      t.eq(order[1], '_cu_1')
      t.eq(order[2], 'fx_a')
    end,
  },
  {
    name = 'fxOrder drains ready consumers before sibling producers (GH tiebreak)',
    run = function()
      -- After fxA, ready={fxB,fxC}; GH drains fxC over producer fxB (id-only
      -- would give fxA,fxB,fxC,fxD). fxC/fxD→master add a sum CU at chain end.
      local ns = {}
      local k0, v0 = source('s', 'guid-s'); ns[k0] = v0
      for _, id in ipairs({ 'fxA', 'fxB', 'fxC', 'fxD' }) do
        local k, v = fx(id); ns[k] = v
      end
      local tracks = tracksOf(mk(ns, {
        { type = 'audio', from = 's',   to = 'fxA' },
        { type = 'audio', from = 's',   to = 'fxB' },
        { type = 'audio', from = 'fxA', to = 'fxC' },
        { type = 'audio', from = 'fxB', to = 'fxD' },
        { type = 'audio', from = 'fxC', to = 'master' },
        { type = 'audio', from = 'fxD', to = 'master' },
      }))
      t.deepEq(tracks['guid-s'].fxOrder, { 'fxA', 'fxC', 'fxB', 'fxD', '_cu_1' })
    end,
  },
  {
    name = 'cross-track midi fan-in coalesces onto one bus, no merge CU',
    run = function()
      -- s1 -> synthA -> midiComp <- synthB <- s2: cross-track feeders coalesce onto
      -- one dest bus; no same-track producer, so no merge CU. see docs/DAG.md § MIDI
      local ns = {}
      local k,  v  = source('s1', 'guid-a');               ns[k]  = v
      local k2, v2 = source('s2', 'guid-b');               ns[k2] = v2
      local k3, v3 = fx('synthA', { ins = 0, outs = 1 }); ns[k3] = v3
      local k4, v4 = fx('synthB', { ins = 0, outs = 1 }); ns[k4] = v4
      local k5, v5 = fx('midiComp', { ins = 0, outs = 0 }); ns[k5] = v5
      local tracks = tracksOf(mk(ns, {
        { type = 'midi',  from = 's1',     to = 'synthA' },
        { type = 'midi',  from = 's2',     to = 'synthB' },
        { type = 'midi',  from = 'synthA', to = 'midiComp' },
        { type = 'midi',  from = 'synthB', to = 'midiComp' },
      }))
      local compCls = t.key('guid-a', 'guid-b')
      t.eq(tracks[compCls].trackKind, 'newTrack')
      t.eq(#cuEntries(tracks[compCls]), 0, 'no merge CU for cross-track fan-in')
      t.deepEq(tracks[compCls].fxOrder, { 'midiComp' })
      t.deepEq(tracks['guid-a'].outWires,
               { { from = 'synthA', to = compCls, toNode = 'midiComp', type = 'midi' } })
      t.deepEq(tracks['guid-b'].outWires,
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
      local tracks = tracksOf(mk(ns, {
        { type = 'audio', from = 's1',   to = 'fx_a' },
        { type = 'audio', from = 's2',   to = 'fx_b', toPort = 1 },
        { type = 'audio', from = 'fx_a', to = 'fx_b', toPort = 2, ops = { gain = 0.5 } },
      }))
      local fxbCls = t.key('guid-a', 'guid-b')
      -- Folded boundary CU bypassed: outWire.from is fx_a (the real producer
      -- upstream of the CU), not the folded CU node id.
      t.deepEq(tracks['guid-a'].outWires,
               { { from = 'fx_a', fromPort = 1, to = fxbCls,
                   toNode = 'fx_b', toPort = 2, type = 'audio', gain = 0.5 } })
      t.deepEq(tracks['guid-a'].fxOrder, { 'fx_a' }, 'gain CU folded out of fxOrder')
    end,
  },
  {
    name = 'gain on the sole wire to master folds onto mainSendGain (no CU)',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('fx_a');            ns[k2] = v2
      local tracks = tracksOf(mk(ns, {
        { type = 'audio', from = 's',    to = 'fx_a' },
        { type = 'audio', from = 'fx_a', to = 'master', ops = { gain = 0.25 } },
      }))
      t.eq(tracks['guid-s'].mainSend, true)
      t.eq(tracks['guid-s'].mainSendGain, 0.25)
      t.deepEq(tracks['guid-s'].fxOrder, { 'fx_a' }, 'gain CU folded out of fxOrder')
    end,
  },
  {
    name = 'two wires to master from one class keep their CU (one fader, two gains)',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('fx_1');            ns[k2] = v2
      local k3, v3 = fx('fx_2');            ns[k3] = v3
      local tracks = tracksOf(mk(ns, {
        { type = 'audio', from = 's',    to = 'fx_1' },
        { type = 'audio', from = 's',    to = 'fx_2' },
        { type = 'audio', from = 'fx_1', to = 'master', ops = { gain = 0.5 } },
        { type = 'audio', from = 'fx_2', to = 'master' },
      }))
      t.eq(tracks['guid-s'].mainSend, true)
      t.eq(tracks['guid-s'].mainSendGain, nil, 'multi-path → no native fold')
      local hasCu = false
      for _, id in ipairs(tracks['guid-s'].fxOrder) do
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
      local tracks = tracksOf(mk(ns, {
        { type = 'audio', from = 's1', to = 'B' },
        { type = 'midi',  from = 's2', to = 'B' },
      }))
      t.eq(tracks['guid-s1|guid-s2'], nil, 'absorbed class has no tracks entry')
      t.eq(tracks['guid-s1'].trackKind, 'sourceTrack')
      t.deepEq(tracks['guid-s1'].fxOrder, { 'B' })
      t.deepEq(tracks['guid-s2'].outWires,
               { { from = 's2', to = 'guid-s1', toNode = 'B', type = 'midi' } })
    end,
  },

  {
    name = 'absorb: primary override picks trackKey even with two audio parents',
    run = function()
      local ns = {}
      local k,  v  = source('s1', 'guid-s1'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-s2'); ns[k2] = v2
      local k3, v3 = fx('B', { ins = 2, outs = 0 }); ns[k3] = v3
      local tracks = tracksOf(mk(ns, {
        { type = 'audio', from = 's1', to = 'B', toPort = 1, primary = true },
        { type = 'audio', from = 's2', to = 'B', toPort = 2 },
      }))
      t.eq(tracks['guid-s1|guid-s2'], nil)
      t.deepEq(tracks['guid-s1'].fxOrder, { 'B' })
      t.deepEq(tracks['guid-s2'].outWires,
               { { from = 's2', fromPort = 1, to = 'guid-s1',
                   toNode = 'B', toPort = 2, type = 'audio' } })
    end,
  },

  {
    name = 'absorb: chain through two hops lands on terminal source trackKey',
    run = function()
      -- mixB terminal (outs=0) keeps the chain's classes newTrack-eligible.
      local ns = {}
      local k1, v1 = source('s', 'guid-s'); ns[k1] = v1
      local k2, v2 = source('t', 'guid-t'); ns[k2] = v2
      local k3, v3 = source('u', 'guid-u'); ns[k3] = v3
      local k4, v4 = fx('mixA', { ins = 2, outs = 1 }); ns[k4] = v4
      local k5, v5 = fx('mixB', { ins = 2, outs = 0 }); ns[k5] = v5
      local tracks = tracksOf(mk(ns, {
        { type = 'audio', from = 's',    to = 'mixA', toPort = 1, primary = true },
        { type = 'audio', from = 't',    to = 'mixA', toPort = 2 },
        { type = 'audio', from = 'mixA', to = 'mixB', toPort = 1, primary = true },
        { type = 'audio', from = 'u',    to = 'mixB', toPort = 2 },
      }))
      t.eq(tracks[t.key('guid-s', 'guid-t')],             nil)
      t.eq(tracks[t.key('guid-s', 'guid-t', 'guid-u')], nil)
      t.eq(tracks['guid-s'].trackKind, 'sourceTrack')
      t.deepEq(tracks['guid-s'].fxOrder, { 'mixA', 'mixB' })
      t.deepEq(tracks['guid-t'].outWires,
               { { from = 't', fromPort = 1, to = 'guid-s',
                   toNode = 'mixA', toPort = 2, type = 'audio' } })
      t.deepEq(tracks['guid-u'].outWires,
               { { from = 'u', fromPort = 1, to = 'guid-s',
                   toNode = 'mixB', toPort = 2, type = 'audio' } })
    end,
  },

  {
    name = 'absorb: gain on now-intra-trackKey wire stays CU (no send to fold onto)',
    run = function()
      local ns = {}
      local k,  v  = source('s1', 'guid-s1'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-s2'); ns[k2] = v2
      local k3, v3 = fx('B', { ins = 2, outs = 0 }); ns[k3] = v3
      local tracks = tracksOf(mk(ns, {
        { type = 'audio', from = 's1', to = 'B', toPort = 1, primary = true,
          ops = { gain = 0.5 } },
        { type = 'audio', from = 's2', to = 'B', toPort = 2 },
      }))
      local order = tracks['guid-s1'].fxOrder
      t.eq(#order, 2, 'CU + B')
      t.eq(order[1], '_cu_1')
      t.eq(order[2], 'B')
    end,
  },

  {
    name = 'absorb: master-hosted class never absorbed even with single audio parent',
    run = function()
      -- master-hosted classes are exempt from absorption: A->master stays a parent
      -- send (mainSend + parentFeed on guid-s1), never folded intra.
      local ns = {}
      local k,  v  = source('s1', 'guid-s1'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-s2'); ns[k2] = v2
      local k3, v3 = fx('A');                 ns[k3] = v3
      local tracks = tracksOf(mk(ns, {
        { type = 'audio', from = 's1', to = 'A' },
        { type = 'audio', from = 'A',  to = 'master' },
        { type = 'midi',  from = 's2', to = 'master' },
      }))
      t.eq(tracks['__master__'], nil, 'FX-less master stays implicit')
      t.eq(tracks['guid-s1|guid-s2'], nil, 'master-hosted vacates merged key for sentinel')
      t.eq(tracks['guid-s1'].mainSend, true)
      t.deepEq(tracks['guid-s1'].parentFeed, { from = 'A', fromPort = 1, toNode = 'master', toPort = 1, sink = '__master__' }, 'not absorbed: A->master is a parent send')
      t.eq(tracks['guid-s2'].mainSend, true, 'midi to master-hosted lifts parent send')
      t.deepEq(tracks['guid-s1'].fxOrder, { 'A' })
      t.deepEq(tracks['guid-s2'].outWires, {})
    end,
  },

  {
    name = 'absorb: source-hosted class is never the absorbee (its trackKey is the source track)',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('f');               ns[k2] = v2
      local tracks = tracksOf(mk(ns, {
        { type = 'audio', from = 's', to = 'f' },
        { type = 'audio', from = 'f', to = 'master' },
      }))
      t.eq(tracks['guid-s'].trackKind, 'sourceTrack')
      t.deepEq(tracks['guid-s'].fxOrder, { 'f' })
      t.eq(tracks['guid-s'].mainSend, true)
    end,
  },

  {
    name = 'absorb: send from another non-trackKey class retargets to trackKey classKey',
    run = function()
      -- midfx (in class {s3}) sends audio into B's absorbed class — must
      -- retarget to guid-s1 (B's trackKey), not the merged-class key.
      local ns = {}
      local k1, v1 = source('s1', 'guid-s1'); ns[k1] = v1
      local k2, v2 = source('s2', 'guid-s2'); ns[k2] = v2
      local k3, v3 = source('s3', 'guid-s3'); ns[k3] = v3
      local k4, v4 = fx('midfx');                       ns[k4] = v4
      local k5, v5 = fx('B', { ins = 2, outs = 0 });    ns[k5] = v5
      local tracks = tracksOf(mk(ns, {
        { type = 'audio', from = 's1',    to = 'B', toPort = 1, primary = true },
        { type = 'midi',  from = 's2',    to = 'B' },
        { type = 'audio', from = 's3',    to = 'midfx' },
        { type = 'audio', from = 'midfx', to = 'B', toPort = 2 },
      }))
      t.eq(tracks['guid-s1|guid-s2|guid-s3'], nil, 'absorbed class vacated')
      t.deepEq(tracks['guid-s1'].fxOrder, { 'B' })
      t.deepEq(tracks['guid-s2'].outWires,
               { { from = 's2', to = 'guid-s1', toNode = 'B', type = 'midi' } })
      t.deepEq(tracks['guid-s3'].outWires,
               { { from = 'midfx', fromPort = 1, to = 'guid-s1',
                   toNode = 'B', toPort = 2, type = 'audio' } })
    end,
  },

  -- intraConns: anchors track-IO and per-FX-pin context for the allocator.
  --   * source -> fx     = track input pair -> fx input pin
  --   * fx     -> fx     = intra-class chain conn
  --   * fx     -> master = trackKey's audio output pair -> REAPER master input
  -- Folded CUs (gain bridges on inter-trackKey wires) never appear; the inter-trackKey
  -- conn carries the gain via outWires.gain instead.

  {
    name = 'intraConns: source -> fx is the only intra wire; fx -> master is a parent send',
    run = function()
      -- master owns its own class, so f->master crosses to the REAPER master as a
      -- parent send (mainSend + parentFeed), not an intra-trackKey anchor.
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('f');               ns[k2] = v2
      local tracks = tracksOf(mk(ns, {
        { type = 'audio', from = 's', to = 'f' },
        { type = 'audio', from = 'f', to = 'master' },
      }))
      t.deepEq(tracks['guid-s'].intraConns, {
        { from = 's', fromPort = 1, to = 'f', toPort = 1, type = 'audio' },
      })
      t.eq(tracks['guid-s'].mainSend, true)
      t.deepEq(tracks['guid-s'].parentFeed, { from = 'f', fromPort = 1, toNode = 'master', toPort = 1, sink = '__master__' })
    end,
  },

  {
    name = 'intraConns: fx -> fx chain conn carries both port indices',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s');                       ns[k]  = v
      local k2, v2 = fx('a', { outs = 2 });                       ns[k2] = v2
      local k3, v3 = fx('b', { ins = 2, outs = 0 });              ns[k3] = v3
      local tracks = tracksOf(mk(ns, {
        { type = 'audio', from = 's', to = 'a' },
        { type = 'audio', from = 'a', to = 'b', fromPort = 1, toPort = 1 },
        { type = 'audio', from = 'a', to = 'b', fromPort = 2, toPort = 2 },
      }))
      local ic = tracks['guid-s'].intraConns
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
      local tracks = tracksOf(mk(ns, {
        { type = 'audio', from = 's1',  to = 'mix', toPort = 1 },
        { type = 'audio', from = 's2',  to = 'mix', toPort = 2 },
        { type = 'audio', from = 'mix', to = 'master' },
      }))
      -- Sources s1/s2 are in their own classes; wires to mix lift to mainSend.
      -- Only mix->master is intra-trackKey on the master-hosted class.
      t.deepEq(tracks['__master__'].intraConns, {
        { from = 'mix', fromPort = 1, to = 'master', toPort = 1, type = 'audio' },
      })
      t.eq(tracks['guid-a'].mainSend, true, 'source->mix lifts to mainSend')
      t.eq(tracks['guid-b'].mainSend, true, 'source->mix lifts to mainSend')
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
      local tracks = tracksOf(mk(ns, {
        { type = 'audio', from = 's1',   to = 'fx_a' },
        { type = 'audio', from = 's2',   to = 'fx_b', toPort = 1 },
        { type = 'audio', from = 'fx_a', to = 'fx_b', toPort = 2, ops = { gain = 0.5 } },
      }))
      for _, c in ipairs(tracks['guid-a'].intraConns) do
        t.eq(c.from:match('^_cu_'), nil, 'no folded CU as intraConn from')
        t.eq(c.to  :match('^_cu_'), nil, 'no folded CU as intraConn to')
      end
      t.deepEq(tracks['guid-a'].intraConns,
               { { from = 's1', fromPort = 1, to = 'fx_a', toPort = 1, type = 'audio' } })
    end,
  },

  -- parentFeed: pins (post-fold) audio producer feeding the parent send for
  -- non-master hosts whose audio crosses into the master-hosted trackKey.

  {
    name = 'parentFeed: cross-trackKey source-to-master stamps source on sender',
    run = function()
      -- two-source fanin: mix lives in master-hosted trackKey; both sources contribute
      -- audio that lifts to mainSend. Each sender's parentFeed names its source.
      local ns = {}
      local k,  v  = source('s1', 'guid-a'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-b'); ns[k2] = v2
      local k3, v3 = fx('mix', { ins = 2 }); ns[k3] = v3
      local tracks = tracksOf(mk(ns, {
        { type = 'audio', from = 's1',  to = 'mix', toPort = 1 },
        { type = 'audio', from = 's2',  to = 'mix', toPort = 2 },
        { type = 'audio', from = 'mix', to = 'master' },
      }))
      t.deepEq(tracks['guid-a'].parentFeed, { from = 's1', fromPort = 1, toNode = 'mix', toPort = 1, sink = '__master__' })
      t.deepEq(tracks['guid-b'].parentFeed, { from = 's2', fromPort = 1, toNode = 'mix', toPort = 2, sink = '__master__' })
    end,
  },

  {
    name = 'parentFeed: cross-trackKey fx-to-master names the fx producer (post-fold)',
    run = function()
      -- fx_pre lives in s1's class; its output crosses into the master-hosted
      -- trackKey (where mix lives). parentFeed on guid-a names fx_pre.
      local ns = {}
      local k,  v  = source('s1', 'guid-a');  ns[k]  = v
      local k2, v2 = source('s2', 'guid-b');  ns[k2] = v2
      local k3, v3 = fx('fx_pre');            ns[k3] = v3
      local k4, v4 = fx('mix', { ins = 2 });  ns[k4] = v4
      local tracks = tracksOf(mk(ns, {
        { type = 'audio', from = 's1',     to = 'fx_pre' },
        { type = 'audio', from = 'fx_pre', to = 'mix', toPort = 1 },
        { type = 'audio', from = 's2',     to = 'mix', toPort = 2 },
        { type = 'audio', from = 'mix',    to = 'master' },
      }))
      t.deepEq(tracks['guid-a'].parentFeed, { from = 'fx_pre', fromPort = 1, toNode = 'mix', toPort = 1, sink = '__master__' })
      t.deepEq(tracks['guid-b'].parentFeed, { from = 's2',     fromPort = 1, toNode = 'mix', toPort = 2, sink = '__master__' })
    end,
  },

  {
    name = 'parentFeed: folded gain CU on master-bound wire bypassed to real producer',
    run = function()
      local ns = {}
      local k,  v  = source('s1', 'guid-a');  ns[k]  = v
      local k2, v2 = source('s2', 'guid-b');  ns[k2] = v2
      local k3, v3 = fx('fx_pre');            ns[k3] = v3
      local k4, v4 = fx('mix', { ins = 2 });  ns[k4] = v4
      local tracks = tracksOf(mk(ns, {
        { type = 'audio', from = 's1',     to = 'fx_pre' },
        { type = 'audio', from = 'fx_pre', to = 'mix', toPort = 1, ops = { gain = 0.5 } },
        { type = 'audio', from = 's2',     to = 'mix', toPort = 2 },
        { type = 'audio', from = 'mix',    to = 'master' },
      }))
      t.deepEq(tracks['guid-a'].parentFeed, { from = 'fx_pre', fromPort = 1, toNode = 'mix', toPort = 1, sink = '__master__' })
      t.eq(tracks['guid-a'].mainSendGain, 0.5)
    end,
  },


  {
    name = 'parentFeed: midi cross-trackKey to master-hosted does not set parentFeed',
    run = function()
      -- s2's midi wire to master lifts mainSend; parentFeed is audio-only.
      local ns = {}
      local k,  v  = source('s1', 'guid-s1'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-s2'); ns[k2] = v2
      local k3, v3 = fx('A');                 ns[k3] = v3
      local tracks = tracksOf(mk(ns, {
        { type = 'audio', from = 's1', to = 'A' },
        { type = 'audio', from = 'A',  to = 'master' },
        { type = 'midi',  from = 's2', to = 'master' },
      }))
      t.eq(tracks['guid-s2'].mainSend, true)
      t.eq(tracks['guid-s2'].parentFeed, nil, 'midi master wire stays bool-only')
    end,
  },

  {
    name = 'intraConns: un-folded gain CU on intra-trackKey wire is included',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('fx_1');            ns[k2] = v2
      local k3, v3 = fx('fx_2');            ns[k3] = v3
      local tracks = tracksOf(mk(ns, {
        { type = 'audio', from = 's',    to = 'fx_1', ops = { gain = 0.5 } },
        { type = 'audio', from = 's',    to = 'fx_2' },
        { type = 'audio', from = 'fx_1', to = 'master' },
        { type = 'audio', from = 'fx_2', to = 'master' },
      }))
      -- The gain CU is the one the source feeds; the master fan-in adds a
      -- separate sum CU, so identify by the s -> CU wire, not "last _cu_".
      local gainCu = nil
      for _, c in ipairs(tracks['guid-s'].intraConns) do
        if c.from == 's' and c.to:match('^_cu_') then gainCu = c.to end
      end
      t.truthy(gainCu, 'gain CU fed by source retained (no fold)')
      local sawSToCu, sawCuToFx1 = false, false
      for _, c in ipairs(tracks['guid-s'].intraConns) do
        if c.from == 's'      and c.to == gainCu then sawSToCu = true end
        if c.from == gainCu   and c.to == 'fx_1' then sawCuToFx1 = true end
      end
      t.truthy(sawSToCu,   's -> gain CU intraConn present')
      t.truthy(sawCuToFx1, 'gain CU -> fx_1 intraConn present')
    end,
  },

  ----- 3c.4.4: per-consumer merge nodes

  {
    name = 'merge: intra gain is a per-consumer merge CU (nPairs=1, audioSum=0)',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('fx_a');            ns[k2] = v2
      local tracks = tracksOf(mk(ns, {
        { type = 'audio', from = 's',    to = 'fx_a', ops = { gain = 0.5 } },
        { type = 'audio', from = 'fx_a', to = 'master' },
      }))
      local list = cuEntries(tracks['guid-s'])
      t.eq(#list, 1, 'one merge CU synthesised')
      local cu = list[1].node
      t.eq(cu.fxIdent,         'JS:Continuum Utility')
      t.eq(cu.params.mode,     'merge')
      t.eq(cu.params.nPairs,   1)
      t.deepEq(cu.params.gains, { 0.5 })
      t.eq(cu.params.audioSum, 0, 'matrix-fed sink, no internal sum')
      t.eq(cu.originConsumer,  'fx_a')
      t.eq(cu.originTrackKey,      'guid-s')
      t.deepEq(cu.inputEdges,  { 1 }, 'maps pair 1 back to the gained edge')
    end,
  },
  {
    name = 'merge: two gained wires to master collapse to one audioSum CU (last-wins fix)',
    run = function()
      -- Master gets its own track (two source classes feed it), so trackKey guid-a's
      -- two wires to master would last-wins on parentFeed without the merge.
      local ns = {}
      local k,  v  = source('s1', 'guid-a'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-b'); ns[k2] = v2
      local k3, v3 = fx('fx_1');             ns[k3] = v3
      local k4, v4 = fx('fx_2');             ns[k4] = v4
      local k5, v5 = fx('fx_3');             ns[k5] = v5
      local tracks = tracksOf(mk(ns, {
        { type = 'audio', from = 's1',   to = 'fx_1' },
        { type = 'audio', from = 's1',   to = 'fx_2' },
        { type = 'audio', from = 's2',   to = 'fx_3' },
        { type = 'audio', from = 'fx_1', to = 'master', ops = { gain = 0.5 } },
        { type = 'audio', from = 'fx_2', to = 'master', ops = { gain = 0.8 } },
        { type = 'audio', from = 'fx_3', to = 'master' },
      }))
      local list = cuEntries(tracks['guid-a'])
      t.eq(#list, 1, 'fan-in collapses to a single merge CU')
      local cu = list[1].node
      t.eq(cu.params.mode,     'merge')
      t.eq(cu.params.nPairs,   2)
      t.eq(cu.params.audioSum, 1, 'matrix-less master sink sums internally')
      t.deepEq(cu.params.gains, { 0.5, 0.8 })
      t.eq(cu.originConsumer,  'master')
      t.eq(cu.originTrackKey,      'guid-a')
      t.deepEq(cu.inputEdges,  { 4, 5 })
      -- The parent send sees ONE producer (the CU), not two competing feeds.
      t.eq(tracks['guid-a'].parentFeed.from, list[1].id, 'parentFeed points at the merge CU')
    end,
  },
  {
    name = 'merge: matrix-fed audio fan-in past 16 fans out to a CU cascade',
    run = function()
      -- 17 gained wires into one fx consumer exceed the 16-wide gain bank, so the
      -- merge fans out to two parallel CUs (16+1); cascade CUs take a '#N' suffix.
      local ns = {}
      local k,  v  = source('s', 'guid-s');             ns[k]  = v
      local k2, v2 = fx('fxP', { ins = 1, outs = 17 }); ns[k2] = v2
      local k3, v3 = fx('C',   { ins = 1, outs = 0 });  ns[k3] = v3
      local edges = { { type = 'audio', from = 's', to = 'fxP' } }
      for p = 1, 17 do
        edges[#edges+1] = { type = 'audio', from = 'fxP', to = 'C',
                            fromPort = p, toPort = 1, ops = { gain = 0.5 } }
      end
      local tracks = tracksOf(mk(ns, edges))
      local list = cuEntries(tracks['guid-s'])
      t.eq(#list, 2, 'two merge CUs for 17 feeders')
      local byKey = {}
      for _, e in ipairs(list) do byKey[e.node.originTrackKey] = e.node end
      t.truthy(byKey['guid-s'] and byKey['guid-s#2'], 'identity suffixed per cascade CU')
      t.eq(byKey['guid-s'].params.nPairs,    16)
      t.eq(byKey['guid-s#2'].params.nPairs,  1)
      t.eq(byKey['guid-s'].params.audioSum,  0, 'matrix-fed, no internal sum')
      t.eq(byKey['guid-s#2'].params.audioSum, 0)
      t.eq(byKey['guid-s'].originConsumer,   'C')
      t.eq(byKey['guid-s#2'].originConsumer, 'C')
      t.eq(#byKey['guid-s'].inputEdges,   16)
      t.eq(#byKey['guid-s#2'].inputEdges, 1)
    end,
  },
  {
    name = 'merge: parent-send audio fan-in past 16 builds a sum-tree of CUs',
    run = function()
      -- 17 audio wires from one class to the master-hosted track exceed the 16-wide
      -- bank; the matrix-less parent send sums them through a sum-tree to parentFeed.
      local ns = {}
      local k,  v  = source('s1', 'guid-a');            ns[k]  = v
      local k2, v2 = source('s2', 'guid-b');            ns[k2] = v2
      local k3, v3 = fx('fxP', { ins = 1, outs = 17 }); ns[k3] = v3
      local k4, v4 = fx('fxQ', { ins = 1, outs = 1 });  ns[k4] = v4
      local edges = {
        { type = 'audio', from = 's1',  to = 'fxP' },
        { type = 'audio', from = 's2',  to = 'fxQ' },
        { type = 'audio', from = 'fxQ', to = 'master' },
      }
      for p = 1, 17 do
        edges[#edges+1] = { type = 'audio', from = 'fxP', to = 'master', fromPort = p }
      end
      local tracks = tracksOf(mk(ns, edges))
      local cus = cuEntries(tracks['guid-a'])
      t.eq(#cus, 3, '2 leaf CUs + 1 root')
      local leaves, root = {}, nil
      for _, e in ipairs(cus) do
        t.eq(e.node.params.audioSum,  1, 'sum-tree CU sums internally')
        t.eq(e.node.originConsumer, 'master')
        if e.node.inputEdges then leaves[#leaves+1] = e else root = e end
      end
      t.eq(#leaves, 2, 'two leaves carry the user edges')
      t.truthy(root, 'one internal root CU (no user edges)')
      t.eq(tracks['guid-a'].parentFeed.from, root.id, 'parentFeed is the tree root')
    end,
  },
  {
    name = 'merge: distinct consumers get distinct merge CUs (per-consumer identity)',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('fx_a');            ns[k2] = v2
      local k3, v3 = fx('fx_b');            ns[k3] = v3
      local tracks = tracksOf(mk(ns, {
        { type = 'audio', from = 's',    to = 'fx_a', ops = { gain = 0.5 } },
        { type = 'audio', from = 's',    to = 'fx_b', ops = { gain = 0.7 } },
        { type = 'audio', from = 'fx_a', to = 'master' },
        { type = 'audio', from = 'fx_b', to = 'master' },
      }))
      local byConsumer = {}
      for _, e in ipairs(cuEntries(tracks['guid-s'])) do byConsumer[e.node.originConsumer] = e.node end
      t.truthy(byConsumer.fx_a and byConsumer.fx_b, 'one merge CU per consumer')
      t.deepEq(byConsumer.fx_a.params.gains, { 0.5 })
      t.deepEq(byConsumer.fx_b.params.gains, { 0.7 })
    end,
  },
}
