-- See docs/dataStore.md for the model.

--invariant: per-key document storage over pextStore; each name lives at one scope (no tier merge)
--invariant: registry is sole truth for valid names; unknown names raise on every entry point
--invariant: owns its cache: deep-clone out and in; callers never alias ds state
--invariant: take/track caches drop on contextChanged; project/global are context-free
--contract: take/track scopes are per-key P_EXT blobs (ctm_data.<name>); global is a disk file
--emits: dataChanged -- { scope, name } on assign/delete; adds invalidate=true on each rewound key
--reaper: none directly; storage + undo watcher are delegated to pextStore
local util = require 'util'

local deps = ...
local ps   = assert(deps and deps.ps, 'dataStore requires a pextStore dep { ps = ... }')

local function print(...) return util.print(...) end

----------- REGISTRY

-- name -> scope (each key's actual write tier in the pre-split configManager).
local registry = {
  groups              = 'take',
  paramAutomation     = 'take',
  noteDelay           = 'take',
  swing               = 'take',
  extraColumns        = 'take',
  fxRegions           = 'take',
  fxParked            = 'take',
  prevWindows         = 'take',
  arrangeNaturalLenQN = 'take',
  mutedChannels       = 'take',
  soloedChannels      = 'take',
  slotEntries         = 'track',
  arrangeSlots        = 'track',
  arrangeColours      = 'project',
  paramFrecency       = 'global',
}

local GLOBAL_SLOT = 'data'   -- continuum-data.lua, the lone global disk file

-- take/track keep one P_EXT slot per name for write isolation + per-key undo
-- baselines; project reuses the engine's projext section with slot = name.
local function slotFor(scope, name)
  if scope == 'global'  then return GLOBAL_SLOT end
  if scope == 'project' then return name end
  return 'ctm_data.' .. name
end

local function checkName(name)
  if not registry[name] then error('Unknown data key: ' .. tostring(name), 3) end
end

local function copy(v)
  if type(v) == 'table' then return util.deepClone(v) end
  return v
end

----------- CACHE

-- cache[scope] = { name -> value }, lazily loaded. The global cache is the whole
-- continuum-data.lua table; per-key scopes load each registered name's own blob.
local cache = { take = nil, track = nil, project = nil, global = nil }

-- Tolerant: a stale name in the global file (post-rename) is dropped, not raised
-- (mirrors cm's pruneUnknown). Per-key blobs can't accrue unknowns -- skip them.
local function loadScope(scope)
  local tbl = {}
  if scope == 'global' then
    local file = ps:get('global', GLOBAL_SLOT) or {}
    for name, value in pairs(file) do
      if registry[name] == 'global' then tbl[name] = value end
    end
  else
    for name, sc in pairs(registry) do
      if sc == scope then tbl[name] = ps:get(scope, slotFor(scope, name)) end
    end
  end
  return tbl
end

local function ensureScope(scope)
  if not cache[scope] then cache[scope] = loadScope(scope) end
end

-- util.REMOVE clears the slot. take/track writes are loud if unbound (document
-- data isn't recomputable, unlike configManager's silent take-tier skip).
local function persist(scope, name, value)
  if scope == 'global' then
    ps:assign('global', GLOBAL_SLOT, cache.global)
  elseif scope == 'project' then
    ps:assign('project', slotFor(scope, name), value)
  elseif scope == 'track' then
    if not ps:boundTrack() then print('Error! No track context for data key ' .. name); return end
    ps:assign('track', slotFor(scope, name), value)
  elseif scope == 'take' then
    if not ps:boundTake() then print('Error! No take context for data key ' .. name); return end
    ps:assign('take', slotFor(scope, name), value)
  end
end

----------- PUBLIC INTERFACE

local ds = {}
local fire = util.installHooks(ds)

-- The bound context moved: drop take/track caches so the next read reloads from
-- the new take/track. project + global are context-free and survive.
ps:subscribe('contextChanged', function()
  cache.take  = nil
  cache.track = nil
end)

----- Watcher

-- take/track per-key blobs ride pextStore's undo watcher as one group. project +
-- global live outside REAPER's undo (like configManager's), so they aren't watched.
local watched = {}
for name, scope in pairs(registry) do
  if scope == 'take' or scope == 'track' then
    watched[#watched + 1] = { scope = scope, slot = slotFor(scope, name), name = name }
  end
end

ps:watch(watched, function(diverged)
  for _, blob in ipairs(diverged) do
    ensureScope(blob.scope)
    cache[blob.scope][blob.name] = ps:get(blob.scope, blob.slot)
    --emits: dataChanged -- { scope, name, invalidate=true } per blob an undo tick rewound
    fire('dataChanged', { scope = blob.scope, name = blob.name, invalidate = true })
  end
end)

----- Reading

--contract: returns deep copy at name's scope; nil if absent; raises on unknown name
function ds:get(name)
  checkName(name)
  local scope = registry[name]
  ensureScope(scope)
  return copy(cache[scope][name])
end

-- Foreign-handle read: bypasses bound context; scope (take/track) from the registry.
function ds:getAt(handle, name)
  checkName(name)
  local scope = registry[name]
  return copy(ps:getAt(handle, scope, slotFor(scope, name)))
end

----- Writing

--contract: writes one key at its registry scope; REMOVE deletes; fires dataChanged { scope, name }
function ds:assign(name, value)
  checkName(name)
  local scope = registry[name]
  ensureScope(scope)
  if value == util.REMOVE then
    cache[scope][name] = nil
    persist(scope, name, util.REMOVE)
  else
    cache[scope][name] = copy(value)
    persist(scope, name, cache[scope][name])
  end
  --emits: dataChanged -- { scope, name }
  fire('dataChanged', { scope = scope, name = name })
end

function ds:delete(name) return ds:assign(name, util.REMOVE) end

-- Foreign-handle write; util.REMOVE deletes. Refreshes the cache + signals only for
-- the bound handle, so a write aimed at another take/track doesn't disturb the view.
function ds:assignAt(handle, name, value)
  checkName(name)
  local scope = registry[name]
  ps:assignAt(handle, scope, slotFor(scope, name), value)
  local bound = (scope == 'take'  and handle == ps:boundTake())
             or (scope == 'track' and handle == ps:boundTrack())
  if bound then
    ensureScope(scope)
    cache[scope][name] = value == util.REMOVE and nil or copy(value)
    --emits: dataChanged -- { scope, name }
    fire('dataChanged', { scope = scope, name = name })
  end
end

return ds
