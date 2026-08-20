-- Pins the box score of docs/sonority.md § The box: the 5-limit column of
-- design/adaptive-tuning.md § Choosing the target chooses the theory, its
-- identity with the Tenney height of the sonority's lcm/gcd, and the two
-- invariances that let the model hold no reference pitch.
--
-- Pins the sonority walk too (§ The walk): which strands are current at each onset,
-- distinctness by step-class, the bass as the class a released chord leaves
-- behind it, and the class still sounding that the last n struck have dropped.
--
-- Pins the objective the solve minimises: the box summed over the walk's
-- sonorities, and the pull counted once per strand (§ The pull).
--
-- Pins the solve of design/adaptive-tuning.md § Solving it: that the DP returns
-- the exact minimum of that objective, held against exhaustive enumeration; that
-- a strand held across a chord change bends the harmony to it (§ The strand); and
-- the two guards.
--
-- Pins the pull's scale on the calibration C7 (§ The dials): the crossing
-- from the otonal seventh to the Pythagorean, and what resolving the chord to
-- F–A–C does to that trade (§ The walk).
--
-- Pins the springs themselves (§ The springs): a spelling read
-- off as the displacement gaps at which its pairs sound pure, nearest-octave,
-- from the seats of the strands its members name.
--
-- Pins the objective those springs stand in (§ The springs): stiffness ×
-- mistuning² per spring and strength × displacement² per strand, both taken in
-- cents over fifty, so that a notation states the seats and measures nothing.
-- The box is no part of it, being a constant in the displacements.
--
-- Pins the relaxation that minimises it (§ The springs): the sweep's answer on a
-- pair whose optimum is a closed form, under soft springs and stiff, and a comma
-- loop whose residue no displacement can make slack.
--
-- Pins the terms the walk relaxes on (§ The solve): a warm start that buys the
-- sweep its speed and not its answer, and a held strand standing as data at the
-- displacement it carries while its neighbours settle around it.
--
-- Pins the beam that chooses the spellings (§ The candidates): a spelling standing
-- at any offset from the seats, no two of its members taking one spelling, a full
-- enumeration the beam of twelve is checked against, one anchor to the set a spelling
-- leaves waiting, and the cut running within a waiting count so a deferral crowds no
-- spelling out.
--
-- Pins the terms the walk takes from the notation (§ The solve): the seat a strand
-- is written on, which onsets a member may wait through, and that everything a
-- sonority reads of a member is indexed at its strand.
--
-- Pins the walk itself (§ The solve): an answer held against an exhaustive search
-- over the same spelling lists, a cap of one taking the greedy road, and a strand
-- that has stopped standing at the cents the walk left it.
--
-- Pins the deferral the walk carries (§ The candidates): a rolled chord charged
-- for the pair it held where that pair places, landing where the struck chord
-- lands and costing what spelling it at its own onset would have cost; and the
-- debt in the merge key, without which the walk keeps the road that only looks
-- cheaper.
--
-- Pins the placement the moves facility takes off all of it (§ The solve): the
-- five-part take below spelled, walked and settled in one call with its
-- displacements summing to nothing, a struck triad standing at the target's own
-- intervals, a notation of finer steps settling that triad where 12-EDO settles
-- it, and a chord no chain of moves reaches spelled and priced rather than refused.

local t        = require('support')
local tuning   = require('tuning')
local util     = require('util')
local sonority = require('sonority')

-- The doc's figures are given to 2dp.
local function near(actual, expected, why)
  t.truthy(math.abs(actual - expected) < 0.005, string.format(
    '%s: expected %.2f, got %.4f', why or 'score', expected, actual))
end

-- A spring pinned whole: which strands it ties, and the gap at which they sound pure.
local function spring(sp, i, j, delta, why)
  t.eq(sp.i, i, why .. ': i')
  t.eq(sp.j, j, why .. ': j')
  near(sp.delta, delta, why)
end

-- The relaxation's original terms: every strand free, and standing where it was written.
local function allFree(count)
  local start, free = {}, {}
  for index = 1, count do start[index], free[index] = 0, index end
  return start, free
end

-- A notation of even steps, and one of uneven, whose steps stand at the cents given.
local edo12 = tuning.presets['12EDO']
local function nameless(cents)
  return tuning.derive{ name = 'scale', period = 1200, cents = cents, stepNames = {} }
end

-- Steps of fifty cents: a note written on a 12-EDO step seats where 12-EDO seats it, with
-- half the room either side of it.
local halfSteps = {}
for step = 0, 23 do halfSteps[step + 1] = step * 50 end
local edo24 = nameless(halfSteps)

-- Targets read as moves: pure fifths and thirds, the set a ii–V–I of sevenths is spelled
-- under, and the eleven-pitch set the figures of § Measured were taken over.
local fifthsAndThirds = tuning.moves{ pitches = { '1/1', '3/2', '5/4' } }
local withSevenths    = tuning.moves{ pitches = { '1/1', '3/2', '5/4', '7/4', '9/8' } }
local elevenPitches   = tuning.moves{ pitches = { '1/1', '3/2', '5/4', '6/5', '7/4', '7/6',
                                                  '7/5', '9/8', '5/3', '8/7', '10/7' } }

-- The chords of § Choosing the target chooses the theory in the spellings that
-- table names, each pitch twice over: as the exponents of the odd primes in it,
-- and as the ratio with the powers of two divided out.
local chords = {
  { name = 'fifth C–G  1/1 3/2', score = 1.58,
    coords = { {}, { [3] = 1 } },
    odd    = { {1,1}, {3,1} } },

  { name = 'sus4 C–F–G  1/1 4/3 3/2', score = 3.17,
    coords = { {}, { [3] = -1 }, { [3] = 1 } },
    odd    = { {1,1}, {1,3}, {3,1} } },

  { name = 'major C–E–G  1/1 5/4 3/2', score = 3.91,
    coords = { {}, { [5] = 1 }, { [3] = 1 } },
    odd    = { {1,1}, {5,1}, {3,1} } },

  { name = 'minor C–E♭–G  1/1 6/5 3/2', score = 3.91,
    coords = { {}, { [3] = 1, [5] = -1 }, { [3] = 1 } },
    odd    = { {1,1}, {3,5}, {3,1} } },

  { name = 'maj7 C–E–G–B  1/1 5/4 3/2 15/8', score = 3.91,
    coords = { {}, { [5] = 1 }, { [3] = 1 }, { [3] = 1, [5] = 1 } },
    odd    = { {1,1}, {5,1}, {3,1}, {15,1} } },

  { name = 'dom7 C–E–G–B♭  1/1 5/4 3/2 9/5', score = 7.81,
    coords = { {}, { [5] = 1 }, { [3] = 1 }, { [3] = 2, [5] = -1 } },
    odd    = { {1,1}, {5,1}, {3,1}, {9,5} } },

  { name = 'dim C–E♭–G♭  1/1 6/5 36/25', score = 7.81,
    coords = { {}, { [3] = 1, [5] = -1 }, { [3] = 2, [5] = -2 } },
    odd    = { {1,1}, {3,5}, {9,25} } },

  { name = 'aug C–E–G♯  1/1 5/4 25/16', score = 4.64,
    coords = { {}, { [5] = 1 }, { [5] = 2 } },
    odd    = { {1,1}, {5,1}, {25,1} } },
}

local function gcd(a, b) while b ~= 0 do a, b = b, a % b end return a end
local function lcm(a, b) return a // gcd(a, b) * b end

-- Tenney height of the set's lcm over its gcd, taken as rationals: the integers
-- the coords reach the same number without ever forming.
local function tenneyOfSpan(odd)
  local numLcm, numGcd, denLcm, denGcd = 1, 0, 1, 0
  for _, r in ipairs(odd) do
    numLcm, numGcd = lcm(numLcm, r[1]), gcd(numGcd, r[1])
    denLcm, denGcd = lcm(denLcm, r[2]), gcd(denGcd, r[2])
  end
  local num, den = numLcm * denLcm, numGcd * denGcd
  local g = gcd(num, den)
  num, den = num // g, den // g
  return math.log(num * den, 2)
end

-- Every coord of the set moved by `by` on one axis, absent exponents included.
local function shifted(coordSet, prime, by)
  local out = {}
  for i, coords in ipairs(coordSet) do
    local moved = { [prime] = by }
    for p, e in pairs(coords) do moved[p] = (moved[p] or 0) + e end
    out[i] = moved
  end
  return out
end

-- A note as the command hands it over, which the grouping holds by reference.
local function event(ppq, pitch, endppq)
  return { ppq = ppq, pitch = pitch, endppq = endppq }
end

-- The pitch class, which is what a step-class comes to under an octave notation.
local function pitchClass(note) return note.pitch % 12 end

-- A strand as the walk reads it: notes given as { ppq, pitch, endppq }, under
-- the step-class they share. The shortlist is the solve's business rather than
-- the walk's, so these carry none.
local function strand(class, notes)
  local built = {}
  for i, note in ipairs(notes) do
    built[i] = { ppq = note[1], pitch = note[2], endppq = note[3] }
  end
  return { class = class, notes = built }
end

-- Strands of one note each, given as { class, ppq, pitch }, every note `over`
-- long so that it is released where the next strikes.
local function struck(over, list)
  local strands = {}
  for i, note in ipairs(list) do
    strands[i] = strand(note[1], { { note[2], note[3], note[2] + over } })
  end
  return strands
end

-- A strand as the solver reads it: the walk's shape with a shortlist of
-- candidates, each carrying the coords it would take and its strain.
local function placed(class, notes, candidates)
  local built = strand(class, notes)
  built.shortlist = candidates
  return built
end

-- Strands of one note and one candidate, given as { class, ppq, pitch, coords,
-- strain } and `over` long, with the choice that takes each strand's only
-- candidate.
local function fixed(over, list)
  local strands, choice = {}, {}
  for i, entry in ipairs(list) do
    strands[i] = placed(entry[1], { { entry[2], entry[3], entry[2] + over } },
      { { coords = entry[4], strain = entry[5] } })
    choice[i] = 1
  end
  return strands, choice
end

-- The strain of a ratio written on a 12-EDO step: its distance from that step
-- as a fraction of the 50¢ half-window.
local function strainOf(num, den, step)
  return math.abs(1200 * math.log(num / den, 2) - step) / 50
end

-- The pitches the objective's cases are built from.
local just = {
  C = {}, E = { [5] = 1 }, G = { [3] = 1 },
  D = { [3] = 2 }, Fsharp = { [3] = 2, [5] = 1 }, A = { [3] = 3 },
  septimal = { [7] = 1 }, pythagorean = { [3] = -2 },
}

-- C major then D major, disjoint in class: at n=3 each onset stands alone, and
-- at n=5 the second sonority holds two classes of the first as well.
local function triads(cStrain, dStrain)
  return fixed(960, {
    { 0,   0, 60, just.C,      cStrain }, { 4, 0, 64, just.E,       0 },
    { 7,   0, 67, just.G,      0       },
    { 2, 960, 62, just.D,      dStrain }, { 6, 960, 66, just.Fsharp, 0 },
    { 9, 960, 69, just.A,      0       },
  })
end

local function classesAt(strands, sonorityAt)
  local out = {}
  for i, index in ipairs(sonorityAt.strands) do out[i] = strands[index].class end
  return out
end

-- The DP is exact, so its answer is held to the enumeration's to the bit.
local function exactly(actual, expected, why)
  t.truthy(math.abs(actual - expected) < 1e-9, string.format(
    '%s: expected %.6f, got %.6f', why, expected, actual))
end

-- The solve's own figures are worked further out than the doc's two places.
local function nearly(actual, expected, why)
  t.truthy(math.abs(actual - expected) < 5e-4, string.format(
    '%s: expected %.4f, got %.6f', why, expected, actual))
end

-- What one sonority of the walk scores under a choice, so a passage can be read
-- chord by chord rather than as its total.
local function scoreAt(strands, choice, sonorityAt)
  local coordSet = {}
  for i, index in ipairs(sonorityAt.strands) do
    coordSet[i] = strands[index].shortlist[choice[index]].coords
  end
  return sonority.score(coordSet)
end

-- Every choice vector over the strands' shortlists, in odometer order.
local function everyChoice(strands, fn)
  local choice = {}
  for i = 1, #strands do choice[i] = 1 end
  while true do
    fn(choice)
    local i = #strands
    while i >= 1 do
      choice[i] = choice[i] + 1
      if choice[i] <= #strands[i].shortlist then break end
      choice[i] = 1; i = i - 1
    end
    if i < 1 then return end
  end
end

local function bruteMinimum(strands, n, strength)
  local best
  everyChoice(strands, function(choice)
    local cost = sonority.cost(strands, n, strength, choice)
    if not best or cost < best then best = cost end
  end)
  return best
end

-- One shortlist shared by every strand of the layouts below: three candidates
-- far enough apart that the box and the pull want different ones.
local threeWays = {
  { coords = just.C,           strain = 0   },
  { coords = just.E,           strain = 0.3 },
  { coords = just.pythagorean, strain = 0.6 },
}

-- Strands given as { class, {{ppq,pitch,endppq},..} }, each taking threeWays.
local function laidOut(list)
  local strands = {}
  for i, entry in ipairs(list) do strands[i] = placed(entry[1], entry[2], threeWays) end
  return strands
end

-- The shapes the schedule has to get right: strands born together and born
-- apart, a strand outliving the last n struck, one sounding under them, and
-- one that no sonority ever holds.
local layouts = {
  { name    = 'a block chord',
    strands = laidOut{ { 0, { { 0, 60, 240 } } }, { 4, { { 0, 64, 240 } } },
                       { 7, { { 0, 67, 240 } } } } },

  { name    = 'the same chord arpeggiated',
    strands = laidOut{ { 0, { { 0, 60, 240 } } }, { 4, { { 240, 64, 480 } } },
                       { 7, { { 480, 67, 720 } } } } },

  { name    = 'a strand restruck across another strand\'s onset',
    strands = laidOut{ { 0, { { 0, 60, 240 }, { 480, 60, 720 } } },
                       { 4, { { 240, 64, 480 } } } } },

  { name    = 'a strand striking at the first onset and the last',
    strands = laidOut{ { 0, { { 0, 60, 240 }, { 960, 60, 1200 } } },
                       { 4, { { 240, 64, 480 } } },
                       { 7, { { 480, 67, 720 } } }, { 11, { { 720, 71, 960 } } } } },

  { name    = 'a strand sounding under the classes that follow it',
    strands = laidOut{ { 0, { { 0, 60, 1200 } } }, { 4, { { 240, 64, 480 } } },
                       { 7, { { 480, 67, 720 } } }, { 11, { { 720, 71, 960 } } },
                       { 2, { { 960, 62, 1200 } } } } },

  { name    = 'an onset wider than n',
    strands = laidOut{ { 0, { { 0, 60, 240 } } }, { 4, { { 0, 64, 240 } } },
                       { 7, { { 0, 67, 240 } } }, { 11, { { 0, 71, 240 } } } } },

  { name    = 'two strands of one class, disjoint in time',
    strands = laidOut{ { 0, { { 0, 60, 240 } } }, { 4, { { 0, 64, 240 } } },
                       { 0, { { 960, 72, 1200 } } } } },
}

-- The held D of § The strand, with everything but the D fixed: the D is asked
-- to serve a G–B♭–D–F it is struck before, and the spans it sounds over say
-- whether it must hold one tuning across the change or may take two.
local dorianD = {
  { coords = { [3] = -2, [5] = 1 }, strain = strainOf(10, 9, 200) },
  { coords = { [3] = 2 },           strain = strainOf(9,  8, 200) },
}

local function dorian(dSpans)
  local strands = fixed(960, {
    { 5,    0, 65, { [3] = -1 },          strainOf(4,  3,  500) },
    { 9,    0, 69, { [3] = -1, [5] = 1 }, strainOf(5,  3,  900) },
    { 7,  960, 55, { [3] = 1 },           strainOf(3,  2,  700) },
    { 10, 960, 58, { [3] = -2 },          strainOf(16, 9, 1000) },
  })
  for i, span in ipairs(dSpans) do
    strands[4 + i] = placed(2, { { span[1], 62, span[2] } }, dorianD)
  end
  return strands
end

-- The 7-limit diamond at odd limit 9, cut to the points each 12-EDO window
-- holds: the shape a target takes (§ What a target is), written out so the
-- calibration runs before any generator exists (§ First brick). Each point is
-- given as its coords and the ratio its strain is taken from.
local diamond = {
  C  = { { {},                    1, 1,    0 } },
  E  = { { { [5] = 1 },           5, 4,  400 }, { { [3] = 2, [7] = -1 },  9, 7,  400 } },
  F  = { { { [3] = -1 },          4, 3,  500 } },
  G  = { { { [3] = 1 },           3, 2,  700 } },
  A  = { { { [3] = -1, [5] = 1 }, 5, 3,  900 }, { { [3] = 1, [7] = -1 }, 12, 7,  900 } },
  Bb = { { { [7] = 1 },           7, 4, 1000 }, { { [3] = -2 },          16, 9, 1000 },
         { { [3] = 2, [5] = -1 }, 9, 5, 1000 } },
}

-- Each chord is released where the next strikes, a bar of 960 later.
local function fromDiamond(class, ppq, pitch, step)
  local candidates = {}
  for i, point in ipairs(diamond[step]) do
    candidates[i] = { coords = point[1], strain = strainOf(point[2], point[3], point[4]) }
  end
  return placed(class, { { ppq, pitch, ppq + 960 } }, candidates)
end

-- The written C7, every note taking what its own window holds. The seventh is
-- strand 4, its candidates 7/4, 16/9 and 9/5 in that order.
local function seventh()
  return {
    fromDiamond(0,  0, 60, 'C'), fromDiamond(4, 0, 64, 'E'),
    fromDiamond(7,  0, 67, 'G'), fromDiamond(10, 0, 70, 'Bb'),
  }
end

-- The same chord resolving to F–A–C a bar later.
local function resolving()
  local strands = seventh()
  strands[5] = fromDiamond(5, 960, 65, 'F')
  strands[6] = fromDiamond(9, 960, 69, 'A')
  strands[7] = fromDiamond(0, 960, 72, 'C')
  return strands
end

-- The 5-limit diamond at odd limit 15 over the classes the run below uses. It
-- fixes nine of the twelve, and B♭ is one of the two it leaves a choice at,
-- between readings a syntonic comma apart.
local sparse = {
  [0]  = { { {},                     1, 1 } },
  [4]  = { { { [5] = 1 },            5, 4 } },
  [5]  = { { { [3] = -1 },           4, 3 } },
  [7]  = { { { [3] = 1 },            3, 2 } },
  [10] = { { { [3] = -2 },          16, 9 }, { { [3] = 2, [5] = -1 }, 9, 5 } },
  [11] = { { { [3] = 1, [5] = 1 },  15, 8 } },
}

local function fromSparse(class, ppq, pitch, endppq)
  local candidates = {}
  for i, point in ipairs(sparse[class]) do
    candidates[i] = { coords = point[1],
                      strain = strainOf(point[2], point[3], class * 100) }
  end
  return placed(class, { { ppq, pitch, endppq } }, candidates)
end

-- A B♭ struck first and released at `endppq`, under a run of five classes the
-- target fixes: nothing the run transmits says how to read the B♭, so only its
-- own release decides whether it stands in the sonorities behind it.
local function underRun(endppq)
  return {
    fromSparse(10,    0, 70, endppq),
    fromSparse(11,  480, 83,  960), fromSparse(7,  960, 79, 1440),
    fromSparse(0,  1440, 72, 1920), fromSparse(4, 1920, 76, 2400),
    fromSparse(5,  2400, 77, 2880),
  }
end

-- A chord to the bar, each released where the next strikes: the passage the walk of
-- docs/sonority.md § The solve is taken over.
local function progression(bars)
  local notes = {}
  for beat, pitches in ipairs(bars) do
    for _, pitch in ipairs(pitches) do
      notes[#notes + 1] = event((beat - 1) * 960, pitch, beat * 960)
    end
  end
  return sonority.strands(notes, pitchClass)
end

-- A chord rolled note by note, every note held to the end of the bar: the passage
-- docs/sonority.md § The candidates takes its deferral over.
local function rolled(pitches, apart)
  local notes = {}
  for k, pitch in ipairs(pitches) do notes[k] = event((k - 1) * apart, pitch, 960) end
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

-- The five-part take the springs' figures are taken over: sixty-six notes, forty
-- strands over sixteen sonorities.
local take = heldLines({
  { 72, 72, 71, 72, 74, 74, 72, 71, 69, 69, 71, 72, 74, 72, 71, 72 },
  { 67, 65, 65, 67, 67, 65, 64, 62, 62, 64, 65, 67, 65, 65, 62, 64 },
  { 64, 62, 62, 60, 59, 60, 57, 59, 57, 60, 60, 60, 57, 59, 55, 55 },
  { 55, 53, 55, 52, 50, 53, 52, 50, 53, 52, 48, 48, 50, 50, 47, 48 },
  { 48, 50, 43, 45, 43, 41, 45, 43, 45, 36, 41, 38, 36, 43, 43, 36 },
}, 960)

-- What the notation and the target hand the walk: an onset per sonority and a spelling
-- list apiece, at the beam width and the stiffness the figures below are taken under.
local function termsOf(strands, n, moves)
  local seat = sonority.seats(strands, edo12)
  local onsets, lists = sonority.onsets(strands, sonority.walk(strands, n)), {}
  for i, onset in ipairs(onsets) do
    lists[i] = sonority.spellings(onset.members, seat, onset.mayWait, moves, 24, 8)
  end
  return onsets, lists, seat
end

-- The whole of what a passage's displacements cost: every spring of it, and the pull on
-- every strand, which is the objective the relaxation minimises.
local function objectiveAt(springs, displacement, count, strength, stiffness)
  local _, free = allFree(count)
  return sonority.springCost(springs, displacement, stiffness, 1, #springs)
       + sonority.pullCost(displacement, strength, free)
end

-- The winner settled by one joint relaxation, which is where the frozen past gives back
-- what it held along the way; the walk's own cost stands above this until then.
local function settledFrom(answer, count, strength, stiffness)
  local _, free = allFree(count)
  local displacement = sonority.relax(sonority.ties(answer.springs, free), strength,
                                      stiffness, answer.displacement, free)
  return answer.box + objectiveAt(answer.springs, displacement, count, strength, stiffness),
         displacement
end

-- What a passage settles to under a target: the walk's answer, given back by the joint
-- relaxation, at the cap and the arity the figures below are taken under.
local function settledUnder(strands, moves)
  local onsets, lists, seat = termsOf(strands, 5, moves)
  return settledFrom(sonority.search(onsets, lists, seat, 1, 8, 60), #seat, 1, 8)
end

-- Every combination of the spelling lists, each relaxed cold with every strand free: the
-- search the walk is held against, in the odometer order everyChoice takes, so that an
-- exact tie falls to the same combination the walk's own tie-break keeps.
local function bruteSpelled(lists, count, strength, stiffness)
  local start, free = allFree(count)
  local at, best = {}, nil
  for i = 1, #lists do at[i] = 1 end
  while true do
    local springs, box = {}, 0
    for i, list in ipairs(lists) do
      springs[i] = list[at[i]].springs
      box        = box + list[at[i]].box
    end
    local displacement = sonority.relax(sonority.ties(springs, free), strength,
                                        stiffness, start, free)
    local cost = box + objectiveAt(springs, displacement, count, strength, stiffness)
    if not best or cost < best.cost then
      best = { cost = cost, displacement = displacement, choice = { table.unpack(at) } }
    end

    local i = #lists
    while i >= 1 do
      at[i] = at[i] + 1
      if at[i] <= #lists[i] then break end
      at[i] = 1; i = i - 1
    end
    if i < 1 then return best end
  end
end

-- The readings the calibration is taken between, septimal seventh first.
local c7Septimal,        c7Pythagorean        = { 1, 1, 1, 1 }, { 1, 1, 1, 2 }
local resolvingSeptimal, resolvingPythagorean = { 1, 1, 1, 1, 1, 1, 1 },
                                                { 1, 1, 1, 2, 1, 1, 1 }

return {
  {
    name = 'the 5-limit column of the theory table',
    run = function()
      for _, chord in ipairs(chords) do
        near(sonority.score(chord.coords), chord.score, chord.name)
      end
    end,
  },

  {
    name = "the score is the Tenney height of the sonority's octave-free lcm/gcd",
    run = function()
      for _, chord in ipairs(chords) do
        local height = tenneyOfSpan(chord.odd)
        t.truthy(math.abs(sonority.score(chord.coords) - height) < 1e-9,
          chord.name .. ': score ' .. sonority.score(chord.coords) .. ' vs height ' .. height)
      end
    end,
  },

  {
    name = 'the score is blind to where the sonority sits',
    run = function()
      local major = chords[3].coords
      near(sonority.score(shifted(major, 3, 2)), 3.91, 'major up two fifths')
      near(sonority.score(shifted(major, 5, -1)), 3.91, 'major down a third')
      near(sonority.score(shifted(major, 7, 3)), 3.91, 'major shifted on an axis it never uses')
    end,
  },

  {
    name = 'a repeated member and an octave doubling cost nothing',
    run = function()
      local major = chords[3].coords
      near(sonority.score{ major[1], major[2], major[3], major[3] }, 3.91, 'G struck twice')
      near(sonority.score{ major[1], major[2], major[3], { [3] = 1 } }, 3.91, 'G doubled an octave up')
      near(sonority.score{ { [3] = 1 } }, 0, 'one pitch spans nothing')
      near(sonority.score{}, 0, 'and neither does none')
    end,
  },

  {
    name = 'springs: a spelled major triad, by hand',
    run = function()
      local springs = sonority.springs({ 1, 2, 3 }, { 0, 400, 700 },
        { {}, { [5] = 1 }, { [3] = 1 } })

      t.eq(#springs, 3, 'a spring per pair')
      spring(springs[1], 1, 2, -13.69, 'the third pure 13.69 below its seat')
      spring(springs[2], 1, 3, 1.955, 'the fifth pure 1.96 above its seat')
      spring(springs[3], 2, 3, 15.64, 'third to fifth, the difference of the two')
    end,
  },

  {
    name = 'springs: deviations reduce to the nearest octave, and name strands',
    run = function()
      -- A seat is read at the strand its member names, whatever position the member holds:
      -- a sonority of strands 3 and 5 reads their two seats, and the spring names them again.
      local springs = sonority.springs({ 3, 5 }, { [3] = 1100, [5] = 0 },
                                       { {}, { [3] = -1, [5] = -1 } })

      t.eq(#springs, 1, 'one pair, one spring')
      spring(springs[1], 3, 5, 11.73, 'pure just over the seam, not a descent of 1188')
    end,
  },

  {
    name = 'springs: a lone member holds no spring',
    run = function()
      t.eq(#sonority.springs({ 4 }, { [4] = 250 }, { {} }), 0, 'one member ties nothing')
    end,
  },

  {
    name = 'springs: the objective sums the springs and the pull',
    run = function()
      -- A C major triad, then the fifth G–D: two sonorities sharing the strand on G. The box
      -- the two spellings carry is charged by whoever chose them, not by the cost of a placement.
      local seat  = { 0, 400, 700, 200 }
      local major = sonority.springs({ 1, 2, 3 }, seat, { {}, { [5] = 1 }, { [3] = 1 } })
      local fifth = sonority.springs({ 3, 4 }, seat, { {}, { [3] = 1 } })
      local displacement = { -4, -12, 2, 6 }

      -- Each spring's mistuning is the gap the displacements realise less the gap the
      -- spelling states: -8 against -13.69, 6 against 1.96, 14 against 15.64, 4 against 1.96.
      local mist = 8 * ((5.6863/50)^2 + (4.0450/50)^2 + (1.6413/50)^2 + (2.0450/50)^2)
      local pull = 1 * ((4/50)^2 + (12/50)^2 + (2/50)^2 + (6/50)^2)

      near(objectiveAt({ major, fifth }, displacement, 4, 1, 8), mist + pull,
        'the two terms summed, and no box among them')
      near(sonority.springCost({ major, fifth }, displacement, 8, 1, 2), mist,
        'the springs charged at the stiffness')
      near(sonority.pullCost(displacement, 1, { 1, 2, 3, 4 }), pull,
        'and the pull over the same fifty the springs are charged over')
    end,
  },

  {
    name = 'springs: displacements realising the spelling leave every spring slack',
    run = function()
      local major = sonority.springs({ 1, 2, 3 }, { 0, 400, 700 }, { {}, { [5] = 1 }, { [3] = 1 } })

      -- The first strand stands where it was written and the others follow their springs
      -- from it, so every pair sounds the interval the spelling states, the third pair included.
      local displacement = { 0, major[1].delta, major[2].delta }
      local pull = 0
      for _, cents in ipairs(displacement) do pull = pull + (cents / 50)^2 end

      local cost = objectiveAt({ major }, displacement, 3, 1, 8)
      near(cost, pull, 'the pull alone, and nothing from the springs')
      t.eq(cost, objectiveAt({ major }, displacement, 3, 1, 1e6),
        'a stiffness of a million charges a slack spring the same nothing')
    end,
  },

  {
    name = 'springs: the pull is charged in cents, whichever way it points',
    run = function()
      near(sonority.pullCost({  10 }, 1, { 1 }), 0.04,
        'ten cents is a fifth of the fifty the strain is taken over')
      near(sonority.pullCost({ -10 }, 1, { 1 }), 0.04,
        'and ten cents down costs what ten cents up costs')
    end,
  },

  {
    name = 'relax: a pair settles where the hand solution puts it',
    run = function()
      -- One spring, and a pull that charges either strand alike, so the two part it
      -- equally: each at stiffness × delta over strength plus twice the stiffness.
      local third = sonority.springs({ 1, 2 }, { 0, 400 }, { {}, { [5] = 1 } })
      local hand  = -8 * third[1].delta / (1 + 2 * 8)

      local start, free  = allFree(2)
      local displacement = sonority.relax(sonority.ties({ third }, free), 1, 8, start, free)
      near(displacement[1],  hand, 'the root rises six and a half cents')
      near(displacement[2], -hand, 'and the third falls as far to meet it')
    end,
  },

  {
    name = 'relax: no wall stops stiff springs stretching a pair',
    run = function()
      -- A 7/4 asks for thirty-one cents of stretch and stiff springs outweigh the pull, so
      -- the pair goes fifteen cents apiece: nothing bounds a displacement, and the closed
      -- form above holds at any stiffness.
      local harmonic = sonority.springs({ 1, 2 }, { 0, 1000 }, { {}, { [7] = 1 } })
      local hand     = -40 * harmonic[1].delta / (1 + 2 * 40)

      local start, free  = allFree(2)
      local displacement = sonority.relax(sonority.ties({ harmonic }, free), 1, 40, start, free)
      near(displacement[1],  hand, 'the root fifteen cents up, past where a fine step sits')
      near(displacement[2], -hand, 'and the seventh as far down')
      near(displacement[2] - displacement[1] - harmonic[1].delta,
           -harmonic[1].delta / (1 + 2 * 40),
        "the spring keeping the strength's share of the stretch, one part in eighty-one")
    end,
  },

  {
    name = 'relax: a comma loop spreads its residue across the springs',
    run = function()
      -- C–E a 5/4, E–A a 4/3, C–A a 27/16: three sonorities whose spellings fail to close
      -- by a syntonic comma, so no displacement leaves all three springs slack.
      local seat   = { 0, 400, 900 }
      local third  = sonority.springs({ 1, 2 }, seat, { {}, { [5] =  1 } })
      local fourth = sonority.springs({ 2, 3 }, seat, { {}, { [3] = -1 } })
      local sixth  = sonority.springs({ 1, 3 }, seat, { {}, { [3] =  3 } })
      local loop = { third, fourth, sixth }

      local start, free  = allFree(3)
      local displacement = sonority.relax(sonority.ties(loop, free), 1, 8, start, free)
      local spread       = objectiveAt(loop, displacement, 3, 1, 8)

      -- Two springs go slack only by handing the whole comma to the third.
      local borne = { 0, third[1].delta,
                      third[1].delta + fourth[1].delta }
      t.truthy(spread < objectiveAt(loop, borne, 3, 1, 8),
        'the spread comma costs less than one spring bearing it')

      for _, springs in ipairs(loop) do
        local tie = springs[1]
        t.truthy(math.abs(displacement[tie.j] - displacement[tie.i] - tie.delta) < 8,
          'no spring left holding more than eight of the twenty-one cents')
      end

      for index = 1, 3 do
        for _, nudge in ipairs{ -0.5, 0.5 } do
          local nudged = { displacement[1], displacement[2], displacement[3] }
          nudged[index] = nudged[index] + nudge
          t.truthy(spread < objectiveAt(loop, nudged, 3, 1, 8),
            'and nothing half a cent away is cheaper')
        end
      end
    end,
  },

  {
    name = 'relax: a warm start settles where the cold one did',
    run = function()
      -- The objective is convex, so where the sweep begins buys it sweeps and not an answer:
      -- the comma loop started well off its optimum comes back to the same three cents.
      local seat   = { 0, 400, 900 }
      local third  = sonority.springs({ 1, 2 }, seat, { {}, { [5] =  1 } })
      local fourth = sonority.springs({ 2, 3 }, seat, { {}, { [3] = -1 } })
      local sixth  = sonority.springs({ 1, 3 }, seat, { {}, { [3] =  3 } })
      local loop = { third, fourth, sixth }

      local start, free = allFree(3)
      local ties = sonority.ties(loop, free)
      local cold = sonority.relax(ties, 1, 8, start, free)
      local warm = sonority.relax(ties, 1, 8, { 40, -30, 25 }, { 1, 2, 3 })

      for index = 1, 3 do
        near(warm[index], cold[index], 'strand ' .. index .. ' settles where it always did')
      end
    end,
  },

  {
    name = 'ties: a set starting from another settles where one gathered whole settles',
    run = function()
      -- The walk ties the onsets an answer has settled once, and starts the ties of each
      -- spelling tried at the cursor from that set, rather than tying every onset at each of them.
      local seat   = { 0, 400, 900 }
      local third  = sonority.springs({ 1, 2 }, seat, { {}, { [5] =  1 } })
      local fourth = sonority.springs({ 2, 3 }, seat, { {}, { [3] = -1 } })
      local sixth  = sonority.springs({ 1, 3 }, seat, { {}, { [3] =  3 } })
      local loop = { third, fourth, sixth }
      local start, free  = allFree(3)

      local settled = sonority.ties(loop, free, { 1, 2 })
      local whole = sonority.relax(sonority.ties(loop, free), 1, 8, start, free)
      local stood = sonority.relax(sonority.ties(loop, free, { 3 }, settled),
                                   1, 8, start, free)

      for index = 1, 3 do
        t.eq(stood[index], whole[index], 'strand ' .. index .. ' settling to the same cents')
      end
    end,
  },

  {
    name = 'relax: a held strand stands where it was put, and the rest settle around it',
    run = function()
      -- The walk frees the strands an onset sounds and reads the rest: here the root is data
      -- at ten cents sharp, pulling on the springs of a triad whose sweep it takes no turn in.
      local major = sonority.springs({ 1, 2, 3 }, { 0, 400, 700 },
                                     { {}, { [5] = 1 }, { [3] = 1 } })

      local sweeping = { 2, 3 }
      local held = sonority.relax(sonority.ties({ major }, sweeping), 1, 8,
                                  { 10, 0, 0 }, sweeping)
      t.eq(held[1], 10, 'the held strand stands exactly where it was put')

      -- The two that sweep sit at the optimum of what is left, the held one a constant in it.
      local settled = objectiveAt({ major }, held, 3, 1, 8)
      for _, index in ipairs{ 2, 3 } do
        for _, nudge in ipairs{ -0.5, 0.5 } do
          local nudged = { held[1], held[2], held[3] }
          nudged[index] = nudged[index] + nudge
          t.truthy(settled < objectiveAt({ major }, nudged, 3, 1, 8),
            'nothing half a cent from strand ' .. index .. ' is cheaper')
        end
      end

      -- And the hold is felt: from the same start, a root free to move would not stay sharp.
      local all  = { 1, 2, 3 }
      local free = sonority.relax(sonority.ties({ major }, all), 1, 8, { 10, 0, 0 }, all)
      t.truthy(held[2] > free[2] and held[3] > free[3],
        "the springs carrying the held strand's sharpness into the two that move")
    end,
  },

  {
    name = 'spellings: a major triad comes back spelled as the theory table has it',
    run = function()
      local best = sonority.spellings({ 1, 2, 3 }, { 0, 400, 700 }, {},
                                      fifthsAndThirds, 12, 8)[1]
      local hand = sonority.springs({ 1, 2, 3 }, { 0, 400, 700 },
                                    { {}, { [5] = 1 }, { [3] = 1 } })

      near(best.box, 3.91, 'the box of a 5-limit major triad')
      t.eq(#best.waiting, 0, 'with nothing deferred')
      t.eq(#best.springs, 3, 'and a spring per pair')
      for k, tie in ipairs(hand) do
        spring(best.springs[k], tie.i, tie.j, tie.delta, 'spring ' .. k)
      end
    end,
  },

  {
    name = 'spellings: a sonority no chain connects is spelled rather than refused',
    run = function()
      -- The nearest moves to 600¢ are 4/3 and 3/2, each 101.955¢ from the seat, so the pair
      -- states an interval neither of its steps can name. A spelling states intervals and
      -- stands at any offset from the seats, so what was refused is now spelled and priced.
      local list = sonority.spellings({ 1, 2 }, { 0, 600 }, {}, fifthsAndThirds, 12, 8)
      t.eq(#list, 4, 'the tritone spelled at the intervals the target does name')
      near(list[1].box, 1.585, 'the cheapest of them a 4/3')
      spring(list[1].springs[1], 1, 2, -101.96, 'a hundred cents under where it was written')

      -- Nor is a diminished triad refused for the minor third the set is silent about.
      local diminished = sonority.spellings({ 1, 2, 3 }, { 0, 300, 600 }, {},
                                            fifthsAndThirds, 12, 8)
      t.eq(#diminished, 12, 'the chord the set says nothing about, spelled at the width')
      near(diminished[1].box, 3.9069, 'the box of a major triad, which is what it states')
      spring(diminished[1].springs[1], 1, 2, 86.31, 'the minor third read as a 5/4 below')
      spring(diminished[1].springs[2], 1, 3, 101.96, 'the tritone as a 3/2')
      spring(diminished[1].springs[3], 2, 3, 15.64, 'and the pair above the root as a 6/5')

      -- Put a G beside the tritone and the C reaches it, while nothing reaches the F sharp
      -- purely: the stranded member is priced into the sonority rather than refusing it.
      local withFifth = sonority.spellings({ 1, 2, 3 }, { 0, 600, 700 }, {},
                                           fifthsAndThirds, 12, 8)
      t.eq(#withFifth, 12, 'a member no chain reaches spelled beside the two that meet')
      near(withFifth[1].box, 3.1699, 'the three carrying a fifth and a fourth between them')
      spring(withFifth[1].springs[1], 1, 2, -101.96, 'the tritone a fourth above the C')
      spring(withFifth[1].springs[2], 1, 3, 1.96, 'the fifth all but pure where it stands')
      spring(withFifth[1].springs[3], 2, 3, 103.91, 'and the pair a whole tone apart')
    end,
  },

  {
    name = 'spellings: no two members of a sonority take one spelling',
    run = function()
      -- E flat, E and G, whose seats stand a hundred cents apart. Nothing in the objective
      -- forbids a spelling stating a unison between two of them, and on this chord such a
      -- spelling wins: the two settle four cents apart, on one MIDI pitch. So a member takes
      -- a spelling no member of its component already holds, and the chord states three
      -- pitches because it has three members.
      local whole = sonority.spellings({ 1, 2, 3 }, { 300, 400, 700 }, {},
                                       fifthsAndThirds, math.huge, 8)
      t.eq(#whole, 36, 'the spellings of the three, enumerated whole')

      for k, spelling in ipairs(whole) do
        for a = 1, 3 do
          for b = a + 1, 3 do
            local one, two = spelling.placed[a], spelling.placed[b]
            t.truthy(one.component ~= two.component or not util.deepEq(one.coords, two.coords),
              string.format('spelling %d stating a pitch each for members %d and %d', k, a, b))
          end
        end
      end
    end,
  },

  {
    name = 'spellings: the offset is the spelling\'s, so which member anchors decides nothing',
    run = function()
      -- The beam anchors on the first member and joins the rest to it, but a spelling states
      -- intervals and stands at one offset from the seats, so the frame the beam builds in is
      -- none of the answer's business. Enumerated whole, since a beam of twelve would report
      -- its own width rather than what the target reaches.
      for _, seat in ipairs{ { 0, 400, 700 }, { 400, 0, 700 }, { 700, 400, 0 } } do
        local list = sonority.spellings({ 1, 2, 3 }, seat, {}, fifthsAndThirds, math.huge, 8)
        t.eq(#list, 36, 'the same spellings whichever member the walk names first')
        near(list[1].box, 3.9069, 'each of them reaching the same box')
      end

      -- And the chord no chain of moves places purely is spelled the same way round.
      for _, seat in ipairs{ { 0, 300, 600 }, { 300, 0, 600 }, { 600, 300, 0 } } do
        local list = sonority.spellings({ 1, 2, 3 }, seat, {}, fifthsAndThirds, math.huge, 8)
        t.eq(#list, 36, 'and spelled in every order where it is spelled in one')
        near(list[1].box, 3.9069, 'at the box a major triad carries')
      end
    end,
  },

  {
    name = 'spellings: every spelling ties the whole sonority, silence pricing under any answer',
    run = function()
      -- A spring charges the gap between the interval the displacements realise and the one
      -- the spelling states, so a pair that states nothing is charged nothing and saying less
      -- is always cheaper. Nothing in the objective forbids that, so the beam must: a spelling
      -- that left a member untied would price under every spelling that spoke for it.
      local strands = progression{ { 62, 65, 69 }, { 55, 59, 62 }, { 60, 64, 67 } }
      local seat    = sonority.seats(strands, edo12)
      local onsets  = sonority.onsets(strands, sonority.walk(strands, 5))

      for i, onset in ipairs(onsets) do
        local list = sonority.spellings(onset.members, seat, {}, fifthsAndThirds, 400, 8)
        t.truthy(#list > 0, 'onset ' .. i .. ' spelled at all')

        for _, spelling in ipairs(list) do
          local seen, count = {}, 0
          for _, member in ipairs(onset.members) do
            local component = spelling.placed[member].component
            if not seen[component] then seen[component], count = true, count + 1 end
          end
          t.eq(count, 1, 'onset ' .. i .. ' spelled in one component throughout')
        end
      end
    end,
  },

  {
    name = 'spellings: a rolled minor defers rather than state what the chord has not',
    run = function()
      -- The E flat has struck and the C is still sounding: spelled where they stand, the C
      -- takes an 8/5 above the E flat, stretching the pair 86¢ from where it was written,
      -- which is the cheapest of the four intervals the target names (§ The candidates).
      local seat    = { 300, 0 }
      local spelled = sonority.spellings({ 1, 2 }, seat, {}, fifthsAndThirds, 12, 8)
      t.eq(#spelled, 4, 'the intervals a pair of members can state')
      near(spelled[1].box, 2.3219, 'the cheapest of them an 8/5')
      t.eq(#spelled[1].springs, 1, 'which the pair sounds')
      spring(spelled[1].springs[1], 1, 2, -86.31, 'the C far below where it was written')

      local deferred = sonority.spellings({ 1, 2 }, seat, { false, true },
                                          fifthsAndThirds, 12, 8)
      t.eq(#deferred, 5, 'the waiting state stands beside the spelled pairs')
      t.eq(#deferred[1].waiting, 1, 'and leads them, having paid nothing yet')
      t.eq(deferred[1].waiting[1], 2, 'the C left to the sonority the fifth completes')
      t.eq(#deferred[1].springs, 0, 'which states no interval here')
    end,
  },

  {
    name = 'spellings: a width of infinity is the enumeration the beam is checked against',
    run = function()
      local members, seat = { 1, 2, 3, 4 }, { 0, 400, 700, 1000 }
      local full = sonority.spellings(members, seat, {}, fifthsAndThirds, math.huge, 8)
      local beam = sonority.spellings(members, seat, {}, fifthsAndThirds, 12, 8)
      local hand = { { 1, 2, -84.36 }, { 1, 3, 1.96 }, { 1, 4, 17.60 },
                     { 2, 3, 86.31 }, { 2, 4, 101.96 }, { 3, 4, 15.64 } }

      t.eq(#full, 456, 'the spellings of a four-member sonority, enumerated whole')
      t.eq(#beam, 12, 'against which a beam of twelve keeps its width')
      near(full[1].box, 5.4919, 'the box the four carry between them')
      near(beam[1].box, full[1].box, 'and the beam finds the same spelling')
      t.eq(#full[1].springs, #hand, 'a spring per pair of the four')
      t.eq(#beam[1].springs, #full[1].springs, 'tie for tie')
      for k, tie in ipairs(hand) do
        spring(full[1].springs[k], tie[1], tie[2], tie[3], 'spring ' .. k)
        spring(beam[1].springs[k], tie[1], tie[2], tie[3], "the beam's spring " .. k)
      end
    end,
  },

  {
    name = 'spellings: the cut runs within a waiting count, not across them',
    run = function()
      -- A deferral pays nothing here and everything later, so ranked against the spellings
      -- it outranks them all; the width is a width per count, and the spelling survives.
      -- States of one count have placed equally many members, which is what makes the
      -- scores the cut ranks commensurable.
      local members, seat = { 1, 2, 3, 4, 5 }, { 0, 400, 700, 1000, 200 }
      local free = { false, true, true, true, true }
      local list = sonority.spellings(members, seat, free, elevenPitches, 12, 8)
      local best = sonority.spellings(members, seat, {}, elevenPitches, 12, 8)[1]

      local spelled, held = nil, {}
      for _, entry in ipairs(list) do
        local waits = #entry.waiting
        held[waits] = (held[waits] or 0) + 1
        if waits == 0 and not spelled then spelled = entry end
      end
      t.truthy(spelled, 'a fully spelled state survives four members free to wait')
      near(spelled.box, best.box, 'and it is what the beam finds with nothing deferred')
      t.eq(#spelled.springs, 10, 'a spring per pair of the five')
      t.truthy(#list[1].waiting > 0, 'though a deferral leads the list')

      for waits = 0, 4 do
        t.truthy((held[waits] or 0) <= 12, string.format(
          'the states deferring %d members kept to the width, and %d stand',
          waits, held[waits] or 0))
      end
    end,
  },

  {
    name = 'spellings: a waiting set is spelled at one anchor, not at each member it leaves',
    run = function()
      -- Every move has its inversion, so a spelling stands at as many coords as it has
      -- members to anchor on, all of them the same intervals read from a different member.
      -- The first member to place anchors and those before it wait, so the enumeration
      -- holds a waiting set once rather than once per gauge.
      local seat  = { 0, 400, 700 }
      local whole = sonority.spellings({ 1, 2, 3 }, seat, { true, true, true },
                                       fifthsAndThirds, math.huge, 8)

      local held = {}
      for _, entry in ipairs(whole) do
        held[#entry.waiting] = (held[#entry.waiting] or 0) + 1
      end

      local pairSpellings = 0
      for _, members in ipairs{ { 1, 2 }, { 1, 3 }, { 2, 3 } } do
        pairSpellings = pairSpellings
          + #sonority.spellings(members, seat, {}, fifthsAndThirds, math.huge, 8)
      end

      t.eq(held[0], #sonority.spellings({ 1, 2, 3 }, seat, {}, fifthsAndThirds,
                                        math.huge, 8), 'the triad, spelled whole')
      t.eq(held[1], pairSpellings, 'each pair it leaves, spelled as that pair alone is')
      t.eq(held[2], 3, 'each member placed alone, stating nothing with anybody')
      t.eq(held[3], 1, 'and the one state that says nothing at all')
    end,
  },

  {
    name = 'spellings: seats and waits are read at the strand a member names',
    run = function()
      -- A sonority's members are strand indices, and everything it reads of them is
      -- indexed the same way, so the decoy seated at strand 2 is never read.
      local members, seat = { 3, 1 }, { 400, 600, 0 }
      local best = sonority.spellings(members, seat, {}, fifthsAndThirds, 12, 8)[1]
      local hand = sonority.springs(members, seat, { {}, { [5] = 1 } })

      t.eq(#best.springs, 1, 'the pair the moves tie')
      spring(best.springs[1], 3, 1, -13.69, 'the third pure below the seat of strand 1')
      spring(best.springs[1], hand[1].i, hand[1].j, hand[1].delta, 'as the springs take it by hand')

      local deferred = sonority.spellings(members, seat, { [1] = true },
                                          fifthsAndThirds, 12, 8)
      t.truthy(#deferred[1].waiting > 0, 'a member free to wait leads the list')
      t.eq(deferred[1].waiting[1], 1, 'and it is the strand mayWait named, not the position')
    end,
  },

  {
    name = 'seats: the notation gives each strand its step',
    run = function()
      local strands = struck(960, { { 0, 0, 60 }, { 4, 0, 64 }, { 7, 960, 79 } })
      t.deepEq(sonority.seats(strands, edo12), { 6000, 6400, 7900 },
               'each strand seated where its first note is written')

      -- The same notes under a scale of uneven steps, where a note seats on the step it
      -- stands nearest rather than on the step of its own index.
      local uneven = nameless{ 0, 100, 350, 700 }
      t.deepEq(sonority.seats(struck(960, { { 0, 0, 61 }, { 0, 0, 63 } }), uneven),
               { 6100, 6350 }, 'the second written on the step at 350, not on the one at 300')
    end,
  },

  {
    name = 'onsets: a member waits while an onset it sounds through is still to come',
    run = function()
      -- A rolled C minor: the C sounds through the two onsets that follow it, and the
      -- chord is complete at the third, where every member states its coords or fails.
      local passage = { strand(0, { {   0, 60, 1440 } }),
                        strand(3, { { 480, 63, 1440 } }),
                        strand(7, { { 960, 67, 1440 } }) }
      local onsets = sonority.onsets(passage, sonority.walk(passage, 5))

      t.eq(#onsets, 3, 'an onset apiece')
      t.deepEq(onsets[1].members, { 1 }, 'the C alone to begin with')
      t.deepEq(onsets[1].mayWait, { [1] = true }, 'free to wait, with two onsets left to sound through')
      t.deepEq(onsets[2].members, { 2, 1 }, 'the E flat struck against it, most recent first')
      t.deepEq(onsets[2].mayWait, { [1] = true, [2] = true }, 'both of them still to sound at the third')
      t.deepEq(onsets[3].sounding, { 3, 2, 1 }, 'where all three sound')
      t.deepEq(onsets[3].mayWait, {}, 'and none may wait, there being no onset after it')
    end,
  },

  {
    name = 'onsets: a member held by recency has stopped, so it is joined to and does not wait',
    run = function()
      local passage = { strand(0, { {    0, 60, 2880 } }),   -- held under the whole passage
                        strand(4, { {    0, 64,  960 } }),   -- stopped where the D strikes
                        strand(2, { {  960, 62, 1920 } }),
                        strand(5, { { 1920, 65, 2880 } }) }
      local onsets = sonority.onsets(passage, sonority.walk(passage, 5))

      t.deepEq(onsets[1].members, { 1, 2 }, 'the C and the E, lowest last')
      t.deepEq(onsets[1].mayWait, { [1] = true }, 'the E placing at the onset it is struck on')
      t.deepEq(onsets[2].members, { 3, 1, 2 }, 'the E a member of the second still, by recency')
      t.deepEq(onsets[2].sounding, { 3, 1 }, 'though it no longer sounds there')
      t.deepEq(onsets[2].mayWait, { [1] = true }, 'so it is joined to rather than waiting')
      t.deepEq(onsets[3].mayWait, {}, 'and the last onset holds nobody who may')
    end,
  },

  {
    name = 'search: the walk returns what an exhaustive search over its spelling lists returns',
    run = function()
      -- A ii–V–I under pure fifths and thirds, spelled 2,016 ways over its three onsets:
      -- the walk carries a capped set of partial answers through it and comes back with
      -- the best of them, at 17.51 against the walk's own 17.74 (§ The solve).
      local strands = progression{ { 62, 65, 69 }, { 55, 59, 62 }, { 60, 64, 67 } }
      local onsets, lists, seat = termsOf(strands, 5, fifthsAndThirds)

      local answer = sonority.search(onsets, lists, seat, 1, 8, 60)
      local cost, displacement = settledFrom(answer, #seat, 1, 8)
      local best = bruteSpelled(lists, #seat, 1, 8)

      nearly(cost, best.cost, 'the walk settles where the enumeration settles')
      t.deepEq(answer.choice, best.choice, 'having spelled every onset as it spells it')
      for index = 1, #strands do
        t.truthy(math.abs(displacement[index] - best.displacement[index]) < 0.01,
          'strand ' .. index .. ' standing where the enumeration stands it')
      end

      t.truthy(answer.cost > cost,
        'and the frozen past costing more than the joint relaxation that recovers it')
    end,
  },

  {
    name = 'search: carrying one answer takes the greedy road',
    run = function()
      -- The V of a septimal ii–V–I is cheapest spelled a way the I then pays for: a walk
      -- carrying one answer takes that road and comes back at 18.6590, and one carrying
      -- sixty finds the way around it at 18.3248.
      local strands = progression{ { 62, 65, 69, 72 }, { 55, 59, 62, 65 }, { 60, 64, 67, 71 } }
      local onsets, lists, seat = termsOf(strands, 5, withSevenths)

      local greedy  = sonority.search(onsets, lists, seat, 1, 8, 1)
      local carried = sonority.search(onsets, lists, seat, 1, 8, 60)

      t.truthy(settledFrom(greedy, #seat, 1, 8) > settledFrom(carried, #seat, 1, 8),
        'the road a cap of one takes costs more than the one sixty answers find')
      t.eq(greedy.choice[1], carried.choice[1], 'the two spelling the ii alike')
      t.truthy(greedy.choice[2] ~= carried.choice[2], 'and parting at the V')
    end,
  },

  {
    name = 'search: a strand that has stopped stands where the walk left it',
    run = function()
      -- The relaxation frees what the onset sounds, so a triad released as the next chord
      -- strikes is data at the cents the first onset settled it to (§ The solve).
      local strands = progression{ { 60, 64, 67 }, { 62, 65, 69 } }
      local onsets, lists, seat = termsOf(strands, 6, fifthsAndThirds)
      t.eq(#onsets[2].members, 6, 'the second onset holding all six')
      t.eq(#onsets[2].sounding, 3, 'and sounding the three that struck')

      local answer = sonority.search(onsets, lists, seat, 1, 8, 60)
      t.eq(#answer.choice, 2, 'a spelling chosen at each onset')

      local start, free = allFree(#seat)
      local opening  = { lists[1][answer.choice[1]].springs }
      local sounding = onsets[1].sounding
      local first = sonority.relax(sonority.ties(opening, sounding), 1, 8,
                                   start, sounding)
      for _, index in ipairs{ 1, 3, 5 } do
        t.eq(answer.displacement[index], first[index],
          'strand ' .. index .. ' standing exactly where the first onset put it')
      end

      -- And the hold is felt, but barely: the second onset ties all six into one spelling, so
      -- the walk has little left to give back and the joint relaxation moves the three by
      -- between 0.06¢ and 0.47¢ — under the half cent the merge treats as no difference.
      local loosened = sonority.relax(sonority.ties(answer.springs, free), 1, 8,
                                      answer.displacement, free)
      for _, index in ipairs{ 1, 3, 5 } do
        local moved = math.abs(loosened[index] - answer.displacement[index])
        t.truthy(moved > 0, 'the second chord moving strand ' .. index .. ' once it is free to')
        t.truthy(moved < 0.5, 'and by less than the merge would tell apart')
      end
    end,
  },

  {
    name = 'search: a rolled chord lands where the struck chord lands',
    run = function()
      -- The rolled C minor is charged the interval the finished chord states rather than
      -- one invented before it arrived, so it settles where the struck chord settles and
      -- pays the pair it held on the way (§ The candidates).
      local whole, standing = settledUnder(progression{ { 60, 63, 67 } }, fifthsAndThirds)
      local cost, displacement = settledUnder(rolled({ 60, 63, 67 }, 240), fifthsAndThirds)

      nearly(whole, 3.9627, 'the chord struck whole')
      nearly(cost, 7.8703, 'and the rolled chord, the pair it held charged where it places')
      for index = 1, 3 do
        t.truthy(math.abs(displacement[index] - standing[index]) < 0.25,
          'strand ' .. index .. ' standing within a quarter cent of the struck chord')
      end
    end,
  },

  {
    name = 'search: a deferral moves the charge rather than dodging it',
    run = function()
      -- Under a set holding 6/5 the opening pair can be spelled at its own onset, so the
      -- road that waits is answerable to the road that does not: what the deferral pays
      -- later is what spelling it where it stood would have paid.
      local strands = rolled({ 60, 63, 67 }, 240)
      local waited, deferred = settledUnder(strands, elevenPitches)

      local onsets, _, seat = termsOf(strands, 5, elevenPitches)
      local spelled = {}
      for i, onset in ipairs(onsets) do
        spelled[i] = sonority.spellings(onset.members, seat, {}, elevenPitches, 24, 8)
      end
      local spelt, standing = settledFrom(
        sonority.search(onsets, spelled, seat, 1, 8, 60), #seat, 1, 8)

      nearly(waited, 7.8703, 'the road that waits')
      nearly(spelt, 7.8703, 'and the road that spells the pair where it stands')
      for index = 1, 3 do
        t.truthy(math.abs(deferred[index] - standing[index]) < 0.25,
          'strand ' .. index .. ' landing alike either way')
      end
    end,
  },

  {
    name = "search: a held sonority is charged in its own onset's slot",
    run = function()
      -- The charge falls due where the sonority stands, not where the waiter lands: the
      -- pair the second onset held is a spring in the second onset's slot.
      local strands = rolled({ 60, 63, 67 }, 240)
      local onsets, lists, seat = termsOf(strands, 5, fifthsAndThirds)
      local answer = sonority.search(onsets, lists, seat, 1, 8, 60)

      t.eq(#answer.springs[1], 0, 'the lone C states nothing')
      t.eq(#answer.springs[2], 1, 'the pair the second sonority held')
      t.eq(#answer.springs[3], 3, 'and a spring per pair of the chord')
      spring(answer.springs[2][1], 2, 1, -15.64, 'the minor third the finished chord states')
    end,
  },

  {
    name = 'search: the road that pays as it goes is the road the walk keeps',
    run = function()
      -- A rolled dominant seventh under the eleven-move set. The road that staggered its
      -- waits left the second sonority spelled as two singletons, charged for neither its
      -- spring nor its box, and came back 2.32 under the road that spells as it goes, at a
      -- tuning the two agree on within 0.03¢ (§ What it costs).
      local strands = rolled({ 60, 64, 67, 70 }, 240)
      local onsets, lists, seat = termsOf(strands, 5, elevenPitches)
      local answer = sonority.search(onsets, lists, seat, 1, 8, 60)

      nearly(answer.cost, 13.2165, 'the walk keeping the road that has paid')
      t.eq(next(answer.held), nil, 'and nothing left owing at the end of the walk')
      t.eq(#answer.springs[2], 1, 'the pair of the second sonority charged where it stands')
    end,
  },

  {
    name = 'search: a wait resolving to what its sonority offered is no second road',
    run = function()
      -- Under a set holding 6/5 the opening pair can be spelled where it stands, so a road
      -- that defers it comes back with coords the second onset itself returned and is
      -- refused; what the walk keeps spells each onset as it reaches it (§ The candidates).
      local strands = rolled({ 60, 63, 67 }, 240)
      local onsets, lists, seat = termsOf(strands, 5, elevenPitches)
      local answer = sonority.search(onsets, lists, seat, 1, 8, 60)

      for i, choice in ipairs(answer.choice) do
        t.eq(#lists[i][choice].waiting, 0, 'onset ' .. i .. ' spelling what it holds')
      end
      nearly(answer.cost, 7.8703, 'at the cost the road that waited reached')
    end,
  },

  {
    name = 'search: a wait that lands tied to nothing refuses the road that took it',
    run = function()
      -- A released chord leaves its bass to the sonority that follows, so at arity two it is
      -- the upper note that falls out and the bass that sustains into the next. The C waits
      -- through that onset and lands beside a G its own sonority never held: the completion
      -- ties it to nobody, so it states no interval there and is charged none, which is the
      -- price the refusal puts at everything (§ The candidates).
      local strands = sonority.strands({ event(0, 76, 480), event(0, 60, 960),
                                         event(480, 67, 960) }, pitchClass)
      local onsets, lists, seat = termsOf(strands, 2, fifthsAndThirds)
      t.deepEq(onsets[2].members, { 3, 1 }, 'the released upper note gone by the second onset')

      local deferring
      for k, spelling in ipairs(lists[1]) do
        if #spelling.waiting > 0 then deferring = k end
      end
      t.truthy(deferring, 'the first sonority offering a road that defers the pair')
      t.eq(lists[1][deferring].box, 0, 'which states nothing and so carries no box at all')

      local answer = sonority.search(onsets, lists, seat, 1, 8, 60)
      t.truthy(answer.choice[1] ~= deferring, 'the walk refusing it rather than taking it free')
      nearly(settledFrom(answer, #seat, 1, 8), 3.9592,
        'and spelling the pair where it stands, at what that road costs')
    end,
  },

  {
    name = 'search: the cut runs over the answers that owe and the answers that have paid',
    run = function()
      -- A road that owes has moved charge out of its running score, so ranked against one
      -- that has paid it takes the whole cut, and every resolution it has left is refused: a
      -- pool apiece keeps a road the refusal cannot touch, at any cap (§ The solve).
      local strands = rolled({ 60, 63, 67 }, 240)
      local onsets, lists, seat = termsOf(strands, 5, elevenPitches)

      local greedy = sonority.search(onsets, lists, seat, 1, 8, 1)
      t.truthy(greedy, 'a walk carrying one answer apiece still answers a rolled chord')
      t.truthy(greedy.cost >= sonority.search(onsets, lists, seat, 1, 8, 60).cost,
        'and pays for the narrower cut rather than escaping it')
    end,
  },

  {
    name = 'solveToMoves: the take settles where § Measured settles it',
    run = function()
      -- Everything the facility does, in one call: the seats the notation states, the
      -- spellings the beam chooses, the walk over them, and the joint relaxation that
      -- settles the winner.
      local cents = sonority.solveToMoves(take, 5, 1, edo12, elevenPitches, 8)
      t.truthy(cents, 'the take is answered')

      local seat = sonority.seats(take, edo12)
      t.eq(#cents, #take, 'a tuning per strand, forty of them')

      -- The pull charges a cent either way alike, so a passage whose strands are all free
      -- to move settles with its body where it was written: shift every displacement by
      -- the same amount and the springs are unmoved while the pull rises.
      local total, worst, signed = 0, 0, 0
      for index = 1, #take do
        local moved = cents[index] - seat[index]
        total, worst = total + math.abs(moved), math.max(worst, math.abs(moved))
        signed = signed + moved
      end
      near(total / #take, 6.63, 'the mean displacement of § Measured')
      t.truthy(worst < 11.4, 'and no note past 11.4 cents: ' .. string.format('%.2f', worst))
      t.truthy(math.abs(signed) < 0.1, 'the forty displacements summing to nothing: '
        .. string.format('%.4f', signed))
    end,
  },

  {
    name = "solveToMoves: a chord stands at the target's intervals, and is priced where it cannot",
    run = function()
      -- A struck C major under pure fifths and thirds: the springs stretch the two
      -- intervals by under a cent between them, and the pull seats the chord where the
      -- three displacements together cost least.
      local cents = sonority.solveToMoves(progression{ { 60, 64, 67 } }, 5, 1, edo12,
                                          fifthsAndThirds, 8)
      t.truthy(cents, 'the chord is answered')
      near(cents[1] - 6000, 3.75, 'the C carried off its seat by the pull')
      near(cents[2] - cents[1], 386.86, 'the third stretched from 386.31')
      near(cents[3] - cents[1], 701.88, 'and the fifth narrowed from 701.96')

      -- No chain of moves reaches the tritone, so the diminished triad is spelled at what
      -- the set can name and priced for the stretch rather than refusing the passage that
      -- holds it: the C settles sixty cents flat, and reads back on the B below it.
      local diminished = sonority.solveToMoves(progression{ { 60, 63, 66 } }, 5, 1, edo12,
                                               fifthsAndThirds, 8)
      t.truthy(diminished, 'while a diminished triad under the same set is answered')
      nearly(diminished[1], 5939.7534, 'the C carried past the step below it')
      nearly(diminished[2], 6322.6145, 'the E flat above it')
      nearly(diminished[3], 6637.6302, 'and the G flat above that')

      local signed = (diminished[1] - 6000) + (diminished[2] - 6300) + (diminished[3] - 6600)
      t.truthy(math.abs(signed) < 0.01, 'the three displacements summing to nothing: '
        .. string.format('%.4f', signed))
    end,
  },

  {
    name = 'solveToMoves: a notation of finer steps settles the chord the same',
    run = function()
      -- The two notations seat these three notes alike and space their neighbours at fifty
      -- cents against a hundred. A pull taken in half-windows charged the finer notation
      -- four times over for the same drift, and settled the chord elsewhere; taken in
      -- cents, the notation states the seats and measures nothing.
      local chord  = progression{ { 60, 64, 67 } }
      local coarse = sonority.solveToMoves(chord, 5, 1, edo12, fifthsAndThirds, 8)
      local fine   = sonority.solveToMoves(chord, 5, 1, edo24, fifthsAndThirds, 8)

      t.truthy(fine, 'the chord is answered under the finer notation')
      for index = 1, 3 do
        t.eq(fine[index], coarse[index],
          'strand ' .. index .. ' settling where the coarser notation settles it')
      end
    end,
  },

  {
    name = 'strands: a class chains through its overlaps and splits where they stop',
    run = function()
      local held  = event(0,   60, 480)
      local over  = event(240, 72, 720)
      local late  = event(600, 60, 900)
      local after = event(900, 60, 1000)

      local strands = sonority.strands({ after, over, late, held }, pitchClass)
      t.eq(#strands, 2, 'the chain, and the note struck where it is released')
      t.eq(#strands[1].notes, 3, 'held reaches over, and over reaches late')
      t.eq(strands[1].notes[1], held, 'the notes are the events themselves, in strike order')
      t.eq(strands[1].notes[2], over)
      t.eq(strands[1].notes[3], late)
      t.eq(strands[1].class, 0, 'under the class they share')
      t.eq(strands[1].shortlist, nil, 'whose shortlist is the command\'s to fill')
      t.eq(#strands[2].notes, 1, 'a note struck at a release overlaps nothing')
      t.eq(strands[2].notes[1], after)
    end,
  },

  {
    name = 'strands: classes never share one, and the order does not follow the input',
    run = function()
      local c     = event(0,   60, 960)
      local e     = event(0,   64, 960)
      local g     = event(480, 67, 960)
      local eHigh = event(960, 76, 1200)

      local strands = sonority.strands({ g, eHigh, e, c }, pitchClass)
      t.eq(#strands, 4, 'three classes sounding together, and E again after them')
      t.eq(strands[1].class, 0); t.eq(strands[1].notes[1], c)
      t.eq(strands[2].class, 4); t.eq(strands[2].notes[1], e)
      t.eq(strands[3].class, 4); t.eq(strands[3].notes[1], eHigh)
      t.eq(strands[4].class, 7); t.eq(strands[4].notes[1], g)
    end,
  },

  {
    name = 'a block chord and an arpeggio of it hand back the same set',
    run = function()
      local chord  = struck(240, { { 0, 0, 60 }, { 4, 0, 64 }, { 7, 0, 67 }, { 11, 0, 71 } })
      local spread = struck(240, { { 0, 0, 60 }, { 4, 240, 64 }, { 7, 480, 67 }, { 11, 720, 71 } })
      local block, arpeggio = sonority.walk(chord, 5), sonority.walk(spread, 5)

      t.eq(#block, 1, 'one onset, one sonority')
      t.eq(#arpeggio, 4, 'four onsets, four sonorities')
      t.bagEq(classesAt(chord, block[1]), classesAt(spread, arpeggio[4]),
        'the chord spread out is the chord')
      t.eq(arpeggio[4].ppq, 720, 'each sonority is stamped with its onset')
      t.eq(#arpeggio[1].strands, 1, 'and the early ones hold only what has struck')
    end,
  },

  {
    name = 'at n one above the arity consecutive sonorities still overlap',
    run = function()
      -- Listed bass first, so a survivor chosen by position would be the G.
      local strands = struck(960, {
        { 0, 0, 60 }, { 4, 0, 64 }, { 11, 0, 71 }, { 7, 0, 67 },
        { 2, 960, 62 }, { 5, 960, 65 }, { 9, 960, 69 }, { 10, 960, 70 },
      })
      local walked = sonority.walk(strands, 5)

      t.eq(#walked, 2, 'two onsets')
      t.eq(#walked[2].strands, 5, 'four struck, one carried over')
      t.bagEq(classesAt(strands, walked[2]), { 2, 5, 9, 10, 0 },
        'the second chord and the bass of the first')
      t.eq(strands[walked[2].strands[5]].class, 0, 'which stands as the oldest entry')
    end,
  },

  {
    name = 'a repeated note and an octave doubling each spend one entry',
    run = function()
      local doubled = {
        strand(0, { { 0, 60, 240 }, { 0, 72, 240 } }), strand(4, { { 0, 64, 240 } }),
        strand(7, { { 0, 67, 240 } }), strand(11, { { 0, 71, 240 } }),
        strand(2, { { 0, 62, 240 } }),
      }
      t.eq(#sonority.walk(doubled, 5)[1].strands, 5, 'the doubling spends one of the five')

      local restruck = { strand(0, { { 0, 60, 240 }, { 480, 60, 720 } }),
                         strand(4, { { 240, 64, 480 } }) }
      local walked   = sonority.walk(restruck, 2)
      t.eq(#walked, 3, 'three strikes, three sonorities')
      t.bagEq(classesAt(restruck, walked[3]), { 0, 4 }, 'the restrike displaces nothing')
      t.eq(restruck[walked[3].strands[1]].class, 0, 'and stands as the most recent entry')
    end,
  },

  {
    name = 'a later strand of a class replaces the earlier one',
    run = function()
      local strands = struck(240, { { 0, 0, 60 }, { 4, 240, 64 }, { 7, 480, 67 },
                                    { 0, 720, 72 } })
      local walked  = sonority.walk(strands, 5)

      t.eq(#walked[3].strands, 3, 'three classes before the C returns')
      t.eq(#walked[4].strands, 3, 'and three after it, though five would fit')
      t.eq(walked[4].strands[1], 4, 'the class stands as the strand that struck last')
      for _, index in ipairs(walked[4].strands) do
        t.truthy(index ~= 1, 'the C that struck first has left the sonority')
      end
    end,
  },

  {
    name = 'a class still sounding stands where the last n struck have dropped it',
    run = function()
      local held    = underRun(3360)
      local shorter = underRun(480)
      local walked, cut = sonority.walk(held, 5), sonority.walk(shorter, 5)

      t.eq(#walked, 6, 'six strikes, six sonorities')
      t.eq(#walked[6].strands, 6, 'five struck and the B♭ sounding under them')
      t.bagEq(classesAt(held, walked[6]), { 5, 4, 0, 7, 11, 10 }, 'the run and the hold')
      t.eq(held[walked[6].strands[6]].class, 10, 'the hold standing as the oldest entry')

      t.eq(#cut[6].strands, 5, 'released where the next strikes, it drops out')
      t.bagEq(classesAt(shorter, cut[6]), { 5, 4, 0, 7, 11 }, 'leaving the run alone')
    end,
  },

  {
    name = 'the box is summed over the walk rather than over the onsets',
    run = function()
      local strands, choice = triads(0, 0)
      near(sonority.cost(strands, 3, 0, choice), 7.81, 'two triads, neither straddling')
      near(sonority.cost(strands, 5, 0, choice), 10.98, 'the second holding the C and E too')
    end,
  },

  {
    name = "the pull is the strength times the square of a strand's strain",
    run = function()
      local strands, choice = triads(0.2, 0.4)
      near(sonority.cost(strands, 3, 0, choice), 7.81, 'at no strength the box stands alone')
      near(sonority.cost(strands, 3, 3, choice), 8.41, 'and three times 0.04 + 0.16 above it')
    end,
  },

  {
    name = 'the pull is counted once per strand however many notes write it',
    run = function()
      local plain, choice = fixed(960, {
        { 0, 0, 60, just.C, 0.5 }, { 4, 0, 64, just.E, 0 }, { 7, 0, 67, just.G, 0 },
      })
      near(sonority.cost(plain, 3, 1, choice), 4.16, 'the triad and the one strain in it')

      local doubled = {
        placed(0, { { 0, 60, 960 }, { 0, 72, 960 } }, { { coords = just.C, strain = 0.5 } }),
        plain[2], plain[3],
      }
      t.eq(sonority.cost(doubled, 3, 1, choice), sonority.cost(plain, 3, 1, choice),
        'the octave doubling changes no answer')
    end,
  },

  {
    name = "the C7's two sevenths cross at a pull of 0.95",
    run = function()
      local strands, choice = fixed(960, {
        { 0, 0, 60, just.C, 0 },
        { 4, 0, 64, just.E, strainOf(5, 4, 400) },
        { 7, 0, 67, just.G, strainOf(3, 2, 700) },
      })
      strands[4] = placed(10, { { 0, 70, 960 } }, {
        { coords = just.septimal,    strain = strainOf(7,  4, 1000) },
        { coords = just.pythagorean, strain = strainOf(16, 9, 1000) },
      })
      choice[4] = 1
      local otonal, pythagorean = choice, { 1, 1, 1, 2 }

      near(sonority.cost(strands, 5, 0, otonal), 6.71, 'the otonal 4:5:6:7')
      near(sonority.cost(strands, 5, 0, pythagorean), 7.08, 'and 16/9 above it by 0.36 of box')
      t.truthy(sonority.cost(strands, 5, 0.94, otonal)
             < sonority.cost(strands, 5, 0.94, pythagorean),
        'below the crossing the chord keeps its septimal seventh')
      t.truthy(sonority.cost(strands, 5, 0.96, pythagorean)
             < sonority.cost(strands, 5, 0.96, otonal),
        'and above it gives it up for 27¢ of fidelity')
    end,
  },

  {
    name = 'the solve is the minimum exhaustive enumeration finds',
    run = function()
      for _, layout in ipairs(layouts) do
        for _, n in ipairs{ 2, 3, 4 } do
          for _, strength in ipairs{ 0, 1, 3 } do
            local choice = sonority.solveToPoints(layout.strands, n, strength)
            exactly(sonority.cost(layout.strands, n, strength, choice),
              bruteMinimum(layout.strands, n, strength),
              string.format('%s at n=%d, strength %d', layout.name, n, strength))
          end
        end
      end
    end,
  },

  {
    name = 'a shortlist of one is fixed and still contributes its coords',
    run = function()
      local third = placed(4, { { 0, 64, 960 } }, {
        { coords = just.E,      strain = strainOf(5,  4, 400) },
        { coords = { [3] = 4 }, strain = strainOf(81, 64, 400) },
      })

      for _, strength in ipairs{ 0.5, 1, 3 } do
        t.eq(sonority.solveToPoints({ third }, 4, strength)[1], 2,
          'alone, the pull takes the Pythagorean third at strength ' .. strength)
      end

      local anchored = fixed(960, { { 0, 0, 60, just.C, 0 }, { 7, 0, 67, just.G, 0 } })
      anchored[3] = third
      local pure, pythagorean = { 1, 1, 1 }, { 1, 1, 2 }
      nearly(sonority.cost(anchored, 4, 0, pythagorean) - sonority.cost(anchored, 4, 0, pure),
        2.4330, 'the box saving the fixed C and G buy')
      nearly((sonority.cost(anchored, 4, 1, pure)        - sonority.cost(anchored, 4, 0, pure))
           - (sonority.cost(anchored, 4, 1, pythagorean) - sonority.cost(anchored, 4, 0, pythagorean)),
        0.0505, 'against the pull it costs at strength 1')
      t.eq(sonority.solveToPoints(anchored, 4, 1)[3], 1, 'so in the chord it takes 5/4')
    end,
  },

  {
    name = 'a held strand bends the harmony to it',
    run = function()
      local held = dorian{ { 0, 1920 } }
      for _, strength in ipairs{ 0, 1, 2 } do
        t.eq(sonority.solveToPoints(held, 4, strength)[5], 1,
          'the D held across the change takes 10/9 at strength ' .. strength)
      end
      local heldChoice, heldWalk = sonority.solveToPoints(held, 4, 0), sonority.walk(held, 4)
      nearly(scoreAt(held, heldChoice, heldWalk[1]), 3.907, 'the chord the D is chosen in')
      nearly(scoreAt(held, heldChoice, heldWalk[2]), 7.077, 'and the one that pays for it')
      nearly(sonority.cost(held, 4, 0, heldChoice), 10.9837, 'the passage held')

      local restruck   = dorian{ { 0, 960 }, { 960, 1920 } }
      local freeChoice = sonority.solveToPoints(restruck, 4, 0)
      local freeWalk   = sonority.walk(restruck, 4)
      t.eq(freeChoice[6], 2, 'a D struck again in the second chord takes 9/8')
      nearly(scoreAt(restruck, freeChoice, freeWalk[2]), 6.340, 'which is what the chord wants')
      nearly(sonority.cost(restruck, 4, 0, freeChoice), 10.2467, 'the passage restruck')
      nearly(sonority.cost(held, 4, 0, heldChoice) - sonority.cost(restruck, 4, 0, freeChoice),
        0.7370, 'so the hold costs the second chord a 5/3')
      t.bagEq(classesAt(held, heldWalk[2]), classesAt(restruck, freeWalk[2]),
        'the same four classes standing in both, only the D tuned differently')
    end,
  },

  {
    name = 'behind a run of fixed classes the answer hangs on the hold',
    run = function()
      t.eq(sonority.solveToPoints(underRun(3360), 5, 0.5)[1], 1,
        'the B♭ sounding under the run takes 16/9')
      t.eq(sonority.solveToPoints(underRun(480), 5, 0.5)[1], 2,
        'and released as the run begins takes 9/5, a syntonic comma away')
    end,
  },

  {
    name = "the C7 sounding alone crosses at a pull of 0.95",
    run = function()
      local strands = seventh()
      for _, strength in ipairs{ 0, 0.5, 0.94 } do
        t.eq(sonority.solveToPoints(strands, 5, strength)[4], 1,
          'the otonal 4:5:6:7 at strength ' .. strength)
      end
      for _, strength in ipairs{ 0.96, 1, 2 } do
        t.eq(sonority.solveToPoints(strands, 5, strength)[4], 2,
          'and 16/9 above the crossing at strength ' .. strength)
      end

      local boxSaved  = sonority.cost(strands, 5, 0, c7Pythagorean)
                      - sonority.cost(strands, 5, 0, c7Septimal)
      local pullSaved = (sonority.cost(strands, 5, 1, c7Septimal)
                       - sonority.cost(strands, 5, 0, c7Septimal))
                      - (sonority.cost(strands, 5, 1, c7Pythagorean)
                       - sonority.cost(strands, 5, 0, c7Pythagorean))
      nearly(boxSaved, 0.3626, 'the box the septimal seventh buys')
      nearly(50 * (strainOf(7, 4, 1000) - strainOf(16, 9, 1000)), 27.264,
        'against the fidelity it spends, in cents')
      nearly(boxSaved / pullSaved, 0.9476, 'so the two cross here')
    end,
  },

  {
    name = 'the rest of the chord stands still, and the third seventh is dominated',
    run = function()
      local strands = seventh()
      for _, strength in ipairs{ 0, 0.94, 0.96, 2, 6 } do
        local choice = sonority.solveToPoints(strands, 5, strength)
        t.eq(choice[2], 1, '5/4 rather than 9/7 at strength ' .. strength)
        t.truthy(choice[4] ~= 3, 'and 9/5 elected by no pull, at strength ' .. strength)
      end

      -- 9/5 spans more than 16/9 and sits further from the written step besides,
      -- so it loses on both terms and no strength turns the trade its way.
      t.truthy(sonority.cost(strands, 5, 0, { 1, 1, 1, 3 })
             > sonority.cost(strands, 5, 0, c7Pythagorean), 'it costs more box')
      t.truthy(strainOf(9, 5, 1000) > strainOf(16, 9, 1000), 'and more strain')
    end,
  },

  {
    name = 'resolving to F–A–C the seventh takes the Pythagorean under any pull',
    run = function()
      local strands = resolving()
      for _, strength in ipairs{ 0, 0.5, 0.94, 2 } do
        t.eq(sonority.solveToPoints(strands, 6, strength)[4], 2, '16/9 at strength ' .. strength)
      end

      local walked = sonority.walk(strands, 6)
      t.bagEq(classesAt(strands, walked[2]), { 5, 9, 0, 4, 7, 10 },
        'the resolution standing with the seventh chord whole behind it')
      nearly(scoreAt(strands, resolvingSeptimal,  walked[2])
           - scoreAt(strands, resolvingPythagorean, walked[2]),
        1.2224, 'the box the resolution saves by it')
      nearly(scoreAt(strands, resolvingPythagorean, walked[1])
           - scoreAt(strands, resolvingSeptimal,    walked[1]),
        0.3626, 'against what the seventh chord pays for it')
      t.truthy(strainOf(16, 9, 1000) < strainOf(7, 4, 1000),
        'and it strains less too, so there is nothing to cross')
    end,
  },

  {
    name = "at n one above the arity the resolution reads the seventh chord's bass alone",
    run = function()
      local strands = resolving()
      local walked  = sonority.walk(strands, 5)
      t.bagEq(classesAt(strands, walked[2]), { 5, 9, 0, 4, 7 },
        'the seventh having left the window by the time F–A–C strikes')
      exactly(scoreAt(strands, resolvingSeptimal,   walked[2]),
              scoreAt(strands, resolvingPythagorean, walked[2]),
        'so the resolution scores the same under either seventh')

      local alone = seventh()
      exactly(sonority.cost(strands, 5, 0, resolvingPythagorean)
            - sonority.cost(strands, 5, 0, resolvingSeptimal),
              sonority.cost(alone,   5, 0, c7Pythagorean)
            - sonority.cost(alone,   5, 0, c7Septimal),
        'leaving exactly the trade the chord made alone')
      t.eq(sonority.solveToPoints(strands, 5, 0.94)[4], 1, 'and the crossing where it was')
      t.eq(sonority.solveToPoints(strands, 5, 0.96)[4], 2, 'on both sides of it')
    end,
  },

  {
    name = 'an exact tie goes to the first candidate rather than to table order',
    run = function()
      -- A widened class reads as a point and its inversion (design/adaptive-tuning.md
      -- § What the solver takes), which a bare fifth scores alike, so four strikes of
      -- one tie sixteen ways.
      local tied = { placed(0, { { 0, 60, 3840 } }, { { coords = just.C, strain = 0 } }) }
      for i = 1, 4 do
        tied[i + 1] = placed(6, { { (i - 1) * 960, 66, i * 960 } }, {
          { coords = { [3] = -1 }, strain = 2.0391 },
          { coords = { [3] =  1 }, strain = 2.0391 },
        })
      end

      local best, minimisers = bruteMinimum(tied, 4, 1), 0
      everyChoice(tied, function(choice)
        if sonority.cost(tied, 4, 1, choice) == best then minimisers = minimisers + 1 end
      end)
      t.eq(minimisers, 16, 'every reading of the four scores the same')
      t.deepEq(sonority.solveToPoints(tied, 4, 1), { 1, 1, 1, 1, 1 },
        'and the first candidate takes each of them')
    end,
  },

  {
    name = 'an empty shortlist and an unaffordable solve are both refused',
    run = function()
      local strands = fixed(960, { { 0, 0, 60, just.C, 0 }, { 4, 0, 64, just.E, 0 } })
      strands[2].shortlist = {}
      local ok, err = pcall(function() sonority.solveToPoints(strands, 4, 1) end)
      t.falsy(ok, 'a strand with nowhere to go raises')
      t.truthy(tostring(err):find('strand 2', 1, true), 'naming it: ' .. tostring(err))

      local wide = {}
      for i = 1, 12 do wide[i] = placed(i - 1, { { 0, 72 - i, 960 } }, threeWays) end
      local affordable, why = pcall(function() sonority.solveToPoints(wide, 12, 1) end)
      t.falsy(affordable, 'twelve strands of three candidates at n=12 raises')
      t.truthy(tostring(why):find('531441', 1, true), 'naming the count: ' .. tostring(why))
    end,
  },
}
