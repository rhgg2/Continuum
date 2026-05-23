-- See docs/arrangeManager.md for the model.
-- @noindex

--invariant: project-wide singleton; reads REAPER items + cm directly, owns no take state of its own
--invariant: slot palette lives in cm at the track tier under 'arrangeSlots'; foreign-track writes route through cm:writeTrackKey
--invariant: slot indices are 0..61, base62-keyed via util.toBase62 (62 chars: 0-9, a-z, A-Z); allocation is lowest-free; gaps allowed
--invariant: every grouped take is a slot — `trackSlots`, `tracksTakes`, `slotForTake` and `projectTracks` route through ensureSlots, which allocates indices for live ids not yet in the dict and prunes dict entries whose id has no live take. A slot has no existence apart from at least one take on the grid carrying its id.
--invariant: createAndDropMidi is the only path that mints a slot; everything else either inherits one from existing items (auto-materialisation) or drops another instance into one that already exists
--invariant: takeId derivation is the source-identity chokepoint — MIDI: POOLEDEVTS guid from item state chunk (pooled takes share it); audio: source filename. Takes whose id can't be derived are skipped during ensureSlots — they neither materialise a slot nor pin one.
--invariant: reswing (reswingAll) is the legacy sequenceManager behaviour folded in and needs the optional tm dependency; pure-discovery callers may omit tm
--invariant: per-take natural length (cm key 'arrangeNaturalLenQN'). Default nil → util.OPEN. The item's D_LENGTH on each track is derived: min(effective natural, gap to next take, source length). relayoutTrack enforces this after every mutation. A stored natural >= source length is demoted to util.OPEN (= nil) so future source growth widens the cap automatically.

local util = require 'util'

local cm, tm = (...).cm, (...).tm

local am = {}

local SLOT_MAX = 61    -- inclusive: 62 slots, base62 0..9 + a..z + A..Z

----- Helpers

local function takeIdOf(take)
  if reaper.TakeIsMIDI(take) then
    local item = reaper.GetMediaItemTake_Item(take)
    if not item then return end
    local ok, chunk = reaper.GetItemStateChunk(item, '', false)
    if not ok or not chunk then return end
    return chunk:match('POOLEDEVTS%s+({[^}]+})')
  end
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return end
  return reaper.GetMediaSourceFileName(src)
end

local function itemQNRange(item)
  local pos = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
  local len = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
  local startQN = reaper.TimeMap2_timeToQN(0, pos)
  local endQN   = reaper.TimeMap2_timeToQN(0, pos + len)
  return startQN, endQN - startQN
end

local function setItemQNRange(item, startQN, endQN)
  local startSec = reaper.TimeMap2_QNToTime(0, startQN)
  local endSec   = reaper.TimeMap2_QNToTime(0, endQN)
  reaper.SetMediaItemInfo_Value(item, 'D_POSITION', startSec)
  reaper.SetMediaItemInfo_Value(item, 'D_LENGTH',   endSec - startSec)
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
end

local function forEachActiveTake(track, fn)
  for ii = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, ii)
    local take = item and reaper.GetActiveTake(item)
    if take then fn(take, item, ii) end
  end
end

----- Natural length

local function sourceLenQN(take, item)
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return math.huge end
  local len, isQN = reaper.GetMediaSourceLength(src)
  if isQN then return len end
  local posSec = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
  return reaper.TimeMap2_timeToQN(0, posSec + len) - reaper.TimeMap2_timeToQN(0, posSec)
end

local function naturalLenOf(take)
  local stored = cm:readTakeKey(take, 'arrangeNaturalLenQN')
  return stored or util.OPEN
end

local function setNaturalLenOf(take, v)
  if v == util.OPEN then cm:writeTakeKey(take, 'arrangeNaturalLenQN', util.REMOVE)
  else                   cm:writeTakeKey(take, 'arrangeNaturalLenQN', v) end
end

--contract: walks track in startQN order; demotes natural ≥ source to OPEN; sets each item's D_LENGTH = min(effective, gap-to-next, source). Cheap to over-call: idempotent.
local function relayoutTrack(track)
  if not track then return end
  local rows = {}
  forEachActiveTake(track, function(take, item)
    local startQN = itemQNRange(item)
    rows[#rows+1] = { take = take, item = item, startQN = startQN }
  end)
  table.sort(rows, function(a, b) return a.startQN < b.startQN end)

  for i, r in ipairs(rows) do
    local src     = sourceLenQN(r.take, r.item)
    local natural = naturalLenOf(r.take)
    if natural ~= util.OPEN and natural >= src then
      setNaturalLenOf(r.take, util.OPEN)
      natural = util.OPEN
    end
    local effective = natural == util.OPEN and src or math.min(natural, src)
    local nextStart = rows[i+1] and rows[i+1].startQN or math.huge
    local rendered  = math.min(effective, nextStart - r.startQN)
    if rendered < 0 then rendered = 0 end
    setItemQNRange(r.item, r.startQN, r.startQN + rendered)
  end
end

-- The effective natural length (post-OPEN-resolution) exposed via tracksTakes.
local function effectiveNaturalLenQN(take, item)
  local natural = naturalLenOf(take)
  local src     = sourceLenQN(take, item)
  if natural == util.OPEN then return src end
  return math.min(natural, src)
end

--contract: idempotent within a frame; returns (dict, slotForId, firstName) so callers don't re-walk
local function ensureSlots(track)
  local dict = readSlots(track)
  local idOrder, liveIds, firstName, kindForId = {}, {}, {}, {}
  forEachActiveTake(track, function(take)
    local id = takeIdOf(take)
    if not id or liveIds[id] then return end
    liveIds[id]      = true
    firstName[id]    = reaper.GetTakeName(take) or ''
    kindForId[id]    = takeKind(take)
    idOrder[#idOrder+1] = id
  end)

  local slotForId, dirty = {}, false
  for slotIdx, entry in pairs(dict) do
    if entry.id and liveIds[entry.id] then
      slotForId[entry.id] = slotIdx
    else
      dict[slotIdx] = nil
      dirty = true
    end
  end
  for _, id in ipairs(idOrder) do
    if not slotForId[id] then
      local idx = nextFreeSlot(dict)
      if idx then
        dict[idx]     = { kind = kindForId[id], id = id }
        slotForId[id] = idx
        dirty = true
      end
    end
  end
  if dirty then writeSlots(track, dict) end
  return dict, slotForId, firstName
end

----------- PUBLIC

----- Discovery

function am:projectTracks()
  local out = {}
  for ti = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, ti)
    local _, name = reaper.GetTrackName(track)
    local dict = ensureSlots(track)
    local slotCount = 0
    for _ in pairs(dict) do slotCount = slotCount + 1 end
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
  local _, slotForId = ensureSlots(track)

  local out = {}
  forEachActiveTake(track, function(take, item)
    local startQN, lengthQN = itemQNRange(item)
    local id = takeIdOf(take)
    out[#out+1] = {
      item           = item,
      take           = take,
      trackIdx       = trackIdx,
      startQN        = startQN,
      lengthQN       = lengthQN,
      naturalLenQN   = effectiveNaturalLenQN(take, item),
      kind           = takeKind(take),
      slotIdx        = id and slotForId[id] or nil,
      name           = reaper.GetTakeName(take) or '',
    }
  end)
  return out
end

--contract: take with largest overlap of [boxStartQN, boxEndQN) on trackIdx; accept(t) prefilters; nil if none
function am:takeAt(trackIdx, boxStartQN, boxEndQN, accept)
  local best, bestOverlap = nil, 0
  for _, take in ipairs(am:tracksTakes(trackIdx)) do
    local overlap = math.min(take.startQN + take.lengthQN, boxEndQN)
                  - math.max(take.startQN, boxStartQN)
    if overlap > bestOverlap and (not accept or accept(take)) then
      best, bestOverlap = take, overlap
    end
  end
  return best
end

--contract: take-shape (from tracksTakes) wrapping reaperTake on any project track; nil if not found
function am:findTake(reaperTake)
  if not reaperTake then return end
  for _, track in ipairs(am:projectTracks()) do
    for _, take in ipairs(am:tracksTakes(track.idx)) do
      if take.take == reaperTake then return take end
    end
  end
  return nil
end

--contract: (trackIdx, qn) boot pos: selected item, else edit-cursor QN + selected track; 0 if no track
function am:initialCursor()
  local item = reaper.GetSelectedMediaItem(0, 0)
  if item then
    local found = am:findTake(reaper.GetActiveTake(item))
    if found then return found.trackIdx, found.startQN end
  end
  local qn       = reaper.TimeMap2_timeToQN(0, reaper.GetCursorPositionEx(0))
  local track    = reaper.GetSelectedTrack(0, 0)
  local trackIdx = track and (reaper.GetMediaTrackInfo_Value(track, 'IP_TRACKNUMBER') - 1) or 0
  return trackIdx, qn
end

----- Transport — project edit cursor, loop range, play head, project end

function am:editCursorQN()
  return reaper.TimeMap2_timeToQN(0, reaper.GetCursorPositionEx(0))
end

function am:setEditCursorQN(qn)
  reaper.SetEditCurPos(reaper.TimeMap2_QNToTime(0, qn), false, false)
end

--contract: (loQN, hiQN) of the project loop range; nil when no loop is set (start == end).
function am:loopRangeQN()
  local startT, endT = reaper.GetSet_LoopTimeRange(false, true, 0, 0, false)
  if startT == endT then return end
  return reaper.TimeMap2_timeToQN(0, startT), reaper.TimeMap2_timeToQN(0, endT)
end

function am:setLoopRangeQN(loQN, hiQN)
  reaper.GetSet_LoopTimeRange(true, true,
    reaper.TimeMap2_QNToTime(0, loQN), reaper.TimeMap2_QNToTime(0, hiQN), false)
end

function am:clearLoopRange()
  reaper.GetSet_LoopTimeRange(true, true, 0, 0, false)
end

--contract: QN of the play head; nil when the transport is not playing.
function am:playPositionQN()
  if reaper.GetPlayState() & 1 == 0 then return end
  return reaper.TimeMap2_timeToQN(0, reaper.GetPlayPosition())
end

--contract: largest item-end QN across all tracks; 0 when the project has no items
function am:projectEndQN()
  local endQN = 0
  for ti = 0, reaper.CountTracks(0) - 1 do
    forEachActiveTake(reaper.GetTrack(0, ti), function(_, item)
      local startQN, lengthQN = itemQNRange(item)
      local e = startQN + lengthQN
      if e > endQN then endQN = e end
    end)
  end
  return endQN
end

function am:trackSlots(trackIdx)
  local track = reaper.GetTrack(0, trackIdx)
  if not track then return {} end
  local dict, _, firstName = ensureSlots(track)

  local out = {}
  for i = 0, SLOT_MAX do
    local entry = dict[i]
    if entry then
      out[#out+1] = {
        idx  = i,
        kind = entry.kind,
        id   = entry.id,
        name = firstName[entry.id] or '',
      }
    end
  end
  return out
end

function am:slotForTake(take)
  local track = reaper.GetMediaItemTake_Track(take)
  local id    = takeIdOf(take)
  if not track or not id then return end
  local _, slotForId = ensureSlots(track)
  return slotForId[id]
end

function am:keyForSlot(slotIdx)
  return util.toBase62(slotIdx)
end

----- Slot mutation

function am:renameSlot(trackIdx, slotIdx, name)
  local track = reaper.GetTrack(0, trackIdx)
  if not track then return end
  local entry = readSlots(track)[slotIdx]
  if not entry or not entry.id then return end
  forEachActiveTake(track, function(take)
    if takeIdOf(take) == entry.id then
      reaper.GetSetMediaItemTakeInfo_String(take, 'P_NAME', name, true)
    end
  end)
end

--contract: deletes every take on trackIdx with this slot's id; returns the removed count
function am:deleteSlot(trackIdx, slotIdx)
  local track = reaper.GetTrack(0, trackIdx)
  if not track then return 0 end
  local entry = readSlots(track)[slotIdx]
  if not entry or not entry.id then return 0 end
  local removed = 0
  for ii = reaper.CountTrackMediaItems(track) - 1, 0, -1 do
    local item = reaper.GetTrackMediaItem(track, ii)
    local take = item and reaper.GetActiveTake(item)
    if take and takeIdOf(take) == entry.id then
      reaper.DeleteTrackMediaItem(track, item)
      removed = removed + 1
    end
  end
  ensureSlots(track)    -- prune the now-orphaned dict entry inline so the palette doesn't briefly show a ghost row
  return removed
end

----- Placement

local function chunkSetPool(chunk, guid)
  if chunk:find('POOLEDEVTS', 1, true) then
    return (chunk:gsub('POOLEDEVTS%s+{[^}]+}', 'POOLEDEVTS ' .. guid))
  end
  -- Defensive: CreateNewMIDIItemInProj always emits a POOLEDEVTS line, so this branch is unreachable in practice.
  return (chunk:gsub('(<SOURCE MIDI\n)', '%1    POOLEDEVTS ' .. guid .. '\n', 1))
end

local function harvestPoolGuid(item)
  local ok, chunk = reaper.GetItemStateChunk(item, '', false)
  if not ok or not chunk then return end
  return chunk:match('POOLEDEVTS%s+({[^}]+})')
end

local function poolMidiItem(item, guid)
  local ok, chunk = reaper.GetItemStateChunk(item, '', false)
  if ok and chunk then
    reaper.SetItemStateChunk(item, chunkSetPool(chunk, guid), false)
  end
end

--contract: MIDI: pooled clone via POOLEDEVTS swap; audio: sibling on file id; nil if REAPER refuses. Natural length defaults to util.OPEN (caller must not write a numeric natural here — placement is an "open the tap" gesture).
local function placeSource(track, kind, id, qnPos, lengthQN, name)
  local take
  if kind == 'midi' then
    local item = reaper.CreateNewMIDIItemInProj(
      track, qnPos, qnPos + lengthQN, true)
    if not item then return end
    poolMidiItem(item, id)
    take = reaper.GetActiveTake(item)
  else
    local item = reaper.AddMediaItemToTrack(track)
    if not item then return end
    local startSec = reaper.TimeMap2_QNToTime(0, qnPos)
    local endSec   = reaper.TimeMap2_QNToTime(0, qnPos + lengthQN)
    reaper.SetMediaItemInfo_Value(item, 'D_POSITION', startSec)
    reaper.SetMediaItemInfo_Value(item, 'D_LENGTH',   endSec - startSec)
    take = reaper.AddTakeToMediaItem(item)
    if take then
      local src = reaper.PCM_Source_CreateFromFile(id)
      if src then reaper.SetMediaItemTake_Source(take, src) end
    end
  end
  if not take then return end
  if name and name ~= '' then
    reaper.GetSetMediaItemTakeInfo_String(take, 'P_NAME', name, true)
  end
  return take
end

--contract: (slotIdx, take) for new MIDI on trackIdx in lowest-free slot; nil if no track or no free slot. Natural length defaults to util.OPEN.
function am:createAndDropMidi(trackIdx, qnPos, lengthQN, name)
  local track   = reaper.GetTrack(0, trackIdx)
  local dict    = track and readSlots(track)
  local slotIdx = dict and nextFreeSlot(dict)
  if not slotIdx then return end

  local item = reaper.CreateNewMIDIItemInProj(track, qnPos, qnPos + lengthQN, true)
  local take = item and reaper.GetActiveTake(item)
  local guid = take and harvestPoolGuid(item)
  if not guid then return end

  dict[slotIdx] = { kind = 'midi', id = guid }
  writeSlots(track, dict)
  if name and name ~= '' then
    reaper.GetSetMediaItemTakeInfo_String(take, 'P_NAME', name, true)
  end
  relayoutTrack(track)
  return slotIdx, take
end

-- What a fresh drop inherits when the caller supplies neither length nor name.
local function siblingInstance(track, id)
  local len, name
  forEachActiveTake(track, function(take, item)
    if not len and takeIdOf(take) == id then
      len  = select(2, itemQNRange(item))
      name = reaper.GetTakeName(take) or ''
    end
  end)
  return len, name
end

--contract: instance of slot at qnPos; lengthQN <- sibling len or 1; name <- sibling; nil if track/slot missing
function am:dropInstance(trackIdx, slotIdx, qnPos, lengthQN)
  local track = reaper.GetTrack(0, trackIdx)
  if not track then return end
  local entry = readSlots(track)[slotIdx]
  if not entry or not entry.id then return end
  local siblingLen, siblingName = siblingInstance(track, entry.id)
  local take = placeSource(track, entry.kind, entry.id, qnPos,
                           lengthQN or siblingLen or 1, siblingName)
  if take then relayoutTrack(track) end
  return take
end

--contract: clones take at qnPos on its own track (name included, original untouched); nil if track/id missing
function am:duplicateTake(take, qnPos)
  local track = reaper.GetTrack(0, take.trackIdx)
  local id    = takeIdOf(take.take)
  if not track or not id then return end
  local copy = placeSource(track, take.kind, id, qnPos, take.lengthQN, take.name)
  if copy then relayoutTrack(track) end
  return copy
end

----- Per-take edits

--contract: true iff no other take on trackIdx starts exactly at startQN (item ~= exceptItem). Replaces the old range-overlap gate: under the natural-length model items may share span, but never a start position.
function am:startIsClear(trackIdx, startQN, exceptItem)
  for _, other in ipairs(am:tracksTakes(trackIdx)) do
    if other.item ~= exceptItem and other.startQN == startQN then
      return false
    end
  end
  return true
end

--contract: shifts item start by deltaQN; relayouts the track. Natural length is preserved; D_LENGTH is re-derived. Returns true iff the new start clears existing starts (no-op on collision).
function am:moveTake(take, deltaQN)
  local startQN  = itemQNRange(take.item)
  local newStart = startQN + deltaQN
  if newStart < 0 then return false end
  if not am:startIsClear(take.trackIdx, newStart, take.item) then return false end
  local _, lengthQN = itemQNRange(take.item)
  setItemQNRange(take.item, newStart, newStart + lengthQN)
  local track = reaper.GetTrack(0, take.trackIdx)
  relayoutTrack(track)
  return true
end

--contract: writes the take's natural length; relayout caps it (source / next-take gap). A value ≥ source is demoted to util.OPEN during relayout.
function am:resizeTake(take, newNaturalQN)
  setNaturalLenOf(take.take, newNaturalQN)
  local track = reaper.GetTrack(0, take.trackIdx)
  relayoutTrack(track)
end

--contract: source length in QN at the take's position; 0 if source missing.
function am:takeSourceLengthQN(take)
  local src = reaper.GetMediaItemTake_Source(take.take)
  if not src then return 0 end
  local len, isQN = reaper.GetMediaSourceLength(src)
  if isQN then return len end
  local posSec = reaper.GetMediaItemInfo_Value(take.item, 'D_POSITION')
  return reaper.TimeMap2_timeToQN(0, posSec + len) - reaper.TimeMap2_timeToQN(0, posSec)
end

function am:deleteTake(take)
  local track = reaper.GetTrack(0, take.trackIdx)
  if not track then return end
  reaper.DeleteTrackMediaItem(track, take.item)
  relayoutTrack(track)
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

--contract: re-binds each takesUsing(name) take with markSwingStale=true; restores the original bound take at end
function am:reswingAll(name)
  assert(tm, 'arrangeManager: reswingAll requires the tm dependency')
  local origTake = tm:currentTake()
  for _, take in ipairs(am:takesUsing(name)) do
    if take ~= origTake then tm:bindTake(take, {markSwingStale=true}) end
  end
  if tm:currentTake() ~= origTake then tm:bindTake(origTake) end
end

return am
