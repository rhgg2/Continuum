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

----------- pin maps

-- Pair P occupies channels 2(P-1)/2(P-1)+1. A port owns two pins (left/right bit
-- masks); a pair is connected when its bit is set across both pins.

-- Adjacent set bits collapse to one pair; lLo|hLo merges the port's two pins.
local function decodePairList(track, fxIdx, isoutput, port)
  local lowPin = 2 * (port - 1)
  local mask   = reaper.TrackFX_GetPinMappings(track, fxIdx, isoutput, lowPin)
               | reaper.TrackFX_GetPinMappings(track, fxIdx, isoutput, lowPin + 1)
  local pairs, lastPair = {}, nil
  for bit = 0, 31 do
    if ((mask >> bit) & 1) == 1 then
      local pair = (bit >> 1) + 1
      if pair ~= lastPair then util.add(pairs, pair); lastPair = pair end
    end
  end
  return pairs
end

-- ports = pins/2; disconnected ports (zero mask) dropped — absent ⇒ disconnected.
local function readPinMaps(track, fxIdx)
  local _, ins, outs = reaper.TrackFX_GetIOSize(track, fxIdx)
  local function dirMap(isoutput, pinCount)
    local out = {}
    for port = 1, math.floor(pinCount / 2) do
      local pairList = decodePairList(track, fxIdx, isoutput, port)
      if #pairList > 0 then out[port] = pairList end
    end
    return out
  end
  return { ins = dirMap(0, ins), outs = dirMap(1, outs) }
end

local function pinMaskFor(pairList, pinOffset)
  local lo, hi = 0, 0
  for _, pair in ipairs(pairList) do
    local bit = 2 * (pair - 1) + pinOffset
    if bit < 32 then lo = lo | (1 << bit)
    else             hi = hi | (1 << (bit - 32))
    end
  end
  return lo, hi
end

-- Full-replace per fx: ports absent from `pm` are disconnected (zero mask).
local function writePinMaps(track, fxIdx, pm)
  local _, ins, outs = reaper.TrackFX_GetIOSize(track, fxIdx)
  local function dir(isoutput, pinCount, byPort)
    byPort = byPort or {}
    for port = 1, math.floor(pinCount / 2) do
      local pairList = byPort[port] or {}
      for pinOffset = 0, 1 do
        reaper.TrackFX_SetPinMappings(track, fxIdx, isoutput,
                                      2 * (port - 1) + pinOffset, pinMaskFor(pairList, pinOffset))
      end
    end
  end
  dir(0, ins,  pm.ins)
  dir(1, outs, pm.outs)
end

----------- fx read

--shape: fx = { id=guid, ident=string, name=string, inPins=int, outPins=int, pinMaps={ins={[port]={pair,...}}, outs=...} }  -- params/midi join later

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
    pinMaps = readPinMaps(track, idx),
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

-- ident → { [name] = sliderIdx }. Param layout is a property of the plugin
-- type, not the instance, and is session-fixed — a memo, not slot state.
local paramIdxByIdent = {}

local function paramsByName(track, fxIdx)
  local _, ident = reaper.TrackFX_GetNamedConfigParm(track, fxIdx, 'fx_ident')
  local byName = paramIdxByIdent[ident]
  if not byName then
    byName = {}
    for p = 0, 511 do
      local ok, name = reaper.TrackFX_GetParamName(track, fxIdx, p)
      if not ok then break end
      byName[name] = p
    end
    paramIdxByIdent[ident] = byName
  end
  return byName
end

--contract: params keyed by display name; an unknown name raises
local function writeParams(track, fxIdx, params)
  local byName = paramsByName(track, fxIdx)
  for name, value in pairs(params) do
    local idx = byName[name]
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
  if t.params  then writeParams(track, idx, t.params)  end
  if t.pinMaps then writePinMaps(track, idx, t.pinMaps) end
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
