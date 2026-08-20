-- What a pairwise box does to a solve, kept because the objective it replaces is the one
-- design/sounding-anchor.md is about to change underneath. Run from the repo root:
--   lua tests/spikes/springs/pairwise_box.lua
--
-- The span box charges a sonority what its coords span on each axis, so a pair sits free
-- anywhere inside room another member has already opened: a wolf fifth between two members
-- costs nothing where a third member has already widened the 3-axis past it. The pairwise
-- box charges every pair the height of the interval it states, which prices what the span
-- lets through.
--
-- Both boxes are carried here rather than read off the module, so the spike says the same
-- thing whichever one production holds.
--
-- WHAT IT SHOWED, on take2's two hundred and fifty-eight notes at matched dials:
--
--   * The pairwise box is not a trade of fifths for thirds. Of 440 sounding pairs a comma
--     or more from any 5-limit interval: fifths and fourths 25 -> 3, thirds and sixths
--     37 -> 29, seconds and sevenths 10 -> 8, tritones 0 -> 1, total 72 -> 41.
--   * What it costs is melodic. A step-class wanders twice as far across the take, mean
--     spread 9.9c -> 18.8c and the widest 21.8c -> 38.7c. Nothing in the objective holds a
--     class to its own past, and the pairwise box has a strong enough opinion per chord to
--     spend that freedom.
--   * The box is three to five times the number it was, so both dials move under it. The
--     C7's trade turns over at a lock of 2.84 where it turned at 0.95, and purity buys less
--     per notch: at 8 the take carries 265 springs over a cent and one 13.4c out, and it
--     takes 64 to clear them where the span box is clear at 32. Lock 3 and purity 32 leave
--     the take about as impure as the span box at 1 and 8 left it, 3.07c against 3.26c, so
--     the dials restore the purity. The wandering they do not restore.
--   * A cap of 4 loses an answer here: 2808.32 against 2806.21 at a cap of 8. Measured in
--     the session that found it, that difference is the E flat triad at row 16 spelled with
--     a Pythagorean third 21c wide against a pure one. A cap of 16 costs more again
--     (2809.91), so the cut is not monotone in the cap and no value is safe on principle.
--
-- WHAT IT LEFT OPEN: whether any of this survives design/sounding-anchor.md phase 2. The
-- wandering is what phase 4's ambient rest is for, and the two dial figures are phase 5's
-- to re-measure with the reach gate gone.
package.path = './?.lua;tests/spikes/springs/?.lua;' .. package.path

local sonority = require('sonority')
local tuning   = require('tuning')
local take     = require('take2')

local ARITY, WIDTH = 5, 24

----- The two boxes

-- What HEAD charges: the coords' span on each axis, weighted by log2 p, which is the
-- Tenney height of the sonority's octave-free lcm/gcd reached without forming either.
local function spanScore(coordSet)
  local spans = {}
  for _, coords in ipairs(coordSet) do
    for prime in pairs(coords) do spans[prime] = 0 end
  end
  for prime in pairs(spans) do
    local high, low = coordSet[1][prime] or 0, coordSet[1][prime] or 0
    for i = 2, #coordSet do
      local exponent = coordSet[i][prime] or 0
      if exponent > high then high = exponent end
      if exponent < low  then low  = exponent end
    end
    spans[prime] = high - low
  end
  return tuning.height(spans)
end

-- What the spike charges: every pair the height of the interval between its two members.
local function pairwiseScore(coordSet)
  local total = 0
  for a = 1, #coordSet do
    for b = a + 1, #coordSet do
      local interval = {}
      for prime, exponent in pairs(coordSet[b]) do interval[prime] = exponent end
      for prime, exponent in pairs(coordSet[a]) do
        local net = (interval[prime] or 0) - exponent
        interval[prime] = net ~= 0 and net or nil
      end
      total = total + tuning.height(interval)
    end
  end
  return total
end

-- The module is asked for its box by name at every site that charges one, so swapping the
-- field swaps the objective whole.
local function under(score, fn)
  local held = sonority.score
  sonority.score = score
  local ok, result = pcall(fn)
  sonority.score = held
  if not ok then error(result, 0) end
  return result
end

----- A solve, with the two figures solveToMoves keeps to itself opened up

local function solve(lock, purity, cap)
  local strands = take.strands
  local seat = sonority.seats(strands, take.notation)
  local onsets, lists = sonority.onsets(strands, sonority.walk(strands, ARITY)), {}
  for i, onset in ipairs(onsets) do
    lists[i] = sonority.spellings(onset.members, seat, onset.mayWait, take.target,
                                  WIDTH, purity)
  end
  local answer = sonority.search(onsets, lists, seat, lock, purity, cap)
  if not answer then return nil end

  local free = {}
  for i = 1, #strands do free[i] = i end
  local displacement = sonority.relax(sonority.ties(answer.springs, free), lock,
                                      purity, answer.displacement, free)
  local cost = answer.box
             + sonority.springCost(answer.springs, displacement, purity, 1, #answer.springs)
             + sonority.pullCost(displacement, lock, free)
  return { displacement = displacement, seat = seat, springs = answer.springs, cost = cost }
end

----- What a listener would count

-- The 5-limit intervals an ear locks onto. The target also names 27/20 and 40/27, the
-- comma-shifted fourth and fifth, which are the beating this measures rather than a place
-- to measure from.
local FAMILY = {
  [0] = 'unison/8ve', [1200] = 'unison/8ve',
  [701.96] = '5th/4th', [498.04] = '5th/4th',
  [386.31] = '3rd/6th', [315.64] = '3rd/6th', [813.69] = '3rd/6th', [884.36] = '3rd/6th',
  [203.91] = '2nd/7th', [111.73] = '2nd/7th', [996.09] = '2nd/7th',
  [1017.60] = '2nd/7th', [1088.27] = '2nd/7th',
  [590.22] = 'tritone', [609.78] = 'tritone',
}
local ORDER = { 'unison/8ve', '5th/4th', '3rd/6th', '2nd/7th', 'tritone' }
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

local WOLF = 12

-- Every pair of notes that sound together, counted by family and by whether the interval
-- they state is a comma or more from the nearest landmark.
local function beating(answer)
  local tuned = {}
  for i, strand in ipairs(take.strands) do
    for _, note in ipairs(strand.notes) do
      tuned[#tuned + 1] = { ppq = note.ppq, endppq = note.endppq,
                            cents = answer.seat[i] + answer.displacement[i]
                                  + (note.pitch - strand.notes[1].pitch) * 100 }
    end
  end
  local wolves, pairs_ = {}, {}
  for _, family in ipairs(ORDER) do wolves[family], pairs_[family] = 0, 0 end
  local total, sounding, worst = 0, 0, { off = 0 }
  for a = 1, #tuned do
    for b = a + 1, #tuned do
      local x, y = tuned[a], tuned[b]
      if x.ppq < y.endppq and y.ppq < x.endppq then
        sounding = sounding + 1
        local off, family = nearest(y.cents - x.cents)
        pairs_[family] = pairs_[family] + 1
        if off > WOLF then
          wolves[family], total = wolves[family] + 1, total + 1
        end
        if off > worst.off then
          worst = { off = off, family = family,
                    from = math.max(x.ppq, y.ppq), to = math.min(x.endppq, y.endppq) }
        end
      end
    end
  end
  return wolves, pairs_, total, sounding, worst
end

-- How far a step-class wanders across the take: nothing in the objective ties one strand
-- of a class to the next, so this is the freedom the box's opinion is spent on.
local NAMES = { [0] = 'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B' }

-- Keyed by the class the strands carry, but named off a note that writes it: what
-- tuning.stepClass counts from is the notation's business, not this report's.
local function wandering(answer)
  local byClass = {}
  for i, strand in ipairs(take.strands) do
    local list = byClass[strand.class]
    if not list then
      list = { pitch = strand.notes[1].pitch }
      byClass[strand.class] = list
    end
    table.insert(list, answer.displacement[i])
  end
  local spread, classes, widest, at = 0, 0, 0, nil
  for _, list in pairs(byClass) do
    if #list > 1 then
      local lo, hi = math.huge, -math.huge
      for _, cents in ipairs(list) do lo, hi = math.min(lo, cents), math.max(hi, cents) end
      spread, classes = spread + (hi - lo), classes + 1
      if hi - lo > widest then widest, at = hi - lo, list.pitch end
    end
  end
  return spread / classes, widest, at and NAMES[at % 12] or '?'
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

----- The C7 the dials are calibrated on (docs/sonority.md § The dials)

local function strainOf(num, den, step)
  return math.abs(1200 * math.log(num / den, 2) - step) / 50
end
local DIAMOND = {
  { 0,  60,    0, { { {}, 1, 1, 0 } } },
  { 4,  64,  400, { { { [5] = 1 }, 5, 4, 400 }, { { [3] = 2, [7] = -1 }, 9, 7, 400 } } },
  { 7,  67,  700, { { { [3] = 1 }, 3, 2, 700 } } },
  { 10, 70, 1000, { { { [7] = 1 }, 7, 4, 1000 }, { { [3] = -2 }, 16, 9, 1000 },
                    { { [3] = 2, [5] = -1 }, 9, 5, 1000 } } },
}
local function c7()
  local strands = {}
  for k, entry in ipairs(DIAMOND) do
    local shortlist = {}
    for i, point in ipairs(entry[4]) do
      shortlist[i] = { coords = point[1], strain = strainOf(point[2], point[3], point[4]) }
    end
    strands[k] = { class = entry[1], shortlist = shortlist,
                   notes = { { ppq = 0, pitch = entry[2], endppq = 960 } } }
  end
  return strands
end

-- Where the seventh gives up the otonal 7/4 for the Pythagorean 16/9 as the pull rises.
local function crossing()
  local strands, lo, hi = c7(), 0, 60
  if sonority.solveToPoints(strands, ARITY, lo)[4]
     == sonority.solveToPoints(strands, ARITY, hi)[4] then return nil end
  for _ = 1, 44 do
    local mid = (lo + hi) / 2
    if sonority.solveToPoints(strands, ARITY, mid)[4] == 1 then lo = mid else hi = mid end
  end
  return (lo + hi) / 2
end

----- The report

-- The take is written on a grid of 1024 ticks, so a row is what an author would point at.
local ROW = 1024

local function beatingTable(label, answer)
  local wolves, pairs_, total, sounding, worst = beating(answer)
  print(('\n%s -- %d sounding pairs'):format(label, sounding))
  print('  family        pairs   a comma or more out')
  for _, family in ipairs(ORDER) do
    print(('  %-12s %5d   %4d'):format(family, pairs_[family], wolves[family]))
  end
  print(('  %-12s %5d   %4d'):format('TOTAL', sounding, total))
  print(('  worst: a %s %.1fc out, rows %.1f-%.1f'):format(
    worst.family, worst.off, worst.from / ROW, worst.to / ROW))
  local mean, widest, class = wandering(answer)
  local impure, over = impurity(answer)
  print(('  wandering: mean %.2fc, widest %.2fc on the %s;  impurity: worst %.2fc, %d springs over 1c')
    :format(mean, widest, class, impure, over))
  print(('  settled cost %.4f'):format(answer.cost))
end

print('==== the two boxes at the dials each was calibrated for')
under(spanScore,     function() beatingTable('span, lock 1 purity 8',      solve(1, 8, 4)) end)
under(pairwiseScore, function() beatingTable('pairwise, lock 3 purity 32', solve(3, 32, 8)) end)

print('\n==== matched dials, so the box is the only difference')
under(spanScore,     function() beatingTable('span, lock 3 purity 32',     solve(3, 32, 8)) end)

print('\n==== where each box puts the C7 trade')
for _, entry in ipairs{ { 'span', spanScore }, { 'pairwise', pairwiseScore } } do
  local at = under(entry[2], crossing)
  print(('  %-9s crossing at %s'):format(entry[1], at and ('%.4f'):format(at) or 'none'))
end

print('\n==== the purity cliff under the pairwise box (lock 3, cap 8)')
under(pairwiseScore, function()
  for _, purity in ipairs{ 8, 16, 32, 64 } do
    local answer = solve(3, purity, 8)
    local worst, over = impurity(answer)
    local _, total = beating(answer)
    print(('  purity %3d  impurity worst %6.2fc  springs over 1c %3d'):format(
      purity, worst, over))
  end
end)

print('\n==== the walk cap on this take (pairwise, lock 3, purity 32)')
under(pairwiseScore, function()
  for _, cap in ipairs{ 4, 8, 16 } do
    local answer = solve(3, 32, cap)
    local mean = select(1, wandering(answer))
    print(('  cap %2d  cost %9.4f  wandering %.2fc'):format(cap, answer.cost, mean))
  end
end)
