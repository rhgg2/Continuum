local t    = require('support')
local util = require('util')

-- Reachability moved from DAG.ancestors/descendants onto wv: ancestorsOf /
-- descendantsOf walk wm's cached { forward, reverse } adjacency. These pin
-- the wiring-page cycle-rejection contract on the real production path.

local FX = { name = 'ReaEQ', ident = 'VST3:ReaEQ (Cockos)' }

local function mkWv(harness)
  local h  = harness.mk()
  local wv = util.instantiate('wiringView', { cm = h.cm })
  return h, wv
end

local function sortedKeys(set)
  local out = {}
  for k in pairs(set) do out[#out+1] = k end
  table.sort(out)
  return out
end

return {
  {
    name = 'isolated node: ancestors = { itself }',
    run = function(harness)
      local _, wv = mkWv(harness)
      wv:addFx(0, 0, FX)
      t.deepEq(sortedKeys(wv:ancestorsOf('n1')), { 'n1' })
    end,
  },
  {
    name = 'audio chain: ancestors of master include everything upstream',
    run = function(harness)
      local _, wv = mkWv(harness)
      wv:addFx(0,   0, FX)
      wv:addFx(100, 0, FX)
      wv:addWire{ type = 'audio', from = 'n1', to = 'n2' }
      wv:addWire{ type = 'audio', from = 'n2', to = 'master' }
      t.deepEq(sortedKeys(wv:ancestorsOf('master')),
               { 'master', 'n1', 'n2' })
    end,
  },
  {
    name = 'reachability follows midi edges too (edge type ignored)',
    run = function(harness)
      local _, wv = mkWv(harness)
      wv:addFx(0,   0, FX)
      wv:addFx(100, 0, FX)
      wv:addWire{ type = 'midi',  from = 'n1', to = 'n2' }
      wv:addWire{ type = 'audio', from = 'n2', to = 'master' }
      t.deepEq(sortedKeys(wv:ancestorsOf('master')),
               { 'master', 'n1', 'n2' })
    end,
  },
  {
    name = 'unrelated branches are excluded',
    run = function(harness)
      local _, wv = mkWv(harness)
      wv:addFx(0,   0, FX)
      wv:addFx(100, 0, FX)
      wv:addFx(200, 0, FX)
      wv:addWire{ type = 'audio', from = 'n1', to = 'n2' }
      local anc = wv:ancestorsOf('n2')
      t.deepEq(sortedKeys(anc), { 'n1', 'n2' })
      t.eq(anc.n3, nil)
    end,
  },
  {
    -- Pins the wiring-page cycle-rejection contract: a draft from X is
    -- ineligible to drop on Y when Y reaches X. ancestorsOf(X) is that set
    -- and crucially excludes X's downstream nodes (legitimate drop targets).
    name = 'cycle-rejection set: ancestors of mid-chain == upstream incl self',
    run = function(harness)
      local _, wv = mkWv(harness)
      wv:addFx(0,   0, FX)
      wv:addFx(100, 0, FX)
      wv:addFx(200, 0, FX)
      wv:addWire{ type = 'audio', from = 'n1', to = 'n2' }
      wv:addWire{ type = 'audio', from = 'n2', to = 'n3' }
      wv:addWire{ type = 'audio', from = 'n3', to = 'master' }
      local anc = wv:ancestorsOf('n2')
      t.deepEq(sortedKeys(anc), { 'n1', 'n2' })
      t.eq(anc.n3,     nil)
      t.eq(anc.master, nil)
    end,
  },
  {
    -- Mirror: forbids cycle-forming new-source candidates when the from-end
    -- of an existing wire is dragged. descendantsOf(Y) excludes Y's upstream.
    name = 'descendants of mid-chain == downstream incl self',
    run = function(harness)
      local _, wv = mkWv(harness)
      wv:addFx(0,   0, FX)
      wv:addFx(100, 0, FX)
      wv:addFx(200, 0, FX)
      wv:addWire{ type = 'audio', from = 'n1', to = 'n2' }
      wv:addWire{ type = 'audio', from = 'n2', to = 'n3' }
      wv:addWire{ type = 'audio', from = 'n3', to = 'master' }
      local desc = wv:descendantsOf('n2')
      t.deepEq(sortedKeys(desc), { 'master', 'n2', 'n3' })
      t.eq(desc.n1, nil)
    end,
  },
}
