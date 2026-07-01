-- See docs/eventMeta.md for the model.

--invariant: per-event metadata keyed by POOL guid, not take — every pooled instance shares one blob
--invariant: project scope via ps; 'ctm.<guid>.keys' is the uuidTxt set, 'ctm.<guid>.u.<uuidTxt>' the fields
--invariant: stores opaque field tables; the strip (which fields are metadata) is mm's, never inspected here
--contract: a nil guid is a no-op/empty everywhere — a take with no derivable pool carries no persisted metadata
local util = require 'util'

local ps   = (...).ps

local function keysSlot(guid)           return 'ctm.' .. guid .. '.keys'      end
local function entrySlot(guid, uuidTxt) return 'ctm.' .. guid .. '.u.' .. uuidTxt end

-- The keys set { [uuidTxt] = true } is the loader's index (projext has no enumerate-by-
-- prefix). Cached in memory; load() re-syncs it. See docs/eventMeta.md § Keyset cache.
local keysCache = {}
local function readKeys(guid)
  local cached = keysCache[guid]
  if cached then return cached end
  local set = ps:get('project', keysSlot(guid)) or {}
  keysCache[guid] = set
  return set
end
local function writeKeys(guid, set)
  keysCache[guid] = set
  ps:assign('project', keysSlot(guid), next(set) and set or util.REMOVE)
end

local eventMeta = {}

--contract: { [uuid:int] = fields }; empty table if the guid has no metadata
function eventMeta:load(guid)
  if not guid then return {} end
  keysCache[guid] = nil                       -- re-sync from projext (absorbs external undo/redo)
  local out = {}
  for uuidTxt in pairs(readKeys(guid)) do
    local fields = ps:get('project', entrySlot(guid, uuidTxt))
    if fields then out[util.fromBase36(uuidTxt)] = fields end
  end
  return out
end

--contract: batched incremental persist: applies dirty={[uuid]=fields} + deleted={[uuid]=true}
--contract: reads/writes the keys set once -- the per-modify hot path, O(#ops) not O(#ops*#keys)
function eventMeta:flush(guid, dirty, deleted)
  if not guid then return end
  local keys, keysChanged = readKeys(guid), false
  for uuid, fields in pairs(dirty) do
    local uuidTxt = util.toBase36(uuid)
    ps:assign('project', entrySlot(guid, uuidTxt), fields)
    if not keys[uuidTxt] then keys[uuidTxt] = true; keysChanged = true end
  end
  for uuid in pairs(deleted) do
    local uuidTxt = util.toBase36(uuid)
    ps:assign('project', entrySlot(guid, uuidTxt), util.REMOVE)
    if keys[uuidTxt] then keys[uuidTxt] = nil; keysChanged = true end
  end
  if keysChanged then writeKeys(guid, keys) end
end

--contract: replaces the pool's whole metadata with byUuid={[uuid]=fields}; sweeps uuids no longer present
function eventMeta:saveAll(guid, byUuid)
  if not guid then return end
  local old, set = readKeys(guid), {}
  for uuid, fields in pairs(byUuid) do
    local uuidTxt = util.toBase36(uuid)
    ps:assign('project', entrySlot(guid, uuidTxt), fields)
    set[uuidTxt] = true
  end
  for uuidTxt in pairs(old) do
    if not set[uuidTxt] then ps:assign('project', entrySlot(guid, uuidTxt), util.REMOVE) end
  end
  writeKeys(guid, set)
end

--contract: forks srcGuid's metadata onto dstGuid (an unpooled clone mints a fresh pool; this seeds it)
function eventMeta:copyPool(srcGuid, dstGuid)
  if not (srcGuid and dstGuid) then return end
  self:saveAll(dstGuid, self:load(srcGuid))
end

--contract: forever-deletes a pool's metadata (deleteSlot's keeper removal)
function eventMeta:dropPool(guid)
  if not guid then return end
  for uuidTxt in pairs(readKeys(guid)) do
    ps:assign('project', entrySlot(guid, uuidTxt), util.REMOVE)
  end
  ps:assign('project', keysSlot(guid), util.REMOVE)
  keysCache[guid] = nil
end

return eventMeta
