-- routingManager Phase 6: track.sends read + assignTrack{sends} full-replace
-- reconcile. Sends are a track attribute (no id); `to` is a dest-track guid.
local t       = require('support')
local harness = require('harness')
local util    = require('util')

local function mkRm()
  local h  = harness.mk()
  local rm = util.instantiate('routingManager')
  return h.reaper, rm
end

local function seedTrack(reaper, name)
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, false)
  local track = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', name, true)
  return track, reaper.GetTrackGUID(track)
end

local function trackById(rm, id)
  for _, tr in ipairs(rm:tracks()) do if tr.id == id then return tr end end
end

local function sendTo(rec, toId)
  for _, s in ipairs(rec.sends) do if s.to == toId then return s end end
end

return {
  {
    name = 'tracks() reads audio + midi sends as records keyed by dest guid',
    run = function()
      local reaper, rm = mkRm()
      local a, idA = seedTrack(reaper, 'Src')
      local b, idB = seedTrack(reaper, 'AudioBus')
      local c, idC = seedTrack(reaper, 'MidiBus')
      reaper:addSend(a, b, { type = 'audio', gain = 0.5 })
      reaper:addSend(a, c, { type = 'midi' })

      local rec = trackById(rm, idA)
      t.eq(#rec.sends, 2, 'both sends read')

      local audio = sendTo(rec, idB)
      t.deepEq(audio, { to = idB, kind = 'audio', gain = 0.5,
                        srcChan = 0, dstChan = 0, pos = 'postFader' })

      local midi = sendTo(rec, idC)
      t.eq(midi.kind, 'midi')
      t.eq(midi.srcChan, 0)
      t.eq(midi.dstChan, 0)
    end,
  },
  {
    name = 'tracks() sends empty when a track has none',
    run = function()
      local reaper, rm = mkRm()
      local _, idA = seedTrack(reaper, 'Lonely')
      t.deepEq(trackById(rm, idA).sends, {})
    end,
  },
  {
    name = 'audio send channels decode from I_SRCCHAN / I_DSTCHAN',
    run = function()
      local reaper, rm = mkRm()
      local a, idA = seedTrack(reaper, 'Src')
      local b, idB = seedTrack(reaper, 'Dst')
      reaper:addSend(a, b, { type = 'audio', srcChan = 2, dstChan = 4 })
      local s = sendTo(trackById(rm, idA), idB)
      t.eq(s.srcChan, 2)
      t.eq(s.dstChan, 4)
    end,
  },
  {
    name = 'assignTrack{sends} creates a send from a record',
    run = function()
      local reaper, rm = mkRm()
      local _, idA = seedTrack(reaper, 'Src')
      local _, idB = seedTrack(reaper, 'Dst')

      rm:assignTrack(idA, { sends = { { to = idB, kind = 'audio', gain = 0.5,
                                        srcChan = 0, dstChan = 0, pos = 'preFader' } } })
      local s = sendTo(trackById(rm, idA), idB)
      t.truthy(s, 'send created')
      t.eq(s.kind, 'audio')
      t.eq(s.gain, 0.5)
      t.eq(s.pos, 'preFader')
    end,
  },
  {
    name = 'assignTrack{sends} is full-replace: drops unlisted, adds new, keeps listed',
    run = function()
      local reaper, rm = mkRm()
      local a, idA = seedTrack(reaper, 'Src')
      local b, idB = seedTrack(reaper, 'OldDst')
      local _, idC = seedTrack(reaper, 'NewDst')
      reaper:addSend(a, b, { type = 'audio' })  -- A→B exists

      rm:assignTrack(idA, { sends = { { to = idC, kind = 'audio' } } })
      local rec = trackById(rm, idA)
      t.eq(#rec.sends, 1, 'one send after replace')
      t.falsy(sendTo(rec, idB), 'old send dropped')
      t.truthy(sendTo(rec, idC), 'new send added')
    end,
  },
  {
    name = 'assignTrack{sends} re-syncs gain on a matching send identity',
    run = function()
      local reaper, rm = mkRm()
      local a, idA = seedTrack(reaper, 'Src')
      local b, idB = seedTrack(reaper, 'Dst')
      reaper:addSend(a, b, { type = 'audio', srcChan = 2, gain = 1.0 })  -- pos postFader

      rm:assignTrack(idA, { sends = { { to = idB, kind = 'audio', srcChan = 2,
                                        dstChan = 0, pos = 'postFader', gain = 0.25 } } })
      local rec = trackById(rm, idA)
      t.eq(#rec.sends, 1, 'no spurious recreate')
      t.eq(sendTo(rec, idB).gain, 0.25)
    end,
  },
  {
    name = 'midi send round-trips channels and pos through reconcile',
    run = function()
      local reaper, rm = mkRm()
      local _, idA = seedTrack(reaper, 'Src')
      local _, idB = seedTrack(reaper, 'Dst')

      rm:assignTrack(idA, { sends = { { to = idB, kind = 'midi', srcChan = 3,
                                        dstChan = 5, pos = 'preFader' } } })
      local s = sendTo(trackById(rm, idA), idB)
      t.eq(s.kind, 'midi')
      t.eq(s.srcChan, 3)
      t.eq(s.dstChan, 5)
      t.eq(s.pos, 'preFader')
    end,
  },
  {
    name = 'pos round-trips preFx / preFader / postFader',
    run = function()
      local reaper, rm = mkRm()
      local _, idA = seedTrack(reaper, 'Src')
      local _, idX = seedTrack(reaper, 'X')
      local _, idY = seedTrack(reaper, 'Y')
      local _, idZ = seedTrack(reaper, 'Z')

      rm:assignTrack(idA, { sends = {
        { to = idX, kind = 'audio', pos = 'preFx' },
        { to = idY, kind = 'audio', pos = 'preFader' },
        { to = idZ, kind = 'audio', pos = 'postFader' },
      } })
      local rec = trackById(rm, idA)
      t.eq(sendTo(rec, idX).pos, 'preFx')
      t.eq(sendTo(rec, idY).pos, 'preFader')
      t.eq(sendTo(rec, idZ).pos, 'postFader')
    end,
  },
  {
    name = 'assignTrack without sends leaves existing sends untouched',
    run = function()
      local reaper, rm = mkRm()
      local a, idA = seedTrack(reaper, 'Src')
      local b, idB = seedTrack(reaper, 'Dst')
      reaper:addSend(a, b, { type = 'audio' })

      rm:assignTrack(idA, { name = 'Renamed' })
      local rec = trackById(rm, idA)
      t.eq(rec.name, 'Renamed')
      t.eq(#rec.sends, 1, 'sends preserved when not in the assign')
    end,
  },
}
