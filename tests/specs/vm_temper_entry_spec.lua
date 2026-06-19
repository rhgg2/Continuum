-- Wired entry under a temperament: drives the real tv:editEvent path
-- (not a re-implementation) so the pitch/octave snapping it performs is
-- the production wiring. The octave column edits the temper's period-
-- cycle octave, keeping the scale step, and rejects octaves a note
-- cannot sit on exactly. See docs/tuning.md for the coordinate model.

local t       = require('support')
local tuning  = require('tuning')

-- A just-intonation temper whose period (9/4) is not an octave, so the
-- period-cycle octave (column) and the 12EDO keyboard octave diverge.
local JI = tuning.derive{
  name = 'JI', periodPitch = '9/4',
  pitches = { '4/4', '5/4', '6/4', '7/4', '8/4' },
  stepNames = {}, periodAsStep = true,
}

local function mk(harness)
  local h = harness.mk{
    seed   = { notes = {} },
    config = {
      take    = { currentOctave = 4 },
      project = { tempers = { JI = JI }, temper = 'JI' },
    },
  }
  h.vm:setGridSize(80, 40)
  return h
end

local function lane1(h)
  for _, c in ipairs(h.vm.grid.cols) do
    if c.midiChan == 1 and c.type == 'note' and c.lane == 1 then return c end
  end
end

-- The pitch part spans two cursor stops (note letter, octave digit);
-- discover them so the test is independent of cellWidth.
local function pitchStops(col)
  local stops = {}
  for s, part in pairs(col.partAt) do
    if part == 'pitch' then stops[#stops + 1] = s end
  end
  table.sort(stops)
  return stops[1], stops[#stops]
end

return {
  {
    name = 'octave column keeps the scale step and sets the period-cycle octave',
    run = function(harness)
      local h = mk(harness)
      local col = lane1(h)
      local letterStop, octStop = pitchStops(col)

      -- Place a note: 'z' = C, snaps to a step at some period-cycle octave.
      h.ec:setPos(0, 1, letterStop)
      h.vm:editEvent(col, nil, letterStop, string.byte('z'), false)

      col = lane1(h)
      local note  = col.cells[0]
      local step0 = select(1, tuning.midiToStep(JI, note.pitch, note.detune))

      -- Type octave 5 into the octave column (cursor on the note's row so
      -- the edit does not repin ppq).
      h.ec:setPos(0, 1, octStop)
      h.vm:editEvent(col, note, octStop, string.byte('5'), false)

      col = lane1(h)
      note = col.cells[0]
      local step, oct = tuning.midiToStep(JI, note.pitch, note.detune)
      local bump = step >= JI.octaveStep and 1 or 0

      t.eq(step, step0, 'scale step preserved across the octave edit')
      t.eq(oct + bump, 5, 'displayed period-cycle octave is the typed digit')
      local _, _, gap = h.vm:noteProjection(note)
      t.eq(gap, 0, 'note stays exactly on its step (in-temper)')
    end,
  },

  {
    name = 'octave column rejects an octave the note cannot sit on exactly',
    run = function(harness)
      local h = mk(harness)
      local col = lane1(h)
      local letterStop, octStop = pitchStops(col)

      h.ec:setPos(0, 1, letterStop)
      h.vm:editEvent(col, nil, letterStop, string.byte('z'), false)

      col = lane1(h)
      local before = col.cells[0]
      local pitch0, detune0 = before.pitch, before.detune

      -- Octave 9: a 9/4-period note that high clamps into MIDI range, so
      -- it could not sit on its step — the edit must be a no-op.
      h.ec:setPos(0, 1, octStop)
      h.vm:editEvent(col, before, octStop, string.byte('9'), false)

      col = lane1(h)
      local after = col.cells[0]
      t.eq(after.pitch,  pitch0,  'pitch unchanged by the rejected octave')
      t.eq(after.detune, detune0, 'detune unchanged by the rejected octave')
    end,
  },

  {
    name = 'pitch nudge keeps a note in the addressable range (refuses past the ceiling)',
    run = function(harness)
      local h = mk(harness)
      local col = lane1(h)
      local letterStop = (pitchStops(col))

      h.ec:setPos(0, 1, letterStop)
      h.vm:editEvent(col, nil, letterStop, string.byte('z'), false)
      local placed = lane1(h).cells[0].pitch

      -- Climb with coarse pitch nudges; the cursor stays on the note's row so
      -- each nudge transposes it in place. It saturates near MIDI 127.
      h.ec:setPos(0, 1, letterStop)
      for _ = 1, 40 do h.cmgr:invoke('nudgeCoarseUp') end

      local note = lane1(h).cells[0]
      t.truthy(note.pitch > placed, 'the note climbed')
      t.truthy(note.pitch <= 127, 'pitch within MIDI range')
      t.truthy(math.abs(note.detune) <= 50,
        'parked on a seated step, not a clamp-fold: ' .. tostring(note.detune))

      -- One more nudge at the ceiling is a verified no-op.
      local p0, d0 = note.pitch, note.detune
      h.cmgr:invoke('nudgeCoarseUp')
      note = lane1(h).cells[0]
      t.eq(note.pitch,  p0, 'ceiling nudge is a no-op (pitch)')
      t.eq(note.detune, d0, 'ceiling nudge is a no-op (detune)')
    end,
  },
}
