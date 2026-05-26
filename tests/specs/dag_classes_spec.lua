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

-- {nodeId,...} → set for unordered comparison.
local function asSet(list)
  local s = {}
  for _, id in ipairs(list) do s[id] = true end
  return s
end

local function classKeys(classes)
  local out = {}
  for k in pairs(classes) do out[#out+1] = k end
  table.sort(out)
  return out
end

return {
  {
    name = 'empty graph: only master, one class with key ""',
    run = function()
      local cs = DAG.compile(mk({})):classes()
      t.deepEq(classKeys(cs), { '' })
      t.deepEq(asSet(cs['']), { master = true })
    end,
  },
  {
    name = 'source + master, no edges: two classes',
    run = function()
      local ns = {}
      local k, v = source('s', 'guid-s'); ns[k] = v
      local cs = DAG.compile(mk(ns, {})):classes()
      t.deepEq(classKeys(cs), { '', 'guid-s' })
      t.deepEq(asSet(cs['']),        { master = true })
      t.deepEq(asSet(cs['guid-s']), { s = true })
    end,
  },
  {
    name = 'chain s → f → master: one class (all three nodes)',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('f');               ns[k2] = v2
      local cs = DAG.compile(mk(ns, {
        { type = 'audio', from = 's', to = 'f' },
        { type = 'audio', from = 'f', to = 'master' },
      })):classes()
      t.deepEq(classKeys(cs), { 'guid-s' })
      t.deepEq(asSet(cs['guid-s']),
               { s = true, f = true, master = true })
    end,
  },
  {
    name = 'two sources, common mix → master: four classes',
    run = function()
      local ns = {}
      local k,  v  = source('s1', 'guid-a'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-b'); ns[k2] = v2
      local k3, v3 = fx('mix', { ins = 2 }); ns[k3] = v3
      local cs = DAG.compile(mk(ns, {
        { type = 'audio', from = 's1',  to = 'mix', toPort = 1 },
        { type = 'audio', from = 's2',  to = 'mix', toPort = 2 },
        { type = 'audio', from = 'mix', to = 'master' },
      })):classes()
      t.deepEq(classKeys(cs), { 'guid-a', 'guid-a|guid-b', 'guid-b' })
      t.deepEq(asSet(cs['guid-a']), { s1 = true })
      t.deepEq(asSet(cs['guid-b']), { s2 = true })
      t.deepEq(asSet(cs['guid-a|guid-b']),
               { mix = true, master = true })
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
      local cs = DAG.compile(mk(ns, {
        { type = 'audio', from = 'sZ', to = 'mix', toPort = 1 },
        { type = 'audio', from = 'sA', to = 'mix', toPort = 2 },
      })):classes()
      t.truthy(cs['guid-a|guid-z'])
      t.falsy(cs['guid-z|guid-a'])
    end,
  },
  {
    name = 'CU nodes inherited by lower share parent class',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('f');               ns[k2] = v2
      local cs = DAG.compile(mk(ns, {
        { type = 'audio', from = 's', to = 'f', ops = { gain = 0.5 } },
      })):classes()
      -- s, gain CU, f all share 'guid-s'; master is empty.
      t.deepEq(classKeys(cs), { '', 'guid-s' })
      t.eq(#cs['guid-s'], 3)
    end,
  },
}
