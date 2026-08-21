-- See docs/editCursor.md for the model (clipboard sits with editCursor
-- because the two share the model and the verb vocabulary).

--invariant: clipboard persists via REAPER ExtState under ('rdm','clipboard'), serialised by util.serialise
--invariant: clip rows are 0-relative to the clip's top (row=0 is first row of selection); paste re-bases against current cursor row
--invariant: single vs multi mode is decided by selected-col count: c1==c2 -> single, otherwise multi
--invariant: single.parts = the parts the span covered, in column order
--invariant: a single clip carries notes iff parts[1] == 'pitch'
--invariant: a lane the span excluded is dropped at copy, filled at paste from the destination
--invariant: a field whose part the column doesn't show can't be excluded — it rides with the note
--invariant: multi.cols carry chanDelta from leftmost source channel; cursor's channel becomes the leftmost destination
--invariant: CLIP_RESERVED keys are stripped at copy; CLIP_ARTIFACTS (row/endRow) are stripped at paste; everything else (including custom metadata) round-trips
--invariant: laneEvent synthesises, never clones — no note payload may ride onto a cc destination
local util    = require 'util'

-- Reserved keys never carry verbatim through copy/paste; keep this list
-- small and rule-based. See docs/editCursor.md § Reserved keys.
local CLIP_RESERVED = {
  -- position (rebuilt from row + cursor)
  ppq = true, endppq = true,
  -- destination identity
  chan = true, rpb = true, lane = true, cc = true,
  -- mm/REAPER bookkeeping
  idx = true, uuid = true, uuidIdx = true, realised = true,
  -- envelope-level
  type = true, evType = true,
}
-- Clip-only fields stripped before a paste materialises into a write event.
local CLIP_ARTIFACTS = { row = true, endRow = true }

-- The event field each part edits. A field with no part -- detune, the
-- note's duration -- has no lane to exclude it and rides with the note.
local PART_FIELD = { pitch = 'pitch', vel = 'vel', sample = 'sample',
                     delay = 'delay', val = 'val', pb = 'val' }

-- Where a part may paste: its own name, plus the one cross-part move --
-- vel and val are both 7-bit lane values. fx regions ride on clip.fxRegions.
local COMPATIBLE = {
  pitch  = { pitch = true },
  vel    = { vel = true, val = true },
  val    = { val = true, vel = true },
  delay  = { delay = true },
  sample = { sample = true },
  pb     = { pb = true },
  fx     = {},
}

local deps = ...

---------- PRIVATE

local ec           = deps.ec
local grid         = deps.grid
local tm           = deps.tm
local cm           = deps.cm
local currentRpb   = deps.currentRpb
local getCtx       = deps.getCtx
local edit         = deps.edit       -- leaf-edit facade: routes add/delete/assign to gm or tm by cell kind
local aliases      = deps.aliases    -- (cells) -> bool: refuse a paste whose footprint aliases one group
local fx           = deps.fx         -- { gather(r1,r2,c1,c2,anchorChan), paste(list) }: fx regions ride the clip

local function save(clip)
  reaper.SetExtState('rdm', 'clipboard', util.serialise(clip), false)
end

local function load()
  local raw = reaper.GetExtState('rdm', 'clipboard')
  if raw == '' then return end
  local clip = util.unserialise(raw)
  -- A clip saved before parts existed can't say what its span covered.
  if clip.mode == 'single' and not clip.parts then return end
  return clip
end

----- Lanes

-- A note-on carries the lane values; a note-off spells itself vel 0.
local function isNoteOn(evt)
  return util.isNote(evt) and evt.vel and evt.vel > 0
end

-- Only velocity has a configured resting value; other lanes rest at zero.
local function laneRest(part)
  return part == 'vel' and cm:get('defaultVelocity') or 0
end

-- vel 0 is a note-off rather than a velocity, so it neither survives the
-- clamp nor displaces the running value. Other lanes take what they're given.
local function laneValue(part, v)
  if part ~= 'vel' then return v end
  if not v or v <= 0 then return nil end
  return util.clamp(v, 1, 127)
end

-- Step a ppq-sorted series with carry-forward: the value at any ppq is the
-- last one at or before it, seeded from before the region.
local function carrier(series, seed)
  local current, i = seed, 1
  return function(ppq)
    while i <= #series and series[i].ppq <= ppq do current, i = series[i].val, i + 1 end
    return current
  end
end

-- The parts a span covered, in column order. The '*' sentinel addresses no
-- part in particular, so it covers them all.
local function spannedParts(col, part1, part2)
  if part1 == '*' then return util.clone(col.parts) end
  -- A selection outlives a part's visibility (delay is a per-lane toggle),
  -- so an endpoint the column no longer shows means its edge.
  local i1, i2 = 1, #col.parts
  for i, p in ipairs(col.parts) do
    if p == part1 then i1 = i end
    if p == part2 then i2 = i end
  end
  local parts = {}
  for i = math.min(i1, i2), math.max(i1, i2) do util.add(parts, col.parts[i]) end
  return parts
end

--contract: nil if empty; single-col -> {mode='single',parts}; multi-col -> {mode='multi',cols}.
local function collect()
  local ctx = getCtx()
  local r1, r2, c1, c2, part1, part2 = ec:region()
  local numRows  = r2 - r1 + 1
  local logPerRow = ctx:ppqPerRow()

  local function rowOf(p)
    return p / logPerRow - r1
  end

  -- Source duration is structural: endRow is the INTENT ceiling in
  -- clip-row space, never the realised tail tm re-clips every rebuild.
  -- The projected surface carries that intent on endppq (authored
  -- logical, or util.OPEN = inf). An open note's endRow stays inf
  -- through rowOf; the paste site clips finite tails against the next
  -- same-column event.
  local function noteEvent(evt)
    local ce = util.clone(evt, CLIP_RESERVED)
    ce.row = rowOf(evt.ppq)
    if util.isNote(evt) then
      ce.endRow = rowOf(evt.endppq)
    end
    return ce
  end

  -- A scalar column's events are the lane itself, so they clone whole.
  local function scalarEvent(evt)
    local ce = util.clone(evt, CLIP_RESERVED)
    ce.row = rowOf(evt.ppq)
    return ce
  end

  -- FX regions are gathered independently of the cell mode and ride on clip.fxRegions; anchor
  -- their chanDelta to the rectangle's left edge so paste rebases them alongside the cells.
  local anchorChan = grid.cols[c1] and grid.cols[c1].midiChan
  local fxRegions  = anchorChan and fx.gather(r1, r2, c1, c2, anchorChan) or {}

  -- Single-column mode
  if c1 == c2 then
    local col = grid.cols[c1]
    if not col then return end

    -- fx columns carry regions, not cells: skip the cell collect, let clip.fxRegions carry them.
    local parts, events = spannedParts(col, part1, part2), {}
    local covered = {}
    for _, p in ipairs(parts) do covered[p] = true end

    -- Drop the lanes the span left out. A field whose part the column
    -- doesn't show wasn't excludable, so it stays with the note.
    local function maskedNote(evt)
      local ce = noteEvent(evt)
      for _, p in ipairs(col.parts) do
        if p ~= 'pitch' and not covered[p] then ce[PART_FIELD[p]] = nil end
      end
      return ce
    end

    -- A lane on a note column is a view onto notes, so only its own values
    -- travel: a clone would land the note's pitch and metadata on a cc.
    local function laneEvent(evt)
      local ce = { row = rowOf(evt.ppq) }
      for _, p in ipairs(parts) do ce[PART_FIELD[p]] = evt[PART_FIELD[p]] end
      return ce
    end

    if col.type ~= 'fx' then
      local startppq, endppq = ctx:rowToPPQ(r1, col.midiChan), ctx:rowToPPQ(r2 + 1, col.midiChan)
      local emit = col.type ~= 'note' and scalarEvent
                or covered.pitch and maskedNote
                or laneEvent
      for evt in util.between(col.events, startppq, endppq) do
        util.add(events, emit(evt))
      end
    end

    if #events == 0 and #fxRegions == 0 then return end
    local clip = { mode = 'single', parts = parts, numRows = numRows,
                   events = events }
    if #fxRegions > 0 then clip.fxRegions = fxRegions end
    return clip
  end

  local cols = {}
  local leftChan
  local notePosByChan = {}
  for col in ec:eachSelectedCol() do
    if col.type == 'fx' then goto skipCol end   -- regions ride clip.fxRegions, not the cell cols
    leftChan = leftChan or col.midiChan

    local entry = {
      type = col.type,
      chanDelta = col.midiChan - leftChan,
      events = {},
    }
    if col.type == 'note' then
      local n = notePosByChan[col.midiChan] or 0
      entry.key = n
      notePosByChan[col.midiChan] = n + 1
    elseif col.type == 'cc' then
      entry.key = col.cc
    end

    local startppq, endppq = ctx:rowToPPQ(r1, col.midiChan), ctx:rowToPPQ(r2 + 1, col.midiChan)
    for evt in util.between(col.events, startppq, endppq) do
      if col.type == 'note' then
        util.add(entry.events, noteEvent(evt))
      else
        util.add(entry.events, scalarEvent(evt))
      end
    end
    util.add(cols, entry)
    ::skipCol::
  end

  if #cols == 0 and #fxRegions == 0 then return end
  local clip = { mode = 'multi', numRows = numRows, startType = cols[1] and cols[1].type,
                 cols = cols }
  if #fxRegions > 0 then clip.fxRegions = fxRegions end
  return clip
end

-- One footprint cell per destination row, fed to aliases() so a paste covering >=2 instances of one
-- group is refused in global mode. Mirrors the shiftEvents gate; see docs/groupManager.md § Block-shift injectivity.
local function refusePaste(chan, evType, lane, cc, startRow, numRows)
  local ctx, cells = getCtx(), {}
  for r = startRow, startRow + numRows - 1 do
    util.add(cells, { ppq = ctx:rowToPPQ(r, chan), chan = chan,
                      evType = evType, lane = lane, cc = cc })
  end
  return aliases(cells)
end

-- The destination lane's own running value across the region, seeded from
-- the event before it. Values are snapshotted: their events are about to go.
local function destCarrier(dstCol, part, startppq, endppq)
  local field, series = PART_FIELD[part], {}
  for evt in util.between(dstCol.events, startppq, endppq) do
    local v = isNoteOn(evt) and laneValue(part, evt[field])
    if v then util.add(series, { ppq = evt.ppq, val = v }) end
  end
  local before = util.seek(dstCol.events, 'before', startppq)
  return carrier(series, before and before[field] or laneRest(part))
end

--contract: a value on a sustain row becomes PA on its host note; onset rows are the note's own
local function emitSustainPA(dstCol, values)
  local rpb = currentRpb()
  for _, v in ipairs(values) do
    local note = util.seek(dstCol.events, 'before', v.ppq, util.isNote)
    if note and note.endppq > v.ppq and note.ppq ~= v.ppq then
      edit.add({ evType = 'pa', ppq = v.ppq, chan = dstCol.midiChan,
                 pitch = note.pitch, val = v.val, rpb = rpb })
    end
  end
end

--contract: carry-forward over the note-ons in region; vel additionally clears and re-emits PA
local function assignLane(dstCol, part, values, startppq, endppq)
  local field = PART_FIELD[part]
  local before = util.seek(dstCol.events, 'before', startppq)
  local at = carrier(values, before and before[field] or laneRest(part))

  if part == 'vel' then
    for evt in util.between(dstCol.events, startppq, endppq) do
      if evt.evType == 'pa' then edit.delete(evt) end
    end
  end
  for evt in util.between(dstCol.events, startppq, endppq) do
    if evt.pitch then edit.assign(evt, { [field] = at(evt.ppq) }) end
  end
  if part == 'vel' and cm:get('polyAftertouch') then emitSustainPA(dstCol, values) end
end

--contract: replaces the region's events with the clip's, under the destination's identity and field
local function replaceLane(dstCol, part, srcField, events, startppq, endppq)
  local field = PART_FIELD[part]
  for evt in util.between(dstCol.events, startppq, endppq) do
    edit.delete(evt)
  end

  local rpb = currentRpb()
  for _, e in ipairs(events) do
    if srcField ~= field then e[field], e[srcField] = e[srcField], nil end
    e.chan, e.rpb = dstCol.midiChan, rpb
    if dstCol.type == 'cc' then e.cc = dstCol.cc end
    e.evType = dstCol.type
    edit.add(e)
  end
end

--contract: replaces the region's notes; lanes the clip omits take the destination's running value
-- see docs/editCursor.md § Clipboard: single vs multi
local function pasteNotes(dstCol, events, startppq, endppq)
  if dstCol.type ~= 'note' then return end
  local fill = {}
  for _, part in ipairs(dstCol.parts) do
    if part ~= 'pitch' then
      fill[PART_FIELD[part]] = destCarrier(dstCol, part, startppq, endppq)
    end
  end

  -- Delete in-region events directly: queueDeleteNotes' survivor-extension
  -- fixup is for leaving a hole, but we're filling it.
  for evt in util.between(dstCol.events, startppq, endppq) do
    edit.delete(evt)
  end

  local rpb = currentRpb()
  for _, e in ipairs(events) do
    for field, at in pairs(fill) do
      if e[field] == nil then e[field] = at(e.ppq) end
    end
    e.chan, e.lane, e.rpb = dstCol.midiChan, dstCol.lane, rpb
    e.evType = 'note'
    edit.add(e)
  end
  tm:flush()
end

--contract: clip parts write into the destination parts from the cursor's onward; incompatible skip
local function pasteLanes(clip, dstCol, events, startppq, endppq)
  local cursorPart, anchor = ec:cursorPart(), 1
  for i, part in ipairs(dstCol.parts) do
    if part == cursorPart then anchor = i end
  end

  for i, srcPart in ipairs(clip.parts) do
    local dstPart = dstCol.parts[anchor + i - 1]
    if not (dstPart and COMPATIBLE[srcPart][dstPart]) then goto nextPart end
    if dstCol.type == 'note' then
      local values = {}
      for _, e in ipairs(events) do
        local v = laneValue(dstPart, e[PART_FIELD[srcPart]])
        if v then util.add(values, { ppq = e.ppq, val = v }) end
      end
      assignLane(dstCol, dstPart, values, startppq, endppq)
    else
      replaceLane(dstCol, dstPart, PART_FIELD[srcPart], events, startppq, endppq)
    end
    ::nextPart::
  end
  tm:flush()
end

--contract: a clip carrying notes replaces the region's; a lane clip writes into the cursor's lane
-- see docs/editCursor.md § Clipboard: single vs multi
local function pasteSingle(clip)
  local ctx = getCtx()
  local dstCol = grid.cols[ec:col()]
  if not dstCol then return end
  local chan = dstCol.midiChan
  local r = ec:row()
  local startppq = ctx:rowToPPQ(r, chan)
  local endppq = ctx:rowToPPQ(r + clip.numRows, chan)
  local logPerRow = ctx:ppqPerRow()
  if refusePaste(chan, dstCol.type, dstCol.lane, dstCol.cc, r, clip.numRows) then return end

  local events = {}
  for _, ce in ipairs(clip.events) do
    local ppq = (r + ce.row) * logPerRow
    if ctx:rowToPPQ(r + ce.row, chan) >= endppq then goto nextCe end
    local e = util.clone(ce, CLIP_ARTIFACTS)
    e.ppq = ppq
    if ce.endRow then
      -- Author the intent ceiling on endppq; tm stamps endppqL and
      -- re-derives the realised tail every rebuild. util.OPEN = inf
      -- rides through arithmetic and lands back as inf on endppq.
      e.endppq = (r + ce.endRow) * logPerRow
    end
    util.add(events, e)
    ::nextCe::
  end
  table.sort(events, function(a, b) return a.ppq < b.ppq end)

  -- pitch is a note column's first part, so a span covers it only as the
  -- first element of the clip's list.
  if clip.parts[1] == 'pitch' then pasteNotes(dstCol, events, startppq, endppq)
  else                             pasteLanes(clip, dstCol, events, startppq, endppq) end
end

--contract: resolves each clip col against cursor's chan via chanDelta; out-of-range channels and missing destinations skip silently; bails entirely if startType=='note' but cursor isn't on a note col.
local function pasteMulti(clip)
  local ctx = getCtx()
  local cursor = grid.cols[ec:col()]
  if not cursor then return end
  -- Notes need a note-col home; other parts paste wherever, using cursor's
  -- channel as the anchor.
  if clip.startType == 'note' and cursor.type ~= 'note' then return end

  -- Lazy per-chan lookup: notes by lane (dense), cc by number, singletons by type.
  local chanInfo = {}
  local function infoFor(chan)
    local info = chanInfo[chan]
    if info then return info end
    info = { noteCols = {}, ccCols = {}, other = {} }
    local first, last = grid.chanFirstCol[chan], grid.chanLastCol[chan]
    local lane = 0
    for ci = first or 1, last or 0 do
      local col = grid.cols[ci]
      if col.type == 'note' then
        lane = lane + 1
        info.noteCols[lane] = col
      elseif col.type == 'cc' then
        info.ccCols[col.cc] = col
      else
        info.other[col.type] = col
      end
    end
    chanInfo[chan] = info
    return info
  end

  local cursorNotePos = cursor.lane or 0

  local function resolve(clipCol)
    local chan = cursor.midiChan + clipCol.chanDelta
    if chan < 1 or chan > 16 then return end
    local info = infoFor(chan)

    if clipCol.type == 'note' then
      local base = (clipCol.chanDelta == 0 and cursorNotePos > 0) and cursorNotePos or 1
      local lane = base + clipCol.key
      return { type = 'note', chan = chan, lane = lane, col = info.noteCols[lane] }
    elseif clipCol.type == 'cc' then
      return { type = 'cc', chan = chan, ccNum = clipCol.key, col = info.ccCols[clipCol.key] }
    else
      return { type = clipCol.type, chan = chan, col = info.other[clipCol.type] }
    end
  end

  local cRow = ec:row()
  local logPerRow = ctx:ppqPerRow()
  local capRow = cRow + clip.numRows
  -- Gate the whole paste atomically: cross-column cells never share a group
  -- slot, so per-column refusal == aggregate refusal (decision 5).
  for _, clipCol in ipairs(clip.cols) do
    local rr = resolve(clipCol)
    if rr and refusePaste(rr.chan, rr.type, rr.lane, rr.ccNum, cRow, clip.numRows) then return end
  end
  for _, clipCol in ipairs(clip.cols) do
    local r = resolve(clipCol)
    if not r then goto nextCol end
    local dst = r.col
    local startppq = ctx:rowToPPQ(cRow, r.chan)
    local endppq   = ctx:rowToPPQ(capRow, r.chan)

    -- Materialise as in pasteSingle; identity overlaid in the write loop below.
    local events = {}
    for _, ce in ipairs(clipCol.events) do
      local ppq = (cRow + ce.row) * logPerRow
      if ctx:rowToPPQ(cRow + ce.row, r.chan) < endppq then
        local e = util.clone(ce, CLIP_ARTIFACTS)
        e.ppq = ppq
        if ce.endRow then
          -- Author the intent ceiling on endppq; tm stamps endppqL and
          -- re-derives the realised tail every rebuild. util.OPEN = inf
          -- rides through arithmetic and lands back as inf on endppq.
          e.endppq = (cRow + ce.endRow) * logPerRow
        end
        util.add(events, e)
      end
    end
    table.sort(events, function(a, b) return a.ppq < b.ppq end)

    -- Wipe existing events in the paste region. For notes, delete directly
    -- rather than via queueDeleteNotes — its survivor-extension fixup is for
    -- leaving a hole, but we're filling it. No predecessor pre-trim: tm's
    -- universal tail pass clips the prior note's realised tail to the
    -- pasted onset and regrows it if the paste is removed.
    -- Attached PAs cascade-delete with their host note.
    if dst then
      if r.type == 'note' then
        for evt in util.between(dst.events, startppq, endppq, util.isNote) do
          edit.delete(evt)
        end
      else
        for evt in util.between(dst.events, startppq, endppq) do
          edit.delete(evt)
        end
      end
    end

    -- Overlay destination identity onto the materialised clones. No
    -- pre-trim of endppq: it is the authored intent; tm clips the
    -- realised tail against any blocker and regrows it when that goes.
    local rpb = currentRpb()
    for _, e in ipairs(events) do
      e.chan, e.rpb = r.chan, rpb
      if r.type == 'note' then
        e.lane   = r.lane
      elseif r.type == 'cc' then
        e.cc = r.ccNum
      end
      e.evType = r.type
      edit.add(e)
    end
    ::nextCol::
  end
  tm:flush()
end

local function pasteClip(clip)
  if clip.mode == 'single' then pasteSingle(clip)
  else                          pasteMulti(clip) end
  if clip.fxRegions then fx.paste(clip.fxRegions) end
  tm:flush()
end

--contract: mutates clip in place; survives both modes; used by duplicate-up at row 0 to keep selection-following behaviour cumulative
-- A note whose start row falls within the trimmed band is dropped entirely.
local function trimTop(clip, trim)
  local function filter(events)
    local i = 1
    for _, e in ipairs(events) do
      if e.row >= trim then
        e.row = e.row - trim
        if type(e.endRow) == 'number' then e.endRow = e.endRow - trim end
        events[i] = e
        i = i + 1
      end
    end
    for j = #events, i, -1 do events[j] = nil end
  end
  clip.numRows = clip.numRows - trim
  if clip.mode == 'single' then
    filter(clip.events)
  else
    for _, c in ipairs(clip.cols) do filter(c.events) end
  end
  if clip.fxRegions then filter(clip.fxRegions) end
end

---------- PUBLIC

local clipboard = {}
function clipboard:collect()           return collect() end
function clipboard:copy()              local c = collect(); if c then save(c) end end
function clipboard:pasteClip(clip)     pasteClip(clip) end
function clipboard:trimTop(clip, trim) trimTop(clip, trim) end

function clipboard:registerCommands(scope)
  scope:registerAll{
    copy  = function() local c = collect(); if c then save(c) end; ec:selClear() end,
    paste = { function()
      if ec:isSticky() then ec:selClear()
      else local c = load(); if c then pasteClip(c) end
      end
    end, 'Paste' },
  }
end

return clipboard
