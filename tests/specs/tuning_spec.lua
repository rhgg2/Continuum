-- Pins tuning.lua's pure display + derivation layer: the Option-B nameless
-- step labels, the derived octaveStep / cellWidth fields, and the coordinate
-- conversions between MIDI and step-octave. Realisation invariants (I1-I5)
-- live in tm_tuning_spec; projection wiring in view_context_spec.

local t      = require('support')
local util   = require('util')
local tuning = require('tuning')

local function nameless(cents)
  return tuning.derive{ name = 'scale', period = 1200, cents = cents, stepNames = {} }
end

-- The two label parts joined, so a case that is about the whole label can
-- assert it as one string.
local function stepText(temper, step, octave)
  local note, octaveStr = tuning.stepToParts(temper, step, octave)
  return note .. octaveStr
end

-- A 12EDO scale with the root fields the case is about; everything else default.
local function rooted(root)
  local cents = {}
  for i = 1, 12 do cents[i] = (i - 1) * 100 end
  local temper = { name = 'rooted', period = 1200, cents = cents, stepNames = {} }
  for k, v in pairs(root) do temper[k] = v end
  return tuning.derive(temper)
end

-- The same 12EDO in the shape a step edit sees: pitch tokens, names densified
-- to '' as cloneForEdit leaves them, so sortSteps and removeStep can drive it.
local function authored(root)
  local temper = { name = 'authored', periodPitch = '2/1', pitches = {}, stepNames = {} }
  for i = 1, 12 do temper.pitches[i], temper.stepNames[i] = (i - 1) .. '\\12', '' end
  for k, v in pairs(root) do temper[k] = v end
  return tuning.derive(temper)
end

-- Quarter-comma meantone's twelve-note MOS (Eb..G#, C at the unison): an
-- unequal scale, so a step's two neighbours sit at different distances.
local function meantone12()
  local s = tuning.genRank2('696.5784', '2/1', 12, 8)
  return tuning.derive{ name = 'QCM12', periodPitch = s.periodPitch,
                        pitches = s.pitches, stepNames = {} }
end

-- A4 = 415Hz: the root placed off the unison, so an edit that moves its step
-- shows up in every pitch the scale sounds.
local A415 = { rootPitch = 69, rootDetune = -101.27, rootStep = 10, rootOctave = 4 }

-- What the rooted step sounds, as (midi, detune); the deletions and sorts below
-- all claim to leave it alone.
local function soundsA415(temper, step, why)
  local midi, detune = tuning.stepToMidi(temper, step, 4)
  t.eq(midi, 68, why)
  t.truthy(math.abs(detune + 1.27) < 1e-9, 'detune ' .. detune)
end

return {
  {
    name = 'preset EDOs derive width 3 and a past-the-end octaveStep',
    run = function()
      local twelve = tuning.presets['12EDO']
      t.eq(twelve.cellWidth, 3, '12EDO cellWidth')
      t.eq(twelve.octaveWidth, 1, '12EDO octave field is one char (range -1..9)')
      t.eq(twelve.octaveStep, 13, '12EDO has no C-tail, so it never bumps')

      local thirtyOne = tuning.presets['31EDO']
      t.eq(thirtyOne.cellWidth, 3, '31EDO multi-byte names are still 2 display chars')
      t.eq(thirtyOne.octaveStep, 31, '31EDO C↓ tail bumps at the last step')
    end,
  },

  {
    name = 'named step renders name + octave',
    run = function()
      t.eq(stepText(tuning.presets['12EDO'], 1, 4), 'C-4')
      t.eq(stepText(tuning.presets['31EDO'], 31, 3), 'C↓4',
        'octaveStep bump: step 31 reads as the next octave')
    end,
  },

  {
    name = 'a negative octave renders as its magnitude and reports the sign',
    run = function()
      local note, octave, negative = tuning.stepToParts(tuning.presets['12EDO'], 1, -1)
      t.eq(note .. octave, 'C-1', 'octave -1 renders as the magnitude')
      t.eq(negative, true, 'and reports itself negative, for the tint')

      local _, octave4, negative4 = tuning.stepToParts(tuning.presets['12EDO'], 1, 4)
      t.eq(octave4, '4')
      t.eq(negative4, false, 'an octave at or above zero is not negative')
    end,
  },

  {
    name = 'the octaveStep bump owns the sign: a step that crosses zero is not negative',
    run = function()
      local temper = tuning.presets['31EDO']
      t.eq(temper.octaveStep, 31, '31EDO bumps at its last step')
      local _, octave, negative = tuning.stepToParts(temper, 31, -1)
      t.eq(octave, '0', 'the bump lands the rendered octave on zero')
      t.eq(negative, false, 'the sign is the rendered octave\'s, taken after the bump')
    end,
  },

  {
    name = 'nameless step falls back to degree-octave with a dash',
    run = function()
      local s = nameless{ 0, 400, 800 }
      t.eq(s.octaveStep, 4, 'no C-tail ⇒ bump sits past the last step')
      t.eq(s.cellWidth, 3, '1-digit degree + dash + octave')
      t.eq(stepText(s, 1, 4), '1-4')
      t.eq(stepText(s, 3, 4), '3-4')
      t.eq(stepText(s, 1, -1), '1-1', 'octave -1 renders as its magnitude')
    end,
  },

  {
    name = 'nameless scale past 9 steps widens the cell for 2-digit degrees',
    run = function()
      local cents = {}
      for i = 1, 12 do cents[i] = (i - 1) * 100 end
      local s = nameless(cents)
      t.eq(s.cellWidth, 4, '2-digit degree + dash + octave')
      t.eq(stepText(s, 12, 4), '12-4')
    end,
  },

  {
    name = 'sub-octave period widens the octave field for 2-digit octaves',
    run = function()
      -- period 600¢ packs ~21 cycles into [0,12700], so octave labels reach
      -- two digits; the octave field grows even though the degree is 1-digit.
      local s = tuning.derive{ name = 'half', period = 600,
                               cents = { 0, 300 }, stepNames = {} }
      t.eq(s.cellWidth, 4, '1-digit degree + dash + 2-digit octave')
      t.eq(s.octaveWidth, 2, 'octave field widens to two chars')
      t.eq(stepText(s, 1, 20), '1-20', 'two-digit octave renders in full')
    end,
  },

  {
    name = 'a root numbering the octaves near zero narrows the field',
    run = function()
      -- A compressed-octave temper packs 11 period-cycles into the MIDI range,
      -- so sizing on the count of cycles reserves two chars. Rooted so middle C
      -- sits in octave 0 the range runs -5..6, and one char covers both ends.
      local function compressed(root)
        local temper = { name = 'compressed', period = 1100,
                         cents = { 0, 275, 550, 825 }, stepNames = {} }
        for k, v in pairs(root) do temper[k] = v end
        return tuning.derive(temper)
      end

      local rooted0 = compressed{ rootOctave = -5 }
      t.eq(rooted0.octaveWidth, 1, 'both ends of -5..6 are one char')
      t.eq(rooted0.cellWidth, 3, '1-digit degree + dash + octave')
      local _, oct = tuning.midiToStep(rooted0, 60, 0)
      t.eq(oct, 0, 'the root is the one that puts middle C in octave 0')

      t.eq(compressed{}.octaveWidth, 2,
        'the same period at the default root spans -1..10 and needs two')
    end,
  },

  {
    name = 'a root numbering the range low makes the bottom end the wider',
    run = function()
      -- (1, 0) = (1, -9): the range runs -10..1, so the bottom carries two
      -- chars where the top carries one.
      local low = rooted{ rootPitch = 1, rootOctave = -9 }
      t.eq(low.octaveWidth, 2, 'the bottom end sizes the field')
      t.eq(low.cellWidth, 5, '2-digit degree + dash + 2-char octave')

      local step, oct = tuning.midiToStep(low, 0, 0)
      t.eq(stepText(low, step, oct), '12-10', 'MIDI 0 fills the cell exactly')
      local _, topOct = tuning.midiToStep(low, 127, 0)
      t.eq(topOct, 1, 'while the top end is a single char')
    end,
  },

  {
    name = 'derive recomputes width when names are dropped',
    run = function()
      local s = tuning.derive{ name = 'x', period = 1200,
        cents = { 0, 400, 800 }, stepNames = { 'Maj', 'Min', 'Aug' } }
      t.eq(s.cellWidth, 4, 'widest name (3 chars) + octave')
      s.stepNames = {}
      tuning.derive(s)
      t.eq(s.cellWidth, 3, 'dropping names reverts to degree width')
    end,
  },

  {
    name = 'partially named scale: named steps keep their label, blanks fall back',
    run = function()
      local s = tuning.derive{ name = 'x', period = 1200,
        cents = { 0, 400, 800 }, stepNames = { 'C', '', 'G' } }
      t.eq(stepText(s, 1, 4), 'C4')
      t.eq(stepText(s, 2, 4), '2-4', 'blank name ⇒ degree fallback')
      t.eq(stepText(s, 3, 4), 'G4')
    end,
  },

  {
    name = 'scalaPitch parses ratios, cents, bare integers and n\\m steps',
    run = function()
      t.eq(tuning.scalaPitch('1/1'), 0)
      t.eq(tuning.scalaPitch('2/1'), 1200)
      t.eq(tuning.scalaPitch('3/2'), 1200 * math.log(3 / 2, 2))
      t.eq(tuning.scalaPitch('204.0'), 204.0, 'decimal point ⇒ cents')
      t.eq(tuning.scalaPitch('2'), 1200, 'bare integer ⇒ ratio n/1')
      t.eq(tuning.scalaPitch('7\\31'), 7 * 1200 / 31, 'n\\m ⇒ n*1200/m')
      t.eq(tuning.scalaPitch('3\\8<3/2>'), 3 * tuning.scalaPitch('3/2') / 8,
        'n\\m<equave> ⇒ equal divisions of the equave')
      t.eq(tuning.scalaPitch('12\\12<2/1>'), 1200, 'explicit octave equave = plain n\\m')
      t.eq(tuning.scalaPitch('1\\2<oops>'), nil, 'unparseable equave ⇒ nil')
      t.eq(tuning.scalaPitch(' 9/8 '), tuning.scalaPitch('9/8'), 'trims whitespace')
      t.eq(tuning.scalaPitch('junk'), nil)
    end,
  },

  {
    name = 'derive compiles pitches → cents and periodPitch → period',
    run = function()
      local s = tuning.derive{ name = 'p', periodPitch = '2/1',
        pitches = { '1/1', '9/8', '5/4' }, stepNames = {} }
      t.eq(s.period, 1200)
      t.eq(s.cents[1], 0)
      t.eq(s.cents[2], 1200 * math.log(9 / 8, 2))
      t.eq(s.cents[3], 1200 * math.log(5 / 4, 2))
    end,
  },

  {
    name = 'derive reduces an authored root to rootCents + octaveBase',
    run = function()
      local cents = {}
      for i = 1, 12 do cents[i] = (i - 1) * 100 end
      local s = tuning.derive{ name = 'a415', period = 1200, cents = cents, stepNames = {},
        rootPitch = 69, rootDetune = -101.27, rootStep = 10, rootOctave = 4 }
      t.eq(s.rootCents, 5898.73,
        'step 10 of 12EDO sits 900c above the unison, so an A tuned to 415Hz '
        .. 'puts the scale unison at 5898.73c')
      t.eq(s.octaveBase, 4, 'period-index 0 carries the root octave untransformed')
    end,
  },

  {
    name = 'a preset states no root and derives the default (0,0) = (1,-1)',
    run = function()
      local twelve = tuning.presets['12EDO']
      t.eq(twelve.rootCents, 0, 'MIDI 0 on the unison leaves the unison at 0c')
      t.eq(twelve.octaveBase, -1, 'MIDI 0 is C-1')
      t.eq(twelve.rootPitch, nil, 'derive reads the root through, never writes it back')
      t.eq(twelve.rootDetune, nil)
      t.eq(twelve.rootStep, nil)
      t.eq(twelve.rootOctave, nil)
    end,
  },

  {
    name = 'unrooted is the library form: the four dropped, the stamps back at the default',
    run = function()
      local plain  = rooted{}
      local placed = rooted{ rootPitch = 69, rootDetune = -101.27, rootStep = 10, rootOctave = 4 }

      local stripped = tuning.unrooted(placed)

      t.truthy(util.deepEq(stripped, plain),
               'the library form of a placed scale is the scale, stamps and all')
      t.eq(placed.rootPitch, 69, 'the placed copy is left alone')
      t.eq(placed.rootCents, 5898.73)
    end,
  },

  {
    name = 'a deleted step takes the root\'s index down with it',
    run = function()
      local below = tuning.derive(tuning.removeStep(authored(A415), 3))
      t.eq(below.rootStep, 9, 'the rooted step lost a step from under it')
      t.eq(below.rootCents, 5898.73, 'so it names the same 900c step, and the scale is unmoved')
      soundsA415(below, 9, 'the rooted step still sounds A415')

      local above = tuning.derive(tuning.removeStep(authored(A415), 11))
      t.eq(above.rootStep, 10, 'a step above the root leaves its index alone')
      t.eq(above.rootCents, 5898.73)
    end,
  },

  {
    name = 'deleting the rooted step restates the root on the unison',
    run = function()
      local before = authored(A415)
      local after  = tuning.derive(tuning.removeStep(authored(A415), 10))

      t.eq(after.rootStep, 1, 'the step the root named is gone, so it moves to the one every scale keeps')
      t.eq(after.rootPitch, 59, 'MIDI 59 is where the unison was already sounding')
      t.truthy(math.abs(after.rootDetune + 1.27) < 1e-9, 'rootDetune ' .. after.rootDetune)
      t.eq(after.rootOctave, 4, 'the octave the root was authored in is untouched')
      t.eq(after.rootCents, 5898.73, '(59, -1.27) = (1, 4) is (69, -101.27) = (10, 4) rewritten')

      for i, was in ipairs{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12 } do
        local bm, bd = tuning.stepToMidi(before, was, 4)
        local am, ad = tuning.stepToMidi(after, i, 4)
        t.truthy(math.abs((am * 100 + ad) - (bm * 100 + bd)) < 1e-9,
                 ('step %d sounds what step %d sounded'):format(i, was))
      end
    end,
  },

  {
    name = 'a step sorted below the root carries the root\'s index',
    run = function()
      local s = authored(A415)
      s.pitches[12] = '50.0'
      tuning.derive(tuning.sortSteps(s))

      t.eq(s.rootStep, 11, 'the retuned step sorted in below the root, pushing it up one')
      t.eq(s.rootCents, 5898.73, 'the root names the same step, so nothing else moves')
      soundsA415(s, 11, 'the rooted step still sounds A415')
    end,
  },

  {
    name = 'retuning the rooted step moves the scale, not the root',
    run = function()
      local s = authored(A415)
      s.pitches[10] = '905.0'
      tuning.derive(tuning.sortSteps(s))

      t.eq(s.rootStep, 10, 'the step kept its place in the order, so the root kept its index')
      soundsA415(s, 10, 'and A415 is still what that step sounds — that is what the root fixes')
      t.eq(s.rootCents, 5893.73, 'so the unison, 905c below it now, drops the 5 cents')

      local midi, detune = tuning.stepToMidi(s, 1, 4)
      t.eq(midi, 59)
      t.truthy(math.abs(detune + 6.27) < 1e-9, 'detune ' .. detune)
    end,
  },

  {
    name = 'a temper stating no root comes through both edits unstamped',
    run = function()
      local s = authored{}
      tuning.removeStep(s, 4)
      s.pitches[11] = '50.0'
      tuning.derive(tuning.sortSteps(s))

      t.eq(s.rootPitch, nil, 'no root was stated, so a step edit states none')
      t.eq(s.rootDetune, nil)
      t.eq(s.rootStep, nil)
      t.eq(s.rootOctave, nil)
    end,
  },

  {
    name = 'midiName spells a pitch in the untempered twelve names',
    run = function()
      t.eq(tuning.midiName(0), 'C-1', 'the bottom of the range is C of octave -1')
      t.eq(tuning.midiName(60), 'C4')
      t.eq(tuning.midiName(61), 'C#4', 'sharps, no natural marker')
      t.eq(tuning.midiName(127), 'G9')
    end,
  },

  {
    name = 'the default root reduces the conversions to MIDI-relative arithmetic',
    run = function()
      local twelve = tuning.presets['12EDO']
      local step, oct = tuning.midiToStep(twelve, 60, 0)
      t.eq(step, 1); t.eq(oct, 4, 'MIDI 60 is the unison of octave 4')
      local midi, detune = tuning.stepToMidi(twelve, 1, 4)
      t.eq(midi, 60); t.eq(detune, 0)

      local _, low = tuning.midiToStep(twelve, 0, 0)
      t.eq(low, -1, 'MIDI 0 is the unison of octave -1')

      local nineteen = tuning.presets['19EDO']
      midi, detune = tuning.stepToMidi(nineteen, 2, 4)
      t.eq(midi, 61)
      t.truthy(math.abs(detune - (1200 / 19 - 100)) < 1e-9, 'detune ' .. detune)
    end,
  },

  {
    name = 'stepWindow halves the distance to each neighbour, wrapping at both ends',
    run = function()
      local twelve = tuning.presets['12EDO']
      local down, up = tuning.stepWindow(twelve, 5)
      t.eq(down, 50); t.eq(up, 50, 'an interior step of an equal scale is symmetric')

      down, up = tuning.stepWindow(twelve, 1)
      t.eq(down, 50, 'step 1 finds its lower neighbour a period below the top step')
      t.eq(up, 50)

      down, up = tuning.stepWindow(twelve, 12)
      t.eq(down, 50)
      t.eq(up, 50, 'and the top step finds its upper neighbour a period above the unison')
    end,
  },

  {
    name = 'stepWindow under an unequal scale reports two different halves',
    run = function()
      -- QCM12's chromatic semitone (76.05c) is far narrower than the diatonic
      -- one that wraps the period (117.11c), so the unison's window is lopsided.
      local qcm = meantone12()
      local down, up = tuning.stepWindow(qcm, 1)
      t.truthy(math.abs(down - 58.554) < 1e-6, 'halfDown ' .. down)
      t.truthy(math.abs(up - 38.0244) < 1e-6, 'halfUp ' .. up)

      down, up = tuning.stepWindow(qcm, 12)
      t.truthy(math.abs(down - 38.0244) < 1e-6, 'halfDown ' .. down)
      t.truthy(math.abs(up - 58.554) < 1e-6, 'the same wrap seen from the other end, halfUp ' .. up)
    end,
  },

  {
    name = 'a flattened root moves every pitch by its offset and renames nothing',
    run = function()
      local base = rooted{}
      local flat = rooted{ rootDetune = -31.77 }
      t.truthy(math.abs(flat.rootCents + 31.77) < 1e-9, 'rootCents ' .. flat.rootCents)
      t.eq(flat.octaveBase, -1, 'the octave half of the root is untouched')

      for _, coord in ipairs{ { 1, 4 }, { 10, 4 }, { 12, 2 } } do
        local step, oct = coord[1], coord[2]
        local bm, bd = tuning.stepToMidi(base, step, oct)
        local fm, fd = tuning.stepToMidi(flat, step, oct)
        t.truthy(math.abs((fm * 100 + fd) - (bm * 100 + bd) + 31.77) < 1e-9,
                 ('step %d octave %d sounds %g cents lower'):format(step, oct,
                   (bm * 100 + bd) - (fm * 100 + fd)))
      end

      for midi = 0, 127 do
        local bs, bo = tuning.midiToStep(base, midi, 0)
        local fs, fo = tuning.midiToStep(flat, midi, 0)
        t.eq(fs, bs, 'step of MIDI ' .. midi)
        t.eq(fo, bo, 'octave of MIDI ' .. midi)
      end
    end,
  },

  {
    name = 'an octave-shifted root renames every octave and moves no pitch',
    run = function()
      local base    = rooted{}
      local shifted = rooted{ rootOctave = 3 }
      t.eq(shifted.rootCents, 0, 'the sounding half of the root is untouched')
      t.eq(shifted.octaveBase, 3)

      for midi = 0, 127 do
        local bs, bo = tuning.midiToStep(base, midi, 0)
        local ss, so = tuning.midiToStep(shifted, midi, 0)
        t.eq(ss, bs, 'step of MIDI ' .. midi)
        t.eq(so, bo + 4, 'octave of MIDI ' .. midi)
        local bm, bd = tuning.stepToMidi(base, bs, bo)
        local sm, sd = tuning.stepToMidi(shifted, ss, so)
        t.eq(sm, bm, 'pitch of MIDI ' .. midi); t.eq(sd, bd)
      end
    end,
  },

  {
    name = 'the conversions invert each other at every root',
    run = function()
      for _, temper in ipairs{ tuning.presets['12EDO'], tuning.presets['19EDO'],
                               rooted{ rootDetune = -31.77 }, rooted{ rootOctave = 3 },
                               rooted{ rootPitch = 69, rootStep = 10, rootOctave = 4 } } do
        for midi = 12, 115 do
          local step, oct = tuning.midiToStep(temper, midi, 0)
          local m, d      = tuning.stepToMidi(temper, step, oct)
          local step2, oct2 = tuning.midiToStep(temper, m, d)
          t.eq(step2, step, temper.name .. ' step at MIDI ' .. midi)
          t.eq(oct2, oct, temper.name .. ' octave at MIDI ' .. midi)
        end
      end
    end,
  },

  {
    name = 'EDO presets carry n\\m source tokens that derive back to their cents',
    run = function()
      local twelve = tuning.presets['12EDO']
      t.eq(twelve.pitches[8], '7\\12')
      t.eq(twelve.cents[8], 700, '7\\12 = 700 cents')
      t.eq(twelve.periodPitch, '2/1')
      t.eq(twelve.period, 1200)
    end,
  },

  {
    name = 'parseScalaFile strips comments, description and count; returns pitch tokens',
    run = function()
      local pitches, desc = tuning.parseScalaFile(
        '! meta.scl\n!\nMy scale\n 3\n!\n 9/8\n 5/4\n 2/1\n')
      t.eq(desc, 'My scale')
      t.eq(#pitches, 3)
      t.eq(pitches[1], '9/8')
      t.eq(pitches[3], '2/1')
    end,
  },

  {
    name = 'parseScalaPitches keeps every non-comment, non-blank line',
    run = function()
      local pitches = tuning.parseScalaPitches('9/8\n\n! note\n5/4\n2/1\n')
      t.eq(#pitches, 3)
      t.eq(pitches[2], '5/4')
    end,
  },

  {
    name = 'scalaToTemper prepends the unison, splits the period, flags periodAsStep',
    run = function()
      local s = tuning.scalaToTemper({ '9/8', '5/4', '2/1' }, 'maj3')
      t.eq(s.name, 'maj3')
      t.eq(s.periodPitch, '2/1')
      t.eq(s.period, 1200)
      t.eq(s.pitches[1], '1/1', 'unison prepended')
      t.eq(s.pitches[3], '5/4', 'last Scala pitch became the period, not a step')
      t.eq(#s.pitches, 3)
      t.eq(s.periodAsStep, true)
      t.eq(s.cents[1], 0)
    end,
  },

  {
    name = 'scalaToTemper sorts unordered pitches ascending; widest becomes the period',
    run = function()
      local s = tuning.scalaToTemper({ '3/2', '4/3', '5/4', '6/5', '7/6', '8/7' }, 'super')
      t.eq(s.periodPitch, '3/2', '3/2 (702c) is the widest interval -> period')
      t.eq(s.pitches[1], '1/1', 'unison prepended')
      t.eq(s.pitches[2], '8/7', 'smallest interval is the first body step')
      for i = 2, #s.cents do
        t.truthy(s.cents[i] > s.cents[i - 1], 'cents stay ascending')
      end
    end,
  },

  {
    name = 'scalaToTemper rejects an unparseable token',
    run = function()
      local s, err = tuning.scalaToTemper({ '9/8', 'oops', '2/1' }, 'x')
      t.eq(s, nil)
      t.eq(type(err), 'string')
    end,
  },

  {
    name = 'genEqual: full EDO and a diatonic subset, base implicit, period last',
    run = function()
      local full = tuning.genEqual(tuning.edoDegrees('1 1 1 1 1 1 1 1 1 1 1 1', 'relative'))
      t.eq(full.pitches[1], '0\\12', 'base 1/1 is the implicit degree 0')
      t.eq(full.pitches[12], '11\\12', 'twelve body steps, 0..11')
      t.eq(full.periodPitch, '12\\12', 'largest degree is the period')
      t.truthy(full.periodAsStep, 'EDO scales read with the equave as trailing row')

      local major = tuning.genEqual(tuning.edoDegrees('2 2 1 2 2 2 1', 'relative'))
      t.eq(#major.pitches, 7, 'base + 6 body degrees')
      t.eq(major.pitches[2], '2\\12')
      t.eq(major.periodPitch, '12\\12')
    end,
  },

  {
    name = 'edoDegrees: relative cumulates, absolute sorts; non-octave equave suffixes',
    run = function()
      t.eq(table.concat(tuning.edoDegrees('2 2 1', 'relative'), ' '), '2 4 5')
      t.eq(table.concat(tuning.edoDegrees('5 2 4', 'absolute'), ' '), '2 4 5', 'absolute sorts')
      t.eq(tuning.edoDegrees('0 1', 'relative'), nil, 'non-positive token rejected')

      local bp = tuning.genEqual(tuning.edoDegrees('1 1 1', 'relative'), '3/1')
      t.eq(bp.periodPitch, '3\\3<3/1>', 'interval ~= 2/1 carries the equave suffix')
    end,
  },

  {
    name = 'degreesToSpec round-trips edoDegrees in both modes',
    run = function()
      t.eq(tuning.degreesToSpec({ 2, 4, 5, 7, 9, 11, 12 }, 'relative'), '2 2 1 2 2 2 1')
      t.eq(tuning.degreesToSpec({ 2, 4, 5, 7, 9, 11, 12 }, 'absolute'), '2 4 5 7 9 11 12')
    end,
  },

  {
    name = 'genHarmonics / genSubharmonics: rooted on the low harmonic, top is period',
    run = function()
      local h = tuning.genHarmonics(4, 8)
      t.eq(table.concat(h.pitches, ' '), '4/4 5/4 6/4 7/4')
      t.eq(h.periodPitch, '8/4')

      local s = tuning.genSubharmonics(4, 8)
      t.eq(table.concat(s.pitches, ' '), '8/8 8/7 8/6 8/5', 'utonal, ascending')
      t.eq(s.periodPitch, '8/4')
    end,
  },

  {
    name = 'genChord: otonal vs inverted, last member is the period',
    run = function()
      local members = tuning.parseChord('4:5:6')
      t.eq(table.concat(members, ' '), '4 5 6')

      local oto = tuning.genChord(members, false)
      t.eq(table.concat(oto.pitches, ' '), '4/4 5/4', 'major triad: 1/1, 5/4')
      t.eq(oto.periodPitch, '6/4')

      local inv = tuning.genChord(members, true)
      t.eq(table.concat(inv.pitches, ' '), '6/6 6/5', 'minor triad: 1/1, 6/5')
      t.eq(inv.periodPitch, '6/4')
    end,
  },

  {
    name = 'parseChord rejects fewer than two notes or non-integers',
    run = function()
      t.eq((tuning.parseChord('4')), nil, 'one note is not a chord')
      t.eq((tuning.parseChord('4:5/2')), nil, 'ratios are not chord members')
    end,
  },

  {
    name = 'genCPS: hexany rooted on the smallest product, 1/1 first, ascending',
    run = function()
      local hex = tuning.genCPS({ 1, 3, 5, 7 }, 2, '2/1')
      t.eq(table.concat(hex.pitches, ' '), '1/1 7/6 5/4 35/24 5/3 7/4')
      t.eq(hex.periodPitch, '2/1')
      t.eq(#hex.pitches, 6, 'C(4,2) = 6 notes, rooted so 1/1 is present')
    end,
  },

  {
    name = 'genDiamond: the 9-diamond entire, and the counts either side of it',
    run = function()
      local nine = tuning.genDiamond(9)
      t.eq(table.concat(nine.pitches, ' '),
           '1/1 10/9 9/8 8/7 7/6 6/5 5/4 9/7 4/3 7/5 10/7 3/2 14/9 8/5 5/3 12/7 7/4 16/9 9/5')
      t.eq(nine.periodPitch, '2/1')
      t.truthy(nine.periodAsStep)
      t.eq(#tuning.genDiamond(11).pitches, 29, 'odd limit 11')
      t.eq(#tuning.genDiamond(15).pitches, 49, 'odd limit 15')
      t.eq(#tuning.genDiamond(21).pitches, 95, 'odd limit 21')
    end,
  },

  {
    name = 'genDiamond: the prime limit filters in place, and leaves a tritone hole',
    run = function()
      local d = tuning.genDiamond(15, 5)
      t.eq(table.concat(d.pitches, ' '),
           '1/1 16/15 10/9 9/8 6/5 5/4 4/3 3/2 8/5 5/3 16/9 9/5 15/8')
      t.eq(#d.pitches, 13, 'the 15-diamond less every point holding a prime above 5')
      local nearest = 1200
      for _, token in ipairs(d.pitches) do
        nearest = math.min(nearest, math.abs(tuning.scalaPitch(token) - 600))
      end
      t.truthy(nearest > 50, 'nothing within 50c of the tritone; nearest is ' .. nearest)
    end,
  },

  {
    name = 'genRank2: pure-fifth size 7 / up 5 is Pythagorean major, 1/1 first',
    run = function()
      local s = tuning.genRank2('3/2', '2/1', 7, 5)
      t.eq(table.concat(s.pitches, ' '), '1/1 9/8 81/64 4/3 3/2 27/16 243/128')
      t.eq(s.periodPitch, '2/1')
      t.truthy(s.periodAsStep)
    end,
  },

  {
    name = 'genRank2: size 4 / up 2 matches the Scale Workshop worked example',
    run = function()
      local s = tuning.genRank2('3/2', '2/1', 4, 2)
      t.eq(table.concat(s.pitches, ' '), '1/1 9/8 4/3 3/2')
      t.eq(s.periodPitch, '2/1')
    end,
  },

  {
    name = 'genRank2: irrational (EDO-step) generator emits cents tokens',
    run = function()
      local s = tuning.genRank2('7\\12', '2/1', 3, 2)
      t.eq(s.pitches[1], '1/1')
      for i = 2, #s.pitches do t.truthy(s.pitches[i]:find('%.'), 'cents token ' .. i) end
    end,
  },

  {
    name = 'nextMosSize / mosInfo: pure-fifth ladder 2->3->5->7->12; 7 is 5L 2s',
    run = function()
      t.eq(tuning.nextMosSize('3/2', '2/1', 2, 1), 3)
      t.eq(tuning.nextMosSize('3/2', '2/1', 3, 1), 5)
      t.eq(tuning.nextMosSize('3/2', '2/1', 5, 1), 7)
      t.eq(tuning.nextMosSize('3/2', '2/1', 7, 1), 12)
      t.eq(tuning.nextMosSize('3/2', '2/1', 7, -1), 5)
      local d = tuning.mosInfo('3/2', '2/1', 7)
      t.truthy(d.isMos, '7 notes is a MOS')
      t.eq(d.large, 5, 'five large steps')
      t.eq(d.small, 2, 'two small steps')
      t.eq(tuning.mosInfo('3/2', '2/1', 6).isMos, false, '6 notes is not a MOS')
    end,
  },

  {
    name = 'coords: the exponents of the odd primes, prime 2 divided out',
    run = function()
      t.deepEq(tuning.coords('1/1'), {}, 'the unison names no prime')
      t.deepEq(tuning.coords('15/8'), { [3] = 1, [5] = 1 }, '2^-3 . 3 . 5')
      t.deepEq(tuning.coords('4/3'), { [3] = -1 }, 'the fourth is the fifth inverted')
      t.deepEq(tuning.coords('9/8'), { [3] = 2 })
      t.deepEq(tuning.coords('7/4'), { [7] = 1 })
      t.deepEq(tuning.coords('45/32'), { [3] = 2, [5] = 1 })
      t.deepEq(tuning.coords('243/128'), { [3] = 5 })
      t.deepEq(tuning.coords('2'), {}, 'a bare integer is that integer over 1')
    end,
  },

  {
    name = 'coords: an unreduced token reads as the interval it states',
    run = function()
      t.deepEq(tuning.coords('6/4'), { [3] = 1 }, 'genHarmonics states its points over its root')
      t.deepEq(tuning.coords('4/4'), {})
      t.deepEq(tuning.coords('3/3'), {}, 'a prime on both sides cancels rather than sitting at 0')
    end,
  },

  {
    name = 'coords: a token that is not a ratio carries none',
    run = function()
      t.eq(tuning.coords('701.955'), nil, 'cents')
      t.eq(tuning.coords('7\\12'), nil, 'equal divisions')
      t.eq(tuning.coords('7\\12<3/1>'), nil, 'equal divisions of a stated equave')
      t.eq(tuning.coords('0/1'), nil, 'a zero term states no interval')
    end,
  },

  {
    name = 'isTarget: a temper whose every pitch factorises, and nothing else',
    run = function()
      t.eq(tuning.isTarget(tuning.genDiamond(9)), true, 'the diamond is ratios throughout')
      t.eq(tuning.isTarget(tuning.genCPS({ 1, 3, 5, 7 }, 2, '2/1')), true, 'so is the hexany')
      t.eq(tuning.isTarget(tuning.genRank2('3/2', '2/1', 7, 5)), true, 'a rational generator stacks to ratios')
      t.eq(tuning.isTarget(tuning.presets['12EDO']), false, 'EDO steps carry no coords')
      t.eq(tuning.isTarget(tuning.genRank2('7\\12', '2/1', 3, 2)), false, 'an irrational generator emits cents')
      t.eq(tuning.isTarget{ pitches = { '1/1', '5/4', '701.955' } }, false, 'one cents pitch is enough')
    end,
  },
}
