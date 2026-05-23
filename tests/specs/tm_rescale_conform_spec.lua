-- Rescale-grow self-repair for conform notes.
--
-- rescaleLength stages every event's doubled geometry, flushes, THEN
-- grows the take (tm:975-979). At that flush the take is still the OLD
-- length, so the flush-time CSK seam clips a trailing conform note's
-- raw note-off to the stale length. The conform note's natural endppqL
-- is preserved (the seam never writes endppqL for a conform note), so
-- conform-tail on setLength's reload rebuild re-derives the raw tail at
-- the now-current take length. Pins that round-trip: the clip is
-- transient, the end state correct.

local t = require('support')

return {
  {
    name = 'rescale grow 2x re-grows a trailing conform note raw tail',
    run = function(harness)
      local h = harness.mk{ seed = { notes = {
        { ppq = 0,    endppq = 60,   ppqL = 0,    endppqL = 60,
          chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0, lane = 1 },
        { ppq = 3780, endppq = 3840, ppqL = 3780, endppqL = 3840,
          chan = 1, pitch = 67, vel = 100, detune = 0, delay = 0,
          lane = 1, conform = true },
      } } }

      h.vm:applyTakeProperties{ name = h.fm:name(), beats = 32, mode = 'rescale' }

      t.eq(h.fm:length(), 7680, 'length doubled')
      local conf
      for _, n in ipairs(h.fm:dump().notes) do
        if n.pitch == 67 then conf = n end
      end
      t.truthy(conf, 'conform note survived rescale')
      t.eq(conf.ppq,     7560, 'onset doubled')
      t.eq(conf.endppqL, 7680, 'natural tail doubled, not left at stale length')
      t.eq(conf.endppq,  7680, 'raw tail re-grew to the new take length')
    end,
  },
}
