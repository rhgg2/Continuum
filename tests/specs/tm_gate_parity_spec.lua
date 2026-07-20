-- Gated-vs-full parity: the shadow harness design/archive/dirty-channels.md § Validation names as the
-- prerequisite for phase B. Exploits I8 (a no-edit rebuild is a fixpoint): after an edit, a gated
-- rebuild -- which re-READS untouched channels' persisted derivation -- must project byte-identically
-- to a forced all-16 rebuild that re-DERIVES every channel from mm. Divergence means a gate froze a
-- channel whose persisted state was not a true fixpoint. Volatile identity (loc) is stripped;
-- everything the view renders is compared. This pins phase A now and guards phase B's retention next.

local t = require('support')
local util = require('util')

local classic58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }

local vib30 = { { kind = 'vibrato', period = { 1, 4 }, depth = 30, onset = 0 } }
local arpUp = { { kind = 'arp',     period = { 1, 4 }, dir = 'up' } }
local pan   = { { kind = 'autopan', period = { 1, 2 }, depth = 32 } }

local function note(chan, ppq, pitch, extra)
  local n = { evType = 'note', ppq = ppq, endppq = ppq + 240, chan = chan, pitch = pitch,
              vel = 100, detune = 0, delay = 0, lane = 1 }
  for k, v in pairs(extra or {}) do n[k] = v end
  return n
end

-- Volatile per-rebuild identity: mm-side loc, the pb working clone's pre-rewrite shape, and the
-- reconcile skeleton's key. None render; all legitimately differ between a carried and a fresh frame.
local VOLATILE = { loc = true, origShape = true, key = true }

local function projEvt(e)
  local out = {}
  for k, v in pairs(e) do if not VOLATILE[k] then out[k] = v end end
  return out
end

-- Canonical, order-independent column projection: strip volatile fields, sort by repr so a
-- same-ppq tie (Lua's table.sort is unstable) can't spuriously diverge the two frames.
local function projCol(col)
  if not col then return nil end
  local evs = {}
  for _, e in ipairs(col.events or col) do evs[#evs + 1] = projEvt(e) end
  table.sort(evs, function(a, b) return t.repr(a) < t.repr(b) end)
  return evs
end

local function projectFrame(tm)
  local frame = {}
  for chan = 1, 16 do
    local channel = tm:getChannel(chan)
    local c = channel.columns
    local f = { notes = {}, ccs = {} }
    for lane, col in ipairs(c.notes) do f.notes[lane] = projCol(col) end
    for ccNum, col in pairs(c.ccs)    do f.ccs[ccNum] = projCol(col) end
    f.pb = projCol(c.pb); f.pc = projCol(c.pc); f.at = projCol(c.at)
    f.parked   = channel.parked   and projCol(channel.parked)   or nil
    f.parkedCC = channel.parkedCC and projCol(channel.parkedCC) or nil
    frame[chan] = f
  end
  return frame
end

-- The rendered grid: each column's built cells/tails/ghosts. B2 carries a clean channel's built cells
-- across an edit rebuild; this pins that carry against a forced full re-derive, as the frame is above.
local function projGrid(vm)
  local out = {}
  for i, col in ipairs(vm.grid.cols) do
    local cells = {}
    for row, evt in pairs(col.cells) do cells[row] = projEvt(evt) end
    local ghosts
    if col.ghosts then
      ghosts = {}
      for row, g in pairs(col.ghosts) do
        ghosts[row] = { val = g.val, fromEvt = projEvt(g.fromEvt), toEvt = projEvt(g.toEvt) }
      end
    end
    out[i] = { type = col.type, lane = col.lane, cc = col.cc, midiChan = col.midiChan,
               cells = cells, overflow = col.overflow, offGrid = col.offGrid,
               tails = col.tails, ghosts = ghosts }
  end
  return out
end

-- The wire-side derived state (carriers, absorber pbs, derived fx notes) is routed out of columns or
-- hidden, so the projected frame never sees it. mm content is its shadow: a converged take that a full
-- re-derive leaves byte-identical proves those hidden derivations were a fixpoint too. loc churns
-- each rebuild; uuid is durable, so a content bag keyed on the rest is the stable comparison.
local function stripRec(e)
  local out = {}
  for k, v in pairs(e) do if k ~= 'loc' then out[k] = v end end
  return out
end

local function mmBag(h)
  local dump, bag = h.fm:dump(), {}
  for _, n in ipairs(dump.notes) do bag[#bag + 1] = stripRec(n) end
  for _, c in ipairs(dump.ccs)   do bag[#bag + 1] = stripRec(c) end
  return bag
end

-- Snapshot the gated frame + mm content, then force a full all-16 re-derive. rebuild(true) marks every
-- channel dirty (the didReload/takeChanged seam) without a take swap, so it re-derives from mm rather
-- than re-reading. Both the projected frame and the mm content must be the fixpoint the gate assumed.
local function assertParity(h, msg)
  local gatedFrame = projectFrame(h.tm)
  local gatedGrid  = projGrid(h.vm)
  local mmBefore   = mmBag(h)
  h.tm:rebuild(true)
  t.deepEq(projectFrame(h.tm), gatedFrame, msg .. ' [projected frame]')
  t.bagEq(mmBag(h), mmBefore, msg .. ' [mm content: full re-derive staged no change]')
  t.deepEq(projGrid(h.vm), gatedGrid, msg .. ' [view grid: carried cells == full re-derive]')
end

return {
  {
    name = 'gated rebuild projects identically to a forced full rebuild across a rich frame',
    run = function(harness)
      -- Global swing so every channel's raw<->logical projection is non-identity, exercising the
      -- reseat/projection path that a frozen channel re-reads rather than recomputes.
      local h = harness.mk{
        config = { project = { swings = { c58 = classic58 } } },
        data   = { swing = { global = 'c58' } },
        groups = true,
      }

      -- chan 1: plain edit target.  chan 2: detuned lane-1 -> absorber pb stream.
      -- chan 3: vibrato host -> pb seats.  chan 4: arp region -> parked host + derived notes.
      h.tm:addEvent(note(1, 0,   60));                 h.tm:flush()
      h.tm:addEvent(note(2, 0,   64, { detune = 25 })); h.tm:flush()
      h.tm:addEvent(note(3, 0,   67, { fx = vib30 }));  h.tm:flush()
      h.tm:addEvent(note(4, 0,   72));                 h.tm:flush()
      -- chan 5: two arp regions in disjoint windows. An edit inside one must freeze the other
      -- producer-for-producer (phase 5), identity-keeping its derived notes.
      h.tm:addEvent(note(5, 0,   60));                 h.tm:flush()
      h.tm:addEvent(note(5, 480, 67));                 h.tm:flush()
      h.ds:assign('fxRegions', {
        { uuid = 'fxr-4',  chan = 4, startppq = 0,   endppq = 240, fx = arpUp },
        { uuid = 'fxr-5a', chan = 5, startppq = 0,   endppq = 240, fx = arpUp },
        { uuid = 'fxr-5b', chan = 5, startppq = 480, endppq = 720, fx = arpUp },
      })
      h.tm:rebuild()

      -- The fixture is live across all three axes, so parity is a real fixpoint claim, not two empty
      -- frames agreeing. Vibrato pb seats + absorber pbs are wire-only (mm), the parked chord is frame-visible.
      local nSeat3, nPb2 = 0, 0
      for _, c in ipairs(h.fm:dump().ccs) do
        if c.evType == 'pb' and c.chan == 3 then nSeat3 = nSeat3 + 1 end
        if c.evType == 'pb' and c.chan == 2 then nPb2   = nPb2   + 1 end
      end
      t.truthy(nSeat3 > 0, 'vibrato pb seats present on chan 3 (fx ran)')
      t.truthy(nPb2 > 0,   'absorber pbs present on chan 2 (tuning ran)')
      t.truthy(projectFrame(h.tm)[4].parked and #projectFrame(h.tm)[4].parked > 0,
        'chan 4 has an off-take parked chord (region ran)')
      t.truthy(h.tm:fromLogical(1, 120) ~= 120, 'swing is active (projection non-identity)')

      -- Plain edit on chan 1: freezes 2/3/4. Their re-read frame must equal a full re-derive.
      h.tm:addEvent(note(1, 480, 62)); h.tm:flush()
      assertParity(h, 'chan-1 edit: frozen 2/3/4 re-read == full re-derive')

      -- Edit the vibrato host itself: chan 3 re-derives (dirty path), 2/4 stay frozen.
      local vibNote = h.tm:getChannel(3).columns.notes[1].events[1]
      h.tm:assignEvent(vibNote, { pitch = 69 }); h.tm:flush()
      assertParity(h, 'chan-3 fx edit: dirty re-derive + frozen 2/4 == full re-derive')

      -- Edit inside the arp region window on chan 4: region re-parks/re-derives.
      h.tm:addEvent(note(4, 0, 74)); h.tm:flush()
      assertParity(h, 'chan-4 region edit: re-park + re-derive == full re-derive')

      -- Add a chord member inside region 5a's window: 5a re-derives, 5b is frozen by the producer
      -- gate (pure-note chain, window untouched) and identity-keeps its arp notes.
      h.tm:addEvent(note(5, 0, 64, { lane = 2 })); h.tm:flush()
      assertParity(h, 'chan-5 producer gate: 5a re-derives, 5b identity-keeps == full re-derive')
    end,
  },
  {
    name = 'continuous gate: kept, clean-overlapping, and orphaned cc producers reconcile to parity',
    run = function(harness)
      local h = harness.mk{
        config = { project = { swings = { c58 = classic58 } } },
        data   = { swing = { global = 'c58' } },
      }

      -- cc-seat uuids on chan/cc within logical [startL, endL): the write pin -- a kept window's
      -- seats must survive an outside edit under their original uuids (no delete/re-add churn).
      local function seatUuids(chan, cc, startL, endL)
        local out = {}
        for _, e in ipairs(h.fm:dump().ccs) do
          if e.evType == 'cc' and e.chan == chan and e.cc == cc then
            local ppqL = h.tm:toLogical(chan, e.ppq)
            if ppqL >= startL and ppqL < endL then out[e.uuid] = true end
          end
        end
        return out
      end

      -- chan 1: disjoint autopan pair -- windows [0,240) and [960,1200) (authored ends bound them).
      h.tm:addEvent(note(1, 0,   60, { endppq = 240,  fx = pan })); h.tm:flush()
      h.tm:addEvent(note(1, 960, 64, { endppq = 1200, fx = pan })); h.tm:flush()
      -- chan 2: overlapping pair on separate lanes -- windows [0,960) and [480,1920).
      h.tm:addEvent(note(2, 0,   60, { endppq = 960,  fx = pan }));            h.tm:flush()
      h.tm:addEvent(note(2, 480, 64, { endppq = 1920, fx = pan, lane = 2 })); h.tm:flush()

      t.truthy(next(seatUuids(1, 10, 0, 240)),     'chan-1 window A has pan seats')
      t.truthy(next(seatUuids(1, 10, 960, 1200)),  'chan-1 window B has pan seats')
      t.truthy(next(seatUuids(2, 10, 960, 1920)),  'chan-2 lane-2 exclusive span has seats')

      -- Edit inside window A only: B is outside every scope and identity-keeps its seats.
      local keptB = seatUuids(1, 10, 960, 1200)
      h.tm:addEvent(note(1, 120, 62, { lane = 2 })); h.tm:flush()
      t.deepEq(seatUuids(1, 10, 960, 1200), keptB, 'kept window B: seat uuids untouched')
      assertParity(h, 'chan-1 disjoint pair: edit in A, B keeps == full re-derive')

      -- Edit exactly on window A's end edge (ppq 240): windowSeeded is edge-inclusive, so window A's
      -- prev seats surface in ccExisting and match rather than duplicate. Half-open would miss them.
      local edgeA = seatUuids(1, 10, 0, 240)
      h.tm:addEvent(note(1, 240, 65, { lane = 3 })); h.tm:flush()
      t.deepEq(seatUuids(1, 10, 0, 240), edgeA, 'edge-inclusive edit: window A seats keep, no duplicate')
      assertParity(h, 'chan-1 edge edit: window A reconciles without churn == full re-derive')

      -- Edit at ppq 240 seeds lane-1's window only: the lane-2 overlapper re-expands as a fold
      -- input but emits nothing of its own -- its exclusive remainder keeps verbatim.
      local keptQ = seatUuids(2, 10, 960, 1920)
      h.tm:addEvent(note(2, 240, 66, { lane = 3 })); h.tm:flush()
      t.deepEq(seatUuids(2, 10, 960, 1920), keptQ, 'clean overlapper: exclusive seats untouched')
      assertParity(h, 'chan-2 overlap: dirty lane-1 + clean overlapper == full re-derive')

      -- Remove window A's fx outright: its orphan seats are fed by nothing and delete; B still keeps.
      keptB = seatUuids(1, 10, 960, 1200)
      local hostA = h.tm:getChannel(1).columns.notes[1].events[1]
      h.tm:assignEvent(hostA, { fx = util.REMOVE }); h.tm:flush()
      t.deepEq(seatUuids(1, 10, 0, 960), {}, 'removed producer: orphan seats deleted')
      t.deepEq(seatUuids(1, 10, 960, 1200), keptB, 'window B still keeps across the removal')
      assertParity(h, 'chan-1 fx removal: orphans delete, B keeps == full re-derive')
    end,
  },
  {
    name = 'continuous gate: pb half -- kept windows carry, overlap clips, hold seeds re-derive',
    run = function(harness)
      local h = harness.mk{
        config = { project = { swings = { c58 = classic58 } } },
        data   = { swing = { global = 'c58' } },
        -- A visible authored pb outside every window keeps chan 1's pb column alive, so the
        -- kept-range prior-slice carry is actually exercised (an all-hidden column projects nil).
        seed   = { ccs = {
          { ppq = 600, chan = 1, evType = 'pb', val = 0, cents = 50, shape = 'step' },
        } },
      }

      -- pb records on `chan` within logical [startL, endL], ppq-sorted: the write pin -- a kept
      -- range must survive an outside edit with identity and values intact. The CC walk anchors a
      -- fresh markerless seat with a one-time ppqL stamp (rebuildCCs), so the anchor is excluded;
      -- cents rides so a kept seat mistaken for an authored pb (back-derived cents) still fails.
      local function pbsIn(chan, startL, endL)
        local out = {}
        for _, e in ipairs(h.fm:dump().ccs) do
          if e.evType == 'pb' and e.chan == chan then
            local ppqL = h.tm:toLogical(chan, e.ppq)
            if ppqL >= startL and ppqL <= endL then
              out[#out + 1] = { ppq = e.ppq, val = e.val, shape = e.shape,
                                uuid = e.uuid, cents = e.cents, derived = e.derived }
            end
          end
        end
        table.sort(out, function(a, b) return a.ppq < b.ppq end)
        return out
      end

      -- chan 1: disjoint vibrato hosts -- windows [0,240) and [960,1200).
      h.tm:addEvent(note(1, 0,   60, { endppq = 240,  fx = vib30 })); h.tm:flush()
      h.tm:addEvent(note(1, 960, 64, { endppq = 1200, fx = vib30 })); h.tm:flush()
      -- chan 2: overlapping vibrato pair on lanes 1/2 -- windows [0,960) and [480,1920).
      h.tm:addEvent(note(2, 0,   60, { endppq = 960,  fx = vib30 }));           h.tm:flush()
      h.tm:addEvent(note(2, 480, 64, { endppq = 1920, fx = vib30, lane = 2 })); h.tm:flush()
      -- Settle: a creation pass projects fresh seats before their uuids land at commit, so a column
      -- carried straight from creation lacks them. One full re-derive reaches the steady state every
      -- later carry preserves (the rich fixture crosses it via its fxRegions all-16 rebuild).
      h.tm:rebuild(true)

      t.truthy(#pbsIn(1, 0, 240) > 0,    'chan-1 window A has pb seats')
      t.truthy(#pbsIn(1, 960, 1200) > 0, 'chan-1 window B has pb seats')
      t.truthy(#pbsIn(2, 960, 1920) > 0, 'chan-2 exclusive overlap remainder has pb seats')

      -- Lane-2 edit inside window A: no hold seed, so B is outside every scope and keeps verbatim.
      local keptB = pbsIn(1, 960, 1200)
      h.tm:addEvent(note(1, 120, 62, { lane = 2 })); h.tm:flush()
      t.deepEq(pbsIn(1, 960, 1200), keptB, 'kept window B: pb seats untouched')
      assertParity(h, 'chan-1 disjoint vibrato: edit in A, B keeps == full re-derive')

      -- Edit at 240 seeds lane-1's window only: the overlapper folds as input inside [0,960) but
      -- its exclusive remainder [960,1920) is a kept range and carries verbatim.
      local keptQ = pbsIn(2, 960, 1920)
      h.tm:addEvent(note(2, 240, 66, { lane = 3 })); h.tm:flush()
      t.deepEq(pbsIn(2, 960, 1920), keptQ, 'clean overlapper: exclusive pb range untouched')
      assertParity(h, 'chan-2 overlap: clipped fold + kept remainder == full re-derive')

      -- Lane-1 detune add between chan-1's windows: a hold seed. A ends before it and still keeps;
      -- B ends after it and re-derives; the new onset seats its absorber.
      local keptA = pbsIn(1, 0, 240)
      h.tm:addEvent(note(1, 480, 62, { detune = 25, endppq = 720 })); h.tm:flush()
      t.deepEq(pbsIn(1, 0, 240), keptA, 'window A upstream of the hold seed: kept')
      t.truthy(#pbsIn(1, 480, 480) > 0, 'detune onset reseated its absorber')
      -- One more gated edit settles the fresh absorber pair (creation-pass projection precedes the
      -- commit that mints uuids -- same gap as the setup settle) before the parity claim.
      h.tm:addEvent(note(1, 60, 65, { lane = 2 })); h.tm:flush()
      assertParity(h, 'chan-1 detune edit: hold reach re-derives B, A keeps == full re-derive')
    end,
  },
  {
    name = 'seat gate: detune closure keeps out-of-closure absorbers; a cascade nudge reseats via the walk emission',
    run = function(harness)
      local h = harness.mk{}   -- no swing: raw == logical + delay

      local function pbAt(chan, ppq)
        for _, e in ipairs(h.fm:dump().ccs) do
          if e.evType == 'pb' and e.chan == chan and e.ppq == ppq then return e end
        end
      end
      local function pbBag(chan)
        local out = {}
        for _, e in ipairs(h.fm:dump().ccs) do
          if e.evType == 'pb' and e.chan == chan then
            out[#out + 1] = { ppq = e.ppq, val = e.val, uuid = e.uuid }
          end
        end
        table.sort(out, function(a, b) return a.ppq < b.ppq end)
        return out
      end

      -- chan 1: detune steps at 0 / 480 / 1440 -> three step absorbers (960 repeats 480's detune,
      -- so it seats nothing). chan 2: same-pitch pair for the cascade below.
      h.tm:addEvent(note(1, 0,    60, { detune = 10 })); h.tm:flush()
      h.tm:addEvent(note(1, 480,  62, { detune = 30 })); h.tm:flush()
      h.tm:addEvent(note(1, 960,  64, { detune = 30 })); h.tm:flush()
      h.tm:addEvent(note(1, 1440, 65, { detune = 50 })); h.tm:flush()
      h.tm:addEvent(note(2, 0,   60)); h.tm:flush()
      h.tm:addEvent(note(2, 480, 60, { detune = 30 })); h.tm:flush()
      -- Settle creation-pass identity (same seam as the pb-half fixture above).
      h.tm:rebuild(true)

      t.truthy(pbAt(1, 0) and pbAt(1, 480) and pbAt(1, 1440), 'absorbers seated at each detune onset')

      -- Detune edit at 480: the closure is [480, next lane-1 onset 960] inclusive. The absorbers
      -- at 0 and 1440 sit outside it and must stand verbatim, uuid included.
      local before = pbBag(1)
      local n480 = h.tm:getChannel(1).columns.notes[1].events[2]
      h.tm:assignEvent(n480, { detune = 45 }); h.tm:flush()
      local after = pbBag(1)
      t.deepEq(after[1], before[1], 'absorber at 0: outside the closure, verbatim')
      t.deepEq(after[#after], before[#before], 'absorber at 1440: outside the closure, verbatim')
      t.truthy(pbAt(1, 480).val ~= before[2].val, 'edited onset reseated to the new detune')
      assertParity(h, 'detune closure: out-of-closure seats keep == full re-derive')

      -- A lane-2 add lands raw-coincident with chan 2's same-pitch lane-1 onset at 480; the walk
      -- nudges the lane-1 note to 481 and emits its seat closure -- the only dirt covering the
      -- absorber, since the add itself is lane-2. see design § The widen and the emission
      h.tm:addEvent(note(2, 470, 60, { lane = 2, delay = 42 })); h.tm:flush()   -- delay is milli-QN; 42 = +10 ticks at res 240
      t.truthy(pbAt(2, 481), 'nudged lane-1 onset reseated its absorber at the new raw')
      t.truthy(not pbAt(2, 480), 'no stale absorber left at the old raw')
      assertParity(h, 'cascade nudge: emission-covered seat == full re-derive')
    end,
  },
}
