-- The installed plugins, each under a catalogue key that survives an update
-- moving the plugin's files. REAPER builds the list once and serves it from memory.
--invariant: stateless; each call re-reads REAPER, so a plugin installed mid-session shows up
--shape: row = { key, name, ident, format }  -- ident raw from REAPER; format the name's prefix before ':', or ''

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

return fxCatalogue
