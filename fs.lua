-- Pure filesystem helpers used by sampleView's browser. Keeps path
-- string-mangling and reaper.Enumerate* iteration in one place so the UI
-- never speaks to the reaper API directly. `listDirs`/`listAudioFiles`
-- sort case-insensitively to match user expectations from Finder/Explorer.

fs = {}

local AUDIO_EXTS = {
  wav = true, aif = true, aiff = true, flac = true,
  mp3 = true, ogg = true, opus = true, m4a = true,
}

function fs.isAudio(name)
  local ext = name:match('%.([^.]+)$')
  if not ext then return false end
  return AUDIO_EXTS[ext:lower()] == true
end

function fs.basename(path)
  return path:match('([^/\\]+)$') or path
end

-- Returns the parent directory, or '' for a path with no separator.
-- Trailing separators on the input are not stripped — caller is
-- expected to pass canonical paths.
function fs.parent(path)
  return path:match('^(.+)[/\\][^/\\]+$') or ''
end

function fs.join(a, b)
  local last = a:sub(-1)
  if last == '/' or last == '\\' then return a .. b end
  return a .. '/' .. b
end

local function ciLess(a, b) return a:lower() < b:lower() end

function fs.listDirs(path)
  local out, i = {}, 0
  while true do
    local sub = reaper.EnumerateSubdirectories(path, i)
    if not sub then break end
    if sub:sub(1, 1) ~= '.' then out[#out + 1] = sub end
    i = i + 1
  end
  table.sort(out, ciLess)
  return out
end

function fs.exists(path)
  local f = io.open(path, 'rb')
  if f then f:close(); return true end
  return false
end

-- Non-cryptographic content fingerprint as 8-char hex. Reads only
-- size + first/last 4KB so a 30MB sample hashes in microseconds. Two
-- distinct audio files colliding in size *and* both endpoints is
-- vanishingly unlikely; sufficient for "is this the same file?" dedup,
-- not for security.
function fs.hashFile(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  f:seek('end')
  local size = f:seek()
  f:seek('set', 0)
  local head = f:read(4096) or ''
  local tail = ''
  if size > 8192 then
    f:seek('set', size - 4096)
    tail = f:read(4096) or ''
  end
  f:close()
  local data = string.format('%d\0', size) .. head .. tail
  local h = 2166136261
  for i = 1, #data do
    h = ((h ~ data:byte(i)) * 16777619) & 0xFFFFFFFF
  end
  return string.format('%08x', h)
end

function fs.listAudioFiles(path)
  local out, i = {}, 0
  while true do
    local f = reaper.EnumerateFiles(path, i)
    if not f then break end
    if fs.isAudio(f) then out[#out + 1] = f end
    i = i + 1
  end
  table.sort(out, ciLess)
  return out
end
