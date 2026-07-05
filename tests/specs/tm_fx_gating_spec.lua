-- Phase A of the dirt spine (design/dirty-channels.md § Scheme): a clean fx channel freezes and its
-- derived notes/CCs/pb seats stand in mm; here a channel frozen by another channel's edit keeps its pb seat stream byte-identical and hidden.

local t    = require('support')

local vib30 = { { kind = 'vibrato', period = { 1, 4 }, depth = 30, onset = 0 } }

local function pbSeatsOf(dump, chan)
  local out = {}
  for _, c in ipairs(dump.ccs) do
    if c.evType == 'pb' and c.chan == chan then
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
    name = 'gating: a chan-1 edit freezes chan 2 fx and keeps its pb seat stream',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent(vibHost(1)); h.tm:flush()
      h.tm:addEvent(vibHost(2)); h.tm:flush()

      local before = pbSeatsOf(h.fm:dump(), 2)
      t.truthy(#before >= 8, 'chan 2 seats a vibrato pb stream')

      -- Two chan-1 edits: chan 2 is derivation-clean and freezes both times. Its seats stand in mm,
      -- carried whole -- the generators never re-run.
      h.tm:addEvent(plainNote(1, 480)); h.tm:flush()
      h.tm:addEvent(plainNote(1, 720)); h.tm:flush()

      t.falsy(h.tm:getChannel(2).columns.pb, 'chan 2 seats stay hidden -- no pb column surfaces')
      t.deepEq(pbSeatsOf(h.fm:dump(), 2), before,
        'frozen chan 2 pb seat stream is byte-identical -- its generators never re-ran')
    end,
  },
}
