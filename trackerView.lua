-- See docs/trackerView.md for the model.

--@map:invariant rows 0-indexed, cols 1-indexed, channels 1..16, stops 1-indexed
--@map:invariant vm.grid is a live handle — rm reads it each frame; mutated in place on rebuild, never reassigned
--@map:invariant rm is pull-only — vm fires no render callbacks; rm queries vm.grid / vm:ec() / vm:rowPerBar() each frame
--@map:invariant all writes funnel through tm (addEvent/assignEvent/deleteEvent/flush); vm never touches mm
--@map:invariant vm sits on the swing boundary; intent only — never reads/writes realisation pb directly (see docs/tuning.md)
--@map:invariant authoring stamps evt.rpb = currentRpb() and evt.ppq = row · logPerRow before tm:addEvent
--@map:invariant off-grid edits snap evt.ppq to cursor row; delay survives, rpb restamps to current
--@map:invariant clipboard encodes rows in source's logical frame; paste decodes against dest's rpb — symmetric on (row, chan), not absolute ppq

loadModule('util')
loadModule('midiManager')
loadModule('trackerManager')
loadModule('tuning')
loadModule('commandManager')
loadModule('editCursor')

local function print(...)
  return util.print(...)
end

--@map:contract pure throwaway snapshot built once per vm:rebuild; no callbacks, no mutation, no migration — discard and rebuild on every change
function newViewContext(args)
  local swing      = args.swing
  local rowPPQs    = args.rowPPQs
  local length     = args.length
  local numRows    = args.numRows
  local rowPerBeat = args.rowPerBeat
  local ppqPerRow  = args.ppqPerRow
  local timeSigs   = args.timeSigs
  local temper     = args.temper
  local ctx        = {}

  ----- Temperament

  function ctx:activeTemper() return temper end

  function ctx:noteProjection(evt)
    if not (temper and evt and evt.pitch) then return end
    local detune    = evt.detune or 0
    local step, oct = tuning.midiToStep(temper, evt.pitch, detune)
    local label     = tuning.stepToText(temper, step, oct)
    local tm_, td_  = tuning.stepToMidi(temper, step, oct)
    local gap       = (evt.pitch * 100 + detune) - (tm_ * 100 + td_)

    local steps, n, period = temper.cents, #temper.cents, temper.period
    local left    = step == 1 and steps[n] - period or steps[step - 1]
    local right   = step == n and steps[1] + period or steps[step + 1]
    local halfGap = math.min(steps[step] - left, right - steps[step]) / 2

    return label, gap, halfGap
  end

  ----- Timing

  --@map:contract identity row math: column-event ppq is the logical position; rows are uniform ppqPerRow units. Inverse of rowToPPQ. The chan argument is unused at this layer (kept for the call-site signature).
  function ctx:ppqToRow(ppqI, chan)
    if ppqI <= 0 then return 0 end
    if ppqI >= length then return numRows end
    return ppqI / ppqPerRow
  end

  --@map:contract identity row math: row × ppqPerRow, integer-rounded, clamped at length. On-grid iff ctx:rowToPPQ(round(ppqToRow(p)), chan) == p.
  function ctx:rowToPPQ(row, chan)
    if row <= 0 then return 0 end
    if row >= numRows then return length end
    return math.floor(row * ppqPerRow + 0.5)
  end

  function ctx:snapRow(ppqI, chan) return util.round(self:ppqToRow(ppqI, chan)) end

  function ctx:ppqPerRow() return ppqPerRow end

  do -- exports ctx:rowBeatInfo, ctx:barBeatSub
    local function timeSigAt(ppq)
      local active = timeSigs[1]
      for i = 2, #timeSigs do
        if timeSigs[i].ppq <= ppq then active = timeSigs[i]
        else break end
      end
      return active
    end

    local function tsRow(ts) return math.floor(ctx:ppqToRow(ts.ppq)) end

    function ctx:rowBeatInfo(row)
      local ts = timeSigAt(self:rowToPPQ(row))
      if not ts then return false, false end
      local rel = row - tsRow(ts)
      return rel % (rowPerBeat * ts.num) == 0, rel % rowPerBeat == 0
    end

    function ctx:barBeatSub(row)
      local bar = 1
      for i, ts in ipairs(timeSigs) do
        local rpbar   = rowPerBeat * ts.num
        local next_   = timeSigs[i + 1]
        local nextRow = next_ and tsRow(next_) or math.huge
        if row < nextRow then
          local rel = row - tsRow(ts)
          return bar + rel // rpbar,
            (rel % rpbar) // rowPerBeat + 1,
            rel % rowPerBeat + 1,
            ts
        end
        bar = bar + (nextRow - tsRow(ts)) // rpbar
      end
      return bar, 1, 1, timeSigs[1]
    end
  end

  return ctx
end

--@map:shape grid = { cols = {<col>...}, chanFirstCol = {[chan]=i}, chanLastCol = {[chan]=i}, lane1Col = {[chan]=<col>}, numRows = int }
--@map:shape gridCol = { type, midiChan, lane?, cc?, label, events, width, parts, stopPos, partAt, partStart, showDelay, cells={[y]=evt}, overflow={[y]=true}, offGrid={[y]=true}, ghosts={[y]={val,fromEvt,toEvt}}, tails? }
--@map:shape selection = { row1, row2, col1, col2, part1, part2 }  -- part names: 'pitch'|'vel'|'delay' on note, 'pb' on pb, 'val' on scalar
--@map:shape plan = { col, e, [newppq], [newEndppq], [newDelay] }  -- consumed by writePlans / conformOverlaps
function newTrackerView(tm, cm, cmgr)

  ---------- PRIVATE

  local resolution    = 240
  local rowPerBar     = 16
  local rowPPQs       = {}
  local length        = 0
  local timeSigs      = {}

  local scrollCol   = 1
  local scrollRow   = 0

  local gridWidth   = 0
  local gridHeight  = 0

  local grid = {
    cols         = {},
    chanFirstCol = {},
    chanLastCol  = {},
  }

  local vm = {}
  vm.grid = grid  -- live handle for rm; mutated in place on rebuild
  vm.aliasMode = false  -- toggled by `toggleAliasMode`; sampled at paste/duplicate time to choose aliased vs plain writer (the clip itself always carries aliasSrc)

  local ec, clipboard, ctx

  ---------- SHARED HELPERS

  ----- Note geometry (used by editing, adjust*, nudge, quantizeKeepRealised)

  -- prev maximises endppq; nxt minimises ppq.
  local function neighbourEvents(cols, ppq, pred)
    local prev, nxt
    for _, c in ipairs(cols) do
      local p = util.seek(c.events, 'before', ppq, pred)
      local n = util.seek(c.events, 'after',  ppq, pred)
      if p and (not prev or p.endppq > prev.endppq) then prev = p end
      if n and (not nxt  or n.ppq    < nxt.ppq    ) then nxt  = n end
    end
    return prev, nxt
  end

  local function notePreds(excludeEvt)
    local pitch = excludeEvt and excludeEvt.pitch
    return function(e) return util.isNote(e) and e ~= excludeEvt and e.pitch ~= pitch end,
           function(e) return util.isNote(e) and e ~= excludeEvt and e.pitch == pitch end
  end

  -- Diff-pitch col-local with `overlapOffset` leniency (matches column allocator).
  -- Same-pitch chan-wide with no leniency: MIDI permits one voice per (chan, pitch).
  local function overlapBounds(col, ppq, excludeEvt, allowOverlap)
    local lenient = allowOverlap and cm:get('overlapOffset') * resolution or 0
    local diff, same = notePreds(excludeEvt)

    local prevD, nextD = neighbourEvents({col}, ppq, diff)
    local prevS, nextS = neighbourEvents(tm:getChannel(col.midiChan).columns.notes, ppq, same)

    local minStart = math.max(prevD and (prevD.endppq - lenient) or 0,      prevS and prevS.endppq or 0)
    local maxEnd   = math.min(nextD and (nextD.ppq    + lenient) or length, nextS and nextS.ppq    or length)
    return minStart, maxEnd
  end

  -- Row-space sibling of overlapBounds. e.ppq is exact logical-ppq
  -- post-projection; lenient diff edges add slack in the same frame.
  local function rowBounds(col, ppq, excludeEvt, allowOverlap)
    local chan, logPerRow = col.midiChan, ctx:ppqPerRow()
    local lenient = allowOverlap and cm:get('overlapOffset') * resolution or 0
    local diff, same = notePreds(excludeEvt)

    local prevD, nextD = neighbourEvents({col}, ppq, diff)
    local prevS, nextS = neighbourEvents(tm:getChannel(chan).columns.notes, ppq, same)

    local function startL(e, slack) return e.ppq    + slack end
    local function endL  (e, slack) return e.endppq + slack end

    local fullL = grid.numRows * logPerRow
    local prevEndL   = math.max(prevD and endL  (prevD, -lenient) or 0,     prevS and endL  (prevS, 0) or 0)
    local nextStartL = math.min(nextD and startL(nextD,  lenient) or fullL, nextS and startL(nextS, 0) or fullL)
    return math.ceil(prevEndL / logPerRow), math.floor(nextStartL / logPerRow)
  end

  --@map:contract resolves overlap excess in a per-column plan list; mutates plan entries in place. Tail-overlap clips predecessor's tail (legato — onset stays); same-onset shifts the later-source-ppq one by 1 ppq. Non-note plans/cols skipped; unplanned col-mates treated as fixed
  local function conformOverlaps(plans)
    local lenient = cm:get('overlapOffset') * resolution
    local plansByCol = {}
    for _, p in ipairs(plans) do
      if util.isNote(p.e) then
        plansByCol[p.col] = plansByCol[p.col] or {}
        util.add(plansByCol[p.col], p)
      end
    end
    for col, colPlans in pairs(plansByCol) do
      local planByEvt = {}
      for _, p in ipairs(colPlans) do planByEvt[p.e] = p end

      local timeline = {}
      for _, e in ipairs(col.events) do
        if util.isNote(e) then
          local p = planByEvt[e]
          util.add(timeline, { e = e, plan = p,
            ppq    = (p and p.newppq)    or e.ppq,
            endppq = (p and p.newEndppq) or e.endppq })
        end
      end
      table.sort(timeline, function(a, b)
        if a.ppq ~= b.ppq then return a.ppq < b.ppq end
        return a.e.ppq < b.e.ppq
      end)

      local function nudgePpq(plan, e, delta)
        plan.newppq = (plan.newppq or e.ppq) + delta
      end
      for i = 2, #timeline do
        local prev, curr = timeline[i - 1], timeline[i]
        -- Same-onset shift first. The later-source-ppqL one (curr by
        -- sort tie-break) moves up 1 ppq; if it's fixed, prev moves
        -- back instead — rare, only when a planned event happens to
        -- round onto an unplanned col-mate's ppq.
        if prev.ppq == curr.ppq then
          if curr.plan then
            nudgePpq(curr.plan, curr.e, 1)
            curr.ppq = curr.ppq + 1
          elseif prev.plan then
            nudgePpq(prev.plan, prev.e, -1)
            prev.ppq = prev.ppq - 1
          end
        end
        -- Tail-overlap clip on the post-shift state. Predecessor's
        -- tail clips first (legato — onset stays); only when the
        -- predecessor is fixed does the successor's onset lift.
        local threshold = (prev.e.pitch == curr.e.pitch) and 0 or lenient
        local excess    = prev.endppq - curr.ppq - threshold
        if excess > 0 then
          if prev.plan then
            local clipped = math.max(prev.ppq + 1,
                                     (prev.plan.newEndppq or prev.e.endppq) - excess)
            prev.plan.newEndppq = clipped
            prev.endppq         = clipped
          elseif curr.plan then
            local lifted = math.min(curr.endppq - 1, curr.ppq + excess)
            nudgePpq(curr.plan, curr.e, lifted - curr.ppq)
            curr.ppq = lifted
          end
        end
      end
    end
  end

  local function writePlans(plans)
    for _, p in ipairs(plans) do
      local kind = util.isNote(p.e) and 'note' or p.col.type
      local u    = {}
      if p.newppq    ~= nil then u.ppq    = p.newppq    end
      if p.newDelay  ~= nil then u.delay  = p.newDelay  end
      if util.isNote(p.e) and p.newEndppq ~= nil then u.endppq = p.newEndppq end
      tm:assignEvent(kind, p.e, u)
    end
  end

  -- Two bounds: same-pitch chan-wide (MIDI one-voice-per-pair) at intent end,
  -- and same-column any-pitch at neighbour's realised onset (so realised order
  -- = intent order within every column — the pb model leans on this).
  -- Floor at 0; ceiling at n.endppq − 1 so realised duration ≥ 1 ppq.
  local function delayRange(col, n)
    local sameP = function(e) return util.isNote(e) and e ~= n and e.pitch == n.pitch end
    local prevSame    = neighbourEvents(tm:getChannel(col.midiChan).columns.notes, n.ppq, sameP)
    local prevSameEnd = prevSame and prevSame.endppq

    local prev  = util.seek(col.events, 'before', n.ppq, util.isNote)
    local nextE = util.seek(col.events, 'after',  n.ppq, util.isNote)
    local realised = function(e) return e.ppq + timing.delayToPPQ(e.delay or 0, resolution) end

    local minStart = math.max(prevSameEnd or 0,
                              prev and (realised(prev) + 1) or 0)
    local maxStart = math.min(n.endppq - 1,
                              nextE and (realised(nextE) - 1) or math.huge)
    return timing.ppqToDelay(minStart - n.ppq, resolution),
           timing.ppqToDelay(maxStart - n.ppq, resolution)
  end

  ----- Show events by column, used by lots of selection ops

  local function eventsByCol()
    local r1, r2, c1, c2, part1, part2 = ec:region()
    local singleNotePart = (c1 == c2 and part1 == part2
      and grid.cols[c1] and grid.cols[c1].type == 'note') and part1 or nil

    local result = {}
    for ci = c1, c2 do
      local col = grid.cols[ci]
      if not col then goto nextCol end

      local startppq, endppq = ctx:rowToPPQ(r1, col.midiChan), ctx:rowToPPQ(r2 + 1, col.midiChan)
      local locs = {}
      -- Keyed by event reference, not loc: notes and CCs use disjoint loc
      -- spaces, so a PA (cc loc=N) and a note (note loc=N) can collide.
      for evt in util.between(col.events, startppq, endppq) do
        locs[evt] = evt
      end

      local part = col.type == 'note' and (singleNotePart or 'pitch') or 'val'
      util.add(result, { col = col, locs = locs, part = part })
      ::nextCol::
    end
    return result
  end

  ----- Frames & timing

  local function logPerRowFor(rpb)
    local denom = (timeSigs[1] and timeSigs[1].denom) or 4
    return timing.logPerRow(rpb, denom, resolution)
  end

  local isFrameChange, currentRpb, releaseTransientFrame do
    local FRAME_KEYS = { rowPerBeat = true }

    --@map:contract a write to a FRAME_KEYS member at any tier other than 'transient' counts as a real frame change — fires releaseTransientFrame from configCallback
    function isFrameChange(change)
      return FRAME_KEYS[change.key] and change.level ~= 'transient'
    end

    function currentRpb() return cm:get('rowPerBeat') end

    -- Returns true iff a transient override was released.
    function releaseTransientFrame()
      if cm:getAt('transient', 'rowPerBeat') == nil then return false end
      local oldRPB = cm:get('rowPerBeat')
      cm:assign('transient', { rowPerBeat = util.REMOVE })
      local newRPB = cm:get('rowPerBeat')
      if newRPB ~= oldRPB then
        ec:rescaleRow(oldRPB, newRPB)
        vm:rebuild(false)
      end
      return true
    end
  end

  -- Pass rowE for span events (notes).
  local function assignStamp(type, evt, chan, rowS, rowE)
    local rpb       = currentRpb()
    local logPerRow = logPerRowFor(rpb)
    local s = { ppq = rowS * logPerRow, rpb = rpb }
    if rowE then s.endppq = rowE * logPerRow end
    tm:assignEvent(type, evt, s)
  end

  --@map:contract whenever a note's tail moves: rebases evt.rpb to current alongside the new endppq
  local function assignTail(evt, chan, endppq)
    tm:assignEvent('note', evt, { endppq = endppq, rpb = currentRpb() })
  end

  local function matchGridToCursor()
    if releaseTransientFrame() then return end

    local col = grid.cols[ec:col()]
    local evt = col and col.type == 'note' and col.cells and col.cells[ec:row()]
    if not (evt and evt.rpb) then return end
    -- Rescale ec before the cm:assign so the rebuild it fires sees ec
    -- already aligned to the new rpb.
    local oldRPB = cm:get('rowPerBeat')
    if evt.rpb ~= oldRPB then ec:rescaleRow(oldRPB, evt.rpb) end
    cm:assign('transient', { rowPerBeat = evt.rpb })
  end

  function vm:setRowPerBeat(n)
    n = util.clamp(n, 1, 32)
    if n == cm:get('rowPerBeat') then return end
    -- Release before cm:set: otherwise configCallback sees a non-transient
    -- frame-key write and rescales ec on top of our own rescaleRow below.
    -- Release may itself rescale; re-read so our rescale is from the
    -- post-release rpb (no-op if release already landed us at n).
    releaseTransientFrame()
    ec:rescaleRow(cm:get('rowPerBeat'), n)
    cm:set('track', 'rowPerBeat', n)
  end

  -- props = { name, rows, mode = 'resize'|'rescale'|'tile' }; mode defaults to 'resize'.
  function vm:applyTakeProperties(props)
    if reaper.Undo_BeginBlock then reaper.Undo_BeginBlock() end
    if props.name ~= tm:name() then tm:setName(props.name) end
    local newPpq = props.rows * ctx:ppqPerRow()
    if newPpq ~= (tm:length() or 0) then
      local mode = props.mode or 'resize'
      if     mode == 'rescale' then tm:rescaleLength(newPpq)
      elseif mode == 'tile'    then tm:tileLength(newPpq)
      else                          tm:setLength(newPpq)
      end
    end
    if reaper.Undo_EndBlock then reaper.Undo_EndBlock('Take properties', -1) end
  end

  -- Slot selections (temper, swing) are views over the data, not data
  -- themselves. Mirroring at project+track means a fresh take inherits
  -- the most recent selection, while takes on an existing track inherit
  -- from their siblings via the track-level value.
  local function writeShared(key, value)
    if value == nil or value == '' then
      cm:remove('project', key)
      cm:remove('track',   key)
    else
      cm:set('project', key, value)
      cm:set('track',   key, value)
    end
  end

  function vm:setSwingSlot(name)  writeShared('swing',  name) end
  function vm:setTemperSlot(name) writeShared('temper', name) end

  -- colSwing is a per-channel map; cross-track bleed via project would
  -- mean track A's per-channel pattern surfaces on a fresh track B until
  -- B overrides every entry. Keep it track-scoped.
  function vm:setColSwingSlot(chan, name)
    local map = cm:get('colSwing')
    map[chan] = (name ~= '' and name) or nil
    cm:set('track', 'colSwing', map)
  end

  function vm:setSwingComposite(name, composite)
    if not name or name == '' then return end
    local lib = cm:getAt('project', 'swings') or {}
    lib[name] = composite
    cm:set('project', 'swings', lib)
  end

  function vm:setTemper(name, temper)
    if not name or name == '' then return end
    local lib = cm:getAt('project', 'tempers') or {}
    lib[name] = temper
    cm:set('project', 'tempers', lib)
  end

  ----- Mute / solo

  local pushMute do
    local effectiveMuted = {}

    local function toggleChannelFlag(key, chan)
      local s = cm:get(key)
      s[chan] = (not s[chan]) or nil
      cm:set('take', key, s)
    end

    --@map:contract effective mute = persistent-mute ∪ solo-implied mute; when any channel soloed, non-soloed forced muted and soloed forced audible (DAW solo-wins). Both sets persist in cm so reload's tm:lastMuteSet matches the wire
    function pushMute()
      local m = cm:get('mutedChannels')
      local s = cm:get('soloedChannels')
      if next(s) then
        for c = 1, 16 do
          if s[c] then m[c] = nil
          else        m[c] = true end
        end
      end
      effectiveMuted = m
      if tm then tm:setMutedChannels(effectiveMuted) end
    end

    function vm:isChannelMuted(chan)            return cm:get('mutedChannels')[chan]  == true end
    function vm:isChannelSoloed(chan)           return cm:get('soloedChannels')[chan] == true end
    function vm:isChannelEffectivelyMuted(chan) return effectiveMuted[chan] == true end
    function vm:toggleChannelMute(chan)         toggleChannelFlag('mutedChannels',  chan) end
    function vm:toggleChannelSolo(chan)         toggleChannelFlag('soloedChannels', chan) end
  end

  ----- Audition

  local audition, killAudition do
    local auditionNote     = nil  -- { chan, pitch } (chan is 0-indexed for MIDI)
    local auditionTime     = 0    -- reaper.time_precise() when note was sent
    local AUDITION_TIMEOUT = 0.8  -- seconds

    function killAudition()
      if not auditionNote then return end
      reaper.StuffMIDIMessage(0, 0x80 | auditionNote.chan, auditionNote.pitch, 0)
      auditionNote = nil
    end

    function audition(pitch, vel, chan)
      killAudition()
      local midiChan = (chan or 1) - 1
      reaper.StuffMIDIMessage(0, 0x90 | midiChan, pitch, vel or 100)
      auditionNote = { chan = midiChan, pitch = pitch }
      auditionTime = reaper.time_precise()
    end

    function vm:tick()
      if auditionNote and reaper.time_precise() - auditionTime > AUDITION_TIMEOUT then
        killAudition()
      end
    end
  end

  ----- Viewport

  local followViewport do
    local function lastVisibleFrom(startCol)
      local used = 0
      local last = startCol - 1
      for i = startCol, #grid.cols do
        local w = grid.cols[i].width + (i > startCol and 1 or 0)
        if used + w > gridWidth then break end
        used = used + w
        last = i
      end
      return last
    end

    function followViewport()
      local maxRow = math.max(0, (grid.numRows or 1) - 1)
      local cRow, cCol = ec:row(), ec:col()

      -- Row follow (skip before gridHeight is set to avoid inverted bounds)
      if gridHeight > 0 then
        local maxScroll = math.max(0, maxRow - gridHeight + 1)
        scrollRow = util.clamp(scrollRow,
                               math.max(0, cRow - gridHeight + 1),
                               math.min(cRow, maxScroll))
      end

      scrollCol = util.clamp(scrollCol, 1, #grid.cols)
      if cCol < scrollCol then
        scrollCol = cCol
      elseif cCol > lastVisibleFrom(scrollCol) then
        while scrollCol < cCol do
          scrollCol = scrollCol + 1
          if cCol <= lastVisibleFrom(scrollCol) then break end
        end
      end
    end

    function vm:scroll()
      return scrollRow, scrollCol, lastVisibleFrom(scrollCol)
    end
  end

  ----- Editing

  do
    local hexDigit = {}
    for i = 0, 9 do hexDigit[string.byte(tostring(i))] = i end
    for i = 0, 5 do
      hexDigit[string.byte('a') + i] = 10 + i
      hexDigit[string.byte('A') + i] = 10 + i
    end

    -- Caller has already pinned (ppq, ppqL, rpb) onto `update`.
    local function placeNewNote(col, update)
      local last = util.seek(col.events, 'before', update.ppq, util.isNote)
      local next = util.seek(col.events, 'after',  update.ppq, util.isNote)
      if last and last.endppq >= update.ppq then
        assignTail(last, col.midiChan, update.ppq)
      end
      update.vel             = last and last.vel or cm:get('defaultVelocity')
      update.endppq          = next and next.ppq or length
      update.lane            = col.lane
      if cm:get('trackerMode') then update.sample = cm:get('currentSample') end
      tm:addEvent('note', update)
    end

    local function notePAEvents(col, pitch, startppq, endppq)
      local pas = {}
      for _, evt in ipairs(col.events) do
        if evt.type == 'pa' and evt.pitch == pitch
          and evt.ppq >= startppq and evt.ppq <= endppq then
          util.add(pas, evt)
        end
      end
      return pas
    end

    --@map:contract single typed-input entry point; dispatches on (col.type, stop, evt-kind). Off-grid edits run through `snap` to repin evt.ppq to cursor row and restamp frame; commit flushes, advances by advanceBy, and may audition
    function vm:editEvent(col, evt, stop, char, half)
      if not col then return end
      local type      = col.type
      local rpbNow         = currentRpb()
      local logPerRowNow   = logPerRowFor(rpbNow)
      local cursorppq      = ec:row() * logPerRowNow

      local function commit(auditionPitch, auditionVel)
        tm:flush()
        ec:advance()
        killAudition()
        if auditionPitch then audition(auditionPitch, auditionVel or 100, col.midiChan) end
      end

      local function snap(update)
        if not evt or evt.ppq == cursorppq then return update end
        update.ppq = cursorppq
        update.rpb = rpbNow
        if evt.endppq then
          update.endppq = cursorppq + (evt.endppq - evt.ppq)
        end
        return update
      end

      -- Step delta for re-relativising typed pitch on an aliased child.
      -- Under temper, midi+detune fold to a step index (step + oct *
      -- octaveStep); the delta is the integer step difference. Without
      -- temper, the scalar MIDI delta is the step delta.
      local function pitchStepDelta(fromMidi, fromDetune, toMidi, toDetune)
        local temper = ctx:activeTemper()
        if not temper then return toMidi - fromMidi end
        local fs, fo = tuning.midiToStep(temper, fromMidi, fromDetune)
        local ts, to = tuning.midiToStep(temper, toMidi,   toDetune)
        local osStep = temper.octaveStep
        return (ts + to * osStep) - (fs + fo * osStep)
      end

      -- Within a part the cursor walks left-to-right (digit 0 = MS char,
      -- digit (width-1) = LS char). setDigit speaks position-from-LS, so
      -- the part's char-position is `(width - 1) - digit`.
      local part  = col.partAt[stop]
      local digit = stop - col.partStart[stop]

      if type == 'note' then

        if part == 'pitch' and digit == 0 then
          local nk = cmgr:noteChars(char); if not nk then return end
          local pitch = util.clamp((cm:get('currentOctave') + 1 + nk[2]) * 12 + nk[1], 0, 127)
          local detune = 0
          local temper = ctx:activeTemper()
          if temper then pitch, detune = tuning.snap(temper, pitch, 0) end

          if util.isNote(evt) then
            if evt.parentUuid then
              local d = pitchStepDelta(evt.pitch, evt.detune, pitch, detune)
              if d == 0 then return commit(pitch, evt.vel) end
              if tm:routeRelative(evt, { pitch = { 'add', d } }) then
                return commit(pitch, evt.vel)
              end
            end
            local upd = { pitch = pitch, detune = detune }
            if cm:get('trackerMode') then upd.sample = cm:get('currentSample') end
            tm:assignEvent('note', evt, snap(upd))
            return commit(pitch, evt.vel)
          end

          -- PA cell → wipe host's PA tail, then fall through
          if evt and evt.type == 'pa' then
            local host = util.seek(col.events, 'before', evt.ppq, util.isNote)
            if host and host.endppq > evt.ppq then
              for _, pa in ipairs(notePAEvents(col, host.pitch, evt.ppq, host.endppq)) do
                tm:deleteEvent('pa', pa)
              end
            else
              tm:deleteEvent('pa', evt)
            end
          end

          local new = {
            pitch = pitch, detune = detune,
            ppq = cursorppq,
            chan = col.midiChan, rpb = rpbNow,
          }
          placeNewNote(col, new)
          return commit(pitch, new.vel)

        elseif part == 'pitch' then  -- octave digit
          if not util.isNote(evt) then return end
          local oct
          if char == string.byte('-') then oct = -1
          else
            local d = char - string.byte('0')
            if d < 0 or d > 9 then return end
            oct = d
          end
          local pitch = util.clamp((oct + 1) * 12 + evt.pitch % 12, 0, 127)
          if evt.parentUuid then
            local d = pitchStepDelta(evt.pitch, evt.detune, pitch, evt.detune)
            if d == 0 then return commit(pitch, evt.vel) end
            if tm:routeRelative(evt, { pitch = { 'add', d } }) then
              return commit(pitch, evt.vel)
            end
          end
          tm:assignEvent('note', evt, { pitch = pitch })
          return commit(pitch, evt.vel)

        -- sample: 2 hex nibbles, 0..127.
        elseif part == 'sample' then
          if not util.isNote(evt) then return end
          local d = hexDigit[char]; if not d then return end
          local newSample = util.clamp(
            util.setDigit(evt.sample or 0, d, 1 - digit, 16, half), 0, 127)
          tm:assignEvent('note', evt, { sample = newSample })
          commit()
          -- After flush so the configChanged-driven rebuild reads the
          -- already-written sample rather than racing the queued assign.
          cm:set('take', 'currentSample', newSample)
          return

        -- delay: signed decimal milli-QN, 3 digits, ±999
        elseif part == 'delay' then
          if not util.isNote(evt) then return end
          local old = evt.delay

          local newDelay
          if char == string.byte('-') then
            if old == 0 then return end
            newDelay = -old
          else
            local d = char - string.byte('0')
            if d < 0 or d > 9 then return end
            local sign = old < 0 and -1 or 1
            local mag  = util.clamp(util.setDigit(math.abs(old), d, 2 - digit, 10, half), 0, 999)
            newDelay = sign * mag
          end

          local minD, maxD = delayRange(col, evt)
          newDelay = util.clamp(newDelay, math.ceil(minD), math.floor(maxD))
          tm:assignEvent('note', evt, { delay = newDelay })
          return commit()

        -- velocity nibble (on note) or PA value
        else  -- part == 'vel'
          local d = hexDigit[char]; if not d then return end
          local function newVel(old)
            return util.clamp(util.setDigit(old, d, 1 - digit, 16, half), 1, 127)
          end

          if evt and evt.type == 'pa' then
            -- Column shape stores the PA's value in `vel` (so it joins the
            -- prevVel chain like a note); mm stores it in `val`. Read the
            -- in-memory `vel` and write the update via `val`.
            tm:assignEvent('pa', evt, snap({ val = newVel(evt.vel) }))
            return commit()
          end

          if evt then
            tm:assignEvent('note', evt, { vel = newVel(evt.vel) })
            return commit()
          end

          if cm:get('polyAftertouch') then
            local note = util.seek(col.events, 'before', cursorppq, util.isNote)
            if note and note.endppq > cursorppq then
              tm:addEvent('pa', {
                ppq = cursorppq,
                chan = col.midiChan,
                pitch = note.pitch, val = newVel(0),
                rpb = currentRpb(),
              })
              return commit()
            end
          end
          return
        end
      end

      -- non-note columns
      local update
      if util.oneOf('cc at pc', type) then
        local d = hexDigit[char]; if not d then return end
        update = { val = util.clamp(util.setDigit(evt and evt.val or 0, d, 1 - digit, 16, half), 0, 127) }
      elseif type == 'pb' then
        local old = evt and evt.val or 0
        if char == string.byte('-') then
          if old == 0 then return end
          update = { val = -old }
        else
          local d = char - string.byte('0')
          if d < 0 or d > 9 then return end
          local sign = old < 0 and -1 or 1
          update = { val = sign * util.setDigit(math.abs(old), d, 3 - digit, 10, half) }
        end
      else
        return
      end

      if evt then
        tm:assignEvent(type, evt, snap(update))
      else
        if type == 'cc' then util.assign(update, { cc = col.cc }) end
        util.assign(update, {
          ppq = cursorppq,
          chan = col.midiChan, rpb = rpbNow,
        })
        tm:addEvent(type, update)
      end
      commit()
    end
  end

  ----- Lane-strip edits (drag, add, delete, shape, tension)

  -- Skips hidden absorbers; returns nil if i out of range.
  local function visibleAt(col, i)
    if not col or not col.events then return end
    local k = 0
    for _, e in ipairs(col.events) do
      if not e.hidden then
        k = k + 1
        if k == i then return e end
      end
    end
  end

  --@map:contract clamps newppq strictly inside (prev.ppq, next.ppq) by ±1 — necessary-and-sufficient invariant for identity-by-visible-index to survive the post-flush rebuild
  function vm:moveLaneEvent(col, i, toRow, toVal)
    if not col or not col.events then return end
    if not util.oneOf('cc pb at', col.type) then return end

    local visible = {}
    for _, e in ipairs(col.events) do
      if not e.hidden then util.add(visible, e) end
    end
    local evt = visible[i]
    if not evt then return end

    local chan       = col.midiChan
    local prev, next = visible[i-1], visible[i+1]
    local newppq     = ctx:rowToPPQ(toRow, chan)
    if prev and newppq <= prev.ppq then newppq = prev.ppq + 1 end
    if next and newppq >= next.ppq then newppq = next.ppq - 1 end
    if prev and newppq <= prev.ppq then return end  -- gap < 2 ppq, nowhere to go

    tm:assignEvent(col.type, evt, { val = toVal, ppq = newppq, rpb = currentRpb() })
    tm:flush()
  end

  -- Inherits prev visible's envelope shape so prev→next curve survives the new midpoint.
  -- Returns the new event's visible index post-flush for drag-seed.
  function vm:addLaneEvent(col, colIdx, ppq, val)
    if not col or not util.oneOf('cc pb at', col.type) then return end
    local chan = col.midiChan
    local prev = util.seek(col.events, 'before', ppq,
                           function(e) return not e.hidden end)
    local update = {
      val   = val,
      ppq   = ppq,
      chan  = chan,
      rpb   = currentRpb(),
      shape = prev and prev.shape or nil,
    }
    if col.type == 'cc' then update.cc = col.cc end
    tm:addEvent(col.type, update)
    tm:flush()

    local newCol = grid.cols[colIdx]
    if not newCol then return end
    local idx = 0
    for _, e in ipairs(newCol.events) do
      if not e.hidden then
        idx = idx + 1
        if e.ppq == ppq then return idx end
      end
    end
  end

  function vm:deleteLaneEvent(col, i)
    if not col or not util.oneOf('cc pb at', col.type) then return end
    local evt = visibleAt(col, i)
    if not evt then return end
    tm:deleteEvent(col.type, evt)
    tm:flush()
  end

  -- Set bezier tension on the i-th visible event. Forces shape to bezier
  -- so the tension is honoured (REAPER ignores tension on other shapes).
  function vm:setLaneTension(col, i, tension)
    if not col or not util.oneOf('cc pb at', col.type) then return end
    local A = visibleAt(col, i)
    if not A then return end
    tm:assignEvent(col.type, A, { tension = tension, shape = 'bezier' })
    tm:flush()
  end

  ----- Interpolation

  local interpolate, interpolateValues do
    local interpolable = { cc = true, pb = true, at = true }
    local shapeCycle = { 'step', 'linear', 'slow', 'fast-start', 'fast-end', 'bezier' }

    local function nextShape(s)
      for i, n in ipairs(shapeCycle) do
        if n == s then return shapeCycle[(i % #shapeCycle) + 1] end
      end
      return 'linear'
    end

    local function cycleShape(col, A)
      if not A then return end
      tm:assignEvent(col.type, A, { shape = nextShape(A.shape or 'step') })
    end

    -- Cycle the segment-owner's shape on the i-th visible event in a
    -- cc/pb/at column. Segment-owner = left endpoint (REAPER convention:
    -- A.shape governs the curve from A to next).
    function vm:cycleLaneShape(col, i)
      if not col or not interpolable[col.type] then return end
      local A = visibleAt(col, i)
      if not A then return end
      cycleShape(col, A)
      tm:flush()
    end

    -- Refused-on-aliased: interpolate writes computed absolute values
    -- (cycleShape → assignEvent on shape). On an aliased child this would
    -- sever and lose the spec relationship; partially skipping aliased
    -- events would produce a misleading curve. Whole command no-ops.
    local function refuseAliased()
      reaper.ShowMessageBox(
        'interpolate: aliased event(s) in scope. Sever (Ctrl+.) first.',
        'interpolate refused', 0)
    end

    function interpolate()
      if ec:hasSelection() then
        local r1, r2 = ec:region()
        local plans = {}
        for col in ec:eachSelectedCol() do
          if interpolable[col.type] then
            local startppq = ctx:rowToPPQ(r1,     col.midiChan)
            local endppq   = ctx:rowToPPQ(r2 + 1, col.midiChan)
            local evts = {}
            for evt in util.between(col.events, startppq, endppq) do
              if evt.parentUuid then refuseAliased(); return end
              evts[#evts + 1] = evt
            end
            plans[#plans + 1] = { col = col, evts = evts }
          end
        end
        for _, p in ipairs(plans) do
          for i = 1, #p.evts - 1 do cycleShape(p.col, p.evts[i]) end
        end
        tm:flush()
        return
      end

      local col = grid.cols[ec:col()]
      if not (col and interpolable[col.type]) then return end
      local r = ec:row()
      local ghost = col.ghosts and col.ghosts[r]
      local A = ghost and ghost.fromEvt
        or (col.cells and col.cells[r])
        or util.seek(col.events, 'before', ctx:rowToPPQ(r + 1, col.midiChan))
      if not A then return end
      if A.parentUuid then refuseAliased(); return end
      cycleShape(col, A); tm:flush()
    end

    -- Returns nil for non-interpolable cols so callers can assign unconditionally.
    function interpolateValues(col)
      if not interpolable[col.type] then return end
      local events, chan, occupied = col.events, col.midiChan, col.cells
      local ghosts = {}
      for i = 1, #events - 1 do
        local A, B = events[i], events[i + 1]
        if A.shape and A.shape ~= 'step' then
          local rA = ctx:ppqToRow(A.ppq, chan)
          local rB = ctx:ppqToRow(B.ppq, chan)
          for y = util.round(rA) + 1, util.round(rB) - 1 do
            if y >= 0 and y < grid.numRows and not (occupied and occupied[y]) then
              local val = tm:interpolate(A, B, ctx:rowToPPQ(y, chan))
              ghosts[y] = { val = util.round(val), fromEvt = A, toEvt = B }
            end
          end
        end
      end
      return ghosts
    end
  end

  ----- Duration & position

  local noteOff, adjustDuration, adjustPosition do
    local function cursorNoteBefore()
      local col = grid.cols[ec:col()]
      if not (col and col.type == 'note') then return end
      local cursorppq = ctx:rowToPPQ(ec:row(), col.midiChan)
      return col, util.seek(col.events, 'at-or-before', cursorppq, util.isNote)
    end

    -- Aliased: tail moves route durL relative; the zero/negative-duration
    -- branch routes through deleteAliased so spec-tree descendants promote
    -- in place rather than vanishing with the swept materialisation.
    local function applyNoteOff(col, last, targetppq, undo)
      if undo then
        local next = util.seek(col.events, 'at-or-after', targetppq, util.isNote)
        local newEnd = next and next.ppq or length
        if last.parentUuid
           and tm:routeRelative(last, { durL = { 'add', newEnd - last.endppq } }) then
          return
        end
        assignTail(last, col.midiChan, newEnd)
      elseif last.ppq >= targetppq then
        if last.parentUuid and tm:deleteAliased(last) then return end
        tm:deleteEvent('note', last)
      else
        local _, maxEnd = overlapBounds(col, last.ppq, last, true)
        local newEnd    = util.clamp(targetppq, last.ppq + 1, maxEnd)
        if last.parentUuid
           and tm:routeRelative(last, { durL = { 'add', newEnd - last.endppq } }) then
          return
        end
        assignTail(last, col.midiChan, newEnd)
      end
    end

    function noteOff()
      if ec:hasSelection() then
        local r1 = ec:region()
        local hits = {}
        for col in ec:eachSelectedCol() do
          if col.type == 'note' then
            local chan = col.midiChan
            local targetppq = ctx:rowToPPQ(r1, chan)
            local nextPPQ   = ctx:rowToPPQ(r1 + 1, chan)
            local last = util.seek(col.events, 'before', nextPPQ, util.isNote)
            if last then util.add(hits, { col = col, note = last, targetppq = targetppq }) end
          end
        end
        if #hits == 0 then return end

        local undo = true
        for _, h in ipairs(hits) do
          if h.note.endppq ~= h.targetppq then undo = false; break end
        end

        for _, h in ipairs(hits) do applyNoteOff(h.col, h.note, h.targetppq, undo) end
        tm:flush()
        return
      end

      local col = grid.cols[ec:col()]
      if not (col and col.type == 'note' and ec:cursorPart() == 'pitch') then return false end
      local r = ec:row()
      local cursorppq     = ctx:rowToPPQ(r,     col.midiChan)
      local nextCursorPPQ = ctx:rowToPPQ(r + 1, col.midiChan)

      local last = util.seek(col.events, 'before', nextCursorPPQ, util.isNote)
      if not last then return end
      applyNoteOff(col, last, cursorppq, last.endppq == cursorppq)
      tm:flush()
    end

    local function adjustDurationCore(col, note, rowDelta)
      local chan      = col.midiChan
      local logPerRow = ctx:ppqPerRow()
      local curRow    = note.endppq / logPerRow
      local newRow    = util.clamp(util.round(curRow + rowDelta), 0, grid.numRows)
      local minPPQ    = math.min(note.endppq, ctx:rowToPPQ(ctx:snapRow(note.ppq, chan) + 1, chan))
      local _, maxPPQ = overlapBounds(col, note.ppq, note, true)
      local newppq    = util.clamp(ctx:rowToPPQ(newRow, chan), minPPQ, maxPPQ)
      if newppq == note.endppq then return end
      if note.parentUuid
         and tm:routeRelative(note, { durL = { 'add', newRow * logPerRow - note.endppq } }) then
        return
      end
      assignTail(note, chan, newppq)
    end

    function adjustDuration(rowDelta)
      if ec:hasSelection() then
        for _, group in ipairs(eventsByCol()) do
          if group.col.type == 'note' then
            for _, note in pairs(group.locs) do
              adjustDurationCore(group.col, note, rowDelta)
            end
          end
        end
      else
        local col, note = cursorNoteBefore()
        if note then adjustDurationCore(col, note, rowDelta) end
      end
      tm:flush()
    end

    local function adjustPositionMulti(rowDelta)
      if rowDelta == 0 then return end
      local logPerRow = ctx:ppqPerRow()
      local runs = {}
      for _, g in ipairs(eventsByCol()) do
        if g.col.type == 'note' then
          local ns = {}
          for _, n in pairs(g.locs) do util.add(ns, n) end
          if #ns > 0 then
            table.sort(ns, function(a, b) return a.ppq < b.ppq end)
            if rowDelta > 0 then
              local _, maxRow = rowBounds(g.col, ns[#ns].ppq, ns[#ns], true)
              if maxRow - ns[#ns].endppq / logPerRow < rowDelta then return end
            else
              local minRow = rowBounds(g.col, ns[1].ppq, ns[1], true)
              if minRow - ns[1].ppq / logPerRow > rowDelta then return end
            end
            util.add(runs, { col = g.col, notes = ns })
          end
        end
      end
      if #runs == 0 then return end

      -- resizeNote moves PBs in the note's ppq range; within each run, process in
      -- the direction that keeps shifted PBs out of unprocessed notes' ranges.
      for _, r in ipairs(runs) do
        local chan = r.col.midiChan
        local notes = r.notes
        local s, e, step = 1, #notes, 1
        if rowDelta > 0 then s, e, step = #notes, 1, -1 end
        for i = s, e, step do
          local n = notes[i]
          local rowS = ctx:ppqToRow(n.ppq,    chan) + rowDelta
          local rowE = ctx:ppqToRow(n.endppq, chan) + rowDelta
          assignStamp('note', n, chan, rowS, rowE)
        end
      end
      tm:flush()
      ec:shiftSelection(rowDelta)
    end

    -- Off-grid neighbours pull integer row inward via ceil/floor (item-start
    -- guard: ceil(0) = 0 catches newStart = -1); on-grid under non-trivial
    -- swing reads ppqL exactly so round-trip noise can't refuse the slot.
    -- Cursor follows by rowDelta unless that row already holds another note.
    function adjustPosition(rowDelta)
      if ec:hasSelection() then return adjustPositionMulti(rowDelta) end

      local col, note = cursorNoteBefore()
      if not col or not note then return end
      local chan = col.midiChan

      local newStart = ctx:snapRow(note.ppq,    chan) + rowDelta
      local newEnd   = ctx:snapRow(note.endppq, chan) + rowDelta
      local minRow, maxRow = rowBounds(col, note.ppq, note, true)
      if newStart < minRow or newEnd > maxRow then return end

      local newCursorRow = ec:row() + rowDelta
      local cursorBlocked = false
      for _, e in ipairs(col.events) do
        if util.isNote(e) and e ~= note
           and ctx:snapRow(e.ppq, chan) == newCursorRow then
          cursorBlocked = true; break
        end
      end

      local logPerRow = logPerRowFor(currentRpb())
      if not (note.parentUuid
              and tm:routeRelative(note, { ppqL = { 'add', newStart * logPerRow - note.ppq } })) then
        assignStamp('note', note, chan, newStart, newEnd)
      end
      tm:flush()
      if not cursorBlocked then ec:setPos(newCursorRow) end
    end
  end

  ----- Reswing / quantize

  do

    -- Every column, every event, as a groups list (for *-all variants).
    local function allGroups()
      local groups = {}
      for _, col in ipairs(grid.cols) do
        local locs = {}
        for _, e in ipairs(col.events) do locs[e.loc] = e end
        util.add(groups, { col = col, locs = locs })
      end
      return groups
    end

    --@map:contract skips events without evt.rpb (foreign-imported); plan→mutate so reads stay stable; clamps plan ppq to take length to stop MIDI_Sort auto-extending the source; rpb left untouched (ppqL is truth)
    local function reswingCore(groups, opts)
      local plans = {}
      local notePlansByChan = {}
      for _, g in ipairs(groups) do
        local col, chan = g.col, g.col.midiChan
        for _, e in pairs(g.locs) do
          if e.rpb and (not opts.include or opts.include(e, chan)) then
            local tgt   = opts.target(chan)
            local entry = { col = col, e = e,
              newppq = math.min(length, util.round(tgt.fromLogical(chan, e.ppqL))) }
            if util.isNote(e) then
              entry.newEndppq = math.min(length, util.round(tgt.fromLogical(chan, e.endppqL)))
              notePlansByChan[chan] = notePlansByChan[chan] or {}
              util.add(notePlansByChan[chan], entry)
            end
            util.add(plans, entry)
          end
        end
      end

      -- Pass 1.5: clamp delays so realised order = intent order under
      -- the post-reswing geometry. delayRange enforces this on direct
      -- edits; reswing changes intent ppqs without touching delay, so
      -- a delay that fit the old gap can spill into the new one. Walk
      -- each channel's note plans in new intent order, tracking the
      -- last realised onset per column (same-col bound) and last
      -- intent end per pitch (same-pitch bound) — same two bounds
      -- delayRange uses, sourced from post-reswing positions.
      local clamped = 0
      for _, list in pairs(notePlansByChan) do
        table.sort(list, function(a, b) return a.newppq < b.newppq end)
        local lastInCol, lastInPitch = {}, {}
        for _, p in ipairs(list) do
          local e = p.e
          local realised = p.newppq + timing.delayToPPQ(e.delay or 0, resolution)
          local floor    = 0
          local prevCol  = lastInCol[p.col]
          if prevCol   then floor = math.max(floor, prevCol.realised + 1) end
          local prevPit  = lastInPitch[e.pitch]
          if prevPit   then floor = math.max(floor, prevPit.newEndppq)   end
          if realised < floor then
            p.newDelay = math.ceil(timing.ppqToDelay(floor - p.newppq, resolution))
            realised   = p.newppq + timing.delayToPPQ(p.newDelay, resolution)
            clamped    = clamped + 1
          end
          lastInCol[p.col]     = { realised = realised, newEndppq = p.newEndppq }
          lastInPitch[e.pitch] = { realised = realised, newEndppq = p.newEndppq }
        end
      end

      -- Pass 2: conform overlaps that monotone-but-rounded
      -- swing.fromLogical may have nudged past noteColumnAccepts'
      -- threshold (or onto the same ppq). Without this, allocator
      -- rejects the persisted lane and the successor drifts.
      conformOverlaps(plans)

      -- conformOverlaps nudges raw mid-plan, so reswing must ship raw and
      -- ppqL together — see "Caller speaks raw" in docs/timing.md.
      for _, p in ipairs(plans) do
        local e, u = p.e, {}
        if p.newppq then
          u.ppq  = p.newppq
          u.ppqL = e.ppqL
        end
        if p.newEndppq ~= nil and util.isNote(e) then
          u.endppq  = p.newEndppq
          u.endppqL = e.endppqL
        end
        if p.newDelay ~= nil then u.delay = p.newDelay end
        if next(u) then tm:assignEvent(util.isNote(e) and 'note' or p.col.type, e, u) end
      end
      tm:flush()

      if clamped > 0 then
        reaper.ShowMessageBox(
          clamped .. ' note(s) reswung — delay clamped at realised-order bound.',
          'reswing', 0)
      end
    end

    local function reswingScope(groups)
      local curSnap = tm:swingSnapshot()
      reswingCore(groups, { target = function() return curSnap end })
    end

    -- Sever aliased children that have plans, before the writes commit.
    -- Sever preserves each event's mm-uuid and loc, so the plan list keyed
    -- on `e` references stays valid; the metadata-clear assigns merge
    -- by-loc with the ppq/endppq writes that follow inside the same flush.
    -- Only planned events are severed — on-grid aliased col-mates in scope
    -- stay attached to the spec. Aliasing roots, planned or not, are left
    -- intact: root ppq moves, descendants compose against it on rebuild.
    local function severAliasedPlans(plans)
      local hits = {}
      for _, p in ipairs(plans) do
        if p.e.parentUuid then util.add(hits, p.e) end
      end
      if #hits > 0 then tm:severBatch(hits) end
    end

    -- Plan-then-write so conformOverlaps can clip plan geometry against
    -- col-mates before the writes commit. Two off-grid col-mates can
    -- otherwise quantize-collapse onto the same ppq (or onto adjacent
    -- rows whose post-snap distance crosses the lenient threshold),
    -- and the allocator would reject the persisted lane on rebuild.
    local function quantizeScope(groups)
      local plans = {}
      for _, g in ipairs(groups) do
        local col, chan = g.col, g.col.midiChan
        for _, e in pairs(g.locs) do
          local sRow   = ctx:ppqToRow(e.ppq, chan)
          local newRow = util.round(sRow)
          local newppq = ctx:rowToPPQ(newRow, chan)
          if util.isNote(e) then
            local newEndRow = newRow + util.round(ctx:ppqToRow(e.endppq, chan) - sRow)
            local newEndppq = ctx:rowToPPQ(newEndRow, chan)
            if newppq ~= e.ppq or newEndppq ~= e.endppq then
              util.add(plans, { col = col, e = e,
                newppq = newppq, newEndppq = newEndppq })
            end
          elseif newppq ~= e.ppq then
            util.add(plans, { col = col, e = e, newppq = newppq })
          end
        end
      end

      conformOverlaps(plans)
      severAliasedPlans(plans)
      writePlans(plans)
      tm:flush()
    end

    -- Plan-then-write so conformOverlaps can adjust newppq before delay re-derives.
    --@map:contract intent ppq snaps to nearest row; delay absorbs the inverse to preserve realised onset; endppq held; delay clamped at delayRange; popup reports clamps
    local function quantizeKeepRealisedScope(groups)
      local plans, clamped = {}, 0
      for _, g in ipairs(groups) do
        local col, chan = g.col, g.col.midiChan
        for _, e in pairs(g.locs) do
          local newRow = ctx:snapRow(e.ppq, chan)
          local newppq = ctx:rowToPPQ(newRow, chan)
          if newppq ~= e.ppq then
            util.add(plans, { col = col, e = e, newppq = newppq })
          end
        end
      end

      conformOverlaps(plans)

      for _, p in ipairs(plans) do
        if util.isNote(p.e) then
          local realised = p.e.ppq + timing.delayToPPQ(p.e.delay, resolution)
          local ideal    = timing.ppqToDelay(realised - p.newppq, resolution)
          local dMin, dMax = delayRange(p.col, p.e)
          p.newDelay = util.clamp(ideal, dMin, dMax)
          if p.newDelay ~= ideal then clamped = clamped + 1 end
        end
      end

      severAliasedPlans(plans)
      writePlans(plans)
      tm:flush()

      if clamped > 0 then
        reaper.ShowMessageBox(
          clamped .. ' note(s) partially quantized — delay clamped at overlap bound.',
          'quantize keep realised', 0)
      end
    end

    function vm:reswingSelection()              reswingScope(eventsByCol())              end
    function vm:reswingAll()                    reswingScope(allGroups())                 end
    function vm:quantizeSelection()             quantizeScope(eventsByCol())              end
    function vm:quantizeAll()                   quantizeScope(allGroups())                end
    function vm:quantizeKeepRealisedSelection() quantizeKeepRealisedScope(eventsByCol())  end
    function vm:quantizeKeepRealisedAll()       quantizeKeepRealisedScope(allGroups())    end
  end

  local insertRow, deleteRow, insertRowCol, deleteRowCol do
    -- Fake pbs are tm-managed absorbers tied to note seats — row ops
    -- shift only real events and leave fake pbs to tm's reconcile.
    local function notFake(e) return not e.fake end

    local function shiftPlan(col, e, dLogical)
      local entry = { col = col, e = e, newppq = e.ppq + dLogical }
      if util.isNote(e) then
        entry.newEndppq = math.min(e.endppq + dLogical, length)
      end
      return entry
    end

    local function insertRowCore(col, topRow, numRows)
      local chan = col.midiChan
      local logPerRow = logPerRowFor(currentRpb())
      local C        = ctx:rowToPPQ(topRow, chan)
      local dLogical = numRows * logPerRow

      local plans, deletes = {}, {}
      for e in util.between(col.events, C, length, notFake) do
        local p = shiftPlan(col, e, dLogical)
        if p.newppq >= length then util.add(deletes, { col = col, evt = e })
        else                       util.add(plans, p) end
      end

      conformOverlaps(plans)
      for _, d in ipairs(deletes) do tm:deleteEvent(d.col.type, d.evt) end
      writePlans(plans)

      if col.type == 'note' then
        local spanning = util.seek(col.events, 'before', C, util.isNote)
        if spanning and spanning.endppq > C then
          assignTail(spanning, chan, math.min(spanning.endppq + dLogical, length))
        end
      end
    end

    local function deleteRowCore(col, topRow, numRows)
      local chan = col.midiChan
      local logPerRow = logPerRowFor(currentRpb())
      local C        = ctx:rowToPPQ(topRow, chan)
      local D        = ctx:rowToPPQ(topRow + numRows, chan)
      local dLogical = numRows * logPerRow

      if col.type == 'note' then
        local spanning = util.seek(col.events, 'before', C, util.isNote)
        if spanning and spanning.endppq > C then
          if spanning.endppq > D then
            assignTail(spanning, chan, spanning.endppq - dLogical)
          else
            assignTail(spanning, chan, C)
          end
        end
      end

      local plans, deletes = {}, {}
      for e in util.between(col.events, C, length, notFake) do
        if e.ppq < D then util.add(deletes, { col = col, evt = e })
        else              util.add(plans, shiftPlan(col, e, -dLogical)) end
      end

      conformOverlaps(plans)
      for _, d in ipairs(deletes) do tm:deleteEvent(d.col.type, d.evt) end
      writePlans(plans)
    end

    -- `noSelCols` picks the column set when no selection is active.
    local function forEachRowOp(core, preSel, noSelCols)
      if ec:hasSelection() then
        if preSel then preSel() end
        local r1, r2 = ec:region()
        for col in ec:eachSelectedCol() do core(col, r1, r2 - r1 + 1) end
      else
        for _, col in ipairs(noSelCols()) do core(col, ec:row(), 1) end
      end
      tm:flush()
    end

    local function allCols() return grid.cols end
    local function curCol()
      local c = grid.cols[ec:col()]
      return c and { c } or {}
    end

    function insertRow()    forEachRowOp(insertRowCore, nil, allCols) end
    function deleteRow()    forEachRowOp(deleteRowCore, function() clipboard:copy() end, allCols) end
    function insertRowCol() forEachRowOp(insertRowCore, nil, curCol) end
    function deleteRowCol() forEachRowOp(deleteRowCore, function() clipboard:copy() end, curCol) end
  end

  ----- Nudge

  local nudge do
    local function pitchStep(coarse)
      if not coarse then return 1 end
      local t = ctx:activeTemper()
      return t and t.octaveStep or 12
    end

    -- Coarse snap interval per column type. nil = no coarse (pc).
    local function valueInterval(col)
      if col.type == 'cc' or col.type == 'at' then return 8
      elseif col.type == 'pb'                 then return 100
      end
    end

    local function valueBounds(col)
      if col.type == 'pb' then local lim = cm:get('pbRange') * 100; return -lim, lim end
      return 0, 127
    end

    local function nudgePitch(col, note, dir, coarse, audible)
      if note.parentUuid then
        local field = coarse and 'octave' or 'pitch'
        if tm:routeRelative(note, { [field] = { 'add', dir } }) then return end
      end
      local delta  = dir * pitchStep(coarse)
      local temper = ctx:activeTemper()
      local pitch, detune
      if temper then
        pitch, detune = tuning.transposeStep(temper, note.pitch, note.detune, delta)
      else
        pitch, detune = util.clamp(note.pitch + delta, 0, 127), note.detune
      end
      if pitch == note.pitch and detune == note.detune then return end
      tm:assignEvent('note', note, { pitch = pitch, detune = detune })
      if audible then audition(pitch, note.vel, col.midiChan) end
    end

    local function nudgeVel(note, dir, coarse)
      local newVel = util.nudgedScalar(note.vel, 1, 127, dir, coarse and 8 or nil)
      if newVel == note.vel then return end
      if note.parentUuid
         and tm:routeRelative(note, { vel = { 'add', newVel - note.vel } }) then return end
      tm:assignEvent('note', note, { vel = newVel })
    end

    local function nudgeDelay(col, note, dir, coarse)
      local minD, maxD = delayRange(col, note)
      local old = note.delay
      local new = util.nudgedScalar(old, math.ceil(minD), math.floor(maxD), dir, coarse and 10 or nil)
      if new == old then return end
      if note.parentUuid
         and tm:routeRelative(note, { delay = { 'add', new - old } }) then return end
      tm:assignEvent('note', note, { delay = new })
    end

    local function nudgeValue(col, evt, dir, coarse)
      local lo, hi   = valueBounds(col)
      local newVal   = util.nudgedScalar(evt.val, lo, hi, dir, coarse and valueInterval(col) or nil)
      if newVal == evt.val then return end
      if evt.parentUuid
         and tm:routeRelative(evt, { val = { 'add', newVal - evt.val } }) then return end
      tm:assignEvent(col.type, evt, { val = newVal })
    end

    local function applyNudge(col, evt, part, dir, coarse, audible)
      if     part == 'val'   then nudgeValue(col, evt, dir, coarse)
      elseif part == 'vel'   then nudgeVel(evt, dir, coarse)
      elseif part == 'delay' then nudgeDelay(col, evt, dir, coarse)
      elseif part == 'pitch' then nudgePitch(col, evt, dir, coarse, audible) end
    end

    -- PAs skipped on note cols.
    local function cursorRowEvent(col)
      if not col then return end
      local r = ec:row()
      local lo, hi = ctx:rowToPPQ(r, col.midiChan), ctx:rowToPPQ(r + 1, col.midiChan)
      local pred = col.type == 'note' and util.isNote or nil
      local evt = util.seek(col.events, 'at-or-after', lo, pred)
      if evt and evt.ppq < hi then return evt end
    end

    -- Column-typed nudge. Selection rule: if any note event is selected,
    -- transpose / velocity- / delay-nudge the notes and leave value events
    -- alone; otherwise nudge val on every value event. Solo cursor: first
    -- event in the cursor row, column- and part-typed.
    function nudge(dir, coarse)
      if ec:hasSelection() then
        local groups = eventsByCol()

        local anyNote = false
        for _, g in ipairs(groups) do
          if g.col.type == 'note' then
            for _, e in pairs(g.locs) do
              if util.isNote(e) then anyNote = true; break end
            end
            if anyNote then break end
          end
        end

        for _, g in ipairs(groups) do
          local skip = g.part == 'val' and anyNote
          if not skip then
            for _, e in pairs(g.locs) do
              if g.part == 'val' or util.isNote(e) then
                applyNudge(g.col, e, g.part, dir, coarse, false)
              end
            end
          end
        end
        tm:flush()
        return
      end

      local col = grid.cols[ec:col()]
      local evt = cursorRowEvent(col)
      if not evt then return end
      applyNudge(col, evt, ec:cursorPart(), dir, coarse, true)
      tm:flush()
    end
  end

  ----- Deletion

  local deleteEvent, deleteSelection do
    -- Delete notes; extend each predecessor that ended at-or-past a deleted run
    -- into the next survivor's start (or `length`). PAs are out of scope here.
    -- Fixups are computed before any mutation: tm:assignEvent's same-key clamp
    -- reads live state, so we must delete first and stretch second.
    local function queueDeleteNotes(col, locs)
      local chan = col.midiChan
      local fixups = {}
      local lastSurvivor, pendingFixup = nil, false
      for _, evt in ipairs(col.events) do
        if evt.type ~= 'pa' then
          if locs[evt] then
            if not pendingFixup and lastSurvivor and lastSurvivor.endppq >= evt.ppq then
              pendingFixup = true
            end
          else
            if pendingFixup then
              util.add(fixups, { evt = lastSurvivor, endppq = evt.ppq })
            end
            pendingFixup = false
            lastSurvivor = evt
          end
        end
      end
      if pendingFixup then
        util.add(fixups, { evt = lastSurvivor, endppq = length })
      end

      for _, evt in pairs(locs) do
        if evt.type ~= 'pa' then tm:deleteEvent('note', evt) end
      end
      for _, f in ipairs(fixups) do
        assignTail(f.evt, chan, f.endppq)
      end
    end

    ---@diagnostic disable-next-line: unused-local
    local function queueResetDelays(col, locs)
      for _, evt in pairs(locs) do
        if evt.type ~= 'pa' and evt.delay ~= 0 then
          tm:assignEvent('note', evt, { delay = 0 })
        end
      end
    end

    -- Reset selected note vels to the prior event's vel (notes or PAs carry
    -- forward); delete selected PAs outright.
    local function queueResetVelocities(col, locs)
      local prevVel = cm:get('defaultVelocity')
      for _, evt in ipairs(col.events) do
        if locs[evt] then
          if evt.type == 'pa' then
            tm:deleteEvent('pa', evt)
          else
            tm:assignEvent('note', evt, { vel = prevVel })
          end
        else
          prevVel = evt.vel
        end
      end
    end

    local function queueDeleteCCs(col, locs)
      for _, evt in pairs(locs) do tm:deleteEvent(col.type, evt) end
    end

    local DELETE_BY_PART = {
      pitch  = queueDeleteNotes,
      vel    = queueResetVelocities,
      delay  = queueResetDelays,
      val    = queueDeleteCCs,
      sample = function() end,
    }

    -- Pitch-column delete on an aliased event (or on a root with descendants)
    -- is structural: route through tm:deleteAliased, which removes the spec
    -- node and promotes its children to new roots. Tail-fixup logic doesn't
    -- apply — the materialised event vanishes via the rebuild sweep, with
    -- no cross-event extension across structural deletes.
    function deleteEvent()
      local col = grid.cols[ec:col()]
      if not col then return end
      local r = ec:row()
      local evt = col.cells and col.cells[r]
      if not evt then
        -- Delete on a ghost cell: unset interpolation on the governing event.
        local ghost = col.ghosts and col.ghosts[r]
        if ghost then
          tm:assignEvent(col.type, ghost.fromEvt, { shape = 'step' })
          tm:flush()
        end
        return
      end
      local part = col.type == 'note' and ec:cursorPart() or 'val'
      if part == 'pitch' and tm:deleteAliased(evt) then
        tm:flush()
        return
      end
      DELETE_BY_PART[part](col, { [evt] = evt })
      tm:flush()
    end

    function deleteSelection()
      for _, g in ipairs(eventsByCol()) do
        if g.part == 'pitch' then
          local rest = {}
          for k, evt in pairs(g.locs) do
            if not tm:deleteAliased(evt) then rest[k] = evt end
          end
          if next(rest) then DELETE_BY_PART[g.part](g.col, rest) end
        else
          DELETE_BY_PART[g.part](g.col, g.locs)
        end
      end
      tm:flush()
      ec:selClear()
    end
  end

  local function deleteOrBackspace()
    if ec:isSticky() then deleteSelection()
    else ec:selClear(); deleteEvent(); ec:advance() end
  end

  --@map:contract sever the aliased event(s) under attention: selection if
  -- present, else the cursor event. Plain (non-aliased) events are ignored.
  -- Each aliased hit is plucked from its root's spec tree and promoted into
  -- a new root (see tm:sever); the next rebuild re-emits its descendants
  -- under the new root.
  local function severCmd()
    local hits = {}
    if ec:hasSelection() then
      for _, g in ipairs(eventsByCol()) do
        for _, e in pairs(g.locs) do
          if e.parentUuid then util.add(hits, e) end
        end
      end
    else
      local col = grid.cols[ec:col()]
      local evt = col and col.cells and col.cells[ec:row()]
      if evt and evt.parentUuid then util.add(hits, evt) end
    end
    if #hits == 0 then return end
    tm:severBatch(hits)
    tm:flush()
  end

  -- Step currentSample by ±1 across the full 0..127 range. Empty slots
  -- are reachable — the user may want to author a sample value before
  -- the sampler has loaded that slot.
  local function stepSample(dir)
    cm:set('take', 'currentSample',
           util.clamp(cm:get('currentSample') + dir, 0, 127))
  end

  ----- Duplicate

  -- Cache of the clip captured on the first duplicate of a run. Subsequent
  -- immediate duplicates re-paste this clip rather than re-collecting, so the
  -- alias-mode `aliasSrc` (uuid, specPath, ppqL) stays anchored to the
  -- original source. Cleared by `doBefore` on every other tracker command.
  local dupeClip = nil

  --@map:contract upward duplication past row 0 trims the top of the clip (start cut, not end), so repeated upward stamps stay anchored at the cursor; never touches user clipboard. First call collects; subsequent immediate calls re-paste the cached clip so successive duplicates anchor to the original source row (matters for alias mode).
  local function duplicate(dir)
    local clip = dupeClip or clipboard:collect()
    if not clip then return end
    local r1, r2, c1, c2, part1, part2 = ec:region()
    local numRows   = r2 - r1 + 1
    local targetRow = dir > 0 and r2 + 1 or r1 - numRows
    local trim      = targetRow < 0 and -targetRow or 0
    targetRow       = math.max(targetRow, 0)
    local effRows   = numRows - trim
    if effRows <= 0 or targetRow >= (grid.numRows or 0) then return end

    if trim > 0 then clipboard:trimTop(clip, trim) end

    local savedRow, savedCol, savedStop = ec:pos()
    ec:setPos(targetRow, ec:regionStart())

    clipboard:pasteClip(clip)

    local shift = targetRow - r1
    ec:setPos(savedRow + shift, savedCol, savedStop)
    if ec:hasSelection() then
      ec:setSelection{ row1 = targetRow, row2 = targetRow + effRows - 1,
                       col1 = c1, col2 = c2, part1 = part1, part2 = part2 }
    end
    dupeClip = clip
  end

  ---------- PUBLIC

  function vm:ec()        return ec end
  function vm:clipboard() return clipboard end

  ----- Accessors for trackerPage

  function vm:rowPerBar()      return rowPerBar end
  function vm:takeName()       return tm:name() end
  function vm:activeTemper()   return ctx:activeTemper() end
  function vm:noteProjection(evt) return ctx:noteProjection(evt) end
  function vm:rowBeatInfo(row) return ctx:rowBeatInfo(row) end
  function vm:barBeatSub(row) return ctx:barBeatSub(row) end
  function vm:ppqToRow(ppq, chan) return ctx:ppqToRow(ppq, chan) end
  function vm:rowToPPQ(row, chan) return ctx:rowToPPQ(row, chan) end
  function vm:sampleCurve(A, B, ppq) return tm:interpolate(A, B, ppq) end
  function vm:timeSig()
    local ts = timeSigs[1] or { num = 4, denom = 4 }
    return ts.num, ts.denom
  end

  ----- Non-command callbacks from trackerPage

  function vm:setGridSize(w, h)
    gridWidth, gridHeight = w, h
  end

  ----- Columns

  function vm:addExtraCol(type, cc)
    local extras = cm:get('extraColumns')
    local seen = {}
    for col in ec:eachSelectedCol() do
      local chan = col.midiChan
      if not seen[chan] then
        seen[chan] = true
        -- Absence-default mirrors tm:rebuild's: no entry means one implicit
        -- note col. Seeding 0 here would erase that col on the next rebuild.
        local want = extras[chan] or { notes = 1 }
        extras[chan] = want
        if type == 'note' then
          want.notes = want.notes + 1
        elseif type == 'cc' then
          want.ccs = want.ccs or {}
          want.ccs[cc] = true
        else
          ---@diagnostic disable-next-line: assign-type-mismatch
          want[type] = true
        end
      end
    end
    cm:set('take', 'extraColumns', extras)
  end

  function vm:hideExtraCol()
    local col = grid.cols[ec:col()]
    if not col then return end
    local chan = col.midiChan

    -- Note col with delay shown: strip the delay first; the column itself
    -- only goes on a subsequent hide.
    if col.type == 'note' then
      local lane = col.lane
      local nd = cm:get('noteDelay')
      local chanMap = nd[chan]
      if chanMap and chanMap[lane] then
        chanMap[lane] = nil
        nd[chan] = next(chanMap) and chanMap
        cm:set('take', 'noteDelay', next(nd) and nd)
        vm:rebuild()
        return
      end
    end

    if #col.events > 0 then return end

    local extras = cm:get('extraColumns')
    local want   = extras[chan] or { notes = 0 }
    extras[chan] = want

    if col.type == 'note' then
      local noteCols = {}
      for ci = grid.chanFirstCol[chan], grid.chanLastCol[chan] do
        local c = grid.cols[ci]
        if c.type == 'note' then util.add(noteCols, c) end
      end
      if #noteCols <= 1 then return end
      -- Lane is rebuild-only at tm (assignNote rejects lane writes), so
      -- we can't shift higher lanes down to close an interior hole. Only
      -- the topmost empty lane can be hidden; to drop interior empties,
      -- the user hides from the right inwards.
      if col.lane ~= #noteCols then return end
      want.notes = #noteCols - 1
    elseif col.type == 'cc' then
      if want.ccs then
        want.ccs[col.cc] = nil
        if not next(want.ccs) then want.ccs = nil end
      end
    else
      want[col.type] = nil
    end

    if want.notes == 0 and not (want.pc or want.pb or want.at or want.ccs) then
      extras[chan] = nil
    end
    cm:set('take', 'extraColumns', next(extras) and extras)
    vm:rebuild()
  end

  function vm:showDelay()
    local nd = cm:get('noteDelay')
    local changed = false
    for col in ec:eachSelectedCol() do
      if col.type == 'note' then
        local chanMap = nd[col.midiChan] or {}
        if not chanMap[col.lane] then
          chanMap[col.lane] = true
          nd[col.midiChan] = chanMap
          changed = true
        end
      end
    end
    if changed then cm:set('take', 'noteDelay', nd) end
  end

  ----- Command table

  local tracker = cmgr:scope('tracker')

  tracker:registerAll{
    cut                     = function() clipboard:copy(); deleteSelection() end,
    delete                  = deleteOrBackspace,
    interpolate             = function() interpolate() end,
    deleteSel               = function() deleteSelection() end,
    duplicateDown           = function() duplicate( 1) end,
    duplicateUp             = function() duplicate(-1) end,
    toggleAliasMode         = function() vm.aliasMode = not vm.aliasMode end,
    sever                   = severCmd,
    inputOctaveUp           = function() cm:set('take', 'currentOctave', util.clamp(cm:get('currentOctave')+1, -1, 9)) end,
    inputOctaveDown         = function() cm:set('take', 'currentOctave', util.clamp(cm:get('currentOctave')-1, -1, 9)) end,
    inputSampleUp           = function() stepSample( 1) end,
    inputSampleDown         = function() stepSample(-1) end,
    noteOff                 = noteOff,
    growNote                = function() adjustDuration(1) end,
    shrinkNote              = function() adjustDuration(-1) end,
    nudgeBack               = function() adjustPosition(-1) end,
    nudgeForward            = function() adjustPosition(1) end,
    insertRow               = function() insertRow() end,
    deleteRow               = function() deleteRow() end,
    insertRowCol            = function() insertRowCol() end,
    deleteRowCol            = function() deleteRowCol() end,
    nudgeCoarseUp           = function() nudge( 1, true)  end,
    nudgeCoarseDown         = function() nudge(-1, true)  end,
    nudgeFineUp             = function() nudge( 1, false) end,
    nudgeFineDown           = function() nudge(-1, false) end,
    playFromTop             = function() tm:playFrom(0) end,
    playFromCursor          = function()
      local col = grid.cols[ec:col()]
      tm:playFrom(ctx:rowToPPQ(ec:row(), col and col.midiChan))
    end,
    addNoteCol              = function() vm:addExtraCol('note') end,
    hideExtraCol            = function() vm:hideExtraCol() end,
    doubleRPB               = function() vm:setRowPerBeat(cm:get('rowPerBeat') * 2) end,
    halveRPB                = function() vm:setRowPerBeat(math.floor(cm:get('rowPerBeat') / 2)) end,
    matchGridToCursor       = matchGridToCursor,
  }

  for i = 0, 9 do
    tracker:register('advBy' .. i, function() cm:set('take', 'advanceBy', i) end)
  end

  ----- Rebuild

  local rebuilding = false

  --@map:contract reentrancy-guarded; bails on no-take (page shows placeholder); takeChanged=true resets ec + re-reads resolution/length/timeSigs; grid/rowPPQs/ctx/cell-maps/ghosts rebuild unconditionally; pushMute at end
  function vm:rebuild(takeChanged)
    if not tm or rebuilding then return end
    if not tm:currentTake() then return end
    rebuilding = true
    takeChanged = takeChanged or false

    local LABELS = {
      note = 'Note', cc = 'CC', pb = 'PB', at = 'AT', pa = 'PA', pc = 'PC',
    }

    -- Length, resolution and timeSigs all change without a take swap:
    -- length on resize (take properties), resolution under tempo changes,
    -- timeSigs on edits to the project's tempo/time-sig markers.
    resolution = tm:resolution()
    length     = tm:length()
    timeSigs   = tm:timeSigs()
    if takeChanged then ec:reset() end

    do
      local rpb = cm:get('rowPerBeat')
      -- Grid resolution is pinned to the first time sig's denominator;
      -- mid-item time sig changes affect bar/beat highlighting but not row size.
      local denom = timeSigs[1] and timeSigs[1].denom or 4
      local num   = timeSigs[1] and timeSigs[1].num or 4
      rowPerBar = rpb * num
      local ppqPerRow = (resolution * 4 / denom) / rpb

      grid.cols         = {}
      grid.chanFirstCol = {}
      grid.chanLastCol  = {}
      grid.lane1Col     = {}

      local noteDelayCfg = cm:get('noteDelay')
      local trackerMode  = cm:get('trackerMode')

      local function addGridCol(chan, type, key, events)
        local showDelay = type == 'note' and (noteDelayCfg[chan] or {})[key] or false

        local gridCol = {
          type        = type,
          cc          = type == 'cc'   and key or nil,
          lane        = type == 'note' and key or nil,
          label       = LABELS[type] or '',
          events      = events or {},
          showDelay   = showDelay,
          trackerMode = type == 'note' and trackerMode or nil,
          midiChan    = chan,
          cells       = {},
        }
        ec:decorateCol(gridCol)   -- stamps parts/stopPos/partAt/partStart/width
        util.add(grid.cols, gridCol)
        grid.chanFirstCol[chan] = grid.chanFirstCol[chan] or #grid.cols
        grid.chanLastCol[chan]  = #grid.cols
        if type == 'note' and key == 1 then grid.lane1Col[chan] = gridCol end
      end

      for chan, channel in tm:channels() do
        local c = channel.columns
        if c.pc and not trackerMode then addGridCol(chan, 'pc', nil, c.pc.events) end
        if c.pb then addGridCol(chan, 'pb', nil,  c.pb.events) end
        for lane, col in ipairs(c.notes) do addGridCol(chan, 'note', lane, col.events) end
        if c.at then addGridCol(chan, 'at', nil,  c.at.events) end
        local ccNums = {}
        for n in pairs(c.ccs) do util.add(ccNums, n) end
        table.sort(ccNums)
        for _, n in ipairs(ccNums) do addGridCol(chan, 'cc', n, c.ccs[n].events) end
      end

      -- Stored as floats so rowToPPQ/ppqToRow are mutually exact (single round
      -- only at realisation) and on-grid tests collapse to integer compare.
      rowPPQs = {}
      local r = 0
      while true do
        local ppq = r * ppqPerRow
        if ppq >= length and r > 0 then break end
        rowPPQs[r] = ppq
        r = r + 1
      end

      local numRows = r
      grid.numRows = numRows

      ctx = newViewContext{
        swing      = tm:swingSnapshot(),
        rowPPQs    = rowPPQs,
        length     = length,
        numRows    = numRows,
        rowPerBeat = rpb,
        ppqPerRow  = ppqPerRow,
        timeSigs   = timeSigs,
        temper     = tuning.findTemper(cm:get('temper'), cm:get('tempers')),
      }

      for _, gridCol in ipairs(grid.cols) do
        gridCol.overflow = {}
        gridCol.offGrid  = {}
        if gridCol.type == 'note' then gridCol.tails = {} end
        local chan = gridCol.midiChan
        for _, evt in ipairs(gridCol.events) do
          local startRow = ctx:ppqToRow(evt.ppq or 0, chan)
          local y        = util.round(startRow)
          if y >= 0 and y < numRows then
            if gridCol.cells[y] then
              gridCol.overflow[y] = true
            else
              gridCol.cells[y] = evt
              if ctx:rowToPPQ(y, chan) ~= evt.ppq then gridCol.offGrid[y] = true end
            end
          end
          if evt.endppq then
            util.add(gridCol.tails, {
              startRow = startRow,
              endRow   = ctx:ppqToRow(evt.endppq, chan),
            })
          end
        end
      end

      for _, gridCol in ipairs(grid.cols) do
        gridCol.ghosts = interpolateValues(gridCol)
      end

      -- Layout changed but no cursor move; re-clamp + re-follow viewport.
      ec:clampPos(); followViewport()
    end
    pushMute()
    rebuilding = false
  end

  ----- Lifecycle

  do
    -- Mute/solo changes don't affect grid shape, so skip rebuild.
    local muteKeys = { mutedChannels = true, soloedChannels = true }

    local pendingTakeSwap = false
    tm:subscribe('takeSwapped', function() pendingTakeSwap = true end)
    tm:subscribe('rebuild', function()
      vm:rebuild(pendingTakeSwap)
      pendingTakeSwap = false
    end)
    --@map:contract vm consumes configChanged only for transient-frame release and mute pulse; rebuild is driven by tm's 'rebuild' signal — closes the (cm, tm) double-fire race
    --@map:contract non-transient writes to FRAME_KEYS while a transient override is active short-circuit into releaseTransientFrame, whose recursive cm:assign fires a fresh configChanged → tm:rebuild → vm:rebuild chain
    cm:subscribe('configChanged', function(change)
      if isFrameChange(change) and releaseTransientFrame() then return end
      if muteKeys[change.key] then pushMute(); return end
    end)
  end

  ----- Factory load

  ec = newEditCursor {
    grid       = grid,
    cm         = cm,
    rowPerBar  = function() return rowPerBar end,
    moveHook   = followViewport,
  }

  clipboard = newClipboard {
    ec = ec, grid = grid, tm = tm, cm = cm,
    currentRpb   = currentRpb,
    assignTail   = assignTail,
    getCtx       = function() return ctx end,
    getLength    = function() return length end,
    getAliasMode = function() return vm.aliasMode end,
  }

  ec:registerCommands(tracker)
  clipboard:registerCommands(tracker)

  tracker:doAfter({
    'nudgeCoarseUp', 'nudgeCoarseDown', 'nudgeFineUp', 'nudgeFineDown',
    'nudgeBack', 'nudgeForward', 'growNote', 'shrinkNote',
    'duplicateDown', 'duplicateUp', 'interpolate', 'insertRow',
    'deleteRow', 'insertRowCol', 'deleteRowCol', 'noteOff',
  }, function() ec:unstick() end)

  tracker:doAfter({ 'delete', 'deleteSel', 'cut' }, function() ec:selClear() end)

  tracker:doBefore({
    'cursorDown', 'cursorUp', 'pageDown', 'pageUp',
    'goTop', 'goBottom', 'goLeft', 'goRight',
    'cursorRight', 'cursorLeft', 'selectDown', 'selectUp',
    'selectRight', 'selectLeft', 'selectClear', 'colRight',
    'colLeft', 'channelRight', 'channelLeft', 'delete',
  }, killAudition)

  -- Any non-duplicate command breaks the duplicate run.
  do
    local keep = { duplicateDown = true, duplicateUp = true }
    local clearOn = {}
    for name in pairs(tracker.commands) do
      if not keep[name] then clearOn[#clearOn + 1] = name end
    end
    tracker:doBefore(clearOn, function() dupeClip = nil end)
  end

  vm:rebuild(true)
  return vm
end
