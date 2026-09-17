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
  return h.tm:getChannel(1).parked.notes[1]
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
      t.falsy(h.tm:getChannel(1).parked.notes[1], 'nothing left parked')
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
      for _, ev in ipairs(h.tm:getChannel(1).onTake.notes[1].events) do
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
        t.eq(fn.derived, host.uuid, 'and its output names the host, wherever that host sat')
        t.eq(fn.lane, nil, 'which is the whole of its address -- the host lane rides onto nothing')
      end
    end,
  },

  ----- baseVoice — the generator's stamp rides the fx pass onto the seated note

  {
    name = 'derived notes carry baseVoice iff their host sits on lane 1',
    run = function(harness)
      local h = harness.mk()
      -- Two retrig hosts, one per lane: base voice is the host's lane, not the expansion's shape.
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                      vel = 100, detune = 0, delay = 0, lane = 1, fx = retrig16 })
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 67,
                      vel = 100, detune = 0, delay = 0, lane = 2, fx = retrig16 })
      h.tm:flush()

      local hostByLane = {}
      for _, p in ipairs(h.tm:getChannel(1).parked.notes) do hostByLane[p.lane] = p end
      t.truthy(hostByLane[1] and hostByLane[2], 'both hosts parked, one per lane')

      local dump = h.fm:dump()
      local base  = fxNotesOf(dump, hostByLane[1].uuid)
      local upper = fxNotesOf(dump, hostByLane[2].uuid)
      t.eq(#base, 4, 'the lane-1 host expanded')
      t.eq(#upper, 4, 'the lane-2 host expanded')
      for _, fn in ipairs(base)  do t.eq(fn.baseVoice, true, 'a lane-1 host derives base voice') end
      for _, fn in ipairs(upper) do t.eq(fn.baseVoice, nil, 'a lane-2 host derives no base voice') end
    end,
  },

  {
    name = 'baseVoice survives a reindex -- it comes back off the wire, not off a re-expansion',
    run = function(harness)
      local h = harness.mk()
      addPlainHost(h)
      local host = parkedHost(h)

      h.fm:load()   -- no rebuild: whatever reads now was persisted as mm metadata
      local fns = fxNotesOf(h.fm:dump(), host.uuid)
      t.eq(#fns, 4, 'the derived notes came back')
      for _, fn in ipairs(fns) do t.eq(fn.baseVoice, true, 'the stamp came back with them') end
    end,
  },

  {
    name = 'a host moved onto lane 1 re-emits its derived notes as base voice',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 67,
                      vel = 100, detune = 0, delay = 0, lane = 2, fx = retrig16 })
      h.tm:flush()
      for _, fn in ipairs(fxNotesOf(h.fm:dump(), parkedHost(h).uuid)) do
        t.falsy(fn.baseVoice, 'not base voice while the host sits on lane 2')
      end

      -- Every other keyed term is unchanged by the move: same host, onsets, pitches, velocities.
      h.tm:assignParked(h.tm:getChannel(1).parked.notes[1], { lane = 1 }); h.tm:flush()

      local host = parkedHost(h)
      t.eq(host.lane, 1, 'the host moved')
      local fns = fxNotesOf(h.fm:dump(), host.uuid)
      t.eq(#fns, 4, 'it still expands')
      for _, fn in ipairs(fns) do
        t.eq(fn.baseVoice, true, 'the derived notes followed the host: they are base voice now')
      end

      h.fm:load()
      for _, fn in ipairs(fxNotesOf(h.fm:dump(), host.uuid)) do
        t.eq(fn.baseVoice, true, 'the re-emitted stamp persisted')
      end
    end,
  },

  ----- G3 — ownership

  {
    name = 'G3: a foreign edit to an fxNote is overwritten, not kept',
    run = function(harness)
      local h = harness.mk()
      addPlainHost(h)
      local take = h.fm:take()

      -- The route a foreign edit really takes: the ReaScript note verb on the take, behind every
      -- model Continuum holds, reaching it through the re-read that notices the bytes changed.
      -- (Reaching into mm instead strands um's index, which no caller does and no re-read repairs.)
      local bent, i = false, 0
      while true do
        local ok, sel, mut, ppq, endppq, chan, pitch, vel = h.reaper.MIDI_GetNote(take, i)
        if not ok then break end
        if vel == 88 then
          h.reaper.MIDI_SetNote(take, i, sel, mut, ppq, endppq, chan, pitch, 17)
          bent = true
          break
        end
        i = i + 1
      end
      t.truthy(bent, 'fixture check: fxNote 2 was on the take at vel 88')

      h.fm:reload()   -- wholesale: every model re-reads, um's index included

      local vels = {}
      for _, fn in ipairs(fxNotesOf(h.fm:dump(), parkedHost(h).uuid)) do vels[#vels + 1] = fn.vel end
      t.deepEq(vels, { 100, 88, 76, 64 }, 'generator geometry restored; foreign vel gone')
      -- And it reached the take the edit landed on, not only the model above it.
      local onTake, j = {}, 0
      while true do
        local ok, _, _, _, _, _, _, vel = h.reaper.MIDI_GetNote(take, j)
        if not ok then break end
        onTake[#onTake + 1] = vel; j = j + 1
      end
      t.deepEq(onTake, { 100, 88, 76, 64 }, 'the foreign velocity is gone from the take')
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
      for _, evt in ipairs(h.tm:getChannel(1).onTake.notes[1].events) do
        if evt.evType == 'pa' and evt.ppq == 30 then pa = evt end
      end
      t.truthy(pa, "the PA seats in the parked host's lane column")
      t.eq(pa.pitch, 60, 'keyed to the host pitch')
    end,
  },

  ----- tm:fxRealisationAt -- the door onto what one host realised

  {
    name = 'tm:fxRealisationAt hands back the host under the row, with its onsets in the logical frame',
    run = function(harness)
      local h = mkRetrigHost(harness)
      local host = parkedHost(h)
      local realised = fxNotesOf(h.fm:dump(), host.uuid)
      t.eq(#realised, 4, 'expansion happened')

      local fx = h.tm:fxRealisation(host.uuid)
      t.eq(#fx.notes, #realised, 'the host carries every derived note the dump holds')

      local onsets = {}
      for _, fn in ipairs(fx.notes) do
        t.eq(fn.derived, host.uuid, 'each record names its host')
        t.eq(fn.lane, nil, 'and carries no lane: the column a ghost reads in is tv\'s to allocate')
        onsets[#onsets + 1] = fn.ppq
      end
      t.deepEq(onsets, { 0, 60, 120, 180 }, 'logical onsets tile at the retrig period')

      -- Swing plus delay=500 means the raw onsets are elsewhere: a record reading
      -- the realised frame could not produce this set.
      local rawOnsets = {}
      for _, n in ipairs(realised) do rawOnsets[n.ppq] = true end
      local diverges = false
      for _, ppq in ipairs(onsets) do diverges = diverges or not rawOnsets[ppq] end
      t.truthy(diverges, 'at least one logical onset has no raw counterpart in the dump')

      t.eq(h.tm:fxRealisation('fxr-nope'), nil, 'a uuid that runs no chain has no realisation at all')

      for lane, column in ipairs(h.tm:getChannel(1).onTake.notes) do
        for _, evt in ipairs(column.events) do
          t.falsy(evt.derived, 'lane ' .. lane .. ' column carries no derived event')
        end
      end
    end,
  },

}
