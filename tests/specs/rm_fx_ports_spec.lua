-- routingManager scratch + live-poke primitives: rm:fx, setSendGain, addTrack{hidden,defaults},
-- addFx ident guard. Backs wm's scratch path and live gain poke.
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

local function sendGain(rm, id, to)
  for _, s in ipairs(rm:track(id).sends) do if s.to == to then return s.gain end end
end

return {
  {
    name = 'fx() reports ports (pins/2), collapses L/R pin names, carries host trackId',
    run = function()
      local reaper, rm = mkRm()
      reaper:setFxIO('FX:comp', {
        ins  = 4, outs = 2,
        inPinNames  = { 'Main L', 'Main R', 'Sidechain L', 'Sidechain R' },
        outPinNames = { 'Out L', 'Out R' },
      })
      local _, tid = seedTrack(reaper, 'Bus')
      local id = rm:addFx(tid, { ident = 'FX:comp' })

      local fx = rm:fx(id)
      t.eq(fx.id, id, 'record carries the fx guid')
      t.eq(fx.ins, 2, 'two input ports from four pins')
      t.eq(fx.outs, 1, 'one output port from two pins')
      t.deepEq(fx.inNames,  { 'Main', 'Sidechain' }, 'L/R pairs collapse to the shared prefix')
      t.deepEq(fx.outNames, { 'Out' })
      t.eq(fx.trackId, tid, 'host trackId is the owning track')
      t.eq(fx.params, nil, 'structural record carries no param values')
    end,
  },
  {
    name = 'params() reads live param values keyed by display name; unset reads 0',
    run = function()
      local reaper, rm = mkRm()
      reaper:setFxIO('FX:cu', { ins = 2, outs = 2 })
      reaper:setFxParamNames('FX:cu', { 'mode', 'gain1' })
      local _, tid = seedTrack(reaper, 'Bus')
      local id = rm:addFx(tid, { ident = 'FX:cu' })

      rm:assignFx(id, { params = { gain1 = 0.25 } })
      local params = rm:params(id)
      t.eq(params.gain1, 0.25, 'written param reads back')
      t.eq(params.mode, 0, 'unset param reads 0')
    end,
  },
  {
    name = 'fx() on a gone id returns nil',
    run = function()
      local _, rm = mkRm()
      t.eq(rm:fx('{NOPE}'), nil)
      t.eq(rm:params('{NOPE}'), nil, 'params on a gone id is nil too')
    end,
  },
  {
    name = 'setSendGain sets the audio send D_VOL; false when no such send is live',
    run = function()
      local reaper, rm = mkRm()
      local a, idA = seedTrack(reaper, 'Src')
      local b, idB = seedTrack(reaper, 'Dst')
      local _, idC = seedTrack(reaper, 'Unsent')
      reaper:addSend(a, b, { type = 'audio', gain = 1.0 })

      t.eq(rm:setSendGain(idA, idB, 0.3), true, 'found and set')
      t.eq(sendGain(rm, idA, idB), 0.3, 'D_VOL updated')
      t.eq(rm:setSendGain(idA, idC, 0.3), false, 'no send to idC → false')
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
  {
    name = 'reaperTrack returns the live MediaTrack handle for an id; nil once gone',
    run = function()
      local reaper, rm = mkRm()
      local id = rm:addTrack({ name = 'src' })
      t.eq(rm:reaperTrack(id), reaper.GetTrack(0, 0), 'handle matches the project track for the id')
      rm:deleteTrack(id)
      t.eq(rm:reaperTrack(id), nil, 'gone id resolves to nil')
    end,
  },
}
