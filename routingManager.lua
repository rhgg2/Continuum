-- See docs/routingManager.md for the model. A thin record abstraction over
-- REAPER's audio/MIDI graph.
--invariant: id is a track/fx GUID string — opaque to callers, stable across reload
--invariant: stateless — ids are guid-backed, so nothing is minted or reset

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
    fx       = {},
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

local function writeTrackFields(track, t)
  if t.name  then reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', t.name, true) end
  if t.nchan then reaper.SetMediaTrackInfo_Value(track, 'I_NCHAN', t.nchan) end
  if t.mainSend then writeMainSend(track, t.mainSend) end
end

----------------- PUBLIC

function rm:tracks()
  local out = {}
  for i = 0, reaper.CountTracks(PROJ) - 1 do
    out[#out+1] = readTrack(reaper.GetTrack(PROJ, i), false)
  end
  local master = reaper.GetMasterTrack(PROJ)
  if master then out[#out+1] = readTrack(master, true) end
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

function rm:transaction(label, fn)
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  fn()
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock2(PROJ, label or '', -1)
end

return rm
