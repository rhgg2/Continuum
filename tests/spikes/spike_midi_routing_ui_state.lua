-- spike_midi_routing_ui_state.lua
--
-- Two-phase verification of the hypothesis that bit 0x40 of the FX
-- routing trailer's flag byte tracks UI window state (FX chain / I/O
-- dialog open) rather than routing semantics. Run as a ReaScript
-- action, bind to a hotkey, alternate "set + close windows + hotkey"
-- per phase.
--
-- Reuses the ctm_routing_spike track + ReaEQ instance left by
-- spike_midi_routing.lua. Uses its own ExtState namespace so the two
-- spikes don't tread on each other.
--
-- Expected if hypothesis holds:
--   phase 1: in=1, out=1, replace, all FX windows closed
--            → trailer flags = 0x10 (no 0x40)
--   phase 2: input DISABLED, out=1, replace, all FX windows closed
--            → trailer flags = 0x11 (0x10 | 0x01, no 0x40)
--
-- If either phase comes back with 0x40 set, the hypothesis is wrong
-- and 0x40 carries routing state we need to model.

local reaper = reaper
local fmt = string.format

local TRACK_NAME = 'ctm_routing_spike'
local FX_IDENTS  = { 'VST3:ReaEQ (Cockos)', 'VST:ReaEQ' }
local NS         = 'ctm_routing_spike_ui'

local PHASES = {
  { label = 'default+windows_closed',
    desc  = 'Set in_bus=1, out_bus=1, REPLACE. Then CLOSE the FX chain window AND the MIDI I/O dialog (all FX windows). Then hit hotkey.',
    expect = 'flags = 0x10 if 0x40 is UI-only' },
  { label = 'in_disabled+windows_closed',
    desc  = 'Set INPUT DISABLED, out_bus=1, REPLACE. Then CLOSE the FX chain window AND the MIDI I/O dialog. Then hit hotkey.',
    expect = 'flags = 0x11 if 0x40 is UI-only' },
}

----- Output / helpers (mirrors spike_midi_routing.lua)

local function out(s) reaper.ShowConsoleMsg(tostring(s) .. '\n') end
local function banner(s) out(''); out('=== ' .. s .. ' ===') end

local function hex(s)
  local t = {}
  for i = 1, #s do t[i] = fmt('%02X', s:byte(i)) end
  return table.concat(t, ' ')
end

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

local function getPhase()
  local s = reaper.GetExtState(NS, 'phase')
  return (s == '' or s == nil) and 0 or tonumber(s)
end

local function setPhase(p)   reaper.SetExtState(NS, 'phase', tostring(p), false) end
local function clearPhase()  reaper.DeleteExtState(NS, 'phase', false) end

local function findTrack(name)
  for i = 0, reaper.CountTracks(0) - 1 do
    local t = reaper.GetTrack(0, i)
    local _, n = reaper.GetSetMediaTrackInfo_String(t, 'P_NAME', '', false)
    if n == name then return t end
  end
end

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

local function printInstruction(phase)
  local p = PHASES[phase]
  banner(fmt('Next: phase %d/%d — %s', phase, #PHASES, p.label))
  out(p.desc)
  out('Expected: ' .. p.expect)
end

local function captureCurrentPhase(track, phase)
  local p = PHASES[phase]
  local _, chunk = reaper.GetTrackStateChunk(track, '', false)
  local b64lines = extractVstBase64(chunk)
  if not b64lines then out('[' .. p.label .. '] no <VST> block'); return end

  local first   = b64lines[1] or ''
  local trailer = b64lines[#b64lines] or ''
  local firstBytes   = b64decode(first)
  local trailerBytes = b64decode(trailer)
  local fL, tL = #firstBytes, #trailerBytes

  banner(fmt('Captured phase %d/%d — %s', phase, #PHASES, p.label))
  out('  desc              : ' .. p.desc)
  out('  expected          : ' .. p.expect)
  out(fmt('  first line tail-6 : %s',
          hex(firstBytes:sub(math.max(1, fL - 5), fL))))
  out(fmt('  trailer (last 6)  : %s',
          hex(trailerBytes:sub(math.max(1, tL - 5), tL))))
end

----- Main

local phase = getPhase()

if phase == 0 then
  reaper.ClearConsole()
  banner('midi-routing 0x40-UI-state spike')
  out('Track : ' .. TRACK_NAME .. ' (reusing the one from spike_midi_routing)')
  out(fmt('Phases: %d total', #PHASES))
  if not findTrack(TRACK_NAME) then
    out('Track not found — run spike_midi_routing.lua first to set it up.')
    return
  end
  setPhase(1)
  printInstruction(1)
  return
end

if phase > #PHASES then
  banner('reset')
  clearPhase()
  out('State cleared. Run again to start over.')
  return
end

local track = findTrack(TRACK_NAME)
if not track then
  out('Track ' .. TRACK_NAME .. ' missing — aborting.')
  clearPhase()
  return
end

captureCurrentPhase(track, phase)

local next = phase + 1
if next > #PHASES then
  banner('DONE')
  out('Both phases captured.')
  out('If both trailers came back without 0x40, hypothesis confirmed.')
  setPhase(next)
else
  setPhase(next)
  printInstruction(next)
end
