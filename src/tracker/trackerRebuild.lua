-- The derivation engine: one gated pass that reconstructs intent from mm, then reauthors raw from it.
-- See docs/trackerManager.md § Rebuild for the model.

--invariant: the frame, the raw index and the stager are the engine's alone to write during a pass
--invariant: the pass's time context is handed in; the engine builds no projection of its own

local util    = require 'util'
local spans   = require 'spans'
local curves  = require 'curves'
local timing  = require 'timing'
local voicing = require 'voicing'
local tuning  = require 'tuning'

local generators = require 'generators'
local perf       = require 'perf'
local fxWindows  = require 'fxWindows'

local mm, cm, ds = (...).mm, (...).cm, (...).ds
-- Forced note columns per channel absent an extraColumns entry; tm resolves the default.
local defaultNoteCols = (...).defaultNoteCols
-- The structures the two files share, each with its own owner: tm keeps them true across edits and
-- the engine is their only mid-pass writer. see docs/trackerManager.md § The frame handle
local index, stager, dirt, frame = (...).index, (...).stager, (...).dirt, (...).frame

local rebuild = {}

local function delayToPPQ(delay) return timing.delayToPPQ(delay, mm:resolution()) end

-- The one map that outlives a pass: the fx stage writes only the channels it ran, keyed by host, so
-- the overlay draws one chain's own. Its lists are built from copies of the fx specs.
--shape: fxNotesByHost[chan][uuid] = { { evType='note', chan, lane, ppq, pitch, vel, detune, delay, derived, [intentCents] }, ... }
--   ppq is the logical onset; derived is the producing region/host uuid; logical-onset order
local fxNotesByHost = {}

----- Rebuild shared helpers

-- ppq tolerance for "raw agrees with its logical projection"; absorbs
-- fromLogical rounding slop, shared by the tail pass and rebuild rule.
local EPS         = 1

-- CCINTERP is interpolated points per QN; the densify grid wants a tick step.
local function ccGridStep()
  return math.max(1, util.round((mm:resolution() or 960) / mm:ccInterp()))
end

-- Onset-membership cover of a ppq-sorted list against disjoint ascending spans: emit each event whose
-- onset falls in [lo, hi). The fx-path rule -- visit window extents, never the whole channel.
local function coverOnsets(events, spanSet, emit)
  for _, span in ipairs(spanSet or {}) do
    for i = util.firstAtOrAfter(events, span[1]), #events do
      local evt = events[i]
      if evt.ppq >= span[2] then break end
      emit(evt)
    end
  end
end

local clipEnd
do
  -- uuid -> clipped span end (logical); take-scoped, dropped by forgetCaches at the take-tier seam,
  -- which a take-length change (mm:setLength) reaches too.
  local cache = {}

  -- One clip cache, shared by on-take hosts and parked events; reclips on wholesale dirt, a seed
  -- naming the event, or a seed ppq inside its cached span. See docs/trackerManager.md § Lane occupancy.
  --contract: always the true clip; the cache is this function's alone to read and write
  function clipEnd(evt, takeLenL)
    local seeds, cached = dirt.has(evt.chan), cache[evt.uuid]
    if cached and seeds ~= true then
      local stands = true
      for _, s in ipairs(seeds or {}) do
        if s.uuid == evt.uuid or (s.ppqL and s.ppqL >= evt.ppq and s.ppqL <= cached) then
          stands = false; break
        end
      end
      if stands then return cached end
    end
    local clipped = frame.clippedSpanEnd(evt, takeLenL)
    cache[evt.uuid] = clipped
    return clipped
  end

  --post: the take-tier clip cache is empty
  function rebuild.forget() cache = {} end
end

local function pushNoteCol(channel)
  local notes = channel.onTake.notes
  return util.add(notes, { events = {} }), #notes
end

-- Column events keep chan/cc so each event is self-describing (the leaf-edit
-- facade resolves an event's column from its own chan + lane/cc; see trackerView).
local function projectCC(cc, overlay)
  local evt = util.clone(cc)
  evt.realised = true
  if overlay then util.assign(evt, overlay) end
  return evt
end

-- Columns are logical-born: each build site flips its events with this as it seats them; the
-- tail walk re-stamps movers' delayC/endppqC. see docs/trackerManager.md § Logical projection
--contract: every column event arrives stamped -- CC walk anchors foreign cc; externals, notes
local function projectEvent(evt, chan, time)
  if evt.ppqL ~= nil then
    -- delayC: realised-frame delay equivalent. Differs from authored delay when
    -- the unified walk clamped raw against a same-pitch predecessor; renderer cues the give-way.
    if evt.delay ~= nil then
      local baseline = time:fromLogical(chan, evt.ppqL)
      evt.delayC = util.round(timing.ppqToDelay(evt.ppq - baseline, mm:resolution()))
    end
    evt.ppq = evt.ppqL
  end
  if evt.endppq ~= nil then
    evt.endppqC = time:toLogical(chan, evt.endppq)
    if evt.endppqL == util.OPEN then
      evt.endppq = util.OPEN
    elseif evt.endppqL ~= nil then
      evt.endppq = evt.endppqL
    else
      evt.endppq = evt.endppqC
    end
  end
  -- The sidecar rode in on the mm event; drop it, or a stale copy of the frame we just
  -- became would ride out through park / clipboard / gm. mm and um's index keep theirs.
  evt.ppqL, evt.endppqL = nil, nil
end

-- Accumulate mm ops, commit once in canonical delete -> assign -> add order; no-op if empty.
local function mmBatch()
  local dels, assigns, adds = {}, {}, {}
  return {
    del     = function(evt)                util.add(dels, evt) end,
    assign  = function(evt, update)        util.add(assigns, { evt = evt, update = update }) end,
    add     = function(spec)               util.add(adds, spec) end,
    commit  = function()
      if #dels + #assigns + #adds == 0 then return end
      local touched = {}
      perf.start('batchModify')
      mm:modify(function()
        for _, e in ipairs(dels) do mm:delete(e.uuid); touched[e.uuid] = true end
        for _, a in ipairs(assigns) do
          mm:assign(a.evt.uuid, a.update)
          touched[a.evt.uuid] = true
        end
        for _, s in ipairs(adds) do local u = mm:add(s); if u then touched[u] = true end end
      end)
      perf.stop('batchModify')
      perf.start('batchIdx')
      local n = 0
      index.withDeferredSort(function()
        for uuid in pairs(touched) do index.sync(uuid); n = n + 1 end
      end)
      perf.count('reconciled', n)
      perf.stop('batchIdx')
    end,
  }
end

-- True when raw ppq can't be explained by the logical projection: foreign MIDI (no ppqL) or
-- an external raw edit. Swing-stale chans return false -- their divergence is an expected reseat.
local function rawDivergesFromLogical(evt, time)
  if evt.ppqL == nil          then return true  end
  if dirt.swing.has(evt.chan) then return false end
  local delayPpq = evt.evType == 'note' and delayToPPQ(evt.delay or 0) or 0
  local rawFromLogical = time:fromLogical(evt.chan, evt.ppqL, delayPpq)
  if evt.ppq == 0 and rawFromLogical < 0 then return false end
  return math.abs(evt.ppq - rawFromLogical) > EPS
end

-- 16 per-channel buckets, all empty; consumers index [chan] directly, so every slot must exist.
local function emptyChans()
  local t = {}
  for i = 1, 16 do t[i] = {} end
  return t
end

----- Derived-event reconcile skeleton (R2)
-- Index existing by `key`, keep-on-match, add the rest, remove unkept. The absorber pass is a richer fungible-move variant, inline.
--contract: appends unmatched-existing to sink.del(event), new/made specs to sink.add(spec)
local function reconcileDerived(a)
  local byKey, kept = {}, {}
  for _, e in ipairs(a.existing) do byKey[a.key(e)] = e end
  for _, spec in ipairs(a.predicted) do
    local have = byKey[a.key(spec)]
    if have and (not a.match or a.match(have, spec)) then
      kept[have] = true
      if a.onKeep then a.onKeep(spec, have) end
    else
      a.sink.add(a.make and a.make(spec) or spec)
    end
  end
  for _, e in ipairs(a.existing) do
    if not kept[e] then a.sink.del(e) end
  end
end

----- PC synthesis reconciliation (grouping + lane-winner pre-pass, then the skeleton)

-- Half-open span membership, frame-matched: projected column events always test logical --
-- projectEvent flips their ppq to ppqL and drops the sidecar; mm-frame records test raw.
local function pcInSpans(seedSpans, ppq, logical)
  for _, s in ipairs(seedSpans) do
    local lo, hi = logical and s.sL or s.sRaw, logical and s.eL or s.eRaw
    if ppq >= lo and ppq < hi then return true end
  end
  return false
end

--contract: synthesised PCs carry derived='pc'; ppqL inherited from winning host-note record
--contract: an existing derived PC matching (ppq, val) is kept, preserving mm-side loc
--contract: appends removals/adds to the sink {del(event), add(spec)}
--contract: marks sampleShadowed=true on the event or the spec of records lost to lane priority
--contract: seedSpans (from pcSeedSpans) narrow existing to in-span events; nil = whole channel
--invariant: seated marks via setEvent; off-take direct; no lane renews an event it lacks
--invariant: c.pc.events not written here; rebuildPCs splices it from mm after commit
local function reconcilePCsForChan(chan, records, sink, seedSpans)
  local existing = {}
  for _, e in ipairs((frame.channels[chan].onTake.pc and frame.channels[chan].onTake.pc.events) or {}) do
    if not seedSpans or pcInSpans(seedSpans, e.ppq, true) then util.add(existing, e) end
  end

  local groups = {}
  for _, r in ipairs(records) do util.bucket(groups, r.ppq, r) end

  local winners = {}
  for _, g in pairs(groups) do
    table.sort(g, function(a, b) return a.lane < b.lane end)
    util.add(winners, g[1])
    for i = 2, #g do
      local lost = g[i]
      -- A seated record marks through its column event. An off-take fx spec holds no event, and
      -- setEvent would renew the lane its number names without that lane's contents having moved.
      if lost.evt then frame.setEvent(lost.evt, 'sampleShadowed', true)
      elseif lost.spec then lost.spec.sampleShadowed = true end
    end
  end

  reconcileDerived{
    existing = existing, predicted = winners, sink = sink,
    key   = function(x) return x.ppq end,
    match = function(have, w) return have.derived and have.val == w.sample end,
    make  = function(w) return { ppq = w.ppq, ppqL = w.ppqL, val = w.sample,
                                 evType = 'pc', chan = chan, derived = 'pc' } end,
  }
end

----- fxNote reconciliation (the PC-synthesis skeleton, note-shaped)

-- Identity is geometry and the name it carries: (host, ppq, endppqL, pitch, vel, detune, sample,
-- intentCents); stale endppqL still matches (tail-walk-owned end stays out). A rename with no pitch move leaves every other field the same, so keying the intent is what lets the reconcile see it.
local function fxKey(spec)
  return util.key(spec.derived, spec.ppq, spec.endppqL or 0,
                  spec.pitch, spec.vel, spec.detune or 0, spec.sample or 0, spec.intentCents)
end

-- onKeep carries the matched note's mm handle + realised end onto the predicted spec, so a
-- kept fxNote is re-clipped in place by the tail walk rather than re-added.
local function reconcileFx(existing, predicted, sink)
  reconcileDerived{ existing = existing, predicted = predicted, key = fxKey, sink = sink,
    onKeep = function(spec, have)
      spec.uuid, spec.realised, spec.endppq = have.uuid, have.realised, have.endppq
    end }
end

----- Rebuild internals

-- (ppqL, lane, pitch) names a seat uniquely -- a lane holds one note per logical row. Delay shifts
-- raw ppq but not ppqL, so the logical seat is the stable key. Shared with the tail walk.
local function seatKey(ppqL, lane, pitch)
  return tostring(ppqL) .. '\0' .. tostring(lane) .. '\0' .. tostring(pitch)
end

-- The seeds' dirty logical rows as a flat list (snapshot ppqL ∪ each survivor's live ppqL): the one
-- derivation of what the dirt covers, so no consumer of it can drift. see design § phase 5
local function seedRowsFor(seedList)
  local rows = {}
  for _, s in ipairs(seedList) do
    util.add(rows, s.ppqL)
    local live = s.uuid and index.byUuid(s.uuid)
    if live then util.add(rows, live.ppqL or live.ppq) end
  end
  return rows
end

-- Seed membership by logical row -- same ppqL any lane, so a deleted shadower re-materialises its
-- row. The fx host query wants the same rows as a range test. see docs § Interval materialisation
local function seedCovers(chan)
  if dirt.wholesale(chan) then return function() return true end end
  local rows = {}
  for _, row in ipairs(seedRowsFor(dirt.has(chan))) do rows[row] = true end
  return function(note) return rows[note.ppqL or note.ppq] or false end
end
local function windowSeeded(rows, startL, endL)
  for _, row in ipairs(rows) do if row >= startL and row <= endL then return true end end
  return false
end

-- Drop the events the seeded rows claim from a channel's note lanes: a seek per row per lane, not a
-- channel scan; `claims` refines within the cluster. see docs/trackerManager.md § The note-lane shed
--invariant: a seated event is projected (ppq == ppqL), so a seed row is the lane's sort key
local function exciseNotes(chan, rows, claims)
  for _, col in ipairs(frame.channels[chan].onTake.notes) do
    local events = col.events
    local dropAt
    for _, row in ipairs(rows) do
      for i = util.firstAtOrAfter(events, row), #events do
        local evt = events[i]
        if evt.ppq ~= row then break end
        if not claims or claims(evt) then
          dropAt = dropAt or {}
          dropAt[i] = true
        end
      end
    end
    if dropAt then
      local kept = {}
      for i, evt in ipairs(events) do
        if not dropAt[i] then util.add(kept, evt) end
      end
      col.events = kept   -- kept is a fresh table: this assignment is the renewal
      frame.markRenewed(col)
    end
  end
end

-- Partition mm notes stamped/external, lay internal columns logical-born, reseat stale-swing.
-- Returns external notes + the per-channel derived-note existing set. see docs/trackerManager.md § Partition and internal lanes
--contract: interval dirt: non-derived notes carry ppqL -- an external mutation reloads wholesale
local function rebuildInternals(time)
  local internal, external = {}, {}
  local noteExisting = emptyChans()
  -- Clean channels carry their columns whole: never visited, so never cloned. Interval-dirty ones
  -- excise the seeded points and re-clone just those; the rest of the column carries untouched.
  for chan = 1, 16 do
    if dirt.has(chan) then
      local covers = seedCovers(chan)
      if not dirt.wholesale(chan) then exciseNotes(chan, seedRowsFor(dirt.has(chan))) end
      for _, raw in mm:notesRaw(chan) do
        -- Derived notes route to fx whole-channel whatever the dirt: a partial noteExisting
        -- reads as mass deletion until the fx reconcile goes interval-native. see design § phase 3
        if raw.derived then
          local note = util.clone(raw, { loc = true }); note.realised = true
          util.add(noteExisting[chan], note)
        elseif covers(raw) then
          local note = util.clone(raw, { loc = true }); note.realised = true
          if rawDivergesFromLogical(note, time) then util.add(external, note)
          else util.add(internal, note)
          end
        end
      end
    end
  end

  local reseats   = mmBatch()
  local builtCols = {}   -- lanes built by append this pass; ordered once at loop end, splices stay ordered
  -- note is already our own mm:notes() clone -- repurpose it as the column note rather than
  -- cloning again. mm's stored note is untouched.
  for _, note in ipairs(internal) do
    local channel = frame.channels[note.chan]
    local notes = channel.onTake.notes
    -- Stamped notes keep their authored lane verbatim (extended if missing);
    -- the tail walk clips tails afterward, so overlap here is never a concern.
    while #notes < note.lane do pushNoteCol(channel) end
    local col = notes[note.lane]
    -- set detune/delay at ingestion to skip defensive guards downstream
    note.detune = note.detune or 0
    note.delay  = note.delay  or 0
    if dirt.swing.has(note.chan) then
      -- Rederive realised onset from logical; endppq is the tail walk's. Reswing can collapse two
      -- distinct-ppqL same-pitch notes onto one raw -- staged to mm; the walk separates it this pass.
      local reswungPpq = time:fromLogical(note.chan, note.ppqL, delayToPPQ(note.delay))
      if reswungPpq ~= note.ppq then reseats.assign(note, { ppq = reswungPpq }) end
      note.ppq = reswungPpq
    end
    -- Columns are logical-born: every seat projects at ingestion.
    projectEvent(note, note.chan, time)
    if not dirt.wholesale(note.chan) and not dirt.swing.has(note.chan) then
      frame.spliceEvent(note.chan, note.lane, note)   -- into the carried logical lane; stays ordered
    else
      util.add(col.events, note)         -- fresh lane: append in mm raw order, order once below
      builtCols[col] = true
    end
    index.stampColEvt(note)
  end
  -- Raw and logical onset order diverge under swing or an authored swap, so only the lanes this pass
  -- appended to can have landed disordered; the splices above stay ordered.
  for col in pairs(builtCols) do frame.orderLane(col) end
  reseats.commit()

  return external, noteExisting
end

----- Rebuild CCs

local function ppqLess(a, b) return a.ppq < b.ppq end

-- Clone one covered cc-family event into its column with the CC walk's reconcile + projection, then
-- splice it in ppq-order. Mirror of the walk's per-event body, driven by spliceChannelCCs' row scan.
local function spliceCcEvent(live, ccWrites, time)
  local chan = live.chan
  -- stale-swing implies wholesale, so only the raw-diverges reconcile can fire on the interval path.
  local movedPpqL
  if not live.derived and rawDivergesFromLogical(live, time) then
    movedPpqL = time:toLogical(chan, live.ppq)
    ccWrites.assign({ uuid = live.uuid }, { ppqL = movedPpqL })
  end
  local event = util.clone(live)
  event.realised = true
  if movedPpqL then event.ppqL = movedPpqL end
  local channel = frame.channels[chan]
  local col
  if live.evType == 'cc' then
    col = channel.onTake.ccs[live.cc] or { cc = live.cc, events = {} }
    channel.onTake.ccs[live.cc] = col
  else
    col = channel.onTake[live.evType] or { events = {} }
    channel.onTake[live.evType] = col
  end
  projectEvent(event, chan, time)
  util.insertSorted(col.events, event, ppqLess)
  return col
end

-- ccExisting scopes to the seed-touched prev cc windows only (edge-inclusive); clean windows keep their seats untouched, and cc-family carries merge rather than replace.
-- Seeks the maintained um index (current mid-pipeline), not mm. See docs/trackerManager.md § CC walk.
local function buildCcExistingInWindows(chan, realisedWindows, ccExisting, seedRows)
  local ccBuckets = index.raw(chan).ccs
  local seen = {}
  for _, window in ipairs(realisedWindows.on(chan)) do
    if windowSeeded(seedRows, window.ppq, window.endppq) then
      local sRaw, eRaw = realisedWindows.rawSpan(window)
      for target in pairs(window.targets) do
        local list = type(target) == 'number' and ccBuckets[target]
        if list then
          for i = util.firstAtOrAfter(list, sRaw), #list do
            local evt = list[i]
            if evt.ppq >= eRaw then break end
            if not seen[evt.uuid] then
              seen[evt.uuid] = true
              util.add(ccExisting[chan],
                { ppq = evt.ppq, val = evt.val, shape = evt.shape, tension = evt.tension, cc = evt.cc, uuid = evt.uuid })
            end
          end
        end
      end
    end
  end
end

-- The carried column an (evType, cc) pair names, or nil when nothing is carried there.
local function ccColumnFor(chan, evType, ccNum)
  local cols = frame.channels[chan].onTake
  if evType == 'cc' then return cols.ccs[ccNum] end
  return cols[evType]
end

-- Excise one event's carried column event: exact-row binary seek (projection makes event ppq == ppqL),
-- then uuid-match within the row cluster, so a co-row tenant's event stands.
local function removeCellFor(col, row, uuid)
  local events = col.events
  local lo, hi = 1, #events + 1
  while lo < hi do
    local mid = (lo + hi) // 2
    if events[mid].ppq < row then lo = mid + 1 else hi = mid end
  end
  while events[lo] and events[lo].ppq == row do
    if events[lo].uuid == uuid then table.remove(events, lo)
    else lo = lo + 1 end
  end
end

-- Interval-dirt cc path: each cc-family seed excises its own event and re-clones its survivor --
-- O(seeds), no channel scan. see docs/trackerManager.md § Interval materialisation
local function spliceChannelCCs(chan, seedList, realisedWindows, ccWrites, ccExisting, time)
  local seen, touched = {}, {}
  for _, s in ipairs(seedList) do
    local family = s.evType == 'cc' or s.evType == 'at' or s.evType == 'pc'
    local uuid = family and (s.uuid or (s.evt and s.evt.uuid)) or nil
    if uuid and not seen[uuid] then
      seen[uuid] = true
      local seedCol = ccColumnFor(chan, s.evType, s.cc)
      if seedCol then touched[seedCol] = true; removeCellFor(seedCol, s.ppqL, uuid) end
      local _, live = mm:byUuid(uuid)
      if live and live.chan == chan then
        local liveCol = ccColumnFor(chan, live.evType, live.cc)
        if liveCol then touched[liveCol] = true; removeCellFor(liveCol, live.ppqL or live.ppq, uuid) end
        if not (live.evType == 'cc' and realisedWindows.ownsRaw('cc', chan, live.cc, live.ppq)) then
          touched[spliceCcEvent(live, ccWrites, time)] = true
        end
      end
    end
  end
  -- tv's cell carry keys on events-table identity (same table => reuse built cells), so a spliced
  -- column must renew its carried table -- exciseNotes' `col.events = kept` is the note-path twin.
  for col in pairs(touched) do col.events = util.clone(col.events) end
  buildCcExistingInWindows(chan, realisedWindows, ccExisting, seedRowsFor(seedList))
end

-- Wholesale / stale-swing path: re-derive a channel's whole cc/at/pc stream from mm. Verbatim from the
-- pre-splice CC walk; interval dirt takes spliceChannelCCs. see docs/trackerManager.md § CC walk
local function fullRebuildChannelCCs(chan, realisedWindows, ccWrites, ccExisting, time)
  for _, cc in mm:ccsRaw(chan) do
    local uuid = cc.uuid
    -- fx cc event: a markerless seat inside a prev cc window (its authored cc parked), routed out and
    -- reconciled fresh at fx expansion. A removed window's orphans reconcile away there. see § Route-by-window
    if cc.evType == 'cc' and realisedWindows.ownsRaw('cc', cc.chan, cc.cc, cc.ppq) then
      util.add(ccExisting[cc.chan],
        { ppq = cc.ppq, val = cc.val, shape = cc.shape, tension = cc.tension, cc = cc.cc, uuid = uuid })
      goto continue
    end

    -- Timing reconcile on the raw (read-only) record; capture what moved for the column clone.
    -- Markerless pb seats in a prior window skip it. see docs/trackerManager.md § CC walk
    local pbSeat = cc.evType == 'pb' and cc.ppqL == nil and realisedWindows.ownsRaw('pb', cc.chan, nil, cc.ppq)
    local movedPpq, movedPpqL
    if not cc.derived and not pbSeat then
      if dirt.swing.has(cc.chan) and cc.ppqL ~= nil then
        local newPpq = time:fromLogical(cc.chan, cc.ppqL)
        if newPpq ~= cc.ppq then
          ccWrites.assign({ uuid = uuid }, { ppq = newPpq })
          movedPpq = newPpq
        end
      elseif rawDivergesFromLogical(cc, time) then
        local newPpqL = time:toLogical(cc.chan, cc.ppq)
        ccWrites.assign({ uuid = uuid }, { ppqL = newPpqL })
        movedPpqL = newPpqL
      end
    end

    -- pb/pa reconcile-only (no column); cc/at/pc clone into their column carrying the reseat.
    if cc.evType == 'cc' or cc.evType == 'at' or cc.evType == 'pc' then
      local event = util.clone(cc, { loc = true })
      event.realised = true
      if movedPpq  then event.ppq  = movedPpq end
      if movedPpqL then event.ppqL = movedPpqL end
      local channel = frame.channels[cc.chan]
      local col
      if cc.evType == 'cc' then
        col = channel.onTake.ccs[cc.cc] or { cc = cc.cc, events = {} }
        channel.onTake.ccs[cc.cc] = col
      else
        col = channel.onTake[cc.evType] or { events = {} }
        channel.onTake[cc.evType] = col
      end
      projectEvent(event, cc.chan, time)
      util.add(col.events, event)
    end
    ::continue::
  end
  -- mm's cc stream is insertion-ordered mid-session (fresh adds append); columns sort by ppq.
  for _, col in pairs(frame.channels[chan].onTake.ccs) do util.sortByPPQ(col.events) end
  for _, key in ipairs{ 'at', 'pc' } do
    if frame.channels[chan].onTake[key] then util.sortByPPQ(frame.channels[chan].onTake[key].events) end
  end
end

-- CC walk: build the carrier routing map, reconcile (raw,ppqL), project CCs.
-- Returns a carrier-map persister; run after fx expansion. see docs/trackerManager.md § CC walk
local function rebuildCCs(realisedWindows, time)
  local ccWrites = mmBatch()
  local ccExisting = emptyChans()

  -- Clean channels carry their cc/at/pc columns whole: never visited. Interval-dirty ones splice just
  -- the seeded events (spliceChannelCCs); wholesale/stale-swing chans re-derive the whole stream.
  for chan = 1, 16 do
    if dirt.has(chan) then
      if dirt.wholesale(chan) then fullRebuildChannelCCs(chan, realisedWindows, ccWrites, ccExisting, time)
      else                         spliceChannelCCs(chan, dirt.has(chan), realisedWindows, ccWrites, ccExisting, time)
      end
    end
  end
  ccWrites.commit()
  return ccExisting
end

----- Rebuild extra columns

-- Reconcile extra columns against the persisted extraColumns spec; grow the spec when a
-- channel already holds more note lanes than recorded; a param binding's cc column is derived here too -- see docs/trackerView.md § Extra columns & delay sub-column.
local function rebuildExtraColumns(extraColumns, paramAutomation)
  local extras = extraColumns or {}
  local bound  = paramAutomation or {}
  local grew   = false
  for i = 1, 16 do
    local c    = frame.channels[i].onTake
    local want = extras[i] or { notes = defaultNoteCols }
    local n    = #c.notes
    if n > want.notes then
      want.notes = n
      extras[i] = want
      grew = true
    end
    while #c.notes < want.notes do pushNoteCol(frame.channels[i]) end
    if want.pc then c.pc = c.pc or { events = {} } end
    if want.pb then c.pb = c.pb or { events = {} } end
    if want.at then c.at = c.at or { events = {} } end
    for ccNum in pairs(want.ccs or {}) do
      c.ccs[ccNum] = c.ccs[ccNum] or { cc = ccNum, events = {} }
    end
    for lane in pairs(bound[i] or {}) do
      c.ccs[lane] = c.ccs[lane] or { cc = lane, events = {} }
    end
  end
  if grew and mm:take() then ds:assign('extraColumns', extras) end
end

----- Rebuild externals

-- Lane packing for one externals pass. Overlap tests are realised-time, but columns are logical by
-- now -- so occupancy is um's raw index plus this pass's placements. see docs/trackerManager.md § Externals
local function externalLanePacker(external)
  local lenient = cm:get('overlapOffset') * mm:resolution()
  local onsetI  = {}   -- [evt] = intent-frame onset; an event's never moves while the pass runs
  local head    = {}   -- [laneList] = first live index; everything below ends too early to ever overlap

  -- Probes arrive in raw-ppq order but test in the intent frame, so the retirement floor trails the
  -- sweep by the pass's largest delay: monotone without reordering the pack. Diverged notes carry one.
  local maxDelayPpq = 0
  local isExternal  = {}
  for _, note in ipairs(external) do
    maxDelayPpq = math.max(maxDelayPpq, delayToPPQ(note.delay or 0))
    isExternal[note.uuid] = true
  end

  -- Raw occupancy per lane: index entries for the seated internals (reseats committed, onsets current),
  -- joined by placed probes -- externals' staged lanes reach the index only at extWrites.commit().
  local occupancy = {}
  local function laneList(chan, lane)
    local lanes = occupancy[chan]
    if not lanes then
      lanes = {}
      for _, entry in ipairs(index.raw(chan).notes) do
        if not entry.derived and not isExternal[entry.uuid] then
          lanes[entry.lane] = lanes[entry.lane] or {}
          util.add(lanes[entry.lane], entry)
        end
      end
      occupancy[chan] = lanes
    end
    local list = lanes[lane]
    if not list then list = {}; lanes[lane] = list end
    return list
  end

  local function onsetOf(evt)
    local ppqI = onsetI[evt]
    if not ppqI then
      ppqI        = evt.ppq - delayToPPQ(evt.delay or 0)
      onsetI[evt] = ppqI
    end
    return ppqI
  end

  local function byRawOnset(a, b) return a.ppq < b.ppq end

  --contract: true iff note fits lane: no over-threshold overlap, coincident onset always refuses
  --invariant: overlap threshold: same-pitch 0, cross-pitch lenient; dominated-by≥2 refuses
  --contract: consulted only for unstamped raw probes; stamped notes never reach it
  local function laneAccepts(events, note)
    local floorPpq = note.ppq - maxDelayPpq
    local live     = head[events] or 1
    while live <= #events and events[live].endppq <= floorPpq do live = live + 1 end
    head[events] = live

    local noteppqI    = onsetOf(note)
    local noteEndppqI = note.endppq
    local dominated   = 0
    -- Backwards: a refusal and the dominated tally are both order-free, and a conflicting note is
    -- always a recent one -- so the conflict surfaces at once instead of a column-walk away.
    for i = #events, live, -1 do
      local evt     = events[i]
      local evtppqI = onsetOf(evt)
      if noteppqI == evtppqI then return false end
      if noteppqI < evt.endppq and evtppqI < noteEndppqI then
        local threshold     = (evt.pitch == note.pitch) and 0 or lenient
        local overlapAmount = math.min(evt.endppq, noteEndppqI) - math.max(evtppqI, noteppqI)
        if overlapAmount > threshold then return false end
        dominated = dominated + 1
      end
    end
    return dominated < 2
  end

  --contract: pick a lane for an external (unstamped) probe via accept → sibling → push bump
  --invariant: called up front after internals placed + swing-reseated; tail walk clips tails after
  return function(channel, note)
    -- A mid-list insert can shift a retired entry back past head; harmless -- its end sits below the floor.
    local function claim(col, lane)
      util.insertSorted(laneList(note.chan, lane), note, byRawOnset)
      return col, lane
    end
    local notes = channel.onTake.notes
    if note.lane then
      local col = notes[note.lane]
      if col and laneAccepts(laneList(note.chan, note.lane), note) then return claim(col, note.lane) end
      if not col then
        while #notes < note.lane do pushNoteCol(channel) end
        return claim(notes[note.lane], note.lane)
      end
    end
    for i, col in ipairs(notes) do
      if laneAccepts(laneList(note.chan, i), note) then return claim(col, i) end
    end
    return claim(pushNoteCol(channel))
  end
end

-- Reintroduce externals: pack lane, stamp ppqL/endppqL, backfill metadata, project, tag `fixed`;
-- block window + tail passes. see docs/trackerManager.md § Externals
local function rebuildExternals(external, time)
  if #external == 0 then return end

  util.sortByPPQ(external)
  local packLane    = externalLanePacker(external)
  local extWrites   = mmBatch()
  for _, note in ipairs(external) do
    local delay     = note.delay or 0
    local d         = delayToPPQ(delay)
    local probe     = { chan = note.chan, ppq = note.ppq, endppq = note.endppq,
                        pitch = note.pitch, delay = delay, lane = note.lane }
    local _, lane = packLane(frame.channels[note.chan], probe)
    local update    = {
      ppqL    = time:toLogical(note.chan, note.ppq - d),
      endppqL = time:toLogical(note.chan, note.endppq),
    }
    if note.lane   ~= lane then update.lane   = lane   end
    if note.detune == nil  then update.detune = 0      end
    if note.delay  == nil  then update.delay  = 0      end
    local colNote = util.clone(note)
    util.assign(colNote, update)
    colNote.fixed = true
    projectEvent(colNote, note.chan, time)
    frame.spliceEvent(note.chan, lane, colNote)
    index.stampColEvt(colNote)
    extWrites.assign(colNote, update)
  end
  extWrites.commit()
end

----- Rebuild region park

-- Park = clone minus the realisation frame, so new authored metadata rides a park/unpark
-- round-trip untouched; restore mirrors it (clone back, re-derive realisation, incl. sampleShadowed).
local REALISATION = { delayC = true, endppqC = true, realised = true, derived = true,
                      frame = true, cents = true, colEvt = true, sampleShadowed = true }
--contract: evt must be logical-frame (a column event); an mm-raw source overrides ppq via `adds`
local function parkSpec(evt, adds) return util.assign(util.clone(evt, REALISATION), adds) end

local function unlink(events, evt)
  for i, e in ipairs(events) do if e == evt then table.remove(events, i); break end end
end

-- Positional match over contents, not identity; endppqC excluded since it's clipParked's own,
-- derived after installation. See docs/trackerManager.md § Note-lane renewal.
local function sameParked(prior, built)
  if not prior or #prior ~= #built then return false end
  for i, evt in ipairs(built) do
    local was = prior[i]
    for k, v in pairs(evt) do
      if k ~= 'endppqC' and not util.deepEq(was[k], v) then return false end
    end
    for k in pairs(was) do if k ~= 'endppqC' and evt[k] == nil then return false end end
  end
  return true
end

-- Off-take render union: parked specs stay visible in-column as render-ready events. A field's list
-- is replaced only where its contents moved, which is what lets an index over one outlive the pass.
--invariant: a parked list changes identity iff its contents changed (tv's carry key, as note lanes)
--post: unsafe result[spec] = its installed event -- the prior list's own wherever contents held
local function renderUnion(field, newParked, toEvent)
  local built, specs = {}, {}
  for _, spec in ipairs(newParked) do
    util.bucket(built, spec.chan, toEvent(spec))
    util.bucket(specs, spec.chan, spec)
  end
  local installed = {}
  for chan = 1, 16 do
    local parked = frame.channels[chan].parked
    local fresh  = built[chan] or {}
    local kept   = sameParked(parked[field], fresh) and parked[field] or fresh
    parked[field] = kept
    for i, spec in ipairs(specs[chan] or {}) do installed[spec] = kept[i] end
  end
  return installed
end

local function persistParked(key, newParked, prior)
  if not util.deepEq(prior or {}, newParked) and mm:take() then
    ds:assign(key, #newParked > 0 and newParked or util.REMOVE)
  end
end

-- A stash spec as its render event: logical like a projected note, showing the authored ceiling, and
-- holding a column home for its lane.
local function parkedEvent(spec)
  local channel = frame.channels[spec.chan]
  while #channel.onTake.notes < spec.lane do pushNoteCol(channel) end
  return util.assign(util.clone(spec), { endppq = spec.endppq or util.OPEN })
end

-- Which hosts are off-take as of now: the park stage moves a host between the halves of its lane, so
-- each reader asks at its own moment. see docs/trackerManager.md § Note host clips and windows
local function parkedUuids()
  local parked = {}
  for chan = 1, 16 do
    for _, evt in ipairs(frame.channels[chan].parked.notes) do parked[evt.uuid] = true end
  end
  return parked
end

-- The clip comes off the lane's strict-next onset, so it moves with the stash standing still: a list
-- whose clip moved sheds its table, like any other change to its contents.
local function clipParked(time)
  local takeLen = time:length()
  for chan = 1, 16 do
    local members = frame.channels[chan].parked.notes
    if #members > 0 then
      local takeLenL, moved = time:toLogical(chan, takeLen), false
      for _, m in ipairs(members) do
        local clip = clipEnd(m, takeLenL)
        if m.endppqC ~= clip then m.endppqC = clip; moved = true end
      end
      if moved then frame.channels[chan].parked.notes = util.clone(members) end
    end
  end
end

-- The parked half of every lane, rendered from the stash at the head of the pass (a park edit has
-- already landed in the document). See docs/trackerManager.md § Note host clips and windows.
local function renderStashedParked(fxParked, time)
  local notes = {}
  for _, spec in ipairs(fxParked or {}) do
    if spec.evType == 'note' then util.add(notes, spec) end
  end
  renderUnion('notes', notes, parkedEvent)
  clipParked(time)
end

-- Region-replace parking: authored events a replace window covers leave the take;
-- the prior parked set carries still-covered forward, restores the rest. see docs/generators.md § Emission is ownership

local function rebuildRegionPark(windows, fxParked, realisedWindows, noteHostClips, pbLimCents, time)
  local batch = mmBatch()
  -- Restored notes re-enter their columns unrealised; this stage's own commit lands them in mm and
  -- seat-stamps each event, so the tail walk meets an ordinary seated entry.
  local restoredEvents = {}
  -- The originals each host's chain parked, keyed by the host that parked each: events by
  -- reference, minted here and handed back for the realisation entries.
  local parkedByHost = {}
  -- The prior parked set, read before renderUnion replaces the lists.
  local parkedAtHead = parkedUuids()

  -- One predicate for all passes, answering with the host that parks the spec: a window covers it
  -- on the spec's own stream, or (note specs only) spec.fx parks itself. see docs/trackerManager.md § Region-replace parking
  --contract: the parking host's uuid, nil for a spec no window claims
  local function coveredBy(spec)
    local host = windows.owns(spec.evType, spec.chan, spec.cc, spec.ppq)
    if host then return host end
    if spec.fx and generators.parksNotes(spec) then return spec.uuid end
  end
  local function covered(spec) return coveredBy(spec) ~= nil end

  -- Park covered candidates, split the prior set into carry-forward / restore. onPark fires
  -- once per freshly-parked spec, never carried-forward. see docs/trackerManager.md § Rebuild
  local allParked = {}
  local function reconcilePark(scan, prior, onPark)
    local newParked, restores = {}, {}
    for _, carry in ipairs(scan) do
      if covered(carry.spec) then
        if onPark then onPark(carry.spec) end
        util.add(newParked, carry.spec)
        batch.del(carry.evt)
        -- A note carry names its lane, not the lane's events table: renewLane replaces that table
        -- between the scan and here, and the old one is no longer the lane tv will read.
        if carry.lane then
          unlink(frame.renewLane(carry.chan, carry.lane).events, carry.evt)
        elseif carry.events then
          unlink(carry.events, carry.evt)
        end
      end
    end
    for _, spec in ipairs(prior) do
      if covered(spec) then util.add(newParked, spec)
      else util.add(restores, spec) end
    end
    for _, spec in ipairs(newParked) do util.add(allParked, spec) end
    return newParked, restores
  end

  -- Notes, ccs and pbs park in one batch -> a single delete-first commit for the whole phase, and
  -- one evType-tagged fxParked stash. Each pass reconciles its own slice of the prior stash.
  local priorByType = {}
  for _, spec in ipairs(fxParked or {}) do util.bucket(priorByType, spec.evType, spec) end

  -- Window spans per target: the fresh note/cc scans visit only these, never the whole channel;
  -- cc spans come from the settled set below. see docs/trackerManager.md § Span-covered fx scans
  local noteSpans = {}
  do
    local noteWins = {}
    for _, w in ipairs(windows.windows()) do
      if w.targets.note then
        util.bucket(noteWins, w.chan, { window = { w.ppq, w.endppq } })
      end
    end
    for chan, wins in pairs(noteWins) do noteSpans[chan] = spans.mergeWindows(wins) end
  end

  -- Notes: can't mute (note-on/off + CC matching), so a covered authored note leaves the take, fed
  -- by two bounded sources -- see docs/trackerManager.md § Span-covered fx scans for the note-host split.
  local parkedNotes
  do
    local scan, seen = {}, {}
    local function candidate(evt, laneIdx)
      if seen[evt] then return end   -- a host under its own region would arrive from both sources
      seen[evt] = true
      util.add(scan, { evt = evt, chan = evt.chan, lane = laneIdx,
                       spec = parkSpec(evt, { lane = laneIdx }) })
    end
    for chan, chanSpans in pairs(noteSpans) do
      if dirt.has(chan) then
        for laneIdx, col in ipairs(frame.channels[chan].onTake.notes) do
          coverOnsets(col.events, chanSpans, function(evt)
            if evt.evType ~= 'pa' then candidate(evt, laneIdx) end
          end)
        end
      end
    end
    -- On-take hosts only: a host already parked is the prior set's to carry or restore.
    for host in pairs(noteHostClips) do
      if dirt.has(host.chan) and generators.parksNotes(host) and not parkedAtHead[host.uuid] then
        candidate(host, host.lane)
      end
    end

    -- Park removes a blocker; same-lane/pitch neighbours' tails regrow.
    local restores
    parkedNotes, restores = reconcilePark(scan, priorByType.note or {},
      function(spec)
        dirt.add(spec.chan, dirt.parkSeed(spec, 'park', time:fromLogical(spec.chan, spec.ppq)))
      end)

    -- Restores re-enter their columns now (unrealised) and land in mm with this stage's commit;
    -- the tail walk then meets each as an ordinary seated entry and clips it in place.
    local takeLen = time:length()
    for _, spec in ipairs(restores) do
      local ppq = time:fromLogical(spec.chan, spec.ppq)
      dirt.add(spec.chan, dirt.parkSeed(spec, 'restore', ppq))
      local channel = frame.channels[spec.chan]
      while #channel.onTake.notes < spec.lane do pushNoteCol(channel) end
      local note = util.clone(spec)   -- the event is the spec: both are logical (keeps the parked uuid too)
      util.add(restoredEvents, note)
      frame.spliceEvent(spec.chan, spec.lane, note)
      -- Provisional raw end: the authored ceiling is all that is known here, since the lane clip is
      -- the tail walk's to find -- boundNote's write-through corrects this in place.
      local ceiling = note.endppq == util.OPEN and math.huge
                      or note.endppq and time:fromLogical(spec.chan, note.endppq)
                      or math.huge
      batch.add(util.assign(util.clone(note, { delayC = true, endppqC = true }),
        { keepUuid = true, ppq = ppq, ppqL = note.ppq, endppqL = note.endppq,
          endppq = util.round(math.max(ppq + 1, math.min(ceiling, takeLen))) }))
    end

    -- Off-take membership for the generator + grid: each is a render-ready logical event
    -- (ppq/endppqC like a projected note); an emptied lane re-extends to keep a column home.
    local installed = renderUnion('notes', parkedNotes, parkedEvent)
    -- The overlay suppresses only its own host's originals, and gridPane matches them by identity, so
    -- the share names what the frame installed, not a candidate a kept list dropped.
    for _, spec in ipairs(parkedNotes) do
      util.bucket(parkedByHost, coveredBy(spec), installed[spec])
    end
    clipParked(time)
  end

  -- PA: rides its host note, so it parks exactly when the host does -- off-take (silent), still
  -- shown in the host lane by rebuildPA. Reconciled against the parked-note set. see docs/trackerManager.md § Region-replace parking
  do
    local function hostParked(chan, pitch, ppq)
      for _, evt in ipairs(frame.channels[chan].parked.notes or {}) do
        if evt.pitch == pitch and ppq >= evt.ppq and ppq < evt.endppqC then return true end
      end
      return false
    end

    local newParked, seen, freshEvents = {}, {}, {}
    -- Fresh: an on-take PA whose host just parked leaves the take and stashes. Bounded by each parked
    -- member's raw span (its own PAs), not the channel's cc count. see docs/trackerManager.md § Span-covered fx scans
    for chan = 1, 16 do
      if dirt.has(chan) then
        local pas = index.raw(chan).pas
        for _, evt in ipairs(frame.channels[chan].parked.notes or {}) do
          local sRaw, eRaw = time:fromLogical(chan, evt.ppq), time:fromLogical(chan, evt.endppqC)
          for i = util.firstAtOrAfter(pas, sRaw), #pas do
            local cc = pas[i]
            if cc.ppq >= eRaw then break end
            if not seen[cc] and hostParked(cc.chan, cc.pitch, cc.ppqL or cc.ppq) then
              seen[cc] = true
              -- Seed the PA's row so rebuildPA's gated parked loop re-projects it: mmBatch.del
              -- accumulates raw ops but seeds no interval dirt, exactly as the pb park seeds its own.
              dirt.add(cc.chan, dirt.rawSeed(cc, 'park'))
              batch.del({ uuid = cc.uuid })
              freshEvents[cc.chan] = freshEvents[cc.chan] or {}
              freshEvents[cc.chan][cc.uuid] = cc.ppqL or cc.ppq   -- the row the excise seeks
              local spec = parkSpec(cc, { ppq = cc.ppqL or cc.ppq })   -- um index source: evType/chan/pitch/vel/rpb ride, ppq flips logical
              spec.uuid = nil                                           -- restore re-mints the rpb sidecar uuid
              util.add(newParked, spec)
            end
          end
        end
      end
    end
    -- The parking PA's on-take column event rode past exciseNotes untouched -- its row seeds only here,
    -- after that pass ran -- so drop it now, or rebuildPA's parked projection doubles the carried event.
    for chan, rowByUuid in pairs(freshEvents) do
      local rows = {}
      for _, row in pairs(rowByUuid) do util.add(rows, row) end
      exciseNotes(chan, rows, function(e) return e.evType == 'pa' and rowByUuid[e.uuid] ~= nil end)
    end
    -- Prior parked PAs: host still parked -> carry; host returned on-take -> restore to the take.
    for _, spec in ipairs(priorByType.pa or {}) do
      if hostParked(spec.chan, spec.pitch, spec.ppq) then
        util.add(newParked, spec)
      else
        local ppq = time:fromLogical(spec.chan, spec.ppq)
        dirt.add(spec.chan, dirt.parkSeed(spec, 'restore', ppq))
        batch.add(util.assign(util.clone(spec),   -- back to mm: raw onset, logical sidecar
          { ppq = ppq, ppqL = spec.ppq }))
      end
    end
    for _, spec in ipairs(newParked) do util.add(allParked, spec) end

    renderUnion('pa', newParked, util.clone)
  end

  -- CCs: a point event has no tail, so the Pass-A curve stands in on the target lane and
  -- restores add back immediately, seating an unrealised projection for the view.
  do
    -- cc spans from the window set, which the note pass above left untouched.
    local ccSpans, ccWins = {}, {}
    for _, w in ipairs(windows.windows()) do
      for target in pairs(w.targets) do
        if type(target) == 'number' then
          util.bucket(ccWins, util.key(w.chan, target), { window = { w.ppq, w.endppq } })
        end
      end
    end
    for key, wins in pairs(ccWins) do ccSpans[key] = spans.mergeWindows(wins) end

    local scan = {}
    for chan = 1, 16 do
      if dirt.has(chan) then
        for cc, col in pairs(frame.channels[chan].onTake.ccs) do
          coverOnsets(col.events, ccSpans[util.key(chan, cc)], function(evt)
            util.add(scan, { evt = evt, events = col.events,
              spec = parkSpec(evt, { cc = cc }) })   -- cc pins the column key; evType/chan/ppq ride the event
          end)
        end
      end
    end
    -- The mm-bound restore of a parked spec: raw onset, logical sidecar. Column and render events
    -- are the spec itself -- already logical.
    local function ccWrite(spec, ppq)
      return util.assign(util.clone(spec), { ppq = ppq, ppqL = spec.ppq })
    end

    local newParked, restores = reconcilePark(scan, priorByType.cc or {})

    -- Seat an unrealised projection so the view shows the restored cc this frame; next rebuild
    -- re-reads the real mm event from the take. The add rides the shared park commit.
    for _, spec in ipairs(restores) do
      local ppq  = time:fromLogical(spec.chan, spec.ppq)   -- realised onset derived fresh (the stash is logical)
      local evt = ccWrite(spec, ppq)
      -- The fill seat at this ppq stays in ccExisting: rebuildFx's reconcile deletes it by its own
      -- uuid, so a restore needs no del. see docs/trackerManager.md § Region-replace parking
      batch.add(evt)
      local channel = frame.channels[spec.chan]
      local col = channel.onTake.ccs[spec.cc]
      if not col then col = { cc = spec.cc, events = {} }; channel.onTake.ccs[spec.cc] = col end
      util.add(col.events, util.clone(spec))
      util.sortByPPQ(col.events)
    end

    -- Render union: the parked authored cc stays the visible surface (the fill is hidden
    -- realisation), so creating a cc-replace region never blanks the lane. Mirrors channels[*].parked.notes.
    renderUnion('ccs', newParked, function(spec)
      local ccs = frame.channels[spec.chan].onTake.ccs
      ccs[spec.cc] = ccs[spec.cc] or { cc = spec.cc, events = {} }
      return util.clone(spec)
    end)
  end

  -- pb: seats are markerless, so the scan can't run every rebuild -- it diffs current pb windows against
  -- last rebuild's persisted set: a created window parks its authored pbs, a removed one sweeps. see § Route-by-window
  local prevPb, curPb = {}, {}
  for _, w in ipairs(realisedWindows.windows()) do
    if w.targets.pb then prevPb[util.key(w.chan, w.ppq, w.endppq)] = w end
  end
  for _, w in ipairs(windows.windows()) do
    if w.targets.pb then curPb[util.key(w.chan, w.ppq, w.endppq)] = w end
  end
  local pbCreated, pbRemoved = {}, {}
  for k, w in pairs(curPb) do if not prevPb[k] then util.add(pbCreated, w) end end
  for k, w in pairs(prevPb) do if not curPb[k] then util.add(pbRemoved, w) end end
  do
    -- Park (create): only a newly-created window walks mm. `derived` can't spot seats (RAM-only,
    -- lost on take round-trip); region can: a pb inside a *previous* window is a seat, never authored.
    local scan = {}
    for _, win in ipairs(pbCreated) do
      local sRaw, eRaw = windows.rawSpan(win)
      local pbs = index.raw(win.chan).pbs
      for i = util.firstAtOrAfter(pbs, sRaw), #pbs do
        local cc = pbs[i]
        if cc.ppq >= eRaw then break end   -- half-open, as coverage and the mm walk are
        if not cc.derived and not realisedWindows.ownsRaw('pb', cc.chan, nil, cc.ppq) then
          dirt.add(cc.chan, dirt.rawSeed(cc, 'park'))
          -- val: logical cents from the cents sidecar (restore maps back); entry.val is already the
          -- raw-derived cents, the best-effort fallback for a foreign pre-cents pb.
          local spec = parkSpec(cc, { ppq = cc.ppqL or cc.ppq,
                                      val = cc.cents or cc.val })   -- index entry: evType/chan/shape/tension ride; ppq flips logical, cents->val
          util.add(scan, { evt = util.clone(cc, { colEvt = true }), spec = spec })
        end
      end
    end

    local newParked, restores = reconcilePark(scan, priorByType.pb or {})

    -- Restore re-adds to the take; the absorber (later this rebuild) refines the wire raw with
    -- detune and re-shows it. The seed val is detune-free -- the absorber's assign corrects it.
    for _, spec in ipairs(restores) do
      local ppq = time:fromLogical(spec.chan, spec.ppq)
      dirt.add(spec.chan, dirt.parkSeed(spec, 'restore', ppq))
      batch.add(util.assign(util.clone(spec),
        { ppq = ppq, ppqL = spec.ppq,
          cents = spec.val, val = tuning.centsToRaw(spec.val, pbLimCents) }))   -- spec.val is cents; the wire wants raw + a sidecar
    end

    -- Sweep queue (remove): a removed window's seats orphan (no marker names them) -- delete every pb
    -- in the swept raw span. The authored restored above is an unrealised add, so delete-first order is safe.
    for _, win in ipairs(pbRemoved) do
      local sRaw, eRaw = realisedWindows.rawSpan(win)   -- a removed window is the stored set's own
      local pbs = index.raw(win.chan).pbs
      for i = util.firstAtOrAfter(pbs, sRaw), #pbs do
        local cc = pbs[i]
        if cc.ppq >= eRaw then break end   -- half-open, as coverage and the mm walk are
        dirt.add(cc.chan, dirt.rawSeed(cc, 'delete'))
        batch.del({ uuid = cc.uuid })
      end
    end

    -- Render union for the view: the authored breakpoints stay visible in-column though off-take.
    renderUnion('pb', newParked, function(spec)
      return util.assign(util.clone(spec), { cents = spec.val })
    end)
  end

  persistParked('fxParked', allParked, fxParked)
  batch.commit()
  -- Seat-stamp each restored event like any other seat, now the commit lands it in mm; bare write,
  -- no setEvent -- see docs/trackerManager.md § Incremental index reconciliation.
  for _, evt in ipairs(restoredEvents) do
    if index.stampColEvt(evt) then evt.realised = true end
  end
  return parkedByHost
end

----- Raw working set

-- The pass's raw note view is um's index, read in place (entries are live um records, colEvt
-- their seat stamp), filtered at use to authored, logically seated notes.
local function walkable(note) return not note.derived and note.ppqL ~= nil end

-- One-pass merge of the pre-sorted index list (filtered) with a small sorted extras list;
-- replaces the whole-channel sort the per-pass scratch copy used to force.
local function mergeIndexed(indexNotes, keep, extras)
  table.sort(extras, index.order)
  local merged, j = {}, 1
  for _, entry in ipairs(indexNotes) do
    if keep(entry) then
      while extras[j] and index.order(extras[j], entry) do
        util.add(merged, extras[j]); j = j + 1
      end
      util.add(merged, entry)
    end
  end
  for i = j, #extras do util.add(merged, extras[i]) end
  return merged
end

----- Rebuild PA

local function findNoteColumnForPitch(channel, pitch, ppq_pos, time)
  local notes = channel.onTake.notes
  -- Containment is raw geometry: scan the index; lowest lane wins, matching column order.
  -- Pre-commit restores can't match -- their endppq is nil until the walk derives it.
  local coveringLane
  for _, rec in ipairs(index.raw(channel.chan).notes) do
    if walkable(rec) and rec.endppq and rec.pitch == pitch and rec.ppq <= ppq_pos
       and rec.endppq > ppq_pos and (coveringLane == nil or rec.lane < coveringLane) then
      coveringLane = rec.lane
    end
  end
  if coveringLane then return notes[coveringLane], coveringLane end
  -- Parked note hosts left the take (off-take, silent); their PAs park with them but stay
  -- shown here, anchored to the host's lane -- rebuildPA re-projects them off-take.
  for _, evt in ipairs(channel.parked.notes or {}) do
    if evt.pitch == pitch and time:fromLogical(channel.chan, evt.ppq) <= ppq_pos
       and time:fromLogical(channel.chan, evt.endppqC) > ppq_pos then
      return notes[evt.lane], evt.lane
    end
  end
  -- Pitch-only fallback: frame-agnostic, so the columns serve it (projected PAs included).
  for laneIdx, col in ipairs(notes) do
    for _, evt in ipairs(col.events) do
      if evt.pitch == pitch then return col, laneIdx end
    end
  end
end

-- Late PA projection: mixes into note columns once lanes are settled, so the view (and rebuildFx's
-- channelStreams) read it inline. see docs/trackerManager.md § PA dispatch
local function rebuildPA(time)
  for chan = 1, 16 do
    if dirt.has(chan) then   -- clean: PA already sits in the carried note column
      local covers = seedCovers(chan)   -- wholesale: always-true; interval: seeded rows only
      for _, cc in ipairs(index.raw(chan).pas) do
        if covers(cc) then
          local noteCol, lane = findNoteColumnForPitch(frame.channels[chan], cc.pitch, cc.ppq, time)
          if noteCol then
            local evt = projectCC(cc, { lane = lane })
            projectEvent(evt, chan, time)
            frame.spliceEvent(chan, lane, evt)
          end
        end
      end
    end
  end

  -- Parked PAs left the take (off-take, silent) but still ride their host's note column --
  -- projected unrealised into the parked host's lane. see docs/trackerManager.md § PA dispatch
  for chan = 1, 16 do
    if dirt.has(chan) then
      local covers = seedCovers(chan)
      for _, evt in ipairs(frame.channels[chan].parked.pa or {}) do
        if covers(evt) then
          local ppq = time:fromLogical(chan, evt.ppq)   -- raw: findNoteColumnForPitch is raw geometry
          local noteCol, lane = findNoteColumnForPitch(frame.channels[chan], evt.pitch, ppq, time)
          if noteCol then
            frame.spliceEvent(chan, lane, projectCC(evt, {lane = lane}))   -- the event is logical-born
          end
        end
      end
    end
  end
end

----- Fx expansion helpers

-- Span cover of a sorted list: governing entry at-or-before each span, through its close, admit-filtered.
-- see docs/trackerManager.md § Span-covered fx scans
local function coverInto(list, spanSet, admit, emit)
  local nextIdx = 1
  for _, span in ipairs(spanSet) do
    local govern = util.firstAfter(list, span[1]) - 1
    while govern >= nextIdx and admit and not admit(list[govern]) do govern = govern - 1 end
    local i = math.max(govern, nextIdx)
    while i <= #list do
      local entry = list[i]
      i = i + 1
      if not admit or admit(entry) then
        emit(entry)
        if entry.ppq > span[2] then break end
      end
    end
    nextIdx = i
  end
end

-- Absolute authored bases per channel (ppq-keyed, logical), covering only the caller's spans.
-- see docs/trackerManager.md § Span-covered fx scans
local function pbBaseFor(chan, spanSet, time)
  local base, seen = {}, {}
  for _, evt in ipairs(frame.channels[chan].parked.pb or {}) do
    util.add(base, { ppq = evt.ppq, val = evt.cents, shape = evt.shape or 'step', tension = evt.tension })
    seen[evt.ppq] = true
  end
  -- The maintained pb index is raw-sorted; pbs carry no delay and swing is monotone, so the raw
  -- cover is the logical cover. Authored = the cents sidecar (seats and foreign pbs carry none).
  local rawSpans = {}
  for _, span in ipairs(spanSet) do
    util.add(rawSpans, { time:fromLogical(chan, span[1]), time:fromLogical(chan, span[2]) })
  end
  local function authored(pb) return not pb.derived and pb.cents ~= nil end
  coverInto(index.raw(chan).pbs, rawSpans, authored, function(pb)
    local ppq = pb.ppqL or pb.ppq
    if not seen[ppq] then
      util.add(base, { ppq = ppq, val = pb.cents, shape = pb.shape or 'step', tension = pb.tension })
    end
  end)
  util.sortByPPQ(base)
  return base
end
local function ccBasesFor(chan, spanSet)
  local bases, seen = {}, {}
  for _, evt in ipairs(frame.channels[chan].parked.ccs or {}) do
    util.bucket(bases, evt.cc, { ppq = evt.ppq, val = evt.val, shape = evt.shape or 'step',
                                  tension = evt.tension })
    seen[util.key(evt.cc, evt.ppq)] = true
  end
  for cc, col in pairs(frame.channels[chan].onTake.ccs) do
    coverInto(col.events, spanSet, nil, function(evt)
      if not seen[util.key(cc, evt.ppq)] then
        util.bucket(bases, cc, { ppq = evt.ppq, val = evt.val, shape = evt.shape or 'step',
                                 tension = evt.tension })
      end
    end)
  end
  for _, base in pairs(bases) do util.sortByPPQ(base) end
  return bases
end

-- Membership is overlap, not storage: one walk feeds generator events + fixed lane occupancy.
-- Cover, not scan: see docs/trackerManager.md § Span-covered fx scans; docs/generators.md § Hosts and membership
local function appendLaneEvents(list, startL, out)
  local from = util.firstAfter(list, startL)
  -- The event already sounding as the window opens leads: its tail reaches in even though its onset
  -- does not. A PA holds no lane of its own and never answers.
  for j = from - 1, 1, -1 do
    if list[j].evType ~= 'pa' then util.add(out, list[j]); break end
  end
  for j = from, #list do
    if list[j].evType ~= 'pa' then util.add(out, list[j]) end
  end
end

-- What holds a lane on the take, which a host's own output stands in for once it parks.
local function onTakeOnLane(chan, lane, startL)
  local events = {}
  appendLaneEvents(frame.channels[chan].onTake.notes[lane].events, startL, events)
  return events
end

-- A lane's whole authored population, on-take and parked alike: what sounds there.
-- see docs/trackerManager.md § Lane occupancy
local function authoredOnLane(chan, lane, startL)
  local events = {}
  appendLaneEvents(frame.authoredEvents(chan, lane), startL, events)
  return events
end

-- One lane walk over an ordered population: each event sounds to the next onset or its own ceiling.
-- Cover, not scan: see docs/trackerManager.md § Span-covered fx scans; docs/generators.md § Hosts and membership
--pre: eventsOnLane(chan, lane, startL) returns the lane's population in ppq order
local function eachLaneSpan(chan, startL, endL, eventsOnLane, fn)
  for laneIdx in ipairs(frame.channels[chan].onTake.notes) do
    -- A lane is monophonic + ppq-sorted, so a note's sounding tail ends at the next note's onset
    -- (or the window): mirror rebuildTails' laneClip so an OPEN ceiling never streams a phantom overlap.
    local pending   -- onset awaiting its tail bound (the next onset's ppq, or endL)
    local function sound(nextOn)
      local ceil = (pending.endppq == nil or pending.endppq == util.OPEN) and endL or pending.endppq
      local hi   = math.min(ceil, nextOn)
      if pending.ppq < endL and hi > startL then fn(laneIdx, pending.ppq, hi, pending) end
    end
    for _, evt in ipairs(eventsOnLane(chan, laneIdx, startL)) do
      if pending then sound(evt.ppq) end
      if evt.ppq >= endL then pending = nil; break end
      pending = evt
    end
    if pending then sound(endL) end
  end
end
local function membersOf(chan, startL, endL)
  local out = {}
  -- The lane rides along: a monophonic stage (portamento) glides the lane-1 voice alone, and a
  -- member's column is the only place that is knowable.
  eachLaneSpan(chan, startL, endL, authoredOnLane, function(laneIdx, lo, hi, evt)
    util.add(out, util.pick(evt, "pitch vel detune intentCents", { ppq = lo, endppq = hi, lane = laneIdx }))
  end)
  return out
end
-- cc-family streams a generator reads (notes via membersOf); pb/ccs are absolute curves sliced
-- from the per-chan bases with entering/closing edges. see docs/generators.md § Input streams
local function channelStreams(chan, startL, endL, pbBase, ccBases)
  local cols = frame.channels[chan].onTake
  local pas, ats = {}, {}
  for _, col in ipairs(cols.notes) do
    for j = util.firstAtOrAfter(col.events, startL), #col.events do
      local evt = col.events[j]
      if evt.ppq >= endL then break end
      if evt.evType == 'pa' then util.add(pas, { ppq = evt.ppq, pitch = evt.pitch, vel = evt.vel }) end
    end
  end
  local atEvents = cols.at and cols.at.events or {}
  for j = util.firstAtOrAfter(atEvents, startL), #atEvents do
    local evt = atEvents[j]
    if evt.ppq >= endL then break end
    util.add(ats, { ppq = evt.ppq, val = evt.val })
  end
  -- Generators read these streams in ppq order (lanes interleave via the sort; ats ride their
  -- column's order; bases pre-sorted, slices preserve order).
  util.sortByPPQ(pas)
  local ccs = {}
  for cc, base in pairs(ccBases) do ccs[cc] = curves.slice(base, startL, endL) end
  return pas, ccs, ats, curves.slice(pbBase, startL, endL)
end
-- Deterministic allocator: lowest lane free of overlap, authored notes seed occupancy;
-- emission order -> deterministic -> G4-stable. see docs/generators.md § Output
local function allocateRegionLanes(chan, startL, endL, derived, emitted)
  -- reach tracks each lane's furthest span end, so a start past it clears the lane without
  -- scanning occupied -- the common case, since region tiling emits notes in span order.
  local occupied, reach = {}, {}
  local function occupy(lane, lo, hi)
    util.bucket(occupied, lane, { lo, hi })
    reach[lane] = math.max(reach[lane] or hi, hi)
  end
  local function laneFree(lane, lo, hi)
    if reach[lane] == nil or lo >= reach[lane] then return true end
    for _, span in ipairs(occupied[lane]) do
      if lo < span[2] and hi > span[1] then return false end
    end
    return true
  end
  eachLaneSpan(chan, startL, endL, onTakeOnLane, occupy)
  -- Already-emitted derived specs occupy too: a parked note host's tiles hold its lane
  -- (the host itself is off-take, so eachWindowNote no longer sees it).
  for _, spec in ipairs(emitted) do
    if spec.ppqL < endL and spec.endppqL > startL then occupy(spec.lane, spec.ppqL, spec.endppqL) end
  end
  for _, spec in ipairs(derived) do
    local lane = 1
    while not laneFree(lane, spec.ppqL, spec.endppqL) do lane = lane + 1 end
    occupy(lane, spec.ppqL, spec.endppqL)
    spec.lane = lane
  end
end
-- A parked event as a generator stream note: it sounds to its render clip, never to the authored
-- ceiling on endppq -- the field the view edits. Mirrors membersOf' shape for on-take notes.
local function soundingEvent(evt)
  return util.assign(util.clone(evt), { endppq = evt.endppqC })
end

-- A note host as fx expansion runs it: derived notes ride the host's lane/delay/sample.
local function hostFromNote(host, windowEnd, lane)
  return { window = { host.ppq, windowEnd }, notes = { host }, fx = host.fx,
           id = host.uuid, lane = lane, delay = host.delay,
           sample = host.sample, delayPpq = delayToPPQ(host.delay) }
end

-- The pass's fx windows, held once: one window per host -- authored region, on-take note or parked
-- note -- and the per-target list a view over them. see docs/trackerManager.md § Fx window census
--shape: window -> { uuid, chan, ppq, endppq, fx, hostType = 'note'|'region', targets }
local function buildFxWindows(fxRegions, noteHostClips, time)
  local windows = {}
  -- Every window is minted here rather than taken by reference: a target set is no part of the
  -- document, and a stored region must not acquire one.
  local function hold(window)
    window.targets = generators.chainTargets(window)
    util.add(windows, window)
  end

  for _, r in ipairs(fxRegions) do
    hold({ uuid = r.uuid, chan = r.chan, ppq = r.ppq, endppq = r.endppq,
           fx = r.fx, hostType = 'region' })
  end
  -- Every fx host, on-take and parked alike, gets a window; sort order matches both halves
  -- of a lane so parking moves no entry. See docs/trackerManager.md § Fx window census.
  local noteHosts = {}
  for host, clip in pairs(noteHostClips) do util.add(noteHosts, { host = host, endppq = clip }) end
  table.sort(noteHosts, function(a, b)
    local ha, hb = a.host, b.host
    if ha.chan ~= hb.chan then return ha.chan < hb.chan end
    if ha.lane ~= hb.lane then return ha.lane < hb.lane end
    if ha.ppq ~= hb.ppq then return ha.ppq < hb.ppq end
    return tostring(ha.uuid) < tostring(hb.uuid)
  end)
  for _, nh in ipairs(noteHosts) do hold(fxWindows.fromNote(nh.host, nh.endppq)) end
  return fxWindows.new(windows, time)
end

-- The stored baseline replayed into the same doors (docs/trackerManager.md § Fx window census).
--shape: replayed window -> { uuid, chan, ppq, endppq, targets }
--invariant: first-appearance order, so perTarget() reproduces the stored list exactly
local function buildRealisedWindows(entries, time)
  local windows, byUuid = {}, {}
  for _, entry in ipairs(entries or {}) do
    local window = byUuid[entry.id]
    if not window then
      window = { uuid = entry.id, chan = entry.chan, targets = {},
                 ppq = entry.ppq, endppq = entry.endppq }
      byUuid[entry.id] = window
      util.add(windows, window)
    end
    window.targets[entry.evType == 'cc' and entry.cc or entry.evType] = true
  end
  return fxWindows.new(windows, time)
end

----- Rebuild Fx

--shape: clipNoteHosts -> { [event] = clipEndL }; each clip starts at its event's own onset
--contract: every fx host of every channel, the on-take events and the parked ones alike
local function clipNoteHosts(time)
  local clips, takeLen = {}, time:length()

  -- Column walk where no uuid can be resolved to an event: a wholesale-dirty channel.
  -- see docs/trackerManager.md § Lane occupancy
  local function walkChannel(chan, takeLenL)
    for _, col in ipairs(frame.channels[chan].onTake.notes) do
      for _, evt in ipairs(col.events) do
        if evt.fx and evt.evType ~= 'pa' then clips[evt] = clipEnd(evt, takeLenL) end
      end
    end
  end

  -- Per-host seek through the index over the on-take half; the frame's parked list says which host
  -- moved. Returns false to fall to walkChannel. See docs/trackerManager.md § Fx window census.
  local function perHost(chan, takeLenL)
    local parked = {}
    for _, evt in ipairs(frame.channels[chan].parked.notes) do parked[evt.uuid] = true end
    for uuid in pairs(index.fxHosts(chan)) do
      if not parked[uuid] then
        local evt = index.colEvtFor(uuid)
        if not evt then return false end
        clips[evt] = clipEnd(evt, takeLenL)
      end
    end
    return true
  end

  for chan = 1, 16 do
    local takeLenL = time:toLogical(chan, takeLen)
    local hosts    = index.fxHosts(chan)
    local hasHosts = hosts and next(hosts)
    if dirt.wholesale(chan) then
      if hasHosts then walkChannel(chan, takeLenL) end
    elseif hasHosts then
      if not perHost(chan, takeLenL) then walkChannel(chan, takeLenL) end
    end
    -- The parked half of the lane: a stashed host runs its chain off-take, and a host this pass
    -- restores is here until the park stage re-enters it.
    for _, evt in ipairs(frame.channels[chan].parked.notes) do
      if evt.fx then clips[evt] = clipEnd(evt, takeLenL) end
    end
  end
  return clips
end

-- Fx expansion: fx-carrying notes / fx-regions -> derived notes, CCs; reconcile vs existing,
-- note existence ops leave as data on fxOut.noteOps. see docs/generators.md § Offline continuous realisation
--contract: notesByHost is carried between passes, so the stage writes the channels it ran and
-- leaves a frozen channel's lists standing
local function rebuildFx(noteExisting, ccExisting, noteHostClips, windows, fxRegions, notesByHost,
                         pbLimCents, time)
  local gridStep = ccGridStep()
  -- Columns must be ppq-ordered here (eachWindowNote / allocateRegionLanes / membersOf read col.events
  -- directly); the writers seat in order and nothing since reorders. see docs § Logical projection

  -- noteHostClips' keys are every fx host; the frame's parked lists say which are off-take, run from
  -- their stash events. The rest bucket by channel, (lane, ppq)-sorted. See § Fx window census.
  local parkedNow = parkedUuids()
  local fxHostsByChan = {}
  for host in pairs(noteHostClips) do
    if not parkedNow[host.uuid] then
      local bucket = fxHostsByChan[host.chan]
      if not bucket then bucket = {}; fxHostsByChan[host.chan] = bucket end
      util.add(bucket, host)
    end
  end
  for _, bucket in pairs(fxHostsByChan) do
    table.sort(bucket, function(a, b)
      if a.lane ~= b.lane then return a.lane < b.lane end
      return a.ppq < b.ppq
    end)
  end

  local res = mm:resolution()
  -- Strict next same-lane note (slide's only consumer): lane occupancy is column union parked, and
  -- the subject is the host's lane, so a region (no lane) resolves nil. see docs/trackerManager.md § Span-covered fx scans
  local function nextSameLaneNote(host)
    local note = host.notes[1]
    if not note or not host.lane then return nil end
    return frame.nextOnLane(host.chan, host.lane, note.ppq)
  end
  -- No notation in here: a generator's pitch demands are cents, so the temper is read by the gestures
  -- that author them and never by this pass. see docs/generators.md § The ctx discipline

  -- slide clamps its target to what pb can reach
  local chanCtx = { resolution = res, pbRangeCents = pbLimCents,
                    nextSameLaneNote = nextSameLaneNote }
  -- Explicit fx-regions (channel x ppq span + fx, no host note), re-queried each
  -- rebuild and bucketed by channel. see docs/generators.md § Hosts and membership
  local fxRegionsByChan = {}
  for _, region in ipairs(fxRegions or {}) do
    util.bucket(fxRegionsByChan, region.chan, region)
  end

  -- Host-owned outputs: live notes, existence ops (dels/adds) awaiting the walk, per-chain pb curves, authored
  -- pb base, and the per-chan pb emit scope (nil = ungated) steering rebuildPbs' live/kept split.
  local fxOut = { noteLive = emptyChans(), noteOps = { dels = {}, adds = {} },
                  pbChains = emptyChans(), pbBase = emptyChans(), pbScope = {} }

  -- reconcileFx's sink: ops cross to the tail walk as inspectable data, not staged batch state --
  -- the walk seats them in its own batch.
  local noteOps = fxOut.noteOps
  local noteOpsSink = { del = function(e)    util.add(noteOps.dels, e)    end,
                        add = function(spec) util.add(noteOps.adds, spec) end }

  -- Pass A: run every chain as a series -- each stage folds into the stream by mode x dest, and
  -- the final owned channels emit. see docs/generators.md § The chain
  local function expandChannel(chan)
    local predicted, ccLive = {}, {}
    local pbBase, ccBases   -- assigned after host enumeration: bases cover host windows
    -- Per-chain continuous records: one absolute curve + fold mode per chain per owned cc target;
    -- cross-chain overlap layers at emission by storage order (pb folds in rebuildPbs). see docs/generators.md § Multiplicity
    local ccChains = {}
    -- One host interface, three sources: an on-take fx note, a parked fx event, or an explicit
    -- fxRegion; the generator sees none of them. see docs/generators.md § Hosts and membership
    local function runHost(host)
      local startL, endL = host.window[1], host.window[2]
      -- The same host as a generator sees it (generators' `host` argument): untouched membership plus
      -- the windowed channel streams; stream seeds as its copy and folds forward stage by stage. see docs/generators.md § The chain
      local pas, ccs, ats, pb = channelStreams(chan, startL, endL, pbBase, ccBases)
      local original = { window = { startL, endL }, chan = chan, lane = host.lane, id = host.id,
                         notes = host.notes, pas = pas, ccs = ccs, ats = ats, pb = pb }
      local stream = util.pick(original, "window chan lane id notes pas ccs ats pb")
      stream.ccs = util.assign({}, original.ccs)   -- folds replace per-target lists; the original's map stays untouched
      local ownsNotes = false
      local owned = {}   -- continuous target ('pb' | cc number) -> true once a stage folded a curve in

      -- Fold a continuous stage into its stream channel: replace overwrites, augment sums its delta on
      -- (exact breakpoint-union). Either way the curve stays absolute over the whole window.
      local function foldContinuous(target, mode, out)
        if owned[target] == nil then owned[target] = false end
        if #out.delta == 0 then return end
        local cur = target == 'pb' and stream.pb or stream.ccs[target] or {}
        -- The stream the stage meets, seeded where the target carries no automation: a cc rests at its
        -- controller's rest, pb at centre (an empty curve evaluates 0, which is that rest).
        if #cur == 0 and target ~= 'pb' then
          cur = { { ppq = startL, val = generators.restFor(target), shape = 'step' } }
        end
        local inherited = cur
        if mode == 'replace' then cur = curves.foldIntoWindow(out.delta, startL, endL)
        else                      cur = curves.sumStreams(cur, { out.delta }, { startL, endL }, gridStep) end
        -- One rule for both modes: whatever the stage did inside its window, the target leaves it reading
        -- as the stage found it. A generator cannot bend the channel past its own end.
        cur = curves.closeAtWindowEnd(cur, curves.eval(inherited, endL), startL, endL)
        owned[target] = true
        if target == 'pb' then stream.pb = cur else stream.ccs[target] = cur end
      end

      for _, params in ipairs(host.fx) do
        local meta = generators.kinds[params.kind]
        if meta then
          local dest = generators.destOf(params)
          -- Ownership is registered below, so an early skip would drop the chain's record; both modes'
          -- identity is augment-with-no-output. See docs/generators.md § The chain.
          local out  = params.bypass and { notes = {}, delta = {} } or meta.expand(stream, original, params, chanCtx)
          local mode = params.bypass and 'augment' or meta.mode
          if dest == 'note' then
            ownsNotes = true
            if mode == 'replace' then stream.notes = out.notes
            else
              local merged = {}
              for _, hit in ipairs(stream.notes) do util.add(merged, hit) end
              for _, hit in ipairs(out.notes)    do util.add(merged, hit) end
              stream.notes = merged
            end
          else
            foldContinuous(dest, mode, out)
          end
        end
      end

      -- Emission is ownership: one record per owned continuous target, the chain's final curve. An
      -- untouched chain re-seats its parked base; an all-zero pb curve empties to a pure re-centre record.
      for target, contributed in pairs(owned) do
        if target == 'pb' then
          local curve = stream.pb
          if not contributed and not curves.anyNonZero(curve) then curve = {} end
          util.add(fxOut.pbChains[chan], { window = { startL, endL }, curve = curve,
                                        mode = generators.chainDestType(host.fx, target) })
        else
          util.bucket(ccChains, target,
                      { window = { startL, endL }, curve = stream.ccs[target] or {},
                        mode = generators.chainDestType(host.fx, target) })
        end
      end
      -- Only a note-dest stage's chain emits (parksNotes mirrors this). Region hosts (lane
      -- unset) defer to batch lane allocation below; note hosts ride their own lane inline.
      if not ownsNotes then return end
      local regionNotes = host.lane == nil and {} or nil
      for _, hit in ipairs(stream.notes) do
        util.add(regionNotes or predicted, {
          evType = 'note', chan = chan, lane = host.lane, derived = host.id,
          pitch = hit.pitch, vel = hit.vel, detune = hit.detune or 0,
          intentCents = hit.intentCents,
          delay = host.delay or 0, sample = host.sample,
          ppqL = hit.ppq, endppqL = hit.endppq,
          ppq    = time:fromLogical(chan, hit.ppq,    host.delayPpq),
          endppq = time:fromLogical(chan, hit.endppq, host.delayPpq),
        })
      end
      if regionNotes then
        allocateRegionLanes(chan, startL, endL, regionNotes, predicted)
        for _, spec in ipairs(regionNotes) do util.add(predicted, spec) end
      end
    end

    -- Host gate: under interval dirt an unseeded host outside every emit scope it feeds keeps
    -- its output verbatim -- notes self-match by fxKey, seats re-feed the reconcile. see design § phase 5
    local gated = not dirt.wholesale(chan)
    local keptById, dirtyRows
    local keptFx = {}   -- identity set: derived specs re-added verbatim, already settled last pass
    local seeded, emitScope = {}, {}
    if gated then dirtyRows = seedRowsFor(dirt.has(chan)) end
    -- keptById feeds only runOrKeep's keep branch; an all-run channel never reads it, so defer the
    -- noteExisting walk to the first keep.
    local function keptFor()
      if not keptById then
        keptById = {}
        for _, kept in ipairs(noteExisting[chan]) do util.bucket(keptById, kept.derived, kept) end
      end
      return keptById
    end
    -- A clean overlapper still runs (its curve is a fold input inside the overlap) but the narrowed
    -- emission drops its own remainder.
    local function keepable(host)
      local targets = generators.continuousTargets(host.fx)
      for target in pairs(targets) do
        if spans.intersects(emitScope[target], host.window) then return false end
      end
      return true
    end
    local function runOrKeep(host)
      if gated and not seeded[host] and keepable(host) then
        for _, kept in ipairs(keptFor()[host.id] or {}) do
          util.add(predicted, kept); keptFx[kept] = true
        end
        -- A kept pb window still records its geometry: pb seats are markerless downstream, so a
        -- vanished window would read them as authored pbs.
        if generators.continuousTargets(host.fx).pb then
          util.add(fxOut.pbChains[chan], { window = { host.window[1], host.window[2] }, kept = true })
        end
      else
        runHost(host)
      end
    end

    -- Host enumeration precedes every run: the continuous-gate scopes below classify each
    -- host against the full set, so the set must exist first.
    local hosts = {}

    -- Note hosts. Only augment ones (continuous kinds) remain on-take -- a discrete-replace host
    -- was parked at 4.5 and runs from its parked event below. Derived notes ride the host lane.
    for _, evt in ipairs(fxHostsByChan[chan] or {}) do
      util.add(hosts, hostFromNote(evt, noteHostClips[evt], evt.lane))
    end

    -- Parked note hosts: note-host replace parks (like a region), so every hit is derived output.
    -- Window is the parked event's realised extent, matching the bounds noteHostClips would apply.
    for _, evt in ipairs(frame.channels[chan].parked.notes or {}) do
      -- A parked event inside a note-park window is region membership, not a note host (own-fx suppressed).

      if evt.fx and not windows.owns('note', chan, nil, evt.ppq) then
        util.add(hosts, hostFromNote(soundingEvent(evt), evt.endppqC, evt.lane))
      end
    end

    -- Region hosts: no note behind them. A discrete-replace kind feeds the realised parked chord
    -- (parking frees the lanes); else members still sound and feed the live overlap. see docs/generators.md § Emission is ownership
    for _, region in ipairs(fxRegionsByChan[chan] or {}) do
      local startL, endL = region.ppq, region.endppq
      local members
      if generators.parksNotes(region) then
        members = {}                             -- replace: derived notes stand in for the parked chord
        for _, evt in ipairs(frame.channels[chan].parked.notes or {}) do
          if evt.ppq >= startL and evt.ppq < endL then util.add(members, soundingEvent(evt)) end
        end
      else
        members = membersOf(chan, startL, endL)  -- augment: members still sound
      end
      util.add(hosts, { window = { startL, endL }, notes = members,
                            fx = region.fx, id = region.uuid, lane = nil, delayPpq = 0 })
    end

    -- Emit scope per target = merged windows of the seeded hosts touching it; the cc fold and
    -- reconcile clip to it. Clean windows never enter ccExisting, so their seats keep untouched.
    if gated then
      -- Hold-stream reach: authored pb/cc breakpoints and lane-1 detune hold forward past window
      -- edges, invisible to window-local seeds.
      local baseHoldFrom, detuneHoldFrom = math.huge, math.huge
      for _, s in ipairs(dirt.has(chan)) do
        if s.pitch == nil or s.lane == 1 then
          local from = s.ppqL
          local liveEvt = s.uuid and index.byUuid(s.uuid)
          if liveEvt then from = math.min(from, liveEvt.ppqL or liveEvt.ppq) end
          if s.pitch == nil then baseHoldFrom   = math.min(baseHoldFrom, from) end
          if s.lane  == 1   then detuneHoldFrom = math.min(detuneHoldFrom, from) end
        end
      end
      local pbHoldFrom = math.min(baseHoldFrom, detuneHoldFrom)
      local function emitsLane1Notes(host)
        if host.lane ~= nil and host.lane ~= 1 then return false end
        return generators.parksNotes(host)
      end
      local function holdSensitive(host, targets)
        if targets.pb and host.window[2] > pbHoldFrom then return true end
        for target in pairs(targets) do
          if target ~= 'pb' and host.window[2] > baseHoldFrom
             and generators.chainDestType(host.fx, target) == 'augment' then return true end
        end
        return false
      end
      local targetsOf = {}
      for _, host in ipairs(hosts) do
        targetsOf[host] = generators.continuousTargets(host.fx)
        seeded[host] = windowSeeded(dirtyRows, host.window[1], host.window[2])
      end
      -- Fixpoint: a live lane-1 note-emitter re-detunes the stream from its window start, which can
      -- wake pb windows further right, which may themselves emit lane-1 notes.
      local changed = true
      while changed do
        changed = false
        for _, host in ipairs(hosts) do
          if seeded[host] and emitsLane1Notes(host) and host.window[1] < pbHoldFrom then
            pbHoldFrom = host.window[1]; changed = true
          end
          if not seeded[host] and holdSensitive(host, targetsOf[host]) then
            seeded[host] = true; changed = true
          end
        end
      end
      local emitWins = {}
      for _, host in ipairs(hosts) do
        if seeded[host] then
          for target in pairs(targetsOf[host]) do util.bucket(emitWins, target, host) end
        end
      end
      for target, group in pairs(emitWins) do emitScope[target] = spans.mergeWindows(group) end
      fxOut.pbScope[chan] = emitScope.pb or {}
    end

    -- Bases cover only the hosts runOrKeep will actually run: a kept host reads no base (its
    -- output re-adds verbatim); every running host's window feeds channelStreams. see design § 5
    local running = {}
    for _, host in ipairs(hosts) do
      if not gated or seeded[host] or not keepable(host) then util.add(running, host) end
    end
    local runWins = spans.mergeWindows(running)
    pbBase, ccBases = pbBaseFor(chan, runWins, time), ccBasesFor(chan, runWins)
    fxOut.pbBase[chan] = pbBase

    for _, host in ipairs(hosts) do runOrKeep(host) end

    -- Reconcile existence (stamps kept specs with the mm handle + realised end); ops land on
    -- fxOut.noteOps. fxOut.noteLive holds the predicted specs; the tail walk clips them in place.
    reconcileFx(noteExisting[chan], predicted, noteOpsSink)
    local fxNotes = {}
    for _, spec in ipairs(predicted) do
      util.add(fxOut.noteLive[chan], { evt = spec, lane = spec.lane, kept = keptFx[spec] or nil })
      -- A copy, not the spec: the tail walk clamps raw onsets and clips ends in these in place below.
      util.add(fxNotes, { evType = 'note', chan = chan, lane = spec.lane, ppq = spec.ppqL,
                          pitch = spec.pitch, vel = spec.vel, detune = spec.detune,
                          intentCents = spec.intentCents,
                          delay = spec.delay, derived = spec.derived })
    end
    -- One sort per rebuild against many windowed reads; lane then pitch break onset collisions stably.
    table.sort(fxNotes, function(a, b)
      if a.ppq ~= b.ppq then return a.ppq < b.ppq end
      if a.lane ~= b.lane then return a.lane < b.lane end
      return a.pitch < b.pitch
    end)
    -- Bucketed after the sort, so each host's list inherits the onset order.
    local byHost = {}
    for _, n in ipairs(fxNotes) do util.bucket(byHost, n.derived, n) end
    notesByHost[chan] = byHost

    -- cc emission: fold (curves.foldChains) into markerless seats, clipped to the emit scope; half-open --
    -- the closing value belongs to the kept side.
    for cc, recs in pairs(ccChains) do
      local base = ccBases[cc] or {}
      if #base == 0 then
        local rest, minStart = generators.restFor(cc), math.huge
        for _, rec in ipairs(recs) do minStart = math.min(minStart, rec.window[1]) end
        base = { { ppq = minStart, val = rest, shape = 'step' } }
      end
      for _, span in ipairs(spans.mergeWindows(recs)) do
        for _, emitSpan in ipairs(gated and spans.clip(span, emitScope[cc]) or { span }) do
          for _, point in ipairs(curves.foldChains(recs, emitSpan, base, gridStep)) do
            if point.ppq >= emitSpan[1] and point.ppq < emitSpan[2] then
              util.add(ccLive, { evType = 'cc', chan = chan, cc = cc,
                                 ppq = time:fromLogical(chan, point.ppq, 0),
                                 val = util.clamp(util.round(point.val), 0, 127),
                                 shape = point.shape, tension = point.tension })
            end
          end
        end
      end
    end

    local wires = mmBatch()
    -- fx cc events: reconcile the summed/replace seats on the target lane; shape is part of the match --
    -- it drives REAPER's interpolation. see docs/generators.md § pb and cc
    reconcileDerived{
      existing = ccExisting[chan], predicted = ccLive, sink = wires,
      key   = function(x) return util.key(x.cc, x.ppq) end,
      match = function(have, spec)
        return have.val == spec.val and have.shape == spec.shape and have.tension == spec.tension
      end,
    }

    wires.commit()
  end

  for chan = 1, 16 do
    -- Frozen: derived notes/CCs stand untouched in mm; leave noteLive empty so tails/pbs/pcs skip too.
    if dirt.has(chan) then expandChannel(chan) end
  end
  return fxOut
end

----- Rebuild tails

-- Unified tail/onset walk + atomic commit: real notes, fixed externals, noteLive
-- walk together (onset clamp then tail clip); host clip + fxNote del/add in one mm:modify. see docs/trackerManager.md § Tail walk
--contract: separates and bounds disturbed notes only; a nudged lane-1 onset emits its seat closure
-- The per-note settle and bound rules as a factory over ctx: both the linear and frontier walks inject
-- their batches and marking tables and drive the same rules over their own state.
--shape: ctx = { chan, res, time, disturbed, nudged, clampWrites, tailWrites, parkedBoundFor }
local function makeTailRules(ctx)
  local chan, res, time = ctx.chan, ctx.res, ctx.time
  local takeLen = time:length()
  local disturbed, nudged = ctx.disturbed, ctx.nudged
  local clampWrites, tailWrites, parkedBoundFor = ctx.clampWrites, ctx.tailWrites, ctx.parkedBoundFor

  local function settleOnset(e, prev)
    local onset = voicing.separateOnset(e, prev)
    if not onset then return false end
    -- A nudge is final where it lands -- notes only ever give way forward -- so the cue and
    -- the clamp write stage here rather than in a second pass over a moved set.
    index.assign(e, 'ppq', onset)
    disturbed[e], nudged[e] = true, true
    local backing = e.colEvt or e   -- seated entries write through to their column note; fxNotes ride bare
    if e.colEvt and e.colEvt.delay ~= nil then
      -- The column stays logical; only the delayC give-way cue carries the raw shift.
      local shift = e.ppq - time:fromLogical(chan, e.ppqL)
      frame.setEvent(e.colEvt, 'delayC', util.round(timing.ppqToDelay(shift, res)))
    end
    if backing.realised then clampWrites.assign(backing, { ppq = e.ppq }) end
    return true
  end

  local function boundNote(e, laneNext, pitchNext)
    local onTake  = not e.derived
    local ceiling = e.endppqL == util.OPEN and math.huge
                    or e.endppqL and time:fromLogical(chan, e.endppqL)
                    or math.huge
    -- On-take tails clip against parked members' lanes too -- the columns no longer carry the event,
    -- but the lane geometry still does. See docs/trackerManager.md § Tail walk.
    local laneAnchor = laneNext
    if onTake then
      local parked = parkedBoundFor(e)
      if parked and (laneAnchor == nil or parked.ppq < laneAnchor.ppq) then laneAnchor = parked end
    end
    local laneClip  = laneAnchor
      and time:fromLogical(chan, laneAnchor.ppqL) + (e.overlap or 0)
      or math.huge
    local pitchClip = pitchNext and pitchNext.ppq or math.huge
    -- Two bounds: the lane bound is intent and drives the column; the raw bound clips it to the next
    -- same-pitch onset and alone reaches mm. see docs/trackerManager.md § Tail walk
    local laneBound = math.max(e.ppq + 1, math.min(ceiling, laneClip, takeLen))
    local rawBound  = math.max(e.ppq + 1, math.min(laneBound, pitchClip))
    local rounded   = util.round(rawBound)
    if rounded ~= e.endppq then
      local backing = e.colEvt or e
      if backing.realised then tailWrites.assign(backing, { endppq = rounded }) end
      index.assign(e, 'endppq', rounded)
    end
    if e.colEvt then
      -- Mirror projectEvent's endppq rule: authored ceiling shows, lane-clipped ceiling rides endppqC.
      local endppqC = time:toLogical(chan, util.round(laneBound))
      frame.setEvent(e.colEvt, 'endppqC', endppqC)
      frame.setEvent(e.colEvt, 'endppq', e.endppqL == util.OPEN and util.OPEN or e.endppqL or endppqC)
    end
  end

  return settleOnset, boundNote
end

-- The seed-driven tail walk over the whole channel: the degenerate fallback for dense and wholesale
-- dirt, chosen over the frontier by seed count. see docs/trackerManager.md § Tail walk
local function linearTails(chan, notes, parkedBoundFor, time, res, clampWrites, tailWrites, keptDerived)
  local disturbed, nudged = {}, {}
  local settleOnset, boundNote = makeTailRules{
    chan = chan, res = res, time = time,
    disturbed = disturbed, nudged = nudged,
    clampWrites = clampWrites, tailWrites = tailWrites, parkedBoundFor = parkedBoundFor,
  }

  -- Disturbed seeded by name: derived membership + the seeds themselves, survivors resolved by uuid,
  -- adds by logical seat. Anchors for the bound probes: seed positions (dead included) plus disturbed onsets.
  local anchors = {}
  -- A kept fx spec (gate-verbatim, unchanged since last pass) is already settled and clipped: it
  -- rides as a bound anchor only, never a fresh disturbance. see docs/trackerManager.md § Tail walk
  for _, e in ipairs(notes) do if e.derived and not keptDerived[e] then disturbed[e] = true end end
  if dirt.wholesale(chan) then
    for _, e in ipairs(notes) do disturbed[e] = true end   -- degenerate pass: load, external change
  else
    local noteByUuid, bySeat = {}, {}
    for _, e in ipairs(notes) do
      if e.uuid then noteByUuid[e.uuid] = e end
      util.bucket(bySeat, seatKey(e.ppqL or e.ppq, e.lane, e.pitch), e)
    end
    for _, seed in ipairs(dirt.has(chan)) do
      util.add(anchors, { pos = seed.ppq, lane = seed.lane, pitch = seed.pitch })
      local rec = seed.uuid and noteByUuid[seed.uuid]
      if rec then disturbed[rec] = true
      else
        for _, e in ipairs(bySeat[seatKey(seed.ppqL or seed.ppq, seed.lane, seed.pitch)] or {}) do
          disturbed[e] = true
        end
      end
    end
  end

  -- Onset settlement: only a disturbed note collides, onto its same-pitch predecessor; a landed nudge
  -- marks itself disturbed so the cascade carries forward.
  local anyNudge, lastByPitch = false, {}
  index.withDeferredSort(function()
    for _, e in ipairs(notes) do
      local prev = lastByPitch[e.pitch]
      if disturbed[e] or (prev and disturbed[prev]) then
        if settleOnset(e, prev) then anyNudge = true end
      end
      lastByPitch[e.pitch] = e
    end
  end)
  -- um re-trued its own list at the block's close; this pass's merge shares those records, so it
  -- carries the same stain and re-trues here.
  if anyNudge then table.sort(notes, index.order) end

  -- Bound set: every disturbed note, plus the nearest same-lane and same-pitch strict predecessor of
  -- every anchor -- the seed-driven replacement for the span stale-test. see design § Span-staleness
  local bound = {}
  for e in pairs(disturbed) do bound[e] = true end
  -- Wholesale already binds every note, so the predecessor probes add nothing. Only the seeded case
  -- needs them, to reach the non-disturbed neighbours dirt shadows.
  if not dirt.wholesale(chan) then
    for e in pairs(disturbed) do util.add(anchors, { pos = e.ppq, lane = e.lane, pitch = e.pitch }) end
    -- One ascending sweep, tracking running last-in-lane/last-in-pitch, answers every anchor at
    -- once -- the forward twin of the successor pass below. See docs/trackerManager.md § Tail walk.
    table.sort(anchors, function(a, b) return a.pos < b.pos end)
    local lastInLane, lastInPitch, i = {}, {}, 1
    for _, a in ipairs(anchors) do
      while i <= #notes and notes[i].ppq < a.pos do
        local e = notes[i]
        lastInLane[e.lane], lastInPitch[e.pitch] = e, e
        i = i + 1
      end
      local lanePred, pitchPred = lastInLane[a.lane], lastInPitch[a.pitch]
      if lanePred  then bound[lanePred]  = true end
      if pitchPred then bound[pitchPred] = true end
    end
  end

  -- Bounds + nudge emission: one backward pass hands over next-in-lane and next-in-pitch (running
  -- state keyed by lane and pitch), the stale test replaced by `bound` membership. see design § Phase 4
  local emitted = {}
  local nearestInLane,  nextAfterLane  = {}, {}
  local nearestInPitch, nextAfterPitch = {}, {}
  for i = #notes, 1, -1 do
    local e = notes[i]
    local laneAbove, pitchAbove = nearestInLane[e.lane], nearestInPitch[e.pitch]
    -- A neighbour sharing e's raw is no successor of it: it hands over its own.
    local laneNext  = laneAbove  and (laneAbove.ppq  > e.ppq and laneAbove  or nextAfterLane[e.lane])
    local pitchNext = pitchAbove and (pitchAbove.ppq > e.ppq and pitchAbove or nextAfterPitch[e.pitch])
    nearestInLane[e.lane],   nextAfterLane[e.lane]   = e, laneNext
    nearestInPitch[e.pitch], nextAfterPitch[e.pitch] = e, pitchNext

    -- The walk's own dirt: a nudged lane-1 onset seeds every absorber seat up to the next lane-1
    -- onset, for pbs to consume later this pass. see design § The widen and the emission are the same fact
    if nudged[e] and e.lane == 1 then
      util.add(emitted, { uuid = e.uuid, verb = 'nudge', ppq = e.ppq, ppqL = e.ppqL,
                          lane = e.lane, pitch = e.pitch, endppqL = laneNext and laneNext.ppqL })
    end
    if bound[e] then boundNote(e, laneNext, pitchNext) end
  end

  return emitted
end

----- Frontier probe walk

-- Above this many disturbed seeds (dirt + derived fx events) the frontier's per-seed probes cost more
-- than the linear walk's single channel pass, so the tail rebuild routes to linear. see design § The degenerate case gates on seed count
local FRONTIER_SEED_CAP = 16

-- First index into the raw-then-logical-sorted `list` with ppq >= `pos`; #list+1 if none. Every frontier
-- probe binary-searches here, then scans outward a bounded few rows -- the seek that replaces the sweep.
local function lowerBound(list, pos)
  local lo, hi = 1, #list + 1
  while lo < hi do
    local mid = (lo + hi) // 2
    if list[mid].ppq < pos then lo = mid + 1 else hi = mid end
  end
  return lo
end
-- First index with ppq > `pos`: the far edge of pos's raw cluster.
local function upperBound(list, pos)
  local lo, hi = 1, #list + 1
  while lo < hi do
    local mid = (lo + hi) // 2
    if list[mid].ppq <= pos then lo = mid + 1 else hi = mid end
  end
  return lo
end

-- Nearest walkable record strictly on one `side` of `pos` (raw ppq) matching `filter`, over the index
-- (binary-searched, scanned outward) and the small extras. The strict-ppq bound probe; mirrors util.seek.
local function nearestNote(indexList, extras, pos, side, filter)
  local best
  local anchor = lowerBound(indexList, pos)
  if side == 'before' then
    for i = anchor - 1, 1, -1 do
      local rec = indexList[i]
      if walkable(rec) and filter(rec) then best = rec; break end
    end
  else
    for i = anchor, #indexList do
      local rec = indexList[i]
      if rec.ppq > pos and walkable(rec) and filter(rec) then best = rec; break end
    end
  end
  for _, rec in ipairs(extras) do
    local onSide = side == 'before' and rec.ppq < pos or side == 'after' and rec.ppq > pos
    local nearer = best == nil
                   or (side == 'before' and index.order(best, rec))
                   or (side == 'after'  and index.order(rec, best))
    if onSide and filter(rec) and nearer then best = rec end
  end
  return best
end

-- Same-pitch record immediately before `node` in the total order, over index + extras -- settlement's
-- predecessor. A same-tick same-pitch note counts here (unlike the strict bound probes).
local function prevSamePitch(indexList, extras, node)
  local best
  for i = upperBound(indexList, node.ppq) - 1, 1, -1 do
    local rec = indexList[i]
    if walkable(rec) and rec ~= node and rec.pitch == node.pitch and index.order(rec, node) then
      best = rec; break
    end
  end
  for _, rec in ipairs(extras) do
    if rec ~= node and rec.pitch == node.pitch and index.order(rec, node)
       and (best == nil or index.order(best, rec)) then best = rec end
  end
  return best
end

-- Same-pitch record immediately after `node` in the total order, keyed on `origPpq` (node's raw before
-- this pass nudged it) -- settlement's cascade successor. see design § Nudge probes stop at the tick
local function nextSamePitch(indexList, extras, node, origPpq)
  local key = { ppq = origPpq, ppqL = node.ppqL, derived = node.derived, lane = node.lane, pitch = node.pitch }
  local best
  for i = lowerBound(indexList, origPpq), #indexList do
    local rec = indexList[i]
    if walkable(rec) and rec ~= node and rec.pitch == node.pitch and index.order(key, rec) then
      best = rec; break
    end
  end
  for _, rec in ipairs(extras) do
    if rec ~= node and rec.pitch == node.pitch and index.order(key, rec)
       and (best == nil or index.order(rec, best)) then best = rec end
  end
  return best
end

-- On-take records at a seed's logical seat, for adds/deletes carrying no surviving uuid. Scans only the
-- seed's raw-ppq cluster in the sorted index (plus extras) -- bounded, not a channel sweep.
local function seatMatches(indexList, extras, seed)
  local out, key = {}, seed.ppqL or seed.ppq
  local function match(rec)
    return (rec.ppqL or rec.ppq) == key and rec.lane == seed.lane and rec.pitch == seed.pitch
  end
  for i = lowerBound(indexList, seed.ppq), #indexList do
    if indexList[i].ppq ~= seed.ppq then break end
    if match(indexList[i]) then util.add(out, indexList[i]) end
  end
  for _, rec in ipairs(extras) do if rec.ppq == seed.ppq and match(rec) then util.add(out, rec) end end
  return out
end

-- The frontier probe walk: seek to each seed, probe a bounded few rows for its neighbours, drive the
-- shared settle/bound rules -- no whole-channel traversal.
local function frontierTails(chan, indexList, extras, parkedBoundFor, time, res,
                             clampWrites, tailWrites, keptDerived)
  local disturbed, nudged = {}, {}
  local settleOnset, boundNote = makeTailRules{
    chan = chan, res = res, time = time,
    disturbed = disturbed, nudged = nudged,
    clampWrites = clampWrites, tailWrites = tailWrites, parkedBoundFor = parkedBoundFor,
  }

  -- Disturbed seeded by name: derived membership is all of extras; adds/deletes name a seat the
  -- index tick cluster answers; byUuid resolve is note-scoped -- see docs § What the walk visits, and what it emits.
  local anchors = {}
  for _, rec in ipairs(extras) do if rec.derived and not keptDerived[rec] then disturbed[rec] = true end end
  for _, seed in ipairs(dirt.has(chan)) do
    util.add(anchors, { pos = seed.ppq, lane = seed.lane, pitch = seed.pitch })
    local rec = seed.uuid and index.byUuid(seed.uuid)
    if rec and rec.evType == 'note' and rec.chan == chan then disturbed[rec] = true
    else for _, hit in ipairs(seatMatches(indexList, extras, seed)) do disturbed[hit] = true end end
  end

  -- Phase 1 -- settle onsets, same-pitch-local (a nudge only collides same-pitch successors). Each
  -- pitch's cascade chain gathers on the pristine index, then settles by position. See docs § What the walk visits.
  local byPitch, chains = {}, {}
  for e in pairs(disturbed) do util.bucket(byPitch, e.pitch, e) end
  for _, seeds in pairs(byPitch) do
    table.sort(seeds, index.order)
    local si = 1
    while si <= #seeds do
      local head = seeds[si]; si = si + 1
      local prev = prevSamePitch(indexList, extras, head)
      local chain = {}
      if prev then util.add(chain, prev) end
      util.add(chain, head)
      -- reach = the running worst-case settled tick; a same-pitch successor cascades only while it can
      -- still collide (separateOnset gives way by one tick), or when it is itself a pending seed.
      local reach = (prev and head.ppq <= prev.ppq) and prev.ppq + 1 or head.ppq
      local node = head
      while true do
        local nxt = nextSamePitch(indexList, extras, node, node.ppq)
        if not nxt then break end
        local isSeed = nxt == seeds[si]
        if nxt.ppq > reach and not isSeed then break end
        util.add(chain, nxt)
        reach = nxt.ppq <= reach and reach + 1 or nxt.ppq
        if isSeed then si = si + 1 end
        node = nxt
      end
      util.add(chains, chain)
    end
  end

  -- The block wraps settlement alone: the chains above gathered against the pristine index, and phase
  -- 2's bound probes below need it true again, so a block around the whole walk would be too late.
  local anyNudge = false
  index.withDeferredSort(function()
    for _, chain in ipairs(chains) do
      for i, node in ipairs(chain) do
        local prev = chain[i - 1]
        if disturbed[node] or (prev and disturbed[prev]) then
          if settleOnset(node, prev) then anyNudge = true end
        end
      end
    end
  end)
  -- indexList is um's own and the block's close re-trued it; extras belongs to this walk.
  if anyNudge then table.sort(extras, index.order) end

  -- Phase 2 -- bounds, order-free: every disturbed note plus each anchor's nearest same-lane and same-
  -- pitch strict predecessor re-bind. Bounds read settled onsets, write only endppq -- no re-disturb.
  local bound = {}
  for e in pairs(disturbed) do
    bound[e] = true
    util.add(anchors, { pos = e.ppq, lane = e.lane, pitch = e.pitch })
  end
  for _, a in ipairs(anchors) do
    local lanePred  = nearestNote(indexList, extras, a.pos, 'before', function(r) return r.lane  == a.lane  end)
    local pitchPred = nearestNote(indexList, extras, a.pos, 'before', function(r) return r.pitch == a.pitch end)
    if lanePred  then bound[lanePred]  = true end
    if pitchPred then bound[pitchPred] = true end
  end

  -- A nudged lane-1 seat emits its closure to the next lane-1 onset -- the lane successor the bound
  -- probe already fetched. see design § The widen and the emission are the same fact
  local emitted = {}
  for e in pairs(bound) do
    local laneNext  = nearestNote(indexList, extras, e.ppq, 'after', function(r) return r.lane  == e.lane  end)
    local pitchNext = nearestNote(indexList, extras, e.ppq, 'after', function(r) return r.pitch == e.pitch end)
    if nudged[e] and e.lane == 1 then
      util.add(emitted, { uuid = e.uuid, verb = 'nudge', ppq = e.ppq, ppqL = e.ppqL,
                          lane = e.lane, pitch = e.pitch, endppqL = laneNext and laneNext.ppqL })
    end
    boundNote(e, laneNext, pitchNext)
  end
  return emitted
end

local function rebuildTails(noteLive, noteOps, time)
  local res = mm:resolution()
  local clampWrites = mmBatch()
  -- The walk's own batch, seeded from fx expansion's existence ops -- a fresh spec is unrealised during the walk, so the
  -- clip mutates it in place, reaching mm once already clipped.
  local tailWrites = mmBatch()
  for _, e in ipairs(noteOps.dels) do tailWrites.del(e) end
  for _, spec in ipairs(noteOps.adds) do tailWrites.add(spec) end
  for chan = 1, 16 do
    -- Clean channels freeze: fx left noteLive empty, real notes converged last rebuild.
    if not dirt.has(chan) then goto nextChan end
    -- A kept fx spec is settled from last pass and rides the walk as a bound anchor only; only fresh
    -- (re-run host) derived notes seed disturbance and count toward the frontier cap.
    local extras, keptDerived, freshLive = {}, {}, 0
    for _, w in ipairs(noteLive[chan]) do
      util.add(extras, w.evt)
      if w.kept then keptDerived[w.evt] = true else freshLive = freshLive + 1 end
    end

    -- Parked members left the columns but still bound a preceding on-take tail in their lane --
    -- the symmetric partner of clipParked's on-take bounds. Bound-only: never rewritten below.
    local parkedBounds = {}
    for _, evt in ipairs(frame.channels[chan].parked.notes or {}) do
      util.add(parkedBounds, { ppq = time:fromLogical(chan, evt.ppq), ppqL = evt.ppq,
                               lane = evt.lane })
    end
    -- A handful of events at most, asked only for the notes the walk bounds: scanned, not indexed.
    local function parkedBoundFor(e)
      local nearest
      for _, b in ipairs(parkedBounds) do
        if b.lane == e.lane and b.ppq > e.ppq
           and (nearest == nil or b.ppq < nearest.ppq) then nearest = b end
      end
      return nearest
    end

    -- Sparse edits seek to their seeds; dense edits and wholesale rebuilds walk the channel once. The
    -- frontier takes the sorted index and extras as separate probe sources -- no O(channel) merge.
    local indexedNotes = index.raw(chan).notes
    local emitted
    if not dirt.wholesale(chan) and #dirt.has(chan) + freshLive <= FRONTIER_SEED_CAP then
      emitted = frontierTails(chan, indexedNotes, extras, parkedBoundFor, time, res, clampWrites, tailWrites, keptDerived)
    else
      local notes = mergeIndexed(indexedNotes, walkable, extras)
      if #notes == 0 then goto nextChan end
      emitted = linearTails(chan, notes, parkedBoundFor, time, res, clampWrites, tailWrites, keptDerived)
    end

    -- The walk's own dirt joins what it was given: past the cap the channel collapses to wholesale,
    -- so the stages below it read the same lattice every other writer does.
    dirt.add(chan, emitted)
    ::nextChan::
  end
  -- Clamps commit first: separating colliding same-pitch onsets settles mm's seat keys before
  -- the clip pass runs. Clips only touch endppq — safe to batch with adds.
  clampWrites.commit()
  -- Delete-first still holds: the fx dels precede the adds within the one batch.
  tailWrites.commit()
end

----- Rebuild Pbs

-- A ramp onset's dual point rides one tick before the onset (see docs/tuning.md § Value-aware
-- seats), so every span that must contain an onset's seats reaches one tick back.
local DUAL_POINT_TICK = 1

--shape: door = { detuneAt(ppq), between(lo, hi), first(), nextAfter(ppq), anyDetuneJump() }
-- A channel's lane-1 onset stream: the raw index's authored notes unioned with the pass's derived
-- lane-1 output, which lives off-take in noteLive. see docs/tuning.md § Absorber reconciliation
--pre: derived is ppq-ascending and holds chan's derived lane-1 notes for this pass
local function lane1Union(chan, derived)
  local authored = index.raw(chan).notes   -- every lane, authored and derived alike; filtered at use
  local function lane1Note(entry) return entry.lane == 1 and walkable(entry) end

  -- The union from the first entry at-or-after `lo` ('after' starts past it instead), merging the two
  -- sources by index.order -- one cursor pair, and the only place the union's order is decided.
  --post: result = (fresh iterator) yielding unsafe index entries in index.order
  local function walk(lo, mode)
    local from = mode == 'after' and util.firstAfter or util.firstAtOrAfter
    local i, j = from(authored, lo), from(derived, lo)
    return function()
      while authored[i] and not lane1Note(authored[i]) do i = i + 1 end
      local a, d = authored[i], derived[j]
      if d and (not a or index.order(d, a)) then j = j + 1; return d end
      if a then i = i + 1 end
      return a
    end
  end

  -- The detune prevailing at ppq: the last union entry at-or-before it, 0 before the first.
  local function detuneAt(ppq)
    local i = util.firstAfter(authored, ppq) - 1        -- last index at or before ppq
    while i >= 1 and not lane1Note(authored[i]) do i = i - 1 end
    local a, d = authored[i], derived[util.firstAfter(derived, ppq) - 1]
    local last = a
    if d and (not a or index.order(a, d)) then last = d end
    return last and last.detune or 0
  end

  -- The union's entries with ppq in [lo, hi] -- the onset walk's per-span slice.
  local function between(lo, hi)
    local out = {}
    for entry in walk(lo) do
      if entry.ppq > hi then break end
      util.add(out, entry)
    end
    return out
  end

  -- The channel's first lane-1 onset, the I2a anchor's point.
  local function first() return walk(0)() end

  -- The next lane-1 onset strictly after ppq; math.huge past the last.
  local function nextAfter(ppq)
    local entry = walk(ppq, 'after')()
    return entry and entry.ppq or math.huge
  end

  -- Whether any lane-1 note carries a non-zero detune. With prev seeded 0 an onset exists iff some
  -- detune is non-zero, so this early-exit scan is the whole-channel jump count.
  local function anyDetuneJump()
    for entry in walk(0) do
      if (entry.detune or 0) ~= 0 then return true end
    end
    return false
  end

  return { detuneAt = detuneAt, between = between, first = first,
           nextAfter = nextAfter, anyDetuneJump = anyDetuneJump }
end

-- Replace windows for a channel: each pb chain's fold curve -- live spans folded to derived-seat
-- bps (no carrier), kept spans recognition-only. see docs/tuning.md § Absorber reconciliation
local function replaceWindows(chan, fxOut, gridStep, pbLimCents, time)
  -- Gate split: live ranges (inside the pb emit scope) fold to bps; kept ranges are recognition-
  -- only -- their seats stand on wire.
  local emitSpans = fxOut.pbScope[chan]   -- nil = ungated: every range is live
  local chains, base = fxOut.pbChains[chan], fxOut.pbBase[chan]
  local liveRecs = {}
  for _, rec in ipairs(chains) do
    if not rec.kept then util.add(liveRecs, rec) end
  end
  local wins = {}
  --shape: replaceWin = { bps = [{ ppq, ppqL, cents, shape, tension }], kept, startRaw, endRaw }
  -- Bounds convert to raw once for zero round-trip drift.
  local function addWin(sub, bps, kept)
    util.add(wins, { bps = bps, kept = kept,
                     startRaw = time:fromLogical(chan, sub[1], 0),
                     endRaw   = time:fromLogical(chan, sub[2], 0) })
  end
  for _, span in ipairs(spans.mergeWindows(chains)) do
    for _, sub in ipairs(emitSpans and spans.clip(span, emitSpans) or { span }) do
      local bps = {}
      for _, point in ipairs(curves.foldChains(liveRecs, sub, base, gridStep)) do
        -- Fold fast paths return whole curves, and an interior closing edge belongs to the kept
        -- side (chain cuts align with window edges) -- clip half-open except at the span's true end.
        if point.ppq >= sub[1] and (point.ppq < sub[2] or sub[2] == span[2]) then
          util.add(bps, { ppq = time:fromLogical(chan, point.ppq, 0), ppqL = point.ppq,
                          cents = util.clamp(point.val, -pbLimCents, pbLimCents),
                          shape = point.shape, tension = point.tension })
        end
      end
      util.sortByPPQ(bps)
      addWin(sub, bps, nil)
    end
    for _, sub in ipairs(emitSpans and spans.subtract(span, emitSpans) or {}) do
      addWin(sub, {}, true)
    end
  end

  -- Which window's curve prevails at a raw ppq (half-open -- the interior stream).
  local function replaceWinAt(ppq)
    for _, win in ipairs(wins) do
      if not win.kept and ppq >= win.startRaw and ppq < win.endRaw then return win end
    end
  end
  -- Seat recognition: exclusive ownership means everything on-take in a window is a generated seat
  -- (authored pbs park off-take). Half-open -- the re-centre seat folds at endRaw-1, inside.
  local function inSeatWindow(ppq)
    for _, win in ipairs(wins) do
      if ppq >= win.startRaw and ppq < win.endRaw then return true end
    end
    return false
  end
  -- Kept ownership at a shared edge: a live opening edge belongs to the live side, every other
  -- covered ppq (interior and closing edges) to the kept side. see design § commit 4
  local function inKeptRange(ppq)
    local kept = false
    for _, win in ipairs(wins) do
      if win.kept then
        if ppq >= win.startRaw and ppq <= win.endRaw then kept = true end
      elseif ppq == win.startRaw then
        return false
      end
    end
    return kept
  end

  return { wins = wins, replaceWinAt = replaceWinAt,
           inSeatWindow = inSeatWindow, inKeptRange = inKeptRange }
end

-- Closes seeds to raw spans that gate the pass's onsets/densify/anchor/absorber-pool; nil = ungated.
-- Extents come by seek, ahead of the gather.
local function seatScope(chan, replaceWins, lane1)
  if dirt.wholesale(chan) then return nil end
  local seatSpans = {}
  local function lane1Span(ppq) util.add(seatSpans, { ppq - DUAL_POINT_TICK, lane1.nextAfter(ppq) }) end
  local function bpSpan(ppq)
    -- The authored value stream: non-derived pbs outside every seat window (realPbs' membership).
    local function authored(pb) return not pb.derived and not replaceWins.inSeatWindow(pb.ppq) end
    local prevBp = util.seek(index.raw(chan).pbs, 'before', ppq, authored)
    local nextBp = util.seek(index.raw(chan).pbs, 'after',  ppq, authored)
    util.add(seatSpans, { prevBp and prevBp.ppq or 0, nextBp and nextBp.ppq or math.huge })
  end
  -- A seed the branches below can't close to a span. Notes on other lanes, region verbs and the
  -- cc/at/pc families move no pb seat, so only an unrecognised kind ungates the channel.
  local function unboundedSeed(seed)
    return not (seed.lane or seed.verb == 'region' or seed.evType == 'cc'
                or seed.evType == 'at' or seed.evType == 'pc')
  end
  for _, seed in ipairs(dirt.has(chan)) do
    -- Dedup keeps a move's vacated snapshot; the survivor's live position comes from byUuid
    -- (the frontier walk's convention, see § Seeds arrive named) and spans separately.
    local live = seed.uuid and index.byUuid(seed.uuid)
    if not (live and live.chan == chan) then live = nil end
    if seed.lane == 1 or (live and live.lane == 1) then
      if seed.lane == 1 then lane1Span(seed.ppq) end
      if live and live.lane == 1 and live.ppq ~= seed.ppq then lane1Span(live.ppq) end
    elseif seed.evType == 'pb' then
      bpSpan(seed.ppq)
      if live and live.ppq ~= seed.ppq then bpSpan(live.ppq) end
    elseif unboundedSeed(seed) then
      return nil
    end
  end
  for _, win in ipairs(replaceWins.wins) do
    if not win.kept then util.add(seatSpans, { win.startRaw - DUAL_POINT_TICK, win.endRaw }) end
  end
  -- The I2a anchor at the first lane-1 onset (authored or derived) is channel-global: any pass may
  -- need to seat, refresh, or retire it, so its point is always in scope.
  local first = lane1.first()
  if first then util.add(seatSpans, { first.ppq - DUAL_POINT_TICK, first.ppq }) end
  return seatSpans
end

-- Reseat absorber pbs against the post-walk lane-1 layout, recompute their raw vals,
-- and project the pb column. see docs/tuning.md § Absorber reconciliation
local function rebuildPbs(fxOut, extraColumns, pbLimCents, time)
  local gridStep = ccGridStep()
  local noteLive = fxOut.noteLive
  -- Reads only the per-chan .pb keep-flag; rebuildExtraColumns's mid-pipeline write grows
  -- .notes only, so the head snapshot is current for this.
  local extras = extraColumns or {}

  perf.start('gather')
  -- Per-chan lane-1 union door, built for dirty channels alone; clean ones reuse their carried pb
  -- column. see docs/tuning.md § Absorber reconciliation
  local freshLane1, lane1ByChan = {}, {}
  for chan = 1, 16 do
    if dirt.has(chan) then
      -- Derived lane-1 fxNotes are routed out of columns; union them so the absorber pass seats
      -- their detune jumps.
      local liveLane1 = {}
      for _, live in ipairs(noteLive[chan]) do
        if live.lane == 1 then
          util.add(liveLane1, live.evt)
          freshLane1[chan] = freshLane1[chan] or not live.kept
        end
      end
      table.sort(liveLane1, index.order)   -- the door's cursors assume ppq order of both sources
      lane1ByChan[chan] = lane1Union(chan, liveLane1)
    end
  end

  -- Replace windows + seat spans per dirty chan, computed ahead of the gather. Fresh (non-kept)
  -- derived lane-1 output ungates the channel (seatSpans nil).
  local winsByChan, seatSpansByChan = {}, {}
  for chan = 1, 16 do
    if dirt.has(chan) then
      local replaceWins = replaceWindows(chan, fxOut, gridStep, pbLimCents, time)
      winsByChan[chan] = replaceWins
      if not freshLane1[chan] then
        seatSpansByChan[chan] = seatScope(chan, replaceWins, lane1ByChan[chan])
      end
    end
  end

  -- A ppq's membership in a channel's seat scope; nil spans (ungated) puts everything in scope. The
  -- clone/carry partition: the gather clones only in-scope pbs, projection carries the rest verbatim.
  local function inSpans(spanSet, ppq)
    if not spanSet then return true end
    for _, s in ipairs(spanSet) do
      if ppq >= s[1] and ppq <= s[2] then return true end
    end
    return false
  end

  -- Each pb rides its own clone through the pass, carrying the index entry's uuid so a mutated clone still
  -- names its source; origShape is held because the pass rewrites shape.
  local pbsByChan = {}
  for chan = 1, 16 do
    if dirt.has(chan) then
      local seatSpans = seatSpansByChan[chan]
      for _, entry in ipairs(index.raw(chan).pbs) do
        if inSpans(seatSpans, entry.ppq) then
          local pb = util.clone(entry, { colEvt = true })
          pb.origShape = entry.shape
          util.bucket(pbsByChan, pb.chan, pb)
        end
      end
    end
  end
  perf.stop('gather')

  local pbWrites = mmBatch()

  -- Seat the lane-1 detune stream, match absorbers, and stage the consolidated assign feeding the
  -- projection below. Clean chans skip it wholesale -- I8: rebuild is a fixpoint.
  local function deriveChan(chan, pbs, replaceWins, seatSpans, lane1)
    perf.start('seats')
    local replaceWinAt, inSeatWindow, inKeptRange =
      replaceWins.replaceWinAt, replaceWins.inSeatWindow, replaceWins.inKeptRange

    -- Detune onsets: every lane-1 ppq whose detune differs from its predecessor, seeded by the
    -- carried-in detune and walked per coalesced seat span. see docs/tuning.md § Seat-span-scoped onset walk
    local onsets, onsetAt = {}, {}
    for _, span in ipairs(seatSpans and spans.merge(seatSpans) or { { 0, math.huge } }) do
      local prev = lane1.detuneAt(span[1] - 1)
      for _, note in ipairs(lane1.between(span[1], span[2])) do
        local detune = note.detune or 0
        if detune ~= prev and not onsetAt[note.ppq] then
          util.add(onsets, { ppq = note.ppq, ppqL = note.ppqL }); onsetAt[note.ppq] = true
        end
        prev = detune
      end
    end
    -- Both of a dual point's seats follow the onset's ownership, so a pb sitting one tick under an
    -- onset is classified by that onset's side.
    local function fencedPb(ppq)
      if onsetAt[ppq + DUAL_POINT_TICK] then return inKeptRange(ppq + DUAL_POINT_TICK) end
      return inKeptRange(ppq)
    end
    -- A replace window's clipped endRaw is kept-owned yet falls inside the window's seat span and
    -- generates no seat here; those kept-boundary seats carry from the prior column.
    local fenced = {}   -- raw ppq -> true: carried (identity refresh via pbEntryByRaw), not projected fresh
    for i = #pbs, 1, -1 do
      if fencedPb(pbs[i].ppq) then fenced[pbs[i].ppq] = true; table.remove(pbs, i) end
    end

    -- Back-derive cents for any authored pb missing it (foreign-MIDI/pre-cents pbs carry raw only) so the
    -- assign carries cents to the sidecar; an in-window seat must not acquire cents or it stops looking like a seat.
    local persistCents = {}
    for _, pb in ipairs(pbs) do
      if pb.cents == nil and not inSeatWindow(pb.ppq) then
        pb.cents = tuning.rawToCents(pb.raw, pbLimCents) - lane1.detuneAt(pb.ppq)
        persistCents[pb] = true
      end
    end

    -- The authored value stream, whole and read-only, straight from the raw index -- decoupled from the
    -- bounded clone set. cents from the sidecar, else back-derived for foreign pbs.
    local realPbs, pbEntryByRaw = {}, {}
    for _, entry in ipairs(index.raw(chan).pbs) do
      pbEntryByRaw[entry.ppq] = entry
      if not entry.derived and not inSeatWindow(entry.ppq) then
        local cents = entry.cents
                      or (tuning.rawToCents(entry.raw, pbLimCents) - lane1.detuneAt(entry.ppq))
        util.add(realPbs, { ppq = entry.ppq, cents = cents, shape = entry.shape, tension = entry.tension })
      end
    end

    local function inSeatScope(ppq) return inSpans(seatSpans, ppq) end

    -- Prevailing cents at any ppq: the replace curve inside a window, else the authored
    -- breakpoints. Interpolate the bounding pair, hold the last past the end, 0 before the first.
    local function streamValue(ppq)
      local win  = replaceWinAt(ppq)
      local src  = win and win.bps or realPbs
      local i    = util.firstAfter(src, ppq)
      local A, B = src[i - 1], src[i]
      if not A then return 0 end
      if not B then return A.cents end
      return curves.interpolate(A, B, ppq, 'cents')
    end

    -- The stream governing M, whichever owns it: a window's own curve inside one, the authored
    -- breakpoints outside. `into` is the segment M is entered on, `at` a breakpoint standing on it.
    local function streamAround(M)
      local win = replaceWinAt(M)
      local src = win and win.bps or realPbs
      local i   = util.firstAtOrAfter(src, M)
      local at  = src[i]
      return src[i - 1], (at and at.ppq == M) and at or nil
    end

    -- Seats to realise: ppq -> { cents, ppqL, shape }; assign turns each into wire raw = centsToRaw(cents + detune).
    -- Flat/held/absent needs one step seat; a ramping value splits onto a dual point plus a curved segment. see docs/tuning.md
    local seats = {}
    for _, onset in ipairs(onsets) do
      if inKeptRange(onset.ppq) then goto nextOnset end   -- kept side: its seats stand from last pass
      local cents    = streamValue(onset.ppq)
      local into, at = streamAround(onset.ppq)
      -- The segment the stream enters the onset on decides: a moving one smears the detune step
      -- back across the preceding event (see docs/tuning.md § Value-aware seats).
      local ramps = into and into.shape and into.shape ~= 'step'
                    and (curves.isCurved(into.shape) or into.cents ~= cents)
      if ramps then
        -- Dual point (see docs/tuning.md § Value-aware seats): before/at carry old/new detune, both
        -- linear so the curve rides through; a window-start onset (ppq 0) has no prior event.
        if onset.ppq > 0 then
          local dual = onset.ppq - DUAL_POINT_TICK
          seats[dual] = { cents = cents, ppqL = time:toLogical(chan, dual), shape = 'linear' }
        end
        seats[onset.ppq] = { cents = cents, ppqL = onset.ppqL, shape = 'linear' }
      else
        -- A breakpoint standing on the onset owns the segment leaving it, so the seat carries its
        -- shape; with nothing there the stream is held and the seat steps.
        seats[onset.ppq] = { cents = cents, ppqL = onset.ppqL, shape = at and at.shape or 'step' }
      end
      ::nextOnset::
    end

    -- Densify each curved segment of `list` that contains an onset into a linear polyline on the
    -- fixed CCINTERP grid -- stable keys (from authored ppqs) keep it churn-free.
    local function densify(list)
      for i = 1, #list - 1 do
        local A, B = list[i], list[i + 1]
        local hasOnset = false
        for _, onset in ipairs(onsets) do
          if onset.ppq > A.ppq and onset.ppq < B.ppq then hasOnset = true break end
        end
        if curves.isCurved(A.shape) and hasOnset then
          local p = A.ppq + gridStep
          while p < B.ppq do
            if not seats[p] and not inKeptRange(p) and inSeatScope(p) then
              seats[p] = { cents = streamValue(p), ppqL = time:toLogical(chan, p), shape = 'linear' }
            end
            p = p + gridStep
          end
        end
      end
    end
    densify(realPbs)

    -- Seat each replace curve as derived (hidden) seats carrying its shape; see docs/tuning.md §
    -- Value-aware seats and densification for the rule. Onset seats above take priority.
    for _, win in ipairs(replaceWins.wins) do
      for _, bp in ipairs(win.bps) do
        if not seats[bp.ppq] then
          seats[bp.ppq] = { cents = bp.cents, ppqL = bp.ppqL, shape = bp.shape }
        end
      end
      densify(win.bps)
    end

    -- Anchor a pb-active channel at its first lane-1 onset (I2a):
    -- without it, playback inherits the synth's unknown prior bend.
    local first = lane1.first()
    if first and not seats[first.ppq] and not inKeptRange(first.ppq) and inSeatScope(first.ppq) then
      -- realPbs is ppq-ascending, so its head settles both questions. The jump test is whole-channel:
      -- the span-bounded onset walk above could hide the only jump the channel has.
      local firstReal = realPbs[1]
      local anchored  = firstReal ~= nil and firstReal.ppq <= first.ppq
      local pbActive  = next(seats) ~= nil or firstReal ~= nil
                        or (seatSpans ~= nil and lane1.anyDetuneJump())
      if pbActive and not anchored then
        seats[first.ppq] = { cents = streamValue(first.ppq), ppqL = first.ppqL, shape = 'step' }
      end
    end
    perf.stop('seats')

    perf.start('match')
    -- Match existing pbs to seats. A real pb at a seat covers it (it steps detune itself); absorbers
    -- consume any already at a seat, move the remaining ones to fill the rest, delete the leftovers.
    local realAt, availAbsorbers = {}, {}
    for _, pb in ipairs(pbs) do
      -- A markerless in-window pb is a generated seat (recognized by window, no marker); tag it in RAM
      -- so projection hides it and the fungible-absorber machinery below reseats it.
      if not pb.derived and inSeatWindow(pb.ppq) then pb.derived = 'absorber' end
      if pb.derived then
        -- Pool = in-scope absorbers plus any absorber standing at a computed seat, so a seat can
        -- never miss its standing absorber and mint a duplicate.
        if inSeatScope(pb.ppq) or seats[pb.ppq] then util.add(availAbsorbers, pb) end
      else realAt[pb.ppq] = pb end
    end
    for ppq in pairs(seats) do
      if realAt[ppq] then seats[ppq] = nil end
    end

    local restampPpqL = {}  -- pb -> newPpqL (existing absorber at a seat with stale ppqL)
    for i = #availAbsorbers, 1, -1 do
      local absorber, seat = availAbsorbers[i], seats[availAbsorbers[i].ppq]
      if seat then
        absorber.cents, absorber.shape = seat.cents, seat.shape
        if absorber.ppqL ~= seat.ppqL then
          absorber.ppqL = seat.ppqL   -- mirror into the clone so the logical projection sees it
          -- A seat's ppqL is raw-only (never persisted), so this nil->seat mirror is not a sidecar write.
          if not inSeatWindow(absorber.ppq) then restampPpqL[absorber] = seat.ppqL end
        end
        seats[absorber.ppq] = nil
        table.remove(availAbsorbers, i)
      end
    end

    local moved = {}  -- pb -> newPpq
    for ppq, seat in pairs(seats) do
      local absorber = table.remove(availAbsorbers)
      if absorber then
        moved[absorber] = ppq
        absorber.ppq, absorber.cents = ppq, seat.cents
        absorber.ppqL, absorber.shape = seat.ppqL, seat.shape
        util.add(pbs, absorber)
      else
        local fresh = { chan = chan, ppq = ppq, cents = seat.cents, ppqL = seat.ppqL,
                        shape = seat.shape, derived = 'absorber', evType = 'pb' }
        util.add(pbs, fresh)
        local raw = tuning.centsToRaw(fresh.cents + lane1.detuneAt(ppq), pbLimCents)
        if inSeatWindow(ppq) then
          -- Markerless seat: native MIDI only ({ppq,val,shape}) -> addCC mints no uuid, no eventMeta
          -- sidecar; recognized next rebuild by its window. see § Route-by-window
          pbWrites.add({ evType = 'pb', chan = chan, ppq = ppq, val = raw, shape = fresh.shape })
        else
          local writeEvt = util.clone(fresh)
          writeEvt.val = raw
          pbWrites.add(writeEvt)
        end
      end
    end

    -- Absorbers still unclaimed have no seat left to fill: delete them from the take, then compact
    -- the working set once rather than rescanning it per absorber.
    local dropped = {}
    for _, absorber in ipairs(availAbsorbers) do
      pbWrites.del({ uuid = absorber.uuid })
      dropped[absorber] = true
    end
    if next(dropped) then
      local kept = 0
      for i = 1, #pbs do
        if not dropped[pbs[i]] then kept = kept + 1; pbs[kept] = pbs[i] end
      end
      for i = #pbs, kept + 1, -1 do pbs[i] = nil end
    end

    util.sortByPPQ(pbs)
    perf.stop('match')

    local detuneOf = {}
    for _, pb in ipairs(pbs) do detuneOf[pb] = lane1.detuneAt(pb.ppq) end
    perf.start('assign')
    -- Consolidated assign: one entry per existing pb where any of (ppq moved, ppqL
    -- restamped, raw changed, cents back-derived, derived shape changed) needs to land.
    for _, pb in ipairs(pbs) do
      if pb.realised then
        local d         = detuneOf[pb]
        local newRaw    = tuning.centsToRaw(pb.cents + d, pbLimCents)
        local shapeChanged = pb.derived and pb.shape ~= pb.origShape
        local markerless   = pb.derived and inSeatWindow(pb.ppq)
        local update = nil
        if moved[pb] then
          update = { ppq = pb.ppq, ppqL = pb.ppqL,
                     cents = pb.cents, val = newRaw }
        elseif restampPpqL[pb] then
          update = { ppqL = restampPpqL[pb], cents = pb.cents, val = newRaw }
        elseif pb.raw ~= newRaw or persistCents[pb] or shapeChanged then
          update = { cents = pb.cents, val = newRaw }
        end
        if update then
          if pb.derived then update.shape = pb.shape end
          -- A markerless seat persists native MIDI only; strip the sidecar fields so the assign
          -- stamps no metadata and the seat stays plain. Its ppq/val/shape still land.
          if markerless then update.cents, update.ppqL = nil, nil end
          pb.raw = newRaw
          pbWrites.assign({ uuid = pb.uuid }, update)
        end
      end
    end
    perf.stop('assign')
    return detuneOf, pbEntryByRaw, fenced
  end

  for chan = 1, 16 do
    -- Clean channels are skipped wholesale -- their carried pb column stands (set at rebuild entry).
    if dirt.has(chan) then
      local pbs = pbsByChan[chan] or {}
      util.sortByPPQ(pbs)

      local priorPbCol = frame.channels[chan].priorPb
      frame.channels[chan].priorPb = nil
      local seatSpans = seatSpansByChan[chan]
      local detuneOf, pbEntryByRaw, fenced = deriveChan(chan, pbs, winsByChan[chan], seatSpans, lane1ByChan[chan])

      perf.start('project')
      -- Column projection. A derived seat is wire-only -- always hidden. This projects the in-scope
      -- clones fresh; the out-of-scope remainder carries below.
      --invariant: one pb per raw ppq in the column -- the projected and carried sets partition it
      local anyVisible, pbColEvents = false, {}
      for _, pb in ipairs(pbs) do
        local hidden = pb.derived ~= nil
        anyVisible = anyVisible or not hidden
        -- pb is our own working clone, done being read by the assign above -- reuse it as the
        -- column event rather than cloning again.
        pb.ppqRaw = pb.ppq   -- survives projectEvent's logical flip; the carry partition keys on it
        pb.val, pb.detune, pb.hidden = pb.cents, detuneOf[pb], hidden
        pb.raw = nil   -- derive-only wire mirror for the delta-gate; never rides into the cents-framed column
        projectEvent(pb, chan, time)
        util.add(pbColEvents, pb)
      end
      -- Carry the whole out-of-scope remainder verbatim -- re-deriving from the wire would quantise through
      -- centsToRaw. Each refreshes uuid/realised since a carried event predates its committed uuid.
      for _, evt in ipairs(priorPbCol and priorPbCol.events or {}) do
        local carry = evt.ppqRaw and (not inSpans(seatSpans, evt.ppqRaw) or fenced[evt.ppqRaw])
        local entry = carry and pbEntryByRaw[evt.ppqRaw]
        if entry then
          evt.uuid, evt.realised = entry.uuid, entry.realised
          anyVisible = anyVisible or not evt.hidden
          util.add(pbColEvents, evt)
        end
      end
      util.sortByPPQ(pbColEvents)
      local keep = anyVisible or (extras[chan] and extras[chan].pb)
      frame.channels[chan].onTake.pb = keep and { events = pbColEvents } or nil
      perf.stop('project')
    end
  end

  perf.start('commit')
  pbWrites.commit()
  perf.stop('commit')
end

----- Rebuild sample stamp

-- The bearing rule: under trackerMode every note bears a sample, stamped once from the onset PC;
-- inheritance freezes at stamp time. Gated on the dirt journal (seed list or wholesale).
local function stampSamples()
  if not cm:get('trackerMode') then return end
  local stampWrites = mmBatch()
  local function stamp(entry)
    if entry.evType == 'note' and walkable(entry) and entry.sample == nil then
      local prevailing = util.seek(index.raw(entry.chan).pcs, 'at-or-before', entry.ppq)
      local sample = prevailing and prevailing.val or 0
      index.assign(entry, 'sample', sample)
      frame.setEvent(entry.colEvt, 'sample', sample)
      stampWrites.assign(entry, { sample = sample })
    end
  end
  for chan = 1, 16 do
    if dirt.wholesale(chan) then
      for _, entry in ipairs(index.raw(chan).notes) do stamp(entry) end
    elseif dirt.has(chan) then
      for _, s in ipairs(dirt.has(chan)) do
        local uuid = s.uuid or (s.evt and s.evt.uuid)
        local entry = uuid and index.byUuid(uuid)
        if entry then stamp(entry) end
      end
    end
  end
  stampWrites.commit()
end

----- Rebuild PCs

-- Seed closure for PC synthesis: each seed onset's [onset, next onset) span, both frames.
-- nil = wholesale (also forced by fresh derived output).
local function pcSeedSpans(chan, noteLive)
  if dirt.wholesale(chan) then return nil end
  for _, w in ipairs(noteLive) do
    if not w.kept then return nil end
  end
  local points = {}
  local function addPoint(ppq, ppqL)
    if ppq ~= nil then util.add(points, { ppq = ppq, ppqL = ppqL or ppq }) end
  end
  for _, s in ipairs(dirt.has(chan)) do
    addPoint(s.ppq, s.ppqL)
    local live = s.uuid and index.byUuid(s.uuid)
    if live then addPoint(live.ppq, live.ppqL) end
  end
  local seedSpans, notes = {}, index.raw(chan).notes
  for _, point in ipairs(points) do
    local i = util.firstAfter(notes, point.ppq)
    while notes[i] and not walkable(notes[i]) do i = i + 1 end
    local nextNote = notes[i]
    util.add(seedSpans, { sRaw = point.ppq, eRaw = nextNote and nextNote.ppq or math.huge,
                          sL = point.ppqL, eL = nextNote and nextNote.ppqL or math.huge })
  end
  return seedSpans
end

-- pcSeedSpans' raw extents overlap routinely (two points per seed, shared next-onsets); merge to
-- disjoint ascending so coverOnsets emits each in-span event exactly once. see interval-dirt v2 § 4
local function rawCoverSpans(seedSpans)
  local raw = {}
  for _, s in ipairs(seedSpans) do util.add(raw, { s.sRaw, s.eRaw }) end
  return spans.merge(raw)
end

-- PC synthesis (trackerMode only), after the sample stamp. Seed-list dirt closes to spans; records,
-- writes and the column splice all clip to them, so out-of-span PCs stand.
local function rebuildPCs(noteLive, time)
  if not cm:get('trackerMode') then return end
  local pcWrites = mmBatch()
  local spansByChan, rawSpansByChan = {}, {}
  for chan = 1, 16 do
    -- Clean channels freeze: their PCs stand in mm and their pc column is carried forward.
    if not dirt.has(chan) then goto nextChan end
    local seedSpans = pcSeedSpans(chan, noteLive[chan])
    local rawSpans = seedSpans and rawCoverSpans(seedSpans)
    spansByChan[chan], rawSpansByChan[chan] = seedSpans, rawSpans
    local records = {}
    local function recordNote(entry)
      if walkable(entry) then
        util.add(records, { ppq = entry.ppq, ppqL = entry.ppqL, lane = entry.lane,
                            sample = entry.sample, evt = entry.colEvt })
      end
    end
    if rawSpans then
      coverOnsets(index.raw(chan).notes, rawSpans, recordNote)
    else
      for _, entry in ipairs(index.raw(chan).notes) do recordNote(entry) end
    end
    for _, w in ipairs(noteLive[chan]) do
      local n = w.evt
      if not seedSpans or pcInSpans(seedSpans, n.ppq, false) then
        -- region-derived notes ride no note host: no sample to inherit, regenerated each pass
        util.add(records, { ppq = n.ppq, ppqL = n.ppqL, lane = w.lane, sample = n.sample or 0, spec = n })
      end
    end
    reconcilePCsForChan(chan, records, pcWrites, seedSpans)
    ::nextChan::
  end
  pcWrites.commit()

  -- pc column splice: out-of-span events carry; in-span (or wholesale) events re-read from the
  -- committed stream. Always a fresh events table -- tv's cell carry keys on table identity.
  for chan = 1, 16 do
    if dirt.has(chan) then
      local seedSpans = spansByChan[chan]
      local events = {}
      if seedSpans then
        for _, e in ipairs((frame.channels[chan].onTake.pc and frame.channels[chan].onTake.pc.events) or {}) do
          if not pcInSpans(seedSpans, e.ppq, true) then util.add(events, e) end
        end
      end
      local function projectPc(cc)
        local evt = projectCC(cc)
        projectEvent(evt, chan, time)
        util.add(events, evt)
      end
      if seedSpans then
        coverOnsets(index.raw(chan).pcs, rawSpansByChan[chan], projectPc)
      else
        for _, cc in ipairs(index.raw(chan).pcs) do projectPc(cc) end
      end
      util.sortByPPQ(events)
      frame.channels[chan].onTake.pc = { events = events }
    end
  end
end

----- Fx output maps

-- Built at the pipeline tail, where the fx pass has already emitted this rebuild's derived notes:
-- a rect's note lanes come off those notes, not window coverage, which is parked-over not produced-onto.
local function buildFreezeRects(hosts)
  local hostChans, lanesByUuid = {}, {}
  for _, host in ipairs(hosts) do hostChans[host.chan] = true end
  for chan in pairs(hostChans) do
    for _, note in ipairs(index.raw(chan).notes) do
      -- A derived note carries its host's uuid, so the bucketing needs no window arithmetic.
      if note.derived then
        local lanes = lanesByUuid[note.derived] or {}
        lanes[note.lane] = true
        lanesByUuid[note.derived] = lanes
      end
    end
  end
  local rects = {}
  for _, host in ipairs(hosts) do
    -- A husk host (no fx, no output) claims an empty stream set rather than none: it is still
    -- a host, and whether an empty footprint is worth minting is the caller's question.
    local streams = {}
    -- The note target is a park window, not output: a rect's note lanes are the ones the fx pass wrote.
    for target in pairs(host.targets) do
      if     target == 'pb'           then streams['pb:0'] = true
      elseif type(target) == 'number' then streams['cc:' .. target] = true end
    end
    for lane in pairs(lanesByUuid[host.uuid] or {}) do streams['note:' .. lane] = true end
    -- Single-channel by construction, so chanOffset 0 is the only key; span is the host's own.
    rects[host.uuid] = { ppq = host.ppq, dur = host.endppq - host.ppq,
                         chanLo = host.chan, streams = { [0] = streams } }
  end
  return rects
end

-- The continuous half of the same window set: which pb/cc targets each host's chains own,
-- logical framed. see docs/trackerManager.md § Realisation by host
--shape: byHost[uuid] = { pb = { {startL, endL}, ... }, [ccNum] = { ... } } -- merged, ascending
local function buildFxTargets(hosts)
  local byHost = {}
  for _, host in ipairs(hosts) do
    local targets, any = {}, false
    for target in pairs(host.targets) do
      -- One span per target: a window takes its host's span, so there is nothing to merge.
      if target ~= 'note' then
        targets[target], any = { { host.ppq, host.endppq } }, true
      end
    end
    if any then byHost[host.uuid] = targets end
  end
  return byHost
end

-- A stored global region is no host of its own, so its uuid answers with the union of the ones
-- it expanded into: their notes, their claimed targets, the events they parked. see docs/trackerManager.md § Realisation by host
local function unionRealisation(uuid, byUuid)
  local union = { uuid = uuid, chans = {}, notes = {}, targets = {}, parked = {} }
  for chan = 1, 16 do
    local part = byUuid[util.key(uuid, chan)]
    if part then
      util.add(union.chans, chan)
      for _, note in ipairs(part.notes)  do util.add(union.notes, note) end
      for _, evt in ipairs(part.parked) do util.add(union.parked, evt) end
      for target, claimed in pairs(part.targets) do
        for _, span in ipairs(claimed) do util.bucket(union.targets, target, span) end
      end
    end
  end
  -- Each channel's list arrives in its own onset order; the union restores one order across them all.
  table.sort(union.notes, function(a, b)
    if a.ppq ~= b.ppq then return a.ppq < b.ppq end
    return a.chan < b.chan
  end)
  -- The expanded hosts claim one span each over the same logical window, so the merge collapses
  -- them back to the stored region's own.
  for target, claimed in pairs(union.targets) do union.targets[target] = spans.merge(claimed) end
  return union
end

--contract: byHost carries the three shares the passes above keyed by host uuid: notes
-- (channel-keyed first), targets, parked
local function buildFxRealisation(census, globals, byHost)
  local out = {}
  for _, p in ipairs(census) do
    out[p.uuid] = { uuid = p.uuid, chans = { p.chan },
                    notes   = (byHost.notes[p.chan] or {})[p.uuid] or {},
                    targets = byHost.targets[p.uuid] or {},
                    parked  = byHost.parked[p.uuid] or {} }
  end
  for _, region in ipairs(globals or {}) do out[region.uuid] = unionRealisation(region.uuid, out) end
  return out
end

----- Rebuild pipeline

--pre: called inside tm:rebuild's mm nest, with the index already reloaded if this pass is wholesale
--pre: sources holds the head's ds reads, taken before any write of this pass, fxRegions expanded
--pre: time is the projection the rebuild head built for this pass
--post: fxNotesByHost[chan] := the pass's derived notes, for each channel the fx stage ran
--post: fresh result = the maps tm:rebuild installs, plus the channels whose mute wants conforming
--invariant: every mm-staging stage nests, so reindex/reprojection defer to one unwind
function rebuild.pipeline(sources, time)
  -- The bend window this pass converts against, in cents per side; the edit side caches its own.
  local pbLimCents = cm:get('pbRange') * 100
  -- The take's own window set, replayed once at the head: the three park-side stages recognise seats
  -- against it, each asking it the same doors the pass's set answers. see docs/generators.md § Route-by-window
  local realisedWindows = buildRealisedWindows(sources.fxRealisedWindows, time)

  perf.start('internals'); local external, noteExisting = rebuildInternals(time); perf.stop('internals')  -- partition; internal cols (logical-born); reseat swing notes
  perf.start('ccs'); local ccExisting = rebuildCCs(realisedWindows, time); perf.stop('ccs')  -- CC walk; reseat swing CCs
  dirt.swing.clear()                            -- swing consumers (partition + CC walk) done
  perf.start('extraCols'); rebuildExtraColumns(sources.extraColumns, sources.paramAutomation); perf.stop('extraCols')  -- reconcile persisted extra columns
  perf.start('externals'); rebuildExternals(external, time); perf.stop('externals')  -- reintroduce foreign / diverged notes
  perf.start('samples'); stampSamples(); perf.stop('samples')  -- bearing rule: stamp bare notes from the prevailing PC

  -- Fx window set: fx-regions plus every note host, on-take or parked, as a degenerate window.
  -- One pass serves the whole pipeline. See docs/generators.md § Offline continuous realisation.
  perf.start('parkRender'); renderStashedParked(sources.fxParked, time); perf.stop('parkRender')
  perf.start('noteHostClips'); local noteHostClips = clipNoteHosts(time); perf.stop('noteHostClips')
  perf.start('fxWindows')
  local windows = buildFxWindows(sources.fxRegions, noteHostClips, time)
  perf.stop('fxWindows')

  perf.start('regionPark')
  local parkedByHost = rebuildRegionPark(windows, sources.fxParked, realisedWindows,
                                             noteHostClips, pbLimCents, time)  -- park covered, carry/restore prior
  perf.stop('regionPark')
  perf.start('pa'); rebuildPA(time); perf.stop('pa')  -- project PAs into settled note columns (each spliced in ppq order)

  perf.start('fx')
  local fxOut = rebuildFx(noteExisting, ccExisting, noteHostClips, windows, sources.fxRegions,
                          fxNotesByHost, pbLimCents, time)  -- fx expansion: derived notes/CCs
  perf.stop('fx')

  perf.start('tails'); rebuildTails(fxOut.noteLive, fxOut.noteOps, time); perf.stop('tails')  -- unified tail/onset walk + atomic note commit
  perf.start('pbs'); rebuildPbs(fxOut, sources.extraColumns, pbLimCents, time); perf.stop('pbs')  -- absorber reconciliation + pb resynthesis
  perf.start('pcs'); rebuildPCs(fxOut.noteLive, time); perf.stop('pcs')  -- PC synthesis (trackerMode)

  -- Persist this rebuild's window set: next rebuild recognizes seats against it (prev-keyed). see § Route-by-window
  perf.start('fxRealisedWindows')
  local windowList = windows.perTarget()
  if mm:take() and not util.deepEq(sources.fxRealisedWindows or {}, windowList) then
    ds:assign('fxRealisedWindows', #windowList > 0 and windowList or util.REMOVE)
  end
  perf.stop('fxRealisedWindows')

  -- Freeze's maps, after the fx pass: a rect built before it would carry the previous rebuild's note
  -- lanes. Sibling maps, one site.
  local maps = { windows = windows }
  perf.start('freezeMaps')
  maps.freezeRect = buildFreezeRects(windows.windows())
  perf.stop('freezeMaps')
  -- The shares the passes above keyed by host, gathered last; only the notes outlive the pass.
  local byHost = { notes = fxNotesByHost, parked = parkedByHost,
                       targets = buildFxTargets(windows.windows()) }
  maps.fxRealisation = buildFxRealisation(windows.windows(), sources.globalRegions, byHost)

  -- Drop un-flushed command-path staging; the index itself is already live (head reload on
  -- wholesale passes, incremental reconciliation otherwise). see docs § Incremental index reconciliation
  perf.start('view'); stager.clear(); perf.stop('view')
  -- The gated stages consumed the spine; the next edit window accumulates fresh dirt. The channels
  -- that ran re-read the wire, so their mute flags want conforming: the head folds this in.
  maps.conform = dirt.clear()
  return maps
end

return rebuild
