-- routingManager Phase 1: track read/write + transaction.
-- rm is dependency-free — a thin record abstraction over the reaper global.
local t       = require('support')
local harness = require('harness')
local util    = require('util')

local function mkRm()
  local h  = harness.mk()
  local rm = util.instantiate('routingManager')
  return h.reaper, rm
end

-- Seed a pre-existing project track via the real fake API so its guid and
-- P_NAME are read back through the same accessors rm uses.
local function seedTrack(reaper, name, opts)
  opts = opts or {}
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, false)
  local track = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', name, true)
  if opts.nchan then reaper.SetMediaTrackInfo_Value(track, 'I_NCHAN', opts.nchan) end
  return track, reaper.GetTrackGUID(track)
end

local function byId(rm, id)
  for _, tr in ipairs(rm:tracks()) do if tr.id == id then return tr end end
end

return {
  {
    name = 'tracks() reads project tracks as records; master appears last with isMaster',
    run = function()
      local reaper, rm = mkRm()
      local _, idA = seedTrack(reaper, 'Drums', { nchan = 2 })
      local _, idB = seedTrack(reaper, 'Bass',  { nchan = 4 })

      local tracks = rm:tracks()
      t.eq(#tracks, 3, 'two project tracks + master')

      local a = tracks[1]
      t.eq(a.id, idA, 'id is the track guid')
      t.eq(a.name, 'Drums')
      t.eq(a.nchan, 2)
      t.falsy(a.isMaster, 'project track is not master')
      t.deepEq(a.fx, {}, 'fx empty in phase 1')
      t.deepEq(a.sends, {}, 'sends empty in phase 1')
      t.deepEq(a.mainSend, { on = true, gain = 1.0, tgtOffset = 0, nchan = 0 })

      t.eq(tracks[2].id, idB)
      t.eq(tracks[3].isMaster, true, 'master last, flagged')
    end,
  },
  {
    name = 'addTrack appends, applies fields, returns a resolvable id',
    run = function()
      local reaper, rm = mkRm()
      seedTrack(reaper, 'Existing')

      local id = rm:addTrack({ name = 'Reverb Bus', nchan = 4,
                               mainSend = { on = false, gain = 0.5 } })
      local rec = byId(rm, id)
      t.truthy(rec, 'new track resolvable by returned id')
      t.eq(rec.name, 'Reverb Bus')
      t.eq(rec.nchan, 4)
      t.eq(rec.mainSend.on, false)
      t.eq(rec.mainSend.gain, 0.5)
    end,
  },
  {
    name = 'assignTrack dispatches on present fields: name, nchan, mainSend',
    run = function()
      local reaper, rm = mkRm()
      local _, id = seedTrack(reaper, 'Old', { nchan = 2 })

      rm:assignTrack(id, { name = 'New', nchan = 6,
                           mainSend = { on = false, gain = 0.25 } })
      local rec = byId(rm, id)
      t.eq(rec.name, 'New')
      t.eq(rec.nchan, 6)
      t.eq(rec.mainSend.on, false)
      t.eq(rec.mainSend.gain, 0.25)
    end,
  },
  {
    name = 'deleteTrack removes the addressed track',
    run = function()
      local reaper, rm = mkRm()
      seedTrack(reaper, 'Keep')
      local _, doomed = seedTrack(reaper, 'Doomed')

      local before = #rm:tracks()
      rm:deleteTrack(doomed)
      t.eq(#rm:tracks(), before - 1, 'one fewer track')
      t.falsy(byId(rm, doomed), 'doomed id no longer resolves')
    end,
  },
  {
    name = 'transaction wraps fn in Undo block + UI-refresh guard, in order',
    run = function()
      local reaper, rm = mkRm()
      local order = {}
      local begin, prevent, finish =
        reaper.Undo_BeginBlock, reaper.PreventUIRefresh, reaper.Undo_EndBlock2
      reaper.Undo_BeginBlock  = function()  order[#order+1] = 'begin';   return begin() end
      reaper.PreventUIRefresh = function(n) order[#order+1] = 'prevent' .. n; return prevent(n) end
      reaper.Undo_EndBlock2   = function(...) order[#order+1] = 'end';   return finish(...) end

      rm:transaction('label', function() order[#order+1] = 'fn' end)
      t.deepEq(order, { 'begin', 'prevent1', 'fn', 'prevent-1', 'end' })
    end,
  },
}
