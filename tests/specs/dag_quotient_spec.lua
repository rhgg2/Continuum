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
  return { nodes = nodes, edges = edges or {}, _nextId = 1 }
end

-- {k1,k2,...} of a set, sorted.
local function sortedKeys(set)
  local out = {}
  for k in pairs(set) do out[#out+1] = k end
  table.sort(out)
  return out
end

local function quotientOf(g)
  return DAG.compile(g):quotient()
end

return {
  {
    name = 'empty graph: master class exists with no parents/children',
    run = function()
      local q = quotientOf(mk({}))
      t.truthy(q[''])
      t.deepEq(sortedKeys(q[''].audioParents),  {})
      t.deepEq(sortedKeys(q[''].audioChildren), {})
    end,
  },
  {
    name = 'chain s -> f -> master: single class, no inter-class edges',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('f');               ns[k2] = v2
      local q = quotientOf(mk(ns, {
        { type = 'audio', from = 's', to = 'f' },
        { type = 'audio', from = 'f', to = 'master' },
      }))
      -- everything is in 'guid-s' class; no inter-class edges.
      t.deepEq(sortedKeys(q['guid-s'].audioParents),  {})
      t.deepEq(sortedKeys(q['guid-s'].audioChildren), {})
    end,
  },
  {
    name = 'two-source mix: mix class has both audio parents and master child',
    run = function()
      local ns = {}
      local k,  v  = source('s1', 'guid-a'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-b'); ns[k2] = v2
      local k3, v3 = fx('mix', { ins = 2 }); ns[k3] = v3
      local q = quotientOf(mk(ns, {
        { type = 'audio', from = 's1',  to = 'mix', toPort = 1 },
        { type = 'audio', from = 's2',  to = 'mix', toPort = 2 },
        { type = 'audio', from = 'mix', to = 'master' },
      }))
      local mixCls = 'guid-a|guid-b'
      t.deepEq(sortedKeys(q[mixCls].audioParents),  { 'guid-a', 'guid-b' })
      t.deepEq(sortedKeys(q[mixCls].audioChildren), {})
      -- mix + master share the same class (both ancestors = both sources),
      -- so master is in the mix class too; the master node has no children.
      t.deepEq(sortedKeys(q['guid-a'].audioChildren), { mixCls })
      t.deepEq(sortedKeys(q['guid-b'].audioChildren), { mixCls })
    end,
  },
  {
    name = 'primary flag on a wire surfaces in primaryAudioParents',
    run = function()
      local ns = {}
      local k,  v  = source('s1', 'guid-a'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-b'); ns[k2] = v2
      local k3, v3 = fx('mix', { ins = 2 }); ns[k3] = v3
      local q = quotientOf(mk(ns, {
        { type = 'audio', from = 's1',  to = 'mix', toPort = 1, primary = true },
        { type = 'audio', from = 's2',  to = 'mix', toPort = 2 },
      }))
      local mixCls = 'guid-a|guid-b'
      t.eq(q[mixCls].audioParents['guid-a'],        true)
      t.eq(q[mixCls].audioParents['guid-b'],        true)
      t.truthy(q[mixCls].primaryAudioParents['guid-a'])
      t.falsy (q[mixCls].primaryAudioParents['guid-b'])
    end,
  },
  {
    name = 'primary on a gain wire propagates through inserted CU',
    run = function()
      -- gain CU sits between source and mix on one input; primary should
      -- still surface as primary on mix's parent (source's class).
      local ns = {}
      local k,  v  = source('s1', 'guid-a'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-b'); ns[k2] = v2
      local k3, v3 = fx('mix', { ins = 2 }); ns[k3] = v3
      local q = quotientOf(mk(ns, {
        { type = 'audio', from = 's1', to = 'mix', toPort = 1,
          primary = true, ops = { gain = 0.5 } },
        { type = 'audio', from = 's2', to = 'mix', toPort = 2 },
      }))
      local mixCls = 'guid-a|guid-b'
      t.truthy(q[mixCls].primaryAudioParents['guid-a'])
    end,
  },
  {
    name = 'midi parents/children populate the midi side, not audio',
    run = function()
      local ns = {}
      local k,  v  = source('s', 'guid-s'); ns[k]  = v
      local k2, v2 = fx('f');               ns[k2] = v2
      local q = quotientOf(mk(ns, {
        { type = 'midi', from = 's', to = 'f' },
      }))
      -- f's class = 'guid-s' (single source ancestor via midi).
      -- s and f end up in the same class so no inter-class edges here either.
      t.deepEq(sortedKeys(q['guid-s'].midiParents),  {})
      t.deepEq(sortedKeys(q['guid-s'].audioParents), {})
    end,
  },
  {
    name = 'midi from two sources: midiParents tracked separately',
    run = function()
      local ns = {}
      local k,  v  = source('s1', 'guid-a'); ns[k]  = v
      local k2, v2 = source('s2', 'guid-b'); ns[k2] = v2
      local k3, v3 = fx('m');                ns[k3] = v3
      local q = quotientOf(mk(ns, {
        { type = 'midi', from = 's1', to = 'm' },
        { type = 'midi', from = 's2', to = 'm' },
      }))
      local mCls = 'guid-a|guid-b'
      t.deepEq(sortedKeys(q[mCls].midiParents),  { 'guid-a', 'guid-b' })
      t.deepEq(sortedKeys(q[mCls].audioParents), {})
    end,
  },
}
