-- See docs/routingManager.md for the model. A thin record abstraction over
-- REAPER's audio/MIDI graph.
--invariant: id is a track/fx GUID string — opaque to callers, stable across reload
--invariant: stateless — ids are guid-backed, so nothing is minted or reset

local util = require('util')

local PROJ = 0

local rm = {}

----------- track resolution

-- Stable under reordering. Master matched first since it is absent
-- from the project-track list.
local function locateTrack(id)
  local master = reaper.GetMasterTrack(PROJ)
  if master and reaper.GetTrackGUID(master) == id then return master end
  for i = 0, reaper.CountTracks(PROJ) - 1 do
    local track = reaper.GetTrack(PROJ, i)
    if reaper.GetTrackGUID(track) == id then return track end
  end
end

----------- fx resolution

local function locateFx(id)
  local function indexIn(track)
    for idx = 0, reaper.TrackFX_GetCount(track) - 1 do
      if reaper.TrackFX_GetFXGUID(track, idx) == id then return idx end
    end
  end
  local master = reaper.GetMasterTrack(PROJ)
  if master then local idx = indexIn(master); if idx then return master, idx end end
  for i = 0, reaper.CountTracks(PROJ) - 1 do
    local track = reaper.GetTrack(PROJ, i)
    local idx = indexIn(track)
    if idx then return track, idx end
  end
end

----------- fx read

--shape: fx = { id=guid, ident=string, name=string, inPins=int, outPins=int }  -- pins are mono channels; params/pinMaps/midi join later

-- Display name: a user instance rename wins, else the plugin's own name.
local function fxName(track, idx)
  local renamed, value = reaper.TrackFX_GetNamedConfigParm(track, idx, 'renamed_name')
  if renamed and value ~= '' then return value end
  local _, name = reaper.TrackFX_GetNamedConfigParm(track, idx, 'fx_name')
  return name
end

local function readFx(track, idx)
  local _, ident = reaper.TrackFX_GetNamedConfigParm(track, idx, 'fx_ident')
  local _, inPins, outPins = reaper.TrackFX_GetIOSize(track, idx)
  return {
    id      = reaper.TrackFX_GetFXGUID(track, idx),
    ident   = ident,
    name    = fxName(track, idx),
    inPins  = inPins,
    outPins = outPins,
  }
end

local function readFxChain(track)
  local out = {}
  for idx = 0, reaper.TrackFX_GetCount(track) - 1 do
    util.add(out, readFx(track, idx))
  end
  return out
end

----------- read

local function trackName(track)
  local _, name = reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', '', false)
  return name
end

local function readMainSend(track)
  local val = function(parm) return reaper.GetMediaTrackInfo_Value(track, parm) end
  return {
    on        = val('B_MAINSEND') ~= 0,
    gain      = val('D_VOL'),
    tgtOffset = val('C_MAINSEND_OFFS'),
    nchan     = val('C_MAINSEND_NCH'),
  }
end

local function readTrack(track, isMaster)
  return {
    id       = reaper.GetTrackGUID(track),
    name     = trackName(track),
    isMaster = isMaster or nil,
    nchan    = reaper.GetMediaTrackInfo_Value(track, 'I_NCHAN'),
    mainSend = readMainSend(track),
    fx       = readFxChain(track),
    sends    = {},
  }
end

----------- write

local function writeMainSend(track, ms)
  local set = function(parm, value)
    if value ~= nil then reaper.SetMediaTrackInfo_Value(track, parm, value) end
  end
  if ms.on ~= nil then set('B_MAINSEND', ms.on and 1 or 0) end
  set('D_VOL',            ms.gain)
  set('C_MAINSEND_OFFS',  ms.tgtOffset)
  set('C_MAINSEND_NCH',   ms.nchan)
end

--contract: params keyed by display name; an unknown name raises
local function writeParams(track, fxIdx, params)
  local idxByName = {}
  for p = 0, 511 do
    local ok, name = reaper.TrackFX_GetParamName(track, fxIdx, p)
    if not ok then break end
    idxByName[name] = p
  end
  for name, value in pairs(params) do
    local idx = idxByName[name]
    if not idx then error(("routingManager: fx has no param named %q"):format(name)) end
    reaper.TrackFX_SetParam(track, fxIdx, idx, value)
  end
end

local function writeTrackFields(track, t)
  if t.name  then reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', t.name, true) end
  if t.nchan then reaper.SetMediaTrackInfo_Value(track, 'I_NCHAN', t.nchan) end
  if t.mainSend then writeMainSend(track, t.mainSend) end
end

----------------- PUBLIC

function rm:tracks()
  local out = {}
  for i = 0, reaper.CountTracks(PROJ) - 1 do
    util.add(out, readTrack(reaper.GetTrack(PROJ, i), false))
  end
  local master = reaper.GetMasterTrack(PROJ)
  if master then util.add(out, readTrack(master, true)) end
  return out
end

function rm:addTrack(t)
  t = t or {}
  local idx = reaper.CountTracks(PROJ)
  reaper.InsertTrackAtIndex(idx, false)
  local track = reaper.GetTrack(PROJ, idx)
  writeTrackFields(track, t)
  return reaper.GetTrackGUID(track)
end

function rm:assignTrack(id, t)
  local track = locateTrack(id)
  if track then writeTrackFields(track, t) end
end

function rm:deleteTrack(id)
  local track = locateTrack(id)
  if track then reaper.DeleteTrack(track) end
end

function rm:addFx(trackId, t)
  local track = locateTrack(trackId)
  if not track then return end
  local idx = reaper.TrackFX_AddByName(track, t.ident, false, -1)
  local id  = reaper.TrackFX_GetFXGUID(track, idx)
  if t.index and t.index ~= idx then
    reaper.TrackFX_CopyToTrack(track, idx, track, t.index, true)
    idx = t.index
  end
  if t.params then writeParams(track, idx, t.params) end
  return id
end

function rm:assignFx(id, t)
  local track, idx = locateFx(id)
  if not track then return end
  if t.track then
    local dst = locateTrack(t.track)
    if dst then
      reaper.TrackFX_CopyToTrack(track, idx, dst, t.index or reaper.TrackFX_GetCount(dst), true)
      track, idx = locateFx(id)
    end
  elseif t.index and t.index ~= idx then
    reaper.TrackFX_CopyToTrack(track, idx, track, t.index, true)
    idx = t.index
  end
  if t.params then writeParams(track, idx, t.params) end
end

function rm:deleteFx(id)
  local track, idx = locateFx(id)
  if track then reaper.TrackFX_Delete(track, idx) end
end

function rm:transaction(label, fn)
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  fn()
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock2(PROJ, label or '', -1)
end

return rm
