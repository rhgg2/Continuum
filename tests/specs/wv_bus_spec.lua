local t    = require('support')
local util = require('util')

local FX = { name = 'ReaEQ', ident = 'VST3:ReaEQ (Cockos)' }

local function mkWv(harness)
  local h  = harness.mk()
  local rm = util.instantiate('routingManager', { ds = h.ds })
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

return {
  {
    name = 'wireViews: insertBus at the consumer re-points the feed and tags both edges',
    run = function(harness)
      local _, wv = mkWv(harness)
      local _, b = mkAudioWire(wv)
      local id = wv:insertBus{ pos = { x = 0, y = -80 }, orient = 'H',
                               node = b, port = 1, dir = 'in' }
      local wires = wv:wireViews()
      t.deepEq(wires[1].bus, { busId = id, bussedEnd = 'to' },   'feed re-pointed into the bar')
      t.deepEq(wires[2].bus, { busId = id, bussedEnd = 'from' }, 'trunk out of the bar')
    end,
  },
  {
    name = 'wireViews: insertBus at the producer re-points the consumer wire from the bar',
    run = function(harness)
      local _, wv = mkWv(harness)
      local a = mkAudioWire(wv)
      local id = wv:insertBus{ pos = { x = 0, y = 80 }, orient = 'H',
                               node = a, port = 1, dir = 'out' }
      local wires = wv:wireViews()
      t.deepEq(wires[1].bus, { busId = id, bussedEnd = 'from' }, 'consumer wire leaves the bar')
      t.deepEq(wires[2].bus, { busId = id, bussedEnd = 'to' },   'trunk feeds the bar')
    end,
  },
  {
    name = 'wireViews: the `to` end wins when both endpoints are busses',
    run = function(harness)
      local _, wv, wm = mkWv(harness)
      local b1 = wm:addBusNode({ x = 0, y = 0 })
      local b2 = wm:addBusNode({ x = 100, y = 0 })
      wv:addWire{ type = 'audio', from = b1, to = b2 }
      t.deepEq(wv:wireViews()[1].bus, { busId = b2, bussedEnd = 'to' })
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
    name = 'busViews: an inserted buss projects from its node at every degree',
    run = function(harness)
      local _, wv = mkWv(harness)
      local _, b = mkAudioWire(wv)
      local id = wv:insertBus{ pos = { x = 5, y = -70 }, orient = 'H',
                               node = b, port = 1, dir = 'in' }
      local bvs = wv:busViews()
      t.eq(#bvs, 1)
      t.deepEq(bvs[1], { id = id, pos = { x = 5, y = -70 }, orient = 'H', matrix = true })
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
    name = 'deleting a tapped node drops its taps; the buss survives',
    run = function(harness)
      local _, wv, wm = mkWv(harness)
      local _, b = mkAudioWire(wv)
      local id = wv:insertBus{ pos = { x = 0, y = -80 }, orient = 'H',
                               node = b, port = 1, dir = 'in' }
      wv:deleteNode(b)
      local rec = wm:busRecords()[id]
      t.truthy(rec, 'buss outlives a tapped node')
      t.deepEq(rec.outs, {}, 'its tap went with the node')
      t.eq(#rec.ins, 1, 'far side untouched')
    end,
  },
  {
    name = 'moveNodes persists an inserted buss pos through the record',
    run = function(harness)
      local _, wv, wm = mkWv(harness)
      local _, b = mkAudioWire(wv)
      local id = wv:insertBus{ pos = { x = 0, y = -80 }, orient = 'H',
                               node = b, port = 1, dir = 'in' }
      wv:moveNodes({ [id] = { x = 33, y = 44 } })
      t.deepEq(wm:busRecords()[id].pos, { x = 33, y = 44 })
    end,
  },
}
