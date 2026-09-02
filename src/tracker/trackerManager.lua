-- See docs/trackerManager.md for the model.

--invariant: mm holds raw + a ppqL sidecar; columns and the park stash are logical-only (evt.ppq)
--invariant: rebuild reconciles raw ↔ ppqL each pass (docs/timing.md)
--invariant: intentCents is a note's intent -- the cents of the step it was written on
--invariant: pitch+detune realise the intent; pb realises detune (channel-wide stream)
--invariant: only lane-1 notes drive detune realisation
--invariant: pb.val is cents inside um; raw↔cents only at load/flush, by tuning's two conversions
--invariant: cents window = cm:get('pbRange') * 100 per side
--invariant: absorber pbs absorb lane-1 detune jumps; first onset anchors a pb-active channel
--invariant: pb.derived=='absorber' marks an absorber (cc sidecar) or in-window seat (RAM-only)
--invariant: replace-window seats are markerless; recognized by window, not a derived-tag on wire
--invariant: pa stores aftertouch value in mm cc.vel; cc-routing fields stripped on projection
--invariant: col events sort by logical ppq
--invariant: endppq carries no delay; delay shifts only the note-on
--invariant: 16 channels always present; frame.channels[i] non-nil for i in 1..16 after rebuild

--shape: channel = { chan, onTake = { notes, ccs={[ccNum]=col}, [pc], [pb], [at] } }
--shape: column = { events=[evt,...], [cc=ccNum] }  -- events sorted by logical ppq
--shape: noteEvent core = { ppq, endppq, pitch, vel, lane, detune, delay }
--invariant: noteEvent optional: muted, sample, sampleShadowed, intentCents, <metadata...>
--shape: pbEventCol = { ppq, val=cents-minus-detune, detune, hidden, ... }
--invariant: pbEventCol optional: delay, shape, tension
--invariant: pbEventCol is the col projection; um cache holds raw cents in val
--shape: paEventCol = { evType='pa', ppq, pitch, vel, ... }
--invariant: paEventCol mixes into note column events
--shape: extraColumns[chan] = { notes=count, [pc], [pb], [at], [ccs={[ccNum]=true}] }
--shape: lastMuteSet = { [chan] = true }, pushed by tv via tm:setMutedChannels
--shape: fxParked = one evType-tagged off-take stash for every replace park; each spec is the authored
--shape:   event in the logical frame, minus the realisation frame (the REALISATION set),
--shape:   so new metadata rides park automatically. Baseline fields per type (raw re-derived on restore):
--shape:   note { evType='note', chan, lane, uuid, ppq, endppq, pitch, vel, detune, delay, sample, [intentCents], [fx] }
--shape:   cc { evType='cc', chan, cc, ppq, val, shape, [tension] }  |  pb { evType='pb', chan, ppq, val (=cents), shape, [tension] }  |  pa { evType='pa', chan, pitch, ppq, vel, [rpb] }
--shape: frame.channels[chan] = { chan, onTake = the half mm holds, parked = the half a replace window took off it }
--shape: frame.channels[chan].onTake = { notes = { [lane] = { events } }, ccs = { [ccNum] = { events } }, at/pc/pb = { events } }
--shape: frame.channels[chan].parked.notes = { { evType='note', chan, uuid, ppq, endppq, endppqC, pitch, vel, detune, sample, delay, lane, [fx] }, ... } -- render-ready off-take replace events (endppq is the authored ceiling the view edits, endppqC the render clip clipParked derives)
--shape: frame.channels[chan].parked.ccs = { { evType='cc', chan, cc, ppq, val, shape, [tension] }, ... } -- off-take cc-replace render events
--shape: frame.channels[chan].parked.pb = { { evType='pb', chan, ppq, val (=cents), cents, shape, [tension] }, ... } -- off-take pb-replace render events
--shape: frame.channels[chan].parked.pa = { { evType='pa', chan, pitch, ppq, vel, [rpb] }, ... } -- off-take PA events; rebuildPA re-projects them into the host note column
--contract: a discrete-replace kind parks its host: a region parks its covered chord, a note parks itself
--invariant: parked members feed generator + grid only; never sounding (mute fails for CC/PA)

local util    = require 'util'
local curves  = require 'curves'
local timing  = require 'timing'
local voicing = require 'voicing'
local tuning  = require 'tuning'

local generators = require 'generators'
local perf       = require 'perf'
local fxWindows  = require 'fxWindows'

local mm, cm, ds = (...).mm, (...).cm, (...).ds
-- Forced note columns per channel absent an extraColumns entry. Main passes nothing (1: every
-- channel is note-typeable); the pattern editor passes 0 so only channels with data appear.
local defaultNoteCols = (...).defaultNoteCols or 1

local tm = {}
local fire = util.installHooks(tm)

---------- STATE

-- The frame the engine derives and the accessors publish. `frame` is the stable handle; its
-- `channels` map swaps each pass, and the operations that seat events in it travel alongside.
local frame       = { channels = {} }
local lastMuteSet = {}
-- The derivation journal, and the swing-staleness flag beside it: any edit or config change adds a
-- channel's dirt, and the gated stages read it. Missed dirt writes silent wrong output. see dirt.lua
local dirt = require('dirt').new()
-- Deep clone of derivationInputs() as of the last rebuild: what the current frame was derived under.
-- bindTake diffs against it, because a rebind can find any of it changed with no signal to hear.
local derivedInputs
-- Rebuilt chans re-read the wire, so muted flags need re-conforming; setMutedChannels consumes.
local muteConform  = {}
-- True while a tm-internal driver (parked flush, region freeze) writes ds; only suppressingRebuild
-- may set it, suppressing the inline dataChanged rebuild. see docs/trackerManager.md § Mutation contract
local flushingParked = false
-- Set via tm:requestRebuild for geometry-only changes staging no mm ops: forces the flush
-- past its no-op return AND the rebuild past the rebuild(∅) gate, which consumes it.
local rebuildRequested = false
-- Held only across tm:setLength's shrink flush: derivation (tail clip, fx windows, parked
-- realisation) must see the new take end before mm:setLength moves the EOT. see § Length
local pendingLen

---------- FRAME

do
  -- col -> already renewed this pass: a lane renewed on the last pass must renew again on this one,
  -- so the memo belongs to the channels map and newPass replaces the two together.
  local renewed = {}

  -- Only note columns interleave notes and PAs, which can share an onset: ties order note-before-PA,
  -- then pitch, so an equal-onset seat holds across rebuilds.
  local function noteColumnLess(a, b)
    if a.ppq ~= b.ppq then return a.ppq < b.ppq end
    local aPa, bPa = a.evType == 'pa', b.evType == 'pa'
    if aPa ~= bPa then return bPa end
    return (a.pitch or 0) < (b.pitch or 0)
  end

  -- Open a rebuild pass: the channels map is minted afresh and handed back for the carry-forward
  -- loop to read the clean channels out of.
  function frame.newPass()
    local prev = frame.channels
    frame.channels, renewed = {}, {}
    return prev
  end

  -- tv's cell carry keys on a note lane's `events` table identity, so a change to the lane's membership
  -- or to a seated event's rendered fields must replace that table with a fresh one. see docs/trackerManager.md § Note-lane renewal
  --invariant: a note lane's events table changes identity iff its contents changed (tv's carry key)
  function frame.renewLane(chan, lane)
    local channel = frame.channels[chan]
    local col = channel and channel.onTake.notes[lane]
    if col and not renewed[col] then
      renewed[col] = true
      col.events = util.clone(col.events)
    end
    return col
  end

  -- A caller that replaced a lane's events table itself has done the renewal; recording it keeps a
  -- later renewLane from cloning the fresh table on top.
  function frame.markRenewed(col) renewed[col] = true end

  -- Field write on a seated event: renew only where the value actually moves, or the tail walk's
  -- restamp renews every bounded lane every pass. Events are self-describing, so (chan, lane) is here.
  function frame.setEvent(evt, field, value)
    if evt[field] == value then return end
    frame.renewLane(evt.chan, evt.lane)
    evt[field] = value
  end

  -- Membership write: renew the lane, then splice at its onset to keep it
  -- ordered; renewal and splice are one act. See docs/trackerManager.md § Note-lane renewal
  function frame.spliceEvent(chan, lane, evt)
    local col = frame.renewLane(chan, lane)
    util.insertSorted(col.events, evt, noteColumnLess)
  end

  -- ppq alone orders a cc or pb column: one stream, and no tie-break to preserve.
  local function ppqLess(a, b) return a.ppq < b.ppq end

  -- A channel's parked list bucketed by the field naming its column: 'lane' for notes, 'cc' for ccs.
  -- see docs/trackerManager.md § Lane occupancy
  --invariant: each parked bucket holds its column's events in ppq order
  local parkedBuckets = setmetatable({}, { __mode = 'k' })   -- parked list -> its column buckets
  local noParked = {}
  local function bucketedParked(parked, field)
    local buckets = parkedBuckets[parked]
    if not buckets then
      buckets = {}
      for _, evt in ipairs(parked) do util.bucket(buckets, evt[field], evt) end
      for _, bucket in pairs(buckets) do util.sortByPPQ(bucket) end
      parkedBuckets[parked] = buckets
    end
    return buckets
  end

  -- Strict-next authored note on a lane: chord-mates share an onset, so the seek is strict, and a
  -- PA holds no lane of its own and never answers. See docs/trackerManager.md § Lane occupancy.
  --post: unsafe result = the lane's parked events in ppq order; empty when the lane holds none
  function frame.parkedOnLane(chan, lane)
    return bucketedParked(frame.channels[chan].parked.notes, 'lane')[lane] or noParked
  end

  -- A column's whole authored population: on-take events plus parked ones off the take, memoised
  -- against those two lists, each replaced whole on change. see docs/trackerManager.md § Lane occupancy
  local unions = setmetatable({}, { __mode = 'k' })   -- on-take events -> parked bucket -> the union
  local function memoUnion(events, parked, less)
    if #parked == 0 then return events end
    local byParked = unions[events]
    if not byParked then
      byParked = setmetatable({}, { __mode = 'k' })
      unions[events] = byParked
    end
    local union = byParked[parked]
    if not union then
      union = util.clone(events)
      for _, evt in ipairs(parked) do util.insertSorted(union, evt, less) end
      byParked[parked] = union
    end
    return union
  end

  --post: unsafe result = the lane's whole population in column order
  --post: (nothing parked on the lane) → result is the lane's own events table
  function frame.authoredEvents(chan, lane)
    local col = frame.channels[chan].onTake.notes[lane]
    return memoUnion(col.events, frame.parkedOnLane(chan, lane), noteColumnLess)
  end

  --pre: the cc column exists -- renderUnion mints one for every parked cc
  --post: unsafe result = the cc column's whole population in ppq order
  --post: (nothing parked on the column) → result is the column's own events table
  function frame.authoredCC(chan, ccNum)
    local channel = frame.channels[chan]
    local parked  = bucketedParked(channel.parked.ccs, 'cc')[ccNum] or noParked
    return memoUnion(channel.onTake.ccs[ccNum].events, parked, ppqLess)
  end

  -- pb is one stream per channel, so the parked list is already the column's own and needs no bucket.
  local noEvents = {}
  --post: unsafe result = the channel's whole pb population in ppq order
  --post: result = nil iff the channel has no pb column and nothing parked
  function frame.authoredPb(chan)
    local channel = frame.channels[chan]
    local col, parked = channel.onTake.pb, channel.parked.pb
    if not col and #parked == 0 then return nil end
    return memoUnion(col and col.events or noEvents, parked, ppqLess)
  end

  -- Span end: an event's own ceiling (authored endppq or take length) clipped to the lane's strict-next
  -- onset (see docs/trackerManager.md § Lane occupancy); takeLenL is hoisted by the caller, not read from event/mm.
  function frame.clippedSpanEnd(evt, takeLenL)
    local ceil = (evt.endppq == nil or evt.endppq == util.OPEN) and takeLenL
                 or math.min(evt.endppq, takeLenL)
    local successor = frame.nextOnLane(evt.chan, evt.lane, evt.ppq)
    return math.max(evt.ppq + 1, math.min(ceil, successor and successor.ppq or math.huge))
  end

  function frame.nextOnLane(chan, lane, ppq)
    local found
    local col = frame.channels[chan].onTake.notes[lane]
    if col then
      for i = util.firstAfter(col.events, ppq), #col.events do
        if col.events[i].evType ~= 'pa' then found = col.events[i]; break end
      end
    end
    local bucket = frame.parkedOnLane(chan, lane)
    local parked = bucket[util.firstAfter(bucket, ppq)]
    if parked and (not found or parked.ppq < found.ppq) then found = parked end
    return found
  end

  -- Re-true a lane appended to in bulk: a raw->logical flip crossing two onsets is what disorders
  -- one, and a cheap scan lets the common already-ordered lane skip the sort.
  function frame.orderLane(col)
    local events = col.events
    for i = 2, #events do
      if noteColumnLess(events[i], events[i - 1]) then
        table.sort(events, noteColumnLess)
        return
      end
    end
  end
end

---------- SHARED HELPERS

--invariant: flushingParked is restored on every exit; an escaping error must not freeze rebuilds
local function suppressingRebuild(fn)
  flushingParked = true
  local ok, err = xpcall(fn, debug.traceback)
  flushingParked = false
  if not ok then error(err, 0) end
end

-- A region edit's real dirt is its members, found later by the park reconcile; here we seed one trigger
-- point per region the uuid diff changed (create/remove/move/fx-change), waking its park scan and its fx expansion.
local function seedRegionEdit(newRegions)
  if not derivedInputs then dirt.add(nil, true); return end
  local function key(r) return r.uuid or util.key(r.chan, r.ppq, r.endppq) end
  local function trigger(r)
    -- A chan-0 region's edit dirties all sixteen channels -- wider than the set in use on purpose. see docs/trackerManager.md § Channel & column model
    -- Each seed sits at that channel's own raw ppq, since swing resolves per channel.
    local first, last = r.chan, r.chan
    if r.chan == 0 then first, last = 1, 16 end
    for chan = first, last do
      dirt.add(chan, { verb = 'region', ppqL = r.ppq,
                       ppq = tm:fromLogical(chan, r.ppq) })
    end
  end
  local old, seen = {}, {}
  for i, r in ipairs(derivedInputs.fxRegions or {}) do old[key(r)] = { region = r, index = i } end
  for i, r in ipairs(newRegions or {}) do
    local k = key(r); seen[k] = true
    local o = old[k]
    if not o then trigger(r)
    elseif o.region.ppq ~= r.ppq or o.region.endppq ~= r.endppq
        or not util.deepEq(o.region.fx, r.fx) then
      trigger(o.region); trigger(r)
    elseif o.index ~= i then
      -- Storage order is derivation input -- lane precedence among overlapping regions follows
      -- the array -- so a pure reorder (lane swap) must dirty too, or rebuild(∅) swallows it.
      trigger(r)
    end
  end
  for k, o in pairs(old) do if not seen[k] then trigger(o.region) end end
end

-- An external/undo fxParked change (not tm's own flush -- that stash write is converged output): seed
-- each added member (newly parked) and removed member (restored).
local function seedParkedEdit(newParked)
  if not derivedInputs then dirt.add(nil, true); return end
  local function key(m)
    if m.evType == 'note' then return 'note\0' .. tostring(m.uuid) end
    return util.key(m.evType, m.chan, m.cc or 0, m.ppq)
  end
  local old, new = {}, {}
  for _, m in ipairs(derivedInputs.fxParked or {}) do old[key(m)] = m end
  for _, m in ipairs(newParked or {}) do new[key(m)] = m end
  local function parkDirt(m, verb)
    dirt.add(m.chan, dirt.parkSeed(m, verb, tm:fromLogical(m.chan, m.ppq)))
  end
  for k, m in pairs(new) do if not old[k] then parkDirt(m, 'park') end end
  for k, m in pairs(old) do if not new[k] then parkDirt(m, 'restore') end end
end

-- Everything the pipeline derives from beyond the take itself. Nothing signals when it changes under a
-- dormant tracker, so the rebind diffs it instead. see docs/trackerManager.md § Dormant guard
local function derivationInputs()
  return {
    trackerMode  = cm:get('trackerMode'),      swings       = cm:get('swings', { mergeTiers = true }),
    pbRange      = cm:get('pbRange'),          overlapOffset= cm:get('overlapOffset'),
    swing        = ds:get('swing'),            fxRegions    = ds:get('fxRegions'),
    extraColumns = ds:get('extraColumns'),     fxParked     = ds:get('fxParked'),
    fxRealisedWindows = ds:get('fxRealisedWindows'), paramAutomation = ds:get('paramAutomation'),
  }
end

-- The edit side's bend window, in cents per side. pbRange resolves through cm's 5 tiers -- too
-- costly to re-fetch per pb. Cache it; rebuild (the cm coherence point) drops the cache.
local pbLimCache
local function pbLim()
  if not pbLimCache then pbLimCache = cm:get('pbRange') * 100 end
  return pbLimCache
end

local function delayToPPQ(delay) return timing.delayToPPQ(delay, mm:resolution()) end

----- Fx uuids and windows

-- ids are `fxr-N` region / `fxp-N` parked. A mint takes the higher of the store's high-water mark
-- and its own counter: store alone reissues an unflushed batch's id; counter alone, reset per session, reissues a live one.
local fxUuidPrefix = { fxRegions = 'fxr', fxParked = 'fxp' }
local fxUuidSeq    = {}

--pre: key names a store in fxUuidPrefix
--post: result = an id claimed neither by ds[key] nor by any id this mint has already issued
local function newFxUuid(key)
  local prefix, seq = fxUuidPrefix[key], fxUuidSeq[key] or 0
  for _, record in ipairs(ds:get(key) or {}) do
    local n = tonumber(tostring(record.uuid):match('^' .. prefix .. '%-(%d+)$'))
    if n and n > seq then seq = n end
  end
  seq = seq + 1
  fxUuidSeq[key] = seq
  return prefix .. '-' .. seq
end

-- inUse is channelsInUse's set, taken from the same head snapshot: a channel outside it runs no
-- host, so a chain reaches nothing the document never used; second return is the stored globals, whose own uuids the union answers for. see docs/trackerManager.md § Channel & column model
local function expandGlobals(regions, inUse)
  local channelRegions, globals = {}, {}
  for _, region in ipairs(regions or {}) do
    util.add(region.chan == 0 and globals or channelRegions, region)
  end
  -- Appended after every stored region, so each channel's own regions come first in storage order and
  -- a global chain takes last precedence there. see docs/trackerManager.md § Channel & column model
  for _, region in ipairs(globals) do
    for chan = 1, 16 do
      if inUse[chan] then
        util.add(channelRegions, util.assign(util.clone(region),
                                             { chan = chan, uuid = util.key(region.uuid, chan) }))
      end
    end
  end
  return channelRegions, globals
end

-- Freeze eligibility over the pass's windows: a refusal means some other window would be left
-- standing over the raw output this freeze creates. see docs/trackerManager.md § Fx window census
local function freezeRefused(frozen, windows)
  for _, other in ipairs(windows.on(frozen.chan)) do
    if other.uuid ~= frozen.uuid then
      -- Half-open for every target: a host's close folds at endppq-1, so abutting windows no
      -- longer share a boundary seat and abutting is genuinely disjoint.
      if frozen.ppq < other.endppq and other.ppq < frozen.endppq then
        for target in pairs(frozen.targets) do
          if other.targets[target] then return true end
        end
        -- A note-dest host parks no stream but its own note, so no target of its own can be met --
        -- its span is the test. Continuous-only hosts do claim curve targets, which the arm above has.
        if frozen.hostType == 'note' and generators.parksNotes(frozen) and other.targets.note then
          return true
        end
      end
      -- Onset-in-window, as parking decides it: a host the frozen note window covers is destroyed with
      -- the chord it parks, taking its seats or its whole output with it.
      if frozen.targets.note and other.hostType == 'note'
         and other.ppq >= frozen.ppq and other.ppq < frozen.endppq then return true end
    end
  end
  return false
end

local function forEachEvent(fn)
  for i=1,16 do
    local channel = frame.channels[i]
    if channel then
      local chan, cols = channel.chan, channel.onTake
      for lane, col in ipairs(cols.notes) do
        for _, evt in ipairs(col.events) do
          local isNote = evt.evType ~= 'pa'
          fn(isNote and 'note' or 'pa', evt, chan, isNote, nil, lane)
        end
      end
      for _, t in ipairs{'pb', 'at', 'pc'} do
        if cols[t] then
          for _, evt in ipairs(cols[t].events) do fn(t, evt, chan, false) end
        end
      end
      for ccNum, col in pairs(cols.ccs) do
        for _, evt in ipairs(col.events) do fn('cc', evt, chan, false, ccNum) end
      end
    end
  end
end

---------- RAW INDEX

-- Owns rawIndex/byUuid/fxHosts and the upkeep that keeps them true; knows nothing of staging.
-- `index` is the handle its doors hang on; the three structures stay private to the block.
local index = {}
do

  ----- State

  --shape: rawIndex[chan] = { notes, pbs, pcs, pas, ats, ccs = { [ccNum] = list } }; every event on the channel, one list per type -- notes and pbs flat across all lanes, pcs/pas/ats flat, ccs bucketed by cc number. Each list raw-then-logical sorted; readers filter at use.
  local rawIndex = {}
  local byUuid = {}
  local fxHosts = {}   -- chan -> { uuid = true } for on-take .fx notes; maintained, never rescanned. see design § Phase 5.5

  ----- Order

  -- Total order for the raw working set; every list here holds it. See docs/trackerManager.md § Update manager (um).
  function index.order(a, b)
    if a.ppq ~= b.ppq then return a.ppq < b.ppq end
    local aL, bL = a.ppqL or a.ppq, b.ppqL or b.ppq
    if aL ~= bL then return aL < bL end
    if (a.derived or false) ~= (b.derived or false) then return not a.derived end
    if (a.lane or 0) ~= (b.lane or 0) then return (a.lane or 0) < (b.lane or 0) end
    return (a.pitch or 0) < (b.pitch or 0)
  end

  ----- Read surface

  -- Prevailing lane-1 detune at-or-before ppq; flush derives wire-raw = cents + index.detuneAt(seat).
  -- Best-effort only; full absorber reconciliation is rebuild's absorber pass (docs/trackerManager.md § Pitchbend).
  function index.detuneAt(chan, P)
    local notes = rawIndex[chan].notes
    for i = util.firstAfter(notes, P) - 1, 1, -1 do
      if notes[i].lane == 1 then return notes[i].detune or 0 end
    end
    return 0
  end

  -- The pipeline's raw working set, read in place by the walk and its raw consumers
  -- (filtered at use); entries are live um records.
  function index.raw(chan) return rawIndex[chan] end

  -- The maintained fx-host set for a channel (uuids of on-take .fx notes); clipNoteHosts reads it
  -- instead of rescanning columns.
  function index.fxHosts(chan) return fxHosts[chan] end

  -- Resolve a uuid to its live column event via the seat stamp (byUuid.colEvt), so the clip cache
  -- reseeks a dirty host without a column walk. see docs/trackerManager.md § Lane occupancy
  function index.colEvtFor(uuid) local e = byUuid[uuid]; return e and e.colEvt end

  -- The live index entry for a uuid, valid until the next rebuild.
  function index.byUuid(uuid) return byUuid[uuid] end
  -- gm and tv resolve a uuid through tm; the entry itself is the index's.
  function tm:byUuid(uuid) return index.byUuid(uuid) end

  -- Ownership is tested logically (a raw delay or nudge can't detach a PA from its own seat), and
  -- this gathers before applying since fn mutates the very pas list it walks. see docs/trackerManager.md § PA binding
  function index.forEachAttachedPA(host, fn)
    local from, to = host.ppqL or host.ppq, host.endppqL or host.endppq
    local attached = {}
    for _, cc in ipairs(rawIndex[host.chan].pas) do
      if cc.pitch == host.pitch then
        local seat = cc.ppqL or cc.ppq
        if seat >= from and seat < to then util.add(attached, cc) end
      end
    end
    for _, cc in ipairs(attached) do fn(cc) end
  end

  ----- List placement

  local function rawIndexListFor(evt, chan)
    local ri = rawIndex[chan]
    local t = evt.evType
    if t == 'note' then return ri.notes end
    if t == 'pb' then return ri.pbs end
    if t == 'pc' then return ri.pcs end
    if t == 'pa' then return ri.pas end
    if t == 'at' then return ri.ats end
    if t == 'cc' then
      -- Created on demand so index.sync's fast path compares two tables, never nil vs table.
      local bucket = ri.ccs[evt.cc]
      if not bucket then bucket = {}; ri.ccs[evt.cc] = bucket end
      return bucket
    end
  end
  -- fx-host membership rides the index turnover: set on insert of a .fx note, cleared on removal, so
  -- clipNoteHosts never rescans columns to find hosts.
  local function setFxHost(evt)
    if evt.evType ~= 'note' or not evt.uuid then return end
    if evt.fx then
      local set = fxHosts[evt.chan]
      if not set then set = {}; fxHosts[evt.chan] = set end
      set[evt.uuid] = true
    else
      local set = fxHosts[evt.chan]
      if set then set[evt.uuid] = nil end
    end
  end
  local function clearFxHost(evt, chan)
    if evt.evType ~= 'note' or not evt.uuid then return end
    local set = fxHosts[chan or evt.chan]
    if set then set[evt.uuid] = nil end
  end
  -- During a batched reconcile this holds the lists index.add touched; the batch
  -- sorts each once at the end instead of re-sorting per insert. nil = sort inline.
  local deferredSort
  function index.add(evt)
    local tbl = rawIndexListFor(evt, evt.chan)
    if not tbl then return end
    setFxHost(evt)
    -- A lone insert seeks its seat rather than re-sorting the already-ordered list whole.
    -- See docs/trackerManager.md § Incremental index reconciliation.
    if deferredSort then
      util.add(tbl, evt)
      deferredSort[tbl] = true
    else
      util.insertSorted(tbl, evt, index.order)
    end
  end
  function index.delete(evt, chan)
    local tbl = rawIndexListFor(evt, chan or evt.chan)
    if not tbl then return end
    clearFxHost(evt, chan)
    for i, item in ipairs(tbl) do if item == evt then table.remove(tbl, i); return end end
  end

  -- Keep the index coherent (util.seek and the walk need ascending order): a chan move or an onset
  -- move both reseat via remove-then-place. See docs/trackerManager.md § Incremental index reconciliation.
  function index.move(evt, oldChan, update)
    local oldList  = rawIndexListFor(evt, oldChan)
    local newList  = rawIndexListFor(evt, evt.chan)
    local migrated = oldList ~= newList
    local reseated = newList ~= nil and (update.ppq ~= nil or update.ppqL ~= nil)
    if migrated or reseated then
      index.delete(evt, oldChan)
      index.add(evt)
    end
    -- A pure fx toggle refreshes the entry in place (no list migration), so the turnover hooks miss it.
    if update.fx ~= nil then setFxHost(evt) end
  end

  -- The batching door: rawIndex is um's, so um owns the deferral. Inserts and sort-key moves inside
  -- fn flag their list; each is sorted once here. A caller reaching for the flag gets a nil it can't see.
  function index.withDeferredSort(fn)
    local prev = deferredSort
    deferredSort = {}
    fn()
    for tbl in pairs(deferredSort) do table.sort(tbl, index.order) end
    deferredSort = prev
  end

  -- The order's keys: a write that moves one leaves the containing list out of order.
  local SORT_KEYS = { ppq = true, ppqL = true, lane = true, pitch = true, derived = true }

  -- Field write on an index entry, mirroring setEvent for column events: skip the no-op, and where the
  -- value moves a sort key, re-true the containing list -- deferred to the open block if there is one.
  function index.assign(entry, field, value)
    if entry[field] == value then return end
    -- Non-member records (fx specs, restores) flag their channel's list spuriously: one redundant sort
    -- of a list the same walk is about to stain anyway, against an O(n) membership scan per write.
    local tbl = SORT_KEYS[field] and rawIndexListFor(entry, entry.chan)
    entry[field] = value
    if not tbl then return end
    if deferredSort then deferredSort[tbl] = true else table.sort(tbl, index.order) end
  end

  ----- Entry lifecycle

  -- Construct the um-frame index entry for one mm clone and file it into byUuid.
  -- Shared verbatim by full reload and the incremental verbs so both build identical entries.
  local function makeEntry(e)
    local evt
    if e.evType == 'pb' then
      -- Clone (not pick) so arbitrary metadata survives; val reframes raw->cents (um's frame), raw keeps
      -- the wire value for rebuildPbs' delta-gate. cents sidecar is authored logical -- nil for foreign pbs.
      evt = util.clone(e)
      evt.val, evt.raw, evt.realised = tuning.rawToCents(e.val, pbLim()), e.val, true
    else
      evt = e
      evt.realised = true
    end
    byUuid[evt.uuid] = evt
    return evt
  end

  -- Refresh an existing entry from mm's fresh clone in place: prev keeps its ppq-sorted
  -- slot in rawIndex, so a same-slot reconcile skips the index.delete scan, reinsert and sort.
  local umDecor = { realised = true, colEvt = true }   -- um's own fields; mm's clone never carries them
  local function refreshEntry(prev, e)
    for k in pairs(prev) do if e[k] == nil and not umDecor[k] then prev[k] = nil end end
    util.assign(prev, e)
    prev.realised = true
    -- pb reframes val raw->cents and mirrors the wire in raw, matching makeEntry so both doors agree.
    if e.evType == 'pb' then prev.val, prev.raw = tuning.rawToCents(e.val, pbLim()), e.val end
  end

  -- Incremental index upkeep for one uuid. rawIndex lists are ppq-sorted and rawIndexListFor ignores
  -- ppq, so refresh in place only at an unchanged ppq. see docs/trackerManager.md § Incremental index reconciliation
  function index.sync(uuid)
    if not uuid then return end
    local prev = byUuid[uuid]
    local _, e = mm:byUuid(uuid)
    if e and prev and prev.ppq == e.ppq
       and rawIndexListFor(prev, prev.chan) == rawIndexListFor(e, e.chan) then
      refreshEntry(prev, e)
      return
    end
    byUuid[uuid] = nil
    if prev then index.delete(prev) end
    if e then
      local entry = makeEntry(e)
      entry.colEvt = prev and prev.colEvt   -- the seat stamp outlives reconciliation; only re-seating replaces it
      index.add(entry)
    end
  end

  -- Seat stamp: columns file their live event on the entry as they seat it, giving raw consumers
  -- the event without a per-pass column scan. Returns whether the uuid has an entry (mm knows it).
  function index.stampColEvt(colNote)
    local entry = byUuid[colNote.uuid]
    if entry then entry.colEvt = colNote end
    return entry ~= nil
  end

  function index.forget(uuid) byUuid[uuid] = nil end

  ----- Load

  -- Rebuild the whole index from mm. Only for genuine loads (init, take swap, external
  -- re-read) where the incremental index is stale; edit rebuilds keep the live index.
  function index.load()
    byUuid = {}
    for i = 1, 16 do rawIndex[i] = { notes = {}, pbs = {}, pcs = {}, pas = {}, ats = {}, ccs = {} }; fxHosts[i] = {} end
    for _, e in mm:events() do
      local evt = makeEntry(e)
      local tbl = rawIndexListFor(evt, evt.chan)
      if tbl then util.add(tbl, evt); setFxHost(evt) end
    end
    -- mm:events() yields each kind ppq-sorted and the per-channel filter preserves that;
    -- one sort per list settles the logical tie-break the incremental path maintains.
    for i = 1, 16 do
      local ri = rawIndex[i]
      table.sort(ri.notes, index.order)
      table.sort(ri.pbs, index.order)
      table.sort(ri.pcs, index.order)
      table.sort(ri.pas, index.order)
      table.sort(ri.ats, index.order)
      for _, bucket in pairs(ri.ccs) do table.sort(bucket, index.order) end
    end
  end

  index.load()
end

---------- FLUSH DERIVATION

-- Same-(chan,pitch) MIDI legality over the post-flush note set: kill verdicts only -- onsets and
-- tails are the walk's. see docs/trackerManager.md § Flush collision scan
local function collisionKills()
  -- Kills only: tm separates once, at the walk. Dedup cannot follow it there -- the walk
  -- separates a duplicate instead, and nothing below kills what it split.
  local kills = {}
  for chan = 1, 16 do
    local byPitch = {}
    for _, n in ipairs(index.raw(chan).notes) do util.bucket(byPitch, n.pitch, n) end
    for _, group in pairs(byPitch) do
      if #group > 1 then   -- a lone note has nothing to collide with
        for _, n in ipairs(voicing.resolveSorted(group)) do util.add(kills, n) end
      end
    end
  end
  return kills
end

---------- STAGER

-- Stages mm-facing ops, commits them in one mm:modify; reaches the index above only via its doors.
-- `stager` is the handle its doors hang on; the staged ops stay private to the block.
local stager = {}
do

  ----- State

  local adds = {}
  local assigns = {}
  local deletes = {}
  --shape: seeds[chan] = list of birth-snapshot seeds (dirt.lua), folded (dedup-by-uuid) into the dirt journal at flush. see design § The model, inverted
  local seeds = {}
  local parkedEdits = {}

  ----- Low-level verbs

  -- Every low-level verb drops a birth-snapshot seed for the event it touched; flush folds them
  -- into seed-valued dirt (dedup-by-uuid). A dead seed's uuid dangles safely: see docs/trackerManager.md § Interval seeds.
  local function seedEvent(evt, verb) util.bucket(seeds, evt.chan, dirt.liveSeed(evt, verb)) end

  --contract: every staged note (any lane) and pb files into rawIndex; detune reads filter to lane 1
  --contract: caller supplies evt.evType
  local function addLowlevel(evt)
    seedEvent(evt, 'add')
    index.add(evt)
    util.add(adds, { evt = evt })
  end

  --contract: dedupes by uuid; in-flight assigns to the same event collapse into one mm write
  --invariant: util.REMOVE markers must survive merging
  local function assignLowlevel(evt, update)
    local oldChan = evt.chan
    -- A move (onset shifts, or now chan) is delete-at-old + insert-at-new; snapshot the vacated slot
    -- before the assign. See docs/trackerManager.md § Interval seeds for the shape and the chan case.
    local moved = update.ppq ~= nil or update.ppqL ~= nil or update.delay ~= nil
                  or update.lane ~= nil or update.chan ~= nil
    local vacated = moved and dirt.liveSeed(evt, 'assign') or nil
    util.assign(evt, update)
    if vacated then util.bucket(seeds, oldChan, vacated) end
    seedEvent(evt, 'assign')
    index.move(evt, oldChan, update)
    if not evt.realised then return end
    for _, e in ipairs(assigns) do
      if e.uuid == evt.uuid then
        -- Plain copy, not util.assign: util.assign collapses util.REMOVE → nil-the-key.
        for k, v in pairs(update) do e.update[k] = v end
        return
      end
    end
    util.add(assigns, { uuid = evt.uuid, update = update, evt = evt })
  end

  local function deleteLowlevel(evt)
    seedEvent(evt, 'delete')
    -- index.delete matches by object identity; the PC mutation hook deletes projected column
    -- events, so resolve the raw record via byUuid first or the index entry strands.
    index.delete(evt.uuid and index.byUuid(evt.uuid) or evt)
    if evt.uuid then index.forget(evt.uuid) end

    if evt.realised then
      util.add(deletes, { uuid = evt.uuid, evt = evt })
      for j = #assigns, 1, -1 do
        if assigns[j].uuid == evt.uuid then table.remove(assigns, j) end
      end
    else
      for j = #adds, 1, -1 do
        if adds[j].evt == evt then table.remove(adds, j); break end
      end
    end
  end

  ----- High-level ops

  -- um is a stager: pb authoring writes cents; wire raw is derived at flush (cents + index.detuneAt seat).
  -- Absorber seating/reseating happens in rebuild's absorber pass from the final note layout.

  local function addNote(n)
    if lastMuteSet[n.chan] then n.muted = true end
    addLowlevel(n)
  end

  local function deleteNote(n, keepPAs)
    if not keepPAs then index.forEachAttachedPA(n, function(evt) deleteLowlevel(evt) end) end
    deleteLowlevel(n)
  end

  -- P1/P2 are the new raw span, the one that reaches mm; L1/L2 the new logical span -- the frame
  -- attachment, the translation test and culling all share. see docs/trackerManager.md § PA binding
  local function resizeNote(n, P1, P2, L1, L2)
    local startL, endL = n.ppqL or n.ppq, n.endppqL or n.endppq
    local shiftL = L1 - startL
    -- Equal logical lengths, not equal raw deltas: swing warps both endpoints alike only when the
    -- length is a period multiple. An OPEN endL needs no case -- huge minus either seat is huge.
    if shiftL ~= 0 and L2 - L1 == endL - startL then
      index.forEachAttachedPA(n, function(evt)
        -- Realise the moved seat, never add the host's raw delta: under swing those disagree, and
        -- the CC walk restamps ppqL from a divergent raw -- overwriting the intent being carried.
        local seat = (evt.ppqL or evt.ppq) + shiftL
        assignLowlevel(evt, { ppq = tm:fromLogical(n.chan, seat), ppqL = seat })
      end)
    else
      local lastPA, lastSeat
      index.forEachAttachedPA(n, function(evt)
        local seat = evt.ppqL or evt.ppq
        if seat <= L1 or seat >= L2 then
          if seat <= L1 and (not lastPA or seat > lastSeat) then lastPA, lastSeat = evt, seat end
          deleteLowlevel(evt)
        end
      end)
      if lastPA then assignLowlevel(n, { vel = lastPA.vel }) end
    end
    assignLowlevel(n, { ppq = P1, endppq = P2, ppqL = L1, endppqL = L2 })
  end

  --contract: lane/chan changes accepted; rebuild reseats columns from the note's authored lane
  --contract: chan change: rebuild's absorber pass reconciles fakes across both channels
  --contract: ppq/endppq route through resizeNote
  local function assignNote(n, update)
    if update.ppq ~= nil or update.endppq ~= nil then
      resizeNote(n, update.ppq or n.ppq, update.endppq or n.endppq,
                    update.ppqL    ~= nil and update.ppqL    or (n.ppqL    or n.ppq),
                    update.endppqL ~= nil and update.endppqL or (n.endppqL or n.endppq))
      update.ppq, update.endppq, update.ppqL, update.endppqL = nil, nil, nil, nil
    end
    if update.pitch then
      index.forEachAttachedPA(n, function(e) assignLowlevel(e, { pitch = update.pitch }) end)
    end
    if next(update) then assignLowlevel(n, update) end
  end

  local function lookup(evtOrUuid)
    local uuid = type(evtOrUuid) == 'table' and evtOrUuid.uuid or evtOrUuid
    if not uuid then return end
    return index.byUuid(uuid), uuid
  end

  ----- Public interface

  function stager.delete(evtOrUuid)
    local evt = lookup(evtOrUuid)
    if not evt then return end
    if evt.evType == 'note' then deleteNote(evt)
    else                        deleteLowlevel(evt) end
  end

  -- endppq arrives as authored logical ceiling. OPEN stamps open ceiling + provisional raw note-off
  -- (ppq+1; tail pass derives the real one); finite value stamps logical ceiling and derives raw.
  local function stampEndppq(rec, chan)
    if rec.endppq == util.OPEN then
      rec.endppqL, rec.endppq = util.OPEN, rec.ppq + 1
    else
      rec.endppqL, rec.endppq = rec.endppq, tm:fromLogical(chan, rec.endppq)
    end
  end

  --contract: update.ppq/endppq arrive logical
  --invariant: endppq is the authored ceiling: a finite logical value, or util.OPEN
  --contract: stamps ppqL and endppqL (OPEN→OPEN, else the logical ceiling)
  --contract: derives a provisional raw note-off; the universal tail pass owns the real one
  --invariant: endppqL is tm-private; callers never set it
  --contract: rawCaller=true bypass: translation skipped, only delay-delta applies
  --invariant: stager.assign consumes rawTime before calling; never reaches mm (docs/timing.md)
  local function realiseNoteUpdate(evt, update, rawCaller)
    -- A delay clear arrives as util.REMOVE (assign honours it downstream); decode
    -- to 0 here so the onset arithmetic below never sees the sentinel table.
    local newDelay = update.delay == util.REMOVE and 0 or update.delay
    local dOld = delayToPPQ(evt.delay)
    local dNew = delayToPPQ(newDelay ~= nil and newDelay or evt.delay)
    if rawCaller then
      if update.ppq ~= nil then
        update.ppq = update.ppq + dNew
      elseif dNew ~= dOld then
        update.ppq = evt.ppq + (dNew - dOld)
      end
      return
    end
    if update.ppq == nil and update.endppq == nil and dNew == dOld then return end
    if update.ppq ~= nil then
      update.ppqL = update.ppq
      update.ppq  = tm:fromLogical(evt.chan, update.ppqL, dNew)
    elseif evt.ppqL ~= nil then
      update.ppq = tm:fromLogical(evt.chan, evt.ppqL, dNew)
    else
      update.ppq = evt.ppq + (dNew - dOld)
    end
    -- Clamp staged raw onset ≥ 0 and tail ≤ takeLen so interim mm readers see bounded values.
    -- see docs/trackerManager.md § Staged-update bounds
    if update.ppq < 0 then update.ppq = 0 end
    if update.endppq ~= nil then
      stampEndppq(update, evt.chan)
      local takeLen = tm:length()
      if update.endppq > takeLen then update.endppq = takeLen end
    end
  end

  local function realiseNonNoteUpdate(chan, update)
    if not chan or update.ppq == nil then return end
    update.ppqL = update.ppq
    update.ppq  = tm:fromLogical(chan, update.ppqL)
  end

  local function realiseAddPpq(evt, isNote)
    if evt.ppq == nil or not evt.chan then return end
    evt.ppqL = evt.ppq
    evt.ppq  = tm:fromLogical(evt.chan, evt.ppqL,
                              isNote and delayToPPQ(evt.delay or 0) or 0)
    if isNote and evt.endppq ~= nil then stampEndppq(evt, evt.chan) end
  end

  function stager.assign(evtOrUuid, update)
    local evt = lookup(evtOrUuid)
    if not evt then return end
    local rawCaller = update.rawTime
    update.rawTime = nil
    if evt.evType == 'note' then
      realiseNoteUpdate(evt, update, rawCaller)
      assignNote(evt, update)
    else
      if not rawCaller then realiseNonNoteUpdate(evt.chan, update) end
      if evt.evType == 'pb' and update.val ~= nil then
        update.cents, update.val = update.val, nil
      end
      assignLowlevel(evt, update)
    end
  end

  --contract: notes default detune=0, delay=0, lane=1
  --contract: evt.ppq/endppq arrive logical; endppq is the authored ceiling (or util.OPEN)
  --contract: stamps ppqL and endppqL (tm-private); rewrites ppq/endppq to raw before mm
  --contract: evt.rawTime=true bypasses translation (mirrors stager.assign; rescale-only caller)
  --invariant: rawTime consumed here so it never persists on the record or reaches mm
  --contract: pb authoring frame is logical cents; val stored as cents on the event
  --contract: um only stages; rebuild absorber pass reconciles seats, recomputes raw vals at flush
  function stager.add(evt)
    local rawCaller = evt.rawTime
    evt.rawTime = nil
    if evt.evType == 'note' then
      evt.detune = evt.detune or 0
      evt.delay  = evt.delay  or 0
      evt.lane   = evt.lane   or 1
      if not rawCaller then realiseAddPpq(evt, true) end
      addNote(evt)
    else
      if not rawCaller then realiseAddPpq(evt, false) end
      if evt.evType == 'pb' then evt.cents, evt.val = evt.val or 0, nil end
      -- pb is one value per tick: adopt a pb already at this slot -- including a hidden
      -- absorber seat -- so we never push a rival onto it. see docs/tuning.md § Absorber reconciliation
      local seat = evt.evType == 'pb' and util.seek(index.raw(evt.chan).pbs, 'at-or-before', evt.ppq)
      if seat and seat.ppq == evt.ppq then
        assignLowlevel(seat, { cents = evt.cents, shape = evt.shape, derived = util.REMOVE })
      else
        addLowlevel(evt)
      end
    end
  end

  ----- Parked staging: logical-only edits to the fx replace off-take

  -- Edits stage here and ride flush: a parked edit that wrote ds inline would rebuild mid-batch and
  -- discard still-staged mm ops. rebuildRegionPark derives realisation from the spec each pass.

  -- Adds ride flush, so every add in a batch scans the same not-yet-landed stash: the mint's own
  -- counter is what keeps one batch's mints apart.
  function stager.addParked(spec)
    if spec.evType == 'note' and not spec.uuid then spec.uuid = newFxUuid('fxParked') end
    util.add(parkedEdits, { op = 'add', spec = spec })
  end

  function stager.assignParked(evt, update)
    util.add(parkedEdits, { op = 'assign', evt = evt, update = update })
  end

  function stager.deleteParked(evt)
    util.add(parkedEdits, { op = 'delete', evt = evt })
  end

  -- One flat stash holds every type, so evType leads the key and cc/pitch discriminate within it --
  -- the wire's own identity, lane deliberately absent. see docs/trackerManager.md § Park identity
  --contract: note specs key by uuid; every other type by (evType, chan, cc, pitch, ppq)
  local function findParked(list, ref)
    local function matches(spec)
      if spec.evType ~= ref.evType then return false end
      if ref.evType == 'note' then return spec.uuid == ref.uuid end
      return spec.chan == ref.chan and spec.cc == ref.cc
         and spec.pitch == ref.pitch and spec.ppq == ref.ppq
    end
    for i, spec in ipairs(list) do if matches(spec) then return i end end
  end

  -- Apply staged edits to cloned stashes, then write back under suppressingRebuild so the inline
  -- dataChanged rebuild is suppressed (tm:flush drives the one rebuild).
  local function flushParked()
    local parked = ds:get('fxParked') or {}
    for _, e in ipairs(parkedEdits) do
      local ref  = e.spec or e.evt
      -- flushParked runs before the fold, so feed the seed table (stager.flushDirt folds it, or the
      -- parked-only path below does), keeping one seed order for the whole flush.
      util.bucket(seeds, ref.chan,
                  dirt.parkSeed(ref, e.op, tm:fromLogical(ref.chan, ref.ppq)))
      if e.op == 'add' then
        util.add(parked, e.spec)
      else
        local i = findParked(parked, ref)
        if i then
          if e.op == 'assign' then util.assign(parked[i], e.update)
          else table.remove(parked, i) end
        end
      end
    end
    parkedEdits = {}
    suppressingRebuild(function()
      if not util.deepEq(ds:get('fxParked') or {}, parked) then
        ds:assign('fxParked', #parked > 0 and parked or util.REMOVE)
      end
    end)
  end

  ----- Flush: commit accumulated ops to mm

  --contract: no-op if nothing staged
  --contract: commits deletes, then assigns, then adds under one mm:modify
  --contract: pb cents→raw conversion happens here
  --contract: snapshots ops before mm:modify; mm-callback re-entry can't re-emit in-flight ops
  --contract: returns true when nothing reached mm, so the caller drives the rebuild
  --emits: preflush -- (adds, assigns, deletes)
  --contract: preflush fires before the no-op check so a subscriber can stage peer ops
  --emits: postflush -- nil
  --contract: postflush fires after the commit; subscribers read mm-stamped uuids on staged adds
  function stager.flush()
    fire('preflush', adds, assigns, deletes)
    if #adds == 0 and #assigns == 0 and #deletes == 0 and #parkedEdits == 0
       and not rebuildRequested then return end

    -- Parked edits stage alongside mm ops. Write the stash first (guarded), then let the mm
    -- commit's reload->rebuild pick it up; with no mm ops, the caller drives the one rebuild.
    local hadMmOps = #adds > 0 or #assigns > 0 or #deletes > 0
    if #parkedEdits > 0 then flushParked() end

    if hadMmOps then
      perf.start('flush')

      perf.start('collide')
      for _, n in ipairs(collisionKills()) do deleteNote(n) end
      perf.stop('collide')

      local flushAdds, flushAssigns, flushDeletes = adds, assigns, deletes
      adds, assigns, deletes = {}, {}, {}
      perf.count('committed', #flushAdds + #flushAssigns + #flushDeletes)

      -- Same-pitch moves transiently share a seat key. assignNote's guard keeps the index correct in
      -- either order; descending only spares the backstop a scan. see docs/trackerManager.md § Same-pitch onset separation
      table.sort(flushAssigns, function(a, b)
        return (a.update.ppq or a.evt.ppq or 0) > (b.update.ppq or b.evt.ppq or 0)
      end)

      -- pb wire conversion at flush: raw = centsToRaw(cents + index.detuneAt(seat)).
      -- Rebuild's absorber pass refines with the post-walk layout; this is best-effort for the interim.
      for _, e in ipairs(flushAssigns) do
        if e.evt.evType == 'pb' and e.update.cents ~= nil then
          e.update.val = tuning.centsToRaw(e.update.cents + index.detuneAt(e.evt.chan, e.evt.ppq), pbLim())
        end
      end
      for _, a in ipairs(flushAdds) do
        if a.evt.evType == 'pb' then
          a.evt.val = tuning.centsToRaw((a.evt.cents or 0) + index.detuneAt(a.evt.chan, a.evt.ppq), pbLim())
        end
      end

      perf.start('mm')
      mm:modify(function()
        for _, o in ipairs(flushDeletes) do
          mm:delete(o.uuid)
          index.forget(o.uuid)
        end
        for _, o in ipairs(flushAssigns) do
          mm:assign(o.uuid, o.update)
        end
        for _, o in ipairs(flushAdds) do
          local uuid = mm:add(o.evt)
          -- addLowlevel already filed the raw staged object into rawIndex; drop it by identity
          -- and re-file mm's canonical clone so the entry matches reload (cc shape, pb cents).
          if uuid then index.delete(o.evt); index.sync(uuid) end
        end
      end)
      perf.stop('mm')
      perf.stop('flush'); perf.report()
    else
      stager.flushDirt({})   -- no mm reload to fold flushParked's seeds; fold them here
    end

    fire('postflush')
    return not hadMmOps
  end

  ----- Reload / clear

  -- Fold this flush's per-verb seeds into the journal as seed dirt: dedup-by-uuid (seeded
  -- chans), fold-whole (unseeded payload chans). see docs/trackerManager.md § Interval seeds
  function stager.flushDirt(payloadChans)
    for chan, list in pairs(seeds) do
      local deduped, seen = {}, {}
      for _, s in ipairs(list) do
        if s.uuid == nil or not seen[s.uuid] then
          if s.uuid then seen[s.uuid] = true end
          util.add(deduped, s)
        end
      end
      dirt.add(chan, deduped)
    end
    for chan in pairs(payloadChans) do
      if not seeds[chan] then dirt.add(chan, true) end
    end
  end

  -- Drop un-flushed staging: a rebuild must not carry command-path ops across
  -- (matches prior "fresh um per rebuild").
  function stager.clear()
    adds, assigns, deletes = {}, {}, {}
    parkedEdits            = {}
    seeds                  = {}
  end

  function stager.reload() stager.clear(); index.load() end
end

---------- PUBLIC

----- Accessors

function tm:getChannel(chan)      return frame.channels[chan] end

-- Each note lane of a channel as its whole authored population -- what a renderer addresses, a
-- parked event being the note the author sees. see docs/trackerManager.md § Lane occupancy
--post: fresh result = one unsafe event list per note lane, in lane order
function tm:authoredLanes(chan)
  local lanes = {}
  for lane in ipairs(frame.channels[chan].onTake.notes) do
    util.add(lanes, frame.authoredEvents(chan, lane))
  end
  return lanes
end

-- Each cc column of a channel as its whole authored population, keyed by cc number -- the note lanes'
-- answer for the other keyed stream. see docs/trackerManager.md § Lane occupancy
--pre: the park stage has run, so its column mint makes a parked cc reachable
--post: fresh result = { [ccNum] = unsafe event list in ppq order }, one entry per cc column
function tm:authoredCCs(chan)
  local cols = {}
  for ccNum in pairs(frame.channels[chan].onTake.ccs) do
    cols[ccNum] = frame.authoredCC(chan, ccNum)
  end
  return cols
end

-- The channel's whole authored pb population, nil answering for a channel with no pb at all -- which
-- is the renderer's test for whether to show the column. see docs/trackerManager.md § Lane occupancy
--post: unsafe result = the channel's pb events in ppq order
--post: result = nil iff the channel has no pb column and nothing parked
function tm:authoredPb(chan) return frame.authoredPb(chan) end

-- Every note host off the take as of now, the stash's render events. Each is self-describing, so a
-- caller reads its chan and lane off it. see docs/trackerManager.md § Lane occupancy
--post: result = (channel-ordered) iterator yielding one unsafe parked note event
function tm:eachParkedHost()
  local chan, i = 1, 0
  return function()
    while chan <= 16 do
      i = i + 1
      local evt = frame.channels[chan].parked.notes[i]
      if evt then return evt end
      chan, i = chan + 1, 0
    end
  end
end

function tm:channels()
  local i = 0
  return function()
    i = i + 1
    local channel = frame.channels[i]
    if channel then
      return i, channel
    end
  end
end

function tm:editCursor()
  if not (mm and mm:take()) then return end
  local editCursorTime = reaper.GetCursorPosition()
  return reaper.MIDI_GetPPQPosFromProjTime(mm:take(), editCursorTime)
end

--contract: reports the pending end while setLength's shrink flush runs; mm's take length otherwise
function tm:length()               return pendingLen or (mm and mm:length()) or 0 end
function tm:resolution()           return mm and mm:resolution() end
function tm:name()                 return mm and mm:name() end
function tm:timeSigs()             return mm and mm:timeSigs() or {} end
function tm:interpolate(A, B, ppq, field) return curves.interpolate(A, B, ppq, field) end

-- The projection the pass runs on, replaced at the rebuild head. The seed is the identity, and
-- stands until the first rebuild. see docs/timing.md § The time context
local timeContext = util.instantiate('timeContext', { length = 0, swings = {}, assignment = {} })

--post: fresh result = the projection over tm:length(), cm's merged swings and ds's assignment
local function newTimeContext()
  return util.instantiate('timeContext', {
    length     = tm:length(),
    ppqPerQN   = mm:resolution(),
    swings     = cm:get('swings', { mergeTiers = true }),
    assignment = ds:get('swing') or {},
  })
end

--post: result = ppqL projected under the context the last rebuild head built
function tm:fromLogical(chan, ppqL, offset) return timeContext:fromLogical(chan, ppqL, offset) end

--post: result = ppqI projected under the context the last rebuild head built
function tm:toLogical(chan, ppqI)           return timeContext:toLogical(chan, ppqI) end

--contract: chan==nil marks all 16 channels stale; otherwise just the named channel
--contract: consumed by the next tm:rebuild, then cleared
function tm:markSwingStale(chan)
  dirt.add(chan, true) -- swing move re-times this chan's derivations (raw reseat + absorber seats); not carried by the mm payload
  dirt.swing.add(chan)
end

-- A geometry-only change (a gm region edit staging no mm ops) still needs the grid rebuilt
-- so tv re-tags cellKind. Forces the next flush and rebuild past their no-op gates.
function tm:requestRebuild() rebuildRequested = true end

-- Rebuild output, not a cache: the pipeline mints them wholesale each pass from the settled census
-- and tm:rebuild installs what comes back; absence = not a host.
local windows = fxWindows.new({})   -- the pass's fx windows, whole
local freezeRectByUuid = {}              -- uuid -> the gm rect a freeze-to-group mint would claim

-- One host's whole output in one place, gathered at the tail where the census has settled: the
-- passes above each key their share by host uuid, and the ghost overlay draws exactly one entry.
--shape: fxRealisationByUuid[uuid] = { uuid, chans, notes, targets, parked }
--   targets' spans are logical; notes and parked are the built lists by reference
local fxRealisationByUuid = {}

-- Subtract the breakpoints a bounded thin can spare, raw frame, before freeze's own flush: this decides
-- which points get authored at all, rather than cutting a curve back.
local function thinSeats(chan, entries)
  local raw = index.raw(chan)
  for _, entry in ipairs(entries) do
    if entry.evType ~= 'note' then
      local isPb     = entry.evType == 'pb'
      local tol      = cm:get('freezeThin.' .. generators.destProfile(isPb and 'pb' or entry.cc).unit)
      local startRaw = tm:fromLogical(chan, entry.ppq, 0)
      local endRaw   = tm:fromLogical(chan, entry.endppq, 0)
      local points   = {}
      for _, e in ipairs((isPb and raw.pbs or raw.ccs[entry.cc]) or {}) do
        -- An absorber is realisation the pb pass owns and re-derives after the freeze: not curve material,
        -- and not freeze's to delete. groupMembers' `hidden` is this partition.
        if not e.derived and e.ppq >= startRaw and e.ppq < endRaw then
          -- A pb index entry's val is realisation, detune included, so the subtraction is what stops a
          -- mid-window detune step reading as a feature of the curve. A cc's val is the intent already.
          util.add(points, { ppq = e.ppq, shape = e.shape, tension = e.tension, evt = e,
                             val = isPb and (e.val - index.detuneAt(chan, e.ppq)) or e.val })
        end
      end
      local kept = {}
      for _, p in ipairs(generators.thinCurve(points, tol)) do kept[p] = true end
      -- By identity, not value: two breakpoints can carry the same number, and it is this one that
      -- lost its place.
      for _, p in ipairs(points) do
        if not kept[p] then stager.delete(p.evt) end
      end
    end
  end
end

-- The material a caller mints a stock group from, gathered once the closing rebuild has settled it:
-- live column events, logical frame, no raw sidecar.
local function groupMembers(frozen, entries, promotedUuids)
  local members = {}
  for _, uuid in ipairs(promotedUuids) do
    -- A promoted note the collision walk killed on the way through has no event left to mint from.
    local evt = index.colEvtFor(uuid)
    if evt then util.add(members, evt) end
  end
  local onTake = frame.channels[frozen.chan].onTake
  for _, entry in ipairs(entries) do
    if entry.evType ~= 'note' then
      local col = entry.evType == 'pb' and onTake.pb or (onTake.ccs or {})[entry.cc]
      for _, e in ipairs(col and col.events or {}) do
        -- Half-open for pb too: the conversion pulls the closing seat inside the window, so nothing legitimate stands on endppq and every member lies inside the rect the mint claims.
        -- An absorber seated around a detune onset is hidden realisation, not group material.
        if not e.hidden and e.ppq >= entry.ppq and e.ppq < entry.endppq then util.add(members, e) end
      end
    end
  end
  return members
end

-- Freeze: a one-way projection out of the derived lifecycle -- notes, parked members, seats and
-- windows all convert to authored form in one flush.
local function freezeRegion(uuid, toGroup)
  -- Settle first: the census reads committed state, so a staged host would be invisible to it
  -- and then committed by our own flush. see docs/trackerManager.md § Fx window census
  tm:flush()

  local regions, keptRegions = ds:get('fxRegions') or {}, {}
  local region
  for _, r in ipairs(regions) do
    if r.uuid == uuid then region = r else util.add(keptRegions, r) end
  end
  -- A global region expands into one host per channel and is none of them, so no one channel's output is the one
  -- to freeze. Its stored uuid names no window of the published set either, but the refusal is stated
  -- here rather than left to fall out of a lookup that misses.
  if region and region.chan == 0 then return false end
  local stash, keptParked = ds:get('fxParked') or {}, {}

  -- The other host shape: a note carrying its own chain, parked or still on the take, resolves
  -- through fxWindows, the window set's own builder.
  local hostSpec, onTakeHost, hostRegion
  if not region then
    for _, spec in ipairs(stash) do
      if spec.evType == 'note' and spec.uuid == uuid and spec.fx then hostSpec = spec end
    end
    if hostSpec then
      hostRegion = fxWindows.fromNote(hostSpec,
                                      frame.clippedSpanEnd(hostSpec, tm:toLogical(hostSpec.chan, tm:length())))
    else
      -- byUuid is the raw-frame index entry and .colEvt its stamped logical event, so the window comes
      -- off the event and the assign off the entry. An unstamped (just-restored) host declines.
      local evt = index.colEvtFor(uuid)
      if evt and evt.fx then
        onTakeHost = index.byUuid(uuid)
        hostRegion = fxWindows.fromNote(evt,
                                        frame.clippedSpanEnd(evt, tm:toLogical(evt.chan, tm:length())))
      end
    end
  end
  -- One window-shaped record from here down: nothing below knows which host shape it froze.
  local frozen = region or hostRegion
  if not frozen then return false end
  -- Ownership by dest, not mode: a note-dest kind's output stands in for the host note, so freezing
  -- destroys it. A continuous-only chain leaves the note where it is.
  local destroysHost = hostRegion and generators.parksNotes(hostRegion)

  -- The windows the last rebuild published, gated before anything is gathered so a refusal leaves
  -- the pass having staged nothing. see docs/trackerManager.md § Fx window census
  local settled = windows.window(uuid)
  if not settled or freezeRefused(settled, windows) then return false end

  -- The frozen window per stream it parks: the group arm's two passes walk it -- the thin in the raw
  -- frame, the member gather in the logical one.
  local frozenEntries = windows.perTarget(settled)
  -- Coverage off the published set, narrowed to this uuid: the gate has refused every neighbour
  -- sharing a target inside this span, so whatever the set covers here it covers on our behalf.
  -- Never rebuildRegionPark's covered(): its first clause answers "does this spec park itself", true
  -- of every self-parked note host on the channel, and would take theirs too.
  local function covered(spec)
    return windows.owns(spec.evType, spec.chan, spec.cc, spec.ppq) == uuid
  end

  -- Gathered before staging: the assigns write the very index list this walks. `derived` is
  -- metadata, so each rides mm's lockless path; the note keeps its uuid, lane and detune.
  local promoted = {}
  for _, note in ipairs(index.raw(frozen.chan).notes) do
    if note.derived == uuid then util.add(promoted, note) end
  end
  for _, note in ipairs(promoted) do stager.assign(note, { derived = util.REMOVE }) end
  -- Captured before the flush: the rebuild that follows refiles these entries, and the uuid is what
  -- crosses it -- index.colEvtFor is the door back to the settled event.
  local promotedUuids = {}
  for _, note in ipairs(promoted) do util.add(promotedUuids, note.uuid) end
  -- The chain goes with the region form it stood for. A note-dest chain would have parked its
  -- host in the stash arm; an on-take host's is continuous-only, and index.move de-registers it, so nothing regenerates.
  if onTakeHost then stager.assign(onTakeHost, { fx = util.REMOVE }) end

  local droppedHosts = {}
  for _, spec in ipairs(stash) do
    if spec.evType == 'note' and covered(spec) then droppedHosts[spec.uuid] = true end
  end
  -- A note host parks no note window of its own, so window coverage cannot reach it:
  -- seeding it here is what carries its parked PAs along through hostDropped below.
  if hostSpec and destroysHost then droppedHosts[uuid] = true end
  -- A pa spec is anchored to a note spec, not to a window, so window coverage alone leaves it
  -- behind. Host resolution is hostParked's, over live render events.
  local function hostDropped(pa)
    for _, evt in ipairs(frame.channels[pa.chan].parked.notes or {}) do
      if evt.pitch == pa.pitch and pa.ppq >= evt.ppq and pa.ppq < evt.endppqC then
        return droppedHosts[evt.uuid] == true
      end
    end
    return false
  end
  for _, spec in ipairs(stash) do
    local drop = spec.evType == 'pa' and hostDropped(spec) or covered(spec)
    if hostSpec and spec.uuid == uuid then
      -- Freeze takes the chain, not the note: a host parked by another live region's note window stays
      -- parked, stripped, so nothing runs its chain over the frozen curve.
      if not destroysHost then util.add(keptParked, util.clone(spec, { fx = true })) end
    elseif not drop then util.add(keptParked, spec) end
  end

  -- By stamped id, not window value: a neighbouring host can hold a window identical to the
  -- frozen one, and identity keeps them apart. See docs/trackerManager.md § Fx window census.
  local realisedWindows, keptWindows = ds:get('fxRealisedWindows') or {}, {}
  for _, w in ipairs(realisedWindows) do
    if w.id ~= uuid then util.add(keptWindows, w) end
  end

  -- ds:get hands back a copy of its cache slot, so an emptied array reads back as a truthy {}:
  -- only the sentinel actually clears the key.
  local function replace(key, kept, prior)
    if util.deepEq(prior, kept) then return end
    ds:assign(key, next(kept) and kept or util.REMOVE)
  end
  suppressingRebuild(function()
    replace('fxParked',    keptParked,  stash)
    replace('fxRegions',   keptRegions, regions)
    replace('fxRealisedWindows', keptWindows, realisedWindows)
  end)

  -- Inside this same staging block, so the closing rebuild back-derives cents on the survivors alone.
  if toGroup then thinSeats(frozen.chan, frozenEntries) end

  dirt.add(frozen.chan, true)   -- freeze is rare and drastic: whole-channel dirt over per-member seeds
  -- A continuous-only or husk region stages no mm ops at all, and flush's no-op gate would swallow
  -- the pass; the request carries it past that and past rebuild(∅). Harmless when assigns staged.
  tm:requestRebuild()
  tm:flush()
  if not toGroup then return true end
  return groupMembers(frozen, frozenEntries, promotedUuids)
end

----- Mutation

function tm:deleteEvent(evt)         stager.delete(evt)         end
function tm:addEvent(evt)            stager.add(evt)            end
function tm:assignEvent(evt, update) stager.assign(evt, update) end
function tm:addParked(spec)           stager.addParked(spec)           end
function tm:assignParked(evt, update) stager.assignParked(evt, update) end
function tm:deleteParked(evt)         stager.deleteParked(evt)         end
--contract: one-way; the host's chain, its parked members and its windows are gone after the call
--contract: host = a live region, or a note (parked or on-take) carrying fx; else false
--contract: flushes any staged ops first, so the eligibility census reads a settled take
--contract: any refusal is silent: returns false, stages nothing of its own, raises nothing
--contract: refuses same-target overlap with a neighbour; abutting counts for pb, not cc/note
--contract: refuses a covered fx host, or a note-dest host under another host's note window
--contract: refuses a global region (chan 0): a view surface, running on no channel
function tm:freezeRegion(uuid)        return freezeRegion(uuid)  end
--contract: freezeRegion's conversion plus a bounded thin of each continuous stream, one flush
--contract: members are column events (authored frame, no ppqL) for gm:markGroup, else false
--contract: the take is settled on return; no part of the conversion is left for the caller's flush
function tm:freezeToGroup(uuid)       return freezeRegion(uuid, true) end
--contract: one-way; the stored global gives way to the hosts it expanded into, uuids kept
--contract: false, staging nothing, for a uuid naming anything but a stored chan-0 region
--contract: false for a chain reaching no channel; the expansion would be empty, losing the chain
--contract: flushes first, rebuilds once; the host list is unchanged, so no channel is dirtied
-- The expansion, persisted: the passes below the head snapshot read the very list they read before,
-- and the rebuild is for the maps keyed by the stored region. see docs/trackerManager.md § Channel & column model
function tm:explodeRegion(uuid)
  tm:flush()
  local region, channelRegions, otherGlobals = nil, {}, {}
  for _, r in ipairs(ds:get('fxRegions') or {}) do
    if r.uuid == uuid then region = r
    else util.add(r.chan == 0 and otherGlobals or channelRegions, r) end
  end
  if not (region and region.chan == 0) then return false end
  -- The channels the last rebuild expanded onto, which is what the strip ghosts: every expanded
  -- host is in its census, emitting or not, so the union answers for the whole set.
  local realisation = fxRealisationByUuid[uuid]
  local chans = realisation and realisation.chans or {}
  if #chans == 0 then return false end
  local inUse = {}
  for _, chan in ipairs(chans) do inUse[chan] = true end

  -- Stored where the expansion puts them -- after the channel regions, before any global still
  -- stored -- so precedence on every channel stands where it stood.
  local stored = channelRegions
  for _, r in ipairs(expandGlobals({ region }, inUse)) do util.add(stored, r) end
  for _, r in ipairs(otherGlobals) do util.add(stored, r) end
  suppressingRebuild(function() ds:assign('fxRegions', stored) end)
  tm:requestRebuild()   -- geometry only: nothing to re-derive, and the output maps still want rebuilding
  tm:flush()
  return true
end
--contract: reads the last rebuild's published windows; staged-not-flushed hosts are invisible
--contract: false for any uuid that is not a live host; never stages
function tm:freezeEligible(uuid)
  local frozen = windows.window(uuid)
  return frozen ~= nil and not freezeRefused(frozen, windows)
end
--contract: reads the last rebuild's settled census; never computes, never stages
--contract: nil for a uuid that hosts no chain; a host with no output gets empty streams
--contract: every member tm:freezeToGroup hands back lies inside the rect
-- A clone per call: gm:markGroup stores the rect by reference and tm replaces its map each rebuild.
function tm:freezeRect(uuid)          local r = freezeRectByUuid[uuid]; return r and util.deepClone(r) end
--contract: everything uuid's chain realised this rebuild; nil if uuid runs no chain
--contract: a stored global uuid answers with the union of the hosts it expanded into
--contract: notes = its derived onsets, logical-onset order (a ghost is one row: no tail rides)
--contract: parked = originals it stands in for; targets = its claimed pb/cc spans, logical framed
--contract: chans = the channels it realises on, ascending -- one for an ordinary host
--invariant: read-only; tm rebuilds the map each pass
function tm:fxRealisation(uuid)
  return uuid and fxRealisationByUuid[uuid] or nil
end
--contract: the host's realised value on target at ppqL; nil outside the spans it claimed
--contract: chan is the channel to read on -- a global chain realises on each of the ones it reaches
--contract: cents-minus-detune for pb, the value itself for cc; interpolated between seats
--invariant: read off the take, so a kept host's curve stands where a re-run one's does
function tm:fxCurveAt(uuid, chan, target, ppqL)
  local realisation = fxRealisationByUuid[uuid]
  local claimed = realisation and realisation.targets[target]
  if not claimed then return nil end
  local inside = false
  for _, span in ipairs(claimed) do
    if ppqL >= span[1] and ppqL < span[2] then inside = true; break end
  end
  if not inside then return nil end
  local ppq = tm:fromLogical(chan, ppqL, 0)
  -- Inside a window every event on the target is realisation: the authored curve parked to make way
  -- for it. So the seats are the take's own stream, read where it lies.
  local raw = index.raw(chan)
  local seats = target == 'pb' and raw.pbs or raw.ccs[target]
  if not seats or #seats == 0 then return nil end
  local val = curves.eval(seats, ppq)
  -- A pb seat's val is realisation, detune included -- the same subtraction the column projection makes.
  return target == 'pb' and val - index.detuneAt(chan, ppq) or val
end
--contract: an id no stored region holds and no earlier mint issued; the caller stores the region
-- The view authors regions, but the store the mint scans is tm's, and the parked stash mints beside it.
function tm:newFxRegionUuid() return newFxUuid('fxRegions') end

-- With no mm ops there is no reload->rebuild to ride, so the one rebuild is driven here.
function tm:flush() if stager.flush() then tm:rebuild(false) end end

----- Length

-- The document's logical time is not all on the take. Fx regions, the park stash and the realised
-- census hold spans of their own, so a length verb maps them through the same time map it maps the
-- events through. see docs/trackerManager.md § Length operations
local fxSpanKeys = { 'fxRegions', 'fxParked', 'fxRealisedWindows' }

--pre: keys name the stores the verb maps; one it omits stands as it is
--pre: mapSpan(ppq, endppq) -> the span's images in order; an empty list drops the record
--pre: mapSpan concretes no util.OPEN ceiling, an open tail being intent that no resize edits
--post: ds[key] := its mapped records, for each named key whose records the map changed
--post: the first image keeps the record's id and every later one mints its own
--post: a parked delay scales by slope, the map being linear across the span the verb rewrites
--invariant: the write is suppressed, so the caller's own flush drives the one rebuild that reads it
local function mapFxDocument(keys, mapSpan, slope)
  local writes = {}
  for _, key in ipairs(keys) do
    local stored, mapped = ds:get(key) or {}, {}
    for _, record in ipairs(stored) do
      for i, span in ipairs(mapSpan(record.ppq, record.endppq)) do
        local out = util.clone(record)
        out.ppq, out.endppq = span[1], span[2]
        if out.delay then out.delay = out.delay * slope end
        -- A copy is a new record: nothing links it to the one it came from, so its id is its own.
        if i > 1 and out.uuid then out.uuid = newFxUuid(key) end
        util.add(mapped, out)
      end
    end
    if not util.deepEq(stored, mapped) then writes[key] = mapped end
  end
  if not next(writes) then return end
  -- All sixteen: a length verb moves the whole document, and the regions' own dirt would otherwise
  -- come from the ds observer this write suppresses.
  dirt.add(nil, true)
  suppressingRebuild(function()
    for key, records in pairs(writes) do
      ds:assign(key, next(records) and records or util.REMOVE)
    end
  end)
end

-- On shrink, an OPEN ceiling is authored intent, not a casualty of resize: only the realised
-- tail clips to the new end. See docs/trackerManager.md § Length operations for the ordering.
--contract: a util.OPEN ceiling survives a shrink; only its realised tail comes down
function tm:setLength(newPpq)
  if not mm then return end
  local oldPpq = mm:length() or 0
  if newPpq < oldPpq then
    local kills, clamps = {}, {}
    forEachEvent(function(_, evt, _, isNote)
      if evt.ppq >= newPpq then
        util.add(kills, evt)
      elseif isNote and evt.endppq ~= util.OPEN and evt.endppq > newPpq then
        util.add(clamps, evt)
      end
    end)
    for _, evt in ipairs(kills)  do stager.delete(evt)                       end
    for _, evt in ipairs(clamps) do stager.assign(evt, { endppq = newPpq })  end
    -- The same verdict on the fx document: past the end it goes, astride the end it clips. A shrink
    -- is no scaling, so this is the one map that drops records.
    mapFxDocument(fxSpanKeys, function(ppq, endppq)
      if ppq >= newPpq          then return {}                 end
      if endppq == util.OPEN    then return { { ppq, endppq } } end
      return { { ppq, endppq and math.min(endppq, newPpq) } }
    end, 1)
    -- mm:setLength runs last, so the take is still long here: pendingLen is what tells the tail
    -- walk the new end. All-16 dirt because any channel may hold an OPEN tail spanning it.
    pendingLen = newPpq
    dirt.add(nil, true)
    tm:requestRebuild()   -- an OPEN-only shrink stages no mm ops; flush must rebuild regardless
    tm:flush()
    pendingLen = nil
  end
  if newPpq ~= oldPpq then mm:setLength(newPpq / mm:resolution()) end
end

-- Stretch take to newPpq: logical rows scale by f=newPpq/oldPpq, raw rederived through swing.
-- see docs/trackerManager.md § Length operations
function tm:rescaleLength(newPpq)
  if not mm then return end
  local oldPpq = mm:length() or 0
  if oldPpq <= 0 or newPpq == oldPpq then
    if newPpq ~= oldPpq then mm:setLength(newPpq / mm:resolution()) end
    return
  end
  local f = newPpq / oldPpq

  -- τ maps the column's logical ppq; raw re-derives through swing, and slopeAt scales delays for
  -- local realised stretch. Two passes so all reads are stable.
  local function applyTimeMap(tau, slopeAt)
    local plans = {}
    forEachEvent(function(_, evt, chan, isNote)
      local p = { evt = evt }
      p.newPpqL = tau(evt.ppq)
      p.newPpq  = tm:fromLogical(chan, p.newPpqL)
      if isNote then
        p.newEndppqL = tau(evt.endppq)
        p.newEndppq  = tm:fromLogical(chan, p.newEndppqL)
        if evt.delay and evt.delay ~= 0 then
          p.newDelay = slopeAt(evt.ppq) * evt.delay
        end
      end
      util.add(plans, p)
    end)
    for _, p in ipairs(plans) do
      stager.assign(p.evt, {
        ppq      = p.newPpq,
        endppq   = p.newEndppq,
        delay    = p.newDelay,
        ppqL     = p.newPpqL,
        endppqL  = p.newEndppqL,
        rawTime  = true,
      })
    end
    tm:flush()
  end

  -- The fx document first, so the rebuild inside applyTimeMap's flush derives from the scaled spans.
  mapFxDocument(fxSpanKeys, function(ppq, endppq) return { { f * ppq, endppq and f * endppq } } end, f)
  applyTimeMap(function(t) return f * t end, function() return f end)
  mm:setLength(newPpq / mm:resolution())
end

-- Loop [0, oldPpq) at offsets k·oldPpq to fill newPpq; shrinks fall through to setLength.
-- see docs/trackerManager.md § Length operations
function tm:tileLength(newPpq)
  if not mm then return end
  local oldPpq = mm:length() or 0
  if oldPpq <= 0 or newPpq <= oldPpq then return self:setLength(newPpq) end

  -- Authored events only: a copy tiles the intent and the copied regions derive their own output.
  -- Copying realisation too would stand it alongside what the region it lands in derives.
  local function snapshot(iter)
    local out = {}
    for _, evt in iter do
      if evt.ppq < oldPpq and not evt.derived then
        local c = util.clone(evt, { uuid = true })
        util.add(out, c)
      end
    end
    return out
  end
  local sourceEvents = snapshot(mm:events())

  mm:setLength(newPpq / mm:resolution())

  -- Regions and parked hosts loop too; the census does not.
  -- See docs/trackerManager.md § tileLength for why.
  mapFxDocument({ 'fxRegions', 'fxParked' }, function(ppq, endppq)
    local function ceilingAt(delta)
      if not endppq or endppq == util.OPEN then return endppq end
      return math.min(endppq + delta, newPpq)
    end
    local images = {}
    for k = 0, math.ceil(newPpq / oldPpq) - 1 do
      local delta = k * oldPpq
      if ppq + delta >= newPpq then break end
      util.add(images, { ppq + delta, ceilingAt(delta) })
    end
    return images
  end, 1)

  local function shift(c, delta)
    c.ppq = c.ppq + delta
    if c.ppqL    then c.ppqL    = c.ppqL    + delta end
    if c.ppq >= newPpq then return false end
    if c.evType == 'note' then
      c.endppq = c.endppq + delta
      if c.endppqL then c.endppqL = c.endppqL + delta end
      if c.endppq > newPpq then c.endppq, c.endppqL = newPpq, nil end
    end
    return true
  end

  mm:modify(function()
    for k = 1, math.ceil(newPpq / oldPpq) - 1 do
      local delta = k * oldPpq
      for _, src in ipairs(sourceEvents) do
        local c = util.clone(src)
        if shift(c, delta) then index.sync(mm:add(c)) end
      end
    end
  end)
end

----- Transport

function tm:playFrom(ppq)
  if not (mm and mm:take()) then return end
  reaper.SetEditCurPos(reaper.MIDI_GetProjTimeFromPPQPos(mm:take(), ppq), false, false)
  reaper.Main_OnCommand(1007, 0)
end

function tm:play()      reaper.Main_OnCommand(1007,  0) end
function tm:stop()      reaper.Main_OnCommand(1016,  0) end
function tm:playPause() reaper.Main_OnCommand(40073, 0) end

----- Mute

--contract: sweeps only chans with a mute delta or rebuild dirt; assign only when n.muted differs
--invariant: lastMuteSet also tags later-added notes (add path stamps muted at insert)
--invariant: PA events ride along in note columns but carry no mute state — skipped
function tm:setMutedChannels(set)
  local prev = lastMuteSet
  lastMuteSet = util.clone(set or {})
  local sweep = muteConform; muteConform = {}
  for chan = 1, 16 do
    if (prev[chan] == true) ~= (lastMuteSet[chan] == true) then sweep[chan] = true end
  end
  for chan in pairs(sweep) do
    local channel = frame.channels[chan]
    local want = lastMuteSet[chan] == true
    for _, col in ipairs(channel and channel.onTake.notes or {}) do
      for _, evt in ipairs(col.events) do
        if evt.evType ~= 'pa' and (evt.muted == true) ~= want then
          stager.assign(evt, { muted = want })
        end
      end
    end
  end
  tm:flush()
end

---------- REBUILD

-- The derivation engine, instantiated with the structures the two files share. It is the frame's only
-- writer, and the index's between edits. see docs/trackerManager.md § Rebuild
local rebuild = util.instantiate('trackerRebuild', {
  mm = mm, cm = cm, ds = ds, defaultNoteCols = defaultNoteCols,
  index = index, stager = stager, dirt = dirt, frame = frame,
})

----- Rebuild

local rebuilding = false
-- mm:reload wholesale-replaces the event set (take swap / external re-read), stranding the
-- incremental index; full-reloads when set, else keeps it. see docs § Incremental index reconciliation
local mmReloaded = false

-- The channels a global chain reaches: those carrying an authored note, a note the park stash holds
-- off the take, or a pb/cc lane of their own. Derived output is no evidence -- it never leaves the set. see docs/trackerManager.md § Channel & column model
local function channelsInUse(sources)
  local inUse = {}
  for chan = 1, 16 do
    for _, note in ipairs(index.raw(chan).notes) do
      if not note.derived then inUse[chan] = true; break end
    end
  end
  for _, spec in ipairs(sources.fxParked or {}) do inUse[spec.chan] = true end
  for chan, want in pairs(sources.extraColumns or {}) do
    if want.pb or want.at or want.pc or next(want.ccs or {}) then inUse[chan] = true end
  end
  for chan, lanes in pairs(sources.paramAutomation or {}) do
    if next(lanes) then inUse[chan] = true end
  end
  return inUse
end

--contract: reentrancy-guarded; rebuilds channels[] from mm, reloads um cache, fires 'rebuild'
--contract: takeChanged forwarded to subscribers via the captured pendingTakeSwap
--contract: dead take (mm:take() nil) is a no-op; tv retains its last frame
--invariant: rebuild(∅) (no dirt/stale swing/reload/takeChanged/request) short-circuits pre-nest
-- see docs/trackerManager.md § Rebuild
function tm:rebuild(takeChanged)
  if rebuilding then return end
  if not mm:take() then return end
  takeChanged = takeChanged or false
  -- rebuild(∅) does literally nothing: with no dirt, clean swing, no wholesale re-read, no
  -- take swap and no force, every stage would converge to the carried frame -- skip it all.
  if not (takeChanged or mmReloaded or rebuildRequested or dirt.pending()) then return end
  rebuildRequested = false
  rebuilding = true
  -- Capture before the pipeline's nested mm:modify calls re-fire 'reload' and clear it.
  local didReload = mmReloaded; mmReloaded = false
  -- Wholesale re-read / take swap: fxRealisedWindows (dataStore) carries the recognition baseline, and the
  -- take-tier caches go, since their uuid keys address the take just left.
  if didReload or takeChanged then dirt.add(nil, true); rebuild.forget() end
  pbLimCache = nil   -- coherence point: refresh cached pbRange for cents<->raw conversions

  local prevLength = timeContext:length()   -- rebuild is the (cm, mm) coherence point
  timeContext = newTimeContext()
  -- A composite's ramps run to the take's end, so a length change re-times every seat near it.
  -- Unmarked, the rebuild rule reads that as an external raw edit. see docs/timing.md § Reswing
  if not takeChanged and timeContext:length() ~= prevLength then dirt.swing.add(nil) end
  -- Carry each clean channel's whole frame forward (B1): re-deriving it is waste, and every
  -- gated stage below skips clean chans so the carried columns stand.
  local prevChannels = frame.newPass()
  for i = 1, 16 do
    -- Parked events are off-take and only the park stage rewrites them, so a wholesale mm re-read has
    -- no claim: all four streams carry forward, lists and all. See § Lane occupancy.
    local prev   = prevChannels[i]
    local parked = prev and prev.parked or { notes = {}, ccs = {}, pb = {}, pa = {} }
    if dirt.wholesale(i) then
      frame.channels[i] = { chan = i, onTake = { notes = {}, ccs = {} }, parked = parked }
    elseif dirt.has(i) then
      -- Interval dirt carries note AND cc/at/pc columns; both splice just their seeded events. Park and
      -- pb still want the fresh channel; priorPb feeds the kept-range carry. see design § phase 3
      local prevOnTake = prev.onTake
      frame.channels[i] = { chan = i, onTake = { notes = prevOnTake.notes, ccs = prevOnTake.ccs,
                                                 at = prevOnTake.at, pc = prevOnTake.pc },
                            priorPb = prevOnTake.pb, parked = parked }
    else
      frame.channels[i] = prev
    end
  end

  -- A wholesale mm re-read strands the incremental index: reload before the snapshot reads it, and
  -- the pass's own commits maintain it from there. see docs § Incremental index reconciliation
  if didReload then perf.start('reload'); stager.reload(); perf.stop('reload') end

  -- One head snapshot of the ds intent keys the pass reads, its regions already expanded to
  -- per-channel hosts against the channels in use. see docs § Channel & column model
  local sources = {
    fxParked          = ds:get('fxParked'),
    fxRealisedWindows = ds:get('fxRealisedWindows'),
    extraColumns      = ds:get('extraColumns'),
    paramAutomation   = ds:get('paramAutomation'),
  }
  sources.fxRegions, sources.globalRegions =
    expandGlobals(ds:get('fxRegions'), channelsInUse(sources))

  -- One nest for every staging stage, so the reindex and the take reprojection land once each
  -- rather than once per stage. rebuilding must outlive it: each stage's commit re-enters via 'reload'.
  local maps
  mm:batch(function() maps = rebuild.pipeline(sources, timeContext) end)
  -- Install what the pass created. Nothing reads these mid-pass, and the accessors read between
  -- rebuilds, so they stand before the signal goes out.
  windows, freezeRectByUuid, fxRealisationByUuid =
    maps.windows, maps.freezeRect, maps.fxRealisation
  for chan in pairs(maps.conform) do muteConform[chan] = true end
  perf.start('derivedInputs')
  derivedInputs = derivationInputs()   -- after the pass's own ds writes have settled
  perf.stop('derivedInputs')
  rebuilding = false

  --emits: rebuild -- takeChanged:boolean
  --contract: rebuild fires at end of every non-degenerate rebuild after the um cache is reloaded
  --invariant: takeChanged is true only when rebuild followed bindTake; signals take-tier reload
  perf.start('fire'); fire('rebuild', takeChanged); perf.stop('fire')
end

----- Lifecycle

do
  --invariant: tvOnlyKeys skip the configChanged rebuild; neither key feeds a derivation
  local tvOnlyKeys = { defaultSwing = true, fxPatches = true }

  --invariant: dataChanged 'swing' → global change marks all 16, else only the diffed channels
  --invariant: configChanged 'swings' → channels resolving to names with diff body vs prevSwings
  --invariant: prev*-caches refresh after each event and on bindTake
  -- Merged-tier read: a save at any tier lands in the same merged view, so diff
  -- captures real change to the composite a channel will resolve to.
  local function readSwings() return cm:get('swings', { mergeTiers = true }) end
  local prevSwings = readSwings()
  local prevSwing  = ds:get('swing') or {}

  local function snapshotSwingState()
    prevSwings = readSwings()
    prevSwing  = ds:get('swing') or {}
  end

  local function swingChannelDiff(prev, cur)
    prev, cur = prev or {}, cur or {}
    local affected = {}
    for chan = 1, 16 do
      if prev[chan] ~= cur[chan] then affected[chan] = true end
    end
    return affected
  end

  local function changedSwingNames(prev, cur)
    prev, cur = prev or {}, cur or {}
    local names = {}
    for name, body in pairs(prev) do
      if not util.deepEq(body, cur[name]) then names[name] = true end
    end
    for name in pairs(cur) do
      if prev[name] == nil then names[name] = true end
    end
    return names
  end

  -- Global swing shadows the per-channel slots: a hit on the global name affects all 16.
  local function channelsResolvingTo(names)
    local affected = {}
    if not next(names) then return affected end
    local sw = ds:get('swing') or {}
    if names[sw.global] then
      for chan = 1, 16 do affected[chan] = true end
      return affected
    end
    for chan = 1, 16 do
      if names[sw[chan]] then affected[chan] = true end
    end
    return affected
  end

  -- True between cm:setContext and mm:load in bindTake; suppresses the
  -- configChanged rebuild so mm:load fires the single coherent one.
  local bindingTake = false
  local pendingTakeSwap = false

  tm:forward('notesDeduped',    mm)
  tm:forward('uuidsReassigned', mm)
  tm:forward('takeSwapped',     mm)
  -- mm's backstop repaired a missed same-pitch collision: re-key um surgically. No
  -- tm:rebuild here (re-enters mm:modify mid-unwind); geometry trues up next rebuild.
  mm:subscribe('collisionsResolved', function(info)
    for _, e in ipairs(info.events) do index.sync(e.uuid) end
  end)
  mm:subscribe('takeSwapped', function() pendingTakeSwap = true end)
  mm:subscribe('reload', function(info)
    mmReloaded = (info and info.wholesale) or false
    -- Own pipeline commits are converged output, not dirt (I8).
    if not rebuilding and info and info.chans then
      stager.flushDirt(info.chans)
    end
    tm:rebuild(pendingTakeSwap)
    pendingTakeSwap = false
  end)
  -- Skip configChanged while dormant (cm unbound, mm/cm mismatch): the rebind diffs derivationInputs
  -- rather than replaying what it missed. see docs/trackerManager.md § Dormant guard
  cm:subscribe('configChanged', function(change)
    if bindingTake or not cm:boundTake() then return end
    local key = change.key
    if key == 'swings' then
      local curSwings = readSwings()
      for chan in pairs(channelsResolvingTo(changedSwingNames(prevSwings, curSwings))) do
        tm:markSwingStale(chan)
      end
      prevSwings = curSwings
    elseif not tvOnlyKeys[key] then
      -- temper reaches no derivation, but tv's context snapshot rides tm's rebuild signal, so a
      -- notation change comes through here to refresh the lens rather than to re-derive anything.
      dirt.add(nil, true)   -- any other derivation config (pbRange/ccInterp/overlapOffset) re-derives all chans
    end
    if not tvOnlyKeys[key] then tm:rebuild(false) end
  end)

  -- swing/extraColumns/noteDelay/fxRegions are document data: edits + undo rewinds
  -- arrive as dataChanged. swing diffs its map; the rest force a full rebuild.
  ds:subscribe('dataChanged', function(change)
    -- Pipeline's own ds:assigns during rebuild (fxParked/extraColumns) are converged
    -- output, not edits; re-entering marks all 16 dirty and breaks B1.
    if rebuilding then return end
    if bindingTake or not cm:boundTake() then return end
    if change.name == 'swing' then
      local cur = ds:get('swing') or {}
      if cur.global ~= prevSwing.global then
        tm:markSwingStale(nil)
      else
        for chan in pairs(swingChannelDiff(prevSwing, cur)) do tm:markSwingStale(chan) end
      end
      prevSwing = cur
      tm:rebuild(false)
    elseif change.name == 'fxRegions' then
      -- Region edits seed only the changed regions' channels; unchanged channels freeze. see § Route-by-window
      if not flushingParked then seedRegionEdit(ds:get('fxRegions')); tm:rebuild(false) end
    elseif change.name == 'fxParked' then
      -- parking drives fx expansion + the pb keep-decision; seed only the changed members.
      if not flushingParked then seedParkedEdit(ds:get('fxParked')); tm:rebuild(false) end
    elseif change.name == 'extraColumns' or change.name == 'paramAutomation' then
      -- extraColumns is grow-only/merge-safe, not parking -- a whole re-derive stays. see design § phase 3
      -- A binding shapes columns the same way, so bind/unbind (and its undo) arrives here too.
      if not flushingParked then dirt.add(nil, true); tm:rebuild(false) end
    elseif change.name == 'noteDelay' then
      -- noteDelay is a display offset -- nothing in the tm pipeline reads it; reproject only,
      -- forced past the rebuild(∅) gate since it seeds no dirt.
      if not flushingParked then tm:requestRebuild(); tm:rebuild(false) end
    end
  end)

  ----- Anticipative-FX guard (see docs/trackerManager.md § Anticipative-FX guard)
  local function trackByGuid(guid)
    for i = 0, reaper.CountTracks(0) - 1 do
      local tr = reaper.GetTrack(0, i)
      if reaper.GetTrackGUID(tr) == guid then return tr end
    end
  end

  local function guardTrack(track)
    if not track then return end
    local flags = math.floor(reaper.GetMediaTrackInfo_Value(track, 'I_PERFFLAGS'))
    ds:assign('guardedTrack', { guid = reaper.GetTrackGUID(track), flags = flags })
    reaper.SetMediaTrackInfo_Value(track, 'I_PERFFLAGS', flags | 2)
  end

  --contract: restores the guarded track's prior I_PERFFLAGS, clears the record; no-op if none
  function tm:restoreGuarded()
    local g = ds:get('guardedTrack')
    if not g then return end
    local track = trackByGuid(g.guid)
    if track then reaper.SetMediaTrackInfo_Value(track, 'I_PERFFLAGS', g.flags) end
    ds:delete('guardedTrack')
  end

  --contract: atomic take swap: cm:setContext runs silently; mm:load fires the coherent rebuild
  --contract: opts.trackerMode (wiring-derived) seeds trackerMode under the same suppression window
  --contract: opts.markSwingStale=true rebuilds raw from ppqL under new (cm, mm) (seqMgr:reswingAll)
  --contract: bindTake(nil) is the dormant seam (e.g. samplePage)
  --contract: opts.skipGuard skips restore/guardTrack; mini stacks never touch the shared guard
  --invariant: bindTake(nil): cm clears under suppression; mm:load(nil) no-op; tm/tv keep last frame
  function tm:bindTake(take, opts)
    local skipGuard = opts and opts.skipGuard
    if not skipGuard then tm:restoreGuarded() end
    bindingTake = true
    cm:setContext(take)
    if take then cm:set('transient', 'trackerMode', (opts and opts.trackerMode) or false) end
    bindingTake = false
    if opts and opts.markSwingStale then dirt.swing.add(nil) end
    -- Nothing above marked dirt (cm ran suppressed), and the converged gate in mm:load no longer
    -- blanket-dirties a rebind. Whatever changed unheard -- an undo of the take's swing, a wiring
    -- flip re-seeding trackerMode -- shows up here as a diff. markSwingStale covers dirt AND reseat.
    if take and not util.deepEq(derivationInputs(), derivedInputs or {}) then tm:markSwingStale(nil) end
    mm:load(take)
    if take and not skipGuard then guardTrack(reaper.GetMediaItemTake_Track(take)) end
    snapshotSwingState()
  end

  --contract: take died under us — nils mm.take so tm:currentTake reads nil; not bindTake(nil) seam
  function tm:detach()
    tm:restoreGuarded()
    bindingTake = true
    cm:setContext(nil)
    bindingTake = false
    mm:unload()
  end

  function tm:currentTake() return mm and mm:take() end

  --contract: re-reads the bound take from REAPER; mm:reload fires standard reload→rebuild
  --invariant: reloadFromReaper does not swap take; for coord's external-mutation watcher
  function tm:reloadFromReaper() if mm then mm:reload() end end
end

tm:restoreGuarded()
tm:rebuild(true)
return tm
