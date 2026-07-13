-- See docs/eventMeta.md for the model.

--invariant: per-event metadata keyed by POOL guid, not take — every pooled instance shares one blob
--invariant: 'ctm.<guid>.' slots: kb=live bucket set, e.<b>={[uuid]=fields}, b=uuid//256
--invariant: one writer per guid — bucket read-modify-write loses concurrent same-guid updates
--invariant: stores opaque field tables; the strip (which fields are metadata) is mm's, never inspected here
--contract: a nil guid is a no-op/empty everywhere — a take with no derivable pool carries no persisted metadata
local util = require 'util'
local perf = require 'perf'

local ps   = (...).ps

local BUCKET = 256   -- uuids per entry bucket; an edit rewrites its bucket, never the pool

local function kbSlot(guid)        return 'ctm.' .. guid .. '.kb'      end
local function bucketSlot(guid, b) return 'ctm.' .. guid .. '.e.' .. b end

-- The bucket is both the data and its own enumeration (projext has no
-- enumerate-by-prefix); kb tracks which buckets exist. See docs/eventMeta.md § Granularity.
local function readKb(guid)        return ps:get('project', kbSlot(guid)) or {}        end
local function readBucket(guid, b) return ps:get('project', bucketSlot(guid, b)) or {} end

local function writeKb(guid, kb)
  ps:assign('project', kbSlot(guid), next(kb) and kb or util.REMOVE)
end

local eventMeta = {}
local fire = util.installHooks(eventMeta)

-- All 'ctm.' slots are document data: they ride the projext-undo mirror.
ps:declareUndoable{ prefixes = { 'ctm.' } }

--emits: poolsRewound -- { guids = set }; a REAPER undo rewound these pools' metadata slots
ps:subscribe('projectRewound', function(slots)
  local guids = {}
  for _, slot in ipairs(slots) do
    local guid = slot:match('^ctm%.(.+)%.kb$') or slot:match('^ctm%.(.+)%.e%.%d+$')
    if guid then guids[guid] = true end
  end
  if next(guids) then fire('poolsRewound', { guids = guids }) end
end)

--contract: { [uuid:int] = fields }; empty table if the guid has no metadata
function eventMeta:load(guid)
  if not guid then return {} end
  local out = {}
  for b in pairs(readKb(guid)) do
    for uuid, fields in pairs(readBucket(guid, b)) do out[uuid] = fields end
  end
  return out
end

--contract: batched incremental persist: applies dirty={[uuid]=fields} + deleted={[uuid]=true}
--contract: per-modify hot path: read-modify-writes touched buckets only, never the whole pool
function eventMeta:flush(guid, dirty, deleted)
  if not guid then return end
  local byBucket = {}   -- [b] = { [uuid] = fields | false (delete) }
  local function edit(uuid, fields)
    local b     = uuid // BUCKET
    local edits = byBucket[b]
    if not edits then edits = {}; byBucket[b] = edits end
    edits[uuid] = fields
  end
  for uuid, fields in pairs(dirty) do edit(uuid, fields) end
  for uuid in pairs(deleted) do edit(uuid, false) end
  if not next(byBucket) then return end
  perf.start('buckets')
  local kb, kbChanged = readKb(guid), false
  for b, edits in pairs(byBucket) do
    local set = kb[b] and readBucket(guid, b) or {}
    for uuid, fields in pairs(edits) do set[uuid] = fields or nil end
    if next(set) then
      ps:assign('project', bucketSlot(guid, b), set)
      if not kb[b] then kb[b] = true; kbChanged = true end
    elseif kb[b] then
      ps:assign('project', bucketSlot(guid, b), util.REMOVE)
      kb[b] = nil; kbChanged = true
    end
  end
  if kbChanged then writeKb(guid, kb) end
  perf.stop('buckets')
end

--contract: replaces the pool's whole metadata with byUuid={[uuid]=fields}; sweeps uuids no longer present
function eventMeta:saveAll(guid, byUuid)
  if not guid then return end
  local byBucket, kb = {}, {}
  for uuid, fields in pairs(byUuid) do
    local b   = uuid // BUCKET
    local set = byBucket[b]
    if not set then set = {}; byBucket[b] = set; kb[b] = true end
    set[uuid] = fields
  end
  for b in pairs(readKb(guid)) do
    if not byBucket[b] then ps:assign('project', bucketSlot(guid, b), util.REMOVE) end
  end
  for b, set in pairs(byBucket) do
    ps:assign('project', bucketSlot(guid, b), set)
  end
  writeKb(guid, kb)
end

--contract: forks srcGuid's metadata onto dstGuid (an unpooled clone mints a fresh pool; this seeds it)
function eventMeta:copyPool(srcGuid, dstGuid)
  if not (srcGuid and dstGuid) then return end
  self:saveAll(dstGuid, self:load(srcGuid))
end

--contract: forever-deletes a pool's metadata (deleteSlot's keeper removal)
function eventMeta:dropPool(guid)
  if not guid then return end
  for b in pairs(readKb(guid)) do
    ps:assign('project', bucketSlot(guid, b), util.REMOVE)
  end
  ps:assign('project', kbSlot(guid), util.REMOVE)
end

return eventMeta
