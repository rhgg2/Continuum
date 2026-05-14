-- See docs/trackerManager.md for the model.

--invariant: tm holds (ppqL, raw) per event; mm holds raw; column events expose evt.ppq as logical. Rebuild reconciles raw ↔ ppqL each pass; see docs/timing.md
--invariant: detune is intent (per-note); pb is realisation (channel-wide stream); only lane-1 notes drive detune realisation
--invariant: pb.val is cents inside um; raw conversion happens only on load (rawToCents) and at flush (centsToRaw); cents window is cm:get('pbRange') * 100 per side
--invariant: fake pbs are absorbers seated at lane-1 note onsets to absorb detune jumps; pb.fake is the sole marker (persisted as cc metadata via mm sidecar)
--invariant: pa events store pitch-aftertouch value in mm cc.vel; col.events project as { type='pa', vel, ... } with the cc-routing fields stripped
--invariant: loc values are valid only within a single rebuild-to-flush window; um's notesByLoc/ccsByLoc are rebuilt fresh each rebuild
--invariant: column events are sorted by logical ppq; endppq carries no delay (delay shifts only the note-on)
--invariant: 16 channels always present; channels[i] non-nil for i in 1..16 after rebuild

--shape: channel = { chan=1..16, columns = { notes=[col,...], ccs={[ccNum]=col,...}, pc=col|nil, pb=col|nil, at=col|nil } }
--shape: column = { events=[evt,...], [cc=ccNum] }  -- events sorted by logical ppq
--shape: noteEvent = { ppq, endppq, pitch, vel, lane, detune, delay, [muted], [sample], [sampleShadowed], loc, [<metadata...>] }
--shape: pbEventCol = { ppq, val=cents-minus-detune, detune, hidden, [delay], [shape], [tension], loc, ... }  -- column projection; um cache holds raw cents in val
--shape: paEventCol = { type='pa', ppq, pitch, vel, loc, ... }  -- mixed into note column events
--shape: extraColumns[chan] = { notes=count, [pc=true], [pb=true], [at=true], [ccs={[ccNum]=true}] }
--shape: lastMuteSet = { [chan] = true }, pushed by tv via tm:setMutedChannels

local util    = require 'util'
local timing  = require 'timing'
local tuning  = require 'tuning'
local aliases = require 'aliases'

local function print(...)
  return util.print(...)
end

local mm, cm = (...).mm, (...).cm

local tm = {}
local fire = util.installHooks(tm)

---------- STATE

local channels    = {}
local lastMuteSet = {}
--invariant: pendingFlushUuids: uuid-set of notes touched by the in-flight flush; read by allocateNoteColumn to attribute lane overlaps; nil outside a flush-driven rebuild
local pendingFlushUuids
--invariant: specOf[uuid]=SpecNode; nodeMeta[node]={parent, uuid}. Cleared at rebuild head, populated by walker. parent=nil → top-level; uuid=nil → suppressed. See docs/aliases.md.
local specOf      = {}
local nodeMeta    = {}
--invariant: staleSwing[chan]=true: this channel's resolved swing changed; rebuild rule rederives raw from ppqL and clears
local staleSwing  = {}
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


--contract: synthesised PCs carry fake=true and inherit ppqL from the winning host-note record; an existing fake PC matching (ppq, val) is kept (omitted from both toRemove and toAdd), preserving its mm-side loc across rebuilds where val did not change
--contract: if record.key is set, marks key.sampleShadowed=true on records lost to lane priority; returns (toRemove, toAdd) for the caller to persist. Shadow marking is rebuild-only — flush-time callers omit key since lane events are reclone'd by the rebuild that follows. c.pc.events is not written here; rebuild's CC walk refreshes it from mm after the caller's commit.
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
    if have and have.fake and have.val == w.sample then
      kept[have] = true
    else
      util.add(toAdd, { ppq = ppq, ppqL = w.ppqL, val = w.sample,
                        evType = 'pc', chan = chan, fake = true })
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

---------- UPDATE MANAGER

local addEvent, assignEvent, deleteEvent, flush, reload do

  ----- State

  local adds = {}
  local assigns = {}
  local deletes = {}
  local chans = {}
  local byToken = {}
  local dirtyPcChans = {}

  ----- Accessors

  local function owner(chan, P)
    return util.seek(chans[chan].notes, 'at-or-before', P, function(n) return n.endppq > P end)
  end

  local function detuneAt(chan, P)
    local n = util.seek(chans[chan].notes, 'at-or-before', P)
    return (n and n.detune) or 0
  end

  local function detuneBefore(chan, P)
    local n = util.seek(chans[chan].notes, 'before', P)
    return (n and n.detune) or 0
  end

  local function rawAt(chan, P)
    local pb = util.seek(chans[chan].pbs, 'at-or-before', P)
    return pb and pb.val or 0
  end

  local function rawBefore(chan, P)
    local pb = util.seek(chans[chan].pbs, 'before', P)
    return pb and pb.val or 0
  end

  local function pbAt(chan, P)
    local pb = util.seek(chans[chan].pbs, 'at-or-before', P)
    return pb and pb.ppq == P and pb or nil
  end

  --contract: logical = raw − detune; this is the "user heard pitch" frame, decoupled from the absorber bookkeeping
  local function logicalAt(chan, P)
    return rawAt(chan, P) - detuneAt(chan, P)
  end

  local function logicalBefore(chan, P)
    return rawBefore(chan, P) - detuneBefore(chan, P)
  end

  local function nextRealChange(chan, P)
    local pb = util.seek(chans[chan].pbs, 'after', P, function(e) return not e.fake end)
    return (pb and pb.ppq) or math.huge
  end

  local function nextNotePPQ(chan, P)
    local n = util.seek(chans[chan].notes, 'after', P)
    return (n and n.ppq) or math.huge
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

  --contract: only lane==1 notes index into chans[chan].notes; higher-lane notes get queued for mm but don't feed detune/realisation reads. Caller supplies evt.evType.
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

  --contract: dedupes by token (unique across types) so multiple in-flight assigns to the same event collapse into one mm write; util.REMOVE markers must survive merging
  local function assignLowlevel(evt, update)
    util.assign(evt, update)
    -- ppq mutates in place; resort so subsequent util.seek calls keyed off chans[chan].notes stay correct under non-monotone callers (reswing).
    if evt.evType == 'note' and update.ppq ~= nil and evt.lane == 1 then
      sortByPPQ(chans[evt.chan].notes)
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
      util.add(deletes, { token = token })
      for j = #assigns, 1, -1 do
        if assigns[j].token == token then table.remove(assigns, j) end
      end
    else
      for j = #adds, 1, -1 do
        if adds[j].evt == evt then table.remove(adds, j); break end
      end
    end
  end

  --contract: shifts every pb's raw val by delta over [P1, P2); preserves logical stream above by definition since detune absorbs delta
  local function retuneLowlevel(chan, P1, P2, delta)
    if delta == 0 then return end
    for _, pb in ipairs(chans[chan].pbs) do
      if pb.ppq >= P1 and pb.ppq < P2 then
        assignLowlevel(pb, { val = pb.val + delta })
      end
    end
  end

  --contract: no-op (returns false) if a pb already sits at P; otherwise seats one at the carrier value (rawAt) so logical stream is preserved
  local function forcePb(chan, P, extras)
    if pbAt(chan, P) then return false end
    addLowlevel(util.assign({ ppq = P, chan = chan, val = rawAt(chan, P), evType = 'pb' }, extras))
    return true
  end

  local function markFake(chan, P)
    local pb = pbAt(chan, P)
    if pb then assignLowlevel(pb, { fake = true }) end
  end

  local function unmarkFake(chan, P)
    local pb = pbAt(chan, P)
    if not (pb and pb.fake) then return end
    assignLowlevel(pb, { fake = util.REMOVE })
  end

  -- Callers invoke post-mutation (note edits committed) so detuneAt/Before see live values.
  local function reconcileBoundary(chan, P)
    if P >= math.huge then return end
    local D, C = detuneAt(chan, P), detuneBefore(chan, P)
    local pb   = pbAt(chan, P)
    if D == C then
      if pb and pb.fake and rawAt(chan, P) == rawBefore(chan, P) then
        deleteLowlevel(pb)
      end
    elseif not pb then
      forcePb(chan, P)               -- val = rawAt = rawBefore (no pb yet)
      markFake(chan, P)
      pb = pbAt(chan, P)
      assignLowlevel(pb, { val = pb.val + (D - C) })
    end
  end

  ----- High-level ops

  --contract: authoring frame is logical (pb.val is logical cents); seats/updates the carrier and retunes forward to next real pb so logical above is preserved
  local function addPb(pb)
    local chan, P, L = pb.chan, pb.ppq, pb.val or 0
    local delta  = L - logicalAt(chan, P)
    -- chan/ppq/val belong to forcePb's structural set; evType comes through the literal.
    local extras = util.clone(pb,
      { chan = true, ppq = true, val = true, evType = true })
    if not next(extras) then extras = nil end
    if not forcePb(chan, P, extras) then
      if extras then assignLowlevel(pbAt(chan, P), extras) end
      unmarkFake(chan, P)
    end
    retuneLowlevel(chan, P, nextRealChange(chan, P), delta)
  end

  --contract: retunes forward to undo pb's logical contribution; collapses to a real delete only if the seat would also be redundant as a fake (detuneAt == detuneBefore)
  local function deletePb(pb)
    local chan, P = pb.chan, pb.ppq
    retuneLowlevel(chan, P, nextRealChange(chan, P), logicalBefore(chan, P) - logicalAt(chan, P))
    if detuneAt(chan, P) == detuneBefore(chan, P) then
      deleteLowlevel(pb)
    else
      if owner(chan, P) then markFake(chan, P) end
    end
  end

  local function assignPb(pb, update)
    if update.ppq and update.ppq ~= pb.ppq then
      local chan, oldP, newP = pb.chan, pb.ppq, update.ppq
      local oldL = logicalAt(chan, oldP)
      local newL = update.val ~= nil and update.val or oldL

      -- Two cases need a true destroy/create on the mm stream and fall
      -- through to deletePb+addPb: a non-self pb already sits at newP
      -- (typically a fake absorber to be merged in), or oldP needs a
      -- fresh fake born to absorb a detune jump after we leave.
      local existing      = pbAt(chan, newP)
      local needFakeAtOld = (detuneAt(chan, oldP) ~= detuneBefore(chan, oldP))
                            and owner(chan, oldP)
      if (existing and existing ~= pb) or needFakeAtOld then
        local extras = util.clone(pb, { token = true, fake = true,
                                         chan = true, ppq = true, val = true,
                                         evType = true })
        util.assign(extras, util.clone(update, { ppq = true, val = true }))
        deletePb(pb)
        addPb(util.assign({ chan = chan, ppq = newP, val = newL }, extras))
        return
      end

      -- In-place move. Mirror deletePb's retune over [oldP, nextRealOld)
      -- to revert the pb's old contribution (this also bumps pb itself
      -- to a passthrough val); then mutate ppq+val+metadata in one
      -- assignLowlevel; then mirror addPb's retune over [newP, nextRealNew)
      -- to lift pb to its new logical value. mm-side identity (uuid,
      -- sidecar, idx) survives the move.
      retuneLowlevel(chan, oldP, nextRealChange(chan, oldP),
                     logicalBefore(chan, oldP) - oldL)
      local carrierAtNew = rawAt(chan, newP)
      local moveUpdate   = util.clone(update)
      moveUpdate.ppq = newP
      moveUpdate.val = carrierAtNew
      assignLowlevel(pb, moveUpdate)
      sortByPPQ(chans[chan].pbs)
      retuneLowlevel(chan, newP, nextRealChange(chan, newP),
                     newL - logicalAt(chan, newP))
      return
    end
    if update.val then
      local chan, P = pb.chan, pb.ppq
      local delta = update.val - logicalAt(chan, P)
      unmarkFake(chan, P)
      retuneLowlevel(chan, P, nextRealChange(chan, P), delta)
    end
    local rest = util.clone(update, { val = true, ppq = true })
    if next(rest) then assignLowlevel(pb, rest) end
  end

  local function dirtyPc(chan) dirtyPcChans[chan] = true end

  --contract: lane-1 path: seat fake-pb if detune jumps the carry, retune forward to next note, then reconcile the next-note boundary; lane>1 just queues with no realisation work
  local function addNote(n)
    dirtyPc(n.chan)
    local D = n.detune
    if lastMuteSet[n.chan] then n.muted = true end
    if n.lane == 1 then
      local C     = detuneAt(n.chan, n.ppq)
      local nextP = nextNotePPQ(n.chan, n.ppq)
      if D ~= C and forcePb(n.chan, n.ppq) then markFake(n.chan, n.ppq) end
      retuneLowlevel(n.chan, n.ppq, nextP, D - C)
      addLowlevel(util.assign(n, { detune = D }))
      reconcileBoundary(n.chan, nextP)
    else
      addLowlevel(util.assign(n, { detune = D }))
    end
  end

  --contract: attached PAs are deleted with the host unless keepPAs; lane-1 path drops any fake seat at n.ppq and retunes back to the prior detune over [n.ppq, nextNote)
  local function deleteNote(n, keepPAs)
    dirtyPc(n.chan)
    if not keepPAs then forEachAttachedPA(n, function(evt) deleteLowlevel(evt) end) end
    if n.lane ~= 1 then deleteLowlevel(n); return end
    local D1, D2 = detuneBefore(n.chan, n.ppq), detuneAt(n.chan, n.ppq)
    local nextP  = nextNotePPQ(n.chan, n.ppq)
    local pb     = pbAt(n.chan, n.ppq)
    if pb and pb.fake then deleteLowlevel(pb) end
    deleteLowlevel(n)
    retuneLowlevel(n.chan, n.ppq, nextP, D1 - D2)
    reconcileBoundary(n.chan, nextP)
  end

  local function resizeNote(n, P1, P2)
    local col1  = n.lane == 1
    local shift = P1 - n.ppq
    if shift ~= 0 and P2 - n.endppq == shift then
      forEachAttachedPA(n, function(evt)
        assignLowlevel(evt, { ppq = evt.ppq + shift })
      end)
    else
      local lastPA
      forEachAttachedPA(n, function(evt)
        if evt.ppq <= P1 or evt.ppq >= P2 then
          if evt.ppq <= P1 and (not lastPA or evt.ppq > lastPA.ppq) then lastPA = evt end
          deleteLowlevel(evt)
        end
      end)
      if lastPA then assignLowlevel(n, { vel = lastPA.vel }) end
    end

    if not col1 then
      assignLowlevel(n, { ppq = P1, endppq = P2 })
      return
    end

    -- col-1: withdraw detune at old seat, move, reapply at new. L is the
    -- logical pb the user authored at P1 *before* the move — if it
    -- differs from prevailing logical there we seat a real pb to carry it.
    local oldppq = n.ppq
    local D   = n.detune
    local L   = logicalAt(n.chan, P1)
    local C1  = detuneBefore(n.chan, oldppq)
    local NP1 = nextNotePPQ(n.chan, oldppq)
    local oldPb = pbAt(n.chan, oldppq)

    assignLowlevel(n, { ppq = P1, endppq = P2 })

    if oldPb and oldPb.fake then
      deleteLowlevel(oldPb)
    end
    retuneLowlevel(n.chan, oldppq, NP1, C1 - D)
    -- The carry into NP1 has shifted from D to C1 (n no longer
    -- bridges); a previously-masked jump may now need its own
    -- absorber, or a previously-needed one may have collapsed.
    reconcileBoundary(n.chan, NP1)

    -- New seat: real pb wins over fake; pre-existing pb wins over
    -- both. logicalBefore(P1) is read after the boundary at NP1
    -- has been reconciled — placing the absorber there can change
    -- rawBefore at P1 in leapfrog moves.
    local C2 = detuneBefore(n.chan, P1)
    if L ~= logicalBefore(n.chan, P1) then
      forcePb(n.chan, P1)
    elseif D ~= C2 and forcePb(n.chan, P1) then
      markFake(n.chan, P1)
    end
    local NP2 = nextNotePPQ(n.chan, P1)
    retuneLowlevel(n.chan, P1, NP2, D - C2)
    reconcileBoundary(n.chan, NP2)
  end

  --contract: chan/lane updates are rejected with a warning; ppq/endppq route through resizeNote; detune updates retune forward and reconcile both endpoint boundaries
  local function assignNote(n, update)
    if update.chan then print('um: not allowed to change channel of notes'); return end
    if update.lane then print('um: not allowed to change lane of notes'); return end

    -- update.ppq covers both direct ppq edits and delay edits
    -- (realiseNoteUpdate maps delay→ppq before we get here). endppq
    -- alone doesn't move the realised onset, so it doesn't dirty.
    if update.sample ~= nil or update.ppq ~= nil then dirtyPc(n.chan) end

    if update.ppq ~= nil or update.endppq ~= nil then
      resizeNote(n, update.ppq or n.ppq, update.endppq or n.endppq)
      update.ppq, update.endppq = nil, nil
    end
    if update.pitch then
      forEachAttachedPA(n, function(e) assignLowlevel(e, { pitch = update.pitch }) end)
    end
    if n.lane == 1 and update.detune ~= nil and update.detune ~= n.detune then
      local nextP = nextNotePPQ(n.chan, n.ppq)
      if forcePb(n.chan, n.ppq) then markFake(n.chan, n.ppq) end
      retuneLowlevel(n.chan, n.ppq, nextP, update.detune - n.detune)
      -- Commit detune now so the boundary reconciliations below read
      -- post-update state. Our own seat may collapse (detune now
      -- matches prior); the next note's seat may flip either way —
      -- a previously-absorbed jump may erase, or a previously-absent
      -- jump may appear because the carry has shifted.
      assignLowlevel(n, { detune = update.detune })
      update.detune = nil
      reconcileBoundary(n.chan, n.ppq)
      reconcileBoundary(n.chan, nextP)
    end
    if next(update) then assignLowlevel(n, update) end
  end

  -- Returns (clampEnd, clampEndL): the realised end and its logical
  -- counterpart. Truncated peers are stamped with endppqL = selfPpqL so
  -- the canonical logical frame stays coherent with endppq.
  local function clearSameKeyRange(chan, pitch, P, Pend, selfPpqL, selfEvt)
    local clampEnd, clampEndL = Pend, nil
    local toDelete, toTruncate = {}, {}
    for _, n in pairs(byToken) do
      if n.evType == 'note' and n ~= selfEvt and n.chan == chan and n.pitch == pitch then
        if n.ppq <= P and n.endppq > P then
          if n.ppq == P then util.add(toDelete, n)
          else util.add(toTruncate, n) end
        elseif clampEnd and n.ppq > P and n.ppq < clampEnd then
          clampEnd, clampEndL = n.ppq, n.ppqL
        end
      end
    end
    for _, n in ipairs(toDelete)   do deleteNote(n) end
    for _, n in ipairs(toTruncate) do
      assignNote(n, { endppq = P, endppqL = selfPpqL })
    end
    return clampEnd, clampEndL
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

  function deleteEvent(evtOrToken)
    local evt = lookup(evtOrToken)
    if not evt then return end
    local et = evt.evType
    if     et == 'note' then deleteNote(evt)
    elseif et == 'pb'   then deletePb(evt)
    else                     deleteLowlevel(evt) end
  end

  --contract: update.ppq/endppq arrive logical; stamps ppqL/endppqL and rewrites ppq/endppq to raw. Caller-supplied update.ppqL/endppqL signals "raw already computed" — translation is skipped, only delay-delta applies. See docs/timing.md.
  local function realiseNoteUpdate(evt, update)
    local dOld = delayToPPQ(evt.delay)
    local dNew = delayToPPQ(update.delay ~= nil and update.delay or evt.delay)
    if update.ppq == nil and update.endppq == nil and dNew == dOld then return end
    if update.ppqL ~= nil or update.endppqL ~= nil then
      if update.ppq ~= nil then
        update.ppq = update.ppq + dNew
      elseif dNew ~= dOld then
        update.ppq = evt.ppq + (dNew - dOld)
      end
      return
    end
    if update.ppq ~= nil then
      update.ppqL = update.ppq
      update.ppq  = tm:fromLogical(evt.chan, update.ppqL, dNew)
    elseif evt.ppqL ~= nil then
      update.ppq = tm:fromLogical(evt.chan, evt.ppqL, dNew)
    else
      update.ppq = evt.ppq + (dNew - dOld)
    end
    if update.endppq ~= nil then
      update.endppqL = update.endppq
      update.endppq  = tm:fromLogical(evt.chan, update.endppqL)
    end
  end

  local function realiseNonNoteUpdate(chan, update)
    if update.ppqL ~= nil then return end
    if not chan or update.ppq == nil then return end
    update.ppqL = update.ppq
    update.ppq  = tm:fromLogical(chan, update.ppqL)
  end

  local function realiseAddPpq(evt, withDelay, withEnd)
    if evt.ppq == nil or not evt.chan then return end
    evt.ppqL = evt.ppq
    evt.ppq  = tm:fromLogical(evt.chan, evt.ppqL,
                              withDelay and delayToPPQ(evt.delay or 0) or 0)
    if withEnd and evt.endppq ~= nil then
      evt.endppqL = evt.endppq
      evt.endppq  = tm:fromLogical(evt.chan, evt.endppqL)
    end
  end

  function assignEvent(evtOrToken, update)
    local evt = lookup(evtOrToken)
    if not evt then return end
    local et = evt.evType
    if et == 'note' then
      local rawCaller = update.ppqL ~= nil or update.endppqL ~= nil
      realiseNoteUpdate(evt, update)
      if not rawCaller
         and (update.pitch ~= nil or update.ppq ~= nil or update.endppq ~= nil) then
        local P      = update.ppq    or evt.ppq
        local Pend   = update.endppq or evt.endppq
        local pitch  = update.pitch  or evt.pitch
        local selfL  = update.ppqL   or evt.ppqL
        local clamped, clampedL = clearSameKeyRange(evt.chan, pitch, P, Pend, selfL, evt)
        if clamped ~= Pend then
          update.endppq  = clamped
          update.endppqL = clampedL
        end
      end
      assignNote(evt, update)
    elseif et == 'pb' then
      realiseNonNoteUpdate(evt.chan, update)
      assignPb(evt, update)
    else
      realiseNonNoteUpdate(evt.chan, update)
      assignLowlevel(evt, update)
    end
  end

  --contract: notes default detune=0, delay=0, lane=1; evt.ppq/endppq arrive logical; stamps ppqL/endppqL and rewrites ppq/endppq to raw before mm. Caller-supplied evt.ppqL signals "raw already computed" — translation is skipped (mirrors assignEvent).
  function addEvent(evt)
    local rawCaller = evt.ppqL ~= nil
    if evt.evType == 'note' then
      evt.detune = evt.detune or 0
      evt.delay  = evt.delay  or 0
      evt.lane   = evt.lane   or 1
      if not rawCaller then realiseAddPpq(evt, true, true) end
      local clamped, clampedL =
        clearSameKeyRange(evt.chan, evt.pitch, evt.ppq, evt.endppq, evt.ppqL, evt)
      evt.endppq = clamped
      if clampedL then evt.endppqL = clampedL end
      addNote(evt)
    else
      if not rawCaller then realiseAddPpq(evt, false, false) end
      if evt.evType == 'pb' then addPb(evt) else addLowlevel(evt) end
    end
  end

  ----- Flush: commit accumulated ops to mm.

  --contract: no-op if nothing staged; otherwise commits assigns then deletes then adds under one mm:modify; pb cents→raw conversion happens here; byToken is re-keyed live from mm:assign's returned token whenever an identity field moved
  --contract: snapshots adds/assigns/deletes before mm:modify so re-entry from mm callbacks (e.g. setMutedChannels via rebuild) cannot re-emit in-flight ops
  function flush()
    if cm:get('trackerMode') and next(dirtyPcChans) then
      for chan in pairs(dirtyPcChans) do reconcilePcs(chan) end
      dirtyPcChans = {}
    end
    if #adds == 0 and #assigns == 0 and #deletes == 0 then return end

    local flushAdds, flushAssigns, flushDeletes = adds, assigns, deletes
    adds, assigns, deletes = {}, {}, {}

    for _, e in ipairs(flushAssigns) do
      if e.evt.evType == 'pb' and e.update.val ~= nil then
        e.update.val = centsToRaw(e.update.val)
      end
    end
    for _, a in ipairs(flushAdds) do
      if a.evt.evType == 'pb' then
        a.evt.val = centsToRaw(a.evt.val)
      end
    end

    -- Capture uuids of notes this flush touches, so the rebuild fired
    -- from mm's reload can attribute over-threshold lane overlaps to us.
    local touched = {}
    for _, o in ipairs(flushAssigns) do
      if o.evt.evType == 'note' and o.evt.uuid then touched[o.evt.uuid] = true end
    end
    pendingFlushUuids = touched

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
          if o.evt.evType == 'note' and o.evt.uuid then touched[o.evt.uuid] = true end
        end
      end
    end)
  end

  ----- Init / reload: (re)load local cache from mm.

  -- Also clears staging buffers: a rebuild must not carry un-flushed ops
  -- across (their tokens may be stale for newly-added events), matching the
  -- prior "fresh um per rebuild" semantics now that the um itself persists.
  function reload()
    adds, assigns, deletes = {}, {}, {}
    dirtyPcChans           = {}
    byToken                = {}
    for i = 1, 16 do chans[i] = { notes = {}, pbs = {} } end

    for tok, e in mm:events() do
      local evt
      if e.evType == 'pb' then
        evt = util.pick(e, 'ppq ppqL chan shape tension fake frame',
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
        local function resolve(name)
          local composite = timing.findShape(name, cm:get('swings'))
          if timing.isIdentity(composite) or length <= 0 then return nil end
          return timing.resolveComposite(composite, length, ppqPerQN)
        end
        global = resolve(cm:get('swing'))
        for chan, name in pairs(cm:get('colSwing') or {}) do
          column[chan] = resolve(name)
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

--contract: chan==nil marks all 16 channels stale; otherwise just the named channel. Consumed by the rebuild rule on the next tm:rebuild, then cleared.
function tm:markSwingStale(chan)
  if chan then staleSwing[chan] = true; return end
  for i = 1, 16 do staleSwing[i] = true end
end

----- Mutation

function tm:deleteEvent(evt)         deleteEvent(evt)         end
function tm:addEvent(evt)            addEvent(evt)            end
function tm:assignEvent(evt, update) assignEvent(evt, update) end
function tm:flush()                           flush()                        end

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

--contract: idempotent: walks every existing note and only emits an assign when n.muted differs from desired; lastMuteSet also tags later-added notes. PA events ride along in note columns but carry no mute state — skipped.
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

----- Aliases

local function resolveAliased(evt)
  if not (evt and evt.parentUuid) then return end
  local node = specOf[evt.uuid]
  if not node then return end
  local _, root, kind = mm:byUuid(evt.parentUuid)
  if not root then return end
  return mm:tokenOf(root), root, kind, node
end

function tm:specOf(uuid)   return specOf[uuid] end
function tm:nodeMeta(node) return nodeMeta[node] end

-- Integer-array spec path for a materialised event, derived live by
-- walking nodeMeta up and finding each ancestor's position in its
-- parent's children list. Replaces the persisted emit.specPath.
-- Returns nil for plain events and for aliased events whose first
-- rebuild has not yet populated specOf.
function tm:specPathOf(evt)
  if not (evt and evt.uuid and evt.parentUuid) then return nil end
  local node = specOf[evt.uuid]
  if not node then return nil end
  local _, root = mm:byUuid(evt.parentUuid)
  if not (root and root.children) then return nil end
  local chain = {}
  while node do
    chain[#chain + 1] = node
    node = nodeMeta[node].parent
  end
  local idx, list = {}, root.children
  for i = #chain, 1, -1 do
    local target = chain[i]
    local found
    for j, n in ipairs(list) do
      if n == target then found = j; break end
    end
    if not found then return nil end
    idx[#idx + 1] = found
    list = target.children
  end
  return idx
end

--contract: appends a per-field op map onto evt's spec node; one root snapshot per call so coupled fields stay atomic. Per-field value is one op or a list (list lands as successive appendOps with coalescence). Returns false if evt isn't aliased or specOf lookup fails — caller falls through to direct mutation. See docs/aliases.md.
function tm:routeRelative(evt, opsByField)
  local rootTok, root, _, node = resolveAliased(evt)
  if not node then return false end
  for field, op in pairs(opsByField) do
    if type(op[1]) == 'table' then
      for _, o in ipairs(op) do
        node.xform = aliases.appendOp(node.xform, field, o)
      end
    else
      node.xform = aliases.appendOp(node.xform, field, op)
    end
  end
  assignEvent(rootTok, { children = root.children })
  return true
end

--contract: groups events by parentUuid; one snapshot per root, deepest-first via nodeMeta walk. Pluck-by-identity dissolves the ordering hazard. Skips events without parentUuid or specOf lookup. Caller flushes. See docs/aliases.md.
function tm:severBatch(events)
  local byParent = {}
  for _, e in ipairs(events) do
    if e and e.parentUuid and specOf[e.uuid] then
      util.bucket(byParent, e.parentUuid, e)
    end
  end
  local function depthOf(evt)
    local d, n = 0, specOf[evt.uuid]
    while n do d = d + 1; n = nodeMeta[n].parent end
    return d
  end
  for parentUuid, list in pairs(byParent) do
    table.sort(list, function(a, b) return depthOf(a) > depthOf(b) end)
    local _, root = mm:byUuid(parentUuid)
    local rootTok = root and mm:tokenOf(root)
    if root and rootTok then
      for _, e in ipairs(list) do
        local node = specOf[e.uuid]
        local pSpec = nodeMeta[node].parent
        local parentList = pSpec and pSpec.children or root.children
        local plucked = aliases.pluckNode(parentList, node)
        if plucked then
          assignEvent(e, {
            parentUuid = util.REMOVE,
            children   = plucked.children or {},
          })
        end
      end
      assignEvent(rootTok, { children = root.children })
    end
  end
end

--contract: single-event wrapper over severBatch. Returns false when evt is unaliased or specOf lookup fails. See docs/aliases.md.
function tm:sever(evt)
  if not resolveAliased(evt) then return false end
  self:severBatch{ evt }
  return true
end

--contract: structural delete: promote spec subtree's direct children to new roots, then drop. Two modes by evt shape — aliased child (drops spec node, evt vanishes via sweep) or root with aliases (drops root event). Suppressed branches dropped silently. Returns false for plain events. Caller flushes. See docs/aliases.md.
function tm:deleteAliased(evt)
  if not evt then return false end

  local rootTok, root, isRoot, S
  if evt.parentUuid then
    rootTok, root, _, S = resolveAliased(evt)
    if not S then return false end
    isRoot = false
  elseif evt.children and #evt.children > 0 then
    rootTok, root = evt.token, evt
    isRoot = true
  else
    return false
  end

  local childSpecs = isRoot and root.children or S.children
  -- Snapshot direct-child list before mutating: pluckNode alters
  -- childSpecs in place; ipairs over a list being mutated skips entries.
  local directChildren = {}
  for _, c in ipairs(childSpecs or {}) do directChildren[#directChildren + 1] = c end

  for _, child in ipairs(directChildren) do
    local meta    = nodeMeta[child]
    local matUuid = meta and meta.uuid
    if matUuid then
      local _, matEvt = mm:byUuid(matUuid)
      if matEvt then
        aliases.pluckNode(childSpecs, child)
        assignEvent(mm:tokenOf(matEvt), {
          parentUuid = util.REMOVE,
          children   = child.children or {},
        })
      end
    end
  end

  if isRoot then
    deleteEvent(rootTok)
  else
    local pSpec = nodeMeta[S].parent
    local parentList = pSpec and pSpec.children or root.children
    aliases.pluckNode(parentList, S)
    assignEvent(rootTok, { children = root.children })
  end
  return true
end

--contract: (rootUuid, specIdx) → { children = deep clone of leaf's children, chain = ancestor xform clones } or nil. Leaf excluded from chain — only ancestor drift counts as tree mutation. See docs/aliases.md.
function tm:aliasSrcSnapshot(rootUuid, specIdx)
  if not (rootUuid and specIdx and #specIdx > 0) then return nil end
  local _, root = mm:byUuid(rootUuid)
  if not (root and root.children) then return nil end
  local list, node, chain = root.children, nil, {}
  for i, idx in ipairs(specIdx) do
    if not list then return nil end
    node = list[idx]
    if not node then return nil end
    if i < #specIdx then
      chain[#chain + 1] = util.deepClone(node.xform)
    end
    list = node.children
  end
  return { children = util.deepClone(node.children or {}), chain = chain }
end

--contract: resolves a captured alias source against the live tree. Three shapes: nil → silent demote (root/index gone); { mismatch=true } → loud demote (ancestor xform drift or unresolvable producing-op); { resolved=fields } otherwise. Leaf xform is free to drift — corrective deltas compensate. See docs/aliases.md.
function tm:resolveAliasSrc(rootUuid, specIdx, chain, evtType)
  if not rootUuid then return nil end
  local _, root = mm:byUuid(rootUuid)
  if not root then return nil end
  local valid = aliases.validFields(evtType)
  local resolved = {}
  for f in pairs(valid) do resolved[f] = root[f] end
  if evtType == 'note' and root.endppqL and root.ppqL then
    resolved.durL = root.endppqL - root.ppqL
  end
  if not specIdx then return { resolved = resolved } end
  if not root.children then return nil end
  local list = root.children
  for i, idx in ipairs(specIdx) do
    local node = list and list[idx]
    if not node then return nil end
    if i < #specIdx then
      local captured = chain and chain[i]
      if not captured or not util.deepEq(captured, node.xform) then
        return { mismatch = true }
      end
    end
    for _, ops in pairs(node.xform) do
      for _, op in ipairs(ops) do
        for j = 2, #op do
          if type(op[j]) ~= 'number' then return { mismatch = true } end
        end
      end
    end
    resolved = aliases.applyXform(resolved, node.xform, evtType, nil)
    list = node.children
  end
  return { resolved = resolved }
end

--contract: concatenates per-field xform op-lists between fromIdx (exclusive) and toIdx (inclusive). Used by family-paste at copy time. Preserves producing-ops verbatim, deep-clones. Returns nil if path invalid or toIdx not a strict descendant. See docs/aliases.md.
function tm:pathXform(rootUuid, fromIdx, toIdx)
  if not (rootUuid and toIdx) then return nil end
  local _, root = mm:byUuid(rootUuid)
  if not (root and root.children) then return nil end
  fromIdx = fromIdx or {}
  if #toIdx <= #fromIdx then return nil end
  for i, fp in ipairs(fromIdx) do
    if toIdx[i] ~= fp then return nil end
  end
  local list, node = root.children, nil
  for _, idx in ipairs(fromIdx) do
    if not list then return nil end
    node = list[idx]
    if not node then return nil end
    list = node.children
  end
  local out = {}
  for i = #fromIdx + 1, #toIdx do
    if not list then return nil end
    node = list[toIdx[i]]
    if not node then return nil end
    for f, ops in pairs(node.xform or {}) do
      out[f] = out[f] or {}
      for _, op in ipairs(ops) do out[f][#out[f] + 1] = util.deepClone(op) end
    end
    list = node.children
  end
  return out
end

--contract: creates a spec node under rootUuid. srcIdx nil → top of root.children; non-nil → child of that spec. children passed verbatim (paste's captured subtree). fit clips materialised endppq to next col event so no new lane is allocated. Returns the new node's specIdx. See docs/aliases.md.
function tm:createAlias(rootUuid, srcIdx, xform, children, fit)
  local _, root = mm:byUuid(rootUuid)
  if not root then return nil end
  local rootTok = mm:tokenOf(root)
  root.children = root.children or {}
  local list, newIdx
  if srcIdx and #srcIdx > 0 then
    local parent = aliases.find(root, srcIdx)
    if not parent then return nil end
    parent.children = parent.children or {}
    list = parent.children
    newIdx = {}
    for _, i in ipairs(srcIdx) do newIdx[#newIdx + 1] = i end
  else
    list, newIdx = root.children, {}
  end
  local node = { xform = xform or {}, children = children or {} }
  if fit then node.fit = true end
  list[#list + 1] = node
  newIdx[#newIdx + 1] = #list
  assignEvent(rootTok, { children = root.children })
  return newIdx
end

----- Rebuild

do
  ----- Aliases walker helpers

  local SEED_EXCLUDE = {
    children = true, uuid = true, parentUuid = true, loc = true, token = true,
  }

  -- chan/evType/ccNum overrides let column events (which carry no chan and have cc/evType stripped) reuse the same keying as raw mm events.
  local function slotKey(evt, chan, evType, ccNum)
    chan   = chan   or evt.chan
    evType = evType or evt.evType
    if evType and evType ~= 'note' then
      local sub = ccNum or evt.cc or evt.pitch or ''
      return 'cc|c=' .. chan .. '|m=' .. evType .. '|i=' .. sub .. '|t=' .. evt.ppq
    end
    return 'note|c=' .. chan .. '|p=' .. evt.pitch .. '|t=' .. evt.ppq
  end

  local function seedFields(root) return util.clone(root, SEED_EXCLUDE) end

  local function seedFromTake(take)
    local guid = ''
    if take then
      _, guid = reaper.GetSetMediaItemTakeInfo_String(take, 'GUID', '', false)
    end
    local s = 0
    for i = 1, #guid do s = (s * 31 + guid:byte(i)) % 2147483648 end
    return s == 0 and 1 or s
  end

  ----- Column allocation

  local function pushNoteCol(channel)
    local notes = channel.columns.notes
    return util.add(notes, { events = {} }), #notes
  end

  --contract: returns (true) on accept; (false, conflictEvt) when the refusal is the bump-prone overlap case (threshold exceeded, or coincident onset); (false) on the dominated-by-two refusal, which is structural rather than bug-attributable
  local function noteColumnAccepts(col, note)
    local lenient = cm:get('overlapOffset') * mm:resolution()
    local noteppqI    = note.ppq - delayToPPQ(note.delay or 0)
    local noteEndppqI = note.endppq
    local dominated = 0
    for _, evt in ipairs(col.events) do
      local evtppqI = evt.ppq - delayToPPQ(evt.delay or 0)
      if noteppqI == evtppqI then return false, evt end
      if noteppqI < evt.endppq and evtppqI < noteEndppqI then
        local threshold = (evt.pitch == note.pitch) and 0 or lenient
        local overlapAmount = math.min(evt.endppq, noteEndppqI) - math.max(evtppqI, noteppqI)
        if overlapAmount > threshold then return false, evt end
        dominated = dominated + 1
      end
    end
    if dominated >= 2 then return false end
    return true
  end

  local function warnLaneOverlap(note, conflict)
    local touched = pendingFlushUuids or {}
    local count = 0
    for _ in pairs(touched) do count = count + 1 end
    local who = (touched[note.uuid] and touched[conflict.uuid] and 'both')
             or (touched[note.uuid] and 'incoming')
             or 'existing'
    print(string.format(
      'tm: lane overlap kept (chan=%d lane=%d): incoming pitch=%d ppq=%d..%d vs existing pitch=%d ppq=%d..%d; touched=%d (%s)',
      note.chan, note.lane,
      note.pitch, note.ppq, note.endppq,
      conflict.pitch, conflict.ppq, conflict.endppq,
      count, who))
  end

  --contract: requested-lane refusals attributable to the in-flight flush (incoming or conflicting note's uuid in pendingFlushUuids) keep the overlap and log a warning, surfacing the bug rather than silently bumping; refusals not attributable, and lane-less adds, fall through to sibling-search bumping unchanged
  local function allocateNoteColumn(channel, note)
    local notes = channel.columns.notes
    if note.lane then
      local col = notes[note.lane]
      if col then
        local ok, conflict = noteColumnAccepts(col, note)
        if ok then return col, note.lane end
        if conflict and pendingFlushUuids
           and (pendingFlushUuids[note.uuid] or pendingFlushUuids[conflict.uuid]) then
          warnLaneOverlap(note, conflict)
          return col, note.lane
        end
      end
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

  ----- Aliases materialisation

  local function materialiseAliases()
    local toDel, roots = {}, {}
    for tok, e in mm:events() do
      if e.parentUuid then util.add(toDel, tok)
      elseif e.children and #e.children > 0 then util.add(roots, e) end
    end

    if #roots == 0 and #toDel == 0 then return end

    -- Route alias-child writes through um so lane-1 onsets seat
    -- fake-pb absorbers when their detune differs from the carry,
    -- same as user-authored notes. Reload first so its chans cache
    -- reflects current mm.
    reload()
    local claims = {}
    for _, e in mm:events() do
      if not e.parentUuid then claims[slotKey(e)] = true end
    end

    local rng = aliases.makeRng(seedFromTake(mm:take()))
    local lenPpq = mm:length() or 0
    local toAdd = {}
    local fitEmits = {}  -- { emit, rChan } for note-aliases marked fit
    local claimedEmits = {}  -- { {node=SpecNode, emit=evt}, ... }; resolved post-flush once mm has minted uuids
    local temper     = tuning.findTemper(cm:get('temper'), cm:get('tempers'))
    local octaveStep = temper and temper.octaveStep or 12

    for _, root in ipairs(roots) do
      local et   = root.evType == 'note' and 'note' or 'cc'
      local seed = seedFields(root)
      -- Logical canonical: spec ops act on ppqL/durL; ppq/endppq are
      -- derived per-emit through the root's authoring-frame swing.
      local rootPitch, rootDetune
      if et == 'note' then
        seed.durL = seed.endppqL - seed.ppqL
        -- pitch/octave are tuning-step accumulators through the spec
        -- walk; the root's MIDI pitch+detune feed transposeStep at emit.
        rootPitch, rootDetune = seed.pitch, seed.detune or 0
        seed.pitch, seed.octave = 0, 0
      end
      local q    = {}
      for _, c in ipairs(root.children) do
        util.add(q, { spec = c, parent = seed, parentSpec = nil })
      end
      while #q > 0 do
        local e = table.remove(q, 1)
        nodeMeta[e.spec] = { parent = e.parentSpec, uuid = nil }
        local resolved = aliases.applyXform(e.parent, e.spec.xform, et, rng)
        if et == 'note' then
          resolved.endppqL = resolved.ppqL + resolved.durL
        end
        local rChan = resolved.chan or 1
        resolved.ppq = tm:fromLogical(rChan, resolved.ppqL,
                                      delayToPPQ(resolved.delay or 0))
        if et == 'note' then
          resolved.endppq = tm:fromLogical(rChan, resolved.endppqL)
          if resolved.endppq > lenPpq then
            resolved.endppq  = lenPpq
            resolved.endppqL = tm:toLogical(rChan, lenPpq)
          end
        end
        local emit = util.clone(resolved, { octave = true })
        if et == 'note' then
          -- rand-arg ops may yield fractional accumulators; pitch/octave
          -- are integer step counts. zero delta skips transposeStep so
          -- an off-scale root detune doesn't snap to the nearest step.
          local steps = math.floor(
            resolved.pitch + resolved.octave * octaveStep + 0.5)
          if steps == 0 then
            emit.pitch, emit.detune = rootPitch, rootDetune
          elseif temper then
            emit.pitch, emit.detune =
              tuning.transposeStep(temper, rootPitch, rootDetune, steps)
          else
            emit.pitch, emit.detune =
              util.clamp(rootPitch + steps, 0, 127), rootDetune
          end
        end
        local key = slotKey(emit)
        if not claims[key] then
          claims[key] = true
          emit.parentUuid = root.uuid
          util.add(toAdd, emit)
          if et == 'note' and e.spec.fit then
            util.add(fitEmits, { emit = emit, rChan = rChan })
          end
          util.add(claimedEmits, { node = e.spec, emit = emit })
        end
        for _, child in ipairs(e.spec.children or {}) do
          util.add(q, { spec = child, parent = resolved, parentSpec = e.spec })
        end
      end
    end

    -- Fit clip pass. For each fit alias, shorten endppq to the next
    -- event's ppq on the same column (chan, lane). Same-column scope
    -- = same channel + same lane authored on the events. Allocator
    -- runs unchanged on the clipped values, so an over-long fit
    -- alias never forces a successor into a new lane.
    if #fitEmits > 0 then
      local byCol = {}
      local function colKey(chan, lane) return (chan or 1) .. ':' .. (lane or 1) end
      for _, n in mm:notes() do
        if not n.parentUuid then
          util.bucket(byCol, colKey(n.chan, n.lane), n.ppq)
        end
      end
      for _, e in ipairs(toAdd) do
        if e.evType == 'note' then
          util.bucket(byCol, colKey(e.chan, e.lane), e.ppq)
        end
      end
      for _, list in pairs(byCol) do table.sort(list) end
      for _, fe in ipairs(fitEmits) do
        local emit = fe.emit
        local list = byCol[colKey(emit.chan, emit.lane)]
        if list then
          for _, ppq in ipairs(list) do
            if ppq > emit.ppq then
              if emit.endppq > ppq then
                emit.endppq  = ppq
                emit.endppqL = tm:toLogical(fe.rChan, ppq)
              end
              break
            end
          end
        end
      end
    end

    for _, tok in ipairs(toDel) do deleteEvent(tok) end
    for _, e   in ipairs(toAdd) do addEvent(e)       end
    flush()

    for _, ce in ipairs(claimedEmits) do
      local u = ce.emit.uuid
      if u then
        specOf[u] = ce.node
        nodeMeta[ce.node].uuid = u
      end
    end
  end

  ----- Rebuild

  local rebuilding = false

  --contract: reentrancy-guarded; rebuilds channels[] from mm, reloads the update-manager cache, fires 'rebuild'; takeChanged forwarded to subscribers via the captured pendingTakeSwap
  function tm:rebuild(takeChanged)
    if rebuilding then return end
    rebuilding = true
    takeChanged = takeChanged or false

    clearSwing()   -- rebuild is the (cm, mm) coherence point
    specOf, nodeMeta = {}, {}

    -- 0) Aliases: materialise spec trees on root events. The helper's
    --    flush() routes through mm:modify, which fires 'reload' and
    --    re-enters rebuild; the rebuilding guard above bails on
    --    re-entry, and the outer call reads the refreshed mm state.
    materialiseAliases()

    channels = {}
    for i = 1, 16 do
      channels[i] = { chan = i, columns = { notes = {}, ccs = {} } }
    end

    -- 1) Seed defaults and truncate same-key overlaps.
    do
      local trackerMode = cm:get('trackerMode')
      local pcByChan
      if trackerMode then
        pcByChan = {}
        for _, cc in mm:ccs() do
          if cc.evType == 'pc' then
            util.bucket(pcByChan, cc.chan, { ppq = cc.ppq, val = cc.val })
          end
        end
        for _, lst in pairs(pcByChan) do sortByPPQ(lst) end
      end

      local groups, work = {}, {}
      for _, note in mm:notes() do
        local update = {}
        if note.detune == nil then update.detune = 0 end
        if note.delay  == nil then update.delay  = 0 end
        if trackerMode and note.sample == nil then
          local realisedPpq = note.ppq + delayToPPQ(note.delay or 0)
          local prev = util.seek(pcByChan[note.chan] or {}, 'at-or-before', realisedPpq)
          update.sample = (prev and prev.val) or 0
        end
        local tok = mm:tokenOf(note)
        if next(update) then mm:assign(tok, update) end
        util.bucket(groups, note.chan .. '|' .. note.pitch,
                    { token = tok, ppq = note.ppq, endppq = note.endppq })
      end
      for _, group in pairs(groups) do
        sortByPPQ(group)
        for i = 1, #group - 1 do
          if group[i].endppq > group[i + 1].ppq then
            util.add(work, { token = group[i].token, endppq = group[i + 1].ppq })
          end
        end
      end
      if #work > 0 then
        mm:modify(function()
          for _, w in ipairs(work) do mm:assign(w.token, { endppq = w.endppq }) end
        end)
      end
    end

    -- 2) Allocate note columns. Clone rather than alias: step 5 overwrites
    -- column evt.ppq with logical while mm retains raw. Lane is non-identity
    -- in the note token, so an allocator-driven lane fix doesn't retire it.
    for _, note in mm:notes() do
      local channel = channels[note.chan]
      local col, lane = allocateNoteColumn(channel, note)
      local tok = mm:tokenOf(note)
      if note.lane ~= lane then mm:assign(tok, { lane = lane }) end
      local ce = util.clone(note, { chan = true, lane = true })
      ce.token = tok
      util.add(col.events, ce)
    end

    -- 3) Single CC walk.
    do
      local pbByChan = {}
      for _, cc in mm:ccs() do
        local channel = channels[cc.chan]
        local tok     = mm:tokenOf(cc)

        if cc.evType == 'pb' then
          local col1       = channel.columns.notes[1]
          local prevailing = col1 and util.seek(col1.events, 'at-or-before', cc.ppq) or nil
          local detune     = (prevailing and prevailing.detune) or 0
          local hidden     = cc.fake and (cc.shape == nil or cc.shape == 'step')

          local pb = pbByChan[cc.chan] or { events = {}, anyVisible = false }
          pbByChan[cc.chan] = pb
          pb.anyVisible = pb.anyVisible or not hidden
          util.add(pb.events, projectCC(cc, tok, {
            val    = util.round(rawToCents(cc.val) - detune),
            detune = detune,
            hidden = hidden,
          }))

        elseif cc.evType == 'pa' then
          local noteCol = findNoteColumnForPitch(channel, cc.pitch, cc.ppq)
          if noteCol then
            util.add(noteCol.events, projectCC(cc, tok, { type = 'pa' }))
          end

        elseif cc.evType == 'cc' or cc.evType == 'at' or cc.evType == 'pc' then
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
      end

      for chan, pb in pairs(pbByChan) do
        if pb.anyVisible then
          channels[chan].columns.pb = { events = pb.events }
        end
      end
    end

    -- 4) Reconcile extras.
    do
      local extras = cm:get('extraColumns')
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
      if grew then cm:set('take', 'extraColumns', extras) end
    end

    -- 4.5) PC synthesis (trackerMode only).
    if cm:get('trackerMode') then
      local toDelete, toAdd = {}, {}
      for chan = 1, 16 do
        local records = {}
        for L, lane in ipairs(channels[chan].columns.notes) do
          for _, n in ipairs(lane.events) do
            util.add(records, { ppq = n.ppq, ppqL = n.ppqL, lane = L, sample = n.sample or 0, key = n })
          end
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

    -- 4.7) Two-frame rebuild rule + fake-pb reseating. See docs/timing.md §"Rebuild rule".
    -- Fakes are absorbers parasitic on lane-1 hosts; the walk skips them
    -- (they have no independent logical position) and reseats each onto
    -- its host's new (ppq, ppqL) in the same pass.
    do
      local EPS      = 1   -- ppq; tolerates rounding slop in fromLogical
      local toAssign = {}  -- { { evt, update } }; evt is a column event whose .token is restamped if mm:assign returns a fresh token (any ppq mutation)

      -- Index fakes by their pre-walk seat (= host's pre-walk ppq).
      local fakesByPos = {}
      local pbTouched  = {}
      for chan = 1, 16 do
        local pbCol = channels[chan].columns.pb
        if pbCol then
          for _, evt in ipairs(pbCol.events) do
            if evt.fake then
              local m = fakesByPos[chan] or {}; fakesByPos[chan] = m
              m[evt.ppq] = evt
            end
          end
        end
      end

      forEachEvent(function(_, evt, chan, isNote, _, lane)
        if evt.fake then return end
        local stale  = staleSwing[chan]
        local d      = isNote and delayToPPQ(evt.delay or 0) or 0
        local oldPpq = evt.ppq
        local update = {}
        if stale and evt.ppqL ~= nil then
          local newPpq = tm:fromLogical(chan, evt.ppqL, d)
          if newPpq ~= evt.ppq then update.ppq, evt.ppq = newPpq, newPpq end
          if isNote and evt.endppqL ~= nil then
            local newEndppq = tm:fromLogical(chan, evt.endppqL)
            if newEndppq ~= evt.endppq then
              update.endppq, evt.endppq = newEndppq, newEndppq
            end
          end
        else
          -- Onset and tail may be stale independently; check each frame
          -- against its predict and rederive only the one that disagrees.
          local predOn = evt.ppqL ~= nil
            and tm:fromLogical(chan, evt.ppqL, d) or nil
          if not predOn or math.abs(evt.ppq - predOn) > EPS then
            local newPpqL = tm:toLogical(chan, evt.ppq - d)
            update.ppqL, evt.ppqL = newPpqL, newPpqL
          end
          if isNote then
            local predEnd = evt.endppqL ~= nil
              and tm:fromLogical(chan, evt.endppqL) or nil
            if not predEnd or math.abs(evt.endppq - predEnd) > EPS then
              local newEndppqL = tm:toLogical(chan, evt.endppq)
              update.endppqL, evt.endppqL = newEndppqL, newEndppqL
            end
          end
        end
        if next(update) then
          util.add(toAssign, { evt = evt, update = update })
        end
        -- Reseat any fake-pb at this lane-1 host's seat. Stage the mm
        -- assign and mirror into the live column event in lockstep.
        if isNote and lane == 1 then
          local m    = fakesByPos[chan]
          local fake = m and m[oldPpq]
          if fake then
            local up = {}
            if fake.ppq ~= evt.ppq then
              up.ppq, fake.ppq = evt.ppq, evt.ppq
              pbTouched[chan]  = true
            end
            if fake.ppqL ~= evt.ppqL then
              up.ppqL, fake.ppqL = evt.ppqL, evt.ppqL
            end
            if next(up) then
              util.add(toAssign, { evt = fake, update = up })
            end
          end
        end
      end)
      if #toAssign > 0 then
        mm:modify(function()
          for _, a in ipairs(toAssign) do
            local newTok = mm:assign(a.evt.token, a.update)
            if newTok and newTok ~= a.evt.token then a.evt.token = newTok end
          end
        end)
        -- Tokens are stable across mm reindex by construction; the slotKey
        -- reseat that loc-form rebuilds needed is not required here. The
        -- end-of-rebuild reload() refreshes byToken, and column events
        -- already carry their post-mutation tokens.
        for chan in pairs(pbTouched) do
          sortByPPQ(channels[chan].columns.pb.events)
        end
      end
      staleSwing = {}
    end

    -- 5) Project to logical.
    do
      -- evt.ppq integer-rounded for tv:rebuild's offGrid compare; ppqL stays float so swing inverse round-trips stay exact.
      local function projectToLogical(col)
        for _, evt in ipairs(col.events) do
          if evt.ppqL    ~= nil then evt.ppq    = util.round(evt.ppqL)    end
          if evt.endppqL ~= nil then evt.endppq = util.round(evt.endppqL) end
        end
        sortByPPQ(col.events)
      end

      for _, chan in ipairs(channels) do
        local c = chan.columns
        if c.pc then projectToLogical(c.pc) end
        if c.pb then projectToLogical(c.pb) end
        for _, col in ipairs(c.notes) do projectToLogical(col) end
        if c.at then projectToLogical(c.at) end
        for _, col in pairs(c.ccs) do projectToLogical(col) end
      end
    end

    -- Project the take's used swing names into take-tier cm so seqMgr can
    -- discover affected takes via cm:readTakeKey. String entries only —
    -- anonymous composites are frozen at authoring.
    do
      local used = {}
      local g = cm:get('swing')
      if type(g) == 'string' then used[g] = true end
      for _, v in pairs(cm:get('colSwing') or {}) do
        if type(v) == 'string' then used[v] = true end
      end
      local prev = cm:get('usedSwings') or {}
      local same = true
      for k in pairs(used) do if not prev[k] then same = false; break end end
      if same then for k in pairs(prev) do if not used[k] then same = false; break end end end
      if not same then cm:set('take', 'usedSwings', used) end
    end

    reload()
    rebuilding = false
    pendingFlushUuids = nil

    --emits: rebuild  -- nil; fires once at the end of every rebuild after the update-manager cache is reloaded
    fire('rebuild', nil)
  end
end

----- Lifecycle

do
  --invariant: usedSwings is rebuild output, not input — suppressed to prevent rebuild's cm:set from firing a redundant follow-up rebuild
  local tvOnlyKeys = { mutedChannels = true, soloedChannels = true, usedSwings = true, regions = true }

  --invariant: configChanged routes: 'swing' → all 16; 'colSwing' → channels with diff vs prevColSwing; 'swings' → channels resolving to names with diff body vs prevSwings. Caches refresh after each event and on bindTake.
  local prevSwings   = util.deepClone(cm:get('swings')   or {})
  local prevColSwing = util.deepClone(cm:get('colSwing') or {})

  local function snapshotSwingState()
    prevSwings   = util.deepClone(cm:get('swings')   or {})
    prevColSwing = util.deepClone(cm:get('colSwing') or {})
  end

  local function colSwingDiffChannels(prev, cur)
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

  -- Global swing shadows colSwing: a hit on the global name affects all 16.
  local function channelsResolvingTo(names)
    local affected = {}
    if not next(names) then return affected end
    if names[cm:get('swing')] then
      for chan = 1, 16 do affected[chan] = true end
      return affected
    end
    local cs = cm:get('colSwing') or {}
    for chan = 1, 16 do
      if names[cs[chan]] then affected[chan] = true end
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
  cm:subscribe('configChanged', function(change)
    if bindingTake then return end
    local key = change.key
    if key == 'swing' then
      tm:markSwingStale(nil)
    elseif key == 'colSwing' then
      for chan in pairs(colSwingDiffChannels(prevColSwing, cm:get('colSwing'))) do
        tm:markSwingStale(chan)
      end
      prevColSwing = util.deepClone(cm:get('colSwing') or {})
    elseif key == 'swings' then
      for chan in pairs(channelsResolvingTo(changedSwingNames(prevSwings, cm:get('swings')))) do
        tm:markSwingStale(chan)
      end
      prevSwings = util.deepClone(cm:get('swings') or {})
    end
    if not tvOnlyKeys[key] then tm:rebuild(false) end
  end)

  --contract: atomic take swap: cm:setContext runs silently; mm:load fires the single coherent rebuild. opts.markSwingStale=true rebuilds raw from ppqL under the new (cm, mm) pair (used by seqMgr:reswingAll).
  --contract: bindTake(nil) is the dormant seam (e.g. samplePage); cm clears under suppression, mm:load(nil) is a no-op, tm/tv retain last frame.
  function tm:bindTake(take, opts)
    bindingTake = true
    cm:setContext(take)
    bindingTake = false
    if opts and opts.markSwingStale then
      for i = 1, 16 do staleSwing[i] = true end
    end
    mm:load(take)
    snapshotSwingState()
  end

  function tm:currentTake() return mm and mm:take() end
end

tm:rebuild(true)
return tm
