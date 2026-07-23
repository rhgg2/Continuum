-- Shared project/library/factory tier logic over a configManager handle.
-- The three sections map to cm tiers: project -> 'project', library -> 'global',
-- factory -> cm:defaultFor (read-only schema catalogue). One key per named
-- library ('swings', 'tempers'); `synthetic` names a per-key floor that is never
-- listed, localized, published, or deleted.

local util = require 'util'

local cm        = (...).cm
local synthetic = (...).synthetic or {}

local lib = {}

----- Tier reads

local function synth(key)       return synthetic[key]           or {} end
local function projectTier(key) return cm:getAt('project', key) or {} end
local function libraryTier(key) return cm:getAt('global',  key) or {} end
local function factoryTier(key) return cm:defaultFor(key)       or {} end

-- Publishable source for a name: library over factory, never the project copy.
local function sourceOf(key, name)
  local g = libraryTier(key)[name]
  if g ~= nil then return g end
  return factoryTier(key)[name]
end

----- Tier writes

-- Read-modify-write a whole tier through one cm:set; cm deep-copies the value in.
local function writeTier(level, key, name, value)
  local tier = cm:getAt(level, key) or {}
  tier[name] = value
  cm:set(level, key, tier)
end

----- Names

local function sortedNames(tier, drop)
  local out = {}
  for name in pairs(tier) do
    if not drop[name] then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

--contract: { project, library, factory } sorted names; synthetic floor dropped, no cross-dedup
function lib.names(key)
  local drop = synth(key)
  return {
    project = sortedNames(projectTier(key), drop),
    library = sortedNames(libraryTier(key), drop),
    factory = sortedNames(factoryTier(key), drop),
  }
end

----- Reads

--contract: resolved deep copy, project over library over factory; nil if no tier has the name
function lib.get(key, name)
  local p = projectTier(key)[name]
  if p ~= nil then return p end
  local g = libraryTier(key)[name]
  if g ~= nil then return g end
  return factoryTier(key)[name]
end

--contract: true iff a project copy and a same-named source both exist and differ (util.deepEq)
function lib.modified(key, name)
  local p = projectTier(key)[name]
  if p == nil then return false end
  local src = sourceOf(key, name)
  if src == nil then return false end
  return not util.deepEq(p, src)
end

----- Localize / fork

--contract: copy the resolved source into project; no-op if synthetic or a project copy exists
function lib.localize(key, name)
  if synth(key)[name] then return end
  if projectTier(key)[name] ~= nil then return end
  local src = sourceOf(key, name)
  if src ~= nil then writeTier('project', key, name, src) end
end

--contract: localize then return the editable project copy
function lib.forkToProject(key, name)
  lib.localize(key, name)
  return projectTier(key)[name]
end

----- Publish / revert

--contract: project copy -> library tier (deepClone via cm:set); no-op when there is no project copy
function lib.publish(key, name)
  local p = projectTier(key)[name]
  if p ~= nil then writeTier('global', key, name, p) end
end

--contract: source (library/factory) -> project, discarding drift; no-op if no source exists
function lib.revert(key, name)
  local src = sourceOf(key, name)
  if src ~= nil then writeTier('project', key, name, src) end
end

----- Tidy / delete

--contract: drop project entries deepEq their source and not in inUse; single cm:set; returns removed
function lib.tidy(key, inUse)
  inUse = inUse or {}
  local tier    = cm:getAt('project', key) or {}
  local removed = {}
  for name, value in pairs(tier) do
    local src = sourceOf(key, name)
    if not inUse[name] and src ~= nil and util.deepEq(value, src) then
      removed[#removed + 1] = name
    end
  end
  if #removed == 0 then return removed end
  table.sort(removed)
  for _, name in ipairs(removed) do tier[name] = nil end
  cm:set('project', key, tier)
  return removed
end

--contract: remove name from tier level (project|global); synthetic never; factory not deletable
function lib.delete(key, level, name)
  if level ~= 'project' and level ~= 'global' then
    error('library.delete: not a deletable level: ' .. tostring(level), 2)
  end
  if synth(key)[name] then return end
  local tier = cm:getAt(level, key) or {}
  if tier[name] == nil then return end
  tier[name] = nil
  cm:set(level, key, tier)
end

return lib
