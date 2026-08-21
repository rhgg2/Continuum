-- Sweeps the walk's cap over a set of passages, which is what docs/sonority.md
-- § The solve leaves open: a passage that loses the answer at the cap the walk takes. Each row
-- states its settled cost against the cheapest any cap found, so a cap that loses the
-- answer shows as a positive difference; the checksum of the settled cents tells apart two
-- placements that cost alike. Run from the repo root:
--   lua tests/spikes/springs/cap_sweep.lua
--
-- At the beam the walk takes, every passage here answers alike from three abreast upward
-- but the five-part take over the septimal eleven, which wants five; at a beam of 48 that
-- take wants eight, the spellings the wider beam admits crowding the capped walk, so the
-- two dials are not independent. The eighty-eight-note take improves at twenty under both.
package.path = './?.lua;tests/spikes/springs/?.lua;' .. package.path

local sonority = require('sonority')
local tuning   = require('tuning')
local realTake = require('take')

local STRENGTH, STIFFNESS, ARITY = 1, 8, 5
local CAPS, WIDTHS = { 2, 3, 4, 5, 6, 8, 20 }, { 24, 48 }

local edo12 = tuning.presets['12EDO']
local withSevenths = tuning.moves{ pitches = { '1/1', '3/2', '5/4', '7/4', '9/8' } }

-- The two eleven-move sets: the ball of radius 15/8 over 3/2 and 5/4, which § Measured
-- states the five-part take's tunings over, and the septimal eleven the spec takes its
-- figures over. The septimal set admits more spellings, and is where a cap loses an answer
-- the other set holds at every cap.
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

-- What sonority.solveToMoves does, with the beam width and the cap handed in rather than
-- read off the module's own figures.
local function solveAt(passage, width, cap)
  local strands = passage.strands
  local seat = sonority.seats(strands, passage.notation or edo12)
  local onsets, spellings = sonority.onsets(strands, sonority.walk(strands, ARITY)), {}
  for i, onset in ipairs(onsets) do
    spellings[i] = sonority.spellings(onset.members, seat, onset.presence, onset.mayWait,
                                      passage.moves, width, STIFFNESS)
  end

  local answer = sonority.search(onsets, spellings, seat, STRENGTH, STIFFNESS, cap, 1)
  if not answer then return nil end

  local free = {}
  for index = 1, #strands do free[index] = index end
  local displacement = sonority.relax(sonority.ties(answer.springs, free), STRENGTH,
                                      STIFFNESS, answer.displacement, answer.rest, free)

  local checksum = 0
  for index = 1, #strands do checksum = checksum + seat[index] + displacement[index] end
  return answer.box
       + sonority.springCost(answer.springs, displacement, STIFFNESS, 1, #answer.springs)
       + sonority.pullCost(displacement, answer.rest, STRENGTH, free), checksum
end

for _, width in ipairs(WIDTHS) do
  print(string.format('beam %d', width))
  for _, passage in ipairs(passages) do
    local rows, cheapest = {}, math.huge
    for _, cap in ipairs(CAPS) do
      local at = os.clock()
      local cost, checksum = solveAt(passage, width, cap)
      rows[#rows + 1] = { cap = cap, took = os.clock() - at, cost = cost, checksum = checksum }
      if cost and cost < cheapest then cheapest = cost end
    end

    print('  ' .. passage.name)
    for _, row in ipairs(rows) do
      if row.cost then
        print(string.format('    cap %3d  %6.2fs  cost %11.4f  %+8.4f  checksum %.6f',
                            row.cap, row.took, row.cost, row.cost - cheapest, row.checksum))
      else
        print(string.format('    cap %3d  %6.2fs  refused', row.cap, row.took))
      end
    end
  end
  print()
end
