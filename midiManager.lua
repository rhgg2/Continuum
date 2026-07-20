-- See docs/midiManager.md for the model.
--invariant: channels are 1..16 internally; +1 applied on read from REAPER, -1 on write
--invariant: loc is 1-indexed REAPER event-order; not stable across reloads
--invariant: mm holds realisation frame; delay baked into note-on ppq (docs/timing.md)
--invariant: mm holds raw pb; cents/detune + absorber pb live in tm (docs/tuning.md)
--invariant: muted is true-or-absent; false coerces to nil at write; pass false to clear
--invariant: per-event metadata persists via eventMeta, keyed by the take's POOL guid (docs/eventMeta.md)
local util = require 'util'
local midiBlob = require 'midiBlob'
local voicing = require 'voicing'
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
--invariant: on a collision collisionIdx holds the survivor; the loser stays uuid-addressable
local collisionIdx      = {}   -- note seats only; the same-pitch detector, never an address book
--invariant: chanIdx[kind][chan].byLoc[loc] = evt; keyed on chan alone, immune to ppq/pitch rewrites
local chanIdx    = { note = {}, cc = {} }   -- per-channel index; rebuild reconstructs, the verbs maintain
local maxUUID    = 0
local lock       = false
local dirty      = false  -- a structural write happened; the take needs reprojecting via flushTake
local modifyDepth  = 0      -- reload can re-enter modify; only the outermost flushes
local flushPending = false  -- a dirty modify happened somewhere in the nest; flush once on unwind
--invariant: adds/ppq-moves unsort the arrays; deletes hole them; neither fired = no reindex needed
local needsSort    = false  -- an add or a ppq move left the arrays out of ppq order; cleared by rebuild
local needsCompact = false  -- a delete left a hole in the arrays; cleared by rebuild
local carriedTexts       = {}  -- parsed text/meta events mm doesn't model; re-emitted verbatim on flush
local carriedPassthrough = {}  -- parsed system messages mm doesn't model; re-emitted verbatim on flush
--invariant: loadedBlob is the take's bytes as of the model agreeing with them; nil = unknown, never gate
local loadedBlob            -- converged-rebind gate; see design/archive/incremental-rebuild.md § The take-hash gate

-- Where a note sits, not which note it is: two notes sharing a seat occupy one MIDI slot,
-- which is exactly what the same-pitch backstop detects. mm addresses by uuid.

-- Chained concat, not util.key: one OP_CONCAT allocates once and coerces the
-- integer fields inline, vs util.key's per-arg tostring + table + table.concat.
local function seatKey(note)
  return note.chan .. '\0' .. note.pitch .. '\0' .. note.ppq
end

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
      -- 14-bit cc carries its value on the wire (MSB/LSB); the sidecar keeps the
      -- integer part for identity -- val regenerates from the wire. floor: bit-op needs int.
      lo, hi = math.floor(cc.val or 0) & 0x7F, 0
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
  plain = true,
}

-- The metadata an event carries: every field that isn't structural or regenerated.
-- eventMeta stores these opaque; the strip (which fields count) is mm's alone.
local function metaFieldsOf(evt)
  local strip = (evt.evType == 'note') and noteEventFields or ccEventFields
  local meta = {}
  for k, v in pairs(evt) do if not strip[k] then meta[k] = v end end
  return meta
end

-- Keyed on the key, so a util.REMOVE clearing a metadata field counts as touching it.
local function touchesMetadata(evt, t)
  local strip = (evt.evType == 'note') and noteEventFields or ccEventFields
  for k in pairs(t) do if not strip[k] then return true end end
  return false
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
    if perf.on then
      local dirtyN, deletedN = 0, 0
      for _ in pairs(metaDirty)   do dirtyN   = dirtyN   + 1 end
      for _ in pairs(metaDeleted) do deletedN = deletedN + 1 end
      perf.count('metaDirty', dirtyN); perf.count('metaDeleted', deletedN)
    end
    eventMeta:flush(poolGuid, metaDirty, metaDeleted)
  end
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
local function fullSortByPpq(list)
  for i, e in ipairs(list) do e.__ord = i end
  table.sort(list, function(a, b)
    if a.ppq ~= b.ppq then return a.ppq < b.ppq end
    return a.__ord < b.__ord
  end)
  for _, e in ipairs(list) do e.__ord = nil end
end

-- Verbs only append or nudge (loads arrive blob-ordered): insertion sort is ~O(n).
-- Bulk disorder blows the shift budget -> fullSortByPpq; strict compare keeps equal-ppq order.
local function stableByPpq(list)
  local budget = 8 * #list
  for i = 2, #list do
    local event = list[i]
    local slot  = i - 1
    while slot >= 1 and list[slot].ppq > event.ppq do
      list[slot + 1] = list[slot]
      slot   = slot - 1
      budget = budget - 1
      if budget < 0 then list[slot + 1] = event; return fullSortByPpq(list) end
    end
    list[slot + 1] = event
  end
end

-- Reuse each note's seat key across rebuilds; recompute only when a seat
-- field changes. Weak keys drop deleted notes. Cf. sidecarCache.
local seatKeyCache = setmetatable({}, { __mode = 'k' })

local function cachedSeatKey(note)
  local hit = seatKeyCache[note]
  if hit and hit.chan == note.chan and hit.pitch == note.pitch and hit.ppq == note.ppq then
    return hit.key
  end
  local key = seatKey(note)
  seatKeyCache[note] = { chan = note.chan, pitch = note.pitch, ppq = note.ppq, key = key }
  return key
end

----- Per-channel index

-- Backs notesRaw(chan) / ccsRaw(chan). tm's gated stages re-derive one channel and would otherwise
-- walk every event to find it. see design/archive/incremental-rebuild.md § The traversal floor
local function chanBucket(slots, chan)
  local bucket = slots[chan]
  if not bucket then bucket = { byLoc = {}, locs = {}, n = 0 }; slots[chan] = bucket end
  return bucket
end

local function slotsFor(evt) return chanIdx[evt.evType == 'note' and 'note' or 'cc'] end

-- locs stays ascending by appending, never sorting: an add takes the highest loc and the reindex
-- seats in loc order, so both hit the fast path. Only a chan move can arrive out of order.
local function seat(bucket, evt)
  local loc = evt.loc
  bucket.byLoc[loc] = evt
  local locs, n = bucket.locs, bucket.n
  if locs and (n == 0 or locs[n] < loc) then
    bucket.n = n + 1
    locs[n + 1] = loc
  else
    bucket.locs = nil   -- out of order: the next walk re-derives it
  end
end

local function indexPut(evt)
  seat(chanBucket(slotsFor(evt), evt.chan), evt)
end

local function indexDrop(evt)
  local bucket = chanBucket(slotsFor(evt), evt.chan)
  bucket.byLoc[evt.loc] = nil   -- locs keeps the key; the walk is hole-tolerant and skips it
end

-- Ascending loc, hole-tolerant: one channel's slice of exactly what a whole-array sparsePairs walk
-- yields, in the same order, with the same tolerance of a delete landing mid-iteration.
local function rawInChan(kind, chan)
  local bucket = chanIdx[kind][chan]
  if not bucket then return function() end end
  if not bucket.locs then
    local locs = {}
    for loc in pairs(bucket.byLoc) do locs[#locs + 1] = loc end
    table.sort(locs)
    bucket.locs, bucket.n = locs, #locs
  end
  local locs, byLoc, i = bucket.locs, bucket.byLoc, 0
  return function()
    while true do
      i = i + 1
      local loc = locs[i]
      if not loc then return nil end
      if byLoc[loc] then return loc, byLoc[loc] end
    end
  end
end

----- Reindex

-- Compact the sparse note/cc arrays to dense (verbs and dedup leave holes), order by ppq, and
-- recompute loc; rebuild collision/uuid/channel indices. metadata (load only) rejoins per-uuid fields.
local function rebuild(metadata)
  perf.start('rebuild')
  -- Compact and sort run only when their flag fired; the index loop always does -- either moves every loc.
  if needsCompact then
    perf.start('compact')
    notes = util.compact(notes, noteCount); noteCount = #notes
    ccs   = util.compact(ccs,   ccCount);   ccCount   = #ccs
    perf.stop('compact')
  end
  if needsSort then
    perf.start('sort')
    stableByPpq(notes); stableByPpq(ccs)
    perf.stop('sort')
  end
  perf.start('collisionIdx')
  collisionIdx, eventsByUuid = {}, {}
  chanIdx = { note = {}, cc = {} }
  -- Seat inline rather than via indexPut: this is the one bulk path (every event, every flush), and
  -- the kind is known per loop, so it skips the dispatch the verbs' single-event path needs.
  local noteSlots, ccSlots = chanIdx.note, chanIdx.cc
  for i, n in ipairs(notes) do
    n.loc = i
    collisionIdx[cachedSeatKey(n)] = n
    seat(chanBucket(noteSlots, n.chan), n)
    if n.uuid then eventsByUuid[n.uuid] = n end
    if metadata then util.assign(n, metadata[n.uuid]) end
  end
  for i, c in ipairs(ccs) do
    c.loc = i
    seat(chanBucket(ccSlots, c.chan), c)
    if c.uuid then
      eventsByUuid[c.uuid] = c
      if metadata then util.assign(c, metadata[c.uuid]) end
    end
  end
  perf.stop('collisionIdx')
  needsSort, needsCompact = false, false
  perf.stop('rebuild')
end

-- An assign that moves no ppq leaves the arrays dense and ordered: nothing for the reindex
-- to do, and the verbs have already maintained every index. see design/archive/incremental-rebuild.md § 6
local function indexStale() return needsSort or needsCompact end

-- Reuse each uuid'd event's sidecar record across flushes; recompute only when a
-- field feeding its body changes. Weak keys drop a deleted event's row. See docs.
local sidecarCache = setmetatable({}, { __mode = 'k' })

local function noteSidecarEntry(note)
  local hit = sidecarCache[note]
  if not (hit and hit.chan == note.chan and hit.pitch == note.pitch and hit.uuid == note.uuid) then
    hit = { chan = note.chan, pitch = note.pitch, uuid = note.uuid,
            entry = { eventtype = 15, msg = noteSidecarEncode(note) } }
    sidecarCache[note] = hit
  end
  hit.entry.ppq = note.ppq   -- ppq places the sidecar but isn't in its body; refresh every flush
  return hit.entry
end

local function ccSidecarEntry(cc)
  local hit = sidecarCache[cc]
  if not (hit and hit.evType == cc.evType and hit.chan == cc.chan and hit.cc == cc.cc
          and hit.pitch == cc.pitch and hit.val == cc.val and hit.vel == cc.vel
          and hit.uuid == cc.uuid) then
    hit = { evType = cc.evType, chan = cc.chan, cc = cc.cc, pitch = cc.pitch,
            val = cc.val, vel = cc.vel, uuid = cc.uuid,
            entry = { eventtype = -1, msg = ccSidecarEncode(cc) } }
    sidecarCache[cc] = hit
  end
  hit.entry.ppq = cc.ppq
  return hit.entry
end

-- Project the model onto the take as one whole-take blob: reproject each uuid'd
-- event's sidecar (cached), carry unmodelled events, preserve the EOT. Sole writer.
local function flushTake()
  if not take then return end
  perf.start('sidecars')
  local texts = {}
  for _, note in ipairs(notes) do
    if note.uuid then util.add(texts, noteSidecarEntry(note)) end
  end
  for _, cc in ipairs(ccs) do
    if not cc.plain then util.add(texts, ccSidecarEntry(cc)) end
  end
  for _, carried in ipairs(carriedTexts) do util.add(texts, carried) end
  perf.stop('sidecars')

  local source   = reaper.GetMediaItemTake_Source(take)
  local ppqPerQN = reaper.MIDI_GetPPQPosFromProjQN(take, 1) - reaper.MIDI_GetPPQPosFromProjQN(take, 0)
  local endPpq   = math.floor(reaper.GetMediaSourceLength(source) * ppqPerQN + 0.5)

  perf.start('serialise')
  local blob = midiBlob.serialise(notes, ccs, texts, carriedPassthrough, endPpq)
  perf.stop('serialise')

  perf.start('setEvts')
  reaper.MIDI_SetAllEvts(take, blob)
  -- SetAllEvts swaps the data but leaves REAPER's play cursor indexing the old event
  -- layout; mid-play it swallows the boundary events. See docs/midiManager.md § Live-edit note release.
  reaper.MIDI_Sort(take)
  -- MIDI API writes bump no undo dirty-counter: without this mark the blob never
  -- enters undo capture, so undo is a no-op on the MIDI (pooled takes can't rewind).
  local item = reaper.GetMediaItemTake_Item(take)
  reaper.MarkTrackItemsDirty(reaper.GetMediaItemTrack(item), item)
  perf.stop('setEvts')

  perf.count('notes', #notes); perf.count('ccs', #ccs); perf.count('texts', #texts)
  dirty = false
  -- Stash REAPER's canonical bytes (post-Sort), not the ones we handed it: the gate in load
  -- compares the take against these, and a re-encode would read as an external mutation.
  local _, canonical = reaper.MIDI_GetAllEvts(take)
  loadedBlob = canonical
end

---------- PUBLIC

--shape: note = { evType, ppq, endppq, chan, pitch, vel, [muted], [uuid], [...meta] }
--invariant: note.chan ∈ 1..16; pitch/vel ∈ 0..127; muted is true-or-absent
--shape: cc = { evType, ppq, chan, val, shape, [tension], [muted], uuid, [plain], [...meta] }
--invariant: a plain cc has no sidecar in the take; its uuid is in-memory only, re-minted every load
--invariant: cc.evType ∈ {cc, pb, pa, at, pc}; pa stores in .vel, others in .val
--invariant: cc.cc set on evType='cc'; cc.pitch set on 'pa'; chan ∈ 1..16; cc/pitch ∈ 0..127
--invariant: cc.shape ∈ {step, linear, slow, fast-start, fast-end, bezier}; tension only on bezier
--shape: noteSidecarPayload = { ppq, chan, pitch, droppedCount }  -- notesDeduped event
--shape: uuidsReassignedEvent = { ppq, chan, pitch, oldUuid, newUuid }
--shape: collisionEvent = { kind='killed'|'nudged', uuid, chan, pitch, ppq }
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
--contract: a take still holding loadedBlob is converged: fires reload{wholesale=false, chans={}}, returns
--contract: metadata persists incrementally: reassignment clones out, uuids no event claims swept
function mm:load(newTake)
  if not newTake then return end
  perf.start('load')

  -- Converged rebind: the take holds the bytes the model was built from, so there is nothing to
  -- re-read -- and no new event objects, hence no materialisation dirt for tm either. The signal
  -- still fires: a rebuild must run to consume dirt marked while dormant.
  if newTake == take and loadedBlob then
    local _, current = reaper.MIDI_GetAllEvts(take)
    if current == loadedBlob then
      --emits: reload -- { wholesale=false, chans={} }; model already agrees with the take: no re-parse, no dirt
      fire('reload', { wholesale = false, chans = {} })
      perf.stop('load')
      return
    end
  end

  local takeSwapped = take ~= newTake
  if takeSwapped then take = newTake; setTakeGuid() end

  notes, ccs, eventsByUuid, collisionIdx, maxUUID, lock = {}, {}, {}, {}, 0, false
  carriedTexts, carriedPassthrough, dirty = {}, {}, false
  local ccSidecars, noteSidecars = {}, {}
  local noteDedupEvents, ccDedupEvents, reassignEvents, reconcileEvents = {}, {}, {}, {}
  local metaWrites = {}   -- the only metadata load authors: the clones minted by uuid reassignment

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

  ----- UUID binding (notes ↔ noteSidecars) + metadata join. Ahead of dedup so
  ----- the voicing verdicts see intent (ppqL, detune, derived).

  local uuidCount = {}
  do
    local buckets = {}
    for _, n in ipairs(notes) do util.bucket(buckets, noteKey(n), n) end
    -- Colliding notes and sidecars pair off in parse order: arbitrary but
    -- deterministic (design/same-pitch-enforcement.md Phase 3).
    for _, ns in ipairs(noteSidecars) do
      local unbound
      for _, note in ipairs(buckets[noteKey(ns)] or {}) do
        if not note.uuid then unbound = note; break end
      end
      if unbound then
        unbound.uuid = ns.uuid
        uuidCount[ns.uuid] = (uuidCount[ns.uuid] or 0) + 1
        util.assign(unbound, metadata[ns.uuid])
      else
        dirty = true   -- orphaned notation sidecar: regeneration drops it
      end
    end
  end

  ----- Note dedup + separation (kills drop to holes; distinct voices nudge apart)

  local collisionEvents = {}
  do
    local lanes, locOf, seenOnset, collidingLanes = {}, {}, {}, {}
    for loc, n in ipairs(notes) do
      local laneKey, onsetKey = util.key(n.chan, n.pitch), noteKey(n)
      util.bucket(lanes, laneKey, n)
      locOf[n] = loc
      if seenOnset[onsetKey] then collidingLanes[laneKey] = true end
      seenOnset[onsetKey] = true
    end
    for laneKey in pairs(collidingLanes) do
      local kills, voiced, onsetOf = voicing.resolveGroup(lanes[laneKey])
      local dropped = {}
      for _, n in ipairs(kills) do
        dirty = true
        notes[locOf[n]] = nil
        if n.uuid then uuidCount[n.uuid] = uuidCount[n.uuid] - 1 end
        util.bucket(dropped, noteKey(n), n)
      end
      for _, group in pairs(dropped) do
        util.add(noteDedupEvents, util.pick(group[1], 'ppq chan pitch', { droppedCount = #group }))
      end
      for _, n in ipairs(voiced) do
        if onsetOf[n] ~= n.ppq then
          dirty = true
          n.ppq = onsetOf[n]
          util.add(collisionEvents, { kind = 'nudged', uuid = n.uuid,
                                      chan = n.chan, pitch = n.pitch, ppq = n.ppq })
        end
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

  ----- UUID unification (reassign duplicated uuids, mint for unbound survivors;
  ----- flushTake regenerates the sidecars)

  for _, note in util.sparsePairs(notes, noteCount) do
    local uuid = note.uuid
    if uuid and uuidCount[uuid] > 1 then
      local newUUID = assignNewUUID(note)
      uuidCount[uuid] = uuidCount[uuid] - 1
      metadata[newUUID] = util.clone(metadata[uuid]) or {}
      if next(metadata[newUUID]) then metaWrites[newUUID] = metadata[newUUID] end
      dirty = true
      util.add(reassignEvents, util.pick(note, 'ppq chan pitch', { oldUuid = uuid, newUuid = newUUID }))
    elseif not uuid then
      metadata[assignNewUUID(note)] = {}
      dirty = true   -- note had no notation sidecar: regeneration inserts one
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

  -- Every hand-out is uuid-addressable: a plain cc mints its uuid here, in memory only.
  -- Runs after persisted uuids are known, so it can't collide. See docs/midiManager.md § Plain ccs.
  for _, cc in util.sparsePairs(ccs, ccCount) do
    if not cc.uuid then cc.plain = true; assignNewUUID(cc) end
  end

  ----- Rebuild dense indices, reproject the normalised model, persist metadata
  needsSort, needsCompact = true, true   -- dedup holes the arrays; a foreign blob's order isn't ours to trust
  rebuild(metadata)
  local wroteTake = dirty
  if wroteTake then flushTake()      -- restashes loadedBlob off the reprojected take
  else loadedBlob = blob end         -- nothing written: the bytes we parsed are still the take's

  -- A surviving uuid's metadata is the store's own bytes: load joins them onto events and never edits
  -- them, so only the clones go back out. see docs/midiManager.md § Metadata I/O
  local metaDrops = {}
  for uuid in pairs(metadata) do
    if not eventsByUuid[uuid] then metaDrops[uuid] = true end
  end
  eventMeta:flush(poolGuid, metaWrites, metaDrops)

  --contract: load fires signals in order: takeSwapped, notesDeduped, uuidsReassigned
  --contract: then: ccsDeduped, ccsReconciled, collisionsResolved, reload, flushed (iff wrote)
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
  --emits: collisionsResolved -- { events = [collisionEvent, ...] }; nudged colliding voices apart
  if #collisionEvents > 0  then fire('collisionsResolved', { events = collisionEvents }) end
  --emits: reload -- { wholesale=true }; full re-read, every event object is new
  fire('reload', { wholesale = true })
  --emits: flushed -- nil; flushTake reprojected the take (self-write, not an external mutation)
  if wroteTake then fire('flushed') end

  perf.count('events', noteCount + ccCount)
  perf.stop('load')
end

function mm:reload()
  if not liveTake() then return end
  self:load(take)
end

-- A projext undo rewound this pool's metadata: the take-hash watcher can't see
-- it (a metadata-only undo writes no MIDI), so reload off the rewound signal.
eventMeta:subscribe('poolsRewound', function(payload)
  if poolGuid and payload.guids[poolGuid] then
    loadedBlob = nil   -- metadata moved with the blob untouched: the converged gate must not fire
    mm:reload()
  end
end)

--contract: clears mm.take and event tables when take dies; distinct from load(nil) dormant seam
function mm:unload()
  take, poolGuid, loadedBlob = nil, nil, nil
  notes, ccs, eventsByUuid, collisionIdx, maxUUID, lock = {}, {}, {}, {}, 0, false
  noteCount, ccCount, dirty = 0, 0, false
  carriedTexts, carriedPassthrough = {}, {}
end


----- Same-pitch backstop

-- Verbs record, the outermost unwind resolves — mid-batch collisions can be
-- transient. See docs/midiManager.md § Same-pitch backstop.
local pendingCollisions = {}
local function noteCollision(note, verb)
  pendingCollisions[util.key(note.chan, note.pitch)] = { chan = note.chan, pitch = note.pitch, verb = verb }
end

--contract: resolves missed same-pitch collisions at the outermost unwind; steady state finds none
local function resolveCollisions()
  if not next(pendingCollisions) then return nil end
  local events = {}
  for _, pending in pairs(pendingCollisions) do
    local group = {}
    for _, n in util.sparsePairs(notes, noteCount) do
      if n.chan == pending.chan and n.pitch == pending.pitch then util.add(group, n) end
    end
    local kills, voiced, onsetOf = voicing.resolveGroup(group)
    for _, n in ipairs(kills) do
      util.add(events, { kind = 'killed', uuid = n.uuid,
                         chan = n.chan, pitch = n.pitch, ppq = n.ppq })
      perf.line('backstop killed uuid %s (chan %d pitch %d ppq %d) via %s',
                n.uuid, n.chan, n.pitch, n.ppq, pending.verb)
      notes[n.loc] = nil
      eventsByUuid[n.uuid] = nil
      deleteMetadatum(n.uuid)
    end
    for _, n in ipairs(voiced) do
      if onsetOf[n] ~= n.ppq then
        local oldPpq = n.ppq
        n.ppq = onsetOf[n]
        util.add(events, { kind = 'nudged', uuid = n.uuid,
                           chan = n.chan, pitch = n.pitch, ppq = n.ppq })
        perf.line('backstop nudged uuid %s: ppq %d -> %d via %s', n.uuid, oldPpq, n.ppq, pending.verb)
      end
    end
  end
  pendingCollisions = {}
  if #events == 0 then return nil end
  needsSort, needsCompact, flushPending = true, true, true   -- kills hole the arrays, nudges unsort them
  return events
end


----- Dirty channels (rebuild dirt spine)

-- Seeds the reload payload so tm gates derivation per channel.
-- See design/archive/dirty-channels.md § Scheme.
local dirtyChans = {}
local function markChan(chan) if chan then dirtyChans[chan] = true end end


----- Locking

--contract: writes (add*, delete*, structural assign*) must run inside mm:modify(fn)
--contract: a structural write marks the take dirty; modify reprojects it once via flushTake
local function checkLock()
  assert(lock, 'Error! You must call modification functions via modify()!')
  dirty = true
  return true
end

local function enterNest()
  modifyDepth = modifyDepth + 1
  if modifyDepth == 1 then metaDirty, metaDeleted, pendingCollisions, dirtyChans = {}, {}, {}, {} end   -- reset once; nested modifies accumulate
end

-- The outermost unwind, and the whole point of the nest: one reindex, one metadata round-trip,
-- one take reprojection, however many gestures ran inside.
local function leaveNest()
  modifyDepth = modifyDepth - 1
  if modifyDepth > 0 then return end
  local resolved = resolveCollisions()
  if indexStale() then rebuild(nil) end         -- pay one reindex, after every nested pipeline write
  --emits: collisionsResolved -- { events = [collisionEvent, ...] }; repaired a missed collision
  if resolved then fire('collisionsResolved', { events = resolved }) end
  perf.start('meta'); flushMetadata(); perf.stop('meta')
  if flushPending then
    flushPending = false
    flushTake()
    --emits: flushed -- nil; flushTake reprojected the take (self-write, not an external mutation)
    fire('flushed')
  end
end

-- Re-entrant: reload reseats absorbers via a nested modify. Reindex and flush
-- are both deferred to the outermost unwind. See docs/midiManager.md § Mutation contract.
function mm:modify(fn)
  if not liveTake() then return end
  enterNest()
  lock = true
  dirty = false
  perf.start('verbs'); local ok, err = pcall(fn); perf.stop('verbs')
  if dirty then flushPending = true end         -- clean (metadata-only) gestures touch no structure
  lock = false
  --emits: reload -- { wholesale=false, chans=set }; chans nil only when wholesale
  perf.start('reload'); fire('reload', { wholesale = false, chans = dirtyChans }); perf.stop('reload')
  leaveNest()
  if not ok then print('Error in modify: ' .. tostring(err)) end
end

--contract: holds the nest open across the caller's modifies; takes no lock, writes nothing
--contract: not a gesture -- fires no reload, and an error propagates rather than printing
-- A caller staging through many separate modifies (tm's rebuild pipeline) would otherwise reindex and
-- reproject the take once per stage. see design/archive/incremental-rebuild.md § 5
function mm:batch(fn)
  enterNest()
  local ok, err = pcall(fn)
  leaveNest()
  if not ok then error(err, 0) end
end

--contract: run the deferred reindex when a modify left arrays stale (sparse/unsorted); else no-op
function mm:reindexIfStale()
  if indexStale() then rebuild(nil) end
end

----- Notes

local function cloneOut(evt)
  if not evt then return nil end
  return util.clone(evt)
end

function mm:notes()
  local it = util.sparsePairs(notes, noteCount)
  return function()
    local i, note = it()
    if note then return i, cloneOut(note) end
  end
end

--contract: yields mm-internal note records uncloned; do not mutate (read-only fast path)
--contract: notesRaw(chan) yields just that channel's, ascending loc -- same slice, same order
function mm:notesRaw(chan)
  if chan then return rawInChan('note', chan) end
  return util.sparsePairs(notes, noteCount)
end

--contract: assignNote: lockless write when t touches no structural field
--contract: persists metadata only when t touches a metadata key; structural-only writes none
--invariant: assignNote structural fields = {ppq, endppq, pitch, vel, chan, muted}
local function assignNote(loc, t)
  if not take then return end

  local hasStructural = t.ppq or t.endppq or t.pitch or t.vel or t.chan or t.muted ~= nil

  if not hasStructural then
    local note = notes[loc]
    if not note then return end

    util.assign(note, t)
    if touchesMetadata(note, t) then saveMetadatum(note.uuid) end
    return
  end

  if not checkLock() then return end

  local note = notes[loc]
  if not note then return end

  local oldKey = seatKey(note)
  if t.ppq and t.ppq ~= note.ppq then needsSort = true end   -- ppq is the sort key; no other field is

  util.assign(note, t)
  if note.muted == false then note.muted = nil end

  local newKey = seatKey(note)
  if newKey ~= oldKey then
    if collisionIdx[newKey] then noteCollision(note, 'assign') end
    if collisionIdx[oldKey] == note then collisionIdx[oldKey] = nil end   -- only the slot it owns
    collisionIdx[newKey] = note
  end

  if touchesMetadata(note, t) then saveMetadatum(note.uuid) end
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
  -- An unpark restore supplies the note's original uuid under keepUuid so fx-editor
  -- handles survive the round trip; anything else (paste clones, stale ids) mints.
  if note.keepUuid and type(note.uuid) == 'number' and not eventsByUuid[note.uuid] then
    note.keepUuid = nil
    if note.uuid > maxUUID then maxUUID = note.uuid end
    eventsByUuid[note.uuid] = note
  else
    note.keepUuid = nil
    assignNewUUID(note)
  end
  t.uuid = note.uuid

  noteCount = noteCount + 1
  notes[noteCount] = note
  note.loc = noteCount
  indexPut(note)
  needsSort = true   -- appended past the tail: dense, but no longer in ppq order
  local key = seatKey(note)
  if collisionIdx[key] then noteCollision(note, 'add') end
  collisionIdx[key] = note

  saveMetadatum(note.uuid)
end

----- CCs

--invariant: a cc in 0..31 with fractional val is 14-bit; MSB/LSB split lives in midiBlob
function mm:ccs()
  local it = util.sparsePairs(ccs, ccCount)
  return function()
    local i, msg = it()
    if msg then return i, cloneOut(msg) end
  end
end

--contract: yields mm-internal cc records uncloned; consumers must NOT mutate them (read-only fast path)
--contract: ccsRaw(chan) yields just that channel's, ascending loc -- same slice, same order
function mm:ccsRaw(chan)
  if chan then return rawInChan('cc', chan) end
  return util.sparsePairs(ccs, ccCount)
end

-- First index into an ascending-loc bucket whose event ppq >= target. Sound only when locs is
-- ppq-monotonic -- true right after a reindex, which every committed pipeline write ends in.
local function firstLocAtPpq(locs, byLoc, targetPpq)
  local lo, hi = 1, #locs + 1
  while lo < hi do
    local mid = (lo + hi) // 2
    if byLoc[locs[mid]].ppq < targetPpq then lo = mid + 1 else hi = mid end
  end
  return lo
end

--contract: yields mm-internal cc records uncloned in raw ppq [loPpq, hiPpq); read-only fast path
--contract: ccsRawBetween binary-searches ccsRaw(chan); sound only post-reindex (locs ppq-sorted)
function mm:ccsRawBetween(chan, loPpq, hiPpq)
  local bucket = chanIdx.cc[chan]
  if not bucket then return function() end end
  if not bucket.locs then
    local locs = {}
    for loc in pairs(bucket.byLoc) do locs[#locs + 1] = loc end
    table.sort(locs)
    bucket.locs, bucket.n = locs, #locs
  end
  local locs, byLoc = bucket.locs, bucket.byLoc
  local i = firstLocAtPpq(locs, byLoc, loPpq) - 1
  return function()
    while true do
      i = i + 1
      local loc = locs[i]
      if not loc then return nil end
      local evt = byLoc[loc]
      if evt then
        if evt.ppq >= hiPpq then return nil end
        return loc, evt
      end
    end
  end
end

--contract: assignCC: lockless iff t touches no structural field and doesn't promote a plain cc
--contract: first metadata stamp on a plain cc needs lock — inserts a sidecar sysex
--contract: persists metadata only when t touches a metadata key; structural-only writes none
local function assignCC(loc, t)
  if not take then return end

  local msg = ccs[loc]
  if not msg then return end

  local hasStructural = t.ppq or t.evType or t.chan or t.cc or t.pitch
                        or t.val or t.vel or t.muted ~= nil or t.shape or t.tension
  local hasMetadata = touchesMetadata(msg, t)

  -- A promotion inserts a sidecar into the take, so it takes the lock even with no
  -- structural field; an already-stamped cc's later metadata stays lockless.
  if not hasStructural and not (hasMetadata and msg.plain) then
    util.assign(msg, t)
    if hasMetadata then saveMetadatum(msg.uuid) end
    return
  end

  if not checkLock() then return end

  if t.evType and not chanMsgLUT[t.evType] then
    print('Error! Unspecified message type')
    return
  end

  if t.ppq and t.ppq ~= msg.ppq then needsSort = true end   -- ppq is the sort key; no other field is

  util.assign(msg, t)

  if hasStructural then
    if msg.muted == false then msg.muted = nil end
    if msg.evType ~= 'cc' then msg.cc    = nil end
    if msg.evType ~= 'pa' then msg.pitch, msg.vel = nil, nil end
    if msg.shape ~= 'bezier' then msg.tension = nil end
  end

  if hasMetadata then
    msg.plain = nil   -- promoted: flushTake now writes its sidecar
    saveMetadatum(msg.uuid)
  end
end

-- Build one ordinary CC record (its wire event is regenerated on flush). No
-- metadata (the lazy-sidecar path lives in addCC).
local function pushCC(t)
  local msg = util.clone(t)
  if not msg.muted then msg.muted = nil end
  msg.shape = msg.shape or 'step'   -- wire default; parse used to supply it on read-back
  if msg.shape ~= 'bezier' then msg.tension = nil end

  ccCount = ccCount + 1
  ccs[ccCount] = msg
  msg.loc = ccCount
  indexPut(msg)
  needsSort = true   -- appended past the tail: dense, but no longer in ppq order
  return msg
end

--contract: addCC always mints a uuid; a cc with no non-structural key is plain -- no sidecar
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

  local msg = pushCC(t)

  local hasMetadata = false
  for k in pairs(t) do
    if not ccEventFields[k] then hasMetadata = true; break end
  end
  assignNewUUID(msg)
  t.uuid = msg.uuid
  if hasMetadata then saveMetadatum(msg.uuid)
  else msg.plain = true end
end

--contract: returns (loc, evt-clone, kind) for the uuid, or nil if absent
--contract: works on every event -- a plain cc's in-memory uuid resolves like any other
--contract: a uuid is durable across reload, except a plain cc's -- re-minted each load
function mm:byUuid(uuid)
  local evt = eventsByUuid[uuid]
  if not evt then return nil end
  return evt.loc, cloneOut(evt), (evt.evType == 'note') and 'note' or 'cc'
end

----- Unified uuid-addressed surface

--contract: t.evType='note' routes to addNote; anything else to addCC
--contract: returns the new event's uuid, or nil if t is malformed; inherits inner lock req
function mm:add(t)
  if not t or not t.evType then return nil end
  if t.evType == 'note' then addNote(t) else addCC(t) end
  markChan(t.chan)
  return t.uuid
end

--contract: dispatches on the resolved event's evType; identity is stable, so no caller re-keys
--contract: returns the event's uuid (always == input), or nil if absent
--contract: inherits the inner method's metadata-only lockless carve-out
function mm:assign(uuid, t)
  local evt = eventsByUuid[uuid]
  if not evt then return nil end
  markChan(evt.chan)                       -- old chan; a chan move dirties both
  local chanMove = t.chan ~= nil and t.chan ~= evt.chan
  if chanMove then indexDrop(evt) end      -- drop from the old bucket while evt.chan still names it
  if evt.evType == 'note' then assignNote(evt.loc, t)
  else                         assignCC(evt.loc, t) end
  if chanMove then indexPut(evt) end
  markChan(t.chan)                          -- new chan; nil-guarded when the assign leaves chan untouched
  return uuid
end

--contract: removes the event in-memory (a hole until rebuild compacts); flushTake reprojects
--contract: wipes the event's ctm_<uuid> metadata via deleteMetadatum; a plain cc stores none
function mm:delete(uuid)
  if not (take and checkLock()) then return end
  local evt = eventsByUuid[uuid]
  if not evt then return end
  markChan(evt.chan)
  indexDrop(evt)
  needsCompact = true   -- the slot below becomes a hole; ppq order is undisturbed

  if evt.evType == 'note' then
    local key = seatKey(evt)
    if collisionIdx[key] == evt then collisionIdx[key] = nil end   -- only the slot it owns
  end

  if evt.evType == 'note' then notes[evt.loc] = nil else ccs[evt.loc] = nil end
  eventsByUuid[evt.uuid] = nil
  if not evt.plain then deleteMetadatum(evt.uuid) end
end

--contract: yields (uuid, evt-clone) over all live events, notes then ccs
--invariant: events() keys by uuid, unlike notes()/ccs(), which yield (loc, clone)
function mm:events()
  local noteIt = util.sparsePairs(notes, noteCount)
  local ccIt   = util.sparsePairs(ccs, ccCount)
  return function()
    local _, e = noteIt()
    if not e then _, e = ccIt() end
    if e then return e.uuid, cloneOut(e) end
  end
end

----- Take data

function mm:take()
  return liveTake()
end

--contract: the bound take's POOLEDEVTS pool guid (the metadata key); nil when dormant
function mm:poolGuid() return poolGuid end

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
  reaper.MarkTrackItemsDirty(reaper.GetMediaItemTrack(item), item)   -- EOT write bypasses flushTake; same undo-capture mark
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

