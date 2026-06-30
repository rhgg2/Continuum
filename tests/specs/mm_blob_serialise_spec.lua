-- Round-trip pin for midiBlob.serialise (inverse of parse).
--
-- serialise is the write-path codec: mm-shape records -> a MIDI_SetAllEvts blob.
-- The contract is parse(serialise(x)) == x -- byte layout may reorder events that
-- share a ppq, but the per-type record lists round-trip identically. Passthrough
-- carries events parse doesn't model so a whole-take rewrite stays lossless.

local t = require('support')
local midiBlob = require('midiBlob')
local fixtures = require('fixtures.midi_blobs')

local tests = {}

for _, f in ipairs(fixtures) do
  tests[#tests + 1] = {
    name = 'records survive serialise -> parse: ' .. f.name,
    run = function()
      local _, _, _, passthrough = midiBlob.parse(f.blob)
      local blob = midiBlob.serialise(f.notes, f.ccs, f.texts, passthrough)
      local notes, ccs, texts = midiBlob.parse(blob)
      t.deepEq(notes, f.notes, f.name .. ' notes')
      t.deepEq(ccs,   f.ccs,   f.name .. ' ccs')
      t.deepEq(texts, f.texts, f.name .. ' texts')
    end,
  }
end

tests[#tests + 1] = {
  name = 'unmodelled events round-trip through passthrough',
  run = function()
    local function evt(off, flags, msg) return string.pack('i4Bs4', off, flags, msg) end
    local blob = evt(0, 0, '\xF2\x01\x02') .. evt(0, 0, '\xB0\x7B\x00')   -- F2 event + tail
    local notes, ccs, texts, passthrough = midiBlob.parse(blob)
    t.eq(#passthrough, 1, 'F2 captured as passthrough')
    t.eq(passthrough[1].msg, '\xF2\x01\x02', 'raw bytes preserved')
    local _, _, _, pt2 = midiBlob.parse(midiBlob.serialise(notes, ccs, texts, passthrough))
    t.deepEq(pt2, passthrough, 'passthrough survives the round-trip')
  end,
}

-- The trailing all-notes-off marker carries the take length (EOT); endPpq
-- places it past the last event so a whole-take rewrite never shrinks the take.
local function tailPpq(blob)
  local pos, ppq = 1, 0
  while pos <= #blob do
    local offset, _, _, nextPos = string.unpack('i4Bs4', blob, pos)
    ppq, pos = ppq + offset, nextPos
  end
  return ppq
end

tests[#tests + 1] = {
  name = 'endPpq positions the EOT tail; never shrinks past the last event',
  run = function()
    local notes = { { evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } }
    t.eq(tailPpq(midiBlob.serialise(notes, {}, {}, {}, 960)), 960, 'tail honours endPpq beyond the last event')
    t.eq(tailPpq(midiBlob.serialise(notes, {}, {}, {}, 100)), 240, 'endPpq below the last event is clamped up')
    t.eq(tailPpq(midiBlob.serialise(notes, {}, {}, {})),      240, 'no endPpq: tail sits at the last event')
  end,
}

return tests
