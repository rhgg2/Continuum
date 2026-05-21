-- Pins tv:scaleSelection's length guard: a scale that would push any
-- note onset off the end of the take is silently refused. Tails are out
-- of scope (tm's universal tail pass clips realised against length).

local t = require('support')

return {
  {
    name = 'scaleSelection 2× refuses when any onset would exceed length',
    run = function(harness)
      -- length=3840, PPR=60, 64 rows. Anchor row 0, note at row 40 (ppq 2400).
      -- 2× from anchor 0 → newppq 4800, past length 3840 → refuse.
      local h = harness.mk{ seed = { notes = {
        { ppq = 0,    endppq = 60,   chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
        { ppq = 2400, endppq = 2460, chan = 1, pitch = 64, vel = 100, detune = 0, delay = 0 },
      } } }
      h.ec:setSelection{ row1 = 0, row2 = 40, col1 = 1, col2 = 1,
                         part1 = 'pitch', part2 = 'pitch' }
      h.vm:scaleSelection(2, 1)

      local notes = h.fm:dump().notes
      table.sort(notes, function(a, b) return a.ppq < b.ppq end)
      t.eq(#notes,         2,    'no notes deleted')
      t.eq(notes[1].ppq,   0,    'anchor note untouched')
      t.eq(notes[2].ppq,   2400, 'off-grid candidate untouched')
      t.eq(notes[2].endppq, 2460, 'off-grid candidate tail untouched')
    end,
  },

  {
    name = 'scaleSelection 2× commits when every onset stays inside length',
    run = function(harness)
      -- Anchor 0, note at row 10 (ppq 600). 2× → newppq 1200, well inside length.
      local h = harness.mk{ seed = { notes = {
        { ppq = 0,   endppq = 60,  chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
        { ppq = 600, endppq = 660, chan = 1, pitch = 64, vel = 100, detune = 0, delay = 0 },
      } } }
      h.ec:setSelection{ row1 = 0, row2 = 10, col1 = 1, col2 = 1,
                         part1 = 'pitch', part2 = 'pitch' }
      h.vm:scaleSelection(2, 1)

      local notes = h.fm:dump().notes
      table.sort(notes, function(a, b) return a.ppq < b.ppq end)
      t.eq(notes[2].ppq,    1200, 'scaled note onset doubled from anchor')
      t.eq(notes[2].endppq, 1320, 'scaled note tail doubled in duration')
    end,
  },
}
