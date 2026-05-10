-- See docs/trackerManager.md for the model.

--@map:invariant tm exposes intent frame; mm holds realisation frame; um works in realisation and shifts to intent at rebuild's tail (tidyCol)
--@map:invariant detune is intent (per-note); pb is realisation (channel-wide stream); only lane-1 notes drive detune realisation
--@map:invariant pb.val is cents inside um; raw conversion happens only on load (rawToCents) and at flush (centsToRaw); cents window is cm:get('pbRange') * 100 per side
--@map:invariant fake pbs are absorbers seated at lane-1 note onsets to absorb detune jumps; pb.fake is the sole marker (persisted as cc metadata via mm sidecar)
--@map:invariant pa events store pitch-aftertouch value in mm cc.val but are projected to col.events as { type='pa', vel } with val stripped via util.REMOVE
--@map:invariant loc values are valid only within a single rebuild-to-flush window; um's notesByLoc/ccsByLoc are rebuilt fresh each rebuild
--@map:invariant column events are sorted by intent ppq; endppq is intent at every layer (delay shifts only the note-on)
--@map:invariant 16 channels always present; channels[i] non-nil for i in 1..16 after rebuild

loadModule('util')
loadModule('midiManager')
loadModule('timing')
loadModule('aliases')

local function print(...)
  return util.print(...)
end

--@map:contract pure; no mm/cm reads; emitted PCs carry fake=true so flush/rebuild can distinguish synthesised from user-authored
--@map:contract emitted PCs inherit ppqL from the winning host-note record so the synthesised stream carries logical truth alongside raw ppq
local function synthesisePCs(chan, records)
  local winners, order, shadowed = {}, {}, {}
  for _, r in ipairs(records) do
    local w = winners[r.ppq]
    if not w then
      winners[r.ppq] = r
      util.add(order, r.ppq)
    elseif r.lane < w.lane then
      shadowed[w.key] = true
      winners[r.ppq] = r
    else
      shadowed[r.key] = true
    end
  end
  table.sort(order)
  local pcs = {}
  for _, ppq in ipairs(order) do
    local w = winners[ppq]
    util.add(pcs, { ppq = ppq, ppqL = w.ppqL, val = w.sample,
                    msgType = 'pc', chan = chan, fake = true })
  end
  return pcs, shadowed
end

--@map:contract returns (desired, shadowed, toRemove, toAdd); desired carries .loc on entries that survived the diff
local function reconcilePCsForChan(chan, records, existing)
  local desired, shadowed = synthesisePCs(chan, records)
  local byPpq = {}
  for _, e in ipairs(existing) do byPpq[e.ppq] = e end
  for _, want in ipairs(desired) do
    local have = byPpq[want.ppq]
    if have and have.val == want.val and have.fake then
      want.loc = have.loc
      byPpq[want.ppq] = nil
    end
  end
  local toRemove, toAdd = {}, {}
  for _, have in ipairs(existing) do
    if byPpq[have.ppq] then util.add(toRemove, have) end
  end
  for _, want in ipairs(desired) do
    if not want.loc then util.add(toAdd, want) end
  end
  return desired, shadowed, toRemove, toAdd
end

----- Aliases walker helpers

local function evtTypeOf(evt) return evt.msgType and 'cc' or 'note' end

local function slotKey(evt)
  if evt.msgType then
    return 'cc|c=' .. evt.chan .. '|m=' .. evt.msgType
        .. '|i=' .. (evt.cc or evt.pitch or '') .. '|t=' .. evt.ppq
  end
  return 'note|c=' .. evt.chan .. '|p=' .. evt.pitch .. '|t=' .. evt.ppq
end

local SEED_EXCLUDE = {
  aliases = true, aliasCtr = true,
  uuid = true, parentUuid = true, specPath = true,
  loc = true,
}

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

--@map:shape channel = { chan=1..16, columns = { notes=[col,...], ccs={[ccNum]=col,...}, pc=col|nil, pb=col|nil, at=col|nil } }
--@map:shape column = { events=[evt,...], [cc=ccNum] }  -- events sorted by intent ppq
--@map:shape noteEvent = { ppq, endppq, pitch, vel, lane, detune, delay, [muted], [sample], [sampleShadowed], loc, [<metadata...>] }
--@map:shape pbEventCol = { ppq, val=cents-minus-detune, detune, hidden, [delay], [shape], [tension], loc, ... }  -- column projection; um cache holds raw cents in val
--@map:shape paEventCol = { type='pa', ppq, pitch, vel, loc, ... }  -- mixed into note column events
--@map:shape extraColumns[chan] = { notes=count, [pc=true], [pb=true], [at=true], [ccs={[ccNum]=true}] }
function newTrackerManager(mm, cm)

  ---------- PRIVATE

  local channels = {}
  local tm    -- forward-declared so um's closures (built in createUpdateManager, defined above tm's body) capture it as upvalue; assigned below
  local fire  -- installed below, once tm exists
  local um    -- update manager; set by tm:rebuild
  local lastMuteSet = {}  -- { [chan] = true }, pushed by vm via tm:setMutedChannels
  --@map:invariant pendingFlushUuids is a uuid-set of notes touched by the in-flight um:flush; populated before mm:modify (assigns) and grown inside it (adds), read by allocateNoteColumn during the rebuild that fires from mm's reload, cleared at the tail of tm:rebuild — nil outside a flush-driven rebuild
  local pendingFlushUuids
  --@map:invariant staleSwing[chan] = true marks a channel whose resolved swing has changed since last rebuild; consumed and cleared by the rebuild rule (step 4.7) which then rederives raw ppq/endppq from each event's ppqL/endppqL
  local staleSwing = {}

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

  ----- Update manager

  local function createUpdateManager()
    local adds = {}
    local assigns = {}
    local deletes = {}
    local chans = {}
    local notesByLoc = {}
    local dirtyPcChans = {}
    local ccsByLoc = {}

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

    --@map:contract logical = raw − detune; this is the "user heard pitch" frame, decoupled from the absorber bookkeeping
    local function logicalAt(chan, P)
      return rawAt(chan, P) - detuneAt(chan, P)
    end

    local function logicalBefore(chan, P)
      return rawBefore(chan, P) - detuneBefore(chan, P)
    end

    local function nextLogicalChange(chan, P)
      local currentLogical = logicalAt(chan, P)
      local pb = util.seek(chans[chan].pbs, 'after', P, function(e) return logicalAt(chan, e.ppq) ~= currentLogical end)
      return (pb and pb.ppq) or math.huge
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
      for _, cc in pairs(ccsByLoc) do
        if cc.msgType == 'pa' and cc.chan == host.chan and cc.pitch == host.pitch
          and cc.ppq >= host.ppq and cc.ppq < host.endppq then
          fn(cc)
        end
      end
    end

    ----- Low-level mutation

    --@map:contract only lane==1 notes index into chans[chan].notes; higher-lane notes get queued for mm but don't feed detune/realisation reads
    local function addLowlevel(evtType, evt)
      if evtType == 'note' then
        local col1 = evt.lane == 1
        if col1 then
          local tbl = chans[evt.chan].notes
          util.add(tbl, evt)
          sortByPPQ(tbl)
        end
      elseif evtType == 'pb' then
        local tbl = chans[evt.chan].pbs
        evt.msgType = 'pb'
        util.add(tbl, evt)
        sortByPPQ(tbl)
      else
        evt.msgType = evtType
      end
      util.add(adds, { type = evtType, evt = evt })
    end

    --@map:contract dedupes by (loc, evtType) so multiple in-flight assigns to the same event collapse into one mm write; util.REMOVE markers must survive merging
    local function assignLowlevel(evtType, evt, update)
      util.assign(evt, update)
      -- ppq mutates in place; resort so subsequent util.seek calls keyed off chans[chan].notes stay correct under non-monotone callers (reswing).
      if evtType == 'note' and update.ppq ~= nil and evt.lane == 1 then
        sortByPPQ(chans[evt.chan].notes)
      end
      if not evt.loc then return end
      for _, e in ipairs(assigns) do
        if e.loc == evt.loc and e.type == evtType then
          -- Plain copy, not util.assign: util.assign collapses util.REMOVE → nil-the-key.
          for k, v in pairs(update) do e.update[k] = v end
          return
        end
      end
      util.add(assigns, { type = evtType, loc = evt.loc, update = update })
    end

    local function deleteLowlevel(evtType, evt)
      local tbl
      local locTbl = ccsByLoc
      if evtType == 'note' then
        tbl = chans[evt.chan].notes
        locTbl = notesByLoc
      elseif evtType == 'pb' then
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

      local loc = evt.loc

      if loc then
        locTbl[loc] = nil
        util.add(deletes, { type = evtType, loc = loc })
        for j = #assigns, 1, -1 do
          local e = assigns[j]
          if e.loc == loc and e.type == evtType then table.remove(assigns, j) end
        end
      else
        for j = #adds, 1, -1 do
          if adds[j].evt == evt then table.remove(adds, j); break end
        end
      end
    end

    --@map:contract shifts every pb's raw val by delta over [P1, P2); preserves logical stream above by definition since detune absorbs delta
    local function retuneLowlevel(chan, P1, P2, delta)
      if delta == 0 then return end
      for _, pb in ipairs(chans[chan].pbs) do
        if pb.ppq >= P1 and pb.ppq < P2 then
          assignLowlevel('pb', pb, { val = pb.val + delta })
        end
      end
    end

    --@map:contract no-op (returns false) if a pb already sits at P; otherwise seats one at the carrier value (rawAt) so logical stream is preserved
    local function forcePb(chan, P, extras)
      if pbAt(chan, P) then return false end
      addLowlevel('pb', util.assign({ ppq = P, chan = chan, val = rawAt(chan, P) }, extras))
      return true
    end

    local function markFake(chan, P)
      local pb = pbAt(chan, P)
      if pb then assignLowlevel('pb', pb, { fake = true }) end
    end

    local function unmarkFake(chan, P)
      local pb = pbAt(chan, P)
      if not (pb and pb.fake) then return end
      assignLowlevel('pb', pb, { fake = util.REMOVE })
    end

    -- Callers invoke post-mutation (note edits committed) so detuneAt/Before see live values.
    local function reconcileBoundary(chan, P)
      if P >= math.huge then return end
      local D, C = detuneAt(chan, P), detuneBefore(chan, P)
      local pb   = pbAt(chan, P)
      if D == C then
        if pb and pb.fake and rawAt(chan, P) == rawBefore(chan, P) then
          deleteLowlevel('pb', pb)
        end
      elseif not pb then
        forcePb(chan, P)               -- val = rawAt = rawBefore (no pb yet)
        markFake(chan, P)
        pb = pbAt(chan, P)
        assignLowlevel('pb', pb, { val = pb.val + (D - C) })
      end
    end

    ----- High-level ops

    --@map:contract authoring frame is logical (pb.val is logical cents); seats/updates the carrier and retunes forward to next real pb so logical above is preserved
    local function addPb(pb)
      local chan, P, L = pb.chan, pb.ppq, pb.val or 0
      local delta  = L - logicalAt(chan, P)
      -- chan/ppq/val belong to forcePb's structural set; msgType is stamped by addLowlevel.
      local extras = util.clone(pb,
        { chan = true, ppq = true, val = true, msgType = true })
      if not next(extras) then extras = nil end
      if not forcePb(chan, P, extras) then
        if extras then assignLowlevel('pb', pbAt(chan, P), extras) end
        unmarkFake(chan, P)
      end
      retuneLowlevel(chan, P, nextRealChange(chan, P), delta)
    end

    --@map:contract retunes forward to undo pb's logical contribution; collapses to a real delete only if the seat would also be redundant as a fake (detuneAt == detuneBefore)
    local function deletePb(pb)
      local chan, P = pb.chan, pb.ppq
      retuneLowlevel(chan, P, nextRealChange(chan, P), logicalBefore(chan, P) - logicalAt(chan, P))
      if detuneAt(chan, P) == detuneBefore(chan, P) then
        deleteLowlevel('pb', pb)
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
          local extras = util.clone(pb, { loc = true, fake = true,
                                           chan = true, ppq = true, val = true,
                                           msgType = true })
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
        assignLowlevel('pb', pb, moveUpdate)
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
      if next(rest) then assignLowlevel('pb', pb, rest) end
    end

    local function dirtyPc(chan) dirtyPcChans[chan] = true end

    --@map:contract lane-1 path: seat fake-pb if detune jumps the carry, retune forward to next note, then reconcile the next-note boundary; lane>1 just queues with no realisation work
    local function addNote(n)
      dirtyPc(n.chan)
      local D = n.detune
      if lastMuteSet[n.chan] then n.muted = true end
      if n.lane == 1 then
        local C     = detuneAt(n.chan, n.ppq)
        local nextP = nextNotePPQ(n.chan, n.ppq)
        if D ~= C and forcePb(n.chan, n.ppq) then markFake(n.chan, n.ppq) end
        retuneLowlevel(n.chan, n.ppq, nextP, D - C)
        addLowlevel('note', util.assign(n, { detune = D }))
        reconcileBoundary(n.chan, nextP)
      else
        addLowlevel('note', util.assign(n, { detune = D }))
      end
    end

    --@map:contract attached PAs are deleted with the host unless keepPAs; lane-1 path drops any fake seat at n.ppq and retunes back to the prior detune over [n.ppq, nextNote)
    local function deleteNote(n, keepPAs)
      dirtyPc(n.chan)
      if not keepPAs then forEachAttachedPA(n, function(evt) deleteLowlevel('pa', evt) end) end
      if n.lane ~= 1 then deleteLowlevel('note', n); return end
      local D1, D2 = detuneBefore(n.chan, n.ppq), detuneAt(n.chan, n.ppq)
      local nextP  = nextNotePPQ(n.chan, n.ppq)
      local pb     = pbAt(n.chan, n.ppq)
      if pb and pb.fake then deleteLowlevel('pb', pb) end
      deleteLowlevel('note', n)
      retuneLowlevel(n.chan, n.ppq, nextP, D1 - D2)
      reconcileBoundary(n.chan, nextP)
    end

    local function resizeNote(n, P1, P2)
      local col1  = n.lane == 1
      local shift = P1 - n.ppq
      if shift ~= 0 and P2 - n.endppq == shift then
        forEachAttachedPA(n, function(evt)
          assignLowlevel('pa', evt, { ppq = evt.ppq + shift })
        end)
      else
        local lastPA
        forEachAttachedPA(n, function(evt)
          if evt.ppq <= P1 or evt.ppq >= P2 then
            if evt.ppq <= P1 and (not lastPA or evt.ppq > lastPA.ppq) then lastPA = evt end
            deleteLowlevel('pa', evt)
          end
        end)
        if lastPA then assignLowlevel('note', n, { vel = lastPA.val }) end
      end

      if not col1 then
        assignLowlevel('note', n, { ppq = P1, endppq = P2 })
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

      assignLowlevel('note', n, { ppq = P1, endppq = P2 })

      if oldPb and oldPb.fake then
        deleteLowlevel('pb', oldPb)
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

    --@map:contract chan/lane updates are rejected with a warning; ppq/endppq route through resizeNote; detune updates retune forward and reconcile both endpoint boundaries
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
        forEachAttachedPA(n, function(e) assignLowlevel('pa', e, { pitch = update.pitch }) end)
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
        assignLowlevel('note', n, { detune = update.detune })
        update.detune = nil
        reconcileBoundary(n.chan, n.ppq)
        reconcileBoundary(n.chan, nextP)
      end
      if next(update) then assignLowlevel('note', n, update) end
    end

    -- Returns (clampEnd, clampEndL): the realised intent end and its logical
    -- counterpart. Truncated peers are stamped with endppqL = selfPpqL so
    -- the canonical logical frame stays coherent with endppq.
    local function clearSameKeyRange(chan, pitch, P, Pend, selfPpqL, selfEvt)
      local clampEnd, clampEndL = Pend, nil
      local toDelete, toTruncate = {}, {}
      for _, n in pairs(notesByLoc) do
        if n ~= selfEvt and n.chan == chan and n.pitch == pitch then
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
      local c = channels[chan].columns
      local laneByLoc = {}
      for _, lane in ipairs(c.notes) do
        for _, evt in ipairs(lane.events) do
          evt.sampleShadowed = nil
          laneByLoc[evt.loc] = evt
        end
      end

      local records = {}
      for _, n in pairs(notesByLoc) do
        if n.chan == chan then
          util.add(records, { ppq = n.ppq, ppqL = n.ppqL, lane = n.lane,
                              sample = n.sample or 0, key = laneByLoc[n.loc] or n })
        end
      end
      for _, a in ipairs(adds) do
        if a.type == 'note' and a.evt.chan == chan then
          local n = a.evt
          util.add(records, { ppq = n.ppq, ppqL = n.ppqL, lane = n.lane,
                              sample = n.sample or 0, key = n })
        end
      end

      local desired, shadowed, toRemove, toAdd =
        reconcilePCsForChan(chan, records, (c.pc and c.pc.events) or {})
      for evt in pairs(shadowed) do evt.sampleShadowed = true end
      for _, have in ipairs(toRemove) do deleteLowlevel('pc', have) end
      for _, want in ipairs(toAdd)    do addLowlevel('pc', want)    end
      c.pc = { events = desired }
    end

    ----- Public interface

    local um = {}

    function um:deleteEvent(evtType, evtOrLoc)
      local loc = type(evtOrLoc) == 'table' and evtOrLoc.loc or evtOrLoc
      if not loc then return end
      local evt = evtType == 'note' and notesByLoc[loc] or ccsByLoc[loc]

      if evtType == 'note' then
        if evt then deleteNote(evt) end
      elseif evtType == 'pb' then
        if evt then deletePb(evt) end
      else
        deleteLowlevel(evtType, evt or { loc = loc })
      end
    end

    -- update.ppq and update.endppq speak the logical frame above tm;
    -- raw is derived as fromLogical(chan, ppq) + delay. We stamp
    -- update.ppqL/endppqL with the logical truth and overwrite
    -- update.ppq/endppq with raw, so mm receives both frames.
    --
    -- trustGeometry callers (reswing) already speak raw and opt out
    -- of translation; they continue to provide ppqL/endppqL alongside.
    local function realiseNoteUpdate(evt, update, opts)
      local dOld = delayToPPQ(evt.delay)
      local dNew = delayToPPQ(update.delay ~= nil and update.delay or evt.delay)
      if update.ppq == nil and update.endppq == nil and dNew == dOld then return end
      if opts and opts.trustGeometry then
        if update.ppq ~= nil then
          update.ppq = update.ppq + dNew
        elseif dNew ~= dOld then
          update.ppq = evt.ppq + (dNew - dOld)
        end
        return
      end
      local snap
      local function getSnap()
        snap = snap or tm:swingSnapshot(); return snap
      end
      if update.ppq ~= nil then
        update.ppqL = update.ppq
        update.ppq  = util.round(getSnap().fromLogical(evt.chan, update.ppqL)) + dNew
      elseif evt.ppqL ~= nil then
        update.ppq = util.round(getSnap().fromLogical(evt.chan, evt.ppqL)) + dNew
      else
        update.ppq = evt.ppq + (dNew - dOld)
      end
      if update.endppq ~= nil then
        update.endppqL = update.endppq
        update.endppq  = util.round(getSnap().fromLogical(evt.chan, update.endppqL))
      end
    end

    -- Non-note writes: update.ppq is logical; stamp ppqL alongside
    -- and overwrite ppq with raw before mm sees it.
    local function realiseNonNoteUpdate(chan, update, opts)
      if opts and opts.trustGeometry then return end
      if not chan or update.ppq == nil then return end
      update.ppqL = update.ppq
      update.ppq  = util.round(tm:swingSnapshot().fromLogical(chan, update.ppqL))
    end

    function um:assignEvent(evtType, evtOrLoc, update, opts)
      local loc = type(evtOrLoc) == 'table' and evtOrLoc.loc or evtOrLoc
      if not loc then return end
      local evt = evtType == 'note' and notesByLoc[loc] or ccsByLoc[loc]

      if evtType == 'note' then
        if evt then
          realiseNoteUpdate(evt, update, opts)
          if not (opts and opts.trustGeometry)
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
        end
      elseif evtType == 'pb' then
        if evt then
          realiseNonNoteUpdate(evt.chan, update, opts)
          assignPb(evt, update)
        end
      else
        realiseNonNoteUpdate(evt and evt.chan, update, opts)
        assignLowlevel(evtType, evt or { loc = loc }, update)
      end
    end

    --@map:contract notes default detune=0, delay=0, lane=1; evt.ppq and evt.endppq arrive in the logical frame; um stamps ppqL/endppqL with the logical truth and rewrites ppq/endppq to raw (fromLogical + delay) before mm sees the record
    function um:addEvent(evtType, evt)
      if evtType == 'note' then
        evt.detune = evt.detune or 0
        evt.delay  = evt.delay  or 0
        evt.lane   = evt.lane   or 1
        if evt.ppq ~= nil and evt.chan then
          local snap = tm:swingSnapshot()
          evt.ppqL = evt.ppq
          evt.ppq  = util.round(snap.fromLogical(evt.chan, evt.ppqL)) + delayToPPQ(evt.delay)
          if evt.endppq ~= nil then
            evt.endppqL = evt.endppq
            evt.endppq  = util.round(snap.fromLogical(evt.chan, evt.endppqL))
          end
        end
        local clamped, clampedL =
          clearSameKeyRange(evt.chan, evt.pitch, evt.ppq, evt.endppq, evt.ppqL, evt)
        evt.endppq = clamped
        if clampedL then evt.endppqL = clampedL end
        addNote(evt)
      elseif evtType == 'pb' then
        if evt.ppq ~= nil and evt.chan then
          evt.ppqL = evt.ppq
          evt.ppq  = util.round(tm:swingSnapshot().fromLogical(evt.chan, evt.ppqL))
        end
        addPb(evt)
      else
        if evt.ppq ~= nil and evt.chan then
          evt.ppqL = evt.ppq
          evt.ppq  = util.round(tm:swingSnapshot().fromLogical(evt.chan, evt.ppqL))
        end
        addLowlevel(evtType, evt)
      end
    end

    ----- Flush: commit accumulated ops to mm.

    local flushing = false

    --@map:contract no-op if nothing staged; otherwise commits in fixed order (assigns, deletes desc by loc, adds) under a single mm:modify; pb cents→raw conversion happens here
    --@map:contract snapshots adds/assigns/deletes before mm:modify so re-entry from mm callbacks (e.g. setMutedChannels via rebuild) cannot re-emit in-flight ops
    function um:flush()
      if cm:get('trackerMode') and next(dirtyPcChans) then
        for chan in pairs(dirtyPcChans) do reconcilePcs(chan) end
        dirtyPcChans = {}
      end
      if #adds == 0 and #assigns == 0 and #deletes == 0 then return end

      local flushAdds, flushAssigns, flushDeletes = adds, assigns, deletes
      adds, assigns, deletes = {}, {}, {}

      for _, e in ipairs(flushAssigns) do
        if e.type == 'pb' and e.update.val ~= nil then
          e.update.val = centsToRaw(e.update.val)
        end
      end
      for _, a in ipairs(flushAdds) do
        if a.type == 'pb' then
          a.evt.val = centsToRaw(a.evt.val)
        end
      end
      table.sort(flushDeletes, function(a, b) return a.loc > b.loc end)

      -- Capture uuids of notes this flush touches, so the rebuild fired
      -- from mm's reload can attribute over-threshold lane overlaps to us.
      local touched = {}
      for _, o in ipairs(flushAssigns) do
        if o.type == 'note' then
          local n = mm:getNote(o.loc)
          if n and n.uuid then touched[n.uuid] = true end
        end
      end
      pendingFlushUuids = touched

      mm:modify(function()
        for _, o in ipairs(flushAssigns) do
          if o.type == 'note' then mm:assignNote(o.loc, o.update)
          else mm:assignCC(o.loc, o.update) end
        end
        for _, o in ipairs(flushDeletes) do
          if o.type == 'note' then mm:deleteNote(o.loc)
          else mm:deleteCC(o.loc) end
        end
        for _, o in ipairs(flushAdds) do
          if o.type == 'note' then
            mm:addNote(o.evt)
            if o.evt.uuid then touched[o.evt.uuid] = true end
          else mm:addCC(o.evt) end
        end
      end)
    end

    ----- Init: load local cache from mm.

    local function init()
      for i = 1, 16 do chans[i] = { notes = {}, pbs = {} } end

      for loc, cc in mm:ccs() do
        local evt
        if cc.msgType == 'pb' then
          evt = util.pick(cc, 'ppq ppqL chan shape tension fake frame loc',
                          { val = rawToCents(cc.val) })
          util.add(chans[evt.chan].pbs, evt)
        else
          evt = cc
        end
        ccsByLoc[loc] = evt
      end
      for i = 1, 16 do sortByPPQ(chans[i].pbs) end

      for loc, n in mm:notes() do
        notesByLoc[loc] = n
        if n.lane == 1 then
          util.add(chans[n.chan].notes, n)
        end
      end
      for i = 1, 16 do sortByPPQ(chans[i].notes) end
    end

    init()
    return um
  end

  ----- Column allocation

  local function pushNoteCol(channel)
    local notes = channel.columns.notes
    return util.add(notes, { events = {} }), #notes
  end

  --@map:contract returns (true) on accept; (false, conflictEvt) when the refusal is the bump-prone overlap case (threshold exceeded, or coincident onset); (false) on the dominated-by-two refusal, which is structural rather than bug-attributable
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

  --@map:contract requested-lane refusals attributable to the in-flight flush (incoming or conflicting note's uuid in pendingFlushUuids) keep the overlap and log a warning, surfacing the bug rather than silently bumping; refusals not attributable, and lane-less adds, fall through to sibling-search bumping unchanged
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

  local CC_PROJECT_STRIP = { chan = true, msgType = true, cc = true }

  local function projectCC(cc, loc, overlay)
    local evt = util.clone(cc, CC_PROJECT_STRIP)
    evt.loc = loc
    if overlay then util.assign(evt, overlay) end
    return evt
  end

  ---------- PUBLIC

  tm = {}
  fire = util.installHooks(tm)

  -- Operates on column-projected events; raw fidelity (cc number, fake) needs mm directly.
  -- Defined here (above rebuild) so rebuild's tail-end usedSwings projection can
  -- share this iteration with applyTimeMap and the time-snap pass below.
  local function forEachEvent(fn)
    for _, channel in tm:channels() do
      local chan, cols = channel.chan, channel.columns
      for _, col in ipairs(cols.notes) do
        for _, evt in ipairs(col.events) do
          local isNote = evt.type ~= 'pa'
          fn(isNote and 'note' or 'pa', evt, chan, isNote)
        end
      end
      for _, t in ipairs{'pb', 'at', 'pc'} do
        if cols[t] then
          for _, evt in ipairs(cols[t].events) do fn(t, evt, chan, false) end
        end
      end
      for _, col in pairs(cols.ccs) do
        for _, evt in ipairs(col.events) do fn('cc', evt, chan, false) end
      end
    end
  end

  ----- Rebuild

  local rebuilding = false

  --@map:contract reentrancy-guarded; rebuilds channels[] from mm, recreates um, fires 'rebuild'; takeChanged forwarded to subscribers via the captured pendingTakeSwap
  function tm:rebuild(takeChanged)
    if rebuilding then return end
    rebuilding = true
    takeChanged = takeChanged or false

    -- 0) Aliases: delete prior materialised events; emit new ones from spec
    --    trees on roots. Runs through mm:modify, which fires 'reload' and
    --    re-enters rebuild; the rebuilding guard above bails on re-entry,
    --    and the outer rebuild reads the refreshed mm state.
    do
      local notesToDel, ccsToDel, roots = {}, {}, {}
      for loc, n in mm:notes() do
        if n.parentUuid then util.add(notesToDel, loc)
        elseif n.aliases and #n.aliases > 0 then util.add(roots, n) end
      end
      for loc, c in mm:ccs() do
        if c.parentUuid then util.add(ccsToDel, loc)
        elseif c.aliases and #c.aliases > 0 then util.add(roots, c) end
      end

      if #roots > 0 or #notesToDel > 0 or #ccsToDel > 0 then
        local claims = {}
        for _, n in mm:notes() do
          if not n.parentUuid then claims[slotKey(n)] = true end
        end
        for _, c in mm:ccs() do
          if not c.parentUuid then claims[slotKey(c)] = true end
        end

        local rng = aliases.makeRng(seedFromTake(mm:take()))
        local lenPpq = mm:length() or 0
        local notesToAdd, ccsToAdd = {}, {}
        local fitEmits = {}  -- { emit, snap, rChan } for note-aliases marked fit

        for _, root in ipairs(roots) do
          local et   = evtTypeOf(root)
          local seed = seedFields(root)
          -- Logical canonical: spec ops act on ppqL/durL; ppq/endppq are
          -- derived per-emit through the root's authoring-frame swing.
          seed.ppqL = seed.ppqL or seed.ppq
          if et == 'note' then
            seed.endppqL = seed.endppqL or seed.endppq
            seed.durL    = (seed.endppqL or 0) - (seed.ppqL or 0)
          end
          local snap = tm:swingSnapshot(root.frame)
          local q    = {}
          for _, c in ipairs(root.aliases) do
            util.add(q, { spec = c, parent = seed, path = { c.id } })
          end
          while #q > 0 do
            local e = table.remove(q, 1)
            local resolved = aliases.applyXform(e.parent, e.spec.xform, et, rng)
            if et == 'note' then
              resolved.endppqL = resolved.ppqL + resolved.durL
            end
            local rChan = resolved.chan or 1
            resolved.ppq = util.round(snap.fromLogical(rChan, resolved.ppqL))
                           + delayToPPQ(resolved.delay or 0)
            if et == 'note' then
              resolved.endppq = util.round(snap.fromLogical(rChan, resolved.endppqL))
              if resolved.endppq > lenPpq then
                resolved.endppq  = lenPpq
                resolved.endppqL = snap.toLogical(rChan, lenPpq)
              end
            end
            local key = slotKey(resolved)
            if not claims[key] then
              claims[key] = true
              local emit = util.clone(resolved)
              emit.parentUuid = root.uuid
              emit.specPath   = table.concat(e.path, '.')
              emit.aliases    = nil
              emit.aliasCtr   = nil
              if et == 'note' then
                util.add(notesToAdd, emit)
                if e.spec.fit then
                  util.add(fitEmits, { emit = emit, snap = snap, rChan = rChan })
                end
              else
                util.add(ccsToAdd, emit)
              end
            end
            for _, child in ipairs(e.spec.children or {}) do
              local p = {}
              for _, id in ipairs(e.path) do p[#p + 1] = id end
              p[#p + 1] = child.id
              util.add(q, { spec = child, parent = resolved, path = p })
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
              local k = colKey(n.chan, n.lane)
              byCol[k] = byCol[k] or {}
              util.add(byCol[k], n.ppq)
            end
          end
          for _, n in ipairs(notesToAdd) do
            local k = colKey(n.chan, n.lane)
            byCol[k] = byCol[k] or {}
            util.add(byCol[k], n.ppq)
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
                    emit.endppqL = fe.snap.toLogical(fe.rChan, ppq)
                  end
                  break
                end
              end
            end
          end
        end

        table.sort(notesToDel, function(a, b) return a > b end)
        table.sort(ccsToDel,   function(a, b) return a > b end)
        mm:modify(function()
          for _, loc in ipairs(notesToDel) do mm:deleteNote(loc) end
          for _, loc in ipairs(ccsToDel)   do mm:deleteCC(loc)   end
          for _, n   in ipairs(notesToAdd) do mm:addNote(n)      end
          for _, c   in ipairs(ccsToAdd)   do mm:addCC(c)        end
        end)
      end
    end

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
          if cc.msgType == 'pc' then
            local lst = pcByChan[cc.chan] or {}
            pcByChan[cc.chan] = lst
            util.add(lst, { ppq = cc.ppq, val = cc.val })
          end
        end
        for _, lst in pairs(pcByChan) do sortByPPQ(lst) end
      end

      local groups, work = {}, {}
      for loc, note in mm:notes() do
        local update
        if note.detune == nil then update = update or {}; update.detune = 0 end
        if note.delay  == nil then update = update or {}; update.delay  = 0 end
        if trackerMode and note.sample == nil then
          local realisedPpq = note.ppq + delayToPPQ(note.delay or 0)
          local prev = util.seek(pcByChan[note.chan] or {}, 'at-or-before', realisedPpq)
          update = update or {}
          update.sample = (prev and prev.val) or 0
        end
        if update then mm:assignNote(loc, update) end
        util.bucket(groups, note.chan .. '|' .. note.pitch,
                    { loc = loc, ppq = note.ppq, endppq = note.endppq })
      end
      for _, group in pairs(groups) do
        sortByPPQ(group)
        for i = 1, #group - 1 do
          if group[i].endppq > group[i + 1].ppq then
            util.add(work, { loc = group[i].loc, endppq = group[i + 1].ppq })
          end
        end
      end
      if #work > 0 then
        mm:modify(function()
          for _, w in ipairs(work) do mm:assignNote(w.loc, { endppq = w.endppq }) end
        end)
      end
    end

    -- 2) Allocate note columns. Clones rather than aliasing the mm-note
    -- table: column events diverge from mm in the projection step (5),
    -- which writes the logical position into evt.ppq while mm keeps raw.
    for loc, note in mm:notes() do
      local channel = channels[note.chan]
      local col, lane = allocateNoteColumn(channel, note)
      if note.lane ~= lane then
        mm:assignNote(loc, { lane = lane })
      end
      local ce = util.clone(note, { chan = true, lane = true })
      ce.loc = loc
      util.add(col.events, ce)
    end

    -- 3) Single CC walk.
    do
      local pbByChan = {}
      for loc, cc in mm:ccs() do
        local channel = channels[cc.chan]

        if cc.msgType == 'pb' then
          local col1       = channel.columns.notes[1]
          local prevailing = col1 and util.seek(col1.events, 'at-or-before', cc.ppq) or nil
          local detune     = (prevailing and prevailing.detune) or 0
          local hidden     = cc.fake and (cc.shape == nil or cc.shape == 'step')

          local pb = pbByChan[cc.chan] or { events = {}, anyVisible = false }
          pbByChan[cc.chan] = pb
          pb.anyVisible = pb.anyVisible or not hidden
          -- Absorbers (cc.fake) carry no delay: they sit at host's raw in
          -- mm and don't traverse the intent frame. The pb column then
          -- holds them at host raw while non-fake pbs project at intent
          -- after tidyCol — Phase 6 collapses the difference.
          util.add(pb.events, projectCC(cc, loc, {
            val    = util.round(rawToCents(cc.val) - detune),
            detune = detune,
            hidden = hidden,
          }))

        elseif cc.msgType == 'pa' then
          local noteCol = findNoteColumnForPitch(channel, cc.pitch, cc.ppq)
          if noteCol then
            util.add(noteCol.events, projectCC(cc, loc, {
              type = 'pa', vel = cc.val, val = util.REMOVE,
            }))
          end

        elseif cc.msgType == 'cc' or cc.msgType == 'at' or cc.msgType == 'pc' then
          local col
          if cc.msgType == 'cc' then
            col = channel.columns.ccs[cc.cc] or { cc = cc.cc, events = {} }
            channel.columns.ccs[cc.cc] = col
          else
            col = channel.columns[cc.msgType] or { events = {} }
            channel.columns[cc.msgType] = col
          end
          util.add(col.events, projectCC(cc, loc))
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
        local c = channels[chan].columns
        local records = {}
        for L, lane in ipairs(c.notes) do
          for _, n in ipairs(lane.events) do
            n.sampleShadowed = nil
            util.add(records, { ppq = n.ppq, ppqL = n.ppqL, lane = L,
                                sample = n.sample or 0, key = n })
          end
        end
        local desired, shadowed, rems, adds_ =
          reconcilePCsForChan(chan, records, (c.pc and c.pc.events) or {})
        for n in pairs(shadowed) do n.sampleShadowed = true end
        for _, r in ipairs(rems)  do util.add(toDelete, r.loc) end
        for _, a in ipairs(adds_) do util.add(toAdd, a) end
        c.pc = { events = desired }
      end

      if #toDelete > 0 or #toAdd > 0 then
        table.sort(toDelete, function(a, b) return a > b end)
        mm:modify(function()
          for _, loc in ipairs(toDelete) do mm:deleteCC(loc) end
          for _, pc  in ipairs(toAdd)    do mm:addCC(pc) end
        end)
        for chan = 1, 16 do channels[chan].columns.pc = { events = {} } end
        for loc, cc in mm:ccs() do
          if cc.msgType == 'pc' then
            util.add(channels[cc.chan].columns.pc.events, projectCC(cc, loc))
          end
        end
      end
    end
    -- 4.7) Two-frame rebuild rule. For each non-derived event in raw frame:
    --   stale=true & ppqL present  → raw is rebuilt from ppqL (+ delay).
    --   else, raw matches predicted → no-op (steady state).
    --   else                        → ppqL is rederived from raw (sole
    --                                  swing.toLogical call site). Covers
    --                                  legacy-take load and externally-edited
    --                                  events under the same branch.
    -- Exempt:
    --   evt.fake — absorber pbs and synthesised PCs are derived.
    --   evt.frame — pre-Phase-7, frame-bearing events have their own reswing
    --     pathway via vm:reswingAll, which reads the authoring frame; the
    --     two-frame rule applies only to events without authoring metadata.
    --
    -- Snapshot lane-1 note ppqs before the rule runs so step 4.8 can
    -- reseat absorbers whose host moved.
    local laneOnePreRule = {}
    for chan = 1, 16 do
      local col1 = channels[chan].columns.notes[1]
      if col1 then
        local list = {}
        for _, n in ipairs(col1.events) do
          util.add(list, { oldPpq = n.ppq, evt = n })
        end
        if #list > 0 then laneOnePreRule[chan] = list end
      end
    end
    do
      local snap     = tm:swingSnapshot()
      local EPS      = 1   -- ppq; tolerates rounding slop in fromLogical
      local toAssign = {}  -- { { isNote, loc, update } }
      forEachEvent(function(evtType, evt, chan, isNote)
        if evt.fake or evt.frame then return end
        local stale = staleSwing[chan]
        local d     = isNote and delayToPPQ(evt.delay or 0) or 0
        local update
        if stale and evt.ppqL ~= nil then
          local newPpq = util.round(snap.fromLogical(chan, evt.ppqL)) + d
          if newPpq ~= evt.ppq then
            evt.ppq = newPpq
            update = { ppq = newPpq }
          end
          if isNote and evt.endppqL ~= nil then
            local newEndppq = util.round(snap.fromLogical(chan, evt.endppqL))
            if newEndppq ~= evt.endppq then
              evt.endppq = newEndppq
              update = update or {}
              update.endppq = newEndppq
            end
          end
        else
          local predicted = evt.ppqL ~= nil
            and (util.round(snap.fromLogical(chan, evt.ppqL)) + d) or nil
          if not predicted or math.abs(evt.ppq - predicted) > EPS then
            local newPpqL = snap.toLogical(chan, evt.ppq - d)
            evt.ppqL = newPpqL
            update = { ppqL = newPpqL }
            if isNote then
              local newEndppqL = snap.toLogical(chan, evt.endppq)
              evt.endppqL = newEndppqL
              update.endppqL = newEndppqL
            end
          elseif isNote then
            -- ppq agrees with ppqL; endppq may still disagree with endppqL
            -- (stale tail). Rederive endppqL from endppq when so.
            local predictedEnd = evt.endppqL ~= nil
              and util.round(snap.fromLogical(chan, evt.endppqL)) or nil
            if not predictedEnd or math.abs(evt.endppq - predictedEnd) > EPS then
              local newEndppqL = snap.toLogical(chan, evt.endppq)
              evt.endppqL = newEndppqL
              update = update or {}
              update.endppqL = newEndppqL
            end
          end
        end
        if update then
          util.add(toAssign, { isNote = isNote, loc = evt.loc, update = update })
        end
      end)
      if #toAssign > 0 then
        mm:modify(function()
          for _, a in ipairs(toAssign) do
            if a.isNote then mm:assignNote(a.loc, a.update)
            else             mm:assignCC(a.loc,   a.update)
            end
          end
        end)
      end
      staleSwing = {}
    end

    -- 4.8) Reseat absorbers: ensure each fake pb sits at its host's seat
    -- in both raw and logical frames. The rule may have moved the host
    -- during the pass; the fake follows. Idempotent — fakes already
    -- aligned to their host (ppq and ppqL) produce no write.
    do
      local fakesByPos
      local toReseat = {}  -- { { loc, update } }
      for chan, list in pairs(laneOnePreRule) do
        for _, entry in ipairs(list) do
          if not fakesByPos then
            fakesByPos = {}
            for loc, cc in mm:ccs() do
              if cc.msgType == 'pb' and cc.fake then
                local m = fakesByPos[cc.chan] or {}; fakesByPos[cc.chan] = m
                m[cc.ppq] = { loc = loc, ppqL = cc.ppqL }
              end
            end
          end
          local m = fakesByPos[chan]; if not m then goto cont end
          local n   = entry.evt
          local hit = m[entry.oldPpq] or m[n.ppq]
          if hit then
            local update = {}
            if m[entry.oldPpq] and entry.oldPpq ~= n.ppq then update.ppq = n.ppq end
            if hit.ppqL ~= n.ppqL then update.ppqL = n.ppqL end
            if next(update) then util.add(toReseat, { loc = hit.loc, update = update }) end
          end
          ::cont::
        end
      end
      if #toReseat > 0 then
        mm:modify(function()
          for _, r in ipairs(toReseat) do mm:assignCC(r.loc, r.update) end
        end)
        local locToUpdate = {}
        for _, r in ipairs(toReseat) do locToUpdate[r.loc] = r.update end
        for chan = 1, 16 do
          local pbCol = channels[chan].columns.pb
          if pbCol then
            local touched
            for _, evt in ipairs(pbCol.events) do
              local u = locToUpdate[evt.loc]
              if u then
                if u.ppq  then evt.ppq  = u.ppq  end
                if u.ppqL then evt.ppqL = u.ppqL end
                touched = true
              end
            end
            if touched then sortByPPQ(pbCol.events) end
          end
        end
      end
    end

    -- 5) Project to logical: column events expose the logical position as
    -- evt.ppq. After step 4.7 every non-fake non-frame event has a ppqL;
    -- step 4.8 has stamped fakes; alias emits carry their own ppqL. Frame-
    -- bearing events authored without a stamp keep raw — harmless, off-grid
    -- under non-identity swing until they're touched.
    -- Round to int when projecting: mm-side ppq is integer, and the offGrid
    -- check in vm:rebuild compares against rowToPPQ's integer-rounded result.
    -- ppqL stays float on the column event so swing-inverse round-trips remain
    -- exact for tooling that reads it.
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

    -- Project the set of authoring swing names referenced by any event in
    -- this take into take-tier cm. sequenceManager reads these via
    -- cm:readTakeKey to drive cross-take reswing on swing-library edits.
    -- Only string references count: anonymous composites are frozen at
    -- authoring and can't go stale.
    do
      local used = {}
      forEachEvent(function(_, evt)
        local f = evt.frame
        if f then
          if type(f.swing)    == 'string' then used[f.swing]    = true end
          if type(f.colSwing) == 'string' then used[f.colSwing] = true end
        end
      end)
      local prev = cm:get('usedSwings') or {}
      local same = true
      for k in pairs(used) do if not prev[k] then same = false; break end end
      if same then for k in pairs(prev) do if not used[k] then same = false; break end end end
      if not same then cm:set('take', 'usedSwings', used) end
    end

    um = createUpdateManager()
    rebuilding = false
    pendingFlushUuids = nil

    --@map:emits rebuild  -- nil; fires once at the end of every rebuild after um is recreated
    fire('rebuild', nil)
  end

  ----- Accessors

  function tm:getChannel(chan)
    return channels and channels[chan]
  end

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

  function tm:length()
    return mm and mm:length()
  end

  function tm:resolution()
    return mm and mm:resolution()
  end

  function tm:name()        return mm and mm:name() end
  function tm:setName(name) if mm then mm:setName(name) end end

  -- τ acts on logical positions; intent ppqs rederive through the current swing snapshot.
  -- Events without ppqL fall back to τ on raw ppq (identical under identity swing).
  -- slopeAt scales note delays so realised stretch tracks logical stretch locally.
  -- Two passes (gather, then mutate) so all reads are stable.
  local function applyTimeMap(tau, slopeAt)
    local snap  = tm:swingSnapshot()
    local plans = {}
    forEachEvent(function(type, evt, chan, isNote)
      local p = { type = type, evt = evt }
      if evt.ppqL ~= nil then
        p.newPpqL = tau(evt.ppqL)
        p.newPpq  = util.round(snap.fromLogical(chan, p.newPpqL))
      else
        p.newPpq = util.round(tau(evt.ppq))
      end
      if isNote then
        if evt.endppqL ~= nil then
          p.newEndppqL = tau(evt.endppqL)
          p.newEndppq  = util.round(snap.fromLogical(chan, p.newEndppqL))
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
      um:assignEvent(p.type, p.evt, {
        ppq      = p.newPpq,
        endppq   = p.newEndppq,
        delay    = p.newDelay,
        ppqL     = p.newPpqL,
        endppqL  = p.newEndppqL,
      })
    end
    um:flush()
  end

  -- On shrink, notes spanning the boundary keep their onset and have endppq clamped.
  function tm:setLength(newPpq)
    if not mm then return end
    local oldPpq = mm:length() or 0
    if newPpq < oldPpq then
      local kills, clamps = {}, {}
      forEachEvent(function(type, evt, _, isNote)
        if evt.ppq >= newPpq then
          util.add(kills, { type, evt })
        elseif isNote and evt.endppq > newPpq then
          util.add(clamps, evt)
        end
      end)
      for _, k in ipairs(kills)    do um:deleteEvent(k[1], k[2]) end
      for _, evt in ipairs(clamps) do um:assignEvent('note', evt, { endppq = newPpq }) end
      um:flush()
    end
    if newPpq ~= oldPpq then mm:setLength(newPpq / mm:resolution()) end
  end

  -- Stretch the take to `newPpq` by linearly remapping the logical
  -- frame: each event on logical row r ends up on row f·r where
  -- f = newPpq/oldPpq. ppqL stamps scale by f; intent ppqs are
  -- rederived through swing — so under non-identity swing realised
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
    local sourceNotes = snapshot(mm:notes())
    local sourceCCs   = snapshot(mm:ccs())

    mm:setLength(newPpq / mm:resolution())

    local function shift(c, delta, isNote)
      c.ppq = c.ppq + delta
      if c.ppqL    then c.ppqL    = c.ppqL    + delta end
      if c.ppq >= newPpq then return false end
      if isNote then
        c.endppq = c.endppq + delta
        if c.endppqL then c.endppqL = c.endppqL + delta end
        if c.endppq > newPpq then c.endppq, c.endppqL = newPpq, nil end
      end
      return true
    end

    mm:modify(function()
      for k = 1, math.ceil(newPpq / oldPpq) - 1 do
        local delta = k * oldPpq
        for _, src in ipairs(sourceNotes) do
          local c = util.clone(src)
          if shift(c, delta, true) then mm:addNote(c) end
        end
        for _, src in ipairs(sourceCCs) do
          local c = util.clone(src)
          if shift(c, delta, false) then mm:addCC(c) end
        end
      end
    end)
  end

  function tm:timeSigs()
    return mm and mm:timeSigs() or {}
  end

  function tm:interpolate(A, B, ppq)
    return mm and mm:interpolate(A, B, ppq)
  end

  -- E_c: column is inner, global is outer (see docs/timing.md).
  --@map:contract returns clipped per-layer Shapes + closures; safe to retain across edits since closures capture the Shapes, not cm reads
  --@map:contract chan==nil marks all 16 channels stale; otherwise just the named channel. Consumed by the rebuild rule on the next tm:rebuild, then cleared.
  function tm:markSwingStale(chan)
    if chan == nil then
      for i = 1, 16 do staleSwing[i] = true end
    else
      staleSwing[chan] = true
    end
  end

  function tm:swingSnapshot(override)
    local global, column = nil, {}
    if mm then
      local gSrc, cSrc
      if override then gSrc, cSrc = override.swing, override.colSwing
      else             gSrc, cSrc = cm:get('swing'), cm:get('colSwing')
      end
      local length   = mm:length() or 0
      local ppqPerQN = mm:resolution()
      local function resolve(name)
        local composite = timing.findShape(name, cm:get('swings'))
        if timing.isIdentity(composite) or length <= 0 then return nil end
        return timing.resolveComposite(composite, length, ppqPerQN)
      end
      global = resolve(gSrc)
      if cSrc then
        for chan, name in pairs(cSrc) do column[chan] = resolve(name) end
      end
    end
    return {
      global = global,
      column = column,
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

  ----- Transport

  function tm:playFrom(ppq)
    if not (mm and mm:take()) then return end
    reaper.SetEditCurPos(reaper.MIDI_GetProjTimeFromPPQPos(mm:take(), ppq), false, false)
    reaper.Main_OnCommand(1007, 0)
  end

  function tm:play() reaper.Main_OnCommand(1007, 0) end
  function tm:stop() reaper.Main_OnCommand(1016, 0) end
  function tm:playPause() reaper.Main_OnCommand(40073, 0) end

  ----- Mutation

  function tm:deleteEvent(type, evt) um:deleteEvent(type, evt) end
  function tm:addEvent(type, evt) um:addEvent(type, evt) end
  function tm:assignEvent(type, evt, update, opts) um:assignEvent(type, evt, update, opts) end
  function tm:flush() um:flush() end

  --@map:contract evt is a materialised alias child (carries parentUuid + specPath); appends each (field, op) entry of `opsByField` to the spec node and queues an aliases-only metadata write on the root. Multi-field is one call so coupled fields (e.g. pitch+detune under a temper) land on a single root snapshot. Returns false when evt is not aliased or the root/spec lookup fails — caller should fall through to direct mutation.
  function tm:routeRelative(evt, opsByField)
    if not (evt and evt.parentUuid) then return false end
    local rootLoc, root, kind = mm:byUuid(evt.parentUuid)
    if not (root and rootLoc) then return false end
    local node = aliases.find(root, evt.specPath)
    if not node then return false end
    for field, op in pairs(opsByField) do
      node.xform = aliases.appendOp(node.xform, field, op)
    end
    um:assignEvent(kind, { loc = rootLoc }, { aliases = root.aliases })
    return true
  end

  --@map:contract for a materialised child source at (rootUuid, specPath), returns { children = deep clone of the leaf spec node's children, chain = [{id, xform-clone}, ...] one entry per ANCESTOR segment (the leaf itself is excluded). Returns nil if the root is missing or any path segment fails to resolve. The chain is the copy-time fingerprint of *ancestor* xforms only — the leaf is the source, so editing or moving it stays compatible with paste; only ancestor edits count as tree-mutation drift.
  function tm:aliasSrcSnapshot(rootUuid, specPath)
    if not (rootUuid and specPath) then return nil end
    local _, root = mm:byUuid(rootUuid)
    if not (root and root.aliases) then return nil end
    local parts = {}
    for id in specPath:gmatch('[^.]+') do parts[#parts + 1] = id end
    local list, node, chain = root.aliases, nil, {}
    for i, id in ipairs(parts) do
      if not list then return nil end
      node = nil
      for _, n in ipairs(list) do if n.id == id then node = n; break end end
      if not node then return nil end
      if i < #parts then
        chain[#chain + 1] = { id = id, xform = util.deepClone(node.xform) }
      end
      list = node.children
    end
    return { children = util.deepClone(node.children or {}), chain = chain }
  end

  --@map:contract resolves the source side of an alias-paste against the live spec tree. Returns nil if root or any path segment missing (→ silent demote, the (A) case); { mismatch = true } if a captured ANCESTOR's xform disagrees with the live one, or any path xform contains a producing-op we cannot re-roll (→ loud demote, "spec tree edited"); { resolved = field-table } otherwise. The leaf node's xform is free to drift — corrective deltas in aliasWriter compensate. Resolved starts at root's fields (with durL = endppqL − ppqL for notes) and composes each path segment's xform via aliases.applyXform.
  function tm:resolveAliasSrc(rootUuid, specPath, chain, evtType)
    if not rootUuid then return nil end
    local _, root = mm:byUuid(rootUuid)
    if not root then return nil end
    local valid = aliases.validFields(evtType)
    local resolved = {}
    for f in pairs(valid) do resolved[f] = root[f] end
    if evtType == 'note' and root.endppqL and root.ppqL then
      resolved.durL = root.endppqL - root.ppqL
    end
    if not specPath then return { resolved = resolved } end
    if not root.aliases then return nil end
    local parts = {}
    for id in specPath:gmatch('[^.]+') do parts[#parts + 1] = id end
    local list = root.aliases
    for i, id in ipairs(parts) do
      local node
      if list then
        for _, n in ipairs(list) do if n.id == id then node = n; break end end
      end
      if not node then return nil end
      if i < #parts then
        local captured = chain and chain[i]
        if not captured or captured.id ~= id
           or not util.deepEq(captured.xform, node.xform) then
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

  --@map:contract walks the live spec tree from fromSpecPath (exclusive) to toSpecPath (inclusive) and concatenates per-field xform op-lists in order. Used at copy time by family-paste to snapshot the structural xforms between a clip's family-parent and its descendant; preserves producing-ops (rand) verbatim. fromSpecPath nil → walk from root. Returns nil if any path segment is missing or toSpecPath is not a strict descendant of fromSpecPath. Ops are deep-cloned.
  function tm:pathXform(rootUuid, fromSpecPath, toSpecPath)
    if not (rootUuid and toSpecPath) then return nil end
    local _, root = mm:byUuid(rootUuid)
    if not (root and root.aliases) then return nil end
    local function parts(p)
      local r = {}
      if not p then return r end
      for id in p:gmatch('[^.]+') do r[#r + 1] = id end
      return r
    end
    local fromParts, toParts = parts(fromSpecPath), parts(toSpecPath)
    if #toParts <= #fromParts then return nil end
    for i, fp in ipairs(fromParts) do
      if toParts[i] ~= fp then return nil end
    end
    local list, node = root.aliases, nil
    for _, id in ipairs(fromParts) do
      if not list then return nil end
      node = nil
      for _, n in ipairs(list) do if n.id == id then node = n; break end end
      if not node then return nil end
      list = node.children
    end
    local out = {}
    for i = #fromParts + 1, #toParts do
      if not list then return nil end
      local id = toParts[i]
      node = nil
      for _, n in ipairs(list) do if n.id == id then node = n; break end end
      if not node then return nil end
      for f, ops in pairs(node.xform or {}) do
        out[f] = out[f] or {}
        for _, op in ipairs(ops) do out[f][#out[f] + 1] = util.deepClone(op) end
      end
      list = node.children
    end
    return out
  end

  --@map:contract creates a new alias spec node under the event identified by `rootUuid`. srcSpecPath nil → top of root.aliases; non-nil → child of the spec node at that path (so descendants of that spec compose this xform). `children`, when given, is taken verbatim as the new node's children (typically a deep clone of the source's subtree, captured at copy time so paste brings the source's alias-children along under the new node). `fit` (truthy) marks the new node as visually fit: at rebuild, its materialised endppq is clipped to the next event on the same column, so the alias never causes a new lane to be allocated for its successor. Returns the new node's full specPath, or nil if the root/spec lookup fails.
  function tm:createAlias(rootUuid, srcSpecPath, xform, children, fit)
    local rootLoc, root, kind = mm:byUuid(rootUuid)
    if not (root and rootLoc) then return nil end
    root.aliases = root.aliases or {}
    local list, prefix
    if srcSpecPath then
      local parent = aliases.find(root, srcSpecPath)
      if not parent then return nil end
      parent.children = parent.children or {}
      list, prefix = parent.children, srcSpecPath .. '.'
    else
      list, prefix = root.aliases, ''
    end
    local id = aliases.allocId(root)
    local node = { id = id, xform = xform or {}, children = children or {} }
    if fit then node.fit = true end
    list[#list + 1] = node
    um:assignEvent(kind, { loc = rootLoc },
                   { aliases = root.aliases, aliasCtr = root.aliasCtr })
    return prefix .. id
  end

  ----- Mute

  --@map:contract idempotent: walks every existing note and only emits an assign when n.muted differs from desired; lastMuteSet also tags later-added notes
  function tm:setMutedChannels(set)
    lastMuteSet = util.clone(set or {})
    if not um then return end
    for _, ch in ipairs(channels) do
      local want = lastMuteSet[ch.chan] == true
      for _, col in ipairs(ch.columns.notes) do
        for _, n in ipairs(col.events) do
          if (n.muted == true) ~= want then
            um:assignEvent('note', n, { muted = want })
          end
        end
      end
    end
    um:flush()
  end

  ----- Lifecycle

  --@map:invariant usedSwings is an output of rebuild (computed from event frames), not an input; suppressed here to prevent the cm:set call inside rebuild from firing a redundant follow-up rebuild
  local vmOnlyKeys = { mutedChannels = true, soloedChannels = true, usedSwings = true }

  --@map:invariant configChanged routes 'swing' to all 16 channels, 'colSwing' to channels whose entry differs vs prevColSwing, 'swings' to channels resolving to a name whose body differs vs prevSwings. The diff caches refresh after each handled event and on bindTake (which silently swaps cm's tier stack).
  local prevSwings   = util.deepClone(cm:get('swings')   or {})
  local prevColSwing = util.deepClone(cm:get('colSwing') or {})

  local function snapshotSwingState()
    prevSwings   = util.deepClone(cm:get('swings')   or {})
    prevColSwing = util.deepClone(cm:get('colSwing') or {})
  end

  -- Channels (1..16) whose colSwing[chan] differs between prev and cur.
  local function colSwingDiffChannels(prev, cur)
    prev, cur = prev or {}, cur or {}
    local affected = {}
    for chan = 1, 16 do
      if prev[chan] ~= cur[chan] then affected[chan] = true end
    end
    return affected
  end

  -- Names whose library body differs (added, removed, or edited).
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

  -- Channels whose resolved swing references any of `names`. Global swing
  -- shadows colSwing for the channels it covers — if the global swing's
  -- name is in the set, every channel is affected.
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

  -- True only inside tm:bindTake, between cm:setContext and mm:load.
  -- Suppresses the configChanged-driven rebuild so the swap reads from a
  -- coherent (cm, mm) pair: mm:load fires the single rebuild downstream.
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
    if not vmOnlyKeys[key] then tm:rebuild(false) end
  end)

  --@map:contract atomic take swap: cm:setContext runs silently (its broadcast is suppressed for both tm's own subscriber and — transitively, since vm rebuilds only via tm's 'rebuild' signal — for vm). mm:load then fires the single coherent rebuild downstream.
  --@map:contract bindTake(nil) is the mirror seam used when the tracker stack goes dormant (e.g. switching to the sample page). cm clears under the same suppression; mm:load(nil) is a no-op, so no rebuild fires. tm/vm retain their last frame harmlessly until the next bindTake re-arms them.
  function tm:bindTake(take)
    bindingTake = true
    cm:setContext(take)
    bindingTake = false
    mm:load(take)
    snapshotSwingState()
  end

  function tm:currentTake() return mm and mm:take() end

  tm:rebuild(true)
  return tm
end
