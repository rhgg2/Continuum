-- See docs/arrangeManager.md for the model.
-- @noindex

--invariant: project-wide singleton; reads REAPER items + cm directly, owns no take state of its own
--invariant: trackIdx is a visible-column index, not a REAPER slot (see docs/arrangeManager.md)
--invariant: slot palette in ds at track scope under key 'arrangeSlots'; writes via ds:assignAt
--invariant: slot indices 0..61, base62-keyed (util.toBase62); lowest-free, gaps allowed
--invariant: a slot survives while its id is live on the track or parked; reads via ensureSlots
--invariant: deleteTake parks a slot's last instance; deleteSlot alone forever-deletes
--invariant: createAndDropMidi + mintParkedTake mint slots; everything else reuses an existing one
--invariant: takeId is the source-identity chokepoint; takes with no derivable id are skipped
--invariant: the takeId memo dies with the build — REAPER recycles a freed take's pointer
--invariant: reswingAll is sequenceManager folded in; bind loop lives behind the 'tracker' facade
--invariant: natural length in ds 'arrangeNaturalLenQN', nil → util.OPEN; see docs § Natural length
--invariant: a stored natural ≥ source demotes to util.OPEN; see docs § Natural length
--invariant: 'arrangeColours' (project scope) maps takeId → colourIdx project-wide
--invariant: arrangeColours allocates lowest-free across live takeIds; ensureColours prunes dead ids
--invariant: placement stamps painter.hueNative(idx) on new takes iff I_CUSTOMCOLOR == 0
--invariant: painter.hue and painter.hueNative share one hash; freshly-stamped takes match the grid
--invariant: render reads serve one cached build; rebuilt on invalidate() or state-count change

local util    = require 'util'
local painter = require 'painter'
local scratch = require 'scratch'

local cm, ds, facade, eventMeta = (...).cm, (...).ds, (...).facade, (...).eventMeta

local am = {}

local SLOT_MAX = 61    -- inclusive: 62 slots, base62 0..9 + a..z + A..Z

-- Arrange render state: one in-memory build serving every render read, rebuilt
-- only on a project change. See docs/arrangeManager.md § state.
local state, dirty, lastTick = nil, true, -1
local ensureState                       -- assigned below buildTakeShape
local takeIdCache = {}                  -- take → takeId; dropped with the build, see takeIdOf
local function invalidate() dirty, takeIdCache = true, {} end

----- Helpers

-- Memoised: costs one chunk read per take rather than one per frame. The memo
-- lasts one build, not the take's life. See docs § takeIdOf is memoised.
local function takeIdOf(take)
  local cached = takeIdCache[take]
  if cached then return cached end
  local id
  if reaper.TakeIsMIDI(take) then
    local item = reaper.GetMediaItemTake_Item(take)
    if not item then return end
    local ok, chunk = reaper.GetItemStateChunk(item, '', false)
    if not ok or not chunk then return end
    id = chunk:match('POOLEDEVTS%s+({[^}]+})')
  else
    local src = reaper.GetMediaItemTake_Source(take)
    if not src then return end
    id = reaper.GetMediaSourceFileName(src)
  end
  takeIdCache[take] = id
  return id
end

local function itemQNRange(item)
  local pos = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
  local len = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
  local startQN = reaper.TimeMap2_timeToQN(0, pos)
  local endQN   = reaper.TimeMap2_timeToQN(0, pos + len)
  return startQN, endQN - startQN
end

-- Skip no-op writes: relayout runs on every build, so a redundant write would
-- bump the project-state count and re-dirty the project for nothing.
local function setItemQNRange(item, startQN, endQN)
  local startSec = reaper.TimeMap2_QNToTime(0, startQN)
  local lenSec   = reaper.TimeMap2_QNToTime(0, endQN) - startSec
  if reaper.GetMediaItemInfo_Value(item, 'D_POSITION') ~= startSec then
    reaper.SetMediaItemInfo_Value(item, 'D_POSITION', startSec)
  end
  if reaper.GetMediaItemInfo_Value(item, 'D_LENGTH') ~= lenSec then
    reaper.SetMediaItemInfo_Value(item, 'D_LENGTH', lenSec)
  end
end

local function takeKind(take)
  return reaper.TakeIsMIDI(take) and 'midi' or 'audio'
end

local function readSlots(track)
  if not track then return {} end
  return ds:getAt(track, 'arrangeSlots') or {}
end

local function writeSlots(track, dict)
  ds:assignAt(track, 'arrangeSlots', dict)
end

local function nextFreeSlot(dict)
  for i = 0, SLOT_MAX do
    if dict[i] == nil then return i end
  end
end

-- fn returning a non-nil value aborts the walk; that value (and a second)
-- is forwarded as forEachActiveTake's return, so callers can early-exit.
local function forEachActiveTake(track, fn)
  for ii = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, ii)
    local take = item and reaper.GetActiveTake(item)
    if take then
      local a, b = fn(take, item, ii)
      if a ~= nil then return a, b end
    end
  end
end

-- A slot with no live instance keeps its source alive as one muted item
-- parked on the scratch track. See docs/arrangeManager.md § Parking.
local function parkedItemFor(id)
  if not id then return end
  local _, scratchTrack = scratch.peek()
  if not scratchTrack then return end
  return forEachActiveTake(scratchTrack, function(take, item)
    if takeIdOf(take) == id then return item, take end
  end)
end

local function writeTakeName(take, name)
  reaper.GetSetMediaItemTakeInfo_String(take, 'P_NAME', name, true)
end

local function isLastInstanceOnTrack(track, id, exceptItem)
  local others = 0
  forEachActiveTake(track, function(take, item)
    if item ~= exceptItem and takeIdOf(take) == id then others = others + 1 end
  end)
  return others == 0
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
  local stored = ds:getAt(take, 'arrangeNaturalLenQN')
  return stored or util.OPEN
end

local function setNaturalLenOf(take, v)
  if v == util.OPEN then ds:assignAt(take, 'arrangeNaturalLenQN', util.REMOVE)
  else                   ds:assignAt(take, 'arrangeNaturalLenQN', v) end
end

--contract: re-derives each D_LENGTH walking startQN order; idempotent. See docs § Natural length
local function relayoutTrack(track)
  if not track then return end
  local rows = {}
  forEachActiveTake(track, function(take, item)
    local startQN = itemQNRange(item)
    util.add(rows, { take = take, item = item, startQN = startQN })
  end)
  table.sort(rows, function(a, b) return a.startQN < b.startQN end)

  for i, r in ipairs(rows) do
    local natural = naturalLenOf(r.take)
    local effective
    if takeKind(r.take) == 'audio' then
      -- Audio length is the user's trim/loop, never the source: capture once
      -- so truncation is non-destructive and a freed neighbour lets it re-grow.
      if natural == util.OPEN then
        natural = (select(2, itemQNRange(r.item)))
        setNaturalLenOf(r.take, natural)
      end
      effective = natural
    else
      local src = sourceLenQN(r.take, r.item)
      if natural ~= util.OPEN and natural >= src then
        setNaturalLenOf(r.take, util.OPEN)
        natural = util.OPEN
      end
      effective = natural == util.OPEN and src or math.min(natural, src)
    end
    local nextStart = rows[i+1] and rows[i+1].startQN or math.huge
    local rendered  = math.min(effective, nextStart - r.startQN)
    if rendered < 0 then rendered = 0 end
    setItemQNRange(r.item, r.startQN, r.startQN + rendered)
  end
  invalidate()
end

-- The effective natural length (post-OPEN-resolution) exposed via tracksTakes.
local function effectiveNaturalLenQN(take, item)
  local natural = naturalLenOf(take)
  if takeKind(take) == 'audio' then
    if natural == util.OPEN then return (select(2, itemQNRange(item))) end
    return natural
  end
  local src = sourceLenQN(take, item)
  if natural == util.OPEN then return src end
  return math.min(natural, src)
end

--contract: idempotent within a frame; returns (dict, slotForId, firstName, liveIds)
local function ensureSlots(track)
  local dict = readSlots(track)
  local idOrder, liveIds, firstName, kindForId = {}, {}, {}, {}
  forEachActiveTake(track, function(take)
    local id = takeIdOf(take)
    if not id or liveIds[id] then return end
    liveIds[id]      = true
    firstName[id]    = reaper.GetTakeName(take) or ''
    kindForId[id]    = takeKind(take)
    util.add(idOrder, id)
  end)

  local slotForId, changed = {}, false
  for slotIdx, entry in pairs(dict) do
    local keep = false
    if entry.id and liveIds[entry.id] then
      slotForId[entry.id] = slotIdx
      keep = true
    elseif entry.id then
      local _, parkedTake = parkedItemFor(entry.id)
      if parkedTake then            -- last instance parked: the slot outlives the take
        slotForId[entry.id] = slotIdx
        firstName[entry.id] = firstName[entry.id] or reaper.GetTakeName(parkedTake) or ''
        keep = true
      end
    end
    if not keep then dict[slotIdx] = nil; changed = true end
  end
  for _, id in ipairs(idOrder) do
    if not slotForId[id] then
      local idx = nextFreeSlot(dict)
      if idx then
        dict[idx]     = { kind = kindForId[id], id = id }
        slotForId[id] = idx
        changed = true
      end
    end
  end
  if changed then writeSlots(track, dict) end
  return dict, slotForId, firstName, liveIds
end

----- Colour palette (project-wide, keyed by takeId)

local function readColours()   return ds:get('arrangeColours') or {} end
local function writeColours(d) ds:assign('arrangeColours', d) end

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
  local used, changed = {}, false
  for id, idx in pairs(dict) do
    if not live[id] then dict[id] = nil; changed = true
    else                  used[idx]  = true end
  end
  local nextFree = 0
  for id in pairs(live) do
    if not dict[id] then
      while used[nextFree] do nextFree = nextFree + 1 end
      dict[id]       = nextFree
      used[nextFree] = true
      changed        = true
    end
  end
  if changed then writeColours(dict) end
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

-- Arrange skips the scratch track (its own park, consulted directly) and the
-- wiring-owned newTrack hosts. see docs/arrangeManager.md § trackIdx
local function isVisibleTrack(track)
  local _, scratchTrack = scratch.peek()
  if scratchTrack and track == scratchTrack then return false end
  local wiring = facade and facade.get('wiring')
  return not (wiring and wiring.isWiringOwnedTrack(track))
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

function am:projectTracks() return ensureState().tracks end

-- Per-note channel/pitch: QN offsets from item start so shapes survive moves; chanMask = used-channel set.
--reaper: MIDI_CountEvts, MIDI_GetNote, MIDI_GetProjQNFromPPQPos
local function midiNotesOf(take, startQN)
  local _, noteCount = reaper.MIDI_CountEvts(take)
  local notes, chanMask = {}, 0
  for i = 0, noteCount - 1 do
    local ok, _, _, startPpq, endPpq, chan, pitch = reaper.MIDI_GetNote(take, i)
    if ok then
      util.add(notes, {
        offS  = reaper.MIDI_GetProjQNFromPPQPos(take, startPpq) - startQN,
        offE  = reaper.MIDI_GetProjQNFromPPQPos(take, endPpq) - startQN,
        chan  = chan,
        pitch = pitch,
      })
      chanMask = chanMask | (1 << chan)
    end
  end
  return notes, chanMask
end

local function buildTakeShape(take, item, trackIdx, startQN, lengthQN, slotForId, colourForId)
  local id   = takeIdOf(take)
  local kind = takeKind(take)
  local notes, chanMask
  if kind == 'midi' then notes, chanMask = midiNotesOf(take, startQN) end
  return {
    item         = item,
    take         = take,
    trackIdx     = trackIdx,
    startQN      = startQN,
    lengthQN     = lengthQN,
    naturalLenQN = effectiveNaturalLenQN(take, item),
    kind         = kind,
    notes        = notes,
    chanMask     = chanMask,
    slotIdx      = id and slotForId[id]   or nil,
    colourIdx    = id and colourForId[id] or nil,
    nativeColour = reaper.GetDisplayedMediaItemColor2(item, take) or 0,
    name         = reaper.GetTakeName(take) or '',
  }
end

----- Project state — one build, served until invalidated

local function slotRowsFor(dict, colourForId, firstName, liveIds)
  local out = {}
  for i = 0, SLOT_MAX do
    local entry = dict[i]
    if entry then
      util.add(out, {
        idx       = i,
        kind      = entry.kind,
        id        = entry.id,
        colourIdx = colourForId[entry.id],
        name      = firstName[entry.id] or '',
        parked    = not liveIds[entry.id],
      })
    end
  end
  return out
end

-- Union of channels used by a column's MIDI takes → {lo, hi}; nil if none. Shared
-- across the column so the preview's voice columns align across its takes.
local function chanRangeOf(takes)
  local mask = 0
  for _, tk in ipairs(takes) do
    if tk.chanMask then mask = mask | tk.chanMask end
  end
  if mask == 0 then return nil end
  local lo, hi
  for ch = 0, 15 do
    if mask & (1 << ch) ~= 0 then lo = lo or ch; hi = ch end
  end
  return { lo = lo, hi = hi }
end

-- One walk: track rows, per-column take-shapes + slot rows; ensureColours/ensureSlots once.
-- relayoutTrack per track re-derives D_LENGTH so a source-length edit outside am reflects.
local function buildState()
  local colourForId = ensureColours()
  local tracks, takesByCol, slotsByCol, chanByCol = {}, {}, {}, {}
  for ti = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, ti)
    if isVisibleTrack(track) then
      relayoutTrack(track)
      local col = #tracks
      local dict, slotForId, firstName, liveIds = ensureSlots(track)
      local _, name = reaper.GetTrackName(track)
      local slotCount = 0
      for _ in pairs(dict) do slotCount = slotCount + 1 end
      util.add(tracks, {
        idx = col, track = track, guid = reaper.GetTrackGUID(track), name = name or '',
        slotCount = slotCount,
        takeCount = reaper.CountTrackMediaItems(track),
      })
      local takes = {}
      forEachActiveTake(track, function(take, item)
        local startQN, lengthQN = itemQNRange(item)
        util.add(takes, buildTakeShape(take, item, col, startQN, lengthQN, slotForId, colourForId))
      end)
      takesByCol[col] = takes
      chanByCol[col]  = chanRangeOf(takes)
      slotsByCol[col] = slotRowsFor(dict, colourForId, firstName, liveIds)
    end
  end
  return { tracks = tracks, takesByCol = takesByCol, slotsByCol = slotsByCol, chanByCol = chanByCol }
end

-- Rebuild when our own edits flag dirty, or REAPER's state-count moves (external
-- edit). Re-reading the count after the build absorbs the build's own ext writes.
function ensureState()
  local tick = reaper.GetProjectStateChangeCount(0)
  if tick ~= lastTick then invalidate(); lastTick = tick end
  if dirty then
    state, dirty = buildState(), false
    lastTick = reaper.GetProjectStateChangeCount(0)
  end
  return state
end

function am:tracksTakes(trackIdx)
  return ensureState().takesByCol[trackIdx] or {}
end

function am:columnChanRange(trackIdx)
  return ensureState().chanByCol[trackIdx]
end

--contract: in-memory filter over the cached take-shapes; cols fromCol..toCol meeting [qnLo,qnHi]
function am:visibleTakes(fromCol, toCol, qnLo, qnHi)
  local byCol = ensureState().takesByCol
  local out = {}
  for col = fromCol, toCol do
    for _, tk in ipairs(byCol[col] or {}) do
      if tk.startQN <= qnHi and tk.startQN + tk.lengthQN >= qnLo then
        util.add(out, tk)
      end
    end
  end
  return out
end

--contract: true iff any visible column holds a placed take instance; parked-on-scratch excluded
function am:hasPlacedTakes()
  for _, takes in pairs(ensureState().takesByCol) do
    if #takes > 0 then return true end
  end
  return false
end

--contract: cached take-shape wrapping reaperTake on any project column; nil if not found
function am:findTake(reaperTake)
  if not reaperTake then return end
  for _, takes in pairs(ensureState().takesByCol) do
    for _, tk in ipairs(takes) do
      if tk.take == reaperTake then return tk end
    end
  end
end

-- The instance every song-growth verb acts from. see docs/arrangeManager.md § Instances of a slot
--contract: instance of take's slot containing qn; else first `back`-wards, else first the other way
--contract: second return true iff the instance contains qn; nil when the slot has no live instance
function am:seekInstance(take, qn, back)
  local id = takeIdOf(take)
  if not id then return end
  local col = colOfTrack(am:ownerTrack(take))
  if not col then return end
  local ahead, behind
  for _, tk in ipairs(am:tracksTakes(col)) do
    if takeIdOf(tk.take) == id then
      if qn >= tk.startQN and qn < tk.startQN + tk.lengthQN then return tk, true end
      if tk.startQN > qn then
        if not ahead  or tk.startQN < ahead.startQN  then ahead  = tk end
      else
        if not behind or tk.startQN > behind.startQN then behind = tk end
      end
    end
  end
  local first, second = ahead, behind
  if back then first, second = behind, ahead end
  local found = first or second
  if found then return found, false end
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

-- Repeat has to go on: a loop range with repeat off plays straight through.
--contract: (loQN, hiQN) — loop span, repeat on; cursor at start unless play head is inside it
function am:loopTo(loQN, hiQN)
  self:setLoopRangeQN(loQN, hiQN)
  reaper.GetSetRepeat(1)
  local playQN = self:playPositionQN()
  if playQN and playQN >= loQN and playQN < hiQN then return end   -- already sounding: don't pull it back
  self:setEditCursorQN(loQN)
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
    local track = reaper.GetTrack(0, ti)
    if isVisibleTrack(track) then
      forEachActiveTake(track, function(_, item)
        local startQN, lengthQN = itemQNRange(item)
        local e = startQN + lengthQN
        if e > endQN then endQN = e end
      end)
    end
  end
  return endQN
end

function am:trackSlots(trackIdx)
  return ensureState().slotsByCol[trackIdx] or {}
end

--contract: logical track owning take's slot — host track unless parked, then a slot-owner scan
function am:ownerTrack(take)
  if not take then return end
  local host = reaper.GetMediaItemTake_Track(take)
  if not am:isParkedTake(take) then return host end
  local id = takeIdOf(take)
  if not id then return host end
  for _, tr in ipairs(am:projectTracks()) do
    local track = visibleTrackOfCol(tr.idx)
    if track then
      for _, entry in pairs(readSlots(track)) do
        if entry.id == id then return track end
      end
    end
  end
  return host
end

--contract: (trackIdx, slotIdx) of the slot take sits in, live or parked; nil if it holds none
function am:slotOfTake(take)
  local id = take and takeIdOf(take)
  if not id then return end
  for _, tr in ipairs(am:projectTracks()) do
    for slotIdx, entry in pairs(readSlots(visibleTrackOfCol(tr.idx))) do
      if entry.id == id then return tr.idx, slotIdx end
    end
  end
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

-- Which slots a rename touches: unchanged ordinal reroots the family,
-- a changed ordinal renames just this slot. See docs/arrangeManager.md § Renaming and name drift.
local function familyRenames(slots, target, name)
  local oldRoot, oldOrdinal = util.variantRoot(target.name)
  local newRoot, newOrdinal = util.variantRoot(name)
  local out = { [target.id] = name }
  if newOrdinal ~= oldOrdinal then return out end
  local bases = {}
  for _, slot in ipairs(slots) do
    local root, ordinal = util.variantRoot(slot.name)
    if slot.id and root == oldRoot then
      if ordinal then out[slot.id] = ('%s (var %d)'):format(newRoot, ordinal)
      else            util.add(bases, slot) end
    end
  end
  -- A family holds one slot with the root plain; two are namesakes, and a
  -- rename of one leaves the other where it is.
  if #bases == 1 then out[bases[1].id] = newRoot end
  return out
end

--contract: renames the family when the ordinal is unchanged, else the slot alone; live + parked
function am:renameSlot(trackIdx, slotIdx, name)
  local track = visibleTrackOfCol(trackIdx)
  if not track then return end
  local slots, target = am:trackSlots(trackIdx), nil
  for _, slot in ipairs(slots) do if slot.idx == slotIdx then target = slot end end
  if not target or not target.id then return end

  local renames = familyRenames(slots, target, name)
  forEachActiveTake(track, function(take)
    local renamed = renames[takeIdOf(take)]
    if renamed then writeTakeName(take, renamed) end
  end)
  for id, renamed in pairs(renames) do
    local _, keeper = parkedItemFor(id)      -- a slot with no live instance still holds its name
    if keeper then writeTakeName(keeper, renamed) end
  end
  invalidate()
end

--contract: forever-deletes the slot: every live instance + the parked keeper; returns live count
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
  local parked = parkedItemFor(entry.id)
  if parked then reaper.DeleteTrackMediaItem(select(2, scratch.peek()), parked) end
  if entry.kind == 'midi' then eventMeta:dropPool(entry.id) end
  ensureSlots(track)    -- prune the orphaned dict entry now; non-render readers see it gone at once
  invalidate()
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

-- REAPER keys undo bookkeeping by item GUID: a clone replaying srcItem's IGUID is
-- invisible to undo capture (dirty marks resolve to the original), so edits on it never rewind.
local function chunkFreshGuids(chunk)
  return (chunk
    :gsub('(IGUID%s+){[^}]+}',      function(pre) return pre .. reaper.genGuid('') end)
    :gsub('(%f[%w]GUID%s+){[^}]+}', function(pre) return pre .. reaper.genGuid('') end))
end

local function harvestPoolGuid(item)
  local ok, chunk = reaper.GetItemStateChunk(item, '', false)
  if not ok or not chunk then return end
  return chunk:match('POOLEDEVTS%s+({[^}]+})')
end

local function setTakeName(take, name)
  if take and name and name ~= '' then writeTakeName(take, name) end
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
    if freshGuid then
      chunk = chunkSetPool(srcChunk, freshGuid)
      eventMeta:copyPool(harvestPoolGuid(srcItem), freshGuid)   -- fresh pool: fork metadata
    end
  end
  reaper.SetItemStateChunk(newItem, chunkFreshGuids(chunk), false)
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
--invariant: overwrites any take already starting at qnPos; create never stacks (matches dropInstance).
function am:createAndDropMidi(trackIdx, qnPos, lengthQN, name)
  local track   = visibleTrackOfCol(trackIdx)
  local dict    = track and readSlots(track)
  local slotIdx = dict and nextFreeSlot(dict)
  if not slotIdx then return end

  -- Captured before placing: the new take starts at qnPos too, so it must not be in this list.
  local occupants = {}
  for _, other in ipairs(am:tracksTakes(trackIdx)) do
    if other.startQN == qnPos then util.add(occupants, other) end
  end

  local item = reaper.CreateNewMIDIItemInProj(track, qnPos, qnPos + lengthQN, true)
  local take = item and reaper.GetActiveTake(item)
  local guid = take and harvestPoolGuid(item)
  if not guid then return end

  dict[slotIdx] = { kind = 'midi', id = guid }
  writeSlots(track, dict)
  if name and name ~= '' then
    reaper.GetSetMediaItemTakeInfo_String(take, 'P_NAME', name, true)
  end
  for _, old in ipairs(occupants) do am:deleteTake(old) end
  stampForTake(take)
  relayoutTrack(track)
  return slotIdx, take
end

-- First instance matching id: item, length, name — what a fresh drop inherits.
-- Falls back to the parked keeper so drops from emptied slots re-materialise.
local function siblingInstance(track, id)
  local sibItem = forEachActiveTake(track, function(take, item)
    if takeIdOf(take) == id then return item end
  end) or parkedItemFor(id)
  if not sibItem then return end
  return sibItem,
         select(2, itemQNRange(sibItem)),
         reaper.GetTakeName(reaper.GetActiveTake(sibItem)) or ''
end

--contract: live-or-parked MIDI take for slot slotIdx on trackIdx; nil if no track/slot/instance
function am:takeForSlot(trackIdx, slotIdx)
  local track = visibleTrackOfCol(trackIdx)
  if not track or not slotIdx then return end
  local entry = readSlots(track)[slotIdx]
  if not entry or entry.kind ~= 'midi' or not entry.id then return end
  local sibItem = siblingInstance(track, entry.id)
  return sibItem and reaper.GetActiveTake(sibItem)
end

function am:trackHandle(trackIdx) return visibleTrackOfCol(trackIdx) end

--contract: true iff take's host is the scratch track (its slot's only instance is parked)
function am:isParkedTake(take)
  if not take then return false end
  local _, scratchTrack = scratch.peek()
  return scratchTrack ~= nil and reaper.GetMediaItemTake_Track(take) == scratchTrack
end

--contract: visible-column index of the track carrying this GUID; nil if it is gone
function am:trackIdxForGuid(guid)
  if not guid then return end
  for _, tr in ipairs(am:projectTracks()) do
    if tr.guid == guid then return tr.idx end
  end
end

--contract: instance of slot at qnPos; nil if track/slot missing (MIDI also requires a live sibling)
--invariant: overwrites any take already starting at qnPos; drop never stacks (matches startIsClear).
function am:dropInstance(trackIdx, slotIdx, qnPos, lengthQN)
  local track = visibleTrackOfCol(trackIdx)
  if not track then return end
  local entry = readSlots(track)[slotIdx]
  if not entry or not entry.id then return end
  local sibItem, sibLen, sibName = siblingInstance(track, entry.id)
  local len = lengthQN or sibLen or 1

  -- Captured before placing: the new take starts at qnPos too, so it must not
  -- be in this list; for MIDI it also keeps the clone source alive until cloned.
  local occupants = {}
  for _, other in ipairs(am:tracksTakes(trackIdx)) do
    if other.startQN == qnPos then util.add(occupants, other) end
  end

  local take
  if entry.kind == 'midi' then
    if not sibItem then return end
    if reaper.GetMediaItem_Track(sibItem) ~= track then
      -- Unpark by moving: a clone would pool across tracks, which breaks undo
      -- restore for consecutive edits. See docs/arrangeManager.md § Pools never span tracks.
      reaper.MoveMediaItemToTrack(sibItem, track)
      setItemQNRange(sibItem, qnPos, qnPos + len)
      take = reaper.GetActiveTake(sibItem)
    else
      take = cloneMidiItem(track, sibItem, qnPos, len, false)
    end
  else
    take = placeAudio(track, entry.id, qnPos, len)
  end
  if not take then return end
  setTakeName(take, sibName)

  for _, old in ipairs(occupants) do am:deleteTake(old) end
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

-- Where a take appends: its rendered end, so a copy starts where the sound stops rather than
-- where the intent does. See docs/arrangeManager.md § The append point.
local function appendPoint(take) return take.startQN + take.lengthQN end

-- A copy has to fit whole: a shorter free span renders it truncated by its neighbour, which
-- is a different sound from the one being copied.
local function roomBelow(take, lengthQN)
  return am:freeSpan(take.trackIdx, appendPoint(take)) >= lengthQN
end

-- An unpooled clone's fresh pool takes its slot at the next build, so the slot is read back
-- off the placed take rather than allocated here.
local function slotOfPlacedTake(trackIdx, take)
  for _, other in ipairs(am:tracksTakes(trackIdx)) do
    if other.take == take then return other.slotIdx end
  end
end

--contract: pooled clone at the append point; nil iff non-MIDI or the free span falls short.
function am:duplicateBelow(take)
  if take.kind ~= 'midi' then return end
  if not roomBelow(take, take.naturalLenQN) then return end
  return am:duplicateTake(take, appendPoint(take))
end

--contract: (slotIdx, take) for an unpooled clone at the append point; nil iff non-MIDI/no slot.
--invariant: parks the clone on scratch for want of room -- the palette grows either way.
function am:duplicateUnpooledBelow(take)
  if take.kind ~= 'midi' then return end
  if not roomBelow(take, take.naturalLenQN) then return am:mintParkedTake(take.trackIdx, '', nil, take.take) end
  local track = visibleTrackOfCol(take.trackIdx)
  local newTake = cloneMidiItem(track, take.item, appendPoint(take), take.naturalLenQN, true)
  if not newTake then return end
  setTakeName(newTake, take.name)
  stampForTake(newTake)
  relayoutTrack(track)
  return slotOfPlacedTake(take.trackIdx, newTake), newTake
end

--contract: (slotIdx, take) for an empty lengthQN take named `name` below take; nil iff non-MIDI
--invariant: parks the take on scratch for want of room -- the palette grows either way.
-- The length is the caller's, not the source's: room is measured against what is being made.
function am:newTakeBelow(take, name, lengthQN)
  if take.kind ~= 'midi' then return end
  if not roomBelow(take, lengthQN) then return am:mintParkedTake(take.trackIdx, name, lengthQN) end
  return am:createAndDropMidi(take.trackIdx, appendPoint(take), lengthQN, name)
end

--contract: mints a slot on trackIdx parked on scratch; (slotIdx, take), nil if no track/free slot
-- srcTake → clone its events + natural length into a fresh unpooled pool; else an empty take of lengthQN.
function am:mintParkedTake(trackIdx, name, lengthQN, srcTake)
  local track   = visibleTrackOfCol(trackIdx)
  local dict    = track and readSlots(track)
  local slotIdx = dict and nextFreeSlot(dict)
  if not slotIdx then return end

  local len = lengthQN
  if srcTake then
    len = effectiveNaturalLenQN(srcTake, reaper.GetMediaItemTake_Item(srcTake))
  end
  local item = reaper.CreateNewMIDIItemInProj(scratch.track(), 0, len, true)
  local take = item and reaper.GetActiveTake(item)
  local guid = take and harvestPoolGuid(item)
  if not guid then return end
  if srcTake then
    copyMidiEvents(srcTake, take)
    eventMeta:copyPool(takeIdOf(srcTake), guid)   -- fresh pool: fork the source's metadata
    if name == '' then name = reaper.GetTakeName(srcTake) or '' end
  end

  dict[slotIdx] = { kind = 'midi', id = guid }
  writeSlots(track, dict)
  setTakeName(take, name)
  stampForTake(take)
  invalidate()                  -- the slot palette cache must see the new parked slot at once
  return slotIdx, take
end

----- Variants

-- Next name in the family: the highest ordinal in use plus one, so a deleted
-- variant keeps its name out of circulation. See docs/arrangeManager.md § Variants.
local function nextVariantName(trackIdx, name)
  local root    = util.variantRoot(name)
  local highest = 0
  for _, slot in ipairs(am:trackSlots(trackIdx)) do
    local slotRoot, ordinal = util.variantRoot(slot.name)
    if slotRoot == root and ordinal and ordinal > highest then highest = ordinal end
  end
  return ('%s (var %d)'):format(root, highest + 1)
end

local function liveInstances(trackIdx, slotIdx)
  local n = 0
  for _, other in ipairs(am:tracksTakes(trackIdx)) do
    if other.slotIdx == slotIdx then n = n + 1 end
  end
  return n
end

--contract: (slotIdx, take) for a variant slot in take's place; nil iff non-MIDI or lone instance
function am:vary(take)
  if take.kind ~= 'midi' then return end
  if liveInstances(take.trackIdx, take.slotIdx) < 2 then return end
  local trackIdx, startQN = take.trackIdx, take.startQN
  local slotIdx = am:mintParkedTake(trackIdx, nextVariantName(trackIdx, take.name), nil, take.take)
  if not slotIdx then return end
  am:deleteTake(take)
  return slotIdx, am:dropInstance(trackIdx, slotIdx, startQN)
end

----- Per-take edits

--contract: QN from startQN to the next take start on trackIdx; math.huge with nothing downstream
function am:freeSpan(trackIdx, startQN)
  local nextStart = math.huge
  for _, other in ipairs(am:tracksTakes(trackIdx)) do
    if other.startQN >= startQN and other.startQN < nextStart then nextStart = other.startQN end
  end
  return nextStart - startQN
end

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

-- Deleting a slot's last live instance parks it on the scratch track (keeping
-- the pool + slot alive) rather than GC-ing it. See docs § Parking.
function am:deleteTake(take)
  local track = visibleTrackOfCol(take.trackIdx)
  if not track then return end
  local id = takeIdOf(take.take)
  if id and isLastInstanceOnTrack(track, id, take.item) and not parkedItemFor(id) then
    reaper.MoveMediaItemToTrack(take.item, scratch.track())
  else
    reaper.DeleteTrackMediaItem(track, take.item)
  end
  relayoutTrack(track)
end

----- Reswing (folded from sequenceManager)

local function projectMidiTakes()
  local takes = {}
  for ti = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, ti)
    if isVisibleTrack(track) then
      forEachActiveTake(track, function(take)
        if reaper.TakeIsMIDI(take) then util.add(takes, take) end
      end)
    end
  end
  return takes
end

--contract: scans each take's swing map (ds) for the named swing; no mm/cm context disturbance
function am:takesUsing(name)
  local hits = {}
  for _, take in ipairs(projectMidiTakes()) do
    local sw = ds:getAt(take, 'swing')
    if sw then
      for _, used in pairs(sw) do
        if used == name then util.add(hits, take); break end
      end
    end
  end
  return hits
end

--contract: temper names referenced by any project take/track tier or project scalar, minus 12EDO
function am:tempersInUse()
  local inUse = {}
  local function note(name) if name and name ~= '12EDO' then inUse[name] = true end end
  note(cm:getAt('project', 'temper'))
  for _, take in ipairs(projectMidiTakes()) do note(cm:valueFor(take, 'take', 'temper')) end
  for ti = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, ti)
    if isVisibleTrack(track) then note(cm:valueFor(track, 'track', 'temper')) end
  end
  return inUse
end

--contract: hands takesUsing(name) to the 'tracker' facade; transient-rebinds each and restores
function am:reswingAll(name)
  facade.get('tracker').reswingTakes(am:takesUsing(name))
end

return am
