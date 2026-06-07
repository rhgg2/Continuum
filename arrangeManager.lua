-- See docs/arrangeManager.md for the model.
-- @noindex

--invariant: project-wide singleton; reads REAPER items + cm directly, owns no take state of its own
--invariant: trackIdx is a visible-column index, not a REAPER slot (see docs/arrangeManager.md)
--invariant: slot palette in cm at track tier under key 'arrangeSlots'; writes via cm:writeTrackKey
--invariant: slot indices 0..61, base62-keyed (util.toBase62); lowest-free, gaps allowed
--invariant: every grouped take is a slot; all four discovery reads route through ensureSlots
--invariant: createAndDropMidi alone mints a slot; all else inherits or drops into an existing one
--invariant: takeId is the source-identity chokepoint; takes with no derivable id are skipped
--invariant: reswingAll is sequenceManager folded in; tm optional, omitted by discovery callers
--invariant: natural length in cm 'arrangeNaturalLenQN', nil → util.OPEN; see docs § Natural length
--invariant: a stored natural ≥ source demotes to util.OPEN; see docs § Natural length
--invariant: 'arrangeColours' (project tier) maps takeId → colourIdx project-wide
--invariant: arrangeColours allocates lowest-free across live takeIds; ensureColours prunes dead ids
--invariant: placement stamps painter.hueNative(idx) on new takes iff I_CUSTOMCOLOR == 0
--invariant: painter.hue and painter.hueNative share one hash; freshly-stamped takes match the grid

local util    = require 'util'
local painter = require 'painter'

local cm, tm, facade = (...).cm, (...).tm, (...).facade

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

--contract: re-derives each D_LENGTH walking startQN order; idempotent. See docs § Natural length
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

----- Colour palette (project-wide, keyed by takeId)

local function readColours()   return cm:getAt('project', 'arrangeColours') or {} end
local function writeColours(d) cm:set('project', 'arrangeColours', d) end

--contract: walks all tracks; prunes dead, allocates lowest-free for new ids. Returns id→idx.
local function ensureColours()
  local live = {}
  for ti = 0, reaper.CountTracks(0) - 1 do
    forEachActiveTake(reaper.GetTrack(0, ti), function(take)
      local id = takeIdOf(take)
      if id then live[id] = true end
    end)
  end
  local dict = readColours()
  local used, dirty = {}, false
  for id, idx in pairs(dict) do
    if not live[id] then dict[id] = nil; dirty = true
    else                  used[idx]  = true end
  end
  local nextFree = 0
  for id in pairs(live) do
    if not dict[id] then
      while used[nextFree] do nextFree = nextFree + 1 end
      dict[id]       = nextFree
      used[nextFree] = true
      dirty          = true
    end
  end
  if dirty then writeColours(dict) end
  return dict
end

-- Preserve user override: only stamp when I_CUSTOMCOLOR == 0. A REAPER
-- recolour on any instance therefore survives every relayout.
local function stampColour(take, colourIdx)
  if not take or not colourIdx then return end
  if reaper.GetMediaItemTakeInfo_Value(take, 'I_CUSTOMCOLOR') ~= 0 then return end
  reaper.SetMediaItemTakeInfo_Value(take, 'I_CUSTOMCOLOR', painter.hueNative(colourIdx))
end

local function stampForTake(take)
  local id = take and takeIdOf(take)
  if not id then return end
  stampColour(take, ensureColours()[id])
end

----------- PUBLIC

----- Discovery

-- The wiring scratch track is a hidden FX-park track; arrange hides it by asking the
-- wiring facade (wm owns the id→track bridge). see docs/arrangeManager.md § trackIdx
local function isVisibleTrack(track)
  local wiring = facade and facade.get('wiring')
  return not (wiring and wiring.isScratchTrack(track))
end

local function visibleTrackOfCol(col)
  if not col or col < 0 then return nil end
  local visIdx = 0
  for ti = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, ti)
    if isVisibleTrack(tr) then
      if visIdx == col then return tr end
      visIdx = visIdx + 1
    end
  end
end

local function colOfTrack(track)
  if not track then return nil end
  local visIdx = 0
  for ti = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, ti)
    if isVisibleTrack(tr) then
      if tr == track then return visIdx end
      visIdx = visIdx + 1
    end
  end
end

function am:projectTracks()
  local out = {}
  for ti = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, ti)
    if isVisibleTrack(track) then
      local _, name = reaper.GetTrackName(track)
      local dict = ensureSlots(track)
      local slotCount = 0
      for _ in pairs(dict) do slotCount = slotCount + 1 end
      out[#out+1] = {
        idx       = #out,
        track     = track,
        name      = name or '',
        slotCount = slotCount,
        takeCount = reaper.CountTrackMediaItems(track),
      }
    end
  end
  return out
end

function am:tracksTakes(trackIdx)
  local track = visibleTrackOfCol(trackIdx)
  if not track then return {} end
  local _, slotForId = ensureSlots(track)
  local colourForId  = ensureColours()

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
      slotIdx        = id and slotForId[id]   or nil,
      colourIdx      = id and colourForId[id] or nil,
      nativeColour   = reaper.GetDisplayedMediaItemColor2(item, take) or 0,
      name           = reaper.GetTakeName(take) or '',
    }
  end)
  return out
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

--contract: (col, qn) — selected item, else edit-cursor QN + selected track; col=0 if neither
function am:initialCursor()
  local item = reaper.GetSelectedMediaItem(0, 0)
  if item then
    local found = am:findTake(reaper.GetActiveTake(item))
    if found then return found.trackIdx, found.startQN end
  end
  local qn  = reaper.TimeMap2_timeToQN(0, reaper.GetCursorPositionEx(0))
  local sel = reaper.GetSelectedTrack(0, 0)
  return colOfTrack(sel) or 0, qn
end

----- Transport — project edit cursor, loop range, play head, project end

function am:editCursorQN()
  return reaper.TimeMap2_timeToQN(0, reaper.GetCursorPositionEx(0))
end

-- seekplay=true: gutter clicks (and arrangePlayFromCursor's seek) drag
-- the playhead with them when the transport is running.
function am:setEditCursorQN(qn)
  reaper.SetEditCurPos(reaper.TimeMap2_QNToTime(0, qn), false, true)
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

--contract: seeks the edit cursor to qn (transport follows if playing); starts playback iff stopped.
function am:playFromQN(qn)
  self:setEditCursorQN(qn)
  if reaper.GetPlayState() & 1 == 0 then reaper.OnPlayButton() end
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
  local track = visibleTrackOfCol(trackIdx)
  if not track then return {} end
  local dict, _, firstName = ensureSlots(track)
  local colourForId        = ensureColours()

  local out = {}
  for i = 0, SLOT_MAX do
    local entry = dict[i]
    if entry then
      out[#out+1] = {
        idx       = i,
        kind      = entry.kind,
        id        = entry.id,
        colourIdx = colourForId[entry.id],
        name      = firstName[entry.id] or '',
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

--contract: lowest-free slot index on trackIdx; nil if track full or missing.
function am:nextFreeSlot(trackIdx)
  local track = visibleTrackOfCol(trackIdx)
  if not track then return nil end
  return nextFreeSlot(readSlots(track))
end

----- Slot mutation

function am:renameSlot(trackIdx, slotIdx, name)
  local track = visibleTrackOfCol(trackIdx)
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
  local track = visibleTrackOfCol(trackIdx)
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

local function setTakeName(take, name)
  if take and name and name ~= '' then
    reaper.GetSetMediaItemTakeInfo_String(take, 'P_NAME', name, true)
  end
end

local function copyMidiEvents(srcTake, dstTake)
  local ok, evts = reaper.MIDI_GetAllEvts(srcTake, '')
  if ok and evts then reaper.MIDI_SetAllEvts(dstTake, evts) end
end

local function placeAudio(track, filePath, qnPos, lengthQN)
  local item = reaper.AddMediaItemToTrack(track)
  if not item then return end
  setItemQNRange(item, qnPos, qnPos + lengthQN)
  local take = reaper.AddTakeToMediaItem(item)
  if take then
    local src = reaper.PCM_Source_CreateFromFile(filePath)
    if src then reaper.SetMediaItemTake_Source(take, src) end
  end
  return take
end

-- See docs/arrangeManager.md § Subsequent drops for why chunk-clone over POOLEDEVTS swap.
--contract: MIDI clone of srcItem at qnPos; rePool=true mints a fresh pool; nil if REAPER refuses.
local function cloneMidiItem(track, srcItem, qnPos, lengthQN, rePool)
  local newItem = reaper.CreateNewMIDIItemInProj(track, qnPos, qnPos + lengthQN, true)
  if not newItem then return end
  local ok, srcChunk = reaper.GetItemStateChunk(srcItem, '', false)
  if not (ok and srcChunk) then return reaper.GetActiveTake(newItem) end

  local chunk = srcChunk
  if rePool then
    local freshGuid = harvestPoolGuid(newItem)
    if freshGuid then chunk = chunkSetPool(srcChunk, freshGuid) end
  end
  reaper.SetItemStateChunk(newItem, chunk, false)
  -- Chunk replays src POSITION/LENGTH and may swap the active take; restore + refetch.
  setItemQNRange(newItem, qnPos, qnPos + lengthQN)
  local newTake = reaper.GetActiveTake(newItem)
  if rePool then
    -- Fresh pool identity sheds the source's visual identity; the next
    -- stamp pass mints a hue against the new takeId.
    reaper.SetMediaItemInfo_Value(newItem, 'I_CUSTOMCOLOR', 0)
    if newTake then reaper.SetMediaItemTakeInfo_Value(newTake, 'I_CUSTOMCOLOR', 0) end
  end
  -- Pooled: idempotent (chunk already carried events). Unpooled: the only
  -- step that populates events into the freshly-minted pool.
  copyMidiEvents(reaper.GetActiveTake(srcItem), newTake)
  return newTake
end

--contract: (slotIdx, take) for new MIDI on trackIdx in lowest-free slot; nil if no track/free slot
function am:createAndDropMidi(trackIdx, qnPos, lengthQN, name)
  local track   = visibleTrackOfCol(trackIdx)
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
  stampForTake(take)
  relayoutTrack(track)
  return slotIdx, take
end

-- First instance matching id: item (chunk source for MIDI clone),
-- length, name. Dictates what a fresh drop inherits.
local function siblingInstance(track, id)
  local sibItem, sibLen, sibName
  forEachActiveTake(track, function(take, item)
    if not sibItem and takeIdOf(take) == id then
      sibItem = item
      sibLen  = select(2, itemQNRange(item))
      sibName = reaper.GetTakeName(take) or ''
    end
  end)
  return sibItem, sibLen, sibName
end

--contract: instance of slot at qnPos; nil if track/slot missing (MIDI also requires a live sibling)
function am:dropInstance(trackIdx, slotIdx, qnPos, lengthQN)
  local track = visibleTrackOfCol(trackIdx)
  if not track then return end
  local entry = readSlots(track)[slotIdx]
  if not entry or not entry.id then return end
  local sibItem, sibLen, sibName = siblingInstance(track, entry.id)
  local len = lengthQN or sibLen or 1
  local take
  if entry.kind == 'midi' then
    if not sibItem then return end
    take = cloneMidiItem(track, sibItem, qnPos, len, false)
  else
    take = placeAudio(track, entry.id, qnPos, len)
  end
  if not take then return end
  setTakeName(take, sibName)
  stampForTake(take)
  relayoutTrack(track)
  return take
end

--contract: clones take at qnPos on its own track, original untouched; nil if track/id missing
function am:duplicateTake(take, qnPos)
  local track = visibleTrackOfCol(take.trackIdx)
  if not track then return end
  local copy
  if take.kind == 'midi' then
    copy = cloneMidiItem(track, take.item, qnPos, take.lengthQN, false)
  else
    local id = takeIdOf(take.take)
    if not id then return end
    copy = placeAudio(track, id, qnPos, take.lengthQN)
  end
  if not copy then return end
  setTakeName(copy, take.name)
  stampForTake(copy)
  relayoutTrack(track)
  return copy
end

-- Destination for the *-Below trio: natural end (not rendered), so a truncated upstream still
-- drops past its downstream neighbour; relayout handles the symmetric truncation.
local function destBelow(take) return take.startQN + take.naturalLenQN end

--contract: pooled clone at startQN+naturalLenQN; nil iff non-MIDI or start-collision.
function am:duplicateBelow(take)
  if take.kind ~= 'midi' then return end
  local destQN = destBelow(take)
  if not am:startIsClear(take.trackIdx, destQN) then return end
  return am:duplicateTake(take, destQN)
end

--contract: unpooled clone at startQN+naturalLenQN; nil iff non-MIDI or start-collision.
function am:duplicateUnpooledBelow(take)
  if take.kind ~= 'midi' then return end
  local destQN = destBelow(take)
  if not am:startIsClear(take.trackIdx, destQN) then return end
  local track = visibleTrackOfCol(take.trackIdx)
  local newTake = cloneMidiItem(track, take.item, destQN, take.naturalLenQN, true)
  if not newTake then return end
  setTakeName(newTake, take.name)
  stampForTake(newTake)
  relayoutTrack(track)
  return newTake
end

--contract: empty MIDI take at natural end, naturalLenQN-sized; nil iff non-MIDI or start collision.
function am:newTakeBelow(take)
  if take.kind ~= 'midi' then return end
  local destQN = destBelow(take)
  if not am:startIsClear(take.trackIdx, destQN) then return end
  local _, newTake = am:createAndDropMidi(take.trackIdx, destQN, take.naturalLenQN, '')
  return newTake
end

----- Per-take edits

--contract: true iff no take on trackIdx (≠ exceptItem) starts exactly at startQN (shared spans OK)
function am:startIsClear(trackIdx, startQN, exceptItem)
  for _, other in ipairs(am:tracksTakes(trackIdx)) do
    if other.item ~= exceptItem and other.startQN == startQN then
      return false
    end
  end
  return true
end

--contract: shifts start by deltaQN, relayouts (natural kept); true iff start clear, else no-op
function am:moveTake(take, deltaQN)
  local startQN  = itemQNRange(take.item)
  local newStart = startQN + deltaQN
  if newStart < 0 then return false end
  if not am:startIsClear(take.trackIdx, newStart, take.item) then return false end
  local _, lengthQN = itemQNRange(take.item)
  setItemQNRange(take.item, newStart, newStart + lengthQN)
  local track = visibleTrackOfCol(take.trackIdx)
  relayoutTrack(track)
  return true
end

--contract: writes the take's natural length; relayout caps it. See docs § Natural length.
function am:resizeTake(take, newNaturalQN)
  setNaturalLenOf(take.take, newNaturalQN)
  local track = visibleTrackOfCol(take.trackIdx)
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
  local track = visibleTrackOfCol(take.trackIdx)
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

--contract: reads each take's persisted usedSwings via cm:readTakeKey; no mm/cm context disturbance
function am:takesUsing(name)
  local hits = {}
  for _, take in ipairs(projectMidiTakes()) do
    local used = cm:readTakeKey(take, 'usedSwings')
    if used and used[name] then hits[#hits+1] = take end
  end
  return hits
end

--contract: re-binds each takesUsing(name) take (markSwingStale); restores the bound take after
function am:reswingAll(name)
  assert(tm, 'arrangeManager: reswingAll requires the tm dependency')
  local origTake = tm:currentTake()
  for _, take in ipairs(am:takesUsing(name)) do
    if take ~= origTake then tm:bindTake(take, {markSwingStale=true}) end
  end
  if tm:currentTake() ~= origTake then tm:bindTake(origTake) end
end

return am
