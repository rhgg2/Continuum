-- See docs/eventMeta.md for the model.

--invariant: per-event metadata keyed by POOL guid, not take — every pooled instance shares one blob
--invariant: 'ctm.<guid>.' slots: kb=bucket index, keys.<b>=bucket uuidTxt set, u.<uuidTxt>=fields
--invariant: stores opaque field tables; the strip (which fields are metadata) is mm's, never inspected here
--contract: a nil guid is a no-op/empty everywhere — a take with no derivable pool carries no persisted metadata
local util = require 'util'
local perf = require 'perf'

local ps   = (...).ps

local BUCKET = 256   -- uuids per key bucket; a uuid birth/death rewrites one bucket, not the pool

local function kbSlot(guid)             return 'ctm.' .. guid .. '.kb'         end
local function bucketSlot(guid, b)      return 'ctm.' .. guid .. '.keys.' .. b end
local function entrySlot(guid, uuidTxt) return 'ctm.' .. guid .. '.u.' .. uuidTxt end

-- The loader's index (projext has no enumerate-by-prefix), bucketed so flush never
-- reserialises the whole uuid set. Cached; load() re-syncs. See docs/eventMeta.md § Keyset cache.
local keysCache = {}
local function readIndex(guid)
  local cached = keysCache[guid]
  if cached then return cached end
  local buckets, byBucket = ps:get('project', kbSlot(guid)) or {}, {}
  for b in pairs(buckets) do
    byBucket[b] = ps:get('project', bucketSlot(guid, b)) or {}
  end
  local index = { buckets = buckets, byBucket = byBucket }
  keysCache[guid] = index
  return index
end

-- Persist one bucket (an emptied bucket removes its slot); true when the bucket was
-- born or died, i.e. the kb index itself needs rewriting.
local function writeBucket(guid, index, b)
  local set = index.byBucket[b]
  if next(set) then
    ps:assign('project', bucketSlot(guid, b), set)
    if not index.buckets[b] then index.buckets[b] = true; return true end
  else
    ps:assign('project', bucketSlot(guid, b), util.REMOVE)
    index.byBucket[b] = nil
    if index.buckets[b] then index.buckets[b] = nil; return true end
  end
end

local function writeKb(guid, index)
  ps:assign('project', kbSlot(guid), next(index.buckets) and index.buckets or util.REMOVE)
end

local eventMeta = {}

--contract: { [uuid:int] = fields }; empty table if the guid has no metadata
function eventMeta:load(guid)
  if not guid then return {} end
  keysCache[guid] = nil                       -- re-sync from projext (absorbs external undo/redo)
  local out = {}
  for _, set in pairs(readIndex(guid).byBucket) do
    for uuidTxt in pairs(set) do
      local fields = ps:get('project', entrySlot(guid, uuidTxt))
      if fields then out[util.fromBase36(uuidTxt)] = fields end
    end
  end
  return out
end

--contract: batched incremental persist: applies dirty={[uuid]=fields} + deleted={[uuid]=true}
--contract: per-modify hot path: entry writes plus touched-bucket writes, never the whole set
function eventMeta:flush(guid, dirty, deleted)
  if not guid then return end
  local index, touched = readIndex(guid), {}
  perf.start('entries')
  for uuid, fields in pairs(dirty) do
    local uuidTxt = util.toBase36(uuid)
    ps:assign('project', entrySlot(guid, uuidTxt), fields)
    local b   = uuid // BUCKET
    local set = index.byBucket[b]
    if not set then set = {}; index.byBucket[b] = set end
    if not set[uuidTxt] then set[uuidTxt] = true; touched[b] = true end
  end
  for uuid in pairs(deleted) do
    local uuidTxt = util.toBase36(uuid)
    ps:assign('project', entrySlot(guid, uuidTxt), util.REMOVE)
    local b   = uuid // BUCKET
    local set = index.byBucket[b]
    if set and set[uuidTxt] then set[uuidTxt] = nil; touched[b] = true end
  end
  perf.stop('entries')
  perf.start('keys')
  local kbChanged = false
  for b in pairs(touched) do
    if writeBucket(guid, index, b) then kbChanged = true end
  end
  if kbChanged then writeKb(guid, index) end
  perf.stop('keys')
end

--contract: replaces the pool's whole metadata with byUuid={[uuid]=fields}; sweeps uuids no longer present
function eventMeta:saveAll(guid, byUuid)
  if not guid then return end
  local old, byBucket = readIndex(guid), {}
  for uuid, fields in pairs(byUuid) do
    local uuidTxt = util.toBase36(uuid)
    ps:assign('project', entrySlot(guid, uuidTxt), fields)
    local b   = uuid // BUCKET
    local set = byBucket[b]
    if not set then set = {}; byBucket[b] = set end
    set[uuidTxt] = true
  end
  for b, oldSet in pairs(old.byBucket) do
    local newSet = byBucket[b]
    for uuidTxt in pairs(oldSet) do
      if not (newSet and newSet[uuidTxt]) then ps:assign('project', entrySlot(guid, uuidTxt), util.REMOVE) end
    end
    if not newSet then ps:assign('project', bucketSlot(guid, b), util.REMOVE) end
  end
  local index = { buckets = {}, byBucket = byBucket }
  for b, set in pairs(byBucket) do
    index.buckets[b] = true
    ps:assign('project', bucketSlot(guid, b), set)
  end
  writeKb(guid, index)
  keysCache[guid] = index
end

--contract: forks srcGuid's metadata onto dstGuid (an unpooled clone mints a fresh pool; this seeds it)
function eventMeta:copyPool(srcGuid, dstGuid)
  if not (srcGuid and dstGuid) then return end
  self:saveAll(dstGuid, self:load(srcGuid))
end

--contract: forever-deletes a pool's metadata (deleteSlot's keeper removal)
function eventMeta:dropPool(guid)
  if not guid then return end
  local index = readIndex(guid)
  for b, set in pairs(index.byBucket) do
    for uuidTxt in pairs(set) do
      ps:assign('project', entrySlot(guid, uuidTxt), util.REMOVE)
    end
    ps:assign('project', bucketSlot(guid, b), util.REMOVE)
  end
  ps:assign('project', kbSlot(guid), util.REMOVE)
  keysCache[guid] = nil
end

return eventMeta
