-- Pins the sweep of design/adaptive-ji.md § What it costs to solve: sonority.placeAt run
-- once at each of eleven offsets spanning the root strand's own step window, the cheapest
-- placement kept together with the offset that found it.
--
-- Pins what the sweep buys: a diminished triad that has no placement where it was
-- written placing 20¢ above it, as the 4:5:7 the move set reaches. Pins that a sweep
-- at 10¢ resolves the same placement a sweep at 0.5¢ does, differing only in the offset
-- it states it at. Pins the refusal, where no offset reaches anything at all.

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

-- A chord per beat, in the order given.
local function prog(chords)
  local beats = {}
  for k, pitches in ipairs(chords) do
    beats[k] = { ppq = (k - 1) * 960, pitches = pitches }
  end
  return passage(beats)
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
    name = 'a chord with no placement where it was written places under the sweep',
    run = function()
      local moves   = tuning.moves{ pitches = { '1/1', '3/2', '5/4', '7/4' } }
      local strands = chord{ 60, 63, 66 }
      t.eq(sonority.placeAt(strands, 5, 1, edo12, moves, 0), nil,
        'nothing the set reaches lands in all three windows where they were written')

      local placed = sonority.solveToMoves(strands, 5, 1, edo12, moves)
      t.truthy(placed, 'and the sweep finds the offset at which it does')

      nearly(placed.offset, 20, 'the placement carries the offset it is stated at')
      t.deepEq(coordsOf(placed, strands), { {}, { [7] = -1 }, { [5] = 1, [7] = -1 } },
        'the diminished triad coming out 4:5:7 on its middle note')
      nearly(placed.tunings[1].cents, 0)
      nearly(placed.tunings[2].cents, 231.1741)
      nearly(placed.tunings[3].cents, 617.4878)
      nearly(placed.cost, 6.8050, 'the cost of the cheapest of the eleven')

      -- Four offsets place, so the winner is chosen against rivals rather than by default.
      local placing = 0
      for k = 0, 10 do
        if sonority.placeAt(strands, 5, 1, edo12, moves, -50 + 10 * k) then
          placing = placing + 1
        end
      end
      t.eq(placing, 4, 'four of the eleven offsets place at all')
    end,
  },

  {
    name = 'a sweep at 10¢ returns the placement a finer sweep returns',
    run = function()
      local moves   = tuning.moves{ pitches = { '1/1', '3/2', '5/4' } }
      local strands = prog{ {60,64,67}, {65,69,72}, {67,71,74}, {60,64,67} }
      local placed  = sonority.solveToMoves(strands, 5, 1, edo12, moves)
      t.truthy(placed, 'the I–IV–V–I places')
      nearly(placed.offset, 10)
      nearly(placed.cost, 23.5045)

      -- The same passage swept at 0.5¢, which lands between two of the eleven.
      local best
      for k = 0, 200 do
        local finer = sonority.placeAt(strands, 5, 1, edo12, moves, -50 + 0.5 * k)
        if finer and (not best or finer.cost < best.cost) then best = finer end
      end
      nearly(best.offset, 14.5, 'the finer sweep states the passage a little higher')
      nearly(best.cost, 23.4002, 'and a little cheaper for it')
      t.deepEq(coordsOf(placed, strands), coordsOf(best, strands),
        'the two agree on the placement, differing only in where they state it')
    end,
  },

  {
    name = 'a move set that reaches nothing at any offset returns nil',
    run = function()
      local moves   = tuning.moves{ pitches = { '1/1', '3/2', '5/4' } }
      local strands = chord{ 60, 61, 62 }
      t.eq(sonority.solveToMoves(strands, 5, 1, edo12, moves), nil,
        'no move of the set spans a semitone, at any offset the sweep tries')
    end,
  },
}
