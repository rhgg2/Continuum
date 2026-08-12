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

-- 12EDO rooted at A4 = (step 1, octave 4), the root that puts octaves -2..8
-- in reach (docs/tuning.md § Addressable range). MIDI 60 reads D#3
-- under it, and octave -2 step 4 is MIDI 0.
local ROOTED = tuning.derive{
  name = 'ROOTED', periodPitch = '2/1',
  pitches   = { '0.', '100.', '200.', '300.', '400.', '500.', '600.', '700.',
                '800.', '900.', '1000.', '1100.' },
  stepNames = { 'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B' },
  rootPitch = 69, rootDetune = 0, rootStep = 1, rootOctave = 4,
}

-- A 300-cent period puts 43 periods inside MIDI range, so the octave field is
-- two chars wide (docs/tuning.md § Display).
local NARROW = tuning.derive{
  name = 'NARROW', periodPitch = '300.',
  pitches = { '0.', '100.', '200.' },
  stepNames = {},
}

local function mk(harness, temper)
  temper = temper or JI
  local h = harness.mk{
    seed   = { notes = {} },
    config = {
      take    = { currentOctave = 4 },
      project = { tempers = { [temper.name] = temper }, temper = temper.name },
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

-- The octave the cell shows: the period-index octave plus the octaveStep bump.
local function octaveShown(h, temper)
  local note = lane1(h).cells[0]
  local step, oct = tuning.midiToStep(temper, note.pitch, note.detune)
  return oct + (step >= temper.octaveStep and 1 or 0), note
end

-- Places a note at the cursor and returns a typist for its octave stop.
local function rootedNote(harness)
  local h   = mk(harness, ROOTED)
  local col = lane1(h)
  local colIdx
  for i, c in ipairs(h.vm.grid.cols) do if c == col then colIdx = i end end
  local letterStop, octStop = pitchStops(col)

  h.ec:setPos(0, colIdx, letterStop)
  h.vm:editEvent(col, nil, letterStop, string.byte('z'), false)

  return h, colIdx, function(ch)
    local live = lane1(h)
    h.ec:setPos(0, colIdx, octStop)
    h.vm:editEvent(live, live.cells[0], octStop, string.byte(ch), false)
  end
end

-- Places a note under NARROW and returns the harness, its column index and the
-- pitch part's three stops: the note name, then the octave's tens and units.
local function narrowNote(harness)
  local h   = mk(harness, NARROW)
  local col = lane1(h)
  local colIdx
  for i, c in ipairs(h.vm.grid.cols) do if c == col then colIdx = i end end
  local nameStop, unitsStop = pitchStops(col)

  h.ec:setPos(0, colIdx, nameStop)
  h.vm:editEvent(col, nil, nameStop, string.byte('z'), false)

  return h, colIdx, nameStop, unitsStop - 1, unitsStop
end

return {
  {
    name = 'a shift-held digit walks the places of a two-char octave field',
    run = function(harness)
      local h, colIdx, _, tensStop, unitsStop = narrowNote(harness)
      t.eq(NARROW.octaveWidth, 2, 'the octave field is two chars wide')
      t.eq(NARROW.cellWidth,   4, 'and the cell is a two-char label plus it')
      t.eq((octaveShown(h, NARROW)), 19, 'MIDI 60 sits at octave 19 under this period')

      h.ec:setPos(0, colIdx, tensStop)
      t.truthy(h.vm:digitsStrike(string.byte('2')), 'the tens digit is consumed')
      t.eq((octaveShown(h, NARROW)), 29, 'the tens place is overwritten keep-below')
      t.eq(select(3, h.ec:pos()), unitsStop, 'the sub-caret stepped to the units place')
      t.eq(h.ec:row(), 0, 'and the gesture holds the row')

      t.truthy(h.vm:digitsStrike(string.byte('5')), 'the units digit is consumed')
      t.eq((octaveShown(h, NARROW)), 25, 'the units place is overwritten')

      t.truthy(h.vm:digitsBackspace(), 'backspace is consumed')
      t.eq((octaveShown(h, NARROW)), 29, 'both pitch and detune came back')

      h.vm:digitsCommit()
      t.eq(h.ec:row(), 1, 'shift release advances a row')
    end,
  },

  {
    name = 'the octave gesture declines on the note-name stop',
    run = function(harness)
      local h, colIdx, nameStop = narrowNote(harness)
      h.ec:setPos(0, colIdx, nameStop)
      t.eq(h.vm:digitsStrike(string.byte('2')), false, 'the name stop is chordStrike\'s')
      t.falsy(h.vm:digitsActive(), 'no gesture armed')
    end,
  },

  {
    name = 'the octave gesture declines on a cell with no note',
    run = function(harness)
      local h, colIdx, _, tensStop = narrowNote(harness)
      h.ec:setPos(4, colIdx, tensStop)
      t.eq(h.vm:digitsStrike(string.byte('2')), false, 'no note to name an octave of')
      t.falsy(h.vm:digitsActive(), 'no gesture armed')
    end,
  },

  {
    name = 'a plain digit on the tens place zeroes the units below it',
    run = function(harness)
      local h, colIdx, _, tensStop = narrowNote(harness)
      local col = lane1(h)
      h.ec:setPos(0, colIdx, tensStop)
      h.vm:editEvent(col, col.cells[0], tensStop, string.byte('2'), false)
      t.eq((octaveShown(h, NARROW)), 20, '19 → 2 → 20, as sample and vel behave')
    end,
  },

  {
    name = "the octave column negates in place, and the next digit keeps the sign",
    run = function(harness)
      local h, _, type_ = rootedNote(harness)
      t.eq((octaveShown(h, ROOTED)), 3, 'MIDI 60 places at octave 3 under this root')

      type_('1')
      t.eq((octaveShown(h, ROOTED)), 1, 'digit sets the octave')
      t.eq(h.ec:row(), 1, 'a digit advances')

      type_('-')
      t.eq((octaveShown(h, ROOTED)), -1, 'minus negates the octave under the cursor')
      t.eq(h.ec:row(), 0, 'the negation stays on the row')

      type_('2')
      local oct, note = octaveShown(h, ROOTED)
      t.eq(oct, -2, 'the digit sets the magnitude and keeps the sign')
      t.eq(note.pitch, 0, 'octave -2 of this root is MIDI 0')
      t.eq(note.detune, 0, 'and sits exactly on its step')

      type_('-')
      t.eq((octaveShown(h, ROOTED)), 2, 'minus flips back')
    end,
  },

  {
    name = "minus on octave zero arms the sign before the digit lands",
    run = function(harness)
      local h, colIdx, type_ = rootedNote(harness)
      type_('0')
      local _, before = octaveShown(h, ROOTED)
      local pitch0, detune0 = before.pitch, before.detune

      type_('-')
      local oct, note = octaveShown(h, ROOTED)
      t.eq(oct, 0, 'the arm writes no octave')
      t.eq(note.pitch, pitch0, 'nor a pitch')
      t.eq(note.detune, detune0, 'nor a detune')

      local part, sign = h.vm:entrySignAt(0, colIdx)
      t.eq(part, 'pitch', 'the octave cell is armed')
      t.eq(sign, -1, 'and reads negative, so the tint shows it')

      type_('1')
      t.eq((octaveShown(h, ROOTED)), -1, 'the digit consumed the arm')
      t.eq(h.vm:entrySignAt(0, colIdx), nil, 'a signed octave carries its own sign')
    end,
  },

  {
    name = 'a negated octave the note cannot sit on is a no-op',
    run = function(harness)
      local h, _, type_ = rootedNote(harness)
      type_('3')
      local _, before = octaveShown(h, ROOTED)
      local pitch0, detune0 = before.pitch, before.detune

      type_('-')   -- octave -3 is below MIDI 0 under this root
      local _, after = octaveShown(h, ROOTED)
      t.eq(after.pitch,  pitch0,  'pitch unchanged by the rejected negation')
      t.eq(after.detune, detune0, 'detune unchanged by the rejected negation')
    end,
  },

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
      local gap = h.vm:noteDeviation(note)
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
