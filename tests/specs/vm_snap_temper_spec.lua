-- Notation snap: tv:snapToTemper{Selection,All} run every note in scope
-- through tuning.snap and write the pair back. The temper is a twelve-note
-- quarter-comma meantone MOS, so a step's seat carries a detune of its own
-- and the window is asymmetric (+38.0 / -58.6 either side of step 1).

local t      = require('support')
local tuning = require('tuning')

local MEAN = tuning.derive{
  name = 'MEAN', periodPitch = '2/1',
  pitches = { '0.0000', '76.0490', '193.1569', '310.2647', '386.3137', '503.4216',
              '579.4706', '696.5784', '772.6274', '889.7353', '1006.8431', '1082.8921' },
  stepNames = {},
}

local function mk(harness, notes)
  local h = harness.mk{
    seed   = { notes = notes },
    config = { project = { tempers = { MEAN = MEAN }, temper = 'MEAN' } },
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

return {
  {
    name = 'snapToTemperAll seats an off-step note on its own step',
    run = function(harness)
      local h = mk(harness, { note(0, 76, 0) })       -- E5 written at 12EDO
      h.vm:snapToTemperAll()
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
      h.vm:snapToTemperAll()
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
      h.vm:snapToTemperAll()
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
      h.vm:snapToTemperAll()
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
      h.vm:snapToTemperSelection()
      local _, d = seat(5, 5)
      near(cell(h, 0).detune, d,  'note inside the selection snapped')
      t.eq(cell(h, 10).detune, 0, 'note outside it untouched')
    end,
  },
}
