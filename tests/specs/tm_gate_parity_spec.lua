-- Gated-vs-full parity: the shadow harness design/archive/dirty-channels.md § Validation names as the
-- prerequisite for phase B. Exploits I8 (a no-edit rebuild is a fixpoint): after an edit, a gated
-- rebuild -- which re-READS untouched channels' persisted derivation -- must project byte-identically
-- to a forced all-16 rebuild that re-DERIVES every channel from mm. Divergence means a gate froze a
-- channel whose persisted state was not a true fixpoint. Volatile identity (token/loc) is stripped;
-- everything the view renders is compared. This pins phase A now and guards phase B's retention next.

local t = require('support')

local classic58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }

local vib30 = { { kind = 'vibrato', period = { 1, 4 }, depth = 30, onset = 0 } }
local arpUp = { { kind = 'arp',     period = { 1, 4 }, dir = 'up' } }

local function note(chan, ppq, pitch, extra)
  local n = { evType = 'note', ppq = ppq, endppq = ppq + 240, chan = chan, pitch = pitch,
              vel = 100, detune = 0, delay = 0, lane = 1 }
  for k, v in pairs(extra or {}) do n[k] = v end
  return n
end

-- Volatile per-rebuild identity: re-keyed token, mm-side loc, pb working-clone origin refs, and the
-- reconcile skeleton's key. None render; all legitimately differ between a carried and a fresh frame.
local VOLATILE = { token = true, loc = true, origTok = true, origShape = true, key = true }

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
-- re-derive leaves byte-identical proves those hidden derivations were a fixpoint too. token/loc churn
-- each rebuild; uuid is durable, so a content bag keyed on the rest is the stable comparison.
local function stripRec(e)
  local out = {}
  for k, v in pairs(e) do if k ~= 'token' and k ~= 'loc' then out[k] = v end end
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
      h.ds:assign('fxRegions', {
        { uuid = 'fxr-4', chan = 4, startppq = 0, endppq = 240, fx = arpUp },
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
    end,
  },
}
