-- Sweeps the beam's width against the walk's cap over a set of passages, at one purity after
-- another, which is what docs/sonority.md § The solve settles. Each row states what the dials
-- settle at, the widest wander of any step-class across the passage and how flat the passage
-- sits, so a setting buying a cheaper answer by letting the music drift shows as a lower cost
-- beside a wider spread. Run from the repo root, and allow a quarter of an hour:
--   lua tests/spikes/springs/cap_sweep.lua
--
-- Purity is swept because the width answers to it: the eighty-eight-note take takes all it
-- gains by a beam of twelve at a purity of 8 and only by twenty-four at 32, a stiffer spring
-- separating spellings further down the beam's ranking. Five answers abreast is what any
-- passage here asks for at any purity. Past that pair the dials pay in drift -- at a purity
-- of 64 a beam of forty-eight is 0.6 per cent cheaper with a step-class wandering 111 cents
-- where twenty-four holds it to 41.
package.path = './?.lua;tests/spikes/springs/?.lua;' .. package.path

local sonority = require('sonority')
local tuning   = require('tuning')
local realTake = require('take')
local bigTake  = require('take2')

-- The dials the retune modal opens on, ambient included: a sweep taken at a full ambient
-- share measures an instrument no author starts from, and drifts further at every width.
local STRENGTH, ARITY, AMBIENT = 1, 5, 0.25
local CAPS, WIDTHS = { 3, 4, 6, 8 }, { 8, 12, 16, 24, 48 }
local PURITIES = { 8, 16, 32, 64 }

local edo12 = tuning.presets['12EDO']
local withSevenths = tuning.moves{ pitches = { '1/1', '3/2', '5/4', '7/4', '9/8' } }

-- The two eleven-move sets: the ball of radius 15/8 over 3/2 and 5/4, which § Measured
-- states the five-part take's tunings over, and the septimal eleven the spec takes its
-- figures over.
local fiveLimitBall  = tuning.moves{ pitches = { '1/1', '16/15', '9/8', '6/5', '5/4', '4/3',
                                                 '3/2', '8/5', '5/3', '16/9', '15/8' } }
local septimalEleven = tuning.moves{ pitches = { '1/1', '3/2', '5/4', '6/5', '7/4', '7/6',
                                                 '7/5', '9/8', '5/3', '8/7', '10/7' } }

----- The passages

local function event(ppq, pitch, endppq)
  return { ppq = ppq, pitch = pitch, endppq = endppq }
end

local function pitchClass(note) return note.pitch % 12 end

-- A chord to the bar, each released where the next strikes.
local function progression(bars)
  local notes = {}
  for beat, pitches in ipairs(bars) do
    for _, pitch in ipairs(pitches) do
      notes[#notes + 1] = event((beat - 1) * 960, pitch, beat * 960)
    end
  end
  return sonority.strands(notes, pitchClass)
end

-- A chord rolled note by note, every note held to the end of the bar.
local function rolled(bars, apart)
  local notes = {}
  for beat, pitches in ipairs(bars) do
    for k, pitch in ipairs(pitches) do
      notes[#notes + 1] = event((beat - 1) * 960 + (k - 1) * apart, pitch, beat * 960)
    end
  end
  return sonority.strands(notes, pitchClass)
end

-- Voice lines a beat apart, a repeated pitch held rather than struck again.
local function heldLines(lines, beat)
  local notes = {}
  for _, line in ipairs(lines) do
    local i = 1
    while i <= #line do
      local j = i
      while j < #line and line[j + 1] == line[i] do j = j + 1 end
      notes[#notes + 1] = event((i - 1) * beat, line[i], j * beat)
      i = j + 1
    end
  end
  return sonority.strands(notes, pitchClass)
end

-- Voices entering one after another and each held to the end, so no debt settles.
local function arpeggio(pitches, apart)
  local notes, last = {}, #pitches * apart
  for k, pitch in ipairs(pitches) do notes[k] = event((k - 1) * apart, pitch, last) end
  return sonority.strands(notes, pitchClass)
end

local fivePart = heldLines({
  { 72, 72, 71, 72, 74, 74, 72, 71, 69, 69, 71, 72, 74, 72, 71, 72 },
  { 67, 65, 65, 67, 67, 65, 64, 62, 62, 64, 65, 67, 65, 65, 62, 64 },
  { 64, 62, 62, 60, 59, 60, 57, 59, 57, 60, 60, 60, 57, 59, 55, 55 },
  { 55, 53, 55, 52, 50, 53, 52, 50, 53, 52, 48, 48, 50, 50, 47, 48 },
  { 48, 50, 43, 45, 43, 41, 45, 43, 45, 36, 41, 38, 36, 43, 43, 36 },
}, 960)

local passages = {
  { name = 'the eighty-eight-note take', strands = realTake.strands,
    notation = realTake.notation, moves = realTake.target },

  { name = 'the two-hundred-and-fifty-eight-note take', strands = bigTake.strands,
    notation = bigTake.notation, moves = bigTake.target },

  { name = 'the five-part take, over the ball of 15/8', strands = fivePart,
    moves = fiveLimitBall },

  { name = 'the five-part take, over the septimal eleven', strands = fivePart,
    moves = septimalEleven },

  { name = 'a ii-V-I of sevenths, struck', moves = withSevenths,
    strands = progression{ { 62, 65, 69, 72 }, { 55, 59, 62, 65 }, { 60, 64, 67, 71 } } },

  { name = 'a ii-V-I of sevenths, rolled', moves = withSevenths,
    strands = rolled({ { 62, 65, 69, 72 }, { 55, 59, 62, 65 }, { 60, 64, 67, 71 } }, 120) },

  { name = 'a comma pump I-vi-ii-V-I', moves = septimalEleven,
    strands = progression{ { 60, 64, 67 }, { 57, 60, 64 }, { 62, 65, 69 },
                           { 55, 59, 62 }, { 60, 64, 67 } } },

  { name = 'five detached triads', moves = septimalEleven,
    strands = progression{ { 60, 64, 67 }, { 62, 65, 69 }, { 64, 67, 71 },
                           { 65, 69, 72 }, { 67, 71, 74 } } },

  { name = 'a rolled minor triad', moves = septimalEleven,
    strands = rolled({ { 60, 63, 67 } }, 240) },

  { name = 'an overlapping arpeggio of four voices', moves = septimalEleven,
    strands = arpeggio({ 60, 64, 67, 70 }, 240) },
}

----- The sweep

-- What sonority.solveToMoves does, with the beam width, the cap and the purity handed in
-- rather than read off the module's own figures and the modal's.
local function solveAt(passage, width, cap, stiffness)
  local strands = passage.strands
  local seat = sonority.seats(strands, passage.notation or edo12)
  local onsets, spellings = sonority.onsets(strands, sonority.walk(strands, ARITY)), {}
  for i, onset in ipairs(onsets) do
    spellings[i] = sonority.spellings(onset.members, seat, onset.presence, onset.mayWait,
                                      passage.moves, width, stiffness)
  end

  local answer = sonority.search(onsets, spellings, seat, STRENGTH, stiffness, cap, AMBIENT)
  if not answer then return nil end

  local free = {}
  for index = 1, #strands do free[index] = index end
  local displacement = sonority.relax(sonority.ties(answer.springs, free), STRENGTH,
                                      stiffness, answer.displacement, answer.rest, free)

  return answer.box
       + sonority.springCost(answer.springs, displacement, stiffness, 1, #answer.springs)
       + sonority.pullCost(displacement, answer.rest, STRENGTH, free), displacement
end

-- The widest wander of any step-class across the passage, and how flat the passage sits.
local function drift(passage, displacement)
  local low, high, total = {}, {}, 0
  for index, strand in ipairs(passage.strands) do
    local class, at = strand.class, displacement[index]
    total = total + at
    if not low[class]  or at < low[class]  then low[class]  = at end
    if not high[class] or at > high[class] then high[class] = at end
  end

  local widest = 0
  for class, bottom in pairs(low) do
    if high[class] - bottom > widest then widest = high[class] - bottom end
  end
  return widest, total / #displacement
end

for _, passage in ipairs(passages) do
  for _, stiffness in ipairs(PURITIES) do
    local rows, cheapest = {}, math.huge
    for _, width in ipairs(WIDTHS) do
      for _, cap in ipairs(CAPS) do
        local at = os.clock()
        local cost, displacement = solveAt(passage, width, cap, stiffness)
        rows[#rows + 1] = { width = width, cap = cap, took = os.clock() - at, cost = cost,
                            displacement = displacement }
        if cost and cost < cheapest then cheapest = cost end
      end
    end

    print(string.format('%s  (%d strands, purity %d)', passage.name, #passage.strands,
                        stiffness))
    print('   beam  cap     time         cost      dcost   spread   flat')
    for _, row in ipairs(rows) do
      if row.cost then
        local spread, flat = drift(passage, row.displacement)
        print(string.format('  %5d %4d %7.2fs %12.4f %+9.4f %8.2f %6.2f',
                            row.width, row.cap, row.took, row.cost, row.cost - cheapest,
                            spread, flat))
      else
        print(string.format('  %5d %4d %7.2fs   refused', row.width, row.cap, row.took))
      end
    end
    print()
  end
end
