-- Note macros, v1: retrig (structural). Pins G1-G4 (see design/note-macros.md § Invariants).
-- G4 runs under swing+delay first — the frame/rounding tripwire for steady-state churn.

local t = require('support')

local classic58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }

local retrig16 = { { kind = 'retrig', period = { 1, 4 }, ramp = -12 } }

local function pcsOnChan(dump, chan)
  local out = {}
  for _, c in ipairs(dump.ccs) do
    if c.evType == 'pc' and c.chan == chan then
      out[#out + 1] = { ppq = c.ppq, val = c.val }
    end
  end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
  return out
end

-- Identity swing, zero delay: realised == logical. (G4 runs under swing+delay; the rest don't.)
local function addPlainHost(h, over)
  local note = { evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                 vel = 100, detune = 0, delay = 0, lane = 1, fx = retrig16 }
  for k, v in pairs(over or {}) do note[k] = v end
  h.tm:addEvent(note)
  h.tm:flush()
end

-- A stable, order-independent view of every note in the dump, uuid and
-- all. Byte-identical means this deepEq's across the round trip.
local function notesView(dump)
  local out = {}
  for _, n in ipairs(dump.notes) do out[#out + 1] = n end
  table.sort(out, function(a, b)
    if a.ppq ~= b.ppq then return a.ppq < b.ppq end
    if a.pitch ~= b.pitch then return a.pitch < b.pitch end
    return (a.uuid or '') < (b.uuid or '')
  end)
  return out
end

local function fxNotesOf(dump, hostUuid)
  local out = {}
  for _, n in ipairs(dump.notes) do
    if n.derived == hostUuid then out[#out + 1] = n end
  end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
  return out
end

local function hostNote(dump)
  for _, n in ipairs(dump.notes) do if n.fx then return n end end
end

-- Host + retrig under swing and delay. Shared across the G-tests.
local function mkRetrigHost(harness)
  local h = harness.mk{
    config = {
      project = { swings = { ['c58'] = classic58 } },
    },
    data = { swing = { global = 'c58' } },
  }
  h.tm:addEvent({ evType = 'note',
    ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
    detune = 0, delay = 500, lane = 1, fx = retrig16,
  })
  h.tm:flush()
  return h
end

return {

  ----- G4 — round-trip stability (FIRST: frame/rounding tripwire)

  {
    name = 'G4: flush -> rebuild -> flush is byte-identical (retrig, swing + delay)',
    run = function(harness)
      local h = mkRetrigHost(harness)

      -- Expansion must actually have happened — otherwise "byte-identical"
      -- is satisfied vacuously by producing nothing.
      local host = hostNote(h.fm:dump())
      t.truthy(host, 'host note carries fx')
      t.eq(#fxNotesOf(h.fm:dump(), host.uuid), 3,
        'retrig over a 1-QN window at 1/4-QN period yields 3 fxNotes (host is fxNote 1)')

      local before = notesView(h.fm:dump())
      h.tm:rebuild()
      h.tm:flush()
      local after = notesView(h.fm:dump())

      t.deepEq(after, before, 'no churn across the round trip')
    end,
  },

  ----- G4-float — int/float fxKey churn guard (canon)
  -- REAPER returns note ppq as a float; predicted fxNote ppq is a Lua integer.
  -- Without canon() in fxKey the two stringify differently, so every rebuild
  -- sees the whole fxNote set as changed and re-mints it. floatPpq makes the
  -- fake mm mirror REAPER so this round trip actually exercises the skew.

  {
    name = 'G4-float: float-ppq reads do not churn fxNotes (fxKey canon)',
    run = function(harness)
      local h = harness.mk{ floatPpq = true }
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                      vel = 100, detune = 0, delay = 0, lane = 1, fx = retrig16 })
      h.tm:flush()

      local host = hostNote(h.fm:dump())
      t.truthy(host, 'host note carries fx')
      t.eq(#fxNotesOf(h.fm:dump(), host.uuid), 3, 'retrig expands to 3 fxNotes')

      local before = notesView(h.fm:dump())
      h.tm:rebuild()
      h.tm:flush()
      local after = notesView(h.fm:dump())
      t.deepEq(after, before, 'no churn across the round trip under float-ppq reads')
    end,
  },

  ----- G1 — provenance

  {
    name = 'G1: every fxNote resolves via derived to a live host carrying a structural fx',
    run = function(harness)
      local h = mkRetrigHost(harness)
      local dump = h.fm:dump()
      local host = hostNote(dump)
      for _, fn in ipairs(fxNotesOf(dump, host.uuid)) do
        t.eq(fn.derived, host.uuid, 'fxNote tagged with host uuid')
        t.truthy(h.tm:byUuid(fn.derived), 'host is live in byUuid')
      end
    end,
  },

  ----- G2 — both directions

  {
    name = 'G2: fx present yields fxNotes; fx removed leaves none after reconcile',
    run = function(harness)
      local h = mkRetrigHost(harness)
      local host = hostNote(h.fm:dump())
      t.eq(#fxNotesOf(h.fm:dump(), host.uuid), 3, 'fxNotes present with fx')

      local hostEvt = h.tm:getChannel(1).columns.notes[1].events[1]
      h.tm:assignEvent(hostEvt, { fx = require('util').REMOVE })
      h.tm:flush()

      t.eq(#fxNotesOf(h.fm:dump(), host.uuid), 0, 'no fxNote survives fx removal')
    end,
  },

  ----- Lane independence — structural hosts are not gated to lane 1

  {
    name = 'a higher-lane note hosts retrig (structural expansion is lane-blind)',
    run = function(harness)
      local h = harness.mk()
      -- lane 1 plain, lane 2 carries the retrig: the host walk must not gate to lane 1.
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                      vel = 100, detune = 0, delay = 0, lane = 1 })
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 67,
                      vel = 100, detune = 0, delay = 0, lane = 2, fx = retrig16 })
      h.tm:flush()
      local dump = h.fm:dump()
      local host = hostNote(dump)
      t.eq(host.lane, 2, 'host sits on lane 2')
      local fns = fxNotesOf(dump, host.uuid)
      t.eq(#fns, 3, 'lane-2 host expands like a lane-1 host')
      for _, fn in ipairs(fns) do
        t.eq(fn.lane, 2, 'fxNotes inherit the host lane, not lane 1')
      end
    end,
  },

  ----- G3 — ownership

  {
    name = 'G3: a foreign edit to an fxNote is overwritten, not kept',
    run = function(harness)
      local h = harness.mk()
      addPlainHost(h)

      -- Bend fxNote 2 (vel 88) behind tm's back, as a foreign script would.
      local tok
      for _, n in h.fm:notes() do
        if n.derived and n.vel == 88 then tok = h.fm:tokenOf(n) end
      end
      t.truthy(tok, 'fxNote 2 present at vel 88')
      h.fm:modify(function() h.fm:assign(tok, { vel = 17 }) end)

      h.tm:rebuild()
      local dump = h.fm:dump()
      local vels = {}
      for _, fn in ipairs(fxNotesOf(dump, hostNote(dump).uuid)) do vels[#vels + 1] = fn.vel end
      t.deepEq(vels, { 88, 76, 64 }, 'generator geometry restored; foreign vel gone')
    end,
  },

  ----- Tail clamp + ramp (structural realisation details)

  {
    name = 'host tail truncates to fxNote 2; authored ceiling preserved; fxNotes clip in turn',
    run = function(harness)
      local h = harness.mk()
      addPlainHost(h)
      local dump = h.fm:dump()
      local host = hostNote(dump)
      t.eq(host.endppq,  60,  'host raw tail clamped to fxNote 2 onset')
      t.eq(host.endppqL, 240, 'host authored ceiling untouched')
      local fns = fxNotesOf(dump, host.uuid)
      t.deepEq({ fns[1].ppq, fns[2].ppq, fns[3].ppq }, { 60, 120, 180 }, 'fxNote onsets')
      t.deepEq({ fns[1].endppq, fns[2].endppq, fns[3].endppq }, { 120, 180, 240 },
        'fxNote tails clip to the next onset / authored ceiling')
    end,
  },

  {
    name = 'velocity ramps per fxNote and floors at 1',
    run = function(harness)
      local h = harness.mk()
      addPlainHost(h, { vel = 20 })
      local dump = h.fm:dump()
      local vels = {}
      for _, fn in ipairs(fxNotesOf(dump, hostNote(dump).uuid)) do vels[#vels + 1] = fn.vel end
      -- 20 -> 8 -> -4 (floor 1) -> -16 (floor 1)
      t.deepEq(vels, { 8, 1, 1 }, 'ramp applied, clamped to 1')
    end,
  },

  ----- PC interplay (trackerMode)

  {
    name = 'under trackerMode fxNotes enter PC synthesis carrying the host sample',
    run = function(harness)
      local h = harness.mk{ config = { transient = { trackerMode = true } } }
      addPlainHost(h, { sample = 5 })
      t.deepEq(pcsOnChan(h.fm:dump(), 1),
        { { ppq = 0, val = 5 }, { ppq = 60, val = 5 }, { ppq = 120, val = 5 }, { ppq = 180, val = 5 } },
        'host + 3 fxNotes each emit a PC carrying sample 5')
    end,
  },

}
