-- M/B fx-node actions through the real wv→wm→rm stack: mute silences via rm's
-- pin-stash (ReaEQ is a processor, so its input side is cleared; the wire
-- survives, reported from below), bypass flips the REAPER-native enable. nodeId
-- is the fxId, so both resolve straight through.
local t    = require('support')
local util = require('util')

local FX = { name = 'ReaEQ', ident = 'VST3:ReaEQ (Cockos)' }

local function mkWv(harness)
  local h  = harness.mk()
  local rm = util.instantiate('routingManager', { ds = h.ds })
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
  local wv = util.instantiate('wiringView', { cm = h.cm, wm = wm })
  return h, wv, rm
end

return {
  {
    name = 'mute reaches rm through the stack and keeps the output wiring reported',
    run = function(harness)
      local _, wv, rm = mkWv(harness)
      local fxId = wv:addFx(10, 10, FX)
      local pm   = rm:fx(fxId).pinMaps
      t.eq(wv:muted(fxId), false, 'starts unmuted')

      wv:setMuted(fxId, true)
      t.eq(wv:muted(fxId), true, 'mute toggled through wv→wm→rm')
      local muted = rm:fx(fxId).pinMaps
      t.deepEq(muted.ins,  pm.ins,  'rm still reports the input wiring (the stashed side) — nothing lost')
      t.deepEq(muted.outs, pm.outs, 'output wiring intact too')

      wv:setMuted(fxId, false)
      t.eq(wv:muted(fxId), false, 'unmute toggled back')
    end,
  },
  {
    name = 'bypass flips the native enable, independent of mute',
    run = function(harness)
      local _, wv = mkWv(harness)
      local fxId = wv:addFx(10, 10, FX)
      t.eq(wv:bypassed(fxId), false, 'starts enabled')

      wv:setBypassed(fxId, true)
      t.eq(wv:bypassed(fxId), true, 'bypassed reads back')

      wv:setMuted(fxId, true)
      t.eq(wv:bypassed(fxId), true, 'mute does not disturb bypass')

      wv:setBypassed(fxId, false)
      t.eq(wv:bypassed(fxId), false, 'un-bypassed')
    end,
  },
}
