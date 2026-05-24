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

-- {trackGuid=true,...} → sorted array, for stable comparison.
local function sortedKeys(set)
  local out = {}
  for k in pairs(set) do out[#out+1] = k end
  table.sort(out)
  return out
end

return {
  {
    name = 'source node srcSet = {its own trackGuid}',
    run = function()
      local ns = {}
      local k, v = source('s', 'guid-s'); ns[k] = v
      local c = DAG.lower(mk(ns, {}))
      t.deepEq(sortedKeys(DAG.srcSet(c, 's')), { 'guid-s' })
    end,
  },
  {
    name = 'isolated master srcSet is empty',
    run = function()
      local c = DAG.lower(mk({}))
      t.deepEq(sortedKeys(DAG.srcSet(c, 'master')), {})
    end,
  },
  {
    name = 'single-chain fx inherits source srcSet',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('f');               ns[k2] = v2
      local c = DAG.lower(mk(ns, {
        { type = 'audio', from = 's', to = 'f' },
      }))
      t.deepEq(sortedKeys(DAG.srcSet(c, 'f')), { 'guid-s' })
    end,
  },
  {
    name = 'two-source fan-in: mix srcSet = union of both',
    run = function()
      local ns = {}
      local k,  v  = source('s1', 'guid-a'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-b'); ns[k2] = v2
      local k3, v3 = fx('mix', { ins = 2 }); ns[k3] = v3
      local c = DAG.lower(mk(ns, {
        { type = 'audio', from = 's1', to = 'mix', toPort = 1 },
        { type = 'audio', from = 's2', to = 'mix', toPort = 2 },
      }))
      t.deepEq(sortedKeys(DAG.srcSet(c, 'mix')), { 'guid-a', 'guid-b' })
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
      local k4, v4 = fx('c', { ins = 2 }); ns[k4] = v4
      local c = DAG.lower(mk(ns, {
        { type = 'audio', from = 's', to = 'a' },
        { type = 'audio', from = 's', to = 'b' },
        { type = 'audio', from = 'a', to = 'c', toPort = 1 },
        { type = 'audio', from = 'b', to = 'c', toPort = 2 },
      }))
      t.deepEq(sortedKeys(DAG.srcSet(c, 'c')), { 'guid-s' })
    end,
  },
  {
    name = 'master receiving from chain has chain-rooted srcSet',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('f');               ns[k2] = v2
      local c = DAG.lower(mk(ns, {
        { type = 'audio', from = 's', to = 'f' },
        { type = 'audio', from = 'f', to = 'master' },
      }))
      t.deepEq(sortedKeys(DAG.srcSet(c, 'master')), { 'guid-s' })
    end,
  },
  {
    name = 'inserted CU nodes carry srcSet through (gain on stereo wire)',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('f');               ns[k2] = v2
      local c = DAG.lower(mk(ns, {
        { type = 'audio', from = 's', to = 'f', ops = { gain = 0.5 } },
      }))
      local gainId
      for id, node in pairs(c.nodes) do
        if node.cuMode == 'gain' then gainId = id end
      end
      t.truthy(gainId)
      t.deepEq(sortedKeys(DAG.srcSet(c, gainId)), { 'guid-s' })
      t.deepEq(sortedKeys(DAG.srcSet(c, 'f')),    { 'guid-s' })
    end,
  },
  {
    name = 'memoisation returns identical set on repeat call',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('f');               ns[k2] = v2
      local c = DAG.lower(mk(ns, {
        { type = 'audio', from = 's', to = 'f' },
      }))
      local a = DAG.srcSet(c, 'f')
      local b = DAG.srcSet(c, 'f')
      t.eq(a, b)  -- same table reference, not just deep-equal
    end,
  },
}
