-- routingManager scratch primitives: fxPorts (port-grouped IO + L/R-collapsed
-- names), addTrack{hidden}, and addFx's unknown-ident guard. These back wm's
-- scratch path (instantiate-to-probe, hidden scratch track).
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

return {
  {
    name = 'fxPorts reports ports (pins/2) and collapses L/R pin names to one port name',
    run = function()
      local reaper, rm = mkRm()
      reaper:setFxIO('FX:comp', {
        ins  = 4, outs = 2,
        inPinNames  = { 'Main L', 'Main R', 'Sidechain L', 'Sidechain R' },
        outPinNames = { 'Out L', 'Out R' },
      })
      local _, tid = seedTrack(reaper, 'Bus')
      local id = rm:addFx(tid, { ident = 'FX:comp' })

      local p = rm:fxPorts(id)
      t.eq(p.ins, 2, 'two input ports from four pins')
      t.eq(p.outs, 1, 'one output port from two pins')
      t.deepEq(p.inNames,  { 'Main', 'Sidechain' }, 'L/R pairs collapse to the shared prefix')
      t.deepEq(p.outNames, { 'Out' })
    end,
  },
  {
    name = 'fxPorts on a gone id returns an empty shape',
    run = function()
      local _, rm = mkRm()
      local p = rm:fxPorts('{NOPE}')
      t.eq(p.ins, 0); t.eq(p.outs, 0)
      t.deepEq(p.inNames, {}); t.deepEq(p.outNames, {})
    end,
  },
  {
    name = 'addFx returns nil for an unknown ident instead of forging a slot',
    run = function()
      local reaper, rm = mkRm()
      reaper:setMissingFx('JS:does-not-exist')
      local _, tid = seedTrack(reaper, 'Bus')

      t.falsy(rm:addFx(tid, { ident = 'JS:does-not-exist' }), 'unknown ident → nil')
      t.deepEq(rm:tracks()[1].fx, {}, 'no fx added')
    end,
  },
  {
    name = 'addTrack{defaults} inserts with REAPER track defaults; plain addTrack stays bare',
    run = function()
      local reaper, rm = mkRm()
      local bare = rm:addTrack({ name = 'scratch' })
      local rich = rm:addTrack({ name = 'source', defaults = true })
      t.eq(reaper:wantDefaultsOf(bare), false, 'plain addTrack is wantDefaults=false')
      t.eq(reaper:wantDefaultsOf(rich), true,  'defaults=true threads wantDefaults through')
    end,
  },
  {
    name = 'addTrack{hidden} hides the track from mixer and TCP',
    run = function()
      local reaper, rm = mkRm()
      local id = rm:addTrack({ name = 'scratch', hidden = true })

      local track
      for i = 0, reaper.CountTracks(0) - 1 do
        if reaper.GetTrackGUID(reaper.GetTrack(0, i)) == id then track = reaper.GetTrack(0, i) end
      end
      t.eq(reaper.GetMediaTrackInfo_Value(track, 'B_SHOWINMIXER'), 0)
      t.eq(reaper.GetMediaTrackInfo_Value(track, 'B_SHOWINTCP'),   0)
    end,
  },
}
