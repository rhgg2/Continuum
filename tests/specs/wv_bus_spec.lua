local t    = require('support')
local util = require('util')

local FX = { name = 'ReaEQ', ident = 'VST3:ReaEQ (Cockos)' }

local function mkWv(harness)
  local h  = harness.mk()
  local rm = util.instantiate('routingManager')
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
  local wv = util.instantiate('wiringView', { cm = h.cm, wm = wm })
  return h, wv, wm
end

-- a --audio--> b, both real fx nodes.
local function mkAudioWire(wv)
  local a = wv:addFx(0,   0, FX)
  local b = wv:addFx(100, 0, FX)
  wv:addWire{ type = 'audio', from = a, to = b }
  return a, b
end

local function inClaim(node)  return { node = node, port = 1, dir = 'in'  } end
local function outClaim(node) return { node = node, port = 1, dir = 'out' } end

return {
  {
    name = 'wireViews: an in-claim on the consumer tags its incoming audio edge',
    run = function(harness)
      local _, wv = mkWv(harness)
      local _, b = mkAudioWire(wv)
      local id = wv:addBusRecord{ pos = { x = 0, y = -80 }, orient = 'H', claim = inClaim(b) }
      t.deepEq(wv:wireViews()[1].bus, { busId = id, bussedEnd = 'to' })
    end,
  },
  {
    name = 'wireViews: an out-claim on the producer tags its outgoing edge from the `from` end',
    run = function(harness)
      local _, wv = mkWv(harness)
      local a = mkAudioWire(wv)
      local id = wv:addBusRecord{ pos = { x = 0, y = 80 }, orient = 'H', claim = outClaim(a) }
      t.deepEq(wv:wireViews()[1].bus, { busId = id, bussedEnd = 'from' })
    end,
  },
  {
    name = 'wireViews: the in-claim takes precedence when both ends are claimed',
    run = function(harness)
      local _, wv = mkWv(harness)
      local a, b = mkAudioWire(wv)
      wv:addBusRecord{ pos = { x = 0, y = 80 }, orient = 'H', claim = outClaim(a) }
      local inId = wv:addBusRecord{ pos = { x = 0, y = -80 }, orient = 'H', claim = inClaim(b) }
      local bus = wv:wireViews()[1].bus
      t.eq(bus.bussedEnd, 'to', 'consumer in-claim wins over producer out-claim')
      t.eq(bus.busId, inId)
    end,
  },
  {
    name = 'wireViews: a claim does not tag a midi edge (audio only)',
    run = function(harness)
      local _, wv = mkWv(harness)
      local a = wv:addFx(0,   0, FX)
      local b = wv:addFx(100, 0, FX)
      wv:addWire{ type = 'midi', from = a, to = b }
      wv:addBusRecord{ pos = { x = 0, y = -80 }, orient = 'H', claim = inClaim(b) }
      t.falsy(wv:wireViews()[1].bus, 'midi edge left untagged')
    end,
  },
  {
    name = 'wireViews: an unclaimed edge carries no bus stamp',
    run = function(harness)
      local _, wv = mkWv(harness)
      mkAudioWire(wv)
      t.falsy(wv:wireViews()[1].bus)
    end,
  },
  {
    name = 'wireViews: edges incident to a bus node are tagged structurally (matrix)',
    run = function(harness)
      local _, wv, wm = mkWv(harness)
      local a, b = mkAudioWire(wv)
      local bus = wm:addBusNode({ x = 50, y = 100 })
      wv:addWire{ type = 'audio', from = a, to = bus }
      wv:addWire{ type = 'audio', from = bus, to = b }
      local wires = wv:wireViews()
      t.deepEq(wires[2].bus, { busId = bus, bussedEnd = 'to' },   'edge into the bus')
      t.deepEq(wires[3].bus, { busId = bus, bussedEnd = 'from' }, 'edge out of the bus')
    end,
  },
  {
    name = 'busViews: a fan record projects pos/orient/claim; no matrix flag',
    run = function(harness)
      local _, wv = mkWv(harness)
      local _, b = mkAudioWire(wv)
      local id = wv:addBusRecord{ pos = { x = 5, y = -70 }, orient = 'H', claim = inClaim(b) }
      local bvs = wv:busViews()
      t.eq(#bvs, 1)
      t.deepEq(bvs[1], { id = id, pos = { x = 5, y = -70 }, orient = 'H', claim = inClaim(b) })
    end,
  },
  {
    name = 'busViews + nodeViews: a bus node projects matrix=true and category bus',
    run = function(harness)
      local _, wv, wm = mkWv(harness)
      local bus = wm:addBusNode({ x = 7, y = 9 })
      local bv = wv:busViews()[1]
      t.eq(bv.id, bus)
      t.truthy(bv.matrix, 'node-backed buss flagged matrix')
      t.deepEq(bv.pos, { x = 7, y = 9 }, 'pos mirrors the node')
      t.falsy(bv.claim)
      local nv
      for _, n in ipairs(wv:nodeViews()) do if n.id == bus then nv = n end end
      t.eq(nv.category, 'bus')
      t.eq(nv.orient, 'V')
      t.eq(nv.label, 'buss')
    end,
  },
  {
    name = 'deleting the claimed node GCs the buss record and unsticks the wires',
    run = function(harness)
      local _, wv, wm = mkWv(harness)
      local _, b = mkAudioWire(wv)
      local id = wv:addBusRecord{ pos = { x = 0, y = -80 }, orient = 'H', claim = inClaim(b) }
      wv:deleteNode(b)
      t.falsy(wm:busRecords()[id], 'record died with its claimed node')
      t.eq(#wv:busViews(), 0)
    end,
  },
  {
    name = 'moveNodes routes a record-only buss to its record pos',
    run = function(harness)
      local _, wv, wm = mkWv(harness)
      local _, b = mkAudioWire(wv)
      local id = wv:addBusRecord{ pos = { x = 0, y = -80 }, orient = 'H', claim = inClaim(b) }
      wv:moveNodes({ [id] = { x = 33, y = 44 } })
      t.deepEq(wm:busRecords()[id].pos, { x = 33, y = 44 })
    end,
  },
}
