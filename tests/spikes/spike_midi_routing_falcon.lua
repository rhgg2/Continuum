-- spike_midi_routing_falcon.lua
--
-- Diagnostic: capture the structure of the FX-at-FX_IDX block on the
-- selected track BEFORE and AFTER you toggle "Output disabled" in the
-- FX's MIDI I/O dialog. The diff shows exactly which base64 line and
-- which decoded-byte offsets REAPER mutates — that's where the
-- surgery in wm.setFXOutputDisabled needs to write.
--
-- Workflow
-- --------
--   1. Select the track with Falcon (or whatever FX you're testing).
--   2. Make sure that FX is at index 0 (or edit FX_IDX below).
--   3. Open the FX's MIDI I/O dialog so you can flip the toggle.
--   4. With MIDI output ENABLED, run this script. Prints "BEFORE" dump.
--   5. In the dialog, set MIDI output to DISABLED.
--   6. Run again. Prints "AFTER" dump + a line-by-line / byte-by-byte
--      diff. The bytes that changed are the bytes the real surgery
--      needs to write.
--   7. Run a third time to reset state.
--
-- Read-only: never calls SetTrackStateChunk.

local reaper = reaper
local fmt    = string.format

local FX_IDX = 0
local NS     = 'ctm_falcon_routing'

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

----- Base64 decode

local B64 = {}
do
  local alphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
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

----- FX-block extraction

local function splitLines(s)
  local lines = {}
  for ln in s:gmatch('([^\n]*)\n') do lines[#lines + 1] = ln end
  return lines
end

-- Walks the chunk to the (fxIdx+1)-th non-JS FX block; returns the
-- inclusive line range `[header .. closing '>']` so the dump shows the
-- full bracketing as REAPER wrote it.
local function extractFxBlock(chunk, fxIdx)
  local lines = splitLines(chunk)
  local seen  = 0
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
            if depth == 0 then
              local block = {}
              for k = i, j do block[#block + 1] = lines[k] end
              return block
            end
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

----- Per-line classification / dump

local function classify(stripped)
  if stripped == '>'                          then return 'close' end
  if stripped:sub(1, 1) == '<'                then return 'open'  end
  if stripped:match('^[A-Za-z0-9%+/=]+$')     then return 'b64'   end
  return 'other'
end

-- Routing-trailer shape: 6 decoded bytes, first two and last byte zero.
local function looksLikeRoutingTrailer(bytes)
  return #bytes == 6
     and bytes:byte(1) == 0
     and bytes:byte(2) == 0
     and bytes:byte(6) == 0
end

local function dumpBlock(block, label)
  banner(label .. ' — FX block (' .. #block .. ' lines)')
  for i, ln in ipairs(block) do
    local stripped = ln:match('^%s*(.-)%s*$')
    local kind     = classify(stripped)
    if kind == 'b64' then
      local bytes = b64decode(stripped)
      local n     = #bytes
      local head  = hex(bytes:sub(1, math.min(6, n)))
      local tail  = hex(bytes:sub(math.max(1, n - 5), n))
      local tag   = looksLikeRoutingTrailer(bytes) and '  <-- ROUTING?' or ''
      out(fmt('  %3d  b64   %5d B   head: %-17s   tail: %-17s%s',
              i, n, head, tail, tag))
    else
      local short = #stripped > 90 and (stripped:sub(1, 87) .. '...') or stripped
      out(fmt('  %3d  %-5s             %s', i, kind, short))
    end
  end
end

----- Diff

local function diffBlocks(before, after)
  banner('DIFF — bytes that changed (before -> after)')
  if #before ~= #after then
    out(fmt('  line count changed: %d -> %d', #before, #after))
  end
  local n        = math.max(#before, #after)
  local anyDiff  = false
  for i = 1, n do
    local a = before[i] or ''
    local b = after[i]  or ''
    if a ~= b then
      anyDiff = true
      local stA = a:match('^%s*(.-)%s*$')
      local stB = b:match('^%s*(.-)%s*$')
      if classify(stA) == 'b64' and classify(stB) == 'b64' then
        local ba, bb = b64decode(stA), b64decode(stB)
        out(fmt('  line %d  (b64 %d B -> %d B):', i, #ba, #bb))
        local lim = math.max(#ba, #bb)
        for k = 1, lim do
          local x = (k <= #ba) and ba:byte(k) or nil
          local y = (k <= #bb) and bb:byte(k) or nil
          if x ~= y then
            out(fmt('    byte %d: %s -> %s',
                    k,
                    x and fmt('%02X', x) or '--',
                    y and fmt('%02X', y) or '--'))
          end
        end
      else
        out(fmt('  line %d  (non-b64):', i))
        out('    before: ' .. (a == '' and '<absent>' or a))
        out('    after : ' .. (b == '' and '<absent>' or b))
      end
    end
  end
  if not anyDiff then
    out('  (no differences — did the UI toggle actually flip?)')
  end
end

----- ExtState phase

local function getPhase()
  local s = reaper.GetExtState(NS, 'phase')
  return (s == '' or s == nil) and 0 or tonumber(s)
end

local function setPhase(p)
  reaper.SetExtState(NS, 'phase', tostring(p), false)
end

local function clearState()
  reaper.DeleteExtState(NS, 'phase',  false)
  reaper.DeleteExtState(NS, 'before', false)
end

local function serialiseBlock(block) return table.concat(block, '\n') end

local function deserialiseBlock(s)
  local lines = {}
  for ln in (s .. '\n'):gmatch('([^\n]*)\n') do lines[#lines + 1] = ln end
  if lines[#lines] == '' then lines[#lines] = nil end
  return lines
end

----- Main

local track = reaper.GetSelectedTrack(0, 0)
if not track then
  reaper.MB('Select a track first.', 'spike_midi_routing_falcon', 0)
  return
end
if reaper.TrackFX_GetCount(track) <= FX_IDX then
  reaper.MB(fmt('No FX at index %d on selected track.', FX_IDX),
           'spike_midi_routing_falcon', 0)
  return
end

local _, chunk = reaper.GetTrackStateChunk(track, '', false)
local block    = extractFxBlock(chunk, FX_IDX)
if not block then
  reaper.ClearConsole()
  out('No <VST|CLAP|AU> block found at fxIdx ' .. tostring(FX_IDX))
  return
end

local phase = getPhase()

if phase == 0 then
  reaper.ClearConsole()
  banner('Falcon routing capture — phase 1/2 (BEFORE)')
  out('Header: ' .. (block[1] or ''):match('^%s*(.-)%s*$'))
  dumpBlock(block, 'BEFORE')
  reaper.SetExtState(NS, 'before', serialiseBlock(block), false)
  setPhase(1)
  banner('Next')
  out('In the FX MIDI I/O dialog, toggle Output -> DISABLED.')
  out('Then run this script again.')
  return
end

if phase == 1 then
  banner('Falcon routing capture — phase 2/2 (AFTER)')
  dumpBlock(block, 'AFTER')
  local before = deserialiseBlock(reaper.GetExtState(NS, 'before'))
  diffBlocks(before, block)

  -- Focused: concat all b64 lines of the block into one decoded stream
  -- and report only bytes whose XOR is exactly 0x02. Plugin-state
  -- re-serialisation noise XORs to arbitrary patterns; an output-
  -- disabled flag flip XORs to exactly 0x02. So this filter shows
  -- exactly the routing-flag locations (mirror + trailer).
  local function concatDecoded(b)
    local parts = {}
    for _, ln in ipairs(b) do
      local stripped = ln:match('^%s*(.-)%s*$')
      if classify(stripped) == 'b64' then
        parts[#parts + 1] = b64decode(stripped)
      end
    end
    return table.concat(parts)
  end
  local bBefore = concatDecoded(before)
  local bAfter  = concatDecoded(block)
  banner('FOCUSED — concatenated decoded stream, bytes where XOR == 0x02')
  out(fmt('  stream length: before=%d  after=%d', #bBefore, #bAfter))
  if #bBefore == #bAfter then
    local hits = 0
    for k = 1, #bBefore do
      local x = bBefore:byte(k)
      local y = bAfter:byte(k)
      if (x ~ y) == 0x02 then
        out(fmt('  offset %d (0-indexed %d): %02X -> %02X', k, k - 1, x, y))
        hits = hits + 1
      end
    end
    out(fmt('  total 0x02-flip hits: %d', hits))
  else
    out('  (stream length differs — Falcon emitted a different state ' ..
        'size; can\'t do direct offset compare)')
  end

  clearState()
  banner('DONE')
  out('State cleared. Run again for a fresh cycle.')
  return
end

clearState()
out('(stale phase ' .. tostring(phase) .. ' — state cleared, run again)')
