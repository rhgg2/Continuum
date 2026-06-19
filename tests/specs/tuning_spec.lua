-- Pins tuning.lua's pure display + derivation layer: the Option-B nameless
-- step labels and the derived octaveStep / cellWidth fields. Realisation
-- invariants (I1-I5) live in tm_tuning_spec; projection wiring in
-- view_context_spec.

local t      = require('support')
local tuning = require('tuning')

local function nameless(cents)
  return tuning.derive{ name = 'scale', period = 1200, cents = cents, stepNames = {} }
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
      t.eq(tuning.stepToText(tuning.presets['12EDO'], 1, 4), 'C-4')
      t.eq(tuning.stepToText(tuning.presets['31EDO'], 31, 3), 'C↓4',
        'octaveStep bump: step 31 reads as the next octave')
    end,
  },

  {
    name = 'nameless step falls back to degree-octave with a dash',
    run = function()
      local s = nameless{ 0, 400, 800 }
      t.eq(s.octaveStep, 4, 'no C-tail ⇒ bump sits past the last step')
      t.eq(s.cellWidth, 3, '1-digit degree + dash + octave')
      t.eq(tuning.stepToText(s, 1, 4), '1-4')
      t.eq(tuning.stepToText(s, 3, 4), '3-4')
      t.eq(tuning.stepToText(s, 1, -1), '1-M', 'octave -1 still renders as M')
    end,
  },

  {
    name = 'nameless scale past 9 steps widens the cell for 2-digit degrees',
    run = function()
      local cents = {}
      for i = 1, 12 do cents[i] = (i - 1) * 100 end
      local s = nameless(cents)
      t.eq(s.cellWidth, 4, '2-digit degree + dash + octave')
      t.eq(tuning.stepToText(s, 12, 4), '12-4')
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
      t.eq(tuning.stepToText(s, 1, 20), '1-20', 'two-digit octave renders in full')
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
      t.eq(tuning.stepToText(s, 1, 4), 'C4')
      t.eq(tuning.stepToText(s, 2, 4), '2-4', 'blank name ⇒ degree fallback')
      t.eq(tuning.stepToText(s, 3, 4), 'G4')
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
}
