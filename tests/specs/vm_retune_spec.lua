-- Retune: with no target tv:retune(slots) runs every note in scope through
-- tuning.snap and writes the pair back, strength being how far of the way there
-- it actually lands, and remembers the target and key on the take. The notation
-- is a twelve-note quarter-comma meantone MOS, so a step's seat carries a detune
-- of its own and the window is asymmetric (+38.0 / -58.6 either side of step 1).
--
-- With a target it is the solve: the scope's notes grouped into strands by
-- step-class, shortlisted from the notation and the target, and handed to
-- sonority.solveToPoints. Those cases write a dominant seventh under a 12-EDO notation
-- against the 7-limit diamond at odd limit 9 -- the chord the pull is calibrated
-- on (design/adaptive-tuning.md § Harmonic lock) -- and a tritone against the
-- 5-limit diamond at odd limit 15, the hole that refuses a solve.
--
-- With the facility on 'moves' the same target is read as intervals rather than
-- points: sonority.solveToMoves spells the strands against one another and settles
-- them by springs. Those cases write a C major and a C minor triad against 1/1, 5/4
-- and 3/2, the minor third being what no point of it reaches, and the purity slot
-- is what the springs hold their intervals to.
--
-- Either facility reads a note's render clip rather than its authored ceiling, so an
-- open tail sounds to the next onset in its lane rather than to the end of the take.
--
-- A note carrying an intent is stranded and seated on the step that intent names rather
-- than on the step its pitch reads as (design/sounding-anchor.md § What the note remembers).

local t      = require('support')
local tuning = require('tuning')
local util   = require('util')

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

local function note(ppq, pitch, detune, intentCents)
  return { ppq = ppq, endppq = ppq + 60, chan = 1, pitch = pitch, vel = 100,
           detune = detune, delay = 0, intentCents = intentCents }
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

-- The springs answer by relaxation rather than by construction, so their placements are
-- pinned to the thousandth of a cent the sweep converges to.
local function settles(a, b, msg)
  t.truthy(math.abs(a - b) < 1e-3, (msg or 'settles') .. ': ' .. tostring(a) .. ' vs ' .. tostring(b))
end

-- Seat of (step, octave) under MEAN, as the spec's expectation frame.
local function seat(step, oct) return tuning.stepToMidi(MEAN, step, oct) end

-- The C7 the pull is calibrated on, written at 12-EDO.
local function c7()
  return { note(0, 60, 0), note(0, 64, 0), note(0, 67, 0), note(0, 70, 0) }
end

-- The chord at a row, as cells by the pitch they sound on: every chan-1 note lane at once.
local function cellsAt(h, row)
  local byPitch = {}
  for _, c in ipairs(h.vm.grid.cols) do
    local e = c.type == 'note' and c.midiChan == 1 and c.cells[row]
    if e then byPitch[e.pitch] = e end
  end
  return byPitch
end

-- The same chord as detune alone, which is what most of these cases read.
local function chordAt(h, row)
  local byPitch = {}
  for pitch, e in pairs(cellsAt(h, row)) do byPitch[pitch] = e.detune end
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
    name = 'the snap seats a note on the step its intent names, and spends the intent',
    run = function(harness)
      -- Written on step 1 at octave 5, which is (72, 0), and sounding a hundred cents above
      -- it -- nearer step 2 than the step it was written on. Reasserting the page means
      -- seating it where it was written rather than where it sounds, and the intent that
      -- said so is spent in the doing (design/sounding-anchor.md § What the note remembers).
      local h = mk(harness, { note(0, 73, 0, 7200), note(0, 60, 0, 6000) })
      h.vm:retune{ scope = 'all', strength = 1 }

      local cells = cellsAt(h, 0)
      t.truthy(cells[72], 'seated on the step it was written on, not the one it sounds nearest')
      near(cells[72].detune, 0, 'and exactly on it')
      t.eq(cells[72].intentCents, nil, 'the intent is spent')
      t.eq(cells[60].intentCents, nil, 'and one standing on its written step gives its up too')
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
      local refused = h.vm:retune{ scope = 'all', strength = 1, target = 'DIA', key = 3,
                                   facility = 'points', sonoritySize = 5, harmonicLock = 1 }
      t.eq(h.cm:getAt('take', 'retune.target'), 'DIA', 'the target is written at take tier')
      t.eq(h.cm:getAt('take', 'retune.key'), 3, 'so is the key')
      t.truthy((h.cm:getAt('project', 'tempers') or {}).DIA,
               'the target is localized into the project library')
      t.deepEq(refused, { 5 }, 'the step the refusal names')
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
                   facility = 'points', sonoritySize = 5, harmonicLock = 0.5 }
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
                   facility = 'points', sonoritySize = 5, harmonicLock = 1.5 }
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
                   facility = 'points', sonoritySize = 5, harmonicLock = 0.5 }
      local chord = chordAt(h, 0)
      near(chord[70], offset('7/4', 10), 'the seventh still takes 7/4')
      near(chord[82], offset('7/4', 10), 'and its octave takes it an octave up')
    end,
  },

  {
    name = 'a note moved off its step strands with the class its intent names',
    run = function(harness)
      local notes = c7()
      -- The seventh's octave, sounding 80 cents above the Bb it was written on: read off
      -- its pitch it is a B of its own, and strands and shortlists as one.
      notes[5] = note(0, 83, -20, 8200)
      local h = mk(harness, notes, '12EDO', { SEPTIMAL = SEPTIMAL })
      h.vm:retune{ scope = 'all', strength = 1, target = 'SEPTIMAL', key = 1,
                   facility = 'points', sonoritySize = 5, harmonicLock = 0.5 }
      local chord = chordAt(h, 0)
      t.truthy(chord[82], 'the drifted octave is seated in the register it was written in')
      near(chord[70], offset('7/4', 10), 'the seventh takes 7/4')
      near(chord[82], offset('7/4', 10), 'and the octave of it takes 7/4 too')
    end,
  },

  {
    name = 'a step the target leaves nowhere to go refuses the solve and names it',
    run = function(harness)
      local h = mk(harness, { note(0, 60, 0), note(0, 64, 0), note(0, 66, 0) },
                   '12EDO', { FIVES = FIVES })
      local refused = h.vm:retune{ scope = 'all', strength = 1, target = 'FIVES', key = 1,
                                   facility = 'points', sonoritySize = 5, harmonicLock = 0.5 }
      t.deepEq(refused, { 7 }, 'the tritone, step 7 of the notation')
      t.eq(chordAt(h, 0)[64], 0, 'and the third that would have moved is untouched')
    end,
  },

  {
    name = 'widened, the refusing class takes the point the music around it wants',
    run = function(harness)
      local slots = { scope = 'all', strength = 1, target = 'FIVES', key = 1,
                      facility = 'points', sonoritySize = 5, harmonicLock = 1 }
      -- The tritone beside one other note, its window stretched to the pair either side.
      local function beside(pitch)
        local h = mk(harness, { note(0, 60, 0), note(0, pitch, 0), note(0, 66, 0) },
                     '12EDO', { FIVES = FIVES })
        t.eq(h.vm:retune(slots, true), nil, 'the widened solve refuses nothing')
        return chordAt(h, 0)
      end

      local withA = beside(69)
      near(withA[65], offset('4/3', 5), 'beside A the tritone leaves F# for F, taking 4/3')
      t.eq(withA[66], nil, 'so nothing is left on the step it was written on')

      local withD = beside(62)
      near(withD[67], offset('3/2', 7), 'and beside D it leaves F# for G, taking 3/2')
      near(withD[62], offset('9/8', 2), 'the D standing on the point its own window holds')
    end,
  },

  {
    name = 'a widened solve stamps the step it carried a note off, and answers alike again',
    run = function(harness)
      -- The diamond holds no point inside the C sharp's window, so widened it takes the 10/9
      -- above the C -- 82 cents up, which is inside the D's own window. Read off its pitch the
      -- note is a D and takes the 9/8 the D holds; read off the intent the solve stamped it is
      -- the C sharp it was written as, and the second run answers as the first did.
      local h = mk(harness, { note(0, 60, 0), note(0, 61, 0), note(0, 67, 0) },
                   '12EDO', { SEPTIMAL = SEPTIMAL })
      local slots = { scope = 'all', strength = 1, target = 'SEPTIMAL', key = 1,
                      facility = 'points', sonoritySize = 5, harmonicLock = 0.5 }

      h.vm:retune(slots, true)
      local cells = cellsAt(h, 0)
      near(cells[62].detune, offset('10/9', 2), 'the C sharp takes the 10/9, inside the D above it')
      t.eq(cells[62].intentCents, 6100, 'and carries the step it was written on')
      t.eq(cells[60].intentCents, 6000, 'the C stamped too, though it never left its step')

      h.vm:retune(slots, true)
      near(chordAt(h, 0)[62], offset('10/9', 2), 'the second run leaves it where the first did')
    end,
  },

  {
    name = 'the facility decides how the same target is read',
    run = function(harness)
      local function retuned(facility)
        local h = mk(harness, { note(0, 60, 0), note(0, 64, 0), note(0, 67, 0) },
                     '12EDO', { DIA = DIA })
        h.vm:retune{ scope = 'all', strength = 1, target = 'DIA', facility = facility,
                     key = 1, sonoritySize = 5, harmonicLock = 1, purity = 8 }
        return chordAt(h, 0)
      end

      local points = retuned('points')
      near(points[60], 0,                 'read as points the key step keeps the 1/1')
      near(points[64], offset('5/4', 4),  'the third on the target point')
      near(points[67], offset('3/2', 7),  'and the fifth on its own')

      -- Read as moves nothing is fixed to the pitch line: the three stand at the target's
      -- own intervals, stretched by what the springs tolerate, and the pull settles where
      -- the chord as a whole sits (docs/sonority.md § The springs).
      local moves = retuned('moves')
      settles(moves[60],  3.7533, 'the C carried off its seat by the pull')
      settles(moves[64], -9.3855, 'the third a stretched 5/4 above it')
      settles(moves[67],  5.6302, 'the fifth a narrowed 3/2 above that')
    end,
  },

  {
    name = 'the moves facility spells a third the target holds no point for',
    run = function(harness)
      -- C minor against 1/1, 5/4 and 3/2: read as points the E flat has nothing in its
      -- window; read as moves it joins the fifth a 5/4 below, standing a 6/5 above the
      -- C the set cannot sound directly (docs/sonority.md § The candidates).
      local function retuned(facility)
        local h = mk(harness, { note(0, 60, 0), note(0, 63, 0), note(0, 67, 0), note(0, 75, 0) },
                     '12EDO', { DIA = DIA })
        local refused = h.vm:retune{ scope = 'all', strength = 1, target = 'DIA',
                                     facility = facility, key = 1,
                                     sonoritySize = 5, harmonicLock = 1, purity = 8 }
        return chordAt(h, 0), refused
      end

      local stood, refused = retuned('points')
      t.deepEq(refused, { 4 }, 'the points reading has nowhere to put the minor third')
      t.eq(stood[63], 0, 'so nothing moved')

      local placed = retuned('moves')
      settles(placed[60], -5.6314, 'the C, the chord mirroring the major triad')
      settles(placed[63],  9.3842, 'the E flat a 6/5 above it, reached through the fifth')
      settles(placed[67], -3.7546, 'the fifth a 3/2 above the C')
      settles(placed[75],  9.3842, 'and the octave doubling seated in its own register')
    end,
  },

  {
    name = 'purity prices how nearly the spelled intervals sound pure',
    run = function(harness)
      -- The same triad under two purities: soft springs leave the third audibly wide,
      -- and stiff ones close it by carrying the notes further from where they were
      -- written (docs/sonority.md § The dials).
      local function retuned(purity)
        local h = mk(harness, { note(0, 60, 0), note(0, 64, 0), note(0, 67, 0) },
                     '12EDO', { DIA = DIA })
        h.vm:retune{ scope = 'all', strength = 1, target = 'DIA', facility = 'moves',
                     key = 1, sonoritySize = 5, harmonicLock = 1, purity = purity }
        return chordAt(h, 0)
      end

      local soft = retuned(2)
      settles(soft[60],  3.3517, 'soft springs seat the C nearest where it was written')
      settles(soft[64], -8.3794, 'the third standing 1.96 cents wide of a pure 5/4')
      settles(soft[67],  5.0274, 'and the fifth 0.28 cents narrow of a pure 3/2')

      local stiff = retuned(32)
      settles(stiff[60],  3.8670, 'stiff springs carry the C further out')
      settles(stiff[64], -9.6781, 'closing the third to 0.14 cents of pure')
      settles(stiff[67],  5.8020, 'and the fifth to 0.02 of pure')
    end,
  },

  {
    name = 'a strand pinned to its window edge keeps the step it was written on',
    run = function(harness)
      -- E flat, E and G against 1/1, 5/4 and 3/2. Nothing in the set reaches the minor
      -- third, so the E-G is spelled as a 5/4 -- 86 cents of stretch, which pins the G to
      -- the top of its window. A strand standing on the edge itself would be equidistant
      -- from two steps, and would read as the other one when the command was run again.
      local h = mk(harness, { note(0, 63, 0), note(0, 64, 0), note(0, 67, 0) },
                   '12EDO', { DIA = DIA })
      local slots = { scope = 'all', strength = 1, target = 'DIA', facility = 'moves',
                      key = 1, sonoritySize = 5, harmonicLock = 1, purity = 8 }

      h.vm:retune(slots)
      local first = chordAt(h, 0)
      settles(first[67],  50,      'the G pinned to the top of its window')
      settles(first[64], -31.8618, 'the E a stretched 5/4 below it')
      settles(first[63], -43.1239, 'and the E flat, which the set reaches from neither')

      h.vm:retune(slots)
      local second = chordAt(h, 0)
      for pitch, detune in pairs(first) do
        t.truthy(second[pitch], 'the note on ' .. pitch .. ' is still written on its own step')
        settles(second[pitch], detune, 'and the second run leaves it where the first did')
      end
    end,
  },

  {
    name = 'an open tail sounds to its clip, so a class returning is a second strand',
    run = function(harness)
      -- A note typed with no OFF carries util.OPEN as its authored ceiling, and tm clips
      -- it to the next onset in its lane. Read literally the open C never stops, so it and
      -- the C that follows are one strand holding one tuning; read as it sounds they are
      -- two, each spelled against the chord it stands in.
      local h = mk(harness, {}, '12EDO', { FIVES = FIVES })
      local function add(ppq, endppq, pitch, lane)
        h.tm:addEvent{ evType = 'note', ppq = ppq, endppq = endppq, endppqL = endppq,
                       chan = 1, lane = lane, pitch = pitch, vel = 100, detune = 0, delay = 0 }
      end
      add(0,   util.OPEN, 60, 1)   -- clipped to 120, where the C returns
      add(120, 180,       60, 1)
      add(0,   60,        64, 2)   -- a major third over the first C
      add(120, 180,       69, 2)   -- a major sixth over the second
      h.tm:flush()

      h.vm:retune{ scope = 'all', strength = 1, target = 'FIVES', facility = 'moves',
                   key = 1, sonoritySize = 5, harmonicLock = 1, purity = 8 }

      local first, second = chordAt(h, 0), chordAt(h, 2)
      t.truthy(first[60] ~= second[60], 'the two C naturals are two strands, tuned apart')
      settles(first[60],   6.6877, 'the first C under its third')
      settles(second[60],  7.2438, 'and the second under its sixth')
      settles(first[64],  -6.1626, 'the third a 5/4 over the C it sounds with')
      settles(second[69], -7.7718, 'the sixth a 5/3 over the C it sounds with')
    end,
  },
}
