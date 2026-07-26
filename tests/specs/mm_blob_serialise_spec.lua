-- Round-trip pin for the write-path codec (inverse of parse).
--
-- buildWire + render turn mm-shape records into a MIDI_SetAllEvts blob. The
-- contract is parse(render(buildWire(x))) == x -- byte layout may reorder events
-- that share a ppq, but the per-type record lists round-trip identically.
-- Passthrough carries events parse doesn't model so a whole-take rewrite stays
-- lossless.

local t = require('support')
local midiBlob = require('midiBlob')
local fixtures = require('fixtures.midi_blobs')

-- buildWire wants texts grouped by rank; a fixture's texts are one flat list, and
-- a parsed blob's sidecars come back indistinguishable from carried ones.
local function grouped(texts)
  return { noteSidecars = {}, ccSidecars = {}, carried = texts or {} }
end

-- Most cases want bytes out of records, not the wire state in between; name the
-- composition once so each case reads as the round trip it is testing.
local function ser(notes, ccs, texts, passthrough, endPpq)
  return midiBlob.render(midiBlob.buildWire(notes, ccs, grouped(texts), passthrough), endPpq)
end

local tests = {}

for _, f in ipairs(fixtures) do
  tests[#tests + 1] = {
    name = 'records survive serialise -> parse: ' .. f.name,
    run = function()
      local _, _, _, passthrough = midiBlob.parse(f.blob)
      local blob = ser(f.notes, f.ccs, f.texts, passthrough)
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
    local _, _, _, pt2 = midiBlob.parse(ser(notes, ccs, texts, passthrough))
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

-- Defence in depth for the same-pitch invariant: warn-and-write, never dedup at
-- blob level -- see design/same-pitch-enforcement.md § Direction decided against.
tests[#tests + 1] = {
  name = 'colliding note onsets warn loudly and still serialise',
  run = function()
    local notes = {
      { evType = 'note', ppq = 0, endppq = 120, chan = 1, pitch = 60, vel = 100 },
      { evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 90 },
    }
    local warned = false
    local origShow = _G.reaper.ShowConsoleMsg
    _G.reaper.ShowConsoleMsg = function(m)
      if m:find('same-pitch onset collision', 1, true) then warned = true end
    end
    local blob = ser(notes, {}, {}, {})
    _G.reaper.ShowConsoleMsg = origShow
    t.eq(warned, true, 'the codec reports the collision')
    local parsed = midiBlob.parse(blob)
    t.eq(#parsed, 2, 'warn-and-write: both notes still in the blob')
  end,
}

tests[#tests + 1] = {
  name = 'endPpq positions the EOT tail; never shrinks past the last event',
  run = function()
    local notes = { { evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } }
    t.eq(tailPpq(ser(notes, {}, {}, {}, 960)), 960, 'tail honours endPpq beyond the last event')
    t.eq(tailPpq(ser(notes, {}, {}, {}, 100)), 240, 'endPpq below the last event is clamped up')
    t.eq(tailPpq(ser(notes, {}, {}, {})),      240, 'no endPpq: tail sits at the last event')
  end,
}

-- The wire outlives the render that consumed it, so render must leave the chunks
-- it was handed exactly as it found them -- the transient tail element included.
tests[#tests + 1] = {
  name = 'render twice over one wire yields identical bytes',
  run = function()
    local f = fixtures[1]
    local _, _, _, passthrough = midiBlob.parse(f.blob)
    local wire = midiBlob.buildWire(f.notes, f.ccs, grouped(f.texts), passthrough)
    t.eq(midiBlob.render(wire, 960), midiBlob.render(wire, 960), 'held wire state survives a render')
  end,
}

-- A sidecar's key is a pure function of its owner's slot and ppq, which is what
-- lets an incremental flush splice one in. Under the old dense text array an
-- insert anywhere earlier renumbered every sidecar after it.
local function keysOfRank(wire, rank)
  local out = {}
  for _, kv in ipairs(wire.keys) do
    if (kv // 100000) % 10 == rank then out[#out + 1] = kv end
  end
  return out
end

tests[#tests + 1] = {
  name = 'note sidecar keys survive an insert at an earlier ppq',
  run = function()
    local function noteAt(ppq)
      return { evType = 'note', ppq = ppq, endppq = ppq + 120, chan = 1, pitch = 60, vel = 100 }
    end
    local function sidecarAt(ppq) return { eventtype = 15, ppq = ppq, msg = 'NOTE uuid' } end

    local notes = { noteAt(480), noteAt(960) }
    local texts = grouped()
    texts.noteSidecars = { sidecarAt(480), sidecarAt(960) }
    local before = midiBlob.buildWire(notes, {}, texts, {})

    notes[3], texts.noteSidecars[3] = noteAt(0), sidecarAt(0)
    local after = midiBlob.buildWire(notes, {}, texts, {})

    local kBefore, kAfter = keysOfRank(before, 3), keysOfRank(after, 3)
    t.eq(#kAfter, #kBefore + 1, 'the added sidecar contributes exactly one rank-3 key')
    local present = {}
    for _, kv in ipairs(kAfter) do present[kv] = true end
    for i, kv in ipairs(kBefore) do
      t.eq(present[kv], true, ('sidecar %d keeps its key across the earlier insert'):format(i))
    end
  end,
}

return tests
