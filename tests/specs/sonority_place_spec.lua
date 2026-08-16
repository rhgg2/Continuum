-- Pins the placement of design/adaptive-ji.md § A placement is connected: the search
-- at one fixed offset over a single sonority, where a strand's candidates are the
-- tunings one move reaches from a strand already placed.
--
-- Pins what the joining buys: a dominant seventh coming out 4:5:6:7, and a
-- minor third the move set holds no move for reached through the fifth. Pins the
-- refusal an offset with nothing reachable returns, and the root seated where it
-- was written (§ Where a placement sits).
--
-- Pins the carry across onsets: what a chord may attach to is what sounds under it
-- or struck before it, so a comma pump drifts by the comma it pumps.
--
-- Pins what waiting buys and what bounds it (§ A strand may wait): a rolled minor triad
-- placing at the coords the struck chord takes, and the same three notes refused where the
-- strand that must wait has stopped sounding before its anchor strikes.

local t        = require('support')
local util     = require('util')
local tuning   = require('tuning')
local sonority = require('sonority')

local edo12 = tuning.presets['12EDO']

-- The placement's figures are worked past the doc's two places.
local function nearly(actual, expected, why)
  t.truthy(math.abs(actual - expected) < 5e-4, string.format(
    '%s: expected %.4f, got %.6f', why or 'nearly', expected, actual))
end

-- The passage as the command hands it over: a note per pitch, each chord a beat long
-- unless it says otherwise, grouped into strands by the step-class the notation gives them.
local function passage(chords)
  local notes = {}
  for _, chord in ipairs(chords) do
    for _, pitch in ipairs(chord.pitches) do
      util.add(notes, { ppq = chord.ppq, pitch = pitch,
                        endppq = chord.ppq + (chord.len or 960) })
    end
  end
  return sonority.strands(notes, function(e)
    return tuning.stepClass(edo12, e.pitch, e.detune)
  end)
end

local function chord(pitches)
  return passage{ { ppq = 0, pitches = pitches } }
end

-- I–vi–ii–V–I: the moves that spell it multiply to a syntonic comma, so the step it
-- opens on is not the tuning it closes on (design/adaptive-ji.md § Drift).
local function commaPump()
  local chords = {}
  for k, pitches in ipairs{ {60,64,67}, {57,60,64}, {62,65,69}, {55,59,62}, {60,64,67} } do
    chords[k] = { ppq = (k - 1) * 960, pitches = pitches }
  end
  return passage(chords)
end

-- A G sustained through a chord change, with C and E under it and then E♭ and A♭.
local function heldUnderChange()
  return passage{ { ppq = 0,   pitches = { 67 }, len = 1920 },
                  { ppq = 0,   pitches = { 60, 64 } },
                  { ppq = 960, pitches = { 63, 68 } } }
end

-- A rolled C minor triad: the C, then the E♭ no move of a 5-limit set reaches from it,
-- then the G it must hang off, each sustaining to the end of the roll.
local function rolledMinor()
  return passage{ { ppq = 0,   pitches = { 60 }, len = 1440 },
                  { ppq = 480, pitches = { 63 }, len = 960 },
                  { ppq = 960, pitches = { 67 }, len = 480 } }
end

-- A placement's coords in strand order, which is ascending step-class: what the
-- chord came out as, blind to where it sits.
local function coordsOf(placement, strands)
  local coordSet = {}
  for index = 1, #strands do coordSet[index] = placement.tunings[index].coords end
  return coordSet
end

-- The cost read back off a placement's own tunings: the box over the walk, plus the pull
-- each strand spends. A sonority a strand kept waiting is charged when it places, once.
local function recost(placement, strands, n, strength)
  local total = 0
  for _, current in ipairs(sonority.walk(strands, n)) do
    local coordSet = {}
    for k, index in ipairs(current.strands) do coordSet[k] = placement.tunings[index].coords end
    total = total + sonority.score(coordSet)
  end
  for index = 1, #strands do
    local strain = placement.tunings[index].strain
    total = total + strength * strain * strain
  end
  return total
end

return {
  {
    name = 'a dominant seventh standing alone comes out 4:5:6:7',
    run = function()
      local moves   = tuning.moves{ pitches = { '1/1', '3/2', '5/4', '7/4' } }
      local strands = chord{ 60, 64, 67, 70 }
      local placed  = sonority.place(strands, 5, 1, edo12, moves, 0)
      t.truthy(placed, 'the chord places where it was written')

      t.deepEq(coordsOf(placed, strands), { {}, { [5] = 1 }, { [3] = 1 }, { [7] = 1 } },
        'the third, the fifth and the seventh each one move from the C')
      nearly(placed.tunings[1].cents, 0,        'the root on the step it was written on')
      nearly(placed.tunings[4].cents, 968.8259, 'and the seventh a 7/4 above it')
      nearly(sonority.score(coordsOf(placed, strands)), 6.7142, 'the box 4:5:6:7 scores')
      nearly(placed.cost, 7.1794, 'and the pull the four strands spend on top of it')
    end,
  },

  {
    name = 'the minor third no move reaches hangs off the fifth',
    run = function()
      local moves   = tuning.moves{ pitches = { '1/1', '3/2', '5/4' } }
      local strands = chord{ 60, 63, 67 }
      local placed  = sonority.place(strands, 5, 1, edo12, moves, 0)
      t.truthy(placed, 'the triad places, though no move of the set is a 6/5')

      -- The E♭ is the second strand and the G it hangs off the third, so an order
      -- fixed in advance would reach the E♭ with nothing to hang it on.
      t.deepEq(placed.tunings[2].coords, { [3] = 1, [5] = -1 },
        'the E♭ a 5/4 below the G, and so a 6/5 above the C')
      nearly(placed.tunings[2].cents, 315.6413)
      t.deepEq(placed.tunings[3].coords, { [3] = 1 }, 'the G it hangs off hanging off the C')
      nearly(placed.cost, 4.0063, 'the minor triad\'s box, and the pull it spends')
    end,
  },

  {
    name = 'a move set of fifths alone places no minor triad',
    run = function()
      local moves = tuning.moves{ pitches = { '1/1', '3/2' } }
      t.eq(sonority.place(chord{ 60, 63, 67 }, 5, 1, edo12, moves, 0), nil,
        'nothing the set reaches lands in the E♭\'s window, from either of the others')
    end,
  },

  {
    name = 'a note held under a chord change constrains what strikes against it',
    run = function()
      local moves   = tuning.moves{ pitches = { '1/1', '3/2', '5/4' } }
      -- A sonority of two, so the chord that has gone is out of reach and the G alone
      -- carries the placement into the second onset.
      local placed  = sonority.place(heldUnderChange(), 2, 1, edo12, moves, 0)
      t.truthy(placed, 'the second chord places against the note held under it')

      t.deepEq(placed.tunings[2].coords, { [3] = 1, [5] = -1 },
        'the E♭ a 5/4 below the held G, and so a 6/5 above the C that has gone')
      nearly(placed.tunings[2].cents, 315.6413)
      t.deepEq(placed.tunings[5].coords, { [5] = -1 }, 'the A♭ a 4/3 above the E♭')
      nearly(placed.tunings[5].cents, 813.6863)

      -- The same three notes with nothing sounding under them go the other way about.
      local alone = sonority.place(chord{ 63, 67, 68 }, 2, 1, edo12, moves, 0)
      t.deepEq(alone.tunings[1].coords, {}, 'the chord standing alone roots on its E♭')
      nearly(alone.tunings[2].cents, 686.3137, 'and takes a G a 5/4 above it')
    end,
  },

  {
    name = 'a move set reaching nothing from what sounds under it refuses the passage',
    run = function()
      local moves = tuning.moves{ pitches = { '1/1', '3/2' } }
      t.eq(sonority.place(heldUnderChange(), 2, 1, edo12, moves, 0), nil,
        'a fifth from the G lands nowhere in the E♭\'s window')
    end,
  },

  {
    name = 'a comma pump returns to its opening step at a different tuning',
    run = function()
      local moves   = tuning.moves{ pitches = { '1/1', '3/2', '5/4' } }
      local placed  = sonority.place(commaPump(), 5, 1, edo12, moves, 0)
      t.truthy(placed, 'the progression places')

      -- The three C strands, in strike order: the opening chord's, the A minor's,
      -- and the one the passage closes on.
      nearly(placed.tunings[1].cents, 0, 'the C it opens on, seated where it was written')
      t.deepEq(placed.tunings[3].coords, { [3] = -4, [5] = 1 },
        'the C it closes on reached by four fifths down and a third up')
      nearly(placed.tunings[3].cents, 1178.4937, 'a syntonic comma below where it began')
    end,
  },

  {
    name = 'chords releasing before the next strikes chain all the same',
    run = function()
      local moves = tuning.moves{ pitches = { '1/1', '3/2', '5/4' } }
      -- A sonority of three: each chord fills the recency window itself and nothing
      -- sounds across the change, so the sonority before an onset is all there is to
      -- attach to (design/adaptive-ji.md § A placement is connected).
      local placed = sonority.place(commaPump(), 3, 1, edo12, moves, 0)
      t.truthy(placed, 'the progression places without a chord rooting itself')

      t.deepEq(placed.tunings[3].coords, { [3] = -4, [5] = 1 }, 'and drifts as it does at five')
      nearly(placed.tunings[3].cents, 1178.4937)
    end,
  },

  {
    name = 'the offset carries the placement, and the root reads it alone',
    run = function()
      local moves   = tuning.moves{ pitches = { '1/1', '3/2', '5/4', '7/4' } }
      local strands = chord{ 60, 64, 67, 70 }
      local placed  = sonority.place(strands, 5, 1, edo12, moves, 20)
      t.truthy(placed, 'the seventh places 20¢ above where it was written too')

      t.deepEq(coordsOf(placed, strands), { {}, { [5] = 1 }, { [3] = 1 }, { [7] = 1 } },
        'the same tree, the offset being no part of a tuning')
      nearly(placed.tunings[1].cents, 0, 'the root still on its own step')
      nearly(placed.tunings[1].strain, 0.4, 'its strain the offset over the half-window')
      nearly(placed.tunings[3].strain, 0.4391, 'where the fifth reads the two together')
      nearly(placed.cost, 7.1329, 'a cheaper trade than the same tree unshifted')
    end,
  },

  {
    name = 'a rolled minor triad waits for the fifth it hangs off',
    run = function()
      local moves   = tuning.moves{ pitches = { '1/1', '3/2', '5/4' } }
      local strands = rolledMinor()
      local placed  = sonority.place(strands, 5, 1, edo12, moves, 0)
      t.truthy(placed, 'the E♭ waits for the G rather than refusing at its own onset')

      local struck = chord{ 60, 63, 67 }
      t.deepEq(coordsOf(placed, strands),
               coordsOf(sonority.place(struck, 5, 1, edo12, moves, 0), struck),
        'and the roll comes out at the coords the struck chord takes')
      nearly(placed.tunings[2].cents, 315.6413)
      nearly(placed.cost, recost(placed, strands, 5, 1),
        'the sonorities its waiting left unscored charged once, and once only')
    end,
  },

  {
    name = 'a strand released before its anchor arrives has nothing to wait for',
    run = function()
      local moves = tuning.moves{ pitches = { '1/1', '3/2', '5/4' } }
      -- The E♭ has no move to the C, and the G that could carry it strikes as the pair
      -- stops. A sonority of three still holds all of them: recency is not sounding together.
      local gone  = passage{ { ppq = 0, pitches = { 60, 63 } },
                             { ppq = 960, pitches = { 67 } } }
      t.eq(sonority.place(gone, 3, 1, edo12, moves, 0), nil,
        'a strand waits only on what sounds with it')

      local held   = passage{ { ppq = 0,   pitches = { 60, 63 }, len = 1920 },
                              { ppq = 960, pitches = { 67 } } }
      local placed = sonority.place(held, 3, 1, edo12, moves, 0)
      t.truthy(placed, 'the same three notes place where the pair is held under the G')
      t.deepEq(placed.tunings[2].coords, { [3] = 1, [5] = -1 },
        'the E♭ having waited for the G to take a 5/4 below it')
    end,
  },
}
