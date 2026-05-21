-- See docs/arrangeManager.md for the model.
-- @noindex

--invariant: project-wide singleton; reads REAPER items + cm directly, owns no take state of its own
--invariant: slot palette lives in cm at the track tier under 'arrangeSlots'; foreign-track writes route through cm:writeTrackKey
--invariant: slot indices are 0..61, base62-keyed via util.toBase62 (62 chars: 0-9, a-z, A-Z); allocation is lowest-free; gaps allowed
--invariant: takeId derivation is the source-identity chokepoint — MIDI: POOLEDEVTS guid from item state chunk (pooled takes share it); audio: source filename. A take whose id can't be derived shows as an orphan, never crashes.
--invariant: reswing (reswingAll) is the legacy sequenceManager behaviour folded in and needs the optional tm dependency; pure-discovery callers may omit tm

local util = require 'util'

local cm, tm = (...).cm, (...).tm

local am = {}

local SLOT_MAX = 61    -- inclusive: 62 slots, base62 0..9 + a..z + A..Z

----- Helpers

-- Identity of a take's underlying source. Stable per session for both kinds.
-- MIDI: POOLEDEVTS guid from item state chunk (pooled takes share it).
-- Audio: absolute source filename.
local function takeIdOf(take)
  if not take then return nil end
  if reaper.TakeIsMIDI(take) then
    local item = reaper.GetMediaItemTake_Item(take)
    if not item then return nil end
    local ok, chunk = reaper.GetItemStateChunk(item, '', false)
    if not ok or not chunk then return nil end
    return chunk:match('POOLEDEVTS%s+({[^}]+})')
  end
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return nil end
  return reaper.GetMediaSourceFileName(src)
end

local function itemQNRange(item)
  local pos = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
  local len = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
  local startQN = reaper.TimeMap2_timeToQN(0, pos)
  local endQN   = reaper.TimeMap2_timeToQN(0, pos + len)
  return startQN, endQN - startQN
end

local function takeKind(take)
  return reaper.TakeIsMIDI(take) and 'midi' or 'audio'
end

local function readSlots(track)
  if not track then return {} end
  return cm:readTrackKey(track, 'arrangeSlots') or {}
end

local function writeSlots(track, dict)
  cm:writeTrackKey(track, 'arrangeSlots', dict)
end

local function nextFreeSlot(dict)
  for i = 0, SLOT_MAX do
    if dict[i] == nil then return i end
  end
  return nil
end

local function forEachActiveTake(track, fn)
  for ii = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, ii)
    local take = item and reaper.GetActiveTake(item)
    if take then fn(take, item, ii) end
  end
end

----------- PUBLIC

----- Discovery

function am:projectTracks()
  local out = {}
  for ti = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, ti)
    local _, name = reaper.GetTrackName(track)
    local slotCount = 0
    for _ in pairs(readSlots(track)) do slotCount = slotCount + 1 end
    out[#out+1] = {
      idx       = ti,
      track     = track,
      name      = name or '',
      slotCount = slotCount,
      takeCount = reaper.CountTrackMediaItems(track),
    }
  end
  return out
end

function am:tracksTakes(trackIdx)
  local track = reaper.GetTrack(0, trackIdx)
  if not track then return {} end
  local dict = readSlots(track)
  local idToSlot = {}
  for slotIdx, entry in pairs(dict) do idToSlot[entry.id] = slotIdx end

  local out = {}
  forEachActiveTake(track, function(take, item)
    local startQN, lengthQN = itemQNRange(item)
    local id = takeIdOf(take)
    out[#out+1] = {
      item     = item,
      take     = take,
      trackIdx = trackIdx,
      startQN  = startQN,
      lengthQN = lengthQN,
      kind     = takeKind(take),
      slotIdx  = id and idToSlot[id] or nil,
      name     = reaper.GetTakeName(take) or '',
    }
  end)
  return out
end

function am:trackSlots(trackIdx)
  local track = reaper.GetTrack(0, trackIdx)
  if not track then return {} end
  local dict = readSlots(track)

  -- Resolve names: first take whose id matches the slot's id wins.
  local nameById = {}
  forEachActiveTake(track, function(take)
    local id = takeIdOf(take)
    if id and nameById[id] == nil then
      nameById[id] = reaper.GetTakeName(take) or ''
    end
  end)

  local out = {}
  for i = 0, SLOT_MAX do
    local entry = dict[i]
    if entry then
      out[#out+1] = {
        idx  = i,
        kind = entry.kind,
        id   = entry.id,
        name = nameById[entry.id] or '',
      }
    end
  end
  return out
end

function am:slotForTake(take)
  if not take then return nil end
  local track = reaper.GetMediaItemTake_Track(take)
  local id    = takeIdOf(take)
  if not track or not id then return nil end
  for slotIdx, entry in pairs(readSlots(track)) do
    if entry.id == id then return slotIdx end
  end
  return nil
end

function am:keyForSlot(slotIdx)
  return util.toBase62(slotIdx)
end

----- Slot management

-- Phase 1 surface: dictionary writers only. Source creation
-- (PCM_Source_CreateFromType for MIDI, file picker for audio) and the
-- placement primitives (dropInstance, duplicateTake, move/resize/trim)
-- land in phase 4 alongside the base62 command scope. newMidiSlot's
-- opts.id seam lets phase-4 callers (and tests) inject the pool guid
-- of an already-created source.

function am:newMidiSlot(trackIdx, opts)
  local track = reaper.GetTrack(0, trackIdx)
  if not track then return nil end
  local dict = readSlots(track)
  local slotIdx = nextFreeSlot(dict)
  if not slotIdx then return nil end
  local id = (opts and opts.id) or reaper.genGuid('')
  dict[slotIdx] = { kind = 'midi', id = id }
  writeSlots(track, dict)
  return slotIdx
end

function am:newAudioSlot(trackIdx, path)
  if not path or path == '' then return nil end
  local track = reaper.GetTrack(0, trackIdx)
  if not track then return nil end
  local dict = readSlots(track)
  local slotIdx = nextFreeSlot(dict)
  if not slotIdx then return nil end
  dict[slotIdx] = { kind = 'audio', id = path }
  writeSlots(track, dict)
  return slotIdx
end

function am:deleteSlot(trackIdx, slotIdx, opts)
  local track = reaper.GetTrack(0, trackIdx)
  if not track then return end
  local dict = readSlots(track)
  local entry = dict[slotIdx]
  if not entry then return end
  dict[slotIdx] = nil

  if opts and opts.removeInstances then
    for ii = reaper.CountTrackMediaItems(track) - 1, 0, -1 do
      local item = reaper.GetTrackMediaItem(track, ii)
      local take = item and reaper.GetActiveTake(item)
      if take and takeIdOf(take) == entry.id then
        reaper.DeleteTrackMediaItem(track, item)
      end
    end
  end

  writeSlots(track, dict)
end

function am:renameSlot(trackIdx, slotIdx, name)
  local track = reaper.GetTrack(0, trackIdx)
  if not track then return end
  local entry = readSlots(track)[slotIdx]
  if not entry then return end
  forEachActiveTake(track, function(take)
    if takeIdOf(take) == entry.id then
      reaper.GetSetMediaItemTakeInfo_String(take, 'P_NAME', name, true)
    end
  end)
end

----- Reswing (folded from sequenceManager)

local function projectMidiTakes()
  local takes = {}
  for ti = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, ti)
    forEachActiveTake(track, function(take)
      if reaper.TakeIsMIDI(take) then takes[#takes+1] = take end
    end)
  end
  return takes
end

--contract: reads each take's persisted usedSwings table via cm:readTakeKey; no mm/cm context disturbance
function am:takesUsing(name)
  local hits = {}
  for _, take in ipairs(projectMidiTakes()) do
    local used = cm:readTakeKey(take, 'usedSwings')
    if used and used[name] then hits[#hits+1] = take end
  end
  return hits
end

--contract: iterates affected takes via tm:bindTake with opts.markSwingStale=true; the post-load rebuild's stale-branch reseats raw from each event's ppqL under the take's current swing. Restores the original take at the end (no stale-mark — the active take's events are unchanged by the visit).
function am:reswingAll(name)
  assert(tm, 'arrangeManager: reswingAll requires the tm dependency')
  local origTake = tm:currentTake()
  for _, take in ipairs(am:takesUsing(name)) do
    if take ~= origTake then tm:bindTake(take, {markSwingStale=true}) end
  end
  if tm:currentTake() ~= origTake then tm:bindTake(origTake) end
end

return am
