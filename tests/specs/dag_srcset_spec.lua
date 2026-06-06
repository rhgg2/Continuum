local t   = require('support')
local DAG = require('DAG')

-- srcSet is a closure-local; we observe it through the public partition.
-- A node's class key IS its sorted srcSet guids joined by util.key, so classOf pins srcSet.

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

local function classKey(nodes, edges, id)
  return DAG.compile(mk(nodes, edges)):classOf()[id]
end

return {
  {
    name = 'source node srcSet = {its own trackGuid}',
    run = function()
      local ns = {}
      local k, v = source('s', 'guid-s'); ns[k] = v
      t.eq(classKey(ns, {}, 's'), 'guid-s')
    end,
  },
  {
    name = 'isolated master carries its own split marker',
    run = function()
      t.eq(classKey({}, {}, 'master'), 'split:master')
    end,
  },
  {
    name = 'single-chain fx inherits source srcSet',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('f');               ns[k2] = v2
      t.eq(classKey(ns, {
        { type = 'audio', from = 's', to = 'f' },
      }, 'f'), 'guid-s')
    end,
  },
  {
    name = 'two-source fan-in: mix srcSet = union of both',
    run = function()
      local ns = {}
      local k,  v  = source('s1', 'guid-a'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-b'); ns[k2] = v2
      local k3, v3 = fx('mix', { ins = 2 }); ns[k3] = v3
      t.eq(classKey(ns, {
        { type = 'audio', from = 's1', to = 'mix', toPort = 1 },
        { type = 'audio', from = 's2', to = 'mix', toPort = 2 },
      }, 'mix'), t.key('guid-a', 'guid-b'))
    end,
  },
  {
    name = 'diamond from single source collapses to one srcSet',
    run = function()
      -- s → a, s → b, a → c, b → c — c's srcSet is just {s}.
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('a');               ns[k2] = v2
      local k3, v3 = fx('b');               ns[k3] = v3
      local k4, v4 = fx('c', { ins = 2 });  ns[k4] = v4
      t.eq(classKey(ns, {
        { type = 'audio', from = 's', to = 'a' },
        { type = 'audio', from = 's', to = 'b' },
        { type = 'audio', from = 'a', to = 'c', toPort = 1 },
        { type = 'audio', from = 'b', to = 'c', toPort = 2 },
      }, 'c'), 'guid-s')
    end,
  },
  {
    name = 'master receiving from chain: chain-rooted srcSet plus its split marker',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('f');               ns[k2] = v2
      t.eq(classKey(ns, {
        { type = 'audio', from = 's', to = 'f' },
        { type = 'audio', from = 'f', to = 'master' },
      }, 'master'), t.key('guid-s', 'split:master'))
    end,
  },
  {
    name = 'gain op on a wire does not alter srcSet propagation (CU is invisible to the partition)',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('f');               ns[k2] = v2
      t.eq(classKey(ns, {
        { type = 'audio', from = 's', to = 'f', ops = { gain = 0.5 } },
      }, 'f'), 'guid-s')
    end,
  },
  {
    name = 'memoisation returns the identical partition table on repeat call',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('f');               ns[k2] = v2
      local c = DAG.compile(mk(ns, {
        { type = 'audio', from = 's', to = 'f' },
      }))
      t.eq(c:classOf(), c:classOf())  -- same table reference, not just deep-equal
    end,
  },
}
