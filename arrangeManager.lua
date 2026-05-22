-- See docs/arrangeManager.md for the model.
-- @noindex

--invariant: project-wide singleton; reads REAPER items + cm directly, owns no take state of its own
--invariant: slot palette lives in cm at the track tier under 'arrangeSlots'; foreign-track writes route through cm:writeTrackKey
--invariant: slot indices are 0..61, base62-keyed via util.toBase62 (62 chars: 0-9, a-z, A-Z); allocation is lowest-free; gaps allowed
--invariant: every grouped take is a slot — `trackSlots`, `tracksTakes`, `slotForTake` and `projectTracks` route through ensureSlots, which allocates indices for live ids not yet in the dict and prunes dict entries whose id has no live take. A slot has no existence apart from at least one take on the grid carrying its id.
--invariant: createAndDropMidi is the only path that mints a slot; everything else either inherits one from existing items (auto-materialisation) or drops another instance into one that already exists
--invariant: takeId derivation is the source-identity chokepoint — MIDI: POOLEDEVTS guid from item state chunk (pooled takes share it); audio: source filename. Takes whose id can't be derived are skipped during ensureSlots — they neither materialise a slot nor pin one.
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

-- Walk the track's live takes; assign the lowest-free slot to any id
-- not yet in the dict; drop dict entries whose id has no live take.
-- Idempotent — repeated calls in one frame do nothing after the first.
-- Returns (dict, slotForId, firstName) so callers don't repeat the walk.
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
      item     = item,
      take     = take,
      trackIdx = trackIdx,
      startQN  = startQN,
      lengthQN = lengthQN,
      kind     = takeKind(take),
      slotIdx  = id and slotForId[id] or nil,
      name     = reaper.GetTakeName(take) or '',
    }
  end)
  return out
end

--contract: returns the take on `trackIdx` overlapping the half-open box [boxStartQN, boxEndQN) by the largest QN span — the take the one-row cursor sits "on"; nil if no take overlaps. Ties resolve to REAPER item order. `accept`, when given, filters candidates first: a take failing accept(take) is never ranked.
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

--contract: returns the take-shape on any project track whose underlying REAPER take is `reaperTake`; nil if not found. Turns a REAPER take handle back into a grid position.
function am:findTake(reaperTake)
  if not reaperTake then return end
  for _, track in ipairs(am:projectTracks()) do
    for _, take in ipairs(am:tracksTakes(track.idx)) do
      if take.take == reaperTake then return take end
    end
  end
  return nil
end

--contract: the arrange cursor's boot position as (trackIdx, qn): the first selected item's take start when an item is selected, else REAPER's edit-cursor QN and selected-track column. trackIdx 0 when no track is selected.
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

--contract: clears the project loop range (start == end); loopRangeQN then returns nil.
function am:clearLoopRange()
  reaper.GetSet_LoopTimeRange(true, true, 0, 0, false)
end

--contract: QN of the play head; nil when the transport is not playing.
function am:playPositionQN()
  if reaper.GetPlayState() & 1 == 0 then return end
  return reaper.TimeMap2_timeToQN(0, reaper.GetPlayPosition())
end

--contract: QN of the end of the last take in the project — the largest item end across all tracks; 0 when the project has no items.
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

--contract: deletes every live take whose id matches this slot's id. ensureSlots prunes the now-orphaned dict entry on the next read; we run it inline so the palette doesn't briefly carry a ghost row. Returns the number of takes removed.
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
  ensureSlots(track)
  return removed
end

----- Placement

-- POOLEDEVTS swap. Splice the existing pool line, or insert one after
-- the SOURCE MIDI header when REAPER returned a chunk without one
-- (defensive — CreateNewMIDIItemInProj always emits a fresh pool line).
local function chunkSetPool(chunk, guid)
  if chunk:find('POOLEDEVTS', 1, true) then
    return (chunk:gsub('POOLEDEVTS%s+{[^}]+}', 'POOLEDEVTS ' .. guid))
  end
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

-- Place a fresh item carrying source `id` on `track` at qnPos for
-- lengthQN, named `name` when given. MIDI: a pooled clone (POOLEDEVTS
-- swap to `id`); audio: a sibling item on file `id` — REAPER doesn't
-- pool audio. Returns the take, or nil if REAPER refused the item.
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

--contract: creates a fresh MIDI source on `trackIdx` at qnPos for lengthQN, allocates the lowest-free slot pointing at the new pool guid, names the take, returns (slotIdx, take). Nil if track missing or slots exhausted. The only path that mints a slot.
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
  return slotIdx, take
end

-- Length and name of the first existing instance of source `id` on
-- `track` — what a fresh drop inherits when the caller supplies neither.
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

--contract: drops a fresh instance of slot `slotIdx` on track `trackIdx` at qnPos. lengthQN defaults to the length of an existing instance of the slot (a slot always has one), else 1 QN; the dropped take inherits that instance's name. MIDI pools via POOLEDEVTS; audio adds a sibling on the slot's file. Returns the take, or nil if track/slot is missing. Audio branch is currently dormant: no surface creates audio slots, but ensureSlots will materialise one from any pre-existing audio item REAPER hands us.
function am:dropInstance(trackIdx, slotIdx, qnPos, lengthQN)
  local track = reaper.GetTrack(0, trackIdx)
  if not track then return end
  local entry = readSlots(track)[slotIdx]
  if not entry or not entry.id then return end
  local siblingLen, siblingName = siblingInstance(track, entry.id)
  return placeSource(track, entry.kind, entry.id, qnPos,
                     lengthQN or siblingLen or 1, siblingName)
end

--contract: clones `take` (name included) at qnPos on its own track, original untouched; returns the new take, or nil if take/track is missing or the take's id can't be derived. MIDI: a pooled clone sharing the POOLEDEVTS guid; audio: a sibling on the same file.
function am:duplicateTake(take, qnPos)
  local track = reaper.GetTrack(0, take.trackIdx)
  local id    = takeIdOf(take.take)
  if not track or not id then return end
  return placeSource(track, take.kind, id, qnPos, take.lengthQN, take.name)
end

----- Per-take edits

--contract: returns (loQN, hiQN), the QN window the take may occupy on its track without overlapping a neighbour — lo the nearest left take's end (>=0), hi the nearest right take's start (math.huge if none). Left/right are decided against the take's current range; abutting is legal under half-open ranges. The mutators below are faithful, so a grid-aware caller consults this to refuse a step that would overlap.
function am:freeSpan(take)
  local startQN, lengthQN = itemQNRange(take.item)
  local endQN = startQN + lengthQN
  local lo, hi = 0, math.huge
  for _, other in ipairs(am:tracksTakes(take.trackIdx)) do
    if other.item ~= take.item then
      local otherEnd = other.startQN + other.lengthQN
      if otherEnd <= startQN then
        lo = math.max(lo, otherEnd)
      elseif other.startQN >= endQN then
        hi = math.min(hi, other.startQN)
      end
    end
  end
  return lo, hi
end

--contract: true when [startQN, startQN+lengthQN) on `trackIdx` overlaps no take whose item differs from `exceptItem` — the placement test for a free mouse move (pass the dragged take's item) or an Alt-duplicate (pass nil, so the original counts). Abutting is legal under half-open ranges.
function am:rangeIsClear(trackIdx, startQN, lengthQN, exceptItem)
  local endQN = startQN + lengthQN
  for _, other in ipairs(am:tracksTakes(trackIdx)) do
    if other.item ~= exceptItem
       and startQN < other.startQN + other.lengthQN
       and other.startQN < endQN then
      return false
    end
  end
  return true
end

--contract: shifts the take's item start by deltaQN, length unchanged. Faithful — no clamping; callers consult freeSpan and own the grid/snap policy.
function am:moveTake(take, deltaQN)
  local startQN, lengthQN = itemQNRange(take.item)
  setItemQNRange(take.item, startQN + deltaQN, startQN + lengthQN + deltaQN)
end

--contract: sets the take's item length to newLengthQN absolutely, start edge fixed. Faithful — no clamping; callers consult freeSpan and own snap and the minimum-length floor.
function am:resizeTake(take, newLengthQN)
  local startQN = itemQNRange(take.item)
  setItemQNRange(take.item, startQN, startQN + newLengthQN)
end

function am:deleteTake(take)
  local track = reaper.GetTrack(0, take.trackIdx)
  if track then reaper.DeleteTrackMediaItem(track, take.item) end
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
