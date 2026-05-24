local t    = require('support')
local util = require('util')

local function mkWv(harness)
  local h  = harness.mk()
  local wv = util.instantiate('wiringView', { cm = h.cm })
  return h, wv
end

local function fxNodes(g)
  local out = {}
  for id, n in pairs(g.nodes) do
    if n.kind == 'fx' then out[id] = n end
  end
  return out
end

local function fxCount(g)
  local n = 0
  for _ in pairs(fxNodes(g)) do n = n + 1 end
  return n
end

return {
  {
    name = 'addFx mints id "n"<_nextId>, bumps _nextId, writes logical pos',
    run = function(harness)
      local _, wv = mkWv(harness)
      local before = wv:graph()
      t.eq(before._nextId, 1, 'fresh _nextId is 1')

      t.truthy(wv:addFx(12, -34))
      local after = wv:graph()
      t.eq(after._nextId, 2, '_nextId bumped to 2')
      t.truthy(after.nodes.n1,           'id minted as n1')
      t.eq(after.nodes.n1.kind, 'fx')
      t.eq(after.nodes.n1.pos.x, 12)
      t.eq(after.nodes.n1.pos.y, -34)
      t.eq(after.nodes.n1.audio.ins,  1, 'stereo in')
      t.eq(after.nodes.n1.audio.outs, 1, 'stereo out')
    end,
  },
  {
    name = 'successive addFx calls stair-step ids and leave master alone',
    run = function(harness)
      local _, wv = mkWv(harness)
      wv:addFx(0, 0); wv:addFx(10, 10); wv:addFx(20, 20)
      local g = wv:graph()
      t.eq(fxCount(g), 3,                'three fx nodes')
      t.truthy(g.nodes.n1 and g.nodes.n2 and g.nodes.n3, 'ids n1,n2,n3')
      t.eq(g._nextId, 4,                 '_nextId past last mint')
      t.eq(g.nodes.master.kind, 'master', 'master untouched')
    end,
  },
  {
    name = 'moveNode updates pos of an existing node via wm:mutate',
    run = function(harness)
      local _, wv = mkWv(harness)
      wv:addFx(0, 0)
      t.truthy(wv:moveNode('n1', 50, -25))
      local g = wv:graph()
      t.eq(g.nodes.n1.pos.x, 50)
      t.eq(g.nodes.n1.pos.y, -25)
    end,
  },
  {
    name = 'moveNode on missing id is a no-op (validation still passes)',
    run = function(harness)
      local _, wv = mkWv(harness)
      local before = wv:graph()
      t.truthy(wv:moveNode('ghost', 1, 2))
      local after = wv:graph()
      t.deepEq(after.nodes, before.nodes, 'no nodes changed')
    end,
  },
}
