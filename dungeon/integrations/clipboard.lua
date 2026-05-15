-- See docs/editCursor.md for the model (clipboard sits with editCursor
-- because the two share the model and the verb vocabulary).

--invariant: clipboard persists via REAPER ExtState under ('rdm','clipboard'), serialised by util.serialise
--invariant: clip rows are 0-relative to the clip's top (row=0 is first row of selection); paste re-bases against current cursor row
--invariant: single vs multi mode is decided by selected-col count: c1==c2 -> single, otherwise multi
--invariant: single.type ∈ { 'note', '7bit', 'pb' } — note/vel split decided at copy by region's part1
--invariant: multi.cols carry chanDelta from leftmost source channel; cursor's channel becomes the leftmost destination
--invariant: CLIP_RESERVED keys are stripped at copy; CLIP_ARTIFACTS (row/endRow) are stripped at paste; everything else (including custom metadata) round-trips
--invariant: velEvent is the only collector that synthesises a clip event rather than cloning the source — vel-mode pastes must not carry note metadata onto cc destinations
local util    = require 'util'
local aliases = require 'aliases'
local tuning  = require 'tuning'

-- Reserved keys never carried verbatim through copy/paste: position is
-- rebuilt from `row` at paste, identity is decided by the destination
-- column, REAPER bookkeeping must not round-trip, and the type tag lives on
-- the clip envelope. Everything else — known fields and any future
-- metadata — rides through. Keep this list small and rule-based; do not
-- allowlist event payload.
local CLIP_RESERVED = {
  -- position (rebuilt from row + cursor)
  ppq = true, endppq = true, ppqL = true, endppqL = true,
  -- destination identity
  chan = true, rpb = true, lane = true, cc = true,
  -- mm/REAPER bookkeeping
  loc = true, idx = true, uuid = true, uuidIdx = true,
  -- envelope-level
  type = true, evType = true,
  -- alias materialisation metadata: a fresh paste gets fresh parentUuid
  -- from the rebuild walker if it's aliased, or none if it isn't.
  -- aliasSrc carries the source identity through the clip; the writer at
  -- paste time decides whether to honour or strip it (alias vs plain mode).
  parentUuid = true,
  -- root-only spec-tree state. A pasted event is never a continuation of the
  -- source root; aliased-mode propagation is handled explicitly via aliasSrc
  -- and the family-paste machinery. aliasCtr is a vestigial counter on test
  -- seeds; strip it at the clip boundary so paste outcomes are clean.
  children = true, aliasCtr = true,
}
-- Clip-only fields stripped before a paste materialises into a write event.
-- aliasSrc rides through to the per-event write site (it carries the source
-- identity needed to encode an alias xform). The plain writer strips it
-- before tm:addEvent; the alias writer consumes it.
local CLIP_ARTIFACTS = { row = true, endRow = true }

local deps = ...

---------- PRIVATE

local ec           = deps.ec
local grid         = deps.grid
local tm           = deps.tm
local cm           = deps.cm
local currentRpb   = deps.currentRpb
local assignTail   = deps.assignTail
local getCtx       = deps.getCtx
local getLength    = deps.getLength
local getAliasMode = deps.getAliasMode or function() return false end

local function save(clip)
  reaper.SetExtState('rdm', 'clipboard', util.serialise(clip), false)
end

local function load()
  local raw = reaper.GetExtState('rdm', 'clipboard')
  if raw == '' then return end
  return util.unserialise(raw)
end

--contract: integer-array specIdx form; nil parent is an ancestor of any non-nil child specIdx. Strict: equal arrays are not ancestors.
local function isStrictAncestor(parent, child)
  if child == nil then return false end
  if parent == nil then return true end
  if #parent >= #child then return false end
  for i = 1, #parent do
    if parent[i] ~= child[i] then return false end
  end
  return true
end

--contract: stamps every aliasSrc with a dense clipId; for each event, records parentClipId (nearest in-clip ancestor) and pathXform (concatenated xforms from family parent down). Paste's aliasWriter consumes both to reattach descendants under their in-clip parent. Always runs — paste-time mode chooses. See docs/aliases.md.
local function resolveAliasFamily(clip)
  local all = {}
  if clip.mode == 'single' then
    for _, e in ipairs(clip.events) do all[#all+1] = e end
  else
    for _, c in ipairs(clip.cols) do
      for _, e in ipairs(c.events) do all[#all+1] = e end
    end
  end
  local n = 0
  for _, e in ipairs(all) do
    if e.aliasSrc then n = n + 1; e.aliasSrc.clipId = n end
  end
  for _, e in ipairs(all) do
    local s = e.aliasSrc
    if s then
      local bestSrc, bestLen = nil, -1
      for _, other in ipairs(all) do
        local o = other.aliasSrc
        if o and other ~= e and o.uuid == s.uuid
           and isStrictAncestor(o.specIdx, s.specIdx) then
          local len = o.specIdx and #o.specIdx or 0
          if len > bestLen then bestSrc, bestLen = o, len end
        end
      end
      if bestSrc then
        s.parentClipId = bestSrc.clipId
        s.pathXform    = tm:pathXform(s.uuid, bestSrc.specIdx, s.specIdx) or {}
      end
    end
  end
end

--contract: nil if the resolved selection is empty; single-col → { mode='single', type, ... }; multi-col → { mode='multi', cols=[...] }. aliasSrc is always captured per event — paste-time mode selects writer. cut follows the same path; deletion-fallback demotes at paste once byUuid fails.
local function collect()
  local ctx = getCtx()
  local r1, r2, c1, c2, part1 = ec:region()
  local numRows  = r2 - r1 + 1
  local logPerRow = ctx:ppqPerRow()

  local function rowOf(p)
    return p / logPerRow - r1
  end

  -- aliasSrc anchors the source in the spec tree; position/chan/lane are
  -- reconstructed at paste from row + destination column. specIdx is the
  -- integer-array spec path, derived live via tm:specPathOf (the field
  -- no longer rides on the materialised event).
  local function aliasSrcOf(evt)
    local chain, idx
    if evt.parentUuid and evt.uuid then
      idx = tm:specPathOf(evt)
      if idx then
        local snap = tm:aliasSrcSnapshot(evt.parentUuid, idx)
        if snap then chain = snap.chain end
      end
    end
    return {
      uuid    = evt.parentUuid or evt.uuid,
      specIdx = idx,
      chain   = chain,
    }
  end

  -- Source duration is structural: endRow always reflects evt.endppq,
  -- regardless of where selection bounds fall. The paste site clips
  -- the materialised note against the next same-column event.
  local function noteEvent(evt)
    local ce = util.clone(evt, CLIP_RESERVED)
    ce.row = rowOf(evt.ppq)
    if util.isNote(evt) then
      ce.endRow = rowOf(evt.endppq)
    end
    ce.aliasSrc = aliasSrcOf(evt)
    return ce
  end

  local function scalarEvent(evt)
    local ce = util.clone(evt, CLIP_RESERVED)
    ce.row = rowOf(evt.ppq)
    ce.aliasSrc = aliasSrcOf(evt)
    return ce
  end

  -- Scalar abstraction over a note: only `val` carries. A clone would
  -- land the source note's pitch/detune onto a CC paste as bogus metadata.
  local function velEvent(evt)
    return { row = rowOf(evt.ppq), val = evt.vel }
  end

  -- Single-column mode
  if c1 == c2 then
    local col = grid.cols[c1]
    if not col then return end
    local startppq, endppq = ctx:rowToPPQ(r1, col.midiChan), ctx:rowToPPQ(r2 + 1, col.midiChan)

    local clipType, events = nil, {}
    local emit
    if col.type == 'note' and part1 == 'pitch' then
      clipType, emit = 'note', noteEvent
    elseif col.type == 'note' and part1 == 'vel' then
      clipType, emit = '7bit', velEvent
    elseif col.type == 'pb' then
      clipType, emit = 'pb',   scalarEvent
    else
      clipType, emit = '7bit', scalarEvent
    end
    for evt in util.between(col.events, startppq, endppq) do
      util.add(events, emit(evt))
    end

    if #events == 0 then return end
    local clip = { mode = 'single', type = clipType, numRows = numRows,
                   events = events }
    resolveAliasFamily(clip)
    return clip
  end

  local cols = {}
  local leftChan
  local notePosByChan = {}
  for col in ec:eachSelectedCol() do
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
  end

  if #cols == 0 then return end
  local clip = { mode = 'multi', numRows = numRows, startType = cols[1].type,
                 cols = cols }
  resolveAliasFamily(clip)
  return clip
end

--contract: carry-forward over note-ons in region (clip val updates currentVel, then writes onto next note-ons); pass 2 may emit PA events on sustain rows when cm.polyAftertouch is set
local function pasteVelocities(events, dstCol, startppq, endppq)
  local last = util.seek(dstCol.events, 'before', startppq)
  local currentVel = last and last.vel or cm:get('defaultVelocity')

  -- Delete existing PA events in the paste region
  for evt in util.between(dstCol.events, startppq, endppq) do
    if evt.type == 'pa' then tm:deleteEvent(evt) end
  end

  -- Pass 1: carry-forward velocities onto note-ons
  local ci = 1
  for evt in util.between(dstCol.events, startppq, endppq) do
    if evt.pitch then
      while ci <= #events and events[ci].ppq <= evt.ppq do
        if events[ci].val > 0 then
          currentVel = util.clamp(events[ci].val, 1, 127)
        end
        ci = ci + 1
      end
      tm:assignEvent(evt, { vel = currentVel })
    end
  end

  -- Pass 2: create PA events for clipboard values landing on sustain rows
  if cm:get('polyAftertouch') then
    for _, ce in ipairs(events) do
      local note = util.seek(dstCol.events, 'before', ce.ppq, util.isNote)
      if note and note.endppq > ce.ppq
        and note.ppq ~= ce.ppq then
        tm:addEvent({
          evType = 'pa',
          ppq = ce.ppq,
          chan = dstCol.midiChan,
          pitch = note.pitch, val = util.clamp(ce.val, 1, 127),
          rpb = currentRpb(),
        })
      end
    end
  end

  tm:flush()
end

-- Writers wrap the per-event write call so paste pipelines stay shape-
-- identical between plain and alias modes (cap, region clear, tail clamp
-- all live in the pipeline). Plain writer strips aliasSrc and calls
-- tm:addEvent. Alias writer routes through writeAsRoot or writeAsFamilyChild
-- depending on whether the event has an in-clip family parent, deferring
-- via `pending` when the parent's outcome isn't yet known. demotedCount
-- tracks alias→plain fallbacks caused by spec-tree mutation between copy
-- and paste — the surprising case that warrants a warning. (A)-class
-- fallbacks (root or spec node simply gone) demote silently. pasteClip
-- resets, runs paste, drains pending, and reads the count.
local demotedCount = 0
local outcomes      -- clipId -> { kind='alias', uuid, specIdx, evt } or { kind='plain', evt }
local pending       -- list of { evtType, e } awaiting their family parent

local function plainWriter(evtType, e)
  e.aliasSrc = nil
  e.evType   = evtType
  tm:addEvent(e)
end

-- Family root or no family relation: today's resolve-and-corrective-delta
-- logic. Returns the outcome so a child in the clip can attach to it.
local function writeAsRoot(evtType, e)
  local src = e.aliasSrc
  e.aliasSrc = nil
  e.evType   = evtType
  if not (src and src.uuid) then
    tm:addEvent(e); return { kind='plain', evt=e }
  end
  local r = tm:resolveAliasSrc(src.uuid, src.specIdx, src.chain, evtType)
  if not r then
    tm:addEvent(e); return { kind='plain', evt=e }
  end
  if r.mismatch then
    demotedCount = demotedCount + 1
    tm:addEvent(e); return { kind='plain', evt=e }
  end
  local liveSrc = r.resolved
  -- alias xform speaks ppqL/durL; translate at the boundary.
  local dst = util.clone(e)
  dst.ppqL = e.ppq
  if evtType == 'note' then
    dst.durL = e.endppq - e.ppq
  end
  -- durL is omitted from the corrective-delta vocabulary: alias
  -- duration is structural (it follows the parent), and fit-clipping
  -- at rebuild handles the visual fit at the paste site.
  -- pitch is special: under a temper, the alias op is a step delta
  -- that absorbs any (pitch, detune) shift; under no temper it is a
  -- MIDI semitone delta. octave is folded into the same step delta.
  local xform = {}
  for f in pairs(aliases.validFields(evtType)) do
    if f ~= 'durL' and f ~= 'pitch' and f ~= 'octave' then
      local d, b = dst[f], liveSrc[f]
      if d ~= nil and b ~= nil and d ~= b then
        xform[f] = {{'add', d - b}}
      end
    end
  end
  if evtType == 'note' then
    local temper = tuning.findTemper(cm:get('temper'), cm:get('tempers'))
    if temper then
      local sD, oD = tuning.midiToStep(temper, dst.pitch,     dst.detune     or 0)
      local sL, oL = tuning.midiToStep(temper, liveSrc.pitch, liveSrc.detune or 0)
      local delta  = (sD + oD * temper.octaveStep)
                   - (sL + oL * temper.octaveStep)
      if delta ~= 0 then xform.pitch = {{'add', delta}} end
    elseif dst.pitch ~= liveSrc.pitch then
      xform.pitch = {{'add', dst.pitch - liveSrc.pitch}}
    end
  end
  local newIdx = tm:createAlias(src.uuid, src.specIdx, xform, nil, true)
  if newIdx then
    return { kind='alias', uuid=src.uuid, specIdx=newIdx, evt=e }
  end
  tm:addEvent(e)
  return { kind='plain', evt=e }
end

--contract: dispatches by family relation. No parentClipId → writeAsRoot (resolve-and-corrective-delta). With parentClipId → tm:createAlias under the parent's recorded outcome (alias → parent's new specIdx; plain → parent's mm uuid post-flush). Defers to `pending` if the parent isn't ready. Outcomes keyed by aliasSrc.clipId. See docs/aliases.md.
local function aliasWriter(evtType, e)
  local src = e.aliasSrc
  local pid = src and src.parentClipId
  if pid then
    local parentRes = outcomes[pid]
    if not parentRes
       or (parentRes.kind == 'plain' and not parentRes.evt.uuid) then
      pending[#pending + 1] = { evtType = evtType, e = e }
      return
    end
    local rootUuid, underIdx
    if parentRes.kind == 'alias' then
      rootUuid, underIdx = parentRes.uuid, parentRes.specIdx
    else
      rootUuid, underIdx = parentRes.evt.uuid, nil
    end
    local newIdx = tm:createAlias(rootUuid, underIdx, src.pathXform or {}, nil, true)
    if newIdx then
      e.aliasSrc = nil
      if src.clipId then
        outcomes[src.clipId] = { kind='alias', uuid=rootUuid, specIdx=newIdx, evt=e }
      end
      return
    end
    pending[#pending + 1] = { evtType = evtType, e = e }
    return
  end
  local res = writeAsRoot(evtType, e)
  if src and src.clipId then outcomes[src.clipId] = res end
end

--contract: dispatches by (clip.type, dstCol.type, cursorPart): note->note(pitch), 7bit->note(vel) via pasteVelocities, pb->pb, 7bit->cc/at/pc; mismatched combos silently no-op. writer is plainWriter or aliasWriter — every paste mode uses the same pipeline (cap, clear, tail clamp); only the per-event write differs.
local function pasteSingle(clip, writer)
  local ctx = getCtx()
  local dstCol = grid.cols[ec:col()]
  if not dstCol then return end
  local chan = dstCol.midiChan
  local r = ec:row()
  local startppq = ctx:rowToPPQ(r, chan)
  local endppq = ctx:rowToPPQ(r + clip.numRows, chan)
  local part = ec:cursorPart()
  local logPerRow = ctx:ppqPerRow()
  local capRow = r + clip.numRows  -- logical row of endppq

  local events = {}
  for _, ce in ipairs(clip.events) do
    local ppq = (r + ce.row) * logPerRow
    if ctx:rowToPPQ(r + ce.row, chan) >= endppq then goto nextCe end
    local e = util.clone(ce, CLIP_ARTIFACTS)
    e.ppq = ppq
    if ce.endRow then
      e.endppq = (r + ce.endRow) * logPerRow
    end
    util.add(events, e)
    ::nextCe::
  end
  table.sort(events, function(a, b) return a.ppq < b.ppq end)

  if clip.type == 'note' and dstCol.type == 'note' and part == 'pitch' then
    local velList = {}
    for evt in util.between(dstCol.events, startppq, endppq) do
      if evt.pitch and evt.vel > 0 then
        util.add(velList, { ppq = evt.ppq, val = evt.vel })
      end
    end
    local last = util.seek(dstCol.events, 'before', startppq)
    local currentVel = last and last.vel or cm:get('defaultVelocity')

    local lastNote = util.seek(dstCol.events, 'before', startppq, util.isNote)
    local nextNote = util.seek(dstCol.events, 'at-or-after', endppq, util.isNote)
    local nextNotePpq = nextNote and nextNote.ppq or getLength()
    local lane = dstCol.lane

    -- Delete in-region events directly: queueDeleteNotes' survivor-extension
    -- fixup is for leaving a hole, but we're filling it. An extended lastNote
    -- would overlap the new notes and force the allocator to spill on rebuild.
    if lastNote and events[1] and lastNote.endppq > events[1].ppq then
      assignTail(lastNote, dstCol.midiChan, events[1].ppq)
    end
    for evt in util.between(dstCol.events, startppq, endppq) do
      tm:deleteEvent(evt)
    end

    local rpb = currentRpb()
    local vi = 1
    for _, e in ipairs(events) do
      while vi <= #velList and velList[vi].ppq <= e.ppq do
        currentVel = util.clamp(velList[vi].val, 1, 127)
        vi = vi + 1
      end
      e.endppq = math.min(e.endppq, nextNotePpq)
      e.chan, e.vel, e.lane, e.rpb = dstCol.midiChan, currentVel, lane, rpb
      writer('note', e)
    end
    tm:flush()
    return
  end

  if clip.type == '7bit' and dstCol.type == 'note' and part == 'vel' then
    pasteVelocities(events, dstCol, startppq, endppq)
    return
  end

  if (clip.type == 'pb' and dstCol.type == 'pb')
  or (clip.type == '7bit' and dstCol.type ~= 'note' and dstCol.type ~= 'pb') then
    for evt in util.between(dstCol.events, startppq, endppq) do
      tm:deleteEvent(evt)
    end

    local rpb = currentRpb()
    for _, e in ipairs(events) do
      e.chan, e.rpb = dstCol.midiChan, rpb
      if dstCol.type == 'cc' then e.cc = dstCol.cc end
      writer(dstCol.type, e)
    end
    tm:flush()
    return
  end
end

--contract: resolves each clip col against cursor's chan via chanDelta; out-of-range channels and missing destinations skip silently; bails entirely if startType=='note' but cursor isn't on a note col. writer is plainWriter or aliasWriter (see pasteSingle).
local function pasteMulti(clip, writer)
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
          e.endppq = (cRow + ce.endRow) * logPerRow
        end
        util.add(events, e)
      end
    end
    table.sort(events, function(a, b) return a.ppq < b.ppq end)

    -- Wipe existing events in the paste region. For notes, delete directly
    -- rather than via queueDeleteNotes — its survivor-extension fixup is for
    -- leaving a hole, but we're filling it. An extended last-survivor would
    -- overlap the new notes and force the allocator to spill on rebuild.
    -- Attached PAs cascade-delete with their host note.
    if dst then
      if r.type == 'note' then
        local last = util.seek(dst.events, 'before', startppq, util.isNote)
        if last and events[1] and last.endppq > events[1].ppq then
          assignTail(last, r.chan, events[1].ppq)
        end
        for evt in util.between(dst.events, startppq, endppq, util.isNote) do
          tm:deleteEvent(evt)
        end
      else
        for evt in util.between(dst.events, startppq, endppq) do
          tm:deleteEvent(evt)
        end
      end
    end

    -- Fit-clip pasted notes against the next same-column event in the
    -- destination. Source duration is preserved unless something stands
    -- in the way; nothing → take length is the upper bound.
    local capPPQ
    if r.type == 'note' and dst then
      local nn = util.seek(dst.events, 'at-or-after', endppq, util.isNote)
      capPPQ = nn and nn.ppq or getLength()
    end

    -- Overlay destination identity onto the materialised clones.
    local rpb = currentRpb()
    for _, e in ipairs(events) do
      e.chan, e.rpb = r.chan, rpb
      if r.type == 'note' then
        e.endppq = math.min(e.endppq, capPPQ)
        e.lane   = r.lane
      elseif r.type == 'cc' then
        e.cc = r.ccNum
      end
      writer(r.type, e)
    end
    ::nextCol::
  end
  tm:flush()
end

local function pasteClip(clip)
  demotedCount = 0
  outcomes, pending = {}, {}
  -- Mode is sampled at paste, not capture: a single clip can paste either
  -- aliased or plain depending on the current vm.aliasMode.
  local writer = getAliasMode() and aliasWriter or plainWriter
  if clip.mode == 'single' then pasteSingle(clip, writer)
  else                          pasteMulti(clip, writer) end
  -- Drain deferred family children. pasteSingle/pasteMulti has flushed,
  -- so any plain demotes have realised mm uuids and any queued spec-tree
  -- mutations from previous-wave parents are visible. Each subsequent
  -- wave starts with a flush so deeper chains (grandchildren whose
  -- parents fired this wave) see the parent's spec node in mm.
  while #pending > 0 do
    local todo = pending; pending = {}
    for _, p in ipairs(todo) do aliasWriter(p.evtType, p.e) end
    if #pending == #todo then break end
    if #pending > 0 then tm:flush() end
  end
  tm:flush()
  if demotedCount > 0 then
    reaper.ShowMessageBox(string.format(
      '%d event(s) pasted as plain — the alias spec tree was edited between copy and paste.',
      demotedCount), 'paste', 0)
  end
end

--contract: mutates clip in place; survives both modes; used by duplicate-up at row 0 to keep selection-following behaviour cumulative
-- A note whose start row falls within the trimmed band is dropped entirely.
local function trimTop(clip, trim)
  local function filter(events)
    local i = 1
    for _, e in ipairs(events) do
      if e.row >= trim then
        e.row = e.row - trim
        if e.endRow then e.endRow = e.endRow - trim end
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
    paste = function()
      if ec:isSticky() then ec:selClear()
      else local c = load(); if c then pasteClip(c) end
      end
    end,
  }
end

return clipboard
