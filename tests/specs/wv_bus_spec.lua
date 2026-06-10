local t    = require('support')
local util = require('util')

local FX = { name = 'ReaEQ', ident = 'VST3:ReaEQ (Cockos)' }

local function mkWv(harness)
  local h  = harness.mk()
  local rm = util.instantiate('routingManager')
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
  local wv = util.instantiate('wiringView', { cm = h.cm, wm = wm })
  return h, wv
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
    name = 'wireViews: an in-bus on the consumer claims its incoming audio edge',
    run = function(harness)
      local _, wv = mkWv(harness)
      local _, b = mkAudioWire(wv)
      wv:addBus(b, { dir = 'in', ports = { 1 }, side = 'L' })
      t.deepEq(wv:wireViews()[1].bus, { nodeId = b, busIdx = 1, bussedEnd = 'to' })
    end,
  },
  {
    name = 'wireViews: an out-bus on the producer claims its outgoing edge from the `from` end',
    run = function(harness)
      local _, wv = mkWv(harness)
      local a = mkAudioWire(wv)
      wv:addBus(a, { dir = 'out', ports = { 1 }, side = 'R' })
      t.deepEq(wv:wireViews()[1].bus, { nodeId = a, busIdx = 1, bussedEnd = 'from' })
    end,
  },
  {
    name = 'wireViews: an in-bus takes precedence when both ends are bussed',
    run = function(harness)
      local _, wv = mkWv(harness)
      local a, b = mkAudioWire(wv)
      wv:addBus(a, { dir = 'out', ports = { 1 }, side = 'R' })
      wv:addBus(b, { dir = 'in',  ports = { 1 }, side = 'L' })
      t.eq(wv:wireViews()[1].bus.bussedEnd, 'to', 'consumer in-bus wins over producer out-bus')
    end,
  },
  {
    name = 'wireViews: a bus does not claim a midi edge (audio only in v1)',
    run = function(harness)
      local _, wv = mkWv(harness)
      local a = wv:addFx(0,   0, FX)
      local b = wv:addFx(100, 0, FX)
      wv:addWire{ type = 'midi', from = a, to = b }
      wv:addBus(b, { dir = 'in', ports = { 1 }, side = 'L' })
      t.falsy(wv:wireViews()[1].bus, 'midi edge left unbussed')
    end,
  },
  {
    name = 'wireViews: an unbussed edge carries no bus stamp',
    run = function(harness)
      local _, wv = mkWv(harness)
      mkAudioWire(wv)
      t.falsy(wv:wireViews()[1].bus)
    end,
  },
}
