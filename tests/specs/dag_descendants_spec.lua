local t   = require('support')
local DAG = require('DAG')

local function source(id, guid)
  return id, { kind = 'source', trackGuid = guid or 'guid-' .. id,
               pos = { x = 0, y = 0 } }
end

local function fx(id, opts)
  opts = opts or {}
  return id, { kind = 'fx', pos = { x = 0, y = 0 },
               fxIdent = 'JS:test', fxDisplay = 'FX',
               audio = { ins  = opts.ins  or 1,
                         outs = opts.outs or 1 } }
end

local function master()
  return 'master', { kind = 'master', pos = { x = 0, y = 0 },
                     audio = { ins = 1 } }
end

local function mk(nodes, edges)
  if not nodes.master then local k, v = master(); nodes[k] = v end
  return { nodes = nodes, edges = edges or {}, _nextId = 1 }
end

local function sortedKeys(set)
  local out = {}
  for k in pairs(set) do out[#out+1] = k end
  table.sort(out)
  return out
end

return {
  {
    name = 'leaf source: descendants = { itself }',
    run = function()
      local ns = {}
      local k, v = source('s'); ns[k] = v
      t.deepEq(sortedKeys(DAG.descendants(mk(ns, {}), 's')), { 's' })
    end,
  },
  {
    name = 'audio chain: descendants include everything downstream',
    run = function()
      local ns = {}
      local k1, v1 = source('s'); ns[k1] = v1
      local k2, v2 = fx('a');     ns[k2] = v2
      local k3, v3 = fx('b');     ns[k3] = v3
      local g = mk(ns, {
        { type = 'audio', from = 's', to = 'a',      fromPort = 1, toPort = 1 },
        { type = 'audio', from = 'a', to = 'b',      fromPort = 1, toPort = 1 },
        { type = 'audio', from = 'b', to = 'master', fromPort = 1, toPort = 1 },
      })
      t.deepEq(sortedKeys(DAG.descendants(g, 's')),
               { 'a', 'b', 'master', 's' })
    end,
  },
  {
    name = 'midi edges are followed too',
    run = function()
      local ns = {}
      local k1, v1 = source('s');               ns[k1] = v1
      local k2, v2 = fx('synth', { ins = 0 });  ns[k2] = v2
      local g = mk(ns, {
        { type = 'midi',  from = 's',     to = 'synth' },
        { type = 'audio', from = 'synth', to = 'master', fromPort = 1, toPort = 1 },
      })
      t.deepEq(sortedKeys(DAG.descendants(g, 's')),
               { 'master', 's', 'synth' })
    end,
  },
  {
    name = 'unrelated branches are excluded',
    run = function()
      local ns = {}
      local k1, v1 = fx('a');  ns[k1] = v1
      local k2, v2 = fx('b');  ns[k2] = v2
      local k3, v3 = fx('c');  ns[k3] = v3
      local g = mk(ns, {
        { type = 'audio', from = 'a', to = 'b', fromPort = 1, toPort = 1 },
      })
      local d = DAG.descendants(g, 'a')
      t.deepEq(sortedKeys(d), { 'a', 'b' })
      t.eq(d.c, nil)
    end,
  },
  {
    name = 'isolated node: descendants = { itself }',
    run = function()
      local ns = {}
      local k1, v1 = fx('iso'); ns[k1] = v1
      local g = mk(ns, {})
      t.eq(DAG.descendants(g, 'iso').iso, true)
    end,
  },
}
