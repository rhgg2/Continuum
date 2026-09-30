-- The installed plugins, each under a catalogue key that survives an update
-- moving the plugin's files. REAPER builds the list once and serves it from memory.
--invariant: holds no state; the catalogue is a global ds key, and installed() re-reads REAPER
--shape: row = { key, name, ident, format }  -- ident raw from REAPER; format the name's prefix before ':', or ''
--shape: fxCatalogue (ds global) = { n = int, entries = { [catalogueKey] = entry } }
--shape: entry = { ports = { ins = int, outs = int }, usage = { s = num, n0 = int } }  -- any field may be absent

local util = require 'util'

local fxCatalogue = {}

-- REAPER's own reaper-vstplugins key: the file name, every byte outside
-- [%w.<] spelt '_'. A shell file's plugins keep their '<id' suffix.
local function vstKey(ident)
  local file = ident:match('[^/\\]*$')
  return (file:gsub('[^%w.<]', '_'))
end

--post: result = vstKey(ident) if format begins 'VST', else ident
function fxCatalogue.key(format, ident)
  if format:sub(1, 3) == 'VST' then return vstKey(ident) end
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
--post: nil for an empty fx_ident; a VST resolves to the installed key its ident matches,
--      with or without its '<id', and to the bare file key when none matches; else key(fx_type, fx_ident)
function fxCatalogue.keyAt(track, fxIdx)
  local _, ident  = reaper.TrackFX_GetNamedConfigParm(track, fxIdx, 'fx_ident')
  if ident == '' then return nil end
  local _, fxType = reaper.TrackFX_GetNamedConfigParm(track, fxIdx, 'fx_type')
  if fxType:sub(1, 3) ~= 'VST' then return fxCatalogue.key(fxType, ident) end
  local withId = vstKey((ident:gsub('{%x+$', '')))
  local bare   = (withId:gsub('<.*$', ''))
  for _, row in ipairs(fxCatalogue.installed()) do
    if row.key == withId or row.key == bare then return row.key end
  end
  return bare
end

-- Usage decays per catalogue-wide use, not per day, so an unused month
-- costs nothing; 0.98 halves a score over about 34 uses.
local DECAY = 0.98

--post: catalogue n advances by 1; entries[key].usage decays by the uses since its n0, then +1
--post: entries[key].ports = ports; the entry's other fields kept
function fxCatalogue.recordUse(ds, key, ports)
  local catalogue = ds:get('fxCatalogue') or { n = 0, entries = {} }
  local n     = catalogue.n + 1
  local entry = catalogue.entries[key] or {}
  local usage = entry.usage
  entry.usage = { s = (usage and usage.s * DECAY ^ (n - usage.n0) or 0) + 1, n0 = n }
  entry.ports = ports
  catalogue.entries[key] = entry
  catalogue.n = n
  ds:assign('fxCatalogue', catalogue)
end

return fxCatalogue
