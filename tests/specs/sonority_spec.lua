-- Pins the box score of design/adaptive-tuning.md § What "in tune" means: the
-- 5-limit column of § Choosing the target chooses the theory, its identity with
-- the Tenney height of the sonority's lcm/gcd, and the two invariances that let
-- the model hold no reference pitch.
--
-- Pins the walk of § The model too: which strands are current at each onset,
-- distinctness by step-class, and the bass as the class a released chord
-- leaves behind it.
--
-- Pins the objective the solve minimises: the box summed over the walk's
-- sonorities, and the pull counted once per strand (§ Harmonic lock).
--
-- Pins the solve of § Solving it: that the DP returns the exact minimum of that
-- objective, held against exhaustive enumeration; that a strand held across a
-- chord change bends the harmony to it (§ The strand); and the two guards.
--
-- Pins the pull's scale on the calibration C7 (§ Harmonic lock): the crossing
-- from the otonal seventh to the Pythagorean, and what resolving the chord to
-- F–A–C does to that trade (§ The model).

local t        = require('support')
local sonority = require('sonority')

-- The doc's figures are given to 2dp.
local function near(actual, expected, why)
  t.truthy(math.abs(actual - expected) < 0.005, string.format(
    '%s: expected %.2f, got %.4f', why or 'score', expected, actual))
end

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

-- A strand as the walk reads it: notes carrying when they are struck and how
-- low they sit, under the step-class they share. The shortlist is the solve's
-- business rather than the walk's, so these carry none.
local function strand(class, notes)
  local built = {}
  for i, note in ipairs(notes) do built[i] = { ppq = note[1], pitch = note[2] } end
  return { class = class, notes = built }
end

-- Strands of one note each, given as { class, ppq, pitch }.
local function struck(list)
  local strands = {}
  for i, note in ipairs(list) do strands[i] = strand(note[1], { { note[2], note[3] } }) end
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
-- strain }, with the choice that takes each strand's only candidate.
local function fixed(list)
  local strands, choice = {}, {}
  for i, entry in ipairs(list) do
    strands[i] = placed(entry[1], { { entry[2], entry[3] } },
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
  return fixed{
    { 0,   0, 60, just.C,      cStrain }, { 4, 0, 64, just.E,       0 },
    { 7,   0, 67, just.G,      0       },
    { 2, 960, 62, just.D,      dStrain }, { 6, 960, 66, just.Fsharp, 0 },
    { 9, 960, 69, just.A,      0       },
  }
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

-- Strands given as { class, {{ppq,pitch},..} }, each taking threeWays.
local function laidOut(list)
  local strands = {}
  for i, entry in ipairs(list) do strands[i] = placed(entry[1], entry[2], threeWays) end
  return strands
end

-- The shapes the schedule has to get right: strands born together and born
-- apart, a strand outliving the window, and one that no sonority ever holds.
local layouts = {
  { name    = 'a block chord',
    strands = laidOut{ { 0, { { 0, 60 } } }, { 4, { { 0, 64 } } }, { 7, { { 0, 67 } } } } },

  { name    = 'the same chord arpeggiated',
    strands = laidOut{ { 0, { { 0, 60 } } }, { 4, { { 240, 64 } } }, { 7, { { 480, 67 } } } } },

  { name    = 'a strand restruck across another strand\'s onset',
    strands = laidOut{ { 0, { { 0, 60 }, { 480, 60 } } }, { 4, { { 240, 64 } } } } },

  { name    = 'a strand striking at the first onset and the last',
    strands = laidOut{ { 0, { { 0, 60 }, { 960, 60 } } }, { 4, { { 240, 64 } } },
                       { 7, { { 480, 67 } } }, { 11, { { 720, 71 } } } } },

  { name    = 'an onset wider than n',
    strands = laidOut{ { 0, { { 0, 60 } } }, { 4, { { 0, 64 } } },
                       { 7, { { 0, 67 } } }, { 11, { { 0, 71 } } } } },

  { name    = 'two strands of one class, disjoint in time',
    strands = laidOut{ { 0, { { 0, 60 } } }, { 4, { { 0, 64 } } }, { 0, { { 960, 72 } } } } },
}

-- The ninth of § The strand, with everything but the D fixed: the D is asked
-- to serve a G–B♭–D–F it is struck before, and the onsets it strikes at say
-- whether it must hold one tuning across the change or may take two.
local dorianD = {
  { coords = { [3] = -2, [5] = 1 }, strain = strainOf(10, 9, 200) },
  { coords = { [3] = 2 },           strain = strainOf(9,  8, 200) },
}

local function dorian(dOnsets)
  local strands = fixed{
    { 5,    0, 65, { [3] = -1 },          strainOf(4,  3,  500) },
    { 9,    0, 69, { [3] = -1, [5] = 1 }, strainOf(5,  3,  900) },
    { 7,  960, 55, { [3] = 1 },           strainOf(3,  2,  700) },
    { 10, 960, 58, { [3] = -2 },          strainOf(16, 9, 1000) },
  }
  for i, ppq in ipairs(dOnsets) do
    strands[4 + i] = placed(2, { { ppq, 62 } }, dorianD)
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

local function fromDiamond(class, ppq, pitch, step)
  local candidates = {}
  for i, point in ipairs(diamond[step]) do
    candidates[i] = { coords = point[1], strain = strainOf(point[2], point[3], point[4]) }
  end
  return placed(class, { { ppq, pitch } }, candidates)
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
    name = 'a block chord and an arpeggio of it hand back the same set',
    run = function()
      local chord  = struck{ { 0, 0, 60 }, { 4, 0, 64 }, { 7, 0, 67 }, { 11, 0, 71 } }
      local spread = struck{ { 0, 0, 60 }, { 4, 240, 64 }, { 7, 480, 67 }, { 11, 720, 71 } }
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
      local strands = struck{
        { 0, 0, 60 }, { 4, 0, 64 }, { 11, 0, 71 }, { 7, 0, 67 },
        { 2, 960, 62 }, { 5, 960, 65 }, { 9, 960, 69 }, { 10, 960, 70 },
      }
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
        strand(0, { { 0, 60 }, { 0, 72 } }), strand(4, { { 0, 64 } }),
        strand(7, { { 0, 67 } }), strand(11, { { 0, 71 } }), strand(2, { { 0, 62 } }),
      }
      t.eq(#sonority.walk(doubled, 5)[1].strands, 5, 'the doubling spends one of the five')

      local restruck = { strand(0, { { 0, 60 }, { 480, 60 } }), strand(4, { { 240, 64 } }) }
      local walked   = sonority.walk(restruck, 2)
      t.eq(#walked, 3, 'three strikes, three sonorities')
      t.bagEq(classesAt(restruck, walked[3]), { 0, 4 }, 'the restrike displaces nothing')
      t.eq(restruck[walked[3].strands[1]].class, 0, 'and stands as the most recent entry')
    end,
  },

  {
    name = 'a later strand of a class replaces the earlier one',
    run = function()
      local strands = struck{ { 0, 0, 60 }, { 4, 240, 64 }, { 7, 480, 67 }, { 0, 720, 72 } }
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
      local plain, choice = fixed{
        { 0, 0, 60, just.C, 0.5 }, { 4, 0, 64, just.E, 0 }, { 7, 0, 67, just.G, 0 },
      }
      near(sonority.cost(plain, 3, 1, choice), 4.16, 'the triad and the one strain in it')

      local doubled = {
        placed(0, { { 0, 60 }, { 0, 72 } }, { { coords = just.C, strain = 0.5 } }),
        plain[2], plain[3],
      }
      t.eq(sonority.cost(doubled, 3, 1, choice), sonority.cost(plain, 3, 1, choice),
        'the octave doubling changes no answer')
    end,
  },

  {
    name = "the C7's two sevenths cross at a pull of 0.95",
    run = function()
      local strands, choice = fixed{
        { 0, 0, 60, just.C, 0 },
        { 4, 0, 64, just.E, strainOf(5, 4, 400) },
        { 7, 0, 67, just.G, strainOf(3, 2, 700) },
      }
      strands[4] = placed(10, { { 0, 70 } }, {
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
            local choice = sonority.solve(layout.strands, n, strength)
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
      local third = placed(4, { { 0, 64 } }, {
        { coords = just.E,      strain = strainOf(5,  4, 400) },
        { coords = { [3] = 4 }, strain = strainOf(81, 64, 400) },
      })

      for _, strength in ipairs{ 0.5, 1, 3 } do
        t.eq(sonority.solve({ third }, 4, strength)[1], 2,
          'alone, the pull takes the Pythagorean third at strength ' .. strength)
      end

      local anchored = fixed{ { 0, 0, 60, just.C, 0 }, { 7, 0, 67, just.G, 0 } }
      anchored[3] = third
      local pure, pythagorean = { 1, 1, 1 }, { 1, 1, 2 }
      nearly(sonority.cost(anchored, 4, 0, pythagorean) - sonority.cost(anchored, 4, 0, pure),
        2.4330, 'the box saving the fixed C and G buy')
      nearly((sonority.cost(anchored, 4, 1, pure)        - sonority.cost(anchored, 4, 0, pure))
           - (sonority.cost(anchored, 4, 1, pythagorean) - sonority.cost(anchored, 4, 0, pythagorean)),
        0.0505, 'against the pull it costs at strength 1')
      t.eq(sonority.solve(anchored, 4, 1)[3], 1, 'so in the chord it takes 5/4')
    end,
  },

  {
    name = 'a held strand bends the harmony to it',
    run = function()
      local held = dorian{ 0 }
      for _, strength in ipairs{ 0, 1, 2 } do
        t.eq(sonority.solve(held, 4, strength)[5], 1,
          'the D held across the change takes 10/9 at strength ' .. strength)
      end
      local heldChoice, heldWalk = sonority.solve(held, 4, 0), sonority.walk(held, 4)
      nearly(scoreAt(held, heldChoice, heldWalk[1]), 3.907, 'the chord the D is chosen in')
      nearly(scoreAt(held, heldChoice, heldWalk[2]), 7.077, 'and the one that pays for it')
      nearly(sonority.cost(held, 4, 0, heldChoice), 10.9837, 'the passage held')

      local restruck   = dorian{ 0, 960 }
      local freeChoice = sonority.solve(restruck, 4, 0)
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
    name = "the C7 sounding alone crosses at a pull of 0.95",
    run = function()
      local strands = seventh()
      for _, strength in ipairs{ 0, 0.5, 0.94 } do
        t.eq(sonority.solve(strands, 5, strength)[4], 1,
          'the otonal 4:5:6:7 at strength ' .. strength)
      end
      for _, strength in ipairs{ 0.96, 1, 2 } do
        t.eq(sonority.solve(strands, 5, strength)[4], 2,
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
        local choice = sonority.solve(strands, 5, strength)
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
        t.eq(sonority.solve(strands, 6, strength)[4], 2, '16/9 at strength ' .. strength)
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
      t.eq(sonority.solve(strands, 5, 0.94)[4], 1, 'and the crossing where it was')
      t.eq(sonority.solve(strands, 5, 0.96)[4], 2, 'on both sides of it')
    end,
  },

  {
    name = 'an empty shortlist and an unaffordable solve are both refused',
    run = function()
      local strands = fixed{ { 0, 0, 60, just.C, 0 }, { 4, 0, 64, just.E, 0 } }
      strands[2].shortlist = {}
      local ok, err = pcall(function() sonority.solve(strands, 4, 1) end)
      t.falsy(ok, 'a strand with nowhere to go raises')
      t.truthy(tostring(err):find('strand 2', 1, true), 'naming it: ' .. tostring(err))

      local wide = {}
      for i = 1, 12 do wide[i] = placed(i - 1, { { 0, 72 - i } }, threeWays) end
      local affordable, why = pcall(function() sonority.solve(wide, 12, 1) end)
      t.falsy(affordable, 'twelve strands of three candidates at n=12 raises')
      t.truthy(tostring(why):find('531441', 1, true), 'naming the count: ' .. tostring(why))
    end,
  },
}
