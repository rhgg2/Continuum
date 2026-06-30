-- Pure wire-format translation for REAPER's MIDI_GetAllEvts blob.
-- See docs/midiManager.md for where this sits in the read path.
--
-- The blob is the only bulk read REAPER offers; parse() turns it into the
-- same note/cc/text records mm:load consumes from the per-event API, so the
-- rest of load (dedup, reconcile, uuid, metadata) is unchanged. Format facts
-- verified against real captures by tests/spikes/spike_capture_blobs.lua.

--shape: parse(blob) -> notes, ccs, texts
--shape: note = { idx, evType='note', ppq, endppq, chan(1..16), pitch, vel, [muted] }
--shape: cc = { idx, ppq, evType, chan(1..16), [cc|pitch], [val|vel], shape, [tension], [muted] }
--shape: text = { idx, ppq, eventtype, msg }  -- 15=notation, -1=sysex; CCBZ tension folds onto its cc
--invariant: idx is the 0-based REAPER per-type index; note idx counts note-ons, text idx skips CCBZ
--reaper: blob = repeat(i4 offset, B flags, s4 msg) + trailing 12-byte all-notes-off tail (excluded)
--reaper: flags bit1=muted; bits4-6=cc shape; status byte classifies; CCBZ rides FF-0F after its cc

local util = require 'util'

local chanMsgEvTypes = { [0xA0] = 'pa', [0xB0] = 'cc', [0xC0] = 'pc', [0xD0] = 'at', [0xE0] = 'pb' }
local shapeNames     = { [0] = 'step', [1] = 'linear', [2] = 'slow',
                         [3] = 'fast-start', [4] = 'fast-end', [5] = 'bezier' }

local shapeCodes, hiByEvType = {}, {}
for code, name in pairs(shapeNames)     do shapeCodes[name] = code end
for hi,   name in pairs(chanMsgEvTypes) do hiByEvType[name] = hi  end
local oneDataByte = { pc = true, at = true }   -- status + a single 7-bit data byte

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

--shape: serialise(notes, ccs, texts, passthrough) -> blob   -- exact inverse of parse, mm-shape in
--invariant: parse(serialise(x))==x; coincident events may reorder, per-type record lists preserved
--reaper: output matches the MIDI_SetAllEvts blob format; 12-byte all-notes-off tail appended
function midiBlob.serialise(notes, ccs, texts, passthrough)
  local wire = {}
  local function push(ppq, rank, seq, flags, msg)
    util.add(wire, { ppq = ppq, rank = rank, seq = seq, flags = flags, msg = msg })
  end

  for i, n in ipairs(notes) do
    local ch = n.chan - 1
    push(n.ppq,    1, i, n.muted and 0x02 or 0, string.char(0x90 | ch, n.pitch, n.vel))
    push(n.endppq, 0, i, 0,                      string.char(0x80 | ch, n.pitch, 0))
  end

  for i, c in ipairs(ccs) do
    local flags = (c.muted and 0x02 or 0) | ((shapeCodes[c.shape] or 0) << 4)
    push(c.ppq, 2, i, flags, ccWire(c))
    if c.shape == 'bezier' then
      push(c.ppq, 2, i + 0.5, 0, '\xFF\x0F' .. 'CCBZ ' .. '\0' .. string.pack('f', c.tension or 0))
    end
  end

  for i, x in ipairs(texts) do
    local msg = x.eventtype == -1
      and ('\xF0' .. x.msg .. '\xF7')
      or  ('\xFF' .. string.char(x.eventtype) .. x.msg)
    push(x.ppq, 3, i, 0, msg)
  end

  for i, p in ipairs(passthrough or {}) do
    push(p.ppq, 4, i, p.flags, p.msg)
  end

  table.sort(wire, function(a, b)
    if a.ppq  ~= b.ppq  then return a.ppq  < b.ppq  end
    if a.rank ~= b.rank then return a.rank < b.rank end
    return a.seq < b.seq
  end)

  local out, prev = {}, 0
  for _, ev in ipairs(wire) do
    util.add(out, string.pack('i4Bs4', ev.ppq - prev, ev.flags, ev.msg))
    prev = ev.ppq
  end
  util.add(out, string.pack('i4Bs4', 0, 0, '\xB0\x7B\x00'))   -- all-notes-off tail
  return table.concat(out)
end

return midiBlob
