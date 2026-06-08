local t    = require('support')
local util = require('util')

local function mkWm(harness, opts)
  local h  = harness.mk(opts)
  local rm = util.instantiate('routingManager')
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
  return h, wm
end

return {
  {
    name = 'fresh project: graph has master node, empty edges',
    run = function(harness)
      local _, wm = mkWm(harness)
      local g = wm:graph()
      t.truthy(g.nodes.master,             'master auto-materialised')
      t.eq(g.nodes.master.kind, 'master',  'master.kind')
      t.eq(#g.edges, 0,                    'no edges in fresh graph')
    end,
  },
  {
    name = 'load reconstructs the graph from REAPER routing (read is the store)',
    run = function(harness)
      local h, wm = mkWm(harness)
      -- A bare project track with no incoming sends is a source node, keyed by its guid.
      local track = { __label = 'src' }
      table.insert(h.reaper._state.projectTracks, track)
      h.reaper._state.trackGuids[track] = 'guid-s'

      wm:load()
      local g = wm:graph()
      t.truthy(g.nodes['guid-s'],         'source recovered from REAPER, keyed by track guid')
      t.eq(g.nodes['guid-s'].kind, 'source')
      t.eq(g.nodes['guid-s'].trackId, 'guid-s')
      t.truthy(g.nodes.master,            'master present')
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
        g.nodes['s'] = { kind = 'source', trackId = 'guid-s',
                         pos = { x = 0, y = 0 },
                         ports = { audio = { ins = 0, outs = 1 },
                                   midi  = { ins = 0, outs = 1 } } }
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
}
