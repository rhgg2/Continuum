-- Note macros: vibrato (continuous pb-augment). Offline park-and-seat: the macro sums onto the
-- authored pb base and seats a markerless pb stream on the base lane (no carrier). see design/note-macros-v2.md § Continuous pb

local t    = require('support')
local util = require('util')

local classic58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }

-- depth 30c, period 1/4 QN: at res 240 one cycle = 60 ticks; sine extrema => peak at ppqL 15,
-- trough at 45; the summed stream anchors 0 at both window ends (closed span re-centres).
local vib30 = { { kind = 'vibrato', period = { 1, 4 }, depth = 30, onset = 0 } }

local function centsToRaw(cents, pbRange)
  return util.round(cents * 8192 / ((pbRange or 2) * 100))
end

-- pb-augment seats a summed stream on the base lane (markerless, no carrier). A seat carries a raw
-- pb `val` (centsToRaw of summed cents + detune) and `shape`; densified linear between feature points.
local function pbSeatsOf(dump, chan)
  local out = {}
  for _, c in ipairs(dump.ccs) do
    if c.evType == 'pb' and c.chan == chan then
      out[#out + 1] = { ppq = c.ppq, val = c.val, shape = c.shape, plain = c.plain }
    end
  end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
  return out
end

local function pbSeatAt(dump, chan, ppq)
  for _, c in ipairs(pbSeatsOf(dump, chan)) do if c.ppq == ppq then return c end end
end

local function addVibHost(h, over)
  local note = { evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                 vel = 100, detune = 0, delay = 0, lane = 1, fx = vib30 }
  for k, v in pairs(over or {}) do note[k] = v end
  h.tm:addEvent(note)
  h.tm:flush()
end

return {

  ----- Emission: summed cents -> raw pb seats at the extrema

  {
    name = 'vibrato seats a summed pb stream: rest 0 + depth at the extrema, markerless',
    run = function(harness)
      local h = harness.mk()
      addVibHost(h)
      local dump  = h.fm:dump()
      local seats = pbSeatsOf(dump, 1)
      t.truthy(#seats >= 8, 'a densified pb seat stream is emitted')
      for _, s in ipairs(seats) do t.eq(s.plain, true, 'seats are markerless (route-by-window)') end
      t.eq(pbSeatAt(dump, 1, 0).val,   centsToRaw(0),   'window start -> centre (rest 0)')
      t.eq(pbSeatAt(dump, 1, 15).val,  centsToRaw(30),  'peak  -> +depth cents as raw pb')
      t.eq(pbSeatAt(dump, 1, 45).val,  centsToRaw(-30), 'trough -> -depth cents as raw pb')
      t.eq(pbSeatAt(dump, 1, 240).val, centsToRaw(0),   'window end re-centres (closed span)')
    end,
  },

  ----- Window end re-centres the channel (no residual bend)

  {
    name = 'vibrato re-centres the channel at the window end (no residual bend)',
    run = function(harness)
      local h = harness.mk()
      addVibHost(h)
      local seats = pbSeatsOf(h.fm:dump(), 1)
      local last  = seats[#seats]
      t.eq(last.ppq, 240, 'terminal seat sits at the host window end (closed span)')
      t.eq(last.val, centsToRaw(0), 'terminal value is centre -- summed 0, channel re-centred')
    end,
  },

  ----- Seats are window-local (no take-start anchor -- the window self-centres)

  {
    name = 'seats are confined to the host window; the window opens at centre',
    run = function(harness)
      local h = harness.mk()
      addVibHost(h, { ppq = 120, endppq = 240 })
      local seats = pbSeatsOf(h.fm:dump(), 1)
      t.eq(seats[1].ppq, 120, 'the first seat is at the window start, not a take-start anchor')
      t.eq(seats[1].val, centsToRaw(0), 'the window opens at centre')
    end,
  },

  ----- G4 — round-trip stability (FIRST: frame/rounding tripwire)

  {
    name = 'G4: vibrato pb seat stream is byte-identical across flush -> rebuild -> flush (swing + delay)',
    run = function(harness)
      local h = harness.mk{
        config = { project = { swings = { ['c58'] = classic58 } } },
        data   = { swing = { global = 'c58' } },
      }
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                      vel = 100, detune = 0, delay = 500, lane = 1, fx = vib30 })
      h.tm:flush()

      local before = pbSeatsOf(h.fm:dump(), 1)
      t.truthy(#before > 0, 'seats present (non-vacuous)')
      h.tm:rebuild()
      h.tm:flush()
      local after = pbSeatsOf(h.fm:dump(), 1)
      t.deepEq(after, before, 'no seat churn across the round trip')
    end,
  },

  ----- Re-derivation fixpoint — a markerless seat re-derived must not promote to a marked one

  {
    name = 're-deriving the channel keeps its markerless seats markerless (route-by-window fixpoint)',
    run = function(harness)
      local h = harness.mk{
        config = { project = { swings = { ['c58'] = classic58 } } },
        data   = { swing = { global = 'c58' } },
      }
      addVibHost(h)
      local before = pbSeatsOf(h.fm:dump(), 1)
      t.truthy(#before > 0, 'seats present (non-vacuous)')
      for _, s in ipairs(before) do t.eq(s.plain, true, 'first-derive seats are markerless') end

      -- Force a full re-derive from the channel's own markerless seats: rebuildCCs recognises them by their
      -- prev pb window and leaves them markerless (a bare rebuild() freezes chan 1, never exercising it).
      h.tm:rebuild(true)

      local after = pbSeatsOf(h.fm:dump(), 1)
      for _, s in ipairs(after) do
        t.eq(s.plain, true, 're-derived seat stays markerless -- not promoted to a marked seat')
      end
      t.deepEq(after, before, 're-derive is a fixpoint: no seat churn, no ppqL sidecar stamped')
    end,
  },

  ----- G2 — both directions

  {
    name = 'G2: fx present yields pb seats; fx removed leaves none after reconcile',
    run = function(harness)
      local h = harness.mk()
      addVibHost(h)
      t.truthy(#pbSeatsOf(h.fm:dump(), 1) > 0, 'seats present with fx')

      local hostEvt = h.tm:getChannel(1).columns.notes[1].events[1]
      h.tm:assignEvent(hostEvt, { fx = util.REMOVE })
      h.tm:flush()
      t.eq(#pbSeatsOf(h.fm:dump(), 1), 0, 'no seat survives fx removal')
    end,
  },

  ----- Regeneration — the single cents->raw site re-runs under config change

  {
    name = 'regeneration: a pbRange change rescales pb seat values (cents -> raw at flush)',
    run = function(harness)
      local h = harness.mk()
      addVibHost(h)
      t.eq(pbSeatAt(h.fm:dump(), 1, 15).val, centsToRaw(30, 2), 'peak under pbRange 2')

      h.cm:assign('transient', { pbRange = 4 })
      h.tm:rebuild()
      t.eq(pbSeatAt(h.fm:dump(), 1, 15).val, centsToRaw(30, 4),
        'wider pb range -> smaller raw delta for the same cents')
    end,
  },

  ----- Any lane — a continuous gesture bends the channel pb regardless of host lane

  {
    name = 'vibrato on a higher lane seats a channel pb stream (lane-blind gesture)',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                      vel = 100, detune = 0, delay = 0, lane = 1 })
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 67,
                      vel = 100, detune = 0, delay = 0, lane = 2, fx = vib30 })
      h.tm:flush()
      t.truthy(#pbSeatsOf(h.fm:dump(), 1) > 0, 'a higher-lane vibrato still bends the channel pb')
    end,
  },

  ----- Regression — duration edits across a take round-trip (mm:load drops the RAM seat tag)

  {
    name = 'noteOff shrink after reload neither parks seats nor restores them as authored pbs',
    run = function(harness)
      local h = harness.mk()
      addVibHost(h, { endppq = 480 })

      -- mm:load rebuilds events from the wire, so seats come back derived=nil; the regionPark
      -- create-scan must recognise them by region (inside a previous window), not by tag.
      local function roundTrip() h.fm:load(); h.tm:rebuild() end
      local function shrinkTo(endppq)
        local host = h.tm:getChannel(1).columns.notes[1].events[1]
        h.tm:assignEvent(host, { endppq = endppq })
        h.tm:flush()
      end

      roundTrip()
      shrinkTo(240)
      for _, spec in ipairs(h.ds:get('fxParked') or {}) do
        t.falsy(spec.evType == 'pb', 'no seat mistaken for an authored pb and parked')
      end

      roundTrip()
      shrinkTo(120)
      local seats = pbSeatsOf(h.fm:dump(), 1)
      t.truthy(#seats > 0, 'seats present (non-vacuous)')
      t.eq(seats[#seats].ppq, 120, 'no stranded pb beyond the shrunk window')
      t.falsy(h.tm:getChannel(1).columns.pb, 'no phantom authored pbs surface in the pb column')
    end,
  },

  ----- Projection — the derived seats never surface as an editable column

  {
    name = 'vibrato seats never surface as a visible cc or pb column',
    run = function(harness)
      local h = harness.mk()
      addVibHost(h)
      local cols = h.tm:getChannel(1).columns
      t.falsy(next(cols.ccs or {}), 'no cc column -- pb-augment no longer bakes a carrier')
      t.falsy(cols.pb, 'the derived seats are hidden -- no pb column without an authored breakpoint')
    end,
  },

}
