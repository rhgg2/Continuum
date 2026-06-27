-- See docs/trackerView.md for the model.

--invariant: rows 0-indexed, cols 1-indexed, channels 1..16, stops 1-indexed
--invariant: vm.grid is a live handle; rm reads it each frame
--invariant: vm.grid is mutated in place on rebuild, never reassigned
--invariant: rm is pull-only; vm fires no render callbacks
--invariant: rm queries vm.grid / vm:ec() / vm:rowPerBar() each frame
--invariant: writes go via tm (add/assign/delete/flush Event); vm never touches mm
--invariant: vm works in logical time and detune-intent for pitch
--invariant: vm never reads/writes raw pb directly (docs/tuning.md)
--invariant: authoring stamps evt.rpb and evt.ppq = row·logPerRow before tm:addEvent
--invariant: off-grid edits snap evt.ppq to cursor row; delay survives, rpb restamps
--invariant: clipboard encodes rows in source's logical frame; paste decodes against dest's rpb
--invariant: clipboard symmetry is on (row, chan), not absolute ppq
--shape: grid = { cols, chanFirstCol, chanLastCol, lane1Col, numRows }
--invariant: grid.chanFirst/Last/lane1Col are chan-keyed; numRows is int
--shape: gridCol core = { type, midiChan, [lane], [cc], label, events, width }
--shape: gridCol parts = { parts, stopPos, partAt, partStart, showDelay }
--shape: gridCol render = { cells={[y]=evt}, overflow, offGrid, ghosts, [tails] }
--shape: selection = { row1, row2, col1, col2, part1, part2 }
--invariant: selection part names: pitch/vel/delay on note; pb on pb; val on scalar
--shape: plan = { col, e, [newppq], [newEndppq], [newDelay] }
--invariant: plan is consumed by writePlans / conformOverlaps

local util       = require 'util'
local timing     = require 'timing'
local tuning     = require 'tuning'

local tm, cm, ds, cmgr, gm, pa, facade =
  (...).tm, (...).cm, (...).ds, (...).cmgr, (...).gm, (...).pa, (...).facade

local function arrange() return facade.get('arrange') end

local function print(...)
  return util.print(...)
end

---------- STATE

local resolution    = 240
local rowPerBar     = 16
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


local tv = {}
tv.grid = grid  -- live handle for rm; mutated in place on rebuild

----- Selection — the tracker's own (track, slot), held in cm, decoupled from the arrange cursor.
-- Writers mutate cm only; trackerPage's bindFromSelection binds. See docs/trackerPage.md § Selection.

-- Nearest extant slot to `desired` in the ascending midiSlots list: the exact
-- slot, else the lowest above it, else the highest below it. nil ⇒ no slots.
local function recoverSlot(slots, desired)
  if not slots[1] then return nil end
  if desired == nil then return slots[1].idx end
  local below
  for _, slot in ipairs(slots) do
    if slot.idx == desired then return desired end
    if slot.idx >  desired then return slot.idx end
    below = slot.idx
  end
  return below
end

local function selectedTrackIdx()
  local guid = cm:getAt('project', 'trackerTrack')
  return guid and arrange().trackIdxForGuid(guid) or nil
end

local function effectiveSlot(trackIdx)
  return recoverSlot(arrange().midiSlots(trackIdx), cm:getAt('track', 'trackerSlot'))
end

function tv:currentTrackIdx() return selectedTrackIdx() end
function tv:currentSlotIdx()
  local trackIdx = selectedTrackIdx()
  return trackIdx and effectiveSlot(trackIdx) or nil
end

-- Resolve the stored (track, slot) to a live take. A vanished slot walks to the
-- nearest extant one and writes through, so storage tracks what's displayed.
function tv:resolveSelectionTake()
  local trackIdx = selectedTrackIdx()
  if not trackIdx then return nil end
  -- A page switch leaves the track tier unbound (tracker's unbind clears cm context); re-key it to
  -- the selection's track before any trackerSlot read/write, exactly as selectTrack does.
  local track = arrange().trackHandle(trackIdx)
  if track and track ~= cm:boundTrack() then cm:setTrack(track) end
  local stored    = cm:getAt('track', 'trackerSlot')
  local effective = recoverSlot(arrange().midiSlots(trackIdx), stored)
  if effective == nil then return nil end
  if effective ~= stored then cm:set('track', 'trackerSlot', effective) end
  return arrange().takeForSlot(trackIdx, effective)
end

--contract: parked take hosts on scratch; re-point track tier at the selection's track so
-- per-track reads (swing seed, trackerSlot) stay coherent. See docs § Selection.
function tv:retargetTrackTier()
  local take = tm:currentTake()
  if not (take and arrange().isParkedTake(take)) then return end
  local trackIdx = selectedTrackIdx(); if not trackIdx then return end
  local track = arrange().trackHandle(trackIdx)
  if track then cm:setTrack(track) end
end

--contract: point at a track by GUID; optSlot pins a slot, else restore its last-viewed slot
function tv:selectTrack(guid, optSlot)
  local trackIdx = arrange().trackIdxForGuid(guid)
  if not trackIdx then return end
  cm:set('project', 'trackerTrack', guid)
  cm:setTrack(arrange().trackHandle(trackIdx))     -- track-tier read/write targets this track
  local desired   = optSlot or cm:getAt('track', 'trackerSlot')
  local effective = recoverSlot(arrange().midiSlots(trackIdx), desired)
  if effective ~= nil then cm:set('track', 'trackerSlot', effective) end
end

--contract: pin a slot on the current track
function tv:selectSlot(slotIdx) cm:set('track', 'trackerSlot', slotIdx) end

--contract: step ±1 over all tracks (may land on an empty one); restores its last slot
function tv:gotoTrack(dir)
  local cur    = selectedTrackIdx()
  local target = cur and arrange().tracks()[cur + 1 + dir]
  if target then self:selectTrack(target.guid) end
end

--contract: step ±1 slot on the current track, from the effective slot
function tv:gotoTake(dir)
  local trackIdx = selectedTrackIdx()
  if not trackIdx then return end
  local slots = arrange().midiSlots(trackIdx)
  local cur   = effectiveSlot(trackIdx)
  local pos
  for i, slot in ipairs(slots) do if slot.idx == cur then pos = i end end
  local target = pos and slots[pos + dir]
  if target then self:selectSlot(target.idx) end
end

function tv:pickTrack(trackIdx)
  local tr = arrange().tracks()[trackIdx + 1]
  if tr then self:selectTrack(tr.guid) end
end
function tv:pickTake(slotIdx) self:selectSlot(slotIdx) end

--contract: mint an empty parked take on the current track, select it; returns its slot
function tv:newParkedTake(name, beats)
  local trackIdx = selectedTrackIdx(); if not trackIdx then return end
  local slot = arrange().mintParkedTake(trackIdx, name, beats)
  if slot then self:selectSlot(slot) end
  return slot
end

--contract: clone the bound take (unpooled) into a fresh parked slot, select it, return slotIdx
function tv:duplicateBoundUnpooled()
  local trackIdx = selectedTrackIdx(); if not trackIdx then return end
  local src = tm:currentTake(); if not src then return end
  local slot = arrange().mintParkedTake(trackIdx, '', nil, src)
  if not slot then return end
  self:selectSlot(slot)
  return slot
end

local ec, clipboard, ctx

---------- SHARED HELPERS

----- Note geometry (used by editing, adjust*, nudge, quantizeKeepRealised)

-- Onset-only: prev maximises onset (nearest predecessor before ppq),
-- nxt minimises onset (nearest successor). Neighbour tails never enter
-- here -- tm's universal tail pass clips an overrun on rebuild, so a
-- tail must not bound a move (the rowBounds/shiftEvents rule).
local function neighbourEvents(cols, ppq, pred)
  local prev, nxt
  for _, c in ipairs(cols) do
    local p = util.seek(c.events, 'before', ppq, pred)
    local n = util.seek(c.events, 'after',  ppq, pred)
    if p and (not prev or p.ppq > prev.ppq) then prev = p end
    if n and (not nxt  or n.ppq < nxt.ppq ) then nxt  = n end
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
-- Onset-only, like rowBounds: bounds are neighbour ONSETS, never tails --
-- tm clips a tail overrun on the next rebuild.
local function overlapBounds(col, ppq, excludeEvt, allowOverlap)
  local lenient = allowOverlap and cm:get('overlapOffset') * resolution or 0
  local diff, same = notePreds(excludeEvt)

  local prevD, nextD = neighbourEvents({col}, ppq, diff)
  local prevS, nextS = neighbourEvents(tm:getChannel(col.midiChan).columns.notes, ppq, same)

  local minStart = math.max(prevD and (prevD.ppq - lenient) or 0,      prevS and prevS.ppq or 0)
  local maxEnd   = math.min(nextD and (nextD.ppq + lenient) or length, nextS and nextS.ppq or length)
  return minStart, maxEnd
end

-- Row-space onset band for a moved note: the inclusive [minRow, maxRow]
-- its onset may occupy without reordering against a neighbour. Bounds
-- are the *onsets* of the nearest diff-pitch col-local and same-pitch
-- chan-wide neighbours -- never their tails. A tail an onset move
-- overruns is clipped by tm's universal tail pass on the next rebuild,
-- so it must not bound the move (mirrors shiftEvents' reorder-not-tail
-- rule). No prev -> the -1 sentinel makes minRow 0, the item-start
-- guard. e.ppq is exact logical-ppq post-projection.
--contract: onset-only; tails never bound the move (tm clips overrun on rebuild)
local function rowBounds(col, ppq, excludeEvt)
  local logPerRow = ctx:ppqPerRow()
  local diff, same = notePreds(excludeEvt)

  local prevD, nextD = neighbourEvents({col}, ppq, diff)
  local prevS, nextS = neighbourEvents(tm:getChannel(col.midiChan).columns.notes, ppq, same)

  local fullL      = grid.numRows * logPerRow
  local prevOnsetL = math.max(prevD and prevD.ppq or -1,    prevS and prevS.ppq or -1)
  local nextOnsetL = math.min(nextD and nextD.ppq or fullL, nextS and nextS.ppq or fullL)
  return math.floor(prevOnsetL / logPerRow) + 1,
         math.ceil (nextOnsetL / logPerRow) - 1
end

--contract: resolves same-onset plan collisions in a per-column plan list (mutates in place)
--invariant: fromLogical is monotone but not isotone; two logical onsets can round onto one raw ppq
--contract: later-source-ppq plan (curr by tie-break) shifts up 1 ppq, else predecessor shifts back
--invariant: tail overlaps NOT resolved here; tm's universal tail pass owns every raw note-off
--contract: skips non-note plans/cols; optional `deleted` event-set excluded from the walk
--invariant: deleted corpses still live in col.events snapshot until next rebuild
local function conformOverlaps(plans, deleted)
  local skip = {}
  if deleted then for _, e in ipairs(deleted) do skip[e] = true end end
  local plansByCol = {}
  for _, plan in ipairs(plans) do
    if util.isNote(plan.e) then
      plansByCol[plan.col] = plansByCol[plan.col] or {}
      util.add(plansByCol[plan.col], plan)
    end
  end
  for col, colPlans in pairs(plansByCol) do
    local planByEvt = {}
    for _, plan in ipairs(colPlans) do planByEvt[plan.e] = plan end

    local timeline = {}
    for _, e in ipairs(col.events) do
      if util.isNote(e) and not skip[e] then
        local plan = planByEvt[e]
        util.add(timeline, { e = e, plan = plan,
          ppq = (plan and plan.newppq) or e.ppq })
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
    end
  end
end

-- Sort by shift direction so a still-old same-pitch peer vacates
-- before its slot gets written. Without this, assignEvent's
-- clearSameKeyRange kills the not-yet-moved peer.
local function writePlans(plans)
  local netShift = 0
  for _, p in ipairs(plans) do
    if p.newppq then netShift = netShift + (p.newppq - p.e.ppq) end
  end
  if netShift ~= 0 then
    local desc = netShift > 0
    table.sort(plans, function(a, b)
      local an, bn = a.newppq or a.e.ppq, b.newppq or b.e.ppq
      if desc then return an > bn else return an < bn end
    end)
  end
  for _, p in ipairs(plans) do
    local u    = {}
    if p.newppq    ~= nil then u.ppq    = p.newppq    end
    if p.newDelay  ~= nil then u.delay  = p.newDelay  end
    if util.isNote(p.e) and p.newEndppq ~= nil then u.endppq = p.newEndppq end
    tm:assignEvent(p.e, u)
  end
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

-- The mirror region's per-stream identity, derived from the column (the
-- column IS the stream): evType:key, key = lane for notes, cc-number for
-- cc, 0 otherwise. Index-free, so it survives column insert/reorder.
local function streamIdOf(col)
  local key = col.type == 'note' and (col.lane or 1)
           or col.type == 'cc'   and (col.cc or 0)
           or 0
  return col.type .. ':' .. tostring(key)
end

----- Frames & timing

local function logPerRowFor(rpb)
  local denom = (timeSigs[1] and timeSigs[1].denom) or 4
  return timing.logPerRow(rpb, denom, resolution)
end

local isFrameChange, currentRpb, releaseTransientFrame do
  local FRAME_KEYS = { rowPerBeat = true }

  --contract: a non-transient write to a FRAME_KEYS member is a real frame change
  --contract: real frame change fires releaseTransientFrame from configCallback
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
      tv:rebuild(false)
    end
    return true
  end
end

-- Pass rowE for span events (notes).
local function assignStamp(evt, chan, rowS, rowE)
  local rpb       = currentRpb()
  local logPerRow = logPerRowFor(rpb)
  local s = { ppq = rowS * logPerRow, rpb = rpb }
  if rowE then s.endppq = rowE * logPerRow end
  tm:assignEvent(evt, s)
end

-- Authoring a tail authors a finite ceiling: passing endppq with no
-- endppqL makes tm stamp the ceiling from this note-off (closing a
-- previously util.OPEN note), so the universal tail pass honours it
-- instead of treating the note as unbounded every rebuild.
--contract: on tail move: stamps endppqL ceiling via tm; rebases evt.rpb alongside endppq
local function assignTail(evt, chan, endppq)
  tm:assignEvent(evt, { endppq = endppq, rpb = currentRpb() })
end

-- Shift onset to rowS and shift endppq by the same ppq delta. endppq
-- is the authored logical ceiling (endppqL), which may run past the
-- take length when an earlier move overshot. Routing it through a row
-- here would clamp to numRows (ctx:ppqToRow) and erase the overshoot,
-- so any further inward move can't regrow the tail. util.OPEN stays open.
local function assignNoteMove(evt, rowS)
  local rpb       = currentRpb()
  local logPerRow = logPerRowFor(rpb)
  local newPpq    = rowS * logPerRow
  local newEnd    = evt.endppq == util.OPEN and util.OPEN
                    or evt.endppq + (newPpq - evt.ppq)
  tm:assignEvent(evt, { ppq = newPpq, endppq = newEnd, rpb = rpb })
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

function tv:setRowPerBeat(n)
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

-- props = { name, beats, mode = 'resize'|'rescale'|'tile' }; mode defaults to 'resize'.
-- Length is universal beats; rows = round(beats * rpb), floored at 1 row.
tv.applyTakeProperties = util.atomic('Take properties', function(self, props)
  if props.name ~= tm:name() then tm:setName(props.name) end
  local rows   = math.max(1, math.floor(props.beats * currentRpb() + 0.5))
  local newPpq = rows * ctx:ppqPerRow()
  if newPpq ~= (tm:length() or 0) then
    local mode = props.mode or 'resize'
    if     mode == 'rescale' then tm:rescaleLength(newPpq)
    elseif mode == 'tile'    then tm:tileLength(newPpq)
    else                          tm:setLength(newPpq)
    end
  end
end)

-- swing is take document data: one map { global=name, [chan]=name }. defaultSwing
-- mirrors that shape across config tiers as a pure seed (copied in on bind, never realised).
local function setTakeSwing(slot, value)
  local map = ds:get('swing') or {}
  map[slot] = value
  ds:assign('swing', map)
end

local function setDefaultSwing(tier, slot, value)
  local map = cm:getAt(tier, 'defaultSwing') or {}
  map[slot] = value
  cm:set(tier, 'defaultSwing', map)
end

-- Picking a library swing copies its composite into the project tier if absent,
-- so the project is self-contained. See docs/swingEditor.md § Library tiers.
local function localizeSwing(name)
  if not name or name == '' or name == 'identity' then return end
  local proj = cm:getAt('project', 'swings') or {}
  if proj[name] ~= nil then return end
  local composite = cm:get('swings', { mergeTiers = true })[name]
  if composite ~= nil then
    proj[name] = composite
    cm:set('project', 'swings', proj)
  end
end

-- Take-wide swing: the take map's 'global' slot + project & track seed.
function tv:setSwingSlot(name)
  if name == nil or name == '' then name = 'identity' end
  localizeSwing(name)
  setTakeSwing('global', name)
  setDefaultSwing('project', 'global', name)
  setDefaultSwing('track',   'global', name)
end

-- Per-channel swing: the take map's channel slot + track seed only
-- (the project tier carries 'global' alone, never per-channel).
function tv:setColSwingSlot(chan, name)
  local value = (name ~= '' and name) or nil
  if value then localizeSwing(value) end
  setTakeSwing(chan, value)
  setDefaultSwing('track', chan, value)
end

function tv:setTemperSlot(name)
  if name == nil or name == '' then name = '12EDO' end
  cm:set('take',    'temper', name)
  cm:set('track',   'temper', name)
  cm:set('project', 'temper', name)
end

--contract: bind materialises a take's swing from defaultSwing (identity floor); no-op once set
function tv:seedSharedSlots()
  if ds:get('swing') == nil then
    ds:assign('swing', cm:get('defaultSwing'))   -- merged read floors to identity, so an Off take sticks
  end
end

function tv:setSwingComposite(name, composite, tier)
  if not name or name == '' then return end
  tier = tier or 'project'
  local lib = cm:getAt(tier, 'swings') or {}
  lib[name] = composite
  cm:set(tier, 'swings', lib)
end

function tv:setTemper(name, temper, tier)
  if not name or name == '' then return end
  tier = tier or 'project'
  local lib = cm:getAt(tier, 'tempers') or {}
  lib[name] = temper
  cm:set(tier, 'tempers', lib)
end

----- Mute / solo

local pushMute do
  local effectiveMuted = {}

  local function toggleChannelFlag(key, chan)
    local s = ds:get(key) or {}
    s[chan] = (not s[chan]) or nil
    ds:assign(key, s)
  end

  --contract: effective mute = persistent-mute ∪ solo-implied mute
  --invariant: any solo: non-soloed forced muted, soloed forced audible (DAW solo-wins)
  --invariant: both sets persist in ds so reload's tm:lastMuteSet matches the wire
  function pushMute()
    local m = ds:get('mutedChannels') or {}
    local s = ds:get('soloedChannels') or {}
    if next(s) then
      for c = 1, 16 do
        if s[c] then m[c] = nil
        else        m[c] = true end
      end
    end
    effectiveMuted = m
    if tm then tm:setMutedChannels(effectiveMuted) end
  end

  function tv:isChannelMuted(chan)            return (ds:get('mutedChannels') or {})[chan]  == true end
  function tv:isChannelSoloed(chan)           return (ds:get('soloedChannels') or {})[chan] == true end
  function tv:isChannelEffectivelyMuted(chan) return effectiveMuted[chan] == true end
  function tv:toggleChannelMute(chan)         toggleChannelFlag('mutedChannels',  chan) end
  function tv:toggleChannelSolo(chan)         toggleChannelFlag('soloedChannels', chan) end
end

----- Audition

local audition, killAudition do
  local auditionNote     = nil  -- { chan, pitch } (chan is 0-indexed for MIDI)
  local auditionTime     = 0    -- reaper.time_precise() when note was sent
  local AUDITION_TIMEOUT = 0.8  -- seconds

  -- Detune→live pitch-bend on the audition channel; mirrors tm's centsToRaw
  -- slope so the preview bends like the seated note (synth range = pbRange).
  local function sendBend(chan, cents)
    local lim  = cm:get('pbRange') * 100
    local raw  = util.clamp(util.round((cents or 0) * 8192 / lim), -8192, 8191)
    local wire = raw + 8192
    reaper.StuffMIDIMessage(0, 0xE0 | chan, wire & 0x7F, (wire >> 7) & 0x7F)
  end

  function killAudition()
    if not auditionNote then return end
    reaper.StuffMIDIMessage(0, 0x80 | auditionNote.chan, auditionNote.pitch, 0)
    sendBend(auditionNote.chan, 0)
    auditionNote = nil
  end

  function audition(pitch, vel, chan, detune)
    killAudition()
    local midiChan = (chan or 1) - 1
    sendBend(midiChan, detune)
    reaper.StuffMIDIMessage(0, 0x90 | midiChan, pitch, vel or 100)
    auditionNote = { chan = midiChan, pitch = pitch }
    auditionTime = reaper.time_precise()
  end

  function tv:tick()
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

  function tv:scroll()
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

  -- Caller has already pinned (ppq, ppqL, rpb) onto `update`. A freshly
  -- placed note is unbounded: author endppq = util.OPEN. tm stamps the
  -- open ceiling and a provisional raw note-off; the universal tail
  -- pass derives the real tail (next onset / take length) every
  -- rebuild.
  local function placeNewNote(col, update)
    local prev    = util.seek(col.events, 'before', update.ppq, util.isNote)
    update.vel    = prev and prev.vel or cm:get('defaultVelocity')
    update.endppq = util.OPEN
    update.lane   = col.lane
    if cm:get('trackerMode') then update.sample = cm:get('currentSample') end
    update.evType = 'note'
    tm:addEvent(update)
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

  --contract: single typed-input entry point; dispatches on (col.type, stop, evt-kind)
  --contract: off-grid edits run through snap to repin evt.ppq to cursor row and restamp frame
  --contract: commit flushes, advances by advanceBy, and may audition
  function tv:editEvent(col, evt, stop, char, half)
    if not col then return end
    local type      = col.type
    local rpbNow         = currentRpb()
    local logPerRowNow   = logPerRowFor(rpbNow)
    local cursorppq      = ec:row() * logPerRowNow

    local function commit(auditionPitch, auditionVel, auditionDetune)
      -- The one mutation that bypasses cmgr (trackerPage's char drain
      -- calls editEvent direct), so the keep-set doBefore sweeps never
      -- see it: end every cascade by hand.
      tv:endAllCascades()
      tm:flush()
      ec:advance()
      killAudition()
      if auditionPitch then audition(auditionPitch, auditionVel or 100, col.midiChan, auditionDetune) end
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
          local upd = { pitch = pitch, detune = detune }
          if cm:get('trackerMode') then upd.sample = cm:get('currentSample') end
          tm:assignEvent(evt, snap(upd))
          return commit(pitch, evt.vel, detune)
        end

        -- PA cell → wipe host's PA tail, then fall through
        if evt and evt.type == 'pa' then
          local host = util.seek(col.events, 'before', evt.ppq, util.isNote)
          if host and host.endppq > evt.ppq then
            for _, pa in ipairs(notePAEvents(col, host.pitch, evt.ppq, host.endppq)) do
              tm:deleteEvent(pa)
            end
          else
            tm:deleteEvent(evt)
          end
        end

        local new = {
          pitch = pitch, detune = detune,
          ppq = cursorppq,
          chan = col.midiChan, rpb = rpbNow,
        }
        placeNewNote(col, new)
        return commit(pitch, new.vel, detune)

      elseif part == 'pitch' then  -- octave digit
        if not util.isNote(evt) then return end
        local oct
        if char == string.byte('-') then oct = -1
        else
          local d = char - string.byte('0')
          if d < 0 or d > 9 then return end
          oct = d
        end
        -- Octave column edits the period-cycle octave: keep the step,
        -- re-derive, reject if it clamps out of MIDI range (|detune|>½ st).
        local temper = ctx:activeTemper()
        local pitch, detune
        if temper then
          local step = tuning.midiToStep(temper, evt.pitch, evt.detune)
          local bump = step >= temper.octaveStep and 1 or 0
          pitch, detune = tuning.stepToMidi(temper, step, oct - bump)
          if math.abs(detune) > 50 then return end
        else
          pitch, detune = util.clamp((oct + 1) * 12 + evt.pitch % 12, 0, 127), evt.detune
        end
        tm:assignEvent(evt, { pitch = pitch, detune = detune })
        return commit(pitch, evt.vel, detune)

      -- sample: 2 hex nibbles, 0..127.
      elseif part == 'sample' then
        if not util.isNote(evt) then return end
        local d = hexDigit[char]; if not d then return end
        local newSample = util.clamp(
          util.setDigit(evt.sample or 0, d, 1 - digit, 16, half), 0, 127)
        tm:assignEvent(evt, { sample = newSample })
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

        -- Authored delay is intent: write through unbounded (modulo the
        -- ±999 cap that sign*mag already enforces). tm clamps raw at
        -- realisation; divergence (delay ~= delayC) surfaces in tp.
        tm:assignEvent(evt, { delay = newDelay })
        return commit()

      -- velocity nibble (on note) or PA value
      else  -- part == 'vel'
        local d = hexDigit[char]; if not d then return end
        local function newVel(old)
          return util.clamp(util.setDigit(old, d, 1 - digit, 16, half), 1, 127)
        end

        if evt and evt.type == 'pa' then
          tm:assignEvent(evt, snap({ vel = newVel(evt.vel) }))
          return commit()
        end

        if evt then
          tm:assignEvent(evt, { vel = newVel(evt.vel) })
          return commit()
        end

        if cm:get('polyAftertouch') then
          local note = util.seek(col.events, 'before', cursorppq, util.isNote)
          if note and note.endppq > cursorppq then
            tm:addEvent({
              evType = 'pa',
              ppq = cursorppq,
              chan = col.midiChan,
              pitch = note.pitch, vel = newVel(0),
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
      tm:assignEvent(evt, snap(update))
    else
      if type == 'cc' then util.assign(update, { cc = col.cc }) end
      util.assign(update, {
        ppq = cursorppq,
        chan = col.midiChan, rpb = rpbNow,
      })
      update.evType = type
      tm:addEvent(update)
    end
    commit()
  end

  -- Every keystroke that flows through editEvent is one undo block.
  -- Includes note entry, pitch octave digit, sample/vel/delay/pb/val digits.
  tv.editEvent = util.atomic('Edit', tv.editEvent)
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

--contract: clamps newppq strictly inside (prev.ppq, next.ppq) by ±1
--invariant: ±1 clamp is necessary-and-sufficient for identity-by-visible-index across rebuild
function tv:moveLaneEvent(col, i, toRow, toVal)
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

  tm:assignEvent(evt, { val = toVal, ppq = newppq, rpb = currentRpb() })
  tm:flush()
end

-- Inherits prev visible's envelope shape so prev→next curve survives the new midpoint.
-- Returns the new event's visible index post-flush for drag-seed.
function tv:addLaneEvent(col, colIdx, ppq, val)
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
  update.evType = col.type
  tm:addEvent(update)
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

function tv:deleteLaneEvent(col, i)
  if not col or not util.oneOf('cc pb at', col.type) then return end
  local evt = visibleAt(col, i)
  if not evt then return end
  tm:deleteEvent(evt)
  tm:flush()
end

-- Set bezier tension on the i-th visible event. Forces shape to bezier
-- so the tension is honoured (REAPER ignores tension on other shapes).
function tv:setLaneTension(col, i, tension)
  if not col or not util.oneOf('cc pb at', col.type) then return end
  local A = visibleAt(col, i)
  if not A then return end
  tm:assignEvent(A, { tension = tension, shape = 'bezier' })
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
    tm:assignEvent(A, { shape = nextShape(A.shape or 'step') })
  end

  -- Cycle the segment-owner's shape on the i-th visible event in a
  -- cc/pb/at column. Segment-owner = left endpoint (REAPER convention:
  -- A.shape governs the curve from A to next).
  function tv:cycleLaneShape(col, i)
    if not col or not interpolable[col.type] then return end
    local A = visibleAt(col, i)
    if not A then return end
    cycleShape(col, A)
    tm:flush()
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

  -- Undo reopens authored intent: the tail was OPEN before any noteOff
  -- closed it (or we have no record), so write util.OPEN and let tm's
  -- universal tail pass re-derive the realised note-off. The finite
  -- branch writes the user's targeted ceiling unclamped -- tm clips
  -- realised against same-pitch onsets and take length on rebuild.
  local function applyNoteOff(col, last, targetppq, undo)
    if undo then
      tm:assignEvent(last, { endppq = util.OPEN, rpb = currentRpb() })
    elseif last.ppq >= targetppq then
      tm:deleteEvent(last)
    else
      assignTail(last, col.midiChan, math.max(targetppq, last.ppq + 1))
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
        if h.note.endppqC ~= h.targetppq then undo = false; break end
      end

      for _, h in ipairs(hits) do applyNoteOff(h.col, h.note, h.targetppq, undo) end
      tm:flush()
      return
    end

    local _, ccol, cstop = ec:pos()
    local col = grid.cols[ccol]
    if not (col and col.type == 'note'
            and ec:cursorPart() == 'pitch'
            and cstop == col.partStart[cstop]) then
      return false
    end
    local r = ec:row()
    local cursorppq     = ctx:rowToPPQ(r,     col.midiChan)
    local nextCursorPPQ = ctx:rowToPPQ(r + 1, col.midiChan)

    local last = util.seek(col.events, 'before', nextCursorPPQ, util.isNote)
    if not last then return end
    applyNoteOff(col, last, cursorppq, last.endppqC == cursorppq)
    tm:flush()
    ec:advance()
  end

  -- The user grows/shrinks from the ceiling they SEE — the clipped
  -- logical endppqC — even when the authored endppq is util.OPEN or
  -- runs longer. assignTail writes a finite logical ceiling, so tm
  -- stamps endppqL and an open note closes.
  local function adjustDurationCore(col, note, rowDelta)
    local chan      = col.midiChan
    local logPerRow = ctx:ppqPerRow()
    local visEnd    = note.endppqC
    local curRow    = visEnd / logPerRow
    local newRow    = util.clamp(util.round(curRow + rowDelta), 0, grid.numRows)
    local minPPQ    = math.min(visEnd, ctx:rowToPPQ(ctx:snapRow(note.ppq, chan) + 1, chan))
    local newppq    = math.max(ctx:rowToPPQ(newRow, chan), minPPQ)
    if newppq == visEnd then return end
    assignTail(note, chan, newppq)
  end

  function adjustDuration(prefix, rowDelta)
    rowDelta = rowDelta * prefix
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

  -- Selection nudge: the rows the block will occupy after the shift
  -- ([selLo..selHi] + rowDelta) must be clear of any foreign onset in
  -- every touched column -- the SELECTION's full row extent, not just
  -- the sparse moving-onset rows. A foreign onset on a selected-but-
  -- empty row would otherwise slip through and let repeated nudges
  -- accumulate overlaps. Onset-only: tm clips note tails on rebuild.
  local function adjustPositionMulti(rowDelta)
    if rowDelta == 0 then return end
    local r1, r2 = ec:region()
    local loDest, hiDest = r1 + rowDelta, r2 + rowDelta
    if loDest < 0 or hiDest >= grid.numRows then return end

    local runs = {}
    for _, g in ipairs(eventsByCol()) do
      local col = g.col
      local moving, evs = {}, {}
      for _, e in pairs(g.locs) do moving[e] = true; util.add(evs, e) end
      if #evs > 0 then
        local noteOnly = col.type == 'note'
        for _, e in ipairs(col.events) do
          if not moving[e] and (not noteOnly or util.isNote(e)) then
            local r = ctx:ppqToRow(e.ppq, col.midiChan)
            if r >= loDest and r <= hiDest then return end
          end
        end
        util.add(runs, { col = col, evs = evs, note = noteOnly })
      end
    end
    if #runs == 0 then return end

    -- resizeNote moves PBs in the note's ppq range; within each run, process in
    -- the direction that keeps shifted PBs out of unprocessed notes' ranges.
    for _, run in ipairs(runs) do
      local chan = run.col.midiChan
      table.sort(run.evs, function(a, b) return a.ppq < b.ppq end)
      local s, e, step = 1, #run.evs, 1
      if rowDelta > 0 then s, e, step = #run.evs, 1, -1 end
      for i = s, e, step do
        local ev = run.evs[i]
        if run.note then
          assignNoteMove(ev, ctx:ppqToRow(ev.ppq, chan) + rowDelta)
        else
          assignStamp(ev, chan, ctx:ppqToRow(ev.ppq, chan) + rowDelta)
        end
      end
    end
    tm:flush()
    ec:shiftSelection(rowDelta)
  end

  -- Notes: onset-only band (rowBounds) -- a neighbour tail never blocks
  -- the move; tm clips an overrun on the next rebuild. The cursor
  -- follows by rowDelta unless that row already holds another note
  -- (cursorNoteBefore would otherwise retarget it). Non-note events
  -- nudge in time too, all-or-nothing like shiftEvents: refuse off the
  -- grid edge or onto a same-column event (a same-ppq collision).
  --contract: single move: notes blocked only by onset reorder; cc/at/pa/pc by occupied dest row
  --contract: selection: refuse if any col's [selLo..selHi]+rowDelta destination holds a foreign onset
  function adjustPosition(prefix, rowDelta)
    rowDelta = rowDelta * prefix
    if ec:hasSelection() then return adjustPositionMulti(rowDelta) end

    local col = grid.cols[ec:col()]
    if not col then return end
    local chan         = col.midiChan
    local newCursorRow = ec:row() + rowDelta

    if col.type == 'note' then
      local _, note = cursorNoteBefore()
      if not note then return end
      local newStart = ctx:snapRow(note.ppq, chan) + rowDelta
      local minRow, maxRow = rowBounds(col, note.ppq, note)
      if newStart < minRow or newStart > maxRow then return end

      local cursorBlocked = false
      for _, e in ipairs(col.events) do
        if util.isNote(e) and e ~= note
           and ctx:snapRow(e.ppq, chan) == newCursorRow then
          cursorBlocked = true; break
        end
      end

      assignNoteMove(note, newStart)
      tm:flush()
      if not cursorBlocked then ec:setPos(newCursorRow) end
      return
    end

    local evt = col.cells and col.cells[ec:row()]
    if not evt then return end
    if newCursorRow < 0 or newCursorRow >= grid.numRows then return end
    for _, e in ipairs(col.events) do
      if e ~= evt and ctx:snapRow(e.ppq, chan) == newCursorRow then return end
    end
    assignStamp(evt, chan, newCursorRow)
    tm:flush()
    ec:setPos(newCursorRow)
  end
end

----- Quantize / scale

do

  -- Every column, every event, as a groups list (for *-all variants).
  local function allGroups()
    local groups = {}
    for _, col in ipairs(grid.cols) do
      local locs = {}
      for _, e in ipairs(col.events) do locs[e.token] = e end
      util.add(groups, { col = col, locs = locs })
    end
    return groups
  end

  -- Plan-then-write so conformOverlaps can clip plan geometry against
  -- col-mates before the writes commit. Two off-grid col-mates can
  -- otherwise quantize-collapse onto the same ppq (or onto adjacent
  -- rows whose post-snap distance crosses the lenient threshold),
  -- and the allocator would reject the persisted lane on rebuild.
  local function quantizeScope(groups)
    local step  = logPerRowFor(currentRpb())
    local plans = {}
    for _, g in ipairs(groups) do
      local col, chan = g.col, g.col.midiChan
      for _, e in pairs(g.locs) do
        local sRow   = ctx:ppqToRow(e.ppq, chan)
        local newRow = util.round(sRow)
        local newppq = ctx:rowToPPQ(newRow, chan)
        local newEndppq
        if util.isNote(e) then
          local newEndRow = newRow + util.round(ctx:ppqToRow(e.endppq, chan) - sRow)
          newEndppq = ctx:rowToPPQ(newEndRow, chan)
        end
        local changed = newppq ~= e.ppq
                        or (util.isNote(e) and newEndppq ~= e.endppq)
        if changed then
          local entry = { col = col, e = e, newppq = newppq }
          if util.isNote(e) then entry.newEndppq = newEndppq end
          util.add(plans, entry)
        end
      end
    end

    conformOverlaps(plans)
    writePlans(plans)
    tm:flush()
  end

  -- Plan-then-write so conformOverlaps can adjust newppq before delay re-derives.
  local function quantizeKeepRealisedScope(groups)
    local plans = {}
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

    -- Write the ideal delay verbatim. tm clamps raw on assign and step
    -- 4.8 reapplies the same-pitch onset floor; any clamp surfaces as
    -- delay ~= delayC, painted by tp's divergent marker.
    for _, p in ipairs(plans) do
      if util.isNote(p.e) then
        local realised = p.e.ppq + timing.delayToPPQ(p.e.delay, resolution)
        p.newDelay = timing.ppqToDelay(realised - p.newppq, resolution)
      end
    end

    writePlans(plans)
    tm:flush()
  end

  function tv:quantizeSelection()             quantizeScope(eventsByCol())              end
  function tv:quantizeAll()                   quantizeScope(allGroups())                end
  function tv:quantizeKeepRealisedSelection() quantizeKeepRealisedScope(eventsByCol())  end
  function tv:quantizeKeepRealisedAll()       quantizeKeepRealisedScope(allGroups())    end

  -- Cap on rpb refinement — matches tv:setRowPerBeat's clamp, so an
  -- attempted refinement that exceeds it is silently refused rather
  -- than silently clamped (clamping would land us at the wrong grid).
  local SCALE_RPB_MAX = 32

  local function scaleScope(groups, kNum, kDen)
    kDen = kDen or 1
    if kDen == 0 then return end
    local k = kNum / kDen
    if not k or k == 1 then return end
    local logPerRow = ctx:ppqPerRow()
    local aRow      = ec:anchorRow() or ec:row()
    local aLogical  = aRow * logPerRow

    local plans = {}
    for _, g in ipairs(groups) do
      local col, chan = g.col, g.col.midiChan
      local aPpq = ctx:rowToPPQ(aRow, chan)
      for _, e in pairs(g.locs) do
        local newppq = util.round(aPpq + k * (e.ppq - aPpq))
        local entry  = { col = col, e = e, newppq = newppq }
        if util.isNote(e) then
          entry.newEndppq = newppq + util.round(k * (e.endppq - e.ppq))
        end
        util.add(plans, entry)
      end
    end
    -- Silent refusal if any onset would land off-grid. Tails are clipped
    -- by tm's universal tail pass, so newEndppq overshoot is benign.
    for _, p in ipairs(plans) do
      if p.newppq < 0 or p.newppq >= length then return end
    end
    conformOverlaps(plans)
    writePlans(plans)
    tm:flush()

    -- Selection follow-up. Only when there's a live selection AND the
    -- caller passed an integer rational — float-k callers stay in the
    -- old shape (no reshape, no rpb refinement).
    if not (ec:hasSelection()
            and type(kNum) == 'number' and kNum == math.floor(kNum)
            and type(kDen) == 'number' and kDen == math.floor(kDen)) then
      return
    end
    local r1, r2, c1, c2, part1, part2 = ec:region()
    local aRowSel = ec:anchorRow() or r1
    local cRowSel = (aRowSel == r1) and r2 or r1
    local span    = cRowSel - aRowSel
    if span == 0 then return end   -- one-row selection: identity

    local g    = util.gcd(kNum, kDen)
    local p, q = kNum // g, kDen // g

    local function reshape(newA, newC)
      local nr1 = math.min(newA, newC)
      local nr2 = math.max(newA, newC)
      ec:setSelection{ row1 = nr1, row2 = nr2, col1 = c1, col2 = c2,
                       part1 = part1, part2 = part2 }
    end

    if span % q == 0 then
      reshape(aRowSel, aRowSel + (p * span) // q)
    else
      local oldRpb = currentRpb()
      local newRpb = oldRpb * q
      if newRpb <= SCALE_RPB_MAX then
        local newA = aRowSel * q
        local newC = newA + p * span
        -- Same tier as tv:setRowPerBeat so a later toolbar / Cmd+= nudge
        -- isn't shadowed by a more-specific override left behind here.
        releaseTransientFrame()
        ec:rescaleRow(oldRpb, newRpb)
        cm:set('track', 'rowPerBeat', newRpb)
        reshape(newA, newC)
      end
      -- else: silent refusal — selection stays at current rpb, geometry slipped.
    end
  end

  function tv:scaleSelection(kNum, kDen) scaleScope(eventsByCol(), kNum, kDen) end
  function tv:scaleAll(kNum, kDen)       scaleScope(allGroups(),   kNum, kDen) end
end

local insertRow, deleteRow, insertRowCol, deleteRowCol do
  -- Absorber pbs are tm-managed, tied to note seats — row ops shift
  -- only real events and leave derived pbs to tm's reconcile.
  local function notDerived(e) return not e.derived end

  -- An open authored tail stays open across the shift; a finite ceiling
  -- shifts with the note, UNCLAMPED — endppq is authored intent, not a
  -- realised value. tm's universal tail pass owns clipping (against take
  -- length and same-pitch onsets); clamping here would shrink intent.
  local function shiftPlan(col, e, dLogical)
    local entry = { col = col, e = e, newppq = e.ppq + dLogical }
    if util.isNote(e) then
      -- util.OPEN = inf: inf + dLogical = inf, so an open tail stays open
      -- across the shift without a sentinel guard.
      entry.newEndppq = e.endppq + dLogical
    end
    return entry
  end

  local function insertRowCore(col, topRow, numRows)
    local chan = col.midiChan
    local logPerRow = logPerRowFor(currentRpb())
    local C        = ctx:rowToPPQ(topRow, chan)
    local dLogical = numRows * logPerRow

    local plans, deletes = {}, {}
    for e in util.between(col.events, C, length, notDerived) do
      local p = shiftPlan(col, e, dLogical)
      if p.newppq >= length then util.add(deletes, e)
      else                       util.add(plans, p) end
    end

    -- col.events is a rebuild-snapshot; deletes don't refresh it,
    -- so corpses must be passed to conform explicitly.
    conformOverlaps(plans, deletes)
    for _, e in ipairs(deletes) do tm:deleteEvent(e) end
    writePlans(plans)

    -- A spanning note (onset before C, tail crosses C) shifts forward
    -- alongside the events at/past C -- the inserted rows widen the gap
    -- between onset and tail. Unclamped: endppq is authored intent, tm's
    -- tail pass clips realised against take length on rebuild. An OPEN
    -- authored tail stays OPEN: no arithmetic on the sentinel, and the
    -- realised tail is re-derived from scratch every rebuild anyway.
    if col.type == 'note' then
      local spanning = util.seek(col.events, 'before', C, util.isNote)
      if spanning and spanning.endppq ~= util.OPEN and spanning.endppq > C then
        assignTail(spanning, chan, spanning.endppq + dLogical)
      end
    end
  end

  local function deleteRowCore(col, topRow, numRows)
    local chan = col.midiChan
    local logPerRow = logPerRowFor(currentRpb())
    local C        = ctx:rowToPPQ(topRow, chan)
    local D        = ctx:rowToPPQ(topRow + numRows, chan)
    local dLogical = numRows * logPerRow

    -- A spanning finite tail either shifts back (tail past the deleted
    -- band) or collapses to C (tail inside the deleted band). An OPEN
    -- authored tail stays OPEN -- a deletion below the onset doesn't
    -- close the note; tm re-derives the realised note-off on rebuild.
    if col.type == 'note' then
      local spanning = util.seek(col.events, 'before', C, util.isNote)
      if spanning and spanning.endppq ~= util.OPEN and spanning.endppq > C then
        assignTail(spanning, chan,
                   spanning.endppq > D and spanning.endppq - dLogical or C)
      end
    end

    local plans, deletes = {}, {}
    for e in util.between(col.events, C, length, notDerived) do
      if e.ppq < D then util.add(deletes, e)
      else              util.add(plans, shiftPlan(col, e, -dLogical)) end
    end

    conformOverlaps(plans, deletes)
    for _, e in ipairs(deletes) do tm:deleteEvent(e) end
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

  -- p scales the step magnitude (universal-argument prefix; defaults
  -- to 1 from the call site). Coarse scales the interval; fine scales
  -- the direction unit.
  local function scaledScalar(v, lo, hi, dir, baseInterval, p)
    if baseInterval then
      return util.nudgedScalar(v, lo, hi, dir, baseInterval * p)
    end
    return util.nudgedScalar(v, lo, hi, dir * p, nil)
  end

  local function nudgePitch(col, note, dir, coarse, audible, p)
    local delta  = dir * pitchStep(coarse) * p
    local temper = ctx:activeTemper()
    local pitch, detune
    if temper then
      pitch, detune = tuning.transposeStep(temper, note.pitch, note.detune, delta)
      -- A clamp-fold past the cents-0 anchor or MIDI ceiling leaves |detune|>50;
      -- a seated note never does. Reject -- keep notes in the addressable range.
      if math.abs(detune) > 50 then return end
    else
      pitch, detune = util.clamp(note.pitch + delta, 0, 127), note.detune
    end
    if pitch == note.pitch and detune == note.detune then return end
    tm:assignEvent(note, { pitch = pitch, detune = detune })
    if audible then audition(pitch, note.vel, col.midiChan, detune) end
  end

  local function nudgeVel(note, dir, coarse, p)
    local newVel = scaledScalar(note.vel, 1, 127, dir, coarse and 8 or nil, p)
    if newVel == note.vel then return end
    tm:assignEvent(note, { vel = newVel })
  end

  local function nudgeDelay(col, note, dir, coarse, p)
    -- Authored delay is intent; the only bound is the display cap that
    -- digit entry also enforces. Realisation clamps live in tm.
    local old = note.delay
    local new = scaledScalar(old, -999, 999, dir, coarse and 10 or nil, p)
    if new == old then return end
    tm:assignEvent(note, { delay = new })
  end

  local function nudgeValue(col, evt, dir, coarse, p)
    local lo, hi   = valueBounds(col)
    local newVal   = scaledScalar(evt.val, lo, hi, dir, coarse and valueInterval(col) or nil, p)
    if newVal == evt.val then return end
    tm:assignEvent(evt, { val = newVal })
  end

  local function applyNudge(col, evt, part, dir, coarse, audible, p)
    if     part == 'val'   then nudgeValue(col, evt, dir, coarse, p)
    elseif part == 'vel'   then nudgeVel(evt, dir, coarse, p)
    elseif part == 'delay' then nudgeDelay(col, evt, dir, coarse, p)
    elseif part == 'pitch' then nudgePitch(col, evt, dir, coarse, audible, p) end
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
  function nudge(prefix, dir, coarse)
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
              applyNudge(g.col, e, g.part, dir, coarse, false, prefix)
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
    applyNudge(col, evt, ec:cursorPart(), dir, coarse, true, prefix)
    tm:flush()
  end
end

----- Note FX (macros)

-- The fx editor addresses hosts by durable uuid (survives rebuilds) and
-- writes through setNoteFx (whole list) / setFxField (one field).

-- The note under the caret, or nil on a non-note / empty cell. The fx
-- editor command gates on this (it is a no-op off a note).
function tv:cursorNote()
  local col = grid.cols[ec:col()]
  if not col or col.type ~= 'note' then return nil end
  local evt = col.cells and col.cells[ec:row()]
  return (evt and util.isNote(evt)) and evt or nil
end

-- An fx host is a note (mm, integer uuid) or a region (ds, 'fxr-N' string uuid); the
-- editor addresses both by uuid. Disjoint namespaces: a missed note lookup falls to the region.
local function regionByUuid(uuid)
  for _, region in ipairs(ds:get('fxRegions') or {}) do
    if region.uuid == uuid then return region end
  end
end

local function mintRegionUuid()
  local maxN = 0
  for _, region in ipairs(ds:get('fxRegions') or {}) do
    local n = tonumber(tostring(region.uuid):match('^fxr%-(%d+)$'))
    if n and n > maxN then maxN = n end
  end
  return 'fxr-' .. (maxN + 1)
end

-- A selection authors a region over (channel, ppq span); find-or-create by exact
-- footprint so re-opening the same span reuses the region, never duplicates it.
local function ensureRegionForSelection()
  local row1, row2, col1 = ec:region()
  local col = grid.cols[col1]
  if not col then return end
  local chan     = col.midiChan
  local startppq = tv:rowToPPQ(row1, chan)
  local endppq   = tv:rowToPPQ(row2 + 1, chan)
  for _, region in ipairs(ds:get('fxRegions') or {}) do
    if region.chan == chan and region.startppq == startppq and region.endppq == endppq then
      return region.uuid, false
    end
  end
  local region = { uuid = mintRegionUuid(), chan = chan,
                   startppq = startppq, endppq = endppq, fx = {} }
  local out = {}
  for _, existing in ipairs(ds:get('fxRegions') or {}) do out[#out + 1] = existing end
  out[#out + 1] = region
  ds:assign('fxRegions', out)
  return region.uuid, true
end

function tv:noteFx(uuid)
  local note = tm:byUuid(uuid)
  if note then return note.fx end
  local region = regionByUuid(uuid)
  return region and region.fx or nil
end

-- The fx host the editor opens on: a selection authors/reopens a region; else the caret's
-- fx cell; else the caret's note (v1). 2nd return = freshly minted (modal takes no snapshot).
function tv:fxHostForEdit()
  if ec:hasSelection() then return ensureRegionForSelection() end
  local col = grid.cols[ec:col()]
  if col and col.type == 'fx' then
    local cell = col.cells and col.cells[ec:row()]
    return cell and cell.uuid or nil
  end
  local note = self:cursorNote()
  return note and note.uuid or nil
end

-- The host note behind a uuid; the stepInterval editor reads its pitch/detune to
-- convert a slide's cents demand to/from temper steps.
function tv:noteByUuid(uuid) return tm:byUuid(uuid) end

-- Write or clear (util.REMOVE) a note's fx list, then flush so the rebuild
-- re-derives its fxNotes. uuid, not the event, is the durable handle.
function tv:setNoteFx(uuid, fxOrRemove)
  local emptyList = type(fxOrRemove) == 'table' and #fxOrRemove == 0
  local note = tm:byUuid(uuid)
  if note then
    -- A note outlives its fx, so clearing means absence -- nil, never an empty list (noteFx
    -- must read falsy). Normalise an empty list to REMOVE; the region path keeps the husk.
    tm:assignEvent(note, { fx = emptyList and util.REMOVE or fxOrRemove })
    tm:flush()
    pa:apply()   -- spawn/reap the CC node when a carrier first appears or last leaves the track
    return
  end
  -- Region host: a document-data write (ds:assign -> dataChanged -> rebuild). A region IS its
  -- fx, but only REMOVE drops it -- an empty list leaves an inert husk the editor can refill.
  local delete = fxOrRemove == util.REMOVE
  local out = {}
  for _, region in ipairs(ds:get('fxRegions') or {}) do
    if region.uuid ~= uuid then
      out[#out + 1] = region
    elseif not delete then
      local updated = util.clone(region); updated.fx = fxOrRemove; out[#out + 1] = updated
    end
  end
  ds:assign('fxRegions', next(out) and out or util.REMOVE)
  pa:apply()
end

-- Set one field of fx entry `index`, preserving sibling entries, then flush.
-- The generic write the per-kind editor descriptors drive -- no per-kind code.
function tv:setFxField(uuid, index, field, value)
  local fx = self:noteFx(uuid)
  if not (fx and fx[index]) then return end
  local list = {}
  for i, entry in ipairs(fx) do list[i] = (i == index) and util.clone(entry) or entry end
  list[index][field] = value
  self:setNoteFx(uuid, list)
end

-- Toggle a macro kind on/off, preserving the other category's entry; render owns defaults.
-- The new list (maybe empty) is the write; setNoteFx decides how empty persists per host.
function tv:setFxKindActive(uuid, entry, active)
  local fx = self:noteFx(uuid)
  local list = {}
  if fx then
    for _, e in ipairs(fx) do if e.kind ~= entry.kind then list[#list + 1] = e end end
  end
  if active then list[#list + 1] = util.deepClone(entry) end
  self:setNoteFx(uuid, list)
end

----- Deletion

local deleteEvent, deleteSelection do
  -- Delete notes; extend each predecessor that ended at-or-past a deleted run
  -- into the next survivor's start (or `length`). PAs are out of scope here.
  -- Fixups are computed before any mutation: tm:assignEvent's same-key clamp
  -- reads live state, so we must delete first and stretch second.
  -- Plain delete. A survivor that legato-owned the run grows back over
  -- the hole for free: tm re-derives every raw tail next rebuild, up to
  -- the survivor's ceiling (take length when it is open).
  local function queueDeleteNotes(col, locs)
    for _, evt in pairs(locs) do
      if evt.type ~= 'pa' then tm:deleteEvent(evt) end
    end
  end

  ---@diagnostic disable-next-line: unused-local
  local function queueResetDelays(col, locs)
    for _, evt in pairs(locs) do
      if evt.type ~= 'pa' and evt.delay ~= 0 then
        tm:assignEvent(evt, { delay = 0 })
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
          tm:deleteEvent(evt)
        else
          tm:assignEvent(evt, { vel = prevVel })
        end
      else
        prevVel = evt.vel
      end
    end
  end

  local function queueDeleteCCs(col, locs)
    for _, evt in pairs(locs) do tm:deleteEvent(evt) end
  end

  local DELETE_BY_PART = {
    pitch  = queueDeleteNotes,
    vel    = queueResetVelocities,
    delay  = queueResetDelays,
    val    = queueDeleteCCs,
    sample = function() end,
  }

  function deleteEvent()
    local col = grid.cols[ec:col()]
    if not col then return end
    local r = ec:row()
    local evt = col.cells and col.cells[r]
    if not evt then
      -- Delete on a ghost cell: unset interpolation on the governing event.
      local ghost = col.ghosts and col.ghosts[r]
      if ghost then
        tm:assignEvent(ghost.fromEvt, { shape = 'step' })
        tm:flush()
      end
      return
    end
    local part = col.type == 'note' and ec:cursorPart() or 'val'
    DELETE_BY_PART[part](col, { [evt] = evt })
    tm:flush()
  end

  function deleteSelection()
    for _, g in ipairs(eventsByCol()) do
      DELETE_BY_PART[g.part](g.col, g.locs)
    end
    tm:flush()
    ec:selClear()
  end
end

local function deleteOrBackspace()
  if ec:isSticky() then deleteSelection()
  else ec:selClear(); deleteEvent(); ec:advance() end
end

----- Horizontal move

-- Shift the cursor event (or an n-row x 1-col selection block) to an
-- adjacent column. Notes step to the next/prev lane that exists in the
-- channel, else cross to the next/prev channel -- right lands on lane 1,
-- left on the channel's highest lane, so the two are inverses. Other
-- event types just step channel. All-or-nothing, like adjustPosition:
-- refuse if the move runs off the grid edge, or onto a destination
-- note-on. Note tails are not a barrier -- a moved note's tail, or a
-- straddling destination note's tail, is clipped by tm's universal tail
-- pass on the rebuild that follows. The cursor follows to the
-- destination column -- single event and selection alike.
--contract: selection must be exactly one grid column; multi-col selection is a no-op
--invariant: a 1-col block stays contiguous when it lands on the destination col
--contract: cursor follows to the destination column (single event and selection alike)
--contract: refuse if dest col has any onset in source's row extent (note: note-on; else any event)
--invariant: source's row extent = selection's [r1,r2] for a block, moved event's onset row for a single
--invariant: tails (either direction) clipped by tm's tail pass; never block
local PART_FOR = { note = 'pitch', pb = 'pb', cc = 'val', pc = 'val', at = 'val' }

local function shiftEvents(dir)
  local function noteColsByLane(chan)
    local byLane = {}
    for ci = grid.chanFirstCol[chan], grid.chanLastCol[chan] do
      local c = grid.cols[ci]
      if c and c.type == 'note' then byLane[c.lane or 1] = c end
    end
    return byLane
  end

  local function findCol(d)
    for i, c in ipairs(grid.cols) do
      if c.midiChan == d.chan and c.type == d.type
         and (d.type ~= 'note' or (c.lane or 1) == d.lane)
         and (d.type ~= 'cc'   or c.cc == d.cc) then
        return c, i
      end
    end
  end

  -- Gather source column + the events that move.
  local srcCol, rows, moving
  if ec:hasSelection() then
    local r1, r2, c1, c2 = ec:region()
    if c1 ~= c2 then return end
    srcCol = grid.cols[c1]
    if not srcCol then return end
    rows, moving = { r1, r2 }, {}
    local pred = srcCol.type == 'note' and util.isNote or nil
    local lo, hi = ctx:rowToPPQ(r1, srcCol.midiChan),
                   ctx:rowToPPQ(r2 + 1, srcCol.midiChan)
    for evt in util.between(srcCol.events, lo, hi, pred) do util.add(moving, evt) end
  else
    srcCol = grid.cols[ec:col()]
    local evt = srcCol and srcCol.cells and srcCol.cells[ec:row()]
    if not evt or (srcCol.type == 'note' and not util.isNote(evt)) then return end
    moving = { evt }
  end
  if #moving == 0 then return end

  -- Destination descriptor, or nil if the move runs off the grid edge.
  local chan = srcCol.midiChan
  local function destDescriptor()
    if srcCol.type ~= 'note' then
      local nc = chan + dir
      if nc < 1 or nc > 16 then return end
      return { chan = nc, type = srcCol.type, cc = srcCol.cc }
    end
    local lane = srcCol.lane or 1
    if noteColsByLane(chan)[lane + dir] then
      return { chan = chan, type = 'note', lane = lane + dir }
    end
    local nc = chan + dir
    if nc < 1 or nc > 16 then return end
    local L = 1
    if dir < 0 then
      for ln in pairs(noteColsByLane(nc)) do if ln > L then L = ln end end
    end
    return { chan = nc, type = 'note', lane = L }
  end
  local dest = destDescriptor()
  if not dest then return end

  -- Refuse the whole move if any onset in the destination column lands
  -- on a row the source occupies: the SELECTION's full row extent
  -- (rows[1..2]) for a block, the moved event's onset row for a
  -- single. Using the selection extent -- not just the sparse moving-
  -- onset band -- stops a dest onset on a selected-but-empty row
  -- slipping through, which would let repeated cross-column shifts
  -- pile up overlapping events. Onset-only: tails truncate on rebuild
  -- and never block.
  local destCol = findCol(dest)
  if destCol then
    local loR, hiR
    if rows then
      loR, hiR = rows[1], rows[2]
    else
      loR, hiR = math.huge, -math.huge
      for _, src in ipairs(moving) do
        local r = ctx:ppqToRow(src.ppq, srcCol.midiChan)
        loR, hiR = math.min(loR, r), math.max(hiR, r)
      end
    end
    local noteOnly = srcCol.type == 'note'
    for _, e in ipairs(destCol.events) do
      if not noteOnly or util.isNote(e) then
        local r = ctx:ppqToRow(e.ppq, destCol.midiChan)
        if r >= loR and r <= hiR then return end
      end
    end
  end

  for _, src in ipairs(moving) do
    local clone = util.clone(src, { token = true, loc = true })
    clone.evType = srcCol.type
    clone.chan   = dest.chan
    if     dest.type == 'note' then clone.lane = dest.lane
    elseif dest.type == 'cc'   then clone.cc   = dest.cc end
    tm:deleteEvent(src)
    tm:addEvent(clone)
  end
  tm:flush()

  local landed, idx = findCol(dest)
  if not landed then return end
  if rows then
    local p = PART_FOR[srcCol.type]
    ec:setSelection{ row1 = rows[1], row2 = rows[2], col1 = idx, col2 = idx,
                     part1 = p, part2 = p }
  end
  ec:setPos(ec:row(), idx)   -- cursor follows to the destination column
end

-- Step currentSample by ±1 across the full 0..127 range. Empty slots
-- are reachable — the user may want to author a sample value before
-- the sampler has loaded that slot.
local function stepSample(dir)
  cm:set('take', 'currentSample',
         util.clamp(cm:get('currentSample') + dir, 0, 127))
end

----- Duplicate

local dupeState = nil

-- Group quick-verb tokens: groupSrc (last copy/mark for groupPaste, nil once mutated),
-- groupDupState (groupDuplicate cascade). Cleared by the keep-set sweep + endReselectCascades.
local groupSrc, groupDupState

-- Cursor cell as a 1-row mirror rect: the seed-rect fallback for plain
-- duplicate when there is no real selection (selectionAsRect is nil).
-- This is the 1x1 carveout -- mirror passes no fallback, so a degenerate
-- selection is a no-op there; plain duplicate clones the cursor cell.
local function cursorRect()
  local _, c = ec:pos()
  local col  = grid.cols[c]
  if not col then return nil end
  local lpr = logPerRowFor(currentRpb())
  return { ppq = ec:row() * lpr, dur = lpr, chanLo = col.midiChan,
           streams = { [0] = { [streamIdOf(col)] = true } } }
end

-- The grid columns the rect's stream set lands on when its chanLo is
-- pinned to `anchor.chan` -- the shared logical->grid mapping. Resolving
-- this at paste/select time (not freezing the seed column) is what lets
-- a channel-changing cursor move carry the cascade to the new channel.
local function colsForAnchor(anchor, rect)
  local col1, col2
  for ci, col in ipairs(grid.cols) do
    local sel = rect.streams[col.midiChan - anchor.chan]
    if sel and sel[streamIdOf(col)] then
      col1 = col1 or ci
      col2 = ci
    end
  end
  return col1, col2
end

-- First stop in `col` carrying part `part` (the seed's part name), or
-- 1 if unknown -- keeps pasteSingle's pitch/vel dispatch on the part
-- the user duplicated, at whatever column the anchor resolved to.
local function stopForPart(col, part)
  for stop, name in ipairs(grid.cols[col].partAt) do
    if name == part then return stop end
  end
  return 1
end

-- Inverse of selectionAsRect: drop a grid selection (cursor at its
-- top-left) at a logical anchor. Whole-column parts -- the cascade
-- carries part precision in its payload, not in the live selection.
local function selectRegionAt(anchor, rect)
  local col1, col2 = colsForAnchor(anchor, rect)
  if not col1 then return end
  local lpr  = logPerRowFor(currentRpb())
  local row1 = anchor.ppq // lpr
  local row2 = row1 + rect.dur // lpr - 1
  local pa1, pa2 = grid.cols[col1].partAt, grid.cols[col2].partAt
  ec:setPos(row1, col1, 1)
  ec:setSelection{ row1 = row1, row2 = row2, col1 = col1, col2 = col2,
                   part1 = pa1[1], part2 = pa2[#pa2] }
end

-- Plain duplicate: clip payload, cursor-cell seed fallback. The cascade
-- lifetime, anchor and select-the-copy live in tv:duplicateCascade.
-- place re-homes the paste to the anchor's channel (colsForAnchor), so a
-- channel-changing cursor move moves subsequent copies, not just rows.
local function duplicate()
  dupeState = tv:duplicateCascade(dupeState,
    function()
      local clip = clipboard:collect()
      if not clip then return nil end
      local col, stop = ec:regionStart()
      return { clip = clip, part = grid.cols[col].partAt[stop] }
    end,
    function(rect, anchor, payload)
      local col = colsForAnchor(anchor, rect)
      if not col then return payload end
      ec:setPos(anchor.ppq // logPerRowFor(currentRpb()),
                col, stopForPart(col, payload.part))
      clipboard:pasteClip(payload.clip)
      return payload
    end,
    cursorRect)
end

---------- PUBLIC

function tv:ec()        return ec end
function tv:clipboard() return clipboard end

----- Accessors for trackerPage

function tv:rowPerBar()      return rowPerBar end
function tv:takeName()       return tm:name() end
function tv:activeTemper()   return ctx:activeTemper() end
function tv:cellWidth()      local t = ctx:activeTemper(); return t and t.cellWidth or 3 end
function tv:octaveWidth()    local t = ctx:activeTemper(); return t and t.octaveWidth or 1 end
function tv:noteProjection(evt) return ctx:noteProjection(evt) end
function tv:rowBeatInfo(row) return ctx:rowBeatInfo(row) end
function tv:barBeatSub(row) return ctx:barBeatSub(row) end
function tv:ppqToRow(ppq, chan) return ctx:ppqToRow(ppq, chan) end
function tv:rowToPPQ(row, chan) return ctx:rowToPPQ(row, chan) end
function tv:logPerRow()         return logPerRowFor(currentRpb()) end
function tv:sampleCurve(A, B, ppq) return tm:interpolate(A, B, ppq) end
function tv:timeSig()
  local ts = timeSigs[1] or { num = 4, denom = 4 }
  return ts.num, ts.denom
end

----- Mirror bridge

-- Shared duplicate cascade. `state` is the run token (nil seeds);
-- `collectSource` captures a payload while the source is still intact
-- (plain dup: clip + part; mirror: nil -- events come from the rect in
-- `place`); `place(rect, anchor, payload)` drops a copy and returns the
-- payload to carry forward; `fallbackRect` (plain dup only) supplies a
-- seed rect when there is no real selection. The seed lands one region
-- below the source; an unmoved cursor stacks the next copy at `next`, a
-- moved cursor drops it at the cursor. A cascade seeded from a real
-- selection re-selects each copy; one seeded from the fallback rect
-- (no selection -- the 1x1 cell carveout) leaves no selection, like a
-- classic cell duplicate. Returns the new run token.
function tv:duplicateCascade(state, collectSource, place, fallbackRect)
  local rect, fromSel
  if state then
    rect, fromSel = state.rect, state.fromSel
  else
    rect    = tv:selectionAsRect()
    fromSel = rect ~= nil
    rect    = rect or (fallbackRect and fallbackRect())
  end
  if not rect then return state end
  local payload = state and state.payload
  local ppq, chan
  if not state then
    if collectSource then
      payload = collectSource()
      if payload == nil then return nil end
    end
    ppq, chan = rect.ppq + rect.dur, rect.chanLo
  else
    local a = tv:cursorAnchor()
    if not a then return state end
    if state.mark and a.ppq == state.mark.ppq and a.chan == state.mark.chan then
      ppq, chan = state.next, a.chan   -- not moved: stack below, same channel
    else
      ppq, chan = a.ppq, a.chan        -- moved: at the cursor
    end
  end
  -- End-of-take: paste whatever fits, then end the cascade. Silently
  -- no-opping here was the "won't fire" symptom near the tail.
  if ppq >= tm:length() then return nil end
  local anchor = { ppq = ppq, chan = chan }
  payload = place(rect, anchor, payload)
  if fromSel then selectRegionAt(anchor, rect) else ec:selClear() end
  local nextPpq = ppq + rect.dur
  if nextPpq >= tm:length() then return nil end
  return { rect = rect, payload = payload, fromSel = fromSel,
           next = nextPpq, mark = tv:cursorAnchor() }
end

-- The active selection as a mirror rect: a logical-frame time span x a
-- per-channel streamId set, chanOffset relative to the lowest selected
-- channel. nil unless a real (non-degenerate) selection exists.
function tv:selectionAsRect()
  if not ec:hasSelection() then return nil end
  local r1, r2, c1, c2 = ec:region()
  local chanLo
  for ci = c1, c2 do
    local col = grid.cols[ci]
    if col then chanLo = math.min(chanLo or col.midiChan, col.midiChan) end
  end
  if not chanLo then return nil end

  local streams = {}
  for ci = c1, c2 do
    local col = grid.cols[ci]
    if col then
      local off = col.midiChan - chanLo
      streams[off] = streams[off] or {}
      streams[off][streamIdOf(col)] = true
    end
  end

  local lpr = logPerRowFor(currentRpb())
  return { ppq = r1 * lpr, dur = (r2 - r1 + 1) * lpr,
           chanLo = chanLo, streams = streams }
end

-- Concrete events the rect contains. Membership is the mirror predicate
-- in the logical frame: onset ppq in the span AND the column's stream is
-- selected for its channel offset. col.events ppq is logical (tm
-- invariant), so the comparison needs no swing maths.
-- chan/lane/cc are column-implicit in the tm stack (the container is the
-- channel/lane); gm needs them per-event for its anchor maths and must
-- keep object identity (it links the live evt for propagation), so we
-- backfill the authoritative column values rather than clone.
function tv:eventsInRect(rect)
  local lo, hi = rect.ppq, rect.ppq + rect.dur
  local out = {}
  for _, col in ipairs(grid.cols) do
    local sel = rect.streams[col.midiChan - rect.chanLo]
    if sel and sel[streamIdOf(col)] then
      for evt in util.between(col.events, lo, hi) do
        evt.chan = evt.chan or col.midiChan
        if col.type == 'note' then evt.lane = evt.lane or col.lane
        elseif col.type == 'cc' then evt.cc  = evt.cc  or col.cc end
        util.add(out, evt)
      end
    end
  end
  return out
end

-- Clears the take cells the rect's projection lands on at `anchor` -- the
-- footprint inverse of eventsInRect. gm:stamp / gm:newInstance only
-- re-place their own concretes (contract: the caller clears foreign
-- ones), so a group dropped on populated cells must wipe them first or
-- the projection interleaves with stale notes. Authored intent on notes
-- whose onset is before the zone is left alone -- tm's universal tail
-- pass clips realised against same-pitch/same-lane successors (the
-- projection that lands post-clear among them) on the next rebuild, so a
-- pre-trim here would only shrink intent. Stages deletes only; the
-- caller flushes alongside gm's staged adds. Called strictly before gm
-- stages, so it never eats the projection; a gm op that then rejects
-- (out-of-range / live-group overlap) is a rare pre-beta edge the
-- bounds/no-straddle gates already exclude for the common path.
function tv:clearRegionAt(rect, anchor)
  local lo, hi = anchor.ppq, anchor.ppq + rect.dur
  for _, col in ipairs(grid.cols) do
    local sel = rect.streams[col.midiChan - anchor.chan]
    if sel and sel[streamIdOf(col)] then
      for evt in util.between(col.events, lo, hi) do tm:deleteEvent(evt) end
    end
  end
end

-- Cursor as a mirror anchor: { ppq, chan } in the logical frame.
function tv:cursorAnchor()
  local _, c = ec:pos()
  local col = grid.cols[c]
  if not col then return nil end
  return { ppq = ec:row() * logPerRowFor(currentRpb()), chan = col.midiChan }
end

-- (channel offset, stream id) for a grid column, relative to chanLo —
-- the coordinates a mirror rect's `streams` table is keyed by.
function tv:streamRefAt(colIx, chanLo)
  local col = grid.cols[colIx]
  if not col then return nil end
  return col.midiChan - chanLo, streamIdOf(col)
end

-- The instance whose region covers the caret cell, or nil. Region mode
-- seeds from this so entry lands on what the caret is over.
function tv:instanceAtCursor()
  local _, c = ec:pos()
  if not grid.cols[c] then return nil end
  local ppq = ec:row() * logPerRowFor(currentRpb())
  for _, e in ipairs(gm:eachInstance()) do
    if ppq >= e.anchor.ppq and ppq < e.anchor.ppq + e.rect.dur then
      local off, sid = tv:streamRefAt(c, e.anchor.chan)
      if off and e.rect.streams[off] and e.rect.streams[off][sid] then
        return { groupId = e.groupId, instId = e.instId }
      end
    end
  end
end

-- Page region-wash reads group instances and per-event state through tv, never gm.
function tv:eachInstance() return gm:eachInstance() end
function tv:stateOf(uuid) return gm:stateOf(uuid) end

-- Install the grid selection for one group instance: its anchor + the
-- group rect -> selectRegionAt (the duplicate-cascade selector). The ec
-- region-mode bridge speaks this; ec never reads gm geometry directly.
function tv:instanceSelection(groupId, instId)
  for _, e in ipairs(gm:eachInstance()) do
    if e.groupId == groupId and e.instId == instId then
      return selectRegionAt(e.anchor, e.rect)
    end
  end
end

--contract: extend hands newly-covered concretes in as `gained` (gm:resizeGroup never rescans)
--contract: idempotent: re-painting an already on/off stream is a no-op true
--invariant: group's live rect found by id off gm:eachInstance — ec carries no geometry
function tv:paintRegionStream(groupId, instId, colIx, on)
  local rect
  for _, e in ipairs(gm:eachInstance()) do
    if e.groupId == groupId then rect = e.rect; break end
  end
  if not rect then return end
  local off, sid = tv:streamRefAt(colIx, rect.chanLo)
  if not off then return end

  local already = rect.streams[off] and rect.streams[off][sid] == true
  if (on and already) or (not on and not already) then return true end

  local streams = {}
  for o, set in pairs(rect.streams) do
    streams[o] = {}
    for k in pairs(set) do streams[o][k] = true end
  end
  streams[off] = streams[off] or {}
  streams[off][sid] = on or nil

  local gained
  if on then
    gained = tv:eventsInRect{ ppq = rect.ppq, dur = rect.dur,
      chanLo = rect.chanLo, streams = { [off] = { [sid] = true } } }
  end
  return gm:resizeGroup(groupId, instId, { streams = streams, gained = gained })
end

----- Non-command callbacks from trackerPage

function tv:setGridSize(w, h)
  gridWidth, gridHeight = w, h
end

----- Columns

function tv:addExtraCol(type, cc)
  local extras = ds:get('extraColumns') or {}
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
  ds:assign('extraColumns', extras)
  -- A cc column at a carrier's code relocates it on the ensuing rebuild; re-run
  -- pa so the add-bank src follows the move. see design/archive/note-macros.md § Delta-code allocation
  if type == 'cc' then pa:apply() end
end

function tv:hideExtraCol()
  local col = grid.cols[ec:col()]
  if not col then return end
  local chan = col.midiChan

  -- Note col with delay shown: strip the delay first; the column itself
  -- only goes on a subsequent hide.
  if col.type == 'note' then
    local lane = col.lane
    local nd = ds:get('noteDelay') or {}
    local chanMap = nd[chan]
    if chanMap and chanMap[lane] then
      chanMap[lane] = nil
      nd[chan] = next(chanMap) and chanMap
      ds:assign('noteDelay', next(nd) and nd or util.REMOVE)
      tv:rebuild()
      return
    end
  end

  if #col.events > 0 then return end

  local extras = ds:get('extraColumns') or {}
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
    if pa:binding(chan, col.cc) then pa:unautomate(chan, col.cc) end
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
  ds:assign('extraColumns', next(extras) and extras or util.REMOVE)
  tv:rebuild()
end

----- Param automation (palette selection, touch-learn + pa pass-throughs)

--shape: paletteParam = { trackGuid, fxGuid, param, label } — the palette's selected parameter
local paletteParam  = nil
local paletteFilter = ''
--shape: paletteExpanded = { [fxGuid] = true } — open fx subtrees in the palette tree
local paletteExpanded = {}
--shape: paletteCursor = { fxGuid, param } — palette tree cursor; param nil = the fx heading row
local paletteCursor   = nil

-- Learn-touched params float above pa's frecency order until the bound
-- take changes; validated lazily against cm:boundTake, no lifecycle hook.
local hoist = { take = nil, byFx = {} }

--shape: learn = { trackGuid, fxGuid, floated, away, baseline } — armed touch-learn, or nil
local learn = nil

local function takeHoist()
  if hoist.take ~= cm:boundTake() then hoist = { take = cm:boundTake(), byFx = {} } end
  return hoist.byFx
end

local function hoistTouch(fxGuid, paramIndex)
  local byFx  = takeHoist()
  local order = byFx[fxGuid] or {}
  byFx[fxGuid] = order
  for i, idx in ipairs(order) do
    if idx == paramIndex then table.remove(order, i); break end
  end
  table.insert(order, 1, paramIndex)
end

function tv:paletteParam()         return paletteParam end
function tv:setPaletteParam(sel)   paletteParam = sel end
function tv:paletteFilter()        return paletteFilter end
function tv:setPaletteFilter(text) paletteFilter = text end
function tv:paletteExpanded()         return paletteExpanded end
function tv:setFxExpanded(fxGuid, on) paletteExpanded[fxGuid] = on or nil end
function tv:paletteCursor()           return paletteCursor end
function tv:setPaletteCursor(c)        paletteCursor = c end

function tv:paramTargets()           return pa:targets() end
function tv:paramBinding(chan, lane) return pa:binding(chan, lane) end

--contract: pa's frecency order with this take's learn-touched params on top, recent first
function tv:listParams(trackGuid, fxGuid)
  local params = pa:params(trackGuid, fxGuid)
  local order = takeHoist()[fxGuid]
  if not order or #order == 0 then return params end
  local hoisted, out = {}, {}
  for _, idx in ipairs(order) do hoisted[idx] = true end
  for _, idx in ipairs(order) do
    for _, prm in ipairs(params) do
      if prm.index == idx then out[#out + 1] = prm; break end
    end
  end
  for _, prm in ipairs(params) do
    if not hoisted[prm.index] then out[#out + 1] = prm end
  end
  return out
end

----- Touch-learn

--contract: arming floats the fx ui; the pre-arm touch is snapshotted so it can't select
function tv:armLearn(row)
  local rearm = learn and learn.fxGuid == row.fxGuid
  tv:cancelLearn()
  if rearm then return end
  learn = { trackGuid = row.trackGuid, fxGuid = row.fxGuid,
            floated  = pa:floatFx(row.trackGuid, row.fxGuid),
            away     = false, baseline = pa:lastTouched() }
end

function tv:learnFxGuid() return learn and learn.fxGuid end

-- The palette's 'show' button: float the fx ui without arming learn.
function tv:showFx(row) pa:floatFx(row.trackGuid, row.fxGuid) end

--contract: pops the fx window down only when arming floated it
function tv:cancelLearn()
  if learn and learn.floated then pa:unfloatFx(learn.trackGuid, learn.fxGuid) end
  learn = nil
end

--contract: focused = any ImGui window focused; cancel fires on regain after a loss
--contract: a touch on the armed fx selects + hoists; frecency is bumped by automate only
function tv:pollLearn(focused)
  if not learn then return end
  if not focused then
    learn.away = true
  elseif learn.away then
    return tv:cancelLearn()
  end
  local touched = pa:lastTouched()
  if not (touched and touched.fxGuid == learn.fxGuid) then return end
  local base = learn.baseline
  if base and base.fxGuid == touched.fxGuid and base.param == touched.param then return end
  learn.baseline = nil
  if paletteParam and paletteParam.fxGuid == touched.fxGuid
                  and paletteParam.param  == touched.param then return end
  paletteParam = { trackGuid = touched.trackGuid, fxGuid = touched.fxGuid,
                   param = touched.param, label = touched.name }
  hoistTouch(touched.fxGuid, touched.param)
end

--contract: binds the selected palette param at the cursor column's channel; adds its cc column
function tv:automateParam()
  local col = grid.cols[ec:col()]
  if not (col and paletteParam) then return end
  local lane = pa:automate(col.midiChan, paletteParam)
  if not lane then return end
  pa:bumpFrecency(paletteParam.trackGuid, paletteParam.fxGuid, paletteParam.label)
  tv:cancelLearn()
  local extras = ds:get('extraColumns') or {}
  -- Absence-default mirrors tm:rebuild's, like addExtraCol: no entry means one note col.
  local want = extras[col.midiChan] or { notes = 1 }
  extras[col.midiChan] = want
  want.ccs = want.ccs or {}
  want.ccs[lane] = true
  ds:assign('extraColumns', extras)
end

--contract: deletes the cursor cc column's events; column + binding then go via hideExtraCol
function tv:unautomateParam()
  local col = grid.cols[ec:col()]
  if not (col and col.type == 'cc') then return end
  for _, evt in ipairs(col.events) do tm:deleteEvent(evt) end
  tm:flush()
  -- hideExtraCol re-reads the grid; rebuild so it sees the emptied lane.
  tv:rebuild()
  tv:hideExtraCol()
end

function tv:showDelay()
  local nd = ds:get('noteDelay') or {}
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
  if changed then ds:assign('noteDelay', nd) end
end


----- Group quick-verbs

-- mark and copy share the one groupSrc lifetime; without this, mark ->
-- groupPaste degrades to plain paste (groupPaste gates on groupSrc, not
-- the active group).
local function groupMark()
  local r = tv:selectionAsRect()
  if r then groupSrc = r; gm:mark(tv:eventsInRect(r), r) end
end

-- Cascade copies into one group. Capture the seed events BEFORE clearing
-- -- source and destination may overlap. clearRegionAt wipes the
-- destination so the projection replaces rather than interleaves;
-- tm:flush commits gm's staged adds (it only stages otherwise,
-- colliding with the next edit).
local function groupDuplicate()
  groupDupState = tv:duplicateCascade(groupDupState, nil,
    function(rect, anchor, gid)
      local src = gid and {} or tv:eventsInRect(rect)
      tv:clearRegionAt(rect, anchor)
      gid = gm:duplicateInto(gid, src, rect, anchor)
      tm:flush()
      return gid
    end)
end

-- The pasted region [a.ppq, a.ppq+groupSrc.dur) must fit wholly inside
-- the take. Out of bounds is a silent no-op, NOT a fallthrough to plain
-- paste (that would paste non-group content the user didn't ask for);
-- the fallthrough is only for "no group source".
local function groupPaste()
  local a = tv:cursorAnchor()
  if groupSrc and a then
    if a.ppq + groupSrc.dur <= tm:length() then
      local src = tv:eventsInRect(groupSrc)
      tv:clearRegionAt(groupSrc, a)
      gm:stamp(src, groupSrc, a)
      tm:flush()
    end
  else
    cmgr:invoke('paste')
  end
end


----- Command table

local tracker = cmgr:scope('tracker')

tracker:registerAll{
  cut                     = { function() clipboard:copy(); deleteSelection() end, 'Cut' },
  delete                  = { deleteOrBackspace,                                  'Delete' },
  interpolate             = { function() interpolate() end,                       'Interpolate' },
  deleteSel               = { function() deleteSelection() end,                   'Delete selection' },
  duplicateDown           = { duplicate,                                          'Duplicate' },
  inputOctaveUp           = function() cm:set('take', 'currentOctave', util.clamp(cm:get('currentOctave')+1, -1, 9)) end,
  inputOctaveDown         = function() cm:set('take', 'currentOctave', util.clamp(cm:get('currentOctave')-1, -1, 9)) end,
  inputSampleUp           = function() stepSample( 1) end,
  inputSampleDown         = function() stepSample(-1) end,
  noteOff                 = { noteOff,                                            'Note off' },
  growNote                = { function(p) adjustDuration(p,  1) end,              'Resize note' },
  shrinkNote              = { function(p) adjustDuration(p, -1) end,              'Resize note' },
  nudgeBack               = { function(p) adjustPosition(p, -1) end,              'Nudge' },
  nudgeForward            = { function(p) adjustPosition(p,  1) end,              'Nudge' },
  -- '(' halves: with prefix p = pn/pd, k = pd/pn (reciprocal). Default 1/2.
  scaleHalf               = { function()
    if not ec:hasSelection() then return end
    local pn, pd = cmgr:prefixRational()
    if pn then tv:scaleSelection(pd, pn)
    else       tv:scaleSelection(1, 2) end
  end, 'Halve' },
  -- ')' doubles: with prefix p = pn/pd, k = pn/pd. Default 2/1.
  scaleDouble             = { function()
    if not ec:hasSelection() then return end
    local pn, pd = cmgr:prefixRational()
    if pn then tv:scaleSelection(pn, pd)
    else       tv:scaleSelection(2, 1) end
  end, 'Double' },
  insertRow               = { function() insertRow() end,         'Insert row' },
  deleteRow               = { function() deleteRow() end,         'Delete row' },
  insertRowCol            = { function() insertRowCol() end,      'Insert row in column' },
  deleteRowCol            = { function() deleteRowCol() end,      'Delete row in column' },
  nudgeCoarseUp           = { function(p) nudge(p,  1, true)  end, 'Nudge' },
  nudgeCoarseDown         = { function(p) nudge(p, -1, true)  end, 'Nudge' },
  nudgeFineUp             = { function(p) nudge(p,  1, false) end, 'Nudge' },
  nudgeFineDown           = { function(p) nudge(p, -1, false) end, 'Nudge' },
  eventShiftLeft          = { function() shiftEvents(-1) end,     'Move event left'  },
  eventShiftRight         = { function() shiftEvents( 1) end,     'Move event right' },
  playFromTop             = function() tm:playFrom(0) end,
  playFromCursor          = function()
    local col = grid.cols[ec:col()]
    tm:playFrom(ctx:rowToPPQ(ec:row(), col and col.midiChan))
  end,
  doubleRPB               = function() tv:setRowPerBeat(cm:get('rowPerBeat') * 2) end,
  halveRPB                = function() tv:setRowPerBeat(math.floor(cm:get('rowPerBeat') / 2)) end,
  matchGridToCursor       = matchGridToCursor,
  groupMark               = { groupMark,      'Mark group'      },
  groupDuplicate          = { groupDuplicate, 'Duplicate group' },
  groupPaste              = { groupPaste,     'Paste group'     },
  groupLocalToggle        = function() gm:setLocalMode(not gm:localMode()) end,
  regionEnter             = function() ec:enterRegionMode() end,
}

for i = 0, 9 do
  tracker:register('advBy' .. i, function() cm:set('take', 'advanceBy', i) end)
end

----- Rebuild

local rebuilding = false

--contract: reentrancy-guarded; bails on no-take (page shows placeholder)
--contract: takeChanged=true resets ec and re-reads resolution/length/timeSigs
--contract: grid/ctx/cell-maps/ghosts rebuild unconditionally; pushMute at end
function tv:rebuild(takeChanged)
  if not tm or rebuilding then return end
  if not tm:currentTake() then return end
  rebuilding = true
  takeChanged = takeChanged or false

  local LABELS = {
    note = 'Note', cc = 'CC', pb = 'PB', at = 'AT', pa = 'PA', pc = 'PC', fx = 'FX',
  }

  -- Length, resolution and timeSigs all change without a take swap:
  -- length on resize (take properties), resolution under tempo changes,
  -- timeSigs on edits to the project's tempo/time-sig markers.
  resolution = tm:resolution()
  length     = tm:length()
  timeSigs   = tm:timeSigs()
  if takeChanged then
    ec:reset()
  end

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

    local noteDelayCfg = ds:get('noteDelay') or {}
    local trackerMode  = cm:get('trackerMode')
    local temper       = tuning.findTemper(cm:get('temper'), cm:get('tempers'))
    local pitchWidth   = temper and temper.cellWidth or 3

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
      ec:decorateCol(gridCol, pitchWidth)   -- stamps parts/stopPos/partAt/partStart/width
      util.add(grid.cols, gridCol)
      grid.chanFirstCol[chan] = grid.chanFirstCol[chan] or #grid.cols
      grid.chanLastCol[chan]  = #grid.cols
      if type == 'note' and key == 1 then grid.lane1Col[chan] = gridCol end
    end

    -- fx-region columns are data-derived (one per channel carrying a region); each is a
    -- tailed kind-badge the cell/tail build below handles via ppq/endppqC. see design/note-macros-v2.md § Authoring
    local fxByChan = {}
    for _, region in ipairs(ds:get('fxRegions') or {}) do
      util.bucket(fxByChan, region.chan, region)
    end

    for chan, channel in tm:channels() do
      local c = channel.columns
      if c.pc and not trackerMode then addGridCol(chan, 'pc', nil, c.pc.events) end
      if c.pb then addGridCol(chan, 'pb', nil,  c.pb.events) end
      -- Replace-region parked notes left the take so the arp packs to lane 1, but they remain
      -- the displayed chord: union each back into its lane. see design/note-macros-v2.md § Generator output
      local parkedByLane = {}
      for _, m in ipairs(channel.parked or {}) do util.bucket(parkedByLane, m.lane, m) end
      for lane, col in ipairs(c.notes) do
        local events = col.events
        if parkedByLane[lane] then
          events = {}
          for _, e in ipairs(col.events)        do util.add(events, e) end
          for _, e in ipairs(parkedByLane[lane]) do util.add(events, e) end
          table.sort(events, function(a, b) return (a.ppq or 0) < (b.ppq or 0) end)
        end
        addGridCol(chan, 'note', lane, events)
      end
      if c.at then addGridCol(chan, 'at', nil,  c.at.events) end
      local ccNums = {}
      for n in pairs(c.ccs) do util.add(ccNums, n) end
      table.sort(ccNums)
      for _, n in ipairs(ccNums) do addGridCol(chan, 'cc', n, c.ccs[n].events) end
      local fxCells = {}
      for _, region in ipairs(fxByChan[chan] or {}) do
        local kind = region.fx and region.fx[1] and region.fx[1].kind
        if kind then
          util.add(fxCells, { ppq = region.startppq, endppqC = region.endppq,
                              kind = kind, uuid = region.uuid })
        end
      end
      if #fxCells > 0 then addGridCol(chan, 'fx', nil, fxCells) end
    end

    local numRows = math.max(1, math.ceil(length / ppqPerRow))
    grid.numRows  = numRows

    ctx = util.instantiate('viewContext', {
      length     = length,
      numRows    = numRows,
      rowPerBeat = rpb,
      ppqPerRow  = ppqPerRow,
      timeSigs   = timeSigs,
      temper     = temper,
    })

    for ci, gridCol in ipairs(grid.cols) do
      gridCol.overflow = {}
      gridCol.offGrid  = {}
      if gridCol.type == 'note' or gridCol.type == 'fx' then gridCol.tails = {} end
      local chan = gridCol.midiChan
      for _, evt in ipairs(gridCol.events) do
        local startRow = ctx:ppqToRow(evt.ppq or 0, chan)
        local onGrid   = ctx:isOnGrid(evt.ppq or 0, chan)
        -- On-grid onset a float-hair below its row boundary must snap to
        -- the nearest row, not floor to the one below; off-grid keeps floor.
        local y = onGrid and ctx:snapRow(evt.ppq or 0, chan) or math.floor(startRow)
        if y >= 0 and y < numRows then
          if gridCol.cells[y] then
            gridCol.overflow[y] = true
          else
            gridCol.cells[y] = evt
            if not onGrid then gridCol.offGrid[y] = true end
          end
        end
        -- endppqC is the clipped logical ceiling (always numeric, even
        -- when the authored endppq is util.OPEN); the tail render is its
        -- sole consumer.
        if evt.endppqC then
          util.add(gridCol.tails, {
            startRow = startRow,
            endRow   = ctx:ppqToRow(evt.endppqC, chan),
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

--contract: blank the grid so renderBody falls through to the "Select a MIDI item" placeholder. Counterpart to bindTake(nil)'s dormant seam, for when the take is destroyed rather than handed off.
function tv:dropGrid()
  grid.cols         = {}
  grid.chanFirstCol = {}
  grid.chanLastCol  = {}
  grid.lane1Col     = {}
end

----- Lifecycle

do
  -- Mute/solo changes don't affect grid shape, so skip rebuild.
  local muteKeys = { mutedChannels = true, soloedChannels = true }

  local pendingTakeSwap = false
  tm:subscribe('takeSwapped', function() pendingTakeSwap = true end)
  tm:subscribe('rebuild', function()
    tv:rebuild(pendingTakeSwap)
    pendingTakeSwap = false
  end)
  --contract: tv consumes configChanged only for transient-frame release and mute pulse
  --contract: rebuild is driven by tm's 'rebuild' signal — closes the (cm, tm) double-fire race
  --contract: non-transient FRAME_KEYS write while transient override active routes into releaseTransientFrame
  --invariant: releaseTransientFrame's cm:assign fires configChanged → tm:rebuild → tv:rebuild
  cm:subscribe('configChanged', function(change)
    if isFrameChange(change) and releaseTransientFrame() then return end
  end)

  -- Mute/solo are document data now: their dataChanged drives pushMute, no rebuild.
  ds:subscribe('dataChanged', function(change)
    if muteKeys[change.name] then pushMute() end
  end)
end

----- Factory load

-- The grid<->logical surface ec region mode reaches gm through. ec
-- never touches gm geometry or tm directly -- everything via these.
local groupBridge = {
  gm                = gm,
  eventsInRect      = function(rect) return tv:eventsInRect(rect) end,
  selectionAsRect   = function()     return tv:selectionAsRect() end,
  cursorAnchor      = function()     return tv:cursorAnchor() end,
  instanceSelection = function(g, i) return tv:instanceSelection(g, i) end,
  instanceAt        = function()     return tv:instanceAtCursor() end,
  paintStream       = function(g, i, c, on) return tv:paintRegionStream(g, i, c, on) end,
  -- The caller clears the destination before gm stages its projection
  -- (gm:newInstance contract: gm only re-places its own concretes).
  clearAt           = function(g, anchor)
    local rect = gm:groupRect(g)
    if rect then tv:clearRegionAt(rect, anchor) end
  end,
  -- gm only stages; the creation verbs flush so a new instance
  -- materialises now, not on the next unrelated mutation.
  commit            = function()     return tm:flush() end,
}

ec = util.instantiate('editCursor', {
  grid        = grid,
  cm          = cm,
  cmgr        = cmgr,
  rowPerBar   = function() return rowPerBar end,
  logPerRow   = function() return logPerRowFor(currentRpb()) end,
  moveHook    = followViewport,
  groupBridge = groupBridge,
})

clipboard = util.instantiate('clipboard', {
  ec = ec, grid = grid, tm = tm, cm = cm,
  currentRpb   = currentRpb,
  getCtx       = function() return ctx end,
  getLength    = function() return length end,
})

ec:registerCommands(tracker)
clipboard:registerCommands(tracker)

cmgr:doAfter({
  'nudgeCoarseUp', 'nudgeCoarseDown', 'nudgeFineUp', 'nudgeFineDown',
  'nudgeBack', 'nudgeForward', 'growNote', 'shrinkNote',
  'duplicateDown', 'interpolate', 'insertRow',
  'deleteRow', 'insertRowCol', 'deleteRowCol', 'noteOff',
}, function() ec:unstick() end)

cmgr:doAfter({ 'delete', 'deleteSel', 'cut' }, function() ec:selClear() end)

cmgr:doBefore({
  'cursorDown', 'cursorUp', 'pageDown', 'pageUp',
  'goTop', 'goBottom', 'goLeft', 'goRight',
  'cursorRight', 'cursorLeft', 'selectDown', 'selectUp',
  'selectRight', 'selectLeft', 'selectClear', 'colRight',
  'colLeft', 'channelRight', 'channelLeft', 'delete',
}, killAudition)

-- A plain duplicate run survives pure cursor moves and the deselection
-- they cause (the DUP_KEEP policy, mirroring trackerPage's); any new
-- selection or mutation ends it.
do
  local keep = { duplicateDown = true, selectClear = true,
    cursorUp=true, cursorDown=true, cursorLeft=true, cursorRight=true,
    pageUp=true, pageDown=true, goTop=true, goBottom=true,
    goLeft=true, goRight=true, colLeft=true, colRight=true,
    channelLeft=true, channelRight=true }
  for i = 0, 9 do keep['advBy' .. i] = true end
  local clearOn = {}
  for name in pairs(tracker.registered) do
    if not keep[name] then clearOn[#clearOn + 1] = name end
  end
  cmgr:doBefore(clearOn, function() dupeState = nil end)
end

----- Group quick-verb lifetimes
--
-- groupSrc + active (mark/copy -> groupPaste): survive navigation
-- between copy and paste; only a real mutation clears them. Keep-set =
-- GROUP_KEEP. groupDupState (groupDuplicate cascade): survives pure
-- cursor moves only; any new selection or mutation ends the run.
-- Keep-set = DUP_KEEP (a strict subset of GROUP_KEEP).
local GROUP_PASSTHROUGH = {
  cursorUp=true, cursorDown=true, cursorLeft=true, cursorRight=true,
  pageUp=true, pageDown=true, goTop=true, goBottom=true, goLeft=true, goRight=true,
  colLeft=true, colRight=true, channelLeft=true, channelRight=true,
  selectUp=true, selectDown=true, selectLeft=true, selectRight=true, selectClear=true,
  cycleBlock=true, cycleVBlock=true, swapBlockEnds=true,
}
for i = 0, 9 do GROUP_PASSTHROUGH['advBy' .. i] = true end

local GROUP_KEEP = {}
for k in pairs(GROUP_PASSTHROUGH) do GROUP_KEEP[k] = true end
for _, n in ipairs{ 'copy', 'groupMark', 'groupDuplicate',
                    'groupPaste', 'groupLocalToggle', 'regionEnter' } do
  GROUP_KEEP[n] = true
end

local DUP_KEEP = { groupDuplicate = true, selectClear = true,
  cursorUp=true, cursorDown=true, cursorLeft=true, cursorRight=true,
  pageUp=true, pageDown=true, goTop=true, goBottom=true,
  goLeft=true, goRight=true, colLeft=true, colRight=true,
  channelLeft=true, channelRight=true,
}
for i = 0, 9 do DUP_KEEP['advBy' .. i] = true end

-- Snapshot the source on copy + install the clear-on-mutation sweep.
-- Must run AFTER every tracker command (tv's, clipboard's, ec's AND
-- trackerPage's page verbs) registers, so the sweep covers page commands
-- too -- trackerPage calls this once post-registration. copy is plain:
-- clipboard:copy ends with ec:selClear(), so a doAfter snapshot would
-- see an empty selection; doBefore captures the live rect.
function tv:wireGroupLifetime()
  cmgr:doBefore('copy', function() groupSrc = tv:selectionAsRect() end)
  local clearOn, dupClearOn = {}, {}
  for name in pairs(tracker.registered) do
    if not GROUP_KEEP[name] then clearOn[#clearOn + 1]    = name end
    if not DUP_KEEP[name]   then dupClearOn[#dupClearOn+1] = name end
  end
  cmgr:doBefore(clearOn, function() groupSrc = nil; gm:clearActive() end)
  cmgr:doBefore(dupClearOn, function() groupDupState = nil end)
end

-- Mouse re-selection ends both cursor-anchored cascades by hand (cmgr's keep-set
-- sweep doesn't see the mouse, so the run tokens would outlive a fresh selection).
function tv:endReselectCascades() dupeState, groupDupState = nil, nil end

-- A committed typed edit cancels every cascade and drops the groupPaste
-- source, exactly as a non-keep cmgr command would -- editEvent is the
-- mutation the keep-set sweeps cannot see (it never reaches cmgr).
function tv:endAllCascades()
  dupeState, groupDupState, groupSrc = nil, nil, nil
  if gm then gm:clearActive() end
end

tv:rebuild(true)
return tv

