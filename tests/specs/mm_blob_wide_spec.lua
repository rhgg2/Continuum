-- 14-bit CC lives in the codec, not a registry: a fractional cc val on a code
-- in 0..31 splits to an MSB(shaped)/LSB(step) wire pair on serialise and
-- coalesces back on parse. The value's type is the whole signal -- integer val
-- stays a plain 7-bit CC, one wire event.

local t = require('support')
local util = require('util')
local midiBlob = require('midiBlob')

-- Raw channel-voice CC events straight off the blob, no coalescing.
local function wireCCs(blob)
  local out, pos, ppq = {}, 1, 0
  while pos < #blob - 12 do
    local offset, flags, msg, nextPos = string.unpack('i4Bs4', blob, pos)
    ppq, pos = ppq + offset, nextPos
    local status = msg:byte(1) or 0
    if status & 0xF0 == 0xB0 then
      out[#out + 1] = { ppq = ppq, cc = msg:byte(2), val = msg:byte(3), shape = (flags >> 4) & 7 }
    end
  end
  table.sort(out, function(a, b) if a.ppq ~= b.ppq then return a.ppq < b.ppq end return a.cc < b.cc end)
  return out
end

local function ccOf(extra)
  return util.assign(
    { idx = 0, ppq = 480, evType = 'cc', chan = 1, cc = 20, val = 100 + 5 / 128, shape = 'linear' },
    extra or {})
end

return {
  {
    name = 'fractional cc in 0..31 serialises to an MSB(shaped)/LSB(step) wire pair',
    run = function()
      local blob = midiBlob.serialise({}, { ccOf() }, {}, {})
      local wire = wireCCs(blob)
      t.eq(#wire, 2, 'one logical wide CC becomes two wire events')
      t.eq(wire[1].cc, 20, 'MSB on the code');       t.eq(wire[1].val, 100, 'MSB = floor(val)')
      t.eq(wire[1].shape, 1, 'MSB carries the authored shape (linear=1)')
      t.eq(wire[2].cc, 52, 'LSB on code + 32');      t.eq(wire[2].val, 5, 'LSB = frac * 128')
      t.eq(wire[2].shape, 0, 'LSB always steps')
      t.eq(wire[1].ppq, 480); t.eq(wire[2].ppq, 480, 'both at the same ppq')
    end,
  },

  {
    name = 'the wire pair coalesces back to one fractional record (round-trip)',
    run = function()
      local x = ccOf()
      local _, ccs = midiBlob.parse(midiBlob.serialise({}, { x }, {}, {}))
      t.eq(#ccs, 1, 'the LSB lane is hidden; one record surfaces')
      t.deepEq(ccs[1], x, 'record reconstructed exactly, idx contiguous')
    end,
  },

  {
    name = 'carrier-style value (14-bit around 8192) round-trips exactly',
    run = function()
      local x = ccOf({ val = (8192 + 100) / 128, shape = 'slow' })
      local _, ccs = midiBlob.parse(midiBlob.serialise({}, { x }, {}, {}))
      t.eq(#ccs, 1)
      t.eq(ccs[1].val * 128 - 8192, 100, '14-bit reconstructs the pb-delta exactly')
    end,
  },

  {
    name = 'integer cc in 0..31 stays a plain 7-bit CC: one wire event',
    run = function()
      local x = ccOf({ val = 64, shape = 'step' })
      local blob = midiBlob.serialise({}, { x }, {}, {})
      t.eq(#wireCCs(blob), 1, 'no LSB companion for an integer value')
      local _, ccs = midiBlob.parse(blob)
      t.eq(#ccs, 1); t.eq(ccs[1].val, 64)
    end,
  },

  {
    name = 'a lone LSB-range code (>= 32) with no MSB partner stays independent',
    run = function()
      local x = ccOf({ cc = 52, val = 40, shape = 'step' })
      local _, ccs = midiBlob.parse(midiBlob.serialise({}, { x }, {}, {}))
      t.eq(#ccs, 1); t.eq(ccs[1].cc, 52, 'unpaired code survives untouched')
      t.eq(ccs[1].val, 40)
    end,
  },

  {
    name = 'bezier wide cc keeps its tension on the MSB across the round-trip',
    run = function()
      local x = ccOf({ shape = 'bezier', tension = 0.5 })
      local _, ccs = midiBlob.parse(midiBlob.serialise({}, { x }, {}, {}))
      t.eq(#ccs, 1); t.eq(ccs[1].shape, 'bezier')
      t.eq(ccs[1].tension, 0.5, 'tension folded onto the coalesced MSB, not the LSB')
    end,
  },
}
