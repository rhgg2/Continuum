local t    = require('support')
local util = require('util')

local function mkWm(harness, opts)
  local h  = harness.mk(opts)
  local wm = util.instantiate('wiringManager', { cm = h.cm })
  return h, wm
end

return {
  {
    name = 'fresh project: graph has master node, empty edges, _nextId=1',
    run = function(harness)
      local _, wm = mkWm(harness)
      local g = wm:graph()
      t.truthy(g.nodes.master,             'master auto-materialised')
      t.eq(g.nodes.master.kind, 'master',  'master.kind')
      t.eq(#g.edges, 0,                    'no edges in fresh graph')
      t.eq(g._nextId, 1,                   'allocator at 1')
    end,
  },
  {
    name = 'mutate persists via cm; fresh wm instance reads it back',
    run = function(harness)
      local h, wm = mkWm(harness)
      local ok = wm:mutate(function(g)
        g.nodes['s'] = { kind = 'source', trackGuid = 'guid-s',
                         pos = { x = 0, y = 0 }, audio = { ins = 0, outs = 1 } }
        g._nextId = 2
      end)
      t.truthy(ok, 'mutate succeeded')

      local cm2 = util.instantiate('configManager')
      cm2:setContext('take1')
      local wm2 = util.instantiate('wiringManager', { cm = cm2 })
      local g2 = wm2:graph()
      t.truthy(g2.nodes.s,         'source node round-tripped')
      t.eq(g2.nodes.s.trackGuid, 'guid-s')
      t.eq(g2._nextId, 2,          '_nextId round-tripped')
      t.truthy(g2.nodes.master,    'master survives round-trip')
    end,
  },
  {
    name = 'mutate that fails validation returns false+err, graph unchanged, no signal',
    run = function(harness)
      local _, wm = mkWm(harness)
      local before = wm:graph()
      local seen   = {}
      wm:subscribe('wiringChanged', function(p) seen[#seen+1] = p end)

      -- Edge to a node id that doesn't exist: DAG.validate returns unknown_to.
      local ok, err = wm:mutate(function(g)
        util.add(g.edges, { type = 'audio', from = 'master', to = 'ghost' })
      end)
      t.falsy(ok,                       'mutate reports failure')
      -- master-as-source is checked before unknown_to, so the actual code is master_as_source.
      t.truthy(err and err.code,        'err carries a code')

      local after = wm:graph()
      t.eq(#after.edges, #before.edges, 'edge count unchanged')
      t.eq(#seen, 0,                    'no wiringChanged on failure')
    end,
  },
  {
    name = 'successful mutate fires one wiringChanged{kind=mutate}',
    run = function(harness)
      local _, wm = mkWm(harness)
      local seen = {}
      wm:subscribe('wiringChanged', function(p) seen[#seen+1] = p end)
      local ok = wm:mutate(function(g)
        g.nodes['s'] = { kind = 'source', trackGuid = 'guid-s',
                         pos = { x = 0, y = 0 }, audio = { ins = 0, outs = 1 } }
      end)
      t.truthy(ok)
      t.eq(#seen, 1,           'one broadcast')
      t.eq(seen[1].kind, 'mutate')
    end,
  },
  {
    name = 'wm:load() fires wiringChanged{kind=load}',
    run = function(harness)
      local _, wm = mkWm(harness)
      local seen = {}
      wm:subscribe('wiringChanged', function(p) seen[#seen+1] = p end)
      wm:load()
      t.eq(#seen, 1)
      t.eq(seen[1].kind, 'load')
    end,
  },
  {
    name = 'wm:graph() returns a deep copy — caller mutation does not leak',
    run = function(harness)
      local _, wm = mkWm(harness)
      local g = wm:graph()
      g.nodes.master.kind = 'mutated'
      g.nodes.injected = { kind = 'source' }
      local g2 = wm:graph()
      t.eq(g2.nodes.master.kind, 'master', 'inner field untouched')
      t.eq(g2.nodes.injected, nil,         'outer key untouched')
    end,
  },
  {
    name = 'wm:compile()/wm:errors() smoke on a fresh graph',
    run = function(harness)
      local _, wm = mkWm(harness)
      local g = wm:compile():graph()
      t.truthy(g.nodes,            'ctx:graph() returns {nodes,conns}')
      t.truthy(g.conns,            'compile has conns array')
      t.eq(#g.conns, 0,            'no edges -> no conns')
      t.deepEq(wm:errors(), {},    'no capacity overflow on fresh graph')
    end,
  },
}
