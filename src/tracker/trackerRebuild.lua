-- The derivation engine: one gated pass reconstructs intent from mm, then reauthors raw from it.
-- One door: rebuild.pipeline runs a pass. See docs/trackerManager.md § Rebuild for the model.

local util       = require 'util'
local spans      = require 'spans'
local curves     = require 'curves'
local timing     = require 'timing'
local voicing    = require 'voicing'
local tuning     = require 'tuning'
local generators = require 'generators'
local fxWindows  = require 'fxWindows'

local mm, cm, ds = (...).mm, (...).cm, (...).ds
local defaultNoteCols = (...).defaultNoteCols -- Forced note columns per channel absent an extraColumns entry
local index, stager, dirt, frame = (...).index, (...).stager, (...).dirt, (...).frame

local rebuild = {}

----- Module state and constants

--shape: fxNotesByHost[chan][uuid] = { { evType='note', chan, ppq (logical), endppq (logical), pitch, vel, detune, delay, derived (= host's uuid), [intentCents], [baseVoice] }, ... }; logical-onset order
local fxNotesByHost = {}
local time

----- Rebuild shared helpers

local function delayToPPQ(delay) return timing.delayToPPQ(delay, mm:resolution()) end

-- CCINTERP is interpolated points per QN; densification consumes a tick step
local function ccGridStep()
  return math.max(1, util.round((mm:resolution() or 960) / mm:ccInterp()))
end

local function onsetsIn(events, spanSet)
  spanSet = spanSet or {}
  local nextSpan, i, hi = 1, 1, -math.huge
  return function()
    while true do
      local evt = events[i]
      if evt and evt.ppq < hi then
        i = i + 1
        return evt
      end
      local span = spanSet[nextSpan]
      if not span then return end
      nextSpan, i, hi = nextSpan + 1, util.firstAtOrAfter(events, span[1]), span[2]
    end
  end
end

local function ensureLane(chan, lane)
  local notes = frame.channels[chan].onTake.notes
  while #notes < lane do util.add(notes, frame.newNoteColumn()) end
  return notes[lane]
end

local function columnEvent(evt, overlay)
  local colEvt = util.clone(evt, { loc = true, colEvt = true })
  colEvt.committed = true
  if overlay then util.assign(colEvt, overlay) end
  return colEvt
end

local function projectEvent(evt, chan)
  if evt.ppqL ~= nil then
    if evt.delay ~= nil then
      local baseline = time:fromLogical(chan, evt.ppqL)
      evt.delayC = util.round(timing.ppqToDelay(evt.ppq - baseline, mm:resolution()))
    end
    evt.ppq = evt.ppqL
  end
  if evt.endppq ~= nil then
    evt.endppq = evt.endppqL or time:toLogical(chan, evt.endppq)
  end
  evt.ppqL, evt.endppqL = nil, nil
end

-- Accumulate mm ops, then commit in delete -> assign -> add order
local function mmBatch()
  local deletes, assigns, adds = {}, {}, {}
  return {
    delete  = function(evt)         util.add(deletes, evt) end,
    assign  = function(evt, update) util.add(assigns, { evt = evt, update = update }) end,
    add     = function(evt)         util.add(adds, evt) end,
    commit  = function()
      if #deletes + #assigns + #adds == 0 then return end
      local touched = {}
      mm:modify(function()
        for _, e in ipairs(deletes) do
          mm:delete(e.uuid)
          touched[e.uuid] = true
        end
        for _, a in ipairs(assigns) do
          mm:assign(a.evt.uuid, a.update)
          touched[a.evt.uuid] = true
        end
        for _, e in ipairs(adds) do
          local u = mm:add(e)
          touched[u] = true
        end
      end)
      index.withDeferredSort(function()
        for uuid in pairs(touched) do index.sync(uuid) end
      end)
    end,
  }
end

local EPS = 1 -- ppq tolerance for "raw agrees with its logical projection"

local function rawDivergesFromLogical(evt)
  if evt.ppqL == nil             then return true  end
  if dirt.swing.has(evt.chan)    then return false end
  if not dirt.foreign.has(evt.chan) then return false end
  local delayPpq = evt.evType == 'note' and delayToPPQ(evt.delay or 0) or 0
  local rawFromLogical = time:fromLogical(evt.chan, evt.ppqL, delayPpq)
  if evt.ppq == 0 and rawFromLogical < 0 then return false end
  return math.abs(evt.ppq - rawFromLogical) > EPS
end

local function isAuthored(note) -- "authored" means "Continuum authored"
  return not note.derived and note.ppqL ~= nil
end

-- Exclude derived events which re-ran this pass and foreign MIDI,
-- keep authored events and retained derived events.
local function survivingEvents(ran)
  return function(rec)
    if rec.ppqL == nil then return false end -- foreign MIDI
    return not (rec.derived and ran[rec.derived])
  end
end

local function diffEvents(existing, predicted, writes, key, onKeep)
  local byKey, taken, kept = {}, {}, {}
  onKeep = onKeep or function (_,_) end
  for _, evt in ipairs(existing) do util.bucket(byKey, key(evt), evt) end
  for _, spec in ipairs(predicted) do
    local k = key(spec)
    local at = (taken[k] or 0) + 1
    local evt = byKey[k] and byKey[k][at]
    if evt then taken[k] = at; kept[evt] = true; onKeep(spec, evt)
    else writes.add(spec)
    end
  end
  for _, e in ipairs(existing) do
    if not kept[e] then writes.delete(e) end
  end
end

local function exciseEvents(cols, ppqs, claims)
  claims = claims or function (_) return true end
  for _, col in ipairs(cols) do
    local events = col.events
    local drop = {}
    for _, ppq in ipairs(ppqs) do
      for i = util.firstAtOrAfter(events, ppq), #events do
        local evt = events[i]
        if evt.ppq > ppq then break end
        if claims(evt) then drop[evt] = true end
      end
    end
    if next(drop) then
      local kept = {}
      for _, evt in ipairs(events) do
        if not drop[evt] then util.add(kept, evt) end
      end
      col.events = kept   -- kept is a fresh table: this assignment is the renewal
      frame.markRenewed(col)
    end
  end
end

local function persistKey(key, new, old)
  if not util.deepEq(old or {}, new) and mm:take() then
    ds:assign(key, #new > 0 and new or util.REMOVE)
  end
end

----- Rebuild internals

-- Partition mm notes stamped/external, write internal columns, reseat
-- stale-swing.
local function rebuildInternals()
  local internal, external = {}, {}
  for chan = 1, 16 do
    if dirt.has(chan) then
      if not dirt.wholesale(chan) then exciseEvents(frame.channels[chan].onTake.notes, dirt.ppqs(chan, 'note')) end
      for _, raw in mm:notesRaw(chan) do
        if not raw.derived and dirt.covers(chan, raw.ppqL or raw.ppq, 'note') then
          local note = columnEvent(raw)
          if rawDivergesFromLogical(note) then util.add(external, note)
          else util.add(internal, note)
          end
        end
      end
    end
  end

  local swingWrites = mmBatch()
  local disordered = {}
  for _, note in ipairs(internal) do
    local col = ensureLane(note.chan, note.lane)
    note.detune = note.detune or 0
    note.delay  = note.delay  or 0
    if dirt.swing.has(note.chan) then
      -- Rederive ppq only; the tail walk handles endppq and nudges
      local reswungPpq = time:fromLogical(note.chan, note.ppqL, delayToPPQ(note.delay))
      if reswungPpq ~= note.ppq then swingWrites.assign(note, { ppq = reswungPpq }) end
      note.ppq = reswungPpq
    end
    projectEvent(note, note.chan) -- Columns are always in logical ppq
    if not dirt.wholesale(note.chan) and not dirt.swing.has(note.chan) then
      frame.spliceEvent(note.chan, note.lane, note) -- into the carried logical lane; stays ordered
    else
      util.add(col.events, note)
      disordered[col] = true
    end
    index.stampColEvt(note)
  end

  for col in pairs(disordered) do frame.orderColumn(col) end
  swingWrites.commit()

  return external
end

----- Rebuild CCs

local function ensureCcColumn(chan, evType, ccNum)
  local cols = frame.channels[chan].onTake
  if evType == 'cc' then
    cols.ccs[ccNum] = cols.ccs[ccNum] or frame.newCcColumn(ccNum)
    return cols.ccs[ccNum]
  else
    cols[evType] = cols[evType] or frame.newStreamColumn()
    return cols[evType]
  end
end

local function spliceCcEvent(entry)
  local event = columnEvent(entry)
  local col   = ensureCcColumn(entry.chan, entry.evType, entry.cc)
  projectEvent(event, entry.chan)
  frame.spliceInto(col, event)
end

local function appendCcEvent(entry, update)
  local event = columnEvent(entry, update)
  local col   = ensureCcColumn(entry.chan, entry.evType, entry.cc)
  projectEvent(event, entry.chan)
  util.add(col.events, event)
end

-- Interval-dirt path: the rows in each seeded cc cell are cleared and refilled from the raw index.
-- See docs/trackerManager.md § Interval materialisation
local function spliceChannelCCs(chan)
  local cells   = dirt.ppqs(chan, 'cc')
  local refills = {}
  local cols = frame.channels[chan].onTake

  for _, cell in pairs(cells) do
    local raw = index.raw(chan)
    local list
    if cell.evType == 'cc' then list = raw.ccs[cell.cc]
    elseif cell.evType == 'at' then list = raw.ats
    elseif cell.evType == 'pc' then list = raw.pcs end
    if list then
      for _, ppqL in ipairs(cell.ppqs) do
        local ppq = time:fromLogical(chan, ppqL)
        for i = util.firstAtOrAfter(list, ppq), #list do
          local entry = list[i]
          if entry.ppq > ppq then break end
          if not entry.derived and entry.ppqL == ppqL then util.add(refills, entry) end
        end
      end
    end

    local col
    if cell.evType == 'cc' then col = cols.ccs[cell.cc]
    else col = cols[cell.evType] end
    if col then exciseEvents({ col }, cell.ppqs) end
  end
  for _, evt in ipairs(refills) do spliceCcEvent(evt) end
end

-- Reconciles ppq and ppqL per the swing rules; see docs/trackerManager.md § CC walk.
local function reconcileCcPpq(entry, fxInWindows, ccWrites)
  local chan = entry.chan
  local pbSeat = entry.evType == 'pb' and entry.ppqL == nil and fxInWindows.ownsRaw('pb', chan, nil, entry.ppq)
  if entry.derived or pbSeat then return nil end
  if dirt.swing.has(chan) and entry.ppqL ~= nil then
    local newPpq = time:fromLogical(chan, entry.ppqL)
    if newPpq == entry.ppq then return nil end
    ccWrites.assign({ uuid = entry.uuid }, { ppq = newPpq })
    return { ppq = newPpq }
  elseif rawDivergesFromLogical(entry) then
    local newPpqL = time:toLogical(chan, entry.ppq)
    ccWrites.assign({ uuid = entry.uuid }, { ppqL = newPpqL })
    return { ppqL = newPpqL }
  end
end

-- Wholesale / stale-swing path: re-derive channel ccs from the raw index.
-- pbs and pas reconcile only; see docs/trackerManager.md § CC walk
local function fullRebuildChannelCCs(chan, fxInWindows, ccWrites)
  local raw = index.raw(chan)
  index.withDeferredSort(function()
    for cc, list in pairs(raw.ccs) do
      for _, entry in ipairs(list) do
        index.assign(entry, 'derived', fxInWindows.ownsRaw('cc', chan, cc, entry.ppq))
        if not entry.derived then
          local update = reconcileCcPpq(entry, fxInWindows, ccWrites)
          appendCcEvent(entry, update)
        end
      end
    end
  end)
  for _, list in ipairs{ raw.ats, raw.pcs } do
    for _, entry in ipairs(list) do
      local update = reconcileCcPpq(entry, fxInWindows, ccWrites)
      appendCcEvent(entry, update)
    end
  end
  for _, list in ipairs{ raw.pbs, raw.pas } do
    for _, entry in ipairs(list) do reconcileCcPpq(entry, fxInWindows, ccWrites) end
  end
  for _, col in pairs(frame.channels[chan].onTake.ccs) do util.sortByPPQ(col.events) end
  for _, key in ipairs{ 'at', 'pc' } do
    if frame.channels[chan].onTake[key] then util.sortByPPQ(frame.channels[chan].onTake[key].events) end
  end
end

local function rebuildCCs(fxInWindows)
  local ccWrites = mmBatch()
  for chan = 1, 16 do
    if dirt.has(chan) then
      if dirt.wholesale(chan) then fullRebuildChannelCCs(chan, fxInWindows, ccWrites)
      else spliceChannelCCs(chan)
      end
    end
  end
  ccWrites.commit()
end

----- Rebuild extra columns

local function rebuildExtraColumns(extraColumns, paramAutomation)
  local extras = extraColumns or {}
  local bound  = paramAutomation or {}
  local grew   = false
  for chan = 1, 16 do
    local cols = frame.channels[chan].onTake
    local want = extras[chan] or { notes = defaultNoteCols }
    if #cols.notes > want.notes then
      want.notes = #cols.notes
      extras[chan] = want
      grew = true
    end
    ensureLane(chan, want.notes)
    if want.pc then cols.pc = cols.pc or frame.newStreamColumn() end
    if want.pb then cols.pb = cols.pb or frame.newStreamColumn() end
    if want.at then cols.at = cols.at or frame.newStreamColumn() end
    for ccNum in pairs(want.ccs or {}) do
      cols.ccs[ccNum] = cols.ccs[ccNum] or frame.newCcColumn(ccNum)
    end
    for lane in pairs(bound[chan] or {}) do
      cols.ccs[lane] = cols.ccs[lane] or frame.newCcColumn(lane)
    end
  end
  if grew and mm:take() then ds:assign('extraColumns', extras) end
end

----- Rebuild externals

-- Lane packing for one externals pass
local function externalLanePacker(external)
  local maxDelayPpq = 0
  local isExternal  = {}
  for _, note in ipairs(external) do
    maxDelayPpq = math.max(maxDelayPpq, delayToPPQ(note.delay or 0))
    isExternal[note.uuid] = true
  end

  local laneList do
    local occupancy = {}
    function laneList(chan, lane)
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
  end

  local laneAccepts do
    local onsetI  = {}
    local function onsetOf(evt)
      local ppqI = onsetI[evt]
      if not ppqI then
        ppqI        = evt.ppq - delayToPPQ(evt.delay or 0)
        onsetI[evt] = ppqI
      end
      return ppqI
    end

    local head = {}   -- [laneList] = first live index
    local maxOverlap = cm:get('overlapOffset') * mm:resolution()
    function laneAccepts(events, note)
      local floorPpq = note.ppq - maxDelayPpq
      local cursor   = head[events] or 1
      while cursor <= #events and events[cursor].endppq <= floorPpq do cursor = cursor + 1 end
      head[events] = cursor

      local noteppqI    = onsetOf(note)
      local noteEndppqI = note.endppq
      local dominated   = 0
      for i = #events, cursor, -1 do
        local evt     = events[i]
        local evtppqI = onsetOf(evt)
        if noteppqI == evtppqI then return false end
        if noteppqI < evt.endppq and evtppqI < noteEndppqI then
          local threshold     = (evt.pitch == note.pitch) and 0 or maxOverlap
          local overlapAmount = math.min(evt.endppq, noteEndppqI) - math.max(evtppqI, noteppqI)
          if overlapAmount > threshold then return false end
          dominated = dominated + 1
        end
      end
      return dominated < 2
    end
  end

  return function(channel, note)
    local function byRawOnset(a, b) return a.ppq < b.ppq end
    local function place(col, lane)
      util.insertSorted(laneList(note.chan, lane), note, byRawOnset)
      return col, lane
    end
    local notes = channel.onTake.notes
    if note.lane then
      local col = ensureLane(note.chan, note.lane)
      if laneAccepts(laneList(note.chan, note.lane), note) then return place(col, note.lane) end
    end
    for i, col in ipairs(notes) do
      if laneAccepts(laneList(note.chan, i), note) then return place(col, i) end
    end
    return place(util.add(notes, frame.newNoteColumn()), #notes)
  end
end

local function rebuildExternals(external)
  if #external == 0 then return end
  util.sortByPPQ(external)

  local packLane    = externalLanePacker(external)
  local extWrites   = mmBatch()
  local seated      = {}
  for _, note in ipairs(external) do
    local delay     = note.delay or 0
    local probe     = { chan = note.chan, ppq = note.ppq, endppq = note.endppq,
                        pitch = note.pitch, delay = delay, lane = note.lane }
    local _, lane = packLane(frame.channels[note.chan], probe)
    local update    = {
      ppqL    = time:toLogical(note.chan, note.ppq - delayToPPQ(delay)),
      endppqL = time:toLogical(note.chan, note.endppq),
    }
    if note.lane   ~= lane then update.lane   = lane   end
    if note.detune == nil  then update.detune = 0      end
    if note.delay  == nil  then update.delay  = 0      end
    local colNote = columnEvent(note, update)
    colNote.fixed = true
    projectEvent(colNote, note.chan)
    frame.spliceEvent(note.chan, lane, colNote)
    util.add(seated, colNote)
    extWrites.assign(colNote, update)
  end
  extWrites.commit()
  for _, colNote in ipairs(seated) do index.stampColEvt(colNote) end
end

----- Rebuild sample stamp

local function rebuildSamples()
  local sampleWrites = mmBatch()
  local function stamp(entry)
    if entry.evType == 'note' and isAuthored(entry) and entry.sample == nil then
      local prevailing = util.seek(index.raw(entry.chan).pcs, 'at-or-before', entry.ppq)
      local sample = prevailing and prevailing.val or 0
      index.assign(entry, 'sample', sample)
      frame.setEvent(entry.colEvt, 'sample', sample)
      sampleWrites.assign(entry, { sample = sample })
    end
  end
  for chan = 1, 16 do
    if dirt.wholesale(chan) then
      for _, entry in ipairs(index.raw(chan).notes) do stamp(entry) end
    elseif dirt.has(chan) then
      for _, s in ipairs(dirt.has(chan)) do
        local entry = s.uuid and index.byUuid(s.uuid)
        if entry then stamp(entry) end
      end
    end
  end
  sampleWrites.commit()
end

----- Logical tail-clip

local function clipTails(chan)
  local channel, parkedMoved = frame.channels[chan], false
  local takeLenL = time:toLogical(chan, time:length())
  for lane = 1, #channel.onTake.notes do
    local offTake = {}
    for _, evt in ipairs(frame.parkedOnLane(chan, lane)) do offTake[evt] = true end
    local population = frame.authoredEvents(chan, lane)
    for _, evt in ipairs(population) do
      if not evt.derived and evt.evType ~= 'pa' then
        local bound = frame.clippedSpanEnd(evt, takeLenL, population)
        if evt.endppqC ~= bound then
          if offTake[evt] then
            evt.endppqC, parkedMoved = bound, true
          else
            dirt.tails.add(chan, evt.uuid)
            frame.setEvent(evt, 'endppqC', bound)
          end
        end
      end
    end
  end
  if parkedMoved then channel.parked.notes = util.clone(channel.parked.notes) end
end

----- Rebuild region park

-- The parked clone of a column event; the realisation frame
-- is removed, and re-added on unpark
--pre: evt is logical-frame; an mm-raw source must override ppq via `adds`
local toParked do
  local REALISATION = { delayC = true, endppqC = true, committed = true, derived = true,
                      frame = true, cents = true, colEvt = true, sampleShadowed = true,
                      raw = true }
  function toParked(evt, adds)
    return util.assign(util.clone(evt, REALISATION), adds)
  end
end

-- The mm-bound clone of a parked spec: raw onset, logical sidecar.
--pre: spec is logical-frame
local function fromParked(spec, adds)
  local ppq = time:fromLogical(spec.chan, spec.ppq)
  return util.assign(util.assign(util.clone(spec), { ppq = ppq, ppqL = spec.ppq }), adds)
end

local function installParked(field, specs, onSeat)
  local function sameParked(old, new)
    if not old or #old ~= #new then return false end
    for i, newSpec in ipairs(new) do
      local oldSpec = old[i]
      for k, v in pairs(newSpec) do
        -- endppqC excluded since it's derived after installation.
        if k ~= 'endppqC' and not util.deepEq(oldSpec[k], v) then return false end
      end
      for k in pairs(oldSpec) do if k ~= 'endppqC' and newSpec[k] == nil then return false end end
    end
    return true
  end

  local fresh = frame.newChannels()
  for _, spec in ipairs(specs) do util.bucket(fresh, spec.chan, util.clone(spec)) end

  for chan = 1, 16 do
    local parked = frame.channels[chan].parked
    if not sameParked(parked[field], fresh[chan]) then parked[field] = fresh[chan] end
  end

  if onSeat then
    for chan = 1, 16 do
      for _, spec in ipairs(frame.channels[chan].parked[field]) do onSeat(spec) end
    end
  end
end

local function installParkedNotes(fxParked)
  local notes = {}
  for _, evt in ipairs(fxParked or {}) do
    if evt.evType == 'note' then util.add(notes, evt) end
  end
  for _, note in ipairs(notes) do ensureLane(note.chan, note.lane) end
  installParked('notes', notes)
end

-- Shared context for the four passes.
--shape: stage = { writes = mmBatch, hostFor, reconcilePark, prior = { [evType] = specs },
--                 windowSpans = { [util.key(chan, target)] = merged spans } }
local function parkStage(fxOutWindows, fxParked)
  local writes = mmBatch()

  local function hostFor(evt)
    local host = fxOutWindows.owns(evt.evType, evt.chan, evt.cc, evt.ppq)
    if host then return host end
    if evt.fx and generators.parksNotes(evt) then return evt.uuid end
  end

  --shape: candidates = { evt (the live column/index event), col = evt's column (nil off-column), spec = toParked(evt, {...}) }
  local function reconcilePark(candidates, prior, onPark)
    onPark = onPark or function (_) end
    local function unlink(events, evt)
      for i, e in ipairs(events) do if e == evt then table.remove(events, i); break end end
    end
    local newParked, restores = {}, {}
    for _, candidate in ipairs(candidates) do
      if hostFor(candidate.spec) then
        onPark(candidate.spec)
        util.add(newParked, candidate.spec)
        writes.delete(candidate.evt)
        -- Unlink through the column, not the table the scan saw: renewal may replace that table
        -- between the scan and here, and the old one is no longer the one tv will read.
        if candidate.col then unlink(frame.renewColumn(candidate.col).events, candidate.evt) end
      end
    end
    for _, spec in ipairs(prior) do
      if hostFor(spec) then util.add(newParked, spec)
      else util.add(restores, spec) end
    end
    return newParked, restores
  end

  local prior = { note = {}, pa = {}, cc = {}, pb = {} }
  for _, spec in ipairs(fxParked or {}) do util.bucket(prior, spec.evType, spec) end

  -- Window spans per (chan, target) for the fresh note/cc scans.
  local buckets = {}
  for _, window in ipairs(fxOutWindows.windows()) do
    for target in pairs(window.targets) do
      util.bucket(buckets, util.key(window.chan, target), { window = { window.ppq, window.endppq } })
    end
  end
  local windowSpans = {}
  for key, bucket in pairs(buckets) do windowSpans[key] = spans.mergeWindows(bucket) end

  return { writes = writes, hostFor = hostFor, reconcilePark = reconcilePark,
           prior = prior, windowSpans = windowSpans }
end

local function parkNotes(stage, onTakeHosts)
  local candidates, seen = {}, {}
  local function addCandidate(evt)
    if not seen[evt] then  -- a host under its own region would arrive from both sources
      seen[evt] = true
      util.add(candidates, { evt = evt, col = frame.channels[evt.chan].onTake.notes[evt.lane], spec = toParked(evt) })
    end
  end
  for chan = 1, 16 do
    local windowSpans = stage.windowSpans[util.key(chan, 'note')]
    if windowSpans and dirt.has(chan) then
      for _, col in ipairs(frame.channels[chan].onTake.notes) do
        for evt in onsetsIn(col.events, windowSpans) do
          if util.isNote(evt) then addCandidate(evt) end
        end
      end
    end
  end
  for host in pairs(onTakeHosts) do
    if dirt.has(host.chan) and generators.parksNotes(host) then
      addCandidate(host)
    end
  end

  -- If park removes a note, same-lane/pitch neighbours' tails should regrow.
  local parkedNotes, restores = stage.reconcilePark(candidates, stage.prior.note,
    function(spec)
      dirt.add(spec.chan, dirt.parkSeed(spec, 'park', time:fromLogical(spec.chan, spec.ppq)))
    end)

  local restoredNotes = {}
  local takeLen = time:length()
  for _, spec in ipairs(restores) do
    ensureLane(spec.chan, spec.lane)
    local note = util.clone(spec)   -- the event is the spec: both are logical (keeps the parked uuid too)
    frame.spliceEvent(spec.chan, spec.lane, note)

    -- Provisional raw end; the tail clip below fills in endppqC, and rebuildTails
    -- back-fills raw from that.
    local rawPpq  = time:fromLogical(spec.chan, spec.ppq)
    local ceiling = math.min(time:fromLogical(spec.chan, spec.endppq or util.OPEN), takeLen)
    local evt = fromParked(spec, { keepUuid = true, endppqL = spec.endppq,
                                   endppq = util.round(math.max(rawPpq + 1, ceiling)) })
    dirt.add(spec.chan, dirt.parkSeed(spec, 'restore', evt.ppq))
    stage.writes.add(evt)

    util.add(restoredNotes, note)
  end

  for _, spec in ipairs(parkedNotes) do ensureLane(spec.chan, spec.lane) end
  local parkedByHost = {}
  installParked('notes', parkedNotes, function(spec)
    util.bucket(parkedByHost, stage.hostFor(spec), spec)
  end)

  local touched = {}
  for _, spec in ipairs(parkedNotes) do touched[spec.chan] = true end
  for _, spec in ipairs(restores)    do touched[spec.chan] = true end
  for chan in pairs(touched) do clipTails(chan) end

  return parkedNotes, restoredNotes, parkedByHost
end

--pre: parkNotes has installed this pass's parked notes
local function parkPAs(stage)
  local function covers(host, pitch, ppqL)
    return host.pitch == pitch and ppqL >= host.ppq and ppqL < host.endppqC
  end
  local function hostIsParked(chan, pitch, ppqL)
    for _, host in ipairs(frame.channels[chan].parked.notes) do
      if covers(host, pitch, ppqL) then return true end
    end
    return false
  end

  -- An on-take PA whose host just parked leaves the take.
  local parkedPAs, seen, parkedPpqs, parkedUuids = {}, {}, {}, {}
  for chan = 1, 16 do
    if dirt.has(chan) then
      local pas = index.raw(chan).pas
      for _, host in ipairs(frame.channels[chan].parked.notes) do
        for pa in onsetsIn(pas, { { time:fromLogical(chan, host.ppq), time:fromLogical(chan, host.endppqC) } }) do
          local ppqL = pa.ppqL or pa.ppq
          -- same-pitch parked spans can overlap (lane clips only), so a PA may meet two hosts
          if not seen[pa] and covers(host, pa.pitch, ppqL) then
            seen[pa] = true
            dirt.add(chan, dirt.rawSeed(pa, 'park'))
            stage.writes.delete({ uuid = pa.uuid })
            util.bucket(parkedPpqs, chan, ppqL)
            parkedUuids[pa.uuid] = true
            local spec = toParked(pa)
            projectEvent(spec, chan)
            spec.uuid = nil -- restore re-mints the rpb sidecar uuid
            util.add(parkedPAs, spec)
          end
        end
      end
    end
  end
  -- The parking PA wasn't excised by note-excision, so do it now.
  for chan, ppqs in pairs(parkedPpqs) do
    exciseEvents(frame.channels[chan].onTake.notes, ppqs,
                 function(e) return e.evType == 'pa' and parkedUuids[e.uuid] end)
  end

  for _, spec in ipairs(stage.prior.pa) do
    if hostIsParked(spec.chan, spec.pitch, spec.ppq) then
      util.add(parkedPAs, spec)
    else
      local evt = fromParked(spec)
      dirt.add(spec.chan, dirt.parkSeed(spec, 'restore', evt.ppq))
      stage.writes.add(evt)
    end
  end

  installParked('pa', parkedPAs)
  return parkedPAs
end

local function parkCCs(stage)
  local candidates = {}
  for chan = 1, 16 do
    if dirt.has(chan) then
      for cc, col in pairs(frame.channels[chan].onTake.ccs) do
        for evt in onsetsIn(col.events, stage.windowSpans[util.key(chan, cc)]) do
          util.add(candidates, { evt = evt, col = col, spec = toParked(evt) })
        end
      end
    end
  end
  local parkedCCs, restores = stage.reconcilePark(candidates, stage.prior.cc)

  local restoredCCs = {}
  for _, spec in ipairs(restores) do
    local evt = util.clone(spec)   -- the event is the spec: both are logical
    frame.spliceInto(ensureCcColumn(spec.chan, 'cc', spec.cc), evt)
    stage.writes.add(fromParked(spec, { keepUuid = true }))
    util.add(restoredCCs, evt)
  end

  for _, spec in ipairs(parkedCCs) do ensureCcColumn(spec.chan, 'cc', spec.cc) end
  installParked('ccs', parkedCCs)
  return parkedCCs, restoredCCs
end

local function parkPbs(stage, fxOutWindows, fxInWindows, pbLimCents)
  local function pbWindows(windowSet)
    local byKey = {}
    for _, window in ipairs(windowSet.windows()) do
      if window.targets.pb then byKey[util.key(window.chan, window.ppq, window.endppq)] = window end
    end
    return byKey
  end
  local prevWindows, curWindows = pbWindows(fxInWindows), pbWindows(fxOutWindows)
  local created, removed = {}, {}
  for k, window in pairs(curWindows)  do if not prevWindows[k] then util.add(created, window) end end
  for k, window in pairs(prevWindows) do if not curWindows[k]  then util.add(removed, window) end end

  local candidates = {}
  for _, window in ipairs(created) do
    for pb in onsetsIn(index.raw(window.chan).pbs, { { fxOutWindows.rawSpan(window) } }) do
      if not pb.derived and not fxInWindows.ownsRaw('pb', pb.chan, nil, pb.ppq) then
        dirt.add(pb.chan, dirt.rawSeed(pb, 'park'))
        -- val: logical cents from the sidecar, with index val
        -- (raw-derived cents) as the fallback for a foreign pb.
        local spec = toParked(pb, { val = pb.cents or pb.val })
        projectEvent(spec, pb.chan)
        util.add(candidates, { evt = { uuid = pb.uuid }, spec = spec }) -- evt is only the delete target
      end
    end
  end

  local parkedPbs, restores = stage.reconcilePark(candidates, stage.prior.pb)

  -- Restores get raw + cents sidecar. The val is detune-free; rebuildPbs corrects it later.
  for _, spec in ipairs(restores) do
    local evt = fromParked(spec, { cents = spec.val, val = tuning.centsToRaw(spec.val, pbLimCents) })
    dirt.add(spec.chan, dirt.parkSeed(spec, 'restore', evt.ppq))
    stage.writes.add(evt)
  end

  for _, window in ipairs(removed) do
    for pb in onsetsIn(index.raw(window.chan).pbs, { { fxInWindows.rawSpan(window) } }) do
      dirt.add(pb.chan, dirt.rawSeed(pb, 'delete'))
      stage.writes.delete({ uuid = pb.uuid })
    end
  end

  -- The cents decoration is realisation, so it decorates a copy.
  local rendered = {}
  for _, spec in ipairs(parkedPbs) do
    util.add(rendered, util.assign(util.clone(spec), { cents = spec.val }))
  end
  installParked('pb', rendered)
  return parkedPbs
end

local function rebuildRegionPark(fxOutWindows, fxParked, fxInWindows, onTakeHosts, pbLimCents)
  local stage                                    = parkStage(fxOutWindows, fxParked)
  local parkedNotes, restoredNotes, parkedByHost = parkNotes(stage, onTakeHosts)
  -- Order matters: parkPAs reconciles against the parked notes parkNotes installs.
  local parkedPAs                                = parkPAs(stage)
  local parkedCCs, restoredCCs                   = parkCCs(stage)
  local parkedPbs                                = parkPbs(stage, fxOutWindows, fxInWindows, pbLimCents)

  local allParked = {}
  for _, parked in ipairs({ parkedNotes, parkedPAs, parkedCCs, parkedPbs }) do
    for _, spec in ipairs(parked) do util.add(allParked, spec) end
  end
  persistKey('fxParked', allParked, fxParked)
  stage.writes.commit()

  -- Seat-stamp each restored event like any other seat, now the commit lands it in mm; bare write,
  -- no setEvent -- see docs/trackerManager.md § Incremental index reconciliation.
  for _, evt in ipairs(restoredNotes) do
    if index.stampColEvt(evt) then evt.committed = true end
  end
  -- A cc entry carries no seat stamp, so a restored cc only learns that mm holds it.
  for _, evt in ipairs(restoredCCs) do
    if index.byUuid(evt.uuid) then evt.committed = true end
  end
  return parkedByHost
end

----- Rebuild PA

local function findNoteColumnForPitch(channel, pitch, ppq_pos)
  local notes = channel.onTake.notes
  -- Pre-commit restores can't match -- their endppq is nil until the walk derives it.
  local coveringLane
  for _, rec in ipairs(index.raw(channel.chan).notes) do
    if isAuthored(rec) and rec.endppq and rec.pitch == pitch and rec.ppq <= ppq_pos
       and rec.endppq > ppq_pos and (coveringLane == nil or rec.lane < coveringLane) then
      coveringLane = rec.lane
    end
  end
  if coveringLane then return notes[coveringLane], coveringLane end

  for _, evt in ipairs(channel.parked.notes) do
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

local function rebuildPA()
  for chan = 1, 16 do
    if dirt.has(chan) then
      for _, evt in ipairs(index.raw(chan).pas) do
        if dirt.covers(chan, evt.ppqL or evt.ppq, 'note') then
          local noteCol, lane = findNoteColumnForPitch(frame.channels[chan], evt.pitch, evt.ppq)
          if noteCol then
            local colEvt = columnEvent(evt, { lane = lane })
            projectEvent(colEvt, chan)
            frame.spliceEvent(chan, lane, colEvt)
          end
        end
      end
      for _, spec in ipairs(frame.channels[chan].parked.pa or {}) do
        if dirt.covers(chan, spec.ppqL or spec.ppq, 'note') then
          local ppq = time:fromLogical(chan, spec.ppq)   -- raw: findNoteColumnForPitch is raw geometry
          local noteCol, lane = findNoteColumnForPitch(frame.channels[chan], spec.pitch, ppq)
          if noteCol then
            frame.spliceEvent(chan, lane, columnEvent(spec, { lane = lane }))   -- the event is logical-born
          end
        end
      end
    end
  end
end

----- Rebuild fx helpers

--shape: window -> { uuid, chan, ppq, endppq, fx, hostType = 'note'|'region', targets }
local function buildFxWindows(fxRegions, onTakeHosts)
  local windows = {}
  local function addWindow(window)
    window.targets = generators.chainTargets(window)
    util.add(windows, window)
  end

  for _, region in ipairs(fxRegions) do
    addWindow(util.assign(util.clone(region), { hostType = 'region' }))
  end

  local noteHosts = {}
  for host in pairs(onTakeHosts) do util.add(noteHosts, host) end
  for chan = 1, 16 do
    for _, evt in ipairs(frame.channels[chan].parked.notes) do
      if evt.fx then util.add(noteHosts, evt) end
    end
  end
  table.sort(noteHosts, function(a, b)
    if a.chan ~= b.chan then return a.chan < b.chan end
    if a.lane ~= b.lane then return a.lane < b.lane end
    if a.ppq ~= b.ppq then return a.ppq < b.ppq end
    return tostring(a.uuid) < tostring(b.uuid)
  end)
  -- A note host's window is the degenerate one (note-is-a-region): its onset to its lane bound.
  for _, host in ipairs(noteHosts) do
    addWindow(util.pick(host, 'uuid chan ppq fx', { endppq = host.endppqC, hostType = 'note' }))
  end
  return fxWindows.new(windows, time)
end

--pre: endppqC has been written by tailClip
--post: returns { [event] = true }
local function onTakeFxHosts()
  local hosts = {}

  local function walkChannel(chan)
    for _, col in ipairs(frame.channels[chan].onTake.notes) do
      for _, evt in ipairs(col.events) do
        if evt.fx and util.isNote(evt) then hosts[evt] = true end
      end
    end
  end

  local function perHost(chan)
    local parked = {}
    for _, evt in ipairs(frame.channels[chan].parked.notes) do parked[evt.uuid] = true end
    for uuid in pairs(index.fxHosts(chan)) do
      if not parked[uuid] then
        local evt = index.colEvtFor(uuid)
        if not evt then return walkChannel(chan) end
        hosts[evt] = true
      end
    end
  end

  for chan = 1, 16 do
    local known = index.fxHosts(chan)
    if known and next(known) then
      if dirt.wholesale(chan) then walkChannel(chan) else perHost(chan) end
    end
  end
  return hosts
end

----- Rebuild fx

-- Curve points relevant to a given set of spans: interior points, plus
-- the nearest points of the complement; see § Span-covered fx scans
local function coverOf(evts, spanSet, admit)
  admit = admit or function (_) return true end
  local cover = {}
  local resumeFrom = 1   -- entries below this were covered by an earlier span
  for _, span in ipairs(spanSet) do
    local spanStart, spanEnd = span[1], span[2]
    -- Governing entry: the last admitted one at-or-before the start, unless an earlier span took it.
    local governing = math.max(util.firstAfter(evts, spanStart) - 1, resumeFrom)
    while governing > resumeFrom and not admit(evts[governing]) do governing = governing - 1 end
    -- Cover through the closing entry: the first admitted one past the end.
    resumeFrom = #evts + 1
    for i = governing, #evts do
      local evt = evts[i]
      if admit(evt) then
        util.add(cover, evt)
        if evt.ppq > spanEnd then resumeFrom = i + 1; break end
      end
    end
  end
  return cover
end

local function basePoint(ppq, val, evt)
  return { ppq = ppq, val = val, shape = evt.shape or 'step', tension = evt.tension }
end

local function pbBaseFor(chan, spanSet)
  local base, seen = {}, {}
  for _, evt in ipairs(frame.channels[chan].parked.pb or {}) do
    util.add(base, basePoint(evt.ppq, evt.cents, evt))
    seen[evt.ppq] = true
  end
  -- The maintained pb index is raw-sorted; pbs carry no delay and swing is monotone, so the raw
  -- cover is the logical cover.
  local rawSpans = {}
  for _, span in ipairs(spanSet) do
    util.add(rawSpans, { time:fromLogical(chan, span[1]), time:fromLogical(chan, span[2]) })
  end
  local function authored(pb) return not pb.derived and pb.cents ~= nil end
  for _, pb in ipairs(coverOf(index.raw(chan).pbs, rawSpans, authored)) do
    local ppq = pb.ppqL or pb.ppq
    if not seen[ppq] then util.add(base, basePoint(ppq, pb.cents, pb)) end
  end
  util.sortByPPQ(base)
  return base
end

local function ccBasesFor(chan, spanSet)
  local bases, seen = {}, {}
  for _, evt in ipairs(frame.channels[chan].parked.ccs or {}) do
    util.bucket(bases, evt.cc, basePoint(evt.ppq, evt.val, evt))
    seen[util.key(evt.cc, evt.ppq)] = true
  end
  for cc, col in pairs(frame.channels[chan].onTake.ccs) do
    for _, evt in ipairs(coverOf(col.events, spanSet)) do
      if not seen[util.key(cc, evt.ppq)] then
        util.bucket(bases, cc, basePoint(evt.ppq, evt.val, evt))
      end
    end
  end
  for _, base in pairs(bases) do util.sortByPPQ(base) end
  return bases
end

-- cc-family streams a generator reads; pb/ccs are absolute curves sliced
-- from the per-chan bases with entering/closing edges. see docs/generators.md § Input streams
local function channelStreams(chan, spanStart, spanEnd, pbBase, ccBases)
  local cols = frame.channels[chan].onTake
  local pas, ats = {}, {}
  for _, col in ipairs(cols.notes) do
    for j = util.firstAtOrAfter(col.events, spanStart), #col.events do
      local evt = col.events[j]
      if evt.ppq >= spanEnd then break end
      if evt.evType == 'pa' then util.add(pas, { ppq = evt.ppq, pitch = evt.pitch, vel = evt.vel }) end
    end
  end
  local atEvents = cols.at and cols.at.events or {}
  for j = util.firstAtOrAfter(atEvents, spanStart), #atEvents do
    local evt = atEvents[j]
    if evt.ppq >= spanEnd then break end
    util.add(ats, { ppq = evt.ppq, val = evt.val })
  end
  -- Generators read these streams in ppq order (lanes interleave via the sort; ats ride their
  -- column's order; bases pre-sorted, slices preserve order).
  util.sortByPPQ(pas)
  local ccs = {}
  for cc, base in pairs(ccBases) do ccs[cc] = curves.slice(base, spanStart, spanEnd) end
  return pas, ccs, ats, curves.slice(pbBase, spanStart, spanEnd)
end
-- A parked event as a generator stream note: it sounds to its render clip, never to the authored
-- ceiling on endppq -- the field the view edits. On-take region members sound to endppqC alike.
local function soundingEvent(evt)
  return util.assign(util.clone(evt), { endppq = evt.endppqC })
end

-- A derived spec's logical-frame copy, as notesByHost carries it; runs per derived note.
local logicalCopyOf = util.picker("evType chan pitch vel detune intentCents baseVoice delay derived")

-- A note host as fx expansion runs it: derived notes ride the host's lane/delay/sample.
local function hostFromNote(note, windowEnd, lane)
  return { window = { note.ppq, windowEnd }, notes = { note }, fx = note.fx,
           targets = generators.continuousTargets(note.fx), id = note.uuid, lane = lane, delay = note.delay,
           sample = note.sample, delayPpq = delayToPPQ(note.delay) }
end

-- Every fx host of a channel, whether or not it will run: the gate classifies each against the full set.
--pre: noteHosts is chan's on-take fx hosts, (lane, ppq)-sorted
local function enumerateHosts(chan, noteHosts, regions, fxOutWindows)
  local hosts = {}

  -- Note hosts. Only augment ones (continuous kinds) remain on-take -- a discrete-replace host
  -- was parked at 4.5 and runs from its parked event below. Derived notes ride the host lane.
  for _, evt in ipairs(noteHosts) do
    util.add(hosts, hostFromNote(evt, evt.endppqC, evt.lane))
  end

  -- Parked note hosts: note-host replace parks (like a region), so every hit is derived output.
  -- Window is the parked event's realised extent, matching the bound the lane pass applied.
  for _, evt in ipairs(frame.channels[chan].parked.notes or {}) do
    -- A parked event inside a note-park window is region membership, not a note host (own-fx suppressed).
    if evt.fx and not fxOutWindows.owns('note', chan, nil, evt.ppq) then
      util.add(hosts, hostFromNote(soundingEvent(evt), evt.endppqC, evt.lane))
    end
  end

  -- Region hosts: no note behind them. A discrete-replace kind feeds the realised parked chord
  -- (parking frees the lanes); else members still sound and feed the live overlap. see docs/generators.md § Emission is ownership
  for _, region in ipairs(regions) do
    local spanStart, spanEnd = region.ppq, region.endppq
    local members = {}
    if generators.parksNotes(region) then
      for _, evt in ipairs(frame.channels[chan].parked.notes or {}) do
        if evt.ppq >= spanStart and evt.ppq < spanEnd then util.add(members, soundingEvent(evt)) end
      end
    else
      for lane in ipairs(frame.channels[chan].onTake.notes) do
        local population = frame.authoredEvents(chan, lane)
        for i = util.firstAtOrAfter(population, spanStart), #population do
          local evt = population[i]
          if evt.ppq >= spanEnd then break end
          if util.isNote(evt) then
            util.add(members, util.pick(evt, "ppq pitch vel detune intentCents", { endppq = evt.endppqC, lane = lane }))
          end
        end
      end
    end
    util.add(hosts, { window = { spanStart, spanEnd }, notes = members, fx = region.fx,
                      targets = generators.continuousTargets(region.fx),
                      id = region.uuid, lane = nil, delayPpq = 0 })
  end
  return hosts
end

-- Host gate: under interval dirt an unseeded host outside every emit scope it feeds does not run.
-- It names nothing the pass carries -- its notes stand in um's index. see design § Keep by omission
--pre: chan's dirt is interval, not wholesale
--shape: status = { [host] = 'seeded' | 'overlap' | 'kept' }; emitScope = { [target] = span set }
local function classifyHosts(chan, hosts)
  -- Hold-stream reach: authored pb/cc breakpoints and base-voice detune hold forward past
  -- window edges, invisible to window-local seeds.
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
  local function holdSensitive(host)
    if host.targets.pb and host.window[2] > pbHoldFrom then return true end
    for target in pairs(host.targets) do
      if target ~= 'pb' and host.window[2] > baseHoldFrom
         and generators.chainDestType(host.fx, target) == 'augment' then return true end
    end
    return false
  end
  local seeded = {}
  for _, host in ipairs(hosts) do seeded[host] = dirt.touches(chan, host.window[1], host.window[2]) end
  -- Fixpoint: a live base-voice emitter re-detunes the stream from its window start, which can
  -- wake pb windows further right, which may themselves emit base voices.
  local changed = true
  while changed do
    changed = false
    for _, host in ipairs(hosts) do
      if seeded[host] and generators.emitsBaseVoice(host) and host.window[1] < pbHoldFrom then
        pbHoldFrom = host.window[1]; changed = true
      end
      if not seeded[host] and holdSensitive(host) then
        seeded[host] = true; changed = true
      end
    end
  end

  -- Emit scope per target = merged windows of seeded hosts touching it; cc fold and reconcile clip
  -- to it. A kept host's window is never gathered, so its seats stay untouched.
  local emitWins, emitScope = {}, {}
  for _, host in ipairs(hosts) do
    if seeded[host] then
      for target in pairs(host.targets) do util.bucket(emitWins, target, host) end
    end
  end
  for target, group in pairs(emitWins) do emitScope[target] = spans.mergeWindows(group) end
  local function meetsEmitScope(host)
    for target in pairs(host.targets) do
      if spans.intersects(emitScope[target], host.window) then return true end
    end
    return false
  end

  -- 'seeded' runs and emits whole; a clean 'overlap' runs as a fold input inside an emit scope, its
  -- own remainder dropped; 'kept' does not run.
  local status = {}
  for _, host in ipairs(hosts) do
    if seeded[host] then status[host] = 'seeded'
    else status[host] = meetsEmitScope(host) and 'overlap' or 'kept' end
  end
  return status, emitScope
end

-- Fx expansion: fx-carrying notes / fx-regions -> derived notes, CCs; reconcile vs existing,
-- note existence ops staged uncommitted on fxOut.deferredWrite for the tail walk. see docs/generators.md § Offline continuous realisation
--pre: every column is ppq-ordered; channelStreams and the region-member scan seek it by ppq
--post: notesByHost[chan][id] is rewritten iff id is in fxOut.ran[chan]; every other list stands
local function rebuildFx(fxOutWindows, fxRegions, notesByHost, pbLimCents)
  local gridStep = ccGridStep()

  -- Asked again here, not carried from the census: the park stage has run since, so this is the
  -- on-take set as of now -- a host it parked gone, one it restored resolved to its live column
  -- event. Bucket by channel, (lane, ppq)-sorted. See § Fx window census.
  local fxHostsByChan = {}
  for host in pairs(onTakeFxHosts()) do util.bucket(fxHostsByChan, host.chan, host) end
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
    return frame.nextOnLane(frame.authoredEvents(host.chan, host.lane), note.ppq)
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

  -- One host interface, three sources: an on-take fx note, a parked fx event, or an explicit
  -- fxRegion; the generator sees none of them. see docs/generators.md § Hosts and membership
  --shape: emission = { notes = [derived spec], pb = chain record | nil, ccs = { [cc] = chain record } }
  local function runHost(chan, host, pbBase, ccBases)
    local spanStart, spanEnd = host.window[1], host.window[2]
    -- The same host as a generator sees it (generators' `host` argument): untouched membership plus
    -- the windowed channel streams; stream seeds as its copy and folds forward stage by stage. see docs/generators.md § The chain
    local pas, ccs, ats, pb = channelStreams(chan, spanStart, spanEnd, pbBase, ccBases)
    local original = { window = { spanStart, spanEnd }, chan = chan, lane = host.lane, id = host.id,
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
        cur = { { ppq = spanStart, val = generators.restFor(target), shape = 'step' } }
      end
      local inherited = cur
      if mode == 'replace' then cur = curves.foldIntoWindow(out.delta, spanStart, spanEnd)
      else                      cur = curves.sumStreams(cur, { out.delta }, { spanStart, spanEnd }, gridStep) end
      -- One rule for both modes: whatever the stage did inside its window, the target leaves it reading
      -- as the stage found it. A generator cannot bend the channel past its own end.
      cur = curves.closeAtWindowEnd(cur, curves.eval(inherited, spanEnd), spanStart, spanEnd)
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
    local emission = { notes = {}, ccs = {} }
    for target, contributed in pairs(owned) do
      if target == 'pb' then
        local curve = stream.pb
        if not contributed and not curves.anyNonZero(curve) then curve = {} end
        emission.pb = { window = { spanStart, spanEnd }, curve = curve,
                        mode = generators.chainDestType(host.fx, target) }
      else
        emission.ccs[target] = { window = { spanStart, spanEnd }, curve = stream.ccs[target] or {},
                                 mode = generators.chainDestType(host.fx, target) }
      end
    end
    -- Only a note-dest stage's chain emits (parksNotes mirrors this). A derived note is off-column
    -- whoever hosts it, so region and note host emit down the one path.
    if not ownsNotes then return emission end
    for _, hit in ipairs(stream.notes) do
      util.add(emission.notes, {
        evType = 'note', chan = chan, derived = host.id,
        pitch = hit.pitch, vel = hit.vel, detune = hit.detune or 0,
        intentCents = hit.intentCents, baseVoice = hit.baseVoice,
        delay = host.delay or 0, sample = host.sample,
        ppqL = hit.ppq, endppqL = hit.endppq,
        ppq    = time:fromLogical(chan, hit.ppq,    host.delayPpq),
        endppq = time:fromLogical(chan, hit.endppq, host.delayPpq),
      })
    end
    return emission
  end

  -- Host-owned outputs: live notes, existence ops (deletes/adds) awaiting the walk, per-chain pb curves, authored
  -- pb base, the per-chan pb emit scope (nil = ungated) steering rebuildPbs' live/kept split, and the host authority.
  --shape: fxOut.ran[chan] = { [hostUuid] = true }; the host files this pass took in hand --
  --   every host that ran, plus every orphan file it swept. A derived record whose host is not
  --   here survives: um's entry is the live copy and the pass says nothing about it.
  local fxOut = { notes = frame.newChannels(), deferredWrite = mmBatch(),
                  pbChains = frame.newChannels(), pbBase = frame.newChannels(),
                  pbScope = {}, ran = frame.newChannels() }

  -- Pass A: run every chain as a series -- each stage folds into the stream by mode x dest, and
  -- the final owned channels emit. see docs/generators.md § The chain
  local function expandChannel(chan)
    -- The existing side of a reconcile, one host at a time, off um's file (notes and ccs together, so
    -- the caller names the kind). Entries sort first for um's order; clones keep the reconcile off um's live records.
    local function producedBy(id, evType)
      local entries = {}
      for _, entry in pairs(index.derivedByHost(chan)[id] or {}) do
        if entry.evType == evType then util.add(entries, entry) end
      end
      table.sort(entries, index.order)
      local out = {}
      for _, entry in ipairs(entries) do util.add(out, columnEvent(entry)) end
      return out
    end

    local hosts = enumerateHosts(chan, fxHostsByChan[chan] or {}, fxRegionsByChan[chan] or {}, fxOutWindows)
    -- Wholesale dirt runs the gate open: every host is seeded, no emit scope narrows, pbScope stays nil.
    local gated = not dirt.wholesale(chan)
    local status, emitScope = {}, {}
    if gated then
      status, emitScope = classifyHosts(chan, hosts)
      fxOut.pbScope[chan] = emitScope.pb or {}
    else
      for _, host in ipairs(hosts) do status[host] = 'seeded' end
    end

    -- Bases cover only the hosts that run: a kept host reads no base (it emits nothing); every
    -- running host's window feeds channelStreams. see design § Keep by omission
    local running = {}
    for _, host in ipairs(hosts) do
      if status[host] ~= 'kept' then util.add(running, host) end
    end
    local runWins = spans.mergeWindows(running)
    local pbBase, ccBases = pbBaseFor(chan, runWins), ccBasesFor(chan, runWins)
    fxOut.pbBase[chan] = pbBase

    -- Per-chain continuous records: one absolute curve + fold mode per chain per owned cc target;
    -- cross-chain overlap layers at emission by storage order (pb folds in rebuildPbs). see docs/generators.md § Multiplicity
    local predicted, ccChains = {}, {}
    for _, host in ipairs(hosts) do
      if status[host] ~= 'kept' then
        local emission = runHost(chan, host, pbBase, ccBases)
        for _, spec in ipairs(emission.notes) do util.add(predicted, spec) end
        if emission.pb then util.add(fxOut.pbChains[chan], emission.pb) end
        for cc, record in pairs(emission.ccs) do util.bucket(ccChains, cc, record) end
      elseif host.targets.pb then
        -- A kept pb window still records its geometry: pb seats are markerless downstream, so a
        -- vanished window would read them as authored pbs.
        util.add(fxOut.pbChains[chan], { window = { host.window[1], host.window[2] }, kept = true })
      end
    end

    -- Convert emitScope to raw (the frame cc seats live in) via fromLogical at each bound; monotone
    -- projection means converted bounds still bracket the scope's seats. Only cc targets are used.
    local ccScope = {}
    for target, wins in pairs(emitScope) do
      local raw = {}
      for _, w in ipairs(wins) do
        util.add(raw, { time:fromLogical(chan, w[1], 0), time:fromLogical(chan, w[2], 0) })
      end
      ccScope[target] = raw
    end

    -- Existence reconcile stamps matched specs with the mm handle + realised end; notes and ccs
    -- gather off the same file so the cc side sees what the note side left. See docs/trackerManager.md § The host gate.
    local existing, existingCCs, ran = {}, {}, fxOut.ran[chan]
    -- `clipped` marks an overlap host, whose cc gather clips to the emit scope; a seeded host hands
    -- over its file whole. See docs/trackerManager.md § The host gate.
    local function gatherFrom(id, clipped)
      ran[id] = true
      for _, evt in ipairs(producedBy(id, 'note')) do util.add(existing, evt) end
      for _, evt in ipairs(producedBy(id, 'cc')) do
        if not clipped or spans.contains(ccScope[evt.cc], evt.ppq) then util.add(existingCCs, evt) end
      end
    end
    for _, host in ipairs(running) do gatherFrom(host.id, status[host] == 'overlap') end
    -- A file belonging to no host of this pass -- kept hosts included, so a kept neighbour's records
    -- are not swept -- belongs to a host deleted or parked away, and falls in whole.
    local hostsOfPass = {}
    for _, host in ipairs(hosts) do hostsOfPass[host.id] = true end
    for id in pairs(index.derivedByHost(chan)) do
      if not hostsOfPass[id] then gatherFrom(id) end
    end

    diffEvents(existing, predicted, fxOut.deferredWrite,
      -- Logical seat: docs/trackerManager.md § Fx expansion covers the key choice.
      function(evt)
        return util.key(
          evt.derived, evt.ppqL, evt.endppqL or 0,
          evt.pitch, evt.vel, evt.detune or 0, evt.sample or 0,
          evt.intentCents, evt.baseVoice)
      end,
      -- copy the matched note's mm handle + realised end onto the spec, so a
      -- re-emitted fxNote is re-clipped in place by the tail walk, not re-added.
      function(spec, evt)
        spec.uuid, spec.committed, spec.endppq = evt.uuid, evt.committed, evt.endppq
      end)

    -- Where the pass's emission order is stated, spec and copy alike: off the columns it is the only
    -- thing separating two hits a generator emitted alike, and every order below reads it from here.
    local fxNotes = {}
    for i, spec in ipairs(predicted) do
      index.stampEmission(spec, i)
      util.add(fxOut.notes[chan], spec)
      -- A copy, not the spec: the tail walk clamps raw onsets and clips ends in these in place below.
      local copy = logicalCopyOf(spec, { ppq = spec.ppqL, endppq = spec.endppqL })
      index.stampEmission(copy, i)
      util.add(fxNotes, copy)
    end
    -- One sort per rebuild against many windowed reads; pitch then emission order break onset
    -- collisions. table.sort is unstable, so the ordinal is what makes the order total.
    table.sort(fxNotes, function(a, b)
      if a.ppq ~= b.ppq then return a.ppq < b.ppq end
      if a.pitch ~= b.pitch then return a.pitch < b.pitch end
      return index.emissionOf(a) < index.emissionOf(b)
    end)
    -- Bucketed after the sort, so each host's list inherits the onset order.
    -- Clearing only the buckets of hosts in `ran` drops the stale list of a host that emitted nothing, or a swept orphan; a kept host's last output stands.
    local byHost = notesByHost[chan] or {}
    for id in pairs(ran) do byHost[id] = nil end
    for _, n in ipairs(fxNotes) do util.bucket(byHost, n.derived, n) end
    notesByHost[chan] = byHost

    -- cc emission: fold (curves.foldChains) into markerless seats, clipped to the emit scope; half-open --
    -- the closing value belongs to the kept side.
    local fxCCs = {}
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
              util.add(fxCCs, { evType = 'cc', chan = chan, cc = cc,
                                 ppq = time:fromLogical(chan, point.ppq, 0),
                                 val = util.clamp(util.round(point.val), 0, 127),
                                 shape = point.shape, tension = point.tension })
            end
          end
        end
      end
    end

    local ccWrites = mmBatch()
    -- fx cc events: reconcile the summed/replace seats on the target lane; shape is part of the key --
    -- it drives REAPER's interpolation. see docs/generators.md § pb and cc
    diffEvents(existingCCs, fxCCs, ccWrites,
      function(x) return util.key(x.cc, x.ppq, x.val, x.shape, x.tension) end)

    ccWrites.commit()
    -- Seat birth: the same question the wholesale walk asks of the persisted census, asked of this
    -- pass's windows -- the frame where the emitting host is still live. mm's add stamps the uuid on
    -- the spec, and only a fresh seat carries one; a kept seat holds the tag it already had.
    -- `derived` is no cc field, so this reaches um's entry and never the record. see § Route-by-window
    index.withDeferredSort(function()
      for _, seat in ipairs(fxCCs) do
        if seat.uuid then
          index.assign(index.byUuid(seat.uuid), 'derived',
                       fxOutWindows.ownsRaw('cc', chan, seat.cc, seat.ppq))
        end
      end
    end)
  end

  for chan = 1, 16 do
    -- Frozen: derived notes/CCs stand untouched in mm; leave fxOut.notes empty so tails/pbs/pcs skip too.
    if dirt.has(chan) then expandChannel(chan) end
  end
  return fxOut
end

----- Tail walk: rules and the linear pass

-- (ppqL, lane, pitch) names a seat uniquely -- a lane holds one note per logical row. Delay shifts
-- raw ppq but not ppqL, so the logical seat is the stable key.
local function seatKey(ppqL, lane, pitch)
  return tostring(ppqL) .. '\0' .. tostring(lane) .. '\0' .. tostring(pitch)
end

-- One-pass merge of the pre-sorted index list (filtered) with a small sorted extras list;
-- replaces the whole-channel sort the per-pass scratch copy used to force.
--shape: pop = { list = the channel's index notes, extras = the pass's derived specs,
--   keep = the index predicate }; the tail walk's two probe sources and the filter over the first
local function mergeIndexed(pop)
  table.sort(pop.extras, index.order)
  local merged, j = {}, 1
  for _, entry in ipairs(pop.list) do
    if pop.keep(entry) then
      while pop.extras[j] and index.order(pop.extras[j], entry) do
        util.add(merged, pop.extras[j]); j = j + 1
      end
      util.add(merged, entry)
    end
  end
  for i = j, #pop.extras do util.add(merged, pop.extras[i]) end
  return merged
end

-- The per-note settle and bound rules as a factory over ctx: both the linear and frontier walks inject
-- their batches and marking tables and drive the same rules over their own state.
--shape: ctx = { chan, res, windows, disturbed, nudged, clampWrites, tailWrites }
local function makeTailRules(ctx)
  local chan, res, windows = ctx.chan, ctx.res, ctx.windows
  local disturbed, nudged = ctx.disturbed, ctx.nudged
  local clampWrites, tailWrites = ctx.clampWrites, ctx.tailWrites

  -- The lane successor in column order: a neighbour delayed off its row still follows here. The
  -- population is the column's own: no derived note bounds by a lane, so none joins one.
  local function laneNext(e)
    local col = frame.channels[chan].onTake.notes[e.lane]
    return col and frame.nextOnLane(col.events, e.ppqL)
  end

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
    if backing.committed then clampWrites.assign(backing, { ppq = e.ppq }) end
    return true
  end

  -- An authored note's lane bound is the lane pass's, read off its column event; a derived
  -- note lies outside the columns, bounded by its host's window (docs § The lane pass, § Tail walk).
  --pre: (not e.derived) → e.colEvt carries its lane bound -- the lane pass ran over this channel
  --pre: e.derived → the pass's window set holds that host's window
  local function boundNote(e, pitchNext)
    local laneBound
    if e.derived then
      laneBound = math.min(e.endppqL, windows.window(e.derived).endppq)
    else
      laneBound = e.colEvt.endppqC
    end
    local pitchClip = pitchNext and pitchNext.ppq or math.huge
    -- Two bounds: the lane bound is intent, every term of it logical, and it drives the column; the
    -- wire bound converts it once and alone reaches mm. see docs/trackerManager.md § Tail walk
    local rawBound  = math.max(e.ppq + 1, math.min(time:fromLogical(chan, laneBound), pitchClip))
    local rounded   = util.round(rawBound)
    if rounded ~= e.endppq then
      local backing = e.colEvt or e
      if backing.committed then tailWrites.assign(backing, { endppq = rounded }) end
      index.assign(e, 'endppq', rounded)
    end
    if e.colEvt then
      -- Mirror projectEvent's endppq rule: the authored ceiling shows in the column, and the lane
      -- bound it is clipped to rides endppqC, where the lane pass wrote it.
      frame.setEvent(e.colEvt, 'endppq', e.endppqL or laneBound)
    end
  end

  return settleOnset, boundNote, laneNext
end

-- The seed-driven tail walk over the whole channel: the degenerate fallback for dense and wholesale
-- dirt, chosen over the frontier by seed count. see docs/trackerManager.md § Tail walk
local function linearTails(chan, notes, extras, res, windows, clampWrites, tailWrites, reBound)
  local disturbed, nudged = {}, {}
  local settleOnset, boundNote, laneNext = makeTailRules{
    chan = chan, res = res, windows = windows,
    disturbed = disturbed, nudged = nudged,
    clampWrites = clampWrites, tailWrites = tailWrites,
  }

  -- Disturbed seeded by name: derived membership + the seeds themselves, survivors resolved by uuid,
  -- adds by logical seat. Anchors for the bound probes: seed positions (dead included) plus disturbed onsets.
  local anchors = {}
  -- extras are the merged list's own entries, so identity names them. A standing derived record is not
  -- among them: its host kept, so it was settled and clipped last pass and rides as a bound anchor only.
  for _, e in ipairs(extras) do disturbed[e] = true end
  if dirt.wholesale(chan) then
    for _, e in ipairs(notes) do disturbed[e] = true end   -- degenerate pass: load, external change
  else
    local noteByUuid, bySeat = {}, {}
    for _, e in ipairs(notes) do
      if e.uuid then noteByUuid[e.uuid] = e end
      util.bucket(bySeat, seatKey(e.ppqL or e.ppq, e.lane, e.pitch), e)
    end
    for _, seed in ipairs(dirt.has(chan)) do
      util.add(anchors, { pos = seed.ppq, pitch = seed.pitch })
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

  -- Bound set: every disturbed note, the lane pass's re-bounded events, and each anchor's nearest
  -- same-pitch predecessor. see docs/trackerManager.md § Tail walk
  local bound = {}
  for e in pairs(disturbed) do bound[e] = true end
  for _, rec in ipairs(reBound) do bound[rec] = true end
  -- Wholesale already bounds every note, so the predecessor probes add nothing. Only the seeded case
  -- needs them, to reach the non-disturbed neighbours dirt shadows.
  if not dirt.wholesale(chan) then
    for e in pairs(disturbed) do util.add(anchors, { pos = e.ppq, pitch = e.pitch }) end
    -- One ascending sweep, tracking the running last-in-pitch, answers every anchor at once -- the
    -- forward twin of the successor pass below. See docs/trackerManager.md § Tail walk.
    table.sort(anchors, function(a, b) return a.pos < b.pos end)
    local lastInPitch, i = {}, 1
    for _, a in ipairs(anchors) do
      while i <= #notes and notes[i].ppq < a.pos do
        lastInPitch[notes[i].pitch] = notes[i]
        i = i + 1
      end
      local pitchPred = lastInPitch[a.pitch]
      if pitchPred then bound[pitchPred] = true end
    end
  end

  -- Bounds + nudge emission: one backward pass hands over next-in-pitch (running state keyed by
  -- pitch), the stale test replaced by `bound` membership. see design § Phase 4
  local emitted = {}
  local nearestInPitch, nextAfterPitch = {}, {}
  for i = #notes, 1, -1 do
    local e = notes[i]
    local pitchAbove = nearestInPitch[e.pitch]
    -- A neighbour sharing e's raw is no successor of it: it hands over its own.
    local pitchNext = pitchAbove and (pitchAbove.ppq > e.ppq and pitchAbove or nextAfterPitch[e.pitch])
    nearestInPitch[e.pitch], nextAfterPitch[e.pitch] = e, pitchNext

    -- The walk's own dirt: a nudged lane-1 onset seeds every absorber seat up to the next lane-1
    -- onset, for pbs to consume later this pass. see design § The widen and the emission are the same fact
    if nudged[e] and isAuthored(e) and e.lane == 1 then
      local nextOnLane = laneNext(e)
      util.add(emitted, { uuid = e.uuid, verb = 'nudge', evType = 'note', ppq = e.ppq, ppqL = e.ppqL,
                          lane = e.lane, pitch = e.pitch, endppqL = nextOnLane and nextOnLane.ppq })
    end
    if bound[e] then boundNote(e, pitchNext) end
  end

  return emitted
end

----- Frontier probe walk

-- Above this many disturbed seeds (dirt + derived fx events) the frontier's per-seed probes cost more
-- than the linear walk's single channel pass, so the tail rebuild routes to linear. see design § The degenerate case gates on seed count
local FRONTIER_SEED_CAP = 16

-- Every probe below binary-searches the raw-then-logical-sorted index -- util.firstAtOrAfter for the
-- near edge of pos's raw cluster, util.firstAfter for the far one -- then scans outward a bounded few
-- rows. The seek that replaces the sweep.

-- Nearest record of the population strictly on one `side` of `pos` (raw ppq) matching `filter`, over the
-- index (binary-searched, scanned outward) and the small extras. The strict-ppq bound probe; mirrors util.seek.
local function nearestNote(pop, pos, side, filter)
  local best
  local anchor = util.firstAtOrAfter(pop.list, pos)
  if side == 'before' then
    for i = anchor - 1, 1, -1 do
      local rec = pop.list[i]
      if pop.keep(rec) and filter(rec) then best = rec; break end
    end
  else
    for i = anchor, #pop.list do
      local rec = pop.list[i]
      if rec.ppq > pos and pop.keep(rec) and filter(rec) then best = rec; break end
    end
  end
  for _, rec in ipairs(pop.extras) do
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
local function prevSamePitch(pop, node)
  local best
  for i = util.firstAfter(pop.list, node.ppq) - 1, 1, -1 do
    local rec = pop.list[i]
    if pop.keep(rec) and rec ~= node and rec.pitch == node.pitch and index.order(rec, node) then
      best = rec; break
    end
  end
  for _, rec in ipairs(pop.extras) do
    if rec ~= node and rec.pitch == node.pitch and index.order(rec, node)
       and (best == nil or index.order(best, rec)) then best = rec end
  end
  return best
end

-- Same-pitch record immediately after `node` in the total order, keyed on `origPpq` (node's raw before
-- this pass nudged it) -- settlement's cascade successor. see design § Nudge probes stop at the tick
local function nextSamePitch(pop, node, origPpq)
  local key = { ppq = origPpq, ppqL = node.ppqL, derived = node.derived, lane = node.lane, pitch = node.pitch }
  -- The probe stands in for node in every term of the order, emission included: without it two hits
  -- emitted alike tie, and the second is no successor of the first for the cascade to separate.
  index.stampEmission(key, index.emissionOf(node))
  local best
  for i = util.firstAtOrAfter(pop.list, origPpq), #pop.list do
    local rec = pop.list[i]
    if pop.keep(rec) and rec ~= node and rec.pitch == node.pitch and index.order(key, rec) then
      best = rec; break
    end
  end
  for _, rec in ipairs(pop.extras) do
    if rec ~= node and rec.pitch == node.pitch and index.order(key, rec)
       and (best == nil or index.order(rec, best)) then best = rec end
  end
  return best
end

-- On-take records at a seed's logical seat, for adds/deletes carrying no surviving uuid. Scans only the
-- seed's raw-ppq cluster in the sorted index (plus extras) -- bounded, not a channel sweep.
local function seatMatches(pop, seed)
  local out, key = {}, seed.ppqL or seed.ppq
  local function match(rec)
    return (rec.ppqL or rec.ppq) == key and rec.lane == seed.lane and rec.pitch == seed.pitch
  end
  for i = util.firstAtOrAfter(pop.list, seed.ppq), #pop.list do
    if pop.list[i].ppq ~= seed.ppq then break end
    -- Authored only, unlike the population the bound probes range over: a seat is lane-keyed and a
    -- derived record carries no lane, so none can answer one.
    if isAuthored(pop.list[i]) and match(pop.list[i]) then util.add(out, pop.list[i]) end
  end
  for _, rec in ipairs(pop.extras) do if rec.ppq == seed.ppq and match(rec) then util.add(out, rec) end end
  return out
end

-- The frontier probe walk: seek to each seed, probe a bounded few rows for its neighbours, drive the
-- shared settle/bound rules -- no whole-channel traversal.
local function frontierTails(chan, pop, res, windows, clampWrites, tailWrites, reBound)
  local disturbed, nudged = {}, {}
  local settleOnset, boundNote, laneNext = makeTailRules{
    chan = chan, res = res, windows = windows,
    disturbed = disturbed, nudged = nudged,
    clampWrites = clampWrites, tailWrites = tailWrites,
  }

  -- Disturbed seeded by name: derived membership is all of extras; adds/deletes name a seat the
  -- index tick cluster answers; byUuid resolve is note-scoped -- see docs § What the walk visits, and what it emits.
  local anchors = {}
  for _, rec in ipairs(pop.extras) do disturbed[rec] = true end
  for _, seed in ipairs(dirt.has(chan)) do
    util.add(anchors, { pos = seed.ppq, pitch = seed.pitch })
    local rec = seed.uuid and index.byUuid(seed.uuid)
    if rec and rec.evType == 'note' and rec.chan == chan then disturbed[rec] = true
    else for _, hit in ipairs(seatMatches(pop, seed)) do disturbed[hit] = true end end
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
      local prev = prevSamePitch(pop, head)
      local chain = {}
      if prev then util.add(chain, prev) end
      util.add(chain, head)
      -- reach = the running worst-case settled tick; a same-pitch successor cascades only while it can
      -- still collide (separateOnset gives way by one tick), or when it is itself a pending seed.
      local reach = (prev and head.ppq <= prev.ppq) and prev.ppq + 1 or head.ppq
      local node = head
      while true do
        local nxt = nextSamePitch(pop, node, node.ppq)
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
  -- pop.list is um's own and the block's close re-trued it; extras belongs to this walk.
  if anyNudge then table.sort(pop.extras, index.order) end

  -- Phase 2 -- bounds, order-free: disturbed notes, the lane pass's re-bounded events, and each
  -- anchor's nearest same-pitch predecessor; reads settled onsets, writes only endppq.
  local bound = {}
  for _, rec in ipairs(reBound) do bound[rec] = true end
  for e in pairs(disturbed) do
    bound[e] = true
    util.add(anchors, { pos = e.ppq, pitch = e.pitch })
  end
  for _, a in ipairs(anchors) do
    local pitchPred = nearestNote(pop, a.pos, 'before', function(r) return r.pitch == a.pitch end)
    if pitchPred then bound[pitchPred] = true end
  end

  -- A nudged lane-1 seat emits its closure to the next lane-1 onset, which the lane's own
  -- population answers. see design § The widen and the emission are the same fact
  local emitted = {}
  for e in pairs(bound) do
    local pitchNext = nearestNote(pop, e.ppq, 'after', function(r) return r.pitch == e.pitch end)
    if nudged[e] and isAuthored(e) and e.lane == 1 then
      local nextOnLane = laneNext(e)
      util.add(emitted, { uuid = e.uuid, verb = 'nudge', evType = 'note', ppq = e.ppq, ppqL = e.ppqL,
                          lane = e.lane, pitch = e.pitch, endppqL = nextOnLane and nextOnLane.ppq })
    end
    boundNote(e, pitchNext)
  end
  return emitted
end

----- Rebuild tails

-- Unified tail/onset walk + atomic commit: real notes, fixed externals, fxNotes
-- walk together (onset clamp then tail clip); host clip + fxNote del/add in one mm:modify. see docs/trackerManager.md § Tail walk
--post: a note is separated only if it is disturbed; a nudged lane-1 onset emits its seat closure
--post: the disturbed, the lane pass's named and each anchor's predecessors take fresh bounds
local function rebuildTails(fxOut, windows)
  local res = mm:resolution()
  local clampWrites = mmBatch()
  -- fx expansion's own batch, still uncommitted and carrying its existence ops -- a fresh
  -- spec is unrealised during the walk, so the clip mutates it in place, reaching mm already clipped.
  local tailWrites = fxOut.deferredWrite
  for chan = 1, 16 do
    if not dirt.has(chan) then goto nextChan end
    -- The channel's population: um's index less what this pass ran, plus the pass's own specs. Every
    -- spec is fresh -- a kept host emits none -- so all of them seed disturbance and count toward the cap.
    local extras = {}
    for _, spec in ipairs(fxOut.notes[chan]) do util.add(extras, spec) end
    local pop = { list = index.raw(chan).notes, extras = extras, keep = survivingEvents(fxOut.ran[chan]) }
    -- The lane pass named the authored events whose bound it moved, over both its runs; the walk
    -- states no lane bound of theirs, so it re-bounds them by name. see docs § The lane pass
    local reBound = {}
    for _, uuid in ipairs(dirt.tails.has(chan) or {}) do
      local rec = index.byUuid(uuid)
      if rec then util.add(reBound, rec) end
    end

    -- Sparse edits seek to their seeds; dense edits and wholesale rebuilds walk the channel once. The
    -- frontier takes the population's two sources as separate probe sources -- no O(channel) merge.
    local emitted
    if not dirt.wholesale(chan) and #dirt.has(chan) + #extras <= FRONTIER_SEED_CAP then
      emitted = frontierTails(chan, pop, res, windows, clampWrites, tailWrites, reBound)
    else
      local notes = mergeIndexed(pop)
      if #notes == 0 then goto nextChan end
      emitted = linearTails(chan, notes, extras, res, windows, clampWrites, tailWrites, reBound)
    end

    -- The walk's own dirt joins what it was given: past the cap the channel collapses to wholesale,
    -- so the stages below it read the same lattice every other writer does.
    dirt.add(chan, emitted)
    ::nextChan::
  end
  clampWrites.commit()
  tailWrites.commit()
end

----- Rebuild Pbs

-- A ramp onset's dual point rides one tick before the onset (see docs/tuning.md § Value-aware
-- seats), so every span that must contain an onset's seats reaches one tick back.
local DUAL_POINT_TICK = 1

--shape: baseVoiceUnion = { detuneAt(ppq), between(lo, hi), first(), nextAfter(ppq), anyDetuneJump() }
-- A channel's base-voice onset stream: the raw index's surviving notes unioned with the pass's
-- derived base voices, which live off-take in fxOut.notes. see docs/tuning.md § Absorber reconciliation
--pre: derived is ppq-ascending and holds chan's derived base voices for this pass
--pre: keep is survivingEvents for chan, so `derived` supersedes exactly what it drops
local function baseVoiceUnion(chan, derived, keep)
  local indexed = index.raw(chan).notes   -- every lane, authored and derived alike; filtered at use
  -- keep drops the index entries of the hosts this pass ran: seated copies of a prior pass's
  -- output, superseded by `derived`. A kept host's stand -- they are the only copy of its voices there is.
  local function indexedBaseVoice(entry) return keep(entry) and index.isBaseVoice(entry) end

  -- The union from the first entry at-or-after `lo` ('after' starts past it instead), merging the two
  -- sources by index.order -- one cursor pair, and the only place the union's order is decided.
  --post: result = (fresh iterator) yielding unsafe index entries in index.order
  local function walk(lo, mode)
    local from = mode == 'after' and util.firstAfter or util.firstAtOrAfter
    local i, j = from(indexed, lo), from(derived, lo)
    return function()
      while indexed[i] and not indexedBaseVoice(indexed[i]) do i = i + 1 end
      local a, d = indexed[i], derived[j]
      if d and (not a or index.order(d, a)) then j = j + 1; return d end
      if a then i = i + 1 end
      return a
    end
  end

  -- The detune prevailing at ppq: the last union entry at-or-before it, 0 before the first.
  local function detuneAt(ppq)
    local i = util.firstAfter(indexed, ppq) - 1        -- last index at or before ppq
    while i >= 1 and not indexedBaseVoice(indexed[i]) do i = i - 1 end
    local a, d = indexed[i], derived[util.firstAfter(derived, ppq) - 1]
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

  -- The channel's first base-voice onset, the I2a anchor's point.
  local function first() return walk(0)() end

  -- The next base-voice onset strictly after ppq; math.huge past the last.
  local function nextAfter(ppq)
    local entry = walk(ppq, 'after')()
    return entry and entry.ppq or math.huge
  end

  -- Whether any base voice carries a non-zero detune. With prev seeded 0 an onset exists iff some
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
local function replaceWindows(chan, fxOut, gridStep, pbLimCents)
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
local function seatScope(chan, replaceWins, baseVoice)
  if dirt.wholesale(chan) then return nil end
  local seatSpans = {}
  local function baseVoiceSpan(ppq) util.add(seatSpans, { ppq - DUAL_POINT_TICK, baseVoice.nextAfter(ppq) }) end
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
    -- Lane 1, not the base voice: a seed names an authored event, and authored means lane 1. The
    -- span it closes to reaches the next base voice, whichever note that is.
    if seed.lane == 1 or (live and live.lane == 1) then
      if seed.lane == 1 then baseVoiceSpan(seed.ppq) end
      if live and live.lane == 1 and live.ppq ~= seed.ppq then baseVoiceSpan(live.ppq) end
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
  -- The I2a anchor at the first base-voice onset (authored or derived) is channel-global: any pass may
  -- need to seat, refresh, or retire it, so its point is always in scope.
  local first = baseVoice.first()
  if first then util.add(seatSpans, { first.ppq - DUAL_POINT_TICK, first.ppq }) end
  return seatSpans
end

-- Reseat absorber pbs against the post-walk base-voice layout, recompute their raw vals,
-- and project the pb column. see docs/tuning.md § Absorber reconciliation
local function rebuildPbs(fxOut, extraColumns, pbLimCents)
  local gridStep = ccGridStep()
  local fxNotes = fxOut.notes
  -- Reads only the per-chan .pb keep-flag; rebuildExtraColumns's mid-pipeline write grows
  -- .notes only, so the head snapshot is current for this.
  local extras = extraColumns or {}

  -- Per-chan base-voice union, built for dirty channels alone; clean ones reuse their carried pb
  -- column. see docs/tuning.md § Absorber reconciliation
  local freshBaseVoice, baseVoiceByChan = {}, {}
  for chan = 1, 16 do
    if dirt.has(chan) then
      -- Derived base voices are routed out of columns; union them so the absorber pass seats
      -- their detune jumps.
      local derivedBaseVoice = {}
      for _, spec in ipairs(fxNotes[chan]) do
        if spec.baseVoice then
          util.add(derivedBaseVoice, spec)
          freshBaseVoice[chan] = true
        end
      end
      table.sort(derivedBaseVoice, index.order)   -- the union's cursors assume ppq order of both sources
      baseVoiceByChan[chan] = baseVoiceUnion(chan, derivedBaseVoice, survivingEvents(fxOut.ran[chan]))
    end
  end

  -- Replace windows + seat spans per dirty chan, computed ahead of the gather. A derived base voice in
  -- the pass's own output ungates the channel (seatSpans nil).
  local winsByChan, seatSpansByChan = {}, {}
  for chan = 1, 16 do
    if dirt.has(chan) then
      local replaceWins = replaceWindows(chan, fxOut, gridStep, pbLimCents)
      winsByChan[chan] = replaceWins
      if not freshBaseVoice[chan] then
        seatSpansByChan[chan] = seatScope(chan, replaceWins, baseVoiceByChan[chan])
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

  local pbWrites = mmBatch()

  -- Seat the base voice's detune stream, match absorbers, and stage the consolidated assign feeding
  -- the projection below. Clean chans skip it wholesale -- I8: rebuild is a fixpoint.
  local function deriveChan(chan, pbs, replaceWins, seatSpans, baseVoice)
    local replaceWinAt, inSeatWindow, inKeptRange =
      replaceWins.replaceWinAt, replaceWins.inSeatWindow, replaceWins.inKeptRange

    -- Detune onsets: every base-voice ppq whose detune differs from its predecessor, seeded by the
    -- carried-in detune and walked per coalesced seat span. see docs/tuning.md § Seat-span-scoped onset walk
    local onsets, onsetAt = {}, {}
    for _, span in ipairs(seatSpans and spans.merge(seatSpans) or { { 0, math.huge } }) do
      local prev = baseVoice.detuneAt(span[1] - 1)
      for _, note in ipairs(baseVoice.between(span[1], span[2])) do
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
        pb.cents = tuning.rawToCents(pb.raw, pbLimCents) - baseVoice.detuneAt(pb.ppq)
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
                      or (tuning.rawToCents(entry.raw, pbLimCents) - baseVoice.detuneAt(entry.ppq))
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

    -- Anchor a pb-active channel at its first base-voice onset (I2a):
    -- without it, playback inherits the synth's unknown prior bend.
    local first = baseVoice.first()
    if first and not seats[first.ppq] and not inKeptRange(first.ppq) and inSeatScope(first.ppq) then
      -- realPbs is ppq-ascending, so its head settles both questions. The jump test is whole-channel:
      -- the span-bounded onset walk above could hide the only jump the channel has.
      local firstReal = realPbs[1]
      local anchored  = firstReal ~= nil and firstReal.ppq <= first.ppq
      local pbActive  = next(seats) ~= nil or firstReal ~= nil
                        or (seatSpans ~= nil and baseVoice.anyDetuneJump())
      if pbActive and not anchored then
        seats[first.ppq] = { cents = streamValue(first.ppq), ppqL = first.ppqL, shape = 'step' }
      end
    end

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
        local raw = tuning.centsToRaw(fresh.cents + baseVoice.detuneAt(ppq), pbLimCents)
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
      pbWrites.delete({ uuid = absorber.uuid })
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

    local detuneOf = {}
    for _, pb in ipairs(pbs) do detuneOf[pb] = baseVoice.detuneAt(pb.ppq) end
    -- Consolidated assign: one entry per existing pb where any of (ppq moved, ppqL
    -- restamped, raw changed, cents back-derived, derived shape changed) needs to land.
    for _, pb in ipairs(pbs) do
      if pb.committed then
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
      local detuneOf, pbEntryByRaw, fenced = deriveChan(chan, pbs, winsByChan[chan], seatSpans, baseVoiceByChan[chan])

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
        projectEvent(pb, chan)
        util.add(pbColEvents, pb)
      end
      -- Carry the whole out-of-scope remainder verbatim -- re-deriving from the wire would quantise through
      -- centsToRaw. Each refreshes uuid/committed since a carried event predates its committed uuid.
      for _, evt in ipairs(priorPbCol and priorPbCol.events or {}) do
        local carry = evt.ppqRaw and (not inSpans(seatSpans, evt.ppqRaw) or fenced[evt.ppqRaw])
        local entry = carry and pbEntryByRaw[evt.ppqRaw]
        if entry then
          evt.uuid, evt.committed = entry.uuid, entry.committed
          anyVisible = anyVisible or not evt.hidden
          util.add(pbColEvents, evt)
        end
      end
      util.sortByPPQ(pbColEvents)
      local keep = anyVisible or (extras[chan] and extras[chan].pb)
      frame.channels[chan].onTake.pb = keep and frame.newStreamColumn(pbColEvents) or nil
    end
  end

  pbWrites.commit()
end

----- Rebuild PCs

--contract: synthesised PCs carry derived='pc'; ppqL inherited from winning host-note record
--contract: an existing derived PC matching (ppq, val) is kept, preserving mm-side loc
--contract: appends removals/adds to the writes batch {delete(event), add(spec)}
--contract: marks sampleShadowed=true on the event or the spec of records lost to the onset's rank
--contract: seedSpans (from pcSeedSpans) narrow existing to its logical spans; nil = whole channel
--invariant: seated marks via setEvent; off-take direct; no lane renews an event it lacks
--invariant: c.pc.events not written here; rebuildPCs splices it from mm after commit
local function reconcilePCsForChan(chan, records, writes, seedSpans)
  local existing = {}
  for _, e in ipairs((frame.channels[chan].onTake.pc and frame.channels[chan].onTake.pc.events) or {}) do
    if not seedSpans or spans.contains(seedSpans.logical, e.ppq) then util.add(existing, e) end
  end

  local groups = {}
  for _, r in ipairs(records) do util.bucket(groups, r.ppq, r) end

  local winners = {}
  for _, g in pairs(groups) do
    -- Authored records rank by lane, derived output after them all: a derived note holds no lane,
    -- being off-column. table.sort is unstable, so `ord` is what makes the rank total.
    table.sort(g, function(a, b)
      local aLane, bLane = a.lane or math.huge, b.lane or math.huge
      if aLane ~= bLane then return aLane < bLane end
      return a.ord < b.ord
    end)
    util.add(winners, g[1])
    for i = 2, #g do
      local lost = g[i]
      -- A seated record marks through its column event. An off-take fx spec holds no event, and
      -- setEvent would renew the lane its number names without that lane's contents having moved.
      if lost.evt then frame.setEvent(lost.evt, 'sampleShadowed', true)
      elseif lost.spec then lost.spec.sampleShadowed = true end
    end
  end

  local predicted = {}
  for _, w in ipairs(winners) do
    util.add(predicted, { ppq = w.ppq, ppqL = w.ppqL, val = w.sample,
                          evType = 'pc', chan = chan, derived = 'pc' })
  end

  diffEvents(existing, predicted, writes,
    function(x) return util.key(x.derived, x.ppq, x.val) end)
end

--shape: seedSpans = { raw = span set, logical = span set }; nil = wholesale
local function pcSeedSpans(chan, fxNotes)
  if dirt.wholesale(chan) then return nil end
  -- Any derived output at all means a host of this channel re-ran, and its PCs are the pass's to
  -- decide wholesale; a kept host contributes no entry here.
  if #fxNotes > 0 then return nil end
  local points = {}
  for _, s in ipairs(dirt.has(chan)) do
    util.add(points, { ppq = s.ppq, ppqL = s.ppqL or s.ppq })
    local live = s.uuid and index.byUuid(s.uuid)
    if live then util.add(points, { ppq = live.ppq, ppqL = live.ppqL or live.ppq }) end
  end
  local raw, logical, notes = {}, {}, index.raw(chan).notes
  for _, point in ipairs(points) do
    local i = util.firstAfter(notes, point.ppq)
    while notes[i] and not isAuthored(notes[i]) do i = i + 1 end
    local nextNote = notes[i]
    util.add(raw, { point.ppq, nextNote and nextNote.ppq or math.huge })
    util.add(logical, { point.ppqL, nextNote and nextNote.ppqL or math.huge })
  end
  return { raw = spans.merge(raw), logical = spans.merge(logical) }
end

-- PC synthesis (trackerMode only), after the sample stamp. Seed-list dirt closes to spans; records,
-- writes and the column splice all clip to them, so out-of-span PCs stand.
local function rebuildPCs(fxOut)
  if not cm:get('trackerMode') then return end
  local fxNotes = fxOut.notes
  local pcWrites = mmBatch()
  local spansByChan = {}
  for chan = 1, 16 do
    -- Clean channels freeze: their PCs stand in mm and their pc column is carried forward.
    if not dirt.has(chan) then goto nextChan end
    local seedSpans = pcSeedSpans(chan, fxNotes[chan])
    spansByChan[chan] = seedSpans
    local records = {}
    -- The gather ordinal, and authored notes are gathered first: it is the rank's tie-break under
    -- the lane, so a laneless derived record falls after every authored one.
    local function addRecord(rec)
      rec.ord = #records + 1
      util.add(records, rec)
    end
    -- A host this pass kept owns PCs at onsets no authored note sits on; those records are um's own.
    -- Off-column, they carry no colEvt, so the shadow mark rides the record like a spec's; no note host means no inherited sample.
    local keep = survivingEvents(fxOut.ran[chan])
    local function recordNote(entry)
      if not keep(entry) then return end
      if entry.derived then
        addRecord{ ppq = entry.ppq, ppqL = entry.ppqL, sample = entry.sample or 0, spec = entry }
      else
        addRecord{ ppq = entry.ppq, ppqL = entry.ppqL, lane = entry.lane,
                   sample = entry.sample, evt = entry.colEvt }
      end
    end
    if seedSpans then
      for entry in onsetsIn(index.raw(chan).notes, seedSpans.raw) do recordNote(entry) end
    else
      for _, entry in ipairs(index.raw(chan).notes) do recordNote(entry) end
    end
    for _, n in ipairs(fxNotes[chan]) do
      if not seedSpans or spans.contains(seedSpans.raw, n.ppq) then
        -- region-derived notes ride no note host: no sample to inherit, regenerated each pass
        addRecord{ ppq = n.ppq, ppqL = n.ppqL, sample = n.sample or 0, spec = n }
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
          if not spans.contains(seedSpans.logical, e.ppq) then util.add(events, e) end
        end
      end
      local function projectPc(cc)
        local evt = columnEvent(cc)
        projectEvent(evt, chan)
        util.add(events, evt)
      end
      if seedSpans then
        for cc in onsetsIn(index.raw(chan).pcs, seedSpans.raw) do projectPc(cc) end
      else
        for _, cc in ipairs(index.raw(chan).pcs) do projectPc(cc) end
      end
      util.sortByPPQ(events)
      frame.channels[chan].onTake.pc = frame.newStreamColumn(events)
    end
  end
end

----- Fx output maps

-- The continuous half of a freeze rect: the pb/cc streams a host's chains target, off the window set
-- alone. The note half is tv's, composed at freeze time off the display allocation the ghosts draw in.
local function buildFreezeRects(hosts)
  local rects = {}
  for _, host in ipairs(hosts) do
    -- A husk host (no fx, no output) claims an empty stream set rather than none: it is still
    -- a host, and whether an empty footprint is worth minting is the caller's question.
    local streams = {}
    -- A note target is a park window, not a stream, so it adds nothing here.
    for target in pairs(host.targets) do
      if     target == 'pb'           then streams['pb:0'] = true
      elseif type(target) == 'number' then streams['cc:' .. target] = true end
    end
    -- Single-channel by construction, so chanOffset 0 is the only key; span is the host's own.
    rects[host.uuid] = { ppq = host.ppq, dur = host.endppq - host.ppq,
                         chanLo = host.chan, streams = { [0] = streams } }
  end
  return rects
end

-- The continuous half of the same window set: which pb/cc targets each host's chains own,
-- logical framed. see docs/trackerManager.md § Realisation by host
--shape: byHost[uuid] = { pb = { {spanStart, spanEnd}, ... }, [ccNum] = { ... } } -- merged, ascending
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

-- inUse is channelsInUse's set: a channel outside it runs no host, so a chain reaches nothing the
-- document never used. Second return is the stored globals, whose own uuids the union answers for.
-- The pass calls it off its head snapshot; explode calls it off the set that snapshot published.
-- see docs/trackerManager.md § Channel & column model
--shape: expandGlobals -> channelRegions = the stored chan 1..16 regions, then each global cloned onto every in-use channel with uuid = util.key(its uuid, chan); globals = the stored chan-0 records
function rebuild.expandGlobals(regions, inUse)
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

--pre: called inside tm:rebuild's mm nest, with the index already reloaded if this pass is wholesale
--pre: context is the projection the rebuild head built for this pass
--post: fxNotesByHost[chan][uuid] := this pass's notes where uuid is in `ran`, else what it last left
--post: fresh result = the maps tm:rebuild installs, the channels whose mute wants conforming, and
--post:   the in-use set the globals expanded onto
--invariant: every mm-staging stage nests, so reindex/reprojection defer to one unwind
--invariant: the ds keys the pass reads are snapshotted here, once, ahead of any write of its own
function rebuild.pipeline(context)
  time = context
  local pbRangeCents = cm:get('pbRange') * 100

  -- One head snapshot of the ds intent keys the pass reads, its regions already expanded to
  -- per-channel hosts against the channels in use. see docs/trackerManager.md § Channel & column model
  local sources = {
    fxParked          = ds:get('fxParked'),
    fxRealisedWindows = ds:get('fxRealisedWindows'),
    extraColumns      = ds:get('extraColumns'),
    paramAutomation   = ds:get('paramAutomation'),
  }
  local inUse = channelsInUse(sources)
  sources.fxRegions, sources.globalRegions = rebuild.expandGlobals(ds:get('fxRegions'), inUse)

  local fxInWindows = fxWindows.new(sources.fxRealisedWindows or {}, time)

  local external = rebuildInternals()
  rebuildCCs(fxInWindows)
  dirt.swing.clear()
  dirt.foreign.clear()

  rebuildExtraColumns(sources.extraColumns, sources.paramAutomation)
  rebuildExternals(external)
  if cm:get('trackerMode') then rebuildSamples() end
  installParkedNotes(sources.fxParked)

  dirt.tails.clear()
  for chan = 1, 16 do if dirt.has(chan) then clipTails(chan) end end

  local onTakeHosts  = onTakeFxHosts()
  local fxOutWindows = buildFxWindows(sources.fxRegions, onTakeHosts)
  local parkedByHost = rebuildRegionPark(fxOutWindows, sources.fxParked, fxInWindows, onTakeHosts, pbRangeCents)
  rebuildPA()

  local fxOut = rebuildFx(fxOutWindows, sources.fxRegions, fxNotesByHost, pbRangeCents)

  rebuildTails(fxOut, fxOutWindows)
  rebuildPbs(fxOut, sources.extraColumns, pbRangeCents)
  rebuildPCs(fxOut)

  local census = fxOutWindows.census()
  persistKey('fxRealisedWindows', census, sources.fxRealisedWindows)

  local byHost = { notes = fxNotesByHost, parked = parkedByHost, targets = buildFxTargets(fxOutWindows.windows()) }

  local maps = {
    windows       = fxOutWindows,
    freezeRect    = buildFreezeRects(fxOutWindows.windows()),
    fxRealisation = buildFxRealisation(fxOutWindows.windows(), sources.globalRegions, byHost),
    dirtyChannels = dirt.byChannel(),
    inUse         = inUse
  }

  dirt.clear()
  stager.clear()
  time = nil

  return maps
end

return rebuild
