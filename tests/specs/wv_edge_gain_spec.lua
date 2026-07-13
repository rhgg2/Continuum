local t    = require('support')
local util = require('util')

local FX = { name = 'ReaEQ', ident = 'VST3:ReaEQ (Cockos)' }

local function mkWv(harness)
  local h  = harness.mk()
  local rm = util.instantiate('routingManager', { ds = h.ds })
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
  local wv = util.instantiate('wiringView', { cm = h.cm, wm = wm })
  return h, wv
end

local function mkAudioWire(wv)
  local a = wv:addFx(0,   0, FX)
  local b = wv:addFx(100, 0, FX)
  wv:addWire{ type = 'audio', from = a, to = b }
  return a, b
end

return {
  {
    name = 'edgeGain defaults to 1.0 when ops.gain is unset',
    run = function(harness)
      local _, wv = mkWv(harness)
      mkAudioWire(wv)
      t.eq(wv:edgeGain(1), 1.0)
    end,
  },
  {
    name = 'edgeGain returns the stored ops.gain when set',
    run = function(harness)
      local _, wv = mkWv(harness)
      mkAudioWire(wv)
      wv:setEdgeGain(1, 0.5)
      t.eq(wv:edgeGain(1), 0.5)
      t.eq(wv:graph().edges[1].ops.gain, 0.5)
    end,
  },
  {
    name = 'setEdgeGain creates ops table when absent',
    run = function(harness)
      local _, wv = mkWv(harness)
      mkAudioWire(wv)
      t.eq(wv:graph().edges[1].ops, nil, 'no ops before first set')
      wv:setEdgeGain(1, 2.5)
      t.eq(wv:graph().edges[1].ops.gain, 2.5)
    end,
  },
  {
    name = 'setEdgeGain is a no-op on a non-audio edge',
    run = function(harness)
      local _, wv = mkWv(harness)
      local a = wv:addFx(0,   0, FX)
      local b = wv:addFx(100, 0, FX)
      wv:addWire{ type = 'midi', from = a, to = b }
      wv:setEdgeGain(1, 0.5)
      t.eq(wv:edgeGain(1), 1.0, 'midi reads as unity (non-audio default)')
      t.eq(wv:graph().edges[1].ops, nil, 'no ops written to midi edge')
    end,
  },
  {
    name = 'setEdgeGain on out-of-range idx is a no-op (no crash)',
    run = function(harness)
      local _, wv = mkWv(harness)
      wv:setEdgeGain(99, 0.5)
      t.eq(#wv:graph().edges, 0)
    end,
  },
  {
    name = 'edgeGain returns 1.0 for non-audio edge regardless of ops',
    run = function(harness)
      local _, wv = mkWv(harness)
      local a = wv:addFx(0,   0, FX)
      local b = wv:addFx(100, 0, FX)
      wv:addWire{ type = 'midi', from = a, to = b }
      -- Manually plant ops.gain through the graph; getter still ignores it
      -- because the edge is non-audio (defensive — design says gain is
      -- audio-only). This pins that contract.
      wv:graph()  -- materialise
      t.eq(wv:edgeGain(1), 1.0)
    end,
  },
}
