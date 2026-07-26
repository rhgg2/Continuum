-- Phase 2f of stable-slots: the verbs record per-slot key dirt and flushTake splices the
-- wire it already holds instead of rebuilding it. Two things need pinning. That the splice
-- path is taken at all -- a steady-state edit must reach the take with zero buildWire calls,
-- which is what goes red today. And that it stays honest: a gesture storm must still
-- serialise to exactly the bytes a wholesale load of the same take produces, a lost or
-- stale key being a silent, byte-level failure.

local t        = require('support')
local midiBlob = require('midiBlob')
local realMM   = require('realMidiManager')()

local function freshTake()
  local fakeReaper = require('fakeReaper').new()
  _G.reaper = fakeReaper
  local take = 'take-wire-splice'
  fakeReaper:bindTake(take, take .. '/item', take .. '/track')
  return take, fakeReaper
end

-- Every blob that reaches the take, in order: the storm's flush and the wholesale
-- instance's flush are the two the equivalence pin compares.
local function captureBlobs(rp)
  local blobs, realSetAllEvts = {}, rp.MIDI_SetAllEvts
  rp.MIDI_SetAllEvts = function(take, evts)
    blobs[#blobs + 1] = evts
    return realSetAllEvts(take, evts)
  end
  return blobs
end

-- Full regenerations for the duration of fn: mm reaches buildWire through the module
-- table, so the field is the seam a count can sit on.
local function buildsDuring(fn)
  local realBuildWire, builds = midiBlob.buildWire, 0
  midiBlob.buildWire = function(...) builds = builds + 1; return realBuildWire(...) end
  local ok, err = pcall(fn)
  midiBlob.buildWire = realBuildWire
  if not ok then error(err, 0) end
  return builds
end

local function noteOfPitch(mm, pitch)
  for _, note in mm:notes() do if note.pitch == pitch then return note end end
end

local function noteAtPpq(mm, ppq)
  for _, note in mm:notes() do if note.ppq == ppq then return note end end
end

local function ccAtPpq(mm, ppq)
  for _, cc in mm:ccs() do if cc.ppq == ppq then return cc end end
end

local function velOfPitch(rp, take, pitch)
  for _, n in ipairs(rp:dumpMidi(take).notes) do if n.pitch == pitch then return n.vel end end
end

local function rdmRows(rp, take)
  local rows = 0
  for _, e in ipairs(rp:dumpMidi(take).texts) do
    if e.eventtype == -1 and e.msg:sub(1, 4) == '}RDM' then rows = rows + 1 end
  end
  return rows
end

-- The notation rows as the take holds them, in wire order: { ppq, pitch } is enough to
-- tell a dropped row from a lingering one and a moved row from a stale one.
local function notationRows(rp, take)
  local rows = {}
  for _, e in ipairs(rp:dumpMidi(take).texts) do
    local pitch = e.eventtype == 15 and e.msg:match('^NOTE%s+%d+%s+(%d+)%s+custom')
    if pitch then rows[#rows + 1] = { ppq = e.ppq, pitch = tonumber(pitch) } end
  end
  return rows
end

return {
  {
    name = 'a property edit after the first flush splices the held wire',
    run = function()
      local take, rp = freshTake()
      rp:seedMidi(take, { notes = {
        { ppq =   0, endppq = 240, chan = 0, pitch = 60, vel = 100 },
        { ppq = 480, endppq = 720, chan = 0, pitch = 64, vel =  90 },
      } })

      local mm = realMM(nil)
      mm:load(take)   -- the notes arrive without notation rows, so load flushes and holds a wire
      local edited = noteOfPitch(mm, 64)

      local builds = buildsDuring(function()
        mm:modify(function() mm:assign(edited.uuid, { vel = 33 }) end)
      end)

      t.eq(builds, 0, 'the flush spliced rather than re-keying the whole take')
      t.eq(velOfPitch(rp, take, 64), 33, 'and the edit reached the take')
    end,
  },

  {
    -- Distinct ppqs throughout, so wire order is settled by ppq and rank alone: the two
    -- instances disagree about slot numbering (one stormed, one minted 1..n) and that
    -- must not reach the bytes. What can reach them is which keys exist and what they say.
    name = 'a gesture storm splices to the bytes a wholesale rebuild produces',
    run = function()
      local take, rp = freshTake()
      rp:seedMidi(take, {
        notes = {
          { ppq =    0, endppq =  240, chan = 0, pitch = 60, vel = 100 },
          { ppq =  480, endppq =  720, chan = 0, pitch = 62, vel =  90 },
          { ppq =  960, endppq = 1200, chan = 0, pitch = 64, vel =  80 },
          { ppq = 1440, endppq = 1680, chan = 0, pitch = 67, vel =  70 },
        },
        ccs = {
          { ppq =   0, chanmsg = 0xB0, chan = 0, msg2 =  7, msg3 = 100 },
          { ppq = 600, chanmsg = 0xB0, chan = 0, msg2 = 11, msg3 =  64 },
        },
      })
      local blobs = captureBlobs(rp)

      local live = realMM(nil)
      live:load(take)
      local reused     = noteOfPitch(live, 60)
      local transposed = noteOfPitch(live, 62)
      local shifted    = noteOfPitch(live, 64)
      local orphaned   = noteOfPitch(live, 67)
      local plainCC    = ccAtPpq(live, 600)

      local builds = buildsDuring(function()
        live:modify(function()
          live:add({ evType = 'note', ppq = 1920, endppq = 2160, chan = 1, pitch = 65, vel = 70 })
          live:assign(transposed.uuid, { pitch = 70 })               -- new body, same slot
          live:assign(shifted.uuid, { ppq = 2400, endppq = 2640 })   -- new placement, same body
          live:assign(plainCC.uuid, { foo = 'tagged' })              -- promoted: gains a row
          live:add({ evType = 'cc', ppq = 1000, chan = 1, cc = 1, val = 50, foo = 'tagged' })
          live:add({ evType = 'cc', ppq = 1200, chan = 1, cc = 2, val = 20 })   -- plain: no row
          live:add({ evType = 'cc', ppq = 1400, chan = 1, cc = 3, val = 64,
                     shape = 'bezier', tension = 0.5, foo = 'tagged' })
          live:delete(reused.uuid)     -- frees a slot, which the add below takes over...
          live:add({ evType = 'note', ppq = 2880, endppq = 3120, chan = 1, pitch = 72, vel = 60 })
          live:delete(orphaned.uuid)   -- ...unlike this one, whose row has nothing to overwrite it
        end)
        -- A second nest, so a key minted by the first has to move again off spliced state --
        -- and a bezier's CCBZ rider has to travel with its cc.
        local curved = ccAtPpq(live, 1400)
        live:modify(function() live:assign(curved.uuid, { ppq = 1600 }) end)
      end)

      t.eq(builds, 0, 'both nests spliced the wire the previous flush left')
      local stormed = blobs[#blobs]
      t.truthy(stormed, 'the storm reached the wire')

      -- A fresh instance sidesteps the converged loadedBlob gate, so it rebuilds wholesale;
      -- the no-op assign is only there to dirty the take.
      local wholesale = realMM(nil)
      wholesale:load(take)
      local pinned, mark = noteOfPitch(wholesale, 70), #blobs
      wholesale:modify(function() wholesale:assign(pinned.uuid, { vel = pinned.vel }) end)

      t.truthy(#blobs > mark, 'the wholesale instance flushed too')
      t.truthy(blobs[#blobs] == stormed, 'the spliced wire serialises to the wholesale bytes')

      -- Blob equality alone can't see a missed cc row: a row never written reloads as a
      -- legitimately plain cc, so both instances would agree on the same wrong bytes.
      t.eq(rdmRows(rp, take), 3, 'the promoted cc and both tagged adds carry a }RDM row')
      t.deepEq(notationRows(rp, take),
               { { ppq =  480, pitch = 70 }, { ppq = 1920, pitch = 65 },
                 { ppq = 2400, pitch = 64 }, { ppq = 2880, pitch = 72 } },
               'every surviving note has exactly one notation row, at its onset')
    end,
  },

  {
    name = 'a load regenerates wholesale, and so does a backstop repair',
    run = function()
      local take, rp = freshTake()
      rp:seedMidi(take, { notes = {
        { ppq =   0, endppq = 240, chan = 0, pitch = 60, vel = 100 },
        { ppq = 480, endppq = 720, chan = 0, pitch = 60, vel = 100 },
      } })

      local mm = realMM(nil)
      t.eq(buildsDuring(function() mm:load(take) end), 1,
           'load replaces notes, ccs and both sidecar groups: nothing held survives it')

      -- Distinct logical onsets make these two voices rather than duplicates, so the
      -- backstop nudges instead of killing. Either way it mutates at the unwind, after the
      -- verbs have reported their dirt, which is what the full regeneration covers.
      local moved = noteAtPpq(mm, 480)
      mm:modify(function() mm:assign(moved.uuid, { ppqL = 480 }) end)

      local builds = buildsDuring(function()
        mm:modify(function() mm:assign(moved.uuid, { ppq = 0 }) end)
      end)

      t.eq(builds, 1, 'a backstop repair falls back to a full regeneration')
      t.deepEq(notationRows(rp, take), { { ppq = 0, pitch = 60 }, { ppq = 1, pitch = 60 } },
               'and the nudged voice\'s row landed with it')
    end,
  },
}
