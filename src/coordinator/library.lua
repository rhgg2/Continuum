-- Project/library tier logic over a configManager handle. See docs/library.md.
--invariant: factory is a seed source, not a resolution tier — only localize's floor reads it

local util = require 'util'

local cm          = (...).cm
local synthetic   = (...).synthetic or {}
local libraryForm = (...).libraryForm or {}

local lib = {}

----- Tier reads

local function synth(key)       return synthetic[key]           or {} end
local function projectTier(key) return cm:getAt('project', key) or {} end
local function libraryTier(key) return cm:getAt('global',  key) or {} end
local function factoryTier(key) return cm:defaultFor(key)       or {} end

-- Some state is project-tier only; publish and modified compare the library
-- *form* of each copy, not the copy itself. See docs/library.md § Modified badge.
local function asLibrary(key, value)
  local form = libraryForm[key]
  return (form and value ~= nil) and form(value) or value
end

-- Publishable/revertable source for a name: the library copy, never the
-- project copy. (The factory catalogue is a seed source, not a live source.)
local function sourceOf(key, name)
  return libraryTier(key)[name]
end

----- Tier writes

-- The tiers a caller may name: factory is a seed source, not somewhere a name lives.
local function checkLevel(level)
  if level ~= 'project' and level ~= 'global' then
    error('library: not an addressable tier: ' .. tostring(level), 3)
  end
end

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
    if not drop[name] then util.add(out, name) end
  end
  table.sort(out)
  return out
end

--post: fresh result.T = sorted(tier T's names \ synthetic(key)), T ∈ { project, library }
function lib.names(key)
  local drop = synth(key)
  return {
    project = sortedNames(projectTier(key), drop),
    library = sortedNames(libraryTier(key), drop),
  }
end

----- Reads

--pre: level ∈ { project, global }
--post: fresh result = tier(level)[name]
function lib.getAt(key, level, name)
  checkLevel(level)
  return (cm:getAt(level, key) or {})[name]
end

--post: result = (project[name] and library[name] exist and asLibrary forms differ)
function lib.modified(key, name)
  local p = projectTier(key)[name]
  if p == nil then return false end
  local src = sourceOf(key, name)
  if src == nil then return false end
  return not util.deepEq(asLibrary(key, p), asLibrary(key, src))
end

----- Localize / fork

--post: no-op iff name is synthetic, project[name] exists, or neither source has name
--post: otherwise, project[name] := library[name] or factory(key)[name]
function lib.localize(key, name)
  if synth(key)[name] then return end
  if projectTier(key)[name] ~= nil then return end
  -- Copy-on-use must materialise any resolvable name, so it falls through to the
  -- factory floor even for a name whose library row was deleted.
  local src = libraryTier(key)[name] or factoryTier(key)[name]
  if src ~= nil then writeTier('project', key, name, src) end
end

--post: fresh result = project[name] after lib.localize — detached, so a write to it is lost
function lib.forkToProject(key, name)
  lib.localize(key, name)
  return projectTier(key)[name]
end

----- Author

--pre: level ∈ { project, global }
--post: no-op iff name is synthetic; else tier(level)[name] := copy of value
function lib.save(key, level, name, value)
  checkLevel(level)
  if synth(key)[name] then return end
  writeTier(level, key, name, value)
end

----- Publish / revert

--post: no-op iff project[name] is nil; else library[name] := asLibrary(key, project[name])
function lib.publish(key, name)
  local p = projectTier(key)[name]
  if p ~= nil then writeTier('global', key, name, asLibrary(key, p)) end
end

--post: result = (project[name] and library[name] exist and asLibrary forms differ)
function lib.publishOverwrites(key, name)
  -- Library tier directly, not sourceOf: a factory-only shadow mints a new row, not an overwrite.
  local p = projectTier(key)[name]
  local g = libraryTier(key)[name]
  if p == nil or g == nil then return false end
  return not util.deepEq(asLibrary(key, p), asLibrary(key, g))
end

--post: no-op iff library[name] is nil; else project[name] := library[name]
function lib.revert(key, name)
  local src = sourceOf(key, name)
  if src ~= nil then writeTier('project', key, name, src) end
end

----- Factory seed / reload

--post: no-op iff library ≠ {}; else library := factory(key) \ synthetic(key)
function lib.seedIfEmpty(key)
  if next(libraryTier(key)) ~= nil then return end
  local drop = synth(key)
  local tier = {}
  for name, value in pairs(factoryTier(key)) do
    if not drop[name] then tier[name] = value end
  end
  if next(tier) ~= nil then cm:set('global', key, tier) end
end

--post: fresh result.add = sorted { n ∈ S : library[n] is nil }, S = factory(key) \ synthetic(key)
--post: fresh result.overwrite = sorted { n ∈ S : library[n] exists and differs }
function lib.reloadPlan(key)
  local libr = libraryTier(key)
  local drop = synth(key)
  local add, overwrite = {}, {}
  for name, value in pairs(factoryTier(key)) do
    if not drop[name] then
      local cur = libr[name]
      if cur == nil then util.add(add, name)
      elseif not util.deepEq(cur, value) then util.add(overwrite, name) end
    end
  end
  table.sort(add); table.sort(overwrite)
  return { add = add, overwrite = overwrite }
end

--post: result = (factory(key)[name] and library[name] exist and differ)
function lib.factoryOverwrites(key, name)
  local f = factoryTier(key)[name]
  local g = libraryTier(key)[name]
  if f == nil or g == nil then return false end
  return not util.deepEq(f, g)
end

--post: no-op iff name is synthetic or not in factory; else library[name] := factory(key)[name]
function lib.importFactory(key, name)
  if synth(key)[name] then return end
  local value = factoryTier(key)[name]
  if value ~= nil then writeTier('global', key, name, value) end
end

----- Tidy / delete

--post: fresh result = sorted { n ∈ project : n ∉ inUse and deepEq(project[n], library[n]) }
--post: project := project \ result, written in one cm:set
function lib.tidy(key, inUse)
  inUse = inUse or {}
  local tier    = cm:getAt('project', key) or {}
  local removed = {}
  for name, value in pairs(tier) do
    local src = sourceOf(key, name)
    if not inUse[name] and src ~= nil and util.deepEq(value, src) then
      util.add(removed, name)
    end
  end
  if #removed == 0 then return removed end
  table.sort(removed)
  for _, name in ipairs(removed) do tier[name] = nil end
  cm:set('project', key, tier)
  return removed
end

--pre: level ∈ { project, global }
--post: no-op iff name is synthetic or absent; else tier(level) := tier(level) \ { name }
function lib.delete(key, level, name)
  checkLevel(level)
  if synth(key)[name] then return end
  local tier = cm:getAt(level, key) or {}
  if tier[name] == nil then return end
  tier[name] = nil
  cm:set(level, key, tier)
end

return lib
