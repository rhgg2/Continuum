-- Witnessed joins: a member joined by a chain of moves running through a member that
-- co-sounds with the pair somewhere in the passage, not necessarily at this onset. Tried
-- as a replacement for the waiting machinery of docs/sonority.md § The
-- candidates — look-ahead as information rather than as deferred charge, so that the beam
-- and the walk each rank over one pool instead of two.
--
-- The rolled C minor is the case: at its second onset the G has not struck, so no move of
-- a 5-limit set reaches between the C and the E flat and the pair is spelled 8/5, 86¢ from
-- where the C was written. The G carries 6/5 between them at the third onset, and that is
-- what the table below hands the second.
--
-- Measured against a sonority.lua carrying this table wired into beamOver's move loop as
-- an extra alphabet per (host, slot), under the refusal that has since landed: standing
-- alone is no placement, so a wider alphabet only ever adds roads.
--
--                           wait      stand    witness
--     C minor struck       3.9627    3.9627    3.9627
--     C minor rolled       7.8703    8.1488    7.8703
--     C7 rolled, 11-move  13.2165   13.2165   13.2165
--     ii–V–I triads       17.5075   17.5075   16.7056
--     ii–V–I sevenths     18.3248   18.3248   18.3248
--     4-voice overlap     13.0574   13.0574   13.0574   (at beam 96; 13.4029 at 24 and 48)
--
-- So the witness matches waiting everywhere measured and beats it on the ii–V–I, and
-- waiting earns nothing the witness does not. Before the refusal landed the table read the
-- other way round: every widening removed a member's free exit, so the witness lost to
-- standing alone, which cost nothing whatever.
--
-- Open. The widening is large — the eleven-move set names 15 moves and the witness adds 25
-- to 29 per ordered pair — so § The candidates' beam of twelve wants re-certifying at
-- width before this is trusted; the overlap row needed 96. And the cost of the precompute
-- at the size of § Measured's five-part take is untested.

package.path = './?.lua;' .. package.path
local util     = require 'util'
local tuning   = require 'tuning'
local sonority = require 'sonority'

local edo12 = tuning.presets['12EDO']

----- sonority.lua's own, since a spike patches nothing

local function joinCoords(coords, move)
  local sum = {}
  for prime, exponent in pairs(coords) do sum[prime] = exponent end
  for prime, exponent in pairs(move.coords) do
    local total = (sum[prime] or 0) + exponent
    sum[prime] = total ~= 0 and total or nil
  end
  return sum
end

local function coordString(coords)
  local primes = util.keys(coords)
  table.sort(primes)
  local parts = {}
  for k, prime in ipairs(primes) do parts[k] = prime .. ':' .. coords[prime] end
  return table.concat(parts, ',')
end

local function inReach(deviation, window)
  if deviation < 0 then return -deviation <= 2 * window.below end
  return deviation <= 2 * window.above
end

----- The table

-- Every interval a chain of moves through a sonority's own members realises between two of
-- them, each step landing within the reach of the member it passes through.
local function chainsWithin(members, seat, window, moves, into, seenBy)
  for _, from in ipairs(members) do
    into[from], seenBy[from] = into[from] or {}, seenBy[from] or {}

    local frontier = { { at = from, coords = {}, cents = seat[from] } }
    local reached  = { [from .. '|'] = true }

    for _ = 2, #members do
      local grown = {}
      for _, state in ipairs(frontier) do
        for _, to in ipairs(members) do
          if to ~= state.at then
            for _, move in ipairs(moves) do
              if move.height > 0 then
                local coords = joinCoords(state.coords, move)
                local cents  = state.cents + move.cents
                local key    = to .. '|' .. coordString(coords)
                if not reached[key] and inReach(tuning.gapTo(seat[to], cents), window[to]) then
                  reached[key] = true
                  util.add(grown, { at = to, coords = coords, cents = cents })

                  if to ~= from and not seenBy[from][to] then seenBy[from][to] = {} end
                  if to ~= from and not seenBy[from][to][coordString(coords)] then
                    seenBy[from][to][coordString(coords)] = true
                    into[from][to] = into[from][to] or {}
                    util.add(into[from][to], { coords = coords, cents = cents - seat[from],
                                               height = tuning.height(coords) })
                  end
                end
              end
            end
          end
        end
      end
      frontier = grown
    end
  end
end

-- The move set widened per ordered pair by what some sonority holding both ends realises
-- between them. A composite the set already names outright is no widening.
local function witnessesOf(onsets, seat, window, moves)
  local into, seenBy = {}, {}
  for _, onset in ipairs(onsets) do
    chainsWithin(onset.members, seat, window, moves, into, seenBy)
  end

  local named = {}
  for _, move in ipairs(moves) do named[coordString(move.coords)] = true end
  for _, targets in pairs(into) do
    for to, list in pairs(targets) do
      local kept = {}
      for _, move in ipairs(list) do
        if not named[coordString(move.coords)] then util.add(kept, move) end
      end
      targets[to] = kept
    end
  end
  return into
end

-- Wired into beamOver by taking the alphabet for a join between `host` and `slot` as
-- `moves` followed by `witness[member(host)][member(slot)]`, everything else unchanged:
-- the join is admitted on the same reach test and priced by the same joinCost.

----- The report

local function event(ppq, pitch, endppq) return { ppq = ppq, pitch = pitch, endppq = endppq } end
local function pitchClass(note) return note.pitch % 12 end

local function rolled(pitches, apart)
  local notes = {}
  for k, pitch in ipairs(pitches) do notes[k] = event((k - 1) * apart, pitch, 960) end
  return sonority.strands(notes, pitchClass)
end

local NAMES = { [0] = 'C', 'C#', 'D', 'Eb', 'E', 'F', 'F#', 'G', 'Ab', 'A', 'Bb', 'B' }

-- Named in full where the widening is small enough to read, and counted where it is not,
-- which is itself the finding: a set of any richness admits composites by the dozen.
-- The reach above is this spike's own, the solve having stopped reading a window, so the
-- windows come from the notation directly.
local function report(label, strands, moves, listed)
  local seat, window = {}, {}
  for index, strand in ipairs(strands) do
    local cents, below, above = tuning.seatWindow(edo12, strand.notes[1])
    seat[index], window[index] = cents, { below = below, above = above }
  end

  local onsets  = sonority.onsets(strands, sonority.walk(strands, 5))
  local witness = witnessesOf(onsets, seat, window, moves)

  print(string.format('--- %s: %d moves named, and what the passage adds ---', label, #moves))
  for from = 1, #strands do
    for to = 1, #strands do
      local list = witness[from] and witness[from][to]
      if list and #list > 0 then
        local shown
        if listed then
          local parts = {}
          for _, move in ipairs(list) do
            util.add(parts, string.format('%s (%+.1f)', coordString(move.coords),
                                          tuning.gapTo(0, tuning.cents(move.coords))))
          end
          shown = table.concat(parts, ', ')
        else
          shown = string.format('%d composites', #list)
        end
        print(string.format('  %-3s -> %-3s : %s',
                            NAMES[strands[from].notes[1].pitch % 12],
                            NAMES[strands[to].notes[1].pitch % 12], shown))
      end
    end
  end
  print('')
end

report('rolled C minor, pure fifths and thirds', rolled({ 60, 63, 67 }, 240),
       tuning.moves{ pitches = { '1/1', '3/2', '5/4' } }, true)

report('rolled C7, the eleven-move set', rolled({ 60, 64, 67, 70 }, 240),
       tuning.moves{ pitches = { '1/1', '3/2', '5/4', '6/5', '7/4', '7/6',
                                 '7/5', '9/8', '5/3', '8/7', '10/7' } }, false)
