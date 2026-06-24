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
--shape: paEventCol = { type='pa', ppq, pitch, vel, loc, ... }
--invariant: paEventCol mixes into note column events
--shape: extraColumns[chan] = { notes=count, [pc], [pb], [at], [ccs={[ccNum]=true}] }
--shape: lastMuteSet = { [chan] = true }, pushed by tv via tm:setMutedChannels

local util    = require 'util'
local timing  = require 'timing'
local tuning  = require 'tuning'
local generators = require 'generators'

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
-- ppq tolerance for "raw agrees with its logical projection"; absorbs
-- fromLogical rounding slop. Shared by the tail pass (stale-frame
-- detection) and the rebuild rule (onset disagreement).
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

-- Toy fixed carrier for continuous (vibrato) deltas; msb cc, lsb cc+32.
-- Proper per-channel banded alloc: design/note-macros.md § Delta-code allocation.
local DELTA_MSB = 20

local function delayToPPQ(d) return timing.delayToPPQ(d, mm:resolution()) end

local function forEachEvent(fn)
  for i=1,16 do
    local channel = channels[i]
    if channel then
      local chan, cols = channel.chan, channel.columns
      -- Note branch carries lane (column events strip it; see util.clone at row clone).
      for lane, col in ipairs(cols.notes) do
        for _, evt in ipairs(col.events) do
          local isNote = evt.type ~= 'pa'
          fn(isNote and 'note' or 'pa', evt, chan, isNote, nil, lane)
        end
      end
      for _, t in ipairs{'pb', 'at', 'pc'} do
        if cols[t] then
          for _, evt in ipairs(cols[t].events) do fn(t, evt, chan, false) end
        end
      end
      -- cc branch carries ccNum: column events have cc stripped (see CC_PROJECT_STRIP), so callers needing the cc number get it from the column key.
      for ccNum, col in pairs(cols.ccs) do
        for _, evt in ipairs(col.events) do fn('cc', evt, chan, false, ccNum) end
      end
    end
  end
end


--contract: synthesised PCs carry derived='pc'; ppqL inherited from winning host-note record
--contract: an existing derived PC matching (ppq, val) is kept, preserving mm-side loc
--contract: returns (toRemove, toAdd) for the caller to persist
--contract: if record.key set, marks key.sampleShadowed=true on records lost to lane priority
--invariant: shadow marking is rebuild-only; flush callers omit key (rebuild reclones lane events)
--invariant: c.pc.events not written here; rebuild's CC walk refreshes it from mm after commit
local function reconcilePCsForChan(chan, records)
  local existing = (channels[chan].columns.pc and channels[chan].columns.pc.events) or {}

  local byPpq  = {}
  local groups = {}
  for _, e in ipairs(existing) do byPpq[e.ppq] = e end
  for _, r in ipairs(records) do util.bucket(groups, r.ppq, r) end

  local toRemove, toAdd, kept = {}, {}, {}
  for ppq, g in pairs(groups) do
    table.sort(g, function(a, b) return a.lane < b.lane end)
    local w = g[1]
    local have = byPpq[ppq]
    if have and have.derived and have.val == w.sample then
      kept[have] = true
    else
      util.add(toAdd, { ppq = ppq, ppqL = w.ppqL, val = w.sample,
                        evType = 'pc', chan = chan, derived = 'pc' })
    end
    for i = 2, #g do
      if g[i].key then g[i].key.sampleShadowed = true end
    end
  end
  for _, have in ipairs(existing) do
    if not kept[have] then util.add(toRemove, have) end
  end
  return toRemove, toAdd
end

----- fxNote reconciliation (the PC-synthesis skeleton, note-shaped)

-- Identity is geometry: (host, ppq, pitch, vel, detune, sample). endppq is
-- owned by the tail walk, never matched. Twin of reconcilePCsForChan.
-- Predicted ppq is a Lua integer; REAPER's MIDI_GetNote returns a float, and
-- util.key stringifies -- canonicalise or 3072 vs 3072.0 churns every fxNote each rebuild.
local function canon(x)
  if type(x) == 'number' then return math.tointeger(x) or x end
  return x
end
local function fxKey(spec)
  return util.key(canon(spec.derived), canon(spec.ppq), canon(spec.pitch),
                  canon(spec.vel), canon(spec.detune or 0), canon(spec.sample or 0))
end

local function reconcileFx(predicted, existing)
  local have, kept = {}, {}
  for _, e in ipairs(existing) do have[fxKey(e)] = e end
  local toRemove, toAdd = {}, {}
  for _, spec in ipairs(predicted) do
    local e = have[fxKey(spec)]
    if e then kept[e] = true else
      util.add(toAdd, spec)
    end
  end
  for _, e in ipairs(existing) do
    if not kept[e] then util.add(toRemove, e) end
  end
  return toRemove, toAdd
end

----- delta-stream (carrier) reconciliation
-- Pure fn of lane-1 hosts; match by ppq, rewrite drifted val/shape, drop unpredicted.
local function reconcileCarrier(existing, predicted)
  local byPpq = {}
  for _, e in ipairs(existing) do byPpq[e.ppq] = e end
  local toRemove, toAdd, kept = {}, {}, {}
  for _, spec in ipairs(predicted) do
    local have = byPpq[spec.ppq]
    if have and have.val == spec.val and have.shape == spec.shape then
      kept[have] = true
    else
      util.add(toAdd, spec)
    end
  end
  for _, e in ipairs(existing) do
    if not kept[e] then util.add(toRemove, e) end
  end
  return toRemove, toAdd
end

---------- UPDATE MANAGER

local addEvent, assignEvent, deleteEvent, flush, reload do

  ----- State

  local adds = {}
  local assigns = {}
  local deletes = {}
  local chans = {}
  local byToken = {}
  local byUuid  = {}
  local dirtyPcChans = {}

  ----- Accessors

  -- Prevailing lane-1 detune at-or-before ppq. Used by flush to derive
  -- a pb's wire-raw from its authored cents (raw = cents + detune at
  -- seat). The full absorber reconciliation lives in tm:rebuild step
  -- 4.9; um just stages.
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
    local oldChan = evt.chan
    util.assign(evt, update)
    -- Keep the per-chan index coherent. chan change migrates the entry;
    -- ppq change resorts (util.seek callers depend on ascending ppq;
    -- rebuild's stale-swing pass updates events in original-order, not
    -- new-raw-order, so a resort is needed after).
    local function listOf(c)
      if evt.evType == 'note' and evt.lane == 1 then return chans[c].notes end
      if evt.evType == 'pb' then return chans[c].pbs end
    end
    if update.chan and update.chan ~= oldChan then
      local old = listOf(oldChan)
      if old then
        for i, item in ipairs(old) do if item == evt then table.remove(old, i); break end end
      end
      local new = listOf(evt.chan)
      if new then util.add(new, evt); sortByPPQ(new) end
    elseif update.ppq ~= nil then
      local list = listOf(evt.chan)
      if list then sortByPPQ(list) end
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

  -- um is a stager. Pb authoring writes cents (the logical authored
  -- value); the wire raw is derived at flush (cents + detune at seat).
  -- All absorber seating, removal, and reseating happens in tm:rebuild
  -- step 4.9 from the final note layout — so a clamp or delay change
  -- that moves a lane-1 onset takes its absorber along automatically.

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

  --contract: lane updates rejected with a warning (column membership is rebuild-owned)
  --contract: chan changes accepted; rebuild's absorber pass reconciles fakes across both channels
  --contract: ppq/endppq route through resizeNote
  local function assignNote(n, update)
    if update.lane then print('um: not allowed to change lane of notes'); return end

    -- update.ppq covers both direct ppq edits and delay edits
    -- (realiseNoteUpdate maps delay→ppq before we get here). endppq
    -- alone doesn't move the realised onset, so it doesn't dirty.
    if update.sample ~= nil or update.ppq ~= nil then dirtyPc(n.chan) end
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

    local toRemove, toAdd = reconcilePCsForChan(chan, records)
    for _, have in ipairs(toRemove) do deleteLowlevel(have) end
    for _, want in ipairs(toAdd)    do addLowlevel(want)    end
  end

  local function lookup(evtOrToken)
    local token = type(evtOrToken) == 'table' and evtOrToken.token or evtOrToken
    if not token then return end
    return byToken[token], token
  end

  ----- Public interface

  -- The live column event for a uuid, valid until the next rebuild.
  -- uuid is mm's durable identity; token is internal and re-keyed, so
  -- cross-rebuild handles (gm) resolve through this, never the token.
  function tm:byUuid(uuid) return byUuid[uuid] end

  function deleteEvent(evtOrToken)
    local evt = lookup(evtOrToken)
    if not evt then return end
    if evt.evType == 'note' then deleteNote(evt)
    else                        deleteLowlevel(evt) end
  end

  -- endppq arrives logical and is the authored ceiling. util.OPEN stamps
  -- an open ceiling + a provisional raw note-off (the tail pass derives
  -- the real one); a finite value stamps the logical ceiling and derives
  -- raw. rec.ppq must already be raw (the OPEN branch uses rec.ppq + 1).
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
    local dOld = delayToPPQ(evt.delay)
    local dNew = delayToPPQ(update.delay ~= nil and update.delay or evt.delay)
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
    -- Authored delay / endppq are intent; raw is realisation. A delay
    -- that pushes raw onset below 0 (or past a same-pitch predecessor
    -- — step 4.8 handles that) floors at 0; a tail past the take edge
    -- clips at takeLen. Step 4.8 and flush both re-apply these against
    -- the post-walk geometry; clamping here keeps the staged raw value
    -- bounded the moment it lands in mm, so interim readers don't see
    -- out-of-range raw. Divergence surfaces as delay ~= delayC and
    -- endppq ~= endppqC; tp paints a * next to the delay digits, and
    -- the realised tail is what the renderer draws (endppqC, not
    -- endppq), so no separate endppq cue is needed.
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
  --contract: um only stages; rebuild step 4.9 reconciles seats and recomputes raw vals at flush
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

  ----- Flush: commit accumulated ops to mm.

  --contract: no-op if nothing staged
  --contract: commits assigns, then deletes, then adds under one mm:modify
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
    if #adds == 0 and #assigns == 0 and #deletes == 0 then return end

    -- Same-(chan,pitch) MIDI legality enforced once here as a SINGLE
    -- scan over every note that will exist post-flush — committed
    -- (byToken, all lanes) and staged adds alike. Not a per-self peer
    -- walk: two notes can collide without either being the edited one,
    -- and repeated per-self truncation damages peers a later same-flush
    -- op would resolve. Run after preflush (propagated peers staged)
    -- and before the snapshot (clamps/deletes ride this flush). This is
    -- only the staging pre-clip so PA/detune resize routing sees
    -- coherent geometry inside this mm:modify; the authoritative raw
    -- tail is re-derived by the rebuild tail pass that follows. raw
    -- endppq is realisation; endppqL is intent and is never written
    -- here — deleting a blocker regrows the raw tail up to it.
    do
      local takeLen = tm:length()
      local byKey   = {}
      for _, n in pairs(byToken) do
        if n.evType == 'note' then util.bucket(byKey, util.key(n.chan, n.pitch), n) end
      end
      for _, o in ipairs(adds) do
        if o.evt.evType == 'note' then util.bucket(byKey, util.key(o.evt.chan, o.evt.pitch), o.evt) end
      end

      local clips, kills = {}, {}
      -- Coincident-onset dedup: authored intent beats a regenerable fxNote;
      -- else keep the longest ceiling (fresh OPEN raw = 1-tick, would lose).
      local function supersedes(a, b)
        local aDerived, bDerived = a.derived ~= nil, b.derived ~= nil
        if aDerived ~= bDerived then return bDerived end
        return (a.endppqL or a.endppq) > (b.endppqL or b.endppq)
      end
      for _, group in pairs(byKey) do
        local longestAt = {}
        for _, n in ipairs(group) do
          local kept = longestAt[n.ppq]
          if not kept then
            longestAt[n.ppq] = n
          elseif supersedes(n, kept) then
            longestAt[n.ppq] = n; util.add(kills, kept)
          else
            util.add(kills, n)
          end
        end

        local voiced = {}
        for _, n in pairs(longestAt) do util.add(voiced, n) end
        table.sort(voiced, function(a, b) return a.ppq < b.ppq end)

        for i = 1, #voiced do
          local n      = voiced[i]
          local nextOn = voiced[i + 1] and voiced[i + 1].ppq or math.huge
          local bound  = math.max(n.ppq + 1, math.min(n.endppq, nextOn, takeLen))
          if bound < n.endppq then
            util.add(clips, { n = n, endppq = bound })
          end
        end
      end

      for _, n in ipairs(kills) do deleteNote(n) end
      for _, c in ipairs(clips) do
        local up = { endppq = c.endppq }
        if c.endppqL ~= nil then up.endppqL = c.endppqL end
        if c.n.token then assignNote(c.n, up)   -- committed: route PA/detune resize
        else              util.assign(c.n, up)  -- staged add: geometry only
        end
      end
    end

    local flushAdds, flushAssigns, flushDeletes = adds, assigns, deletes
    adds, assigns, deletes = {}, {}, {}

    -- pb wire conversion: um stores authored cents in pb.cents; mm wire
    -- carries raw 14-bit. Compute raw = cents + prevailing lane-1 detune
    -- at seat, clamped via centsToRaw. The rebuild absorber pass refines
    -- this (and seats/removes fakes) using the post-walk note layout;
    -- this is the best-effort wire value for the interim.
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

    mm:modify(function()
      for _, o in ipairs(flushAssigns) do
        local newTok = mm:assign(o.token, o.update)
        if newTok and newTok ~= o.token then
          byToken[o.token] = nil
          byToken[newTok]  = o.evt
          o.evt.token      = newTok
        end
      end
      for _, o in ipairs(flushDeletes) do
        mm:delete(o.token)
        byToken[o.token] = nil
      end
      for _, o in ipairs(flushAdds) do
        local tok = mm:add(o.evt)
        if tok then
          byToken[tok] = o.evt
          o.evt.token  = tok
        end
      end
    end)
    fire('postflush')
  end

  ----- Init / reload: (re)load local cache from mm.

  -- Also clears staging buffers: a rebuild must not carry un-flushed ops
  -- across (their tokens may be stale for newly-added events), matching the
  -- prior "fresh um per rebuild" semantics now that the um itself persists.
  function reload()
    adds, assigns, deletes = {}, {}, {}
    dirtyPcChans           = {}
    byToken                = {}
    byUuid                 = {}
    for i = 1, 16 do chans[i] = { notes = {}, pbs = {} } end

    for tok, e in mm:events() do
      local evt
      if e.evType == 'pb' then
        -- val is the wire raw cents (raw 14-bit → cents for um's frame).
        -- cents (sidecar) is the authored logical value; nil for foreign-
        -- MIDI or pre-cents pbs -- back-derived in rebuild step 4.9
        -- once the final lane-1 layout is settled.
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
function tm:interpolate(A, B, ppq) return mm and mm:interpolate(A, B, ppq) end

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

-- Stretch the take to `newPpq` by linearly remapping the logical
-- frame: each event on logical row r ends up on row f·r where
-- f = newPpq/oldPpq. ppqL stamps scale by f; raw ppqs are
-- rederived through swing — so under non-identity swing raw
-- ppqs are not linearly scaled (rows are preserved instead, which
-- keeps reswing well-defined). Note delays scale by f. Frame stamps
-- (rpb, swing slot names) are untouched. No events are deleted.
function tm:rescaleLength(newPpq)
  if not mm then return end
  local oldPpq = mm:length() or 0
  if oldPpq <= 0 or newPpq == oldPpq then
    if newPpq ~= oldPpq then mm:setLength(newPpq / mm:resolution()) end
    return
  end
  local f = newPpq / oldPpq

  -- τ acts on logical positions; raw ppqs rederive through the current swing snapshot.
  -- Events without ppqL fall back to τ on raw ppq (identical under identity swing).
  -- slopeAt scales note delays so realised stretch tracks logical stretch locally.
  -- Two passes (gather, then mutate) so all reads are stable.
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

-- Loop the existing pattern to fill `newPpq`. The events in [0, oldPpq)
-- are replicated at offsets k·oldPpq for k = 1 .. ceil(newPpq/oldPpq)-1.
-- Copies whose shifted ppq lands at-or-past newPpq are dropped; note
-- endppqs that extend past newPpq are clamped. Originals are untouched.
-- Shrinks fall through to setLength.
--
-- Walks mm-level events directly rather than column-projected ones:
-- the projection strips fields a verbatim replica needs (cc number,
-- pb fake flag, custom user metadata). For pbs this means the copied
-- stream recreates the source's pitch trajectory exactly — including
-- whatever carry it inherits from the end of the prior tile.
--
-- Because oldPpq sits on a swing-period boundary (take length aligns
-- to QN), shifting by k·oldPpq is identical in logical and realised
-- frames; one delta serves both ppq and ppqL paths.
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

----- Rebuild

do
  ----- Column allocation

  local function pushNoteCol(channel)
    local notes = channel.columns.notes
    return util.add(notes, { events = {} }), #notes
  end

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

  --contract: stamped notes (ppqL ~= nil) take their authored lane verbatim
  --invariant: step 4.8 raw walk clips tails so they can't overlap; lane extends if missing
  local function pickStampedLane(channel, note)
    local notes = channel.columns.notes
    while #notes < note.lane do pushNoteCol(channel) end
    return notes[note.lane], note.lane
  end

  --contract: pick a lane for an external (unstamped) note via accept → sibling → push bump
  --invariant: called by step 6 AFTER internals' raw tails settle, so accept sees realised state
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

  local function findNoteColumnForPitch(channel, pitch, ppq_pos)
    local notes = channel.columns.notes
    for _, col in ipairs(notes) do
      for _, evt in ipairs(col.events) do
        if evt.endppq and evt.pitch == pitch and evt.ppq <= ppq_pos and evt.endppq > ppq_pos then
          return col
        end
      end
    end
    for _, col in ipairs(notes) do
      for _, evt in ipairs(col.events) do
        if evt.pitch == pitch then return col end
      end
    end
  end

  ----- CC projection

  local CC_PROJECT_STRIP = { chan = true, cc = true }

  local function projectCC(cc, token, overlay)
    local evt = util.clone(cc, CC_PROJECT_STRIP)
    evt.token = token
    if overlay then util.assign(evt, overlay) end
    return evt
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

    local function applyAssigns(list)
      if #list == 0 then return end
      mm:modify(function()
        for _, a in ipairs(list) do
          local newTok = mm:assign(a.evt.token, a.update)
          if newTok and newTok ~= a.evt.token then a.evt.token = newTok end
        end
      end)
    end

    clearSwing()   -- rebuild is the (cm, mm) coherence point
    channels = {}
    for i = 1, 16 do
      channels[i] = { chan = i, columns = { notes = {}, ccs = {} } }
    end

    -- fxExisting: derived notes parsed at step 0, reconciled at 4.6.
    -- fxLive: post-expansion set unioned into the tail walk and PC synthesis.
    local fxExisting, fxLive, carrierExisting = {}, {}, {}
    for i = 1, 16 do fxExisting[i] = {}; fxLive[i] = {}; carrierExisting[i] = {} end
    -- host event -> pre-fx realised tail, stashed at 4.6, restored onto the
    -- column event after the 4.8 tail walk so the view sees the authored note.
    local fxHostEnd = {}

    -- 0) Partition mm events into internal (stamped + raw consistent
    -- with ppqL: model-governed) and external (foreign-MIDI, or
    -- external raw edit on a stamped record). Internals are fully-
    -- schema'd by construction; the main rebuild flows them branchlessly.
    -- Externals re-enter at step 6: notes get a fresh lane pack and
    -- ppqL/endppqL stamp; CCs get ppqL stamped in line here (no lane,
    -- no tail, single-field recache).
    --
    -- A stamped note whose raw disagrees with fromLogical(ppqL, delay)
    -- under non-staleSwing has been externally edited (Ctrl-Z, foreign
    -- script): raw is truth, the cached ppqL/endppqL are stale. Route
    -- to external so step 6 re-stamps from raw.
    --
    -- Exception: realiseNoteUpdate floors raw at 0 when authored delay
    -- pushes the realised onset negative. ppqL/delay are still the
    -- intent; the divergence is intentional and surfaces as delayC
    -- (which tp paints with a * next to the delay digits). Recognise
    -- the clamp shape (raw == 0, fromLogical < 0) and stay internal.
    local function rawDivergesFromLogical(evt)
      if evt.ppqL == nil      then return true  end
      if staleSwing[evt.chan] then return false end
      local d = evt.evType == 'note' and delayToPPQ(evt.delay or 0) or 0
      local rawFromLogical = tm:fromLogical(evt.chan, evt.ppqL, d)
      if evt.ppq == 0 and rawFromLogical < 0 then return false end
      return math.abs(evt.ppq - rawFromLogical) > EPS
    end

    local internal, external = {}, {}
    for _, note in mm:notes() do
      if note.derived then
        note.token = mm:tokenOf(note)
        util.add(fxExisting[note.chan], note)
      elseif rawDivergesFromLogical(note) then util.add(external, note)
      else util.add(internal, note)
      end
    end
    -- Register the fixed continuous carrier (cc = DELTA_MSB) as 14-bit so the
    -- CC walk coalesces its pair and routes it out. see design/note-macros.md § Continuous realisation
    for _, list in ipairs({ internal, external }) do
      for _, note in ipairs(list) do
        for _, params in ipairs(note.fx or {}) do
          if generators.continuous[params.kind] then mm:wideCC(note.chan, DELTA_MSB, true) end
        end
      end
    end
    -- 2) Allocate note columns for internals (stamped path). Clone rather
    -- than alias: step 5 overwrites column evt.ppq with logical while mm
    -- retains raw.
    for _, note in ipairs(internal) do
      local channel = channels[note.chan]
      local col, lane = pickStampedLane(channel, note)
      local ce = util.clone(note, { chan = true, lane = true })
      ce.token = mm:tokenOf(note)
      util.add(col.events, ce)
    end

    -- 3) Single CC walk. Reconciles each non-fake CC's (raw, ppqL) under
    -- the current swing, then projects non-pb CCs into columns:
    --   - staleSwing[chan]: ppqL is truth, reseat raw = fromLogical(ppqL).
    --   - else, raw diverges from ppqL: external edit on raw; restamp
    --     ppqL = toLogical(raw).
    -- Reconcile updates are mutated into the live cc record so the
    -- subsequent column-event clone sees up-to-date values; mm:assign
    -- propagates them at the end of the walk. Fakes are parasitic: fake
    -- pbs are reconciled by step 4.9 (whole absorber pass against the
    -- post-walk lane-1 layout); fake PCs reconciled fresh by step 4.5.
    -- Pb column projection is deferred to step 4.9 so it sees the final
    -- reconciled fakes and the recomputed raw vals.
    do
      local ccUpdates = {}
      for _, cc in mm:ccs() do
        if cc.evType == 'cc' and cc.cc == DELTA_MSB then
          -- Carrier: generator-owned, no metadata; routed out by address,
          -- reconciled stream-level at 4.6. see design/note-macros.md § Continuous realisation
          util.add(carrierExisting[cc.chan],
            { ppq = cc.ppq, val = cc.val, shape = cc.shape, token = mm:tokenOf(cc) })
          goto continue
        end
        if not cc.derived then
          if staleSwing[cc.chan] and cc.ppqL ~= nil then
            local newPpq = tm:fromLogical(cc.chan, cc.ppqL)
            if newPpq ~= cc.ppq then
              util.add(ccUpdates, { tok = mm:tokenOf(cc), update = { ppq = newPpq } })
              cc.ppq = newPpq
            end
          elseif rawDivergesFromLogical(cc) then
            local newPpqL = tm:toLogical(cc.chan, cc.ppq)
            util.add(ccUpdates, { tok = mm:tokenOf(cc), update = { ppqL = newPpqL } })
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

      if #ccUpdates > 0 then
        mm:modify(function()
          for _, u in ipairs(ccUpdates) do mm:assign(u.tok, u.update) end
        end)
      end
    end

    -- 4) Reconcile extras.
    do
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

    -- 4.7) Two-frame rebuild rule. See docs/timing.md §"Rebuild rule".
    -- staleSwing reseat on notes only: rederive raw from ppqL under the
    -- channel's new swing. Non-fake CCs are reconciled by step 3; fakes
    -- (pb absorbers, synthesised PCs) are reconciled by step 4.9 and
    -- step 4.5 respectively against the post-walk layout. raw endppq is
    -- owned by step 4.8's tail-realisation pass, never reseated from
    -- endppqL here.
    do
      local toAssign = {}
      forEachEvent(function(_, evt, chan, isNote, _, lane)
        if not isNote or evt.derived then return end
        if staleSwing[chan] then
          local newPpq = tm:fromLogical(chan, evt.ppqL, delayToPPQ(evt.delay or 0))
          if newPpq ~= evt.ppq then
            evt.ppq = newPpq
            util.add(toAssign, { evt = evt, update = { ppq = newPpq } })
          end
        end
      end)
      applyAssigns(toAssign)
      staleSwing = {}
    end

    -- 4.6) Macro expansion: expand fx-carrying notes on every lane, reconcile
    -- against fxExisting, commit. fxLive feeds the tail walk + PC synthesis. see design/note-macros.md § Pipeline placement
    do
      local res = mm:resolution()
      local takeLen = tm:length()
      local churned = false
      for chan = 1, 16 do
        -- Window ends at the first same-pitch or same-lane onset after the host
        -- (monophonic column; see design/note-macros.md § host contract).
        local foreignOnsets, laneOnsets = {}, {}
        local function addOnset(n, lane)
          if n.derived or n.type == 'pa' then return end
          util.bucket(foreignOnsets, n.pitch, n.ppq)
          if lane then util.bucket(laneOnsets, lane, n.ppq) end
        end
        for laneIdx, col in ipairs(channels[chan].columns.notes) do
          for _, n in ipairs(col.events) do addOnset(n, laneIdx) end
        end
        for _, n in ipairs(external) do if n.chan == chan then addOnset(n) end end
        for _, list in pairs(foreignOnsets) do table.sort(list) end
        for _, list in pairs(laneOnsets)    do table.sort(list) end

        local function firstAfter(list, ppq)
          for _, p in ipairs(list or {}) do if p > ppq then return p end end
        end

        local predicted = {}
        local predictedDelta, lastDeltaPpq = {}, nil
        for laneIdx, col in ipairs(channels[chan].columns.notes) do
          for _, host in ipairs(col.events) do
            if host.fx and host.type ~= 'pa' then
              local endL = (host.endppqL == nil or host.endppqL == util.OPEN)
                           and tm:toLogical(chan, takeLen) or host.endppqL
              local bound = math.min(firstAfter(foreignOnsets[host.pitch], host.ppq) or math.huge,
                                     firstAfter(laneOnsets[laneIdx],       host.ppq) or math.huge)
              if bound ~= math.huge then endL = math.min(endL, tm:toLogical(chan, bound)) end
              fxHostEnd[host] = tm:fromLogical(chan, endL)
              local d = delayToPPQ(host.delay or 0)
              for _, params in ipairs(host.fx) do
                local gen = generators[params.kind]
                if gen then
                  local out = gen({ window = { host.ppqL, endL }, events = { host },
                                    id = host.uuid, chan = chan }, params, { resolution = res })
                  for _, fn in ipairs(out.notes) do
                    util.add(predicted, {
                      evType = 'note', chan = chan, lane = laneIdx, derived = host.uuid,
                      pitch = fn.pitch, vel = fn.vel, detune = fn.detune or 0,
                      delay = host.delay or 0, sample = host.sample,
                      ppqL = fn.ppqL, endppqL = fn.endppqL,
                      ppq    = tm:fromLogical(chan, fn.ppqL,    d),
                      endppq = tm:fromLogical(chan, fn.endppqL, d),
                    })
                  end
                  -- Continuous deltas -> carrier ccs: cents -> 14-bit pb units
                  -- (signed ~8192), fixed-point for wideCC. Lane-1 only (pb channel-wide).
                  if laneIdx == 1 then
                    for _, bp in ipairs(out.delta) do
                      local ppq = tm:fromLogical(chan, bp.ppqL, d)
                      if ppq ~= lastDeltaPpq then
                        lastDeltaPpq = ppq
                        util.add(predictedDelta, {
                          evType = 'cc', chan = chan, cc = DELTA_MSB, ppq = ppq,
                          val = (8192 + centsToRaw(bp.val)) / 128, shape = bp.shape,
                        })
                      end
                    end
                  end
                end
              end
            end
          end
        end

        local toRemove, toAdd = reconcileFx(predicted, fxExisting[chan])
        if #toRemove > 0 or #toAdd > 0 then
          churned = true
          mm:modify(function()
            for _, e    in ipairs(toRemove) do mm:delete(e.token) end
            for _, spec in ipairs(toAdd)    do mm:add(spec)       end
          end)
        end

        -- Anchor carrier to 0 at take start; CC chase re-establishes centre
        -- on any loop/seek before the first host. see design/note-macros.md § Continuous realisation
        if #predictedDelta > 0 and predictedDelta[1].ppq ~= 0 then
          util.add(predictedDelta, { evType = 'cc', chan = chan, cc = DELTA_MSB,
                                     ppq = 0, val = (8192 + centsToRaw(0)) / 128, shape = 'slow' })
        end

        local cRemove, cAdd = reconcileCarrier(carrierExisting[chan], predictedDelta)
        if #cRemove > 0 or #cAdd > 0 then
          mm:modify(function()
            for _, e in ipairs(cRemove) do mm:delete(e.token) end
            for _, s in ipairs(cAdd)    do mm:add(s)          end
          end)
        end
      end

      -- fxLive (tail walk + PC consume it) clones its evts because the walk
      -- mutates them; on a no-churn rebuild fxExisting already lists the derived
      -- set with current tokens, so skip the mm:notes() re-scan. see docs/trackerManager.md § Rebuild
      local fxSource = {}
      if churned then
        for _, n in mm:notes() do if n.derived then util.add(fxSource, n) end end
      else
        for chan = 1, 16 do
          for _, n in ipairs(fxExisting[chan]) do util.add(fxSource, n) end
        end
      end
      for _, n in ipairs(fxSource) do
        local ce = util.clone(n)
        ce.token = n.token
        util.add(fxLive[n.chan], { evt = ce, lane = n.lane or 1 })
      end
    end

    -- 6) Reintroduce externals. Per external (raw-ppq order): pack a
    -- lane against the now-settled internals plus any earlier externals
    -- already placed (noteColumnAccepts sees realised tails); stamp
    -- ppqL/endppqL from raw, backfill any missing metadata (foreign-
    -- MIDI lacks all; stale-stamped notes come in with authored detune/
    -- delay intact -- preserved here). The column event is inserted
    -- in lockstep so the next external's pack sees this one, and tagged
    -- evt.external = true so step 4.8 treats it as a blocker (its onset
    -- shows up as 'next' for internals) but never writes to its tail or
    -- clamps its onset.
    if #external > 0 then
      table.sort(external, function(a, b) return a.ppq < b.ppq end)
      local trackerMode = cm:get('trackerMode')
      local inserts = {}
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
        local ce = util.clone(note, { chan = true, lane = true })
        util.assign(ce, update)
        ce.external = true
        util.add(col.events, ce)
        util.add(inserts, { note = note, ce = ce, update = update })
      end
      mm:modify(function()
        for _, ins in ipairs(inserts) do
          local newTok = mm:assign(mm:tokenOf(ins.note), ins.update)
          ins.ce.token = newTok or mm:tokenOf(ins.note)
        end
      end)
    end

    -- 4.8) Unified tail/onset walk on internals. Externals (tagged
    -- evt.external by step 6) participate as BLOCKERS only -- their
    -- onsets show up as "next" lookups so internals' tails clip against
    -- them -- but the walk never writes to them.
    --
    --   tail target = max(onset+1, min(
    --     authored ceiling = fromLogical(endppqL); math.huge for util.OPEN,
    --     same-lane next intent = fromLogical(nextSameLane.ppqL) + overlap,
    --     same-pitch next raw   = nextSamePitch.ppq,
    --     take length))
    --
    -- Same-lane uses INTENT (logical) so authored music geometry wins
    -- over realisation delays. Same-pitch uses RAW because MIDI physics
    -- is realised. "Next" is strict-greater on raw ppq -- a chord-mate
    -- at the same onset is not "following".
    --
    -- Collision (current raw <= prev same-pitch raw, raw order with ppqL
    -- tie-break) clamps the successor to prev+1. Authored swap survives:
    -- when raw order differs from logical order, whoever lands first in
    -- raw becomes the realised predecessor.
    do
      local takeLen = tm:length()
      local clamps, clips = {}, {}
      for chan = 1, 16 do
        local notes, byLane, byPitch = {}, {}, {}
        for laneIdx, col in ipairs(channels[chan].columns.notes) do
          for _, evt in ipairs(col.events) do
            if evt.type ~= 'pa' and evt.ppqL ~= nil then
              local n = { evt = evt, lane = laneIdx }
              util.add(notes, n)
              util.bucket(byLane,  laneIdx,   n)
              util.bucket(byPitch, evt.pitch, n)
            end
          end
        end
        for _, w in ipairs(fxLive[chan]) do
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

        -- Same-pitch onset clamp. Retro-clip of the predecessor's tail
        -- is subsumed by the tail pass below (the clamped successor's
        -- onset shows up as same-pitch next).
        local lastByPitch = {}
        for _, n in ipairs(notes) do
          local e, prev = n.evt, lastByPitch[n.evt.pitch]
          if prev and not n.evt.external and e.ppq <= prev.evt.ppq then
            local floor = prev.evt.ppq + 1
            util.add(clamps, { evt = e, update = { ppq = floor } })
            e.ppq = floor
          end
          lastByPitch[e.pitch] = n
        end
        sortAll()

        -- Strict-next per note: first group member with a greater ppq,
        -- chord-mates skipped. Precomputed O(n); see docs/trackerManager.md § Rebuild.
        local function strictNextMap(groups)
          local nextOf = {}
          for _, g in pairs(groups) do
            for i = #g - 1, 1, -1 do
              nextOf[g[i]] = g[i + 1].evt.ppq > g[i].evt.ppq
                             and g[i + 1] or nextOf[g[i + 1]]
            end
          end
          return nextOf
        end
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
            util.add(clips, { evt = e, update = { endppq = rounded } })
            e.endppq = rounded
          end
        end
        ::nextChan::
      end
      -- Clamps first: reindex separates colliding tokens before clip
      -- assigns dereference them (same-pitch notes can share a content-
      -- keyed token until ppq differs).
      applyAssigns(clamps)
      applyAssigns(clips)

      -- Restore pre-fx tail onto column events so the view sees the authored
      -- note; mm is untouched, so the take and G4 round-trip are unaffected.
      for host, rawEnd in pairs(fxHostEnd) do host.endppq = rawEnd end
    end

    -- 4.9) Absorber reconciliation + pb wire/column resynthesis.
    -- see docs/tuning.md § Absorber reconciliation
    do
      local extras = ds:get('extraColumns') or {}

      local function detuneAt(events, P)
        local n = util.seek(events, 'at-or-before', P)
        return (n and n.detune) or 0
      end

      -- Per-chan lane-1 sort, used both at reconcile and inside mm:modify.
      local lane1ByChan = {}
      for chan = 1, 16 do
        local lane1 = channels[chan].columns.notes[1]
        local list  = {}
        if lane1 then
          for _, n in ipairs(lane1.events) do
            if n.type ~= 'pa' then util.add(list, n) end
          end
          table.sort(list, function(a, b) return a.ppq < b.ppq end)
        end
        lane1ByChan[chan] = list
      end

      -- mm uses content-keyed tokens, so any pb whose ppq we touch
      -- needs its pre-mutation token captured up front. Each pb here
      -- is a mm:ccs() clone with origTok set once.
      local pbsByChan = {}
      for _, cc in mm:ccs() do
        if cc.evType == 'pb' then
          cc.origTok = mm:tokenOf(cc)
          util.bucket(pbsByChan, cc.chan, cc)
        end
      end

      local pbAdds, pbAssigns, pbDeletes = {}, {}, {}

      for chan = 1, 16 do
        local lane1Events = lane1ByChan[chan]
        local pbs         = pbsByChan[chan] or {}
        table.sort(pbs, function(a, b) return a.ppq < b.ppq end)

        -- Needed seats: every lane-1 onset where detune ≠ predecessor.
        -- hostPpqL captures the lane-1 ppqL at each needed seat so a
        -- fake placed (or moved) there carries its host's logical
        -- position into the pb column (step 5's logical projection
        -- and the tv-facing pb display rely on ppqL, not raw).
        local needed, hostPpqL = {}, {}
        local prev = 0
        for _, n in ipairs(lane1Events) do
          local d = n.detune or 0
          if d ~= prev then
            needed[n.ppq] = true
            hostPpqL[n.ppq] = n.ppqL
          end
          prev = d
        end

        -- Anchor a pb-active channel at its first lane-1 onset (I2a):
        -- without it, playback inherits the synth's unknown prior bend.
        local first = lane1Events[1]
        if first and not needed[first.ppq] then
          local hasReal, anchored = false, false
          for _, pb in ipairs(pbs) do
            if not pb.derived then
              hasReal = true
              if pb.ppq <= first.ppq then anchored = true break end
            end
          end
          if (next(needed) ~= nil or hasReal) and not anchored then
            needed[first.ppq]  = true
            hostPpqL[first.ppq] = first.ppqL
          end
        end

        -- Back-derive cents for any pb missing it; foreign-MIDI / pre-
        -- cents-sidecar pbs carry only raw on the wire, so the authored
        -- value is recovered once here against the current lane-1
        -- layout. Marked so the consolidated assign below always
        -- carries cents to the sidecar (raw alone may stay unchanged).
        local persistCents = {}
        for _, pb in ipairs(pbs) do
          if pb.cents == nil then
            pb.cents = rawToCents(pb.val) - detuneAt(lane1Events, pb.ppq)
            persistCents[pb] = true
          end
        end

        -- Match existing pbs to needed seats. Real pbs cover their seat.
        -- Fakes: consume any already at a needed seat in place, move
        -- remaining fakes to fill the rest, delete leftovers.
        local realAt, availAbsorbers = {}, {}
        for _, pb in ipairs(pbs) do
          if pb.derived then util.add(availAbsorbers, pb)
          else realAt[pb.ppq] = pb end
        end

        local restampPpqL = {}  -- pb -> newPpqL (existing fake at needed seat with stale ppqL)
        for i = #availAbsorbers, 1, -1 do
          local f = availAbsorbers[i]
          if needed[f.ppq] and not realAt[f.ppq] then
            if f.ppqL ~= hostPpqL[f.ppq] then
              restampPpqL[f] = hostPpqL[f.ppq]
              f.ppqL = hostPpqL[f.ppq]   -- mirror into the clone so step 5 / column projection sees it
            end
            needed[f.ppq] = nil
            table.remove(availAbsorbers, i)
          end
        end

        local moved = {}  -- pb -> newPpq
        for ppq in pairs(needed) do
          if not realAt[ppq] then
            local f = table.remove(availAbsorbers)
            if f then
              moved[f] = ppq
              f.ppq, f.cents, f.ppqL = ppq, 0, hostPpqL[ppq]
              util.add(pbs, f)
            else
              local fresh = { chan = chan, ppq = ppq, cents = 0,
                              ppqL = hostPpqL[ppq], derived = 'absorber', evType = 'pb' }
              util.add(pbs, fresh)
              util.add(pbAdds, { evt = fresh })
            end
          end
        end

        for _, f in ipairs(availAbsorbers) do
          util.add(pbDeletes, { token = f.origTok })
          for i, p in ipairs(pbs) do
            if p == f then table.remove(pbs, i); break end
          end
        end

        table.sort(pbs, function(a, b) return a.ppq < b.ppq end)

        -- Consolidated assign: one entry per existing pb where ANY of
        -- (ppq moved, ppqL restamped, raw changed, cents back-derived)
        -- needs to land.
        for _, pb in ipairs(pbs) do
          if pb.origTok then
            local d      = detuneAt(lane1Events, pb.ppq)
            local newRaw = centsToRaw(pb.cents + d)
            local update = nil
            if moved[pb] then
              update = { ppq = pb.ppq, ppqL = pb.ppqL,
                         cents = pb.cents, val = newRaw }
            elseif restampPpqL[pb] then
              update = { ppqL = restampPpqL[pb], cents = pb.cents, val = newRaw }
            elseif pb.val ~= newRaw or persistCents[pb] then
              update = { cents = pb.cents, val = newRaw }
            end
            if update then
              pb.val = newRaw
              util.add(pbAssigns, { token = pb.origTok, update = update })
            end
          end
        end

        -- Column projection.
        local anyVisible, pbColEvents = false, {}
        for _, pb in ipairs(pbs) do
          local hidden = pb.derived and (pb.shape == nil or pb.shape == 'step')
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

      if #pbAdds > 0 or #pbAssigns > 0 or #pbDeletes > 0 then
        mm:modify(function()
          for _, op in ipairs(pbDeletes) do mm:delete(op.token) end
          for _, op in ipairs(pbAssigns) do mm:assign(op.token, op.update) end
          for _, op in ipairs(pbAdds) do
            local d = detuneAt(lane1ByChan[op.evt.chan], op.evt.ppq)
            local writeEvt = util.clone(op.evt)
            writeEvt.val = centsToRaw(op.evt.cents + d)
            mm:add(writeEvt)
          end
        end)
      end
    end

    -- 6.5) PA dispatch. Runs after step 6 so foreign-MIDI PAs can locate
    -- their host note (now in channels[]). PAs do not own a lane in the
    -- model -- they ride a same-pitch note's column.
    for _, cc in mm:ccs() do
      if cc.evType == 'pa' then
        local noteCol = findNoteColumnForPitch(channels[cc.chan], cc.pitch, cc.ppq)
        if noteCol then
          util.add(noteCol.events, projectCC(cc, mm:tokenOf(cc), { type = 'pa' }))
        end
      end
    end

    -- 4.5) PC synthesis (trackerMode only). Runs after step 6 so it sees
    -- externals too: a foreign-MIDI note in trackerMode inherits sample
    -- from the prevailing PC and is reflected in the synthesised set.
    if cm:get('trackerMode') then
      local toDelete, toAdd = {}, {}
      for chan = 1, 16 do
        local records = {}
        for L, lane in ipairs(channels[chan].columns.notes) do
          for _, n in ipairs(lane.events) do
            util.add(records, { ppq = n.ppq, ppqL = n.ppqL, lane = L, sample = n.sample or 0, key = n })
          end
        end
        for _, w in ipairs(fxLive[chan]) do
          local n = w.evt
          util.add(records, { ppq = n.ppq, ppqL = n.ppqL, lane = w.lane, sample = n.sample or 0, key = n })
        end
        local rems, adds_ = reconcilePCsForChan(chan, records)
        for _, r in ipairs(rems)  do util.add(toDelete, r.token) end
        for _, a in ipairs(adds_) do util.add(toAdd, a) end
      end

      if #toDelete > 0 or #toAdd > 0 then
        mm:modify(function()
          for _, tok in ipairs(toDelete) do mm:delete(tok) end
          for _, pc  in ipairs(toAdd)    do mm:add(pc) end
        end)
        for chan = 1, 16 do channels[chan].columns.pc = { events = {} } end
        for _, cc in mm:ccs() do
          if cc.evType == 'pc' then
            util.add(channels[cc.chan].columns.pc.events, projectCC(cc, mm:tokenOf(cc)))
          end
        end
      end
    end

    -- 5) Project to logical. The tv surface is logical-only: both the
    -- onset and the tail leave here in the authoring frame, raw stays
    -- private to tm/mm.
    --
    -- evt.ppq and evt.endppq leave here as floats: the logical frame
    -- is float by design, and the on-grid predicate (ctx:isOnGrid) is
    -- the sole owner of the row-membership tolerance. Rounding here
    -- would silently widen that tolerance to 1 ppq.
    --
    -- evt.endppq is the AUTHORED logical ceiling, unclipped: endppqL,
    -- or util.OPEN for a deliberately-unbounded tail. The tail pass
    -- already folded every blocker into mm's raw endppq; inverting it
    -- gives evt.endppqC, the CLIPPED logical ceiling — render-only
    -- (the tp tail build is the sole consumer). An uncached note (no
    -- endppqL) has no authored stamp, so its authored ceiling is the
    -- realised one.
    do
      local res = mm:resolution()
      local function projectToLogical(col, chan)
        for _, evt in ipairs(col.events) do
          if evt.ppqL ~= nil then
            -- delayC: realised-frame delay equivalent. Differs from
            -- authored delay when the unified walk clamped raw against
            -- a same-pitch predecessor; renderer cues the give-way.
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

    reload()
    rebuilding = false

    --emits: rebuild -- takeChanged:boolean
    --contract: rebuild fires at end of every rebuild after the um cache is reloaded
    --invariant: takeChanged is true only when rebuild followed bindTake; signals take-tier reload
    fire('rebuild', takeChanged)
  end
end

----- Lifecycle

do
  --invariant: tvOnlyKeys skip the configChanged rebuild; defaultSwing is the sole remaining cm key
  local tvOnlyKeys = { defaultSwing = true }

  --invariant: dataChanged 'swing' → global change marks all 16, else only the diffed channels
  --invariant: configChanged 'swings' → channels resolving to names with diff body vs prevSwings
  --invariant: prev*-caches refresh after each event and on bindTake
  -- Merged-tier read: a save at any tier (project, global) lands in the
  -- same merged view, so diff captures real change to the composite a
  -- channel will resolve to.
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

  -- swing/extraColumns/noteDelay are document data: edits + undo rewinds arrive as
  -- dataChanged. swing diffs its map; the column-layout keys force a full rebuild.
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
    elseif change.name == 'extraColumns' or change.name == 'noteDelay' then
      tm:rebuild(false)
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
