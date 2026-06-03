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

-- {classKey → {id=true}} reconstructed via classOf(); classes() is private to
-- DAG so this validates it only through its public inverse.
local function partition(graph)
  local byKey = {}
  for id, key in pairs(DAG.compile(graph):classOf()) do
    byKey[key] = byKey[key] or {}
    byKey[key][id] = true
  end
  return byKey
end

local function keysOf(byKey)
  local out = {}
  for k in pairs(byKey) do out[#out+1] = k end
  table.sort(out)
  return out
end

return {
  {
    name = 'empty graph: master splits into its own class',
    run = function()
      local p = partition(mk({}))
      t.deepEq(keysOf(p), { 'split:master' })
      t.deepEq(p['split:master'], { master = true })
    end,
  },
  {
    name = 'source + master, no edges: two classes',
    run = function()
      local ns = {}
      local k, v = source('s', 'guid-s'); ns[k] = v
      local p = partition(mk(ns, {}))
      t.deepEq(keysOf(p), { 'guid-s', 'split:master' })
      t.deepEq(p['split:master'], { master = true })
      t.deepEq(p['guid-s'],       { s = true })
    end,
  },
  {
    name = 'chain s → f → master: master splits, s+f share a class',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('f');               ns[k2] = v2
      local p = partition(mk(ns, {
        { type = 'audio', from = 's', to = 'f' },
        { type = 'audio', from = 'f', to = 'master' },
      }))
      t.deepEq(keysOf(p), { 'guid-s', 'guid-s|split:master' })
      t.deepEq(p['guid-s'], { s = true, f = true })
      t.deepEq(p['guid-s|split:master'], { master = true })
    end,
  },
  {
    name = 'two sources, common mix → master: four classes',
    run = function()
      local ns = {}
      local k,  v  = source('s1', 'guid-a'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-b'); ns[k2] = v2
      local k3, v3 = fx('mix', { ins = 2 }); ns[k3] = v3
      local p = partition(mk(ns, {
        { type = 'audio', from = 's1',  to = 'mix', toPort = 1 },
        { type = 'audio', from = 's2',  to = 'mix', toPort = 2 },
        { type = 'audio', from = 'mix', to = 'master' },
      }))
      t.deepEq(keysOf(p), { 'guid-a', 'guid-a|guid-b', 'guid-b' })
      t.deepEq(p['guid-a'], { s1 = true })
      t.deepEq(p['guid-b'], { s2 = true })
      t.deepEq(p['guid-a|guid-b'], { mix = true, master = true })
    end,
  },
  {
    name = 'classKey is sorted regardless of source declaration order',
    run = function()
      -- declare z first, a second; key should still be a|z, not z|a.
      local ns = {}
      local k,  v  = source('sZ', 'guid-z'); ns[k]  = v
      local k2, v2 = source('sA', 'guid-a'); ns[k2] = v2
      local k3, v3 = fx('mix', { ins = 2 }); ns[k3] = v3
      local p = partition(mk(ns, {
        { type = 'audio', from = 'sZ', to = 'mix', toPort = 1 },
        { type = 'audio', from = 'sA', to = 'mix', toPort = 2 },
      }))
      t.truthy(p['guid-a|guid-z'])
      t.falsy(p['guid-z|guid-a'])
    end,
  },
  {
    name = 'gain op adds no class member (CU is invisible to the partition)',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('f');               ns[k2] = v2
      local p = partition(mk(ns, {
        { type = 'audio', from = 's', to = 'f', ops = { gain = 0.5 } },
      }))
      -- s, f share 'guid-s'; master splits into its own class. The gain CU is
      -- synthesised at targetTracks, not a graph vertex, so it never appears.
      t.deepEq(keysOf(p), { 'guid-s', 'split:master' })
      t.deepEq(p['guid-s'], { s = true, f = true })
    end,
  },
}
