-- Phase 2d of stable-slots: the sidecar rows stop being regenerated per flush and
-- become mm state the verbs maintain. The pin is equivalence -- a storm of gestures on
-- a live instance must serialise to exactly the bytes a fresh wholesale load of the
-- same take produces. A missed drop leaves a dead row behind (on a reused slot, one
-- wearing the wrong body); a missed put loses one. Either diverges.

local t = require('support')
local realMM = require('realMidiManager')()

local function freshTake()
  local fakeReaper = require('fakeReaper').new()
  _G.reaper = fakeReaper
  local take = 'take-sidecar-state'
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

local function noteOfPitch(mm, pitch)
  for _, note in mm:notes() do if note.pitch == pitch then return note end end
end

local function noteAtPpq(mm, ppq)
  for _, note in mm:notes() do if note.ppq == ppq then return note end end
end

local function ccAtPpq(mm, ppq)
  for _, cc in mm:ccs() do if cc.ppq == ppq then return cc end end
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
    -- Distinct ppqs throughout, so wire order is settled by ppq and rank alone: the two
    -- instances disagree about slot numbering (one stormed, one minted 1..n) and that
    -- must not reach the bytes. What can reach them is which rows exist and what they say.
    name = 'a gesture storm serialises exactly like a wholesale rebuild of the same take',
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

      live:modify(function()
        live:add({ evType = 'note', ppq = 1920, endppq = 2160, chan = 1, pitch = 65, vel = 70 })
        live:assign(transposed.uuid, { pitch = 70 })               -- new body, same slot
        live:assign(shifted.uuid, { ppq = 2400, endppq = 2640 })   -- new placement, same body
        live:assign(plainCC.uuid, { foo = 'tagged' })              -- promoted: gains a row
        live:add({ evType = 'cc', ppq = 1000, chan = 1, cc = 1, val = 50, foo = 'tagged' })
        live:add({ evType = 'cc', ppq = 1200, chan = 1, cc = 2, val = 20 })   -- plain: no row
        live:delete(reused.uuid)     -- frees a slot, which the add below takes over...
        live:add({ evType = 'note', ppq = 2880, endppq = 3120, chan = 1, pitch = 72, vel = 60 })
        live:delete(orphaned.uuid)   -- ...unlike this one, whose row has nothing to overwrite it
      end)

      local stormed = blobs[#blobs]
      t.truthy(stormed, 'the storm reached the wire')

      -- A fresh instance sidesteps the converged loadedBlob gate, so it rebuilds the
      -- sidecar state wholesale; the no-op assign is only there to dirty the take.
      local wholesale = realMM(nil)
      wholesale:load(take)
      local pinned, mark = noteOfPitch(wholesale, 70), #blobs
      wholesale:modify(function() wholesale:assign(pinned.uuid, { vel = pinned.vel }) end)

      t.truthy(#blobs > mark, 'the wholesale instance flushed too')
      t.truthy(blobs[#blobs] == stormed,
               'maintained sidecar rows serialise to the wholesale bytes')
    end,
  },

  {
    name = 'a deleted note takes its notation row with it; the survivor keeps its own',
    run = function()
      local take, rp = freshTake()
      rp:seedMidi(take, { notes = {
        { ppq =   0, endppq = 240, chan = 0, pitch = 60, vel = 100 },
        { ppq = 480, endppq = 720, chan = 0, pitch = 64, vel = 100 },
      } })

      local mm = realMM(nil)
      mm:load(take)
      t.deepEq(notationRows(rp, take), { { ppq = 0, pitch = 60 }, { ppq = 480, pitch = 64 } },
               'both notes start with a notation row')

      local doomed = noteOfPitch(mm, 60)
      mm:modify(function() mm:delete(doomed.uuid) end)

      t.deepEq(notationRows(rp, take), { { ppq = 480, pitch = 64 } },
               'the deleted note leaves no row behind')
    end,
  },

  {
    -- The same-pitch backstop resolves at the outermost unwind, after the verbs have
    -- already had their say -- so it maintains the rows itself or the flush writes stale ones.
    name = 'a backstop kill takes the loser\'s notation row with it',
    run = function()
      local take, rp = freshTake()
      rp:seedMidi(take, { notes = {
        { ppq =   0, endppq = 960, chan = 0, pitch = 60, vel = 100 },
        { ppq = 480, endppq = 720, chan = 0, pitch = 60, vel = 100 },
      } })

      local mm = realMM(nil)
      mm:load(take)
      local doomed = noteAtPpq(mm, 480)
      mm:modify(function() mm:assign(doomed.uuid, { ppq = 0 }) end)   -- true duplicate: one dies

      local survivors = {}
      for _, note in mm:notes() do survivors[#survivors + 1] = note.ppq end
      t.deepEq(survivors, { 0 }, 'the true duplicates collapsed to one note')
      t.deepEq(notationRows(rp, take), { { ppq = 0, pitch = 60 } },
               'and the loser took its row with it')
    end,
  },

  {
    name = 'a backstop nudge carries the notation row to the new onset',
    run = function()
      local take, rp = freshTake()
      rp:seedMidi(take, { notes = {
        { ppq =   0, endppq = 240, chan = 0, pitch = 60, vel = 100 },
        { ppq = 480, endppq = 720, chan = 0, pitch = 60, vel = 100 },
      } })

      local mm = realMM(nil)
      mm:load(take)
      local moved = noteAtPpq(mm, 480)
      -- Distinct logical onsets make these two voices rather than duplicates, so the
      -- backstop separates them instead of killing one.
      mm:modify(function() mm:assign(moved.uuid, { ppqL = 480 }) end)
      mm:modify(function() mm:assign(moved.uuid, { ppq = 0 }) end)

      t.deepEq(notationRows(rp, take), { { ppq = 0, pitch = 60 }, { ppq = 1, pitch = 60 } },
               'the nudged voice\'s row followed it to ppq 1')
    end,
  },

  {
    -- Blob equality can't see this one: a cc with no row reloads as a legitimately plain
    -- cc, so a missed seat reproduces itself. Hence the direct count.
    name = 'a metadata-bearing cc gets its }RDM row on the spot, promoted or added',
    run = function()
      local take, rp = freshTake()
      rp:seedMidi(take, {
        ccs = { { ppq = 100, chanmsg = 0xB0, chan = 0, msg2 = 7, msg3 = 30 } },
      })

      local mm = realMM(nil)
      mm:load(take)
      local cc = ccAtPpq(mm, 100)
      t.eq(cc.plain, true, 'a cc with no metadata is plain -- no row in the take')

      mm:modify(function() mm:assign(cc.uuid, { foo = 'tagged' }) end)
      t.eq(rdmRows(rp, take), 1, 'the promotion seats a row without a reload')

      mm:modify(function()
        mm:add({ evType = 'cc', ppq = 300, chan = 1, cc = 9, val = 40, foo = 'tagged' })
        mm:add({ evType = 'cc', ppq = 500, chan = 1, cc = 9, val = 20 })   -- plain: still no row
      end)
      t.eq(rdmRows(rp, take), 2, 'an added metadata cc gets one too, and the plain one does not')
    end,
  },
}
