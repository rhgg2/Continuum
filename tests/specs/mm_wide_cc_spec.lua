-- 14-bit CC primitive (design/note-macros.md § Continuous realisation).
-- A wideCC-registered MSB code carries a fixed-point value 0..127.99..; mm
-- splits it to an MSB(shaped)/LSB(step) wire pair on write and coalesces it
-- back on read. The code is the only signal -- the wire pair is not
-- self-describing -- so an unregistered code stays a plain 7-bit CC, one
-- message, integer value.

local t = require('support')
local realMM = require('realMidiManager')()

local STEP, LINEAR = 0, 1   -- MIDI_*CCShape indices (mm's shapeLUT)

local function freshTake(name)
  local fakeReaper = require('fakeReaper').new()
  _G.reaper = fakeReaper
  local take = name or 'take-wide-cc'
  fakeReaper:bindTake(take, take .. '/item', take .. '/track')
  return take, fakeReaper
end

-- Raw wire CCs straight from REAPER, bypassing mm's coalescing. cc-sorted.
local function wireCCs(rp, take)
  local _, _, n = rp.MIDI_CountEvts(take)
  local out = {}
  for i = 0, n - 1 do
    local ok, _, _, ppq, _, chan, msg2, msg3 = rp.MIDI_GetCC(take, i)
    if ok then
      local _, shape = rp.MIDI_GetCCShape(take, i)
      out[#out + 1] = { ppq = ppq, chan = chan, cc = msg2, val = msg3, shape = shape }
    end
  end
  table.sort(out, function(a, b) return a.cc < b.cc end)
  return out
end

local function readCCs(mm)
  local out = {}
  for _, c in mm:ccs() do out[#out + 1] = c end
  table.sort(out, function(a, b)
    if a.ppq ~= b.ppq then return a.ppq < b.ppq end
    return (a.cc or 0) < (b.cc or 0)
  end)
  return out
end

return {
  {
    name = 'wide CC write splits into an MSB-shaped / LSB-step wire pair',
    run = function()
      local take, rp = freshTake()
      local mm = realMM(take)
      mm:wideCC(1, 20, true)
      mm:modify(function()
        mm:add{ evType = 'cc', chan = 1, cc = 20, ppq = 480, val = 100 + 5 / 128, shape = 'linear' }
      end)

      local wire = wireCCs(rp, take)
      t.eq(#wire, 2, 'one logical wide CC becomes two wire events')
      t.eq(wire[1].cc, 20, 'MSB on the registered code')
      t.eq(wire[1].val, 100, 'MSB = floor(val)')
      t.eq(wire[1].shape, LINEAR, 'MSB carries the authored shape')
      t.eq(wire[1].ppq, 480)
      t.eq(wire[2].cc, 52, 'LSB on code + 32')
      t.eq(wire[2].val, 5, 'LSB = fractional * 128')
      t.eq(wire[2].shape, STEP, 'LSB always steps')
      t.eq(wire[2].ppq, 480)
    end,
  },

  {
    name = 'wide CC reads back as one coalesced fixed-point event (round-trip)',
    run = function()
      local take = freshTake()
      local mm = realMM(take)
      mm:wideCC(1, 20, true)
      mm:modify(function()
        mm:add{ evType = 'cc', chan = 1, cc = 20, ppq = 480, val = 100 + 5 / 128, shape = 'linear' }
      end)

      -- A second instance against the same take is a reload; wideCC is
      -- transient mm state, re-declared before the coalescing read.
      local mm2 = realMM(take)
      mm2:wideCC(1, 20, true)
      local cs = readCCs(mm2)
      t.eq(#cs, 1, 'the LSB lane is hidden; one event surfaces')
      t.eq(cs[1].cc, 20)
      t.eq(cs[1].val, 100 + 5 / 128, 'value reconstructed exactly')
      t.eq(cs[1].shape, 'linear', 'MSB shape surfaces')
    end,
  },

  {
    name = 'carrier-style value (14-bit around 8192) round-trips exactly',
    run = function()
      local take = freshTake()
      local mm = realMM(take)
      mm:wideCC(1, 20, true)
      local v = (8192 + 100) / 128   -- a pb-delta of +100 raw units, fixed-point
      mm:modify(function()
        mm:add{ evType = 'cc', chan = 1, cc = 20, ppq = 240, val = v }
      end)
      local mm2 = realMM(take); mm2:wideCC(1, 20, true)
      local cs = readCCs(mm2)
      t.eq(#cs, 1)
      t.eq(cs[1].val * 128 - 8192, 100, '14-bit reconstructs the pb-delta exactly')
    end,
  },

  {
    name = 'a registered MSB with no LSB partner upgrades to 14-bit (LSB 0)',
    run = function()
      local take, rp = freshTake()
      -- Plant a lone 7-bit CC20 on the wire, as foreign MIDI would.
      rp.MIDI_InsertCC(take, false, false, 240, 0xB0, 0, 20, 77)

      local mm = realMM(take)
      mm:wideCC(1, 20, true)
      local cs = readCCs(mm)
      t.eq(#cs, 1, 'the lone MSB surfaces as one event')
      t.eq(cs[1].cc, 20)
      t.eq(cs[1].val, 77, 'upgraded with LSB 0 -> integer value')
    end,
  },

  {
    name = 'plain (unregistered) CC is untouched: one message, integer value',
    run = function()
      local take, rp = freshTake()
      local mm = realMM(take)
      -- code 20 is NOT registered on this instance.
      mm:modify(function()
        mm:add{ evType = 'cc', chan = 1, cc = 20, ppq = 240, val = 64 }
      end)
      t.eq(#wireCCs(rp, take), 1, 'no LSB companion for an unregistered code')
      local cs = readCCs(mm)
      t.eq(#cs, 1); t.eq(cs[1].val, 64)
    end,
  },

  {
    name = 'deleting a wide CC removes both wire lanes',
    run = function()
      local take, rp = freshTake()
      local mm = realMM(take)
      mm:wideCC(1, 20, true)
      local tok
      mm:modify(function()
        tok = mm:add{ evType = 'cc', chan = 1, cc = 20, ppq = 480, val = 100 + 5 / 128, shape = 'linear' }
      end)
      t.eq(#wireCCs(rp, take), 2, 'pair present before delete')
      mm:modify(function() mm:delete(tok) end)
      t.eq(#wireCCs(rp, take), 0, 'both MSB and LSB gone')
    end,
  },

  {
    name = 'wideCC registration clears on take swap (per-take, not inherited)',
    run = function()
      local takeA, rp = freshTake('take-A')
      rp:bindTake('take-B', 'take-B/item', 'take-B/track')
      local mm = realMM(takeA)
      mm:wideCC(1, 20, true)

      -- Swap to a different take; cc20 there is a plain 7-bit code, not a carrier.
      mm:load('take-B')
      mm:modify(function()
        mm:add{ evType = 'cc', chan = 1, cc = 20, ppq = 240, val = 64 }
      end)
      t.eq(#wireCCs(rp, 'take-B'), 1, 'no LSB companion: registration did not survive the swap')
    end,
  },
}
