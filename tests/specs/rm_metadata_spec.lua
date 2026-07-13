-- rm metadata facility: non-native record fields persist behind the scenes —
-- fx/bus-meta ride pextStore's undo mirror as ds keys; track-meta rides P_EXT.
local t       = require('support')
local harness = require('harness')
local util    = require('util')

local function mkRm()
  local h = harness.mk()
  return h.reaper, util.instantiate('routingManager', { ds = h.ds }), h
end

local function seedTrack(reaper, name)
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, false)
  local track = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', name, true)
  return track, reaper.GetTrackGUID(track)
end

local function addFx(reaper, rm, tid, ident)
  reaper:setFxIO(ident, { ins = 2, outs = 2 })
  return rm:addFx(tid, { ident = ident })
end

return {
  {
    name = 'track meta rides the track P_EXT and folds back onto the record',
    run = function()
      local reaper, rm = mkRm()
      local _, tid = seedTrack(reaper, 'Src')
      rm:assignTrack(tid, { pos = { x = 10, y = 20 } })
      t.deepEq(rm:track(tid).pos, { x = 10, y = 20 }, 'pos reads back on the record')

      rm:assignTrack(tid, { split = true })
      t.deepEq(rm:track(tid).pos, { x = 10, y = 20 }, 'pos survives a later split write')
      t.eq(rm:track(tid).split, true, 'split persists alongside pos')
    end,
  },
  {
    name = 'native-only fx write mints no scratch and stores no metadata',
    run = function()
      local reaper, rm = mkRm()
      local _, tid = seedTrack(reaper, 'Bus')
      local fxId = addFx(reaper, rm, tid, 'FX:comp')
      local before = reaper.CountTracks(0)
      rm:assignFx(fxId, { params = {} })
      t.eq(reaper.CountTracks(0), before, 'no track created (no scratch minted)')
      t.eq(reaper.GetProjExtState(0, 'continuum_wiring', 'scratch'), 0, 'no scratch guid persisted')
      t.eq(rm:fx(fxId).split, nil, 'no metadata stored')
    end,
  },
  {
    name = 'fx meta lives in projext, mirrors to scratch, folds onto records',
    run = function()
      local reaper, rm = mkRm()
      local _, tid = seedTrack(reaper, 'Bus')
      local fxId = addFx(reaper, rm, tid, 'FX:comp')
      rm:assignFx(fxId, { split = true, pos = { x = 1, y = 2 } })

      t.eq(rm:fx(fxId).split, true, 'rm:fx folds fx-meta')
      t.deepEq(rm:fx(fxId).pos, { x = 1, y = 2 })
      t.eq(reaper.GetProjExtState(0, 'continuum_wiring', 'scratch'), 1, 'fx-meta write minted + persisted the scratch track')

      local chain
      for _, tr in ipairs(rm:tracks()) do if tr.id == tid then chain = tr.fx end end
      t.eq(chain[1].split, true, 'rm:tracks folds fx-meta onto chain entries')
    end,
  },
  {
    name = 'fx-meta partial merge keeps earlier fields; util.REMOVE clears one',
    run = function()
      local reaper, rm = mkRm()
      local _, tid = seedTrack(reaper, 'Bus')
      local fxId = addFx(reaper, rm, tid, 'FX:comp')
      rm:assignFx(fxId, { pos = { x = 3, y = 4 } })
      rm:assignFx(fxId, { split = true })
      t.deepEq(rm:fx(fxId).pos, { x = 3, y = 4 }, 'pos survives a later split write')
      t.eq(rm:fx(fxId).split, true)

      rm:assignFx(fxId, { split = util.REMOVE })
      t.eq(rm:fx(fxId).split, nil, 'util.REMOVE clears the field')
      t.deepEq(rm:fx(fxId).pos, { x = 3, y = 4 }, 'sibling untouched by the clear')
    end,
  },
  {
    name = 'fx-meta rides undo: a rewound scratch mirror restores it through ds',
    run = function()
      local reaper, rm, h = mkRm()
      local _, tid = seedTrack(reaper, 'Bus')
      local fxId = addFx(reaper, rm, tid, 'FX:comp')
      rm:assignFx(fxId, { split = true })

      -- REAPER undo rewinds the scratch track's chunk but not projext; the mirror
      -- lives in the chunk, so the poll copies the pre-edit value back.
      local snap = util.clone(reaper._state.trackExt)
      rm:assignFx(fxId, { split = util.REMOVE })
      t.eq(rm:fx(fxId).split, nil, 'cleared before the undo')

      reaper._state.trackExt = util.clone(snap)
      reaper._state.projStateCount = reaper._state.projStateCount + 1
      h.cm:pollUndo()   -- coordinator.frame's entry point: mirror resync + ds invalidate
      t.eq(rm:fx(fxId).split, true, 'undo restored fx-meta through the mirror')
    end,
  },
}
