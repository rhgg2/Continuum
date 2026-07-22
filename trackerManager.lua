-- See docs/trackerManager.md for the model.

--invariant: mm holds raw + a ppqL sidecar; columns and the park stash are logical-only (evt.ppq)
--invariant: rebuild reconciles raw ↔ ppqL each pass (docs/timing.md)
--invariant: detune is intent (per-note); pb is realisation (channel-wide stream)
--invariant: only lane-1 notes drive detune realisation
--invariant: pb.val is cents inside um; raw↔cents only at load/flush (rawToCents/centsToRaw)
--invariant: cents window = cm:get('pbRange') * 100 per side
--invariant: absorber pbs absorb lane-1 detune jumps; first onset anchors a pb-active channel
--invariant: pb.derived=='absorber' marks an absorber (cc sidecar) or in-window seat (RAM-only)
--invariant: replace-window seats are markerless; recognized by window, not a derived-tag on wire
--invariant: pa stores aftertouch value in mm cc.vel; cc-routing fields stripped on projection
--invariant: col events sort by logical ppq
--invariant: endppq carries no delay; delay shifts only the note-on
--invariant: 16 channels always present; channels[i] non-nil for i in 1..16 after rebuild

--shape: channel = { chan, columns = { notes, ccs={[ccNum]=col}, [pc], [pb], [at] } }
--shape: column = { events=[evt,...], [cc=ccNum] }  -- events sorted by logical ppq
--shape: noteEvent core = { ppq, endppq, pitch, vel, lane, detune, delay }
--invariant: noteEvent optional: muted, sample, sampleShadowed, <metadata...>
--shape: pbEventCol = { ppq, val=cents-minus-detune, detune, hidden, ... }
--invariant: pbEventCol optional: delay, shape, tension
--invariant: pbEventCol is the col projection; um cache holds raw cents in val
--shape: paEventCol = { evType='pa', ppq, pitch, vel, ... }
--invariant: paEventCol mixes into note column events
--shape: extraColumns[chan] = { notes=count, [pc], [pb], [at], [ccs={[ccNum]=true}] }
--shape: lastMuteSet = { [chan] = true }, pushed by tv via tm:setMutedChannels
--shape: fxParked = one evType-tagged off-take stash for every replace park; each spec is the authored
--shape:   event in the logical frame, minus realisation (delayC/endppqC/realised/derived/frame/cents),
--shape:   so new metadata rides park automatically. Baseline fields per type (raw re-derived on restore):
--shape:   note { evType='note', chan, lane, uuid, ppq, endppq, pitch, vel, detune, delay, sample, [fx] }
--shape:   cc { evType='cc', chan, cc, ppq, val, shape, [tension] }  |  pb { evType='pb', chan, ppq, val (=cents), shape, [tension] }  |  pa { evType='pa', chan, pitch, ppq, vel, [rpb] }
--shape: channels[chan].parked = { { evType='note', chan, uuid, ppq, endppq, endppqC, pitch, vel, detune, sample, delay, lane, [fx] }, ... } -- render-ready off-take replace cells (endppq is the authored ceiling the view edits, endppqC the render clip realiseParked derives)
--shape: channels[chan].parkedCC = { { evType='cc', chan, cc, ppq, val, shape, [tension] }, ... } -- off-take cc-replace render cells
--shape: channels[chan].parkedPb = { { evType='pb', chan, ppq, val (=cents), cents, shape, [tension] }, ... } -- off-take pb-replace render cells
--shape: channels[chan].parkedPA = { { evType='pa', chan, pitch, ppq, vel, [rpb] }, ... } -- off-take PA cells; rebuildPA re-projects them into the host note column
--contract: a discrete-replace kind parks its host: a region parks its covered chord, a note parks itself
--invariant: parked members feed generator + grid only; never sounding (mute fails for CC/PA)

local util    = require 'util'
local timing  = require 'timing'
local tuning  = require 'tuning'
local voicing = require 'voicing'

-- Past this many distinct seeds, whole-channel re-derive beats per-seed bookkeeping; the dirt
-- collapses to the wholesale sentinel. Was intervals.merge's MAX. see design § Retirement of intervals
local WHOLESALE_SEED_CAP = 64
-- Above this many disturbed seeds (dirt + derived fx events) the frontier's per-seed probes cost more
-- than the linear walk's single channel pass, so the tail rebuild routes to linear. see design § The degenerate case gates on seed count
local FRONTIER_SEED_CAP = 16
local generators = require 'generators'
local perf       = require 'perf'

local mm, cm, ds = (...).mm, (...).cm, (...).ds
-- Forced note columns per channel absent an extraColumns entry. Main passes nothing (1: every
-- channel is note-typeable); the pattern editor passes 0 so only channels with data appear.
local defaultNoteCols = (...).defaultNoteCols or 1

local tm = {}
local fire = util.installHooks(tm)

---------- STATE

local channels    = {}
local lastMuteSet = {}
--invariant: staleSwing[chan]=true: resolved swing changed; rebuild rederives raw, clears
local staleSwing  = {}
--invariant: dirtyChans[chan] (seed|true): ccs/fx/park/tails/pbs/pcs re-derive it, else freeze
local dirtyChans   = {}
-- Deep clone of derivationInputs() as of the last rebuild: what the current frame was derived under.
-- bindTake diffs against it, because a rebind can find any of it changed with no signal to hear.
local derivedInputs
-- Rebuilt chans re-read the wire, so muted flags need re-conforming; setMutedChannels consumes.
local muteConform  = {}
-- True only while flush writes the parked stash; suppresses the inline dataChanged
-- rebuild so flush drives the single rebuild (B3 staging, see design/note-macros-v2.md).
local flushingParked = false
-- Set via tm:requestRebuild for geometry-only changes staging no mm ops: forces the flush
-- past its no-op return AND the rebuild past the rebuild(∅) gate, which consumes it.
local rebuildRequested = false
-- Held only across tm:setLength's shrink flush: derivation (tail clip, fx windows, parked
-- realisation) must see the new take end before mm:setLength moves the EOT. see § Length
local pendingLen
-- ppq tolerance for "raw agrees with its logical projection"; absorbs
-- fromLogical rounding slop, shared by the tail pass and rebuild rule.
local EPS         = 1

---------- SHARED HELPERS

local function sortByPPQ(tbl)
  table.sort(tbl, function(a, b) return a.ppq < b.ppq end)
end

-- Total order for the raw working set: raw tick, then logical seat (ppqL, falling back to raw
-- pre-seating), authored-before-generated, lane, then pitch. See docs/decisions.md § 2026-07-18.
local function rawThenLogical(a, b)
  if a.ppq ~= b.ppq then return a.ppq < b.ppq end
  local aL, bL = a.ppqL or a.ppq, b.ppqL or b.ppq
  if aL ~= bL then return aL < bL end
  if (a.derived or false) ~= (b.derived or false) then return not a.derived end
  if (a.lane or 0) ~= (b.lane or 0) then return (a.lane or 0) < (b.lane or 0) end
  return (a.pitch or 0) < (b.pitch or 0)
end

-- Only note columns interleave notes and PAs, which can share an onset: ties order note-before-PA,
-- then pitch, so an equal-onset seat holds across rebuilds. see design/archive/logical-column-order.md
local function noteColumnLess(a, b)
  if a.ppq ~= b.ppq then return a.ppq < b.ppq end
  local aPa, bPa = a.evType == 'pa', b.evType == 'pa'
  if aPa ~= bPa then return bPa end
  return (a.pitch or 0) < (b.pitch or 0)
end

local function sortNoteColumn(tbl) table.sort(tbl, noteColumnLess) end

-- A writer that knows an onset splices its cell at the seat, keeping the lane ordered without a blunt
-- whole-column re-sort downstream. see design/interval-dirt.md § Phase 5.5
local function insertNoteCell(events, cell)
  util.insertSorted(events, cell, noteColumnLess)
end

-- A lane is disordered only when a raw->logical flip crossed two onsets; a cheap scan lets the flip
-- skip re-sorting the common already-ordered lane. see design/interval-dirt.md § Phase 5.5
local function isSorted(events)
  for i = 2, #events do
    if noteColumnLess(events[i], events[i - 1]) then return false end
  end
  return true
end

-- General derivation-dirt spine: any edit/config change re-derives a channel's gated stages.
-- Spurious dirt costs a re-derive; missed dirt writes silent wrong output. see design/archive/dirty-channels.md § Scheme
local function dirtyChan(chan)
  if chan then dirtyChans[chan] = true; return end
  for i = 1, 16 do dirtyChans[i] = true end
end

-- Mid-pass seed append: the region/park reconcile's per-member dirt, after the flush already set the
-- channel. No-op once wholesale; collapses past the cap. see design/interval-dirt.md § phase 5
local function seedDirty(chan, seed)
  local dirt = dirtyChans[chan]
  if dirt == true then return end
  if dirt == nil then dirtyChans[chan] = { seed }; return end
  util.add(dirt, seed)
  if #dirt > WHOLESALE_SEED_CAP then dirtyChans[chan] = true end
end

-- A birth-snapshot seed for a park member, so its dirt reads like verb dirt downstream: parkSeed from a
-- logical park spec (raw derived), rawSeed from an mm-raw event (raw in hand). Mirror um's snapshot.
local function parkSeed(spec, verb)
  return { uuid = spec.uuid, verb = verb, ppq = tm:fromLogical(spec.chan, spec.ppq),
           ppqL = spec.ppq, lane = spec.lane, pitch = spec.pitch, endppqL = spec.endppq }
end
local function rawSeed(evt, verb)
  return { uuid = evt.uuid, verb = verb, ppq = evt.ppq, ppqL = evt.ppqL or evt.ppq,
           evType = evt.evType, cc = evt.cc,
           lane = evt.lane, pitch = evt.pitch, endppqL = evt.endppqL }
end

-- A region edit's real dirt is its members, discovered later by the park reconcile; here we seed one
-- trigger point per changed region so its channel's park scan runs and its fx producer wakes. Diff by
-- uuid against the last rebuild's set (create/remove/move/fx-change). see design/interval-dirt.md § phase 5
local function seedRegionEdit(newRegions)
  if not derivedInputs then dirtyChan(); return end
  local function key(r) return r.uuid or util.key(r.chan, r.startppq, r.endppq) end
  local function trigger(r)
    seedDirty(r.chan, { verb = 'region', ppqL = r.startppq,
                        ppq = tm:fromLogical(r.chan, r.startppq) })
  end
  local old, seen = {}, {}
  for i, r in ipairs(derivedInputs.fxRegions or {}) do old[key(r)] = { region = r, index = i } end
  for i, r in ipairs(newRegions or {}) do
    local k = key(r); seen[k] = true
    local o = old[k]
    if not o then trigger(r)
    elseif o.region.startppq ~= r.startppq or o.region.endppq ~= r.endppq
        or not util.deepEq(o.region.fx, r.fx) then
      trigger(o.region); trigger(r)
    elseif o.index ~= i then
      -- Storage order is derivation input -- lane precedence among overlapping regions follows
      -- the array -- so a pure reorder (lane swap) must dirty too, or rebuild(∅) swallows it.
      trigger(r)
    end
  end
  for k, o in pairs(old) do if not seen[k] then trigger(o.region) end end
end

-- An external/undo fxParked change (not tm's own flush -- that stash write is converged output): seed
-- each added member (newly parked) and removed member (restored). see design/interval-dirt.md § phase 5
local function seedParkedEdit(newParked)
  if not derivedInputs then dirtyChan(); return end
  local function key(m)
    if m.evType == 'note' then return 'note\0' .. tostring(m.uuid) end
    return util.key(m.evType, m.chan, m.cc or 0, m.ppq)
  end
  local old, new = {}, {}
  for _, m in ipairs(derivedInputs.fxParked or {}) do old[key(m)] = m end
  for _, m in ipairs(newParked or {}) do new[key(m)] = m end
  for k, m in pairs(new) do if not old[k] then seedDirty(m.chan, parkSeed(m, 'park')) end end
  for k, m in pairs(old) do if not new[k] then seedDirty(m.chan, parkSeed(m, 'restore')) end end
end

-- Everything the pipeline derives from beyond the take itself. A dormant tracker hears nothing when
-- this changes: an undo rewinds take-scoped ds/cm storage while ps watches only the bound take's
-- slots, and the caches simply refill at the next setContext. So the rebind diffs it instead.
-- see design/archive/incremental-rebuild.md § The take-hash gate
local function derivationInputs()
  return {
    trackerMode  = cm:get('trackerMode'),      swings       = cm:get('swings', { mergeTiers = true }),
    pbRange      = cm:get('pbRange'),          temper       = cm:get('temper'),
    overlapOffset= cm:get('overlapOffset'),
    swing        = ds:get('swing'),            fxRegions    = ds:get('fxRegions'),
    extraColumns = ds:get('extraColumns'),     fxParked     = ds:get('fxParked'),
    prevWindows  = ds:get('prevWindows'),      fxPatterns   = ds:get('fxPatterns'),
  }
end

-- pbRange resolves through cm's 5 tiers -- too costly to re-fetch per pb in the
-- absorber pass. Cache it; rebuild (the cm coherence point) drops the cache.
local pbLimCents
local function pbLim()
  if not pbLimCents then pbLimCents = cm:get('pbRange') * 100 end
  return pbLimCents
end

local function centsToRaw(cents)
  return util.clamp(util.round(cents * 8192 / pbLim()), -8192, 8191)
end

local function isCurved(shape)
  return shape and shape ~= 'step' and shape ~= 'linear'
end

-- CCINTERP is interpolated points per QN; the densify grid wants a tick step.
local function ccGridStep()
  return math.max(1, util.round((mm:resolution() or 960) / mm:ccInterp()))
end

-- Merge macro windows into maximal covered spans (overlap/adjacency joins, gaps split); and pick the
-- macros covering a span. Shared by cc- and pb-augment summation.
local function mergeWindows(bucket)
  local wins = {}
  for _, m in ipairs(bucket) do util.add(wins, { m.window[1], m.window[2] }) end
  table.sort(wins, function(a, b) return a[1] < b[1] end)
  local merged = {}
  for _, w in ipairs(wins) do
    local last = merged[#merged]
    if last and w[1] <= last[2] then last[2] = math.max(last[2], w[2])
    else util.add(merged, { w[1], w[2] }) end
  end
  return merged
end
local function overlapping(bucket, span)
  local out = {}
  for _, m in ipairs(bucket) do
    if m.window[1] < span[2] and m.window[2] > span[1] then util.add(out, m) end
  end
  return out
end

-- Half-open span-set intersection over the continuous gate's merged scopes (nil scope = empty).
local function spanSetIntersects(spans, window)
  for _, span in ipairs(spans or {}) do
    if window[1] < span[2] and window[2] > span[1] then return true end
  end
  return false
end
local function clipToSpanSet(span, spans)
  local clipped = {}
  for _, scope in ipairs(spans or {}) do
    local lo, hi = math.max(span[1], scope[1]), math.min(span[2], scope[2])
    if lo < hi then util.add(clipped, { lo, hi }) end
  end
  return clipped
end
-- Complement of clipToSpanSet within `span` (`spans` sorted and disjoint: mergeWindows output).
local function subtractSpanSet(span, spans)
  local rest, cursor = {}, span[1]
  for _, scope in ipairs(spans or {}) do
    local lo, hi = math.max(span[1], scope[1]), math.min(span[2], scope[2])
    if lo < hi then
      if cursor < lo then util.add(rest, { cursor, lo }) end
      cursor = hi
    end
  end
  if cursor < span[2] then util.add(rest, { cursor, span[2] }) end
  return rest
end

-- Sum a held base curve and N macro curves onto the ccGridStep lattice over span [sL, eL) -- half-open,
-- so eL is never emitted. Macros anchor 0 at their own edges, so disjoint macros still sum correctly.
local function firstAfter(list, target)   -- first index with .ppq > target (binary; list ppq-sorted)
  local lo, hi = 1, #list + 1
  while lo < hi do
    local mid = (lo + hi) // 2
    if list[mid].ppq <= target then lo = mid + 1 else hi = mid end
  end
  return lo
end
local function firstAtOrAfter(list, target)   -- first index with .ppq >= target (binary; list ppq-sorted)
  local lo, hi = 1, #list + 1
  while lo < hi do
    local mid = (lo + hi) // 2
    if list[mid].ppq < target then lo = mid + 1 else hi = mid end
  end
  return lo
end
-- Strict-next non-pa onset after ppq in a ppq-sorted lane column (logical); nil past the last.
local function nextLaneOnset(events, ppq)
  local i = firstAfter(events, ppq)
  while events[i] and events[i].evType == 'pa' do i = i + 1 end
  return events[i] and events[i].ppq
end
-- Onset-membership cover of a ppq-sorted list against disjoint ascending spans: emit each event whose
-- onset falls in [lo, hi). The fx-path rule -- visit window extents, never the whole channel.
local function coverOnsets(events, spans, emit)
  for _, span in ipairs(spans or {}) do
    for i = firstAtOrAfter(events, span[1]), #events do
      local evt = events[i]
      if evt.ppq >= span[2] then break end
      emit(evt)
    end
  end
end

-- Curve value at ppq: held both ways (first value before, last after), shape interp within.
local function evalCurve(curve, ppq)
  if #curve == 0 then return 0 end
  local i = firstAfter(curve, ppq)
  local A, B = curve[i - 1], curve[i]
  if not A then return curve[1].val end
  if not B then return A.val end
  return mm:interpolate(A, B, ppq, 'val')
end

local function sumStreams(base, macros, span, opts)
  local sL, eL = span[1], span[2]
  local grid   = ccGridStep()
  local curves = { base }
  for _, m in ipairs(macros) do util.add(curves, m) end
  local function governingShape(curve, ppq)   -- shape at ppq: bp at-or-before; 'step' at/beyond the ends
    local i = firstAfter(curve, ppq)
    local A, B = curve[i - 1], curve[i]
    if not A or not B then return 'step' end
    return A.shape or 'linear'
  end
  local function sumAt(ppq)
    local v = 0
    for _, c in ipairs(curves) do v = v + evalCurve(c, ppq) end
    if opts.round then v = util.round(v) end
    if opts.lo then v = util.clamp(v, opts.lo, opts.hi) end
    return v
  end

  -- feature points: span ends plus every constituent bp strictly within, deduped and sorted
  local seen, fps = { [sL] = true, [eL] = true }, { sL, eL }
  for _, c in ipairs(curves) do
    for _, bp in ipairs(c) do
      if bp.ppq > sL and bp.ppq < eL and not seen[bp.ppq] then
        seen[bp.ppq] = true; util.add(fps, bp.ppq)
      end
    end
  end
  table.sort(fps)

  -- emit each pair's left point; densify a pair only when some constituent curves through it (linear+linear
  -- and step+step sum exactly at the union, no growth). eL bounds the final pair but is never emitted.
  local pts = {}
  for idx = 1, #fps - 1 do
    local p, q = fps[idx], fps[idx + 1]
    local anyCurved, allStep = false, true
    for _, c in ipairs(curves) do
      local s = governingShape(c, p)
      if isCurved(s) then anyCurved = true end
      if s ~= 'step' then allStep = false end
    end
    util.add(pts, { ppq = p, val = sumAt(p), shape = allStep and 'step' or 'linear' })
    if anyCurved then
      local g = p + grid
      while g < q do
        util.add(pts, { ppq = g, val = sumAt(g), shape = 'linear' })
        g = g + grid
      end
    end
  end
  -- pb-augment closes the span: the terminal eL point re-centres the channel (macros anchor 0 there),
  -- so it must land as a seat -- cc leaves eL to the next window/authored value. see § Continuous pb
  if opts.closed then util.add(pts, { ppq = eL, val = sumAt(eL), shape = 'step' }) end
  return pts
end

local function rawToCents(raw)
  return util.round(raw / 8192 * pbLim())
end

----- Continuous curves (fx chain)

local function negated(pts)
  local out = {}
  for _, point in ipairs(pts) do
    util.add(out, { ppq = point.ppq, val = -point.val, shape = point.shape, tension = point.tension })
  end
  return out
end
local function anyNonZero(curve)
  for _, point in ipairs(curve) do if point.val ~= 0 then return true end end
  return false
end

-- Slice a ppq-keyed base curve to [startL, endL]: entering/closing values at the edges (shape/tension
-- from the governing point so interpolation carries through), authored points strictly within.
local function sliceCurve(base, startL, endL)
  if #base == 0 then return {} end
  local function edge(ppq)
    local govern = base[firstAfter(base, ppq) - 1]
    return { ppq = ppq, val = evalCurve(base, ppq),
             shape = govern and govern.shape or 'step', tension = govern and govern.tension }
  end
  local pts = { edge(startL) }
  for _, point in ipairs(base) do
    if point.ppq > startL and point.ppq < endL then util.add(pts, point) end
  end
  util.add(pts, edge(endL))
  return pts
end

-- Fold records in storage order (later replace wins, painter fold); all-flat -> empty so stale seats sweep.
-- Kept distinct from foldSub: a whole-span replace emits verbatim, no synthetic edge point. see design/note-macros-v2.md § The fx chain
local function foldWhole(covering, span, base, opts)
  local stream, any = base, false
  for _, rec in ipairs(covering) do
    if #rec.curve > 0 then
      any = true
      if rec.mode == 'replace' then
        stream = rec.curve
      else
        stream = sumStreams(stream, { rec.curve, negated(base) }, span, opts)
      end
    end
  end
  if not any and not anyNonZero(base) then return {} end
  return stream
end

-- Boundaries within `span` where the covering set changes: span ends plus every record edge strictly
-- inside. Between consecutive cuts the active set is constant, so foldWhole's fold is exact there.
local function chainCuts(covering, span)
  local seen, cuts = { [span[1]] = true, [span[2]] = true }, { span[1], span[2] }
  for _, rec in ipairs(covering) do
    for _, edge in ipairs({ rec.window[1], rec.window[2] }) do
      if edge > span[1] and edge < span[2] and not seen[edge] then
        seen[edge] = true; util.add(cuts, edge)
      end
    end
  end
  table.sort(cuts)
  return cuts
end

-- Fold the active records over one sub-span [a,b) with a constant active set; half-open unless closing.
-- A curved replace clipped mid-segment re-interpolates from the slice edge (accepted fidelity loss). see design/note-macros-v2.md § The fx chain
local function foldSub(active, a, b, base, closeHere, opts)
  local subOpts = opts
  if not closeHere then subOpts = util.assign({}, opts); subOpts.closed = false end
  local subBase = sliceCurve(base, a, b)
  local stream, streamed, touched = subBase, false, false
  for _, rec in ipairs(active) do
    if #rec.curve > 0 then
      touched = true
      if rec.mode == 'replace' then
        stream, streamed = rec.curve, false
      else
        stream = sumStreams(stream, { rec.curve, negated(subBase) }, { a, b }, subOpts)
        streamed = true
      end
    end
  end
  if streamed then return stream end                       -- sumStreams already emitted [a,b) or [a,b]
  if not touched and not anyNonZero(subBase) then return {} end
  local pts = sliceCurve(stream, a, b)                     -- raw replace curve or held base: clip to [a,b]
  if not closeHere and #pts > 0 then table.remove(pts) end -- half-open: the edge belongs to the next sub-span
  return pts
end

-- Fold parallel chains covering `span` in storage order: whole-span records take the verbatim fast path,
-- otherwise sub-split at record edges so each layer folds only where it applies. see design/note-macros-v2.md § The fx chain
local function foldChains(recs, span, base, opts)
  local covering = overlapping(recs, span)
  if #covering == 1 then return covering[1].curve end
  local cuts = chainCuts(covering, span)
  if #cuts == 2 then return foldWhole(covering, span, base, opts) end
  local out = {}
  for i = 1, #cuts - 1 do
    local a, b = cuts[i], cuts[i + 1]
    local active = {}
    for _, rec in ipairs(covering) do
      if rec.window[1] <= a and rec.window[2] >= b then util.add(active, rec) end
    end
    local closeHere = opts.closed and i == #cuts - 1
    for _, point in ipairs(foldSub(active, a, b, base, closeHere, opts)) do util.add(out, point) end
  end
  return out
end

local function delayToPPQ(delay) return timing.delayToPPQ(delay, mm:resolution()) end

----- Fx expansion helpers

-- Span cover of a sorted list: governing entry at-or-before each span, through its close, admit-filtered.
-- see docs/trackerManager.md § Span-covered fx scans
local function coverInto(list, spans, admit, emit)
  local nextIdx = 1
  for _, span in ipairs(spans) do
    local govern = firstAfter(list, span[1]) - 1
    while govern >= nextIdx and admit and not admit(list[govern]) do govern = govern - 1 end
    local i = math.max(govern, nextIdx)
    while i <= #list do
      local entry = list[i]
      i = i + 1
      if not admit or admit(entry) then
        emit(entry)
        if entry.ppq > span[2] then break end
      end
    end
    nextIdx = i
  end
end

-- Membership is overlap, not storage: one walk feeds generator events + fixed lane occupancy.
-- Cover, not scan: see docs/trackerManager.md § Span-covered fx scans; design/note-macros-v2.md § The anchor generalized
local function eachWindowNote(chan, startL, endL, fn)
  for laneIdx, col in ipairs(channels[chan].columns.notes) do
    -- A lane is monophonic + ppq-sorted, so a note's sounding tail ends at the next note's onset
    -- (or the window): mirror rebuildTails' laneClip so an OPEN ceiling never streams a phantom overlap.
    local events = col.events
    local pending   -- onset awaiting its tail bound (the next onset's ppq, or endL)
    local function sound(nextOn)
      local ceil = (pending.endppq == nil or pending.endppq == util.OPEN) and endL or pending.endppq
      local hi   = math.min(ceil, nextOn)
      if pending.ppq < endL and hi > startL then fn(laneIdx, pending.ppq, hi, pending) end
    end
    local from = firstAfter(events, startL)
    for j = from - 1, 1, -1 do
      if events[j].evType ~= 'pa' then pending = events[j]; break end
    end
    for j = from, #events do
      local evt = events[j]
      if evt.evType ~= 'pa' then
        if pending then sound(evt.ppq) end
        if evt.ppq >= endL then pending = nil; break end
        pending = evt
      end
    end
    if pending then sound(endL) end
  end
end
local function membersOf(chan, startL, endL)
  local out = {}
  eachWindowNote(chan, startL, endL, function(_, lo, hi, evt)
    util.add(out, util.pick(evt, "pitch vel detune", { ppq = lo, endppq = hi }))
  end)
  return out
end
-- cc-family streams a generator reads (notes via membersOf); pb/ccs are absolute curves sliced
-- from the per-chan bases with entering/closing edges. see design/note-macros-v2.md § The fx chain
local function channelStreams(chan, startL, endL, pbBase, ccBases)
  local cols = channels[chan].columns
  local pas, ats = {}, {}
  for _, col in ipairs(cols.notes) do
    for j = firstAtOrAfter(col.events, startL), #col.events do
      local evt = col.events[j]
      if evt.ppq >= endL then break end
      if evt.evType == 'pa' then util.add(pas, { ppq = evt.ppq, pitch = evt.pitch, vel = evt.vel }) end
    end
  end
  local atEvents = cols.at and cols.at.events or {}
  for j = firstAtOrAfter(atEvents, startL), #atEvents do
    local evt = atEvents[j]
    if evt.ppq >= endL then break end
    util.add(ats, { ppq = evt.ppq, val = evt.val })
  end
  -- Generators read these streams in ppq order (lanes interleave via the sort; ats ride their
  -- column's order; bases pre-sorted, slices preserve order). see design/archive/deferred-reindex.md § Phase A
  sortByPPQ(pas)
  local ccs = {}
  for cc, base in pairs(ccBases) do ccs[cc] = sliceCurve(base, startL, endL) end
  return pas, ccs, ats, sliceCurve(pbBase, startL, endL)
end
-- Deterministic allocator: lowest lane free of overlap, authored notes seed occupancy;
-- emission order -> deterministic -> G4-stable. see design/note-macros-v2.md § Generator output
local function allocateRegionLanes(chan, startL, endL, derived, emitted)
  local occupied = {}
  eachWindowNote(chan, startL, endL, function(laneIdx, lo, hi)
    util.bucket(occupied, laneIdx, { lo, hi })
  end)
  -- Already-emitted derived specs occupy too: a parked note host's tiles hold its lane
  -- (the host itself is off-take, so eachWindowNote no longer sees it).
  for _, spec in ipairs(emitted) do
    if spec.ppqL < endL and spec.endppqL > startL then
      util.bucket(occupied, spec.lane, { spec.ppqL, spec.endppqL })
    end
  end
  local function laneFree(lane, lo, hi)
    for _, span in ipairs(occupied[lane] or {}) do
      if lo < span[2] and hi > span[1] then return false end
    end
    return true
  end
  for _, spec in ipairs(derived) do
    local lane = 1
    while not laneFree(lane, spec.ppqL, spec.endppqL) do lane = lane + 1 end
    util.bucket(occupied, lane, { spec.ppqL, spec.endppqL })
    spec.lane = lane
  end
end
local function firstRestOverride(recs)   -- earliest chain's explicit rest override wins
  local rest, best = nil, math.huge
  for _, rec in ipairs(recs) do
    if rec.rest ~= nil and rec.window[1] < best then rest, best = rec.rest, rec.window[1] end
  end
  return rest
end
-- A parked cell as a generator stream note: it sounds to its render clip, never to the authored
-- ceiling on endppq -- the field the view edits. Mirrors membersOf' shape for on-take notes.
local function soundingCell(cell)
  return util.assign(util.clone(cell), { endppq = cell.endppqC })
end

-- A note host (on-take or parked) as a producer: derived notes ride the host's lane/delay/sample.
local function hostProducer(host, windowEnd, lane)
  return { window = { host.ppq, windowEnd }, notes = { host }, fx = host.fx,
           id = host.uuid, lane = lane, delay = host.delay,
           sample = host.sample, delayPpq = delayToPPQ(host.delay) }
end

local function forEachEvent(fn)
  for i=1,16 do
    local channel = channels[i]
    if channel then
      local chan, cols = channel.chan, channel.columns
      for lane, col in ipairs(cols.notes) do
        for _, evt in ipairs(col.events) do
          local isNote = evt.evType ~= 'pa'
          fn(isNote and 'note' or 'pa', evt, chan, isNote, nil, lane)
        end
      end
      for _, t in ipairs{'pb', 'at', 'pc'} do
        if cols[t] then
          for _, evt in ipairs(cols[t].events) do fn(t, evt, chan, false) end
        end
      end
      for ccNum, col in pairs(cols.ccs) do
        for _, evt in ipairs(col.events) do fn('cc', evt, chan, false, ccNum) end
      end
    end
  end
end


----- derived-event reconcile skeleton (R2)
-- Index existing by `key`, keep-on-match, add the rest, remove unkept. The absorber pass is a richer fungible-move variant, inline.
--contract: appends unmatched-existing to sink.del(event), new/made specs to sink.add(spec)
local function reconcileDerived(a)
  local index, kept = {}, {}
  for _, e in ipairs(a.existing) do index[a.key(e)] = e end
  for _, spec in ipairs(a.predicted) do
    local have = index[a.key(spec)]
    if have and (not a.match or a.match(have, spec)) then
      kept[have] = true
      if a.onKeep then a.onKeep(spec, have) end
    else
      a.sink.add(a.make and a.make(spec) or spec)
    end
  end
  for _, e in ipairs(a.existing) do
    if not kept[e] then a.sink.del(e) end
  end
end

----- PC synthesis reconciliation (grouping + lane-winner pre-pass, then the skeleton)

-- Half-open span membership, frame-matched: projected column cells always test logical --
-- projectEvent flips their ppq to ppqL and drops the sidecar; mm-frame records test raw.
local function pcInSpans(spans, ppq, logical)
  for _, s in ipairs(spans) do
    local lo, hi = logical and s.sL or s.sRaw, logical and s.eL or s.eRaw
    if ppq >= lo and ppq < hi then return true end
  end
  return false
end

--contract: synthesised PCs carry derived='pc'; ppqL inherited from winning host-note record
--contract: an existing derived PC matching (ppq, val) is kept, preserving mm-side loc
--contract: appends removals/adds to the sink {del(event), add(spec)}
--contract: if record.key set, marks key.sampleShadowed=true on records lost to lane priority
--contract: spans (from pcSeedSpans) narrow existing to in-span cells; nil = whole channel
--invariant: shadow marking is rebuild-only; flush callers omit key (rebuild reclones lane events)
--invariant: c.pc.events not written here; rebuildPCs splices it from mm after commit
local function reconcilePCsForChan(chan, records, sink, spans)
  local existing = {}
  for _, e in ipairs((channels[chan].columns.pc and channels[chan].columns.pc.events) or {}) do
    if not spans or pcInSpans(spans, e.ppq, true) then util.add(existing, e) end
  end

  local groups = {}
  for _, r in ipairs(records) do util.bucket(groups, r.ppq, r) end

  local winners = {}
  for _, g in pairs(groups) do
    table.sort(g, function(a, b) return a.lane < b.lane end)
    util.add(winners, g[1])
    for i = 2, #g do
      if g[i].key then g[i].key.sampleShadowed = true end
    end
  end

  reconcileDerived{
    existing = existing, predicted = winners, sink = sink,
    key   = function(x) return x.ppq end,
    match = function(have, w) return have.derived and have.val == w.sample end,
    make  = function(w) return { ppq = w.ppq, ppqL = w.ppqL, val = w.sample,
                                 evType = 'pc', chan = chan, derived = 'pc' } end,
  }
end

----- fxNote reconciliation (the PC-synthesis skeleton, note-shaped)

-- Identity is geometry: (host, ppq, endppqL, pitch, vel, detune, sample); stale endppqL still
-- matches (tail-walk-owned realised end stays out). Fields are integer at source (blob codec read).
local function fxKey(spec)
  return util.key(spec.derived, spec.ppq, spec.endppqL or 0,
                  spec.pitch, spec.vel, spec.detune or 0, spec.sample or 0)
end

-- onKeep carries the matched note's mm handle + realised end onto the predicted spec, so a
-- kept fxNote is re-clipped in place by the tail walk rather than re-added.
local function reconcileFx(existing, predicted, sink)
  reconcileDerived{ existing = existing, predicted = predicted, key = fxKey, sink = sink,
    onKeep = function(spec, have)
      spec.uuid, spec.realised, spec.endppq = have.uuid, have.realised, have.endppq
    end }
end

---------- UPDATE MANAGER

local addEvent, assignEvent, deleteEvent, addParked, assignParked, deleteParked,
      flush, reload, idxReconcile, withDeferredSort, clearStaging, absorbReloadDirt,
      stampColEvt, rawNotes, rawPbs, rawIndexFor, resortRawNotes, fxHostsFor,
      colEvtFor do

  ----- State

  local adds = {}
  local assigns = {}
  local deletes = {}
  --shape: seeds[chan] = list of birth-snapshot seeds { uuid, verb, ppq, ppqL, lane, pitch, endppqL, evType, cc, evt }; evt = the snapshotted record itself -- an add's uuid is stamped on it at mm commit, so it late-binds. folded (dedup-by-uuid) into dirtyChans. see design § The model, inverted
  local seeds = {}
  local parkedEdits = {}
  local parkedUuidSeq = 0
  local rawIndex = {}
  local byUuid = {}
  local fxHosts = {}   -- chan -> { uuid = true } for on-take .fx notes; maintained, never rescanned. see design § Phase 5.5
  local dirtyPcChans = {}

  ----- Accessors

  -- Prevailing lane-1 detune at-or-before ppq; flush derives wire-raw = cents + detuneAt(seat).
  -- Full absorber reconciliation is rebuild's absorber pass; um just stages the best-effort value.
  local function laneOne(n) return n.lane == 1 end
  local function detuneAt(chan, P)
    local n = util.seek(rawIndex[chan].notes, 'at-or-before', P, laneOne)
    return (n and n.detune) or 0
  end

  -- The pipeline's raw working set, read in place by the walk and its raw consumers
  -- (filtered at use); entries are live um records. see design/interval-dirt.md § Phase 4.5
  function rawNotes(chan) return rawIndex[chan].notes end
  function rawPbs(chan) return rawIndex[chan].pbs end
  function rawIndexFor(chan) return rawIndex[chan] end   -- the channel's { notes, pbs, pcs, pas, ats, ccs } record; ccs is a { [ccNum] = list } map

  -- The maintained fx-host set for a channel (uuids of on-take .fx notes); computeFxWindows reads it
  -- instead of rescanning columns. see design/interval-dirt.md § Phase 5.5
  function fxHostsFor(chan) return fxHosts[chan] end

  -- Resolve a uuid to its live column cell via the seat stamp (byUuid.colEvt), so the fx-window cache
  -- reseeks a dirty host without a column walk. see docs/trackerManager.md § Fx window cache
  function colEvtFor(uuid) local e = byUuid[uuid]; return e and e.colEvt end

  -- Ownership is intent, so it is tested logically: a PA carries its own seat and reswings from
  -- it, and a raw-frame test would let a delay or a nudge detach one. see docs/trackerManager.md § PA binding
  local function forEachAttachedPA(host, fn)
    local from, to = host.ppqL or host.ppq, host.endppqL or host.endppq
    for _, cc in pairs(byUuid) do
      if cc.evType == 'pa' and cc.chan == host.chan and cc.pitch == host.pitch then
        local seat = cc.ppqL or cc.ppq
        if seat >= from and seat < to then fn(cc) end
      end
    end
  end

  ----- Low-level mutation

  -- rawIndex holds every event per channel, one list per type: notes and pbs flat (all lanes),
  -- pcs/pas/ats flat, ccs bucketed by cc number. Each raw-then-logical sorted; readers filter at use.
  local function rawIndexListFor(evt, chan)
    local ri = rawIndex[chan]
    local t = evt.evType
    if t == 'note' then return ri.notes end
    if t == 'pb' then return ri.pbs end
    if t == 'pc' then return ri.pcs end
    if t == 'pa' then return ri.pas end
    if t == 'at' then return ri.ats end
    if t == 'cc' then
      -- Created on demand so idxReconcile's fast path compares two tables, never nil vs table.
      local bucket = ri.ccs[evt.cc]
      if not bucket then bucket = {}; ri.ccs[evt.cc] = bucket end
      return bucket
    end
  end
  -- fx-host membership rides the index turnover: set on insert of a .fx note, cleared on removal, so
  -- computeFxWindows never rescans columns to find hosts. see design/interval-dirt.md § Phase 5.5
  local function setFxHost(evt)
    if evt.evType ~= 'note' or not evt.uuid then return end
    if evt.fx then
      local set = fxHosts[evt.chan]
      if not set then set = {}; fxHosts[evt.chan] = set end
      set[evt.uuid] = true
    else
      local set = fxHosts[evt.chan]
      if set then set[evt.uuid] = nil end
    end
  end
  local function clearFxHost(evt, chan)
    if evt.evType ~= 'note' or not evt.uuid then return end
    local set = fxHosts[chan or evt.chan]
    if set then set[evt.uuid] = nil end
  end
  -- During a batched reconcile this holds the lists rawIndexInsert touched; the batch
  -- sorts each once at the end instead of re-sorting per insert. nil = sort inline.
  local deferredSort
  local function rawIndexInsert(evt)
    local tbl = rawIndexListFor(evt, evt.chan)
    if not tbl then return end
    util.add(tbl, evt)
    setFxHost(evt)
    if deferredSort then deferredSort[tbl] = true else table.sort(tbl, rawThenLogical) end
  end
  local function rawIndexRemove(evt, chan)
    local tbl = rawIndexListFor(evt, chan or evt.chan)
    if not tbl then return end
    clearFxHost(evt, chan)
    for i, item in ipairs(tbl) do if item == evt then table.remove(tbl, i); return end end
  end

  -- The batching door: rawIndex is um's, so um owns the deferral. Inserts inside fn flag their list;
  -- each is sorted once here. A caller reaching for the flag directly gets a nil it cannot see.
  function withDeferredSort(fn)
    local prev = deferredSort
    deferredSort = {}
    fn()
    for tbl in pairs(deferredSort) do table.sort(tbl, rawThenLogical) end
    deferredSort = prev
  end

  -- The tail walk nudges shared entries' ppq in place -- invisible to idxReconcile's
  -- unchanged-ppq fast path -- and re-trues the lists it stained through this.
  function resortRawNotes(chan) table.sort(rawIndex[chan].notes, rawThenLogical) end

  -- Construct the um-frame index entry for one mm clone and file it into byUuid.
  -- Shared verbatim by full reload and the incremental verbs so both build identical entries.
  local function makeEntry(e)
    local evt
    if e.evType == 'pb' then
      -- Clone (not pick) so arbitrary metadata survives; val reframes raw->cents (um's frame), raw keeps
      -- the wire value for rebuildPbs' delta-gate. cents sidecar is authored logical -- nil for foreign pbs.
      evt = util.clone(e)
      evt.val, evt.raw, evt.realised = rawToCents(e.val), e.val, true
    else
      evt = e
      evt.realised = true
    end
    byUuid[evt.uuid] = evt
    return evt
  end

  -- Refresh an existing entry from mm's fresh clone in place: prev keeps its ppq-sorted
  -- slot in rawIndex, so a same-slot reconcile skips the rawIndexRemove scan, reinsert and sort.
  local umDecor = { realised = true, colEvt = true }   -- um's own fields; mm's clone never carries them
  local function refreshEntry(prev, e)
    for k in pairs(prev) do if e[k] == nil and not umDecor[k] then prev[k] = nil end end
    util.assign(prev, e)
    prev.realised = true
    -- pb reframes val raw->cents and mirrors the wire in raw, matching makeEntry so both doors agree.
    if e.evType == 'pb' then prev.val, prev.raw = rawToCents(e.val), e.val end
  end

  -- Incremental index upkeep for one uuid. rawIndex lists are ppq-sorted and rawIndexListFor ignores
  -- ppq, so refresh in place only at an unchanged ppq. see docs/trackerManager.md § Incremental index reconciliation
  function idxReconcile(uuid)
    if not uuid then return end
    local prev = byUuid[uuid]
    local _, e = mm:byUuid(uuid)
    if e and prev and prev.ppq == e.ppq
       and rawIndexListFor(prev, prev.chan) == rawIndexListFor(e, e.chan) then
      refreshEntry(prev, e)
      return
    end
    byUuid[uuid] = nil
    if prev then rawIndexRemove(prev) end
    if e then
      local entry = makeEntry(e)
      entry.colEvt = prev and prev.colEvt   -- the seat stamp outlives reconciliation; only re-seating replaces it
      rawIndexInsert(entry)
    end
  end

  -- Seat stamp: columns file their live cell on the entry as they seat it, giving raw consumers
  -- the cell without a per-pass column scan. Returns whether the uuid has an entry (mm knows it).
  function stampColEvt(colNote)
    local entry = byUuid[colNote.uuid]
    if entry then entry.colEvt = colNote end
    return entry ~= nil
  end

  -- Absorber derivation inputs: any pb, and lane-1 notes' onset/detune geometry.
  local PB_GEOMETRY = { detune = true, ppq = true, ppqL = true, delay = true, chan = true, lane = true }
  local function pbSource(evt, lane)
    return evt.evType == 'pb' or (evt.evType == 'note' and lane == 1)
  end
  local function assignDirtiesPb(evt, oldLane, update)
    if evt.evType == 'pb' then return true end
    if not pbSource(evt, oldLane) and not pbSource(evt, evt.lane) then return false end
    for key in pairs(update) do
      if PB_GEOMETRY[key] then return true end
    end
    return false
  end

  -- Every low-level verb drops a birth-snapshot seed for the event it touched; flush folds them
  -- into seed-valued dirt (dedup-by-uuid). A dead seed's uuid dangles safely: see docs/trackerManager.md § Interval seeds.
  local function snapshot(evt, verb)
    return { uuid = evt.uuid, verb = verb, ppq = evt.ppq, ppqL = evt.ppqL or evt.ppq,
             lane = evt.lane, pitch = evt.pitch, endppqL = evt.endppqL,
             evType = evt.evType, cc = evt.cc, evt = evt }
  end
  local function seedEvent(evt, verb) util.bucket(seeds, evt.chan, snapshot(evt, verb)) end

  --contract: every staged note (any lane) and pb files into rawIndex; detune reads filter to lane 1
  --contract: caller supplies evt.evType
  local function addLowlevel(evt)
    if pbSource(evt, evt.lane) then dirtyChan(evt.chan) end
    seedEvent(evt, 'add')
    rawIndexInsert(evt)
    util.add(adds, { evt = evt })
  end

  --contract: dedupes by uuid; in-flight assigns to the same event collapse into one mm write
  --invariant: util.REMOVE markers must survive merging
  local function assignLowlevel(evt, update)
    local oldChan, oldLane = evt.chan, evt.lane
    -- A move (onset shifts) is delete-at-old + insert-at-new. Snapshot the vacated slot before the
    -- assign and seed it as the birth; dedup keeps it, byUuid recovers the new position. see design § The model, inverted
    local moved = update.ppq ~= nil or update.ppqL ~= nil or update.delay ~= nil
                  or update.lane ~= nil
    local vacated = moved and snapshot(evt, 'assign') or nil
    util.assign(evt, update)
    if assignDirtiesPb(evt, oldLane, update) then dirtyChan(oldChan); dirtyChan(evt.chan) end
    if vacated then util.bucket(seeds, oldChan, vacated) end
    seedEvent(evt, 'assign')
    -- Keep the index coherent: a chan move migrates the entry between lists; a move in
    -- either frame resorts in place (util.seek and the walk need ascending order).
    local oldList = rawIndexListFor(evt, oldChan)
    local newList = rawIndexListFor(evt, evt.chan)
    if oldList ~= newList then
      rawIndexRemove(evt, oldChan)
      rawIndexInsert(evt)
    elseif (update.ppq ~= nil or update.ppqL ~= nil) and newList then
      table.sort(newList, rawThenLogical)
    end
    -- A pure fx toggle refreshes the entry in place (no list migration), so the turnover hooks miss it.
    if update.fx ~= nil then setFxHost(evt) end
    if not evt.realised then return end
    for _, e in ipairs(assigns) do
      if e.uuid == evt.uuid then
        -- Plain copy, not util.assign: util.assign collapses util.REMOVE → nil-the-key.
        for k, v in pairs(update) do e.update[k] = v end
        return
      end
    end
    util.add(assigns, { uuid = evt.uuid, update = update, evt = evt })
  end

  local function deleteLowlevel(evt)
    if pbSource(evt, evt.lane) then dirtyChan(evt.chan) end
    seedEvent(evt, 'delete')
    -- rawIndexRemove matches by object identity; the PC mutation hook deletes projected column
    -- cells, so resolve the raw record via byUuid first or the index entry strands.
    rawIndexRemove(evt.uuid and byUuid[evt.uuid] or evt)
    if evt.uuid then byUuid[evt.uuid] = nil end

    if evt.realised then
      util.add(deletes, { uuid = evt.uuid, evt = evt })
      for j = #assigns, 1, -1 do
        if assigns[j].uuid == evt.uuid then table.remove(assigns, j) end
      end
    else
      for j = #adds, 1, -1 do
        if adds[j].evt == evt then table.remove(adds, j); break end
      end
    end
  end

  ----- High-level ops

  -- um is a stager: pb authoring writes cents; wire raw is derived at flush (cents + detuneAt seat).
  -- Absorber seating/reseating happens in rebuild's absorber pass from the final note layout.

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

  -- P1/P2 are the new raw span, the one that reaches mm; L1/L2 the new logical span -- the frame
  -- attachment, the translation test and culling all share. see docs/trackerManager.md § PA binding
  local function resizeNote(n, P1, P2, L1, L2)
    local startL, endL = n.ppqL or n.ppq, n.endppqL or n.endppq
    local shiftL = L1 - startL
    -- Equal logical lengths, not equal raw deltas: swing warps both endpoints alike only when the
    -- length is a period multiple. An OPEN endL needs no case -- huge minus either seat is huge.
    if shiftL ~= 0 and L2 - L1 == endL - startL then
      forEachAttachedPA(n, function(evt)
        -- Realise the moved seat, never add the host's raw delta: under swing those disagree, and
        -- the CC walk restamps ppqL from a divergent raw -- overwriting the intent being carried.
        local seat = (evt.ppqL or evt.ppq) + shiftL
        assignLowlevel(evt, { ppq = tm:fromLogical(n.chan, seat), ppqL = seat })
      end)
    else
      local lastPA, lastSeat
      forEachAttachedPA(n, function(evt)
        local seat = evt.ppqL or evt.ppq
        if seat <= L1 or seat >= L2 then
          if seat <= L1 and (not lastPA or seat > lastSeat) then lastPA, lastSeat = evt, seat end
          deleteLowlevel(evt)
        end
      end)
      if lastPA then assignLowlevel(n, { vel = lastPA.vel }) end
    end
    assignLowlevel(n, { ppq = P1, endppq = P2, ppqL = L1, endppqL = L2 })
  end

  --contract: lane/chan changes accepted; rebuild reseats columns via pickStampedLane
  --contract: chan change: rebuild's absorber pass reconciles fakes across both channels
  --contract: ppq/endppq route through resizeNote
  local function assignNote(n, update)
    -- lane/sample/ppq dirty PC priority; update.ppq covers direct + delay edits
    -- (realiseNoteUpdate maps delay→ppq); endppq alone doesn't move the onset, so no dirty.
    if update.sample ~= nil or update.ppq ~= nil or update.lane ~= nil then dirtyPc(n.chan) end
    if update.chan and update.chan ~= n.chan then dirtyPc(n.chan); dirtyPc(update.chan) end

    if update.ppq ~= nil or update.endppq ~= nil then
      resizeNote(n, update.ppq or n.ppq, update.endppq or n.endppq,
                    update.ppqL    ~= nil and update.ppqL    or (n.ppqL    or n.ppq),
                    update.endppqL ~= nil and update.endppqL or (n.endppqL or n.endppq))
      update.ppq, update.endppq, update.ppqL, update.endppqL = nil, nil, nil, nil
    end
    if update.pitch then
      forEachAttachedPA(n, function(e) assignLowlevel(e, { pitch = update.pitch }) end)
    end
    if next(update) then assignLowlevel(n, update) end
  end

  ----- PC reconciliation (trackerMode mutation hook)

  local function reconcilePcs(chan)
    local records = {}
    for _, n in pairs(byUuid) do
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

    reconcilePCsForChan(chan, records, { del = deleteLowlevel, add = addLowlevel })
  end

  local function lookup(evtOrUuid)
    local uuid = type(evtOrUuid) == 'table' and evtOrUuid.uuid or evtOrUuid
    if not uuid then return end
    return byUuid[uuid], uuid
  end

  ----- Public interface

  -- The live column event for a uuid, valid until the next rebuild.
  function tm:byUuid(uuid) return byUuid[uuid] end

  function deleteEvent(evtOrUuid)
    local evt = lookup(evtOrUuid)
    if not evt then return end
    if evt.evType == 'note' then deleteNote(evt)
    else                        deleteLowlevel(evt) end
  end

  -- endppq arrives as authored logical ceiling. OPEN stamps open ceiling + provisional raw note-off
  -- (ppq+1; tail pass derives the real one); finite value stamps logical ceiling and derives raw.
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
    -- A delay clear arrives as util.REMOVE (assign honours it downstream); decode
    -- to 0 here so the onset arithmetic below never sees the sentinel table.
    local newDelay = update.delay == util.REMOVE and 0 or update.delay
    local dOld = delayToPPQ(evt.delay)
    local dNew = delayToPPQ(newDelay ~= nil and newDelay or evt.delay)
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
    -- Clamp staged raw onset ≥ 0 and tail ≤ takeLen so interim mm readers see bounded values.
    -- see docs/trackerManager.md § Staged-update bounds
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

  function assignEvent(evtOrUuid, update)
    local evt = lookup(evtOrUuid)
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
  --contract: um only stages; rebuild absorber pass reconciles seats, recomputes raw vals at flush
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
      -- pb is one value per tick: adopt a pb already at this slot -- including a hidden
      -- absorber seat -- so we never push a rival onto it. see docs/tuning.md § Absorber reconciliation
      local seat = evt.evType == 'pb' and util.seek(rawIndex[evt.chan].pbs, 'at-or-before', evt.ppq)
      if seat and seat.ppq == evt.ppq then
        assignLowlevel(seat, { cents = evt.cents, shape = evt.shape, derived = util.REMOVE })
      else
        addLowlevel(evt)
      end
    end
  end

  ----- Parked staging (B3): logical-only edits to the fx replace off-take.

  -- Edits stage here and ride flush: a parked edit that wrote ds inline would rebuild mid-batch and
  -- discard still-staged mm ops. rebuildRegionPark derives realisation from the spec each pass.

  local function mintParkedUuid()
    parkedUuidSeq = parkedUuidSeq + 1
    return 'fxp-' .. parkedUuidSeq
  end

  function addParked(spec)
    if spec.evType == 'note' and not spec.uuid then spec.uuid = mintParkedUuid() end
    util.add(parkedEdits, { op = 'add', spec = spec })
  end

  function assignParked(evt, update)
    util.add(parkedEdits, { op = 'assign', evt = evt, update = update })
  end

  function deleteParked(evt)
    util.add(parkedEdits, { op = 'delete', evt = evt })
  end

  --contract: notes key by uuid (fxp-N for a window-authored add), other types by (chan, cc, ppq)
  local function findParked(list, ref)
    if ref.evType == 'note' then
      for i, s in ipairs(list) do if s.uuid == ref.uuid then return i end end
    else
      for i, s in ipairs(list) do
        if s.chan == ref.chan and s.cc == ref.cc and s.ppq == ref.ppq then return i end
      end
    end
  end

  -- Apply staged edits to cloned stashes, then write back under flushingParked so the inline
  -- dataChanged rebuild is suppressed (flush drives the one rebuild).
  local function flushParked()
    local parked = util.deepClone(ds:get('fxParked') or {})
    for _, e in ipairs(parkedEdits) do
      local ref  = e.spec or e.evt
      -- flushParked runs before the fold, so feed the seed table (absorbReloadDirt folds it, or the
      -- parked-only path below does); a mid-pass seedDirty here would be overwritten by that fold.
      util.bucket(seeds, ref.chan, parkSeed(ref, e.op))
      if e.op == 'add' then
        util.add(parked, e.spec)
      else
        local i = findParked(parked, ref)
        if i then
          if e.op == 'assign' then util.assign(parked[i], e.update)
          else table.remove(parked, i) end
        end
      end
    end
    parkedEdits = {}
    flushingParked = true
    if not util.deepEq(ds:get('fxParked') or {}, parked) then ds:assign('fxParked', #parked > 0 and parked or util.REMOVE) end
    flushingParked = false
  end

  ----- Flush: commit accumulated ops to mm.

  --contract: no-op if nothing staged
  --contract: commits deletes, then assigns, then adds under one mm:modify
  --contract: pb cents→raw conversion happens here
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
    if #adds == 0 and #assigns == 0 and #deletes == 0 and #parkedEdits == 0
       and not rebuildRequested then return end

    -- Parked edits stage alongside mm ops. Write the stash first (guarded), then let the mm
    -- commit's reload->rebuild pick it up; with no mm ops, drive the one rebuild explicitly.
    local hadMmOps = #adds > 0 or #assigns > 0 or #deletes > 0
    if #parkedEdits > 0 then flushParked() end
    if not hadMmOps then
      absorbReloadDirt({})   -- no mm reload to fold flushParked's seeds; fold them here
      tm:rebuild(false)
      fire('postflush')
      return
    end

    perf.start('flush')

    -- Single scan over all post-flush notes for same-(chan,pitch) MIDI legality: kill verdicts
    -- only -- onsets and tails are the walk's. see docs/trackerManager.md § Flush collision scan
    do
      local byKey = {}
      for _, n in pairs(byUuid) do
        if n.evType == 'note' then util.bucket(byKey, util.key(n.chan, n.pitch), n) end
      end
      for _, o in ipairs(adds) do
        if o.evt.evType == 'note' then util.bucket(byKey, util.key(o.evt.chan, o.evt.pitch), o.evt) end
      end

      -- Kills only: tm separates once, at the walk. Dedup cannot follow it there -- the walk
      -- separates a duplicate instead, and nothing below kills what it split.
      local kills = {}
      for _, group in pairs(byKey) do
        for _, n in ipairs(voicing.resolveGroup(group)) do util.add(kills, n) end
      end
      for _, n in ipairs(kills) do deleteNote(n) end
    end

    local flushAdds, flushAssigns, flushDeletes = adds, assigns, deletes
    adds, assigns, deletes = {}, {}, {}
    perf.count('committed', #flushAdds + #flushAssigns + #flushDeletes)

    -- Same-pitch moves transiently share a seat key. assignNote's guard keeps the index correct in
    -- either order; descending only spares the backstop a scan. see docs/trackerManager.md § Commit ordering
    table.sort(flushAssigns, function(a, b)
      return (a.update.ppq or a.evt.ppq or 0) > (b.update.ppq or b.evt.ppq or 0)
    end)

    -- pb wire conversion at flush: raw = centsToRaw(cents + detuneAt(seat)).
    -- Rebuild's absorber pass refines with the post-walk layout; this is best-effort for the interim.
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

    perf.start('mm')
    mm:modify(function()
      for _, o in ipairs(flushDeletes) do
        mm:delete(o.uuid)
        byUuid[o.uuid] = nil
      end
      for _, o in ipairs(flushAssigns) do
        mm:assign(o.uuid, o.update)
      end
      for _, o in ipairs(flushAdds) do
        local uuid = mm:add(o.evt)
        -- addLowlevel already filed the raw staged object into rawIndex; drop it by identity
        -- and re-file mm's canonical clone so the entry matches reload (cc shape, pb cents).
        if uuid then rawIndexRemove(o.evt); idxReconcile(uuid) end
      end
    end)
    perf.stop('mm')
    perf.stop('flush'); perf.report()
    fire('postflush')
  end

  ----- Init / reload: (re)load local cache from mm.

  -- Rebuild the whole index from mm. Only for genuine loads (init, take swap, external
  -- re-read) where the incremental index is stale; edit rebuilds keep the live index.
  local function loadIndex()
    mm:reindexIfStale()   -- deferred edits may leave mm sparse/unsorted; events() below needs compact+sorted (item 5)
    byUuid = {}
    for i = 1, 16 do rawIndex[i] = { notes = {}, pbs = {}, pcs = {}, pas = {}, ats = {}, ccs = {} }; fxHosts[i] = {} end
    for _, e in mm:events() do
      local evt = makeEntry(e)
      local tbl = rawIndexListFor(evt, evt.chan)
      if tbl then util.add(tbl, evt); setFxHost(evt) end
    end
    -- mm:events() yields each kind ppq-sorted and the per-channel filter preserves that;
    -- one sort per list settles the logical tie-break the incremental path maintains.
    for i = 1, 16 do
      local ri = rawIndex[i]
      table.sort(ri.notes, rawThenLogical)
      table.sort(ri.pbs, rawThenLogical)
      table.sort(ri.pcs, rawThenLogical)
      table.sort(ri.pas, rawThenLogical)
      table.sort(ri.ats, rawThenLogical)
      for _, bucket in pairs(ri.ccs) do table.sort(bucket, rawThenLogical) end
    end
  end

  -- Fold this flush's per-verb seeds into dirtyChans as seed dirt: dedup-by-uuid (seeded
  -- chans), fold-whole (unseeded payload chans). see docs/trackerManager.md § Interval seeds
  function absorbReloadDirt(payloadChans)
    for chan, list in pairs(seeds) do
      local deduped, seen = {}, {}
      for _, s in ipairs(list) do
        if s.uuid == nil or not seen[s.uuid] then
          if s.uuid then seen[s.uuid] = true end
          util.add(deduped, s)
        end
      end
      -- Past the cap the dirt collapses to the whole channel, so the fresh-channel alloc (:3275) and
      -- excise-skip agree with the walk; commit 5 moves the cap to the walk's degenerate threshold.
      dirtyChans[chan] = #deduped > WHOLESALE_SEED_CAP and true or deduped
    end
    for chan in pairs(payloadChans) do
      if not seeds[chan] then dirtyChans[chan] = true end
    end
  end

  -- Drop un-flushed staging: a rebuild must not carry command-path ops across
  -- (matches prior "fresh um per rebuild").
  function clearStaging()
    adds, assigns, deletes = {}, {}, {}
    parkedEdits            = {}
    dirtyPcChans           = {}
    seeds                  = {}
  end

  function reload() clearStaging(); loadIndex() end

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

--contract: reports the pending end while setLength's shrink flush runs; mm's take length otherwise
function tm:length()               return pendingLen or (mm and mm:length()) or 0 end
function tm:resolution()           return mm and mm:resolution() end
function tm:name()                 return mm and mm:name() end
function tm:setName(name)          if mm then mm:setName(name) end end
function tm:timeSigs()             return mm and mm:timeSigs() or {} end
function tm:interpolate(A, B, ppq, field) return mm and mm:interpolate(A, B, ppq, field) end

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
  dirtyChan(chan) -- swing move re-times this chan's derivations (raw reseat + absorber seats); not carried by the mm payload
  if chan then staleSwing[chan] = true; return end
  for i = 1, 16 do staleSwing[i] = true end
end

-- A geometry-only change (a gm region edit staging no mm ops) still needs the grid rebuilt
-- so tv re-tags cellKind. Forces the next flush and rebuild past their no-op gates.
function tm:requestRebuild() rebuildRequested = true end

----- Mutation

function tm:deleteEvent(evt)         deleteEvent(evt)         end
function tm:addEvent(evt)            addEvent(evt)            end
function tm:assignEvent(evt, update) assignEvent(evt, update) end
function tm:addParked(spec)           addParked(spec)           end
function tm:assignParked(evt, update) assignParked(evt, update) end
function tm:deleteParked(evt)         deleteParked(evt)         end
function tm:flush() flush() end

----- Length

-- On shrink, an OPEN ceiling is authored intent, not a casualty of resize: only the realised
-- tail clips to the new end. See docs/trackerManager.md § Length operations for the ordering.
--contract: a util.OPEN ceiling survives a shrink; only its realised tail comes down
function tm:setLength(newPpq)
  if not mm then return end
  local oldPpq = mm:length() or 0
  if newPpq < oldPpq then
    local kills, clamps = {}, {}
    forEachEvent(function(_, evt, _, isNote)
      if evt.ppq >= newPpq then
        util.add(kills, evt)
      elseif isNote and evt.endppq ~= util.OPEN and evt.endppq > newPpq then
        util.add(clamps, evt)
      end
    end)
    for _, evt in ipairs(kills)  do deleteEvent(evt)                       end
    for _, evt in ipairs(clamps) do assignEvent(evt, { endppq = newPpq })  end
    -- mm:setLength runs last, so the take is still long here: pendingLen is what tells the tail
    -- walk the new end. All-16 dirt because any channel may hold an OPEN tail spanning it.
    pendingLen = newPpq
    dirtyChan()
    tm:requestRebuild()   -- an OPEN-only shrink stages no mm ops; flush must rebuild regardless
    flush()
    pendingLen = nil
  end
  if newPpq ~= oldPpq then mm:setLength(newPpq / mm:resolution()) end
end

-- Stretch take to newPpq: logical rows scale by f=newPpq/oldPpq, raw rederived through swing.
-- see docs/trackerManager.md § Length operations
function tm:rescaleLength(newPpq)
  if not mm then return end
  local oldPpq = mm:length() or 0
  if oldPpq <= 0 or newPpq == oldPpq then
    if newPpq ~= oldPpq then mm:setLength(newPpq / mm:resolution()) end
    return
  end
  local f = newPpq / oldPpq

  -- τ maps the column's logical ppq; raw re-derives through swing, and slopeAt scales delays for
  -- local realised stretch. Two passes so all reads are stable.
  local function applyTimeMap(tau, slopeAt)
    local plans = {}
    forEachEvent(function(_, evt, chan, isNote)
      local p = { evt = evt }
      p.newPpqL = tau(evt.ppq)
      p.newPpq  = tm:fromLogical(chan, p.newPpqL)
      if isNote then
        p.newEndppqL = tau(evt.endppq)
        p.newEndppq  = tm:fromLogical(chan, p.newEndppqL)
        if evt.delay and evt.delay ~= 0 then
          p.newDelay = slopeAt(evt.ppq) * evt.delay
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

-- Loop [0, oldPpq) at offsets k·oldPpq to fill newPpq; shrinks fall through to setLength.
-- see docs/trackerManager.md § Length operations
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
        if shift(c, delta) then idxReconcile(mm:add(c)) end
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

--contract: sweeps only chans with a mute delta or rebuild dirt; assign only when n.muted differs
--invariant: lastMuteSet also tags later-added notes (add path stamps muted at insert)
--invariant: PA events ride along in note columns but carry no mute state — skipped
function tm:setMutedChannels(set)
  local prev = lastMuteSet
  lastMuteSet = util.clone(set or {})
  local sweep = muteConform; muteConform = {}
  for chan = 1, 16 do
    if (prev[chan] == true) ~= (lastMuteSet[chan] == true) then sweep[chan] = true end
  end
  for chan in pairs(sweep) do
    local channel = channels[chan]
    local want = lastMuteSet[chan] == true
    for _, col in ipairs(channel and channel.columns.notes or {}) do
      for _, evt in ipairs(col.events) do
        if evt.evType ~= 'pa' and (evt.muted == true) ~= want then
          assignEvent(evt, { muted = want })
        end
      end
    end
  end
  flush()
end

---------- REBUILD

----- Rebuild shared helpers

local function pushNoteCol(channel)
  local notes = channel.columns.notes
  return util.add(notes, { events = {} }), #notes
end

-- Column events keep chan/cc so each event is self-describing (the leaf-edit
-- facade resolves an event's column from its own chan + lane/cc; see trackerView).
local function projectCC(cc, overlay)
  local evt = util.clone(cc)
  evt.realised = true
  if overlay then util.assign(evt, overlay) end
  return evt
end

-- Columns are logical-born: each build site flips its events with this as it seats them; the
-- tail walk re-stamps movers' delayC/endppqC. see docs/trackerManager.md § Rebuild: logical projection
--contract: every column event arrives stamped -- CC walk anchors foreign cc; externals, notes
local function projectEvent(evt, chan)
  if evt.ppqL ~= nil then
    -- delayC: realised-frame delay equivalent. Differs from authored delay when
    -- the unified walk clamped raw against a same-pitch predecessor; renderer cues the give-way.
    if evt.delay ~= nil then
      local baseline = tm:fromLogical(chan, evt.ppqL)
      evt.delayC = util.round(timing.ppqToDelay(evt.ppq - baseline, mm:resolution()))
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
  -- The sidecar rode in on the mm event; drop it, or a stale copy of the frame we just
  -- became would ride out through park / clipboard / gm. mm and um's index keep theirs.
  evt.ppqL, evt.endppqL = nil, nil
end

-- Strict-next per note: first group member with a greater ppq,
-- chord-mates skipped. Precomputed O(n); see docs/trackerManager.md § Rebuild.
local function strictNextMap(groups)
  local nextOf = {}
  for _, g in pairs(groups) do
    for i = #g - 1, 1, -1 do
      nextOf[g[i]] = g[i + 1].ppq > g[i].ppq
                     and g[i + 1] or nextOf[g[i + 1]]
    end
  end
  return nextOf
end

-- Accumulate mm ops, commit once in canonical delete -> assign -> add order; no-op if empty.
local function mmBatch()
  local dels, assigns, adds, lazyAdds = {}, {}, {}, {}
  return {
    del     = function(evt)                util.add(dels, evt) end,
    assign  = function(evt, update)        util.add(assigns, { evt = evt, update = update }) end,
    add     = function(spec)               util.add(adds, spec) end,
    -- addLazy: fn produces its spec at commit, after any post-accumulation mutation it must read.
    addLazy = function(fn)                 util.add(lazyAdds, fn) end,
    commit  = function()
      if #dels + #assigns + #adds + #lazyAdds == 0 then return end
      local touched = {}
      perf.start('batchModify')
      mm:modify(function()
        for _, e in ipairs(dels) do mm:delete(e.uuid); touched[e.uuid] = true end
        for _, a in ipairs(assigns) do
          mm:assign(a.evt.uuid, a.update)
          touched[a.evt.uuid] = true
        end
        for _, s  in ipairs(adds)     do local u = mm:add(s);    if u then touched[u] = true end end
        for _, fn in ipairs(lazyAdds) do local u = mm:add(fn()); if u then touched[u] = true end end
      end)
      perf.stop('batchModify')
      perf.start('batchIdx')
      local n = 0
      withDeferredSort(function()
        for uuid in pairs(touched) do idxReconcile(uuid); n = n + 1 end
      end)
      perf.count('reconciled', n)
      perf.stop('batchIdx')
    end,
  }
end

-- True when raw ppq can't be explained by the logical projection: foreign MIDI (no ppqL) or
-- an external raw edit. staleSwing chans return false -- their divergence is an expected reseat.
local function rawDivergesFromLogical(evt)
  if evt.ppqL == nil      then return true  end
  if staleSwing[evt.chan] then return false end
  local delayPpq = evt.evType == 'note' and delayToPPQ(evt.delay or 0) or 0
  local rawFromLogical = tm:fromLogical(evt.chan, evt.ppqL, delayPpq)
  if evt.ppq == 0 and rawFromLogical < 0 then return false end
  return math.abs(evt.ppq - rawFromLogical) > EPS
end

-- 16 per-channel buckets, all empty; consumers index [chan] directly, so every slot must exist.
local function emptyChans()
  local t = {}
  for i = 1, 16 do t[i] = {} end
  return t
end

----- Rebuild internals

-- (ppqL, lane, pitch) names a seat uniquely -- a lane holds one note per logical row. Delay shifts
-- raw ppq but not ppqL, so the logical seat is the stable key. Shared with the tail walk.
local function seatKey(ppqL, lane, pitch)
  return tostring(ppqL) .. '\0' .. tostring(lane) .. '\0' .. tostring(pitch)
end

-- Seed membership by logical row (snapshot ppqL, plus a survivor's live ppqL byUuid recovers) --
-- same ppqL any lane, so a deleted shadower re-materialises its row. see docs § Interval materialisation
local function seedCovers(seedList)
  if seedList == true then return function() return true end end
  local rows = {}
  for _, s in ipairs(seedList) do
    rows[s.ppqL] = true
    local live = s.uuid and tm:byUuid(s.uuid)
    if live then rows[live.ppqL or live.ppq] = true end
  end
  return function(note) return rows[note.ppqL or note.ppq] or false end
end

-- The seeds' dirty logical rows as a flat list (snapshot ppqL ∪ each survivor's live ppqL) -- the fx
-- producer window query wants a range test where seedCovers wants membership. see design § phase 5
local function seedRowsFor(seedList)
  local rows = {}
  for _, s in ipairs(seedList) do
    util.add(rows, s.ppqL)
    local live = s.uuid and tm:byUuid(s.uuid)
    if live then util.add(rows, live.ppqL or live.ppq) end
  end
  return rows
end
local function windowSeeded(rows, startL, endL)
  for _, row in ipairs(rows) do if row >= startL and row <= endL then return true end end
  return false
end

-- Drop the carried events this pass's clones will replace. PAs go whatever the dirt says:
-- rebuildPA re-projects every PA on a dirty chan, so a carried one would double up.
local function exciseNotes(chan, covers)
  for _, col in ipairs(channels[chan].columns.notes) do
    local kept = {}
    for _, evt in ipairs(col.events) do
      if evt.evType ~= 'pa' and not covers(evt) then
        util.add(kept, evt)
      end
    end
    col.events = kept
  end
end

-- Partition mm notes stamped/external, lay internal columns logical-born, reseat stale-swing.
-- Returns external notes + the per-channel derived-note existing set. see docs/trackerManager.md § Rebuild: partition
--contract: interval dirt: non-derived notes carry ppqL -- an external mutation reloads wholesale
local function rebuildInternals()
  local internal, external = {}, {}
  local noteExisting = emptyChans()
  -- Clean channels carry their columns whole: never visited, so never cloned. Interval-dirty ones
  -- excise the seeded points and re-clone just those; the rest of the column carries untouched.
  for chan = 1, 16 do
    local dirt = dirtyChans[chan]
    if dirt then
      local covers = seedCovers(dirt)
      if dirt ~= true then exciseNotes(chan, covers) end
      for _, raw in mm:notesRaw(chan) do
        -- Derived notes route to fx whole-channel whatever the dirt: a partial noteExisting
        -- reads as mass deletion until the fx reconcile goes interval-native. see design § phase 3
        if raw.derived then
          local note = util.clone(raw, { loc = true }); note.realised = true
          util.add(noteExisting[chan], note)
        elseif covers(raw) then
          local note = util.clone(raw, { loc = true }); note.realised = true
          if rawDivergesFromLogical(note) then util.add(external, note)
          else util.add(internal, note)
          end
        end
      end
    end
  end

  local reseats   = mmBatch()
  local builtCols = {}   -- lanes built by append this pass; ordered once at loop end, splices stay ordered
  -- note is already our own mm:notes() clone -- repurpose it as the column note rather than
  -- cloning again. mm's stored note is untouched.
  for _, note in ipairs(internal) do
    local channel = channels[note.chan]
    local notes = channel.columns.notes
    -- Stamped notes keep their authored lane verbatim (extended if missing);
    -- the tail walk clips tails afterward, so overlap here is never a concern.
    while #notes < note.lane do pushNoteCol(channel) end
    local col = notes[note.lane]
    -- set detune/delay at ingestion to skip defensive guards downstream
    note.detune = note.detune or 0
    note.delay  = note.delay  or 0
    if staleSwing[note.chan] then
      -- Rederive realised onset from logical; endppq is the tail walk's. Reswing can collapse two
      -- distinct-ppqL same-pitch notes onto one raw -- staged to mm; the walk separates it this pass.
      local reswungPpq = tm:fromLogical(note.chan, note.ppqL, delayToPPQ(note.delay))
      if reswungPpq ~= note.ppq then reseats.assign(note, { ppq = reswungPpq }) end
      note.ppq = reswungPpq
    end
    -- Columns are logical-born: every seat projects at ingestion. see design/rebuild-pipeline.md § The frame law
    projectEvent(note, note.chan)
    if dirtyChans[note.chan] ~= true and not staleSwing[note.chan] then
      insertNoteCell(col.events, note)   -- splice into the carried logical lane; stays ordered
    else
      util.add(col.events, note)         -- fresh lane: append in mm raw order, order once below
      builtCols[col] = true
    end
    stampColEvt(note)
  end
  -- Raw and logical onset order diverge under swing or an authored swap; re-sort just the appended
  -- lanes that landed disordered. see design/interval-dirt.md § Phase 5.5
  for col in pairs(builtCols) do
    if not isSorted(col.events) then sortNoteColumn(col.events) end
  end
  reseats.commit()

  return external, noteExisting
end

----- Rebuild CCs

-- Markerless cc-replace fill seats are recognized by window (mirrors pb inSeatWindow). Bounds raw once,
-- half-open like the park's covered(); cc curves carry no terminal-at-end seat, so the open end is safe.
local function rawSpanMap(wins)
  local map = {}
  for _, w in ipairs(wins) do
    local key = w.cc or false   -- pb windows carry no cc; a single false slot holds them
    map[w.chan]      = map[w.chan] or {}
    map[w.chan][key] = map[w.chan][key] or {}
    util.add(map[w.chan][key], { sRaw = tm:fromLogical(w.chan, w.startppq),
                                 eRaw = tm:fromLogical(w.chan, w.endppq),
                                 sL   = w.startppq, eL = w.endppq })
  end
  return map
end

local function inSpan(map, chan, cc, ppq, inclusiveEnd)
  local spans = map[chan] and map[chan][cc or false]
  if spans then
    for _, s in ipairs(spans) do
      local withinEnd = ppq < s.eRaw or (inclusiveEnd and ppq == s.eRaw)
      if ppq >= s.sRaw and withinEnd then return true end
    end
  end
  return false
end

local function ppqLess(a, b) return a.ppq < b.ppq end

-- Clone one covered cc-family event into its column with the CC walk's reconcile + projection, then
-- splice it in ppq-order. Mirror of the walk's per-event body, driven by spliceChannelCCs' row scan.
local function spliceCcCell(live, ccWrites)
  local chan = live.chan
  -- stale-swing implies wholesale, so only the raw-diverges reconcile can fire on the interval path.
  local movedPpqL
  if not live.derived and rawDivergesFromLogical(live) then
    movedPpqL = tm:toLogical(chan, live.ppq)
    ccWrites.assign({ uuid = live.uuid }, { ppqL = movedPpqL })
  end
  local event = util.clone(live)
  event.realised = true
  if movedPpqL then event.ppqL = movedPpqL end
  local channel = channels[chan]
  local col
  if live.evType == 'cc' then
    col = channel.columns.ccs[live.cc] or { cc = live.cc, events = {} }
    channel.columns.ccs[live.cc] = col
  else
    col = channel.columns[live.evType] or { events = {} }
    channel.columns[live.evType] = col
  end
  projectEvent(event, chan)
  util.insertSorted(col.events, event, ppqLess)
  return col
end

-- ccExisting scopes to the seed-touched prev cc windows only (edge-inclusive); clean windows keep their seats untouched, and cc-family carries merge rather than replace.
-- Seeks the maintained um index (current mid-pipeline), not mm. See design/interval-dirt-v2.md § 1, docs/decisions.md § 2026-07-21.
local function buildCcExistingInWindows(chan, fillWin, ccExisting, seedRows)
  local byCc = fillWin[chan]
  if not byCc then return end
  local ccBuckets = rawIndexFor(chan).ccs
  local seen = {}
  for ccNum, spans in pairs(byCc) do
    local list = ccBuckets[ccNum]
    if list then
      for _, span in ipairs(spans) do
        if windowSeeded(seedRows, span.sL, span.eL) then
          for i = firstAtOrAfter(list, span.sRaw), #list do
            local evt = list[i]
            if evt.ppq >= span.eRaw then break end
            if not seen[evt.uuid] then
              seen[evt.uuid] = true
              util.add(ccExisting[chan],
                { ppq = evt.ppq, val = evt.val, shape = evt.shape, tension = evt.tension, cc = evt.cc, uuid = evt.uuid })
            end
          end
        end
      end
    end
  end
end

-- The carried column an (evType, cc) pair names, or nil when nothing is carried there.
local function ccColumnFor(chan, evType, ccNum)
  local cols = channels[chan].columns
  if evType == 'cc' then return cols.ccs[ccNum] end
  return cols[evType]
end

-- Excise one event's carried cell: exact-row binary seek (projection makes cell ppq == ppqL),
-- then uuid-match within the row cluster, so a co-row tenant's cell stands.
local function removeCellFor(col, row, uuid)
  local events = col.events
  local lo, hi = 1, #events + 1
  while lo < hi do
    local mid = (lo + hi) // 2
    if events[mid].ppq < row then lo = mid + 1 else hi = mid end
  end
  while events[lo] and events[lo].ppq == row do
    if events[lo].uuid == uuid then table.remove(events, lo)
    else lo = lo + 1 end
  end
end

-- Interval-dirt cc path: each cc-family seed excises its own cell and re-clones its survivor --
-- O(seeds), no channel scan. see docs/decisions.md § 2026-07-20
local function spliceChannelCCs(chan, seedList, fillWin, ccWrites, ccExisting)
  local seen, touched = {}, {}
  for _, s in ipairs(seedList) do
    local family = s.evType == 'cc' or s.evType == 'at' or s.evType == 'pc'
    local uuid = family and (s.uuid or (s.evt and s.evt.uuid)) or nil
    if uuid and not seen[uuid] then
      seen[uuid] = true
      local seedCol = ccColumnFor(chan, s.evType, s.cc)
      if seedCol then touched[seedCol] = true; removeCellFor(seedCol, s.ppqL, uuid) end
      local _, live = mm:byUuid(uuid)
      if live and live.chan == chan then
        local liveCol = ccColumnFor(chan, live.evType, live.cc)
        if liveCol then touched[liveCol] = true; removeCellFor(liveCol, live.ppqL or live.ppq, uuid) end
        if not (live.evType == 'cc' and inSpan(fillWin, chan, live.cc, live.ppq)) then
          touched[spliceCcCell(live, ccWrites)] = true
        end
      end
    end
  end
  -- tv's cell carry keys on events-table identity (same table => reuse built cells), so a spliced
  -- column must shed its carried table -- exciseNotes' `col.events = kept` is the note-path twin.
  for col in pairs(touched) do col.events = util.clone(col.events) end
  buildCcExistingInWindows(chan, fillWin, ccExisting, seedRowsFor(seedList))
end

-- Wholesale / stale-swing path: re-derive a channel's whole cc/at/pc stream from mm. Verbatim from the
-- pre-splice CC walk; interval dirt takes spliceChannelCCs. see docs/trackerManager.md § Rebuild: CC walk
local function fullRebuildChannelCCs(chan, fillWin, pbFillWin, ccWrites, ccExisting)
  for _, cc in mm:ccsRaw(chan) do
    local uuid = cc.uuid
    -- fx cc event: a markerless seat inside a prev cc window (its authored cc parked), routed out and
    -- reconciled fresh at fx expansion. A removed window's orphans reconcile away there. see § Route-by-window
    if cc.evType == 'cc' and inSpan(fillWin, cc.chan, cc.cc, cc.ppq) then
      util.add(ccExisting[cc.chan],
        { ppq = cc.ppq, val = cc.val, shape = cc.shape, tension = cc.tension, cc = cc.cc, uuid = uuid })
      goto continue
    end

    -- Timing reconcile on the raw (read-only) record; capture what moved for the column clone.
    -- Markerless pb seats in a prior window skip it (inclusive end). see docs/trackerManager.md § Rebuild: CC walk
    local pbSeat = cc.evType == 'pb' and cc.ppqL == nil and inSpan(pbFillWin, cc.chan, nil, cc.ppq, true)
    local movedPpq, movedPpqL
    if not cc.derived and not pbSeat then
      if staleSwing[cc.chan] and cc.ppqL ~= nil then
        local newPpq = tm:fromLogical(cc.chan, cc.ppqL)
        if newPpq ~= cc.ppq then
          ccWrites.assign({ uuid = uuid }, { ppq = newPpq })
          movedPpq = newPpq
        end
      elseif rawDivergesFromLogical(cc) then
        local newPpqL = tm:toLogical(cc.chan, cc.ppq)
        ccWrites.assign({ uuid = uuid }, { ppqL = newPpqL })
        movedPpqL = newPpqL
      end
    end

    -- pb/pa reconcile-only (no column); cc/at/pc clone into their column carrying the reseat.
    if cc.evType == 'cc' or cc.evType == 'at' or cc.evType == 'pc' then
      local event = util.clone(cc, { loc = true })
      event.realised = true
      if movedPpq  then event.ppq  = movedPpq end
      if movedPpqL then event.ppqL = movedPpqL end
      local channel = channels[cc.chan]
      local col
      if cc.evType == 'cc' then
        col = channel.columns.ccs[cc.cc] or { cc = cc.cc, events = {} }
        channel.columns.ccs[cc.cc] = col
      else
        col = channel.columns[cc.evType] or { events = {} }
        channel.columns[cc.evType] = col
      end
      projectEvent(event, cc.chan)
      util.add(col.events, event)
    end
    ::continue::
  end
  -- mm's cc stream is insertion-ordered mid-session (fresh adds append); columns sort by ppq.
  for _, col in pairs(channels[chan].columns.ccs) do sortByPPQ(col.events) end
  for _, key in ipairs{ 'at', 'pc' } do
    if channels[chan].columns[key] then sortByPPQ(channels[chan].columns[key].events) end
  end
end

-- CC walk: build the carrier routing map, reconcile (raw,ppqL), project CCs.
-- Returns a carrier-map persister; run after fx expansion. see docs/trackerManager.md § Rebuild: CC walk
local function rebuildCCs(prevWindows)
  local ccWrites = mmBatch()
  local ccExisting = emptyChans()

  -- Seats are recognized against last rebuild's persisted windows: an on-take cc inside a prev cc window is a
  -- seat; a just-created window's cc still parks, a removed one's orphans reconcile away. see design/note-macros-v2.md § Route-by-window
  local ccWins, pbWins = {}, {}
  for _, w in ipairs(prevWindows or {}) do
    if w.evType == 'cc'     then util.add(ccWins, w)
    elseif w.evType == 'pb' then util.add(pbWins, w) end
  end
  local fillWin, pbFillWin = rawSpanMap(ccWins), rawSpanMap(pbWins)

  -- Clean channels carry their cc/at/pc columns whole: never visited. Interval-dirty ones splice just
  -- the seeded cells (spliceChannelCCs); wholesale/stale-swing chans re-derive the whole stream.
  for chan = 1, 16 do
    local dirt = dirtyChans[chan]
    if dirt then
      if dirt == true then fullRebuildChannelCCs(chan, fillWin, pbFillWin, ccWrites, ccExisting)
      else                 spliceChannelCCs(chan, dirt, fillWin, ccWrites, ccExisting)
      end
    end
  end
  ccWrites.commit()
  return ccExisting
end

----- Rebuild extra columns

-- Reconcile extra columns against the persisted extraColumns spec; grow the spec when a
-- channel already holds more note lanes than recorded.
local function rebuildExtraColumns(extraColumns)
  local extras = extraColumns or {}
  local grew   = false
  for i = 1, 16 do
    local c    = channels[i].columns
    local want = extras[i] or { notes = defaultNoteCols }
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

----- Rebuild externals

-- Lane packing for one externals pass. Overlap tests are realised-time, but columns are logical by
-- now -- so occupancy is um's raw index plus this pass's placements. see docs/trackerManager.md § Rebuild: externals
local function externalLanePacker(external)
  local lenient = cm:get('overlapOffset') * mm:resolution()
  local onsetI  = {}   -- [evt] = intent-frame onset; an event's never moves while the pass runs
  local head    = {}   -- [laneList] = first live index; everything below ends too early to ever overlap

  -- Probes arrive in raw-ppq order but test in the intent frame, so the retirement floor trails the
  -- sweep by the pass's largest delay: monotone without reordering the pack. Diverged notes carry one.
  local maxDelayPpq = 0
  local isExternal  = {}
  for _, note in ipairs(external) do
    maxDelayPpq = math.max(maxDelayPpq, delayToPPQ(note.delay or 0))
    isExternal[note.uuid] = true
  end

  -- Raw occupancy per lane: index entries for the seated internals (reseats committed, onsets current),
  -- joined by placed probes -- externals' staged lanes reach the index only at extWrites.commit().
  local occupancy = {}
  local function laneList(chan, lane)
    local lanes = occupancy[chan]
    if not lanes then
      lanes = {}
      for _, entry in ipairs(rawNotes(chan)) do
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

  local function onsetOf(evt)
    local ppqI = onsetI[evt]
    if not ppqI then
      ppqI        = evt.ppq - delayToPPQ(evt.delay or 0)
      onsetI[evt] = ppqI
    end
    return ppqI
  end

  local function byRawOnset(a, b) return a.ppq < b.ppq end

  --contract: true iff note fits lane: no over-threshold overlap, coincident onset always refuses
  --invariant: overlap threshold: same-pitch 0, cross-pitch lenient; dominated-by≥2 refuses
  --contract: consulted only for unstamped raw probes; stamped notes never reach it
  local function laneAccepts(events, note)
    local floorPpq = note.ppq - maxDelayPpq
    local live     = head[events] or 1
    while live <= #events and events[live].endppq <= floorPpq do live = live + 1 end
    head[events] = live

    local noteppqI    = onsetOf(note)
    local noteEndppqI = note.endppq
    local dominated   = 0
    -- Backwards: a refusal and the dominated tally are both order-free, and a conflicting note is
    -- always a recent one -- so the conflict surfaces at once instead of a column-walk away.
    for i = #events, live, -1 do
      local evt     = events[i]
      local evtppqI = onsetOf(evt)
      if noteppqI == evtppqI then return false end
      if noteppqI < evt.endppq and evtppqI < noteEndppqI then
        local threshold     = (evt.pitch == note.pitch) and 0 or lenient
        local overlapAmount = math.min(evt.endppq, noteEndppqI) - math.max(evtppqI, noteppqI)
        if overlapAmount > threshold then return false end
        dominated = dominated + 1
      end
    end
    return dominated < 2
  end

  --contract: pick a lane for an external (unstamped) probe via accept → sibling → push bump
  --invariant: called up front after internals placed + swing-reseated; tail walk clips tails after
  return function(channel, note)
    -- A mid-list insert can shift a retired entry back past head; harmless -- its end sits below the floor.
    local function claim(col, lane)
      util.insertSorted(laneList(note.chan, lane), note, byRawOnset)
      return col, lane
    end
    local notes = channel.columns.notes
    if note.lane then
      local col = notes[note.lane]
      if col and laneAccepts(laneList(note.chan, note.lane), note) then return claim(col, note.lane) end
      if not col then
        while #notes < note.lane do pushNoteCol(channel) end
        return claim(notes[note.lane], note.lane)
      end
    end
    for i, col in ipairs(notes) do
      if laneAccepts(laneList(note.chan, i), note) then return claim(col, i) end
    end
    return claim(pushNoteCol(channel))
  end
end

-- Reintroduce externals: pack lane, stamp ppqL/endppqL, backfill metadata, project, tag `fixed`;
-- block window + tail passes. see docs/trackerManager.md § Rebuild: externals
local function rebuildExternals(external)
  if #external == 0 then return end

  sortByPPQ(external)
  local packLane    = externalLanePacker(external)
  local extWrites   = mmBatch()
  for _, note in ipairs(external) do
    local delay     = note.delay or 0
    local d         = delayToPPQ(delay)
    local probe     = { chan = note.chan, ppq = note.ppq, endppq = note.endppq,
                        pitch = note.pitch, delay = delay, lane = note.lane }
    local col, lane = packLane(channels[note.chan], probe)
    local update    = {
      ppqL    = tm:toLogical(note.chan, note.ppq - d),
      endppqL = tm:toLogical(note.chan, note.endppq),
    }
    if note.lane   ~= lane then update.lane   = lane   end
    if note.detune == nil  then update.detune = 0      end
    if note.delay  == nil  then update.delay  = 0      end
    local colNote = util.clone(note)
    util.assign(colNote, update)
    colNote.fixed = true
    projectEvent(colNote, note.chan)
    insertNoteCell(col.events, colNote)
    stampColEvt(colNote)
    extWrites.assign(colNote, update)
  end
  extWrites.commit()
end

----- Rebuild region park

local parkedClipEnd = {}   -- uuid -> endppqC (logical); a take-length change arrives as a wholesale
                           -- reload, recomputed there -- no separate length guard (mirrors fxHostWin)

-- Clip each parked member's tail to its render end (ceiling, on-take lane onset, parked-neighbour
-- onset), cached per uuid and dirt-gated -- see docs/trackerManager.md § Region-replace parking
--contract: derives each member's endppqC (the render clip); the authored ceiling on endppq stands
local function realiseParked(chan, members, takeLenL, dirt)
  local seededUuid, seededPpq = {}, {}
  for _, s in ipairs(type(dirt) == 'table' and dirt or {}) do
    if s.uuid then seededUuid[s.uuid] = true end
    if s.ppqL then util.add(seededPpq, s.ppqL) end
  end
  -- member-next map: a parked member bounds another on its lane (both off-take, neither in the column)
  local byLane = {}
  for _, m in ipairs(members) do util.bucket(byLane, m.lane, m) end
  for _, g in pairs(byLane) do sortByPPQ(g) end
  local memberNextOf = strictNextMap(byLane)
  for _, m in ipairs(members) do
    local cached = parkedClipEnd[m.uuid]
    local dirty  = dirt == true or cached == nil or seededUuid[m.uuid]
    if not dirty then
      for _, p in ipairs(seededPpq) do
        if p >= m.ppq and p <= cached then dirty = true; break end
      end
    end
    if dirty then
      local ceil       = (m.endppq == nil or m.endppq == util.OPEN) and takeLenL or m.endppq
      local onTake     = nextLaneOnset(channels[chan].columns.notes[m.lane].events, m.ppq)
      local memberNext = memberNextOf[m]
      m.endppqC = math.max(m.ppq + 1, math.min(ceil,
        onTake or math.huge, memberNext and memberNext.ppq or math.huge, takeLenL))
    else
      m.endppqC = cached
    end
    parkedClipEnd[m.uuid] = m.endppqC
  end
end

-- Park = clone minus the realisation frame, so new authored metadata rides a park/unpark
-- round-trip untouched; restore mirrors it (clone back, re-derive realisation; pb also cents->raw).
local REALISATION = { delayC = true, endppqC = true, realised = true, derived = true, frame = true, cents = true, colEvt = true }
--contract: evt must be logical-frame (a column event); an mm-raw source overrides ppq via `adds`
local function parkSpec(evt, adds) return util.assign(util.clone(evt, REALISATION), adds) end

local function unlink(events, evt)
  for i, e in ipairs(events) do if e == evt then table.remove(events, i); break end end
end

-- Off-take render union: parked specs stay visible in-column as render-ready cells.
local function renderUnion(field, newParked, toCell)
  for chan = 1, 16 do channels[chan][field] = {} end
  for _, spec in ipairs(newParked) do
    util.add(channels[spec.chan][field], toCell(spec))
  end
end

local function persistParked(key, newParked, prior)
  if not util.deepEq(prior or {}, newParked) and mm:take() then
    ds:assign(key, #newParked > 0 and newParked or util.REMOVE)
  end
end

-- Region-replace parking: authored events a replace window covers leave the take;
-- the prior parked set carries still-covered forward, restores the rest. see design/note-macros-v2.md § Generator output

local function rebuildRegionPark(deferred, currentWindows, fxParked, prevWindows, hostWindows)
  local batch = mmBatch()
  -- Restored notes re-enter their columns unrealised (the real mm event lands with the deferred
  -- tail commit); their raw scratch recs return so rebuild can wire each cell post-commit.
  local restoredNotes = {}

  -- One predicate for all passes: spec.fx (note specs only) parks itself; otherwise membership
  -- matches a currentWindows entry. see docs/trackerManager.md § Region-replace parking
  local function covered(spec)
    if spec.fx and generators.parksNotes(spec) then return true end
    for _, w in ipairs(currentWindows) do
      if w.evType == spec.evType and w.chan == spec.chan and w.cc == spec.cc
         and spec.ppq >= w.startppq and spec.ppq < w.endppq then return true end
    end
    return false
  end

  -- Park covered candidates, split the prior set into carry-forward / restore. onPark fires
  -- once per freshly-parked spec, never carried-forward. see docs/trackerManager.md § Rebuild
  local allParked = {}
  local function reconcilePark(scan, prior, onPark)
    local newParked, restores = {}, {}
    for _, carry in ipairs(scan) do
      if covered(carry.spec) then
        if onPark then onPark(carry.spec) end
        util.add(newParked, carry.spec)
        batch.del(carry.evt)
        if carry.events then unlink(carry.events, carry.evt) end
      end
    end
    for _, spec in ipairs(prior) do
      if covered(spec) then util.add(newParked, spec)
      else util.add(restores, spec) end
    end
    for _, spec in ipairs(newParked) do util.add(allParked, spec) end
    return newParked, restores
  end

  -- Notes, ccs and pbs park in one batch -> a single delete-first commit for the whole phase, and
  -- one evType-tagged fxParked stash. Each pass reconciles its own slice of the prior stash.
  local priorByType = {}
  for _, spec in ipairs(fxParked or {}) do util.bucket(priorByType, spec.evType, spec) end

  -- Window extents per target: the fresh note/cc scans visit only these, never the whole channel --
  -- see docs/trackerManager.md § Span-covered fx scans for why the extents are the complete cover set.
  local noteSpans, ccSpans = {}, {}
  do
    local noteWins, ccWins = {}, {}
    for _, w in ipairs(currentWindows) do
      local box = { window = { w.startppq, w.endppq } }
      if     w.evType == 'note' then util.bucket(noteWins, w.chan, box)
      elseif w.evType == 'cc'   then util.bucket(ccWins, util.key(w.chan, w.cc), box) end
    end
    for chan, wins in pairs(noteWins) do noteSpans[chan] = mergeWindows(wins) end
    for key,  wins in pairs(ccWins)   do ccSpans[key]   = mergeWindows(wins) end
  end

  -- Notes: can't mute (note-on/off + CC matching), so a covered authored note leaves the take, fed
  -- by two bounded sources -- see docs/trackerManager.md § Span-covered fx scans for the note-host split.
  do
    local scan, seen = {}, {}
    local function candidate(evt, laneIdx, events)
      if seen[evt] then return end   -- a host under its own region would arrive from both sources
      seen[evt] = true
      util.add(scan, { evt = evt, events = events, spec = parkSpec(evt, { lane = laneIdx }) })
    end
    for chan, spans in pairs(noteSpans) do
      if dirtyChans[chan] then
        for laneIdx, col in ipairs(channels[chan].columns.notes) do
          coverOnsets(col.events, spans, function(evt)
            if evt.evType ~= 'pa' then candidate(evt, laneIdx, col.events) end
          end)
        end
      end
    end
    for host in pairs(hostWindows or {}) do
      if dirtyChans[host.chan] and generators.parksNotes(host) then
        candidate(host, host.lane, channels[host.chan].columns.notes[host.lane].events)
      end
    end

    -- Park removes a blocker; same-lane/pitch neighbours' tails regrow.
    local newParked, restores = reconcilePark(scan, priorByType.note or {},
      function(spec) seedDirty(spec.chan, parkSeed(spec, 'park')) end)

    -- Restores re-enter their columns now (unrealised); the tail walk clips them in place and
    -- the tail walk's commit adds them after the derived deletions.
    for _, spec in ipairs(restores) do
      seedDirty(spec.chan, parkSeed(spec, 'restore'))   -- restored note re-enters columns; the tail walk re-derives it
      local channel = channels[spec.chan]
      while #channel.columns.notes < spec.lane do pushNoteCol(channel) end
      local note = util.clone(spec)   -- the cell is the spec: both are logical (keeps the parked uuid too)
      -- The rec holds the walk's raw frame: endppq stays unset because only the walk can derive it
      -- (the spec's ceiling is logical, landing on endppqL), then rides back to the cell via colEvt.
      local rec = util.pick(note, 'uuid chan pitch lane evType detune sample overlap fixed',
                            { colEvt = note, ppq = tm:fromLogical(spec.chan, note.ppq),
                              ppqL = note.ppq, endppqL = note.endppq })
      util.add(restoredNotes, rec)
      util.add(channel.columns.notes[spec.lane].events, note)
      sortNoteColumn(channel.columns.notes[spec.lane].events)
      -- Lazy: reshaped at commit so it reads the rec's raw ppq/endppq after the tail-walk clip.
      deferred.addLazy(function()
        return util.assign(util.clone(note, { delayC = true, endppqC = true }),
                           { keepUuid = true, ppq = rec.ppq, endppq = rec.endppq,
                             ppqL = rec.ppqL, endppqL = rec.endppqL })
      end)
    end

    -- Off-take membership for the generator + grid: each is a render-ready logical cell
    -- (ppq/endppqC like a projected note); an emptied lane re-extends to keep a column home.
    local takeLen = tm:length()
    renderUnion('parked', newParked, function(spec)
      local channel = channels[spec.chan]
      while #channel.columns.notes < spec.lane do pushNoteCol(channel) end
      return util.assign(util.clone(spec), { endppq = spec.endppq or util.OPEN })
    end)
    for chan = 1, 16 do
      local members = channels[chan].parked
      if #members > 0 then
        -- On-take survivors bound a parked tail on its own lane (rebuildTails' model): the per-member
        -- column seek finds the first note after the region, not just the next parked member.
        realiseParked(chan, members, tm:toLogical(chan, takeLen), dirtyChans[chan])
      end
    end
  end

  -- PA: rides its host note, so it parks exactly when the host does -- off-take (silent), still
  -- shown in the host lane by rebuildPA. Reconciled against the parked-note set. see docs/trackerManager.md § Region-replace parking
  do
    local function hostParked(chan, pitch, ppq)
      for _, cell in ipairs(channels[chan].parked or {}) do
        if cell.pitch == pitch and ppq >= cell.ppq and ppq < cell.endppqC then return true end
      end
      return false
    end

    local newParked, seen = {}, {}
    -- Fresh: an on-take PA whose host just parked leaves the take and stashes. Bounded by each parked
    -- member's raw span (its own PAs), not the channel's cc count. see docs/trackerManager.md § Span-covered fx scans
    for chan = 1, 16 do
      if dirtyChans[chan] then
        local pas = rawIndexFor(chan).pas
        for _, cell in ipairs(channels[chan].parked or {}) do
          local sRaw, eRaw = tm:fromLogical(chan, cell.ppq), tm:fromLogical(chan, cell.endppqC)
          for i = firstAtOrAfter(pas, sRaw), #pas do
            local cc = pas[i]
            if cc.ppq >= eRaw then break end
            if not seen[cc] and hostParked(cc.chan, cc.pitch, cc.ppqL or cc.ppq) then
              seen[cc] = true
              batch.del({ uuid = cc.uuid })
              local spec = parkSpec(cc, { ppq = cc.ppqL or cc.ppq })   -- um index source: evType/chan/pitch/vel/rpb ride, ppq flips logical
              spec.uuid = nil                                           -- restore re-mints the rpb sidecar uuid
              util.add(newParked, spec)
            end
          end
        end
      end
    end
    -- Prior parked PAs: host still parked -> carry; host returned on-take -> restore to the take.
    for _, spec in ipairs(priorByType.pa or {}) do
      if hostParked(spec.chan, spec.pitch, spec.ppq) then
        util.add(newParked, spec)
      else
        seedDirty(spec.chan, parkSeed(spec, 'restore'))
        batch.add(util.assign(util.clone(spec),   -- back to mm: raw onset, logical sidecar
          { ppq = tm:fromLogical(spec.chan, spec.ppq), ppqL = spec.ppq }))
      end
    end
    for _, spec in ipairs(newParked) do util.add(allParked, spec) end

    renderUnion('parkedPA', newParked, util.clone)
  end

  -- CCs: a point event has no tail, so the Pass-A curve stands in on the target lane and
  -- restores add back immediately, seating an unrealised projection for the view.
  do
    local scan = {}
    for chan = 1, 16 do
      if dirtyChans[chan] then
        for cc, col in pairs(channels[chan].columns.ccs) do
          coverOnsets(col.events, ccSpans[util.key(chan, cc)], function(evt)
            util.add(scan, { evt = evt, events = col.events,
              spec = parkSpec(evt, { cc = cc }) })   -- cc pins the column key; evType/chan/ppq ride the event
          end)
        end
      end
    end
    -- The mm-bound restore of a parked spec: raw onset, logical sidecar. Column and render cells
    -- are the spec itself -- already logical.
    local function ccWrite(spec, ppq)
      return util.assign(util.clone(spec), { ppq = ppq, ppqL = spec.ppq })
    end

    local newParked, restores = reconcilePark(scan, priorByType.cc or {})

    -- Seat an unrealised projection so the view shows the restored cc this frame; next rebuild
    -- re-reads the real mm event from the take. The add rides the shared park commit.
    for _, spec in ipairs(restores) do
      local ppq  = tm:fromLogical(spec.chan, spec.ppq)   -- realised onset derived fresh (the stash is logical)
      local cell = ccWrite(spec, ppq)
      -- The fill seat at this ppq stays in ccExisting: rebuildFx's reconcile deletes it by its own
      -- uuid, so a restore needs no del. see docs/trackerManager.md § Region-replace parking
      batch.add(cell)
      local channel = channels[spec.chan]
      local col = channel.columns.ccs[spec.cc]
      if not col then col = { cc = spec.cc, events = {} }; channel.columns.ccs[spec.cc] = col end
      util.add(col.events, util.clone(spec))
      sortByPPQ(col.events)
    end

    -- Render union: the parked authored cc stays the visible surface (the fill is hidden
    -- realisation), so creating a cc-replace region never blanks the lane. Mirrors channels[*].parked.
    renderUnion('parkedCC', newParked, function(spec)
      local ccs = channels[spec.chan].columns.ccs
      ccs[spec.cc] = ccs[spec.cc] or { cc = spec.cc, events = {} }
      return util.clone(spec)
    end)
  end

  -- pb: seats are markerless, so the scan can't run every rebuild -- it diffs current pb windows against
  -- last rebuild's persisted set: a created window parks its authored pbs, a removed one sweeps. see § Route-by-window
  local prevPb, curPb = {}, {}
  for _, w in ipairs(prevWindows or {}) do
    if w.evType == 'pb' then prevPb[util.key(w.chan, w.startppq, w.endppq)] = w end
  end
  for _, w in ipairs(currentWindows) do
    if w.evType == 'pb' then curPb[util.key(w.chan, w.startppq, w.endppq)] = w end
  end
  local pbCreated, pbRemoved = {}, {}
  for k, w in pairs(curPb) do if not prevPb[k] then util.add(pbCreated, w) end end
  for k, w in pairs(prevPb) do if not curPb[k] then util.add(pbRemoved, w) end end
  do
    -- Park (create): only a newly-created window walks mm. `derived` can't spot seats (RAM-only,
    -- lost on take round-trip); region can: a pb inside a *previous* window is a seat, never authored.
    local prevSpans = {}
    for _, win in pairs(prevPb) do
      util.bucket(prevSpans, win.chan,
        { tm:fromLogical(win.chan, win.startppq), tm:fromLogical(win.chan, win.endppq) })
    end
    local function seatByRegion(chan, ppq)
      for _, span in ipairs(prevSpans[chan] or {}) do
        if ppq >= span[1] and ppq <= span[2] then return true end
      end
      return false
    end
    local scan = {}
    for _, win in ipairs(pbCreated) do
      local sRaw, eRaw = tm:fromLogical(win.chan, win.startppq), tm:fromLogical(win.chan, win.endppq)
      local pbs = rawPbs(win.chan)
      for i = firstAtOrAfter(pbs, sRaw), #pbs do
        local cc = pbs[i]
        if cc.ppq > eRaw then break end   -- inclusive upper, as the mm walk was
        if not cc.derived and not seatByRegion(cc.chan, cc.ppq) then
          seedDirty(cc.chan, rawSeed(cc, 'park'))
          -- val: logical cents from the cents sidecar (restore maps back); entry.val is already the
          -- raw-derived cents, the best-effort fallback for a foreign pre-cents pb.
          local spec = parkSpec(cc, { ppq = cc.ppqL or cc.ppq,
                                      val = cc.cents or cc.val })   -- index entry: evType/chan/shape/tension ride; ppq flips logical, cents->val
          util.add(scan, { evt = util.clone(cc, { colEvt = true }), spec = spec })
        end
      end
    end

    local newParked, restores = reconcilePark(scan, priorByType.pb or {})

    -- Restore re-adds to the take; the absorber (later this rebuild) refines the wire raw with
    -- detune and re-shows it. The seed val is detune-free -- the absorber's assign corrects it.
    for _, spec in ipairs(restores) do
      seedDirty(spec.chan, parkSeed(spec, 'restore'))
      batch.add(util.assign(util.clone(spec),
        { ppq = tm:fromLogical(spec.chan, spec.ppq), ppqL = spec.ppq,
          cents = spec.val, val = centsToRaw(spec.val) }))   -- spec.val is cents; the wire wants raw + a cents sidecar
    end

    -- Sweep queue (remove): a removed window's seats orphan (no marker names them) -- delete every pb
    -- in the swept raw span. The authored restored above is an unrealised add, so delete-first order is safe.
    for _, win in ipairs(pbRemoved) do
      local sRaw, eRaw = tm:fromLogical(win.chan, win.startppq), tm:fromLogical(win.chan, win.endppq)
      local pbs = rawPbs(win.chan)
      for i = firstAtOrAfter(pbs, sRaw), #pbs do
        local cc = pbs[i]
        if cc.ppq > eRaw then break end   -- inclusive upper, as the mm walk was
        seedDirty(cc.chan, rawSeed(cc, 'delete'))
        batch.del({ uuid = cc.uuid })
      end
    end

    -- Render union for the view: the authored breakpoints stay visible in-column though off-take.
    renderUnion('parkedPb', newParked, function(spec)
      return util.assign(util.clone(spec), { cents = spec.val })
    end)
  end

  persistParked('fxParked', allParked, fxParked)
  batch.commit()
  return restoredNotes
end

----- Raw working set

-- The pass's raw note view is um's index, read in place (entries are live um records, colEvt
-- their seat stamp), filtered at use to authored, logically seated notes. see design/interval-dirt.md § Phase 4.5
local function walkable(note) return not note.derived and note.ppqL ~= nil end

-- One-pass merge of the pre-sorted index list (filtered) with a small sorted extras list;
-- replaces the whole-channel sort the per-pass scratch copy used to force.
local function mergeIndexed(indexNotes, keep, extras)
  table.sort(extras, rawThenLogical)
  local merged, j = {}, 1
  for _, entry in ipairs(indexNotes) do
    if keep(entry) then
      while extras[j] and rawThenLogical(extras[j], entry) do
        util.add(merged, extras[j]); j = j + 1
      end
      util.add(merged, entry)
    end
  end
  for i = j, #extras do util.add(merged, extras[i]) end
  return merged
end

----- Rebuild PA

local function findNoteColumnForPitch(channel, pitch, ppq_pos)
  local notes = channel.columns.notes
  -- Containment is raw geometry: scan the index; lowest lane wins, matching column order.
  -- Pre-commit restores can't match -- their endppq is nil until the walk derives it.
  local coveringLane
  for _, rec in ipairs(rawNotes(channel.chan)) do
    if walkable(rec) and rec.endppq and rec.pitch == pitch and rec.ppq <= ppq_pos
       and rec.endppq > ppq_pos and (coveringLane == nil or rec.lane < coveringLane) then
      coveringLane = rec.lane
    end
  end
  if coveringLane then return notes[coveringLane], coveringLane end
  -- Parked note hosts left the take (off-take, silent); their PAs park with them but stay
  -- shown here, anchored to the host's lane -- rebuildPA re-projects them off-take.
  for _, cell in ipairs(channel.parked or {}) do
    if cell.pitch == pitch and tm:fromLogical(channel.chan, cell.ppq) <= ppq_pos
       and tm:fromLogical(channel.chan, cell.endppqC) > ppq_pos then
      return notes[cell.lane], cell.lane
    end
  end
  -- Pitch-only fallback: frame-agnostic, so the columns serve it (projected PAs included).
  for laneIdx, col in ipairs(notes) do
    for _, evt in ipairs(col.events) do
      if evt.pitch == pitch then return col, laneIdx end
    end
  end
end

-- Late PA projection: mixes into note columns once lanes are settled, so the view (and rebuildFx's
-- channelStreams) read it inline. see docs/trackerManager.md § PA dispatch
local function rebuildPA()
  local touched = {}
  for chan = 1, 16 do
    if dirtyChans[chan] then   -- clean: PA already sits in the carried note column
      for _, cc in ipairs(rawIndexFor(chan).pas) do
        local noteCol, lane = findNoteColumnForPitch(channels[chan], cc.pitch, cc.ppq)
        if noteCol then
          local cell = projectCC(cc, { lane = lane })
          projectEvent(cell, chan)
          insertNoteCell(noteCol.events, cell)
          touched[chan] = true
        end
      end
    end
  end

  -- Parked PAs left the take (off-take, silent) but still ride their host's note column --
  -- projected unrealised into the parked host's lane. see docs/trackerManager.md § PA dispatch
  for chan = 1, 16 do
    if dirtyChans[chan] then
      for _, cell in ipairs(channels[chan].parkedPA or {}) do
        local ppq = tm:fromLogical(chan, cell.ppq)   -- raw: findNoteColumnForPitch is raw geometry
        local noteCol, lane = findNoteColumnForPitch(channels[chan], cell.pitch, ppq)
        if noteCol then
          insertNoteCell(noteCol.events, projectCC(cell, {lane = lane}))   -- the cell is logical-born
          touched[chan] = true
        end
      end
    end
  end
  return touched
end

----- Rebuild Fx

-- Note-host fx windows: authored/take ceiling clipped to strict-next same-lane onset, cached per
-- uuid (fxHostWin), dirt-gated. see docs/trackerManager.md § Fx window cache
local fxHostWin = {}   -- uuid -> windowEndL (logical); a take-length change arrives as a wholesale reload
                       -- (mm:setLength), which walkChannel recomputes -- no separate length guard needed

-- One host cell's window end: authored (or take-end) ceiling, clipped to its strict-next lane onset.
local function hostWindowEnd(cell, takeLenL)
  local ceil = (cell.endppq == nil or cell.endppq == util.OPEN) and takeLenL or math.min(cell.endppq, takeLenL)
  local succ = nextLaneOnset(channels[cell.chan].columns.notes[cell.lane].events, cell.ppq)
  return succ and math.min(ceil, succ) or ceil
end

local function computeFxWindows(extraFxChans)
  local takeLen = tm:length()
  local fxWindow = {}

  -- Column walk: full recompute for wholesale-dirty channels and restored (not-yet-stamped) hosts.
  -- Take-length changes land here too via mm:setLength's wholesale reload. see docs/trackerManager.md
  local function walkChannel(chan, takeLenL)
    local hosts = {}
    for _, col in ipairs(channels[chan].columns.notes) do
      -- Chord-mates share an onset and a successor: hold each host open until a later onset, then clip all.
      local openHosts = {}
      for _, evt in ipairs(col.events) do
        if evt.evType ~= 'pa' then
          if openHosts[1] and evt.ppq > openHosts[1].ppq then
            for _, h in ipairs(openHosts) do fxWindow[h] = math.min(fxWindow[h], evt.ppq) end
            openHosts = {}
          end
          if evt.fx then
            fxWindow[evt] = (evt.endppq == nil or evt.endppq == util.OPEN) and takeLenL or math.min(evt.endppq, takeLenL)
            util.add(openHosts, evt); util.add(hosts, evt)
          end
        end
      end
    end
    for _, h in ipairs(hosts) do fxHostWin[h.uuid] = fxWindow[h] end
  end

  -- Per-host reuse/reseek: recomputes a host only when its own uuid seeded or a seed ppq fell in its
  -- cached span; else the cached end rides. Returns false on an unstamped host to fall to walkChannel.
  local function perHost(chan, takeLenL, dirt)
    local seededUuid, seededPpq = {}, {}
    for _, s in ipairs(dirt or {}) do
      if s.uuid then seededUuid[s.uuid] = true end
      if s.ppqL then util.add(seededPpq, s.ppqL) end
    end
    for uuid in pairs(fxHostsFor(chan)) do
      local cell = colEvtFor(uuid)
      if not cell then return false end
      local cached = fxHostWin[uuid]
      local dirty = cached == nil or seededUuid[uuid]
      if not dirty then
        for _, p in ipairs(seededPpq) do
          if p >= cell.ppq and p <= cached then dirty = true; break end
        end
      end
      local windowEnd = dirty and hostWindowEnd(cell, takeLenL) or cached
      fxHostWin[uuid] = windowEnd
      fxWindow[cell]  = windowEnd
    end
    return true
  end

  for chan = 1, 16 do
    local takeLenL = tm:toLogical(chan, takeLen)
    local hosts    = fxHostsFor(chan)
    local hasHosts = hosts and next(hosts)
    local dirt     = dirtyChans[chan]
    local isExtra  = extraFxChans and extraFxChans[chan]
    if isExtra or dirt == true then
      if hasHosts or isExtra then walkChannel(chan, takeLenL) end
    elseif hasHosts then
      if not perHost(chan, takeLenL, type(dirt) == 'table' and dirt or nil) then
        walkChannel(chan, takeLenL)
      end
    end
  end
  return fxWindow
end

-- Fx expansion: fx-carrying notes / fx-regions -> derived notes, CCs;
-- reconcile vs existing, note writes deferred to the tail walk. see design/note-macros-v2.md § Offline continuous realisation
local function rebuildFx(noteExisting, ccExisting, deferred, fxWindow, currentWindows, fxRegions)
  -- Columns must be ppq-ordered here (eachWindowNote / allocateRegionLanes / membersOf read col.events
  -- directly); the writers seat in order and nothing since reorders. see docs/decisions.md § 2026-07-19

  -- fxWindow's keys are exactly the non-pa fx cells (computeFxWindows emitted them, on-take + restored);
  -- bucket by channel, (lane, ppq)-sorted, so expandChannel reads producers instead of rescanning columns.
  local fxHostsByChan = {}
  for host in pairs(fxWindow) do
    local bucket = fxHostsByChan[host.chan]
    if not bucket then bucket = {}; fxHostsByChan[host.chan] = bucket end
    util.add(bucket, host)
  end
  for _, bucket in pairs(fxHostsByChan) do
    table.sort(bucket, function(a, b)
      if a.lane ~= b.lane then return a.lane < b.lane end
      return a.ppq < b.ppq
    end)
  end

  -- Region note-park windows: a parked cell inside one is region membership, not a note host.
  local function noteParkCovered(chan, ppq)
    for _, win in ipairs(currentWindows) do
      if win.evType == 'note' and win.chan == chan and ppq >= win.startppq and ppq < win.endppq then
        return true
      end
    end
    return false
  end

  -- Absolute authored bases per channel (ppq-keyed, logical), covering only the caller's spans.
  -- see docs/trackerManager.md § Span-covered fx scans
  local function pbBaseFor(chan, spans)
    local base, seen = {}, {}
    for _, cell in ipairs(channels[chan].parkedPb or {}) do
      util.add(base, { ppq = cell.ppq, val = cell.cents, shape = cell.shape or 'step', tension = cell.tension })
      seen[cell.ppq] = true
    end
    -- The maintained pb index is raw-sorted; pbs carry no delay and swing is monotone, so the raw
    -- cover is the logical cover. Authored = the cents sidecar (seats and foreign pbs carry none).
    local rawSpans = {}
    for _, span in ipairs(spans) do
      util.add(rawSpans, { tm:fromLogical(chan, span[1]), tm:fromLogical(chan, span[2]) })
    end
    local function authored(pb) return not pb.derived and pb.cents ~= nil end
    coverInto(rawPbs(chan), rawSpans, authored, function(pb)
      local ppq = pb.ppqL or pb.ppq
      if not seen[ppq] then
        util.add(base, { ppq = ppq, val = pb.cents, shape = pb.shape or 'step', tension = pb.tension })
      end
    end)
    sortByPPQ(base)
    return base
  end
  local function ccBasesFor(chan, spans)
    local bases, seen = {}, {}
    for _, cell in ipairs(channels[chan].parkedCC or {}) do
      util.bucket(bases, cell.cc, { ppq = cell.ppq, val = cell.val, shape = cell.shape or 'step',
                                    tension = cell.tension })
      seen[util.key(cell.cc, cell.ppq)] = true
    end
    for cc, col in pairs(channels[chan].columns.ccs) do
      coverInto(col.events, spans, nil, function(evt)
        if not seen[util.key(cc, evt.ppq)] then
          util.bucket(bases, cc, { ppq = evt.ppq, val = evt.val, shape = evt.shape or 'step',
                                   tension = evt.tension })
        end
      end)
    end
    for _, base in pairs(bases) do sortByPPQ(base) end
    return bases
  end

  local res = mm:resolution()
  local pbRangeCents = pbLim()   -- slide clamps its target to what pb can reach
  local temper = tuning.findTemper(cm:get('temper'), cm:get('tempers'))
  local function stepOp(pitch, detune, n)        -- trill: scale steps -> (pitch, detune) via the temper
    return tuning.transposeStep(temper, pitch, detune, n)
  end
  -- Strict next same-lane note, sought directly in the host's lane column (slide's only consumer).
  -- see docs/trackerManager.md § Span-covered fx scans
  local function nextSameLaneNote(host)
    local note = host.notes[1]
    local col = note and channels[note.chan].columns.notes[note.lane]
    if not col then return nil end
    local events = col.events
    local from = firstAfter(events, note.ppq)
    local seated = false
    for j = from - 1, 1, -1 do
      if events[j].ppq < note.ppq then break end
      if events[j] == note then seated = true; break end
    end
    local found
    if seated then
      for j = from, #events do
        if events[j].evType ~= 'pa' then found = events[j]; break end
      end
    end
    return found
  end
  local chanCtx = { resolution = res, pbRangeCents = pbRangeCents, step = stepOp,
                    nextSameLaneNote = nextSameLaneNote }
  -- Explicit fx-regions (channel x ppq span + fx, no host note), re-queried each
  -- rebuild and bucketed by channel. see design/note-macros-v2.md § The anchor generalized
  local fxRegionsByChan = {}
  for _, region in ipairs(fxRegions or {}) do
    util.bucket(fxRegionsByChan, region.chan, region)
  end

  -- Producer-owned outputs: post-expansion live notes, per-chain pb curves, authored pb base, and
  -- the per-chan pb emit scope (nil = ungated) steering rebuildPbs' live/kept split.
  local fxOut = { noteLive = emptyChans(), pbChains = emptyChans(), pbBase = emptyChans(), pbScope = {} }

  -- Pass A: run every chain as a series -- each stage folds into the stream by mode x dest, and
  -- the final owned channels emit. see design/note-macros-v2.md § The fx chain
  local function expandChannel(chan)
    local predicted, ccLive = {}, {}
    local pbBase, ccBases   -- assigned after producer enumeration: bases cover producer windows
    -- Per-chain continuous records: one absolute curve + fold mode per chain per owned cc target;
    -- cross-chain overlap layers at emission by storage order (pb folds in rebuildPbs). see design/note-macros-v2.md § The fx chain
    local ccChains = {}
    -- One producer interface, three sources: an on-take fx note, a parked fx cell, or an explicit
    -- fxRegion; the generator sees none of them. see design/note-macros-v2.md § The anchor generalized
    local function runProducer(producer)
      local startL, endL = producer.window[1], producer.window[2]
      -- host: the untouched membership + windowed channel input streams, built once per chain;
      -- stream seeds as its copy and folds forward stage by stage. see design/note-macros-v2.md § The fx chain
      local pas, ccs, ats, pb = channelStreams(chan, startL, endL, pbBase, ccBases)
      local host = { window = { startL, endL }, chan = chan, lane = producer.lane, id = producer.id,
                     notes = producer.notes, pas = pas, ccs = ccs, ats = ats, pb = pb }
      local stream = util.pick(host, "window chan lane id notes pas ccs ats pb")
      stream.ccs = util.assign({}, host.ccs)   -- folds replace per-target lists; host's map stays untouched
      local ownsNotes = false
      local owned = {}   -- continuous target ('pb' | cc number) -> true once a stage folded a curve in

      -- Fold a continuous stage into its stream channel: replace overwrites, augment sums its delta on
      -- (exact breakpoint-union; closed, so the curve stays absolute over the whole window).
      local function foldContinuous(meta, out)
        local target = meta.dest
        if owned[target] == nil then owned[target] = false end
        if #out.delta == 0 then return end
        local cur = target == 'pb' and stream.pb or stream.ccs[target] or {}
        if meta.mode == 'replace' then
          cur = out.delta
        else
          if #cur == 0 and target ~= 'pb' then
            local rest = producer.fx.rest or generators.ccDefaultRest[target] or 0
            cur = { { ppq = startL, val = rest, shape = 'step' } }
          end
          cur = sumStreams(cur, { out.delta }, { startL, endL }, { closed = true })
        end
        owned[target] = true
        if target == 'pb' then stream.pb = cur else stream.ccs[target] = cur end
      end

      for _, params in ipairs(producer.fx) do
        local meta = generators.kinds[params.kind]
        if meta then
          local out = meta.expand(stream, host, params, chanCtx)
          if meta.dest == 'note' then
            ownsNotes = true
            if meta.mode == 'replace' then stream.notes = out.notes
            else
              local merged = {}
              for _, hit in ipairs(stream.notes) do util.add(merged, hit) end
              for _, hit in ipairs(out.notes)    do util.add(merged, hit) end
              stream.notes = merged
            end
          else
            foldContinuous(meta, out)
          end
        end
      end

      -- Emission is ownership: one record per owned continuous target, the chain's final curve. An
      -- untouched chain re-seats its parked base; an all-zero pb curve empties to a pure re-centre record.
      for target, contributed in pairs(owned) do
        if target == 'pb' then
          local curve = stream.pb
          if not contributed and not anyNonZero(curve) then curve = {} end
          util.add(fxOut.pbChains[chan], { window = { startL, endL }, curve = curve,
                                        mode = generators.chainDestType(producer.fx, target) })
        else
          util.bucket(ccChains, target,
                      { window = { startL, endL }, curve = stream.ccs[target] or {},
                        rest = producer.fx.rest, mode = generators.chainDestType(producer.fx, target) })
        end
      end
      -- Only a note-dest stage's chain emits (parksNotes mirrors this). Region producers (lane
      -- unset) defer to batch lane allocation below; note producers ride the host lane inline.
      if not ownsNotes then return end
      local regionNotes = producer.lane == nil and {} or nil
      for _, hit in ipairs(stream.notes) do
        util.add(regionNotes or predicted, {
          evType = 'note', chan = chan, lane = producer.lane, derived = producer.id,
          pitch = hit.pitch, vel = hit.vel, detune = hit.detune or 0,
          delay = producer.delay or 0, sample = producer.sample,
          ppqL = hit.ppq, endppqL = hit.endppq,
          ppq    = tm:fromLogical(chan, hit.ppq,    producer.delayPpq),
          endppq = tm:fromLogical(chan, hit.endppq, producer.delayPpq),
        })
      end
      if regionNotes then
        allocateRegionLanes(chan, startL, endL, regionNotes, predicted)
        for _, spec in ipairs(regionNotes) do util.add(predicted, spec) end
      end
    end

    -- Producer gate: under interval dirt an unseeded producer outside every emit scope it feeds keeps
    -- its output verbatim -- notes self-match by fxKey, seats re-feed the reconcile. see design § phase 5
    local dirt = dirtyChans[chan]
    local gated = dirt ~= true
    local keptById, dirtyRows
    local keptFx = {}   -- identity set: derived specs re-added verbatim, already settled last pass
    local seeded, emitScope = {}, {}
    if gated then
      keptById = {}
      for _, kept in ipairs(noteExisting[chan]) do util.bucket(keptById, kept.derived, kept) end
      dirtyRows = seedRowsFor(dirt)
    end
    -- A clean overlapper still runs (its curve is a fold input inside the overlap) but the narrowed
    -- emission drops its own remainder.
    local function keepable(producer)
      local targets = generators.continuousTargets(producer.fx)
      for target in pairs(targets) do
        if spanSetIntersects(emitScope[target], producer.window) then return false end
      end
      return true
    end
    local function runOrKeep(producer)
      if gated and not seeded[producer] and keepable(producer) then
        for _, kept in ipairs(keptById[producer.id] or {}) do
          util.add(predicted, kept); keptFx[kept] = true
        end
        -- A kept pb window still records its geometry: pb seats are markerless downstream, so a
        -- vanished window would read them as authored pbs. see design/interval-dirt.md § commit 4
        if generators.continuousTargets(producer.fx).pb then
          util.add(fxOut.pbChains[chan], { window = { producer.window[1], producer.window[2] }, kept = true })
        end
      else
        runProducer(producer)
      end
    end

    -- Producer enumeration precedes every run: the continuous-gate scopes below classify each
    -- producer against the full set, so the set must exist first. see design/interval-dirt.md § phase 5
    local producers = {}

    -- Note producers. Only augment hosts (continuous kinds) remain on-take -- a discrete-replace
    -- host was parked at 4.5 and runs from its parked cell below. Derived notes ride the host lane.
    for _, host in ipairs(fxHostsByChan[chan] or {}) do
      util.add(producers, hostProducer(host, fxWindow[host], host.lane))
    end

    -- Parked note hosts: the host left the take (note-host replace parks, like a region), so
    -- every hit is derived output. Window = the parked cell's realised extent (realiseParked
    -- applies the same bounds fxWindow would). A cell inside a region note-park window is region
    -- membership, not a host (own-fx suppressed -- the retained gap).
    for _, cell in ipairs(channels[chan].parked or {}) do
      if cell.fx and not noteParkCovered(chan, cell.ppq) then
        util.add(producers, hostProducer(soundingCell(cell), cell.endppqC, cell.lane))
      end
    end

    -- Region producers: no host note. A discrete-replace kind feeds the realised parked chord
    -- (parking frees the lanes); else members still sound and feed the live overlap. see design/note-macros-v2.md § Generator output
    for _, region in ipairs(fxRegionsByChan[chan] or {}) do
      local startL, endL = region.startppq, region.endppq
      local members
      if generators.parksNotes(region) then
        members = {}                             -- replace: derived notes stand in for the parked chord
        for _, cell in ipairs(channels[chan].parked or {}) do
          if cell.ppq >= startL and cell.ppq < endL then util.add(members, soundingCell(cell)) end
        end
      else
        members = membersOf(chan, startL, endL)  -- augment: members still sound
      end
      util.add(producers, { window = { startL, endL }, notes = members,
                            fx = region.fx, id = region.uuid, lane = nil, delayPpq = 0 })
    end

    -- Bases cover the merged producer windows and nothing more: every read below is span-bounded.
    local spans = mergeWindows(producers)
    pbBase, ccBases = pbBaseFor(chan, spans), ccBasesFor(chan, spans)
    fxOut.pbBase[chan] = pbBase

    -- Emit scope per target = merged windows of the seeded producers touching it; the cc fold and
    -- reconcile clip to it. Clean windows never enter ccExisting, so their seats keep untouched.
    if gated then
      -- Hold-stream reach: authored pb/cc breakpoints and lane-1 detune hold forward past window
      -- edges, invisible to window-local seeds. see design/interval-dirt.md § Implementation plan, commit 4
      local baseHoldFrom, detuneHoldFrom = math.huge, math.huge
      for _, s in ipairs(dirt) do
        if s.pitch == nil or s.lane == 1 then
          local from = s.ppqL
          local liveEvt = s.uuid and tm:byUuid(s.uuid)
          if liveEvt then from = math.min(from, liveEvt.ppqL or liveEvt.ppq) end
          if s.pitch == nil then baseHoldFrom   = math.min(baseHoldFrom, from) end
          if s.lane  == 1   then detuneHoldFrom = math.min(detuneHoldFrom, from) end
        end
      end
      local pbHoldFrom = math.min(baseHoldFrom, detuneHoldFrom)
      local function emitsLane1Notes(producer)
        if producer.lane ~= nil and producer.lane ~= 1 then return false end
        return generators.parksNotes(producer)
      end
      local function holdSensitive(producer, targets)
        if targets.pb and producer.window[2] > pbHoldFrom then return true end
        for target in pairs(targets) do
          if target ~= 'pb' and producer.window[2] > baseHoldFrom
             and generators.chainDestType(producer.fx, target) == 'augment' then return true end
        end
        return false
      end
      local targetsOf = {}
      for _, producer in ipairs(producers) do
        targetsOf[producer] = generators.continuousTargets(producer.fx)
        seeded[producer] = windowSeeded(dirtyRows, producer.window[1], producer.window[2])
      end
      -- Fixpoint: a live lane-1 note-emitter re-detunes the stream from its window start, which can
      -- wake pb windows further right, which may themselves emit lane-1 notes.
      local changed = true
      while changed do
        changed = false
        for _, producer in ipairs(producers) do
          if seeded[producer] and emitsLane1Notes(producer) and producer.window[1] < pbHoldFrom then
            pbHoldFrom = producer.window[1]; changed = true
          end
          if not seeded[producer] and holdSensitive(producer, targetsOf[producer]) then
            seeded[producer] = true; changed = true
          end
        end
      end
      local emitWins = {}
      for _, producer in ipairs(producers) do
        if seeded[producer] then
          for target in pairs(targetsOf[producer]) do util.bucket(emitWins, target, producer) end
        end
      end
      for target, group in pairs(emitWins) do emitScope[target] = mergeWindows(group) end
      fxOut.pbScope[chan] = emitScope.pb or {}
    end

    for _, producer in ipairs(producers) do runOrKeep(producer) end

    -- Reconcile existence (stamps kept specs with the mm handle + realised end); defer writes to the tail walk's atomic commit.
    -- fxOut.noteLive holds the predicted specs; the tail walk clips them in place.
    reconcileFx(noteExisting[chan], predicted, deferred)
    for _, spec in ipairs(predicted) do
      util.add(fxOut.noteLive[chan], { evt = spec, lane = spec.lane, kept = keptFx[spec] or nil })
    end

    -- cc emission: fold (foldChains) into markerless seats, clipped to the emit scope; half-open --
    -- the closing value belongs to the kept side. see design/interval-dirt.md § Implementation plan, commit 3
    for cc, recs in pairs(ccChains) do
      local base = ccBases[cc] or {}
      if #base == 0 then
        local rest, minStart = firstRestOverride(recs) or generators.ccDefaultRest[cc] or 0, math.huge
        for _, rec in ipairs(recs) do minStart = math.min(minStart, rec.window[1]) end
        base = { { ppq = minStart, val = rest, shape = 'step' } }
      end
      for _, span in ipairs(mergeWindows(recs)) do
        for _, emitSpan in ipairs(gated and clipToSpanSet(span, emitScope[cc]) or { span }) do
          for _, point in ipairs(foldChains(recs, emitSpan, base, { closed = true })) do
            if point.ppq >= emitSpan[1] and point.ppq < emitSpan[2] then
              util.add(ccLive, { evType = 'cc', chan = chan, cc = cc,
                                 ppq = tm:fromLogical(chan, point.ppq, 0),
                                 val = util.clamp(util.round(point.val), 0, 127),
                                 shape = point.shape, tension = point.tension })
            end
          end
        end
      end
    end

    local wires = mmBatch()
    -- fx cc events: reconcile the summed/replace seats on the target lane; shape is part of the match --
    -- it drives REAPER's interpolation. see design/note-macros-v2.md § Continuous cc
    reconcileDerived{
      existing = ccExisting[chan], predicted = ccLive, sink = wires,
      key   = function(x) return util.key(x.cc, x.ppq) end,
      match = function(have, spec)
        return have.val == spec.val and have.shape == spec.shape and have.tension == spec.tension
      end,
    }

    wires.commit()
  end

  for chan = 1, 16 do
    -- Frozen: derived notes/CCs stand untouched in mm; leave noteLive empty so tails/pbs/pcs skip too.
    -- see design/archive/dirty-channels.md § Phase A
    if dirtyChans[chan] then expandChannel(chan) end
  end
  return fxOut
end

----- Rebuild tails

-- Unified tail/onset walk + atomic commit: real notes, fixed externals, noteLive
-- walk together (onset clamp then tail clip); host clip + fxNote del/add in one mm:modify. see docs/trackerManager.md § Rebuild: tail walk
--contract: separates and bounds disturbed notes only; a nudged lane-1 onset emits its seat closure
-- The per-note settle and bound rules as a factory over ctx: both the linear and frontier walks inject
-- their batches and marking tables and drive the same rules over their own state.
--shape: ctx = { chan, res, takeLen, disturbed, nudged, clampWrites, deferred, parkedBoundFor }
local function makeTailRules(ctx)
  local chan, res, takeLen = ctx.chan, ctx.res, ctx.takeLen
  local disturbed, nudged = ctx.disturbed, ctx.nudged
  local clampWrites, deferred, parkedBoundFor = ctx.clampWrites, ctx.deferred, ctx.parkedBoundFor

  local function settleOnset(e, prev)
    local onset = voicing.separateOnset(e, prev)
    if not onset then return false end
    -- A nudge is final where it lands -- notes only ever give way forward -- so the cue and
    -- the clamp write stage here rather than in a second pass over a moved set.
    e.ppq = onset
    disturbed[e], nudged[e] = true, true
    local backing = e.colEvt or e   -- seated entries write through to their column note; fxNotes ride bare
    if e.colEvt and e.colEvt.delay ~= nil then
      -- The column stays logical; only the delayC give-way cue carries the raw shift.
      e.colEvt.delayC = util.round(timing.ppqToDelay(e.ppq - tm:fromLogical(chan, e.ppqL), res))
    end
    if backing.realised then clampWrites.assign(backing, { ppq = e.ppq }) end
    return true
  end

  local function boundNote(e, laneNext, pitchNext)
    local onTake  = not e.derived
    local ceiling = e.endppqL == util.OPEN and math.huge
                    or e.endppqL and tm:fromLogical(chan, e.endppqL)
                    or math.huge
    -- On-take tails clip against parked members' lanes too -- the columns no longer carry the cell,
    -- but the lane geometry still does. See docs/trackerManager.md § Rebuild: tail walk.
    local laneAnchor = laneNext
    if onTake then
      local parked = parkedBoundFor(e)
      if parked and (laneAnchor == nil or parked.ppq < laneAnchor.ppq) then laneAnchor = parked end
    end
    local laneClip  = laneAnchor
      and tm:fromLogical(chan, laneAnchor.ppqL) + (e.overlap or 0)
      or math.huge
    local pitchClip = pitchNext and pitchNext.ppq or math.huge
    -- Two bounds: the lane bound is intent and drives the column; the raw bound clips it to the next
    -- same-pitch onset and alone reaches mm. see docs/trackerManager.md § Rebuild: tail walk
    local laneBound = math.max(e.ppq + 1, math.min(ceiling, laneClip, takeLen))
    local rawBound  = math.max(e.ppq + 1, math.min(laneBound, pitchClip))
    local rounded   = util.round(rawBound)
    if rounded ~= e.endppq then
      local backing = e.colEvt or e
      if backing.realised then deferred.assign(backing, { endppq = rounded }) end
      e.endppq = rounded
    end
    if e.colEvt then
      -- Mirror projectEvent's endppq rule: authored ceiling shows, lane-clipped ceiling rides endppqC.
      e.colEvt.endppqC = tm:toLogical(chan, util.round(laneBound))
      e.colEvt.endppq  = e.endppqL == util.OPEN and util.OPEN
                         or e.endppqL or e.colEvt.endppqC
    end
  end

  return settleOnset, boundNote
end

-- The seed-driven tail walk over the whole channel: the degenerate fallback for dense and wholesale
-- dirt, chosen over the frontier by seed count. see docs/trackerManager.md § Rebuild: tail walk
local function linearTails(chan, notes, dirt, parkedBoundFor, takeLen, res, clampWrites, deferred, keptDerived)
  local disturbed, nudged = {}, {}
  local settleOnset, boundNote = makeTailRules{
    chan = chan, res = res, takeLen = takeLen,
    disturbed = disturbed, nudged = nudged,
    clampWrites = clampWrites, deferred = deferred, parkedBoundFor = parkedBoundFor,
  }

  -- Disturbed seeded by name: derived membership + the seeds themselves -- survivors resolved by uuid,
  -- adds by logical seat (an add's uuid lands only at commit). Anchors for the bound probes are the
  -- seed positions (dead seeds included) plus every disturbed onset, added below.
  local anchors = {}
  -- A kept fx spec (gate-verbatim, unchanged since last pass) is already settled and clipped: it
  -- rides as a bound anchor only, never a fresh disturbance. see docs/trackerManager.md § Rebuild: tail walk
  for _, e in ipairs(notes) do if e.derived and not keptDerived[e] then disturbed[e] = true end end
  if dirt == true then
    for _, e in ipairs(notes) do disturbed[e] = true end   -- degenerate pass: load, external change
  else
    local noteByUuid, bySeat = {}, {}
    for _, e in ipairs(notes) do
      if e.uuid then noteByUuid[e.uuid] = e end
      util.bucket(bySeat, seatKey(e.ppqL or e.ppq, e.lane, e.pitch), e)
    end
    for _, seed in ipairs(dirt) do
      util.add(anchors, { pos = seed.ppq, lane = seed.lane, pitch = seed.pitch })
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
  -- marks itself disturbed so the cascade carries forward. see design/interval-dirt.md § Phase 4
  local anyNudge, lastByPitch = false, {}
  for _, e in ipairs(notes) do
    local prev = lastByPitch[e.pitch]
    if disturbed[e] or (prev and disturbed[prev]) then
      if settleOnset(e, prev) then anyNudge = true end
    end
    lastByPitch[e.pitch] = e
  end
  -- A nudge moved shared index entries in place -- invisible to idxReconcile's unchanged-ppq fast
  -- path -- so re-true both the local list and um's.
  if anyNudge then table.sort(notes, rawThenLogical); resortRawNotes(chan) end

  -- Bound set: every disturbed note, plus the nearest same-lane and same-pitch strict predecessor of
  -- every anchor -- the seed-driven replacement for the span stale-test. see design § Span-staleness
  local bound = {}
  for e in pairs(disturbed) do bound[e] = true end
  -- Wholesale already binds every note, so the predecessor probes add nothing -- and running them per
  -- note is O(n^2). Only the seeded case needs them, to reach the non-disturbed neighbours dirt shadows.
  if dirt ~= true then
    for e in pairs(disturbed) do util.add(anchors, { pos = e.ppq, lane = e.lane, pitch = e.pitch }) end
    for _, a in ipairs(anchors) do
      local lanePred  = util.seek(notes, 'before', a.pos, function(e) return e.lane  == a.lane  end)
      local pitchPred = util.seek(notes, 'before', a.pos, function(e) return e.pitch == a.pitch end)
      if lanePred  then bound[lanePred]  = true end
      if pitchPred then bound[pitchPred] = true end
    end
  end

  -- Bounds + nudge emission: one backward pass hands over next-in-lane and next-in-pitch (running
  -- state keyed by lane and pitch), the stale test replaced by `bound` membership. see design § Phase 4
  local emitted = {}
  local nearestInLane,  nextAfterLane  = {}, {}
  local nearestInPitch, nextAfterPitch = {}, {}
  for i = #notes, 1, -1 do
    local e = notes[i]
    local laneAbove, pitchAbove = nearestInLane[e.lane], nearestInPitch[e.pitch]
    -- A neighbour sharing e's raw is no successor of it: it hands over its own.
    local laneNext  = laneAbove  and (laneAbove.ppq  > e.ppq and laneAbove  or nextAfterLane[e.lane])
    local pitchNext = pitchAbove and (pitchAbove.ppq > e.ppq and pitchAbove or nextAfterPitch[e.pitch])
    nearestInLane[e.lane],   nextAfterLane[e.lane]   = e, laneNext
    nearestInPitch[e.pitch], nextAfterPitch[e.pitch] = e, pitchNext

    -- The walk's own dirt: a nudged lane-1 onset seeds every absorber seat up to the next lane-1
    -- onset, for pbs to consume later this pass. see design § The widen and the emission are the same fact
    if nudged[e] and e.lane == 1 then
      util.add(emitted, { uuid = e.uuid, verb = 'nudge', ppq = e.ppq, ppqL = e.ppqL,
                          lane = e.lane, pitch = e.pitch, endppqL = laneNext and laneNext.ppqL })
    end
    if bound[e] then boundNote(e, laneNext, pitchNext) end
  end

  return emitted
end

----- Frontier probe walk

-- First index into the rawThenLogical-sorted `list` with ppq >= `pos`; #list+1 if none. Every frontier
-- probe binary-searches here, then scans outward a bounded few rows -- the seek that replaces the sweep.
local function lowerBound(list, pos)
  local lo, hi = 1, #list + 1
  while lo < hi do
    local mid = (lo + hi) // 2
    if list[mid].ppq < pos then lo = mid + 1 else hi = mid end
  end
  return lo
end
-- First index with ppq > `pos`: the far edge of pos's raw cluster.
local function upperBound(list, pos)
  local lo, hi = 1, #list + 1
  while lo < hi do
    local mid = (lo + hi) // 2
    if list[mid].ppq <= pos then lo = mid + 1 else hi = mid end
  end
  return lo
end

-- Nearest walkable record strictly on one `side` of `pos` (raw ppq) matching `filter`, over the index
-- (binary-searched, scanned outward) and the small extras. The strict-ppq bound probe; mirrors util.seek.
local function nearestNote(indexList, extras, pos, side, filter)
  local best
  local anchor = lowerBound(indexList, pos)
  if side == 'before' then
    for i = anchor - 1, 1, -1 do
      local rec = indexList[i]
      if walkable(rec) and filter(rec) then best = rec; break end
    end
  else
    for i = anchor, #indexList do
      local rec = indexList[i]
      if rec.ppq > pos and walkable(rec) and filter(rec) then best = rec; break end
    end
  end
  for _, rec in ipairs(extras) do
    local onSide = side == 'before' and rec.ppq < pos or side == 'after' and rec.ppq > pos
    local nearer = best == nil
                   or (side == 'before' and rawThenLogical(best, rec))
                   or (side == 'after'  and rawThenLogical(rec, best))
    if onSide and filter(rec) and nearer then best = rec end
  end
  return best
end

-- Same-pitch record immediately before `node` in the total order, over index + extras -- settlement's
-- predecessor. A same-tick same-pitch note counts here (unlike the strict bound probes).
local function prevSamePitch(indexList, extras, node)
  local best
  for i = upperBound(indexList, node.ppq) - 1, 1, -1 do
    local rec = indexList[i]
    if walkable(rec) and rec ~= node and rec.pitch == node.pitch and rawThenLogical(rec, node) then
      best = rec; break
    end
  end
  for _, rec in ipairs(extras) do
    if rec ~= node and rec.pitch == node.pitch and rawThenLogical(rec, node)
       and (best == nil or rawThenLogical(best, rec)) then best = rec end
  end
  return best
end

-- Same-pitch record immediately after `node` in the total order, keyed on `origPpq` (node's raw before
-- this pass nudged it) -- settlement's cascade successor. see design § Nudge probes stop at the tick
local function nextSamePitch(indexList, extras, node, origPpq)
  local key = { ppq = origPpq, ppqL = node.ppqL, derived = node.derived, lane = node.lane, pitch = node.pitch }
  local best
  for i = lowerBound(indexList, origPpq), #indexList do
    local rec = indexList[i]
    if walkable(rec) and rec ~= node and rec.pitch == node.pitch and rawThenLogical(key, rec) then
      best = rec; break
    end
  end
  for _, rec in ipairs(extras) do
    if rec ~= node and rec.pitch == node.pitch and rawThenLogical(key, rec)
       and (best == nil or rawThenLogical(rec, best)) then best = rec end
  end
  return best
end

-- On-take records at a seed's logical seat, for adds/deletes carrying no surviving uuid. Scans only the
-- seed's raw-ppq cluster in the sorted index (plus extras) -- bounded, not a channel sweep.
local function seatMatches(indexList, extras, seed)
  local out, key = {}, seed.ppqL or seed.ppq
  local function match(rec)
    return (rec.ppqL or rec.ppq) == key and rec.lane == seed.lane and rec.pitch == seed.pitch
  end
  for i = lowerBound(indexList, seed.ppq), #indexList do
    if indexList[i].ppq ~= seed.ppq then break end
    if match(indexList[i]) then util.add(out, indexList[i]) end
  end
  for _, rec in ipairs(extras) do if rec.ppq == seed.ppq and match(rec) then util.add(out, rec) end end
  return out
end

-- The frontier probe walk: seek to each seed, probe a bounded few rows for its neighbours, drive the
-- shared settle/bound rules -- no whole-channel traversal. see design/interval-dirt.md § Phase 4.75
local function frontierTails(chan, indexList, extras, dirt, parkedBoundFor, takeLen, res,
                             clampWrites, deferred, keptDerived)
  local disturbed, nudged = {}, {}
  local settleOnset, boundNote = makeTailRules{
    chan = chan, res = res, takeLen = takeLen,
    disturbed = disturbed, nudged = nudged,
    clampWrites = clampWrites, deferred = deferred, parkedBoundFor = parkedBoundFor,
  }

  -- Disturbed seeded by name: derived membership is all of extras; adds/deletes name a seat the
  -- index tick cluster answers; byUuid resolve is note-scoped -- see docs/decisions.md § 2026-07-18.
  local anchors = {}
  for _, rec in ipairs(extras) do if rec.derived and not keptDerived[rec] then disturbed[rec] = true end end
  for _, seed in ipairs(dirt) do
    util.add(anchors, { pos = seed.ppq, lane = seed.lane, pitch = seed.pitch })
    local rec = seed.uuid and tm:byUuid(seed.uuid)
    if rec and rec.evType == 'note' and rec.chan == chan then disturbed[rec] = true
    else for _, hit in ipairs(seatMatches(indexList, extras, seed)) do disturbed[hit] = true end end
  end

  -- Phase 1 -- settle onsets, same-pitch-local (a nudge only collides same-pitch successors). Each
  -- pitch's cascade chain gathers on the pristine index, then settles by position. See docs/decisions.md § 2026-07-18.
  local byPitch, chains = {}, {}
  for e in pairs(disturbed) do util.bucket(byPitch, e.pitch, e) end
  for _, seeds in pairs(byPitch) do
    table.sort(seeds, rawThenLogical)
    local si = 1
    while si <= #seeds do
      local head = seeds[si]; si = si + 1
      local prev = prevSamePitch(indexList, extras, head)
      local chain = {}
      if prev then util.add(chain, prev) end
      util.add(chain, head)
      -- reach = the running worst-case settled tick; a same-pitch successor cascades only while it can
      -- still collide (separateOnset gives way by one tick), or when it is itself a pending seed.
      local reach = (prev and head.ppq <= prev.ppq) and prev.ppq + 1 or head.ppq
      local node = head
      while true do
        local nxt = nextSamePitch(indexList, extras, node, node.ppq)
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

  local anyNudge = false
  for _, chain in ipairs(chains) do
    for i, node in ipairs(chain) do
      local prev = chain[i - 1]
      if disturbed[node] or (prev and disturbed[prev]) then
        if settleOnset(node, prev) then anyNudge = true end
      end
    end
  end
  -- Nudges moved shared entries' ppq in place; re-true both probe sources for phase 2.
  if anyNudge then table.sort(indexList, rawThenLogical); table.sort(extras, rawThenLogical) end

  -- Phase 2 -- bounds, order-free: every disturbed note plus each anchor's nearest same-lane and same-
  -- pitch strict predecessor re-bind. Bounds read settled onsets, write only endppq -- no re-disturb.
  local bound = {}
  for e in pairs(disturbed) do
    bound[e] = true
    util.add(anchors, { pos = e.ppq, lane = e.lane, pitch = e.pitch })
  end
  for _, a in ipairs(anchors) do
    local lanePred  = nearestNote(indexList, extras, a.pos, 'before', function(r) return r.lane  == a.lane  end)
    local pitchPred = nearestNote(indexList, extras, a.pos, 'before', function(r) return r.pitch == a.pitch end)
    if lanePred  then bound[lanePred]  = true end
    if pitchPred then bound[pitchPred] = true end
  end

  -- A nudged lane-1 seat emits its closure to the next lane-1 onset -- the lane successor the bound
  -- probe already fetched. see design § The widen and the emission are the same fact
  local emitted = {}
  for e in pairs(bound) do
    local laneNext  = nearestNote(indexList, extras, e.ppq, 'after', function(r) return r.lane  == e.lane  end)
    local pitchNext = nearestNote(indexList, extras, e.ppq, 'after', function(r) return r.pitch == e.pitch end)
    if nudged[e] and e.lane == 1 then
      util.add(emitted, { uuid = e.uuid, verb = 'nudge', ppq = e.ppq, ppqL = e.ppqL,
                          lane = e.lane, pitch = e.pitch, endppqL = laneNext and laneNext.ppqL })
    end
    boundNote(e, laneNext, pitchNext)
  end
  return emitted
end

local function rebuildTails(noteLive, deferred, restoredNotes)
  local takeLen = tm:length()
  local res = mm:resolution()
  local clampWrites = mmBatch()
  -- Restores are column-only until this walk's deferred commit lands them in mm; until then
  -- they walk as extra inputs alongside the index, cell backref included.
  local restoredByChan = {}
  for _, rec in ipairs(restoredNotes) do util.bucket(restoredByChan, rec.chan, rec) end
  for chan = 1, 16 do
    -- Clean channels freeze: fx left noteLive empty, real notes converged last rebuild.
    local dirt = dirtyChans[chan]
    if not dirt then goto nextChan end
    -- A kept fx spec is settled from last pass and rides the walk as a bound anchor only; only fresh
    -- (re-run producer) derived notes seed disturbance and count toward the frontier cap.
    local extras, keptDerived, freshLive = {}, {}, 0
    for _, rec in ipairs(restoredByChan[chan] or {}) do util.add(extras, rec) end
    for _, w in ipairs(noteLive[chan]) do
      util.add(extras, w.evt)
      if w.kept then keptDerived[w.evt] = true else freshLive = freshLive + 1 end
    end

    -- Parked members left the columns but still bound a preceding on-take tail in their lane --
    -- the symmetric partner of realiseParked's on-take bounds. Bound-only: never rewritten below.
    local parkedBounds = {}
    for _, cell in ipairs(channels[chan].parked or {}) do
      util.add(parkedBounds, { ppq = tm:fromLogical(chan, cell.ppq), ppqL = cell.ppq,
                               lane = cell.lane })
    end
    -- A handful of cells at most, asked only for the notes the walk bounds: scanned, not indexed.
    local function parkedBoundFor(e)
      local nearest
      for _, b in ipairs(parkedBounds) do
        if b.lane == e.lane and b.ppq > e.ppq
           and (nearest == nil or b.ppq < nearest.ppq) then nearest = b end
      end
      return nearest
    end

    -- Sparse edits seek to their seeds; dense edits and wholesale rebuilds walk the channel once. The
    -- frontier takes the sorted index and extras as separate probe sources -- no O(channel) merge.
    local emitted
    if dirt ~= true and #dirt + freshLive <= FRONTIER_SEED_CAP then
      emitted = frontierTails(chan, rawNotes(chan), extras, dirt, parkedBoundFor, takeLen, res, clampWrites, deferred, keptDerived)
    else
      local notes = mergeIndexed(rawNotes(chan), walkable, extras)
      if #notes == 0 then goto nextChan end
      emitted = linearTails(chan, notes, dirt, parkedBoundFor, takeLen, res, clampWrites, deferred, keptDerived)
    end

    if #emitted > 0 and dirt ~= true then
      for _, s in ipairs(dirt) do util.add(emitted, s) end
      dirtyChans[chan] = emitted
    end
    ::nextChan::
  end
  -- Clamps commit first: separating colliding same-pitch onsets settles mm's seat keys before
  -- the clip pass runs. Clips only touch endppq — safe to batch with adds.
  clampWrites.commit()
  -- fxNote del/add + parked restores commit in one mm:modify/MIDI_Sort; canonical
  -- delete-first means no transient same-pitch overlap.
  deferred.commit()
end

----- Rebuild Pbs

-- Reseat absorber pbs against the post-walk lane-1 layout, recompute their raw vals,
-- and project the pb column. see docs/tuning.md § Absorber reconciliation
local function rebuildPbs(fxOut, extraColumns)
  local noteLive, pbChains, pbBase, pbScope = fxOut.noteLive, fxOut.pbChains, fxOut.pbBase, fxOut.pbScope
  -- Reads only the per-chan .pb keep-flag; rebuildExtraColumns's mid-pipeline write grows
  -- .notes only, so the head snapshot is current for this. see design/rebuild-pipeline.md § The pre-phase
  local extras = extraColumns or {}

  perf.start('gather')
  -- Dirty gate on the shared spine, hoisted ahead of lane-1 sort and clone (both skip clean chans).
  -- Frozen fx channels are not dirty: their derived output stands in mm, absorber seats carried.
  local dirty = {}
  for chan = 1, 16 do
    dirty[chan] = dirtyChans[chan] or nil
  end

  -- Per-chan derived lane-1 stream, unioned with the raw index by the seeks below. Built for dirty
  -- channels alone; clean channels reuse their carried pb column and never read it.
  local function lane1Note(entry) return entry.lane == 1 and walkable(entry) end
  local freshLane1, liveLane1ByChan = {}, {}
  for chan = 1, 16 do
    if dirty[chan] then
      -- Derived lane-1 fxNotes are routed out of columns; union them so the absorber pass seats
      -- their detune jumps.
      local liveLane1 = {}
      for _, w in ipairs(noteLive[chan]) do
        if w.lane == 1 then
          util.add(liveLane1, w.evt)
          freshLane1[chan] = freshLane1[chan] or not w.kept
        end
      end
      -- Sorted for the seeks below: seatScope and the value/onset queries walk it assuming ppq order,
      -- and the derived stream lives off-take in noteLive, so a raw-only seek would miss a parked host.
      table.sort(liveLane1, rawThenLogical)
      liveLane1ByChan[chan] = liveLane1
    end
  end

  -- Lane-1 detune queries over rawNotes union liveLane1, by binary seek -- the materialised whole-
  -- channel view is gone; each query hits the index and the derived stream direct. see design/interval-dirt-v2.md § 3
  local function detuneAt(chan, P)
    local notes = rawNotes(chan)
    local i = firstAfter(notes, P) - 1        -- last index with ppq <= P
    while i >= 1 and not lane1Note(notes[i]) do i = i - 1 end
    local authored = i >= 1 and notes[i] or nil
    local derived  = liveLane1ByChan[chan]
    local d = derived and derived[firstAfter(derived, P) - 1] or nil
    if authored and d then return ((authored.ppq >= d.ppq) and authored or d).detune or 0 end
    return (authored and authored.detune) or (d and d.detune) or 0
  end

  -- Authored (walkable lane-1) union derived lane-1 with ppq in [lo, hi], in rawThenLogical order --
  -- the onset walk's per-span slice, replacing the whole-channel scan.
  local function lane1Between(chan, lo, hi)
    local notes, derived = rawNotes(chan), liveLane1ByChan[chan] or {}
    local i, j, out = firstAtOrAfter(notes, lo), firstAtOrAfter(derived, lo), {}
    while true do
      while notes[i] and not lane1Note(notes[i]) do i = i + 1 end
      local authored = notes[i]; if authored and authored.ppq > hi then authored = nil end
      local d = derived[j];      if d and d.ppq > hi then d = nil end
      if not authored and not d then break end
      if d and (not authored or rawThenLogical(d, authored)) then util.add(out, d); j = j + 1
      else util.add(out, authored); i = i + 1 end
    end
    return out
  end

  -- The first lane-1 onset (authored or derived), the I2a anchor's point; nearer wins on a tie.
  local function firstLane1(chan)
    local notes, i = rawNotes(chan), 1
    while notes[i] and not lane1Note(notes[i]) do i = i + 1 end
    local authored = notes[i]
    local d = liveLane1ByChan[chan] and liveLane1ByChan[chan][1]
    if authored and d then return rawThenLogical(authored, d) and authored or d end
    return authored or d
  end

  -- Whether any lane-1 note (authored or derived) carries a non-zero detune. With prev seeded 0 an
  -- onset exists iff some detune is non-zero, so this early-exit scan is the whole-channel jump count.
  local function anyDetune(chan)
    for _, n in ipairs(rawNotes(chan)) do
      if lane1Note(n) and (n.detune or 0) ~= 0 then return true end
    end
    for _, n in ipairs(liveLane1ByChan[chan] or {}) do
      if (n.detune or 0) ~= 0 then return true end
    end
    return false
  end

  -- Sort + coalesce overlapping seat spans into disjoint ascending, so the onset walk visits each ppq
  -- once and in order (its dual-point overwrite is order-sensitive). nil (ungated) stays nil.
  local function disjointSpans(spans)
    if not spans then return nil end
    local sorted = {}
    for _, s in ipairs(spans) do util.add(sorted, { s[1], s[2] }) end
    table.sort(sorted, function(a, b) return a[1] < b[1] end)
    local merged = {}
    for _, s in ipairs(sorted) do
      local last = merged[#merged]
      if last and s[1] <= last[2] then last[2] = math.max(last[2], s[2])
      else util.add(merged, { s[1], s[2] }) end
    end
    return merged
  end

  -- Replace windows for a channel: each pb chain's fold curve -- live spans folded to derived-seat
  -- bps (no carrier), kept spans recognition-only. see docs/tuning.md § Absorber reconciliation
  local function replaceWindows(chan)
    local lim = pbLim()
    -- Gate split: live ranges (inside the pb emit scope) fold to bps; kept ranges are recognition-
    -- only -- their seats stand on wire. see design/interval-dirt.md § Implementation plan, commit 4
    local emitSpans = pbScope[chan]   -- nil = ungated: every range is live
    local liveRecs = {}
    for _, rec in ipairs(pbChains[chan]) do
      if not rec.kept then util.add(liveRecs, rec) end
    end
    local wins = {}
    -- Bounds convert to raw once for zero round-trip drift.
    local function addWin(sub, bps, kept)
      util.add(wins, { bps = bps, kept = kept,
                       startRaw = tm:fromLogical(chan, sub[1], 0),
                       endRaw   = tm:fromLogical(chan, sub[2], 0) })
    end
    for _, span in ipairs(mergeWindows(pbChains[chan])) do
      for _, sub in ipairs(emitSpans and clipToSpanSet(span, emitSpans) or { span }) do
        local bps = {}
        for _, point in ipairs(foldChains(liveRecs, sub, pbBase[chan], { closed = true })) do
          -- Fold fast paths return whole curves, and an interior closing edge belongs to the kept
          -- side (chain cuts align with window edges) -- clip half-open except at the span's true end.
          if point.ppq >= sub[1] and (point.ppq < sub[2] or sub[2] == span[2]) then
            util.add(bps, { ppq = tm:fromLogical(chan, point.ppq, 0), ppqL = point.ppq,
                            cents = util.clamp(point.val, -lim, lim), shape = point.shape, tension = point.tension })
          end
        end
        table.sort(bps, function(a, b) return a.ppq < b.ppq end)
        addWin(sub, bps, nil)
      end
      for _, sub in ipairs(emitSpans and subtractSpanSet(span, emitSpans) or {}) do
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
    -- (authored pbs park off-take). Inclusive of endRaw to catch the terminal re-centre seat.
    local function inSeatWindow(ppq)
      for _, win in ipairs(wins) do
        if ppq >= win.startRaw and ppq <= win.endRaw then return true end
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

    return { wins = wins, winAt = replaceWinAt, inSeatWindow = inSeatWindow, inKeptRange = inKeptRange }
  end

  -- Closes seeds to raw spans that gate onsets/densify/anchor/absorber-pool below; nil = ungated.
  -- Extents come by seek, ahead of the gather. see design/interval-dirt-v2.md § 3
  local function seatScope(chan, dirt, rw, derivedLane1)
    if dirt == true then return nil end
    local spans = {}
    -- The lane-1 onset stream is authored notes (raw index) plus the off-take derived stream, the
    -- same union lane1Between/detuneAt seek; seek both here and take the nearer.
    local function nextLane1After(ppq)
      local authored = util.seek(rawNotes(chan), 'after', ppq, lane1Note)
      local derived  = util.seek(derivedLane1, 'after', ppq)
      return math.min(authored and authored.ppq or math.huge, derived and derived.ppq or math.huge)
    end
    local function lane1Span(ppq) util.add(spans, { ppq - 1, nextLane1After(ppq) }) end
    local function bpSpan(ppq)
      -- The authored value stream: non-derived pbs outside every seat window (realPbs' membership).
      local function authored(pb) return not pb.derived and not rw.inSeatWindow(pb.ppq) end
      local prevBp = util.seek(rawPbs(chan), 'before', ppq, authored)
      local nextBp = util.seek(rawPbs(chan), 'after',  ppq, authored)
      util.add(spans, { prevBp and prevBp.ppq or 0, nextBp and nextBp.ppq or math.huge })
    end
    for _, seed in ipairs(dirt) do
      -- Dedup keeps a move's vacated snapshot; the survivor's live position comes from byUuid
      -- (the frontier walk's convention, see § Seeds arrive named) and spans separately.
      local live = seed.uuid and tm:byUuid(seed.uuid)
      if not (live and live.chan == chan) then live = nil end
      if seed.lane == 1 or (live and live.lane == 1) then
        if seed.lane == 1 then lane1Span(seed.ppq) end
        if live and live.lane == 1 and live.ppq ~= seed.ppq then lane1Span(live.ppq) end
      elseif seed.evType == 'pb' then
        bpSpan(seed.ppq)
        if live and live.ppq ~= seed.ppq then bpSpan(live.ppq) end
      elseif not (seed.lane or seed.verb == 'region' or seed.evType == 'cc'
                  or seed.evType == 'at' or seed.evType == 'pc') then
        return nil
      end
    end
    for _, win in ipairs(rw.wins) do
      if not win.kept then util.add(spans, { win.startRaw - 1, win.endRaw }) end
    end
    -- The I2a anchor at the first lane-1 onset (authored or derived) is channel-global: any pass may
    -- need to seat, refresh, or retire it, so its point is always in scope.
    local authoredFirst = util.seek(rawNotes(chan), 'at-or-after', 0, lane1Note)
    local firstPpq = math.min(authoredFirst and authoredFirst.ppq or math.huge,
                              derivedLane1[1] and derivedLane1[1].ppq or math.huge)
    if firstPpq ~= math.huge then util.add(spans, { firstPpq - 1, firstPpq }) end
    return spans
  end

  -- Replace windows + seat spans per dirty chan, computed ahead of the gather. Fresh (non-kept)
  -- derived lane-1 output ungates the channel (seatSpans nil). see design/archive/interval-dirt-closing.md § 1
  local winsByChan, seatSpansByChan = {}, {}
  for chan = 1, 16 do
    if dirty[chan] then
      local rw = replaceWindows(chan)
      winsByChan[chan] = rw
      seatSpansByChan[chan] = not freshLane1[chan] and seatScope(chan, dirty[chan], rw, liveLane1ByChan[chan]) or nil
    end
  end

  -- A ppq's membership in a channel's seat scope; nil spans (ungated) puts everything in scope. The
  -- clone/carry partition: the gather clones only in-scope pbs, projection carries the rest verbatim.
  local function inSpans(spans, ppq)
    if not spans then return true end
    for _, s in ipairs(spans) do
      if ppq >= s[1] and ppq <= s[2] then return true end
    end
    return false
  end

  -- Each pb rides its own clone through the pass, carrying the index entry's uuid so a mutated clone still
  -- names its source; origShape is held because the pass rewrites shape. see design/interval-dirt-v2.md § 3
  local pbsByChan = {}
  for chan = 1, 16 do
    if dirty[chan] then
      local spans = seatSpansByChan[chan]
      for _, entry in ipairs(rawPbs(chan)) do
        if inSpans(spans, entry.ppq) then
          local pb = util.clone(entry, { colEvt = true })
          pb.origShape = entry.shape
          util.bucket(pbsByChan, pb.chan, pb)
        end
      end
    end
  end
  perf.stop('gather')

  local pbWrites = mmBatch()
  local gridStep = ccGridStep()

  -- Seat the lane-1 detune stream, match absorbers, stage the consolidated assign; returns
  -- detuneOf. Clean chans skip it wholesale -- I8: rebuild is a fixpoint. see design/incremental-pbs.md
  local function deriveChan(chan, pbs, rw, seatSpans)
    perf.start('seats')
    local replaceWins = rw.wins
    local replaceWinAt, inSeatWindow, inKeptRange = rw.winAt, rw.inSeatWindow, rw.inKeptRange

    -- Detune onsets: every lane-1 ppq whose detune differs from its predecessor, walked per seat
    -- span, seeded by the carried-in detune. see docs/tuning.md § Seat-span-scoped onset walk
    local onsets, onsetAt = {}, {}
    for _, span in ipairs(disjointSpans(seatSpans) or { { 0, math.huge } }) do
      local prev = detuneAt(chan, span[1] - 1)
      for _, n in ipairs(lane1Between(chan, span[1], span[2])) do
        local detune = n.detune or 0
        if detune ~= prev and not onsetAt[n.ppq] then
          util.add(onsets, { ppq = n.ppq, ppqL = n.ppqL }); onsetAt[n.ppq] = true
        end
        prev = detune
      end
    end
    -- A ramp onset's dual point rides one tick before it: both seats follow the onset's ownership,
    -- so the fence classifies a pb under an onset at ppq+1 by that onset's side.
    local function fencedPb(ppq)
      if onsetAt[ppq + 1] then return inKeptRange(ppq + 1) end
      return inKeptRange(ppq)
    end
    -- A replace window's clipped endRaw is kept-owned yet falls inside the window's seat span and
    -- generates no seat here; those kept-boundary seats carry from the prior column. see design/interval-dirt-v2.md § 3
    local fenced = {}   -- raw ppq -> true: carried (identity refresh via pbEntryByRaw), not projected fresh
    for i = #pbs, 1, -1 do
      if fencedPb(pbs[i].ppq) then fenced[pbs[i].ppq] = true; table.remove(pbs, i) end
    end

    -- Back-derive cents for any authored pb missing it (foreign-MIDI/pre-cents pbs carry raw only) so the
    -- assign carries cents to the sidecar; an in-window seat must not acquire cents or it stops looking like a seat.
    local persistCents = {}
    for _, pb in ipairs(pbs) do
      if pb.cents == nil and not inSeatWindow(pb.ppq) then
        pb.cents = rawToCents(pb.raw) - detuneAt(chan, pb.ppq)
        persistCents[pb] = true
      end
    end

    -- The authored value stream, whole and read-only, straight from the raw index -- decoupled from the
    -- bounded clone set. cents from the sidecar, else back-derived for foreign pbs. see design/interval-dirt-v2.md § 3
    local realPbs, pbEntryByRaw = {}, {}
    for _, entry in ipairs(rawPbs(chan)) do
      pbEntryByRaw[entry.ppq] = entry
      if not entry.derived and not inSeatWindow(entry.ppq) then
        local cents = entry.cents or (rawToCents(entry.raw) - detuneAt(chan, entry.ppq))
        util.add(realPbs, { ppq = entry.ppq, cents = cents, shape = entry.shape, tension = entry.tension })
      end
    end

    local function inSeatScope(ppq) return inSpans(seatSpans, ppq) end
    -- The onset walk is already span-bounded, so onsets need no scope filter. anyJump keeps the
    -- whole-channel jump count the anchor decision below needs (bounded onsets could hide it).
    local anyJump = anyDetune(chan)

    -- Prevailing cents at any ppq: the replace curve inside a window, else the authored
    -- breakpoints. Interpolate the bounding pair, hold the last past the end, 0 before the first.
    local function streamValue(ppq)
      local win  = replaceWinAt(ppq)
      local src  = win and win.bps or realPbs
      local i    = firstAfter(src, ppq)
      local A, B = src[i - 1], src[i]
      if not A then return 0 end
      if not B then return A.cents end
      return mm:interpolate(A, B, ppq, 'cents')
    end

    -- Authored breakpoints bounding M, excluding any pb exactly at M.
    local function spanAround(M)
      local after  = firstAfter(realPbs, M)
      local before = after - 1
      while before >= 1 and realPbs[before].ppq == M do before = before - 1 end
      return realPbs[before], realPbs[after]
    end

    -- Seats to realise: ppq -> { cents, ppqL, shape }. The consolidated assign turns each
    -- into wire raw = centsToRaw(cents + detune). A flat/held/absent stream needs only a
    -- lone step seat; a value that ramps across the onset rides linearly, so the detune
    -- step splits onto a dual point and a curved segment densifies. see docs/tuning.md
    local seats = {}
    for _, o in ipairs(onsets) do
      if inKeptRange(o.ppq) then goto nextOnset end   -- kept side: its seats stand from last pass
      local v    = streamValue(o.ppq)
      local A, B = spanAround(o.ppq)
      -- Inside a replace window the curve always ramps; otherwise ramp only across a curved or
      -- value-changing authored span.
      local ramps = replaceWinAt(o.ppq)
                    or (A and B and A.shape and A.shape ~= 'step'
                        and (isCurved(A.shape) or A.cents ~= B.cents))
      if ramps then
        -- Dual point (see docs/tuning.md § Value-aware seats): before/at carry old/new detune, both
        -- linear so the curve rides through; a window-start onset (ppq 0) has no prior cell.
        if o.ppq > 0 then
          seats[o.ppq - 1] = { cents = v, ppqL = tm:toLogical(chan, o.ppq - 1), shape = 'linear' }
        end
        seats[o.ppq]     = { cents = v, ppqL = o.ppqL, shape = 'linear' }
      else
        seats[o.ppq]     = { cents = v, ppqL = o.ppqL, shape = 'step' }
      end
      ::nextOnset::
    end

    -- Densify each curved segment of `list` that contains an onset into a linear polyline on the
    -- fixed CCINTERP grid -- stable keys (from authored ppqs) keep it churn-free.
    local function densify(list)
      for i = 1, #list - 1 do
        local A, B = list[i], list[i + 1]
        local hasOnset = false
        for _, o in ipairs(onsets) do
          if o.ppq > A.ppq and o.ppq < B.ppq then hasOnset = true break end
        end
        if isCurved(A.shape) and hasOnset then
          local p = A.ppq + gridStep
          while p < B.ppq do
            if not seats[p] and not inKeptRange(p) and inSeatScope(p) then
              seats[p] = { cents = streamValue(p), ppqL = tm:toLogical(chan, p), shape = 'linear' }
            end
            p = p + gridStep
          end
        end
      end
    end
    densify(realPbs)

    -- Seat each replace curve as derived (hidden) seats carrying its shape; see docs/tuning.md §
    -- Value-aware seats and densification for the rule. Onset seats above take priority.
    for _, win in ipairs(replaceWins) do
      for _, bp in ipairs(win.bps) do
        if not seats[bp.ppq] then
          seats[bp.ppq] = { cents = bp.cents, ppqL = bp.ppqL, shape = bp.shape }
        end
      end
      densify(win.bps)
    end

    -- Anchor a pb-active channel at its first lane-1 onset (I2a):
    -- without it, playback inherits the synth's unknown prior bend.
    local first = firstLane1(chan)
    if first and not seats[first.ppq] and not inKeptRange(first.ppq) and inSeatScope(first.ppq) then
      local hasReal, anchored = false, false
      for _, pb in ipairs(realPbs) do
        hasReal = true
        if pb.ppq <= first.ppq then anchored = true break end
      end
      if (next(seats) ~= nil or hasReal or (seatSpans ~= nil and anyJump)) and not anchored then
        seats[first.ppq] = { cents = streamValue(first.ppq), ppqL = first.ppqL, shape = 'step' }
      end
    end
    perf.stop('seats')

    perf.start('match')
    -- Match existing pbs to seats. A real pb at a seat covers it (it steps detune itself);
    -- fakes consume any already at a seat, move remaining fakes to fill the rest, delete the
    -- leftovers.
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

    local restampPpqL = {}  -- pb -> newPpqL (existing fake at a seat with stale ppqL)
    for i = #availAbsorbers, 1, -1 do
      local f, seat = availAbsorbers[i], seats[availAbsorbers[i].ppq]
      if seat then
        f.cents, f.shape = seat.cents, seat.shape
        if f.ppqL ~= seat.ppqL then
          f.ppqL = seat.ppqL   -- mirror into the clone so the logical projection sees it
          -- A seat's ppqL is raw-only (never persisted), so this nil->seat mirror is not a sidecar write.
          if not inSeatWindow(f.ppq) then restampPpqL[f] = seat.ppqL end
        end
        seats[f.ppq] = nil
        table.remove(availAbsorbers, i)
      end
    end

    local moved = {}  -- pb -> newPpq
    for ppq, seat in pairs(seats) do
      local f = table.remove(availAbsorbers)
      if f then
        moved[f] = ppq
        f.ppq, f.cents, f.ppqL, f.shape = ppq, seat.cents, seat.ppqL, seat.shape
        util.add(pbs, f)
      else
        local fresh = { chan = chan, ppq = ppq, cents = seat.cents, ppqL = seat.ppqL,
                        shape = seat.shape, derived = 'absorber', evType = 'pb' }
        util.add(pbs, fresh)
        local raw = centsToRaw(fresh.cents + detuneAt(chan, ppq))
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

    for _, f in ipairs(availAbsorbers) do
      pbWrites.del({ uuid = f.uuid })
      for i, p in ipairs(pbs) do
        if p == f then table.remove(pbs, i); break end
      end
    end

    table.sort(pbs, function(a, b) return a.ppq < b.ppq end)
    perf.stop('match')

    local detuneOf = {}
    for _, pb in ipairs(pbs) do detuneOf[pb] = detuneAt(chan, pb.ppq) end
    perf.start('assign')
    -- Consolidated assign: one entry per existing pb where any of (ppq moved, ppqL
    -- restamped, raw changed, cents back-derived, derived shape changed) needs to land.
    for _, pb in ipairs(pbs) do
      if pb.realised then
        local d         = detuneOf[pb]
        local newRaw    = centsToRaw(pb.cents + d)
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
    perf.stop('assign')
    return detuneOf, pbEntryByRaw, fenced
  end

  for chan = 1, 16 do
    -- Clean channels are skipped wholesale -- their carried pb column stands (set at rebuild entry).
    if dirty[chan] then
      local pbs = pbsByChan[chan] or {}
      table.sort(pbs, function(a, b) return a.ppq < b.ppq end)

      local priorPbCol = channels[chan].priorPb
      channels[chan].priorPb = nil
      local seatSpans = seatSpansByChan[chan]
      local detuneOf, pbEntryByRaw, fenced = deriveChan(chan, pbs, winsByChan[chan], seatSpans)

      perf.start('project')
      -- Column projection. A derived seat is wire-only -- always hidden. This projects the in-scope
      -- clones fresh; the out-of-scope remainder carries below.
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
      -- centsToRaw. Each refreshes uuid/realised since a carried event predates its committed uuid. see design/interval-dirt-v2.md § 3
      for _, evt in ipairs(priorPbCol and priorPbCol.events or {}) do
        local carry = evt.ppqRaw and (not inSpans(seatSpans, evt.ppqRaw) or fenced[evt.ppqRaw])
        local entry = carry and pbEntryByRaw[evt.ppqRaw]
        if entry then
          evt.uuid, evt.realised = entry.uuid, entry.realised
          anyVisible = anyVisible or not evt.hidden
          util.add(pbColEvents, evt)
        end
      end
      table.sort(pbColEvents, function(a, b) return a.ppq < b.ppq end)
      local keep = anyVisible or (extras[chan] and extras[chan].pb)
      channels[chan].columns.pb = keep and { events = pbColEvents } or nil
      perf.stop('project')
    end
  end

  perf.start('commit')
  pbWrites.commit()
  perf.stop('commit')
end

----- Rebuild sample stamp

-- The bearing rule: under trackerMode every note bears a sample, stamped once from the PC
-- prevailing at its onset; inheritance freezes at stamp time. see design/archive/interval-dirt-closing.md § 2
local function stampSamples()
  if not cm:get('trackerMode') then return end
  local stampWrites = mmBatch()
  for chan = 1, 16 do
    if dirtyChans[chan] then
      local pcs = rawIndexFor(chan).pcs
      for _, entry in ipairs(rawNotes(chan)) do
        if walkable(entry) and entry.sample == nil then
          local prevailing = util.seek(pcs, 'at-or-before', entry.ppq)
          local sample = prevailing and prevailing.val or 0
          entry.sample, entry.colEvt.sample = sample, sample
          stampWrites.assign(entry, { sample = sample })
        end
      end
    end
  end
  stampWrites.commit()
end

----- Rebuild PCs

-- Seed closure for PC synthesis: each seed onset's [onset, next onset) span, both frames.
-- nil = wholesale (also forced by fresh derived output). see design/archive/interval-dirt-closing.md § 2
local function pcSeedSpans(chan, dirt, noteLive)
  if dirt == true then return nil end
  for _, w in ipairs(noteLive) do
    if not w.kept then return nil end
  end
  local points = {}
  local function addPoint(ppq, ppqL)
    if ppq ~= nil then util.add(points, { ppq = ppq, ppqL = ppqL or ppq }) end
  end
  for _, s in ipairs(dirt) do
    addPoint(s.ppq, s.ppqL)
    local live = s.uuid and tm:byUuid(s.uuid)
    if live then addPoint(live.ppq, live.ppqL) end
  end
  local spans = {}
  for _, point in ipairs(points) do
    local nextRaw, nextL = math.huge, math.huge
    for _, n in ipairs(rawNotes(chan)) do
      if walkable(n) and n.ppq > point.ppq then nextRaw, nextL = n.ppq, n.ppqL; break end
    end
    util.add(spans, { sRaw = point.ppq, eRaw = nextRaw, sL = point.ppqL, eL = nextL })
  end
  return spans
end

-- PC synthesis (trackerMode only), after the sample stamp. Seed-list dirt closes to spans;
-- see design/archive/interval-dirt-closing.md § 2 for the filter chain and out-of-span guarantee.
local function rebuildPCs(noteLive)
  if not cm:get('trackerMode') then return end
  local pcWrites = mmBatch()
  local spansByChan = {}
  for chan = 1, 16 do
    -- Clean channels freeze: their PCs stand in mm and their pc column is carried forward.
    local dirt = dirtyChans[chan]
    if not dirt then goto nextChan end
    local spans = pcSeedSpans(chan, dirt, noteLive[chan])
    spansByChan[chan] = spans
    local records = {}
    for _, entry in ipairs(rawNotes(chan)) do
      if walkable(entry) and (not spans or pcInSpans(spans, entry.ppq, false)) then
        util.add(records, { ppq = entry.ppq, ppqL = entry.ppqL, lane = entry.lane,
                            sample = entry.sample, key = entry.colEvt })
      end
    end
    for _, w in ipairs(noteLive[chan]) do
      local n = w.evt
      if not spans or pcInSpans(spans, n.ppq, false) then
        -- region-derived notes ride no note host: no sample to inherit, regenerated each pass
        util.add(records, { ppq = n.ppq, ppqL = n.ppqL, lane = w.lane, sample = n.sample or 0, key = n })
      end
    end
    reconcilePCsForChan(chan, records, pcWrites, spans)
    ::nextChan::
  end
  pcWrites.commit()

  -- pc column splice: out-of-span cells carry; in-span (or wholesale) cells re-read from the
  -- committed stream. Always a fresh events table -- tv's cell carry keys on table identity.
  for chan = 1, 16 do
    if dirtyChans[chan] then
      local spans = spansByChan[chan]
      local events = {}
      if spans then
        for _, e in ipairs((channels[chan].columns.pc and channels[chan].columns.pc.events) or {}) do
          if not pcInSpans(spans, e.ppq, true) then util.add(events, e) end
        end
      end
      for _, cc in ipairs(rawIndexFor(chan).pcs) do
        if not spans or pcInSpans(spans, cc.ppq, false) then
          local cell = projectCC(cc)
          projectEvent(cell, chan)
          util.add(events, cell)
        end
      end
      sortByPPQ(events)
      channels[chan].columns.pc = { events = events }
    end
  end
end

----- Rebuild

local rebuilding = false
-- mm:reload wholesale-replaces the event set (take swap / external re-read), stranding the
-- incremental index; full-reloads when set, else keeps it. see docs § Incremental index reconciliation
local mmReloaded = false

--contract: the staging pipeline; runs inside tm:rebuild's mm:modify, never called bare
--invariant: nine stages stage mm ops; all nest, so reindex/reprojection defer to one unwind
local function rebuildPipeline(didReload)
  -- A wholesale mm re-read strands the incremental index: reload before any stage reads it;
  -- the pipeline's own commits maintain it from here. see docs § Incremental index reconciliation
  if didReload then perf.start('reload'); reload(); perf.stop('reload') end

  -- fxNote add/del + parked-member restores, deferred from fx expansion / region parking into the tail
  -- walk's atomic note commit: host clip + these inserts in one mm:modify (one MIDI_Sort, canonical delete-first).
  local deferred = mmBatch()

  -- One head snapshot of the ds intent keys the pipeline reads; stages take these as params.
  -- Every key is read before any same-pass write, so a head read equals each old use-site value.
  local sources = {
    fxRegions    = ds:get('fxRegions'),
    fxParked     = ds:get('fxParked'),
    prevWindows  = ds:get('prevWindows'),
    extraColumns = ds:get('extraColumns'),
  }

  perf.start('internals'); local external, noteExisting = rebuildInternals(); perf.stop('internals')  -- partition; internal cols (logical-born); reseat swing notes
  perf.start('ccs'); local ccExisting = rebuildCCs(sources.prevWindows); perf.stop('ccs')  -- CC walk; reseat swing CCs
  staleSwing = {}                               -- swing consumers (partition + CC walk) done; see :53 invariant
  perf.start('extraCols'); rebuildExtraColumns(sources.extraColumns); perf.stop('extraCols')  -- reconcile persisted extra columns
  perf.start('externals'); rebuildExternals(external); perf.stop('externals')  -- reintroduce foreign / diverged notes
  perf.start('samples'); stampSamples(); perf.stop('samples')  -- bearing rule: stamp bare notes from the prevailing PC

  -- Park window set: fx-regions plus every on-take note host as a degenerate region (note-is-a-region),
  -- from the settled columns. The producer re-scans post-unpark below. see design/note-macros-v2.md § Offline continuous realisation
  perf.start('fxWindows'); local hostWindows = computeFxWindows(); perf.stop('fxWindows')
  perf.start('parkRegions')
  local parkRegions = {}
  for _, r in ipairs(sources.fxRegions or {}) do util.add(parkRegions, r) end
  -- computeFxWindows already found every on-take fx host (its map keys are exactly the non-pa
  -- fx cells); iterate that rather than rescanning the columns. Sort (chan, lane, ppq) to hold the
  -- emission order the whole-column scan gave -- parkWindows downstream is G4-stable.
  local noteHosts = {}
  for host, windowEnd in pairs(hostWindows) do util.add(noteHosts, { host = host, endppq = windowEnd }) end
  table.sort(noteHosts, function(a, b)
    local ha, hb = a.host, b.host
    if ha.chan ~= hb.chan then return ha.chan < hb.chan end
    if ha.lane ~= hb.lane then return ha.lane < hb.lane end
    return ha.ppq < hb.ppq
  end)
  for _, nh in ipairs(noteHosts) do
    util.add(parkRegions, { chan = nh.host.chan, startppq = nh.host.ppq, endppq = nh.endppq,
                            fx = nh.host.fx, noteHost = true })
  end
  -- A self-parked host is off-take but still runs a producer, so its continuous (pb/cc) windows must
  -- register on any surviving fx, not just parksNotes -- see § Route-by-window: mixed-kind un-parking.
  for _, spec in ipairs(sources.fxParked or {}) do
    if spec.evType == 'note' and spec.fx then
      local endL = (spec.endppq == nil or spec.endppq == util.OPEN)
                   and tm:toLogical(spec.chan, tm:length()) or spec.endppq
      util.add(parkRegions, { chan = spec.chan, startppq = spec.ppq, endppq = endL,
                              fx = spec.fx, noteHost = true })
    end
  end
  local currentWindows = generators.parkWindows(parkRegions)
  perf.stop('parkRegions')

  perf.start('regionPark'); local restoredNotes = rebuildRegionPark(deferred, currentWindows, sources.fxParked, sources.prevWindows, hostWindows); perf.stop('regionPark')  -- park covered, carry/restore prior
  perf.start('pa'); rebuildPA(); perf.stop('pa')  -- project PAs into settled note columns (each spliced in ppq order)

  -- Post-park window pass: the maintained on-take hosts plus any fx-note cell an unpark just restored
  -- into its column (a replace host that lost its note-producing kind falls back to on-take augment).
  local restoredFxChans = {}
  for _, rec in ipairs(restoredNotes) do
    if rec.colEvt.fx then restoredFxChans[rec.colEvt.chan] = true end
  end
  perf.start('fxWindows'); local fxWindow = computeFxWindows(restoredFxChans); perf.stop('fxWindows')
  perf.start('fx'); local fxOut = rebuildFx(noteExisting, ccExisting, deferred, fxWindow, currentWindows, sources.fxRegions); perf.stop('fx')  -- fx expansion: derived notes/CCs

  perf.start('tails'); rebuildTails(fxOut.noteLive, deferred, restoredNotes); perf.stop('tails')  -- unified tail/onset walk + atomic note commit

  -- The deferred commit added each restored note to mm; mark its column cell realised so an
  -- immediate edit resolves the backing, and seat-stamp the fresh entry like any other seat.
  for _, rec in ipairs(restoredNotes) do
    if stampColEvt(rec.colEvt) then rec.colEvt.realised = true end
  end
  perf.start('pbs'); rebuildPbs(fxOut, sources.extraColumns); perf.stop('pbs')  -- absorber reconciliation + pb resynthesis
  perf.start('pcs'); rebuildPCs(fxOut.noteLive); perf.stop('pcs')  -- PC synthesis (trackerMode)

  -- Persist this rebuild's window set: next rebuild recognizes seats against it (prev-keyed). see § Route-by-window
  perf.start('prevWindows')
  if mm:take() and not util.deepEq(sources.prevWindows or {}, currentWindows) then
    ds:assign('prevWindows', #currentWindows > 0 and currentWindows or util.REMOVE)
  end
  perf.stop('prevWindows')

  -- Drop un-flushed command-path staging; the index itself is already live (head reload on
  -- wholesale passes, incremental reconciliation otherwise). see docs § Incremental index reconciliation
  perf.start('view'); clearStaging(); perf.stop('view')
  for chan in pairs(dirtyChans) do muteConform[chan] = true end
  dirtyChans = {}   -- gated stages consumed the spine; next edit window accumulates fresh
  perf.start('derivedInputs')
  derivedInputs = util.deepClone(derivationInputs())   -- after the pipeline's own ds writes have settled
  perf.stop('derivedInputs')
end

--contract: reentrancy-guarded; rebuilds channels[] from mm, reloads um cache, fires 'rebuild'
--contract: takeChanged forwarded to subscribers via the captured pendingTakeSwap
--contract: dead take (mm:take() nil) is a no-op; tv retains its last frame
--invariant: rebuild(∅) (no dirt/staleSwing/reload/takeChanged/request) short-circuits pre-nest
-- see docs/trackerManager.md § Rebuild
function tm:rebuild(takeChanged)
  if rebuilding then return end
  if not mm:take() then return end
  takeChanged = takeChanged or false
  -- rebuild(∅) does literally nothing: with no dirt, clean swing, no wholesale re-read, no
  -- take swap and no force, every stage would converge to the carried frame -- skip it all.
  if not (takeChanged or mmReloaded or rebuildRequested
          or next(dirtyChans) ~= nil or next(staleSwing) ~= nil) then return end
  rebuildRequested = false
  rebuilding = true
  -- Capture before the pipeline's nested mm:modify calls re-fire 'reload' and clear it.
  local didReload = mmReloaded; mmReloaded = false
  if didReload or takeChanged then dirtyChan() end   -- wholesale re-read / take swap: prevWindows (dataStore) carries the recognition baseline
  pbLimCents = nil   -- coherence point: refresh cached pbRange for cents<->raw conversions

  clearSwing()   -- rebuild is the (cm, mm) coherence point
  -- Carry each clean channel's whole frame forward (B1): re-deriving it is waste, and every
  -- gated stage below skips clean chans so the carried columns stand. see design/archive/dirty-channels.md § Phase B
  local prevChannels = channels
  channels = {}
  for i = 1, 16 do
    if dirtyChans[i] == true then
      channels[i] = { chan = i, columns = { notes = {}, ccs = {} } }
    elseif dirtyChans[i] then
      -- Interval dirt carries note AND cc/at/pc columns; both splice just their seeded cells. Park and
      -- pb still want the fresh channel; priorPb feeds the kept-range carry. see design § phase 3
      local prevCols = prevChannels[i].columns
      channels[i] = { chan = i, columns = { notes = prevCols.notes, ccs = prevCols.ccs,
                                            at = prevCols.at, pc = prevCols.pc },
                      priorPb = prevCols.pb }
    else
      channels[i] = prevChannels[i]
    end
  end

  -- One nest for all nine staging stages, so the reindex and the take reprojection land once each
  -- rather than once per stage. rebuilding must outlive it: each stage's commit re-enters via 'reload'.
  mm:batch(function() rebuildPipeline(didReload) end)
  rebuilding = false

  --emits: rebuild -- takeChanged:boolean
  --contract: rebuild fires at end of every non-degenerate rebuild after the um cache is reloaded
  --invariant: takeChanged is true only when rebuild followed bindTake; signals take-tier reload
  perf.start('fire'); fire('rebuild', takeChanged); perf.stop('fire')
end

----- Lifecycle

do
  --invariant: tvOnlyKeys skip the configChanged rebuild; defaultSwing is the sole remaining cm key
  local tvOnlyKeys = { defaultSwing = true }

  --invariant: dataChanged 'swing' → global change marks all 16, else only the diffed channels
  --invariant: configChanged 'swings' → channels resolving to names with diff body vs prevSwings
  --invariant: prev*-caches refresh after each event and on bindTake
  -- Merged-tier read: a save at any tier lands in the same merged view, so diff
  -- captures real change to the composite a channel will resolve to.
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
  -- mm's backstop repaired a missed same-pitch collision: re-key um surgically. No
  -- tm:rebuild here (re-enters mm:modify mid-unwind); geometry trues up next rebuild.
  mm:subscribe('collisionsResolved', function(info)
    for _, e in ipairs(info.events) do idxReconcile(e.uuid) end
  end)
  mm:subscribe('takeSwapped', function() pendingTakeSwap = true end)
  mm:subscribe('reload', function(info)
    mmReloaded = (info and info.wholesale) or false
    -- Own pipeline commits are converged output, not dirt (I8).
    -- see design/archive/dirty-channels.md § Scheme item 1
    if not rebuilding and info and info.chans then
      absorbReloadDirt(info.chans)
    end
    tm:rebuild(pendingTakeSwap)
    pendingTakeSwap = false
  end)
  -- Skip configChanged while dormant (cm unbound, mm/cm mismatch): the rebind diffs derivationInputs
  -- rather than replaying what it missed. see docs/trackerManager.md § Dormant guard
  cm:subscribe('configChanged', function(change)
    if bindingTake or not cm:boundTake() then return end
    local key = change.key
    if key == 'swings' then
      local curSwings = readSwings()
      for chan in pairs(channelsResolvingTo(changedSwingNames(prevSwings, curSwings))) do
        tm:markSwingStale(chan)
      end
      prevSwings = util.deepClone(curSwings)
    elseif not tvOnlyKeys[key] then
      dirtyChan()   -- any other derivation config (temper/pbRange/ccInterp/overlapOffset) re-derives all chans
    end
    if not tvOnlyKeys[key] then tm:rebuild(false) end
  end)

  -- swing/extraColumns/noteDelay/fxRegions are document data: edits + undo rewinds
  -- arrive as dataChanged. swing diffs its map; the rest force a full rebuild.
  ds:subscribe('dataChanged', function(change)
    -- Pipeline's own ds:assigns during rebuild (fxParked/extraColumns) are converged
    -- output, not edits; re-entering marks all 16 dirty and breaks B1. see design/archive/dirty-channels.md § Phase B
    if rebuilding then return end
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
    elseif change.name == 'fxRegions' then
      -- Region edits seed only the changed regions' channels; unchanged channels freeze. see § Route-by-window
      if not flushingParked then seedRegionEdit(ds:get('fxRegions')); tm:rebuild(false) end
    elseif change.name == 'fxParked' then
      -- parking drives fx expansion + the pb keep-decision; seed only the changed members.
      if not flushingParked then seedParkedEdit(ds:get('fxParked')); tm:rebuild(false) end
    elseif change.name == 'extraColumns' then
      -- extraColumns is grow-only/merge-safe, not parking -- a whole re-derive stays. see design § phase 3
      if not flushingParked then dirtyChan(); tm:rebuild(false) end
    elseif change.name == 'noteDelay' then
      -- noteDelay is a display offset -- nothing in the tm pipeline reads it; reproject only,
      -- forced past the rebuild(∅) gate since it seeds no dirt.
      if not flushingParked then tm:requestRebuild(); tm:rebuild(false) end
    elseif change.name == 'fxPatterns' then
      -- Shared pattern-library edit (P3 write-through): re-realise every consumer. v1 dirties
      -- all 16; pattern->consumer targeting is P4. see design/fx-patterns.md § The checkout model
      dirtyChan(); tm:rebuild(false)
    end
  end)

  ----- Anticipative-FX guard (see docs/trackerManager.md § Anticipative-FX guard)
  local function trackByGuid(guid)
    for i = 0, reaper.CountTracks(0) - 1 do
      local tr = reaper.GetTrack(0, i)
      if reaper.GetTrackGUID(tr) == guid then return tr end
    end
  end

  local function guardTrack(track)
    if not track then return end
    local flags = math.floor(reaper.GetMediaTrackInfo_Value(track, 'I_PERFFLAGS'))
    ds:assign('guardedTrack', { guid = reaper.GetTrackGUID(track), flags = flags })
    reaper.SetMediaTrackInfo_Value(track, 'I_PERFFLAGS', flags | 2)
  end

  --contract: restores the guarded track's prior I_PERFFLAGS, clears the record; no-op if none
  function tm:restoreGuarded()
    local g = ds:get('guardedTrack')
    if not g then return end
    local track = trackByGuid(g.guid)
    if track then reaper.SetMediaTrackInfo_Value(track, 'I_PERFFLAGS', g.flags) end
    ds:delete('guardedTrack')
  end

  --contract: atomic take swap: cm:setContext runs silently; mm:load fires the coherent rebuild
  --contract: opts.trackerMode (wiring-derived) seeds trackerMode under the same suppression window
  --contract: opts.markSwingStale=true rebuilds raw from ppqL under new (cm, mm) (seqMgr:reswingAll)
  --contract: bindTake(nil) is the dormant seam (e.g. samplePage)
  --contract: opts.skipGuard skips restore/guardTrack; mini stacks never touch the shared guard
  --invariant: bindTake(nil): cm clears under suppression; mm:load(nil) no-op; tm/tv keep last frame
  function tm:bindTake(take, opts)
    local skipGuard = opts and opts.skipGuard
    if not skipGuard then tm:restoreGuarded() end
    bindingTake = true
    cm:setContext(take)
    if take then cm:set('transient', 'trackerMode', (opts and opts.trackerMode) or false) end
    bindingTake = false
    if opts and opts.markSwingStale then
      for i = 1, 16 do staleSwing[i] = true end
    end
    -- Nothing above marked dirt (cm ran suppressed), and the converged gate in mm:load no longer
    -- blanket-dirties a rebind. Whatever changed unheard -- an undo of the take's swing, a wiring
    -- flip re-seeding trackerMode -- shows up here as a diff. markSwingStale covers dirt AND reseat.
    if take and not util.deepEq(derivationInputs(), derivedInputs or {}) then tm:markSwingStale(nil) end
    mm:load(take)
    if take and not skipGuard then guardTrack(reaper.GetMediaItemTake_Track(take)) end
    snapshotSwingState()
  end

  --contract: take died under us — nils mm.take so tm:currentTake reads nil; not bindTake(nil) seam
  function tm:detach()
    tm:restoreGuarded()
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

tm:restoreGuarded()
tm:rebuild(true)
return tm
