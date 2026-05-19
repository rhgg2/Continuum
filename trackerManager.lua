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

local function print(...)
  return util.print(...)
end

local mm, cm = (...).mm, (...).cm

local tm = {}
local fire = util.installHooks(tm)

---------- STATE

local channels    = {}
local lastMuteSet = {}
--invariant: staleSwing[chan]=true: this channel's resolved swing changed; rebuild rule rederives raw from ppqL and clears
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
  local byUuid  = {}
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
    local et = evt.evType
    if     et == 'note' then deleteNote(evt)
    elseif et == 'pb'   then deletePb(evt)
    else                     deleteLowlevel(evt) end
  end

  --contract: update.ppq/endppq arrive logical; stamps ppqL, and stamps endppqL from the note-off only when the caller omitted it. A caller-supplied endppqL is authoritative: a finite ceiling, or util.OPEN to reopen an unbounded tail. update.rawTime=true is the explicit "caller already computed raw" bypass (reswing/rescale's plan-then-mutate): translation is skipped, only the delay-delta applies, and the flag is consumed here so it never reaches mm. ppqL/endppqL are intent stamps, NOT the bypass signal — a logical caller (groups) sets endppqL freely. See docs/timing.md.
  local function realiseNoteUpdate(evt, update)
    local dOld = delayToPPQ(evt.delay)
    local dNew = delayToPPQ(update.delay ~= nil and update.delay or evt.delay)
    if update.rawTime then
      update.rawTime = nil
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
    if update.endppq ~= nil then
      -- endppq arrives logical. Stamp the ceiling from this note-off
      -- only when the caller didn't author one: a finite endppqL, or
      -- util.OPEN to reopen, is authoritative and rides through (the
      -- provisional raw note-off is still derived below).
      if update.endppqL == nil then update.endppqL = update.endppq end
      update.endppq = tm:fromLogical(evt.chan, update.endppq)
    end
  end

  local function realiseNonNoteUpdate(chan, update)
    if update.rawTime then update.rawTime = nil; return end
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
      -- Stamp the ceiling from the note-off only when the caller didn't
      -- author one. A supplied endppqL is authoritative and survives:
      -- a finite intent carried through a clone (the re-author paths —
      -- shiftEvents, paste, gm), or util.OPEN for a freshly-placed
      -- unbounded note. The raw note-off is still derived.
      if evt.endppqL == nil then evt.endppqL = evt.endppq end
      evt.endppq = tm:fromLogical(evt.chan, evt.endppq)
    end
  end

  function assignEvent(evtOrToken, update)
    local evt = lookup(evtOrToken)
    if not evt then return end
    local et = evt.evType
    if et == 'note' then
      realiseNoteUpdate(evt, update)
      assignNote(evt, update)
    elseif et == 'pb' then
      realiseNonNoteUpdate(evt.chan, update)
      assignPb(evt, update)
    else
      realiseNonNoteUpdate(evt.chan, update)
      assignLowlevel(evt, update)
    end
  end

  --contract: notes default detune=0, delay=0, lane=1; evt.ppq/endppq arrive logical; stamps ppqL, stamps endppqL from the note-off only when the caller omitted it (a supplied endppqL — finite, or util.OPEN — is authoritative), rewrites ppq/endppq to raw before mm. evt.rawTime=true is the explicit "caller already computed raw" bypass (mirrors assignEvent); consumed here so it never persists on the record or reaches mm.
  function addEvent(evt)
    local rawCaller = evt.rawTime
    evt.rawTime = nil
    if evt.evType == 'note' then
      evt.detune = evt.detune or 0
      evt.delay  = evt.delay  or 0
      evt.lane   = evt.lane   or 1
      if not rawCaller then realiseAddPpq(evt, true, true) end
      addNote(evt)
    else
      if not rawCaller then realiseAddPpq(evt, false, false) end
      if evt.evType == 'pb' then addPb(evt) else addLowlevel(evt) end
    end
  end

  ----- Flush: commit accumulated ops to mm.

  --contract: no-op if nothing staged; otherwise commits assigns then deletes then adds under one mm:modify; pb cents→raw conversion happens here; byToken is re-keyed live from mm:assign's returned token whenever an identity field moved
  --contract: snapshots adds/assigns/deletes before mm:modify so re-entry from mm callbacks (e.g. setMutedChannels via rebuild) cannot re-emit in-flight ops
  --emits: preflush -- (adds, assigns, deletes); fired first, before the no-op check, so a subscriber (gm) can stage peer ops into the same lists and ride the one mm:modify
  --emits: postflush -- nil; fired after mm:modify so a subscriber can read the uuids mm just stamped onto staged add events
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
        if n.evType == 'note' then util.bucket(byKey, n.chan .. '|' .. n.pitch, n) end
      end
      for _, o in ipairs(adds) do
        if o.evt.evType == 'note' then util.bucket(byKey, o.evt.chan .. '|' .. o.evt.pitch, o.evt) end
      end

      local clips, kills = {}, {}
      for _, group in pairs(byKey) do
        -- Coincident-onset dedup: keep the longest, drop the rest
        -- (mm's note-dedup rule). Outcome-deterministic — equal-length
        -- duplicates are geometrically identical.
        local longestAt = {}
        for _, n in ipairs(group) do
          local kept = longestAt[n.ppq]
          if not kept then
            longestAt[n.ppq] = n
          elseif n.endppq > kept.endppq then
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

----- Rebuild

do
  ----- Column allocation

  local function pushNoteCol(channel)
    local notes = channel.columns.notes
    return util.add(notes, { events = {} }), #notes
  end

  --contract: true iff note fits col -- no over-threshold overlap (same-pitch: zero tolerance; cross-pitch: overlapOffset lenient), coincident onset always refuses, dominated-by->=2 refuses. Only consulted for unstamped raw notes (stamped notes never reach it).
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

  --contract: a stamped note (ppqL ~= nil) is model-governed -- the universal tail pass clips its realised note-off to its lane neighbour so it cannot overlap; its authored lane is returned verbatim, extending notes[] if absent. Only an unstamped raw note (ppqL == nil: foreign-MIDI import) runs the accept -> sibling-search -> push bump path.
  local function allocateNoteColumn(channel, note)
    local notes = channel.columns.notes
    if note.ppqL ~= nil then
      local lane = note.lane or 1
      while #notes < lane do pushNoteCol(channel) end
      return notes[lane], lane
    end
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

  --contract: reentrancy-guarded; rebuilds channels[] from mm, reloads the update-manager cache, fires 'rebuild'; takeChanged forwarded to subscribers via the captured pendingTakeSwap
  function tm:rebuild(takeChanged)
    if rebuilding then return end
    rebuilding = true
    takeChanged = takeChanged or false

    clearSwing()   -- rebuild is the (cm, mm) coherence point
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

      -- byLane drives the universal tail-realisation pass; byPitch is
      -- its same-(chan,pitch) physics input. Runs BEFORE column
      -- allocation so the allocator sees the realised (short) raw tail
      -- and doesn't bump a would-be lane blocker out of the lane.
      local byPitch, byLane, work = {}, {}, {}
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
        -- A stale logical frame is no logical frame. On a NON-stale
        -- channel a raw onset that disagrees with ppqL is an external/
        -- legacy edit: raw is the truth, the cached ppqL/endppqL are
        -- garbage. Drop them so every tail-pass fallback (onsetL,
        -- ceilingL, laterL) reads raw; the rebuild rule recaches the
        -- real logical frame right after. (A staleSwing channel is the
        -- opposite — ppqL is authoritative there, raw the stale one —
        -- so it is excluded.)
        local frameStale = not staleSwing[note.chan]
          and note.ppqL ~= nil
          and math.abs(note.ppq - tm:fromLogical(note.chan, note.ppqL,
                delayToPPQ(note.delay or 0))) > EPS
        local e = { token = tok, chan = note.chan, pitch = note.pitch,
                    ppq = note.ppq, endppq = note.endppq,
                    ppqL    = not frameStale and note.ppqL or nil,
                    endppqL = not frameStale and note.endppqL or nil,
                    overlap = note.overlap }
        util.bucket(byPitch, note.chan .. '|' .. note.pitch, e)
        util.bucket(byLane,  note.chan .. '|' .. (note.lane or 1), e)
      end
      for _, g in pairs(byPitch) do sortByPPQ(g) end
      for _, g in pairs(byLane)  do sortByPPQ(g) end

      -- Logical onset; ppqL is not yet reconciled at this pre-allocation
      -- phase for raw-arrived notes, so fall back to toLogical.
      local function onsetL(x) return x.ppqL or tm:toLogical(x.chan, x.ppq) end
      -- Logical onset of the first strictly-later note in a ppq-sorted
      -- group (chords at the same onset are not "following").
      local function laterL(group, ppq)
        local n = util.seek(group, 'after', ppq)
        return n and onsetL(n)
      end

      -- Universal tail realisation. raw note-off = min(endppqL ceiling
      -- (util.OPEN = unbounded; nil = uncached, derive from raw), next
      -- same-lane onset + overlap, next same-pitch chan-wide onset,
      -- take length), floored at onset+1.
      -- overlap widens only the column onset (the monophonic-legato
      -- glide); the same-pitch onset is hard MIDI physics and the take
      -- length the absolute backstop. endppqL is never touched —
      -- deleting a blocker grows the raw tail back up to the ceiling.
      local takeLenL = tm:length()
      for _, group in pairs(byLane) do
        for _, e in ipairs(group) do
          local laneL    = laterL(group, e.ppq)
          local pitchL   = laterL(byPitch[e.chan .. '|' .. e.pitch], e.ppq)
          -- endppqL == util.OPEN is the deliberately-unbounded tail
          -- (freshly-placed legato note). Absent endppqL is an uncached
          -- ceiling, not open — derive it from raw.
          local ceilingL = e.endppqL == util.OPEN and math.huge
                           or e.endppqL or tm:toLogical(e.chan, e.endppq)
          local colL     = laneL and laneL + (e.overlap or 0) or math.huge
          local boundL   = math.max(onsetL(e) + 1,
            math.min(ceilingL, colL, pitchL or math.huge, takeLenL))
          local raw      = util.round(tm:fromLogical(e.chan, boundL))
          if raw ~= e.endppq then
            util.add(work, { token = e.token, endppq = raw })
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
      if grew and mm:take() then cm:set('take', 'extraColumns', extras) end
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
          -- raw endppq is owned by the tail-realisation pass, never
          -- reseated from endppqL (which is intent, kept long).
        else
          -- Onset and tail may be stale independently; check each frame
          -- against its predict and rederive only the one that disagrees.
          local predOn = evt.ppqL ~= nil
            and tm:fromLogical(chan, evt.ppqL, d) or nil
          local onsetExternal = not predOn
            or math.abs(evt.ppq - predOn) > EPS
          if onsetExternal then
            local newPpqL = tm:toLogical(chan, evt.ppq - d)
            update.ppqL, evt.ppqL = newPpqL, newPpqL
          end
          -- endppqL is intent: in steady state raw is the tail pass's
          -- clipped projection of it, so never back-derive it from raw.
          -- Two cases mean "raw is the truth here, not a clip": an
          -- absent ceiling on an external raw note (cache it once), and
          -- a disagreeing onset (the whole record was externally edited
          -- — ppqL just followed raw, so endppqL must too). Never on a
          -- util.OPEN note (unbounded by definition).
          if isNote and evt.endppqL ~= util.OPEN
             and (evt.endppqL == nil or onsetExternal) then
            local seed = tm:toLogical(chan, evt.endppq)
            update.endppqL, evt.endppqL = seed, seed
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
      -- evt.ppq integer-rounded for tv:rebuild's offGrid compare; ppqL
      -- stays float so swing inverse round-trips stay exact. raw endppq
      -- is the tail pass's clipped realisation, NOT reseated from
      -- endppqL here — endppqL is intent (kept long); the note-off the
      -- user sees is the clipped value the tail pass wrote.
      local function projectToLogical(col)
        for _, evt in ipairs(col.events) do
          if evt.ppqL ~= nil then evt.ppq = util.round(evt.ppqL) end
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
    -- anonymous composites are frozen at authoring. No-op when no take is
    -- bound: usedSwings is take-scoped and global tiers can still resolve
    -- a non-empty `swing` here (e.g. samplePage's setTrack-induced rebuild).
    if mm:take() then
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

    --emits: rebuild  -- takeChanged:boolean; fires once at the end of every rebuild after the update-manager cache is reloaded. True only when this rebuild followed a take swap (bindTake), so a subscriber can reload take-tier state.
    fire('rebuild', takeChanged)
  end
end

----- Lifecycle

do
  --invariant: usedSwings is rebuild output, not input — suppressed to prevent rebuild's cm:set from firing a redundant follow-up rebuild
  local tvOnlyKeys = { mutedChannels = true, soloedChannels = true, usedSwings = true }

  --invariant: configChanged routes: 'swing' → all 16; 'colSwing' → channels with diff vs prevColSwing; 'swings' → channels resolving to names with diff body vs prevSwings. Caches refresh after each event and on bindTake.
  -- Merged-tier read: a save at any tier (project, global) lands in the
  -- same merged view, so diff captures real change to the composite a
  -- channel will resolve to.
  local function readSwings() return cm:get('swings', { mergeTiers = true }) end
  local prevSwings   = util.deepClone(readSwings())
  local prevColSwing = util.deepClone(cm:get('colSwing') or {})

  local function snapshotSwingState()
    prevSwings   = util.deepClone(readSwings())
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
      local curSwings = readSwings()
      for chan in pairs(channelsResolvingTo(changedSwingNames(prevSwings, curSwings))) do
        tm:markSwingStale(chan)
      end
      prevSwings = util.deepClone(curSwings)
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

  --contract: re-reads the bound take from REAPER. Used by the coord-owned external-mutation watcher (e.g. user hit Ctrl-Z, an external script wrote the take). mm:reload fires the standard reload→rebuild chain; no take swap.
  function tm:reloadFromReaper() if mm then mm:reload() end end
end

tm:rebuild(true)
return tm
