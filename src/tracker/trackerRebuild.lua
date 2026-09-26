-- The derivation engine: one gated pass reconstructs intent from mm, then emits the take from it.
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
      if not dirt.wholesale(chan) then
        exciseEvents(frame.channels[chan].onTake.notes, dirt.ppqs(chan, 'note'),
                     function(e) return not e.parked end)
      end
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

-- A pb's column event is its intent: val is the cents sidecar and the wire value stays in mm. It
-- carries a seat stamp, through which rebuildPbs stamps its detune cue.
local function ccColumnEvent(entry, update)
  local event = columnEvent(entry, update)
  if entry.evType == 'pb' then
    event.val, event.raw = event.cents, nil
    index.stampColEvt(event)
  end
  projectEvent(event, entry.chan)
  return event
end

local function spliceCcEvent(entry)
  frame.spliceInto(ensureCcColumn(entry.chan, entry.evType, entry.cc), ccColumnEvent(entry))
end

local function appendCcEvent(entry, update)
  util.add(ensureCcColumn(entry.chan, entry.evType, entry.cc).events, ccColumnEvent(entry, update))
end

-- Interval-dirt path: the rows in each seeded cc cell, and each seeded pb row, are cleared and
-- refilled from the raw index. See docs/trackerManager.md § Interval materialisation
local function spliceChannelCCs(chan)
  local cells   = dirt.ppqs(chan, 'cc')
  local refills = {}
  local cols = frame.channels[chan].onTake

  -- pbs carry no delay, so a row's raw seat is its logical one reswung; a markerless seat has no
  -- ppqL, so the match leaves it out.
  local pbRows, pbs = dirt.ppqs(chan, 'pb'), index.raw(chan).pbs
  for _, ppqL in ipairs(pbRows) do
    local ppq = time:fromLogical(chan, ppqL)
    for i = util.firstAtOrAfter(pbs, ppq), #pbs do
      local entry = pbs[i]
      if entry.ppq > ppq then break end
      if not entry.derived and entry.ppqL == ppqL then util.add(refills, entry) end
    end
  end
  if cols.pb then exciseEvents({ cols.pb }, pbRows) end

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
    if col then exciseEvents({ col }, cell.ppqs, function(e) return not e.parked end) end
  end
  for _, evt in ipairs(refills) do spliceCcEvent(evt) end
end

-- A markerless seat a previous window left on the wire: realisation, recognised by the window alone.
local function isPbSeat(entry, fxInWindows)
  return entry.evType == 'pb' and entry.ppqL == nil and fxInWindows.ownsRaw('pb', entry.chan, nil, entry.ppq)
end

-- Reconciles ppq and ppqL per the swing rules; see docs/trackerManager.md § CC walk.
local function reconcileCcPpq(entry, fxInWindows, ccWrites)
  local chan = entry.chan
  if entry.derived or isPbSeat(entry, fxInWindows) then return nil end
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
-- pas reconcile only; see docs/trackerManager.md § CC walk
local function fullRebuildChannelCCs(chan, fxInWindows, ccWrites, pbLimCents)
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
      if not entry.derived then
        local update = reconcileCcPpq(entry, fxInWindows, ccWrites)
        appendCcEvent(entry, update)
      end
    end
  end
  for _, entry in ipairs(raw.pbs) do
    if not entry.derived and not isPbSeat(entry, fxInWindows) then
      local update = reconcileCcPpq(entry, fxInWindows, ccWrites)
      -- A foreign pb has no cents sidecar: its intent is what it sounds less the previous emission's
      -- detune. see docs/trackerManager.md § CC walk
      if entry.cents == nil then
        local cents = tuning.rawToCents(entry.raw, pbLimCents) - index.detuneAt(chan, entry.ppq)
        ccWrites.assign({ uuid = entry.uuid }, { cents = cents })
        update = util.assign(update or {}, { cents = cents })
      end
      appendCcEvent(entry, update)
    end
  end
  for _, entry in ipairs(raw.pas) do reconcileCcPpq(entry, fxInWindows, ccWrites) end
  for _, col in pairs(frame.channels[chan].onTake.ccs) do util.sortByPPQ(col.events) end
  for _, key in ipairs{ 'at', 'pc', 'pb' } do
    if frame.channels[chan].onTake[key] then util.sortByPPQ(frame.channels[chan].onTake[key].events) end
  end
end

local function rebuildCCs(fxInWindows, pbLimCents)
  local ccWrites = mmBatch()
  for chan = 1, 16 do
    if dirt.has(chan) then
      if dirt.wholesale(chan) then fullRebuildChannelCCs(chan, fxInWindows, ccWrites, pbLimCents)
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
  local takeLenL = time:toLogical(chan, time:length())
  for _, col in ipairs(frame.channels[chan].onTake.notes) do
    local population = col.events
    for _, evt in ipairs(population) do
      if not evt.derived and util.isNote(evt) then
        local bound = frame.clippedSpanEnd(evt, takeLenL, population)
        if evt.endppqC ~= bound then
          if not evt.parked then dirt.tails.add(chan, evt.uuid) end
          frame.setEvent(evt, 'endppqC', bound)
        end
      end
    end
  end
end

----- Rebuild region park

-- The parked clone of a column event; the realisation frame
-- is removed, and re-added on unpark
--pre: evt is logical-frame; an mm-raw source must override ppq via `adds`
local toParked, parkInPlace do
  local REALISATION = { delayC = true, endppqC = true, committed = true, derived = true,
                      frame = true, cents = true, colEvt = true, sampleShadowed = true,
                      raw = true }
  function toParked(evt, adds)
    return util.assign(util.clone(evt, REALISATION), adds)
  end

  -- Park flips the column event where it stands, shedding the realisation frame there too.
  --post: evt is its toParked spec plus parked = true, so the next head seat holds it
  function parkInPlace(evt)
    for field in pairs(REALISATION) do frame.setEvent(evt, field, nil) end
    frame.setEvent(evt, 'parked', true)
  end
end

-- The mm-bound clone of a parked spec: raw onset, logical sidecar.
--pre: spec is logical-frame
local function fromParked(spec, adds)
  local ppq = time:fromLogical(spec.chan, spec.ppq)
  return util.assign(util.assign(util.clone(spec), { ppq = ppq, ppqL = spec.ppq }), adds)
end

-- A seated parked event against the spec it renders: endppqC is derived after seating, and the
-- parked flag is the seat's own.
local function sameSpec(seated, spec)
  local ignored = { endppqC = true, parked = true }
  for k, v in pairs(spec) do
    if not ignored[k] and not util.deepEq(seated[k], v) then return false end
  end
  for k in pairs(seated) do if not ignored[k] and spec[k] == nil then return false end end
  return true
end

local function installParked(field, specs)
  local function sameParked(old, new)
    if not old or #old ~= #new then return false end
    for i, newSpec in ipairs(new) do
      if not sameSpec(old[i], newSpec) then return false end
    end
    return true
  end

  local fresh = frame.newChannels()
  for _, spec in ipairs(specs) do util.bucket(fresh, spec.chan, util.clone(spec)) end

  for chan = 1, 16 do
    local parked = frame.channels[chan].parked
    if not sameParked(parked[field], fresh[chan]) then parked[field] = fresh[chan] end
  end
end

-- Where a parked spec of each seated kind sits: the field its columns live under, and its own column.
local parkHomes = {
  note = { field = 'notes', column = function(spec) return ensureLane(spec.chan, spec.lane) end },
  cc   = { field = 'ccs',   column = function(spec) return ensureCcColumn(spec.chan, 'cc', spec.cc) end },
  pa   = { field = 'notes', column = function(spec) return ensureLane(spec.chan, spec.lane) end },
}

-- Seat a kind's parked specs in their own columns, flagged; a seated event whose spec held keeps its
-- table, so the column's carry holds. see docs/trackerManager.md § Lane occupancy
--pre: kinds sharing a field (notes, pas) are distinguished by evType, leaving the other's seats
local function seatParked(kind, specs)
  local home = parkHomes[kind]
  local wanted = frame.newChannels()
  for _, spec in ipairs(specs) do
    wanted[spec.chan][frame.parkKey(spec)] = spec
    home.column(spec)
  end
  local held = {}
  for chan = 1, 16 do
    for _, col in pairs(frame.channels[chan].onTake[home.field]) do
      local stale = {}
      for _, evt in ipairs(col.events) do
        if evt.parked and evt.evType == kind then
          local spec = wanted[chan][frame.parkKey(evt)]
          if spec and not held[spec] and sameSpec(evt, spec) then held[spec] = evt
          else stale[evt] = true end
        end
      end
      if next(stale) then
        local kept = {}
        for _, evt in ipairs(col.events) do if not stale[evt] then util.add(kept, evt) end end
        col.events = kept   -- kept is a fresh table: this assignment is the renewal
        frame.markRenewed(col)
      end
    end
  end
  for _, spec in ipairs(specs) do
    if not held[spec] then frame.spliceInto(home.column(spec), util.assign(util.clone(spec), { parked = true })) end
  end
end

-- The event seated from a parked spec, which a restore flips in place.
--pre: the spec is seated, from the stash at the pass head or parked in place this pass
local function seatedOf(spec)
  local key = frame.parkKey(spec)
  for _, evt in ipairs(parkHomes[spec.evType].column(spec).events) do
    if evt.parked and frame.parkKey(evt) == key then return evt end
  end
end

-- The pass head seats the stash as it stands, which a wholesale channel's fresh columns lack.
local function seatStash(fxParked)
  local byKind = { note = {}, cc = {}, pa = {} }
  for _, spec in ipairs(fxParked or {}) do
    if byKind[spec.evType] then util.add(byKind[spec.evType], spec) end
  end
  for kind, specs in pairs(byKind) do seatParked(kind, specs) end
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

  --shape: candidates = { evt (the live column/index event), seated = evt is a column event, spec = toParked(evt, {...}) }
  local function reconcilePark(candidates, prior, onPark)
    onPark = onPark or function (_) end
    local newParked, restores = {}, {}
    for _, candidate in ipairs(candidates) do
      if hostFor(candidate.spec) then
        onPark(candidate.spec)
        util.add(newParked, candidate.spec)
        writes.delete(candidate.evt)
        if candidate.seated then parkInPlace(candidate.evt) end
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
      util.add(candidates, { evt = evt, seated = true, spec = toParked(evt) })
    end
  end
  for chan = 1, 16 do
    local windowSpans = stage.windowSpans[util.key(chan, 'note')]
    if windowSpans and dirt.has(chan) then
      for _, col in ipairs(frame.channels[chan].onTake.notes) do
        for evt in onsetsIn(col.events, windowSpans) do
          if util.isNote(evt) and not evt.parked then addCandidate(evt) end
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
    -- Restore flips the seated event in place: it is logical, and keeps the parked uuid too.
    local note = seatedOf(spec)
    frame.setEvent(note, 'parked', nil)

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

  local parkedByHost = {}
  for _, spec in ipairs(parkedNotes) do util.bucket(parkedByHost, stage.hostFor(spec), seatedOf(spec)) end

  local touched = {}
  for _, spec in ipairs(parkedNotes) do touched[spec.chan] = true end
  for _, spec in ipairs(restores)    do touched[spec.chan] = true end
  for chan in pairs(touched) do clipTails(chan) end

  return parkedNotes, restoredNotes, parkedByHost
end

-- A pa parks with its host: park and restore flip it in place in the host's lane, as a cc's do.
-- No dirt seed: the lane's pa population is the same either way. see docs/trackerManager.md § Region-replace parking
--pre: parkNotes has parked this pass's hosts in place and clipped their lanes
local function parkPAs(stage)
  local hostsByCol = {}
  local function parkedHostsIn(col)
    if not hostsByCol[col] then
      local hosts = {}
      for _, evt in ipairs(col.events) do
        if evt.parked and util.isNote(evt) then util.add(hosts, evt) end
      end
      hostsByCol[col] = hosts
    end
    return hostsByCol[col]
  end
  local function underParkedHost(pa, col)
    for _, host in ipairs(parkedHostsIn(col)) do
      if host.pitch == pa.pitch and host.ppq <= pa.ppq and pa.ppq < host.endppqC then return true end
    end
    return false
  end

  local candidates = {}
  for chan = 1, 16 do
    if dirt.has(chan) then
      for _, col in ipairs(frame.channels[chan].onTake.notes) do
        if #parkedHostsIn(col) > 0 then
          for _, evt in ipairs(col.events) do
            if evt.evType == 'pa' and not evt.parked and underParkedHost(evt, col) then util.add(candidates, evt) end
          end
        end
      end
    end
  end
  local parkedPAs, restores = {}, {}
  for _, spec in ipairs(stage.prior.pa) do
    util.add(underParkedHost(spec, parkHomes.pa.column(spec)) and parkedPAs or restores, spec)
  end

  for _, evt in ipairs(candidates) do
    util.add(parkedPAs, toParked(evt))
    stage.writes.delete(evt)
    parkInPlace(evt)
  end
  local restoredPAs = {}
  for _, spec in ipairs(restores) do
    local evt = seatedOf(spec)
    frame.setEvent(evt, 'parked', nil)
    -- lane is display-only, overlaid at dispatch; mm would persist it
    stage.writes.add(fromParked(spec, { keepUuid = true, lane = util.REMOVE }))
    util.add(restoredPAs, evt)
  end

  return parkedPAs, restoredPAs
end

local function parkCCs(stage)
  local candidates = {}
  for chan = 1, 16 do
    if dirt.has(chan) then
      for cc, col in pairs(frame.channels[chan].onTake.ccs) do
        for evt in onsetsIn(col.events, stage.windowSpans[util.key(chan, cc)]) do
          if not evt.parked then util.add(candidates, { evt = evt, seated = true, spec = toParked(evt) }) end
        end
      end
    end
  end
  local parkedCCs, restores = stage.reconcilePark(candidates, stage.prior.cc)

  local restoredCCs = {}
  for _, spec in ipairs(restores) do
    local evt = seatedOf(spec)   -- flipped in place: the event is the spec, both logical
    frame.setEvent(evt, 'parked', nil)
    stage.writes.add(fromParked(spec, { keepUuid = true }))
    util.add(restoredCCs, evt)
  end

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
        local spec = toParked(pb, { val = pb.cents })
        projectEvent(spec, pb.chan)
        util.add(candidates, { evt = { uuid = pb.uuid }, spec = spec }) -- evt is only the delete target
      end
    end
  end

  -- Until the stash seats pbs in their column, a pb parks off it and restores back into it.
  local newlyParked, parkedRows = {}, frame.newChannels()
  local parkedPbs, restores = stage.reconcilePark(candidates, stage.prior.pb, function(spec)
    newlyParked[spec.uuid] = true
    util.add(parkedRows[spec.chan], spec.ppq)
  end)
  for chan, rows in ipairs(parkedRows) do
    local col = frame.channels[chan].onTake.pb
    if col and #rows > 0 then exciseEvents({ col }, rows, function(e) return newlyParked[e.uuid] end) end
  end

  -- Restores get raw + cents sidecar. The val is detune-free; rebuildPbs corrects it later.
  local restoredPbs = {}
  for _, spec in ipairs(restores) do
    local evt = fromParked(spec, { cents = spec.val, val = tuning.centsToRaw(spec.val, pbLimCents) })
    dirt.add(spec.chan, dirt.parkSeed(spec, 'restore', evt.ppq))
    stage.writes.add(evt)
    local colEvt = util.assign(util.clone(spec), { cents = spec.val })
    frame.spliceInto(ensureCcColumn(spec.chan, 'pb'), colEvt)
    util.add(restoredPbs, colEvt)
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
  util.sortByPPQ(rendered)   -- pbBaseFor covers the parked list, and a cover bisects
  installParked('pb', rendered)
  return parkedPbs, restoredPbs
end

local function rebuildRegionPark(fxOutWindows, fxParked, fxInWindows, onTakeHosts, pbLimCents)
  local stage                                    = parkStage(fxOutWindows, fxParked)
  local parkedNotes, restoredNotes, parkedByHost = parkNotes(stage, onTakeHosts)
  -- Order matters: parkPAs reconciles against the parked notes parkNotes installs.
  local parkedPAs, restoredPAs                   = parkPAs(stage)
  local parkedCCs, restoredCCs                   = parkCCs(stage)
  local parkedPbs, restoredPbs                   = parkPbs(stage, fxOutWindows, fxInWindows, pbLimCents)

  local allParked = {}
  for _, parked in ipairs({ parkedNotes, parkedPAs, parkedCCs, parkedPbs }) do
    for _, spec in ipairs(parked) do util.add(allParked, spec) end
  end
  persistKey('fxParked', allParked, fxParked)
  stage.writes.commit()

  -- Seat-stamp each restored event like any other seat, now the commit lands it in mm; bare write,
  -- no setEvent -- see docs/trackerManager.md § Incremental index reconciliation.
  for _, restored in ipairs({ restoredNotes, restoredPbs }) do
    for _, evt in ipairs(restored) do
      if index.stampColEvt(evt) then evt.committed = true end
    end
  end
  -- A cc or pa entry carries no seat stamp, so a restored one only learns that mm holds it.
  for _, restored in ipairs({ restoredCCs, restoredPAs }) do
    for _, evt in ipairs(restored) do
      if index.byUuid(evt.uuid) then evt.committed = true end
    end
  end
  return parkedByHost
end

----- Rebuild PA

-- takeLenL is hoisted by the caller: a parked host's lane bound is derived here, as its endppqC
-- is stamped only by the lane-bound pass after dispatch.
local function findNoteColumnForPitch(channel, pa, takeLenL)
  local notes = channel.onTake.notes
  -- Pre-commit restores can't match -- their endppq is nil until the walk derives it.
  local coveringLane
  for _, rec in ipairs(index.raw(channel.chan).notes) do
    if isAuthored(rec) and rec.endppq and rec.pitch == pa.pitch and rec.ppq <= pa.ppq
       and rec.endppq > pa.ppq and (coveringLane == nil or rec.lane < coveringLane) then
      coveringLane = rec.lane
    end
  end
  if coveringLane then return notes[coveringLane], coveringLane end

  local ppqL = pa.ppqL or pa.ppq
  for _, evt in ipairs(frame.parkedNotes(channel.chan)) do
    if evt.pitch == pa.pitch and evt.ppq <= ppqL
       and frame.clippedSpanEnd(evt, takeLenL, notes[evt.lane].events) > ppqL then
      return notes[evt.lane], evt.lane
    end
  end

  -- Pitch-only fallback: frame-agnostic, so the columns serve it (projected PAs included).
  for lane, col in ipairs(notes) do
    for _, evt in ipairs(col.events) do
      if evt.pitch == pa.pitch and not evt.parked then return col, lane end
    end
  end
end

-- Dispatches on-take pas only; a parked one is seated from the stash.
local function rebuildPA()
  for chan = 1, 16 do
    if dirt.has(chan) then
      local takeLenL = time:toLogical(chan, time:length())
      for _, evt in ipairs(index.raw(chan).pas) do
        if dirt.covers(chan, evt.ppqL or evt.ppq, 'note') then
          local noteCol, lane = findNoteColumnForPitch(frame.channels[chan], evt, takeLenL)
          if noteCol then
            local colEvt = columnEvent(evt, { lane = lane })
            projectEvent(colEvt, chan)
            frame.spliceEvent(chan, lane, colEvt)
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
    for _, evt in ipairs(frame.parkedNotes(chan)) do
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
        if evt.fx and util.isNote(evt) and not evt.parked then hosts[evt] = true end
      end
    end
  end

  local function perHost(chan)
    local parked = {}
    for _, evt in ipairs(frame.parkedNotes(chan)) do parked[evt.uuid] = true end
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

-- Curve events relevant to a given set of spans: interior points, plus
-- the nearest points of the complement; see § Span-covered fx scans
local function pointsFor(evts, spanSet, admit)
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

local function boundsFor(evts, span, admit)
  admit = admit or function (_) return true end
  local spanStart, spanEnd = span[1], span[2]
  local lo = util.firstAfter(evts, spanStart) - 1
  while lo >= 1 and not admit(evts[lo]) do lo = lo - 1 end
  local hi = util.firstAfter(evts, spanEnd)
  while hi <= #evts and not admit(evts[hi]) do hi = hi + 1 end
  local function ppqFor(i)
    if i < 1     then return -math.huge end
    if i > #evts then return math.huge end
    return evts[i].ppqL or evts[i].ppq
  end
  return ppqFor(lo), ppqFor(hi)
end

local function toRawSpan(chan, span)
  return { time:fromLogical(chan, span[1]), time:fromLogical(chan, span[2]) }
end

local function basePoint(ppq, val, evt)
  return { ppq = ppq, val = val, shape = evt and evt.shape or 'step', tension = evt and evt.tension }
end

local function isAuthoredPb(pb) return not pb.derived and pb.cents ~= nil end

-- The covers of all authored pbs; see § Span-covered fx scans pre:
-- parked.pb is in ppq order, as parkPbs installs it
local function pbBaseFor(chan, spanSet)
  local base, seen = {}, {}
  for _, evt in ipairs(pointsFor(frame.channels[chan].parked.pb, spanSet)) do
    util.add(base, basePoint(evt.ppq, evt.cents, evt))
    seen[evt.ppq] = true
  end
  -- The maintained pb index is raw-sorted; pbs carry no delay and swing is monotone, so the raw
  -- cover is the logical cover.
  local rawSpans = {}
  for _, span in ipairs(spanSet) do
    util.add(rawSpans, toRawSpan(chan, span))
  end
  for _, pb in ipairs(pointsFor(index.raw(chan).pbs, rawSpans, isAuthoredPb)) do
    local ppq = pb.ppqL or pb.ppq
    if not seen[ppq] then util.add(base, basePoint(ppq, pb.cents, pb)) end
  end
  util.sortByPPQ(base)
  return base
end

-- The cover of each cc column's authored events; see § Span-covered fx scans
--pre: the park stage has run: parked ccs are seated in their columns
--post: each base is in ppq order
local function ccBasesFor(chan, spanSet)
  local bases = {}
  for cc, col in pairs(frame.channels[chan].onTake.ccs) do
    for _, evt in ipairs(pointsFor(col.events, spanSet)) do
      util.bucket(bases, cc, basePoint(evt.ppq, evt.val, evt))
    end
  end
  return bases
end

-- cc-family streams a generator reads; see docs/generators.md § Input streams
local function continuousStreams(chan, spanStart, spanEnd, pbBase, ccBases)
  local cols = frame.channels[chan].onTake
  local pas = {}
  for _, col in ipairs(cols.notes) do
    for j = util.firstAtOrAfter(col.events, spanStart), #col.events do
      local evt = col.events[j]
      if evt.ppq >= spanEnd then break end
      if evt.evType == 'pa' then util.add(pas, { ppq = evt.ppq, pitch = evt.pitch, vel = evt.vel }) end
    end
  end
  -- ats ride their column's order and bases are pre-sorted, but pas need sorting
  util.sortByPPQ(pas)

  local ats = {}
  local atEvents = cols.at and cols.at.events or {}
  for j = util.firstAtOrAfter(atEvents, spanStart), #atEvents do
    local evt = atEvents[j]
    if evt.ppq >= spanEnd then break end
    util.add(ats, { ppq = evt.ppq, val = evt.val })
  end

  local ccs = {}
  for cc, base in pairs(ccBases) do ccs[cc] = curves.slice(base, spanStart, spanEnd) end
  return pas, ccs, ats, curves.slice(pbBase, spanStart, spanEnd)
end

-- A parked event as a generator stream note: it sounds to its render clip.
local function soundingEvent(evt)
  return util.assign(util.clone(evt), { endppq = evt.endppqC })
end

-- Every fx host of a channel, since the gate classifies each against the full set.
--pre: noteHosts is chan's on-take fx hosts, (lane, ppq)-sorted
local function enumerateHosts(chan, noteHosts, regions)
  local hosts = {}
  local function addNoteHost(note)
    util.add(hosts, {
      window = { note.ppq, note.endppqC }, notes = { note }, fx = note.fx,
      targets = generators.continuousTargets(note.fx), id = note.uuid, lane = note.lane,
      delay = note.delay, sample = note.sample, delayPpq = delayToPPQ(note.delay)
    })
  end

  for _, note in ipairs(noteHosts) do addNoteHost(note) end

  for _, spec in ipairs(frame.parkedNotes(chan)) do
    if spec.fx then addNoteHost(soundingEvent(spec)) end
  end

  for _, region in ipairs(regions) do
    local notes = {}
    for _, col in ipairs(frame.channels[chan].onTake.notes) do
      local population = col.events
      for i = util.firstAtOrAfter(population, region.ppq), #population do
        local evt = population[i]
        if evt.ppq >= region.endppq then break end
        if util.isNote(evt) then
          util.add(notes, util.pick(soundingEvent(evt), "ppq endppq pitch vel detune intentCents lane"))
        end
      end
    end
    util.add(hosts, {
      window = { region.ppq, region.endppq }, notes = notes, fx = region.fx,
      targets = generators.continuousTargets(region.fx),
      id = region.uuid, delayPpq = 0
    })
  end
  return hosts
end

-- 'seeded' runs and emits whole; 'overlap' runs only as fold input to an emit scope; 'kept'
-- does not run, and um's index holds its output. see docs/trackerManager.md § The host gate
--pre: chan's dirt is interval, not wholesale
--post: status[host] = 'kept' → no dirt can change host's output, directly or via a hold stream
--post: status[host] = 'kept' → for all of host.targets, host.window doesn't meet emitScope[target]
--shape: status = { [host] = 'seeded' | 'overlap' | 'kept' }; emitScope = { [target] = span set }
local function classifyHosts(chan, hosts)
  local seedsOn, detuneHoldFrom = {}, math.huge

  -- Every mode reads its target's base curve; this checks for dirt that
  -- will alter this curve, including changes to the points before and after.
  local function baseIsDirty(host)
    for target in pairs(host.targets) do
      if seedsOn[target] then
        local lo, hi
        if target == 'pb' then
          local lo1, hi1 = boundsFor(frame.channels[chan].parked.pb, host.window)
          local lo2, hi2 = boundsFor(index.raw(chan).pbs, toRawSpan(chan, host.window), isAuthoredPb)
          lo, hi = math.max(lo1, lo2), math.min(hi1, hi2)
        else
          lo, hi = boundsFor(frame.channels[chan].onTake.ccs[target].events, host.window)
        end
        for _, ppq in ipairs(seedsOn[target]) do
          if ppq >= lo and ppq <= hi then return true end
        end
      end
    end
    return false
  end

  for _, seed in ipairs(dirt.has(chan)) do
    -- A breakpoint seeds its stream at its snapshot and at its live seat, so a move names both the
    -- cover it left and the one it joined.
    local liveEvt = seed.uuid and index.byUuid(seed.uuid)
    local livePpq = liveEvt and (liveEvt.ppqL or liveEvt.ppq)
    local stream = (seed.evType == 'pb' and 'pb') or (seed.evType == 'cc' and seed.cc)
    if stream then
      util.bucket(seedsOn, stream, seed.ppqL)
      if livePpq then util.bucket(seedsOn, stream, livePpq) end
    end
    -- Base-voice detune holds forward, so a lane-1 or region seed (whose host may gain or lose base
    -- voices) reaches every pb window after it. see docs/tuning.md § Seat-span-scoped onset walk
    if seed.lane == 1 or seed.evType == nil then
      detuneHoldFrom = math.min(detuneHoldFrom, seed.ppqL, livePpq or seed.ppqL)
    end
  end

  local seeded = {}
  for _, host in ipairs(hosts) do
    seeded[host] = dirt.touches(chan, host.window[1], host.window[2]) or baseIsDirty(host)
  end

  -- Fixpoint: a seeded base-voice emitter re-detunes pb from its window start on, waking pb windows
  -- that end past it; one of those may emit base voices itself and start earlier still.
  while true do
    local changed = false
    for _, host in ipairs(hosts) do
      if seeded[host] and generators.emitsBaseVoice(host) and host.window[1] < detuneHoldFrom then
        detuneHoldFrom = host.window[1]; changed = true
      elseif not seeded[host] and host.targets.pb and host.window[2] > detuneHoldFrom then
        seeded[host] = true; changed = true
      end
    end
    if not changed then break end
  end

  -- Emit scope per target = merged windows of seeded hosts touching
  -- it; cc fold and reconcile clip to this.
  local emitWindows = {}
  for _, host in ipairs(hosts) do
    if seeded[host] then
      for target in pairs(host.targets) do util.bucket(emitWindows, target, host) end
    end
  end

  local emitScope = {}
  for target, group in pairs(emitWindows) do emitScope[target] = spans.mergeWindows(group) end

  local function meetsEmitScope(host)
    for target in pairs(host.targets) do
      if spans.intersects(emitScope[target], host.window) then return true end
    end
    return false
  end

  local status = {}
  for _, host in ipairs(hosts) do
    status[host] = seeded[host] and 'seeded'  or
           meetsEmitScope(host) and 'overlap' or
                                    'kept'
  end
  return status, emitScope
end

-- Emit spans are half-open because the closing value belongs to the kept side, which emits it.
--pre: emitScope is nil iff chan is ungated
--post: result = raw-ppq cc seat specs, not yet reconciled against mm
local function emitCCs(chan, ccChains, ccBases, emitScope, gridStep)
  local fxCCs = {}
  for cc, chain in pairs(ccChains) do
    local base = ccBases[cc] or {}
    if #base == 0 then
      local rest, minStart = generators.restFor(cc), math.huge
      for _, rec in ipairs(chain) do minStart = math.min(minStart, rec.window[1]) end
      base = { basePoint(minStart, rest) }
    end
    for _, span in ipairs(spans.mergeWindows(chain)) do
      for _, emitSpan in ipairs(emitScope and spans.clip(span, emitScope[cc]) or { span }) do
        for _, point in ipairs(curves.foldChains(chain, emitSpan, base, gridStep)) do
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
  return fxCCs
end

-- A host is an on-take fx note, a parked fx event or an fx region; generators can't tell which.
--shape: emission = { notes = [derived spec], pb = chain record | nil, ccs = { [cc] = chain record } }
local function runHost(chan, host, pbBase, ccBases, chanCtx, gridStep)
  local spanStart, spanEnd = host.window[1], host.window[2]
  local pas, ccs, ats, pb = continuousStreams(chan, spanStart, spanEnd, pbBase, ccBases)
  local original = { window = { spanStart, spanEnd }, chan = chan, lane = host.lane, id = host.id,
                     notes = host.notes, pas = pas, ccs = ccs, ats = ats, pb = pb }
  local stream = util.clone(original)
  stream.ccs = util.clone(original.ccs)   -- folds replace per-target lists; the original's map stays untouched
  local ownsNotes = false
  local owned = {}   -- continuous target ('pb' | cc number) -> true once a stage folded a curve in

  local function foldContinuous(target, mode, output)
    if owned[target] == nil then owned[target] = false end
    if #output.delta == 0 then return end
    local cur = target == 'pb' and stream.pb or stream.ccs[target] or {}
    -- An empty pb curve already reads as centre, its rest; a cc has to have its rest seeded.
    if #cur == 0 and target ~= 'pb' then
      cur = { basePoint(spanStart, generators.restFor(target)) }
    end
    local endRestValue = curves.eval(cur, spanEnd)
    if mode == 'replace' then
      cur = curves.foldIntoWindow(output.delta, spanStart, spanEnd)
    else
      cur = curves.sumStreams(cur, { output.delta }, { spanStart, spanEnd }, gridStep)
    end
    -- Handing back what the stage found keeps a generator from bending the channel past its window.
    cur = curves.closeAtWindowEnd(cur, endRestValue, spanStart, spanEnd)
    owned[target] = true
    if target == 'pb' then stream.pb = cur else stream.ccs[target] = cur end
  end

  for _, params in ipairs(host.fx) do
    local meta = generators.kinds[params.kind]
    if meta then
      local dest = generators.destOf(params)
      -- Bypass runs as an empty augment rather than a skip, so its target is still owned and the
      -- chain's record survives. see docs/generators.md § The chain
      local out  = params.bypass and { notes = {}, delta = {} } or meta.expand(stream, original, params, chanCtx)
      local mode = params.bypass and 'augment' or meta.mode
      if dest == 'note' then
        ownsNotes = true
        if mode == 'replace' then stream.notes = out.notes
        else
          local merged = {}
          for _, note in ipairs(stream.notes) do util.add(merged, note) end
          for _, note in ipairs(out.notes)    do util.add(merged, note) end
          stream.notes = merged
        end
      else
        foldContinuous(dest, mode, out)
      end
    end
  end

  local emission = { notes = {}, ccs = {} }

  -- Every owned target emits, contributed to or not, so an all-bypassed chain re-seats its base
  -- rather than leaving its window to read as unowned.
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

  -- The same test parksNotes applies, so the emitted stream stands in for exactly the members
  -- parking took off the lane.
  if ownsNotes then
    for _, note in ipairs(stream.notes) do
      util.add(emission.notes, {
        evType = 'note', chan = chan, derived = host.id,
        pitch = note.pitch, vel = note.vel, detune = note.detune or 0,
        intentCents = note.intentCents, baseVoice = note.baseVoice,
        delay = host.delay or 0, sample = host.sample,
        ppqL = note.ppq, endppqL = note.endppq,
        ppq    = time:fromLogical(chan, note.ppq,    host.delayPpq),
        endppq = time:fromLogical(chan, note.endppq, host.delayPpq),
      })
    end
  end
  return emission
end

-- A derived spec's logical-frame copy, as fxNotesByHost carries it; runs per derived note.
local logicalCopyOf = util.picker("evType chan pitch vel detune intentCents baseVoice delay derived")

--pre: every column is ppq-ordered
--post: fxNotesByHost[chan][id] is rewritten iff id is in fxOut.ran[chan]; all other inputs unchanged
local function rebuildFx(fxOutWindows, fxRegions, pbLimCents)
  local gridStep = ccGridStep()

  -- No notation here: a generator's pitch demands are cents, so this pass never reads the temper.
  -- see docs/generators.md § The ctx discipline
  local chanCtx = {
    resolution = mm:resolution(),
    pbRangeCents = pbLimCents,   -- slide clamps its target to what pb can reach
    -- Parked notes still occupy their lane, so the successor comes off the authored population.
    nextSameLaneNote = function (host)
      local note = host.notes[1]
      if not note or not host.lane then return nil end
      return frame.nextOnLane(frame.channels[host.chan].onTake.notes[host.lane].events, note.ppq)
    end
  }

  -- Recompute, since rebuildRegionPark may have moved fx note hosts. See § Fx window census.
  local fxHostsByChan = {}
  for host in pairs(onTakeFxHosts()) do util.bucket(fxHostsByChan, host.chan, host) end
  for _, bucket in pairs(fxHostsByChan) do
    table.sort(bucket, function(a, b)
      if a.lane ~= b.lane then return a.lane < b.lane end
      return a.ppq < b.ppq
    end)
  end

  local fxRegionsByChan = {}
  for _, region in ipairs(fxRegions or {}) do
    util.bucket(fxRegionsByChan, region.chan, region)
  end

  -- Host-owned outputs: live notes, existence ops (deletes/adds) awaiting the walk, per-chain pb curves, authored
  -- pb base, the per-chan pb emit scope (nil = ungated) steering rebuildPbs' live/kept split, and the host authority.
  --shape: fxOut.ran[chan] = { [hostUuid] = true }; a derived record whose host is absent here is left standing
  local fxOut = { notes = frame.newChannels(), deferredWrite = mmBatch(),
                  pbChains = frame.newChannels(), pbBase = frame.newChannels(),
                  pbScope = {}, ran = frame.newChannels() }

  local function expandChannel(chan)
    local hosts = enumerateHosts(chan, fxHostsByChan[chan] or {}, fxRegionsByChan[chan] or {})
    local gated = not dirt.wholesale(chan)
    local status, emitScope = {}, {}
    if gated then
      status, emitScope = classifyHosts(chan, hosts)
      fxOut.pbScope[chan] = emitScope.pb or {}
    else
      for _, host in ipairs(hosts) do status[host] = 'seeded' end
    end

    local running = {}
    for _, host in ipairs(hosts) do
      if status[host] ~= 'kept' then util.add(running, host) end
    end
    local runWindows = spans.mergeWindows(running)
    local pbBase, ccBases = pbBaseFor(chan, runWindows), ccBasesFor(chan, runWindows)
    fxOut.pbBase[chan] = pbBase

    local fxOutNotes, ccChains = {}, {}
    for _, host in ipairs(hosts) do
      if status[host] ~= 'kept' then
        local emission = runHost(chan, host, pbBase, ccBases, chanCtx, gridStep)
        for _, spec in ipairs(emission.notes) do util.add(fxOutNotes, spec) end
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
    for target, windows in pairs(emitScope) do
      local raw = {}
      for _, window in ipairs(windows) do
        util.add(raw, toRawSpan(chan, window))
      end
      ccScope[target] = raw
    end

    local fxInNotes, fxInCCs, ran = {}, {}, fxOut.ran[chan]
    local function gatherFrom(id, clipped)
      ran[id] = true
      local entries = {}
      for _, entry in pairs(index.derivedByHost(chan)[id] or {}) do util.add(entries, entry) end
      table.sort(entries, index.order)
      for _, entry in ipairs(entries) do
        if entry.evType == 'note' then
          util.add(fxInNotes, entry)
        elseif entry.evType == 'cc' then
          if not clipped or spans.contains(ccScope[entry.cc], entry.ppq) then util.add(fxInCCs, entry) end
        end
      end
    end
    for _, host in ipairs(running) do gatherFrom(host.id, status[host] == 'overlap') end
    -- A file whose host is absent from the pass was parked or deleted, so it is swept whole; kept
    -- hosts count as present, so a kept neighbour's records are not swept with it.
    local hostsOfPass = {}
    for _, host in ipairs(hosts) do hostsOfPass[host.id] = true end
    for id in pairs(index.derivedByHost(chan)) do
      if not hostsOfPass[id] then gatherFrom(id) end
    end

    diffEvents(fxInNotes, fxOutNotes, fxOut.deferredWrite,
      -- docs/trackerManager.md § Fx expansion covers the key choice.
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

    local fxOutNotesLogical = {}
    for i, spec in ipairs(fxOutNotes) do
      index.stampEmission(spec, i)
      util.add(fxOut.notes[chan], spec)
      -- A clone, since rebuildTails mutates fxOut.notes below.
      local copy = logicalCopyOf(spec, { ppq = spec.ppqL, endppq = spec.endppqL })
      index.stampEmission(copy, i)
      util.add(fxOutNotesLogical, copy)
    end
    -- table.sort is unstable, so the emission ordinal is what makes onset collisions order totally.
    table.sort(fxOutNotesLogical, function(a, b)
      if a.ppq ~= b.ppq then return a.ppq < b.ppq end
      if a.pitch ~= b.pitch then return a.pitch < b.pitch end
      return index.emissionOf(a) < index.emissionOf(b)
    end)
    -- Bucketed after the sort, so each host's list inherits onset order. Clearing only `ran`'s
    -- buckets drops the stale list of a host that emitted nothing or was swept; a kept host's stands.
    local byHost = fxNotesByHost[chan] or {}
    for id in pairs(ran) do byHost[id] = nil end
    for _, note in ipairs(fxOutNotesLogical) do util.bucket(byHost, note.derived, note) end
    fxNotesByHost[chan] = byHost

    local fxCCs = emitCCs(chan, ccChains, ccBases, gated and emitScope or nil, gridStep)

    local ccWrites = mmBatch()
    diffEvents(fxInCCs, fxCCs, ccWrites,
      function(x) return util.key(x.cc, x.ppq, x.val, x.shape, x.tension) end)
    ccWrites.commit()
    -- Only a fresh seat has a uuid from mm:add, so a kept seat keeps its tag. `derived` is no cc
    -- field, so it goes on um's entry and never reaches the record. see § Route-by-window
    index.withDeferredSort(function()
      for _, entry in ipairs(fxCCs) do
        if entry.uuid then
          index.assign(index.byUuid(entry.uuid), 'derived',
                       fxOutWindows.ownsRaw('cc', chan, entry.cc, entry.ppq))
        end
      end
    end)
  end

  for chan = 1, 16 do
    -- A clean channel's derived output stands in mm; leaving its fxOut empty makes tails, pbs and
    -- pcs skip it too.
    if dirt.has(chan) then expandChannel(chan) end
  end
  return fxOut
end

----- Tail walk

-- One channel's per-note settle, bound and emission rules: the linear and frontier walks drive the
-- same rules over their own traversals, and read back the disturbed set the rules mark.
--shape: rules = { disturbed = set, settleOnset(e, prev), boundNote(note, pitchNext), emitNudge(emitted, e) }
local function makeTailRules(chan, res, windows, writes)
  local disturbed, nudged = {}, {}

  -- The lane successor in column order: a neighbour delayed off its row still follows here. The
  -- population is the column's own: no derived note bounds by a lane, so none joins one.
  local function laneNext(e)
    local col = frame.channels[chan].onTake.notes[e.lane]
    if not col then return end
    for i = util.firstAfter(col.events, e.ppqL), #col.events do
      local evt = col.events[i]
      if util.isNote(evt) and not evt.parked then return evt end
    end
  end

  local function settleOnset(e, prev)
    local onset = voicing.separateOnset(e, prev)
    if not onset then return false end
    -- Notes only ever give way forward, so a nudge is final and its writes can stage here.
    disturbed[e], nudged[e] = true, true
    index.assign(e, 'ppq', onset)
    local backing = e.colEvt or e   -- seated entries write through to their column note; fxNotes ride bare
    if backing.committed then writes.assign(backing, { ppq = e.ppq }) end
    if e.colEvt and e.colEvt.delay ~= nil then
      -- The column stays logical, so the raw shift reaches it only as the delayC give-way cue.
      local shift = e.ppq - time:fromLogical(chan, e.ppqL)
      frame.setEvent(e.colEvt, 'delayC', util.round(timing.ppqToDelay(shift, res)))
    end
    return true
  end

  --pre: (not e.derived) → e.colEvt carries its lane bound -- the lane pass ran over this channel
  --pre: e.derived → the pass's window set holds that host's window
  local function boundNote(note, pitchNext)
    local laneBound  = note.derived and math.min(note.endppqL, windows.window(note.derived).endppq)
                       or note.colEvt.endppqC
    local pitchBound = pitchNext and pitchNext.ppq or math.huge
    -- The lane bound stays logical because the column draws it; the raw bound reaches mm,
    -- so is converted. see docs/trackerManager.md § Tail walk
    local rawCeiling = math.min(time:fromLogical(chan, laneBound), pitchBound)
    local rawBound   = util.round(math.max(note.ppq + 1, rawCeiling))
    if rawBound ~= note.endppq then
      index.assign(note, 'endppq', rawBound)
      local backing = note.colEvt or note
      if backing.committed then writes.assign(backing, { endppq = rawBound }) end
    end
    if note.colEvt then
      -- An uncached note has no authored ceiling to draw, so the column shows its lane bound.
      frame.setEvent(note.colEvt, 'endppq', note.endppqL or laneBound)
    end
  end

  -- The walk's own dirt: a nudged lane-1 onset seeds every absorber seat up to the next lane-1
  -- onset, for pbs to consume later this pass. see design § The widen and the emission are the same fact
  local function emitNudge(emitted, e)
    if nudged[e] and isAuthored(e) and e.lane == 1 then
      local nextOnLane = laneNext(e)
      util.add(emitted, { uuid = e.uuid, verb = 'nudge', evType = 'note', ppq = e.ppq, ppqL = e.ppqL,
                          lane = e.lane, pitch = e.pitch, endppqL = nextOnLane and nextOnLane.ppq })
    end
  end

  return { disturbed = disturbed, settleOnset = settleOnset, boundNote = boundNote, emitNudge = emitNudge }
end

--shape: notes = { onTake = raw index notes, reran = the pass's derived specs,
--                 carried = filter over the raw index }
local function mergeIndexed(notes)
  table.sort(notes.reran, index.order)
  local merged, j = {}, 1
  for _, entry in ipairs(notes.onTake) do
    if notes.carried(entry) then
      while notes.reran[j] and index.order(notes.reran[j], entry) do
        util.add(merged, notes.reran[j]); j = j + 1
      end
      util.add(merged, entry)
    end
  end
  for i = j, #notes.reran do util.add(merged, notes.reran[i]) end
  return merged
end

-- Linear tail walk for dense and wholesale dirt; see docs § Tail walk
local function linearTails(chan, rules, notes, bound)
  local disturbed = rules.disturbed
  local merged    = mergeIndexed(notes)

  -- Disturbed seeded by name: derived membership + the seeds themselves, survivors resolved by uuid,
  -- adds by logical seat. Anchors for the bound probes: seed positions (dead included) plus disturbed onsets.
  local anchors = {}
  -- reran's entries are the merged list's own, so identity names them. A standing derived record is not
  -- among them: its host kept, so it was settled and clipped last pass and rides as a bound anchor only.
  for _, note in ipairs(notes.reran) do disturbed[note] = true end
  if dirt.wholesale(chan) then
    for _, note in ipairs(merged) do disturbed[note] = true end   -- degenerate pass: load, external change
  else
    local byUuid, byKey = {}, {}
    for _, note in ipairs(merged) do
      if note.uuid then byUuid[note.uuid] = note end
      util.bucket(byKey, util.key(note.ppqL or note.ppq, note.lane, note.pitch), note)
    end
    for _, seed in ipairs(dirt.has(chan)) do
      util.add(anchors, { pos = seed.ppq, pitch = seed.pitch })
      local note = seed.uuid and byUuid[seed.uuid]
      if note then disturbed[note] = true
      else
        for _, evt in ipairs(byKey[util.key(seed.ppqL or seed.ppq, seed.lane, seed.pitch)] or {}) do
          disturbed[evt] = true
        end
      end
    end
  end

  -- Onset settlement: only a disturbed note collides, onto its same-pitch predecessor; a landed nudge
  -- marks itself disturbed so the cascade carries forward.
  local anyNudge, lastByPitch = false, {}
  index.withDeferredSort(function()
    for _, note in ipairs(merged) do
      local prev = lastByPitch[note.pitch]
      if disturbed[note] or (prev and disturbed[prev]) then
        if rules.settleOnset(note, prev) then anyNudge = true end
      end
      lastByPitch[note.pitch] = note
    end
  end)
  if anyNudge then table.sort(merged, index.order) end

  -- Bound set: the lane pass's re-bounded events it arrives with, every disturbed note, and each
  -- anchor's nearest same-pitch predecessor. see docs/trackerManager.md § Tail walk
  for e in pairs(disturbed) do bound[e] = true end
  -- Wholesale already bounds every note, so the predecessor probes add nothing. Only the seeded case
  -- needs them, to reach the non-disturbed neighbours dirt shadows.
  if not dirt.wholesale(chan) then
    for e in pairs(disturbed) do util.add(anchors, { pos = e.ppq, pitch = e.pitch }) end
    -- One ascending sweep, tracking the running last-in-pitch, answers every anchor at once -- the
    -- forward twin of the successor pass below. See docs/trackerManager.md § Tail walk.
    table.sort(anchors, function(a, b) return a.pos < b.pos end)
    local lastInPitch, i = {}, 1
    for _, a in ipairs(anchors) do
      while i <= #merged and merged[i].ppq < a.pos do
        lastInPitch[merged[i].pitch] = merged[i]
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
  for i = #merged, 1, -1 do
    local e = merged[i]
    local pitchAbove = nearestInPitch[e.pitch]
    -- A neighbour sharing e's raw is no successor of it: it hands over its own.
    local pitchNext = pitchAbove and (pitchAbove.ppq > e.ppq and pitchAbove or nextAfterPitch[e.pitch])
    nearestInPitch[e.pitch], nextAfterPitch[e.pitch] = e, pitchNext

    rules.emitNudge(emitted, e)
    if bound[e] then rules.boundNote(e, pitchNext) end
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
-- index (binary-searched, scanned outward) and the small reran list. The strict-ppq bound probe; mirrors util.seek.
local function nearestNote(notes, pos, side, filter)
  local best
  local anchor = util.firstAtOrAfter(notes.onTake, pos)
  if side == 'before' then
    for i = anchor - 1, 1, -1 do
      local rec = notes.onTake[i]
      if notes.carried(rec) and filter(rec) then best = rec; break end
    end
  else
    for i = anchor, #notes.onTake do
      local rec = notes.onTake[i]
      if rec.ppq > pos and notes.carried(rec) and filter(rec) then best = rec; break end
    end
  end
  for _, rec in ipairs(notes.reran) do
    local onSide = side == 'before' and rec.ppq < pos or side == 'after' and rec.ppq > pos
    local nearer = best == nil
                   or (side == 'before' and index.order(best, rec))
                   or (side == 'after'  and index.order(rec, best))
    if onSide and filter(rec) and nearer then best = rec end
  end
  return best
end

-- Same-pitch record immediately before `node` in the total order, over index + reran -- settlement's
-- predecessor. A same-tick same-pitch note counts here (unlike the strict bound probes).
local function prevSamePitch(notes, node)
  local best
  for i = util.firstAfter(notes.onTake, node.ppq) - 1, 1, -1 do
    local rec = notes.onTake[i]
    if notes.carried(rec) and rec ~= node and rec.pitch == node.pitch and index.order(rec, node) then
      best = rec; break
    end
  end
  for _, rec in ipairs(notes.reran) do
    if rec ~= node and rec.pitch == node.pitch and index.order(rec, node)
       and (best == nil or index.order(best, rec)) then best = rec end
  end
  return best
end

-- Same-pitch record immediately after `node` in the total order, keyed on `origPpq` (node's raw before
-- this pass nudged it) -- settlement's cascade successor. see design § Nudge probes stop at the tick
local function nextSamePitch(notes, node, origPpq)
  local key = { ppq = origPpq, ppqL = node.ppqL, derived = node.derived, lane = node.lane, pitch = node.pitch }
  -- The probe stands in for node in every term of the order, emission included: without it two hits
  -- emitted alike tie, and the second is no successor of the first for the cascade to separate.
  index.stampEmission(key, index.emissionOf(node))
  local best
  for i = util.firstAtOrAfter(notes.onTake, origPpq), #notes.onTake do
    local rec = notes.onTake[i]
    if notes.carried(rec) and rec ~= node and rec.pitch == node.pitch and index.order(key, rec) then
      best = rec; break
    end
  end
  for _, rec in ipairs(notes.reran) do
    if rec ~= node and rec.pitch == node.pitch and index.order(key, rec)
       and (best == nil or index.order(rec, best)) then best = rec end
  end
  return best
end

-- On-take records at a seed's logical seat, for adds/deletes carrying no surviving uuid. Scans only the
-- seed's raw-ppq cluster in the sorted index (plus reran) -- bounded, not a channel sweep.
local function seatMatches(notes, seed)
  local out, key = {}, seed.ppqL or seed.ppq
  local function match(rec)
    return (rec.ppqL or rec.ppq) == key and rec.lane == seed.lane and rec.pitch == seed.pitch
  end
  for i = util.firstAtOrAfter(notes.onTake, seed.ppq), #notes.onTake do
    if notes.onTake[i].ppq ~= seed.ppq then break end
    -- Authored only, unlike the notes the bound probes range over: a seat is lane-keyed and a
    -- derived record carries no lane, so none can answer one.
    if isAuthored(notes.onTake[i]) and match(notes.onTake[i]) then util.add(out, notes.onTake[i]) end
  end
  for _, rec in ipairs(notes.reran) do if rec.ppq == seed.ppq and match(rec) then util.add(out, rec) end end
  return out
end

-- The frontier probe walk: seek to each seed, probe a bounded few rows for its neighbours, drive the
-- shared settle/bound rules -- no whole-channel traversal.
local function frontierTails(chan, rules, notes, bound)
  local disturbed = rules.disturbed

  -- Disturbed seeded by name: derived membership is all of reran; adds/deletes name a seat the
  -- index tick cluster answers; byUuid resolve is note-scoped -- see docs § What the walk visits, and what it emits.
  local anchors = {}
  for _, rec in ipairs(notes.reran) do disturbed[rec] = true end
  for _, seed in ipairs(dirt.has(chan)) do
    util.add(anchors, { pos = seed.ppq, pitch = seed.pitch })
    local rec = seed.uuid and index.byUuid(seed.uuid)
    if rec and rec.evType == 'note' and rec.chan == chan then disturbed[rec] = true
    else for _, hit in ipairs(seatMatches(notes, seed)) do disturbed[hit] = true end end
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
      local prev = prevSamePitch(notes, head)
      local chain = {}
      if prev then util.add(chain, prev) end
      util.add(chain, head)
      -- reach = the running worst-case settled tick; a same-pitch successor cascades only while it can
      -- still collide (separateOnset gives way by one tick), or when it is itself a pending seed.
      local reach = (prev and head.ppq <= prev.ppq) and prev.ppq + 1 or head.ppq
      local node = head
      while true do
        local nxt = nextSamePitch(notes, node, node.ppq)
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
          if rules.settleOnset(node, prev) then anyNudge = true end
        end
      end
    end
  end)
  -- notes.onTake is um's own and the block's close re-trued it; reran belongs to this walk.
  if anyNudge then table.sort(notes.reran, index.order) end

  -- Phase 2 -- bounds, order-free: the lane pass's re-bounded events it arrives with, disturbed notes,
  -- and each anchor's nearest same-pitch predecessor; reads settled onsets, writes only endppq.
  for e in pairs(disturbed) do
    bound[e] = true
    util.add(anchors, { pos = e.ppq, pitch = e.pitch })
  end
  for _, a in ipairs(anchors) do
    local pitchPred = nearestNote(notes, a.pos, 'before', function(r) return r.pitch == a.pitch end)
    if pitchPred then bound[pitchPred] = true end
  end

  local emitted = {}
  for e in pairs(bound) do
    local pitchNext = nearestNote(notes, e.ppq, 'after', function(r) return r.pitch == e.pitch end)
    rules.emitNudge(emitted, e)
    rules.boundNote(e, pitchNext)
  end
  return emitted
end

----- Rebuild tails

-- Exclude derived events re-run this pass and foreign MIDI, keep authored events and retained
-- derived events; rebuildPbs and rebuildPCs read the same population.
local function carriedFor(ran)
  return function(rec)
    if rec.ppqL == nil then return false end -- foreign MIDI
    return not (rec.derived and ran[rec.derived])
  end
end

-- The tail walk: real notes, fixed externals and fxNotes settle onsets then clip tails together,
-- every write landing with fx's del/add in one mm:modify. see docs/trackerManager.md § Tail walk
--post: a note is separated only if it is disturbed; a nudged lane-1 onset emits its seat closure
--post: the disturbed, the lane pass's named and each anchor's predecessors take fresh bounds
local function rebuildTails(fxOut, windows)
  local resolution = mm:resolution()
  -- rebuildFx's uncommitted batch, so its fresh specs are clipped in place and reach mm clipped.
  local writes = fxOut.deferredWrite

  for chan = 1, 16 do
    if dirt.has(chan) then
      local notes = {
        onTake  = index.raw(chan).notes,
        reran   = util.clone(fxOut.notes[chan]),
        carried = carriedFor(fxOut.ran[chan])
      }
      -- Seeded with the lane pass's re-bounded events; each walk adds what it disturbs and probes.
      local bound = {}
      for _, uuid in ipairs(dirt.tails.has(chan) or {}) do
        local evt = index.byUuid(uuid)
        if evt then bound[evt] = true end
      end
      local rules = makeTailRules(chan, resolution, windows, writes)

      -- Sparse edits seek to their seeds; dense edits and wholesale rebuilds walk the channel once.
      local sparse  = not dirt.wholesale(chan) and #dirt.has(chan) + #notes.reran <= FRONTIER_SEED_CAP
      local emitted = (sparse and frontierTails or linearTails)(chan, rules, notes, bound)

      -- Past the cap this collapses the channel to wholesale
      dirt.add(chan, emitted)
    end
  end
  writes.commit()
end

----- Rebuild Pbs

-- A ramp onset's dual point rides one tick before the onset (see docs/tuning.md § Value-aware
-- seats), so every span that must contain an onset's seats reaches one tick back.
local DUAL_POINT_TICK = 1

--shape: baseVoiceUnion = { detuneAt(ppq), between(lo, hi), first(), nextAfter(ppq), anyDetuneJump() }
-- A channel's base-voice onset stream: the raw index's surviving notes unioned with the pass's
-- derived base voices, which live off-take in fxOut.notes. see docs/tuning.md § Absorber reconciliation
--pre: derived is ppq-ascending and holds chan's derived base voices for this pass
--pre: keep is carriedFor for chan, so `derived` supersedes exactly what it drops
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
    local function authored(pb) return isAuthoredPb(pb) and not replaceWins.inSeatWindow(pb.ppq) end
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
-- and stamp the detune cue on column pbs. see docs/tuning.md § Absorber reconciliation
local function rebuildPbs(fxOut, extraColumns, pbLimCents)
  local gridStep = ccGridStep()
  local fxNotes = fxOut.notes
  -- Reads only the per-chan .pb keep-flag; rebuildExtraColumns's mid-pipeline write grows
  -- .notes only, so the head snapshot is current for this.
  local extras = extraColumns or {}

  -- Per-chan base-voice union, built for dirty channels alone; clean ones carry their pb column
  -- whole. see docs/tuning.md § Absorber reconciliation
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
      baseVoiceByChan[chan] = baseVoiceUnion(chan, derivedBaseVoice, carriedFor(fxOut.ran[chan]))
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
  -- gather clones only in-scope pbs, and only their column events take a fresh detune cue.
  local function inSpans(spanSet, ppq)
    if not spanSet then return true end
    for _, s in ipairs(spanSet) do
      if ppq >= s[1] and ppq <= s[2] then return true end
    end
    return false
  end

  -- Each pb rides its own clone through the pass, carrying the index entry's uuid so a mutated clone still
  -- names its source; origShape is held because the pass rewrites shape.
  local pbsByChan, cuedByChan = {}, frame.newChannels()
  for chan = 1, 16 do
    if dirt.has(chan) then
      local seatSpans = seatSpansByChan[chan]
      for _, entry in ipairs(index.raw(chan).pbs) do
        if inSpans(seatSpans, entry.ppq) then
          local pb = util.clone(entry, { colEvt = true })
          pb.origShape = entry.shape
          util.bucket(pbsByChan, pb.chan, pb)
          if not entry.derived and entry.colEvt then
            util.add(cuedByChan[chan], { colEvt = entry.colEvt, ppq = entry.ppq })
          end
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
    -- generates no seat here; those kept-boundary seats stand from last pass.
    for i = #pbs, 1, -1 do
      if fencedPb(pbs[i].ppq) then table.remove(pbs, i) end
    end

    -- The CC walk gave every authored pb its cents, so a centless one is a seat, whether a live window
    -- covers it or its window's host no longer runs.
    local function isRealPb(pb) return isAuthoredPb(pb) and not inSeatWindow(pb.ppq) end

    -- The authored value stream, whole and read-only, straight from the raw index -- decoupled from the
    -- bounded clone set.
    local realPbs = {}
    for _, entry in ipairs(index.raw(chan).pbs) do
      if isRealPb(entry) then
        util.add(realPbs, { ppq = entry.ppq, cents = entry.cents, shape = entry.shape, tension = entry.tension })
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

    -- Seat each replace curve as derived seats carrying its shape; see docs/tuning.md §
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
      -- A markerless pb is a generated seat (recognized by window, no marker); tag it in RAM so the
      -- fungible-absorber machinery below reseats it.
      if not pb.derived and not isRealPb(pb) then pb.derived = 'absorber' end
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
    -- restamped, raw changed, derived shape changed) needs to land.
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
        elseif pb.raw ~= newRaw or shapeChanged then
          update = { cents = pb.cents, val = newRaw }
        end
        if update then
          -- The marker lands with the sidecar: a seat tagged in RAM that takes cents outside every window
          -- must not read as authored next pass.
          if pb.derived then update.shape, update.derived = pb.shape, pb.derived end
          -- A markerless seat persists native MIDI only; strip the sidecar fields so the assign
          -- stamps no metadata and the seat stays plain. Its ppq/val/shape still land.
          if markerless then update.cents, update.ppqL, update.derived = nil, nil, nil end
          pb.raw = newRaw
          pbWrites.assign({ uuid = pb.uuid }, update)
        end
      end
    end
  end

  for chan = 1, 16 do
    -- Clean channels are skipped wholesale -- their carried pb column stands (set at rebuild entry).
    if dirt.has(chan) then
      local pbs = pbsByChan[chan] or {}
      util.sortByPPQ(pbs)
      local baseVoice = baseVoiceByChan[chan]
      deriveChan(chan, pbs, winsByChan[chan], seatSpansByChan[chan], baseVoice)

      -- An out-of-scope column pb keeps last pass's cue: no base voice around it moved.
      for _, cued in ipairs(cuedByChan[chan]) do
        frame.setEvent(cued.colEvt, 'detune', baseVoice.detuneAt(cued.ppq))
      end
      -- A pb column exists when it holds an event or extraColumns asks for it.
      local onTake = frame.channels[chan].onTake
      if onTake.pb and #onTake.pb.events == 0 and not (extras[chan] and extras[chan].pb) then
        onTake.pb = nil
      end
    end
  end

  pbWrites.commit()
end

----- Rebuild PCs

--contract: synthesised PCs carry derived='pc'; ppqL inherited from winning host-note record
--contract: an existing derived PC matching (ppq, val) is kept, preserving mm-side loc
--contract: appends removals/adds to the writes batch {delete(event), add(spec)}
--contract: marks sampleShadowed=true on the event or the spec of records lost to the onset's rank
--pre: seedSpans (from pcSeedSpans) narrow existing to its raw spans; nil = whole channel
--post: returns the logical seats of the authored pcs it deletes, read before writes commit
--invariant: seated marks via setEvent; off-take direct; no lane renews an event it lacks
local function reconcilePCsForChan(chan, records, writes, seedSpans)
  -- The previous emission is um's raw index, in the frame the prediction carries.
  local pcs, existing = index.raw(chan).pcs, {}
  if seedSpans then
    for e in onsetsIn(pcs, seedSpans) do util.add(existing, e) end
  else
    for _, e in ipairs(pcs) do util.add(existing, e) end
  end
  local consumed = {}
  for _, e in ipairs(existing) do
    if not e.derived then util.add(consumed, e.ppqL) end
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
  return consumed
end

--shape: pcSeedSpans(chan, fxNotes) -> raw span set ({ {lo, hi}, ... }, merged); nil = wholesale
local function pcSeedSpans(chan, fxNotes)
  if dirt.wholesale(chan) then return nil end
  -- Any derived output at all means a host of this channel re-ran, and its PCs are the pass's to
  -- decide wholesale; a kept host contributes no entry here.
  if #fxNotes > 0 then return nil end
  local points = {}
  for _, s in ipairs(dirt.has(chan)) do
    util.add(points, s.ppq)
    local live = s.uuid and index.byUuid(s.uuid)
    if live then util.add(points, live.ppq) end
  end
  local raw, notes = {}, index.raw(chan).notes
  for _, ppq in ipairs(points) do
    local i = util.firstAfter(notes, ppq)
    while notes[i] and not isAuthored(notes[i]) do i = i + 1 end
    local nextNote = notes[i]
    util.add(raw, { ppq, nextNote and nextNote.ppq or math.huge })
  end
  return spans.merge(raw)
end

-- PC synthesis (trackerMode only), after the sample stamp. Seed-list dirt closes to spans; records
-- and writes clip to them, so out-of-span PCs stand. see docs/trackerManager.md § PC synthesis
local function rebuildPCs(fxOut, extraColumns)
  if not cm:get('trackerMode') then return end
  local fxNotes = fxOut.notes
  local pcWrites = mmBatch()
  local consumedByChan = {}
  for chan = 1, 16 do
    -- Clean channels freeze: their PCs stand in mm and their pc column is carried forward.
    if not dirt.has(chan) then goto nextChan end
    local seedSpans = pcSeedSpans(chan, fxNotes[chan])
    local records = {}
    -- The gather ordinal, and authored notes are gathered first: it is the rank's tie-break under
    -- the lane, so a laneless derived record falls after every authored one.
    local function addRecord(rec)
      rec.ord = #records + 1
      util.add(records, rec)
    end
    -- A host this pass kept owns PCs at onsets no authored note sits on; those records are um's own.
    -- Off-column, they carry no colEvt, so the shadow mark rides the record like a spec's; no note host means no inherited sample.
    local carried = carriedFor(fxOut.ran[chan])
    local function recordNote(entry)
      if not carried(entry) then return end
      if entry.derived then
        addRecord{ ppq = entry.ppq, ppqL = entry.ppqL, sample = entry.sample or 0, spec = entry }
      else
        addRecord{ ppq = entry.ppq, ppqL = entry.ppqL, lane = entry.lane,
                   sample = entry.sample, evt = entry.colEvt }
      end
    end
    if seedSpans then
      for entry in onsetsIn(index.raw(chan).notes, seedSpans) do recordNote(entry) end
    else
      for _, entry in ipairs(index.raw(chan).notes) do recordNote(entry) end
    end
    for _, n in ipairs(fxNotes[chan]) do
      if not seedSpans or spans.contains(seedSpans, n.ppq) then
        -- region-derived notes ride no note host: no sample to inherit, regenerated each pass
        addRecord{ ppq = n.ppq, ppqL = n.ppqL, sample = n.sample or 0, spec = n }
      end
    end
    local consumed = reconcilePCsForChan(chan, records, pcWrites, seedSpans)
    if #consumed > 0 then consumedByChan[chan] = consumed end
    ::nextChan::
  end
  pcWrites.commit()

  -- Synthesis consumes authored pcs, so they leave the column the walk projected them into; a
  -- column left empty stands only where extraColumns asks for it.
  for chan, ppqLs in pairs(consumedByChan) do
    local onTake = frame.channels[chan].onTake
    exciseEvents({ onTake.pc }, ppqLs)
    local wanted = extraColumns and extraColumns[chan] and extraColumns[chan].pc
    if #onTake.pc.events == 0 and not wanted then onTake.pc = nil end
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
  rebuildCCs(fxInWindows, pbRangeCents)
  dirt.swing.clear()
  dirt.foreign.clear()

  rebuildExtraColumns(sources.extraColumns, sources.paramAutomation)
  rebuildExternals(external)
  if cm:get('trackerMode') then rebuildSamples() end
  seatStash(sources.fxParked)
  rebuildPA()

  dirt.tails.clear()
  for chan = 1, 16 do if dirt.has(chan) then clipTails(chan) end end

  local onTakeHosts  = onTakeFxHosts()
  local fxOutWindows = buildFxWindows(sources.fxRegions, onTakeHosts)
  local parkedByHost = rebuildRegionPark(fxOutWindows, sources.fxParked, fxInWindows, onTakeHosts, pbRangeCents)

  local fxOut = rebuildFx(fxOutWindows, sources.fxRegions, pbRangeCents)

  rebuildTails(fxOut, fxOutWindows)
  rebuildPbs(fxOut, sources.extraColumns, pbRangeCents)
  rebuildPCs(fxOut, sources.extraColumns)

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
