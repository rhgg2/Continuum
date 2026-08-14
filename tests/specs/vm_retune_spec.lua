-- Retune: with no target tv:retune(slots) runs every note in scope through
-- tuning.snap and writes the pair back, strength being how far of the way there
-- it actually lands, and remembers the target and key on the take. The notation
-- is a twelve-note quarter-comma meantone MOS, so a step's seat carries a detune
-- of its own and the window is asymmetric (+38.0 / -58.6 either side of step 1).
--
-- With a target it is the solve: the scope's notes grouped into strands by
-- step-class, shortlisted from the notation and the target, and handed to
-- sonority.solve. Those cases write a dominant seventh under a 12-EDO notation
-- against the 7-limit diamond at odd limit 9 -- the chord the pull is calibrated
-- on (design/adaptive-tuning.md § Harmonic lock) -- and a tritone against the
-- 5-limit diamond at odd limit 15, the hole that refuses a solve.

local t      = require('support')
local tuning = require('tuning')

local MEAN = tuning.derive{
  name = 'MEAN', periodPitch = '2/1',
  pitches = { '0.0000', '76.0490', '193.1569', '310.2647', '386.3137', '503.4216',
              '579.4706', '696.5784', '772.6274', '889.7353', '1006.8431', '1082.8921' },
  stepNames = {},
}

-- A target: every pitch a ratio, so its points carry coords to score.
local DIA = tuning.derive{
  name = 'DIA', periodPitch = '2/1',
  pitches = { '1/1', '5/4', '3/2' },
  stepNames = {},
}

-- The diamonds the solve runs against, derived as the temper editor saves one.
local SEPTIMAL = tuning.derive(tuning.genDiamond(9, 7))
local FIVES    = tuning.derive(tuning.genDiamond(15, 5))

local function mk(harness, notes, temper, tempers)
  local h = harness.mk{
    seed   = { notes = notes },
    config = { project = { tempers = tempers or { MEAN = MEAN },
                           temper  = temper  or 'MEAN' } },
  }
  h.vm:setGridSize(80, 40)
  return h
end

local function note(ppq, pitch, detune)
  return { ppq = ppq, endppq = ppq + 60, chan = 1, pitch = pitch, vel = 100,
           detune = detune, delay = 0 }
end

local function lane1(h)
  for _, c in ipairs(h.vm.grid.cols) do
    if c.midiChan == 1 and c.type == 'note' and c.lane == 1 then return c end
  end
end

local function cell(h, row) return lane1(h).cells[row] end

local function near(a, b, msg)
  t.truthy(math.abs(a - b) < 1e-6, (msg or 'near') .. ': ' .. tostring(a) .. ' vs ' .. tostring(b))
end

-- Seat of (step, octave) under MEAN, as the spec's expectation frame.
local function seat(step, oct) return tuning.stepToMidi(MEAN, step, oct) end

-- The C7 the pull is calibrated on, written at 12-EDO.
local function c7()
  return { note(0, 60, 0), note(0, 64, 0), note(0, 67, 0), note(0, 70, 0) }
end

-- The chord at a row, as detune by written pitch: every chan-1 note lane at once.
local function chordAt(h, row)
  local byPitch = {}
  for _, c in ipairs(h.vm.grid.cols) do
    local e = c.type == 'note' and c.midiChan == 1 and c.cells[row]
    if e then byPitch[e.pitch] = e.detune end
  end
  return byPitch
end

-- The detune a target point lands as, seated on the 12-EDO note it is written on.
local function offset(token, semitones) return tuning.scalaPitch(token) - semitones * 100 end

return {
  {
    name = 'retune(all) seats an off-step note on its own step',
    run = function(harness)
      local h = mk(harness, { note(0, 76, 0) })       -- E5 written at 12EDO
      h.vm:retune{ scope = 'all', strength = 1 }
      local m, d = seat(5, 5)
      local n = cell(h, 0)
      t.eq(n.pitch, m, 'pitch of the meantone seat')
      near(n.detune, d, 'detune of the meantone seat')
      t.truthy(math.abs(n.detune + 13.69) < 0.01, 'meantone major third, 13.7 cents flat')
    end,
  },

  {
    name = 'a note past the half-way point lands on its neighbour',
    run = function(harness)
      -- Step 1 at octave 5 is (72, 0); its upper half-gap is 38.0 cents.
      local h = mk(harness, { note(0, 72, 40) })
      h.vm:retune{ scope = 'all', strength = 1 }
      local m, d = seat(2, 5)
      local n = cell(h, 0)
      t.eq(n.pitch, m, 'crossed to step 2')
      near(n.detune, d, 'seated on step 2')
    end,
  },

  {
    name = 'a note inside the window keeps its step',
    run = function(harness)
      local h = mk(harness, { note(0, 72, 37) })
      h.vm:retune{ scope = 'all', strength = 1 }
      local n = cell(h, 0)
      t.eq(n.pitch, 72, 'still step 1')
      near(n.detune, 0, 'seated back on step 1')
    end,
  },

  {
    name = 'a note already on its step is left where it is',
    run = function(harness)
      local m, d = seat(5, 5)
      local h = mk(harness, { note(0, m, d) })
      h.vm:retune{ scope = 'all', strength = 1 }
      local n = cell(h, 0)
      t.eq(n.pitch, m, 'pitch untouched')
      near(n.detune, d, 'detune untouched')
    end,
  },

  {
    name = 'a selection confines the snap to the notes inside it',
    run = function(harness)
      local h = mk(harness, { note(0, 76, 0), note(600, 76, 0) })
      h.ec:setSelection{ row1 = 0, row2 = 0, col1 = 1, col2 = 1,
                         part1 = 'pitch', part2 = 'pitch' }
      h.vm:retune{ scope = 'selection', strength = 1 }
      local _, d = seat(5, 5)
      near(cell(h, 0).detune, d,  'note inside the selection snapped')
      t.eq(cell(h, 10).detune, 0, 'note outside it untouched')
    end,
  },

  {
    name = 'half strength closes half the distance, and again on the next run',
    run = function(harness)
      -- 40 cents BELOW step 1 at octave 5: the window reaches only 38.0 above
      -- it, so a note at +40 would snap to step 2 instead (the case above).
      local h = mk(harness, { note(0, 72, -40) })
      h.vm:retune{ scope = 'all', strength = 0.5 }
      near(cell(h, 0).detune, -20, 'half way to the step')
      h.vm:retune{ scope = 'all', strength = 0.5 }
      near(cell(h, 0).detune, -10, 'half of what was left')
      t.eq(cell(h, 0).pitch, 72, 'still written as step 1')
    end,
  },

  {
    name = 'a blend below full strength is re-seated on the nearest semitone',
    run = function(harness)
      -- (73, +40) snaps to step 3 of octave 5, seated at (74, -6.8431); the
      -- blend at 0.5 is 7366.5784 cents, which seats on 74.
      local h = mk(harness, { note(0, 73, 40) })
      h.vm:retune{ scope = 'all', strength = 0.5 }
      local n = cell(h, 0)
      t.eq(n.pitch, 74, 'the written pitch moved a semitone')
      t.truthy(math.abs(n.detune + 33.4216) < 0.01,
               'half way to the seat, re-seated: ' .. tostring(n.detune))
    end,
  },

  {
    name = 'zero strength moves nothing, not even the written pitch',
    run = function(harness)
      -- More detune than half a semitone, so an enharmonic re-seat would show.
      local h = mk(harness, { note(0, 72, 70) })
      h.vm:retune{ scope = 'all', strength = 0 }
      local n = cell(h, 0)
      t.eq(n.pitch, 72, 'pitch untouched')
      near(n.detune, 70, 'detune untouched')
    end,
  },

  {
    name = 'retune remembers the target and the key on the take',
    run = function(harness)
      local h = mk(harness, { note(0, 76, 0) })
      h.cm:set('global', 'tempers', { DIA = DIA })
      -- Three points against a meantone window: the E has nowhere to go, so this
      -- take refuses, and the slots are remembered all the same.
      local step = h.vm:retune{ scope = 'all', strength = 1, target = 'DIA', key = 3,
                               sonoritySize = 5, harmonicLock = 1 }
      t.eq(h.cm:getAt('take', 'retune.target'), 'DIA', 'the target is written at take tier')
      t.eq(h.cm:getAt('take', 'retune.key'), 3, 'so is the key')
      t.truthy((h.cm:getAt('project', 'tempers') or {}).DIA,
               'the target is localized into the project library')
      t.eq(step, 5, 'the step the refusal names')
      near(cell(h, 0).detune, 0, 'and the refused note stands where it was written')
    end,
  },

  {
    name = 'retune with no target forgets the one the take carried',
    run = function(harness)
      local h = mk(harness, { note(0, 76, 0) })
      h.cm:set('take', 'retune.target', 'DIA')
      h.vm:retune{ scope = 'all', strength = 1, key = 1, sonoritySize = 5, harmonicLock = 1 }
      t.eq(h.cm:getAt('take', 'retune.target'), nil, 'none is remembered as none')
    end,
  },

  {
    name = 'a dominant seventh takes the otonal seventh the diamond offers',
    run = function(harness)
      local h = mk(harness, c7(), '12EDO', { SEPTIMAL = SEPTIMAL })
      h.vm:retune{ scope = 'all', strength = 1, target = 'SEPTIMAL', key = 1,
                   sonoritySize = 5, harmonicLock = 0.5 }
      local chord = chordAt(h, 0)
      near(chord[60], 0,                  'the key step keeps the 1/1 it was written on')
      near(chord[64], offset('5/4',  4),  'the third at 5/4')
      near(chord[67], offset('3/2',  7),  'the fifth at 3/2')
      near(chord[70], offset('7/4', 10),  'the seventh at 7/4')
    end,
  },

  {
    name = 'above the crossing the seventh gives up the otonal tuning',
    run = function(harness)
      local h = mk(harness, c7(), '12EDO', { SEPTIMAL = SEPTIMAL })
      h.vm:retune{ scope = 'all', strength = 1, target = 'SEPTIMAL', key = 1,
                   sonoritySize = 5, harmonicLock = 1.5 }
      local chord = chordAt(h, 0)
      near(chord[70], offset('16/9', 10), 'the Pythagorean seventh, for 27 cents of fidelity')
      near(chord[64], offset('5/4',   4), 'and the third is where it was')
    end,
  },

  {
    name = 'an octave doubling is seated in its own register, and moves no answer',
    run = function(harness)
      local notes = c7()
      notes[5] = note(0, 82, 0)
      local h = mk(harness, notes, '12EDO', { SEPTIMAL = SEPTIMAL })
      h.vm:retune{ scope = 'all', strength = 1, target = 'SEPTIMAL', key = 1,
                   sonoritySize = 5, harmonicLock = 0.5 }
      local chord = chordAt(h, 0)
      near(chord[70], offset('7/4', 10), 'the seventh still takes 7/4')
      near(chord[82], offset('7/4', 10), 'and its octave takes it an octave up')
    end,
  },

  {
    name = 'a step the target leaves nowhere to go refuses the solve and names it',
    run = function(harness)
      local h = mk(harness, { note(0, 60, 0), note(0, 64, 0), note(0, 66, 0) },
                   '12EDO', { FIVES = FIVES })
      local step = h.vm:retune{ scope = 'all', strength = 1, target = 'FIVES', key = 1,
                               sonoritySize = 5, harmonicLock = 0.5 }
      t.eq(step, 7, 'the tritone, step 7 of the notation')
      t.eq(chordAt(h, 0)[64], 0, 'and the third that would have moved is untouched')
    end,
  },
}
