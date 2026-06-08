-- DAG.classify: post-hoc component grouping over read's domain (master-excluded union-find)
-- + bus-aware quarantine. See design/wiring-implicit-graph.md § Quarantine.
local t   = require('support')
local DAG = require('DAG')

local function g(nodes, edges)
  return { nodes = nodes, edges = edges or {}, nextId = 1 }
end
local master = { kind = 'master',
                 ports = { audio = { ins = 1, outs = 0 }, midi = { ins = 0, outs = 0 } } }
local function src()
  return { kind = 'source', ports = { audio = { ins = 0, outs = 1 }, midi = { ins = 0, outs = 1 } } }
end
local function fx(opts)
  return { kind = 'fx', busAware = opts and opts.busAware,
           ports = { audio = { ins = 1, outs = 1 }, midi = { ins = 1, outs = 1 } } }
end

-- components keyed by their sorted node list -> reason (false = managed), for order-free asserts.
local function byNodes(comps)
  local out = {}
  for _, c in ipairs(comps) do out[table.concat(c.nodes, ',')] = c.reason or false end
  return out
end

return {
  {
    name = 'classify: one source->fx->master chain is a single managed component',
    run = function()
      local comps = DAG.classify(g(
        { master = master, s = src(), f = fx() },
        { { type='audio', from='s', to='f' }, { type='audio', from='f', to='master' } }))
      t.deepEq(byNodes(comps), { ['f,s'] = false })
    end,
  },
  {
    name = 'classify: master never bridges two independent chains',
    run = function()
      local comps = DAG.classify(g(
        { master = master, sa = src(), fa = fx(), sb = src(), fb = fx() },
        { { type='audio', from='sa', to='fa' }, { type='audio', from='fa', to='master' },
          { type='audio', from='sb', to='fb' }, { type='audio', from='fb', to='master' } }))
      t.deepEq(byNodes(comps), { ['fa,sa'] = false, ['fb,sb'] = false })
    end,
  },
  {
    name = 'classify: a bus-aware fx quarantines its whole component',
    run = function()
      local comps = DAG.classify(g(
        { master = master, s = src(), f1 = fx(), f2 = fx{ busAware = true } },
        { { type='audio', from='s', to='f1' }, { type='midi', from='f1', to='f2' },
          { type='audio', from='f2', to='master' } }))
      t.deepEq(byNodes(comps), { ['f1,f2,s'] = 'busAware' })
    end,
  },
  {
    name = 'classify: bus-aware in one component leaves a sibling managed',
    run = function()
      local comps = DAG.classify(g(
        { master = master, sa = src(), fa = fx{ busAware = true }, sb = src(), fb = fx() },
        { { type='audio', from='sa', to='fa' }, { type='audio', from='fa', to='master' },
          { type='audio', from='sb', to='fb' }, { type='audio', from='fb', to='master' } }))
      t.deepEq(byNodes(comps), { ['fa,sa'] = 'busAware', ['fb,sb'] = false })
    end,
  },
  {
    name = 'classify: an isolated node with no edges is its own managed component',
    run = function()
      local comps = DAG.classify(g({ master = master, lone = src() }, {}))
      t.deepEq(byNodes(comps), { ['lone'] = false })
    end,
  },
  {
    name = 'classify: a seeded feedback component is tagged feedback',
    run = function()
      local comps = DAG.classify(g(
        { master = master, p = fx(), q = fx() },
        { { type='audio', from='p', to='q' } }),
        { p = true, q = true })
      t.deepEq(byNodes(comps), { ['p,q'] = 'feedback' })
    end,
  },
  {
    name = 'classify: feedback outranks bus-aware on the same component',
    run = function()
      local comps = DAG.classify(g(
        { master = master, p = fx{ busAware = true }, q = fx() },
        { { type='audio', from='p', to='q' } }),
        { p = true, q = true })
      t.deepEq(byNodes(comps), { ['p,q'] = 'feedback' })
    end,
  },
}
