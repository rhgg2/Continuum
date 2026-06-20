-- spike_midi_routing.lua
--
-- Ground-truth capture for the per-FX MIDI routing trailer encoding
-- documented in docs/reaper_midi_routing.md. Run as a ReaScript action,
-- ideally bound to a hotkey — each invocation advances one phase.
--
-- Workflow
-- --------
-- Bind this script to a hotkey (e.g. Shift+F12) and:
--
--   1. Run it once. The script creates a scratch track + ReaEQ instance
--      and prints the first config to set on the FX's MIDI I/O dialog.
--   2. In the FX chain window, right-click the FX → "MIDI I/O", set the
--      requested routing.
--   3. Hit the hotkey. The script captures the chunk for the current
--      config, prints the trailer bytes + first-line tail, and prints
--      the next config to set.
--   4. Repeat until "DONE" — the script clears its state and the next
--      run will start a fresh capture cycle.
--
-- To abort and start over, just run again past "DONE" — state resets.

local reaper = reaper
local fmt = string.format

local TRACK_NAME = 'ctm_routing_spike'
local FX_IDENTS  = { 'VST3:ReaEQ (Cockos)', 'VST:ReaEQ' }
local NS         = 'ctm_routing_spike'

local CAPTURE_CONFIGS = {
  { label = 'default',
    desc  = 'input enabled, output enabled, in_bus=1, out_bus=1, REPLACE' },
  { label = 'merge',
    desc  = 'input enabled, output enabled, in_bus=1, out_bus=1, MERGE' },
  { label = 'in_bus=2',
    desc  = 'in_bus=2, out_bus=1, REPLACE' },
  { label = 'out_bus=2',
    desc  = 'in_bus=1, out_bus=2, REPLACE' },
  { label = 'in_disabled',
    desc  = 'INPUT DISABLED, out_bus=1, REPLACE' },
  { label = 'out_disabled',
    desc  = 'in_bus=1, OUTPUT DISABLED, REPLACE' },
  { label = 'both_disabled',
    desc  = 'INPUT DISABLED, OUTPUT DISABLED' },
  { label = 'in_bus=128',
    desc  = 'in_bus=128, out_bus=128, REPLACE (boundary)' },
  { label = 'in_disabled+out_bus=1+replace',
    desc  = 'INPUT DISABLED, out_bus=1, REPLACE (doc says n+1 = 0x80 here)' },
}

----- Output

local function out(s) reaper.ShowConsoleMsg(tostring(s) .. '\n') end

local function hex(s)
  local t = {}
  for i = 1, #s do t[i] = fmt('%02X', s:byte(i)) end
  return table.concat(t, ' ')
end

local function banner(s)
  out('')
  out('=== ' .. s .. ' ===')
end

----- Base64 decode (Lua 5.4 bitwise)

local B64 = {}
do
  local alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  for i = 1, #alphabet do B64[alphabet:sub(i, i):byte()] = i - 1 end
end

local function b64decode(s)
  local bytes, buf, bits = {}, 0, 0
  for i = 1, #s do
    local c = s:byte(i)
    if c == 61 then break end
    local v = B64[c]
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

----- ExtState phase

local function getPhase()
  local s = reaper.GetExtState(NS, 'phase')
  return (s == '' or s == nil) and 0 or tonumber(s)
end

local function setPhase(p)
  reaper.SetExtState(NS, 'phase', tostring(p), false)
end

local function clearPhase()
  reaper.DeleteExtState(NS, 'phase', false)
end

----- Track / FX

local function findTrack(name)
  for i = 0, reaper.CountTracks(0) - 1 do
    local t = reaper.GetTrack(0, i)
    local _, n = reaper.GetSetMediaTrackInfo_String(t, 'P_NAME', '', false)
    if n == name then return t end
  end
end

local function ensureTrackWithFx()
  local t = findTrack(TRACK_NAME)
  if t and reaper.TrackFX_GetCount(t) > 0 then return t end
  if not t then
    reaper.InsertTrackAtIndex(reaper.CountTracks(0), false)
    t = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
    reaper.GetSetMediaTrackInfo_String(t, 'P_NAME', TRACK_NAME, true)
  end
  for _, ident in ipairs(FX_IDENTS) do
    if reaper.TrackFX_AddByName(t, ident, false, -1) >= 0 then return t end
  end
  reaper.MB('Could not insert ReaEQ. Edit FX_IDENTS in the script.',
           'spike_midi_routing', 0)
  error('no FX')
end

----- Chunk parsing

local function splitLines(s)
  local lines = {}
  for ln in s:gmatch('[^\n]+') do lines[#lines + 1] = ln end
  return lines
end

local function extractVstBase64(chunk)
  local lines = splitLines(chunk)
  for i, ln in ipairs(lines) do
    if ln:match('^%s*<VST%s') then
      local depth = 1
      for j = i + 1, #lines do
        local stripped = lines[j]:match('^%s*(.-)%s*$')
        if stripped == '>' then
          depth = depth - 1
          if depth == 0 then
            local b64 = {}
            for k = i + 1, j - 1 do b64[#b64 + 1] = lines[k] end
            return b64, lines[i]
          end
        elseif stripped:sub(1, 1) == '<' then
          depth = depth + 1
        end
      end
    end
  end
end

----- Capture + print

local function printConfigInstruction(phase)
  local cfg = CAPTURE_CONFIGS[phase]
  banner(fmt('Next: phase %d/%d — %s', phase, #CAPTURE_CONFIGS, cfg.label))
  out('Set the FX MIDI I/O dialog to:')
  out('  ' .. cfg.desc)
  out('Then hit the hotkey to capture.')
end

local function captureCurrentPhase(track, phase)
  local cfg = CAPTURE_CONFIGS[phase]
  local _, chunk = reaper.GetTrackStateChunk(track, '', false)
  local b64lines, header = extractVstBase64(chunk)
  if not b64lines then
    out('[' .. cfg.label .. '] no <VST> block found in track chunk')
    return
  end

  local first   = b64lines[1] or ''
  local trailer = b64lines[#b64lines] or ''
  local firstBytes   = b64decode(first)
  local trailerBytes = b64decode(trailer)
  local fL, tL = #firstBytes, #trailerBytes

  banner(fmt('Captured phase %d/%d — %s', phase, #CAPTURE_CONFIGS, cfg.label))
  out('  desc              : ' .. cfg.desc)
  out('  header line       : ' .. (header or ''))
  out('  base64 lines      : ' .. tostring(#b64lines))
  out(fmt('  first line bytes  : %d', fL))
  out(fmt('  first line tail-6 : %s',
          hex(firstBytes:sub(math.max(1, fL - 5), fL))))
  out(fmt('  trailer line bytes: %d', tL))
  out(fmt('  trailer (last 6)  : %s',
          hex(trailerBytes:sub(math.max(1, tL - 5), tL))))
end

----- Main

local phase = getPhase()

if phase == 0 then
  reaper.ClearConsole()
  banner('midi-routing capture spike')
  out('Track : ' .. TRACK_NAME)
  out('FX    : ' .. table.concat(FX_IDENTS, ' or '))
  out(fmt('Phases: %d total', #CAPTURE_CONFIGS))
  ensureTrackWithFx()
  setPhase(1)
  printConfigInstruction(1)
  return
end

if phase > #CAPTURE_CONFIGS then
  banner('reset')
  clearPhase()
  out('State cleared. Run again to start a fresh capture cycle.')
  return
end

local track = ensureTrackWithFx()
captureCurrentPhase(track, phase)

local next = phase + 1
if next > #CAPTURE_CONFIGS then
  banner('DONE')
  out('All ' .. tostring(#CAPTURE_CONFIGS) .. ' configs captured.')
  out('Paste the output above into design/midi-routing-fixtures.md.')
  out('Run again to clear state.')
  setPhase(next)
else
  setPhase(next)
  printConfigInstruction(next)
end
