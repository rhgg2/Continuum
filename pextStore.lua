-- See docs/pextStore.md for the model.

--invariant: single source of bound take/track context, shared by every face; setTake derives track from the take's item
--invariant: watcher baselines refresh on bound writes (assign) and context changes; foreign assignAt leaves them stale
--invariant: a stale take/track ptr is dropped (handle→nil, its baselines→'') before any read on a poll tick
--contract: get/assign (de)serialise by scope; no schema prune — each face owns its own key registry
--reaper: take/track P_EXT via GetSetMedia{ItemTake,Track}Info_String; project via Get/SetProjExtState; global via io
local util = require 'util'

local function print(...)
  return util.print(...)
end

----------- PRIVATE STATE

local PROJEXT_SECTION = 'rdm'

-- Global blobs are disk files in the resource dir, one per slot: 'config' ->
-- continuum-config.lua, 'data' -> continuum-data.lua. Lazy so load needs no reaper.
local function globalPath(slot)
  return reaper.GetResourcePath() .. '/continuum-' .. slot .. '.lua'
end

-- Per-slot lock: a global file that fails to parse must not be clobbered by the
-- next save, so writes to it are refused until it reads clean. Keyed by slot.
local globalLocked = {}

local take, track = nil, nil

-- External-mutation watcher: REAPER undo/redo rewrites P_EXT without notifying us. pollUndo
-- compares the project state count once per frame and re-reads watched blobs on a tick.
local lastStateCount = -1
local baseline    = {}   -- [scope/slot] = last-seen raw string (watched blobs only)
local watchGroups = {}   -- { { blobs = { { scope, slot }, ... }, onDiverge = fn }, ... }

----------- RAW BACKEND I/O

local function takeRaw(handle, slot)
  if not handle then return '' end
  local _, v = reaper.GetSetMediaItemTakeInfo_String(handle, 'P_EXT:' .. slot, '', false)
  return v or ''
end

local function trackRaw(handle, slot)
  if not handle then return '' end
  local _, v = reaper.GetSetMediaTrackInfo_String(handle, 'P_EXT:' .. slot, '', false)
  return v or ''
end

-- handle overrides the bound context (foreign-handle reads); scope picks the backend.
local function readRaw(scope, slot, handle)
  if scope == 'take'  then return takeRaw(handle or take, slot)   end
  if scope == 'track' then return trackRaw(handle or track, slot) end
  if scope == 'project' then
    local ok, v = reaper.GetProjExtState(0, PROJEXT_SECTION, slot)
    return (ok and v) or ''
  end
  if scope == 'global' then
    local f = io.open(globalPath(slot), 'r')
    if not f then return '' end
    local content = f:read('*a')
    f:close()
    return content or ''
  end
  error('pextStore: unknown scope ' .. tostring(scope))
end

local function writeRaw(scope, slot, raw, handle)
  if scope == 'take' then
    reaper.GetSetMediaItemTakeInfo_String(handle or take, 'P_EXT:' .. slot, raw, true)
  elseif scope == 'track' then
    reaper.GetSetMediaTrackInfo_String(handle or track, 'P_EXT:' .. slot, raw, true)
  elseif scope == 'project' then
    reaper.SetProjExtState(0, PROJEXT_SECTION, slot, raw)
  elseif scope == 'global' then
    if globalLocked[slot] then
      print('Error! Refusing to overwrite unreadable ' .. globalPath(slot) .. '; fix or delete it.')
      return
    end
    local f = io.open(globalPath(slot), 'w')
    if not f then print('Error! Could not write ' .. globalPath(slot)); return end
    f:write(raw)
    f:close()
  else
    error('pextStore: unknown scope ' .. tostring(scope))
  end
end

-- Format by backend: global -> hand-editable Lua literal, P_EXT/projext ->
-- compact wire. A bad global parse locks writes. See docs/pextStore.md § Formats.
local function decode(scope, slot, raw)
  if not raw or raw == '' then
    if scope == 'global' then globalLocked[slot] = nil end
    return nil
  end
  if scope == 'global' then
    local value, err = util.prettyUnserialise(raw)
    if err then
      globalLocked[slot] = true
      print('Error! ' .. globalPath(slot) .. ' is unreadable: ' .. tostring(err)
            .. ' -- refusing to overwrite. Fix or delete it.')
      return nil
    end
    globalLocked[slot] = nil
    return value
  end
  local ok, value = pcall(util.unserialise, raw)
  return ok and value or nil
end

local function encode(scope, value)
  if scope == 'global' then return util.prettySerialise(value) end
  return util.serialise(value)
end

----------- WATCHER

local function blobKey(blob) return blob.scope .. '/' .. blob.slot end

local function snapshotBaseline()
  lastStateCount = reaper.GetProjectStateChangeCount
                   and reaper.GetProjectStateChangeCount(0) or -1
  for _, group in ipairs(watchGroups) do
    for _, blob in ipairs(group.blobs) do
      baseline[blobKey(blob)] = readRaw(blob.scope, blob.slot)
    end
  end
end

-- A dropped handle's watched blobs read as '' on the next poll; zeroing their
-- baselines to match keeps that drop from registering as an external diff.
local function zeroBaselines(scope)
  for _, group in ipairs(watchGroups) do
    for _, blob in ipairs(group.blobs) do
      if blob.scope == scope then baseline[blobKey(blob)] = '' end
    end
  end
end

local function dropStale()
  if take and reaper.ValidatePtr2
     and not reaper.ValidatePtr2(0, take, 'MediaItem_Take*') then
    take = nil
    zeroBaselines('take')
  end
  if track and reaper.ValidatePtr2
     and not reaper.ValidatePtr2(0, track, 'MediaTrack*') then
    track = nil
    zeroBaselines('track')
  end
end

----------- PUBLIC INTERFACE

local ps = {}
local fire = util.installHooks(ps)

----- Context

--contract: setTake(nil) clears take+track; setTake(take) derives track via GetMediaItemTrack; resnapshots baselines
--emits: contextChanged -- {} on every context change so faces drop+reload their scope caches
function ps:setTake(newTake)
  take = newTake
  track = nil
  if take then
    local item = reaper.GetMediaItemTake_Item(take)
    if item then track = reaper.GetMediaItemTrack(item) end
  end
  snapshotBaseline()
  fire('contextChanged', {})
end

function ps:clearTake()
  take = nil
  snapshotBaseline()
  fire('contextChanged', {})
end

function ps:setTrack(newTrack)
  track = newTrack
  snapshotBaseline()
  fire('contextChanged', {})
end

function ps:boundTake()  return take  end
function ps:boundTrack() return track end

----- Storage

--contract: returns the decoded value at (scope, slot) under bound context; nil if absent or undecodable
function ps:get(scope, slot)           return decode(scope, slot, readRaw(scope, slot))         end
function ps:getAt(handle, scope, slot) return decode(scope, slot, readRaw(scope, slot, handle)) end

--contract: writes value at (scope, slot); util.REMOVE clears; refreshes watcher baseline if watched
function ps:assign(scope, slot, value)
  local raw = value == util.REMOVE and '' or encode(scope, value)
  writeRaw(scope, slot, raw)
  local key = scope .. '/' .. slot
  if baseline[key] ~= nil then baseline[key] = raw end
end

-- Foreign-handle write: bypasses bound context and never touches the baseline.
function ps:assignAt(handle, scope, slot, value)
  writeRaw(scope, slot, value == util.REMOVE and '' or encode(scope, value), handle)
end

----- Watcher

--contract: blobs = { { scope, slot }, ... }; onDiverge(divergedBlobs) fires once per poll tick that diverges
function ps:watch(blobs, onDiverge)
  watchGroups[#watchGroups + 1] = { blobs = blobs, onDiverge = onDiverge }
  for _, blob in ipairs(blobs) do
    baseline[blobKey(blob)] = readRaw(blob.scope, blob.slot)
  end
end

--invariant: polls project state count per frame; on tick re-reads watched blobs, fires diverged groups once each
--contract: no-op without GetProjectStateChangeCount (test harness); one int compare per frame otherwise
function ps:pollUndo()
  if not reaper.GetProjectStateChangeCount then return end
  local count = reaper.GetProjectStateChangeCount(0)
  if count == lastStateCount then return end
  lastStateCount = count
  dropStale()
  for _, group in ipairs(watchGroups) do
    local diverged = {}
    for _, blob in ipairs(group.blobs) do
      local key = blobKey(blob)
      local raw = readRaw(blob.scope, blob.slot)
      if raw ~= baseline[key] then
        baseline[key] = raw
        diverged[#diverged + 1] = blob
      end
    end
    if #diverged > 0 then group.onDiverge(diverged) end
  end
end

return ps
