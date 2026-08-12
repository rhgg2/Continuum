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
}
