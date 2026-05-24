local t   = require('support')
local DAG = require('DAG')

local function source(id, guid)
  return id, { kind = 'source', trackGuid = guid or 'guid-' .. id,
               pos = { x = 0, y = 0 } }
end

local function rep(ch, n)
  local out = {}
  for i = 1, n do out[i] = ch end
  return out
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

local function mk(nodes, edges)
  if not nodes.master then
    local k, v = master(); nodes[k] = v
  end
  return { nodes = nodes, edges = edges or {}, _nextId = 1 }
end

local function errorsOf(g)
  local c = DAG.lower(g)
  return DAG.capacityErrors(c, DAG.classes(c))
end

return {
  {
    name = 'empty graph: no errors',
    run = function()
      t.deepEq(errorsOf(mk({})), {})
    end,
  },
  {
    name = 'stereo passthrough chain: 2 intra-class conns, no errors',
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
      -- one class: source (2-ch out) + 31 stereo pairs a -> b = 64 conns.
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('a', { ins = rep('L', 62), outs = rep('L', 62) }); ns[k2] = v2
      local k3, v3 = fx('b', { ins = rep('L', 62), outs = rep('L', 62) }); ns[k3] = v3
      local edges = { { type = 'audio', from = 's', to = 'a' } }  -- 2 conns
      for p = 1, 31 do                                            -- + 62 conns
        edges[#edges+1] = { type = 'audio', from = 'a', to = 'b',
                            fromPort = p, toPort = p }
      end
      t.deepEq(errorsOf(mk(ns, edges)), {})
    end,
  },
  {
    name = 'intra-class audio > 64 raises one error',
    run = function()
      -- source (2) + 32 stereo pairs a -> b (64) = 66 intra-class audio conns.
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('a', { ins = rep('L', 64), outs = rep('L', 64) }); ns[k2] = v2
      local k3, v3 = fx('b', { ins = rep('L', 64), outs = rep('L', 64) }); ns[k3] = v3
      local edges = { { type = 'audio', from = 's', to = 'a' } }
      for p = 1, 32 do
        edges[#edges+1] = { type = 'audio', from = 'a', to = 'b',
                            fromPort = p, toPort = p }
      end
      local errs = errorsOf(mk(ns, edges))
      t.eq(#errs, 1)
      t.eq(errs[1].classKey, 'guid-s')
      t.eq(errs[1].kind,     'audio')
      t.eq(errs[1].count,    66)
    end,
  },
  {
    name = 'intra-class midi > 128 raises one error',
    run = function()
      -- 129 MIDI wires inside a single class would require 129 distinct
      -- nodes; use a chain a1 -> a2 -> ... -> a130 in one class.
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
      t.eq(errs[1].classKey, 'guid-s')
      t.eq(errs[1].kind,     'midi')
      t.eq(errs[1].count,    N)  -- 130 midi conns
    end,
  },
  {
    name = 'inter-class conns are not counted (own class only)',
    run = function()
      -- Two sources, each chained into a wide FX whose outputs merge into a
      -- big stereo mix. Inter-class conns into the mix don't count against
      -- the mix's intra-class capacity.
      local ns = {}
      local k,  v  = source('s1', 'guid-a'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-b'); ns[k2] = v2
      local k3, v3 = fx('mix', { ins = { 'L', 'R', 'L', 'R' } }); ns[k3] = v3
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
      -- 33 stereo pairs intra-class audio.
      local k2, v2 = fx('a', { ins = rep('L', 64), outs = rep('L', 64) }); ns[k2] = v2
      local k3, v3 = fx('b', { ins = rep('L', 64), outs = rep('L', 64) }); ns[k3] = v3
      local edges = { { type = 'audio', from = 's', to = 'a' } }
      for p = 1, 32 do
        edges[#edges+1] = { type = 'audio', from = 'a', to = 'b',
                            fromPort = p, toPort = p }
      end
      -- 130 MIDI conns intra-class via chain m1 -> m2 -> ... -> m130.
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
      -- both errors on classKey 'guid-s'; sort puts audio before midi.
      t.eq(errs[1].kind, 'audio')
      t.eq(errs[2].kind, 'midi')
    end,
  },
}
