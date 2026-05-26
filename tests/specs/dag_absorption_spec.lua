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
               audio = { ins  = opts.ins  or 1,
                         outs = opts.outs or 1 } }
end

local function master(opts)
  opts = opts or {}
  return 'master', { kind = 'master', pos = { x = 0, y = 0 },
                     audio = { ins = opts.ins or 1 } }
end

local function mk(nodes, edges)
  if not nodes.master then
    local k, v = master(); nodes[k] = v
  end
  return { nodes = nodes, edges = edges or {}, _nextId = 1 }
end

local function absorptionOf(g)
  return DAG.compile(g):absorption()
end

return {
  {
    name = 'single class: no absorption (nothing to absorb)',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('f');               ns[k2] = v2
      local abs = absorptionOf(mk(ns, {
        { type = 'audio', from = 's', to = 'f' },
        { type = 'audio', from = 'f', to = 'master' },
      }))
      t.falsy(abs['guid-s'])
    end,
  },
  {
    name = 'two parents: target class has no auto-absorb host',
    run = function()
      local ns = {}
      local k,  v  = source('s1', 'guid-a'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-b'); ns[k2] = v2
      local k3, v3 = fx('mix', { ins = 2 }); ns[k3] = v3
      local abs = absorptionOf(mk(ns, {
        { type = 'audio', from = 's1',  to = 'mix', toPort = 1 },
        { type = 'audio', from = 's2',  to = 'mix', toPort = 2 },
        { type = 'audio', from = 'mix', to = 'master' },
      }))
      local mixCls = 'guid-a|guid-b'
      t.falsy(abs[mixCls])
    end,
  },
  {
    name = 'two parents + primary: mix absorbs into the primary parent',
    run = function()
      local ns = {}
      local k,  v  = source('s1', 'guid-a'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-b'); ns[k2] = v2
      local k3, v3 = fx('mix', { ins = 2 }); ns[k3] = v3
      local abs = absorptionOf(mk(ns, {
        { type = 'audio', from = 's1',  to = 'mix', toPort = 1, primary = true },
        { type = 'audio', from = 's2',  to = 'mix', toPort = 2 },
      }))
      t.eq(abs['guid-a|guid-b'], 'guid-a')
    end,
  },
  {
    name = 'fx with isolated own srcSet + extra source: only audio parent is host',
    run = function()
      -- s and t in source nodes, but only s wires to mix; t hangs detached.
      -- mix's class is just 'guid-s' and has 'guid-s' as single audio parent
      -- through the source class -- but src class IS the same as mix class.
      -- So construct a more genuine case: two-source mix already covered.
      -- Here: source -> mix -> master, mix and master different classes only
      -- if master picks up another source. Use a dangling source to differ.
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = source('t', 'guid-t'); ns[k2] = v2
      local k3, v3 = fx('f');               ns[k3] = v3
      local abs = absorptionOf(mk(ns, {
        { type = 'audio', from = 's', to = 'f' },
        { type = 'audio', from = 'f', to = 'master' },
        { type = 'audio', from = 't', to = 'master' },
      }))
      -- master class = 'guid-s|guid-t'; has 2 audio parents (f's class = 'guid-s',
      -- and t's class = 'guid-t') -> no auto-absorption.
      t.falsy(abs['guid-s|guid-t'])
    end,
  },
  {
    name = 'chain absorption resolves to terminal host',
    run = function()
      -- s -> a -> mix (mix also fed by t)
      -- a's class is 'guid-s' (subset), mix's class is 'guid-s|guid-t'.
      -- mix has 2 audio parents -> absorbs only with primary override.
      -- Make it a chain by having two absorption hops: build a graph where
      -- B absorbs into A (single audio parent), and C absorbs into B (also
      -- single audio parent), so resolve(C) = A.
      local ns = {}
      local k,  v  = source('s', 'guid-s');  ns[k]  = v
      local k2, v2 = fx('a'); ns[k2] = v2
      local k3, v3 = fx('b'); ns[k3] = v3
      -- Add a second source feeding A so A's class differs from s's class.
      local k4, v4 = source('t', 'guid-t'); ns[k4] = v4
      local k5, v5 = fx('mixA', { ins = 2 }); ns[k5] = v5
      -- And a third source feeding B alongside A, so B's class differs from A's.
      local k6, v6 = source('u', 'guid-u'); ns[k6] = v6
      local k7, v7 = fx('mixB', { ins = { 'L', 'R', 'L', 'R' } }); ns[k7] = v7
      local abs = absorptionOf(mk(ns, {
        -- A = mixA's class is {s,t}; only one audio parent route from each
        -- s and t, so mixA has 2 audio parents (no auto).
        { type = 'audio', from = 's', to = 'mixA', toPort = 1, primary = true },
        { type = 'audio', from = 't', to = 'mixA', toPort = 2 },
        -- mixA -> mixB primary; mixB class = {s,t,u}; mixB also has u parent.
        { type = 'audio', from = 'mixA', to = 'mixB', toPort = 1, primary = true },
        { type = 'audio', from = 'u',    to = 'mixB', toPort = 2 },
      }))
      -- mixA class {s,t} absorbs into {s} (the primary parent class).
      -- mixB class {s,t,u} absorbs into {s,t} (primary), which itself
      -- resolves to {s}. So mixB -> 'guid-s'.
      t.eq(abs['guid-s|guid-t'],         'guid-s')
      t.eq(abs['guid-s|guid-t|guid-u'],  'guid-s')
    end,
  },
  {
    name = 'two primaries on same target: no absorption (ambiguous)',
    run = function()
      local ns = {}
      local k,  v  = source('s1', 'guid-a'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-b'); ns[k2] = v2
      local k3, v3 = fx('mix', { ins = { 'L', 'R', 'L', 'R' } }); ns[k3] = v3
      local abs = absorptionOf(mk(ns, {
        { type = 'audio', from = 's1', to = 'mix', toPort = 1, primary = true },
        { type = 'audio', from = 's2', to = 'mix', toPort = 2, primary = true },
      }))
      t.falsy(abs['guid-a|guid-b'])
    end,
  },
  {
    name = 'midi-only inter-class edge does not trigger audio absorption',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = source('t', 'guid-t'); ns[k2] = v2
      local k3, v3 = fx('m'); ns[k3] = v3
      local abs = absorptionOf(mk(ns, {
        { type = 'midi', from = 's', to = 'm' },
        { type = 'midi', from = 't', to = 'm' },
      }))
      -- m has 2 midi parents, 0 audio parents -> no absorption.
      t.falsy(abs['guid-s|guid-t'])
    end,
  },
}
