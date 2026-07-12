-- See docs/pextStore.md for the model.

--invariant: single source of bound take/track context, shared by every face; setTake derives track from the take's item
--invariant: watcher baselines refresh on bound writes (assign) and context changes; foreign assignAt leaves them stale
--invariant: a stale take/track ptr is dropped (handle→nil, its baselines→'') before any read on a poll tick
--contract: get/assign (de)serialise by scope; no schema prune — each face owns its own key registry
--reaper: take/track P_EXT via GetSetMedia{ItemTake,Track}Info_String; project via Get/SetProjExtState; global via io
--invariant: undoable project slots mirror to scratch P_EXT (two-level hash manifest); rest don't
local util = require 'util'
local scratch = require 'scratch'

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

----------- PROJEXT UNDO MIRROR

-- REAPER undo rewinds the scratch chunk but not projext; undoable project slots
-- write both, and pollUndo copies rewound mirrors back — docs/pextStore.md § Mirror.

local MIRROR_BUCKETS = 64

local undoableSlots, undoablePrefixes = {}, {}

local function isUndoable(slot)
  if undoableSlots[slot] then return true end
  for _, prefix in ipairs(undoablePrefixes) do
    if slot:sub(1, #prefix) == prefix then return true end
  end
  return false
end

-- Scratch P_EXT keys, namespaced to mark ownership (rm's fx-meta mirrors share
-- the track): s.<slot> mirrored raw, m.<b> bucket manifest, root watermark.
local function mirrorKey(name) return 'P_EXT:ctm_ps.' .. name end

local function mirrorRead(strack, name)
  local _, v = reaper.GetSetMediaTrackInfo_String(strack, mirrorKey(name), '', false)
  return v or ''
end

local function mirrorWrite(strack, name, raw)
  reaper.GetSetMediaTrackInfo_String(strack, mirrorKey(name), raw, true)
end

local function decodeMirror(raw)
  if raw == '' then return {} end
  local ok, v = pcall(util.unserialise, raw)
  return (ok and type(v) == 'table') and v or {}
end

local function bucketOf(slot) return util.hash(slot) % MIRROR_BUCKETS end

--shape: mirror = { guid, buckets = { [b] = { [slot] = hash } }, manifestHash = { [b] = hash }, rootRaw }
-- The expected state: what scratch looks like after our own writes. nil until
-- seeded; seeded once from root + manifests (~65 small reads), never the slots.
local mirror = nil

local function seedMirror()
  local guid, strack = scratch.peek()
  mirror = { guid = guid, strack = strack, buckets = {}, manifestHash = {}, rootRaw = '' }
  if not strack then return end
  mirror.rootRaw = mirrorRead(strack, 'root')
  mirror.manifestHash = decodeMirror(mirror.rootRaw)
  for b in pairs(mirror.manifestHash) do
    mirror.buckets[b] = decodeMirror(mirrorRead(strack, 'm.' .. b))
  end
end

-- Persist one bucket's manifest + the root, merge-reading the root first: a second
-- engine (patternEditor) writes this mirror too, and adopting the merge covers it too.
local function writeBucketAndRoot(strack, b, set)
  local manifestRaw = next(set) and util.serialise(set) or ''
  mirror.buckets[b] = next(set) and set or nil
  mirrorWrite(strack, 'm.' .. b, manifestRaw)
  local root = decodeMirror(mirrorRead(strack, 'root'))
  root[b] = manifestRaw ~= '' and util.hash(manifestRaw) or nil
  mirror.manifestHash = root
  mirror.rootRaw = next(root) and util.serialise(root) or ''
  mirrorWrite(strack, 'root', mirror.rootRaw)
end

local function knownSlots()
  local known = {}
  for _, set in pairs(mirror.buckets) do
    for slot in pairs(set) do known[#known + 1] = slot end
  end
  return known
end

-- Replay slots the mirror lacks, from projext (current-project truth). Reached on
-- any scratch change (re-mint, switch, other engine); a switch just replays nothing.
local function remirrorMissing(strack, slots)
  local touched = {}
  for _, slot in ipairs(slots) do
    local b = bucketOf(slot)
    local set = mirror.buckets[b]
    if not (set and set[slot]) then
      local raw = readRaw('project', slot)
      if raw ~= '' then
        mirrorWrite(strack, 's.' .. slot, raw)
        if not set then set = {}; mirror.buckets[b] = set end
        set[slot] = util.hash(raw)
        touched[b] = true
      end
    end
  end
  for b in pairs(touched) do writeBucketAndRoot(strack, b, mirror.buckets[b]) end
end

-- Resolve the live scratch handle; guid is re-checked even when ValidatePtr2 passes
-- (REAPER reuses freed pointers) — see docs/pextStore.md § Guid changes.
local function ensureScratch()
  if mirror.strack and reaper.ValidatePtr2
     and reaper.ValidatePtr2(0, mirror.strack, 'MediaTrack*')
     and reaper.GetTrackGUID(mirror.strack) == mirror.guid then
    return mirror.strack
  end
  mirror.strack = nil
  local guid, strack = scratch.peek()
  if not strack then return nil end
  if guid ~= mirror.guid then
    local known = knownSlots()
    seedMirror()
    remirrorMissing(strack, known)
  end
  mirror.strack = strack
  return strack
end

-- The mirror half of an undoable project write: slot raw + its bucket manifest
-- + root. The bucket is merge-read for the same second-writer reason as the root.
local function mirrorAssign(slot, raw)
  if not mirror then seedMirror() end
  local strack = ensureScratch()
  if not strack then
    -- A removal with no scratch mirrors nothing: don't mint a track to record
    -- it. Stale bookkeeping self-heals at the next real write's remirror.
    if raw == '' then return end
    local known = knownSlots()
    strack = scratch.track()
    seedMirror()
    remirrorMissing(strack, known)
  end
  mirrorWrite(strack, 's.' .. slot, raw)
  local b = bucketOf(slot)
  local set = decodeMirror(mirrorRead(strack, 'm.' .. b))
  if raw == '' then set[slot] = nil else set[slot] = util.hash(raw) end
  writeBucketAndRoot(strack, b, set)
end

-- Undo rewound the scratch chunk: walk root → buckets → slots, copying back only
-- genuine diffs from projext. Adopts state as expected before the caller fires.
local function resyncMirror()
  if not mirror then seedMirror(); return end
  local prevGuid = mirror.guid
  local strack = ensureScratch()
  if not strack then return end                    -- deleted: the next write re-mints
  if mirror.guid ~= prevGuid then return end       -- re-mint/switch absorbed; not a rewind
  local rootRaw = mirrorRead(strack, 'root')
  if rootRaw == mirror.rootRaw then return end
  local actualRoot = decodeMirror(rootRaw)
  local buckets = {}
  for b in pairs(actualRoot) do buckets[b] = true end
  for b in pairs(mirror.manifestHash) do buckets[b] = true end
  local candidates = {}
  for b in pairs(buckets) do
    if actualRoot[b] ~= mirror.manifestHash[b] then
      local actual   = decodeMirror(mirrorRead(strack, 'm.' .. b))
      local expected = mirror.buckets[b] or {}
      local slots = {}
      for slot in pairs(actual)   do slots[slot] = true end
      for slot in pairs(expected) do slots[slot] = true end
      for slot in pairs(slots) do
        if actual[slot] ~= expected[slot] then candidates[#candidates + 1] = slot end
      end
      mirror.buckets[b] = next(actual) and actual or nil
    end
  end
  mirror.manifestHash = actualRoot
  mirror.rootRaw = rootRaw
  local diverged = {}
  for _, slot in ipairs(candidates) do
    -- Load-bearing filter, not an optimisation: adoption/merge can leave
    -- expected buckets stale, inflating candidates; only a genuine diff copies.
    local raw = mirrorRead(strack, 's.' .. slot)
    if raw ~= readRaw('project', slot) then
      reaper.SetProjExtState(0, PROJEXT_SECTION, slot, raw)   -- direct: must not re-mirror
      diverged[#diverged + 1] = slot
    end
  end
  if #diverged > 0 then return diverged end
end

local function writeRaw(scope, slot, raw, handle)
  if scope == 'take' then
    reaper.GetSetMediaItemTakeInfo_String(handle or take, 'P_EXT:' .. slot, raw, true)
  elseif scope == 'track' then
    reaper.GetSetMediaTrackInfo_String(handle or track, 'P_EXT:' .. slot, raw, true)
  elseif scope == 'project' then
    reaper.SetProjExtState(0, PROJEXT_SECTION, slot, raw)
    if isUndoable(slot) then mirrorAssign(slot, raw) end
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

--contract: declared project slots mirror to scratch and rewind with undo; others stay projext-only
function ps:declareUndoable(spec)
  for _, slot in ipairs(spec.slots or {}) do undoableSlots[slot] = true end
  for _, prefix in ipairs(spec.prefixes or {}) do
    undoablePrefixes[#undoablePrefixes + 1] = prefix
  end
end

--contract: blobs = { { scope, slot }, ... }; onDiverge(divergedBlobs) fires once per poll tick that diverges
function ps:watch(blobs, onDiverge)
  watchGroups[#watchGroups + 1] = { blobs = blobs, onDiverge = onDiverge }
  for _, blob in ipairs(blobs) do
    baseline[blobKey(blob)] = readRaw(blob.scope, blob.slot)
  end
end

--invariant: polls project state count per frame; on tick re-reads watched blobs, fires diverged groups once each
--invariant: mirror resync runs before the watch groups, so a rewound blob diverges same tick
--contract: no-op without GetProjectStateChangeCount (test harness); one int compare per frame otherwise
--emits: projectRewound -- [slot, ...]; undo rewound these mirrored slots (already copied back)
function ps:pollUndo()
  if not reaper.GetProjectStateChangeCount then return end
  local count = reaper.GetProjectStateChangeCount(0)
  if count == lastStateCount then return end
  lastStateCount = count
  dropStale()
  local rewound = resyncMirror()
  if rewound then fire('projectRewound', rewound) end
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
