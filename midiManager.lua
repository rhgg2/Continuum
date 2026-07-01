-- See docs/midiManager.md for the model.
--invariant: channels are 1..16 internally; +1 applied on read from REAPER, -1 on write
--invariant: loc is 1-indexed REAPER event-order; not stable across reloads
--invariant: mm holds realisation frame; delay baked into note-on ppq (docs/timing.md)
--invariant: mm holds raw pb; cents/detune + absorber pb live in tm (docs/tuning.md)
--invariant: muted is true-or-absent; false coerces to nil at write; pass false to clear
--invariant: per-event metadata persists via eventMeta, keyed by the take's POOL guid (docs/eventMeta.md)
local util = require 'util'
local midiBlob = require 'midiBlob'
local perf = require 'perf'

local take      = (...).take
local eventMeta = (...).eventMeta

-- A deleted take leaves `take` dangling (the dormant bindTake(nil) seam keeps
-- it for tm's last frame); like cm:pollUndo, a dead ptr self-heals to nil here.
local function liveTake()
  if take and reaper.ValidatePtr2
     and not reaper.ValidatePtr2(0, take, 'MediaItem_Take*') then
    take = nil
  end
  return take
end

-- Metadata is keyed by the take's POOLEDEVTS guid (its source identity), so every
-- pooled instance shares one blob. Derived from the item chunk, cached across reloads.
local poolGuid, ccInterp
local function setTakeGuid()
  poolGuid, ccInterp = nil, nil
  if not take then return end
  local item = reaper.GetMediaItemTake_Item(take)
  if not item then return end
  local ok, chunk = reaper.GetItemStateChunk(item, '', false)
  if ok and chunk then
    poolGuid = chunk:match('POOLEDEVTS%s+({[^}]+})')
    ccInterp = tonumber(chunk:match('CCINTERP%s+(%d+)'))
  end
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
local noteCount  = 0    -- high-water extent of notes/ccs; verbs leave holes, rebuild compacts
local ccCount    = 0
local eventsByUuid      = {}
local tokenIdx   = {}
local wideMsb    = {}   -- (chan*128+cc) -> true: code is a 14-bit MSB; LSB rides cc+32
local maxUUID    = 0
local lock       = false
local dirty      = false  -- a structural write happened; the take needs reprojecting via flushTake
local modifyDepth  = 0      -- reload can re-enter modify; only the outermost flushes
local flushPending = false  -- a dirty modify happened somewhere in the nest; flush once on unwind
local carriedTexts       = {}  -- parsed text/meta events mm doesn't model; re-emitted verbatim on flush
local carriedPassthrough = {}  -- parsed system messages mm doesn't model; re-emitted verbatim on flush

-- Opaque, content-keyed addressing. Token is private string built from
-- the event's identity fields; collision-free by construction across the
-- evType space. Rebuilt fresh in mm:load alongside eventsByUuid.
-- Chained concat, not util.key: one OP_CONCAT allocates once and coerces the
-- integer fields inline, vs util.key's per-arg tostring + table + table.concat.
-- Byte-identical (n..'' == tostring(n)), so tokens stay stable across the rewrite.
local function tokenOf(evt)
  local et = evt.evType
  if et == 'note' then return 'note\0' .. evt.chan .. '\0' .. evt.pitch .. '\0' .. evt.ppq end
  if et == 'pa'   then return 'pa\0'   .. evt.chan .. '\0' .. evt.pitch .. '\0' .. evt.ppq end
  if et == 'cc'   then return 'cc\0'   .. evt.chan .. '\0' .. evt.cc    .. '\0' .. evt.ppq end
  return et .. '\0' .. evt.chan .. '\0' .. evt.ppq
end

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

local shapeLUT = { step = 0, linear = 1, slow = 2, ['fast-start'] = 3, ['fast-end'] = 4, bezier = 5 }

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

local noteEventFields = {
  loc = true, ppq = true, endppq = true, chan = true,
  evType = true, pitch = true, vel = true, muted = true, uuid = true,
  sampleShadowed = true,
}
local ccEventFields = {
  loc = true, ppq = true, evType = true, chan = true,
  cc = true, pitch = true, val = true, vel = true,
  muted = true, shape = true, tension = true, uuid = true,
}

-- The metadata an event carries: every field that isn't structural or regenerated.
-- eventMeta stores these opaque; the strip (which fields count) is mm's alone.
local function metaFieldsOf(evt)
  local strip = (evt.evType == 'note') and noteEventFields or ccEventFields
  local meta = {}
  for k, v in pairs(evt) do if not strip[k] then meta[k] = v end end
  return meta
end

-- Per-modify metadata write buffer: incremental saves/deletes coalesce here so the
-- project-ext keys set is (de)serialised once at flushMetadata(), not per event.
local metaDirty, metaDeleted = {}, {}

local function saveMetadatum(uuid)
  local evt = eventsByUuid[uuid]
  if not evt then print('Error! uuid not found'); return end
  metaDirty[uuid], metaDeleted[uuid] = metaFieldsOf(evt), nil
end

local function deleteMetadatum(uuid)
  if uuid then metaDeleted[uuid], metaDirty[uuid] = true, nil end
end

-- Commit buffered metadata in one keys-set round-trip, once at the outermost
-- modify unwind. See docs/midiManager.md § Mutation contract.
local function flushMetadata()
  if next(metaDirty) or next(metaDeleted) then
    eventMeta:flush(poolGuid, metaDirty, metaDeleted)
  end
end

local function saveMetadata()
  local byUuid = {}
  for uuid, evt in pairs(eventsByUuid) do byUuid[uuid] = metaFieldsOf(evt) end
  eventMeta:saveAll(poolGuid, byUuid)
end

----- Utils

local function assignNewUUID(evt)
  maxUUID = maxUUID + 1
  evt.uuid = maxUUID
  eventsByUuid[maxUUID] = evt
  return maxUUID
end

-- Stable sort by ppq: REAPER's MIDI_Sort used to order the take and the
-- modify re-read mirrored it back; with the read-back gone mm owns the order,
-- and tm/view consume notes/ccs strictly in ppq order.
local function stableByPpq(list)
  for i, e in ipairs(list) do e.__ord = i end
  table.sort(list, function(a, b)
    if a.ppq ~= b.ppq then return a.ppq < b.ppq end
    return a.__ord < b.__ord
  end)
  for _, e in ipairs(list) do e.__ord = nil end
end

-- Compact the sparse note/cc arrays to dense (verbs and dedup leave holes),
-- order by ppq, recompute loc, and rebuild the token + uuid indices. metadata
-- (load only) joins the per-uuid non-structural fields back onto the records.
local function rebuild(metadata)
  notes = util.compact(notes, noteCount); noteCount = #notes
  ccs   = util.compact(ccs,   ccCount);   ccCount   = #ccs
  stableByPpq(notes); stableByPpq(ccs)
  tokenIdx, eventsByUuid = {}, {}
  for i, n in ipairs(notes) do
    n.loc = i
    tokenIdx[tokenOf(n)] = n
    if n.uuid then eventsByUuid[n.uuid] = n end
    if metadata then util.assign(n, metadata[n.uuid]) end
  end
  for i, c in ipairs(ccs) do
    c.loc = i
    tokenIdx[tokenOf(c)] = c
    if c.uuid then
      eventsByUuid[c.uuid] = c
      if metadata then util.assign(c, metadata[c.uuid]) end
    end
  end
end

-- Project the in-memory model onto the take as one whole-take blob: regenerate
-- every sidecar from its event's uuid, carry through unmodelled events, and
-- preserve the source-length EOT. The sole writer to the take.
local function flushTake()
  if not take then return end
  perf.start('sidecars')
  local texts = {}
  for _, n in ipairs(notes) do
    if n.uuid then util.add(texts, { ppq = n.ppq, eventtype = 15, msg = noteSidecarEncode(n) }) end
  end
  for _, c in ipairs(ccs) do
    if c.uuid then util.add(texts, { ppq = c.ppq, eventtype = -1, msg = ccSidecarEncode(c) }) end
  end
  for _, t in ipairs(carriedTexts) do util.add(texts, t) end
  perf.stop('sidecars')

  local source   = reaper.GetMediaItemTake_Source(take)
  local ppqPerQN = reaper.MIDI_GetPPQPosFromProjQN(take, 1) - reaper.MIDI_GetPPQPosFromProjQN(take, 0)
  local endPpq   = math.floor(reaper.GetMediaSourceLength(source) * ppqPerQN + 0.5)

  perf.start('serialise')
  local blob = midiBlob.serialise(notes, ccs, texts, carriedPassthrough, endPpq)
  perf.stop('serialise')

  perf.start('setEvts')
  reaper.MIDI_SetAllEvts(take, blob)
  perf.stop('setEvts')

  perf.count('notes', #notes); perf.count('ccs', #ccs); perf.count('texts', #texts)
  dirty = false
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

--contract: load is always external (lock-free): reads the take, normalises in-memory, reprojects
--contract: dedup/unify/reconcile mutate the model + set dirty; flushTake writes once if dirty
function mm:load(newTake)
  if not newTake then return end
  perf.start('load')

  local takeSwapped = take ~= newTake
  -- wideCC registration is per-take config (tm re-asserts it each rebuild from
  -- the take's hosts); a swapped-in take must not inherit the old one's codes.
  if takeSwapped then take = newTake; wideMsb = {}; setTakeGuid() end

  notes, ccs, eventsByUuid, tokenIdx, maxUUID, lock = {}, {}, {}, {}, 0, false
  carriedTexts, carriedPassthrough, dirty = {}, {}, false
  local ccSidecars, noteSidecars = {}, {}
  local noteDedupEvents, ccDedupEvents, reassignEvents, reconcileEvents = {}, {}, {}, {}

  local metadata = eventMeta:load(poolGuid)
  for uuid in pairs(metadata) do if uuid > maxUUID then maxUUID = uuid end end

  ----- Helper functions
  local function noteKey(n)   return util.key(n.ppq, n.chan, n.pitch) end
  local function idOf(cc)     return cc.cc or cc.pitch or 0 end
  local function ccIdKey(e)   return util.key(e.evType, e.chan, idOf(e)) end
  local function ccPPQKey(e)  return util.key(ccIdKey(e), e.ppq) end
  local function ccFullKey(e) return util.key(ccPPQKey(e), e.val or 0) end

  ----- Read take: one MIDI_GetAllEvts blob parsed to note/cc/text records
  perf.start('read')
  local _, blob = reaper.MIDI_GetAllEvts(take)
  local texts, passthrough
  notes, ccs, texts, passthrough = midiBlob.parse(blob)
  perf.stop('read')
  carriedPassthrough = passthrough
  noteCount, ccCount = #notes, #ccs
  -- Sidecars (notation type 15, cc type -1) are consumed for uuid binding and
  -- regenerated on flush; anything that doesn't decode is carried through verbatim.
  for _, t in ipairs(texts) do
    if t.eventtype == 15 then
      local sc = noteSidecarDecode(t.msg)
      if sc then util.add(noteSidecars, util.assign(sc, { ppq = t.ppq }))
      else util.add(carriedTexts, t) end
    elseif t.eventtype == -1 then
      local sc = ccSidecarDecode(t.msg)
      if sc then util.add(ccSidecars, util.assign(sc, { ppq = t.ppq }))
      else util.add(carriedTexts, t) end
    else
      util.add(carriedTexts, t)
    end
  end

  ----- Note dedup (in-memory; losers drop to holes, flushTake omits them)

  local notesKeyed = {}
  do
    local groups = {}
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
        dirty = true
        util.add(noteDedupEvents, util.pick(kept, 'ppq chan pitch', { droppedCount = #g.dropped }))
        for _, loc in ipairs(g.dropped) do notes[loc] = nil end
      end
    end
  end

  ----- CC dedup (in-memory; sidecar-matching cc wins, else highest loc)

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
        dirty = true
        util.add(ccDedupEvents, util.pick(kept, 'ppq chan evType cc pitch', { droppedCount = #locs - 1 }))
        for _, loc in ipairs(locs) do
          if loc ~= winnerLoc then ccs[loc] = nil end
        end
      end
    end
  end

  ----- UUID unification (notes ↔ noteSidecars; flushTake regenerates the sidecars)

  do
    local uuidCount = {}
    for _, ns in ipairs(noteSidecars) do
      local note = notesKeyed[noteKey(ns)]
      if note and not note.uuid then
        note.uuid = ns.uuid
        uuidCount[ns.uuid] = (uuidCount[ns.uuid] or 0) + 1
      else
        dirty = true   -- orphaned notation sidecar: regeneration drops it
      end
    end

    for _, note in pairs(notesKeyed) do
      local uuid = note.uuid
      if uuid and uuidCount[uuid] > 1 then
        local oldUUID = uuid
        local newUUID = assignNewUUID(note)
        uuidCount[oldUUID] = uuidCount[oldUUID] - 1
        metadata[newUUID] = util.clone(metadata[oldUUID]) or {}
        dirty = true
        util.add(reassignEvents, util.pick(note, 'ppq chan pitch', { oldUuid = oldUUID, newUuid = newUUID }))
      elseif not uuid then
        metadata[assignNewUUID(note)] = {}
        dirty = true   -- note had no notation sidecar: regeneration inserts one
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
      c.uuid = s.uuid
      if s.uuid > maxUUID then maxUUID = s.uuid end
      if kind then
        dirty = true   -- sidecar moves to the cc's position/value on regeneration
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

    if next(scsWorking) then dirty = true end   -- unbound sidecars: regeneration drops them
  end

  ----- Rebuild dense indices, reproject the normalised model, persist metadata
  rebuild(metadata)
  if dirty then flushTake() end
  saveMetadata()

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
  --emits: reload -- { wholesale=true }; full re-read, every event object is new
  fire('reload', { wholesale = true })

  perf.count('events', noteCount + ccCount)
  perf.stop('load')
end

function mm:reload()
  if not liveTake() then return end
  self:load(take)
end

--contract: clears mm.take and event tables when take dies; distinct from load(nil) dormant seam
function mm:unload()
  take, poolGuid = nil, nil
  notes, ccs, eventsByUuid, tokenIdx, maxUUID, lock = {}, {}, {}, {}, 0, false
  noteCount, ccCount, dirty = 0, 0, false
  carriedTexts, carriedPassthrough = {}, {}
end


----- Locking

--contract: writes (add*, delete*, structural assign*) must run inside mm:modify(fn)
--contract: a structural write marks the take dirty; modify reprojects it once via flushTake
local function checkLock()
  assert(lock, 'Error! You must call modification functions via modify()!')
  dirty = true
  return true
end

-- Re-entrant: reload reseats absorbers via a nested modify. Flush the take and
-- metadata once on the outermost unwind. See docs/midiManager.md § Mutation contract.
function mm:modify(fn)
  if not liveTake() then return end
  modifyDepth = modifyDepth + 1
  lock = true
  dirty = false
  if modifyDepth == 1 then metaDirty, metaDeleted = {}, {} end   -- reset once; nested modifies accumulate
  perf.start('verbs'); local ok, err = pcall(fn); perf.stop('verbs')
  if dirty then                                 -- clean (metadata-only) gestures touch no structure
    perf.start('rebuild'); rebuild(nil); perf.stop('rebuild')
    flushPending = true
  end
  lock = false
  --emits: reload -- { wholesale=false }; in-place modify, incremental caches stay valid
  perf.start('reload'); fire('reload', { wholesale = false }); perf.stop('reload')
  modifyDepth = modifyDepth - 1
  if modifyDepth == 0 then
    perf.start('meta'); flushMetadata(); perf.stop('meta')
    if flushPending then
      flushPending = false
      flushTake()
    end
  end
  if not ok then print('Error in modify: ' .. tostring(err)) end
end

----- Notes

local function cloneOut(evt)
  if not evt then return nil end
  local c = util.clone(evt)
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

  local oldTok = tokenOf(note)

  util.assign(note, t)
  if note.muted == false then note.muted = nil end

  local newTok = tokenOf(note)
  if newTok ~= oldTok then
    tokenIdx[oldTok] = nil
    tokenIdx[newTok] = note
  end

  saveMetadatum(note.uuid)
end

--contract: addNote always allocates a uuid; flushTake regenerates its notation sidecar
local function addNote(t)
  if not (take and checkLock()) then return end

  if t.ppq == nil or t.endppq == nil or t.chan == nil or t.pitch == nil or t.vel == nil then
    print('Error! Underspecified new note')
    return
  end

  local note = util.clone(t)
  note.evType = 'note'
  if not note.muted then note.muted = nil end
  assignNewUUID(note)
  t.uuid = note.uuid

  noteCount = noteCount + 1
  notes[noteCount] = note
  note.loc = noteCount
  tokenIdx[tokenOf(note)] = note

  saveMetadatum(note.uuid)
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

--contract: yields mm-internal cc records uncloned; consumers must NOT mutate them (read-only fast path)
function mm:ccsRaw()
  local i = 0
  return function()
    while true do
      i = i + 1
      local msg = ccs[i]
      if not msg then return end
      if not isWideLsb(msg) then return i, msg end
    end
  end
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

  if t.evType and not chanMsgLUT[t.evType] then
    print('Error! Unspecified message type')
    return
  end

  local oldTok = tokenOf(msg)

  util.assign(msg, t)

  if hasStructural then
    if msg.muted == false then msg.muted = nil end
    if msg.evType ~= 'cc' then msg.cc    = nil end
    if msg.evType ~= 'pa' then msg.pitch, msg.vel = nil, nil end
    if msg.shape ~= 'bezier' then msg.tension = nil end
  end

  local newTok = tokenOf(msg)
  if newTok ~= oldTok then
    tokenIdx[oldTok] = nil
    tokenIdx[newTok] = msg
  end

  if hasMetadata and not msg.uuid then
    assignNewUUID(msg)   -- flushTake writes the new sidecar
  end

  if msg.uuid then saveMetadatum(msg.uuid) end
end

-- Build one ordinary CC record (its wire event is regenerated on flush). No
-- metadata (the lazy-sidecar path lives in addCC); the wideCC split reuses this.
local function pushCC(t)
  local msg = util.clone(t)
  if not msg.muted then msg.muted = nil end
  msg.shape = msg.shape or 'step'   -- wire default; parse used to supply it on read-back
  if msg.shape ~= 'bezier' then msg.tension = nil end

  ccCount = ccCount + 1
  ccs[ccCount] = msg
  msg.loc = ccCount
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
    return
  end

  local msg = pushCC(t)

  local hasMetadata = false
  for k in pairs(t) do
    if not ccEventFields[k] then hasMetadata = true; break end
  end
  if hasMetadata then
    assignNewUUID(msg)
    t.uuid = msg.uuid
    saveMetadatum(msg.uuid)
  end
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

--contract: removes the event in-memory (a hole until rebuild compacts); flushTake reprojects
--contract: a wideCC MSB drags its LSB shadow (code+32); both records drop
--contract: wipes the event's ctm_<uuid> metadata via deleteMetadatum
function mm:delete(token)
  if not (take and checkLock()) then return end
  local evt = tokenIdx[token]
  if not evt then return end

  if evt.evType == 'note' then
    tokenIdx[token] = nil
    notes[evt.loc] = nil
    eventsByUuid[evt.uuid] = nil
    deleteMetadatum(evt.uuid)
    return
  end

  local recs = { evt }
  if isWideMsb(evt) then
    local lsb = tokenIdx[tokenOf{ evType = 'cc', chan = evt.chan, cc = evt.cc + 32, ppq = evt.ppq }]
    if lsb then util.add(recs, lsb) end
  end
  for _, rec in ipairs(recs) do
    tokenIdx[tokenOf(rec)] = nil
    ccs[rec.loc] = nil
    if rec.uuid then eventsByUuid[rec.uuid] = nil; deleteMetadatum(rec.uuid) end
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

-- REAPER convention: shape on A governs the curve from A to next. field defaults to
-- 'val'; pass 'cents' to interpolate the authored cents stream (rebuildPbs seats).
function mm:interpolate(A, B, ppq, field)
  field = field or 'val'
  if not A.shape or A.shape == 'step' then return A[field] end
  local span = B.ppq - A.ppq
  if span == 0 then return A[field] end
  local t = (ppq - A.ppq) / span
  return (A[field] or 0) + curveSample(A.shape, A.tension, t) * ((B[field] or 0) - (A[field] or 0))
end

-- CCINTERP from the item chunk: interpolated points per QN REAPER linearizes CC at
-- (not ticks). rebuildPbs converts to a tick step via resolution. Default 32.
function mm:ccInterp() return ccInterp or 32 end

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

-- Reposition the take's trailing end marker (CC 0x7B all-notes-off, or FF 2F meta) to targetPpq.
-- Shrink assumes events past targetPpq are already deleted upstream (tm:setLength does this).
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
  local status = msg:byte(1)
  local isEnd = msglen == 3 and (
       ((status & 0xF0) == 0xB0 and msg:byte(2) == 0x7B)   -- all-notes-off (REAPER's marker)
    or (status == 0xFF            and msg:byte(2) == 0x2F))  -- end-of-track meta (imported MIDI)
  if not isEnd then return buf end
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

if take then setTakeGuid(); mm:load(take) end
return mm

