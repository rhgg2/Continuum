-- Pins the placement of design/adaptive-ji.md § A placement is a tree: the search
-- at one fixed offset over a single sonority, where a strand's candidates are the
-- tunings one move reaches from a strand already placed.
--
-- Pins what the tree's shape buys: a dominant seventh coming out 4:5:6:7, and a
-- minor third the move set holds no move for reached through the fifth. Pins the
-- refusal an offset with nothing reachable returns, and the root seated where it
-- was written (§ Where a placement sits).

local t        = require('support')
local tuning   = require('tuning')
local sonority = require('sonority')

local edo12 = tuning.presets['12EDO']

-- The placement's figures are worked past the doc's two places.
local function nearly(actual, expected, why)
  t.truthy(math.abs(actual - expected) < 5e-4, string.format(
    '%s: expected %.4f, got %.6f', why or 'nearly', expected, actual))
end

-- The chord as the command hands it over: a note per pitch, struck together and a
-- beat long, grouped into strands by the step-class the notation gives them.
local function chord(pitches)
  local notes = {}
  for i, pitch in ipairs(pitches) do
    notes[i] = { ppq = 0, pitch = pitch, endppq = 960 }
  end
  return sonority.strands(notes, function(e)
    return tuning.stepClass(edo12, e.pitch, e.detune)
  end)
end

-- A placement's coords in strand order, which is ascending step-class: what the
-- chord came out as, blind to where it sits.
local function coordsOf(placement, strands)
  local coordSet = {}
  for index = 1, #strands do coordSet[index] = placement.tunings[index].coords end
  return coordSet
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
}
