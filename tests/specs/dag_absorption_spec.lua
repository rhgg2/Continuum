local t   = require('support')
local DAG = require('DAG')

-- absorption is a closure-local; its decision surfaces through resolveHost.
-- No absorbing host → resolves to self; absorbed class → resolves to host class.

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

local function hostOf(g, cls)
  return DAG.compile(g):resolveHost(cls)
end

return {
  {
    name = 'single class: no absorption (nothing to absorb)',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('f');               ns[k2] = v2
      local g = mk(ns, {
        { type = 'audio', from = 's', to = 'f' },
        { type = 'audio', from = 'f', to = 'master' },
      })
      t.eq(hostOf(g, 'guid-s'), 'guid-s')
    end,
  },
  {
    name = 'two parents: target class hosts itself (no auto-absorb)',
    run = function()
      local ns = {}
      local k,  v  = source('s1', 'guid-a'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-b'); ns[k2] = v2
      local k3, v3 = fx('mix', { ins = 2 }); ns[k3] = v3
      local g = mk(ns, {
        { type = 'audio', from = 's1',  to = 'mix', toPort = 1 },
        { type = 'audio', from = 's2',  to = 'mix', toPort = 2 },
        { type = 'audio', from = 'mix', to = 'master' },
      })
      t.eq(hostOf(g, 'guid-a|guid-b'), 'guid-a|guid-b')
    end,
  },
  {
    name = 'two parents + primary: mix absorbs into the primary parent',
    run = function()
      local ns = {}
      local k,  v  = source('s1', 'guid-a'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-b'); ns[k2] = v2
      local k3, v3 = fx('mix', { ins = 2 }); ns[k3] = v3
      local g = mk(ns, {
        { type = 'audio', from = 's1', to = 'mix', toPort = 1, primary = true },
        { type = 'audio', from = 's2', to = 'mix', toPort = 2 },
      })
      t.eq(hostOf(g, 'guid-a|guid-b'), 'guid-a')
    end,
  },
  {
    name = 'primary survives an inserted gain CU: still absorbs into the primary parent',
    run = function()
      -- the gain CU is synthesised at plan time and is invisible to the
      -- partition, so the primary flag still drives absorption.
      local ns = {}
      local k,  v  = source('s1', 'guid-a'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-b'); ns[k2] = v2
      local k3, v3 = fx('mix', { ins = 2 }); ns[k3] = v3
      local g = mk(ns, {
        { type = 'audio', from = 's1', to = 'mix', toPort = 1,
          primary = true, ops = { gain = 0.5 } },
        { type = 'audio', from = 's2', to = 'mix', toPort = 2 },
      })
      t.eq(hostOf(g, 'guid-a|guid-b'), 'guid-a')
    end,
  },
  {
    name = 'master class with two audio parents hosts itself',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = source('t', 'guid-t'); ns[k2] = v2
      local k3, v3 = fx('f');               ns[k3] = v3
      local g = mk(ns, {
        { type = 'audio', from = 's', to = 'f' },
        { type = 'audio', from = 'f', to = 'master' },
        { type = 'audio', from = 't', to = 'master' },
      })
      t.eq(hostOf(g, 'guid-s|guid-t'), 'guid-s|guid-t')
    end,
  },
  {
    name = 'chain absorption resolves to the terminal host',
    run = function()
      -- mixA {s,t} absorbs into its primary {s}; mixB {s,t,u} absorbs into its
      -- primary {s,t}, which itself resolves to {s}. So both land on guid-s.
      local ns = {}
      local k,  v  = source('s', 'guid-s');   ns[k]  = v
      local k2, v2 = source('t', 'guid-t');   ns[k2] = v2
      local k3, v3 = source('u', 'guid-u');   ns[k3] = v3
      local k4, v4 = fx('mixA', { ins = 2 }); ns[k4] = v4
      local k5, v5 = fx('mixB', { ins = 2 }); ns[k5] = v5
      local g = mk(ns, {
        { type = 'audio', from = 's',    to = 'mixA', toPort = 1, primary = true },
        { type = 'audio', from = 't',    to = 'mixA', toPort = 2 },
        { type = 'audio', from = 'mixA', to = 'mixB', toPort = 1, primary = true },
        { type = 'audio', from = 'u',    to = 'mixB', toPort = 2 },
      })
      t.eq(hostOf(g, 'guid-s|guid-t'),        'guid-s')
      t.eq(hostOf(g, 'guid-s|guid-t|guid-u'), 'guid-s')
    end,
  },
  {
    name = 'two primaries on same target: hosts itself (ambiguous)',
    run = function()
      local ns = {}
      local k,  v  = source('s1', 'guid-a'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-b'); ns[k2] = v2
      local k3, v3 = fx('mix', { ins = 2 }); ns[k3] = v3
      local g = mk(ns, {
        { type = 'audio', from = 's1', to = 'mix', toPort = 1, primary = true },
        { type = 'audio', from = 's2', to = 'mix', toPort = 2, primary = true },
      })
      t.eq(hostOf(g, 'guid-a|guid-b'), 'guid-a|guid-b')
    end,
  },
  {
    name = 'midi-only inter-class edge does not trigger audio absorption',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = source('t', 'guid-t'); ns[k2] = v2
      local k3, v3 = fx('m');               ns[k3] = v3
      local g = mk(ns, {
        { type = 'midi', from = 's', to = 'm' },
        { type = 'midi', from = 't', to = 'm' },
      })
      t.eq(hostOf(g, 'guid-s|guid-t'), 'guid-s|guid-t')
    end,
  },
}
