-- Bit-level surgery on the per-FX MIDI routing flag.
--
-- Encoding documented in docs/reaper_midi_routing.md; ground-truth
-- captures live in design/midi-routing-fixtures.md. The flag exists in
-- two places that REAPER keeps in sync and reads from independently:
--
--   * the trailer line: last base64 content line of the <VST ...>
--     block, byte 3 of the decoded 6-byte trailer.
--   * a mirror inside REAPER's wrapper header at the head of the
--     concatenated decoded stream: 1-indexed offset 27 + 8*pinChannels,
--     where pinChannels = inputPins + outputPins (mono channels) as
--     reported by TrackFX_GetIOSize. Trailer-only writes do not take
--     effect — the mirror is read by REAPER's UI/runtime path.

local t    = require('support')
local util = require('util')

local function wm()
  local cm = util.instantiate('configManager')
  return util.instantiate('wiringManager', { cm = cm })
end

----- Local base64 codec for fixture construction (decoded-stream
----- aware so we can place a flag byte at any 1-indexed offset).

local ALPHA = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local DEC   = {}
for i = 1, #ALPHA do DEC[ALPHA:sub(i, i):byte()] = i - 1 end

local function b64decode(s)
  local bytes, buf, bits = {}, 0, 0
  for i = 1, #s do
    local c = s:byte(i)
    if c == 61 then break end
    local v = DEC[c]
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
  local out, buf, bits = {}, 0, 0
  for i = 1, #s do
    buf  = buf * 256 + s:byte(i)
    bits = bits + 8
    while bits >= 6 do
      bits = bits - 6
      local v = (buf >> bits) & 0x3F
      out[#out + 1] = ALPHA:sub(v + 1, v + 1)
      buf = buf - (v << bits)
    end
  end
  if bits > 0 then
    local v = (buf << (6 - bits)) & 0x3F
    out[#out + 1] = ALPHA:sub(v + 1, v + 1)
  end
  while #out % 4 ~= 0 do out[#out + 1] = '=' end
  return table.concat(out)
end

----- Synthesise an <FXCHAIN> with one or more <VST> blocks.

-- Build the lines of a single <VST> block with a realistic REAPER
-- wrapper. opts: { pinChannels=4, flag=0x10, trailerFlag=flag, inBus=0,
-- outBus=0, streamLen=200, lineSplit=#stream }.
--
-- Wrapper bytes 1..(27+8*pc) are fillers + flag at 1-indexed offset
-- (27+8*pc), then a single 0x00 pad. Plugin state pads the wrapper+
-- state stream up to streamLen bytes. Trailer is the canonical
-- 6-byte routing trailer. If lineSplit is set, the stream is split
-- into b64 lines of that decoded-byte width; otherwise one line.
local function buildFxBlock(opts)
  opts = opts or {}
  local pinChannels = opts.pinChannels or 4
  local flag        = opts.flag or 0x10
  local trailerFlag = opts.trailerFlag or flag
  local inBus       = opts.inBus or 0
  local outBus      = opts.outBus or 0

  local fillerByte  = '\xAB'
  local mirrorOff   = 27 + 8 * pinChannels
  local wrapper     = string.rep(fillerByte, mirrorOff - 1)
                   .. string.char(flag)
                   .. '\0'
  local streamLen   = opts.streamLen or math.max(#wrapper + 32, 200)
  local pluginState = string.rep(fillerByte, streamLen - #wrapper)
  local stream      = wrapper .. pluginState
  local trailer     = string.char(0, 0, trailerFlag, inBus, outBus, 0)

  local lines  = {}
  local splitN = opts.lineSplit or #stream
  for i = 1, #stream, splitN do
    lines[#lines + 1] = '    ' .. b64encode(stream:sub(i, i + splitN - 1))
  end

  local block = {
    '  <VST "VST: TestFX (Cockos)" testfx.vst.dylib 0 "" 1234567890 ""',
  }
  for _, l in ipairs(lines) do block[#block + 1] = l end
  block[#block + 1] = '    ' .. b64encode(trailer)
  block[#block + 1] = '  >'
  return block
end

local function wrapTrack(fxBlocks)
  local out = { '<TRACK', '  NAME "x"', '  <FXCHAIN' }
  for _, blk in ipairs(fxBlocks) do
    for _, ln in ipairs(blk) do out[#out + 1] = ln end
  end
  out[#out + 1] = '  >'
  out[#out + 1] = '>'
  return table.concat(out, '\n') .. '\n'
end

local function mkChunk(opts) return wrapTrack({ buildFxBlock(opts) }) end

local function mkMultiChunk(blockOpts)
  local blocks = {}
  for i, o in ipairs(blockOpts) do blocks[i] = buildFxBlock(o) end
  return wrapTrack(blocks)
end

----- Extract decoded mirror/trailer bytes from the nth <VST> block.

-- Returns (mirror, trailerFlag, inBus, outBus) for the (blockIdx+1)-th
-- VST block (0-indexed) given its pinChannels.
local function extractBytes(chunk, pinChannels, blockIdx)
  blockIdx = blockIdx or 0
  local lines, content = {}, nil
  for ln in chunk:gmatch('([^\n]*)\n') do lines[#lines + 1] = ln end
  local seen = 0
  local i = 1
  while i <= #lines do
    local ln = lines[i]
    if ln:match('^%s*<VST%s')
       or ln:match('^%s*<CLAP%s')
       or ln:match('^%s*<AU%s') then
      if seen == blockIdx then
        content = {}
        local depth = 1
        for j = i + 1, #lines do
          local s = lines[j]:match('^%s*(.-)%s*$')
          if s == '>' then
            depth = depth - 1
            if depth == 0 then break end
          elseif s:sub(1, 1) == '<' then
            depth = depth + 1
          elseif depth == 1 and s:match('^[A-Za-z0-9%+/=]+$') then
            content[#content + 1] = b64decode(s)
          end
        end
        break
      end
      seen = seen + 1
    end
    i = i + 1
  end
  if not content then return nil end
  local stream = table.concat(content)
  return stream:byte(27 + 8 * pinChannels),
         stream:byte(#stream - 3),
         stream:byte(#stream - 2),
         stream:byte(#stream - 1)
end

return {
  ----- Flag transitions (pinChannels=4 baseline)
  {
    name = 'fxRouting: set disables output (default -> out_disabled)',
    run = function()
      local chunk = mkChunk()
      local new, ok = wm().setFXOutputDisabled(chunk, 0, true, 4)
      t.eq(ok, true)
      local m, tf = extractBytes(new, 4)
      t.eq(m,  0x12, 'mirror 0x10 -> 0x12')
      t.eq(tf, 0x12, 'trailer 0x10 -> 0x12')
    end,
  },
  {
    name = 'fxRouting: clear re-enables output',
    run = function()
      local chunk = mkChunk({ flag = 0x12 })
      local new, ok = wm().setFXOutputDisabled(chunk, 0, false, 4)
      t.eq(ok, true)
      local m, tf = extractBytes(new, 4)
      t.eq(m,  0x10)
      t.eq(tf, 0x10)
    end,
  },
  {
    name = 'fxRouting: idempotent on repeated set',
    run = function()
      local fn  = wm().setFXOutputDisabled
      local one = (fn(mkChunk(), 0, true, 4))
      local two = (fn(one,       0, true, 4))
      t.eq(two, one, 'second set is a no-op')
    end,
  },
  {
    name = 'fxRouting: idempotent on repeated clear',
    run = function()
      local fn    = wm().setFXOutputDisabled
      local start = mkChunk({ flag = 0x12 })
      local one   = (fn(start, 0, false, 4))
      local two   = (fn(one,   0, false, 4))
      t.eq(two, one)
    end,
  },
  {
    name = 'fxRouting: set->clear round-trips to the original chunk',
    run = function()
      local fn       = wm().setFXOutputDisabled
      local original = mkChunk()
      local disabled = (fn(original, 0, true,  4))
      local restored = (fn(disabled, 0, false, 4))
      t.eq(restored, original, 'byte-for-byte round-trip')
    end,
  },

  ----- Bit preservation
  {
    name = 'fxRouting: preserves other flag bits on set (0x51 -> 0x53)',
    run = function()
      -- 0x51 = sticky | preset-state | in_disabled
      local chunk = mkChunk({ flag = 0x51 })
      local new   = (wm().setFXOutputDisabled(chunk, 0, true, 4))
      local m, tf = extractBytes(new, 4)
      t.eq(m,  0x53, 'sticky + preset + in_disabled preserved')
      t.eq(tf, 0x53)
    end,
  },
  {
    name = 'fxRouting: preserves other flag bits on clear (0x53 -> 0x51)',
    run = function()
      local chunk = mkChunk({ flag = 0x53 })
      local new   = (wm().setFXOutputDisabled(chunk, 0, false, 4))
      local m, tf = extractBytes(new, 4)
      t.eq(m,  0x51)
      t.eq(tf, 0x51)
    end,
  },
  {
    name = 'fxRouting: preserves in_bus and out_bus',
    run = function()
      local chunk = mkChunk({ inBus = 1, outBus = 2 })
      local new   = (wm().setFXOutputDisabled(chunk, 0, true, 4))
      local _, _, inBus, outBus = extractBytes(new, 4)
      t.eq(inBus,  1, 'in_bus survived flag patch')
      t.eq(outBus, 2, 'out_bus survived flag patch')
    end,
  },

  ----- Bounds
  {
    name = 'fxRouting: out-of-range fxIdx returns chunk unchanged + false',
    run = function()
      local chunk   = mkChunk()
      local new, ok = wm().setFXOutputDisabled(chunk, 7, true, 4)
      t.eq(ok, false)
      t.eq(new, chunk, 'chunk preserved byte-for-byte on miss')
    end,
  },

  ----- Mirror offset varies with pinChannels (the real bug)
  {
    name = 'fxRouting: mirror at pinChannels=10 (Softube, offset 107)',
    run = function()
      local chunk = mkChunk({ pinChannels = 10, streamLen = 250 })
      local new   = (wm().setFXOutputDisabled(chunk, 0, true, 10))
      local m, tf = extractBytes(new, 10)
      t.eq(m,  0x12, 'mirror at offset 107 patched')
      t.eq(tf, 0x12)
    end,
  },
  {
    name = 'fxRouting: mirror at pinChannels=34 (Falcon, offset 299)',
    run = function()
      local chunk = mkChunk({ pinChannels = 34, streamLen = 600 })
      local new   = (wm().setFXOutputDisabled(chunk, 0, true, 34))
      local m, tf = extractBytes(new, 34)
      t.eq(m,  0x12, 'mirror at offset 299 patched')
      t.eq(tf, 0x12)
    end,
  },

  ----- Walker locates the mirror across base64 line boundaries
  {
    name = 'fxRouting: mirror landing on a non-first b64 line',
    run = function()
      -- pinChannels=4 -> mirror at offset 59. lineSplit=30 -> mirror
      -- falls in the second content line (bytes 31..60), within-byte 29.
      local chunk = mkChunk({ pinChannels = 4, lineSplit = 30 })
      local new   = (wm().setFXOutputDisabled(chunk, 0, true, 4))
      local m, tf = extractBytes(new, 4)
      t.eq(m,  0x12, 'walker crossed a b64 line break')
      t.eq(tf, 0x12)
    end,
  },
  {
    name = 'fxRouting: Falcon-shape mirror across multiple lines',
    run = function()
      -- pinChannels=34 -> mirror at offset 299. lineSplit=210 mimics
      -- REAPER's observed wrap (Falcon dump: 210-byte lines), so the
      -- mirror lands on the 2nd content line at within-byte 89.
      local chunk = mkChunk({ pinChannels = 34, streamLen = 1552, lineSplit = 210 })
      local new   = (wm().setFXOutputDisabled(chunk, 0, true, 34))
      local m, tf = extractBytes(new, 34)
      t.eq(m,  0x12)
      t.eq(tf, 0x12)
    end,
  },

  ----- Multi-FX chain + JSFX skipping
  {
    name = 'fxRouting: multi-FX chain — patches only the requested index',
    run = function()
      local chunk = mkMultiChunk({
        { pinChannels = 4 },
        { pinChannels = 4 },
        { pinChannels = 4 },
      })
      local new = (wm().setFXOutputDisabled(chunk, 1, true, 4))
      local m0, t0 = extractBytes(new, 4, 0)
      local m1, t1 = extractBytes(new, 4, 1)
      local m2, t2 = extractBytes(new, 4, 2)
      t.eq(m0, 0x10, 'fx 0 mirror unchanged')
      t.eq(t0, 0x10, 'fx 0 trailer unchanged')
      t.eq(m1, 0x12, 'fx 1 mirror patched')
      t.eq(t1, 0x12, 'fx 1 trailer patched')
      t.eq(m2, 0x10, 'fx 2 mirror unchanged')
      t.eq(t2, 0x10, 'fx 2 trailer unchanged')
    end,
  },
  {
    name = 'fxRouting: JSFX block is not counted in fxIdx',
    run = function()
      local jsBlock = {
        '  <JS Util/foo ""',
        '    0 0 0 -',
        '  >',
      }
      local vst = buildFxBlock({ pinChannels = 4 })
      local chunk = wrapTrack({ jsBlock, vst })
      local new, ok = wm().setFXOutputDisabled(chunk, 0, true, 4)
      t.eq(ok, true, 'VST found at routing-index 0 despite JSFX above')
      local m, tf = extractBytes(new, 4)
      t.eq(m,  0x12)
      t.eq(tf, 0x12)
    end,
  },
}
