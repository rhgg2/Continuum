-- Bit-level surgery on the per-FX MIDI routing trailer encoded inside
-- an FXCHAIN's `<VST ...>` block. Encoding is documented in
-- docs/reaper_midi_routing.md; ground-truth captures live in
-- design/midi-routing-fixtures.md.

local t    = require('support')
local util = require('util')

local function wm()
  local cm = util.instantiate('configManager')
  return util.instantiate('wiringManager', { cm = cm })
end

-- Wrap a flag byte + bus pair into the synthetic block REAPER would
-- emit for a 3-byte plugin-state header.
--   first base64 line  : 00 <mirror_flag> 00
--   middle line        : opaque, never touched
--   trailer line       : 00 00 <flag> <in_bus> <out_bus> 00
local function mkChunk(opts)
  opts = opts or {}
  local first   = opts.first   or 'ABAA'      -- mirror_flag = 0x10
  local middle  = opts.middle  or 'D34dB33f'
  local trailer = opts.trailer or 'AAAQAAAA'  -- flag=0x10, in=0, out=0
  local fxBlock =
       '  <VST "VST: TestFX (Cockos)" testfx.vst.dylib 0 "" 1234567890 ""\n'
    .. '    ' .. first   .. '\n'
    .. '    ' .. middle  .. '\n'
    .. '    ' .. trailer .. '\n'
    .. '  >\n'
  return '<TRACK\n  NAME "x"\n  <FXCHAIN\n' .. fxBlock .. '  >\n>\n'
end

-- Pull out (first base64 line, trailer base64 line) from a single-FX chunk.
local function extractLines(chunk)
  local first, middle, trailer =
    chunk:match('<VST[^\n]*\n%s*(%S+)\n%s*(%S+)\n%s*(%S+)\n%s*>')
  return first, middle, trailer
end

return {
  {
    name = 'fxRouting: set disables output (default → out_disabled)',
    run = function()
      local chunk = mkChunk()
      local new, ok = wm().setFXOutputDisabled(chunk, 0, true)
      t.eq(ok, true, 'reported patched')
      local first, _, trailer = extractLines(new)
      t.eq(trailer, 'AAASAAAA', 'trailer flag 0x10 → 0x12')
      t.eq(first,   'ABIA',     'mirror flag 0x10 → 0x12')
    end,
  },
  {
    name = 'fxRouting: clear re-enables output (out_disabled → default)',
    run = function()
      local chunk = mkChunk({ first = 'ABIA', trailer = 'AAASAAAA' })
      local new, ok = wm().setFXOutputDisabled(chunk, 0, false)
      t.eq(ok, true)
      local first, _, trailer = extractLines(new)
      t.eq(trailer, 'AAAQAAAA', 'trailer flag 0x12 → 0x10')
      t.eq(first,   'ABAA',     'mirror flag 0x12 → 0x10')
    end,
  },
  {
    name = 'fxRouting: idempotent on repeated set',
    run = function()
      local fn  = wm().setFXOutputDisabled
      local one = (fn(mkChunk(), 0, true))
      local two = (fn(one,         0, true))
      t.eq(two, one, 'second set is a no-op')
    end,
  },
  {
    name = 'fxRouting: idempotent on repeated clear',
    run = function()
      local fn    = wm().setFXOutputDisabled
      local start = mkChunk({ first = 'ABIA', trailer = 'AAASAAAA' })
      local one   = (fn(start, 0, false))
      local two   = (fn(one,   0, false))
      t.eq(two, one)
    end,
  },
  {
    name = 'fxRouting: set→clear round-trips to the original chunk',
    run = function()
      local fn       = wm().setFXOutputDisabled
      local original = mkChunk()
      local disabled = (fn(original, 0, true))
      local restored = (fn(disabled, 0, false))
      t.eq(restored, original, 'round-trip restores byte-for-byte')
    end,
  },
  {
    name = 'fxRouting: preserves other flag bits (0x51 → 0x53 on set)',
    run = function()
      -- 0x51 = 0x40 sticky | 0x10 preset-state | 0x01 in_disabled
      local chunk = mkChunk({ first = 'AFEA', trailer = 'AABRAAAA' })
      local new   = (wm().setFXOutputDisabled(chunk, 0, true))
      local first, _, trailer = extractLines(new)
      t.eq(trailer, 'AABTAAAA', '0x51 → 0x53, sticky+preset+in preserved')
      t.eq(first,   'AFMA')
    end,
  },
  {
    name = 'fxRouting: preserves other flag bits (0x53 → 0x51 on clear)',
    run = function()
      local chunk = mkChunk({ first = 'AFMA', trailer = 'AABTAAAA' })
      local new   = (wm().setFXOutputDisabled(chunk, 0, false))
      local first, _, trailer = extractLines(new)
      t.eq(trailer, 'AABRAAAA', '0x53 → 0x51')
      t.eq(first,   'AFEA')
    end,
  },
  {
    name = 'fxRouting: preserves in_bus and out_bus',
    run = function()
      -- trailer: 00 00 10 01 02 00 — in_bus=2, out_bus=3, flag=0x10
      local chunk = mkChunk({ trailer = 'AAAQAQIA' })
      local new   = (wm().setFXOutputDisabled(chunk, 0, true))
      local _, _, trailer = extractLines(new)
      t.eq(trailer, 'AAASAQIA', 'bus bytes survived the flag patch')
    end,
  },
  {
    name = 'fxRouting: preserves the opaque middle line',
    run = function()
      local chunk = mkChunk({ middle = 'qrstuvwx' })
      local new   = (wm().setFXOutputDisabled(chunk, 0, true))
      local _, middle = extractLines(new)
      t.eq(middle, 'qrstuvwx', 'plugin state line untouched')
    end,
  },
  {
    name = 'fxRouting: out-of-range fxIdx returns chunk unchanged + false',
    run = function()
      local chunk      = mkChunk()
      local new, ok    = wm().setFXOutputDisabled(chunk, 7, true)
      t.eq(ok, false)
      t.eq(new, chunk, 'chunk preserved byte-for-byte on miss')
    end,
  },
  {
    name = 'fxRouting: multi-FX chain — patches only the requested index',
    run = function()
      local fx = function(first, trailer)
        return '  <VST "VST: x" x.vst.dylib 0 "" 1 ""\n'
            .. '    ' .. first   .. '\n'
            .. '    AAAA\n'
            .. '    ' .. trailer .. '\n'
            .. '  >\n'
      end
      local chunk = '<TRACK\n  <FXCHAIN\n'
                 .. fx('ABAA', 'AAAQAAAA')   -- fx 0: default
                 .. fx('ABAA', 'AAAQAAAA')   -- fx 1: default
                 .. fx('ABAA', 'AAAQAAAA')   -- fx 2: default
                 .. '  >\n>\n'
      local new = (wm().setFXOutputDisabled(chunk, 1, true))
      local trailers = {}
      for line in new:gmatch('AAA[QS]AAAA') do trailers[#trailers + 1] = line end
      t.eq(#trailers, 3, 'three trailers preserved')
      t.eq(trailers[1], 'AAAQAAAA', 'fx 0 unchanged')
      t.eq(trailers[2], 'AAASAAAA', 'fx 1 patched')
      t.eq(trailers[3], 'AAAQAAAA', 'fx 2 unchanged')
    end,
  },
  {
    name = 'fxRouting: JSFX block is not counted in fxIdx',
    run = function()
      local jsBlock = '  <JS Util/foo ""\n    0 0 0 -\n  >\n'
      local vstBlock =
           '  <VST "VST: x" x.vst.dylib 0 "" 1 ""\n'
        .. '    ABAA\n    AAAA\n    AAAQAAAA\n  >\n'
      local chunk = '<TRACK\n  <FXCHAIN\n' .. jsBlock .. vstBlock .. '  >\n>\n'
      local new, ok = wm().setFXOutputDisabled(chunk, 0, true)
      t.eq(ok, true, 'VST found at routing-index 0 despite JSFX above')
      t.truthy(new:find('AAASAAAA', 1, true), 'VST trailer was patched')
    end,
  },
}
