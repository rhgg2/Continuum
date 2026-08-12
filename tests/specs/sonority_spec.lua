-- Pins the box score of design/adaptive-tuning.md § What "in tune" means: the
-- 5-limit column of § Choosing the target chooses the theory, its identity with
-- the Tenney height of the sonority's lcm/gcd, and the two invariances that let
-- the model hold no reference pitch.

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
}
