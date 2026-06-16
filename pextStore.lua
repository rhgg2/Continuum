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
local SCRIPT_PATH = debug.getinfo(1,'S').source:match[[^@?(.*[\/])[^\/]-$]]
local GLOBAL_PATH = SCRIPT_PATH .. 'ctm_cfg.txt'

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
    local f = io.open(GLOBAL_PATH, 'r')
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
    local f = io.open(GLOBAL_PATH, 'w')
    if not f then print('Error! Could not write ' .. GLOBAL_PATH); return end
    f:write(raw)
    f:close()
  else
    error('pextStore: unknown scope ' .. tostring(scope))
  end
end

-- Stage 2 stores every scope in the compact wire format. Commit B switches
-- the global disk backend to the hand-editable Lua-literal format.
local function decode(raw)
  if not raw or raw == '' then return nil end
  local ok, value = pcall(util.unserialise, raw)
  if ok then return value end
  return nil
end

local function encode(value)
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

----- Context

--contract: setTake(nil) clears take+track; setTake(take) derives track via GetMediaItemTrack; resnapshots baselines
function ps:setTake(newTake)
  take = newTake
  track = nil
  if take then
    local item = reaper.GetMediaItemTake_Item(take)
    if item then track = reaper.GetMediaItemTrack(item) end
  end
  snapshotBaseline()
end

function ps:clearTake()
  take = nil
  snapshotBaseline()
end

function ps:setTrack(newTrack)
  track = newTrack
  snapshotBaseline()
end

function ps:boundTake()  return take  end
function ps:boundTrack() return track end

----- Storage

--contract: returns the decoded value at (scope, slot) under bound context; nil if absent or undecodable
function ps:get(scope, slot)           return decode(readRaw(scope, slot))         end
function ps:getAt(handle, scope, slot) return decode(readRaw(scope, slot, handle)) end

-- Reads the undecoded blob — for callers that diff bytes against a saved copy.
function ps:getRawAt(handle, scope, slot) return readRaw(scope, slot, handle) end

--contract: serialises value into (scope, slot) under bound context; refreshes the watcher baseline if watched
function ps:assign(scope, slot, value)
  local raw = encode(value)
  writeRaw(scope, slot, raw)
  local key = scope .. '/' .. slot
  if baseline[key] ~= nil then baseline[key] = raw end
end

-- Foreign-handle write: bypasses bound context and never touches the baseline.
function ps:assignAt(handle, scope, slot, value)
  writeRaw(scope, slot, encode(value), handle)
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
