-- See docs/midiManager.md for the model.
--invariant: channels are 1..16 internally; +1 applied on read from REAPER, -1 on write
--invariant: loc is a slot id, stable while the event lives; slots are re-minted on every load
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

local eventsByUuid      = {}
--invariant: on a collision collisionIdx holds the survivor; the loser stays uuid-addressable
local collisionIdx      = {}   -- note seats only; the same-pitch detector, never an address book
local maxUUID    = 0
local lock       = false
local dirty      = false  -- a structural write happened; the take needs reprojecting via flushTake
local modifyDepth  = 0      -- reload can re-enter modify; only the outermost flushes
local flushPending = false  -- a dirty modify happened somewhere in the nest; flush once on unwind
local carriedTexts       = {}  -- parsed text/meta events mm doesn't model; re-emitted verbatim on flush
local carriedPassthrough = {}  -- parsed system messages mm doesn't model; re-emitted verbatim on flush
--shape: a sidecar row is { eventtype = 15, ppq, msg } on a note, { eventtype = -1, ppq, msg } on a cc
local sidecarCount = 0    -- for perf.count('texts') alone; a sparse table has no #
-- The grouped view buildWire keys on: state, not a per-flush composition, because the wire
-- holds a reference to it. rebuild regroups -- the one place all three are replaced.
local sidecarTexts        -- composed below, once the two streams exist
--invariant: loadedBlob is the take's bytes as of the model agreeing with them; nil = unknown, never gate
local loadedBlob            -- converged-rebind gate; see docs/midiManager.md § Converged load
local wire                  -- last flush's midiBlob wire state; nil = nothing built yet
--invariant: wireDirt[stream][slot] is that slot's state before the nest's first touch of it
local wireDirt = { note = {}, cc = {} }
local wireFull = true       -- nothing held, or the model moved wholesale: regenerate, don't splice
local NO_KEYS  = {}         -- an add's slot held nothing; shared, never mutated

-- Where a note sits, not which note it is: two notes sharing a seat occupy one MIDI slot,
-- which is exactly what the same-pitch backstop detects. mm addresses by uuid.

-- Chained concat, not util.key: one OP_CONCAT allocates once and coerces the
-- integer fields inline, vs util.key's per-arg tostring + table + table.concat.
local function seatKey(note)
  return note.chan .. '\0' .. note.pitch .. '\0' .. note.ppq
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

----- Seat keys

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

----- Sidecar rows

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
  hit.entry.ppq = note.ppq   -- ppq places the sidecar but isn't in its body; refresh on every seat
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

local function seatSidecar(group, slot, entry)
  if (group[slot] == nil) ~= (entry == nil) then sidecarCount = sidecarCount + (entry and 1 or -1) end
  group[slot] = entry
end

----- Slot streams

--invariant: list is sparse, keyed by slot; a slot is one event's loc for as long as it lives
--invariant: order is dense [1..n] slot ids, ascending ppq; only load leaves dead ones
--invariant: chans[chan] holds that channel's slice of order, in the same order
local function makeStream()
  local list       = {}   -- the events, sparse, keyed by slot
  local order      = {}   -- slot ids in ppq order
  local free       = {}   -- slots a delete handed back, LIFO; reused before minting
  local chans      = {}   -- per-channel index; reindex reconstructs it, the verbs maintain it
  local sidecars   = {}   -- [slot] = the owner's sidecar row; every note has one, a plain cc none
  local maxSlot    = 0    -- high-water mark: a mint comes from here when the free list is empty
  local orderEpoch = 0    -- bumped whenever order moves; a live walk asserts on it. Per stream, so
                          -- the other kind's splices can't trip a walk over this one.
  local stream     = {}

  -- Ppq-ordered reads go through an order array, not array position -- what lets loc
  -- name a slot instead. See docs/midiManager.md § Conventions.
  local function identityOrder(n)
    local ids = {}
    for i = 1, n do ids[i] = i end
    return ids
  end

  -- Walk in ppq order. The length is captured up front, so a mid-walk add stays unseen -- the
  -- mid-iteration contract. A live-walk splice raises instead; see docs/midiManager.md § Collect first, then mutate.
  local function walk(ids)   -- yields (loc, evt)
    local i, n, epoch = 0, #ids, orderEpoch
    return function()
      assert(epoch == orderEpoch, 'mm: order array spliced under a live walk')
      while i < n do
        i = i + 1
        local evt = list[ids[i]]
        if evt then return ids[i], evt end   -- load's dedup holes the arrays until reindex compacts
      end
    end
  end

  -- util.insertSorted lands at the lower bound, so a non-strict comparator carries the new slot past
  -- everything already at its ppq -- the pinned add rule, and a move obeys it for free.
  local function spliceIn(ids, slot)
    orderEpoch = orderEpoch + 1
    util.insertSorted(ids, slot, function(a, b) return list[a].ppq <= list[b].ppq end)
  end

  -- Must run while the event is still in `list` under its OLD ppq: that ppq is the search key.
  -- Binary-search to the head of its run of equals, then scan the run for the slot itself.
  local function spliceOut(ids, slot)
    local ppq    = list[slot].ppq
    local lo, hi = 1, #ids + 1
    while lo < hi do
      local mid = (lo + hi) // 2
      if list[ids[mid]].ppq < ppq then lo = mid + 1 else hi = mid end
    end
    for i = lo, #ids do
      if ids[i] == slot then
        orderEpoch = orderEpoch + 1
        table.remove(ids, i)
        return
      end
    end
    error('mm: slot ' .. tostring(slot) .. ' is missing from its order array')
  end

  -- Lifecycle replaces the order array outright where the splices mutate it in place; either way
  -- a walk that captured the old one is stale, so both bump the epoch.
  local function replaceOrder(ids)
    orderEpoch = orderEpoch + 1
    order      = ids
  end

  -- Backs notesRaw(chan) / ccsRaw(chan). tm's gated stages re-derive one channel and would otherwise
  -- walk every event to find it.
  local function bucket(chan)
    local ids = chans[chan]
    if not ids then ids = {}; chans[chan] = ids end
    return ids
  end

  ----- Verbs

  function stream.get(slot) return list[slot] end
  function stream.count()   return #order end
  function stream.ordered() return walk(order) end

  -- One channel's slice of exactly what a whole-stream ordered walk yields, in the same order --
  -- being the same kind of walk over that channel's own order array.
  function stream.inChan(chan)
    local ids = chans[chan]
    if not ids then return function() end end
    return walk(ids)
  end

  -- Seat an event: a slot off the free list, or a fresh one off the high-water mark. The splice
  -- reads list[slot].ppq, so the seat has to precede it.
  function stream.admit(evt)
    local slot = table.remove(free)
    if not slot then maxSlot = maxSlot + 1; slot = maxSlot end
    list[slot] = evt
    evt.loc    = slot
    spliceIn(order, slot)
    return slot
  end

  -- admit's mirror: out of the order array, out of the list, onto the free list.
  function stream.release(slot)
    spliceOut(order, slot)
    list[slot] = nil
    util.add(free, slot)
  end

  -- The order array alone: a ppq move re-splices without the slot changing hands.
  function stream.insert(slot) spliceIn(order, slot)  end
  function stream.remove(slot) spliceOut(order, slot) end

  -- The per-channel buckets reuse the global array's splice helpers, inheriting the pinned
  -- equal-ppq add rule and its constraint: drop while evt is still listed at its OLD ppq.
  function stream.bucketPut(evt)  spliceIn(bucket(evt.chan), evt.loc)  end
  function stream.bucketDrop(evt) spliceOut(bucket(evt.chan), evt.loc) end

  function stream.putSidecar(slot, entry) seatSidecar(sidecars, slot, entry) end

  ----- Lifecycle

  -- The two tables a held wire points at: buildWire keeps a reference to the list across
  -- flushes, and sidecarTexts groups the two sidecar tables the same way.
  function stream.rawList()      return list end
  function stream.sidecarGroup() return sidecars end

  -- Take the parsed events whole, in parse order; reindex reseats them by ppq.
  function stream.seed(events)
    list, maxSlot = events, #events
    replaceOrder(identityOrder(maxSlot))
  end

  -- chans is left standing: the next load's reindex replaces it, and until then a walk over
  -- an emptied list yields nothing whichever slots it names.
  function stream.reset()
    list, free, sidecars, maxSlot = {}, {}, {}, 0
    replaceOrder({})
  end

  function stream.compact()
    list    = util.compact(list, maxSlot)
    maxSlot = #list
  end

  function stream.sortByPpq() stableByPpq(list) end

  -- Load's own pass; slots don't move under the verbs, so they don't need it. Compacted and
  -- sorted here, slot order coincides with ppq order: order is identity, buckets append not splice.
  function stream.reindex(seat)
    chans, free, sidecars = {}, {}, {}
    replaceOrder(identityOrder(maxSlot))
    for slot, evt in ipairs(list) do
      evt.loc = slot
      util.add(bucket(evt.chan), slot)
      seat(evt, slot)
    end
  end

  return stream
end

--invariant: streams.note and streams.cc are the only two; every event belongs to exactly one
local streams = { note = makeStream(), cc = makeStream() }
-- Every evType but 'note' is a cc. Resolving an event to its stream is the only place
-- that discrimination is made, bar the two boundaries where midiBlob wants the kind's name.
local function streamOf(evt) return evt.evType == 'note' and streams.note or streams.cc end
sidecarTexts = { noteSidecars = streams.note.sidecarGroup(),
                 ccSidecars   = streams.cc.sidecarGroup(), carried = carriedTexts }

local function indexPut(evt)  streamOf(evt).bucketPut(evt)  end
local function indexDrop(evt) streamOf(evt).bucketDrop(evt) end

-- A refresh, not a reseat: the entry's ppq places the row and its body encodes it, so any
-- structural assign re-derives both through sidecarCache -- a few field compares on a hit.
local function sidecarPut(evt)
  if evt.evType == 'note' then streams.note.putSidecar(evt.loc, noteSidecarEntry(evt))
  else streams.cc.putSidecar(evt.loc, (not evt.plain) and ccSidecarEntry(evt) or nil) end
end

local function sidecarDrop(evt)
  streamOf(evt).putSidecar(evt.loc, nil)
end

----- Reindex

-- Load's own pass, and load's alone: verbs don't need this, since slots don't move under them.
-- Compacts the dedup holes, orders by ppq, and mints slots 1..n; rebuilds every index. See docs/midiManager.md § Stable slots.
local function rebuild(metadata)
  perf.start('rebuild')
  perf.start('compact')
  streams.note.compact(); streams.cc.compact()
  perf.stop('compact')
  perf.start('sort')
  streams.note.sortByPpq(); streams.cc.sortByPpq()   -- a foreign blob's order isn't ours to trust
  perf.stop('sort')
  perf.start('collisionIdx')
  collisionIdx, eventsByUuid, sidecarCount = {}, {}, 0
  -- Seat inline rather than via sidecarPut: this is the one bulk path (every event, every load)
  -- and the kind is known per loop, so neither seat pays for a dispatch it can't get wrong.
  streams.note.reindex(function(n, slot)
    collisionIdx[cachedSeatKey(n)] = n
    if n.uuid then
      eventsByUuid[n.uuid] = n
      streams.note.putSidecar(slot, noteSidecarEntry(n))
    end
    if metadata then util.assign(n, metadata[n.uuid]) end
  end)
  streams.cc.reindex(function(c, slot)
    if c.uuid then
      eventsByUuid[c.uuid] = c
      if metadata then util.assign(c, metadata[c.uuid]) end
    end
    if not c.plain then streams.cc.putSidecar(slot, ccSidecarEntry(c)) end
  end)
  -- Every table a held wire points at has just been replaced, so every held key is meaningless.
  sidecarTexts = { noteSidecars = streams.note.sidecarGroup(),
                   ccSidecars   = streams.cc.sidecarGroup(), carried = carriedTexts }
  wireFull = true
  perf.stop('collisionIdx')
  perf.stop('rebuild')
end

-- Project the model onto the take as one whole-take blob: splice the wire the last flush
-- left (or rebuild it), carry unmodelled events, preserve the EOT. Sole writer.
local function flushTake()
  if not take then return end

  local source   = reaper.GetMediaItemTake_Source(take)
  local ppqPerQN = reaper.MIDI_GetPPQPosFromProjQN(take, 1) - reaper.MIDI_GetPPQPosFromProjQN(take, 0)
  local endPpq   = math.floor(reaper.GetMediaSourceLength(source) * ppqPerQN + 0.5)

  perf.start('serialise')
  -- The live tables, unsnapshotted: buildWire keys on the slot, so it reads notes, ccs
  -- and both sidecar groups sparse.
  local noteList, ccList = streams.note.rawList(), streams.cc.rawList()
  if wireFull or not wire then
    wire, wireFull = midiBlob.buildWire(noteList, ccList, sidecarTexts, carriedPassthrough), false
  else
    perf.start('splice')
    if not midiBlob.syncSlots(wire, wireDirt) then
      -- A disagreement means the dirt has lost track of the wire: no further splice would
      -- be trustworthy, and a lost key is silent at the byte level.
      print('flushTake: wire splice disagreed with the held wire; regenerating')
      wire = midiBlob.buildWire(noteList, ccList, sidecarTexts, carriedPassthrough)
    end
    perf.stop('splice')
  end
  local blob = midiBlob.render(wire, endPpq)
  perf.stop('serialise')

  perf.start('setEvts')
  reaper.MIDI_SetAllEvts(take, blob)
  -- MIDI_Sort reseats the play cursor SetAllEvts strands, not the order -- serialise already emits
  -- canonical order -- so a stopped transport skips it. See docs/midiManager.md § Live-edit note release.
  if reaper.GetPlayState() ~= 0 then reaper.MIDI_Sort(take) end
  -- MIDI API writes bump no undo dirty-counter: without this mark the blob never
  -- enters undo capture, so undo is a no-op on the MIDI (pooled takes can't rewind).
  local item = reaper.GetMediaItemTake_Item(take)
  reaper.MarkTrackItemsDirty(reaper.GetMediaItemTrack(item), item)
  perf.stop('setEvts')

  perf.count('notes', streams.note.count()); perf.count('ccs', streams.cc.count())
  perf.count('texts', sidecarCount + #carriedTexts)
  dirty = false
  wireDirt = { note = {}, cc = {} }   -- spent: the wire agrees with the model again
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

  -- The point of no return: the held model goes now, and the parse below replaces it.
  streams.note.reset(); streams.cc.reset()
  eventsByUuid, collisionIdx, maxUUID, lock = {}, {}, 0, false
  carriedTexts, carriedPassthrough, dirty = {}, {}, false
  local parsedCcSidecars, parsedNoteSidecars = {}, {}   -- decoded off the take; consumed for binding
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
  local notes, ccs, texts, passthrough = midiBlob.parse(blob)
  perf.stop('read')
  carriedPassthrough = passthrough
  -- Streams take the parsed lists as-is, in take order; rebuild reseats by ppq below. notes/ccs
  -- stay aliases for the normalisation pass to mutate in place -- until compact replaces the lists, past which nothing may read them.
  streams.note.seed(notes)
  streams.cc.seed(ccs)
  -- Sidecars (notation type 15, cc type -1) are consumed for uuid binding and
  -- regenerated on flush; anything that doesn't decode is carried through verbatim.
  for _, t in ipairs(texts) do
    if t.eventtype == 15 then
      local sc = noteSidecarDecode(t.msg)
      if sc then util.add(parsedNoteSidecars, util.assign(sc, { ppq = t.ppq }))
      else util.add(carriedTexts, t) end
    elseif t.eventtype == -1 then
      local sc = ccSidecarDecode(t.msg)
      if sc then util.add(parsedCcSidecars, util.assign(sc, { ppq = t.ppq }))
      else util.add(carriedTexts, t) end
    else
      util.add(carriedTexts, t)
    end
  end

  ----- UUID binding (notes ↔ the parsed note sidecars) + metadata join
  -- Ahead of dedup, so the voicing verdicts see intent (ppqL, detune, derived).

  local uuidCount = {}
  do
    local buckets = {}
    for _, n in ipairs(notes) do util.bucket(buckets, noteKey(n), n) end
    -- Colliding notes and sidecars pair off in parse order: arbitrary but
    -- deterministic.
    for _, ns in ipairs(parsedNoteSidecars) do
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
    for _, s in ipairs(parsedCcSidecars) do
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

  ----- UUID unification — reassign duplicated uuids, mint for unbound survivors
  -- flushTake regenerates the sidecars.

  for _, note in streams.note.ordered() do
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

  ----- Sidecar reconcile (ccs ↔ the parsed cc sidecars)
  if next(parsedCcSidecars) then
    --contract: stage-3 consensus: winning offset needs ≥ max(2, ceil(0.5·n)) votes, unique
    local THRESHOLD_FRAC, THRESHOLD_MIN = 0.5, 2
    local scsWorking, ccsWorking = util.clone(parsedCcSidecars), util.clone(ccs)
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
  for _, cc in streams.cc.ordered() do
    if not cc.uuid then cc.plain = true; assignNewUUID(cc) end
  end

  ----- Rebuild dense indices, reproject the normalised model, persist metadata
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

  perf.count('events', streams.note.count() + streams.cc.count())
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
  take, poolGuid, loadedBlob, wire = nil, nil, nil, nil
  eventsByUuid, collisionIdx, maxUUID, lock = {}, {}, 0, false
  for _, stream in pairs(streams) do stream.reset() end
  dirty, sidecarCount = false, 0
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
    for _, n in streams.note.ordered() do
      if n.chan == pending.chan and n.pitch == pending.pitch then util.add(group, n) end
    end
    local kills, voiced, onsetOf = voicing.resolveGroup(group)
    for _, n in ipairs(kills) do
      util.add(events, { kind = 'killed', uuid = n.uuid,
                         chan = n.chan, pitch = n.pitch, ppq = n.ppq })
      perf.line('backstop killed uuid %s (chan %d pitch %d ppq %d) via %s',
                n.uuid, n.chan, n.pitch, n.ppq, pending.verb)
      indexDrop(n)
      sidecarDrop(n)
      streams.note.release(n.loc)
      eventsByUuid[n.uuid] = nil
      deleteMetadatum(n.uuid)
    end
    for _, n in ipairs(voiced) do
      if onsetOf[n] ~= n.ppq then
        local oldPpq = n.ppq
        streams.note.remove(n.loc); indexDrop(n)
        n.ppq = onsetOf[n]
        streams.note.insert(n.loc); indexPut(n)
        sidecarPut(n)   -- the nudge moved the ppq that places its row
        util.add(events, { kind = 'nudged', uuid = n.uuid,
                           chan = n.chan, pitch = n.pitch, ppq = n.ppq })
        perf.line('backstop nudged uuid %s: ppq %d -> %d via %s', n.uuid, oldPpq, n.ppq, pending.verb)
      end
    end
  end
  pendingCollisions = {}
  if #events == 0 then return nil end
  flushPending = true
  return events
end


----- Dirty channels (rebuild dirt spine)

-- Seeds the reload payload so tm gates derivation per channel. see docs/trackerManager.md § Derivation dirt: the gated spine
local dirtyChans = {}
local function markChan(chan) if chan then dirtyChans[chan] = true end end

-- The wire's own dirt: one before-snapshot per slot, first touch in the nest winning, which is
-- what makes repeated gestures on a slot coalesce. See docs/midiManager.md § Wire dirt.
local function markWire(evt, before)
  if wireFull or not wire or not evt then return end
  -- One of the two boundaries that wants the kind's name rather than its stream: midiBlob
  -- keys the wire by it. mm:byUuid, which hands the name out, is the other.
  local kind  = evt.evType == 'note' and 'note' or 'cc'
  local group = wireDirt[kind]
  if group[evt.loc] == nil then
    group[evt.loc] = before or midiBlob.slotState(wire, kind, evt.loc)
  end
end

-- A freshly seated slot holds no keys: it was either just minted, or came off the free list,
-- where a previous flush dropped its keys or this nest's delete has already snapshotted them.
local function markWireAdded(evt) markWire(evt, NO_KEYS) end


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
  if modifyDepth == 1 then   -- reset once; nested modifies accumulate
    metaDirty, metaDeleted, pendingCollisions, dirtyChans = {}, {}, {}, {}
    wireDirt = { note = {}, cc = {} }
  end
end

-- The outermost unwind, and the whole point of the nest: one reindex, one metadata round-trip,
-- one take reprojection, however many gestures ran inside.
local function leaveNest()
  modifyDepth = modifyDepth - 1
  if modifyDepth > 0 then return end
  local resolved = resolveCollisions()
  --emits: collisionsResolved -- { events = [collisionEvent, ...] }; repaired a missed collision
  -- The backstop mutates after the verbs have had their say, and fires ~never: regenerating
  -- the wire here beats maintaining a fifth dirt site.
  if resolved then fire('collisionsResolved', { events = resolved }); wireFull = true end
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
-- reproject the take once per stage.
function mm:batch(fn)
  enterNest()
  local ok, err = pcall(fn)
  leaveNest()
  if not ok then error(err, 0) end
end

----- Notes

local function cloneOut(evt)
  if not evt then return nil end
  return util.clone(evt, { loc = true })
end

function mm:notes()
  local it = streams.note.ordered()
  return function()
    local i, note = it()
    if note then return i, cloneOut(note) end
  end
end

--contract: yields mm-internal note records uncloned; do not mutate (read-only fast path)
--contract: notesRaw(chan) yields just that channel's, in ppq order -- same slice, same order
function mm:notesRaw(chan)
  if chan then return streams.note.inChan(chan) end
  return streams.note.ordered()
end

--contract: assignNote: lockless write when t touches no structural field
--contract: persists metadata only when t touches a metadata key; structural-only writes none
--invariant: assignNote structural fields = {ppq, endppq, pitch, vel, chan, muted}
local function assignNote(loc, t)
  if not take then return end

  local hasStructural = t.ppq or t.endppq or t.pitch or t.vel or t.chan or t.muted ~= nil

  if not hasStructural then
    local note = streams.note.get(loc)
    if not note then return end

    util.assign(note, t)
    if touchesMetadata(note, t) then saveMetadatum(note.uuid) end
    return
  end

  if not checkLock() then return end

  local note = streams.note.get(loc)
  if not note then return end

  local oldKey = seatKey(note)
  -- ppq is the sort key and no other field is, so only a move re-splices -- and the remove has to
  -- see the old ppq. Hence the sequence: remove, assign, insert.
  local movesPpq = t.ppq ~= nil and t.ppq ~= note.ppq
  if movesPpq then streams.note.remove(note.loc) end

  util.assign(note, t)
  if note.muted == false then note.muted = nil end
  if movesPpq then streams.note.insert(note.loc) end

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

  streams.note.admit(note)
  indexPut(note)
  sidecarPut(note)
  local key = seatKey(note)
  if collisionIdx[key] then noteCollision(note, 'add') end
  collisionIdx[key] = note

  saveMetadatum(note.uuid)
end

----- CCs

--invariant: a cc in 0..31 with fractional val is 14-bit; MSB/LSB split lives in midiBlob
function mm:ccs()
  local it = streams.cc.ordered()
  return function()
    local i, msg = it()
    if msg then return i, cloneOut(msg) end
  end
end

--contract: yields mm-internal cc records uncloned; consumers must NOT mutate them (read-only fast path)
--contract: ccsRaw(chan) yields just that channel's, in ppq order -- same slice, same order
function mm:ccsRaw(chan)
  if chan then return streams.cc.inChan(chan) end
  return streams.cc.ordered()
end

--contract: assignCC: lockless iff t touches no structural field and doesn't promote a plain cc
--contract: first metadata stamp on a plain cc needs lock — inserts a sidecar sysex
--contract: persists metadata only when t touches a metadata key; structural-only writes none
local function assignCC(loc, t)
  if not take then return end

  local msg = streams.cc.get(loc)
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

  local movesPpq = t.ppq ~= nil and t.ppq ~= msg.ppq   -- ppq is the sort key; no other field is
  if movesPpq then streams.cc.remove(msg.loc) end

  util.assign(msg, t)
  if movesPpq then streams.cc.insert(msg.loc) end

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

  streams.cc.admit(msg)
  indexPut(msg)
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
  sidecarPut(msg)   -- here and not in pushCC: the plain decision above is what decides the row
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
  markWireAdded(eventsByUuid[t.uuid])   -- nil when the add was malformed and bailed
  return t.uuid
end

--contract: dispatches on the resolved event's evType; identity is stable, so no caller re-keys
--contract: returns the event's uuid (always == input), or nil if absent
--contract: inherits the inner method's metadata-only lockless carve-out
function mm:assign(uuid, t)
  local evt = eventsByUuid[uuid]
  if not evt then return nil end
  markChan(evt.chan)                       -- old chan; a chan move dirties both
  markWire(evt)                            -- before indexDrop and sidecarPut: snapshot the OLD keys
  -- A chan move changes which bucket holds the event; a ppq move changes where it sits inside
  -- one. Both computed once, before the mutation overwrites the values indexDrop still needs.
  local reseats = (t.chan ~= nil and t.chan ~= evt.chan) or (t.ppq ~= nil and t.ppq ~= evt.ppq)
  if reseats then indexDrop(evt) end
  if evt.evType == 'note' then assignNote(evt.loc, t)
  else                         assignCC(evt.loc, t) end
  if reseats then indexPut(evt) end
  -- Ungated: a pitch/chan/value edit rewrites the row's body, a ppq edit moves it, and
  -- assignCC's promotion seats a first one -- all three land here rather than each at its own site.
  sidecarPut(evt)
  markChan(t.chan)                          -- new chan; nil-guarded when the assign leaves chan untouched
  return uuid
end

--contract: deletes the event, returns its slot to the free list; flushTake reprojects
--contract: wipes the event's ctm_<uuid> metadata via deleteMetadatum; a plain cc stores none
function mm:delete(uuid)
  if not (take and checkLock()) then return end
  local evt = eventsByUuid[uuid]
  if not evt then return end
  markChan(evt.chan)
  markWire(evt)      -- before sidecarDrop nils the row the snapshot has to see
  indexDrop(evt)
  sidecarDrop(evt)   -- else a reused slot inherits the dead event's row

  if evt.evType == 'note' then
    local key = seatKey(evt)
    if collisionIdx[key] == evt then collisionIdx[key] = nil end   -- only the seat it owns
  end
  streamOf(evt).release(evt.loc)
  eventsByUuid[evt.uuid] = nil
  if not evt.plain then deleteMetadatum(evt.uuid) end
end

--contract: yields (uuid, evt-clone) over all live events, notes then ccs
--invariant: events() keys by uuid, unlike notes()/ccs(), which yield (loc, clone)
function mm:events()
  local noteIt = streams.note.ordered()
  local ccIt   = streams.cc.ordered()
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
--contract: qn sizes the source from its origin, so a head-trimmed item renders qn less its head
function mm:setLength(qn)
  if not liveTake() then return end
  local item     = reaper.GetMediaItemTake_Item(take)
  local startSec = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
  local startQN  = reaper.TimeMap2_timeToQN(0, startSec)
  local originQN = reaper.MIDI_GetProjQNFromPPQPos(take, 0)
  local ok, buf = reaper.MIDI_GetAllEvts(take)
  if ok then
    local newBuf = setEot(buf, qn * self:resolution())
    if newBuf ~= buf then reaper.MIDI_SetAllEvts(take, newBuf) end
  end
  -- The head sits before the item, so the source's end lands originQN + qn.
  -- A source shrunk inside the head floors at the start, as relayoutTrack does.
  reaper.MIDI_SetItemExtents(item, startQN, math.max(startQN, originQN + qn))
  reaper.MarkTrackItemsDirty(reaper.GetMediaItemTrack(item), item)   -- EOT write bypasses flushTake; same undo-capture mark
  self:reload()
end

-- Spanned from the source origin to the source end, not the item's edges: a
-- head-trimmed instance starts inside its source, and tm's frame runs from ppq 0.
--contract: ppq is measured from the source origin; the span covers head and tail alike
function mm:timeSigs()
  if not liveTake() then return {} end

  local originQN  = reaper.MIDI_GetProjQNFromPPQPos(take, 0)
  local endQN     = reaper.MIDI_GetProjQNFromPPQPos(take, self:length())
  local startTime = reaper.TimeMap2_QNToTime(0, originQN)
  local endTime   = reaper.TimeMap2_QNToTime(0, endQN)
  local baseppq   = reaper.MIDI_GetPPQPosFromProjTime(take, startTime)

  local result = {}
  local count = reaper.CountTempoTimeSigMarkers(0)

  -- Scan for the last time-sig marker at or before the source origin; fall back to
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

