-- What a member held by recency should count for: sonority.lua's RECENT, which weights every
-- spring the stopped member holds (docs/sonority.md § The walk). The passages are the ones
-- the value could decide -- a chord that cannot state a pure interval to the pitch held into
-- it, where the spring the stopped member drags it by is strained. Run from the repo root:
--   lua tests/spikes/springs/recency.lua [purity]
--
-- WHAT IT SHOWED, at the dials' openings and the beam and cap of § The solve:
--
--   * On ordinary music the value decides nothing. An F sharp released as C-E-G strikes, its
--     tritone spelled by a chain under a 5-limit set and standing 102c from where it was
--     written, moves the chord by three hundredths of a cent between a half and one. The
--     stopped strand is free to move, so it takes the strain rather than dragging the chord.
--     The example of § The strand, D-F-A into G-Bb-D, moves its G by two hundredths.
--   * Where both members of a strained pair have stopped, the value decides too much. B-F
--     released into Eb-G-Bb flips the spelling: the worst spring stands at 11.5c at a half
--     and 50.7c at one, with displacements swinging sixty cents and no trend across the four
--     values. That is instability rather than evidence, and it says the same at a purity of 8.
--   * So the half stands on the argument of § The walk, and nothing measured tells it from one.
package.path = './?.lua;tests/spikes/springs/?.lua;' .. package.path

local sonority = require('sonority')
local tuning   = require('tuning')

local ARITY, WIDTH, CAP, AMBIENT = 5, 24, 6, 0.25
local LOCK, PURITY = 1, tonumber(arg[1] or '32')

local edo12 = tuning.presets['12EDO']
local fiveLimit = tuning.moves{ pitches = { '1/1', '16/15', '9/8', '6/5', '5/4', '4/3',
                                            '3/2', '8/5', '5/3', '16/9', '15/8' } }

local function pitchClass(note) return note.pitch % 12 end

-- Each event is { ppq, endppq, pitch }.
local function passage(events)
  local notes = {}
  for k, e in ipairs(events) do
    notes[k] = { ppq = e[1], endppq = e[2], pitch = e[3] }
  end
  return sonority.strands(notes, pitchClass)
end

-- The presence is patched onto the onsets the walk built, so one passage is solved at one
-- value after another without the module holding a dial it does not have.
local function solveAt(strands, recent)
  local seat = sonority.seats(strands, edo12)
  local onsets, lists = sonority.onsets(strands, sonority.walk(strands, ARITY)), {}
  for _, onset in ipairs(onsets) do
    for index, presence in pairs(onset.presence) do
      if presence ~= 1 then onset.presence[index] = recent end
    end
  end
  for i, onset in ipairs(onsets) do
    lists[i] = sonority.spellings(onset.members, seat, onset.presence, onset.mayWait,
                                  fiveLimit, WIDTH, PURITY)
  end
  local answer = sonority.search(onsets, lists, seat, LOCK, PURITY, CAP, AMBIENT)
  if not answer then return nil end

  local free = {}
  for i = 1, #strands do free[i] = i end
  local displacement = sonority.relax(sonority.ties(answer.springs, free), LOCK, PURITY,
                                      answer.displacement, answer.rest, free)
  return displacement, answer
end

local function report(name, events, labels)
  local strands = passage(events)
  print(('\n%s  (%d strands, purity %g)'):format(name, #strands, PURITY))
  io.write('  recent ')
  for _, label in ipairs(labels) do io.write(('%9s'):format(label)) end
  print('   worst spring')
  for _, recent in ipairs({ 0.25, 0.5, 0.75, 1 }) do
    local displacement, answer = solveAt(strands, recent)
    if not displacement then
      print(('  %5.2f    refused'):format(recent))
    else
      io.write(('  %5.2f '):format(recent))
      for i = 1, #strands do io.write(('%9.3f'):format(displacement[i])) end
      local worst = 0
      for onset = 1, #answer.springs do
        for _, spring in ipairs(answer.springs[onset]) do
          worst = math.max(worst, math.abs(displacement[spring.j] - displacement[spring.i]
                                           - spring.delta))
        end
      end
      print(('   %8.3f'):format(worst))
    end
  end
end

-- An F sharp alone, released as C-E-G strikes: the tritone the set cannot state.
report('F#, then C-E-G', {
  { 0, 960, 66 }, { 960, 1920, 60 }, { 960, 1920, 64 }, { 960, 1920, 67 },
}, { 'F#', 'C', 'E', 'G' })

-- The same chord with the F sharp still sounding, where the spring carries full weight
-- whatever the dial says.
report('F# held through C-E-G', {
  { 0, 1920, 66 }, { 960, 1920, 60 }, { 960, 1920, 64 }, { 960, 1920, 67 },
}, { 'F#', 'C', 'E', 'G' })

-- The example of § The strand: a D held from D-F-A into G-Bb-D, released as the second strikes.
report('D-F-A, then G-Bb-D', {
  { 0, 960, 62 }, { 0, 960, 65 }, { 0, 960, 69 },
  { 960, 1920, 55 }, { 960, 1920, 58 }, { 960, 1920, 62 },
}, { 'D', 'F', 'A', 'G', 'Bb', 'D2' })

-- A tritone pair released into a chord that shares nothing with it, so both members of the
-- strained pair are held by recency alone.
report('B-F, then Eb-G-Bb', {
  { 0, 960, 59 }, { 0, 960, 65 }, { 960, 1920, 63 }, { 960, 1920, 67 }, { 960, 1920, 70 },
}, { 'B', 'F', 'Eb', 'G', 'Bb' })
