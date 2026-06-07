-- routingManager Phase 2: fx read. tracks() nests each track's fx chain as
-- records — id (fx guid), ident, display name, and port counts (pins/2).
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
  return track
end

local function trackByName(rm, name)
  for _, tr in ipairs(rm:tracks()) do if tr.name == name then return tr end end
end

return {
  {
    name = 'tracks() nests the fx chain: id, ident, name, port counts',
    run = function()
      local reaper, rm = mkRm()
      local track = seedTrack(reaper, 'Synth')
      reaper:setTrackFX(track, {
        { ident = 'VST3:ReaEQ',  name = 'VST3: ReaEQ (Cockos)' },
        { ident = 'JS:utility/volume', name = 'JS: Volume Adjustment' },
      })
      reaper:setFxIO('VST3:ReaEQ', { ins = 2, outs = 2 })
      reaper:setFxIO('JS:utility/volume', { ins = 4, outs = 6 })
      reaper:setFxGuid(track, 0, '{FX-eq}')
      reaper:setFxGuid(track, 1, '{FX-vol}')

      local fx = trackByName(rm, 'Synth').fx
      t.eq(#fx, 2, 'both fx read')

      t.eq(fx[1].id, '{FX-eq}', 'id is the fx guid')
      t.eq(fx[1].ident, 'VST3:ReaEQ', 'ident from fx_ident')
      t.eq(fx[1].name, 'VST3: ReaEQ (Cockos)', 'name from fx_name')
      t.eq(fx[1].ins, 1)
      t.eq(fx[1].outs, 1)

      t.eq(fx[2].id, '{FX-vol}')
      t.eq(fx[2].ident, 'JS:utility/volume')
      t.eq(fx[2].ins, 2)
      t.eq(fx[2].outs, 3)
    end,
  },
  {
    name = 'fx name prefers a user instance rename over the plugin name',
    run = function()
      local reaper, rm = mkRm()
      local track = seedTrack(reaper, 'Bus')
      reaper:setTrackFX(track, {
        { ident = 'VST3:ReaComp', name = 'VST3: ReaComp (Cockos)', renamed = 'Glue' },
      })

      t.eq(trackByName(rm, 'Bus').fx[1].name, 'Glue')
    end,
  },
  {
    name = 'a track with no fx reads an empty chain',
    run = function()
      local reaper, rm = mkRm()
      seedTrack(reaper, 'Empty')
      t.deepEq(trackByName(rm, 'Empty').fx, {})
    end,
  },
  {
    name = 'chain order is list order',
    run = function()
      local reaper, rm = mkRm()
      local track = seedTrack(reaper, 'Chain')
      reaper:setTrackFX(track, {
        { ident = 'a' }, { ident = 'b' }, { ident = 'c' },
      })

      local idents = {}
      for _, fx in ipairs(trackByName(rm, 'Chain').fx) do util.add(idents, fx.ident) end
      t.deepEq(idents, { 'a', 'b', 'c' })
    end,
  },
}
