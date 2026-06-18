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
}
