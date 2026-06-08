local t    = require('support')
local util = require('util')

-- Reachability moved from DAG.ancestors/descendants onto wv: ancestorsOf /
-- descendantsOf walk wm's cached { forward, reverse } adjacency. These pin
-- the wiring-page cycle-rejection contract on the real production path.

local FX = { name = 'ReaEQ', ident = 'VST3:ReaEQ (Cockos)' }

local function mkWv(harness)
  local h  = harness.mk()
  local rm = util.instantiate('routingManager')
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
  local wv = util.instantiate('wiringView', { cm = h.cm, wm = wm })
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
      local a = wv:addFx(0, 0, FX)
      t.deepEq(sortedKeys(wv:ancestorsOf(a)), { a })
    end,
  },
  {
    name = 'audio chain: ancestors of master include everything upstream',
    run = function(harness)
      local _, wv = mkWv(harness)
      local a = wv:addFx(0,   0, FX)
      local b = wv:addFx(100, 0, FX)
      wv:addWire{ type = 'audio', from = a, to = b }
      wv:addWire{ type = 'audio', from = b, to = 'master' }
      t.deepEq(sortedKeys(wv:ancestorsOf('master')),
               sortedKeys({ master = true, [a] = true, [b] = true }))
    end,
  },
  {
    name = 'reachability follows midi edges too (edge type ignored)',
    run = function(harness)
      local _, wv = mkWv(harness)
      local a = wv:addFx(0,   0, FX)
      local b = wv:addFx(100, 0, FX)
      wv:addWire{ type = 'midi',  from = a, to = b }
      wv:addWire{ type = 'audio', from = b, to = 'master' }
      t.deepEq(sortedKeys(wv:ancestorsOf('master')),
               sortedKeys({ master = true, [a] = true, [b] = true }))
    end,
  },
  {
    name = 'unrelated branches are excluded',
    run = function(harness)
      local _, wv = mkWv(harness)
      local a = wv:addFx(0,   0, FX)
      local b = wv:addFx(100, 0, FX)
      local c = wv:addFx(200, 0, FX)
      wv:addWire{ type = 'audio', from = a, to = b }
      local anc = wv:ancestorsOf(b)
      t.deepEq(sortedKeys(anc), sortedKeys({ [a] = true, [b] = true }))
      t.eq(anc[c], nil)
    end,
  },
  {
    -- Pins the wiring-page cycle-rejection contract: a draft from X is
    -- ineligible to drop on Y when Y reaches X. ancestorsOf(X) is that set
    -- and crucially excludes X's downstream nodes (legitimate drop targets).
    name = 'cycle-rejection set: ancestors of mid-chain == upstream incl self',
    run = function(harness)
      local _, wv = mkWv(harness)
      local a = wv:addFx(0,   0, FX)
      local b = wv:addFx(100, 0, FX)
      local c = wv:addFx(200, 0, FX)
      wv:addWire{ type = 'audio', from = a, to = b }
      wv:addWire{ type = 'audio', from = b, to = c }
      wv:addWire{ type = 'audio', from = c, to = 'master' }
      local anc = wv:ancestorsOf(b)
      t.deepEq(sortedKeys(anc), sortedKeys({ [a] = true, [b] = true }))
      t.eq(anc[c],     nil)
      t.eq(anc.master, nil)
    end,
  },
  {
    -- Mirror: forbids cycle-forming new-source candidates when the from-end
    -- of an existing wire is dragged. descendantsOf(Y) excludes Y's upstream.
    name = 'descendants of mid-chain == downstream incl self',
    run = function(harness)
      local _, wv = mkWv(harness)
      local a = wv:addFx(0,   0, FX)
      local b = wv:addFx(100, 0, FX)
      local c = wv:addFx(200, 0, FX)
      wv:addWire{ type = 'audio', from = a, to = b }
      wv:addWire{ type = 'audio', from = b, to = c }
      wv:addWire{ type = 'audio', from = c, to = 'master' }
      local desc = wv:descendantsOf(b)
      t.deepEq(sortedKeys(desc), sortedKeys({ master = true, [b] = true, [c] = true }))
      t.eq(desc[a], nil)
    end,
  },
}
