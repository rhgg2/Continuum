local t    = require('support')
local util = require('util')

local function mkWv(harness, graph)
  local h = harness.mk()
  if graph then h.cm:set('project', 'wiringGraph', graph) end
  local rm = util.instantiate('routingManager')
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
  local wv = util.instantiate('wiringView', { cm = h.cm, wm = wm })
  return h, wv
end

local function master()
  return 'master', { kind = 'master', pos = { x = 0, y = 0 },
                     ports = { audio = { ins = 1, outs = 0 },
                               midi  = { ins = 0, outs = 0 } } }
end

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

local function mk(nodes, edges)
  if not nodes.master then local k, v = master(); nodes[k] = v end
  return { nodes = nodes, edges = edges or {}, nextId = 1 }
end

return {
  {
    name = 'fresh graph: errors() is empty',
    run = function(harness)
      local _, wv = mkWv(harness)
      t.deepEq(wv:errors(), {})
    end,
  },
  {
    name = 'intra-class audio > 64: one entry with budget, count, and class node ids',
    run = function(harness)
      -- source→a (1 conn) + 64 wires a→b (64 conns) = 65 intra-class audio.
      -- One class: s, a, b; master split out (nothing reaches it).
      local ns = {}
      local sk, sv = source('s', 'guid-s');           ns[sk] = sv
      local ak, av = fx('a', { ins = 1, outs = 64 }); ns[ak] = av
      local bk, bv = fx('b', { ins = 64 });           ns[bk] = bv
      local edges = { { type = 'audio', from = 's', to = 'a' } }
      for p = 1, 64 do
        edges[#edges+1] = { type = 'audio', from = 'a', to = 'b',
                            fromPort = p, toPort = p }
      end
      local _, wv = mkWv(harness, mk(ns, edges))
      local errs = wv:errors()
      t.eq(#errs, 1,             'one capacity entry')
      t.eq(errs[1].kind,   'audio')
      t.eq(errs[1].count,  65)
      t.eq(errs[1].budget, 64,   'audio budget exposed')
      t.deepEq(errs[1].nodeIds, { s = true, a = true, b = true },
               'user-graph nodes of the overflowing class')
    end,
  },
  {
    name = 'intra-class midi > 128: budget 128, nodeIds cover the chain',
    run = function(harness)
      local ns = {}
      local sk, sv = source('s', 'guid-s'); ns[sk] = sv
      local N = 130
      for i = 1, N do
        local fk, fv = fx('f' .. i); ns[fk] = fv
      end
      local edges = { { type = 'midi', from = 's', to = 'f1' } }
      for i = 1, N - 1 do
        edges[#edges+1] = { type = 'midi', from = 'f' .. i, to = 'f' .. (i+1) }
      end
      local _, wv = mkWv(harness, mk(ns, edges))
      local errs = wv:errors()
      t.eq(#errs, 1)
      t.eq(errs[1].kind,   'midi')
      t.eq(errs[1].count,  N)
      t.eq(errs[1].budget, 128)
      t.truthy(errs[1].nodeIds.s,    's in the class')
      t.truthy(errs[1].nodeIds.f1,   'f1 in the class')
      t.truthy(errs[1].nodeIds.f130, 'fN in the class')
    end,
  },
  {
    name = 'CU nodes synthesised by lowering are filtered out of nodeIds',
    run = function(harness)
      -- Same overflow as the audio test, but each a→b wire carries a gain
      -- op. Lowering splices a CU node per wire; the class now contains
      -- 64 _cu_* ids alongside s/a/b, and the conn count rises to 129.
      -- nodeIds must only surface the user-graph ids.
      local ns = {}
      local sk, sv = source('s', 'guid-s');           ns[sk] = sv
      local ak, av = fx('a', { ins = 1, outs = 64 }); ns[ak] = av
      local bk, bv = fx('b', { ins = 64 });           ns[bk] = bv
      local edges = { { type = 'audio', from = 's', to = 'a' } }
      for p = 1, 64 do
        edges[#edges+1] = { type = 'audio', from = 'a', to = 'b',
                            fromPort = p, toPort = p,
                            ops = { gain = 0.5 } }
      end
      local _, wv = mkWv(harness, mk(ns, edges))
      local errs = wv:errors()
      t.eq(#errs, 1)
      t.deepEq(errs[1].nodeIds, { s = true, a = true, b = true },
               'CU ids do not leak through to nodeIds')
    end,
  },
}
