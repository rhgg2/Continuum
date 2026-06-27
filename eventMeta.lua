-- See docs/eventMeta.md for the model.

--invariant: per-event metadata keyed by POOL guid, not take — every pooled instance shares one blob
--invariant: project scope via ps; 'ctm.<guid>.keys' is the uuidTxt set, 'ctm.<guid>.u.<uuidTxt>' the fields
--invariant: stores opaque field tables; the strip (which fields are metadata) is mm's, never inspected here
--contract: a nil guid is a no-op/empty everywhere — a take with no derivable pool carries no persisted metadata
local util = require 'util'

local ps   = (...).ps

local function keysSlot(guid)           return 'ctm.' .. guid .. '.keys'      end
local function entrySlot(guid, uuidTxt) return 'ctm.' .. guid .. '.u.' .. uuidTxt end

-- The keys set { [uuidTxt] = true } is the loader's index — projext has no
-- enumerate-by-prefix, so the live uuid set is tracked explicitly.
local function readKeys(guid)
  return ps:get('project', keysSlot(guid)) or {}
end
local function writeKeys(guid, set)
  ps:assign('project', keysSlot(guid), next(set) and set or util.REMOVE)
end

local eventMeta = {}

--contract: { [uuid:int] = fields }; empty table if the guid has no metadata
function eventMeta:load(guid)
  if not guid then return {} end
  local out = {}
  for uuidTxt in pairs(readKeys(guid)) do
    local fields = ps:get('project', entrySlot(guid, uuidTxt))
    if fields then out[util.fromBase36(uuidTxt)] = fields end
  end
  return out
end

--contract: persists one uuid's fields; extends the keys set only when the uuid is new (hot path stays O(1) writes)
function eventMeta:saveOne(guid, uuid, fields)
  if not guid then return end
  local uuidTxt = util.toBase36(uuid)
  ps:assign('project', entrySlot(guid, uuidTxt), fields)
  local keys = readKeys(guid)
  if not keys[uuidTxt] then
    keys[uuidTxt] = true
    writeKeys(guid, keys)
  end
end

--contract: clears one uuid's fields slot and drops it from the keys set
function eventMeta:deleteOne(guid, uuid)
  if not guid then return end
  local uuidTxt = util.toBase36(uuid)
  ps:assign('project', entrySlot(guid, uuidTxt), util.REMOVE)
  local keys = readKeys(guid)
  if keys[uuidTxt] then
    keys[uuidTxt] = nil
    writeKeys(guid, keys)
  end
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
end

return eventMeta
