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

local function mk(nodes, edges)
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
