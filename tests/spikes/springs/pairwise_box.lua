-- Whether the box should charge pairs rather than spans (docs/sonority.md § The box).
-- Run from the repo root:
--   lua tests/spikes/springs/pairwise_box.lua
--
-- The span box charges a sonority what its coords span on each axis, so a pair sits free
-- anywhere inside room another member has already opened: a wolf fifth between two members
-- costs nothing where a third member has already widened the 3-axis past it. The rival
-- charges every pair the height of the interval it states. Both are carried here rather than
-- read off the module, so the spike says the same thing whichever one production holds.
--
-- WHAT IT SHOWED, on take2's two hundred and fifty-eight notes, each box at the dials its
-- own magnitude names -- the C7 crossing setting the lock, the purity riding with it:
--
--   * The count barely separates them. Of 440 sounding pairs a comma or more from any
--     5-limit interval: span 37, and 39 under every pair-height norm. The pairwise boxes
--     trade fifths for thirds, 6 -> 3 against 24 -> 28. A five per cent change of lock moves
--     the total by three, so nothing here is outside the noise.
--   * The norm's shape does nothing. q=1 and q=2 return the same spellings and the same
--     displacements to the last figure, differing only in the box's scale, which the dials
--     absorb; q=inf, charging the widest pair alone, parts from them and lands on the same
--     count. Between summing the pairs and taking the worst there is no choice to make.
--   * What separates them is drift, and that is what an ear hears. A step-class wanders
--     26.7c across the take under the span box and the passage's centre keeps to -23c..+6c;
--     under q=inf, 42.5c and -44c..+6c; under q=1, 60.6c and -64c..+7c. Charging pairs
--     loosens what holds a spelling together, and the passage walks off the page.
--   * The C7's trade is stated by every box, which is what makes the crossing a magnitude
--     match: 0.9476 under the span box and under q=inf, 2.8428 under q=1.
--
-- WHAT WAS SHOWN UNDER A PATCHED TREE, and cannot be re-run here as it stands:
--
--   * Weighting each pair by the product of its two members' presence, as a spring is
--     weighted, improves every pairwise box: q=1 goes 39 -> 36 and its wandering 60.6c ->
--     35.9c, q=inf goes 39 -> 34 with its wolf fifths 3 -> 0. It wants sonority.score to
--     read a presence per member, which the three sites that charge a box already hold.
--     The weighted widest-pair box was the best of the family on the count, was put in the
--     tree and listened to, and was rejected: a max has no opinion about anything but the
--     worst pair, so a spelling walks its members apart as far as the worst already reaches,
--     and a member held by recency is spelled remotely for a quarter of the price. The top
--     line pulls sharp and drags the rest after it.
--   * The ambient sweep that came out of that listening, under the span box at lock 1 and
--     purity 32, a strand inheriting a share of the sonority it was born into rather than
--     all of it -- wolf pairs, then how far a class wanders: 0 -> 66, 10.3c;  0.25 -> 42,
--     10.7c;  0.5 -> 44, 10.6c;  0.75 -> 39, 25.2c;  1 -> 40, 26.6c. The knee is at a
--     quarter, and it is the evidence for the ambient dial.
--
-- WHAT IT LEFT OPEN: the beam of twenty-four and the cap of six everything was taken at
-- are phase 6's to re-sweep, and the purity is set at the floor where this take's springs
-- come out under a cent rather than at anything an author would choose.
package.path = './?.lua;tests/spikes/springs/?.lua;' .. package.path

local sonority = require('sonority')
local tuning   = require('tuning')
local take     = require('take2')

local ARITY, WIDTH, CAP = 5, 24, 6

----- The boxes

-- What production charges: the coords' span on each axis, weighted by log2 p, which is the
-- Tenney height of the sonority's octave-free lcm/gcd reached without forming either. It is
-- carried here rather than read off the module, so the spike says the same thing whichever
-- box production holds.
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

-- The rival family: every pair states an interval, and the pair heights are gathered into
-- one charge by a q-norm. At q = 1 each pair pays its whole height, which is the pairwise
-- box the design proposed; as q rises the widest pair takes the charge over, which is what
-- a span charges -- room one pair has opened standing free to the rest.
local function normBox(q)
  return function(coordSet)
    local total = 0
    for a = 1, #coordSet do
      for b = a + 1, #coordSet do
        local interval = {}
        for prime, exponent in pairs(coordSet[b]) do interval[prime] = exponent end
        for prime, exponent in pairs(coordSet[a]) do
          local net = (interval[prime] or 0) - exponent
          interval[prime] = net ~= 0 and net or nil
        end
        local height = tuning.height(interval)
        if q == math.huge then
          if height > total then total = height end
        else
          total = total + height ^ q
        end
      end
    end
    return q == math.huge and total or total ^ (1 / q)
  end
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
    lists[i] = sonority.spellings(onset.members, seat, onset.presence, onset.mayWait, take.target,
                                  WIDTH, purity)
  end
  local answer = sonority.search(onsets, lists, seat, lock, purity, cap, 1)
  if not answer then return nil end

  local free = {}
  for i = 1, #strands do free[i] = i end
  local displacement = sonority.relax(sonority.ties(answer.springs, free), lock,
                                      purity, answer.displacement, answer.rest, free)
  local cost = answer.box
             + sonority.springCost(answer.springs, displacement, purity, 1, #answer.springs)
             + sonority.pullCost(displacement, answer.rest, lock, free)
  return { displacement = displacement, seat = seat, springs = answer.springs, cost = cost,
           rest = answer.rest, onsets = onsets }
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

-- The same spread taken against each strand's rest, so a passage's drift is out of it: what
-- is left is how far a class stands from the music it was born into, chord by chord.
local function wanderingFromRest(answer)
  local byClass = {}
  for i, strand in ipairs(take.strands) do
    local list = byClass[strand.class] or {}
    byClass[strand.class] = list
    table.insert(list, answer.displacement[i] - answer.rest[i])
  end
  local spread, classes, widest = 0, 0, 0
  for _, list in pairs(byClass) do
    if #list > 1 then
      local lo, hi = math.huge, -math.huge
      for _, cents in ipairs(list) do lo, hi = math.min(lo, cents), math.max(hi, cents) end
      spread, classes = spread + (hi - lo), classes + 1
      if hi - lo > widest then widest = hi - lo end
    end
  end
  return spread / classes, widest
end

-- Where the passage as a whole has gone: the presence-weighted mean displacement of each
-- onset, which is the ambient a strand born there would rest at.
local function drift(answer)
  local first, last, lowest, highest = nil, nil, math.huge, -math.huge
  for _, onset in ipairs(answer.onsets) do
    local total, weight = 0, 0
    for _, index in ipairs(onset.members) do
      total  = total + onset.presence[index] * answer.displacement[index]
      weight = weight + onset.presence[index]
    end
    local mean = total / weight
    first, last = first or mean, mean
    lowest, highest = math.min(lowest, mean), math.max(highest, mean)
  end
  return first, last, lowest, highest
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
-- Every box states the same trade here, so it is the one figure that matches magnitudes.
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
  local restMean, restWidest = wanderingFromRest(answer)
  local impure, over = impurity(answer)
  local first, last, lowest, highest = drift(answer)
  print(('  wandering: mean %.2fc, widest %.2fc on the %s;  impurity: worst %.2fc, %d springs over 1c')
    :format(mean, widest, class, impure, over))
  print(('  from rest: mean %.2fc, widest %.2fc;  drift: %.1fc to %.1fc, range %.1fc..%.1fc')
    :format(restMean, restWidest, first, last, lowest, highest))
  print(('  settled cost %.4f'):format(answer.cost))
end

-- The span box's own dials: the purity is where its springs come out under a cent on this
-- take, and every other box's ride off it by what its C7 crossing says it weighs.
local SPAN_LOCK, SPAN_PURITY = 0.9476, 32

local function atOwnDials(label, score)
  local at = under(score, crossing)
  if not at then print(('  %-14s no crossing'):format(label)) return end
  local purity = SPAN_PURITY * at / SPAN_LOCK
  under(score, function()
    beatingTable(('%s, crossing %.4f -> lock %.2f purity %.0f'):format(label, at, at, purity),
                 solve(at, purity, CAP))
  end)
end

print('==== the box family, each at the dials its own magnitude names')
atOwnDials('span',  spanScore)
atOwnDials('q=1',   normBox(1))
atOwnDials('q=2',   normBox(2))
atOwnDials('q=inf', normBox(math.huge))
