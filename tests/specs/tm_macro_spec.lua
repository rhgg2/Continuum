-- Note macros, v1: retrig (structural). Pins G1-G4 (see design/archive/note-macros.md § Invariants).
-- G4 runs under swing+delay first — the frame/rounding tripwire for steady-state churn.

local t = require('support')
local util = require('util')

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

-- Note-host replace parks: the authored note leaves the take and remains the
-- visible, editable surface in channels[chan].parked.
local function parkedHost(h)
  return h.tm:getChannel(1).parked[1]
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
      local host = parkedHost(h)
      t.truthy(host, 'the host note is parked off-take')
      t.eq(#fxNotesOf(h.fm:dump(), host.uuid), 4,
        'retrig over a 1-QN window at 1/4-QN period yields 4 fxNotes (all hits derived)')

      local before = notesView(h.fm:dump())
      h.tm:rebuild()
      h.tm:flush()
      local after = notesView(h.fm:dump())

      t.deepEq(after, before, 'no churn across the round trip')
    end,
  },

  ----- G1 — provenance

  {
    name = 'G1: every fxNote resolves via derived to the parked host carrying the structural fx',
    run = function(harness)
      local h = mkRetrigHost(harness)
      local dump = h.fm:dump()
      local host = parkedHost(h)
      local fns = fxNotesOf(dump, host.uuid)
      t.eq(#fns, 4, 'expansion happened')
      for _, fn in ipairs(fns) do
        t.eq(fn.derived, host.uuid, 'fxNote tagged with the parked host uuid')
      end
      t.falsy(h.tm:byUuid(host.uuid), 'the host is off-take (parked), not in mm')
      t.truthy(host.fx, 'the parked cell carries the fx (the editable surface)')
    end,
  },

  ----- G2 — both directions

  {
    name = 'G2: fx present yields fxNotes; fx removed leaves none after reconcile',
    run = function(harness)
      local h = mkRetrigHost(harness)
      local host = parkedHost(h)
      t.eq(#fxNotesOf(h.fm:dump(), host.uuid), 4, 'fxNotes present with fx')

      h.tm:assignParked(host, { fx = util.REMOVE })
      h.tm:flush()

      t.eq(#fxNotesOf(h.fm:dump(), host.uuid), 0, 'no fxNote survives fx removal')
      t.falsy(h.tm:getChannel(1).parked[1], 'nothing left parked')
      local restored
      for _, n in ipairs(h.fm:dump().notes) do
        if not n.derived then restored = n end
      end
      t.truthy(restored, 'the authored note is restored to the take')
      t.eq(restored.uuid, host.uuid, 'restore preserves the uuid (fx-editor handles survive)')
      t.falsy(restored.fx, 'the restored note carries no fx')
    end,
  },

  -- The restored note re-enters its column unrealised; its real mm event lands only with
  -- the deferred tail commit. Unless wired to that backing, the cell is inert till rebuild.
  {
    name = 'G2b: an edit through the restored grid cell lands (cell wired to its backing)',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                      vel = 100, detune = 0, delay = 0, lane = 1, fx = retrig16 })
      h.tm:flush()
      local uuid = parkedHost(h).uuid

      -- Clear exactly as the fx editor does for a parked host.
      h.tm:assignParked(parkedHost(h), { fx = util.REMOVE })
      h.tm:flush()

      local cell
      for _, ev in ipairs(h.tm:getChannel(1).columns.notes[1].events) do
        if ev.uuid == uuid then cell = ev end
      end
      t.truthy(cell, 'the restored note is present as a grid cell')

      -- The view edits by handing the column cell straight to tm:assignEvent.
      h.tm:assignEvent(cell, { pitch = 64 })
      h.tm:flush()
      t.eq(h.tm:byUuid(uuid).pitch, 64, 'edit through the restored cell reaches its backing')
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
      local host = parkedHost(h)
      t.eq(host.lane, 2, 'host parked from lane 2')
      local fns = fxNotesOf(dump, host.uuid)
      t.eq(#fns, 4, 'lane-2 host expands like a lane-1 host')
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
        if n.derived and n.vel == 88 then tok = n.uuid end
      end
      t.truthy(tok, 'fxNote 2 present at vel 88')
      h.fm:modify(function() h.fm:assign(tok, { vel = 17 }) end)

      h.tm:rebuild()
      local dump = h.fm:dump()
      local vels = {}
      for _, fn in ipairs(fxNotesOf(dump, parkedHost(h).uuid)) do vels[#vels + 1] = fn.vel end
      t.deepEq(vels, { 100, 88, 76, 64 }, 'generator geometry restored; foreign vel gone')
    end,
  },

  ----- Tail clamp + ramp (structural realisation details)

  {
    name = 'the host parks; all hits are derived; authored ceiling preserved; fxNotes clip in turn',
    run = function(harness)
      local h = harness.mk()
      addPlainHost(h)
      local dump = h.fm:dump()
      local host = parkedHost(h)
      t.eq(host.endppq, 240, 'the parked cell carries the authored ceiling')
      for _, n in ipairs(dump.notes) do
        t.truthy(n.derived, 'no authored note remains in the take')
      end
      local fns = fxNotesOf(dump, host.uuid)
      t.deepEq({ fns[1].ppq, fns[2].ppq, fns[3].ppq, fns[4].ppq }, { 0, 60, 120, 180 },
        'fxNote onsets tile from the window start')
      t.deepEq({ fns[1].endppq, fns[2].endppq, fns[3].endppq, fns[4].endppq }, { 60, 120, 180, 240 },
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
      for _, fn in ipairs(fxNotesOf(dump, parkedHost(h).uuid)) do vels[#vels + 1] = fn.vel end
      -- 20 -> 8 -> -4 (floor 1) -> -16 (floor 1)
      t.deepEq(vels, { 20, 8, 1, 1 }, 'tile 0 carries the host vel; ramp applied from tile 1, floored at 1')
    end,
  },

  ----- PC interplay (trackerMode)

  {
    name = 'under trackerMode the derived tiles enter PC synthesis carrying the host sample',
    run = function(harness)
      local h = harness.mk{ config = { transient = { trackerMode = true } } }
      addPlainHost(h, { sample = 5 })
      t.deepEq(pcsOnChan(h.fm:dump(), 1),
        { { ppq = 0, val = 5 }, { ppq = 60, val = 5 }, { ppq = 120, val = 5 }, { ppq = 180, val = 5 } },
        'host + 3 fxNotes each emit a PC carrying sample 5')
    end,
  },

  ----- Effective window — a same-pitch note bounds the host, and survives

  {
    name = 'a same-pitch note inside a retrig truncates the window and is not clobbered',
    run = function(harness)
      local h = harness.mk()
      addPlainHost(h)
      t.eq(#fxNotesOf(h.fm:dump(), parkedHost(h).uuid), 4, 'baseline 4 fxNotes')

      -- Same-pitch note at 120 bounds the host window to [0,120); the
      -- regenerable fxNote must not clobber authored intent.
      h.tm:addEvent({ evType = 'note', ppq = 120, endppq = util.OPEN, chan = 1,
                      pitch = 60, vel = 90, detune = 0, delay = 0, lane = 1 })
      h.tm:flush()

      local dump = h.fm:dump()
      local host = parkedHost(h)
      local authored
      for _, n in ipairs(dump.notes) do
        if n.pitch == 60 and n.ppq == 120 and not n.derived then authored = n end
      end
      t.truthy(authored, 'authored same-pitch note survives the retrig')
      local fns = fxNotesOf(dump, host.uuid)
      t.eq(#fns, 2, 'window bounded to [0,120): fxNotes at 0 and 60 remain')
      t.deepEq({ fns[1].ppq, fns[2].ppq }, { 0, 60 }, 'surviving fxNotes sit at 0 and 60')
    end,
  },

  ----- Effective window — a same-lane note of any pitch bounds the host

  {
    name = 'a same-lane note inside a retrig truncates the window and the host tail',
    run = function(harness)
      local h = harness.mk()
      addPlainHost(h)
      t.eq(#fxNotesOf(h.fm:dump(), parkedHost(h).uuid), 4, 'baseline 4 fxNotes')

      -- Same-lane note at 100 (different pitch): monophonic column cuts the
      -- retrig window, so no fxNote should appear at or after 100.
      h.tm:addEvent({ evType = 'note', ppq = 100, endppq = util.OPEN, chan = 1,
                      pitch = 64, vel = 90, detune = 0, delay = 0, lane = 1 })
      h.tm:flush()

      local dump = h.fm:dump()
      local fns = fxNotesOf(dump, parkedHost(h).uuid)
      t.eq(#fns, 2, 'window bounded to [0,100): fxNotes at 0 and 60 remain')
      t.deepEq({ fns[1].ppq, fns[2].ppq }, { 0, 60 }, 'surviving fxNotes sit at 0 and 60')

      t.eq(parkedHost(h).endppqC, 100, 'parked cell view tail clipped to the new note at 100')
    end,
  },

  ----- Effective window — the take end bounds the host, even when the authored tail overruns it

  {
    name = 'a retrig whose authored tail overruns the take generates nothing past the take end',
    run = function(harness)
      -- 1-QN take; authored tail runs to 2 QN. Paste (and overshooting moves)
      -- can leave endppqL past the take end -- the fx window must still clamp to it,
      -- or the generator writes derived events off-take and grows the take.
      local h = harness.mk{ seed = { length = 240 } }
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 480, chan = 1, pitch = 60,
                      vel = 100, detune = 0, delay = 0, lane = 1, fx = retrig16 })
      h.tm:flush()

      local dump = h.fm:dump()
      local host = parkedHost(h)
      t.truthy(host, 'the host is parked')
      local fns = fxNotesOf(dump, host.uuid)
      for _, fn in ipairs(fns) do
        t.truthy(fn.ppq < 240, 'fxNote onset stays within the take (got ppq=' .. fn.ppq .. ')')
        t.truthy(fn.endppq <= 240, 'fxNote tail stays within the take (got endppq=' .. fn.endppq .. ')')
      end
      t.eq(#fns, 4, 'window clamped to the 1-QN take: hits at 0/60/120/180 only')
    end,
  },

  ----- View sees the pre-fx host (no spurious give-way cue)

  {
    name = 'the parked host cell shows the authored length (the visible, editable surface)',
    run = function(harness)
      local h = harness.mk()
      addPlainHost(h)
      local host = parkedHost(h)
      t.eq(host.endppqC, 240, 'view sees the full authored tail')
      t.eq(host.endppq, 240, 'authored ceiling intact on the cell')
    end,
  },

  ----- PA display -- a parked host anchors its PA to its lane

  {
    name = 'a PA on a parked host projects into the host lane column (display anchor survives parking)',
    run = function(harness)
      local h = harness.mk()
      addPlainHost(h)
      h.tm:addEvent({ evType = 'pa', ppq = 30, chan = 1, pitch = 60, vel = 90 })
      h.tm:flush()
      local pa
      for _, evt in ipairs(h.tm:getChannel(1).columns.notes[1].events) do
        if evt.evType == 'pa' and evt.ppq == 30 then pa = evt end
      end
      t.truthy(pa, "the PA seats in the parked host's lane column")
      t.eq(pa.pitch, 60, 'keyed to the host pitch')
    end,
  },

}
