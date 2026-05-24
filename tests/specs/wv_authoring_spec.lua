local t    = require('support')
local util = require('util')

local FX = { name = 'ReaEQ', ident = 'VST3:ReaEQ (Cockos)' }

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

      t.truthy(wv:addFx(12, -34, FX))
      local after = wv:graph()
      t.eq(after._nextId, 2, '_nextId bumped to 2')
      t.truthy(after.nodes.n1,           'id minted as n1')
      t.eq(after.nodes.n1.kind, 'fx')
      t.eq(after.nodes.n1.pos.x, 12)
      t.eq(after.nodes.n1.pos.y, -34)
      t.eq(after.nodes.n1.fxIdent,   FX.ident, 'ident from picker record')
      t.eq(after.nodes.n1.fxDisplay, FX.name,  'display name from picker record')
      t.eq(after.nodes.n1.audio.ins,  1, 'stereo in')
      t.eq(after.nodes.n1.audio.outs, 1, 'stereo out')
    end,
  },
  {
    name = 'successive addFx calls stair-step ids and leave master alone',
    run = function(harness)
      local _, wv = mkWv(harness)
      wv:addFx(0, 0, FX); wv:addFx(10, 10, FX); wv:addFx(20, 20, FX)
      local g = wv:graph()
      t.eq(fxCount(g), 3,                'three fx nodes')
      t.truthy(g.nodes.n1 and g.nodes.n2 and g.nodes.n3, 'ids n1,n2,n3')
      t.eq(g._nextId, 4,                 '_nextId past last mint')
      t.eq(g.nodes.master.kind, 'master', 'master untouched')
    end,
  },
  {
    name = 'moveNodes writes pos for one node via wm:mutate',
    run = function(harness)
      local _, wv = mkWv(harness)
      wv:addFx(0, 0, FX)
      t.truthy(wv:moveNodes{ n1 = { x = 50, y = -25 } })
      local g = wv:graph()
      t.eq(g.nodes.n1.pos.x, 50)
      t.eq(g.nodes.n1.pos.y, -25)
    end,
  },
  {
    name = 'moveNodes writes several ids atomically in one mutate',
    run = function(harness)
      local _, wv = mkWv(harness)
      wv:addFx(0, 0, FX); wv:addFx(0, 0, FX); wv:addFx(0, 0, FX)
      t.truthy(wv:moveNodes{
        n1 = { x = 10, y = 20 },
        n2 = { x = 30, y = 40 },
        n3 = { x = 50, y = 60 },
      })
      local g = wv:graph()
      t.eq(g.nodes.n1.pos.x, 10); t.eq(g.nodes.n1.pos.y, 20)
      t.eq(g.nodes.n2.pos.x, 30); t.eq(g.nodes.n2.pos.y, 40)
      t.eq(g.nodes.n3.pos.x, 50); t.eq(g.nodes.n3.pos.y, 60)
    end,
  },
  {
    name = 'moveNodes skips missing ids; existing ids still land',
    run = function(harness)
      local _, wv = mkWv(harness)
      wv:addFx(0, 0, FX)
      t.truthy(wv:moveNodes{
        n1    = { x = 7, y = 8 },
        ghost = { x = 1, y = 2 },
      })
      local g = wv:graph()
      t.eq(g.nodes.n1.pos.x, 7)
      t.eq(g.nodes.n1.pos.y, 8)
      t.truthy(g.nodes.ghost == nil, 'missing id stayed missing')
    end,
  },
  {
    name = 'moveNodes with empty map is a no-op (mutate still succeeds)',
    run = function(harness)
      local _, wv = mkWv(harness)
      wv:addFx(11, 22, FX)
      local before = wv:graph()
      t.truthy(wv:moveNodes{})
      local after = wv:graph()
      t.deepEq(after.nodes, before.nodes)
    end,
  },
  {
    name = 'listInstalledFX is a passthrough to wm',
    run = function(harness)
      local _, wv = mkWv(harness)
      reaper.EnumInstalledFX = function(i)
        if i == 0 then return true, 'VST3: ReaEQ (Cockos)',   'VST3:ReaEQ (Cockos)'   end
        if i == 1 then return true, 'VST3: ReaComp (Cockos)', 'VST3:ReaComp (Cockos)' end
        return false
      end
      local list = wv:listInstalledFX()
      t.eq(#list, 2)
      t.eq(list[1].name,  'VST3: ReaEQ (Cockos)',   'raw name passes through')
      t.eq(list[2].ident, 'VST3:ReaComp (Cockos)',  'ident untouched')
    end,
  },
  {
    name = 'selection starts empty, setSelection writes the id set',
    run = function(harness)
      local _, wv = mkWv(harness)
      t.deepEq(wv:selection(), {}, 'fresh selection is empty')
      wv:setSelection{ n1 = true, n2 = true }
      t.deepEq(wv:selection(), { n1 = true, n2 = true })
    end,
  },
  {
    name = 'setSelection replaces wholesale (no merge with previous)',
    run = function(harness)
      local _, wv = mkWv(harness)
      wv:setSelection{ n1 = true, n2 = true }
      wv:setSelection{ n3 = true }
      t.deepEq(wv:selection(), { n3 = true }, 'previous ids dropped')
    end,
  },
  {
    name = 'setSelection{} clears',
    run = function(harness)
      local _, wv = mkWv(harness)
      wv:setSelection{ n1 = true }
      wv:setSelection{}
      t.deepEq(wv:selection(), {})
    end,
  },
  {
    name = 'setSelection defensive-copies its argument',
    run = function(harness)
      local _, wv = mkWv(harness)
      local input = { n1 = true }
      wv:setSelection(input)
      input.n2 = true                                  -- mutate caller's table after the call
      t.deepEq(wv:selection(), { n1 = true }, 'wv view not aliased to caller table')
    end,
  },
}
