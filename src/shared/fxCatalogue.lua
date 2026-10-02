-- The installed plugins, each under a catalogue key that survives an update
-- moving the plugin's files. REAPER builds the list once and serves it from memory.
--invariant: only state is a session memo of JSFX parses by path; the catalogue is a global ds key
--invariant: installed() re-reads REAPER on every call
--shape: row = { key, name, ident, format }  -- ident raw from REAPER; format the name's prefix before ':', or ''
--shape: fxCatalogue (ds global) = { n = int, entries = { [catalogueKey] = entry }, standing = { [path] = true } }
--shape: entry = { ports?={ ins=int, outs=int }, usage?={ s=num, n0=int }, traits?={ midiIn?=bool, midiOut?=bool, instrument?=bool }, paths?={ [path] = true }, developer?=string }
--shape: path = string  -- names joined by '/', none empty
--shape: traits = { midiIn=bool, midiOut=bool, instrument=bool, busAware=bool }  -- resolved; all four present
--shape: jsfxParse = { busAware=bool, midiIn=bool, midiOut=bool }
--shape: sources = { installed=int, tree=source, user=source+{ standing={ [path]=true } }, folders=source, derived=source, developers=source }  -- derived names nested by the seed
--shape: source = { names={ [catalogueKey]={ [name]=true } }, covered=int, distinct=int, dropped=int }

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

local function isPath(name) return not ('/' .. name .. '/'):find('//', 1, true) end

local function checkPath(path)
  if not isPath(path) then
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
function fxCatalogue.categories(ds)
  local paths   = util.keys(listedPaths(load(ds)))
  local sortKey = {}
  for _, path in ipairs(paths) do sortKey[path] = (path:lower():gsub('/', '\0')) end
  table.sort(paths, function(a, b)
    if sortKey[a] ~= sortKey[b] then return sortKey[a] < sortKey[b] end
    return a < b
  end)
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

----- Sources: see docs/fxCatalogue.md § The sources

-- An ini file's sections by header, each { [key] = value }; empty when unreadable.
-- A section holding a non-blank line that is not key=value is left out whole.
local function readIni(path)
  local sections, broken, current = {}, {}, nil
  for line in (fs.readText(path) or ''):gmatch('[^\r\n]+') do
    local header = line:match('^%[(.*)%]%s*$')
    if header then
      current = header
      sections[current] = sections[current] or {}
    elseif current and line:find('%S') then
      local key, value = line:match('^([^=]*)=(.*)$')
      if key then sections[current][key] = value else broken[current] = true end
    end
  end
  for header in pairs(broken) do sections[header] = nil end
  return sections
end

-- Every root a [REAPER] vstpath key lists, without its trailing '/'.
local function vstRoots(settings)
  local roots, home = {}, os.getenv('HOME')
  for key, value in pairs(settings) do
    if key:match('^vstpath') and key ~= 'vstpath_root' then
      for part in value:gmatch('[^;]+') do
        util.add(roots, (part:gsub('^~', function() return home end):gsub('/+$', '')))
      end
    end
  end
  return roots
end

-- A row's install-tree name: its ident's directories below the deepest root holding it.
local function treeName(row, roots)
  if row.format == 'JS' then return row.ident:match('^(.*)/[^/]*$') end
  if not isVst(row.format) then return nil end
  local deepest
  for _, root in ipairs(roots) do
    local under = root .. '/'
    if row.ident:sub(1, #under) == under and (not deepest or #root > #deepest) then deepest = root end
  end
  return deepest and row.ident:sub(#deepest + 2):match('^(.*)/[^/]*$')
end

-- The installed keys a reference may name: exactly, by JSFX file name, and either ignoring case.
local function keyIndex(rows)
  local index = { exact = {}, jsBase = {}, folded = {} }
  local function enter(byName, name, key)
    byName[name] = byName[name] or {}
    byName[name][key] = true
  end
  for _, row in ipairs(rows) do
    index.exact[row.key] = { [row.key] = true }
    enter(index.folded, row.key:lower(), row.key)
    if row.format == 'JS' then
      local base = fs.basename(row.key)
      enter(index.jsBase, base, row.key)
      enter(index.folded, base:lower(), row.key)
    end
  end
  return index
end

-- The key set a reference resolves to, nil when it resolves to none.
local function resolve(index, reference)
  return index.exact[reference] or index.jsBase[reference] or index.folded[reference:lower()]
end

local function addName(names, key, name)
  names[key] = names[key] or {}
  names[key][name] = true
end

-- A category value's names: split on '|', each kept only if a path.
local function categoryNames(value)
  local names = {}
  for name in (value .. '|'):gmatch('([^|]*)|') do
    if isPath(name) then util.add(names, name) end
  end
  return names
end

local function developerNames(value) return value ~= '' and { value } or {} end

-- A key=value section's references resolved, each value's names filed under every key it resolves to.
local function fromSection(section, index, namesOf)
  local names, dropped = {}, 0
  for reference, value in pairs(section or {}) do
    local keys = resolve(index, reference)
    if keys then
      for key in pairs(keys) do
        for _, name in ipairs(namesOf(value)) do addName(names, key, name) end
      end
    else
      dropped = dropped + 1
    end
  end
  return names, dropped
end

local FOLDER_FORMAT = { ['2'] = 'JS', ['3'] = 'VST', ['5'] = 'AU', ['7'] = 'CLAP' }
local SMART_FILTER  = '1048576'
local FAVOURITES_ID   = '0'
local FAVOURITES_PATH = 'Favourites'

-- REAPER's derived category names: to a path, to false (discarded), or absent (kept bare).
local SEED_NESTING = {
  ['Effect']             = 'Effects',
  ['Effects']            = 'Effects',
  ['Fx']                 = 'Effects',
  ['Channel Strip']      = 'Effects/Channel Strip',
  ['Chorus']             = 'Effects/Chorus',
  ['Compressor']         = 'Effects/Compressor',
  ['Delay']              = 'Effects/Delay',
  ['Distortion']         = 'Effects/Distortion',
  ['Dynamics']           = 'Effects/Dynamics',
  ['EQ']                 = 'Effects/EQ',
  ['Filter']             = 'Effects/Filter',
  ['Gate']               = 'Effects/Gate',
  ['Guitar']             = 'Effects/Guitar',
  ['Mastering']          = 'Effects/Mastering',
  ['Microphone']         = 'Effects/Microphone',
  ['Modulation']         = 'Effects/Modulation',
  ['Pitch Correction']   = 'Effects/Pitch Correction',
  ['Pitch Shift']        = 'Effects/Pitch Shift',
  ['Restoration']        = 'Effects/Restoration',
  ['Reverb']             = 'Effects/Reverb',
  ['Spatial']            = 'Effects/Spatial',
  ['Instrument']         = 'Instruments',
  ['Drum']               = 'Instruments/Drum',
  ['External']           = 'Instruments/External',
  ['Organ']              = 'Instruments/Organ',
  ['Piano']              = 'Instruments/Piano',
  ['Sampler']            = 'Instruments/Sampler',
  ['Synth']              = 'Instruments/Synth',
  ['Tools']              = 'Tools',
  ['Analyzer']           = 'Tools/Analyzer',
  ['Generator']          = 'Tools/Generator',
  ['Tuner']              = 'Tools/Tuner',
  ['Up-Downmix']         = 'Tools/Up-Downmix',
  ['Ambisonics']         = false,
  ['Mono']               = false,
  ['Stereo']             = false,
  ['Surround']           = false,
  ['MIDI']               = false,
  ['Network']            = false,
  ['u-he']               = false,
  ['Fx Instrument Tools'] = false,
}

-- A derived category value's names, nested: see docs/fxCatalogue.md § The seed nesting.
local function derivedNames(value)
  local names = {}
  for _, name in ipairs(categoryNames(value)) do
    local nested = SEED_NESTING[name]
    if nested == nil then util.add(names, name)
    elseif nested then util.add(names, nested) end
  end
  return names
end

-- Each folder's members, its sections found by id; id 0 is named Favourites, whatever its Name.
local function fromFolders(ini, index)
  local names, dropped = {}, 0
  local folders = ini.Folders or {}
  for i = 0, (tonumber(folders.NbFolders) or 0) - 1 do
    local id      = folders['Id' .. i]
    local name    = id == FAVOURITES_ID and FAVOURITES_PATH or folders['Name' .. i]
    local members = id and ini['Folder' .. id]
    if members and name and isPath(name) then
      for n = 0, (tonumber(members.Nb) or 0) - 1 do
        local item, itemType = members['Item' .. n], members['Type' .. n]
        local format = FOLDER_FORMAT[itemType]
        local keys   = format and item and resolve(index, fxCatalogue.key(format, item))
        if itemType == SMART_FILTER then -- a filter, naming no plugin
        elseif not keys then dropped = dropped + 1
        else for key in pairs(keys) do addName(names, key, name) end end
      end
    end
  end
  return names, dropped
end

local function source(names, dropped)
  local covered, distinct = {}, {}
  for key, held in pairs(names) do
    covered[key] = true
    util.assign(distinct, held)
  end
  return { names = names, covered = #util.keys(covered), distinct = #util.keys(distinct), dropped = dropped }
end

--post: fresh; each source's references resolved to installed keys, unresolved ones counted dropped
--post: a missing ini reads as empty, so its sources are empty
function fxCatalogue.sources()
  local resource = reaper.GetResourcePath()
  local settings = readIni(fs.join(resource, 'reaper.ini'))
  local fxFolders = readIni(fs.join(resource, 'reaper-fxfolders.ini'))
  local fxTags   = readIni(fs.join(resource, 'reaper-fxtags.ini'))
  local rows     = fxCatalogue.installed()
  local index    = keyIndex(rows)
  local roots    = vstRoots(settings.REAPER or {})

  local treeNames = {}
  for _, row in ipairs(rows) do
    local name = treeName(row, roots)
    if name and isPath(name) then addName(treeNames, row.key, name) end
  end
  local user = source(fromSection(fxFolders.category, index, categoryNames))
  user.standing = {}
  for path in pairs(fxFolders.categories or {}) do
    if isPath(path) then user.standing[path] = true end
  end

  return {
    installed  = #rows,
    tree       = source(treeNames, 0),
    user       = user,
    folders    = source(fromFolders(fxFolders, index)),
    derived    = source(fromSection(fxTags.category, index, derivedNames)),
    developers = source(fromSection(fxTags.developer, index, developerNames)),
  }
end

----- Import: see docs/fxCatalogue.md § Import

local PATH_SOURCES = { 'tree', 'user', 'folders', 'derived' }
local IMPORTABLE   = { tree = true, user = true, folders = true, derived = true, developers = true }
local MODES        = { augment = true, replace = true }

local function lowest(names)
  local found
  for name in pairs(names) do
    if not found or name < found then found = name end
  end
  return found
end

--pre: sources a sources() result; chosen a set of its source names
--pre: mode augment or replace, else raises
--post: replace first clears standing and each entry's paths and developer, chosen or not
--post: developer written only to an entry holding none, the lowest-sorting where a key has several
function fxCatalogue.import(ds, sources, chosen, mode)
  if not MODES[mode] then
    error('fxCatalogue: no import mode ' .. string.format('%q', tostring(mode)), 2)
  end
  for name in pairs(chosen) do
    if not IMPORTABLE[name] then
      error('fxCatalogue: no source ' .. string.format('%q', tostring(name)) .. ' to import', 2)
    end
  end

  local catalogue = load(ds)
  local entries   = catalogue.entries
  if mode == 'replace' then
    for _, entry in pairs(entries) do entry.paths, entry.developer = nil, nil end
    catalogue.standing = {}
  end
  local function entryAt(key)
    entries[key] = entries[key] or {}
    return entries[key]
  end

  for _, name in ipairs(PATH_SOURCES) do
    if chosen[name] then
      for key, names in pairs(sources[name].names) do
        local entry = entryAt(key)
        entry.paths = util.assign(entry.paths or {}, names)
      end
    end
  end
  if chosen.user then util.assign(catalogue.standing, sources.user.standing) end
  if chosen.developers then
    for key, names in pairs(sources.developers.names) do
      local entry = entryAt(key)
      entry.developer = entry.developer or lowest(names)
    end
  end
  ds:assign('fxCatalogue', catalogue)
end

return fxCatalogue
