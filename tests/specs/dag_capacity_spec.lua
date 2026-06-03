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

local function errorsOf(g)
  return DAG.compile(g):capacityErrors()
end

return {
  {
    name = 'empty graph: no errors',
    run = function()
      t.deepEq(errorsOf(mk({})), {})
    end,
  },
  {
    name = 'audio passthrough chain: 2 intra-class conns, no errors',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('f');               ns[k2] = v2
      t.deepEq(errorsOf(mk(ns, {
        { type = 'audio', from = 's', to = 'f' },
        { type = 'audio', from = 'f', to = 'master' },
      })), {})
    end,
  },
  {
    name = 'intra-class audio at 64: no error',
    run = function()
      -- one class: source→a (1 conn) + 63 stereo wires a→b (63 conns) = 64.
      local ns = {}
      local k,  v  = source('s', 'guid-s');           ns[k]  = v
      local k2, v2 = fx('a', { ins = 1, outs = 63 }); ns[k2] = v2
      local k3, v3 = fx('b', { ins = 63 });           ns[k3] = v3
      local edges = { { type = 'audio', from = 's', to = 'a' } }
      for p = 1, 63 do
        edges[#edges+1] = { type = 'audio', from = 'a', to = 'b',
                            fromPort = p, toPort = p }
      end
      t.deepEq(errorsOf(mk(ns, edges)), {})
    end,
  },
  {
    name = 'intra-class audio > 64 raises one error',
    run = function()
      -- source→a (1) + 64 stereo wires a→b (64) = 65 intra-class audio conns.
      local ns = {}
      local k,  v  = source('s', 'guid-s');           ns[k]  = v
      local k2, v2 = fx('a', { ins = 1, outs = 64 }); ns[k2] = v2
      local k3, v3 = fx('b', { ins = 64 });           ns[k3] = v3
      local edges = { { type = 'audio', from = 's', to = 'a' } }
      for p = 1, 64 do
        edges[#edges+1] = { type = 'audio', from = 'a', to = 'b',
                            fromPort = p, toPort = p }
      end
      local errs = errorsOf(mk(ns, edges))
      t.eq(#errs, 1)
      t.eq(errs[1].trackKey, 'guid-s')
      t.eq(errs[1].kind,     'audio')
      t.eq(errs[1].count,    65)
    end,
  },
  {
    name = 'intra-class midi > 128 raises one error',
    run = function()
      -- 130 MIDI wires in one class via chain s -> f1 -> ... -> f130.
      local ns = {}
      local k, v = source('s', 'guid-s'); ns[k] = v
      local N = 130
      for i = 1, N do
        local k2, v2 = fx('f' .. i); ns[k2] = v2
      end
      local edges = { { type = 'midi', from = 's', to = 'f1' } }
      for i = 1, N - 1 do
        edges[#edges+1] = { type = 'midi', from = 'f' .. i, to = 'f' .. (i+1) }
      end
      local errs = errorsOf(mk(ns, edges))
      t.eq(#errs, 1)
      t.eq(errs[1].trackKey, 'guid-s')
      t.eq(errs[1].kind,     'midi')
      t.eq(errs[1].count,    N)
    end,
  },
  {
    name = 'inter-class conns are not counted (own class only)',
    run = function()
      -- Two sources, each feeding mix on a different in-port. Inter-class
      -- conns into mix don't count against mix's intra-class capacity.
      local ns = {}
      local k,  v  = source('s1', 'guid-a');   ns[k]  = v
      local k2, v2 = source('s2', 'guid-b');   ns[k2] = v2
      local k3, v3 = fx('mix', { ins = 2 });   ns[k3] = v3
      local errs = errorsOf(mk(ns, {
        { type = 'audio', from = 's1', to = 'mix', toPort = 1 },
        { type = 'audio', from = 's2', to = 'mix', toPort = 2 },
      }))
      t.deepEq(errs, {})
    end,
  },
  {
    name = 'audio and midi overflow on same class: two errors, sorted by kind',
    run = function()
      local ns = {}
      local k, v = source('s', 'guid-s'); ns[k] = v
      -- 65 intra-class audio conns: source→a (1) + 64 a→b (64).
      local k2, v2 = fx('a', { ins = 1, outs = 64 }); ns[k2] = v2
      local k3, v3 = fx('b', { ins = 64 });           ns[k3] = v3
      local edges = { { type = 'audio', from = 's', to = 'a' } }
      for p = 1, 64 do
        edges[#edges+1] = { type = 'audio', from = 'a', to = 'b',
                            fromPort = p, toPort = p }
      end
      -- 130 MIDI wires intra-class via chain m1 -> m2 -> ... -> m130.
      local N = 130
      for i = 1, N do
        local k4, v4 = fx('m' .. i); ns[k4] = v4
      end
      edges[#edges+1] = { type = 'midi', from = 's', to = 'm1' }
      for i = 1, N - 1 do
        edges[#edges+1] = { type = 'midi', from = 'm' .. i, to = 'm' .. (i+1) }
      end
      local errs = errorsOf(mk(ns, edges))
      t.eq(#errs, 2)
      t.eq(errs[1].kind, 'audio')
      t.eq(errs[2].kind, 'midi')
    end,
  },
}
