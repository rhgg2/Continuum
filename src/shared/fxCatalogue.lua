-- The installed plugins, each under a catalogue key that survives an update
-- moving the plugin's files. REAPER builds the list once and serves it from memory.
--invariant: only state is a session memo of JSFX parses by path; the catalogue is a global ds key
--invariant: installed() re-reads REAPER on every call
--shape: row = { key, name, ident, format }  -- ident raw from REAPER; format the name's prefix before ':', or ''
--shape: fxCatalogue (ds global) = { n = int, entries = { [catalogueKey] = entry }, standing = { [path] = true } }
--shape: entry = { ports?={ ins=int, outs=int }, usage?={ s=num, n0=int }, traits?={ midiIn?=bool, midiOut?=bool, instrument?=bool }, paths?={ [path] = true } }
--shape: path = string  -- names joined by '/', none empty
--shape: traits = { midiIn=bool, midiOut=bool, instrument=bool, busAware=bool }  -- resolved; all four present
--shape: jsfxParse = { busAware=bool, midiIn=bool, midiOut=bool }

local util = require 'util'
local fs   = require 'fs'

local fxCatalogue = {}

local function isVst(format) return format:sub(1, 3) == 'VST' end

-- REAPER's own reaper-vstplugins key: the file name, every byte outside
-- [%w.<] spelt '_'. A shell file's plugins keep their '<id' suffix.
local function vstKey(ident)
  local file = ident:match('[^/\\]*$')
  return (file:gsub('[^%w.<]', '_'))
end

--post: result = vstKey(ident) if format begins 'VST', else ident
function fxCatalogue.key(format, ident)
  if isVst(format) then return vstKey(ident) end
  return ident
end

--post: fresh rows, one per EnumInstalledFX entry, in its order
function fxCatalogue.installed()
  local rows, i = {}, 0
  while true do
    local ok, name, ident = reaper.EnumInstalledFX(i)
    if not ok then break end
    local format = name:match('^(%w+):') or ''
    util.add(rows, { key = fxCatalogue.key(format, ident), name = name, ident = ident, format = format })
    i = i + 1
  end
  return rows
end

-- A VST instance's ident always ends '<id' (VST3 then '{' and 32 hex, unclosed);
-- the installed list keeps '<id' only for a shell file's members.
--pre: rows are installed() rows when format begins 'VST'; read only then
--post: nil for an empty ident; a VST resolves to the row key its ident matches,
--      with or without its '<id', and to the bare file key when none matches; else key(format, ident)
function fxCatalogue.instanceKey(format, ident, rows)
  if ident == '' then return nil end
  if not isVst(format) then return fxCatalogue.key(format, ident) end
  local withId = vstKey((ident:gsub('{%x+$', '')))
  local bare   = (withId:gsub('<.*$', ''))
  for _, row in ipairs(rows) do
    if row.key == withId or row.key == bare then return row.key end
  end
  return bare
end

--post: instanceKey of the instance's fx_type and fx_ident, walking the installed set only for a VST
function fxCatalogue.keyAt(track, fxIdx)
  local _, ident  = reaper.TrackFX_GetNamedConfigParm(track, fxIdx, 'fx_ident')
  local _, fxType = reaper.TrackFX_GetNamedConfigParm(track, fxIdx, 'fx_type')
  return fxCatalogue.instanceKey(fxType, ident, isVst(fxType) and fxCatalogue.installed() or nil)
end

----- Traits: see docs/fxCatalogue.md § Traits

local function parseJsfx(content)
  local parse = { busAware = false, midiIn = false, midiOut = false }
  for line in content:gmatch('[^\r\n]+') do
    local code = line:gsub('//.*', '')
    if code:match('^%s*ext_midi_bus%s*=%s*1%f[%D]') then parse.busAware = true end
    if code:find('midirecv', 1, true) then parse.midiIn = true end
    if code:find('midisend', 1, true) or code:find('midisyx', 1, true) then parse.midiOut = true end
  end
  return parse
end

-- A JSFX's source is static for the session; an unreadable one memoises as false.
local jsfxMemo = {}

-- The parse of Effects/<path>, nil if unreadable; each path read once per session.
local function jsfx(path)
  if jsfxMemo[path] == nil then
    local file = io.open(fs.join(reaper.GetResourcePath(), 'Effects/' .. path), 'rb')
    jsfxMemo[path] = file and parseJsfx(file:read('a')) or false
    if file then file:close() end
  end
  return jsfxMemo[path] or nil
end

local DEFAULT_TRAITS = { midiIn = true, midiOut = true, instrument = false }

--post: each trait the first non-nil of authored, parsed, the format's 'i' mark, the default
--post: busAware from the JSFX parse, else false
function fxCatalogue.traits(catalogue, format, key)
  local entry  = catalogue and key and catalogue.entries[key]
  local parsed = format == 'JS' and key and jsfx(key) or {}
  local mark   = format:match('i$') and { instrument = true, midiIn = true } or {}
  local sources  = { entry and entry.traits or {}, parsed, mark, DEFAULT_TRAITS }
  local resolved = { busAware = parsed.busAware or false }
  for name in pairs(DEFAULT_TRAITS) do
    for _, source in ipairs(sources) do
      if source[name] ~= nil then resolved[name] = source[name]; break end
    end
  end
  return resolved
end

-- The persisted catalogue, defaulted; one written before standing paths lacks them.
local function load(ds)
  local catalogue = ds:get('fxCatalogue') or { n = 0, entries = {} }
  catalogue.standing = catalogue.standing or {}
  return catalogue
end

-- Usage decays per catalogue-wide use, not per day, so an unused month
-- costs nothing; 0.98 halves a score over about 34 uses.
local DECAY = 0.98

--post: catalogue n advances by 1; entries[key].usage decays by the uses since its n0, then +1
--post: entries[key].ports = ports; the entry's other fields kept
function fxCatalogue.recordUse(ds, key, ports)
  local catalogue = load(ds)
  local n     = catalogue.n + 1
  local entry = catalogue.entries[key] or {}
  local usage = entry.usage
  entry.usage = { s = (usage and usage.s * DECAY ^ (n - usage.n0) or 0) + 1, n0 = n }
  entry.ports = ports
  catalogue.entries[key] = entry
  catalogue.n = n
  ds:assign('fxCatalogue', catalogue)
end

----- Taxonomy: see docs/fxCatalogue.md § The taxonomy

--invariant: UNFILED is compared by identity; it is returned, never stored
fxCatalogue.UNFILED = {}

local function checkPath(path)
  if ('/' .. path .. '/'):find('//', 1, true) then
    error('fxCatalogue: a name is empty in path ' .. string.format('%q', path), 3)
  end
end

-- Every path an entry names or standing holds, with each one's prefixes.
local function listedPaths(catalogue)
  local listed = {}
  local function list(path)
    for slash in path:gmatch('()/') do listed[path:sub(1, slash - 1)] = true end
    listed[path] = true
  end
  for _, entry in pairs(catalogue.entries) do
    for path in pairs(entry.paths or {}) do list(path) end
  end
  for path in pairs(catalogue.standing) do list(path) end
  return listed
end

--post: fresh; each listed path once, name by name ignoring case, the raw string breaking a tie
--post: UNFILED last
function fxCatalogue.categories(ds)
  local paths   = util.keys(listedPaths(load(ds)))
  local sortKey = {}
  for _, path in ipairs(paths) do sortKey[path] = (path:lower():gsub('/', '\0')) end
  table.sort(paths, function(a, b)
    if sortKey[a] ~= sortKey[b] then return sortKey[a] < sortKey[b] end
    return a < b
  end)
  util.add(paths, fxCatalogue.UNFILED)
  return paths
end

--post: path standing, so listed whatever is filed under it
function fxCatalogue.makePath(ds, path)
  checkPath(path)
  local catalogue = load(ds)
  catalogue.standing[path] = true
  ds:assign('fxCatalogue', catalogue)
end

--post: entries[key] holds path, created if absent; its other paths and facts kept
function fxCatalogue.file(ds, key, path)
  checkPath(path)
  local catalogue = load(ds)
  local entry = catalogue.entries[key] or {}
  entry.paths = entry.paths or {}
  entry.paths[path] = true
  catalogue.entries[key] = entry
  ds:assign('fxCatalogue', catalogue)
end

--post: entries[key] no longer holds path, and paths is nil once none remain; no-op when not held
function fxCatalogue.unfile(ds, key, path)
  local catalogue = load(ds)
  local entry = catalogue.entries[key]
  if not (entry and entry.paths and entry.paths[path]) then return end
  entry.paths[path] = nil
  if next(entry.paths) == nil then entry.paths = nil end
  ds:assign('fxCatalogue', catalogue)
end

--pre: from is listed in categories, else raises
--post: from and each path under it re-rooted at to, in every entry and standing; unions on a clash
function fxCatalogue.renamePath(ds, from, to)
  checkPath(from)
  checkPath(to)
  local catalogue = load(ds)
  if not listedPaths(catalogue)[from] then
    error('fxCatalogue: no path ' .. string.format('%q', from) .. ' to rename', 2)
  end
  local under = from .. '/'
  local function rewrite(paths)
    local rewritten = {}
    for path in pairs(paths) do
      if path == from then rewritten[to] = true
      elseif path:sub(1, #under) == under then rewritten[to .. path:sub(#from + 1)] = true
      else rewritten[path] = true end
    end
    return rewritten
  end

  local entryPaths = {}
  for key, entry in pairs(catalogue.entries) do
    if entry.paths then entryPaths[key] = rewrite(entry.paths) end
  end
  local standing = rewrite(catalogue.standing)

  for key, paths in pairs(entryPaths) do catalogue.entries[key].paths = paths end
  catalogue.standing = standing
  ds:assign('fxCatalogue', catalogue)
end

return fxCatalogue
