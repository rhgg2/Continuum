-- See docs/fs.md for the model.

--@map:invariant sole module touching reaper.Enumerate* and filesystem IO; UI/view layers route through here
--@map:invariant listDirs and listAudioFiles return case-insensitively sorted output (Finder/Explorer parity)

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

--@map:contract returns '' if path has no separator; trailing separators on input are not stripped (caller passes canonical paths)
function fs.parent(path)
  return path:match('^(.+)[/\\][^/\\]+$') or ''
end

--@map:contract inserts '/' between a and b unless a already ends in '/' or '\\'; no path normalisation
function fs.join(a, b)
  local last = a:sub(-1)
  if last == '/' or last == '\\' then return a .. b end
  return a .. '/' .. b
end

local function ciLess(a, b) return a:lower() < b:lower() end

--@map:contract hides dotfile-prefixed entries (.git, .DS_Store, etc.)
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

--@map:contract FNV-1a over (size, first 4KB, last 4KB); 8-char hex; non-cryptographic; see docs/fs.md
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
