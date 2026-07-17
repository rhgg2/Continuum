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
--invariant: loc values valid only within one rebuild-to-flush window
--invariant: um's notesByLoc/ccsByLoc rebuild fresh each rebuild
--invariant: col events sort by logical ppq
--invariant: endppq carries no delay; delay shifts only the note-on
--invariant: 16 channels always present; channels[i] non-nil for i in 1..16 after rebuild

--shape: channel = { chan, columns = { notes, ccs={[ccNum]=col}, [pc], [pb], [at] } }
--shape: column = { events=[evt,...], [cc=ccNum] }  -- events sorted by logical ppq
--shape: noteEvent core = { ppq, endppq, pitch, vel, lane, detune, delay, loc }
--invariant: noteEvent optional: muted, sample, sampleShadowed, <metadata...>
--shape: pbEventCol = { ppq, val=cents-minus-detune, detune, hidden, loc, ... }
--invariant: pbEventCol optional: delay, shape, tension
--invariant: pbEventCol is the col projection; um cache holds raw cents in val
--shape: paEventCol = { evType='pa', ppq, pitch, vel, loc, ... }
--invariant: paEventCol mixes into note column events
--shape: extraColumns[chan] = { notes=count, [pc], [pb], [at], [ccs={[ccNum]=true}] }
--shape: lastMuteSet = { [chan] = true }, pushed by tv via tm:setMutedChannels
--shape: fxParked = one evType-tagged off-take stash for every replace park; each spec is the authored
--shape:   event in the logical frame, minus realisation (delayC/endppqC/loc/realised/derived/frame/cents),
--shape:   so new metadata rides park automatically. Baseline fields per type (raw re-derived on restore):
--shape:   note { evType='note', chan, lane, uuid, ppq, endppq, pitch, vel, detune, delay, sample, [fx] }
--shape:   cc { evType='cc', chan, cc, ppq, val, shape }  |  pb { evType='pb', chan, ppq, val (=cents), shape, [tension] }  |  pa { evType='pa', chan, pitch, ppq, vel, [rpb] }
--shape: channels[chan].parked = { { evType='note', chan, uuid, ppq, endppq, endppqC, pitch, vel, detune, sample, delay, lane, [fx] }, ... } -- render-ready off-take replace cells (endppq is the authored ceiling the view edits, endppqC the render clip realiseParked derives)
--shape: channels[chan].parkedCC = { { evType='cc', chan, cc, ppq, val, shape }, ... } -- off-take cc-replace render cells
--shape: channels[chan].parkedPb = { { evType='pb', chan, ppq, val (=cents), cents, shape, [tension] }, ... } -- off-take pb-replace render cells
--shape: channels[chan].parkedPA = { { evType='pa', chan, pitch, ppq, vel, [rpb] }, ... } -- off-take PA cells; rebuildPA re-projects them into the host note column
--contract: a discrete-replace kind parks its host: a region parks its covered chord, a note parks itself
--invariant: parked members feed generator + grid only; never sounding (mute fails for CC/PA)

local util    = require 'util'
local timing  = require 'timing'
local tuning  = require 'tuning'
local voicing = require 'voicing'
local intervals  = require 'intervals'
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
--invariant: dirtyChans[chan]: gated stages (ccs/fx/park/tails/pbs/pcs) re-derive it, else freeze
local dirtyChans   = {}
-- Deep clone of derivationInputs() as of the last rebuild: what the current frame was derived under.
-- bindTake diffs against it, because a rebind can find any of it changed with no signal to hear.
local derivedInputs
-- Rebuilt chans re-read the wire, so muted flags need re-conforming; setMutedChannels consumes.
local muteConform  = {}
-- True only while flush writes the parked stash; suppresses the inline dataChanged
-- rebuild so flush drives the single rebuild (B3 staging, see design/note-macros-v2.md).
local flushingParked = false
-- Set via tm:requestRebuild by a preflush subscriber whose geometry-only change stages no
-- mm ops but still needs the grid (cellKind region tags) rebuilt. Consumed + cleared by flush.
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

-- Only note columns interleave notes and PAs, which can share an onset: ties order note-before-PA,
-- then pitch, so an equal-onset seat holds across rebuilds. see design/archive/logical-column-order.md
local function sortNoteColumn(tbl)
  table.sort(tbl, function(a, b)
    if a.ppq ~= b.ppq then return a.ppq < b.ppq end
    local aPa, bPa = a.evType == 'pa', b.evType == 'pa'
    if aPa ~= bPa then return bPa end
    return (a.pitch or 0) < (b.pitch or 0)
  end)
end

-- General derivation-dirt spine: any edit/config change re-derives a channel's gated stages.
-- Spurious dirt costs a re-derive; missed dirt writes silent wrong output. see design/archive/dirty-channels.md § Scheme
local function dirtyChan(chan)
  if chan then dirtyChans[chan] = true; return end
  for i = 1, 16 do dirtyChans[i] = true end
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

-- detune-at-ppq for every pb in one linear merge (pbs and lane1Events both ppq-sorted).
local function mergeDetunes(pbs, lane1Events)
  local detuneOf, di, dcur = {}, 1, 0
  for _, pb in ipairs(pbs) do
    while di <= #lane1Events and lane1Events[di].ppq <= pb.ppq do
      dcur = lane1Events[di].detune or 0
      di = di + 1
    end
    detuneOf[pb] = dcur
  end
  return detuneOf
end

local function delayToPPQ(delay) return timing.delayToPPQ(delay, mm:resolution()) end

----- Fx expansion helpers

-- Membership is overlap, not storage: authored notes re-queried each rebuild; one walk
-- feeds generator events + fixed lane occupancy. see design/note-macros-v2.md § The anchor generalized
local function eachWindowNote(chan, startL, endL, fn)
  for laneIdx, col in ipairs(channels[chan].columns.notes) do
    -- A lane is monophonic + ppq-sorted, so a note's sounding tail ends at the next note's onset
    -- (or the window): mirror rebuildTails' laneClip so an OPEN ceiling never streams a phantom overlap.
    local onsets = {}
    for _, evt in ipairs(col.events) do
      if evt.evType ~= 'pa' then util.add(onsets, evt) end
    end
    for i, evt in ipairs(onsets) do
      local ceil   = (evt.endppq == nil or evt.endppq == util.OPEN) and endL or evt.endppq
      local nextOn = onsets[i + 1] and onsets[i + 1].ppq or endL
      local hi     = math.min(ceil, nextOn)
      if evt.ppq < endL and hi > startL then fn(laneIdx, evt.ppq, hi, evt) end
    end
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
  local function within(ppq) return ppq >= startL and ppq < endL end
  local pas, ats = {}, {}
  for _, col in ipairs(cols.notes) do
    for _, evt in ipairs(col.events) do
      if evt.evType == 'pa' and within(evt.ppq) then
        util.add(pas, { ppq = evt.ppq, pitch = evt.pitch, vel = evt.vel })
      end
    end
  end
  for _, evt in ipairs(cols.at and cols.at.events or {}) do
    if within(evt.ppq) then util.add(ats, { ppq = evt.ppq, val = evt.val }) end
  end
  -- Generators read these streams in ppq order (bases pre-sorted, slices preserve order). see design/archive/deferred-reindex.md § Phase A
  sortByPPQ(pas)
  sortByPPQ(ats)
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

--contract: synthesised PCs carry derived='pc'; ppqL inherited from winning host-note record
--contract: an existing derived PC matching (ppq, val) is kept, preserving mm-side loc
--contract: appends removals/adds to the sink {del(event), add(spec)}
--contract: if record.key set, marks key.sampleShadowed=true on records lost to lane priority
--invariant: shadow marking is rebuild-only; flush callers omit key (rebuild reclones lane events)
--invariant: c.pc.events not written here; rebuild's CC walk refreshes it from mm after commit
local function reconcilePCsForChan(chan, records, sink)
  local existing = (channels[chan].columns.pc and channels[chan].columns.pc.events) or {}

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

local addEvent, assignEvent, deleteEvent, addParked, assignParked, deleteParked, flush, reload, idxReconcile, withDeferredSort, clearStaging, absorbReloadDirt do

  ----- State

  local adds = {}
  local assigns = {}
  local deletes = {}
  --shape: seeds[chan] = list of intervals.seed objs (pre-merge); folded into dirtyChans at reload. see design § phase 2
  local seeds = {}
  local parkedEdits = {}
  local parkedUuidSeq = 0
  local chans = {}
  local byUuid = {}
  local dirtyPcChans = {}

  ----- Accessors

  -- Prevailing lane-1 detune at-or-before ppq; flush derives wire-raw = cents + detuneAt(seat).
  -- Full absorber reconciliation is rebuild's absorber pass; um just stages the best-effort value.
  local function detuneAt(chan, P)
    local n = util.seek(chans[chan].notes, 'at-or-before', P)
    return (n and n.detune) or 0
  end

  local function forEachAttachedPA(host, fn)
    for _, cc in pairs(byUuid) do
      if cc.evType == 'pa' and cc.chan == host.chan and cc.pitch == host.pitch
        and cc.ppq >= host.ppq and cc.ppq < host.endppq then
        fn(cc)
      end
    end
  end

  ----- Low-level mutation

  -- chans indexes only what detune/seek read: lane-1 notes and pbs. One place to
  -- resolve the target list, so insert/remove/migrate stay in sync across ops.
  local function chansListFor(evt, chan, lane)
    if evt.evType == 'note' and lane == 1 then return chans[chan].notes end
    if evt.evType == 'pb' then return chans[chan].pbs end
  end
  -- During a batched reconcile this holds the lists chansInsert touched; the batch
  -- sorts each once at the end instead of re-sorting per insert. nil = sort inline.
  local deferredSort
  local function chansInsert(evt)
    local tbl = chansListFor(evt, evt.chan, evt.lane)
    if not tbl then return end
    util.add(tbl, evt)
    if deferredSort then deferredSort[tbl] = true else sortByPPQ(tbl) end
  end
  local function chansRemove(evt, chan, lane)
    local tbl = chansListFor(evt, chan or evt.chan, lane or evt.lane)
    if not tbl then return end
    for i, item in ipairs(tbl) do if item == evt then table.remove(tbl, i); return end end
  end

  -- The batching door: chans is um's, so um owns the deferral. Inserts inside fn flag their list;
  -- each is sorted once here. A caller reaching for the flag directly gets a nil it cannot see.
  function withDeferredSort(fn)
    local prev = deferredSort
    deferredSort = {}
    fn()
    for tbl in pairs(deferredSort) do sortByPPQ(tbl) end
    deferredSort = prev
  end

  -- Construct the um-frame index entry for one mm clone and file it into byUuid.
  -- Shared verbatim by full reload and the incremental verbs so both build identical entries.
  local function makeEntry(e)
    local evt
    if e.evType == 'pb' then
      -- val is raw 14-bit converted to cents (um's frame). cents sidecar is authored logical value;
      -- nil for foreign-MIDI/pre-cents pbs — back-derived in rebuild's absorber pass from lane-1 layout.
      evt = util.pick(e, 'ppq ppqL chan shape tension derived frame cents uuid',
                      { val = rawToCents(e.val), realised = true, evType = 'pb' })
    else
      evt = e
      evt.realised = true
    end
    byUuid[evt.uuid] = evt
    return evt
  end

  -- Refresh an existing entry from mm's fresh clone in place: prev keeps its ppq-sorted
  -- slot in chans, so a same-slot reconcile skips the chansRemove scan, reinsert and sort.
  local function refreshEntry(prev, e)
    if e.evType == 'pb' then
      prev.ppqL, prev.shape, prev.tension = e.ppqL, e.shape, e.tension
      prev.derived, prev.frame, prev.cents = e.derived, e.frame, e.cents
      prev.val = rawToCents(e.val)
    else
      for k in pairs(prev) do if e[k] == nil and k ~= 'realised' then prev[k] = nil end end
      util.assign(prev, e)
      prev.realised = true
    end
  end

  -- Incremental index upkeep for one uuid. chans lists are ppq-sorted and chansListFor ignores
  -- ppq, so refresh in place only at an unchanged ppq. see docs/trackerManager.md § Incremental index reconciliation
  function idxReconcile(uuid)
    if not uuid then return end
    local prev = byUuid[uuid]
    local _, e = mm:byUuid(uuid)
    if e and prev and prev.ppq == e.ppq
       and chansListFor(prev, prev.chan, prev.lane) == chansListFor(e, e.chan, e.lane) then
      refreshEntry(prev, e)
      return
    end
    byUuid[uuid] = nil
    if prev then chansRemove(prev) end
    if e then chansInsert(makeEntry(e)) end
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

  -- Every low-level verb drops a point seed at the event's logical position; flush folds them
  -- into interval-valued dirt (§ phase 2). A delete seed's dying uuid is safe: see docs/trackerManager.md § Interval seeds.
  local function seedAt(chan, ppqL, uuid)
    util.bucket(seeds, chan, intervals.seed(ppqL, ppqL, uuid, uuid))
  end
  local function seedEvent(evt) seedAt(evt.chan, evt.ppqL or evt.ppq, evt.uuid) end

  --contract: only lane==1 notes index into chans[chan].notes
  --contract: higher-lane notes get queued for mm but don't feed detune/realisation reads
  --contract: caller supplies evt.evType
  local function addLowlevel(evt)
    if pbSource(evt, evt.lane) then dirtyChan(evt.chan) end
    seedEvent(evt)
    chansInsert(evt)
    util.add(adds, { evt = evt })
  end

  --contract: dedupes by uuid; in-flight assigns to the same event collapse into one mm write
  --invariant: util.REMOVE markers must survive merging
  local function assignLowlevel(evt, update)
    local oldChan, oldLane = evt.chan, evt.lane
    local oldPpqL = evt.ppqL or evt.ppq
    util.assign(evt, update)
    if assignDirtiesPb(evt, oldLane, update) then dirtyChan(oldChan); dirtyChan(evt.chan) end
    -- A move (onset shifts) is delete-at-old + insert-at-new: seed both positions. see design § Intervals are event-anchored
    if update.ppq ~= nil or update.ppqL ~= nil or update.delay ~= nil then seedAt(oldChan, oldPpqL, evt.uuid) end
    seedEvent(evt)
    -- Keep the lane-1 detune index coherent: a chan OR lane move migrates the
    -- entry between lists; a ppq move resorts in place (util.seek needs ascending).
    local oldList = chansListFor(evt, oldChan, oldLane)
    local newList = chansListFor(evt, evt.chan, evt.lane)
    if oldList ~= newList then
      chansRemove(evt, oldChan, oldLane)
      chansInsert(evt)
    elseif update.ppq ~= nil and newList then
      sortByPPQ(newList)
    end
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
    seedEvent(evt)
    chansRemove(evt)
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

  -- cullEnd is the span ceiling PAs are tested against; for an open tail
  -- it must be passed explicitly — see docs/trackerManager.md § Update manager.
  local function resizeNote(n, P1, P2, cullEnd)
    cullEnd = cullEnd or P2
    local shift = P1 - n.ppq
    if shift ~= 0 and P2 - n.endppq == shift then
      forEachAttachedPA(n, function(evt)
        assignLowlevel(evt, { ppq = evt.ppq + shift })
      end)
    else
      local lastPA
      forEachAttachedPA(n, function(evt)
        if evt.ppq <= P1 or evt.ppq >= cullEnd then
          if evt.ppq <= P1 and (not lastPA or evt.ppq > lastPA.ppq) then lastPA = evt end
          deleteLowlevel(evt)
        end
      end)
      if lastPA then assignLowlevel(n, { vel = lastPA.vel }) end
    end
    assignLowlevel(n, { ppq = P1, endppq = P2 })
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
      local endppqL = update.endppqL ~= nil and update.endppqL or n.endppqL
      local cullEnd = endppqL == util.OPEN and util.OPEN or (update.endppq or n.endppq)
      resizeNote(n, update.ppq or n.ppq, update.endppq or n.endppq, cullEnd)
      update.ppq, update.endppq = nil, nil
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
      local seat = evt.evType == 'pb' and util.seek(chans[evt.chan].pbs, 'at-or-before', evt.ppq)
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
      dirtyChan(ref.chan)   -- parked specs feed the producer: an edit re-derives the channel
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
    rebuildRequested = false

    -- Parked edits stage alongside mm ops. Write the stash first (guarded), then let the mm
    -- commit's reload->rebuild pick it up; with no mm ops, drive the one rebuild explicitly.
    local hadMmOps = #adds > 0 or #assigns > 0 or #deletes > 0
    if #parkedEdits > 0 then flushParked() end
    if not hadMmOps then
      tm:rebuild(false)
      fire('postflush')
      return
    end

    perf.start('flush')

    -- Single scan over all post-flush notes for same-(chan,pitch) MIDI legality: verdicts + onset
    -- separation, no tails -- those are the walk's. see docs/trackerManager.md § Flush collision scan
    do
      local byKey = {}
      for _, n in pairs(byUuid) do
        if n.evType == 'note' then util.bucket(byKey, util.key(n.chan, n.pitch), n) end
      end
      for _, o in ipairs(adds) do
        if o.evt.evType == 'note' then util.bucket(byKey, util.key(o.evt.chan, o.evt.pitch), o.evt) end
      end

      -- Verdicts and onset separation only: the tail bound is the walk's, computed against post-walk
      -- geometry and strictly stronger. A rebuild always follows a flush. see design/archive/same-pitch-enforcement.md
      local updates, kills = {}, {}
      for _, group in pairs(byKey) do
        local groupKills, voiced, onsetOf = voicing.resolveGroup(group)
        for _, n in ipairs(groupKills) do util.add(kills, n) end

        for _, n in ipairs(voiced) do
          if onsetOf[n] ~= n.ppq then util.add(updates, { n = n, up = { ppq = onsetOf[n] } }) end
        end
      end

      for _, n in ipairs(kills) do deleteNote(n) end
      for _, u in ipairs(updates) do
        if u.n.realised then assignNote(u.n, u.up)   -- realised: route PA/detune resize
        else                 util.assign(u.n, u.up)  -- staged add: geometry only
        end
      end
    end

    local flushAdds, flushAssigns, flushDeletes = adds, assigns, deletes
    adds, assigns, deletes = {}, {}, {}
    perf.count('committed', #flushAdds + #flushAssigns + #flushDeletes)

    -- Same-pitch moves transiently share a content key: an occupier clobbers a peer's collisionIdx
    -- slot before it vacates. Sort descending so every vacate leads its occupy. see docs/trackerManager.md § Flush collision scan
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
        -- addLowlevel already filed the raw staged object into chans; drop it by identity
        -- and re-file mm's canonical clone so the entry matches reload (cc shape, pb cents).
        if uuid then chansRemove(o.evt); idxReconcile(uuid) end
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
    for i = 1, 16 do chans[i] = { notes = {}, pbs = {} } end
    for _, e in mm:events() do
      local evt = makeEntry(e)
      local tbl = chansListFor(evt, evt.chan, evt.lane)
      if tbl then util.add(tbl, evt) end
    end
    -- mm:events() yields notes then ccs each already ppq-sorted (mm's stableByPpq);
    -- the per-channel filter above preserves that order, so no re-sort is needed.
  end

  -- Fold this flush's per-verb seeds into dirtyChans as interval dirt: payload chans the seeds cover
  -- stay narrowed, unseeded payload chans (mm-internal writes) fold whole. see design § phase 2
  function absorbReloadDirt(payloadChans)
    intervals.absorbSeeds(dirtyChans, seeds, payloadChans)
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
-- so tv re-tags cellKind. Forces the next flush past its no-op early-return.
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
  -- became would ride out through park / clipboard / gm. mm and the raw scratch keep theirs.
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

-- Drop the carried events this pass's clones will replace. PAs go whatever the dirt says:
-- rebuildPA re-projects every PA on a dirty chan, so a carried one would double up.
local function exciseNotes(chan, dirt)
  for _, col in ipairs(channels[chan].columns.notes) do
    local kept = {}
    for _, evt in ipairs(col.events) do
      if evt.evType ~= 'pa' and not intervals.intersects(dirt, evt.ppq, evt.ppq) then
        util.add(kept, evt)
      end
    end
    col.events = kept
  end
end

-- Partition mm notes stamped/external, lay internal columns, reseat stale-swing.
-- Returns seated internals + external notes + the per-channel derived-note existing set. see docs/trackerManager.md § Rebuild: partition
--contract: interval dirt: non-derived notes carry ppqL -- an external mutation reloads wholesale
local function rebuildInternals()
  local internal, external = {}, {}
  local noteExisting = emptyChans()
  -- Clean channels carry their columns whole: never visited, so never cloned. Interval-dirty ones
  -- excise the seeded points and re-clone just those; the rest of the column carries untouched.
  for chan = 1, 16 do
    local dirt = dirtyChans[chan]
    if dirt then
      if dirt ~= true then exciseNotes(chan, dirt) end
      for _, raw in mm:notesRaw(chan) do
        -- Derived notes route to fx whole-channel whatever the dirt: a partial noteExisting
        -- reads as mass deletion until the fx reconcile goes interval-native. see design § phase 3
        if raw.derived then
          local note = util.clone(raw); note.realised = true
          util.add(noteExisting[chan], note)
        elseif dirt == true or intervals.intersects(dirt, raw.ppqL, raw.ppqL) then
          local note = util.clone(raw); note.realised = true
          if rawDivergesFromLogical(note) then util.add(external, note)
          else util.add(internal, note)
          end
        end
      end
    end
  end

  local reseats     = mmBatch()
  local reseated    = {}
  local reseatedWas = {}
  for _, note in ipairs(internal) do
    local channel = channels[note.chan]
    local notes = channel.columns.notes
    -- Stamped notes keep their authored lane verbatim (extended if missing);
    -- the tail walk clips tails afterward, so overlap here is never a concern.
    while #notes < note.lane do pushNoteCol(channel) end
    local col = notes[note.lane]
    -- note is already our own mm:notes() clone -- repurpose it as the column note rather than
    -- cloning again. mm's stored note is untouched; the post-externals flip rewrites ppq to logical.
    local colNote = note
    -- set detune/delay at ingestion to skip defensive guards downstream
    colNote.detune = colNote.detune or 0
    colNote.delay  = colNote.delay  or 0
    -- when swing is stale, rederive realised onset from logical; endppq handled by the tail walk.
    if staleSwing[note.chan] then
      reseatedWas[colNote] = colNote.ppq   -- capture raw before the reseat mutates it (alias, not a copy)
      colNote.ppq = tm:fromLogical(note.chan, colNote.ppqL, delayToPPQ(colNote.delay))
      util.add(reseated, colNote)
    end
    util.add(col.events, colNote)
  end

  -- Reswing can collapse two distinct-ppqL same-pitch notes onto one raw. Separate them before
  -- the commit so mm's reload-dedup never eats a voice -- the tail walk's gate runs far too late.
  table.sort(reseated, function(a, b)
    if a.chan ~= b.chan then return a.chan < b.chan end
    if a.ppq  ~= b.ppq  then return a.ppq  < b.ppq  end
    return a.ppqL < b.ppqL
  end)
  voicing.nudgeOnsets(reseated)
  for _, e in ipairs(reseated) do
    if e.ppq ~= reseatedWas[e] then reseats.assign(e, { ppq = e.ppq }) end
  end
  reseats.commit()

  return internal, external, noteExisting
end

----- Rebuild CCs

-- Markerless cc-replace fill seats are recognized by window (mirrors pb inSeatWindow). Bounds raw once,
-- half-open like the park's covered(); cc curves carry no terminal-at-end seat, so the open end is safe.
local function rawSpanMap(wins)
  local map = {}
  for _, w in ipairs(wins) do
    map[w.chan]       = map[w.chan] or {}
    map[w.chan][w.cc] = map[w.chan][w.cc] or {}
    util.add(map[w.chan][w.cc], { sRaw = tm:fromLogical(w.chan, w.startppq),
                                  eRaw = tm:fromLogical(w.chan, w.endppq) })
  end
  return map
end

local function inSpan(map, chan, cc, ppq)
  local spans = map[chan] and map[chan][cc]
  if spans then
    for _, s in ipairs(spans) do if ppq >= s.sRaw and ppq < s.eRaw then return true end end
  end
  return false
end

-- CC walk: build the carrier routing map, reconcile (raw,ppqL), project CCs.
-- Returns a carrier-map persister; run after fx expansion. see docs/trackerManager.md § Rebuild: CC walk
local function rebuildCCs(prevWindows)
  local ccWrites = mmBatch()
  local ccExisting = emptyChans()

  -- Seats are recognized against last rebuild's persisted windows: an on-take cc inside a prev cc window is a
  -- seat; a just-created window's cc still parks, a removed one's orphans reconcile away. see design/note-macros-v2.md § Route-by-window
  local ccWins = {}
  for _, w in ipairs(prevWindows or {}) do
    if w.evType == 'cc' then util.add(ccWins, w) end
  end
  local fillWin = rawSpanMap(ccWins)

  -- Clean channels carry their cc/at/pc columns whole: never visited.
  for chan = 1, 16 do
    if not dirtyChans[chan] then goto nextChan end
    for _, cc in mm:ccsRaw(chan) do
      local uuid = cc.uuid
      -- fx cc event: a markerless seat inside a prev cc window (its authored cc parked), routed out and
      -- reconciled fresh at fx expansion. A removed window's orphans reconcile away there. see § Route-by-window
      if cc.evType == 'cc' and inSpan(fillWin, cc.chan, cc.cc, cc.ppq) then
        util.add(ccExisting[cc.chan],
          { ppq = cc.ppq, val = cc.val, shape = cc.shape, cc = cc.cc, uuid = uuid })
        goto continue
      end

      -- Timing reconcile on the raw (read-only) record; capture what moved for the column clone.
      local movedPpq, movedPpqL
      if not cc.derived then
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
        local event = util.clone(cc)
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
    ::nextChan::
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

-- Lane packing for one externals pass. The overlap threshold and each event's intent onset are
-- invariant across the probe walk; a per-column head retires what the sweep has passed. see docs/trackerManager.md § Rebuild: externals
local function externalLanePacker(external)
  local lenient = cm:get('overlapOffset') * mm:resolution()
  local onsetI  = {}   -- [evt] = intent-frame onset; an event's never moves while the pass runs
  local head    = {}   -- [col] = first live index; everything below it ends too early to ever overlap

  -- Probes arrive in raw-ppq order but test in the intent frame, so the retirement floor trails the
  -- sweep by the pass's largest delay: monotone without reordering the pack. Diverged notes carry one.
  local maxDelayPpq = 0
  for _, note in ipairs(external) do
    maxDelayPpq = math.max(maxDelayPpq, delayToPPQ(note.delay or 0))
  end

  local function onsetOf(evt)
    local ppqI = onsetI[evt]
    if not ppqI then
      ppqI        = evt.ppq - delayToPPQ(evt.delay or 0)
      onsetI[evt] = ppqI
    end
    return ppqI
  end

  --contract: true iff note fits col: no over-threshold overlap, coincident onset always refuses
  --invariant: overlap threshold: same-pitch 0, cross-pitch lenient; dominated-by≥2 refuses
  --contract: consulted only for unstamped raw notes; stamped notes never reach it
  local function columnAccepts(col, note)
    local events  = col.events
    local floorPpq = note.ppq - maxDelayPpq
    local live     = head[col] or 1
    while live <= #events and events[live].endppq <= floorPpq do live = live + 1 end
    head[col] = live

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

  --contract: pick a lane for an external (unstamped) note via accept → sibling → push bump
  --invariant: called up front after internals placed + swing-reseated; tail walk clips tails after
  return function(channel, note)
    local notes = channel.columns.notes
    if note.lane then
      local col = notes[note.lane]
      if col and columnAccepts(col, note) then return col, note.lane end
      if not col then
        while #notes < note.lane do pushNoteCol(channel) end
        return notes[note.lane], note.lane
      end
    end
    for i, col in ipairs(notes) do
      if columnAccepts(col, note) then return col, i end
    end
    return pushNoteCol(channel)
  end
end

-- Reintroduce externals: pack lane, stamp ppqL/endppqL, backfill metadata, tag `fixed`; block window
-- + tail passes. Returns the seated notes, still raw, for projectNotes. see docs/trackerManager.md § Rebuild: externals
local function rebuildExternals(external)
  if #external == 0 then return {} end

  table.sort(external, function(a, b) return a.ppq < b.ppq end)
  local trackerMode = cm:get('trackerMode')
  local packLane    = externalLanePacker(external)
  local extWrites   = mmBatch()
  local seated      = {}
  for _, note in ipairs(external) do
    local delay     = note.delay or 0
    local d         = delayToPPQ(delay)
    local probe     = { ppq = note.ppq, endppq = note.endppq,
                        pitch = note.pitch, delay = delay, lane = note.lane }
    local col, lane = packLane(channels[note.chan], probe)
    local update    = {
      ppqL    = tm:toLogical(note.chan, note.ppq - d),
      endppqL = tm:toLogical(note.chan, note.endppq),
    }
    if note.lane   ~= lane then update.lane   = lane   end
    if note.detune == nil  then update.detune = 0      end
    if note.delay  == nil  then update.delay  = 0      end
    if trackerMode and note.sample == nil then update.sample = 0 end
    local colNote = util.clone(note)
    util.assign(colNote, update)
    colNote.fixed = true
    util.add(col.events, colNote)
    util.add(seated, colNote)
    extWrites.assign(colNote, update)
  end
  extWrites.commit()
  return seated
end

----- Rebuild region park

-- Clip each parked member's tail to its lane successor onset and take end (logical frame), against
-- bounds (unclipped on-take notes). Lane only -- see docs/trackerManager.md § Region-replace parking.
--contract: derives each member's endppqC (the render clip); the authored ceiling on endppq stands
local function realiseParked(members, takeLenL, bounds)
  local byLane = {}
  local function seat(evt) util.bucket(byLane, evt.lane, evt) end
  for _, m in ipairs(members)      do seat(m) end
  for _, b in ipairs(bounds or {}) do seat(b) end
  for _, g in pairs(byLane) do sortByPPQ(g) end
  local laneNextOf = strictNextMap(byLane)
  for _, m in ipairs(members) do
    local ceil = (m.endppq == nil or m.endppq == util.OPEN) and takeLenL or m.endppq
    local laneNext = laneNextOf[m]
    m.endppqC = math.max(m.ppq + 1, math.min(ceil,
      laneNext and laneNext.ppq or math.huge, takeLenL))
  end
end

-- Park = clone minus the realisation frame, so new authored metadata rides a park/unpark
-- round-trip untouched; restore mirrors it (clone back, re-derive realisation; pb also cents->raw).
local REALISATION = { delayC = true, endppqC = true, loc = true, realised = true, derived = true, frame = true, cents = true }
--contract: evt must be logical-frame (a column event); an mm-raw source overrides ppq via `adds`
local function parkSpec(evt, adds) return util.assign(util.clone(evt, REALISATION), adds) end

-- One raw-frame scratch record per on-take note; the walk's working shape (see buildRawScratch).
local SCRATCH_FIELDS = 'ppq ppqL endppq endppqL chan pitch lane evType detune sample overlap fixed'

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

local function rebuildRegionPark(deferred, currentWindows, fxParked, prevWindows)
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

  -- Notes: can't mute (note-on/off + CC matching), so a covered authored note leaves the take.
  do
    local scan = {}
    for chan = 1, 16 do
      if dirtyChans[chan] then   -- clean chan holds no on-take candidate a window could newly cover
        for laneIdx, col in ipairs(channels[chan].columns.notes) do
          for _, evt in ipairs(col.events) do
            -- Gate the clone on coverage: a no-fx take covers nothing, so the scan stays empty and the
            -- 8438-note column never spawns a throwaway parkSpec. covered(evt) == covered(its parkSpec).
            if evt.evType ~= 'pa' and covered(evt) then
              util.add(scan, { evt = evt, events = col.events,
                spec = parkSpec(evt, { lane = laneIdx }) })   -- evType/chan ride the event; lane pins the column index
            end
          end
        end
      end
    end

    -- Park removes a blocker; same-lane/pitch neighbours' tails regrow.
    local newParked, restores = reconcilePark(scan, priorByType.note or {},
      function(spec) dirtyChan(spec.chan) end)

    -- Restores re-enter their columns now (unrealised); the tail walk clips them in place and
    -- the tail walk's commit adds them after the derived deletions.
    for _, spec in ipairs(restores) do
      dirtyChan(spec.chan)   -- restored note re-enters columns; tail walk + absorber pass re-derive it
      local channel = channels[spec.chan]
      while #channel.columns.notes < spec.lane do pushNoteCol(channel) end
      local note = util.clone(spec)   -- the cell is the spec: both are logical (keeps the parked uuid too)
      -- The rec holds the walk's raw frame: endppq clears because only the walk can derive it (the
      -- spec's ceiling is logical, and lands on endppqL), then rides back to the cell via colEvt.
      local rec = util.pick(note, SCRATCH_FIELDS,
                            { colEvt = note, ppq = tm:fromLogical(spec.chan, note.ppq),
                              ppqL = note.ppq, endppqL = note.endppq, endppq = util.REMOVE })
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
        -- On-take survivors bound a parked tail on its own lane/pitch (rebuildTails' model), so a
        -- member clips to the first note after the region, not just the next parked member.
        local bounds = {}
        for _, col in ipairs(channels[chan].columns.notes) do
          for _, evt in ipairs(col.events) do
            if evt.evType ~= 'pa' then
              util.add(bounds, evt)
            end
          end
        end
        realiseParked(members, tm:toLogical(chan, takeLen), bounds)
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

    local newParked = {}
    -- Fresh: an on-take PA whose host just parked leaves the take and stashes.
    for chan = 1, 16 do
      if dirtyChans[chan] then
        for _, cc in mm:ccsRaw(chan) do
          if cc.evType == 'pa' and hostParked(cc.chan, cc.pitch, cc.ppqL or cc.ppq) then
            batch.del({ uuid = cc.uuid })
            local spec = parkSpec(cc, { ppq = cc.ppqL or cc.ppq })   -- mm-raw source: evType/chan/pitch/vel/rpb ride, ppq flips logical
            spec.uuid = nil                                           -- restore re-mints the rpb sidecar uuid
            util.add(newParked, spec)
          end
        end
      end
    end
    -- Prior parked PAs: host still parked -> carry; host returned on-take -> restore to the take.
    for _, spec in ipairs(priorByType.pa or {}) do
      if hostParked(spec.chan, spec.pitch, spec.ppq) then
        util.add(newParked, spec)
      else
        dirtyChan(spec.chan)
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
          for _, evt in ipairs(col.events) do
            if covered(evt) then   -- pre-filter (see the note pass): only covered ccs pay a parkSpec clone
              util.add(scan, { evt = evt, events = col.events,
                spec = parkSpec(evt, { cc = cc }) })   -- cc pins the column key; evType/chan/ppq ride the event
            end
          end
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
      for _, cc in mm:ccsRaw(win.chan) do
        if cc.evType == 'pb' and not cc.derived
           and cc.ppq >= sRaw and cc.ppq <= eRaw and not seatByRegion(cc.chan, cc.ppq) then
          dirtyChan(cc.chan)
          -- val: logical cents from mm's cents sidecar (restore maps back); a foreign pre-cents pb
          -- falls back to raw-derived cents (best-effort).
          local spec = parkSpec(cc, { ppq = cc.ppqL or cc.ppq,
                                      val = cc.cents or rawToCents(cc.val) })   -- from mm-raw: evType/chan/shape/tension ride; ppq flips logical, cents->val
          local pb = util.clone(cc); pb.realised = true
          util.add(scan, { evt = pb, spec = spec })
        end
      end
    end

    local newParked, restores = reconcilePark(scan, priorByType.pb or {})

    -- Restore re-adds to the take; the absorber (later this rebuild) refines the wire raw with
    -- detune and re-shows it. The seed val is detune-free -- the absorber's assign corrects it.
    for _, spec in ipairs(restores) do
      dirtyChan(spec.chan)
      batch.add(util.assign(util.clone(spec),
        { ppq = tm:fromLogical(spec.chan, spec.ppq), ppqL = spec.ppq,
          cents = spec.val, val = centsToRaw(spec.val) }))   -- spec.val is cents; the wire wants raw + a cents sidecar
    end

    -- Sweep queue (remove): a removed window's seats orphan (no marker names them) -- delete every mm pb
    -- in the swept raw span. The authored restored above is an unrealised add, so delete-first order is safe.
    for _, win in ipairs(pbRemoved) do
      local sRaw, eRaw = tm:fromLogical(win.chan, win.startppq), tm:fromLogical(win.chan, win.endppq)
      for _, cc in mm:ccsRaw(win.chan) do
        if cc.evType == 'pb' and cc.ppq >= sRaw and cc.ppq <= eRaw then
          dirtyChan(cc.chan)
          batch.del({ uuid = cc.uuid })
        end
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

-- The pass's raw note view: raw consumers read these records, never the columns.
-- see design/interval-dirt.md § Phase 3 for why, and what colEvt backrefs.
--shape: scratch[chan] = { ppq, ppqL, endppq, endppqL, chan, pitch, lane, evType, detune, sample, overlap, fixed, colEvt }[] -- dirty chans only
local function buildRawScratch(restoredRecs)
  local scratch = {}
  for chan = 1, 16 do
    if dirtyChans[chan] then
      local colByUuid = {}
      for _, col in ipairs(channels[chan].columns.notes) do
        for _, evt in ipairs(col.events) do
          if evt.uuid then colByUuid[evt.uuid] = evt end
        end
      end
      local recs = {}
      for _, raw in mm:notesRaw(chan) do
        if not raw.derived and raw.ppqL ~= nil then
          local rec = util.pick(raw, SCRATCH_FIELDS, { colEvt = colByUuid[raw.uuid] })
          rec.detune = rec.detune or 0   -- ingestion defaults it on the column note; mirror that
          util.add(recs, rec)
        end
      end
      scratch[chan] = recs
    end
  end
  -- Restores are column-only until the tail walk's deferred commit lands them in mm;
  -- rebuildRegionPark built their recs (cell backref included) as it re-seated them.
  for _, rec in ipairs(restoredRecs) do
    util.add(scratch[rec.chan], rec)
  end
  return scratch
end

----- Rebuild PA

local function findNoteColumnForPitch(channel, pitch, ppq_pos, chanScratch)
  local notes = channel.columns.notes
  -- Containment is raw geometry: scan the scratch; lowest lane wins, matching column order.
  local coveringLane
  for _, rec in ipairs(chanScratch) do
    if rec.endppq and rec.pitch == pitch and rec.ppq <= ppq_pos and rec.endppq > ppq_pos
       and (coveringLane == nil or rec.lane < coveringLane) then
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
local function rebuildPA(scratch)
  local touched = {}
  for chan = 1, 16 do
    if dirtyChans[chan] then   -- clean: PA already sits in the carried note column
      for _, cc in mm:ccsRaw(chan) do
        if cc.evType == 'pa' then
          local noteCol, lane = findNoteColumnForPitch(channels[chan], cc.pitch, cc.ppq, scratch[chan])
          if noteCol then
            local cell = projectCC(cc, { lane = lane })
            projectEvent(cell, chan)
            util.add(noteCol.events, cell)
            touched[chan] = true
          end
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
        local noteCol, lane = findNoteColumnForPitch(channels[chan], cell.pitch, ppq, scratch[chan])
        if noteCol then
          util.add(noteCol.events, projectCC(cell, nil, { lane = lane }))   -- the cell is logical-born
          touched[chan] = true
        end
      end
    end
  end
  return touched
end

----- Rebuild Fx

-- fx host voice extents: authored end, take end, or strict next same-lane onset -- soonest wins. A pure,
-- G4-stable scan of all 16 chans (parking + recognition see the whole set), sort gated by unsortedChans. see design/archive/note-macros.md § host contract, design/archive/logical-column-order.md
local function computeFxWindows(unsortedChans)
  local fxWindow = {}
  local takeLen = tm:length()
  for chan = 1, 16 do
    if unsortedChans[chan] then
      for _, col in ipairs(channels[chan].columns.notes) do sortNoteColumn(col.events) end
    end
    local takeLenL = tm:toLogical(chan, takeLen)
    for _, col in ipairs(channels[chan].columns.notes) do
      -- Chord-mates share an onset and so share a successor: hold each host open until an event with a
      -- greater ppq arrives, then clip them all against it. col.events is ppq-ordered.
      local openHosts = {}
      for _, evt in ipairs(col.events) do
        if evt.evType ~= 'pa' then
          if openHosts[1] and evt.ppq > openHosts[1].ppq then
            for _, host in ipairs(openHosts) do fxWindow[host] = math.min(fxWindow[host], evt.ppq) end
            openHosts = {}
          end
          if evt.fx then
            -- Take is the world: a tail past take end (paste / overshooting move) can't sound past it.
            fxWindow[evt] = (evt.endppq == nil or evt.endppq == util.OPEN)
                            and takeLenL or math.min(evt.endppq, takeLenL)
            util.add(openHosts, evt)
          end
        end
      end
    end
  end
  return fxWindow
end

-- Fx expansion: fx-carrying notes / fx-regions -> derived notes, CCs;
-- reconcile vs existing, note writes deferred to the tail walk. see design/note-macros-v2.md § Offline continuous realisation
local function rebuildFx(noteExisting, ccExisting, deferred, fxWindow, currentWindows, fxRegions)
  -- Columns must be ppq-ordered here (eachWindowNote / allocateRegionLanes / membersOf read col.events
  -- directly); the computeFxWindows call immediately upstream sorted them and nothing since reorders.

  -- Region note-park windows: a parked cell inside one is region membership, not a note host.
  local function noteParkCovered(chan, ppq)
    for _, win in ipairs(currentWindows) do
      if win.evType == 'note' and win.chan == chan and ppq >= win.startppq and ppq < win.endppq then
        return true
      end
    end
    return false
  end

  -- Authored pb breakpoints per channel, exposed to the generator as channel input (authored
  -- only, fakes excluded) -- only expandChannel reads it, gated dirty. see design/note-macros-v2.md § A4
  local authoredPbByChan = {}
  for chan = 1, 16 do
    if dirtyChans[chan] then
      for _, cc in mm:ccsRaw(chan) do
        if cc.evType == 'pb' and not cc.derived and cc.cents ~= nil then
          util.bucket(authoredPbByChan, cc.chan, { ppq = cc.ppqL or cc.ppq, cents = cc.cents, shape = cc.shape })
        end
      end
    end
  end
  for _, list in pairs(authoredPbByChan) do sortByPPQ(list) end

  -- Absolute authored bases per channel (ppq-keyed, logical): parked events are authoritative in their
  -- windows (dedup by ppq), the on-take stream elsewhere. Seeds + the cross-chain fold read them.
  local function pbBaseFor(chan)
    local base, seen = {}, {}
    for _, cell in ipairs(channels[chan].parkedPb or {}) do
      util.add(base, { ppq = cell.ppq, val = cell.cents, shape = cell.shape or 'step', tension = cell.tension })
      seen[cell.ppq] = true
    end
    for _, point in ipairs(authoredPbByChan[chan] or {}) do
      if not seen[point.ppq] then
        util.add(base, { ppq = point.ppq, val = point.cents, shape = point.shape or 'step' })
      end
    end
    sortByPPQ(base)
    return base
  end
  local function ccBasesFor(chan)
    local bases, seen = {}, {}
    for _, cell in ipairs(channels[chan].parkedCC or {}) do
      util.bucket(bases, cell.cc, { ppq = cell.ppq, val = cell.val, shape = cell.shape or 'step' })
      seen[util.key(cell.cc, cell.ppq)] = true
    end
    for cc, col in pairs(channels[chan].columns.ccs) do
      for _, evt in ipairs(col.events) do
        if not seen[util.key(cc, evt.ppq)] then
          util.bucket(bases, cc, { ppq = evt.ppq, val = evt.val, shape = evt.shape or 'step' })
        end
      end
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
  -- Strict next same-lane note, built per channel on first ask: slide(target='next') is its only
  -- consumer, so a channel no slide queries never pays for the map. see design/archive/incremental-rebuild.md § 8
  local laneNextByChan = {}
  local function nextSameLaneNote(host)
    local note = host.notes[1]
    if not note then return nil end
    local laneNextOf = laneNextByChan[note.chan]
    if not laneNextOf then
      local byLane = {}
      for laneIdx, col in ipairs(channels[note.chan].columns.notes) do
        for _, evt in ipairs(col.events) do
          if evt.evType ~= 'pa' then util.bucket(byLane, laneIdx, evt) end
        end
      end
      laneNextOf = strictNextMap(byLane)   -- ppq-ordered: computeFxWindows sorted col.events
      laneNextByChan[note.chan] = laneNextOf
    end
    return laneNextOf[note]
  end
  local chanCtx = { resolution = res, pbRangeCents = pbRangeCents, step = stepOp,
                    nextSameLaneNote = nextSameLaneNote }
  -- Explicit fx-regions (channel x ppq span + fx, no host note), re-queried each
  -- rebuild and bucketed by channel. see design/note-macros-v2.md § The anchor generalized
  local fxRegionsByChan = {}
  for _, region in ipairs(fxRegions or {}) do
    util.bucket(fxRegionsByChan, region.chan, region)
  end

  -- Producer-owned outputs: post-expansion live notes, per-chain pb curves, authored pb base per chan.
  local fxOut = { noteLive = emptyChans(), pbChains = emptyChans(), pbBase = emptyChans() }

  -- Pass A: run every chain as a series -- each stage folds into the stream by mode x dest, and
  -- the final owned channels emit. see design/note-macros-v2.md § The fx chain
  local function expandChannel(chan)
    local predicted, ccLive = {}, {}
    local pbBase, ccBases = pbBaseFor(chan), ccBasesFor(chan)
    fxOut.pbBase[chan] = pbBase
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

    -- Note producers. Only augment hosts (continuous kinds) remain on-take -- a discrete-replace
    -- host was parked at 4.5 and runs from its parked cell below. Derived notes ride the host lane.
    for laneIdx, col in ipairs(channels[chan].columns.notes) do
      for _, host in ipairs(col.events) do
        if host.fx and host.evType ~= 'pa' then
          runProducer(hostProducer(host, fxWindow[host], laneIdx))
        end
      end
    end

    -- Parked note hosts: the host left the take (note-host replace parks, like a region), so
    -- every hit is derived output. Window = the parked cell's realised extent (realiseParked
    -- applies the same bounds fxWindow would). A cell inside a region note-park window is region
    -- membership, not a host (own-fx suppressed -- the retained gap).
    for _, cell in ipairs(channels[chan].parked or {}) do
      if cell.fx and not noteParkCovered(chan, cell.ppq) then
        runProducer(hostProducer(soundingCell(cell), cell.endppqC, cell.lane))
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
      runProducer{ window = { startL, endL }, notes = members,
                   fx = region.fx, id = region.uuid, lane = nil, delayPpq = 0 }
    end

    -- Reconcile existence (stamps kept specs with the mm handle + realised end); defer writes to the tail walk's atomic commit.
    -- fxOut.noteLive holds the predicted specs; the tail walk clips them in place.
    reconcileFx(noteExisting[chan], predicted, deferred)
    for _, spec in ipairs(predicted) do
      util.add(fxOut.noteLive[chan], { evt = spec, lane = spec.lane })
    end

    -- cc emission: per target, merge chain windows and fold (foldChains) into markerless seats on the
    -- target lane; half-open -- the closing value belongs to the next window. see design/note-macros-v2.md § The fx chain
    for cc, recs in pairs(ccChains) do
      local base = ccBases[cc] or {}
      if #base == 0 then
        local rest, minStart = firstRestOverride(recs) or generators.ccDefaultRest[cc] or 0, math.huge
        for _, rec in ipairs(recs) do minStart = math.min(minStart, rec.window[1]) end
        base = { { ppq = minStart, val = rest, shape = 'step' } }
      end
      for _, span in ipairs(mergeWindows(recs)) do
        for _, point in ipairs(foldChains(recs, span, base, { closed = true })) do
          if point.ppq < span[2] then
            util.add(ccLive, { evType = 'cc', chan = chan, cc = cc,
                               ppq = tm:fromLogical(chan, point.ppq, 0),
                               val = util.clamp(util.round(point.val), 0, 127), shape = point.shape })
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
      match = function(have, spec) return have.val == spec.val and have.shape == spec.shape end,
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
local function rebuildTails(noteLive, deferred, scratch)
  local takeLen = tm:length()
  local res = mm:resolution()
  local clampWrites = mmBatch()
  for chan = 1, 16 do
    -- Clean channels freeze: fx left noteLive empty, real notes converged last rebuild.
    if not dirtyChans[chan] then goto nextChan end
    local notes, byLane, byPitch = {}, {}, {}
    for _, rec in ipairs(scratch[chan]) do
      util.add(notes, rec)
    end
    for _, w in ipairs(noteLive[chan]) do
      util.add(notes, w.evt)
    end
    if #notes == 0 then goto nextChan end

    -- Parked members left the columns but still bound a preceding on-take tail in their lane --
    -- the symmetric partner of realiseParked's on-take bounds. Bound-only: never rewritten below.
    local parkedBounds = {}
    for _, cell in ipairs(channels[chan].parked or {}) do
      util.add(parkedBounds, { ppq = tm:fromLogical(chan, cell.ppq), ppqL = cell.ppq,
                               lane = cell.lane })
    end

    local function rawThenLogical(a, b)
      if a.ppq ~= b.ppq then return a.ppq < b.ppq end
      return a.ppqL < b.ppqL
    end
    -- Sort notes once; the buckets partition notes, so rebuilding them by walking the
    -- sorted array yields sorted buckets in O(N) -- cheaper than re-sorting each bucket.
    local function sortAll()
      table.sort(notes, rawThenLogical)
      byLane, byPitch = {}, {}
      for _, n in ipairs(notes) do
        util.bucket(byLane,  n.lane,  n)
        util.bucket(byPitch, n.pitch, n)
      end
    end
    sortAll()

    -- Same-pitch onset separation; retro-clip subsumed by tail pass. Realised events assign;
    -- a new fxNote (not yet in mm) mutates in place, riding into mm:add at the atomic commit.
    local moved = voicing.nudgeOnsets(notes)
    for _, n in ipairs(moved) do
      if n.lane == 1 then dirtyChan(chan) end   -- nudged lane-1 onset moves absorber seats (pbs runs after tails)
      local backing = n.colEvt or n   -- scratch recs write through to their column note; fxNotes ride bare
      if n.colEvt and n.colEvt.delay ~= nil then
        -- The column stays logical; only the delayC give-way cue carries the raw shift.
        n.colEvt.delayC = util.round(timing.ppqToDelay(n.ppq - tm:fromLogical(chan, n.ppqL), res))
      end
      if backing.realised then clampWrites.assign(backing, { ppq = n.ppq }) end
    end
    -- Re-sort only when a nudge actually moved an onset (rare); otherwise ordering stands.
    if #moved > 0 then sortAll() end

    local laneNextOf  = strictNextMap(byLane)
    local pitchNextOf = strictNextMap(byPitch)

    -- On-take tails clip against parked members' lanes too -- the columns no longer carry the cell,
    -- but the lane geometry still does. See docs/trackerManager.md § Rebuild: tail walk.
    local laneNextOn = laneNextOf
    if #parkedBounds > 0 then
      local byLaneP = {}
      for _, n in ipairs(notes)        do util.bucket(byLaneP, n.lane, n) end
      for _, b in ipairs(parkedBounds) do util.bucket(byLaneP, b.lane, b) end
      for _, g in pairs(byLaneP) do table.sort(g, rawThenLogical) end
      laneNextOn = strictNextMap(byLaneP)
    end

    for _, e in ipairs(notes) do
      local onTake    = not e.derived
      local ceiling   = e.endppqL == util.OPEN and math.huge
                        or e.endppqL and tm:fromLogical(chan, e.endppqL)
                        or math.huge
      local laneNext  = (onTake and laneNextOn or laneNextOf)[e]
      local pitchNext = pitchNextOf[e]
      local laneClip  = laneNext
        and tm:fromLogical(chan, laneNext.ppqL) + (e.overlap or 0)
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
    ::nextChan::
  end
  -- Clamps commit first: separating colliding same-pitch onsets settles mm's content keys before
  -- the clip pass runs. Clips only touch endppq — safe to batch with adds.
  clampWrites.commit()
  -- fxNote del/add + parked restores commit in one mm:modify/MIDI_Sort; canonical
  -- delete-first means no transient same-pitch overlap.
  deferred.commit()
end

----- Rebuild Pbs

-- Reseat absorber pbs against the post-walk lane-1 layout, recompute their raw vals,
-- and project the pb column. see docs/tuning.md § Absorber reconciliation
local function rebuildPbs(fxOut, extraColumns, scratch)
  local noteLive, pbChains, pbBase = fxOut.noteLive, fxOut.pbChains, fxOut.pbBase
  -- Reads only the per-chan .pb keep-flag; rebuildExtraColumns's mid-pipeline write grows
  -- .notes only, so the head snapshot is current for this. see design/rebuild-pipeline.md § The pre-phase
  local extras = extraColumns or {}

  local function detuneAt(events, P)
    local n = util.seek(events, 'at-or-before', P)
    return (n and n.detune) or 0
  end

  perf.start('gather')
  -- Dirty gate on the shared spine, hoisted ahead of lane-1 sort and clone (both skip clean chans).
  -- Frozen fx channels are not dirty: their derived output stands in mm, absorber seats carried.
  local dirty = {}
  for chan = 1, 16 do
    dirty[chan] = dirtyChans[chan] or nil
  end

  -- Per-chan lane-1 sort, consumed only by deriveChan: built for dirty channels alone. Clean
  -- channels reuse their carried pb column and never read it.
  local lane1ByChan = {}
  for chan = 1, 16 do
    if dirty[chan] then
      local list = {}
      for _, rec in ipairs(scratch[chan]) do
        if rec.lane == 1 then util.add(list, rec) end
      end
      -- Derived lane-1 fxNotes are routed out of columns; union them so the absorber pass seats
      -- their detune jumps.
      for _, w in ipairs(noteLive[chan]) do
        if w.lane == 1 then util.add(list, w.evt) end
      end
      table.sort(list, function(a, b) return a.ppq < b.ppq end)
      lane1ByChan[chan] = list
    end
  end

  -- Each pb rides its own clone through the pass, carrying mm's uuid so a mutated clone still
  -- names its source; origShape is held because the pass rewrites shape. Only dirty channels clone.
  local pbsByChan = {}
  for chan = 1, 16 do
    if dirty[chan] then
      for _, cc in mm:ccsRaw(chan) do
        if cc.evType == 'pb' then
          local pb = util.clone(cc)
          pb.realised, pb.origShape = true, cc.shape
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
  local function deriveChan(chan, lane1Events, pbs)
    perf.start('seats')
    -- pb chain windows: each chain's curve seats as derived pbs on the base lane (no carrier); overlap
    -- folds onto the authored base (foldChains). Bounds convert to raw once for zero round-trip drift. see docs/tuning.md § Absorber reconciliation
    local lim = pbLim()
    local replaceWins = {}
    for _, span in ipairs(mergeWindows(pbChains[chan])) do
      local bps = {}
      for _, point in ipairs(foldChains(pbChains[chan], span, pbBase[chan], { closed = true })) do
        util.add(bps, { ppq = tm:fromLogical(chan, point.ppq, 0), ppqL = point.ppq,
                        cents = util.clamp(point.val, -lim, lim), shape = point.shape, tension = point.tension })
      end
      table.sort(bps, function(a, b) return a.ppq < b.ppq end)
      util.add(replaceWins, { bps = bps,
                              startRaw = tm:fromLogical(chan, span[1], 0),
                              endRaw   = tm:fromLogical(chan, span[2], 0) })
    end

    -- Which window's curve prevails at a raw ppq (half-open -- the interior stream).
    local function replaceWinAt(ppq)
      for _, win in ipairs(replaceWins) do
        if ppq >= win.startRaw and ppq < win.endRaw then return win end
      end
    end
    -- Seat recognition: exclusive ownership means everything on-take in a window is a generated seat
    -- (authored pbs park off-take). Inclusive of endRaw to catch the terminal re-centre seat.
    local function inSeatWindow(ppq)
      for _, win in ipairs(replaceWins) do
        if ppq >= win.startRaw and ppq <= win.endRaw then return true end
      end
      return false
    end

    -- Back-derive cents for any authored pb missing it (foreign-MIDI/pre-cents pbs carry raw only) so the
    -- assign carries cents to the sidecar; an in-window seat must not acquire cents or it stops looking like a seat.
    local persistCents = {}
    for _, pb in ipairs(pbs) do
      if pb.cents == nil and not inSeatWindow(pb.ppq) then
        pb.cents = rawToCents(pb.val) - detuneAt(lane1Events, pb.ppq)
        persistCents[pb] = true
      end
    end

    -- Authored (non-derived, out-of-window) pbs in ppq order: the value stream the seats sample.
    local realPbs = {}
    for _, pb in ipairs(pbs) do
      if not pb.derived and not inSeatWindow(pb.ppq) then util.add(realPbs, pb) end
    end

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

    -- Detune onsets: every lane-1 ppq whose detune differs from its predecessor.
    local onsets, prev = {}, 0
    for _, n in ipairs(lane1Events) do
      if n.detune ~= prev then util.add(onsets, { ppq = n.ppq, ppqL = n.ppqL }) end
      prev = n.detune
    end

    -- Seats to realise: ppq -> { cents, ppqL, shape }. The consolidated assign turns each
    -- into wire raw = centsToRaw(cents + detune). A flat/held/absent stream needs only a
    -- lone step seat; a value that ramps across the onset rides linearly, so the detune
    -- step splits onto a dual point and a curved segment densifies. see docs/tuning.md
    local seats = {}
    for _, o in ipairs(onsets) do
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
            if not seats[p] then
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
    local first = lane1Events[1]
    if first and not seats[first.ppq] then
      local hasReal, anchored = false, false
      for _, pb in ipairs(realPbs) do
        hasReal = true
        if pb.ppq <= first.ppq then anchored = true break end
      end
      if (next(seats) ~= nil or hasReal) and not anchored then
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
      if pb.derived then util.add(availAbsorbers, pb)
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
        local raw = centsToRaw(fresh.cents + detuneAt(lane1Events, ppq))
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

    local detuneOf = mergeDetunes(pbs, lane1Events)
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
        elseif pb.val ~= newRaw or persistCents[pb] or shapeChanged then
          update = { cents = pb.cents, val = newRaw }
        end
        if update then
          if pb.derived then update.shape = pb.shape end
          -- A markerless seat persists native MIDI only; strip the sidecar fields so the assign
          -- stamps no metadata and the seat stays plain. Its ppq/val/shape still land.
          if markerless then update.cents, update.ppqL = nil, nil end
          pb.val = newRaw
          pbWrites.assign({ uuid = pb.uuid }, update)
        end
      end
    end
    perf.stop('assign')
    return detuneOf
  end

  for chan = 1, 16 do
    -- Clean channels are skipped wholesale -- their carried pb column stands (set at rebuild entry).
    if dirty[chan] then
      local lane1Events = lane1ByChan[chan]
      local pbs         = pbsByChan[chan] or {}
      table.sort(pbs, function(a, b) return a.ppq < b.ppq end)

      local detuneOf = deriveChan(chan, lane1Events, pbs)

      perf.start('project')
      -- Column projection. A derived seat is wire-only -- always hidden.
      local anyVisible, pbColEvents = false, {}
      for _, pb in ipairs(pbs) do
        local hidden = pb.derived ~= nil
        anyVisible = anyVisible or not hidden
        -- pb is our own working clone, done being read by the assign above -- reuse it as the
        -- column event rather than cloning again.
        pb.val, pb.detune, pb.hidden = pb.cents, detuneOf[pb], hidden
        projectEvent(pb, chan)
        util.add(pbColEvents, pb)
      end
      local keep = anyVisible or (extras[chan] and extras[chan].pb)
      channels[chan].columns.pb = keep and { events = pbColEvents } or nil
      perf.stop('project')
    end
  end

  perf.start('commit')
  pbWrites.commit()
  perf.stop('commit')
end

----- Rebuild PCs

-- PC synthesis (trackerMode only). Runs after externals so a foreign-MIDI note inherits
-- sample from the prevailing PC.
local function rebuildPCs(noteLive, scratch)
  if not cm:get('trackerMode') then return end
  local pcWrites = mmBatch()
  for chan = 1, 16 do
    -- Clean channels freeze: their PCs stand in mm and their pc column is carried forward.
    if not dirtyChans[chan] then goto nextChan end
    local records = {}
    for _, rec in ipairs(scratch[chan]) do
      util.add(records, { ppq = rec.ppq, ppqL = rec.ppqL, lane = rec.lane, sample = rec.sample or 0, key = rec.colEvt })
    end
    for _, w in ipairs(noteLive[chan]) do
      local n = w.evt
      util.add(records, { ppq = n.ppq, ppqL = n.ppqL, lane = w.lane, sample = n.sample or 0, key = n })
    end
    reconcilePCsForChan(chan, records, pcWrites)
    ::nextChan::
  end
  pcWrites.commit()

  -- Refresh every pc column from mm (frozen channels' PCs stand). reconcilePCsForChan leaves
  -- c.pc.events unwritten (its invariant), so rebuild it here from the committed stream.
  for chan = 1, 16 do
    if dirtyChans[chan] then
      channels[chan].columns.pc = { events = {} }
      for _, cc in mm:ccsRaw(chan) do
        if cc.evType == 'pc' then
          local cell = projectCC(cc)
          projectEvent(cell, chan)
          util.add(channels[chan].columns.pc.events, cell)
        end
      end
      sortByPPQ(channels[chan].columns.pc.events)
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

  perf.start('internals'); local internal, external, noteExisting = rebuildInternals(); perf.stop('internals')  -- partition; internal cols; reseat swing notes
  perf.start('ccs'); local ccExisting = rebuildCCs(sources.prevWindows); perf.stop('ccs')  -- CC walk; reseat swing CCs
  staleSwing = {}                               -- swing consumers (partition + CC walk) done; see :53 invariant
  perf.start('extraCols'); rebuildExtraColumns(sources.extraColumns); perf.stop('extraCols')  -- reconcile persisted extra columns
  perf.start('externals'); local seatedExternals = rebuildExternals(external); perf.stop('externals')  -- reintroduce foreign / diverged notes

  -- Note columns flip to logical here, not at ingestion: partition, reseat and the externals' lane
  -- packer need the raw frame; the walk covers this pass's clones only. see docs/trackerManager.md § Rebuild: logical projection
  perf.start('projectNotes')
  for _, evt in ipairs(internal)        do projectEvent(evt, evt.chan) end
  for _, evt in ipairs(seatedExternals) do projectEvent(evt, evt.chan) end
  perf.stop('projectNotes')

  -- Park window set: fx-regions plus every on-take note host as a degenerate region (note-is-a-region),
  -- from the settled columns. The producer re-scans post-unpark below. see design/note-macros-v2.md § Offline continuous realisation
  perf.start('fxWindows'); local hostWindows = computeFxWindows(dirtyChans); perf.stop('fxWindows')
  perf.start('parkRegions')
  local parkRegions = {}
  for _, r in ipairs(sources.fxRegions or {}) do util.add(parkRegions, r) end
  for chan = 1, 16 do
    for _, col in ipairs(channels[chan].columns.notes) do
      for _, host in ipairs(col.events) do
        if host.fx and host.evType ~= 'pa' and hostWindows[host] then
          util.add(parkRegions, { chan = chan, startppq = host.ppq, endppq = hostWindows[host],
                                  fx = host.fx, noteHost = true })
        end
      end
    end
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

  perf.start('regionPark'); local restoredNotes = rebuildRegionPark(deferred, currentWindows, sources.fxParked, sources.prevWindows); perf.stop('regionPark')  -- park covered, carry/restore prior
  perf.start('rawScratch'); local rawScratch = buildRawScratch(restoredNotes); perf.stop('rawScratch')  -- the pass's raw note view, from mm now the on-take set is settled
  perf.start('pa'); local paTouched = rebuildPA(rawScratch); perf.stop('pa')  -- project PAs into settled note columns

  -- Re-scan windows post park/unpark/PA: the producer reads the final columns, including a host an unpark
  -- just restored (a replace host that lost its note-producing kind falls back to on-take augment).
  perf.start('fxWindows'); local fxWindow = computeFxWindows(paTouched); perf.stop('fxWindows')
  perf.start('fx'); local fxOut = rebuildFx(noteExisting, ccExisting, deferred, fxWindow, currentWindows, sources.fxRegions); perf.stop('fx')  -- fx expansion: derived notes/CCs

  perf.start('tails'); rebuildTails(fxOut.noteLive, deferred, rawScratch); perf.stop('tails')  -- unified tail/onset walk + atomic note commit

  -- The deferred commit added each restored note to mm; mark its column cell realised so an
  -- immediate edit resolves the backing (else the cell is inert until the next full rebuild).
  for _, rec in ipairs(restoredNotes) do
    if tm:byUuid(rec.colEvt.uuid) then rec.colEvt.realised = true end
  end
  perf.start('pbs'); rebuildPbs(fxOut, sources.extraColumns, rawScratch); perf.stop('pbs')  -- absorber reconciliation + pb resynthesis
  perf.start('pcs'); rebuildPCs(fxOut.noteLive, rawScratch); perf.stop('pcs')  -- PC synthesis (trackerMode)

  -- Persist this rebuild's window set: next rebuild recognizes seats against it (prev-keyed). see § Route-by-window
  perf.start('prevWindows')
  if mm:take() and not util.deepEq(sources.prevWindows or {}, currentWindows) then
    ds:assign('prevWindows', #currentWindows > 0 and currentWindows or util.REMOVE)
  end
  perf.stop('prevWindows')

  -- Index: full reload only when mm re-read its event set (load/reload); edit rebuilds
  -- trust the incremental index and just clear staging. see docs § Incremental index reconciliation
  perf.start('view'); if didReload then reload() else clearStaging() end; perf.stop('view')
  for chan in pairs(dirtyChans) do muteConform[chan] = true end
  dirtyChans = {}   -- gated stages consumed the spine; next edit window accumulates fresh
  perf.start('derivedInputs')
  derivedInputs = util.deepClone(derivationInputs())   -- after the pipeline's own ds writes have settled
  perf.stop('derivedInputs')
end

--contract: reentrancy-guarded; rebuilds channels[] from mm, reloads um cache, fires 'rebuild'
--contract: takeChanged forwarded to subscribers via the captured pendingTakeSwap
--contract: dead take (mm:take() nil) is a no-op; tv retains its last frame
-- see docs/trackerManager.md § Rebuild
function tm:rebuild(takeChanged)
  if rebuilding then return end
  if not mm:take() then return end
  rebuilding = true
  takeChanged = takeChanged or false
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
      -- Interval dirt narrows note materialisation only: every other producer (ccs, park, pb) still
      -- wants the fresh channel a dirty chan has always handed it. see docs/trackerManager.md § Derivation dirt: the gated spine
      channels[i] = { chan = i, columns = { notes = prevChannels[i].columns.notes, ccs = {} } }
    else
      channels[i] = prevChannels[i]
    end
  end

  -- One nest for all nine staging stages, so the reindex and the take reprojection land once each
  -- rather than once per stage. rebuilding must outlive it: each stage's commit re-enters via 'reload'.
  mm:batch(function() rebuildPipeline(didReload) end)
  rebuilding = false

  --emits: rebuild -- takeChanged:boolean
  --contract: rebuild fires at end of every rebuild after the um cache is reloaded
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
      -- Region edits re-derive; the rebuild diffs current vs persisted windows for park/sweep. see § Route-by-window
      if not flushingParked then dirtyChan(); tm:rebuild(false) end
    elseif change.name == 'extraColumns' or change.name == 'fxParked' then
      -- parking/extraColumns drive fx expansion + the pb keep-decision (inside the gated passes) -- re-derive.
      if not flushingParked then dirtyChan(); tm:rebuild(false) end
    elseif change.name == 'noteDelay' then
      -- noteDelay is a display offset -- nothing in the tm pipeline reads it; reproject only.
      if not flushingParked then tm:rebuild(false) end
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
