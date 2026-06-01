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
               split     = opts.split or nil,
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

-- s1 -> a -> b -> master, s2 -> master. Two sources, so master's class
-- differs from the {s1} chain: marking b evicts it cleanly.
local function twoSourceChain(splitB)
  local ns = {}
  local k,  v  = source('s1', 'g1');         ns[k]  = v
  local k2, v2 = source('s2', 'g2');         ns[k2] = v2
  local k3, v3 = fx('a');                    ns[k3] = v3
  local k4, v4 = fx('b', { split = splitB }); ns[k4] = v4
  return mk(ns, {
    { type = 'audio', from = 's1', to = 'a' },
    { type = 'audio', from = 'a',  to = 'b' },
    { type = 'audio', from = 'b',  to = 'master' },
    { type = 'audio', from = 's2', to = 'master' },
  })
end

local function hasOutWire(entry, to, from)
  for _, w in ipairs(entry.outWires) do
    if w.to == to and w.from == from then return true end
  end
  return false
end

local function inList(list, id)
  for _, x in ipairs(list) do if x == id then return true end end
  return false
end

return {
  {
    name = 'unmarked: chain stays one class',
    run = function()
      local cls = DAG.compile(twoSourceChain(false)):classOf()
      t.eq(cls['a'], 'g1')
      t.eq(cls['b'], 'g1')
    end,
  },
  {
    name = 'split tag evicts the node into its own class',
    run = function()
      local cx  = DAG.compile(twoSourceChain(true))
      local cls = cx:classOf()
      t.eq(cls['a'], 'g1')
      t.eq(cls['b'], 'g1|split:b')
      t.truthy(cx:splitClasses()['g1|split:b'])
    end,
  },
  {
    name = 'split-tagged class never absorbs into its single audio parent',
    run = function()
      -- b has exactly one audio parent (a); absent the guard it would
      -- auto-absorb back onto a's host, undoing the split.
      local abs = DAG.compile(twoSourceChain(true)):absorption()
      t.falsy(abs['g1|split:b'])
    end,
  },
  {
    name = 'targetPlan: cut edge is a send, cone is its own newTrack',
    run = function()
      local plan = DAG.compile(twoSourceChain(true)):targetPlan()
      t.eq(plan['g1|split:b'].hostKind, 'newTrack')
      t.truthy(hasOutWire(plan['g1'], 'g1|split:b', 'a'))
      t.truthy(plan['g1|split:b'].mainSend)
    end,
  },
  {
    name = 'unmarked: a->b is intra-host, no eviction',
    run = function()
      local plan = DAG.compile(twoSourceChain(false)):targetPlan()
      t.falsy(plan['g1|split:b'])
      local intra = false
      for _, c in ipairs(plan['g1'].intraConns) do
        if c.from == 'a' and c.to == 'b' then intra = true end
      end
      t.truthy(intra)
    end,
  },
  {
    name = 'sole contributor to master re-merges (no eviction)',
    run = function()
      -- s -> a -> master, a marked. a's cone is master's only feed, so
      -- a and master share class 'g1|split:a'; a hosts on the master.
      local ns = {}
      local k,  v  = source('s', 'g1');          ns[k]  = v
      local k2, v2 = fx('a', { split = true });   ns[k2] = v2
      local cx  = DAG.compile(mk(ns, {
        { type = 'audio', from = 's', to = 'a' },
        { type = 'audio', from = 'a', to = 'master' },
      }))
      local cls = cx:classOf()
      t.eq(cls['a'], cls['master'])
      t.truthy(inList(cx:targetPlan()['__master__'].fxOrder, 'a'))
    end,
  },
  {
    name = 'validate rejects split on a source node',
    run = function()
      local ns = {}
      local k, v = source('s', 'g1'); ns[k] = v
      ns['s'].split = true
      t.eq(DAG.validate(mk(ns, {})).code, 'split_non_fx')
    end,
  },
  {
    name = 'validate rejects split on the master node',
    run = function()
      local ns = {}
      local k, v = source('s', 'g1'); ns[k] = v
      local g = mk(ns, {})
      g.nodes.master.split = true
      t.eq(DAG.validate(g).code, 'split_non_fx')
    end,
  },
}
