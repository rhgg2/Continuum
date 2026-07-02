-- Phase A of the dirt spine (design/dirty-channels.md § Scheme): fx generator runs are gated
-- per dirty channel. A clean fx channel freezes -- its derived notes/CCs/carriers stand in mm,
-- fx leaves noteLive empty so tails/pbs/pcs skip it too. The one coupling that does NOT live in
-- mm is the persisted carrier map (fxCarrier): reapCarriers replaces it wholesale, so a gated
-- rebuild must seed the frozen channels' entries or their routing is erased and generator-owned
-- carrier CCs leak back into the view. This is the design's named ds-key-carry red test.

local t    = require('support')

local DELTA_MSB = 20
local vib30 = { { kind = 'vibrato', period = { 1, 4 }, depth = 30, onset = 0 } }

local function carriersOf(dump, chan)
  local out = {}
  for _, c in ipairs(dump.ccs) do
    if c.evType == 'cc' and c.cc == DELTA_MSB and c.chan == chan then
      out[#out + 1] = { ppq = c.ppq, val = c.val, shape = c.shape }
    end
  end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
  return out
end

local function vibHost(chan)
  return { evType = 'note', ppq = 0, endppq = 240, chan = chan, pitch = 60,
           vel = 100, detune = 0, delay = 0, lane = 1, fx = vib30 }
end

local function plainNote(chan, ppq)
  return { evType = 'note', ppq = ppq, endppq = ppq + 240, chan = chan, pitch = 62,
           vel = 100, detune = 0, delay = 0, lane = 1 }
end

return {
  {
    name = 'ds-key carry: a chan-1 edit freezes chan 2 fx and keeps its carrier routing',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent(vibHost(1)); h.tm:flush()
      h.tm:addEvent(vibHost(2)); h.tm:flush()

      local before = carriersOf(h.fm:dump(), 2)
      t.truthy(#before >= 8, 'chan 2 emits a vibrato carrier stream')
      t.truthy(h.ds:get('fxCarrier') and h.ds:get('fxCarrier')[2], 'chan 2 carrier map persisted')

      -- First chan-1 edit: chan 2 is derivation-clean and freezes. Without the carrier carry,
      -- reapCarriers persists a map missing chan 2 here -- erasing its routing entry.
      h.tm:addEvent(plainNote(1, 480)); h.tm:flush()
      t.truthy(h.ds:get('fxCarrier')[2],
        'chan 2 carrier map survived the chan-1 edit (item-3 ds-key carry, not erased)')

      -- Second chan-1 edit: had chan 2's entry been erased, its carrierRoute would now be empty
      -- and its carrier CCs would surface as a visible cc-20 column. The carry keeps them out.
      h.tm:addEvent(plainNote(1, 720)); h.tm:flush()
      t.falsy(h.tm:getChannel(2).columns.ccs[DELTA_MSB],
        'chan 2 carriers stay routed out of columns after two chan-1 edits')
      t.deepEq(carriersOf(h.fm:dump(), 2), before,
        'frozen chan 2 carrier stream is byte-identical -- its generators never re-ran')
    end,
  },
}
