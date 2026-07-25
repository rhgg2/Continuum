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
    -- Phase 2 of stable-slots makes serialise incremental, and its safety argument is
    -- "the incremental blob matches the full one" -- which needs the full path to be
    -- deterministic in the first place. see plan/stable-slots.md
    name = 'reflushing an unchanged model writes byte-identical bytes',
    run = function()
      local take, rp = freshTake()
      rp:seedMidi(take, {
        notes = {
          { ppq =   0, endppq = 240, chan = 1, pitch = 60, vel = 100 },
          { ppq =   0, endppq = 480, chan = 1, pitch = 64, vel =  90 },
          { ppq = 240, endppq = 480, chan = 2, pitch = 67, vel =  80 },
        },
        ccs = {
          { ppq =   0, chanmsg = 0xB0, chan = 1, msg2 =  7, msg3 = 100,
            shape = 5, tension = 0.5 },   -- 5 = bezier, REAPER's shape code
          { ppq =   0, chanmsg = 0xB0, chan = 1, msg2 = 11, msg3 =  64 },
          { ppq = 120, chanmsg = 0xE0, chan = 1, msg2 =  0, msg3 =  64 },
        },
        texts = { { ppq = 0, eventtype = 3, msg = 'trackname' } },
      })

      local mm = realMM(nil)
      mm:load(take)

      local blobs, realSetAllEvts = {}, rp.MIDI_SetAllEvts
      rp.MIDI_SetAllEvts = function(tk, evts)
        blobs[#blobs + 1] = evts
        return realSetAllEvts(tk, evts)
      end

      -- Each assign rewrites vel to the value the note already holds: enough to dirty
      -- the take and reach the wire, not enough to change what is serialised.
      local _, note = mm:notes()()
      for _ = 1, 2 do
        mm:modify(function() mm:assign(note.uuid, { vel = note.vel }) end)
      end

      t.eq(#blobs, 2, 'both flushes reached the wire')
      t.truthy(blobs[1] == blobs[2], 'an unchanged model reserialises to the same bytes')
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
