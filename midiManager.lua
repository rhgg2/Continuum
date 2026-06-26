-- See docs/midiManager.md for the model.
--invariant: channels are 1..16 internally; +1 applied on read from REAPER, -1 on write
--invariant: loc is 1-indexed REAPER event-order; not stable across reloads
--invariant: mm holds realisation frame; delay baked into note-on ppq (docs/timing.md)
--invariant: mm holds raw pb; cents/detune + absorber pb live in tm (docs/tuning.md)
--invariant: muted is true-or-absent; false coerces to nil at write; pass false to clear
--invariant: per-event metadata: util:serialise to take ext-data, unserialised on read
local util = require 'util'

local take = (...).take

-- A deleted take leaves `take` dangling (the dormant bindTake(nil) seam keeps
-- it for tm's last frame); like cm:pollUndo, a dead ptr self-heals to nil here.
local function liveTake()
  if take and reaper.ValidatePtr2
     and not reaper.ValidatePtr2(0, take, 'MediaItem_Take*') then
    take = nil
  end
  return take
end

local function print(...)
  return util.print(...)
end

local mm = {}

--invariant: chanMsgEvTypes is derived from chanMsgLUT so the two directions can't drift
local chanMsgLUT = { pa = 0xA0, cc = 0xB0, pc = 0xC0, at = 0xD0, pb = 0xE0 }
local chanMsgEvTypes = {}
for k, v in pairs(chanMsgLUT) do chanMsgEvTypes[v] = k end


---------- PRIVATE

local notes      = {}
local ccs        = {}
local eventsByUuid      = {}
local tokenIdx   = {}
local wideMsb    = {}   -- (chan*128+cc) -> true: code is a 14-bit MSB; LSB rides cc+32
local maxUUID    = 0
local lock       = false

-- Opaque, content-keyed addressing. Token is private string built from
-- the event's identity fields; collision-free by construction across the
-- evType space. Rebuilt fresh in mm:load alongside eventsByUuid.
local function tokenOf(evt)
  local et = evt.evType
  if et == 'note' then return util.key('note', evt.chan, evt.pitch, evt.ppq) end
  if et == 'pa'   then return util.key('pa',   evt.chan, evt.pitch, evt.ppq) end
  if et == 'cc'   then return util.key('cc',   evt.chan, evt.cc,    evt.ppq) end
  return util.key(et, evt.chan, evt.ppq)
end

--contract: INTERNALS fields (idx, uuidIdx) stripped from clones returned to callers
local INTERNALS = { idx = true, uuidIdx = true }

-- 14-bit CC carriers: MSB code n, fixed-point value 0..127.99.., low 7 bits ride n+32.
-- See design/archive/note-macros.md § Continuous realisation.
local function wideKey(chan, cc) return chan * 128 + cc end
local function isWideMsb(c) return c.evType == 'cc' and c.cc and wideMsb[wideKey(c.chan, c.cc)] end
local function isWideLsb(c)
  return c.evType == 'cc' and c.cc and c.cc >= 32 and wideMsb[wideKey(c.chan, c.cc - 32)]
end
local function splitWide(val)
  local msb = math.floor(val)
  local lsb = util.round((val - msb) * 128)
  if lsb >= 128 then msb, lsb = msb + 1, 0 end
  return util.clamp(msb, 0, 127), lsb
end

--invariant: shapeNames is derived from shapeLUT so the two directions can't drift
local shapeLUT = { step = 0, linear = 1, slow = 2, ['fast-start'] = 3, ['fast-end'] = 4, bezier = 5 }
local shapeNames = {}
for k, v in pairs(shapeLUT) do shapeNames[v] = k end

local curveSample do
  local BEZIER = {
    { 0.2794, 0.4636,    0.4636 },
    { 0.3442, 0.7704,    0.3384 },
    { 0.4020, 0.9849,    0.2466 },
    { 0.4642, 1.1455,    0.1812 },
    { 0.5326, 1.2647,    0.1353 },
    { 0.6059, 1.3532,    0.1011 },
    { 0.6820, 1.4199,    0.0738 },
    { 0.7604, 1.4714,    0.0515 },
    { 0.8397, 1.5116,    0.0321 },
    { 0.9198, 1.5441,    0.0154 },
    { 1.0000, math.pi / 2, 0 },
  }

  local function bezierSample(tau, t)
    if t <= 0 then return 0 end
    if t >= 1 then return 1 end
    local fi     = util.clamp(math.abs(tau), 0, 1) * 10
    local i      = math.min(math.floor(fi), 9)
    local f      = fi - i
    local r0, r1 = BEZIER[i + 1], BEZIER[i + 2]
    local h      = r0[1] + (r1[1] - r0[1]) * f
    local tL     = r0[2] + (r1[2] - r0[2]) * f
    local tS     = r0[3] + (r1[3] - r0[3]) * f
    local t1, t2 = tS, tL
    if tau < 0 then t1, t2 = tL, tS end
    local ax, ay = h * math.cos(t1), h * math.sin(t1)
    local bx, by = 1 - h * math.cos(t2), 1 - h * math.sin(t2)
    local lo, hi = 0, 1
    for _ = 1, 20 do
      local s = (lo + hi) * 0.5
      local u = 1 - s
      local x = 3 * u * u * s * ax + 3 * u * s * s * bx + s * s * s
      if x < t then lo = s else hi = s end
    end
    local s = (lo + hi) * 0.5
    local u = 1 - s
    return 3 * u * u * s * ay + 3 * u * s * s * by + s * s * s
  end

  function curveSample(shape, tension, t)
    if shape == 'step' then
      return t >= 1 and 1 or 0
    elseif shape == 'linear' then
      return t
    elseif shape == 'slow' then
      return t * t * (3 - 2 * t)
    elseif shape == 'fast-start' then
      local u = 1 - t; return 1 - u * u * u
    elseif shape == 'fast-end' then
      return t * t * t
    elseif shape == 'bezier' then
      return bezierSample(tension or 0, t)
    end
  end
end

--shape: ccSidecar.body = '}RDM' [typeNib chan-1 id val_lo7 val_hi7] uuid-base36
--shape: noteSidecar.body = 'NOTE <chan-1> <pitch> custom ctm_<base36>'   (text type 15)
local noteSidecarEncode, noteSidecarDecode, ccSidecarEncode, ccSidecarDecode do
  local SIDECAR_MAGIC = '\x7D\x52\x44\x4D'  -- '}RDM'
  local function idOf(cc) return cc.cc or cc.pitch or 0 end

  function noteSidecarEncode(note)
    return string.format('NOTE %d %d custom ctm_%s', note.chan-1, note.pitch, util.toBase36(note.uuid))
  end

  function noteSidecarDecode(msg)
    local chan, pitch, uuidTxt = msg:match('^NOTE%s+(%d+)%s+(%d+)%s+custom%s+ctm_(.+)$')
    if uuidTxt then
      return { chan = chan + 1, pitch = pitch, uuid = util.fromBase36(uuidTxt) }
    end
  end

  function ccSidecarEncode(cc)
    local typeByte = chanMsgLUT[cc.evType]
    if not typeByte then return nil end
    local typeNib = typeByte >> 4

    local lo, hi
    if cc.evType == 'pb' then
      local raw = (cc.val or 0) + 8192
      lo, hi = raw & 0x7F, (raw >> 7) & 0x7F
    elseif cc.evType == 'pa' then
      lo, hi = (cc.vel or 0) & 0x7F, 0
    else
      lo, hi = (cc.val or 0) & 0x7F, 0
    end

    return SIDECAR_MAGIC
      .. string.char(typeNib)
      .. string.char((cc.chan or 1) - 1)
      .. string.char(idOf(cc))
      .. string.char(lo)
      .. string.char(hi)
      .. util.toBase36(cc.uuid)
  end

  function ccSidecarDecode(body)
    if not body or #body < 10 then return nil end
    if body:sub(1, 4) ~= SIDECAR_MAGIC then return nil end

    local out = {}
    out.evType = chanMsgEvTypes[body:byte(5) << 4]
    out.uuid = tonumber(body:sub(10), 36)
    if not out.evType or not out.uuid then return nil end
    local lo, hi = body:byte(8), body:byte(9)
    out.chan = body:byte(6) + 1
    if     out.evType == 'pb' then out.val = ((hi << 7) | lo) - 8192
    elseif out.evType == 'pa' then out.vel = lo
    else                           out.val = lo end
    if     out.evType == 'cc' then out.cc    = body:byte(7)
    elseif out.evType == 'pa' then out.pitch = body:byte(7)
    end
    return out
  end
end

-- Resolve a sidecar's current wire index by content for REAPER text type
-- (15 = note notation, -1 = cc/pb). uuidIdx desyncs once a delete shifts the
-- shared text-sysex stream within a modify, so in-modify writes/deletes must
-- re-resolve rather than trust it.
local function sidecarIdxOf(uuid, eventType)
  if not uuid then return nil end
  local _, _, _, textCount = reaper.MIDI_CountEvts(take)
  for i = 0, textCount - 1 do
    local ok, _, _, _, et, msg = reaper.MIDI_GetTextSysexEvt(take, i)
    if ok and et == eventType then
      local sc = (eventType == 15) and noteSidecarDecode(msg) or ccSidecarDecode(msg)
      if sc and sc.uuid == uuid then return i end
    end
  end
end

local function loadMetadata()
  if not take then return {} end

  local ok, keysText = reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:ctm_keys', '', false)
  if not (ok and keysText and keysText ~= '') then return {} end
  local tbl = {}
  for uuidTxt in keysText:gmatch('[^,]+') do
    local uuid = util.fromBase36(uuidTxt)
    tbl[uuid] = { }

    local entryOk, fields = reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:ctm_' .. uuidTxt, '', false)
    if entryOk and fields then
      tbl[uuid] = util.unserialise(fields)
    end
  end
  return tbl
end

local noteEventFields = {
  idx = true, loc = true, ppq = true, endppq = true, chan = true,
  evType = true, pitch = true, vel = true, muted = true, uuid = true, uuidIdx = true,
  sampleShadowed = true,
}
local ccEventFields = {
  idx = true, loc = true, uuidIdx = true, ppq = true, evType = true, chan = true,
  cc = true, pitch = true, val = true, vel = true,
  muted = true, shape = true, tension = true, uuid = true,
}

local function saveMetadatum(uuid)
  if not take then return end

  local uuidTxt = util.toBase36(uuid)
  local evt   = eventsByUuid[uuid]

  if not evt then
    print('Error! uuid not found')
    return
  end

  local strip = (evt.evType == 'note') and noteEventFields or ccEventFields
  reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:ctm_' .. uuidTxt, util.serialise(evt, strip), true)

  -- Ensure uuid is in the keys list so loadMetadata() finds it on reload
  local ok, keysText = reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:ctm_keys', '', false)
  if not ok or not keysText or not keysText:find(uuidTxt, 1, true) then
    local keys = (ok and keysText and keysText ~= '') and (keysText .. ',' .. uuidTxt) or uuidTxt
    reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:ctm_keys', keys, true)
  end
end

-- Wipe one uuid's ext-data + keys entry inline, so internal reloads can skip the
-- wholesale saveMetadata() keys-reconcile. See docs/midiManager.md § Metadata I/O.
local function deleteMetadatum(uuid)
  if not (take and uuid) then return end
  local uuidTxt = util.toBase36(uuid)
  reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:ctm_' .. uuidTxt, '', true)

  local ok, keysText = reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:ctm_keys', '', false)
  if ok and keysText and keysText ~= '' then
    local kept = {}
    for k in keysText:gmatch('[^,]+') do
      if k ~= uuidTxt then kept[#kept + 1] = k end
    end
    reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:ctm_keys', table.concat(kept, ','), true)
  end
end

local function saveMetadata()
  if not take then return end

  local newKeys, keyList = {}, {}
  for uuid in pairs(eventsByUuid) do
    local uuidTxt = util.toBase36(uuid)
    newKeys[uuidTxt] = true
    util.add(keyList, uuidTxt)
    saveMetadatum(uuid)
  end

  local ok, oldKeysText = reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:ctm_keys', '', false)
  if ok and oldKeysText and oldKeysText ~= '' then
    for oldUuidTxt in oldKeysText:gmatch('[^,]+') do
      if not newKeys[oldUuidTxt] then
        -- Writing an empty string effectively removes the extension data
        reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:ctm_' .. oldUuidTxt, '', true)
      end
    end
  end

  reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:ctm_keys', table.concat(keyList, ','), true)
end

-- In-memory equivalent of loadMetadata() (per uuid, the non-structural fields):
-- lets an internal reload reuse live metadata. See docs/midiManager.md § Metadata I/O.
local function snapshotMetadata()
  local tbl = {}
  for uuid, evt in pairs(eventsByUuid) do
    local strip = (evt.evType == 'note') and noteEventFields or ccEventFields
    local meta = {}
    for k, v in pairs(evt) do
      if not strip[k] then meta[k] = v end
    end
    tbl[uuid] = meta
  end
  return tbl
end

----- Utils

local function assignNewUUID(evt)
  maxUUID = maxUUID + 1
  evt.uuid = maxUUID
  eventsByUuid[maxUUID] = evt
  return maxUUID
end

---------- PUBLIC

--shape: note = { evType, ppq, endppq, chan, pitch, vel, [muted], [uuid], [...meta] }
--invariant: note.chan ∈ 1..16; pitch/vel ∈ 0..127; muted is true-or-absent
--shape: cc = { evType, ppq, chan, val, shape, [tension], [muted], [uuid], [...meta] }
--invariant: cc.evType ∈ {cc, pb, pa, at, pc}; pa stores in .vel, others in .val
--invariant: cc.cc set on evType='cc'; cc.pitch set on 'pa'; chan ∈ 1..16; cc/pitch ∈ 0..127
--invariant: cc.shape ∈ {step, linear, slow, fast-start, fast-end, bezier}; tension only on bezier
--shape: noteSidecarPayload = { ppq, chan, pitch, droppedCount }  -- notesDeduped event
--shape: uuidsReassignedEvent = { ppq, chan, pitch, oldUuid, newUuid }
--shape: ccDedupEvent = { ppq, chan, evType, cc, pitch, droppedCount }  -- ccsDeduped event
--shape: reconcileEvent base = { kind, uuid, chan, evType, [cc], [pitch], ppq }
--shape: reconcileEvent.valueRebound = base + { oldVal, newVal }
--shape: reconcileEvent.consensusRebound = base + { offset }
--shape: reconcileEvent.guessedRebound = base
--shape: reconcileEvent.ambiguous = { kind, uuid, candidateppqs }
--shape: reconcileEvent.orphaned = base + { lastppq } (lastppq replaces ppq)
local fire = util.installHooks(mm)

----- Load

--contract: internal reload (lock held) reuses live metadata; skips ext-data read + write
--contract: external load (take swap, undo, watcher, init) does full loadMetadata + saveMetadata
function mm:load(newTake)
  if not newTake then return end

  local takeSwapped = take ~= newTake
  -- wideCC registration is per-take config (tm re-asserts it each rebuild from
  -- the take's hosts); a swapped-in take must not inherit the old one's codes.
  if takeSwapped then take = newTake; wideMsb = {} end

  -- lock is held only by modify() at reload time → this is a self-inflicted reload.
  -- Snapshot the live metadata before the clear so we can skip the ext-data round-trip.
  local internal = lock
  local carried  = internal and snapshotMetadata() or nil

  notes, ccs, eventsByUuid, tokenIdx, maxUUID, lock = {}, {}, {}, {}, 0, false
  local ccSidecars, noteSidecars = {}, {}
  local sidecarRewrites, sidecarInserts, sidecarDeletes, ccDeletes = {}, {}, {}, {}
  local noteDedupEvents, ccDedupEvents, reassignEvents, reconcileEvents = {}, {}, {}, {}
  local takeDirty = false  -- set when an in-load step re-sorts the take (see final read pass)

  local metadata = carried or loadMetadata()
  for uuid in pairs(metadata) do if uuid > maxUUID then maxUUID = uuid end end

  ----- Helper functions
  local function noteKey(n)   return util.key(n.ppq, n.chan, n.pitch) end
  local function idOf(cc)     return cc.cc or cc.pitch or 0 end
  local function ccIdKey(e)   return util.key(e.evType, e.chan, idOf(e)) end
  local function ccPPQKey(e)  return util.key(ccIdKey(e), e.ppq) end
  local function ccFullKey(e) return util.key(ccPPQKey(e), e.val or 0) end

  ----- Read notes
  local _, noteCount = reaper.MIDI_CountEvts(take)
  for i = 0, noteCount-1 do
    local ok, _, muted, ppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
    if ok then
      local evt = { idx = i, evType = 'note', ppq = ppq, endppq = endppq, chan = chan + 1, pitch = pitch, vel = vel }
      if muted then evt.muted = true end
      util.add(notes, evt)
    end
  end

  ----- Note dedup

  local notesKeyed = {}
  do
    local groups, noteDeletes = {}, {}
    for loc, n in ipairs(notes) do
      local key = noteKey(n)
      local g = groups[key]
      if not g then
        groups[key] = { kept = loc, dropped = {} }
      elseif n.endppq > notes[g.kept].endppq then
        util.add(g.dropped, g.kept); g.kept = loc
      else
        util.add(g.dropped, loc)
      end
    end
    for key, g in pairs(groups) do
      local kept = notes[g.kept]
      notesKeyed[key] = kept
      if #g.dropped > 0 then
        util.add(noteDedupEvents, util.pick(kept, 'ppq chan pitch', { droppedCount = #g.dropped }))
        for _, loc in ipairs(g.dropped) do
          util.add(noteDeletes, notes[loc].idx)
          notes[loc] = nil
        end
      end
    end
    if #noteDeletes > 0 then
      takeDirty = true
      table.sort(noteDeletes)
      reaper.MIDI_DisableSort(take)
      for i = #noteDeletes, 1, -1 do reaper.MIDI_DeleteNote(take, noteDeletes[i]) end
      reaper.MIDI_Sort(take)
    end
  end

  ----- Read ccs + sysex
  local _, _, ccCount, textCount = reaper.MIDI_CountEvts(take)

  for i = 0, ccCount-1 do
    local ok, _, muted, ppq, chanmsg, chan, msg2, msg3 = reaper.MIDI_GetCC(take, i)
    if ok then
      local evType = chanMsgEvTypes[chanmsg] or ('chanmsg_' .. chanmsg)
      local evt = { idx = i, ppq = ppq, evType = evType, chan = chan + 1}
      if muted then evt.muted = true end
      if     evType == 'pa' then evt.pitch, evt.vel = msg2, msg3
      elseif evType == 'cc' then evt.cc,    evt.val = msg2, msg3
      elseif evType == 'pc' or evType == 'at' then evt.val = msg2
      elseif evType == 'pb' then evt.val = ((msg3 << 7) | msg2) - 8192
      end
      local _, shape, tension = reaper.MIDI_GetCCShape(take, i)
      evt.shape = shapeNames[shape] or 'step'
      if evt.shape == 'bezier' then evt.tension = tension end
      util.add(ccs, evt)
    end
  end

  for i = 0, textCount-1 do
    local ok, _, _, ppq, eventtype, msg = reaper.MIDI_GetTextSysexEvt(take, i)
    if ok and eventtype == 15 then
      local sc = noteSidecarDecode(msg)
      if sc then util.add(noteSidecars, util.assign(sc, { idx = i, ppq = ppq})) end
    elseif ok and eventtype == -1 then
      local sc = ccSidecarDecode(msg)
      if sc then util.add(ccSidecars, util.assign(sc, { idx = i, ppq = ppq})) end
    end
  end
  local sidecarCount = #ccSidecars

  ----- CC dedup

  do
    local stageOneHit = {}
    for _, s in ipairs(ccSidecars) do
      stageOneHit[ccFullKey(s)] = true
    end

    local groups = {}
    for loc, c in ipairs(ccs) do util.bucket(groups, ccPPQKey(c), loc) end

    for _, locs in pairs(groups) do
      if #locs > 1 then
        local candidates, fallbacks = {}, {}
        for _, loc in ipairs(locs) do
          util.add(stageOneHit[ccFullKey(ccs[loc])] and candidates or fallbacks, loc)
        end
        local pool = #candidates > 0 and candidates or fallbacks
        local winnerLoc = pool[#pool]
        local kept = ccs[winnerLoc]
        util.add(ccDedupEvents, util.pick(kept, 'ppq chan evType cc pitch', { droppedCount = #locs - 1 }))
        for _, loc in ipairs(locs) do
          if loc ~= winnerLoc then util.add(ccDeletes, ccs[loc].idx); ccs[loc] = nil end
        end
      end
    end
  end

  ----- UUID unification (notes ↔ noteSidecars)

  do
    local uuidCount = {}
    for _, ns in ipairs(noteSidecars) do
      local note = notesKeyed[noteKey(ns)]
      if note and not note.uuid then
        note.uuid, note.uuidIdx = ns.uuid, ns.idx
        uuidCount[ns.uuid] = (uuidCount[ns.uuid] or 0) + 1
      else
        util.add(sidecarDeletes, ns.idx)
      end
    end

    for _, note in pairs(notesKeyed) do
      local uuid = note.uuid
      if uuid and uuidCount[uuid] > 1 then
        local oldUUID = uuid
        local newUUID = assignNewUUID(note)
        uuidCount[oldUUID] = uuidCount[oldUUID] - 1
        uuidCount[newUUID] = 1
        metadata[newUUID] = util.clone(metadata[oldUUID]) or {}
        util.add(sidecarRewrites, {
          idx = note.uuidIdx, ppq = note.ppq, type = 15,
          body = noteSidecarEncode(note),
        })
        util.add(reassignEvents, util.pick(note, 'ppq chan pitch', { oldUuid = oldUUID, newUuid = newUUID }))
      elseif uuid then
        eventsByUuid[uuid] = note
      else
        local newUUID = assignNewUUID(note)
        uuidCount[newUUID] = 1
        metadata[newUUID] = {}
        util.add(sidecarInserts, util.pick(note, 'ppq chan pitch', { uuid = newUUID }))
      end
    end
  end

  ----- Sidecar reconcile (ccs ↔ ccSidecars)
  if next(ccSidecars) then
    --contract: stage-3 consensus: winning offset needs ≥ max(2, ceil(0.5·n)) votes, unique
    local THRESHOLD_FRAC, THRESHOLD_MIN = 0.5, 2
    local scsWorking, ccsWorking = util.clone(ccSidecars), util.clone(ccs)
    local scBuckets, ccBuckets

    local function bucketBy(keyFn)
      scBuckets, ccBuckets = {}, {}
      for _, s in pairs(scsWorking) do util.bucket(scBuckets, keyFn(s), s) end
      for _, c in pairs(ccsWorking) do util.bucket(ccBuckets, keyFn(c), c) end
    end

    local function bind(s, c, kind, extras)
      local function removeFirst(t, e)
        for i, x in pairs(t) do if x == e then t[i] = nil; return end end
      end
      c.uuid, c.uuidIdx = s.uuid, s.idx
      if s.uuid > maxUUID then maxUUID = s.uuid end
      if kind then
        util.add(sidecarRewrites, { idx = s.idx, ppq = c.ppq, type = -1, body = ccSidecarEncode(c) })
        util.add(reconcileEvents,
          util.assign(util.pick(c, 'ppq chan evType cc pitch', { kind = kind, uuid = s.uuid }),
                      extras or {}))
      end
      removeFirst(scsWorking, s); removeFirst(ccsWorking, c)
    end

    -- Stage 1: exact (ppq, val).
    bucketBy(ccFullKey)
    for k, scs in pairs(scBuckets) do
      local cs = ccBuckets[k] or {}
      for _, s in ipairs(scs) do
        if cs[1] then bind(s, cs[1]); table.remove(cs, 1) end
      end
    end

    -- Stage 2: same ppq, val drift.
    bucketBy(ccPPQKey)
    for k, scs in pairs(scBuckets) do
      local cs = ccBuckets[k] or {}
      for _, s in ipairs(scs) do
        local c = cs[1]
        if c then
          bind(s, c, 'valueRebound', { oldVal = (s.evType == 'pa') and s.vel or s.val,
                                       newVal = (c.evType == 'pa') and c.vel or c.val })
          table.remove(cs, 1)
        end
      end
    end

    -- Stage 3: consensus offset.
    bucketBy(ccIdKey)
    for k, scs in pairs(scBuckets) do
      local cs = ccBuckets[k] or {}
      if #scs > 0 and #cs > 0 then
        local offsetVotes, sidecarOffsets = {}, {}
        for _, s in ipairs(scs) do
          local seen = {}
          for _, c in ipairs(cs) do
            local off = c.ppq - s.ppq
            if not seen[off] then
              seen[off] = true
              offsetVotes[off] = (offsetVotes[off] or 0) + 1
            end
          end
          sidecarOffsets[s] = seen
        end

        local bestOff, bestCount, tied = nil, 0, false
        for off, count in pairs(offsetVotes) do
          if count > bestCount then bestOff, bestCount, tied = off, count, false
          elseif count == bestCount then tied = true end
        end

        local threshold = math.max(THRESHOLD_MIN, math.ceil(THRESHOLD_FRAC * #scs))
        if bestOff and not tied and bestCount >= threshold then
          for _, s in ipairs(scs) do
            if sidecarOffsets[s][bestOff] then
              for i, c in ipairs(cs) do
                if c.ppq - s.ppq == bestOff then
                  bind(s, c, 'consensusRebound', { offset = bestOff })
                  table.remove(cs, i)
                  break
                end
              end
            end
          end
        end
      end
    end

    -- Stage 4: per-orphan fallback.
    bucketBy(ccIdKey)
    for k, scs in pairs(scBuckets) do
      local cs = ccBuckets[k] or {}
      for _, s in ipairs(scs) do
        if #cs == 0 then
          util.add(reconcileEvents, util.pick(s, 'uuid chan evType cc pitch', { kind = 'orphaned', lastppq = s.ppq }))
        elseif #cs == 1 then
          bind(s, cs[1], 'guessedRebound')
          table.remove(cs, 1)
        else
          local ppqs = {}
          for _, c in ipairs(cs) do util.add(ppqs, c.ppq) end
          util.add(reconcileEvents, { kind = 'ambiguous', uuid = s.uuid, candidateppqs = ppqs })
        end
      end
    end

    if next(scsWorking) then
      local unbound = {}
      for _, s in pairs(scsWorking) do unbound[s] = true end
      for loc, sc in pairs(ccSidecars) do
        if unbound[sc] then
          util.add(sidecarDeletes, sc.idx)
          ccSidecars[loc] = nil
        end
      end
    end
  end

  ----- Single bracketed flush: sets first (idx-stable), deletes descending,
  ----- inserts last (their idxs aren't tracked — final read will pick them up).
  local hasFlush = #sidecarRewrites + #ccDeletes + #sidecarDeletes + #sidecarInserts > 0
  if hasFlush then
    takeDirty = true
    reaper.MIDI_DisableSort(take)
    for _, r in ipairs(sidecarRewrites) do
      reaper.MIDI_SetTextSysexEvt(take, r.idx, nil, nil, r.ppq, r.type, r.body, true)
    end

    table.sort(ccDeletes, function(a, b) return a > b end)
    table.sort(sidecarDeletes, function(a, b) return a > b end)
    for _, idx in ipairs(ccDeletes) do reaper.MIDI_DeleteCC(take, idx) end
    for _, idx in ipairs(sidecarDeletes) do reaper.MIDI_DeleteTextSysexEvt(take, idx) end

    for _, ins in ipairs(sidecarInserts) do
      reaper.MIDI_InsertTextSysexEvt(take, false, false, ins.ppq, 15, noteSidecarEncode(ins))
    end
    reaper.MIDI_Sort(take)
  end

  ----- Compact in-memory tables to dense; loc is the lua position
  ----- (1-based), valid until next rebuild
  notes      = util.compact(notes,      noteCount)
  ccs        = util.compact(ccs,        ccCount)
  ccSidecars = util.compact(ccSidecars, sidecarCount)
  for i, n in ipairs(notes) do n.loc = i end
  for i, c in ipairs(ccs)   do c.loc = i end

  ----- Rebuild in-memory indices: notesKeyed / tokenIdx / eventsByUuid + metadata join
  notesKeyed = {}
  local ccsKeyed = {}
  for _, n in ipairs(notes) do
    notesKeyed[noteKey(n)] = n
    tokenIdx[tokenOf(n)] = n
    util.assign(n, metadata[n.uuid])
  end
  for _, c in ipairs(ccs) do
    ccsKeyed[ccPPQKey(c)] = c
    tokenIdx[tokenOf(c)] = c
    if c.uuid then
      eventsByUuid[c.uuid] = c
      util.assign(c, metadata[c.uuid])
    end
  end

  -- idx/uuidIdx re-read: only needed when load re-sorted the take (dedup / sidecar
  -- reconcile). On a clean reload the first-pass indices still hold. See docs § Index re-read elision.
  if takeDirty then
    _, noteCount, ccCount, textCount = reaper.MIDI_CountEvts(take)
    for i = 0, noteCount-1 do
      local ok, _, _, ppq, _, chan, pitch = reaper.MIDI_GetNote(take, i)
      if ok then
        local evt = { ppq = ppq, chan = chan + 1, pitch = pitch }
        local n = notesKeyed[noteKey(evt)]
        if n then n.idx = i end
      end
    end
    for i = 0, ccCount-1 do
      local ok, _, _, ppq, chanmsg, chan, msg2 = reaper.MIDI_GetCC(take, i)
      if ok then
        local evType = chanMsgEvTypes[chanmsg] or ('chanmsg_'..chanmsg)
        local evt = { ppq = ppq, chan = chan + 1, evType = evType }
        if evType == 'cc' then evt.cc = msg2 end
        if evType == 'pa' then evt.pitch = msg2 end
        local c = ccsKeyed[ccPPQKey(evt)]
        if c then c.idx = i end
      end
    end
    for i = 0, textCount-1 do
      local ok, _, _, _, eventtype, msg = reaper.MIDI_GetTextSysexEvt(take, i)
      local sc = ok and (eventtype == 15  and noteSidecarDecode(msg)
                      or eventtype == -1 and ccSidecarDecode(msg))
      local evt = sc and eventsByUuid[sc.uuid]
      if evt then evt.uuidIdx = i end
    end
  end

  ----- Persist + signals
  -- Internal reloads skip this — ext-data is kept current incrementally. See docs § Metadata I/O.
  if not internal then saveMetadata() end

  --contract: load fires signals in order: takeSwapped, notesDeduped, uuidsReassigned
  --contract: then: ccsDeduped, ccsReconciled, reload
  --contract: dedup/reconcile signals fire only when their event kind has ≥1 record
  --emits: takeSwapped    -- nil; only when load received a different take
  if takeSwapped           then fire('takeSwapped',     nil) end
  --emits: notesDeduped   -- { events = [{ppq, chan, pitch, droppedCount}, ...] }
  if #noteDedupEvents > 0  then fire('notesDeduped',    { events = noteDedupEvents }) end
  --emits: uuidsReassigned -- { events = [{ppq, chan, pitch, oldUuid, newUuid}, ...] }
  if #reassignEvents > 0   then fire('uuidsReassigned', { events = reassignEvents })  end
  --emits: ccsDeduped -- { events = [{ppq, chan, evType, cc, pitch, droppedCount}, ...] }
  if #ccDedupEvents > 0    then fire('ccsDeduped',      { events = ccDedupEvents })   end
  --emits: ccsReconciled -- { events = [reconcileEvent, ...] }  -- 5 kinds in reconcileEvent.*
  if #reconcileEvents > 0  then fire('ccsReconciled',   { events = reconcileEvents }) end
  --emits: reload         -- nil; every load, including after modify()
  fire('reload', nil)
end

function mm:reload()
  if not liveTake() then return end
  self:load(take)
end

--contract: clears mm.take and event tables when take dies; distinct from load(nil) dormant seam
function mm:unload()
  take = nil
  notes, ccs, eventsByUuid, tokenIdx, maxUUID, lock = {}, {}, {}, {}, 0, false
end


----- Locking

--contract: writes (add*, delete*, structural assign*) must run inside mm:modify(fn)
--contract: modify disables sort, runs fn under lock, re-sorts, then reload→callbacks
local function checkLock()
  assert(lock, 'Error! You must call modification functions via modify()!')
  return true
end

function mm:modify(fn)
  if not liveTake() then return end
  lock = true
  reaper.MIDI_DisableSort(take)
  local ok, err = pcall(fn)
  reaper.MIDI_Sort(take)
  self:reload()
  lock = false
  if not ok then print('Error in modify: ' .. tostring(err)) end
end

----- Notes

local function cloneOut(evt)
  if not evt then return nil end
  local c = util.clone(evt, INTERNALS)
  c.token = tokenOf(evt)
  if isWideMsb(evt) then
    local lsb = tokenIdx[tokenOf{ evType = 'cc', chan = evt.chan, cc = evt.cc + 32, ppq = evt.ppq }]
    c.val = evt.val + (lsb and lsb.val or 0) / 128
  end
  return c
end

function mm:notes()
  local i = 0
  return function()
    i = i + 1
    local note = notes[i]
    if note then return i, cloneOut(note) end
  end
end

--contract: assignNote: lockless write when t touches no structural field
--invariant: assignNote structural fields = {ppq, endppq, pitch, vel, chan, muted}
local function assignNote(loc, t)
  if not take then return end

  if not (t.ppq or t.endppq or t.pitch or t.vel or t.chan or t.muted ~= nil) then
    local note = notes[loc]
    if not note then return end

    util.assign(note, t)
    saveMetadatum(note.uuid)
    return
  end

  if not checkLock() then return end

  local note = notes[loc]
  if not note then return end

  local chan = (t.chan or note.chan) - 1
  local oldTok = tokenOf(note)

  -- nil args leave REAPER's value unchanged
  reaper.MIDI_SetNote(take, note.idx, nil, t.muted, t.ppq, t.endppq, chan, t.pitch, t.vel, true)

  util.assign(note, t)
  if note.muted == false then note.muted = nil end

  local newTok = tokenOf(note)
  if newTok ~= oldTok then
    tokenIdx[oldTok] = nil
    tokenIdx[newTok] = note
  end

  -- notation event encodes (chan, pitch) at ppq, so keep it in sync. Resolve the
  -- sidecar index fresh -- uuidIdx goes stale if a delete shifted the text-sysex
  -- stream earlier in this modify (notation + cc sidecars share that index space).
  if t.ppq or t.chan or t.pitch then
    local idx = sidecarIdxOf(note.uuid, 15)
    if idx then
      reaper.MIDI_SetTextSysexEvt(take, idx, nil, nil, note.ppq, 15, noteSidecarEncode(note), true)
    end
  end

  saveMetadatum(note.uuid)
end

--contract: addNote always allocates a uuid + inserts a notation event (unlike addCC)
local function addNote(t)
  if not (take and checkLock()) then return end

  if t.ppq == nil or t.endppq == nil or t.chan == nil or t.pitch == nil or t.vel == nil then
    print('Error! Underspecified new note')
    return
  end

  reaper.MIDI_InsertNote(take, false, t.muted or false, t.ppq, t.endppq, t.chan - 1, t.pitch, t.vel, true)

  local note = util.clone(t)
  note.evType = 'note'
  if not note.muted then note.muted = nil end
  assignNewUUID(note)
  t.uuid = note.uuid
  reaper.MIDI_InsertTextSysexEvt(take, false, false, t.ppq, 15, noteSidecarEncode(note))

  local _, noteCount, _, sysexCount = reaper.MIDI_CountEvts(take)
  note.uuidIdx = sysexCount - 1
  note.idx = noteCount - 1
  util.add(notes, note)
  note.loc = #notes
  tokenIdx[tokenOf(note)] = note

  saveMetadatum(note.uuid)

  return #notes
end

----- CCs

--contract: marks (chan, cc) a 14-bit MSB whose low 7 bits ride cc+32; transient, not persisted
--contract: writes split to MSB(shaped)/LSB(step) pair; reads coalesce to fixed-point val 0..127.99
--invariant: code is the only signal -- wire pair is not self-describing (design/archive/note-macros.md)
function mm:wideCC(chan, cc, on)
  wideMsb[wideKey(chan, cc)] = on or nil
end

function mm:ccs()
  local i = 0
  return function()
    while true do
      i = i + 1
      local msg = ccs[i]
      if not msg then return end
      if not isWideLsb(msg) then return i, cloneOut(msg) end
    end
  end
end

local function reconstruct(tbl)
  local evType = tbl.evType
  if not evType or evType == 'note' then return end

  local msg2, msg3
  if evType == 'pb' then
    local raw = (tbl.val or 0) + 8192
    msg2 = raw & 0x7F
    msg3 = (raw >> 7) & 0x7F
  elseif evType == 'pa' then
    msg2 = tbl.pitch or 0
    msg3 = tbl.vel   or 0
  elseif evType == 'pc' or evType == 'at' then
    msg2 = tbl.val or 0
    msg3 = 0
  else
    msg2 = tbl.cc  or 0
    msg3 = tbl.val or 0
  end
  return msg2, msg3
end

--contract: assignCC: lockless iff t touches no structural field and the cc has a uuid
--contract: first metadata stamp on a plain cc needs lock — inserts a sidecar sysex
local function assignCC(loc, t)
  if not take then return end

  local msg = ccs[loc]
  if not msg then return end

  local hasStructural = t.ppq or t.evType or t.chan or t.cc or t.pitch
                        or t.val or t.vel or t.muted ~= nil or t.shape or t.tension
  local hasMetadata = false
  for k in pairs(t) do
    if not ccEventFields[k] then hasMetadata = true; break end
  end

  if not hasStructural and msg.uuid then
    util.assign(msg, t)
    saveMetadatum(msg.uuid)
    return
  end

  if not checkLock() then return end

  local oldTok = tokenOf(msg)

  if hasStructural then
    local chanmsg, msg2, msg3
    if t.evType then
      chanmsg = chanMsgLUT[t.evType]
      if not chanmsg then
        print('Error! Unspecified message type')
        return
      end
      msg2, msg3 = reconstruct(t)
    elseif t.val or t.cc or t.pitch or t.vel then
      msg2, msg3 = reconstruct(util.assign(util.clone(msg), t))
    end
    local chan = t.chan and t.chan - 1
    reaper.MIDI_SetCC(take, msg.idx, nil, t.muted, t.ppq, chanmsg, chan, msg2, msg3, true)
  end

  util.assign(msg, t)

  if hasStructural then
    if msg.muted == false then msg.muted = nil end
    if msg.evType ~= 'cc' then msg.cc    = nil end
    if msg.evType ~= 'pa' then msg.pitch, msg.vel = nil, nil end
    if t.shape or t.tension then
      local shape = shapeLUT[msg.shape] or 0
      reaper.MIDI_SetCCShape(take, msg.idx, shape, msg.tension or 0, true)
    end
    if msg.shape ~= 'bezier' then msg.tension = nil end
  end

  local newTok = tokenOf(msg)
  if newTok ~= oldTok then
    tokenIdx[oldTok] = nil
    tokenIdx[newTok] = msg
  end

  if hasMetadata and not msg.uuid then
    assignNewUUID(msg)
    reaper.MIDI_InsertTextSysexEvt(take, false, false, msg.ppq, -1, ccSidecarEncode(msg))
    local _, _, _, sysexCount = reaper.MIDI_CountEvts(take)
    msg.uuidIdx = sysexCount - 1
  end

  if msg.uuid and hasStructural then
    -- Resolve fresh -- uuidIdx is stale if a delete shifted the shared text-sysex
    -- stream earlier in this modify, and would clobber a note's notation event.
    local idx = sidecarIdxOf(msg.uuid, -1)
    if idx then
      reaper.MIDI_SetTextSysexEvt(take, idx, nil, nil, msg.ppq, -1, ccSidecarEncode(msg), true)
    end
  end

  if msg.uuid then saveMetadatum(msg.uuid) end
end

-- Insert one ordinary CC: wire event + record + idx + token. No metadata
-- (the lazy-sidecar path lives in addCC); the wideCC split reuses this.
local function pushCC(t)
  local msg2, msg3 = reconstruct(t)
  reaper.MIDI_InsertCC(take, false, t.muted or false, t.ppq, chanMsgLUT[t.evType], t.chan - 1, msg2, msg3)

  local msg = util.clone(t)
  if not msg.muted then msg.muted = nil end

  local _, _, ccCount = reaper.MIDI_CountEvts(take)
  msg.idx = ccCount - 1

  if t.shape or t.tension then
    reaper.MIDI_SetCCShape(take, msg.idx, shapeLUT[t.shape] or 0, t.tension or 0, true)
  end
  if msg.shape ~= 'bezier' then msg.tension = nil end

  util.add(ccs, msg)
  msg.loc = #ccs
  tokenIdx[tokenOf(msg)] = msg
  return msg
end

--contract: addCC lazy-sidecar: uuid + sidecar only when t has a non-structural key
--contract: a wideCC-registered code splits to an MSB(shaped)/LSB(step) wire pair
local function addCC(t)
  if not (take and checkLock()) then return end

  if t.evType == nil then t.evType = 'cc' end

  local valueField = (t.evType == 'pa') and 'vel' or 'val'
  if t.ppq == nil or t.chan == nil or t[valueField] == nil then
    print('Error! Underspecified new cc event')
    return
  end

  if not chanMsgLUT[t.evType] then
    print('Error! Unspecified message type')
    return
  end

  if isWideMsb(t) then
    local msb, lsb = splitWide(t.val)
    pushCC{ evType = 'cc', chan = t.chan, cc = t.cc,      ppq = t.ppq, val = msb,
            shape = t.shape, tension = t.tension, muted = t.muted }
    pushCC{ evType = 'cc', chan = t.chan, cc = t.cc + 32, ppq = t.ppq, val = lsb,
            shape = 'step', muted = t.muted }
    return #ccs
  end

  local msg = pushCC(t)

  local hasMetadata = false
  for k in pairs(t) do
    if not ccEventFields[k] then hasMetadata = true; break end
  end
  if hasMetadata then
    assignNewUUID(msg)
    t.uuid = msg.uuid
    reaper.MIDI_InsertTextSysexEvt(take, false, false, msg.ppq, -1, ccSidecarEncode(msg))
    local _, _, _, sysexCount = reaper.MIDI_CountEvts(take)
    msg.uuidIdx = sysexCount - 1
    saveMetadatum(msg.uuid)
  end

  return #ccs
end

--contract: token stable across reload while identity fields don't change
--invariant: token identity fields = evType, chan, ppq, and pitch|cc as relevant
--contract: mutating an identity field retires the old token and issues a new one
function mm:tokenOf(evt)
  if not evt or not evt.evType then return nil end
  return tokenOf(evt)
end

--contract: returns (loc, evt-clone, kind) for the token, or nil if absent
--contract: works on every event (including plain ccs with no uuid)
--invariant: byToken's evt-clone carries .token equal to the input
function mm:byToken(token)
  local evt = tokenIdx[token]
  if not evt then return nil end
  return evt.loc, cloneOut(evt), (evt.evType == 'note') and 'note' or 'cc'
end

----- Unified token-keyed surface

--contract: t.evType='note' routes to addNote; anything else to addCC
--contract: returns the new token, or nil if t is malformed; inherits inner lock req
function mm:add(t)
  if not t or not t.evType then return nil end
  if t.evType == 'note' then addNote(t) else addCC(t) end
  return tokenOf(t)
end

--contract: dispatches on the resolved event's evType
--contract: returns the event's token, == input iff no identity field changed (caller re-keys)
--contract: inherits the inner method's metadata-only lockless carve-out
function mm:assign(token, t)
  local evt = tokenIdx[token]
  if not evt then return nil end
  if evt.evType == 'note' then assignNote(evt.loc, t)
  else                         assignCC(evt.loc, t) end
  return tokenOf(evt)
end

-- Mirror REAPER's idx-shift-down after a delete: decrement evt[field] on every
-- event in tbl whose field > threshold. Guarded by `v and` so uuidIdx (absent
-- on plain ccs) is safely skipped.
local function shiftDown(tbl, field, threshold)
  for _, e in pairs(tbl) do
    local v = e[field]
    if v and v > threshold then e[field] = v - 1 end
  end
end

-- Remove a cc/pb sidecar (type -1) by content. The sole caller is a cc/pb delete;
-- a note's notation (type 15) is cascade-removed by MIDI_DeleteNote. Resolve fresh
-- -- the shared text-sysex index space shifts across deletes within a modify.
local function deleteSidecarByUuid(uuid)
  local idx = sidecarIdxOf(uuid, -1)
  if idx then reaper.MIDI_DeleteTextSysexEvt(take, idx) end
end

--contract: immediate-mode delete (no batch); fires inside the modify caller's lock
--invariant: MIDI_DeleteNote cascade-removes notation sidecar; MIDI_DeleteCC does not
--contract: cc/pb sidecar is removed here by content-addressed scan on text events
--contract: per-array idx is shifted down so later deletes in this modify see correct slots
--invariant: uuidIdx is NOT tracked across deletes — post-modify read pass re-resolves
--contract: wipes the event's ctm_<uuid> ext-data + keys entry inline (internal reload skips save)
function mm:delete(token)
  if not (take and checkLock()) then return end
  local evt = tokenIdx[token]
  if not evt then return end

  if evt.evType == 'note' then
    tokenIdx[token] = nil
    notes[evt.loc] = nil
    eventsByUuid[evt.uuid] = nil
    deleteMetadatum(evt.uuid)
    reaper.MIDI_DeleteNote(take, evt.idx)
    shiftDown(notes, 'idx', evt.idx)
    return
  end

  -- A wideCC MSB drags its LSB shadow (code+32). Delete the higher wire
  -- idx first so the lower idx stays valid across shiftDown.
  local recs = { evt }
  if isWideMsb(evt) then
    local lsb = tokenIdx[tokenOf{ evType = 'cc', chan = evt.chan, cc = evt.cc + 32, ppq = evt.ppq }]
    if lsb then util.add(recs, lsb) end
  end
  table.sort(recs, function(a, b) return a.idx > b.idx end)
  for _, rec in ipairs(recs) do
    tokenIdx[tokenOf(rec)] = nil
    ccs[rec.loc] = nil
    if rec.uuid then eventsByUuid[rec.uuid] = nil; deleteMetadatum(rec.uuid) end
    reaper.MIDI_DeleteCC(take, rec.idx)
    shiftDown(ccs, 'idx', rec.idx)
    deleteSidecarByUuid(rec.uuid)
  end
end

--contract: yields (token, evt-clone) over all live events, notes then ccs
--invariant: events()'s clone carries .token; loc is intentionally absent
function mm:events()
  local i, src = 0, notes
  return function()
    while true do
      i = i + 1
      local e = src[i]
      if not e then
        if src == ccs then return end
        src, i = ccs, 0
      elseif src == ccs and isWideLsb(e) then
        -- LSB shadow: hidden behind its MSB
      else
        return tokenOf(e), cloneOut(e)
      end
    end
  end
end

----- Take data

function mm:take()
  return liveTake()
end

-- REAPER convention: shape on A governs the curve from A to next.
function mm:interpolate(A, B, ppq)
  if not A.shape or A.shape == 'step' then return A.val end
  local span = B.ppq - A.ppq
  if span == 0 then return A.val end
  local t = (ppq - A.ppq) / span
  return (A.val or 0) + curveSample(A.shape, A.tension, t) * ((B.val or 0) - (A.val or 0))
end

function mm:resolution()
  if not liveTake() then return end
  return reaper.MIDI_GetPPQPosFromProjQN(take, 1) - reaper.MIDI_GetPPQPosFromProjQN(take, 0)
end

-- Source length. setLength positions the source's EOT explicitly to keep this in sync.
function mm:length()
  if not liveTake() then return end
  local source = reaper.GetMediaItemTake_Source(take)
  local lenQN  = reaper.GetMediaSourceLength(source)
  return lenQN * self:resolution()
end

function mm:name()
  if not liveTake() then return end
  local _, name = reaper.GetSetMediaItemTakeInfo_String(take, 'P_NAME', '', false)
  return name
end

function mm:setName(name)
  if not liveTake() then return end
  reaper.GetSetMediaItemTakeInfo_String(take, 'P_NAME', name, true)
end

-- Rewrite the trailing EOT meta event so it sits exactly at targetPpq.
-- Handles both shrink (offset reduces) and grow (offset increases).
-- Assumes events past targetPpq are already deleted upstream on shrink
-- (tm:setLength does this).
local function setEot(buf, targetPpq)
  local pos, ppq, lastPpq, lastStart = 1, 0, 0, nil
  while pos + 8 <= #buf do
    local offset, _, msglen = string.unpack('<i4Bi4', buf, pos)
    lastPpq, lastStart = ppq, pos
    ppq = ppq + offset
    pos = pos + 9 + msglen
  end
  if not lastStart then return buf end
  local _, flag, msglen = string.unpack('<i4Bi4', buf, lastStart)
  local msg = buf:sub(lastStart + 9, lastStart + 9 + msglen - 1)
  local isEot = msglen == 3 and msg:byte(1) == 0xFF and msg:byte(2) == 0x2F
  if not isEot then return buf end
  local newOffset = math.max(0, targetPpq - lastPpq)
  return buf:sub(1, lastStart - 1)
      .. string.pack('<i4Bi4', newOffset, flag, msglen) .. msg
end

-- MIDI_SetItemExtents only resizes the item; on grow it leaves source EOT short,
-- on shrink it leaves source EOT stale. Reposition the source EOT first so the
-- source is the right size, then bring the item to match.
-- Project metadata only — bypasses modify(); fires reload so tm picks up the new length.
function mm:setLength(qn)
  if not liveTake() then return end
  local item     = reaper.GetMediaItemTake_Item(take)
  local startSec = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
  local startQN  = reaper.TimeMap2_timeToQN(0, startSec)
  local ok, buf = reaper.MIDI_GetAllEvts(take)
  if ok then
    local newBuf = setEot(buf, qn * self:resolution())
    if newBuf ~= buf then reaper.MIDI_SetAllEvts(take, newBuf) end
  end
  reaper.MIDI_SetItemExtents(item, startQN, startQN + qn)
  self:reload()
end

function mm:timeSigs()
  if not liveTake() then return {} end

  local item = reaper.GetMediaItemTake_Item(take)
  local startTime = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
  local itemLength = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
  local endTime = startTime + itemLength
  local baseppq = reaper.MIDI_GetPPQPosFromProjTime(take, startTime)

  local result = {}
  local count = reaper.CountTempoTimeSigMarkers(0)

  -- Scan for the last time-sig marker at or before take start; fall back to
  -- TimeMap_GetTimeSigAtTime if none precedes it (covers takes at project start).
  local initNum, initDenom
  for i = 0, count - 1 do
    local _, pos, _, _, _, num, denom, _ = reaper.GetTempoTimeSigMarker(0, i)
    if num > 0 and pos <= startTime then
      initNum, initDenom = num, denom
    end
  end

  if not initNum then
    local num, denom, _ = reaper.TimeMap_GetTimeSigAtTime(0, startTime)
    initNum, initDenom = num, denom
  end

  result[1] = { ppq = 0, num = initNum, denom = initDenom }

  for i = 0, count - 1 do
    local _, pos, _, _, _, num, denom, _ = reaper.GetTempoTimeSigMarker(0, i)
    if num > 0 and pos > startTime and pos < endTime then
      local ppq = reaper.MIDI_GetPPQPosFromProjTime(take, pos) - baseppq
      util.add(result, { ppq = ppq, num = num, denom = denom })
    end
  end

  return result
end

if take then mm:load(take) end
return mm

