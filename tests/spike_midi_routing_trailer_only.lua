-- spike_midi_routing_trailer_only.lua
--
-- One-shot experiment: patch ONLY the 6-byte routing trailer of the
-- selected track's FX[FX_IDX]. No mirror write. Toggles the output-
-- disabled bit (0x02) on each invocation.
--
-- Verifies the hypothesis that the mirror byte in REAPER's wrapper
-- header is a write-back cache, not a read-back source — i.e. that
-- trailer-only surgery is sufficient to drive the FX MIDI I/O dialog.
--
-- Workflow
-- --------
--   1. Select the track with the FX of interest.
--   2. Open the FX's MIDI I/O dialog so you can watch it.
--   3. Run the script. Console prints what it did. Dialog should flip
--      "Output bus: 1" <-> "Output: DISABLED".
--   4. Run again to flip back.
--
-- If the dialog tracks correctly across several toggles, the mirror
-- write in wm.setFXOutputDisabled is redundant and the surgery can be
-- collapsed to trailer-only.

local reaper = reaper
local fmt    = string.format

local FX_IDX = 0

----- Output

local function out(s) reaper.ShowConsoleMsg(tostring(s) .. '\n') end

----- Base64

local B64D, B64E = {}, {}
do
  local alphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  for i = 1, #alphabet do
    B64D[alphabet:sub(i, i):byte()] = i - 1
    B64E[i - 1] = alphabet:sub(i, i)
  end
end

local function b64decode(s)
  local bytes, buf, bits = {}, 0, 0
  for i = 1, #s do
    local c = s:byte(i)
    if c == 61 then break end
    local v = B64D[c]
    if v then
      buf  = buf * 64 + v
      bits = bits + 6
      if bits >= 8 then
        bits = bits - 8
        local b = buf >> bits
        buf = buf - (b << bits)
        bytes[#bytes + 1] = string.char(b)
      end
    end
  end
  return table.concat(bytes)
end

local function b64encode(s)
  local out_, buf, bits = {}, 0, 0
  for i = 1, #s do
    buf  = buf * 256 + s:byte(i)
    bits = bits + 8
    while bits >= 6 do
      bits = bits - 6
      local v = (buf >> bits) & 0x3F
      out_[#out_ + 1] = B64E[v]
      buf = buf - (v << bits)
    end
  end
  if bits > 0 then
    local v = (buf << (6 - bits)) & 0x3F
    out_[#out_ + 1] = B64E[v]
  end
  while #out_ % 4 ~= 0 do out_[#out_ + 1] = '=' end
  return table.concat(out_)
end

----- Chunk parsing and surgery

local function splitLines(s)
  local hasTrailing = s:sub(-1) == '\n'
  local body  = hasTrailing and s or s .. '\n'
  local lines = {}
  for ln in body:gmatch('([^\n]*)\n') do lines[#lines + 1] = ln end
  return lines, hasTrailing
end

local function joinLines(lines, hasTrailing)
  return table.concat(lines, '\n') .. (hasTrailing and '\n' or '')
end

-- Locate the (fxIdx+1)-th non-JS FX block and return (firstContentLine,
-- trailerLine). Mirrors fxRouting.findFxBlock in wiringManager.lua.
local function findFxBlock(lines, fxIdx)
  local seen = 0
  for i, ln in ipairs(lines) do
    if ln:match('^%s*<VST%s')
       or ln:match('^%s*<CLAP%s')
       or ln:match('^%s*<AU%s') then
      if seen == fxIdx then
        local depth = 1
        for j = i + 1, #lines do
          local stripped = lines[j]:match('^%s*(.-)%s*$')
          if stripped == '>' then
            depth = depth - 1
            if depth == 0 then return i + 1, j - 1 end
          elseif stripped:sub(1, 1) == '<' then
            depth = depth + 1
          end
        end
        return
      end
      seen = seen + 1
    end
  end
end

-- Read-modify-write the 0x02 bit at byteIdx (1-indexed) of a base64
-- line. Preserves leading and trailing whitespace exactly.
local function setBit02(line, byteIdx, on)
  local lead, content, tail = line:match('^(%s*)(%S*)(%s*)$')
  if not content or content == '' then return line, nil, nil end
  local bytes = b64decode(content)
  if byteIdx < 1 or byteIdx > #bytes then return line, nil, nil end
  local before = bytes:byte(byteIdx)
  local after  = on and (before | 0x02) or (before & ~0x02)
  if after == before then return line, before, after end
  local patched = bytes:sub(1, byteIdx - 1)
               .. string.char(after)
               .. bytes:sub(byteIdx + 1)
  return lead .. b64encode(patched) .. tail, before, after
end

----- Main

local track = reaper.GetSelectedTrack(0, 0)
if not track then
  reaper.MB('Select a track first.', 'spike_midi_routing_trailer_only', 0)
  return
end
if reaper.TrackFX_GetCount(track) <= FX_IDX then
  reaper.MB(fmt('No FX at index %d on selected track.', FX_IDX),
           'spike_midi_routing_trailer_only', 0)
  return
end

local _, chunk = reaper.GetTrackStateChunk(track, '', false)
local lines, hasTrailing = splitLines(chunk)
local _, trailerIdx      = findFxBlock(lines, FX_IDX)
if not trailerIdx then
  reaper.ClearConsole()
  out('No <VST|CLAP|AU> block found at fxIdx ' .. tostring(FX_IDX))
  return
end

-- Read current state, then write the opposite. Toggles on every run.
local trailerLine = lines[trailerIdx]
local trailerBytes = b64decode((trailerLine:match('^%s*(%S+)%s*$')))
local currentDisabled = (trailerBytes:byte(3) or 0) & 0x02 ~= 0
local nextDisabled    = not currentDisabled

local newLine, before, after = setBit02(trailerLine, 3, nextDisabled)
lines[trailerIdx] = newLine

local ok = reaper.SetTrackStateChunk(track,
                                     joinLines(lines, hasTrailing),
                                     false)

reaper.ClearConsole()
out('=== trailer-only routing surgery ===')
out(fmt('FX[%d] trailer line:      %d', FX_IDX, trailerIdx))
out(fmt('flag byte (3 of trailer): %02X -> %02X (output %s)',
        before or 0,
        after  or 0,
        nextDisabled and 'DISABLED' or 'ENABLED'))
out(fmt('SetTrackStateChunk: %s', tostring(ok)))
out('')
out('Now check the FX MIDI I/O dialog. Did it follow?')
