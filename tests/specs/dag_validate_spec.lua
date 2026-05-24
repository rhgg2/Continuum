local t   = require('support')
local DAG = require('DAG')

local function source(id, guid)
  return id, { kind = 'source', trackGuid = guid or 'guid-' .. id,
               pos = { x = 0, y = 0 } }
end

local function fx(id, opts)
  opts = opts or {}
  return id, { kind = 'fx', pos = { x = 0, y = 0 },
               fxIdent   = opts.ident   or 'JS:test',
               fxDisplay = opts.display or 'FX',
               audio = { ins  = opts.ins  or { 'L', 'R' },
                         outs = opts.outs or { 'L', 'R' } } }
end

local function master(opts)
  opts = opts or {}
  return 'master', { kind = 'master', pos = { x = 0, y = 0 },
                     audio = { ins = opts.ins or { 'L', 'R' } } }
end

-- mk auto-adds a default master (matches production: every graph has one)
-- unless opts.noMaster is set, or the caller already supplied one.
local function mk(nodes, edges, opts)
  opts = opts or {}
  if not opts.noMaster and not nodes.master then
    local k, v = master()
    nodes[k] = v
  end
  return { nodes = nodes, edges = edges or {}, _nextId = 1 }
end

return {
  {
    name = 'empty graph passes',
    run = function()
      t.eq(DAG.validate(mk({})), nil)
    end,
  },
  {
    name = 'edge with unknown from-id rejects',
    run = function()
      local ns = {} local k, v = source('a'); ns[k] = v
      local err = DAG.validate(mk(ns, {
        { type = 'audio', from = 'ghost', to = 'a' },
      }))
      t.eq(err.code, 'unknown_from')
      t.eq(err.id,   'ghost')
    end,
  },
  {
    name = 'edge with unknown to-id rejects',
    run = function()
      local ns = {} local k, v = source('a'); ns[k] = v
      local err = DAG.validate(mk(ns, {
        { type = 'audio', from = 'a', to = 'ghost' },
      }))
      t.eq(err.code, 'unknown_to')
      t.eq(err.id,   'ghost')
    end,
  },
  {
    name = 'source-as-sink rejects on audio',
    run = function()
      local ns = {}
      local k, v = source('a'); ns[k] = v
      local k2, v2 = source('b'); ns[k2] = v2
      local err = DAG.validate(mk(ns, {
        { type = 'audio', from = 'a', to = 'b' },
      }))
      t.eq(err.code, 'source_as_sink')
      t.eq(err.id,   'b')
    end,
  },
  {
    name = 'source-as-sink rejects on midi',
    run = function()
      local ns = {}
      local k, v = source('a'); ns[k] = v
      local k2, v2 = source('b'); ns[k2] = v2
      local err = DAG.validate(mk(ns, {
        { type = 'midi', from = 'a', to = 'b' },
      }))
      t.eq(err.code, 'source_as_sink')
    end,
  },
  {
    name = 'MIDI edge with port index rejects',
    run = function()
      local ns = {}
      local k, v = source('a'); ns[k] = v
      local k2, v2 = fx('b'); ns[k2] = v2
      local err = DAG.validate(mk(ns, {
        { type = 'midi', from = 'a', to = 'b', fromPort = 1 },
      }))
      t.eq(err.code, 'midi_port_index')
    end,
  },
  {
    name = 'audio from-port out of range rejects',
    run = function()
      local ns = {}
      local k, v = source('a'); ns[k] = v
      local k2, v2 = fx('b'); ns[k2] = v2
      local err = DAG.validate(mk(ns, {
        { type = 'audio', from = 'a', to = 'b', fromPort = 2 },
      }))
      t.eq(err.code, 'audio_from_port_oob')
      t.eq(err.have, 1)
    end,
  },
  {
    name = 'audio to-port out of range rejects',
    run = function()
      local ns = {}
      local k, v = source('a'); ns[k] = v
      local k2, v2 = fx('b', { ins = { 'L', 'R' } }); ns[k2] = v2
      local err = DAG.validate(mk(ns, {
        { type = 'audio', from = 'a', to = 'b', toPort = 2 },
      }))
      t.eq(err.code, 'audio_to_port_oob')
      t.eq(err.have, 1)
    end,
  },
  {
    name = 'audio edge to MIDI-only FX (no audio pairs) rejects',
    run = function()
      local ns = {}
      local k, v = source('a'); ns[k] = v
      local k2, v2 = fx('b', { ins = {}, outs = {} }); ns[k2] = v2
      local err = DAG.validate(mk(ns, {
        { type = 'audio', from = 'a', to = 'b' },
      }))
      t.eq(err.code, 'audio_to_port_oob')
      t.eq(err.have, 0)
    end,
  },
  {
    name = 'audio edge: nil port resolves to pair 1 (single-pair fx)',
    run = function()
      local ns = {}
      local k, v = source('a'); ns[k] = v
      local k2, v2 = fx('b', { ins = { 'L', 'R' } }); ns[k2] = v2
      t.eq(DAG.validate(mk(ns, {
        { type = 'audio', from = 'a', to = 'b' },
      })), nil)
    end,
  },
  {
    name = 'audio edge: explicit pairIdx=2 valid on 4-channel fx',
    run = function()
      local ns = {}
      local k, v = source('a'); ns[k] = v
      local k2, v2 = fx('b', { ins = { 'L', 'R', 'L', 'R' } }); ns[k2] = v2
      t.eq(DAG.validate(mk(ns, {
        { type = 'audio', from = 'a', to = 'b', toPort = 2 },
      })), nil)
    end,
  },
  {
    name = 'audio edge: trailing odd channel forms a valid mono pair',
    run = function()
      local ns = {}
      local k, v = source('a'); ns[k] = v
      local k2, v2 = fx('b', { ins = { 'L', 'R', 'C' } }); ns[k2] = v2
      -- pair 3 = channel 5? no — {L,R,C} has 3 chans => pairs={2,1}, so pair 2 = mono.
      t.eq(DAG.validate(mk(ns, {
        { type = 'audio', from = 'a', to = 'b', toPort = 2 },
      })), nil)
    end,
  },
  {
    name = 'self-loop is a cycle',
    run = function()
      local ns = {} local k, v = fx('a'); ns[k] = v
      local err = DAG.validate(mk(ns, {
        { type = 'midi', from = 'a', to = 'a' },
      }))
      t.eq(err.code, 'cycle')
      t.eq(err.at,   'a')
    end,
  },
  {
    name = 'two-cycle (A→B, B→A) rejects',
    run = function()
      local ns = {}
      local k, v = fx('a'); ns[k] = v
      local k2, v2 = fx('b'); ns[k2] = v2
      local err = DAG.validate(mk(ns, {
        { type = 'midi', from = 'a', to = 'b' },
        { type = 'midi', from = 'b', to = 'a' },
      }))
      t.eq(err.code, 'cycle')
    end,
  },
  {
    name = 'three-cycle (A→B→C→A) rejects',
    run = function()
      local ns = {}
      local k, v   = fx('a'); ns[k]   = v
      local k2, v2 = fx('b'); ns[k2] = v2
      local k3, v3 = fx('c'); ns[k3] = v3
      local err = DAG.validate(mk(ns, {
        { type = 'midi', from = 'a', to = 'b' },
        { type = 'midi', from = 'b', to = 'c' },
        { type = 'midi', from = 'c', to = 'a' },
      }))
      t.eq(err.code, 'cycle')
    end,
  },
  {
    name = 'cycle across audio and midi layers rejects',
    run = function()
      -- a --audio--> b --midi--> a: a cycle even though no single edge type loops.
      local ns = {}
      local k, v = fx('a'); ns[k] = v
      local k2, v2 = fx('b'); ns[k2] = v2
      local err = DAG.validate(mk(ns, {
        { type = 'audio', from = 'a', to = 'b' },
        { type = 'midi',  from = 'b', to = 'a' },
      }))
      t.eq(err.code, 'cycle')
    end,
  },
  {
    name = 'DAG with fan-in and fan-out passes',
    run = function()
      local ns = {}
      local k, v   = source('s1'); ns[k]   = v
      local k2, v2 = source('s2'); ns[k2] = v2
      local k3, v3 = fx('mix', { ins = { 'L', 'R', 'L', 'R' } }); ns[k3] = v3
      local k4, v4 = fx('split', { outs = { 'L', 'R', 'L', 'R' } }); ns[k4] = v4
      t.eq(DAG.validate(mk(ns, {
        { type = 'audio', from = 's1',  to = 'mix', toPort = 1 },
        { type = 'audio', from = 's2',  to = 'mix', toPort = 2 },
        { type = 'audio', from = 'mix', to = 'split' },
      })), nil)
    end,
  },
  {
    name = 'no master rejects (singleton)',
    run = function()
      local err = DAG.validate(mk({}, {}, { noMaster = true }))
      t.eq(err.code,  'master_singleton')
      t.eq(err.count, 0)
    end,
  },
  {
    name = 'two masters reject (singleton)',
    run = function()
      local ns = {}
      local k,  v  = master(); ns[k] = v
      ns.master2 = { kind = 'master', pos = { x = 0, y = 0 },
                     audio = { ins = { 'L', 'R' } } }
      local err = DAG.validate({ nodes = ns, edges = {}, _nextId = 1 })
      t.eq(err.code,  'master_singleton')
      t.eq(err.count, 2)
    end,
  },
  {
    name = 'master cannot be `from` of any edge',
    run = function()
      local ns = {}
      local k, v = fx('b'); ns[k] = v
      local err = DAG.validate(mk(ns, {
        { type = 'audio', from = 'master', to = 'b' },
      }))
      t.eq(err.code, 'master_as_source')
      t.eq(err.id,   'master')
    end,
  },
  {
    name = 'MIDI wire to master rejects',
    run = function()
      local ns = {}
      local k, v = source('a'); ns[k] = v
      local err = DAG.validate(mk(ns, {
        { type = 'midi', from = 'a', to = 'master' },
      }))
      t.eq(err.code, 'midi_to_master')
    end,
  },
  {
    name = 'audio wire from source to master passes',
    run = function()
      local ns = {}
      local k, v = source('a'); ns[k] = v
      t.eq(DAG.validate(mk(ns, {
        { type = 'audio', from = 'a', to = 'master' },
      })), nil)
    end,
  },
  {
    name = 'audio wire to master with port=2 oob (default ins={L,R}) rejects',
    run = function()
      local ns = {}
      local k, v = source('a'); ns[k] = v
      local err = DAG.validate(mk(ns, {
        { type = 'audio', from = 'a', to = 'master', toPort = 2 },
      }))
      t.eq(err.code, 'audio_to_port_oob')
      t.eq(err.have, 1)
    end,
  },
  {
    name = 'audio wire to master with explicit pair 2 (4-ch master) passes',
    run = function()
      local ns = {}
      local k,  v  = master({ ins = { 'L', 'R', 'L', 'R' } }); ns[k] = v
      local k2, v2 = source('a');                              ns[k2] = v2
      t.eq(DAG.validate({ nodes = ns, edges = {
        { type = 'audio', from = 'a', to = 'master', toPort = 2 },
      }, _nextId = 1 }), nil)
    end,
  },
  {
    name = 'unknown edge type rejects',
    run = function()
      local ns = {}
      local k, v = source('a'); ns[k] = v
      local k2, v2 = fx('b'); ns[k2] = v2
      local err = DAG.validate(mk(ns, {
        { type = 'video', from = 'a', to = 'b' },
      }))
      t.eq(err.code, 'unknown_edge_type')
    end,
  },
}
