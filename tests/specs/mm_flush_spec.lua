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
      mm:modify(function() mm:assign(note.uuid, { vel = 90 }) end)

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
      mm:modify(function() mm:assign(note.uuid, { pitch = 67 }) end)

      local pitch
      for _, e in ipairs(rp:dumpMidi(take).texts) do
        local p = e.eventtype == 15 and e.msg:match('^NOTE%s+%d+%s+(%d+)%s+custom')
        if p then pitch = tonumber(p) end
      end
      t.eq(pitch, 67, 'transposed note re-encodes its notation sidecar')
    end,
  },

  {
    -- MIDI_Sort after the write exists only to reseat REAPER's play cursor, which SetAllEvts
    -- strands on the old event layout. It is not what orders the take -- serialise is -- so the
    -- editing case can skip a call that costs ~9ms on a dense take.
    name = 'a stopped-transport flush skips MIDI_Sort and still writes an ordered take',
    run = function()
      local take, rp = freshTake()
      rp:seedMidi(take, {
        notes = { { ppq = 480, endppq = 720, chan = 1, pitch = 64, vel = 100 } },
      })

      local mm = realMM(nil)
      mm:load(take)

      local sorts, realSort = 0, rp.MIDI_Sort
      rp.MIDI_Sort = function(tk) sorts = sorts + 1; return realSort(tk) end

      -- Added behind the seeded note, so only the serialiser's ordering puts it first.
      mm:modify(function()
        mm:add({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 })
      end)

      t.eq(sorts, 0, 'transport stopped: the write skips MIDI_Sort')

      local ppqs = {}
      for _, n in ipairs(rp:dumpMidi(take).notes) do ppqs[#ppqs + 1] = n.ppq end
      t.deepEq(ppqs, { 0, 480 }, 'the take is in ppq order anyway -- REAPER never sorted it')
    end,
  },

  {
    name = 'a flush during playback still sorts, to reseat the strandable play cursor',
    run = function()
      local take, rp = freshTake()
      rp:seedMidi(take, {
        notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } },
      })

      local mm = realMM(nil)
      mm:load(take)

      local sorts, realSort = 0, rp.MIDI_Sort
      rp.MIDI_Sort = function(tk) sorts = sorts + 1; return realSort(tk) end
      rp:setPlay(true)

      local _, note = mm:notes()()
      mm:modify(function() mm:assign(note.uuid, { vel = 90 }) end)

      t.truthy(sorts > 0, 'transport running: the write sorts so the cursor re-indexes')
    end,
  },
}
