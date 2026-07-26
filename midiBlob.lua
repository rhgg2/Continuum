-- Pure wire-format translation for REAPER's MIDI_GetAllEvts blob.
-- See docs/midiManager.md for where this sits in the read path.
--
-- The blob is the only bulk read REAPER offers; parse() turns it into the
-- same note/cc/text records mm:load consumes from the per-event API, so the
-- rest of load (dedup, reconcile, uuid, metadata) is unchanged. Format facts
-- verified against real captures by tests/spikes/spike_capture_blobs.lua.

--shape: parse(blob) -> notes, ccs, texts, passthrough
--shape: note = { idx, evType='note', ppq, endppq, chan(1..16), pitch, vel, [muted] }
--shape: cc = { idx, ppq, evType, chan(1..16), [cc|pitch], [val|vel], shape, [tension], [muted] }
--shape: text = { idx, ppq, eventtype, msg }  -- 15=notation, -1=sysex; CCBZ tension folds onto its cc
--invariant: idx is the 0-based REAPER per-type index; note idx counts note-ons, text idx skips CCBZ
--reaper: blob = repeat(i4 offset, B flags, s4 msg) + trailing 12-byte all-notes-off tail (excluded)
--reaper: flags bit1=muted; bits4-6=cc shape; status byte classifies; CCBZ rides FF-0F after its cc

local util = require 'util'
local perf = require 'perf'

local chanMsgEvTypes = { [0xA0] = 'pa', [0xB0] = 'cc', [0xC0] = 'pc', [0xD0] = 'at', [0xE0] = 'pb' }
local shapeNames     = { [0] = 'step', [1] = 'linear', [2] = 'slow',
                         [3] = 'fast-start', [4] = 'fast-end', [5] = 'bezier' }

local shapeCodes, hiByEvType = {}, {}
for code, name in pairs(shapeNames)     do shapeCodes[name] = code end
for hi,   name in pairs(chanMsgEvTypes) do hiByEvType[name] = hi  end
local oneDataByte = { pc = true, at = true }   -- status + a single 7-bit data byte

-- 14-bit CC: a code in 0..31 with a fractional value rides an LSB on code+32.
-- The value's type is the whole signal -- an integer value stays a plain 7-bit CC.
local function isWideCC(c) return c.evType == 'cc' and c.cc <= 31 and c.val % 1 ~= 0 end
local function splitWide(val)
  local msb = math.floor(val)
  local lsb = util.round((val - msb) * 128)
  if lsb >= 128 then msb, lsb = msb + 1, 0 end
  return util.clamp(msb, 0, 127), lsb
end

local midiBlob = {}

-- The value-bearing fields for a cc-family event, keyed as mm:load stores them.
local function ccValueFields(evType, b2, b3)
  if evType == 'pa' then return { pitch = b2, vel = b3 } end
  if evType == 'cc' then return { cc = b2, val = b3 } end
  if evType == 'pb' then return { val = ((b3 << 7) | b2) - 8192 } end
  return { val = b2 }   -- pc, at: single 7-bit payload
end

function midiBlob.parse(blob)
  local notes, ccs, texts, passthrough = {}, {}, {}, {}
  local pending = {}   -- (chan*128+pitch) -> FIFO queue of open note-ons awaiting their note-off
  local lastCC         -- most-recent cc, for CCBZ tension attachment
  local noteIdx, ccIdx, textIdx = 0, 0, 0
  local pos, ppq, len = 1, 0, #blob

  while pos < len - 12 do   -- the trailing 12 bytes are REAPER's all-notes-off marker
    local offset, flags, msg, nextPos = string.unpack('i4Bs4', blob, pos)
    ppq, pos = ppq + offset, nextPos

    local status = msg:byte(1) or 0
    local hi     = status & 0xF0
    local b2, b3 = msg:byte(2) or 0, msg:byte(3) or 0
    local muted  = (flags & 2) ~= 0 or nil
    local chan   = (status & 0x0F) + 1

    if hi == 0x90 and b3 ~= 0 then
      local note = { idx = noteIdx, evType = 'note', ppq = ppq, endppq = ppq,
                     chan = chan, pitch = b2, vel = b3, muted = muted }
      noteIdx = noteIdx + 1
      util.add(notes, note)
      local key = (status & 0x0F) * 128 + b2
      local q = pending[key]; if not q then q = {}; pending[key] = q end
      q[#q + 1] = note
    elseif hi == 0x80 or hi == 0x90 then   -- note-off (incl. note-on with vel 0)
      local q = pending[(status & 0x0F) * 128 + b2]
      if q and q[1] then table.remove(q, 1).endppq = ppq end
    elseif hi >= 0xA0 and hi < 0xF0 then
      local evType = chanMsgEvTypes[hi] or ('chanmsg_' .. hi)
      local cc = { idx = ccIdx, ppq = ppq, evType = evType, chan = chan,
                   shape = shapeNames[(flags >> 4) & 7] or 'step', muted = muted }
      for k, v in pairs(ccValueFields(evType, b2, b3)) do cc[k] = v end
      ccIdx = ccIdx + 1
      util.add(ccs, cc)
      lastCC = cc
    elseif status == 0xFF then
      if b2 == 0x0F and msg:sub(3, 7) == 'CCBZ ' then
        if lastCC and lastCC.shape == 'bezier' then lastCC.tension = string.unpack('f', msg:sub(9)) end
      else
        util.add(texts, { idx = textIdx, ppq = ppq, eventtype = b2, msg = msg:sub(3) })
        textIdx = textIdx + 1
      end
    elseif status == 0xF0 then
      util.add(texts, { idx = textIdx, ppq = ppq, eventtype = -1, msg = msg:sub(2, #msg - 1) })
      textIdx = textIdx + 1
    elseif status ~= 0 then
      util.add(passthrough, { ppq = ppq, flags = flags, msg = msg })
    end
  end

  -- Coalesce 14-bit pairs (REAPER's convention): MSB keeps shape/tension, LSB folds in and drops.
  -- see docs/midiManager.md § 14-bit CCs
  local byPos, drop = {}, nil
  for _, c in ipairs(ccs) do
    if c.evType == 'cc' then byPos[c.chan .. '\0' .. c.cc .. '\0' .. c.ppq] = c end
  end
  for _, msb in ipairs(ccs) do
    if msb.evType == 'cc' and msb.cc <= 31 then
      local lsb = byPos[msb.chan .. '\0' .. (msb.cc + 32) .. '\0' .. msb.ppq]
      if lsb then
        msb.val = msb.val + lsb.val / 128
        drop = drop or {}; drop[lsb] = true
      end
    end
  end
  if drop then
    local kept = {}
    for _, c in ipairs(ccs) do if not drop[c] then util.add(kept, c) end end
    for i, c in ipairs(kept) do c.idx = i - 1 end
    ccs = kept
  end

  return notes, ccs, texts, passthrough
end

-- Value bytes for a cc-family record (inverse of ccValueFields).
local function ccDataBytes(c)
  if c.evType == 'pa' then return c.pitch, c.vel end
  if c.evType == 'cc' then return c.cc, c.val end
  if c.evType == 'pb' then local raw = c.val + 8192; return raw & 0x7F, (raw >> 7) & 0x7F end
  return c.val or 0, 0   -- pc, at: single 7-bit payload
end

local function ccWire(c)
  local status = (hiByEvType[c.evType] or 0) | (c.chan - 1)
  local b2, b3 = ccDataBytes(c)
  if oneDataByte[c.evType] then return string.char(status, b2) end
  return string.char(status, b2, b3)
end

--shape: wire = { keys = { [i] = ppq*1e6 + rank*1e5 + seq2 }, chunks = { [i] = packed bytes for keys[i] }, model = { notes, ccs, texts, passthrough } }  -- keys ascending and dense 1..n, chunks index-parallel
--shape: rank = 0 note-off | 1 note-on | 2 cc (odd seq2 = its CCBZ rider) | 3 note sidecar | 4 cc sidecar | 5 carried text | 6 passthrough
--shape: buildWire(notes, ccs, texts, passthrough) -> wire   -- notes/ccs keyed by slot; texts = { noteSidecars = [noteSlot], ccSidecars = [ccSlot], carried = [i] }
--shape: render(wire, endPpq?) -> blob   -- concat plus the EOT tail; endPpq places the tail
--shape: putKey/dropKey/repackKey(wire, kv) -> ok   -- splice one key; the model they pack from rides the wire
--contract: a splice helper returns false and mutates nothing when kv is already present / absent
--invariant: a note/cc slot stays under 5e4: seq2 = slot*2 shares the key's 1e5 digit band with rank
--invariant: parse(render(buildWire(x)))==x; coincident events may reorder, per-type lists intact
--invariant: note onsets unique per (ppq,chan,pitch); collision is upstream bug, warn+write
--reaper: matches MIDI_SetAllEvts format; tail at max(endPpq, last-event ppq) (default: last event)
-- Packed-chunk cache: identity fields validate the row, the neighbour-coupled
-- delta revalidates per chunk. An edit repacks only its own neighbourhood.
local chunkCache = setmetatable({}, { __mode = 'k' })

local function noteRow(n)
  local row = chunkCache[n]
  if not (row and row.chan == n.chan and row.pitch == n.pitch
          and row.vel == n.vel and row.muted == n.muted) then
    row = { chan = n.chan, pitch = n.pitch, vel = n.vel, muted = n.muted }
    chunkCache[n] = row
  end
  return row
end

local function ccRow(c)
  local row = chunkCache[c]
  if not (row and row.evType == c.evType and row.chan == c.chan and row.cc == c.cc
          and row.pitch == c.pitch and row.val == c.val and row.vel == c.vel
          and row.muted == c.muted and row.shape == c.shape and row.tension == c.tension) then
    row = { evType = c.evType, chan = c.chan, cc = c.cc, pitch = c.pitch, val = c.val,
            vel = c.vel, muted = c.muted, shape = c.shape, tension = c.tension }
    chunkCache[c] = row
  end
  return row
end

local function textRow(x)
  local row = chunkCache[x]
  if not (row and row.eventtype == x.eventtype and row.msg == x.msg) then
    row = { eventtype = x.eventtype, msg = x.msg }
    chunkCache[x] = row
  end
  return row
end

local function textChunk(x, dppq)
  local row = textRow(x)
  if row.d ~= dppq then
    row.d, row.chunk = dppq, string.pack('i4Bs4', dppq, 0, x.eventtype == -1
      and ('\xF0' .. x.msg .. '\xF7')
      or  ('\xFF' .. string.char(x.eventtype) .. x.msg))
  end
  return row.chunk
end

-- Decodes a packed sort key to its wire chunk(s): rank digit picks the stream, seq//2
-- the event's slot, an odd seq a cc's bezier CCBZ rider. Mirrors midiBlob.parse.
local function chunkOf(kv, dppq, notes, ccs, texts, passthrough)
  local rank = (kv // 100000) % 10
  local i    = (kv % 100000) // 2
  if rank == 1 then
    local n   = notes[i]
    local row = noteRow(n)
    if row.onD ~= dppq then
      row.onD, row.on = dppq, string.pack('i4Bs4', dppq, n.muted and 0x02 or 0,
                                          string.char(0x90 | (n.chan - 1), n.pitch, n.vel))
    end
    return row.on
  elseif rank == 0 then
    local n   = notes[i]
    local row = noteRow(n)
    if row.offD ~= dppq then
      row.offD, row.off = dppq, string.pack('i4Bs4', dppq, 0,
                                            string.char(0x80 | (n.chan - 1), n.pitch, 0))
    end
    return row.off
  elseif rank == 2 then
    local c   = ccs[i]
    local row = ccRow(c)
    if kv % 2 == 1 then   -- CCBZ rider directly follows its cc at the same ppq: delta always 0
      if not row.bz then
        row.bz = string.pack('i4Bs4', 0, 0,
                             '\xFF\x0F' .. 'CCBZ ' .. '\0' .. string.pack('f', c.tension or 0))
      end
      return row.bz
    end
    if row.mainD ~= dppq then
      row.mainD = dppq
      local shaped = (c.muted and 0x02 or 0) | ((shapeCodes[c.shape] or 0) << 4)
      if isWideCC(c) then
        local msb, lsb = splitWide(c.val)
        local status = 0xB0 | (c.chan - 1)
        -- LSB(step) first so a bezier CCBZ rider (next key, same ppq) still lands on the MSB in parse.
        row.main  = string.pack('i4Bs4', dppq, c.muted and 0x02 or 0, string.char(status, c.cc + 32, lsb))
        row.main2 = string.pack('i4Bs4', 0, shaped, string.char(status, c.cc, msb))
      else
        row.main, row.main2 = string.pack('i4Bs4', dppq, shaped, ccWire(c)), nil
      end
    end
    return row.main, row.main2
  elseif rank == 3 then
    return textChunk(texts.noteSidecars[i], dppq)
  elseif rank == 4 then
    return textChunk(texts.ccSidecars[i], dppq)
  elseif rank == 5 then
    return textChunk(texts.carried[i], dppq)
  elseif rank == 6 then
    local p = passthrough[i]
    return string.pack('i4Bs4', dppq, p.flags, p.msg)
  end
end

-- Keys, sorts and packs the model into wire state the caller holds across flushes,
-- so an edit can replace the chunks it touched instead of rebuilding all of them.
function midiBlob.buildWire(notes, ccs, texts, passthrough)
  passthrough = passthrough or {}
  -- key = ppq*1e6 + rank*1e5 + seq2, seq2 = slot*2 (+1 for a bezier tail); dense
  -- streams use index*2 in place of slot. See docs/midiBlob.md.
  local keys, count = {}, 0
  local function key(ppq, rank, seq2)
    count = count + 1
    keys[count] = ppq * 1000000 + rank * 100000 + seq2
  end

  perf.start('keys')
  local seenOnset = {}   -- (ppq,chan,pitch) occupancy; 2048 = 16 chans x 128 pitches per ppq
  -- pairs, not ipairs: slots are sparse. Enumeration order can't reach the blob -- slots are
  -- unique per stream, so the keys are a set and the sort settles emission order.
  for slot, n in pairs(notes) do
    local onset = n.ppq * 2048 + (n.chan - 1) * 128 + n.pitch
    if seenOnset[onset] then
      util.print(('midiBlob.buildWire: same-pitch onset collision ppq=%d chan=%d pitch=%d -- upstream bug, writing anyway')
        :format(n.ppq, n.chan, n.pitch))
    end
    seenOnset[onset] = true
    key(n.ppq, 1, slot * 2)      -- note-on
    key(n.endppq, 0, slot * 2)   -- note-off
  end
  for slot, c in pairs(ccs) do
    key(c.ppq, 2, slot * 2)
    if c.shape == 'bezier' then key(c.ppq, 2, slot * 2 + 1) end
  end
  -- A sidecar rides its owner's slot, so the two groups need ranks of their own: note
  -- slot 5 and cc slot 5 are different events and would otherwise share a key.
  for slot, x in pairs(texts.noteSidecars) do key(x.ppq, 3, slot * 2) end
  for slot, x in pairs(texts.ccSidecars)   do key(x.ppq, 4, slot * 2) end
  for i, x in ipairs(texts.carried)        do key(x.ppq, 5, i * 2) end
  for i, p in ipairs(passthrough)          do key(p.ppq, 6, i * 2) end
  perf.stop('keys')

  perf.start('sort')
  table.sort(keys)
  perf.stop('sort')

  -- A chunk's delta comes from its predecessor key, so packing is inherently a walk
  -- over the sorted keys -- which is why it lives here and not in render.
  perf.start('pack')
  local chunks, prevPpq = {}, 0
  for i = 1, count do
    local kv  = keys[i]
    local ppq = kv // 1000000
    local chunk, chunk2 = chunkOf(kv, ppq - prevPpq, notes, ccs, texts, passthrough)
    chunks[i] = chunk2 and (chunk .. chunk2) or chunk   -- wide LSB rides first, MSB at offset 0
    prevPpq = ppq
  end
  perf.stop('pack')

  return { keys = keys, chunks = chunks,
           model = { notes = notes, ccs = ccs, texts = texts, passthrough = passthrough } }
end

-- First index whose key is >= kv, over the ascending key array.
local function lowerBound(keys, kv)
  local lo, hi = 1, #keys + 1
  while lo < hi do
    local mid = (lo + hi) // 2
    if keys[mid] < kv then lo = mid + 1 else hi = mid end
  end
  return lo
end

-- Re-derives the predecessor's ppq rather than carrying it forward: a splice has no
-- walk to carry it from, which is why buildWire keeps its own loop.
local function chunkAt(wire, i)
  local keys, m = wire.keys, wire.model
  local ppq  = keys[i] // 1000000
  local prev = i > 1 and keys[i - 1] // 1000000 or 0
  local chunk, chunk2 = chunkOf(keys[i], ppq - prev, m.notes, m.ccs, m.texts, m.passthrough)
  return chunk2 and (chunk .. chunk2) or chunk   -- wide LSB rides first, MSB at offset 0
end

-- A chunk's delta comes from its predecessor's ppq, so a splice moves only its
-- own delta and its successor's. See docs/midiBlob.md § Splicing a held wire.
function midiBlob.putKey(wire, kv)
  local i = lowerBound(wire.keys, kv)
  if wire.keys[i] == kv then return false end
  table.insert(wire.keys, i, kv)
  table.insert(wire.chunks, i, chunkAt(wire, i))
  if wire.keys[i + 1] then wire.chunks[i + 1] = chunkAt(wire, i + 1) end
  return true
end

function midiBlob.dropKey(wire, kv)
  local i = lowerBound(wire.keys, kv)
  if wire.keys[i] ~= kv then return false end
  table.remove(wire.keys, i)
  table.remove(wire.chunks, i)
  if wire.keys[i] then wire.chunks[i] = chunkAt(wire, i) end
  return true
end

-- The property edit: the key does not move, only the bytes under it.
function midiBlob.repackKey(wire, kv)
  local i = lowerBound(wire.keys, kv)
  if wire.keys[i] ~= kv then return false end
  wire.chunks[i] = chunkAt(wire, i)
  return true
end

-- The tail goes on as a transient last element and comes straight back off:
-- table.concat(chunks) .. tail would copy the whole blob to add twelve bytes.
function midiBlob.render(wire, endPpq)
  perf.start('concat')
  local keys, chunks = wire.keys, wire.chunks
  local last    = #keys
  local lastPpq = last > 0 and keys[last] // 1000000 or 0
  local tailPpq = math.max(endPpq or lastPpq, lastPpq)   -- never shrink past the last event
  chunks[last + 1] = string.pack('i4Bs4', tailPpq - lastPpq, 0, '\xB0\x7B\x00')   -- all-notes-off tail
  local blob = table.concat(chunks)
  chunks[last + 1] = nil
  perf.stop('concat')
  return blob
end

return midiBlob
