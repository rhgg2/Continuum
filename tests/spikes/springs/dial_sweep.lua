-- Sweeps harmonic lock against purity, which is what docs/sonority.md § The dials settles.
-- cap_sweep.lua sweeps the search's own two figures at fixed dials; this one holds the beam
-- and the cap where § The solve leaves them and moves the dials an author sets. Each row
-- states what a listener would count: the pairs standing a comma or more from any 5-limit
-- landmark, the residual mistuning the springs were left holding, how far a step-class
-- wanders and how far the passage as a whole has gone. Run from the repo root:
--   lua tests/spikes/springs/dial_sweep.lua [passage] [locks] [purities]
-- with the passage one of the keys below and the two lists comma-separated.
--
-- WHAT IT SHOWED, at the beam of twenty-four, the cap of six and the ambient quarter the
-- modal opens on:
--
--   * Only the ratio moves a settled note. A lock of 1 with a purity of 8, a lock of 2 with
--     16 and a lock of 4 with 32 return the same cents to the last figure on every passage
--     here, which is what settling at a weighted mean of the two charges says. The scale the
--     pair stands at decides one thing: how much say the box has in the spelling.
--   * Below a purity of 16 a take chooses spellings it cannot realise. The eighty-eight-note
--     take at a lock of 1 is left holding 16.05c of residual mistuning at a purity of 8 with
--     32 springs over a cent, 1.28c and 4 at 16, and 0.71c and none at 32. A factor of twelve
--     across one doubling is a change of spelling and not the mechanical halving.
--   * A purity of 32 is the best cell measured. The two-hundred-and-fifty-eight-note take at
--     a lock of 1: 48 wolf pairs and 19.3c of mean class wander at a purity of 8, 55 and 14.9
--     at 16, 42 and 10.7 at 32, 49 and 22.2 at 64.
--   * A lock of zero leaves a passage unmoored. The five-part take drifts to +297c and the
--     eighty-eight-note take to +664c, which is a figure of the sweep order rather than of
--     the music. At 0.1 the page still fixes the answer, the eighty-eight-note take wandering
--     115c where a lock of 0.5 holds it to 21c. From 0.5 to 4 nothing measured moves: 42, 42,
--     41 and 44 wolf pairs on the big take at a purity of 32.
--   * The stiff end trades harmony for the page rather than doing nothing. At a lock of 10
--     against a purity of 32 the eighty-eight-note take's wolf pairs go 53 to 64 and its
--     springs stop being satisfied -- 3.34c worst, 28 of them over a cent.
--   * The beam of twenty-four serves the purity ceiling. At 128 and 256 the eighty-eight-note
--     take keeps its 53 wolf pairs and 21.4c of wander, the residual halving 0.19c to 0.10c.
package.path = './?.lua;tests/spikes/springs/?.lua;' .. package.path

local sonority = require('sonority')
local tuning   = require('tuning')

-- What § The solve settles and what the modal opens the ambient on; the two dials under test
-- are the sweep's own axes.
local ARITY, WIDTH, CAP, AMBIENT = 5, 24, 6, 0.25

local edo12 = tuning.presets['12EDO']
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

local fivePart = heldLines({
  { 72, 72, 71, 72, 74, 74, 72, 71, 69, 69, 71, 72, 74, 72, 71, 72 },
  { 67, 65, 65, 67, 67, 65, 64, 62, 62, 64, 65, 67, 65, 65, 62, 64 },
  { 64, 62, 62, 60, 59, 60, 57, 59, 57, 60, 60, 60, 57, 59, 55, 55 },
  { 55, 53, 55, 52, 50, 53, 52, 50, 53, 52, 48, 48, 50, 50, 47, 48 },
  { 48, 50, 43, 45, 43, 41, 45, 43, 45, 36, 41, 38, 36, 43, 43, 36 },
}, 960)

local realTake, bigTake = require('take'), require('take2')

local passages = {
  take88  = { name = 'the eighty-eight-note take', strands = realTake.strands,
              notation = realTake.notation, moves = realTake.target },
  take258 = { name = 'the two-hundred-and-fifty-eight-note take', strands = bigTake.strands,
              notation = bigTake.notation, moves = bigTake.target },
  five    = { name = 'the five-part take, over the ball of 15/8', strands = fivePart,
              notation = edo12, moves = fiveLimitBall },
  fiveSep = { name = 'the five-part take, over the septimal eleven', strands = fivePart,
              notation = edo12, moves = septimalEleven },
  pump    = { name = 'a comma pump I-vi-ii-V-I', notation = edo12, moves = septimalEleven,
              strands = progression{ { 60, 64, 67 }, { 57, 60, 64 }, { 62, 65, 69 },
                                     { 55, 59, 62 }, { 60, 64, 67 } } },
}

----- A solve, with the two figures solveToMoves keeps to itself opened up

local function solve(passage, lock, purity)
  local strands = passage.strands
  local seat = sonority.seats(strands, passage.notation)
  local onsets, lists = sonority.onsets(strands, sonority.walk(strands, ARITY)), {}
  for i, onset in ipairs(onsets) do
    lists[i] = sonority.spellings(onset.members, seat, onset.presence, onset.mayWait,
                                  passage.moves, WIDTH, purity)
  end
  local answer = sonority.search(onsets, lists, seat, lock, purity, CAP, AMBIENT)
  if not answer then return nil end

  local free = {}
  for i = 1, #strands do free[i] = i end
  local displacement = sonority.relax(sonority.ties(answer.springs, free), lock,
                                      purity, answer.displacement, answer.rest, free)
  local cost = answer.box
             + sonority.springCost(answer.springs, displacement, purity, 1, #answer.springs)
             + sonority.pullCost(displacement, answer.rest, lock, free)
  return { displacement = displacement, seat = seat, springs = answer.springs, cost = cost,
           rest = answer.rest, onsets = onsets, strands = strands }
end

----- What a listener would count (pairwise_box.lua's measures, off any passage)

-- The 5-limit intervals an ear locks onto, and how far out of one a pair has to stand to
-- count as a wolf.
local FAMILY = {
  [0] = 'unison/8ve', [1200] = 'unison/8ve',
  [701.96] = '5th/4th', [498.04] = '5th/4th',
  [386.31] = '3rd/6th', [315.64] = '3rd/6th', [813.69] = '3rd/6th', [884.36] = '3rd/6th',
  [203.91] = '2nd/7th', [111.73] = '2nd/7th', [996.09] = '2nd/7th',
  [1017.60] = '2nd/7th', [1088.27] = '2nd/7th',
  [590.22] = 'tritone', [609.78] = 'tritone',
}
local WOLF = 12

local landmarks = {}
for cents in pairs(FAMILY) do landmarks[#landmarks + 1] = cents end

local function nearest(gap)
  local octave, off, at = gap % 1200, math.huge, nil
  for _, cents in ipairs(landmarks) do
    local d = octave - cents
    if math.abs(d) < math.abs(off) then off, at = d, cents end
  end
  return math.abs(off), FAMILY[at]
end

-- Every pair of notes that sound together, and whether the interval they state is a comma or
-- more from the nearest landmark.
local function beating(answer)
  local tuned = {}
  for i, strand in ipairs(answer.strands) do
    for _, note in ipairs(strand.notes) do
      tuned[#tuned + 1] = { ppq = note.ppq, endppq = note.endppq,
                            cents = answer.seat[i] + answer.displacement[i]
                                  + (note.pitch - strand.notes[1].pitch) * 100 }
    end
  end
  local wolves, fifths, sounding, worst = 0, 0, 0, 0
  for a = 1, #tuned do
    for b = a + 1, #tuned do
      local x, y = tuned[a], tuned[b]
      if x.ppq < y.endppq and y.ppq < x.endppq then
        sounding = sounding + 1
        local off, family = nearest(y.cents - x.cents)
        if off > WOLF then
          wolves = wolves + 1
          if family == '5th/4th' then fifths = fifths + 1 end
        end
        worst = math.max(worst, off)
      end
    end
  end
  return wolves, fifths, sounding, worst
end

-- How far a step-class wanders across the passage: nothing in the objective ties one strand
-- of a class to the next, so this is the freedom the dials are spent on.
local function wandering(answer)
  local byClass = {}
  for i, strand in ipairs(answer.strands) do
    local list = byClass[strand.class] or {}
    byClass[strand.class] = list
    list[#list + 1] = answer.displacement[i]
  end
  local spread, classes, widest = 0, 0, 0
  for _, list in pairs(byClass) do
    if #list > 1 then
      local lo, hi = math.huge, -math.huge
      for _, cents in ipairs(list) do lo, hi = math.min(lo, cents), math.max(hi, cents) end
      spread, classes = spread + (hi - lo), classes + 1
      widest = math.max(widest, hi - lo)
    end
  end
  return classes > 0 and spread / classes or 0, widest
end

-- Where the passage as a whole has gone, onset by onset: the presence-weighted mean a strand
-- born there would rest on its share of.
local function drift(answer)
  local lowest, highest = math.huge, -math.huge
  for _, onset in ipairs(answer.onsets) do
    local total, weight = 0, 0
    for _, index in ipairs(onset.members) do
      total  = total + onset.presence[index] * answer.displacement[index]
      weight = weight + onset.presence[index]
    end
    local mean = total / weight
    lowest, highest = math.min(lowest, mean), math.max(highest, mean)
  end
  return lowest, highest
end

-- What the spellings asked for against what the displacements gave them.
local function impurity(answer)
  local worst, over = 0, 0
  for onset = 1, #answer.springs do
    for _, spring in ipairs(answer.springs[onset]) do
      local off = math.abs(answer.displacement[spring.j] - answer.displacement[spring.i]
                           - spring.delta)
      worst = math.max(worst, off)
      if off > 1 then over = over + 1 end
    end
  end
  return worst, over
end

-- How far a strand stands from its own seat, which is what the cell reports as a deviation.
local function offSeat(answer)
  local total, worst = 0, 0
  for i = 1, #answer.displacement do
    total = total + math.abs(answer.displacement[i])
    worst = math.max(worst, math.abs(answer.displacement[i]))
  end
  return total / #answer.displacement, worst
end

----- The sweep

local function numbers(text, fallback)
  if not text then return fallback end
  local list = {}
  for item in text:gmatch('[^,]+') do list[#list + 1] = tonumber(item) end
  return list
end

local passage  = passages[arg[1] or 'take88']
local LOCKS    = numbers(arg[2], { 0, 0.1, 0.25, 0.5, 1, 2, 4, 10 })
local PURITIES = numbers(arg[3], { 4, 8, 16, 32, 64, 128, 256 })

print(('%s  (%d strands, beam %d, cap %d, ambient %.2f)')
  :format(passage.name, #passage.strands, WIDTH, CAP, AMBIENT))
print('   lock purity     time    wolves/pairs  5ths   worst   impure  >1c    wander  widest' ..
      '   drift lo..hi     offseat  worst')
for _, lock in ipairs(LOCKS) do
  for _, purity in ipairs(PURITIES) do
    local at = os.clock()
    local answer = solve(passage, lock, purity)
    local took = os.clock() - at
    if not answer then
      print(('  %5.2f %6.1f %7.2fs   refused'):format(lock, purity, took))
    else
      local wolves, fifths, sounding, worstPair = beating(answer)
      local wander, widest = wandering(answer)
      local lo, hi = drift(answer)
      local impure, over = impurity(answer)
      local mean, worstSeat = offSeat(answer)
      print(('  %5.2f %6.1f %7.2fs %6d/%-6d %4d %7.1f %8.2f %4d %8.2f %7.2f %7.1f..%-7.1f %6.2f %6.2f')
        :format(lock, purity, took, wolves, sounding, fifths, worstPair, impure, over,
                wander, widest, lo, hi, mean, worstSeat))
    end
    io.stdout:flush()
  end
end
