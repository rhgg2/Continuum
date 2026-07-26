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

----- Incremental splice
--
-- One question, asked of every gesture: is a wire spliced key-by-key
-- indistinguishable from the wire a full buildWire over the same mutated model
-- would have produced? Each case mutates the model, splices, and pins.

local function key(ppq, rank, seq2) return ppq * 1000000 + rank * 100000 + seq2 end

local function modelOf(notes, ccs, texts, passthrough)
  return { notes = notes or {}, ccs = ccs or {},
           texts = texts or grouped(), passthrough = passthrough or {} }
end

local function build(m) return midiBlob.buildWire(m.notes, m.ccs, m.texts, m.passthrough) end

local function matchesRegen(wire, m, what)
  local fresh = build(m)
  t.deepEq(wire.keys,   fresh.keys,   what .. ': keys')
  t.deepEq(wire.chunks, fresh.chunks, what .. ': chunks')
  t.eq(midiBlob.render(wire, 3840), midiBlob.render(fresh, 3840), what .. ': blob')
end

local function noteAt(ppq, pitch, vel)
  return { evType = 'note', ppq = ppq, endppq = ppq + 120,
           chan = 1, pitch = pitch or 60, vel = vel or 100 }
end
local function ccAt(ppq, code, val, shape)
  return { evType = 'cc', ppq = ppq, chan = 1, cc = code, val = val, shape = shape or 'step' }
end
local function sidecarAt(ppq) return { eventtype = 15, ppq = ppq, msg = 'NOTE uuid' } end

local function noteKeys(notes, slot)
  local n = notes[slot]
  return key(n.ppq, 1, slot * 2), key(n.endppq, 0, slot * 2)
end

local function indexOf(wire, kv)
  for i, k in ipairs(wire.keys) do if k == kv then return i end end
end

tests[#tests + 1] = {
  name = 'putKey splices a note in, chunk for chunk with a full rebuild',
  run = function()
    local m = modelOf({ noteAt(480), noteAt(960) })
    local wire = build(m)
    m.notes[3] = noteAt(720)
    local on, off = noteKeys(m.notes, 3)
    t.eq(midiBlob.putKey(wire, on),  true, 'note-on key was absent')
    t.eq(midiBlob.putKey(wire, off), true, 'note-off key was absent')
    matchesRegen(wire, m, 'note added between two others')
  end,
}

tests[#tests + 1] = {
  name = 'a splice before the first key re-packs the successor delta',
  run = function()
    local m = modelOf({ noteAt(480), noteAt(960) })
    local wire = build(m)
    local wasFirst = wire.chunks[1]   -- the 480 note-on, delta 480 from the take start
    m.notes[3] = noteAt(0)
    local on, off = noteKeys(m.notes, 3)
    midiBlob.putKey(wire, on)
    midiBlob.putKey(wire, off)
    t.eq(wire.keys[3], key(480, 1, 2), 'the old first key sits third now')
    t.eq(wire.chunks[3] ~= wasFirst, true, 'its delta re-packed against the new predecessor')
    matchesRegen(wire, m, 'note added before the first key')
  end,
}

tests[#tests + 1] = {
  name = 'dropKey removes a note, the last key of the array included',
  run = function()
    local m = modelOf({ noteAt(0), noteAt(480) })
    local wire = build(m)
    local on, off = noteKeys(m.notes, 2)
    t.eq(wire.keys[#wire.keys], off, 'its note-off is the array tail')
    m.notes[2] = nil
    t.eq(midiBlob.dropKey(wire, off), true, 'tail key dropped')
    t.eq(midiBlob.dropKey(wire, on),  true, 'note-on dropped')
    matchesRegen(wire, m, 'note deleted')
  end,
}

tests[#tests + 1] = {
  name = 'a ppq move is a drop of both keys and a put of both',
  run = function()
    local m = modelOf({ noteAt(0), noteAt(480, 62), noteAt(960, 64) })
    local wire = build(m)
    local on, off = noteKeys(m.notes, 2)
    midiBlob.dropKey(wire, off)
    midiBlob.dropKey(wire, on)
    local moved = m.notes[2]
    moved.ppq, moved.endppq = 1200, 1320
    midiBlob.putKey(wire, (noteKeys(m.notes, 2)))
    midiBlob.putKey(wire, select(2, noteKeys(m.notes, 2)))
    matchesRegen(wire, m, 'note moved past its neighbour')
  end,
}

tests[#tests + 1] = {
  name = 'a length edit moves only the note-off key',
  run = function()
    local m = modelOf({ noteAt(0), noteAt(480) })
    local wire = build(m)
    local _, off = noteKeys(m.notes, 1)
    t.eq(midiBlob.dropKey(wire, off), true, 'the old note-off key goes')
    m.notes[1].endppq = 600
    t.eq(midiBlob.putKey(wire, select(2, noteKeys(m.notes, 1))), true, 'the new one lands')
    matchesRegen(wire, m, 'note lengthened past the next onset')
  end,
}

tests[#tests + 1] = {
  name = 'repackKey rewrites the bytes under a key that has not moved',
  run = function()
    local m = modelOf({ noteAt(0), noteAt(480) })
    local wire = build(m)
    local on = noteKeys(m.notes, 2)
    m.notes[2].vel = 20
    t.eq(midiBlob.repackKey(wire, on), true, 'the key stays, the bytes change')
    matchesRegen(wire, m, 'velocity edited in place')
  end,
}

tests[#tests + 1] = {
  name = 'a bezier cc splices with its rider and loses it alone on a shape change',
  run = function()
    local m = modelOf(nil, { ccAt(0, 7, 100) })
    local wire = build(m)
    m.ccs[2] = ccAt(240, 11, 64, 'bezier')
    m.ccs[2].tension = 0.5
    local kv = key(240, 2, 4)
    t.eq(midiBlob.putKey(wire, kv),     true, 'cc key added')
    t.eq(midiBlob.putKey(wire, kv + 1), true, 'CCBZ rider added')
    matchesRegen(wire, m, 'bezier cc added')

    m.ccs[2].shape, m.ccs[2].tension = 'linear', nil
    t.eq(midiBlob.dropKey(wire, kv + 1), true, 'the rider drops on its own')
    t.eq(midiBlob.repackKey(wire, kv),   true, 'the cc re-packs with its new shape byte')
    matchesRegen(wire, m, 'bezier downgraded to linear')
  end,
}

tests[#tests + 1] = {
  name = 'a wide cc splices as one chunks entry holding two events',
  run = function()
    local m = modelOf(nil, { ccAt(0, 7, 100) })
    local wire = build(m)
    m.ccs[2] = ccAt(240, 1, 64.5)
    local kv = key(240, 2, 4)
    t.eq(midiBlob.putKey(wire, kv), true, 'wide cc key added')
    t.eq(#wire.chunks[indexOf(wire, kv)], 24, 'MSB and LSB share the one entry')
    matchesRegen(wire, m, 'wide fractional cc added')
  end,
}

tests[#tests + 1] = {
  name = 'a sidecar splices beside its owner on the owner\'s slot',
  run = function()
    local m = modelOf({ noteAt(0), noteAt(480) })
    m.texts.noteSidecars = { sidecarAt(0), sidecarAt(480) }
    local wire = build(m)
    m.notes[3], m.texts.noteSidecars[3] = noteAt(240), sidecarAt(240)
    local on, off = noteKeys(m.notes, 3)
    midiBlob.putKey(wire, on)
    midiBlob.putKey(wire, off)
    t.eq(midiBlob.putKey(wire, key(240, 3, 6)), true, 'the sidecar keys on note slot 3')
    matchesRegen(wire, m, 'note and sidecar spliced together')
  end,
}

-- A false return is the signal 2f's guard falls back to a full regen on, so it has
-- to mean the wire is still exactly what it was.
tests[#tests + 1] = {
  name = 'the splice helpers refuse a kv the wire disagrees about, untouched',
  run = function()
    local m = modelOf({ noteAt(0) })
    local wire = build(m)
    local keysBefore   = { table.unpack(wire.keys) }
    local chunksBefore = { table.unpack(wire.chunks) }
    local on = noteKeys(m.notes, 1)
    local absent = key(9999, 1, 2)
    t.eq(midiBlob.putKey(wire, on),         false, 'putKey refuses a key already present')
    t.eq(midiBlob.dropKey(wire, absent),    false, 'dropKey refuses an absent key')
    t.eq(midiBlob.repackKey(wire, absent),  false, 'repackKey refuses an absent key')
    t.deepEq(wire.keys,   keysBefore,   'keys untouched')
    t.deepEq(wire.chunks, chunksBefore, 'chunks untouched')
  end,
}

-- The item's own evidence: gestures piled onto a real blob's model, spliced one at a
-- time, each step pinned against the full rebuild of the model as it then stood.
tests[#tests + 1] = {
  name = 'a storm of gestures splices to the same bytes as a full rebuild',
  run = function()
    local f = fixtures[1]
    local notes, ccs, texts, passthrough = midiBlob.parse(f.blob)
    local m = modelOf(notes, ccs, grouped(texts), passthrough)
    local wire = build(m)

    m.notes[6] = noteAt(1440, 72)
    midiBlob.putKey(wire, key(1440, 1, 12))
    midiBlob.putKey(wire, key(1560, 0, 12))
    matchesRegen(wire, m, 'storm: note added past the last event')

    local muted = m.ccs[6]
    m.ccs[6] = nil
    midiBlob.dropKey(wire, key(muted.ppq, 2, 12))
    matchesRegen(wire, m, 'storm: muted cc deleted')

    local moved = m.notes[2]
    midiBlob.dropKey(wire, key(moved.ppq, 1, 4))
    midiBlob.dropKey(wire, key(moved.endppq, 0, 4))
    moved.ppq, moved.endppq = 720, 840
    midiBlob.putKey(wire, key(720, 1, 4))
    midiBlob.putKey(wire, key(840, 0, 4))
    matchesRegen(wire, m, 'storm: note moved across the take')

    m.ccs[2].val = 12
    midiBlob.repackKey(wire, key(m.ccs[2].ppq, 2, 4))
    matchesRegen(wire, m, 'storm: cc value edited in place')

    local first = m.notes[1]
    m.notes[1] = nil
    midiBlob.dropKey(wire, key(first.ppq, 1, 2))
    midiBlob.dropKey(wire, key(first.endppq, 0, 2))
    matchesRegen(wire, m, 'storm: the take\'s first note deleted')

    m.ccs[8] = ccAt(60, 74, 40, 'linear')
    midiBlob.putKey(wire, key(60, 2, 16))
    matchesRegen(wire, m, 'storm: cc added between two events')

    t.eq(midiBlob.render(wire, 3840), midiBlob.render(build(m), 3840), 'storm: byte-identical blob')
  end,
}

return tests
