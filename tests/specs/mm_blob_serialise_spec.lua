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
local function rankOf(kv) return (kv // 100000000) % 10 end

local function keysOfRank(wire, rank)
  local out = {}
  for _, kv in ipairs(wire.keys) do
    if rankOf(kv) == rank then out[#out + 1] = kv end
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
-- One question, asked of every gesture: is a wire synced from the caller's dirt
-- indistinguishable from the wire a full buildWire over the same mutated model would
-- have produced? Each case snapshots the slots it is about to touch, mutates the model,
-- syncs, and pins the answer against that rebuild.

local function key(ppq, rank, seq2) return ppq * 1000000000 + rank * 100000000 + seq2 end

local function modelOf(notes, ccs, texts, passthrough)
  return { notes = notes or {}, ccs = ccs or {},
           texts = texts or grouped(), passthrough = passthrough or {} }
end

local function build(m) return midiBlob.buildWire(m.notes, m.ccs, m.texts, m.passthrough) end

local function firstDiff(a, b)
  for i = 1, math.max(#a, #b) do if a[i] ~= b[i] then return i end end
end

-- Chunks and blobs are raw MIDI bytes, so a deepEq of them prints the take's wire form
-- into the console on a failure. Name where they diverge instead.
local function matchesRegen(wire, m, what)
  local fresh = build(m)
  t.deepEq(wire.keys, fresh.keys, what .. ': keys')
  t.eq(firstDiff(wire.chunks, fresh.chunks), nil, what .. ': chunks match the rebuild at every index')
  t.eq(midiBlob.render(wire, 3840) == midiBlob.render(fresh, 3840), true, what .. ': blob')
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

-- What mm's markWire records at a verb site: each touched slot's state before the model
-- moves. A slot holding nothing snapshots as the empty state mm passes for an add.
local function slotsBefore(wire, stream, ...)
  local group = {}
  for _, slot in ipairs({ ... }) do group[slot] = midiBlob.slotState(wire, stream, slot) end
  return group
end

-- The slot cap is the key's digit banding, and a long take reaches it: rebuildPbs
-- writes a cc per QN. A slot past the band carries seq2 into the rank digit, and the
-- note decodes as another stream's event -- silently, on the wire bytes.
tests[#tests + 1] = {
  name = 'a slot far above the old band still keys and decodes as a note',
  run = function()
    local m = modelOf({ noteAt(0) })
    local wire = build(m)
    local dirt = { note = slotsBefore(wire, 'note', 60000) }
    m.notes[60000] = noteAt(480)
    local on, off = noteKeys(m.notes, 60000)
    t.eq(rankOf(on),  1, 'the note-on of a five-digit slot still decodes as rank 1')
    t.eq(rankOf(off), 0, 'the note-off still decodes as rank 0')
    t.eq(math.type(on), 'integer', 'the composed key is an int64, not a float')
    t.eq(midiBlob.syncSlots(wire, dirt), true, 'the slot spliced in')
    matchesRegen(wire, m, 'note at a slot above the old band')
  end,
}

tests[#tests + 1] = {
  name = 'an added slot splices in, chunk for chunk with a full rebuild',
  run = function()
    local m = modelOf({ noteAt(480), noteAt(960) })
    local wire = build(m)
    local dirt = { note = slotsBefore(wire, 'note', 3) }
    m.notes[3] = noteAt(720)
    t.eq(midiBlob.syncSlots(wire, dirt), true, 'the added note spliced')
    matchesRegen(wire, m, 'note added between two others')
  end,
}

tests[#tests + 1] = {
  name = 'a splice before the first key re-packs the successor delta',
  run = function()
    local m = modelOf({ noteAt(480), noteAt(960) })
    local wire = build(m)
    local wasFirst = wire.chunks[1]   -- the 480 note-on, delta 480 from the take start
    local dirt = { note = slotsBefore(wire, 'note', 3) }
    m.notes[3] = noteAt(0)
    t.eq(midiBlob.syncSlots(wire, dirt), true, 'the note spliced ahead of the first key')
    t.eq(wire.keys[3], key(480, 1, 2), 'the old first key sits third now')
    t.eq(wire.chunks[3] ~= wasFirst, true, 'its delta re-packed against the new predecessor')
    matchesRegen(wire, m, 'note added before the first key')
  end,
}

tests[#tests + 1] = {
  name = 'a deleted slot takes its keys with it, the array tail included',
  run = function()
    local m = modelOf({ noteAt(0), noteAt(480) })
    local wire = build(m)
    local _, off = noteKeys(m.notes, 2)
    t.eq(wire.keys[#wire.keys], off, 'its note-off is the array tail')
    local dirt = { note = slotsBefore(wire, 'note', 2) }
    m.notes[2] = nil
    t.eq(midiBlob.syncSlots(wire, dirt), true, 'both its keys dropped')
    matchesRegen(wire, m, 'note deleted')
  end,
}

tests[#tests + 1] = {
  name = 'a ppq move is a drop of both keys and a put of both',
  run = function()
    local m = modelOf({ noteAt(0), noteAt(480, 62), noteAt(960, 64) })
    local wire = build(m)
    local dirt  = { note = slotsBefore(wire, 'note', 2) }
    local moved = m.notes[2]
    moved.ppq, moved.endppq = 1200, 1320
    t.eq(midiBlob.syncSlots(wire, dirt), true, 'the moved slot re-keyed')
    matchesRegen(wire, m, 'note moved past its neighbour')
  end,
}

tests[#tests + 1] = {
  name = 'a length edit moves only the note-off key',
  run = function()
    local m = modelOf({ noteAt(0), noteAt(480) })
    local wire = build(m)
    local on    = noteKeys(m.notes, 1)
    local count = #wire.keys
    local dirt  = { note = slotsBefore(wire, 'note', 1) }
    m.notes[1].endppq = 600
    t.eq(midiBlob.syncSlots(wire, dirt), true, 'the note-off key moved')
    t.eq(#wire.keys, count, 'one key out, one key in')
    t.eq(indexOf(wire, on) ~= nil, true, 'the onset key is where it was')
    matchesRegen(wire, m, 'note lengthened past the next onset')
  end,
}

tests[#tests + 1] = {
  name = 'a property edit rewrites the bytes under keys that have not moved',
  run = function()
    local m = modelOf({ noteAt(0), noteAt(480) })
    local wire = build(m)
    local on   = noteKeys(m.notes, 2)
    local at   = indexOf(wire, on)
    local was  = wire.chunks[at]
    local dirt = { note = slotsBefore(wire, 'note', 2) }
    m.notes[2].vel = 20
    t.eq(midiBlob.syncSlots(wire, dirt), true, 'the velocity edit synced')
    t.eq(indexOf(wire, on), at, 'the key stayed where it was')
    t.eq(wire.chunks[at] ~= was, true, 'the bytes under it changed')
    matchesRegen(wire, m, 'velocity edited in place')
  end,
}

tests[#tests + 1] = {
  name = 'a bezier cc splices with its rider and loses it alone on a shape change',
  run = function()
    local m = modelOf(nil, { ccAt(0, 7, 100) })
    local wire = build(m)
    local kv   = key(240, 2, 4)
    local dirt = { cc = slotsBefore(wire, 'cc', 2) }
    m.ccs[2] = ccAt(240, 11, 64, 'bezier')
    m.ccs[2].tension = 0.5
    t.eq(midiBlob.syncSlots(wire, dirt), true, 'the cc spliced in')
    t.eq(indexOf(wire, kv + 1) ~= nil, true, 'its CCBZ rider came with it')
    matchesRegen(wire, m, 'bezier cc added')

    dirt = { cc = slotsBefore(wire, 'cc', 2) }
    m.ccs[2].shape, m.ccs[2].tension = 'linear', nil
    t.eq(midiBlob.syncSlots(wire, dirt), true, 'the shape change synced')
    t.eq(indexOf(wire, kv + 1), nil, 'the rider dropped on its own')
    t.eq(indexOf(wire, kv) ~= nil, true, 'the cc kept its key and re-packed its shape byte')
    matchesRegen(wire, m, 'bezier downgraded to linear')
  end,
}

tests[#tests + 1] = {
  name = 'a wide cc splices as one chunks entry holding two events',
  run = function()
    local m = modelOf(nil, { ccAt(0, 7, 100) })
    local wire = build(m)
    local kv   = key(240, 2, 4)
    local dirt = { cc = slotsBefore(wire, 'cc', 2) }
    m.ccs[2] = ccAt(240, 1, 64.5)
    t.eq(midiBlob.syncSlots(wire, dirt), true, 'wide cc spliced in')
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
    local dirt = { note = slotsBefore(wire, 'note', 3) }
    m.notes[3], m.texts.noteSidecars[3] = noteAt(240), sidecarAt(240)
    t.eq(midiBlob.syncSlots(wire, dirt), true, 'one dirty note slot carries its sidecar too')
    t.eq(indexOf(wire, key(240, 3, 6)) ~= nil, true, 'the sidecar keys on note slot 3')
    matchesRegen(wire, m, 'note and sidecar spliced together')
  end,
}

-- The nest hands its whole dirt over at once, so a sync is a set of gestures rather
-- than a sequence of them: which order the wire applies them in is its own business.
tests[#tests + 1] = {
  name = 'one sync carries a drop, a put, a move and a repack together',
  run = function()
    local m = modelOf({ noteAt(0), noteAt(480, 62), noteAt(960, 64) }, { ccAt(240, 7, 100) })
    local wire = build(m)
    local dirt = { note = slotsBefore(wire, 'note', 1, 2, 4),
                   cc   = slotsBefore(wire, 'cc', 1) }
    m.notes[1] = nil                                   -- a drop of both its keys
    m.notes[2].ppq, m.notes[2].endppq = 1200, 1320     -- a move: two drops and two puts
    m.notes[4] = noteAt(120, 65)                       -- a put of both its keys
    m.ccs[1].val = 40                                  -- a repack, key unmoved
    t.eq(midiBlob.syncSlots(wire, dirt), true, 'the batch spliced')
    matchesRegen(wire, m, 'four gestures in one sync')
  end,
}

-- A false return is the signal flushTake's guard falls back to a full regen on, so it
-- has to mean the wire is still exactly what it was.
tests[#tests + 1] = {
  name = 'a sync whose dirt disagrees with the wire refuses it, untouched',
  run = function()
    local m = modelOf({ noteAt(0), noteAt(480) })
    local wire = build(m)
    local keysBefore   = { table.unpack(wire.keys) }
    local chunksBefore = { table.unpack(wire.chunks) }

    -- Dirt claiming slot 2 held nothing, when the wire holds both its keys: a put of
    -- a key already there.
    t.eq(midiBlob.syncSlots(wire, { note = { [2] = {} } }), false, 'a put of a present key')
    t.deepEq(wire.keys, keysBefore, 'keys untouched after the refused put')
    t.eq(firstDiff(wire.chunks, chunksBefore), nil, 'chunks untouched after the refused put')

    -- Dirt claiming a ppq slot 2 never had: a drop of a key the wire never held.
    local stale = { note = { [2] = { ppq = 9999, endppq = 10080 } } }
    t.eq(midiBlob.syncSlots(wire, stale), false, 'a drop of an absent key')
    t.deepEq(wire.keys, keysBefore, 'keys untouched after the refused drop')
    t.eq(firstDiff(wire.chunks, chunksBefore), nil, 'chunks untouched after the refused drop')
  end,
}

-- The item's own evidence: gestures piled onto a real blob's model, synced one at a
-- time, each step pinned against the full rebuild of the model as it then stood.
tests[#tests + 1] = {
  name = 'a storm of gestures splices to the same bytes as a full rebuild',
  run = function()
    local f = fixtures[1]
    local notes, ccs, texts, passthrough = midiBlob.parse(f.blob)
    local m = modelOf(notes, ccs, grouped(texts), passthrough)
    local wire = build(m)

    local dirt = { note = slotsBefore(wire, 'note', 6) }
    m.notes[6] = noteAt(1440, 72)
    t.eq(midiBlob.syncSlots(wire, dirt), true, 'storm: the added note synced')
    matchesRegen(wire, m, 'storm: note added past the last event')

    dirt = { cc = slotsBefore(wire, 'cc', 6) }
    m.ccs[6] = nil
    t.eq(midiBlob.syncSlots(wire, dirt), true, 'storm: the deleted cc synced')
    matchesRegen(wire, m, 'storm: muted cc deleted')

    dirt = { note = slotsBefore(wire, 'note', 2) }
    m.notes[2].ppq, m.notes[2].endppq = 720, 840
    t.eq(midiBlob.syncSlots(wire, dirt), true, 'storm: the moved note synced')
    matchesRegen(wire, m, 'storm: note moved across the take')

    dirt = { cc = slotsBefore(wire, 'cc', 2) }
    m.ccs[2].val = 12
    t.eq(midiBlob.syncSlots(wire, dirt), true, 'storm: the edited cc synced')
    matchesRegen(wire, m, 'storm: cc value edited in place')

    dirt = { note = slotsBefore(wire, 'note', 1) }
    m.notes[1] = nil
    t.eq(midiBlob.syncSlots(wire, dirt), true, 'storm: the deleted note synced')
    matchesRegen(wire, m, 'storm: the take\'s first note deleted')

    dirt = { cc = slotsBefore(wire, 'cc', 8) }
    m.ccs[8] = ccAt(60, 74, 40, 'linear')
    t.eq(midiBlob.syncSlots(wire, dirt), true, 'storm: the added cc synced')
    matchesRegen(wire, m, 'storm: cc added between two events')

    t.eq(midiBlob.render(wire, 3840) == midiBlob.render(build(m), 3840), true,
         'storm: byte-identical blob')
  end,
}

-- The hand-written cases above each name one gesture; the merge's branches are reached by
-- combinations of them, which random play covers and enumeration would not. The oracle is
-- the same one, so the ground truth regenerates itself: a legitimate change to the wire
-- format moves both sides at once and this case never needs hand-patching.
--
-- A slot's (chan, pitch) is fixed and unique, so no gesture can ever collide two onsets --
-- which would be a warning about the fixture rather than about the splice.
tests[#tests + 1] = {
  name = 'random play over the whole gesture set stays byte-identical to a full rebuild',
  run = function()
    math.randomseed(20260902)
    local function seat(slot) return 1 + slot % 16, 20 + (slot // 16) % 100 end

    local m = modelOf()
    for slot = 1, 30 do
      local chan, pitch = seat(slot)
      m.notes[slot] = { evType = 'note', ppq = slot * 120, endppq = slot * 120 + 90,
                        chan = chan, pitch = pitch, vel = 100 }
    end
    for slot = 1, 20 do
      m.ccs[slot] = { evType = 'cc', ppq = slot * 180, chan = 1, cc = 7, val = slot, shape = 'step' }
    end
    local wire = build(m)

    -- One gesture on one slot, drawn from everything a verb can do to it.
    local function play(stream, slot)
      local roll = math.random(6)
      if stream == 'note' then
        local n = m.notes[slot]
        if not n then
          local chan, pitch = seat(slot)
          local ppq = math.random(0, 4000)
          m.notes[slot] = { evType = 'note', ppq = ppq, endppq = ppq + math.random(10, 300),
                            chan = chan, pitch = pitch, vel = 100 }
        elseif roll == 1 then m.notes[slot], m.texts.noteSidecars[slot] = nil, nil
        elseif roll == 2 then
          n.ppq, n.endppq = math.random(0, 4000), 0
          n.endppq = n.ppq + math.random(10, 300)
          if m.texts.noteSidecars[slot] then m.texts.noteSidecars[slot].ppq = n.ppq end
        elseif roll == 3 then n.endppq = n.ppq + math.random(10, 600)
        elseif roll == 4 then n.vel = math.random(1, 127)
        elseif roll == 5 then m.texts.noteSidecars[slot] = sidecarAt(n.ppq)
        else m.texts.noteSidecars[slot] = nil end
      else
        local c = m.ccs[slot]
        if not c then m.ccs[slot] = ccAt(math.random(0, 4000), 7, math.random(0, 127))
        elseif roll == 1 then m.ccs[slot], m.texts.ccSidecars[slot] = nil, nil
        elseif roll == 2 then
          c.ppq = math.random(0, 4000)
          if m.texts.ccSidecars[slot] then m.texts.ccSidecars[slot].ppq = c.ppq end
        elseif roll == 3 then c.val = math.random(0, 127)
        elseif roll == 4 then
          if c.shape == 'bezier' then c.shape, c.tension = 'linear', nil
          else c.shape, c.tension = 'bezier', 0.25 end
        elseif roll == 5 then
          m.texts.ccSidecars[slot] = { eventtype = -1, ppq = c.ppq, msg = 'CC ' .. slot }
        else m.texts.ccSidecars[slot] = nil end
      end
    end

    local rounds, gestures, diverged = 500, 0, nil
    for round = 1, rounds do
      local dirt, touched = { note = {}, cc = {} }, {}
      for _ = 1, math.random(1, 4) do
        local stream = math.random(2) == 1 and 'note' or 'cc'
        local slot   = math.random(1, 40)
        if not touched[stream .. slot] then
          touched[stream .. slot] = true
          dirt[stream][slot] = midiBlob.slotState(wire, stream, slot)
          play(stream, slot)
          gestures = gestures + 1
        end
      end
      local ref = build(m)
      if not midiBlob.syncSlots(wire, dirt) then diverged = round .. ': sync refused'
      elseif firstDiff(wire.keys, ref.keys) then
        diverged = round .. ': key ' .. firstDiff(wire.keys, ref.keys)
      elseif firstDiff(wire.chunks, ref.chunks) then
        diverged = round .. ': chunk ' .. firstDiff(wire.chunks, ref.chunks)
      elseif midiBlob.render(wire, 9000) ~= midiBlob.render(ref, 9000) then
        diverged = round .. ': blob'
      end
      if diverged then break end
    end

    t.eq(diverged, nil, 'every round matched the rebuild; first divergence at round ')
    t.eq(gestures > rounds, true, 'the play was non-trivial: more gestures than rounds')
    t.eq(#wire.keys > 40, true, 'the wire still carries a take at the end of the play')
  end,
}

return tests
