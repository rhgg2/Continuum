-- See docs/trackerManager.md for the model.

--invariant: tm holds (ppqL, raw) per event; mm holds raw; col events expose evt.ppq as logical
--invariant: rebuild reconciles raw ↔ ppqL each pass (docs/timing.md)
--invariant: detune is intent (per-note); pb is realisation (channel-wide stream)
--invariant: only lane-1 notes drive detune realisation
--invariant: pb.val is cents inside um; raw↔cents only at load/flush (rawToCents/centsToRaw)
--invariant: cents window = cm:get('pbRange') * 100 per side
--invariant: absorber pbs absorb lane-1 detune jumps; first onset anchors a pb-active channel
--invariant: pb.derived=='absorber' is the absorber marker, persisted as cc metadata via mm sidecar
--invariant: pa stores aftertouch value in mm cc.vel; cc-routing fields stripped on projection
--invariant: loc values valid only within one rebuild-to-flush window
--invariant: um's notesByLoc/ccsByLoc rebuild fresh each rebuild
--invariant: col events sort by logical ppq
--invariant: endppq carries no delay; delay shifts only the note-on
--invariant: 16 channels always present; channels[i] non-nil for i in 1..16 after rebuild

--shape: channel = { chan, columns = { notes, ccs={[ccNum]=col}, [pc], [pb], [at] } }
--shape: column = { events=[evt,...], [cc=ccNum] }  -- events sorted by logical ppq
--shape: noteEvent core = { ppq, endppq, pitch, vel, lane, detune, delay, loc }
--invariant: noteEvent optional: muted, sample, sampleShadowed, <metadata...>
--shape: pbEventCol = { ppq, val=cents-minus-detune, detune, hidden, loc, ... }
--invariant: pbEventCol optional: delay, shape, tension
--invariant: pbEventCol is the col projection; um cache holds raw cents in val
--shape: paEventCol = { evType='pa', ppq, pitch, vel, loc, ... }
--invariant: paEventCol mixes into note column events
--shape: extraColumns[chan] = { notes=count, [pc], [pb], [at], [ccs={[ccNum]=true}] }
--shape: lastMuteSet = { [chan] = true }, pushed by tv via tm:setMutedChannels
--shape: fxParked = { { evType='note', chan, lane, uuid, ppqL, endppqL, pitch, vel, detune, delay, sample }, ... } -- logical-only; realised ppq derived on restore
--shape: fxParkedCC = { { evType='cc', chan, cc, ppqL, val, shape }, ... } -- authored cc parked off-take by a cc-replace window (logical-only)
--shape: channels[chan].parked = { { evType='note', chan, uuid, ppq, ppqL, endppq, endppqL, endppqC, pitch, vel, detune, sample, delay, lane }, ... } -- render-ready off-take replace cells (ppq==ppqL; endppq is the authored ceiling the view edits, endppqC==endppqL clipped for render)
--shape: channels[chan].parkedCC = { { evType='cc', chan, cc, ppq, ppqL, val, shape }, ... } -- off-take cc-replace members as render-ready logical cells (ppq==ppqL)
--contract: a discrete-replace in a region parks its covered chord off-take; else it keeps sounding
--invariant: parked members feed generator + grid only; never sounding (mute fails for CC/PA)

local util    = require 'util'
local timing  = require 'timing'
local tuning  = require 'tuning'
local generators = require 'generators'
local perf       = require 'perf'

local function print(...)
  return util.print(...)
end

local mm, cm, ds = (...).mm, (...).cm, (...).ds

local tm = {}
local fire = util.installHooks(tm)

---------- STATE

local channels    = {}
local lastMuteSet = {}
--invariant: staleSwing[chan]=true: resolved swing changed; rebuild rederives raw, clears
local staleSwing  = {}
-- True only while flush writes the parked stash; suppresses the inline dataChanged
-- rebuild so flush drives the single rebuild (B3 staging, see design/note-macros-v2.md).
local flushingParked = false
-- ppq tolerance for "raw agrees with its logical projection"; absorbs
-- fromLogical rounding slop, shared by the tail pass and rebuild rule.
local EPS         = 1
--invariant: swingSnap caches the (cm, mm)-derived swing transforms; nil
--  means "needs rebuild". Invalidated at the head of every tm:rebuild —
--  the sole synchronisation point at which mm/cm read coherently.
local swingSnap

---------- SHARED HELPERS

local function sortByPPQ(tbl)
  table.sort(tbl, function(a, b) return a.ppq < b.ppq end)
end

local function centsToRaw(cents)
  local lim = cm:get('pbRange') * 100
  return util.clamp(util.round(cents * 8192 / lim), -8192, 8191)
end

local function rawToCents(raw)
  local lim = cm:get('pbRange') * 100
  return util.round(raw / 8192 * lim)
end

local function delayToPPQ(d) return timing.delayToPPQ(d, mm:resolution()) end

local function forEachEvent(fn)
  for i=1,16 do
    local channel = channels[i]
    if channel then
      local chan, cols = channel.chan, channel.columns
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


----- derived-event reconcile skeleton (R2)
-- Index existing by `key`, keep-on-match, add the rest, remove unkept. The absorber pass is a richer fungible-move variant, inline.
--contract: appends unmatched-existing to sink.del(event), new/made specs to sink.add(spec)
local function reconcileDerived(a)
  local index, kept = {}, {}
  for _, e in ipairs(a.existing) do index[a.key(e)] = e end
  for _, spec in ipairs(a.predicted) do
    local have = index[a.key(spec)]
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

--contract: synthesised PCs carry derived='pc'; ppqL inherited from winning host-note record
--contract: an existing derived PC matching (ppq, val) is kept, preserving mm-side loc
--contract: appends removals/adds to the sink {del(event), add(spec)}
--contract: if record.key set, marks key.sampleShadowed=true on records lost to lane priority
--invariant: shadow marking is rebuild-only; flush callers omit key (rebuild reclones lane events)
--invariant: c.pc.events not written here; rebuild's CC walk refreshes it from mm after commit
local function reconcilePCsForChan(chan, records, sink)
  local existing = (channels[chan].columns.pc and channels[chan].columns.pc.events) or {}

  local groups = {}
  for _, r in ipairs(records) do util.bucket(groups, r.ppq, r) end

  local winners = {}
  for _, g in pairs(groups) do
    table.sort(g, function(a, b) return a.lane < b.lane end)
    util.add(winners, g[1])
    for i = 2, #g do
      if g[i].key then g[i].key.sampleShadowed = true end
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

-- Identity is geometry: (host, ppq, endppqL, pitch, vel, detune, sample); stale endppqL still
-- matches (tail-walk-owned realised end stays out). Predicted ppq is integer; REAPER returns float.
local function canon(x)
  if type(x) == 'number' then return math.tointeger(x) or x end
  return x
end
local function fxKey(spec)
  return util.key(canon(spec.derived), canon(spec.ppq), canon(spec.endppqL or 0),
                  canon(spec.pitch), canon(spec.vel), canon(spec.detune or 0),
                  canon(spec.sample or 0))
end

-- onKeep carries the matched note's token + realised end onto the predicted spec, so a
-- kept fxNote is re-clipped through its token by the tail walk rather than re-added.
local function reconcileFx(existing, predicted, sink)
  reconcileDerived{ existing = existing, predicted = predicted, key = fxKey, sink = sink,
    onKeep = function(spec, have) spec.token, spec.endppq = have.token, have.endppq end }
end

----- delta-stream (carrier) reconciliation
-- Pure fn of lane-1 hosts; key by (cc, canon ppq) — REAPER float vs int prediction churns whole stream. see design/archive/note-macros.md § Delta-code allocation
local function reconcileCarrier(existing, predicted, sink)
  reconcileDerived{
    existing = existing, predicted = predicted, sink = sink,
    key   = function(x) return util.key(canon(x.cc), canon(x.ppq)) end,
    match = function(have, spec) return have.val == spec.val and have.shape == spec.shape end,
  }
end

---------- UPDATE MANAGER

local addEvent, assignEvent, deleteEvent, addParked, assignParked, deleteParked, flush, reload do

  ----- State

  local adds = {}
  local assigns = {}
  local deletes = {}
  local parkedEdits = {}
  local parkedUuidSeq = 0
  local chans = {}
  local byToken = {}
  local byUuid  = {}
  local dirtyPcChans = {}

  ----- Accessors

  -- Prevailing lane-1 detune at-or-before ppq; flush derives wire-raw = cents + detuneAt(seat).
  -- Full absorber reconciliation is rebuild's absorber pass; um just stages the best-effort value.
  local function detuneAt(chan, P)
    local n = util.seek(chans[chan].notes, 'at-or-before', P)
    return (n and n.detune) or 0
  end

  local function forEachAttachedPA(host, fn)
    for _, cc in pairs(byToken) do
      if cc.evType == 'pa' and cc.chan == host.chan and cc.pitch == host.pitch
        and cc.ppq >= host.ppq and cc.ppq < host.endppq then
        fn(cc)
      end
    end
  end

  ----- Low-level mutation

  --contract: only lane==1 notes index into chans[chan].notes
  --contract: higher-lane notes get queued for mm but don't feed detune/realisation reads
  --contract: caller supplies evt.evType
  local function addLowlevel(evt)
    local et = evt.evType
    if et == 'note' then
      if evt.lane == 1 then
        local tbl = chans[evt.chan].notes
        util.add(tbl, evt); sortByPPQ(tbl)
      end
    elseif et == 'pb' then
      local tbl = chans[evt.chan].pbs
      util.add(tbl, evt); sortByPPQ(tbl)
    end
    util.add(adds, { evt = evt })
  end

  --contract: dedupes by token; in-flight assigns to the same event collapse into one mm write
  --invariant: util.REMOVE markers must survive merging
  local function assignLowlevel(evt, update)
    local oldChan, oldLane = evt.chan, evt.lane
    util.assign(evt, update)
    -- Keep the lane-1 detune index coherent: a chan OR lane move migrates the
    -- entry between lists; a ppq move resorts in place (util.seek needs ascending).
    local function listFor(chan, lane)
      if evt.evType == 'note' and lane == 1 then return chans[chan].notes end
      if evt.evType == 'pb' then return chans[chan].pbs end
    end
    local oldList = listFor(oldChan, oldLane)
    local newList = listFor(evt.chan, evt.lane)
    if oldList ~= newList then
      if oldList then
        for i, item in ipairs(oldList) do if item == evt then table.remove(oldList, i); break end end
      end
      if newList then util.add(newList, evt); sortByPPQ(newList) end
    elseif update.ppq ~= nil and newList then
      sortByPPQ(newList)
    end
    if not evt.token then return end
    for _, e in ipairs(assigns) do
      if e.token == evt.token then
        -- Plain copy, not util.assign: util.assign collapses util.REMOVE → nil-the-key.
        for k, v in pairs(update) do e.update[k] = v end
        return
      end
    end
    util.add(assigns, { token = evt.token, update = update, evt = evt })
  end

  local function deleteLowlevel(evt)
    local et = evt.evType
    local tbl
    if et == 'note' then
      tbl = chans[evt.chan].notes
    elseif et == 'pb' then
      tbl = chans[evt.chan].pbs
    end

    if tbl then
      for i, item in ipairs(tbl) do
        if item == evt then
          table.remove(tbl, i)
          break
        end
      end
    end

    local token = evt.token

    if token then
      byToken[token] = nil
      util.add(deletes, { token = token, evt = evt })
      for j = #assigns, 1, -1 do
        if assigns[j].token == token then table.remove(assigns, j) end
      end
    else
      for j = #adds, 1, -1 do
        if adds[j].evt == evt then table.remove(adds, j); break end
      end
    end
  end

  ----- High-level ops

  -- um is a stager: pb authoring writes cents; wire raw is derived at flush (cents + detuneAt seat).
  -- Absorber seating/reseating happens in rebuild's absorber pass from the final note layout.

  local function dirtyPc(chan) dirtyPcChans[chan] = true end

  local function addNote(n)
    dirtyPc(n.chan)
    if lastMuteSet[n.chan] then n.muted = true end
    addLowlevel(n)
  end

  local function deleteNote(n, keepPAs)
    dirtyPc(n.chan)
    if not keepPAs then forEachAttachedPA(n, function(evt) deleteLowlevel(evt) end) end
    deleteLowlevel(n)
  end

  -- cullEnd is the span ceiling PAs are tested against; for an open tail
  -- it must be passed explicitly — see docs/trackerManager.md § Update manager.
  local function resizeNote(n, P1, P2, cullEnd)
    cullEnd = cullEnd or P2
    local shift = P1 - n.ppq
    if shift ~= 0 and P2 - n.endppq == shift then
      forEachAttachedPA(n, function(evt)
        assignLowlevel(evt, { ppq = evt.ppq + shift })
      end)
    else
      local lastPA
      forEachAttachedPA(n, function(evt)
        if evt.ppq <= P1 or evt.ppq >= cullEnd then
          if evt.ppq <= P1 and (not lastPA or evt.ppq > lastPA.ppq) then lastPA = evt end
          deleteLowlevel(evt)
        end
      end)
      if lastPA then assignLowlevel(n, { vel = lastPA.vel }) end
    end
    assignLowlevel(n, { ppq = P1, endppq = P2 })
  end

  --contract: lane/chan changes accepted; rebuild reseats columns via pickStampedLane
  --contract: chan change: rebuild's absorber pass reconciles fakes across both channels
  --contract: ppq/endppq route through resizeNote
  local function assignNote(n, update)
    -- lane/sample/ppq dirty PC priority; update.ppq covers direct + delay edits
    -- (realiseNoteUpdate maps delay→ppq); endppq alone doesn't move the onset, so no dirty.
    if update.sample ~= nil or update.ppq ~= nil or update.lane ~= nil then dirtyPc(n.chan) end
    if update.chan and update.chan ~= n.chan then dirtyPc(n.chan); dirtyPc(update.chan) end

    if update.ppq ~= nil or update.endppq ~= nil then
      local endppqL = update.endppqL ~= nil and update.endppqL or n.endppqL
      local cullEnd = endppqL == util.OPEN and util.OPEN or (update.endppq or n.endppq)
      resizeNote(n, update.ppq or n.ppq, update.endppq or n.endppq, cullEnd)
      update.ppq, update.endppq = nil, nil
    end
    if update.pitch then
      forEachAttachedPA(n, function(e) assignLowlevel(e, { pitch = update.pitch }) end)
    end
    if next(update) then assignLowlevel(n, update) end
  end

  ----- PC reconciliation (trackerMode mutation hook)

  local function reconcilePcs(chan)
    local records = {}
    for _, n in pairs(byToken) do
      if n.evType == 'note' and n.chan == chan then
        util.add(records, { ppq = n.ppq, ppqL = n.ppqL, lane = n.lane,
                            sample = n.sample or 0 })
      end
    end
    for _, a in ipairs(adds) do
      if a.evt.evType == 'note' and a.evt.chan == chan then
        local n = a.evt
        util.add(records, { ppq = n.ppq, ppqL = n.ppqL, lane = n.lane,
                            sample = n.sample or 0 })
      end
    end

    reconcilePCsForChan(chan, records, { del = deleteLowlevel, add = addLowlevel })
  end

  local function lookup(evtOrToken)
    local token = type(evtOrToken) == 'table' and evtOrToken.token or evtOrToken
    if not token then return end
    return byToken[token], token
  end

  ----- Public interface

  -- The live column event for a uuid, valid until the next rebuild.
  -- uuid is durable; token is re-keyed each rebuild, so cross-rebuild handles use uuid.
  function tm:byUuid(uuid) return byUuid[uuid] end

  function deleteEvent(evtOrToken)
    local evt = lookup(evtOrToken)
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
  --invariant: assignEvent consumes rawTime before calling; never reaches mm (docs/timing.md)
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

  function assignEvent(evtOrToken, update)
    local evt = lookup(evtOrToken)
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
  --contract: evt.rawTime=true bypasses translation (mirrors assignEvent; rescale-only caller)
  --invariant: rawTime consumed here so it never persists on the record or reaches mm
  --contract: pb authoring frame is logical cents; val stored as cents on the event
  --contract: um only stages; rebuild absorber pass reconciles seats, recomputes raw vals at flush
  function addEvent(evt)
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
      addLowlevel(evt)
    end
  end

  ----- Parked staging (B3): logical-only edits to the fx replace off-take.

  -- Specs are logical (no realised ppq); rebuildRegionPark derives realisation each rebuild.
  -- Dispatch on evType like addEvent: notes key by uuid (fxp-N minted for window-authored
  -- adds), ccs by (chan, cc, ppqL). Edits stage here and ride flush -- a parked edit that wrote
  -- ds inline would rebuild mid-batch and discard still-staged mm ops.

  local function mintParkedUuid()
    parkedUuidSeq = parkedUuidSeq + 1
    return 'fxp-' .. parkedUuidSeq
  end

  function addParked(spec)
    if spec.evType == 'note' and not spec.uuid then spec.uuid = mintParkedUuid() end
    util.add(parkedEdits, { op = 'add', spec = spec })
  end

  function assignParked(evt, update)
    util.add(parkedEdits, { op = 'assign', evt = evt, update = update })
  end

  function deleteParked(evt)
    util.add(parkedEdits, { op = 'delete', evt = evt })
  end

  local function findParked(list, ref)
    if ref.evType == 'note' then
      for i, s in ipairs(list) do if s.uuid == ref.uuid then return i end end
    else
      for i, s in ipairs(list) do
        if s.chan == ref.chan and s.cc == ref.cc and s.ppqL == ref.ppqL then return i end
      end
    end
  end

  -- Apply staged edits to cloned stashes, then write back under flushingParked so the inline
  -- dataChanged rebuild is suppressed (flush drives the one rebuild).
  local function flushParked()
    local notes = util.deepClone(ds:get('fxParked')   or {})
    local ccs   = util.deepClone(ds:get('fxParkedCC') or {})
    for _, e in ipairs(parkedEdits) do
      local ref  = e.spec or e.evt
      local list = ref.evType == 'note' and notes or ccs
      if e.op == 'add' then
        util.add(list, e.spec)
      else
        local i = findParked(list, ref)
        if i then
          if e.op == 'assign' then util.assign(list[i], e.update)
          else table.remove(list, i) end
        end
      end
    end
    parkedEdits = {}
    flushingParked = true
    if not util.deepEq(ds:get('fxParked')   or {}, notes) then ds:assign('fxParked',   #notes > 0 and notes or util.REMOVE) end
    if not util.deepEq(ds:get('fxParkedCC') or {}, ccs)   then ds:assign('fxParkedCC', #ccs   > 0 and ccs   or util.REMOVE) end
    flushingParked = false
  end

  ----- Flush: commit accumulated ops to mm.

  --contract: no-op if nothing staged
  --contract: commits deletes, then assigns, then adds under one mm:modify
  --contract: pb cents→raw conversion happens here
  --contract: byToken re-keyed live from mm:assign's returned token when an identity field moved
  --contract: snapshots ops before mm:modify; mm-callback re-entry can't re-emit in-flight ops
  --emits: preflush -- (adds, assigns, deletes)
  --contract: preflush fires before the no-op check so a subscriber can stage peer ops
  --emits: postflush -- nil
  --contract: postflush fires after mm:modify; subscribers read mm-stamped uuids on staged adds
  function flush()
    fire('preflush', adds, assigns, deletes)
    if cm:get('trackerMode') and next(dirtyPcChans) then
      for chan in pairs(dirtyPcChans) do reconcilePcs(chan) end
      dirtyPcChans = {}
    end
    if #adds == 0 and #assigns == 0 and #deletes == 0 and #parkedEdits == 0 then return end

    -- Parked edits stage alongside mm ops. Write the stash first (guarded), then let the mm
    -- commit's reload->rebuild pick it up; with no mm ops, drive the one rebuild explicitly.
    local hadMmOps = #adds > 0 or #assigns > 0 or #deletes > 0
    if #parkedEdits > 0 then flushParked() end
    if not hadMmOps then
      tm:rebuild(false)
      fire('postflush')
      return
    end

    perf.openFrame(); perf.start('flush')

    -- Single scan over all post-flush notes for same-(chan,pitch) MIDI legality (staging pre-clip).
    -- see docs/trackerManager.md § Pre-clip collision scan
    do
      local takeLen = tm:length()
      local byKey   = {}
      for _, n in pairs(byToken) do
        if n.evType == 'note' then util.bucket(byKey, util.key(n.chan, n.pitch), n) end
      end
      for _, o in ipairs(adds) do
        if o.evt.evType == 'note' then util.bucket(byKey, util.key(o.evt.chan, o.evt.pitch), o.evt) end
      end

      -- Dedup same-(chan,pitch) raw collision only when one is a regenerable fxNote or they share
      -- logical seat and detune; otherwise distinct voices: separate (+1) so each keeps its raw.
      local function supersedes(a, b)
        local aDerived, bDerived = a.derived ~= nil, b.derived ~= nil
        if aDerived ~= bDerived then return bDerived end
        return (a.endppqL or a.endppq) > (b.endppqL or b.endppq)
      end
      local function redundant(a, b)
        if (a.derived ~= nil) ~= (b.derived ~= nil) then return true end
        return a.ppqL == b.ppqL and (a.detune or 0) == (b.detune or 0)
      end

      local updates, kills = {}, {}
      for _, group in pairs(byKey) do
        table.sort(group, function(a, b)
          if a.ppq ~= b.ppq then return a.ppq < b.ppq end
          return (a.ppqL or 0) < (b.ppqL or 0)
        end)
        -- Walk the sorted voice: dedup true duplicates, nudge distinct collisions apart.
        -- onsetOf carries each survivor's post-separation raw onset.
        local voiced, onsetOf = {}, {}
        for _, n in ipairs(group) do
          local prev = voiced[#voiced]
          if prev and n.ppq <= onsetOf[prev] then
            if redundant(n, prev) then
              if supersedes(n, prev) then
                util.add(kills, prev); voiced[#voiced] = n; onsetOf[n] = onsetOf[prev]
              else
                util.add(kills, n)
              end
            else
              onsetOf[n] = onsetOf[prev] + 1
              util.add(voiced, n)
            end
          else
            onsetOf[n] = n.ppq
            util.add(voiced, n)
          end
        end

        for i = 1, #voiced do
          local n      = voiced[i]
          local nextOn = voiced[i + 1] and onsetOf[voiced[i + 1]] or math.huge
          local bound  = math.max(onsetOf[n] + 1, math.min(n.endppq, nextOn, takeLen))
          local up
          if onsetOf[n] ~= n.ppq then up = { ppq = onsetOf[n] } end
          if bound < n.endppq    then up = up or {}; up.endppq = bound end
          if up then util.add(updates, { n = n, up = up }) end
        end
      end

      for _, n in ipairs(kills) do deleteNote(n) end
      for _, u in ipairs(updates) do
        if u.n.token then assignNote(u.n, u.up)   -- committed: route PA/detune resize
        else            util.assign(u.n, u.up)    -- staged add: geometry only
        end
      end
    end

    local flushAdds, flushAssigns, flushDeletes = adds, assigns, deletes
    adds, assigns, deletes = {}, {}, {}
    perf.count('committed', #flushAdds + #flushAssigns + #flushDeletes)

    -- Same-pitch moves can alias ppq-keyed tokens: occupying move re-keys onto a peer's slot before
    -- that peer vacates. Sort descending so every vacate lands ahead of its occupy. see docs/trackerManager.md § Pre-clip collision scan
    table.sort(flushAssigns, function(a, b)
      return (a.update.ppq or a.evt.ppq or 0) > (b.update.ppq or b.evt.ppq or 0)
    end)

    -- pb wire conversion at flush: raw = centsToRaw(cents + detuneAt(seat)).
    -- Rebuild's absorber pass refines with the post-walk layout; this is best-effort for the interim.
    for _, e in ipairs(flushAssigns) do
      if e.evt.evType == 'pb' and e.update.cents ~= nil then
        e.update.val = centsToRaw(e.update.cents + detuneAt(e.evt.chan, e.evt.ppq))
      end
    end
    for _, a in ipairs(flushAdds) do
      if a.evt.evType == 'pb' then
        a.evt.val = centsToRaw((a.evt.cents or 0) + detuneAt(a.evt.chan, a.evt.ppq))
      end
    end

    perf.start('mm')
    mm:modify(function()
      for _, o in ipairs(flushDeletes) do
        mm:delete(o.token)
        byToken[o.token] = nil
      end
      for _, o in ipairs(flushAssigns) do
        local newTok = mm:assign(o.token, o.update)
        if newTok and newTok ~= o.token then
          byToken[o.token] = nil
          byToken[newTok]  = o.evt
          o.evt.token      = newTok
        end
      end
      for _, o in ipairs(flushAdds) do
        local tok = mm:add(o.evt)
        if tok then
          byToken[tok] = o.evt
          o.evt.token  = tok
        end
      end
    end)
    perf.stop('mm')
    perf.stop('flush'); perf.report('flush'); perf.closeFrame()
    fire('postflush')
  end

  ----- Init / reload: (re)load local cache from mm.

  -- Also clears staging buffers: rebuild must not carry un-flushed ops across
  -- (tokens may be stale for newly-added events; matches prior "fresh um per rebuild").
  function reload()
    adds, assigns, deletes = {}, {}, {}
    parkedEdits            = {}
    dirtyPcChans           = {}
    byToken                = {}
    byUuid                 = {}
    for i = 1, 16 do chans[i] = { notes = {}, pbs = {} } end

    for tok, e in mm:events() do
      local evt
      if e.evType == 'pb' then
        -- val is raw 14-bit converted to cents (um's frame). cents sidecar is authored logical value;
        -- nil for foreign-MIDI/pre-cents pbs — back-derived in rebuild's absorber pass from lane-1 layout.
        evt = util.pick(e, 'ppq ppqL chan shape tension derived frame cents',
                        { val = rawToCents(e.val), token = tok, evType = 'pb' })
        util.add(chans[evt.chan].pbs, evt)
      else
        evt = e
        evt.token = tok
        if evt.evType == 'note' and evt.lane == 1 then
          util.add(chans[evt.chan].notes, evt)
        end
      end
      byToken[tok] = evt
      if evt.uuid then byUuid[evt.uuid] = evt end
    end
    for i = 1, 16 do sortByPPQ(chans[i].notes); sortByPPQ(chans[i].pbs) end
  end

  reload()
end

---------- PUBLIC

----- Accessors

function tm:getChannel(chan)      return channels and channels[chan] end

function tm:channels()
  local i = 0
  return function()
    i = i + 1
    local channel = channels[i]
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

function tm:length()               return mm and mm:length() or 0 end
function tm:resolution()           return mm and mm:resolution() end
function tm:name()                 return mm and mm:name() end
function tm:setName(name)          if mm then mm:setName(name) end end
function tm:timeSigs()             return mm and mm:timeSigs() or {} end
function tm:interpolate(A, B, ppq, field) return mm and mm:interpolate(A, B, ppq, field) end

-- E_c: column is inner, global is outer (see docs/timing.md).
--contract: cached per-(cm, mm) pair; invalidated at rebuild head.
--  fromLogical returns rounded int + optional offset (raw ppqs are integer).
--  toLogical returns the raw float (ppqL is a float frame).
local clearSwing do
  local swing = nil
  local function currentSwing()
    if not swing then
      local global, column = nil, {}
      if mm then
        local length, ppqPerQN = mm:length() or 0, mm:resolution()
        local lib = cm:get('swings', { mergeTiers = true })
        local function resolve(name)
          local composite = name and lib[name]
          if timing.isIdentity(composite) or length <= 0 then return nil end
          return timing.resolveComposite(composite, length, ppqPerQN)
        end
        local sw = ds:get('swing') or {}
        global = resolve(sw.global)
        for chan, name in pairs(sw) do
          if chan ~= 'global' then column[chan] = resolve(name) end
        end
      end
      swing = {
        fromLogical = function(chan, ppqL)
          local ppqI = ppqL
          local c = column[chan]
          if c      then ppqI = timing.eval(c, ppqI) end
          if global then ppqI = timing.eval(global, ppqI) end
          return ppqI
        end,
        toLogical = function(chan, ppqI)
          local ppqL = ppqI
          if global then ppqL = timing.invert(global, ppqL) end
          local c = column[chan]
          if c      then ppqL = timing.invert(c, ppqL) end
          return ppqL
        end,
      }
    end
    return swing
  end

  function tm:fromLogical(chan, ppqL, offset)
    return util.round(currentSwing().fromLogical(chan, ppqL) + (offset or 0))
  end

  function tm:toLogical(chan, ppqI)
    return currentSwing().toLogical(chan, ppqI)
  end

  function clearSwing()
    swing = nil
  end
end

--contract: chan==nil marks all 16 channels stale; otherwise just the named channel
--contract: consumed by the next tm:rebuild, then cleared
function tm:markSwingStale(chan)
  if chan then staleSwing[chan] = true; return end
  for i = 1, 16 do staleSwing[i] = true end
end

----- Mutation

function tm:deleteEvent(evt)         deleteEvent(evt)         end
function tm:addEvent(evt)            addEvent(evt)            end
function tm:assignEvent(evt, update) assignEvent(evt, update) end
function tm:addParked(spec)           addParked(spec)           end
function tm:assignParked(evt, update) assignParked(evt, update) end
function tm:deleteParked(evt)         deleteParked(evt)         end
function tm:flush() flush() end

----- Length

-- On shrink, notes spanning the boundary keep their onset and have endppq clamped.
function tm:setLength(newPpq)
  if not mm then return end
  local oldPpq = mm:length() or 0
  if newPpq < oldPpq then
    local kills, clamps = {}, {}
    forEachEvent(function(_, evt, _, isNote)
      if evt.ppq >= newPpq then
        util.add(kills, evt)
      elseif isNote and evt.endppq > newPpq then
        util.add(clamps, evt)
      end
    end)
    for _, evt in ipairs(kills)  do deleteEvent(evt)                       end
    for _, evt in ipairs(clamps) do assignEvent(evt, { endppq = newPpq })  end
    flush()
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

  -- τ maps logical ppqL; events without ppqL fall back to raw (identical under identity swing).
  -- slopeAt scales delays for local realised stretch. Two passes so all reads are stable.
  local function applyTimeMap(tau, slopeAt)
    local plans = {}
    forEachEvent(function(_, evt, chan, isNote)
      local p = { evt = evt }
      if evt.ppqL ~= nil then
        p.newPpqL = tau(evt.ppqL)
        p.newPpq  = tm:fromLogical(chan, p.newPpqL)
      else
        p.newPpq = util.round(tau(evt.ppq))
      end
      if isNote then
        if evt.endppqL ~= nil then
          p.newEndppqL = tau(evt.endppqL)
          p.newEndppq  = tm:fromLogical(chan, p.newEndppqL)
        else
          p.newEndppq = util.round(tau(evt.endppq))
        end
        if evt.delay and evt.delay ~= 0 then
          p.newDelay = slopeAt(evt.ppqL or evt.ppq) * evt.delay
        end
      end
      util.add(plans, p)
    end)
    for _, p in ipairs(plans) do
      assignEvent(p.evt, {
        ppq      = p.newPpq,
        endppq   = p.newEndppq,
        delay    = p.newDelay,
        ppqL     = p.newPpqL,
        endppqL  = p.newEndppqL,
        rawTime  = true,
      })
    end
    flush()
  end

  applyTimeMap(function(t) return f * t end, function() return f end)
  mm:setLength(newPpq / mm:resolution())
end

-- Loop [0, oldPpq) at offsets k·oldPpq to fill newPpq; shrinks fall through to setLength.
-- see docs/trackerManager.md § Length operations
function tm:tileLength(newPpq)
  if not mm then return end
  local oldPpq = mm:length() or 0
  if oldPpq <= 0 or newPpq <= oldPpq then return self:setLength(newPpq) end

  local function snapshot(iter)
    local out = {}
    for _, evt in iter do
      if evt.ppq < oldPpq then
        local c = util.clone(evt, { uuid = true })
        util.add(out, c)
      end
    end
    return out
  end
  local sourceEvents = snapshot(mm:events())

  mm:setLength(newPpq / mm:resolution())

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
        if shift(c, delta) then mm:add(c) end
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

--contract: idempotent: emits an assign only when n.muted differs from desired
--invariant: lastMuteSet also tags later-added notes
--invariant: PA events ride along in note columns but carry no mute state — skipped
function tm:setMutedChannels(set)
  lastMuteSet = util.clone(set or {})
  forEachEvent(function(_, n, chan, isNote)
    if not isNote then return end
    local want = lastMuteSet[chan] == true
    if (n.muted == true) ~= want then
      assignEvent(n, { muted = want })
    end
  end)
  flush()
end

----- Rebuild step helpers

local function pushNoteCol(channel)
  local notes = channel.columns.notes
  return util.add(notes, { events = {} }), #notes
end

-- Column events keep chan/cc so each event is self-describing (the leaf-edit
-- facade resolves an event's column from its own chan + lane/cc; see trackerView).
local function projectCC(cc, token, overlay)
  local evt = util.clone(cc)
  evt.token = token
  if overlay then util.assign(evt, overlay) end
  return evt
end

-- Strict-next per note: first group member with a greater ppq,
-- chord-mates skipped. Precomputed O(n); see docs/trackerManager.md § Rebuild.
local function strictNextMap(groups, onset)
  onset = onset or function(rec) return rec.evt.ppq end
  local nextOf = {}
  for _, g in pairs(groups) do
    for i = #g - 1, 1, -1 do
      nextOf[g[i]] = onset(g[i + 1]) > onset(g[i])
                     and g[i + 1] or nextOf[g[i + 1]]
    end
  end
  return nextOf
end

-- Accumulate mm ops, commit once in canonical delete -> assign -> add order; no-op if empty.
-- assign re-keys a passed evt's token in place when an identity field moved.
local function mmBatch()
  local dels, assigns, adds, lazyAdds = {}, {}, {}, {}
  return {
    del     = function(evt)                util.add(dels, evt) end,
    assign  = function(evt, update)        util.add(assigns, { evt = evt, update = update }) end,
    add     = function(spec)               util.add(adds, spec) end,
    -- addLazy: fn produces its spec at commit, after any post-accumulation mutation it must read.
    addLazy = function(fn)                 util.add(lazyAdds, fn) end,
    commit  = function()
      if #dels + #assigns + #adds + #lazyAdds == 0 then return end
      mm:modify(function()
        for _, e in ipairs(dels) do mm:delete(e.token) end
        for _, a in ipairs(assigns) do
          local newTok = mm:assign(a.evt.token, a.update)
          if newTok and newTok ~= a.evt.token then a.evt.token = newTok end
        end
        for _, s  in ipairs(adds)     do mm:add(s)    end
        for _, fn in ipairs(lazyAdds) do mm:add(fn()) end
      end)
    end,
  }
end

-- True when raw ppq can't be explained by the logical projection: foreign MIDI (no ppqL) or
-- an external raw edit. staleSwing chans return false -- their divergence is an expected reseat.
local function rawDivergesFromLogical(evt)
  if evt.ppqL == nil      then return true  end
  if staleSwing[evt.chan] then return false end
  local d = evt.evType == 'note' and delayToPPQ(evt.delay or 0) or 0
  local rawFromLogical = tm:fromLogical(evt.chan, evt.ppqL, d)
  if evt.ppq == 0 and rawFromLogical < 0 then return false end
  return math.abs(evt.ppq - rawFromLogical) > EPS
end

-- Nudge colliding same-(chan,pitch) onsets to prev.ppq+1 (cascades; fixed externals frozen).
-- Pure geometry on evt.ppq; callers stage mm writes. Input sorted (raw, ppqL). see docs/trackerManager.md § Same-pitch onset separation
local function nudgeSamePitchOnsets(records)
  local moved, lastByVoice = {}, {}
  for _, n in ipairs(records) do
    local e   = n.evt
    local key = util.key(e.chan, e.pitch)
    local prev = lastByVoice[key]
    if prev and not e.fixed and e.ppq <= prev.evt.ppq then
      e.ppq = prev.evt.ppq + 1
      util.add(moved, n)
    end
    lastByVoice[key] = n
  end
  return moved
end

----- Rebuild steps

-- Partition mm notes stamped/external, lay internal columns, reseat stale-swing. Returns external.
-- see docs/trackerManager.md § Rebuild: partition
local function rebuildInternals(fx)
  local internal, external = {}, {}
  for _, note in mm:notes() do
    if note.derived then
      note.token = mm:tokenOf(note)
      util.add(fx.noteExisting[note.chan], note)
    elseif rawDivergesFromLogical(note) then util.add(external, note)
    else util.add(internal, note)
    end
  end

  local reseats  = mmBatch()
  local reseated = {}
  for _, note in ipairs(internal) do
    local channel = channels[note.chan]
    local notes = channel.columns.notes
    -- Stamped notes keep their authored lane verbatim (extended if missing);
    -- the tail walk clips tails afterward, so overlap here is never a concern.
    while #notes < note.lane do pushNoteCol(channel) end
    local col = notes[note.lane]
    -- clone not alias: projectLogical rewrites column ppq to logical; mm retains raw
    local colNote = util.clone(note)
    -- set detune/delay at ingestion to skip defensive guards downstream
    colNote.detune = colNote.detune or 0
    colNote.delay  = colNote.delay  or 0
    colNote.token  = mm:tokenOf(note)
    -- when swing is stale, rederive realised onset from logical; endppq handled by the tail walk.
    if staleSwing[note.chan] then
      colNote.ppq = tm:fromLogical(note.chan, colNote.ppqL, delayToPPQ(colNote.delay))
      util.add(reseated, { evt = colNote, was = note.ppq })
    end
    util.add(col.events, colNote)
  end

  -- Reswing can collapse two distinct-ppqL same-pitch notes onto one raw. Separate them before
  -- the commit so mm's reload-dedup never eats a voice -- the tail walk's gate runs far too late.
  table.sort(reseated, function(a, b)
    if a.evt.chan ~= b.evt.chan then return a.evt.chan < b.evt.chan end
    if a.evt.ppq  ~= b.evt.ppq  then return a.evt.ppq  < b.evt.ppq  end
    return a.evt.ppqL < b.evt.ppqL
  end)
  nudgeSamePitchOnsets(reseated)
  for _, r in ipairs(reseated) do
    if r.evt.ppq ~= r.was then reseats.assign(r.evt, { ppq = r.evt.ppq }) end
  end
  reseats.commit()

  return external
end

-- Carrier setup + CC walk: arm prior carriers/sidecars, reconcile (raw,ppqL), project CCs.
-- Returns reapCarriers; run after fx expansion. see docs/trackerManager.md § Rebuild: CC walk
local function rebuildCCs(fx)
  -- Carrier codes from the prior rebuild: route existing events out of cc columns; new codes
  -- allocated in fx expansion once windows are known. see design/archive/note-macros.md § Delta-code allocation
  local prevCarrier  = ds:get('fxCarrier') or {}   -- chan -> { {code, target}, ... }
  local carrierRoute = {}
  for chan, carriers in pairs(prevCarrier) do
    carrierRoute[chan] = {}
    for _, c in ipairs(carriers) do
      carrierRoute[chan][c.code] = true
      mm:wideCC(chan, c.code, true)
    end
  end

  local ccWrites = mmBatch()
  for _, cc in mm:ccs() do
    if cc.evType == 'cc' and carrierRoute[cc.chan] and carrierRoute[cc.chan][cc.cc] then
      -- Carrier: generator-owned, no metadata; routed out by allocated code,
      -- reconciled stream-level in fx expansion. see design/archive/note-macros.md § Delta-code allocation
      util.add(fx.ccExisting[cc.chan].carrier,
        { ppq = cc.ppq, val = cc.val, shape = cc.shape, cc = cc.cc, token = mm:tokenOf(cc) })
      goto continue
    end
    -- Rest seat: a generator-owned base CC at a real cc target (derived sidecar), routed out
    -- of columns like a carrier so it stays off-screen. see design/note-macros-v2.md § Continuous cc
    if cc.evType == 'cc' and cc.derived == 'ccbase' then
      util.add(fx.ccExisting[cc.chan].base,
        { ppq = cc.ppq, val = cc.val, cc = cc.cc, token = mm:tokenOf(cc) })
      goto continue
    end
    -- Replace fill: the generated curve written straight onto a cc target (replace mode), routed
    -- out like the rest seat and reconciled at Pass B. see design/note-macros-v2.md § Continuous cc
    if cc.evType == 'cc' and cc.derived == 'ccfill' then
      util.add(fx.ccExisting[cc.chan].fill,
        { ppq = cc.ppq, val = cc.val, shape = cc.shape, cc = cc.cc, token = mm:tokenOf(cc) })
      goto continue
    end
    if not cc.derived then
      if staleSwing[cc.chan] and cc.ppqL ~= nil then
        local newPpq = tm:fromLogical(cc.chan, cc.ppqL)
        if newPpq ~= cc.ppq then
          ccWrites.assign({ token = mm:tokenOf(cc) }, { ppq = newPpq })
          cc.ppq = newPpq
        end
      elseif rawDivergesFromLogical(cc) then
        local newPpqL = tm:toLogical(cc.chan, cc.ppq)
        ccWrites.assign({ token = mm:tokenOf(cc) }, { ppqL = newPpqL })
        cc.ppqL = newPpqL
      end
    end

    if cc.evType == 'cc' or cc.evType == 'at' or cc.evType == 'pc' then
      local channel = channels[cc.chan]
      local tok     = mm:tokenOf(cc)
      local col
      if cc.evType == 'cc' then
        col = channel.columns.ccs[cc.cc] or { cc = cc.cc, events = {} }
        channel.columns.ccs[cc.cc] = col
      else
        col = channel.columns[cc.evType] or { events = {} }
        channel.columns[cc.evType] = col
      end
      util.add(col.events, projectCC(cc, tok))
    end
    ::continue::
  end
  ccWrites.commit()

  -- Reap stale carrier codes (relocated / removed); persist live map for pa's add bank.
  -- see design/archive/note-macros.md § Delta-code allocation
  return function(newFxCarrier)
    for chan in pairs(carrierRoute) do
      local live = {}
      for _, c in ipairs(newFxCarrier[chan] or {}) do live[c.code] = true end
      for code in pairs(carrierRoute[chan]) do
        if not live[code] then mm:wideCC(chan, code, false) end
      end
    end
    if not util.deepEq(prevCarrier, newFxCarrier) and mm:take() then
      ds:assign('fxCarrier', next(newFxCarrier) and newFxCarrier or util.REMOVE)
    end
  end
end

-- Reconcile extra columns against the persisted extraColumns spec; grow the spec when a
-- channel already holds more note lanes than recorded.
local function rebuildExtraColumns()
  local extras = ds:get('extraColumns') or {}
  local grew   = false
  for i = 1, 16 do
    local c    = channels[i].columns
    local want = extras[i] or { notes = 1 }
    local n    = #c.notes
    if n > want.notes then
      want.notes = n
      extras[i] = want
      grew = true
    end
    while #c.notes < want.notes do pushNoteCol(channels[i]) end
    if want.pc then c.pc = c.pc or { events = {} } end
    if want.pb then c.pb = c.pb or { events = {} } end
    if want.at then c.at = c.at or { events = {} } end
    for ccNum in pairs(want.ccs or {}) do
      c.ccs[ccNum] = c.ccs[ccNum] or { cc = ccNum, events = {} }
    end
  end
  if grew and mm:take() then ds:assign('extraColumns', extras) end
end

-- Reintroduce externals: pack lane, stamp ppqL/endppqL, backfill metadata, tag `fixed`;
-- block window + tail passes -- onsets frozen, tails clipped. see docs/trackerManager.md § Rebuild: externals
local function rebuildExternals(external)
  if #external == 0 then return end

  --contract: true iff note fits col: no over-threshold overlap, coincident onset always refuses
  --invariant: overlap threshold: same-pitch 0, cross-pitch lenient; dominated-by≥2 refuses
  --contract: consulted only for unstamped raw notes; stamped notes never reach it
  local function noteColumnAccepts(col, note)
    local lenient = cm:get('overlapOffset') * mm:resolution()
    local noteppqI    = note.ppq - delayToPPQ(note.delay or 0)
    local noteEndppqI = note.endppq
    local dominated = 0
    for _, evt in ipairs(col.events) do
      local evtppqI = evt.ppq - delayToPPQ(evt.delay or 0)
      if noteppqI == evtppqI then return false end
      if noteppqI < evt.endppq and evtppqI < noteEndppqI then
        local threshold = (evt.pitch == note.pitch) and 0 or lenient
        local overlapAmount = math.min(evt.endppq, noteEndppqI) - math.max(evtppqI, noteppqI)
        if overlapAmount > threshold then return false end
        dominated = dominated + 1
      end
    end
    if dominated >= 2 then return false end
    return true
  end

  --contract: pick a lane for an external (unstamped) note via accept → sibling → push bump
  --invariant: called up front after internals placed + swing-reseated; tail walk clips tails after
  local function packExternalLane(channel, note)
    local notes = channel.columns.notes
    if note.lane then
      local col = notes[note.lane]
      if col and noteColumnAccepts(col, note) then return col, note.lane end
      if not col then
        while #notes < note.lane do pushNoteCol(channel) end
        return notes[note.lane], note.lane
      end
    end
    for i, col in ipairs(notes) do
      if noteColumnAccepts(col, note) then return col, i end
    end
    return pushNoteCol(channel)
  end

  table.sort(external, function(a, b) return a.ppq < b.ppq end)
  local trackerMode = cm:get('trackerMode')
  local extWrites = mmBatch()
  for _, note in ipairs(external) do
    local delay     = note.delay or 0
    local d         = delayToPPQ(delay)
    local probe     = { ppq = note.ppq, endppq = note.endppq,
                        pitch = note.pitch, delay = delay, lane = note.lane }
    local col, lane = packExternalLane(channels[note.chan], probe)
    local update    = {
      ppqL    = tm:toLogical(note.chan, note.ppq - d),
      endppqL = tm:toLogical(note.chan, note.endppq),
    }
    if note.lane   ~= lane then update.lane   = lane   end
    if note.detune == nil  then update.detune = 0      end
    if note.delay  == nil  then update.delay  = 0      end
    if trackerMode and note.sample == nil then update.sample = 0 end
    local colNote = util.clone(note)
    util.assign(colNote, update)
    colNote.fixed = true
    util.add(col.events, colNote)
    colNote.token = mm:tokenOf(note)
    extWrites.assign(colNote, update)
  end
  extWrites.commit()
end

-- Clip each parked member's tail to lane / pitch successor onset and take end:
-- displayed membership is the realised held chord, not raw overlaps (logical frame).
local function realiseParked(members, takeLenL)
  local byLane, byPitch, records = {}, {}, {}
  for _, m in ipairs(members) do
    local rec = { evt = m }
    util.add(records, rec)
    util.bucket(byLane,  m.lane,  rec)
    util.bucket(byPitch, m.pitch, rec)
  end
  local onset = function(rec) return rec.evt.ppqL end
  local function byOnset(a, b) return onset(a) < onset(b) end
  for _, g in pairs(byLane)  do table.sort(g, byOnset) end
  for _, g in pairs(byPitch) do table.sort(g, byOnset) end
  local laneNextOf  = strictNextMap(byLane,  onset)
  local pitchNextOf = strictNextMap(byPitch, onset)
  for _, rec in ipairs(records) do
    local m = rec.evt
    local ceil = (m.endppqL == nil or m.endppqL == util.OPEN) and takeLenL or m.endppqL
    local laneNext, pitchNext = laneNextOf[rec], pitchNextOf[rec]
    m.endppqL = math.max(m.ppqL + 1, math.min(ceil,
      laneNext  and laneNext.evt.ppqL  or math.huge,
      pitchNext and pitchNext.evt.ppqL or math.huge, takeLenL))
  end
end

-- Region-replace parking: authored events a replace window covers leave the take;
-- the prior parked set carries still-covered forward, restores the rest. see design/note-macros-v2.md § Generator output
local function rebuildRegionPark(deferred)
  local function unlink(events, evt)
    for i, e in ipairs(events) do if e == evt then table.remove(events, i); break end end
  end

  -- Park covered candidates, split the prior set into carry-forward / restore. scan records carry
  -- {evt,chan,sub,ppqL,events}; covered(chan,sub,ppqL); shape(evt,chan,sub)->spec.
  local function reconcilePark(scan, prior, covered, shape, batch)
    local newParked, restores = {}, {}
    for _, c in ipairs(scan) do
      if covered(c.chan, c.sub, c.ppqL) then
        util.add(newParked, shape(c.evt, c.chan, c.sub))
        batch.del(c.evt)
        unlink(c.events, c.evt)
      end
    end
    for _, spec in ipairs(prior) do
      if covered(spec.chan, spec.cc, spec.ppqL) then util.add(newParked, spec)
      else util.add(restores, spec) end
    end
    return newParked, restores
  end

  local function persistParked(key, newParked)
    if not util.deepEq(ds:get(key) or {}, newParked) and mm:take() then
      ds:assign(key, #newParked > 0 and newParked or util.REMOVE)
    end
  end

  -- Notes and ccs park in one batch -> a single delete-first commit for the whole phase.
  local batch = mmBatch()
  local parkWindows = generators.parkWindows(ds:get('fxRegions') or {})

  -- Notes: can't mute (note-on/off + CC matching), so a covered authored note leaves the take.
  do
    local windows = parkWindows.notes
    local function covered(chan, _, ppqL)
      for _, w in ipairs(windows[chan] or {}) do
        if ppqL >= w[1] and ppqL < w[2] then return true end
      end
      return false
    end

    local scan = {}
    for chan = 1, 16 do
      for laneIdx, col in ipairs(channels[chan].columns.notes) do
        for _, evt in ipairs(col.events) do
          if evt.evType ~= 'pa' and evt.ppqL ~= nil then
            util.add(scan, { evt = evt, chan = chan, sub = laneIdx, ppqL = evt.ppqL, events = col.events })
          end
        end
      end
    end
    local function shape(evt, chan, laneIdx)
      return util.pick(evt, "uuid ppqL endppqL pitch vel detune delay sample",
                       { evType = 'note', chan = chan, lane = laneIdx })
    end

    local newParked, restores = reconcilePark(scan, ds:get('fxParked') or {}, covered, shape, batch)

    -- Restores re-enter their columns now (token-less); the tail walk clips them in place and
    -- the tail walk's commit adds them after the derived deletions.
    for _, spec in ipairs(restores) do
      local channel = channels[spec.chan]
      while #channel.columns.notes < spec.lane do pushNoteCol(channel) end
      local colNote = util.clone(spec, { uuid = true })    -- sheds the parked uuid; mm:add mints a fresh one
      colNote.ppq = tm:fromLogical(spec.chan, spec.ppqL)    -- realised onset derived fresh (spec is logical-only)
      util.add(channel.columns.notes[spec.lane].events, colNote)
      table.sort(channel.columns.notes[spec.lane].events, function(a, b) return a.ppqL < b.ppqL end)
      -- Lazy: reshaped at commit so it reads colNote.ppq/endppq after the tail-walk clip.
      deferred.addLazy(function()
        return util.pick(colNote, "ppq endppq ppqL endppqL pitch vel detune delay sample",
                         { evType = 'note', chan = spec.chan, lane = spec.lane })
      end)
    end

    persistParked('fxParked', newParked)

    -- Off-take membership for the generator + grid: each is a render-ready logical cell
    -- (ppq/endppqC like a projected note); an emptied lane re-extends to keep a column home.
    local takeLen = tm:length()
    for chan = 1, 16 do channels[chan].parked = {} end
    for _, spec in ipairs(newParked) do
      local channel = channels[spec.chan]
      while #channel.columns.notes < spec.lane do pushNoteCol(channel) end
      util.add(channel.parked, util.pick(spec,
        "evType chan uuid ppqL endppqL pitch vel detune sample delay lane",
        { ppq = spec.ppqL, endppq = spec.endppqL or util.OPEN }))
    end
    for chan = 1, 16 do
      realiseParked(channels[chan].parked, tm:toLogical(chan, takeLen))
      for _, m in ipairs(channels[chan].parked) do m.endppqC = m.endppqL end
    end
  end

  -- CCs: a point event has no tail, so the Pass-A curve stands in on the target lane and
  -- restores add back immediately, seating a token-less projection for the view.
  do
    local windows = parkWindows.ccs   -- [chan][cc] = { {startL, endL}, ... }
    local function covered(chan, cc, ppqL)
      for _, w in ipairs((windows[chan] or {})[cc] or {}) do
        if ppqL >= w[1] and ppqL < w[2] then return true end
      end
      return false
    end

    local scan = {}
    for chan = 1, 16 do
      for cc, col in pairs(channels[chan].columns.ccs) do
        for _, evt in ipairs(col.events) do
          util.add(scan, { evt = evt, chan = chan, sub = cc, ppqL = evt.ppqL or evt.ppq, events = col.events })
        end
      end
    end
    local function shape(evt, chan, cc)
      return { evType = 'cc', chan = chan, cc = cc, ppqL = evt.ppqL or evt.ppq,
               val = evt.val, shape = evt.shape }
    end
    -- A logical cc event from a parked spec, seated at ppq (realised onset on restore; ppqL for a render cell).
    local function ccCell(spec, ppq)
      return util.pick(spec, "chan cc ppqL val shape", { evType = 'cc', ppq = ppq })
    end

    local newParked, restores = reconcilePark(scan, ds:get('fxParkedCC') or {}, covered, shape, batch)

    -- Seat a token-less projection so the view shows the restored cc this frame; next rebuild
    -- re-reads the real token'd event from the take. The add rides the shared park commit.
    for _, spec in ipairs(restores) do
      local ppq = tm:fromLogical(spec.chan, spec.ppqL)   -- realised onset derived fresh (spec is logical-only)
      batch.add(ccCell(spec, ppq))
      local channel = channels[spec.chan]
      local col = channel.columns.ccs[spec.cc]
      if not col then col = { cc = spec.cc, events = {} }; channel.columns.ccs[spec.cc] = col end
      util.add(col.events, ccCell(spec, ppq))
      table.sort(col.events, function(a, b) return (a.ppqL or a.ppq) < (b.ppqL or b.ppq) end)
    end

    persistParked('fxParkedCC', newParked)

    -- Render union: the parked authored cc stays the visible surface (the fill is hidden
    -- realisation), so creating a cc-replace region never blanks the lane. Mirrors channels[*].parked.
    for chan = 1, 16 do channels[chan].parkedCC = {} end
    for _, spec in ipairs(newParked) do
      local channel = channels[spec.chan]
      channel.columns.ccs[spec.cc] = channel.columns.ccs[spec.cc] or { cc = spec.cc, events = {} }
      util.add(channel.parkedCC, ccCell(spec, spec.ppqL))
    end
  end

  batch.commit()
end

-- Late PA projection: mixes into note columns once lanes are settled, so the view (and rebuildFx's
-- channelStreams) read it inline. Must follow column layout, so it can't ride the CC walk.
local function rebuildPA()
  local function findNoteColumnForPitch(channel, pitch, ppq_pos)
    local notes = channel.columns.notes
    for laneIdx, col in ipairs(notes) do
      for _, evt in ipairs(col.events) do
        if evt.endppq and evt.pitch == pitch and evt.ppq <= ppq_pos and evt.endppq > ppq_pos then
          return col, laneIdx
        end
      end
    end
    for laneIdx, col in ipairs(notes) do
      for _, evt in ipairs(col.events) do
        if evt.pitch == pitch then return col, laneIdx end
      end
    end
  end

  for _, cc in mm:ccs() do
    if cc.evType == 'pa' then
      local noteCol, lane = findNoteColumnForPitch(channels[cc.chan], cc.pitch, cc.ppq)
      if noteCol then
        util.add(noteCol.events, projectCC(cc, mm:tokenOf(cc), { lane = lane }))
      end
    end
  end
end

-- Fx expansion: fx-carrying notes / fx-regions -> derived notes, CCs, carriers;
-- reconcile vs existing, note writes deferred to the tail walk. Returns per-chan carrier map. see design/archive/note-macros.md § Pipeline placement
local function rebuildFx(fx, deferred)
  local newFxCarrier = {}

  -- Windows (read-only): fx host voice extents + per-note same-lane successor ppqL, floored by authored
  -- end; no realised round-trip (G4-stable). see design/archive/note-macros.md § host contract
  local fxWindow, nextInLane = {}, {}
  do
    local takeLen = tm:length()
    for chan = 1, 16 do
      local takeLenL = tm:toLogical(chan, takeLen)
      local byLane = {}
      for laneIdx, col in ipairs(channels[chan].columns.notes) do
        for _, evt in ipairs(col.events) do
          if evt.evType ~= 'pa' and evt.ppqL ~= nil then
            util.bucket(byLane, laneIdx, { evt = evt })
          end
        end
      end
      for _, g in pairs(byLane) do table.sort(g, function(a, b) return a.evt.ppq < b.evt.ppq end) end
      local laneNextOf = strictNextMap(byLane)
      for _, g in pairs(byLane) do
        for _, rec in ipairs(g) do
          local nextRec = laneNextOf[rec]
          nextInLane[rec.evt] = nextRec and nextRec.evt
          if rec.evt.fx then
            -- Take is the world: a tail past take end (paste / overshooting move)
            -- can't sound past it; window caps at take regardless of authored ceiling.
            local endL = (rec.evt.endppqL == nil or rec.evt.endppqL == util.OPEN)
                         and takeLenL or math.min(rec.evt.endppqL, takeLenL)
            if nextRec then endL = math.min(endL, nextRec.evt.ppqL) end
            fxWindow[rec.evt] = endL
          end
        end
      end
    end
  end

  -- Authored pb breakpoints per channel, exposed to the generator as channel input
  -- (authored only, fakes excluded). see design/note-macros-v2.md § A4
  local authoredPbByChan = {}
  for _, cc in mm:ccs() do
    if cc.evType == 'pb' and not cc.derived and cc.cents ~= nil then
      util.bucket(authoredPbByChan, cc.chan, { ppqL = cc.ppqL or cc.ppq, cents = cc.cents })
    end
  end
  for _, list in pairs(authoredPbByChan) do
    table.sort(list, function(a, b) return a.ppqL < b.ppqL end)
  end

  local res = mm:resolution()
  local pbRangeCents = cm:get('pbRange') * 100   -- slide clamps its target to what pb can reach
  local temper = tuning.findTemper(cm:get('temper'), cm:get('tempers'))
  local function stepOp(pitch, detune, n)        -- trill: scale steps -> (pitch, detune) via the temper
    return tuning.transposeStep(temper, pitch, detune, n)
  end
  local extras  = ds:get('extraColumns') or {}   -- authored columns block carrier codes
  local chanCtx = { resolution = res, pbRangeCents = pbRangeCents, step = stepOp,
                    nextSameLaneNote = function(host) return nextInLane[host.notes[1]] end }
  -- Explicit fx-regions (channel x ppq span + fx, no host note), re-queried each
  -- rebuild and bucketed by channel. see design/note-macros-v2.md § The anchor generalized
  local fxRegionsByChan = {}
  for _, region in ipairs(ds:get('fxRegions') or {}) do
    util.bucket(fxRegionsByChan, region.chan, region)
  end
  -- Membership is overlap, not storage: authored notes re-queried each rebuild; one walk
  -- feeds generator events + fixed lane occupancy. see design/note-macros-v2.md § The anchor generalized
  local function eachWindowNote(chan, startL, endL, fn)
    for laneIdx, col in ipairs(channels[chan].columns.notes) do
      for _, evt in ipairs(col.events) do
        if evt.evType ~= 'pa' and evt.ppqL ~= nil then
          local hi = (evt.endppqL == nil or evt.endppqL == util.OPEN) and endL or evt.endppqL
          if evt.ppqL < endL and hi > startL then fn(laneIdx, evt.ppqL, hi, evt) end
        end
      end
    end
  end
  local function membersOf(chan, startL, endL)
    local out = {}
    eachWindowNote(chan, startL, endL, function(_, lo, hi, evt)
      util.add(out, util.pick(evt, "pitch vel detune", { ppqL = lo, endppqL = hi }))
    end)
    return out
  end
  -- cc-family streams a generator reads over its window (notes via membersOf). Key `evt.ppqL or evt.ppq`:
  -- ppqL nil when raw==logical (logical projection); pb sliced from the pre-producer authoredPbByChan. see design/note-macros-v2.md § A4
  local function channelStreams(chan, startL, endL)
    local cols = channels[chan].columns
    local function within(ppqL) return ppqL >= startL and ppqL < endL end
    local pas, ccs, ats, pb = {}, {}, {}, {}
    for _, col in ipairs(cols.notes) do
      for _, evt in ipairs(col.events) do
        local ppqL = evt.ppqL or evt.ppq
        if evt.evType == 'pa' and within(ppqL) then
          util.add(pas, { ppqL = ppqL, pitch = evt.pitch, vel = evt.vel })
        end
      end
    end
    for ccNum, col in pairs(cols.ccs) do
      for _, evt in ipairs(col.events) do
        local ppqL = evt.ppqL or evt.ppq
        if within(ppqL) then util.bucket(ccs, ccNum, { ppqL = ppqL, val = evt.val }) end
      end
    end
    for _, evt in ipairs(cols.at and cols.at.events or {}) do
      local ppqL = evt.ppqL or evt.ppq
      if within(ppqL) then util.add(ats, { ppqL = ppqL, val = evt.val }) end
    end
    for _, bp in ipairs(authoredPbByChan[chan] or {}) do
      if within(bp.ppqL) then util.add(pb, { ppqL = bp.ppqL, cents = bp.cents }) end
    end
    return pas, ccs, ats, pb
  end
  -- Deterministic allocator: lowest lane free of overlap, authored notes seed occupancy;
  -- emission order -> deterministic -> G4-stable. see design/note-macros-v2.md § Generator output
  local function allocateRegionLanes(chan, startL, endL, derived)
    local occupied = {}
    eachWindowNote(chan, startL, endL, function(laneIdx, lo, hi)
      util.bucket(occupied, laneIdx, { lo, hi })
    end)
    local function laneFree(lane, lo, hi)
      for _, iv in ipairs(occupied[lane] or {}) do
        if lo < iv[2] and hi > iv[1] then return false end
      end
      return true
    end
    for _, spec in ipairs(derived) do
      local lane = 1
      while not laneFree(lane, spec.ppqL, spec.endppqL) do lane = lane + 1 end
      util.bucket(occupied, lane, { spec.ppqL, spec.endppqL })
      spec.lane = lane
    end
  end
  for chan = 1, 16 do
    -- Pass A: run every generator. Structural notes commit per lane; continuous deltas
    -- stash with their window for colouring (channel-wide, not note-tied). see design/archive/note-macros.md § Continuous realisation
    local predicted, pending, ccFill = {}, {}, {}
    -- One producer interface, two sources: a note with fx (v1 augment) or an explicit
    -- fxRegion; the generator sees neither. see design/note-macros-v2.md § The anchor generalized
    local function runProducer(p)
      local startL, endL = p.window[1], p.window[2]
      -- The host the generators read: the note membership plus the windowed channel input
      -- streams, built once per host (not per kind). see design/note-macros-v2.md § A4
      local pas, ccs, ats, pb = channelStreams(chan, startL, endL)
      local host = { window = { startL, endL }, chan = chan, lane = p.lane, id = p.id,
                     notes = p.notes, pas = pas, ccs = ccs, ats = ats, pb = pb }
      -- Region producers (lane unset) defer their notes: lanes are allocated over the
      -- whole batch after the fx loop. Note producers ride the host's own lane inline.
      local regionNotes = p.lane == nil and {} or nil
      for _, params in ipairs(p.fx) do
        local meta = generators.kinds[params.kind]
        if meta then
          local out = meta.expand(host, params, chanCtx)
          for _, fn in ipairs(out.notes) do
            local spec = {
              evType = 'note', chan = chan, lane = p.lane, derived = p.id,
              pitch = fn.pitch, vel = fn.vel, detune = fn.detune or 0,
              delay = p.delay or 0, sample = p.sample,
              ppqL = fn.ppqL, endppqL = fn.endppqL,
              ppq    = tm:fromLogical(chan, fn.ppqL,    p.d),
              endppq = tm:fromLogical(chan, fn.endppqL, p.d),
            }
            if regionNotes then util.add(regionNotes, spec)
            else util.add(predicted, spec) end
          end
          -- pb (augment+replace) and cc augment ride the additive carrier; cc replace alone
          -- forks off it -- the curve goes straight on the target lane, authored cc parked at 4.5b.
          local target = meta.dest ~= 'note' and meta.dest or nil
          if target and #out.delta > 0 then
            if meta.mode == 'replace' and type(target) == 'number' then
              -- cc replace: write the curve onto the target cc lane verbatim. No carrier is
              -- allocated, so the node never registers (adst) the target -- it hears it direct.
              for _, bp in ipairs(out.delta) do
                util.add(ccFill, { evType = 'cc', chan = chan, cc = target, derived = 'ccfill',
                                   ppq = tm:fromLogical(chan, bp.ppqL, p.d), val = bp.val, shape = bp.shape })
              end
            else
              -- Replace overwrites the wire over [startL,endL): record it for the absorber pass's base suppression.
              if meta.mode == 'replace' and target == 'pb' then
                util.add(fx.replacePb[chan], { startL, endL })
              end
              -- cc augment with no authored base needs a resting seat; carry its value so Pass B
              -- emits it once per target. see design/note-macros-v2.md § Continuous cc
              local rest = type(target) == 'number'
                and (p.fx.rest or generators.ccDefaultRest[target] or 0) or nil
              util.add(pending, { startL = startL, endL = endL,
                                  target = target, delta = out.delta, d = p.d, rest = rest })
            end
          end
        end
      end
      if regionNotes then
        allocateRegionLanes(chan, startL, endL, regionNotes)
        for _, spec in ipairs(regionNotes) do util.add(predicted, spec) end
      end
    end

    -- Note producers: fx.hostEnd stash sustains the v1 augment view-restore; the
    -- derived notes ride the host's own lane.
    for laneIdx, col in ipairs(channels[chan].columns.notes) do
      for _, host in ipairs(col.events) do
        if host.fx and host.evType ~= 'pa' then
          local endL = fxWindow[host]
          fx.hostEnd[host] = tm:fromLogical(chan, endL)
          runProducer{ window = { host.ppqL, endL }, notes = { host }, fx = host.fx,
                       id = host.uuid, lane = laneIdx, delay = host.delay,
                       sample = host.sample, d = delayToPPQ(host.delay) }
        end
      end
    end

    -- Region producers: no host note. A discrete-replace kind feeds the realised parked chord
    -- (parking frees the lanes); else members still sound and feed the live overlap. see design/note-macros-v2.md § Generator output
    for _, region in ipairs(fxRegionsByChan[chan] or {}) do
      local startL, endL = region.startppq, region.endppq
      local members
      if generators.parksNotes(region) then
        members = {}                             -- replace: derived notes stand in for the parked chord
        for _, m in ipairs(channels[chan].parked or {}) do
          if m.ppqL >= startL and m.ppqL < endL then util.add(members, m) end
        end
      else
        members = membersOf(chan, startL, endL)  -- augment: members still sound
      end
      runProducer{ window = { startL, endL }, notes = members,
                   fx = region.fx, id = region.uuid, lane = nil, d = 0 }
    end

    -- Reconcile existence (stamps kept specs with token + realised end); defer writes to the tail walk's atomic commit.
    -- fx.noteLive holds the predicted specs; the tail walk clips them in place.
    reconcileFx(fx.noteExisting[chan], predicted, deferred)
    for _, spec in ipairs(predicted) do
      util.add(fx.noteLive[chan], { evt = spec, lane = spec.lane })
    end

    -- Pass B: per target, interval-colour stashed instances -- overlapping carriers get
    -- distinct codes (node sums by target), disjoint share the coldest. see design/archive/note-macros.md § Delta-code allocation
    local occupied = {}
    for code in pairs(channels[chan].columns.ccs or {}) do occupied[code] = true end
    for code in pairs((extras[chan] or {}).ccs or {})   do occupied[code] = true end
    local byTarget = {}
    for _, inst in ipairs(pending) do util.bucket(byTarget, inst.target, inst) end
    local targets = util.keys(byTarget)
    table.sort(targets, function(a, b) return tostring(a) < tostring(b) end)

    local predictedDelta, lastDeltaPpq, newCarriers = {}, {}, {}
    for _, target in ipairs(targets) do
      local insts = byTarget[target]
      table.sort(insts, function(a, b)
        if a.startL ~= b.startL then return a.startL < b.startL end
        return a.endL < b.endL
      end)
      local colourEnd, colourCode = {}, {}
      for _, inst in ipairs(insts) do
        local colour
        for ci = 1, #colourEnd do
          if colourEnd[ci] <= inst.startL then colour = ci; break end
        end
        if not colour then
          colour = #colourEnd + 1
          local code = generators.allocateCarrier(occupied)
          colourCode[colour] = code
          occupied[code], occupied[code + 32] = true, true
          mm:wideCC(chan, code, true)
          util.add(newCarriers, { code = code, target = target })
        end
        colourEnd[colour] = inst.endL
        -- dedup per code: a disjoint sharer's start can land on the prior window's
        -- re-centre ppq (both centre, so identical) -- keep the first.
        local code = colourCode[colour]
        for _, bp in ipairs(inst.delta) do
          local ppq = tm:fromLogical(chan, bp.ppqL, inst.d)
          if ppq ~= lastDeltaPpq[code] then
            lastDeltaPpq[code] = ppq
            -- pb deltas are cents (-> raw); cc deltas are already cc steps. Shared 14-bit
            -- transport: (8192 + raw) / 128. see design/note-macros-v2.md § Continuous cc
            local raw = target == 'pb' and centsToRaw(bp.val) or bp.val
            util.add(predictedDelta, {
              evType = 'cc', chan = chan, cc = code, ppq = ppq,
              val = (8192 + raw) / 128, shape = bp.shape,
            })
          end
        end
      end
    end

    -- Anchor each carrier to 0 at take start; CC chase re-establishes centre
    -- on any loop/seek before the first host. see design/archive/note-macros.md § Continuous realisation
    local earliest = {}
    for _, e in ipairs(predictedDelta) do
      if not earliest[e.cc] or e.ppq < earliest[e.cc] then earliest[e.cc] = e.ppq end
    end
    for code, first in pairs(earliest) do
      if first ~= 0 then
        util.add(predictedDelta, { evType = 'cc', chan = chan, cc = code,
                                   ppq = 0, val = (8192 + centsToRaw(0)) / 128, shape = 'slow' })
      end
    end

    -- Rest seats: one base CC per augment cc target lacking authored automation (derived ones
    -- already routed out, so an empty cc column == no authored base). see design/note-macros-v2.md § Continuous cc
    local predictedBase = {}
    for _, target in ipairs(targets) do
      if type(target) == 'number' and not channels[chan].columns.ccs[target] then
        util.add(predictedBase, { evType = 'cc', chan = chan, cc = target, ppq = 0,
                                  val = byTarget[target][1].rest or 0, shape = 'step', derived = 'ccbase' })
      end
    end
    local wires = mmBatch()
    reconcileDerived{
      existing = fx.ccExisting[chan].base, predicted = predictedBase, sink = wires,
      key   = function(x) return util.key(canon(x.cc), canon(x.ppq)) end,
      match = function(have, spec) return have.val == spec.val end,
    }
    -- cc-replace fill: reconcile the generated curve on its target lane; shape is part of the
    -- match -- it drives REAPER's interpolation. see design/note-macros-v2.md § Continuous cc
    reconcileDerived{
      existing = fx.ccExisting[chan].fill, predicted = ccFill, sink = wires,
      key   = function(x) return util.key(canon(x.cc), canon(x.ppq)) end,
      match = function(have, spec) return have.val == spec.val and have.shape == spec.shape end,
    }

    reconcileCarrier(fx.ccExisting[chan].carrier, predictedDelta, wires)
    wires.commit()
    if #newCarriers > 0 then newFxCarrier[chan] = newCarriers end
  end
  return newFxCarrier
end

-- Unified tail/onset walk + atomic commit: real notes, fixed externals, fx.noteLive
-- walk together (onset clamp then tail clip); host clip + fxNote del/add in one mm:modify. see docs/trackerManager.md § Rebuild: tail walk
local function rebuildTails(fx, deferred)
  local takeLen = tm:length()
  local clampWrites = mmBatch()
  for chan = 1, 16 do
    local notes, byLane, byPitch = {}, {}, {}
    for laneIdx, col in ipairs(channels[chan].columns.notes) do
      for _, evt in ipairs(col.events) do
        if evt.evType ~= 'pa' and evt.ppqL ~= nil then
          local n = { evt = evt, lane = laneIdx }
          util.add(notes, n)
          util.bucket(byLane,  laneIdx,   n)
          util.bucket(byPitch, evt.pitch, n)
        end
      end
    end
    for _, w in ipairs(fx.noteLive[chan]) do
      local fn = { evt = w.evt, lane = w.lane }
      util.add(notes, fn)
      util.bucket(byLane,  w.lane,      fn)
      util.bucket(byPitch, w.evt.pitch, fn)
    end
    if #notes == 0 then goto nextChan end

    local function rawThenLogical(a, b)
      if a.evt.ppq ~= b.evt.ppq then return a.evt.ppq < b.evt.ppq end
      return a.evt.ppqL < b.evt.ppqL
    end
    local function sortAll()
      table.sort(notes, rawThenLogical)
      for _, g in pairs(byLane)  do table.sort(g, rawThenLogical) end
      for _, g in pairs(byPitch) do table.sort(g, rawThenLogical) end
    end
    sortAll()

    -- Same-pitch onset separation; retro-clip subsumed by tail pass. Token'd events assign;
    -- a new fxNote (no token yet) mutates in place, riding into mm:add at the atomic commit.
    for _, n in ipairs(nudgeSamePitchOnsets(notes)) do
      if n.evt.token then clampWrites.assign(n.evt, { ppq = n.evt.ppq }) end
    end
    sortAll()

    local laneNextOf  = strictNextMap(byLane)
    local pitchNextOf = strictNextMap(byPitch)

    for _, n in ipairs(notes) do
      local e         = n.evt
      local ceiling   = e.endppqL == util.OPEN and math.huge
                        or e.endppqL and tm:fromLogical(chan, e.endppqL)
                        or math.huge
      local laneNext  = laneNextOf[n]
      local pitchNext = pitchNextOf[n]
      local laneClip  = laneNext
        and tm:fromLogical(chan, laneNext.evt.ppqL) + (e.overlap or 0)
        or math.huge
      local pitchClip = pitchNext and pitchNext.evt.ppq or math.huge
      local bound     = math.max(e.ppq + 1,
                          math.min(ceiling, laneClip, pitchClip, takeLen))
      local rounded   = util.round(bound)
      if rounded ~= e.endppq then
        if e.token then deferred.assign(e, { endppq = rounded }) end
        e.endppq = rounded
      end
    end
    ::nextChan::
  end
  -- Clamps reindex colliding same-pitch onsets separately: reload separates the shared content-keyed token before the clip pass dereferences it.
  -- Clips only touch endppq, never re-key — safe to batch with adds.
  clampWrites.commit()
  -- Host clips (each clipped to first fxNote) commit WITH the fxNote del/add + restores in one
  -- mm:modify/MIDI_Sort; canonical delete-first means no transient same-pitch overlap.
  deferred.commit()

  -- Restore pre-fx tail onto column events so the view sees the authored
  -- note; mm is untouched, so the take and G4 round-trip are unaffected.
  for host, rawEnd in pairs(fx.hostEnd) do host.endppq = rawEnd end
end

-- Reseat absorber pbs against the post-walk lane-1 layout, recompute their raw vals,
-- and project the pb column. see docs/tuning.md § Absorber reconciliation
local function rebuildPbs(noteLive, replacePb)
  local extras = ds:get('extraColumns') or {}

  local function detuneAt(events, P)
    local n = util.seek(events, 'at-or-before', P)
    return (n and n.detune) or 0
  end

  local function isCurved(shape)
    return shape and shape ~= 'step' and shape ~= 'linear'
  end

  -- Replace-pb overwrites the wire over its window, so an authored pb there contributes 0 cents
  -- to its wire raw (column cents untouched) -- the node's base is detune-only. see design/note-macros-v2.md § Continuous pb replace
  local function inReplacePb(chan, P)
    local pL = tm:toLogical(chan, P)
    for _, w in ipairs(replacePb[chan]) do
      if pL >= w[1] and pL < w[2] then return true end
    end
    return false
  end

  -- Per-chan lane-1 sort, used both at reconcile and inside mm:modify.
  local lane1ByChan = {}
  for chan = 1, 16 do
    local lane1 = channels[chan].columns.notes[1]
    local list  = {}
    if lane1 then
      for _, n in ipairs(lane1.events) do
        if n.evType ~= 'pa' then util.add(list, n) end
      end
    end
    -- Derived lane-1 fxNotes (a trill's per-fxNote detune) are routed out of
    -- columns; union them so the absorber pass seats their detune jumps.
    for _, w in ipairs(noteLive[chan]) do
      if w.lane == 1 then util.add(list, w.evt) end
    end
    table.sort(list, function(a, b) return a.ppq < b.ppq end)
    lane1ByChan[chan] = list
  end

  -- mm uses content-keyed tokens: any pb whose ppq we touch needs its pre-mutation token
  -- captured up front. Each pb here is a mm:ccs() clone with origTok set once.
  local pbsByChan = {}
  for _, cc in mm:ccs() do
    if cc.evType == 'pb' then
      cc.origTok, cc.origShape = mm:tokenOf(cc), cc.shape
      util.bucket(pbsByChan, cc.chan, cc)
    end
  end

  local pbWrites = mmBatch()
  -- CCINTERP is interpolated points per QN; the densify grid wants a tick step.
  local gridStep = math.max(1, util.round((mm:resolution() or 960) / mm:ccInterp()))

  for chan = 1, 16 do
    local lane1Events = lane1ByChan[chan]
    local pbs         = pbsByChan[chan] or {}
    table.sort(pbs, function(a, b) return a.ppq < b.ppq end)

    -- Back-derive cents for any pb missing it (foreign-MIDI/pre-cents pbs carry raw only).
    -- Marked so the consolidated assign below always carries cents to the sidecar.
    local persistCents = {}
    for _, pb in ipairs(pbs) do
      if pb.cents == nil then
        pb.cents = rawToCents(pb.val) - detuneAt(lane1Events, pb.ppq)
        persistCents[pb] = true
      end
    end

    -- Authored (non-derived) pbs in ppq order: the value stream the seats sample.
    local realPbs = {}
    for _, pb in ipairs(pbs) do
      if not pb.derived then util.add(realPbs, pb) end
    end

    -- Prevailing authored cents at any ppq: interpolate between the bounding
    -- breakpoints, hold the last past the end, 0 before the first.
    local function streamValue(ppq)
      local A, B
      for _, pb in ipairs(realPbs) do
        if pb.ppq <= ppq then A = pb else B = pb break end
      end
      if not A then return 0 end
      if not B then return A.cents end
      return mm:interpolate(A, B, ppq, 'cents')
    end

    -- Authored breakpoints bounding M, excluding any pb exactly at M.
    local function spanAround(M)
      local A, B
      for _, pb in ipairs(realPbs) do
        if pb.ppq < M then A = pb elseif pb.ppq > M then B = pb break end
      end
      return A, B
    end

    -- Detune onsets: every lane-1 ppq whose detune differs from its predecessor.
    local onsets, prev = {}, 0
    for _, n in ipairs(lane1Events) do
      if n.detune ~= prev then util.add(onsets, { ppq = n.ppq, ppqL = n.ppqL }) end
      prev = n.detune
    end

    -- Seats to realise: ppq -> { cents, ppqL, shape }. The consolidated assign turns each
    -- into wire raw = centsToRaw(cents + detune). A flat/held/absent stream needs only a
    -- lone step seat; a value that ramps across the onset rides linearly, so the detune
    -- step splits onto a dual point and a curved segment densifies. see docs/tuning.md
    local seats = {}
    for _, o in ipairs(onsets) do
      local v    = streamValue(o.ppq)
      local A, B = spanAround(o.ppq)
      local ramps = A and B and A.shape and A.shape ~= 'step'
                    and (isCurved(A.shape) or A.cents ~= B.cents)
      if ramps then
        -- Dual point: the curve value held across a one-tick detune step (before carries
        -- the old detune cell, at carries the new), both linear so the curve rides through.
        seats[o.ppq - 1] = { cents = v, ppqL = tm:toLogical(chan, o.ppq - 1), shape = 'linear' }
        seats[o.ppq]     = { cents = v, ppqL = o.ppqL, shape = 'linear' }
      else
        seats[o.ppq]     = { cents = v, ppqL = o.ppqL, shape = 'step' }
      end
    end

    -- Densify each curved authored segment that contains an onset into a linear polyline
    -- on the fixed CCINTERP grid -- stable keys (from authored ppqs) keep it churn-free.
    for i = 1, #realPbs - 1 do
      local A, B = realPbs[i], realPbs[i + 1]
      local hasOnset = false
      for _, o in ipairs(onsets) do
        if o.ppq > A.ppq and o.ppq < B.ppq then hasOnset = true break end
      end
      if isCurved(A.shape) and hasOnset then
        local p = A.ppq + gridStep
        while p < B.ppq do
          if not seats[p] then
            seats[p] = { cents = streamValue(p), ppqL = tm:toLogical(chan, p), shape = 'linear' }
          end
          p = p + gridStep
        end
      end
    end

    -- Anchor a pb-active channel at its first lane-1 onset (I2a):
    -- without it, playback inherits the synth's unknown prior bend.
    local first = lane1Events[1]
    if first and not seats[first.ppq] then
      local hasReal, anchored = false, false
      for _, pb in ipairs(realPbs) do
        hasReal = true
        if pb.ppq <= first.ppq then anchored = true break end
      end
      if (next(seats) ~= nil or hasReal) and not anchored then
        seats[first.ppq] = { cents = streamValue(first.ppq), ppqL = first.ppqL, shape = 'step' }
      end
    end

    -- Match existing pbs to seats. A real pb at a seat covers it (it steps detune itself);
    -- fakes consume any already at a seat, move remaining fakes to fill the rest, delete the
    -- leftovers.
    local realAt, availAbsorbers = {}, {}
    for _, pb in ipairs(pbs) do
      if pb.derived then util.add(availAbsorbers, pb)
      else realAt[pb.ppq] = pb end
    end
    for ppq in pairs(seats) do
      if realAt[ppq] then seats[ppq] = nil end
    end

    local restampPpqL = {}  -- pb -> newPpqL (existing fake at a seat with stale ppqL)
    for i = #availAbsorbers, 1, -1 do
      local f, seat = availAbsorbers[i], seats[availAbsorbers[i].ppq]
      if seat then
        f.cents, f.shape = seat.cents, seat.shape
        if f.ppqL ~= seat.ppqL then
          restampPpqL[f] = seat.ppqL
          f.ppqL = seat.ppqL   -- mirror into the clone so the logical projection sees it
        end
        seats[f.ppq] = nil
        table.remove(availAbsorbers, i)
      end
    end

    local moved = {}  -- pb -> newPpq
    for ppq, seat in pairs(seats) do
      local f = table.remove(availAbsorbers)
      if f then
        moved[f] = ppq
        f.ppq, f.cents, f.ppqL, f.shape = ppq, seat.cents, seat.ppqL, seat.shape
        util.add(pbs, f)
      else
        local fresh = { chan = chan, ppq = ppq, cents = seat.cents, ppqL = seat.ppqL,
                        shape = seat.shape, derived = 'absorber', evType = 'pb' }
        util.add(pbs, fresh)
        local writeEvt = util.clone(fresh)
        writeEvt.val = centsToRaw(fresh.cents + detuneAt(lane1ByChan[chan], ppq))
        pbWrites.add(writeEvt)
      end
    end

    for _, f in ipairs(availAbsorbers) do
      pbWrites.del({ token = f.origTok })
      for i, p in ipairs(pbs) do
        if p == f then table.remove(pbs, i); break end
      end
    end

    table.sort(pbs, function(a, b) return a.ppq < b.ppq end)

    -- Consolidated assign: one entry per existing pb where any of (ppq moved, ppqL
    -- restamped, raw changed, cents back-derived, derived shape changed) needs to land.
    for _, pb in ipairs(pbs) do
      if pb.origTok then
        local d         = detuneAt(lane1Events, pb.ppq)
        local wireCents = (not pb.derived and inReplacePb(chan, pb.ppq)) and 0 or pb.cents
        local newRaw    = centsToRaw(wireCents + d)
        local shapeChanged = pb.derived and pb.shape ~= pb.origShape
        local update = nil
        if moved[pb] then
          update = { ppq = pb.ppq, ppqL = pb.ppqL,
                     cents = pb.cents, val = newRaw }
        elseif restampPpqL[pb] then
          update = { ppqL = restampPpqL[pb], cents = pb.cents, val = newRaw }
        elseif pb.val ~= newRaw or persistCents[pb] or shapeChanged then
          update = { cents = pb.cents, val = newRaw }
        end
        if update then
          if pb.derived then update.shape = pb.shape end
          pb.val = newRaw
          pbWrites.assign({ token = pb.origTok }, update)
        end
      end
    end

    -- Column projection. A derived seat is wire-only -- always hidden.
    local anyVisible, pbColEvents = false, {}
    for _, pb in ipairs(pbs) do
      local hidden = pb.derived ~= nil
      anyVisible = anyVisible or not hidden
      util.add(pbColEvents, projectCC(pb, pb.origTok, {
        val    = pb.cents,
        detune = detuneAt(lane1Events, pb.ppq),
        hidden = hidden,
      }))
    end
    local keep = anyVisible or (extras[chan] and extras[chan].pb)
    channels[chan].columns.pb = keep and { events = pbColEvents } or nil
  end

  pbWrites.commit()
end

-- PC synthesis (trackerMode only). Runs after externals so a foreign-MIDI note inherits
-- sample from the prevailing PC.
local function rebuildPCs(fx)
  if not cm:get('trackerMode') then return end
  local pcWrites, dirty = mmBatch(), false
  local sink = {
    del = function(r) pcWrites.del(r); dirty = true end,
    add = function(a) pcWrites.add(a); dirty = true end,
  }
  for chan = 1, 16 do
    local records = {}
    for L, lane in ipairs(channels[chan].columns.notes) do
      for _, n in ipairs(lane.events) do
        util.add(records, { ppq = n.ppq, ppqL = n.ppqL, lane = L, sample = n.sample or 0, key = n })
      end
    end
    for _, w in ipairs(fx.noteLive[chan]) do
      local n = w.evt
      util.add(records, { ppq = n.ppq, ppqL = n.ppqL, lane = w.lane, sample = n.sample or 0, key = n })
    end
    reconcilePCsForChan(chan, records, sink)
  end
  pcWrites.commit()

  if dirty then
    for chan = 1, 16 do channels[chan].columns.pc = { events = {} } end
    for _, cc in mm:ccs() do
      if cc.evType == 'pc' then
        util.add(channels[cc.chan].columns.pc.events, projectCC(cc, mm:tokenOf(cc)))
      end
    end
  end
end

-- Project columns to logical. tv surface is logical-only; ppq/endppq leave here as floats.
-- see docs/trackerManager.md § Rebuild: logical projection
local function projectLogical()
  local res = mm:resolution()
  local function projectToLogical(col, chan)
    for _, evt in ipairs(col.events) do
      if evt.ppqL ~= nil then
        -- delayC: realised-frame delay equivalent. Differs from authored delay when
        -- the unified walk clamped raw against a same-pitch predecessor; renderer cues the give-way.
        if evt.delay ~= nil then
          local baseline = tm:fromLogical(chan, evt.ppqL)
          evt.delayC = util.round(timing.ppqToDelay(evt.ppq - baseline, res))
        end
        evt.ppq = evt.ppqL
      end
      if evt.endppq ~= nil then
        evt.endppqC = tm:toLogical(chan, evt.endppq)
        if evt.endppqL == util.OPEN then
          evt.endppq = util.OPEN
        elseif evt.endppqL ~= nil then
          evt.endppq = evt.endppqL
        else
          evt.endppq = evt.endppqC
        end
      end
    end
    sortByPPQ(col.events)
  end

  for _, chan in ipairs(channels) do
    local c, n = chan.columns, chan.chan
    if c.pc then projectToLogical(c.pc, n) end
    if c.pb then projectToLogical(c.pb, n) end
    for _, col in ipairs(c.notes) do projectToLogical(col, n) end
    if c.at then projectToLogical(c.at, n) end
    for _, col in pairs(c.ccs) do projectToLogical(col, n) end
  end
end

----- Rebuild

local rebuilding = false

--contract: reentrancy-guarded; rebuilds channels[] from mm, reloads um cache, fires 'rebuild'
--contract: takeChanged forwarded to subscribers via the captured pendingTakeSwap
--contract: dead take (mm:take() nil) is a no-op; tv retains its last frame
-- see docs/trackerManager.md § Rebuild
function tm:rebuild(takeChanged)
  if rebuilding then return end
  if not mm:take() then return end
  rebuilding = true
  takeChanged = takeChanged or false

  clearSwing()   -- rebuild is the (cm, mm) coherence point
  channels = {}
  for i = 1, 16 do
    channels[i] = { chan = i, columns = { notes = {}, ccs = {} } }
  end

  -- Per-channel fx realisation state (hostEnd is host-event-keyed, not per-channel).
  -- noteExisting/noteLive: derived vs post-expansion fx notes. ccExisting: carrier/base/fill CC. replacePb: pb windows.
  local fx = { noteExisting = {}, noteLive = {}, ccExisting = {}, replacePb = {}, hostEnd = {} }
  for i = 1, 16 do
    fx.noteExisting[i] = {}
    fx.noteLive[i]     = {}
    fx.ccExisting[i]   = { carrier = {}, base = {}, fill = {} }
    fx.replacePb[i]    = {}
  end
  -- fxNote add/del + parked-member restores, deferred from fx expansion / region parking into the tail
  -- walk's atomic note commit: host clip + these inserts in one mm:modify (one MIDI_Sort, canonical delete-first).
  local deferred = mmBatch()

  local external     = rebuildInternals(fx)     -- partition; lay internal columns; reseat stale-swing notes
  local reapCarriers = rebuildCCs(fx)           -- carrier setup + CC walk; reseat stale-swing CCs
  staleSwing = {}                               -- swing consumers (partition + CC walk) done; see :53 invariant
  rebuildExtraColumns()                         -- reconcile persisted extra columns
  rebuildExternals(external)                    -- reintroduce foreign / diverged notes up front

  rebuildRegionPark(deferred)                   -- region-replace parking: park covered, carry/restore prior set
  rebuildPA()                                   -- project PAs into the settled note columns

  local newFxCarrier = rebuildFx(fx, deferred)  -- fx expansion: derived notes/CCs/carriers; note writes deferred
  reapCarriers(newFxCarrier)                    -- disarm stale carrier codes; persist the live map

  rebuildTails(fx, deferred)                    -- unified tail/onset walk + atomic note commit
  rebuildPbs(fx.noteLive, fx.replacePb)         -- absorber reconciliation + pb resynthesis
  rebuildPCs(fx)                                -- PC synthesis (trackerMode)

  projectLogical()                              -- project columns to logical

  reload()
  rebuilding = false

  --emits: rebuild -- takeChanged:boolean
  --contract: rebuild fires at end of every rebuild after the um cache is reloaded
  --invariant: takeChanged is true only when rebuild followed bindTake; signals take-tier reload
  fire('rebuild', takeChanged)
end

----- Lifecycle

do
  --invariant: tvOnlyKeys skip the configChanged rebuild; defaultSwing is the sole remaining cm key
  local tvOnlyKeys = { defaultSwing = true }

  --invariant: dataChanged 'swing' → global change marks all 16, else only the diffed channels
  --invariant: configChanged 'swings' → channels resolving to names with diff body vs prevSwings
  --invariant: prev*-caches refresh after each event and on bindTake
  -- Merged-tier read: a save at any tier lands in the same merged view, so diff
  -- captures real change to the composite a channel will resolve to.
  local function readSwings() return cm:get('swings', { mergeTiers = true }) end
  local prevSwings = util.deepClone(readSwings())
  local prevSwing  = util.deepClone(ds:get('swing') or {})

  local function snapshotSwingState()
    prevSwings = util.deepClone(readSwings())
    prevSwing  = util.deepClone(ds:get('swing') or {})
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
  mm:subscribe('takeSwapped', function() pendingTakeSwap = true end)
  mm:subscribe('reload', function()
    tm:rebuild(pendingTakeSwap)
    pendingTakeSwap = false
  end)
  -- Skip configChanged while dormant (cm unbound, mm/cm mismatch).
  -- see docs/trackerManager.md § Dormant guard
  cm:subscribe('configChanged', function(change)
    if bindingTake or not cm:boundTake() then return end
    local key = change.key
    if key == 'swings' then
      local curSwings = readSwings()
      for chan in pairs(channelsResolvingTo(changedSwingNames(prevSwings, curSwings))) do
        tm:markSwingStale(chan)
      end
      prevSwings = util.deepClone(curSwings)
    end
    if not tvOnlyKeys[key] then tm:rebuild(false) end
  end)

  -- swing/extraColumns/noteDelay/fxRegions are document data: edits + undo rewinds
  -- arrive as dataChanged. swing diffs its map; the rest force a full rebuild.
  ds:subscribe('dataChanged', function(change)
    if bindingTake or not cm:boundTake() then return end
    if change.name == 'swing' then
      local cur = ds:get('swing') or {}
      if cur.global ~= prevSwing.global then
        tm:markSwingStale(nil)
      else
        for chan in pairs(swingChannelDiff(prevSwing, cur)) do tm:markSwingStale(chan) end
      end
      prevSwing = util.deepClone(cur)
      tm:rebuild(false)
    elseif change.name == 'extraColumns' or change.name == 'noteDelay'
           or change.name == 'fxRegions'
           or change.name == 'fxParked' or change.name == 'fxParkedCC' then
      if not flushingParked then tm:rebuild(false) end
    end
  end)

  --contract: atomic take swap: cm:setContext runs silently; mm:load fires the coherent rebuild
  --contract: opts.trackerMode (wiring-derived) seeds trackerMode under the same suppression window
  --contract: opts.markSwingStale=true rebuilds raw from ppqL under new (cm, mm) (seqMgr:reswingAll)
  --contract: bindTake(nil) is the dormant seam (e.g. samplePage)
  --invariant: bindTake(nil): cm clears under suppression; mm:load(nil) no-op; tm/tv keep last frame
  function tm:bindTake(take, opts)
    bindingTake = true
    cm:setContext(take)
    if take then cm:set('transient', 'trackerMode', (opts and opts.trackerMode) or false) end
    bindingTake = false
    if opts and opts.markSwingStale then
      for i = 1, 16 do staleSwing[i] = true end
    end
    mm:load(take)
    snapshotSwingState()
  end

  --contract: take died under us — nils mm.take so tm:currentTake reads nil; not bindTake(nil) seam
  function tm:detach()
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

tm:rebuild(true)
return tm
