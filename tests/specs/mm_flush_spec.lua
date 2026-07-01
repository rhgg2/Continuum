-- A modify rewrites the whole take, so events mm doesn't model -- a non-sidecar
-- text meta, an unmodelled status byte -- must be carried through, not dropped.
-- ("Respect what's there.") Pins the load->modify flush as lossless.

local t = require('support')
local realMM = require('realMidiManager')()

local function freshTake()
  local fakeReaper = require('fakeReaper').new()
  _G.reaper = fakeReaper
  local take = 'take-flush-carry'
  fakeReaper:bindTake(take, take .. '/item', take .. '/track')
  return take, fakeReaper
end

return {
  {
    name = 'modify carries through unmodelled text + passthrough events',
    run = function()
      local take, rp = freshTake()
      rp:seedMidi(take, {
        notes       = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } },
        texts       = { { ppq = 0,   eventtype = 3, msg = 'trackname' } },   -- non-sidecar meta
        passthrough = { { ppq = 120, flags = 0,     msg = '\xF2\x01\x02' } },   -- song-position ptr
      })

      local mm = realMM(nil)
      mm:load(take)

      local _, note = mm:notes()()
      mm:modify(function() mm:assign(note.token, { vel = 90 }) end)

      local dump = rp:dumpMidi(take)

      local keptText = false
      for _, e in ipairs(dump.texts) do
        if e.eventtype == 3 and e.msg == 'trackname' then keptText = true end
      end
      t.truthy(keptText, 'non-sidecar text meta survives the whole-take rewrite')

      t.eq(#dump.passthrough,        1,              'passthrough event survives the rewrite')
      t.eq(dump.passthrough[1].msg,  '\xF2\x01\x02', 'passthrough bytes intact')
    end,
  },

  {
    -- The sidecar cache reuses a note's notation record across flushes; a
    -- structural edit must invalidate it, not serve the stale pre-edit body.
    name = 'editing a cached note re-encodes its notation sidecar at the new pitch',
    run = function()
      local take, rp = freshTake()
      rp:seedMidi(take, {
        notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } },
      })

      local mm = realMM(nil)
      mm:load(take)   -- mints a uuid + caches the note's notation sidecar

      local _, note = mm:notes()()
      mm:modify(function() mm:assign(note.token, { pitch = 67 }) end)

      local pitch
      for _, e in ipairs(rp:dumpMidi(take).texts) do
        local p = e.eventtype == 15 and e.msg:match('^NOTE%s+%d+%s+(%d+)%s+custom')
        if p then pitch = tonumber(p) end
      end
      t.eq(pitch, 67, 'transposed note re-encodes its notation sidecar')
    end,
  },
}
