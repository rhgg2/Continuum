-- See docs/tuning.md for the model.
-- @noindex

--invariant: pure coordinate-system module: no module state, no take state, no pb / detune realisation logic
--invariant: intent / realisation split — owns intent (cents-typed detune); pb realisation is tm's domain
--invariant: detune is cents throughout; raw 14-bit pb conversion is tm's flush boundary, never here
--invariant: first step of every temper is C; octaveStep derivation depends on this
--invariant: octave parameters are MIDI-relative (C4 → 4), not period-index
--shape: Temper = {name=string, period=cents, cents=number[ascending], stepNames=string[], octaveStep=int}
local M = {}

----- Temperament presets

local function computeOctaveStep(stepNames)
  for i = #stepNames, 1, -1 do
    if stepNames[i]:sub(1, 1) ~= 'C' then return i + 1 end
  end
  return 1
end

local function edo(n, names)
  local cents = {}
  for i = 1, n do cents[i] = math.floor((i - 1) * 1200 / n + 0.5) end
  return {
    name       = n .. 'EDO',
    period     = 1200,
    cents      = cents,
    stepNames  = names,
    octaveStep = computeOctaveStep(names),
  }
end

M.presets = {
  ['12EDO'] = edo(12, {
    'C-','C#','D-','D#','E-','F-','F#','G-','G#','A-','A#','B-'
  }),
  ['19EDO'] = edo(19, {
    'C-','C#','Db','D-','D#','Eb','E-','E#','F-','F#','Gb',
    'G-','G#','Ab','A-','A#','Bb','B-','B#'
  }),
  ['31EDO'] = edo(31, {
    'C-','C↑','C#','Db','D↓','D-','D↑','D#','Eb','E↓','E-',
    'E↑','F↓','F-','F↑','F#','Gb','G↓','G-','G↑','G#','Ab',
    'A↓','A-','A↑','A#','Bb','B↓','B-','B↑','C↓'
  }),
  ['53EDO'] = edo(53, {
    'C-','C↑','C⇑','C⇈','Db','C#','D⇊','D⇓','D↓','D-','D↑',
    'D⇑','D⇈','Eb','D#','E⇊','E⇓','E↓','E-','E↑','E⇑','F↓',
    'F-','F↑','F⇑','F⇈','Gb','F#','G⇊','G⇓','G↓','G-','G↑',
    'G⇑','G⇈','Ab','G#','A⇊','A⇓','A↓','A-','A↑','A⇑','A⇈',
    'Bb','A#','B⇊','B⇓','B↓','B-','B↑','B⇑','C↓'
  }),
}

--contract: returns nil if either name or userLib is missing; callers treat nil as "no temperament"
function M.findTemper(name, userLib)
  if not (name and userLib) then return nil end
  return userLib[name]
end

----- Coordinate conversions

--contract: detune optional (defaults 0); snaps to nearest scale point including the period boundary (rounds up to step 1 of next octave)
--contract: returned octave is MIDI-relative (C-1 → -1)
function M.midiToStep(temper, midi, detune)
  detune = detune or 0
  local cents  = midi * 100 + detune
  local period = temper.period
  local octave = math.floor(cents / period)
  local res    = cents - octave * period
  local steps  = temper.cents

  local best, bestDist = 1, math.abs(res - steps[1])
  for i = 2, #steps do
    local d = math.abs(res - steps[i])
    if d < bestDist then best, bestDist = i, d end
  end
  -- Step 1 of the next period sits at cents = period.
  if math.abs(res - period) < bestDist then
    best, octave = 1, octave + 1
  end

  return best, octave - 1
end

--contract: wraps out-of-range step by adjusting octave; clamps midi to 0..127 by folding overflow into detune (never silently drops)
function M.stepToMidi(temper, step, octave)
  local steps, n = temper.cents, #temper.cents
  while step < 1 do step = step + n; octave = octave - 1 end
  while step > n do step = step - n; octave = octave + 1 end

  local cents  = (octave + 1) * temper.period + steps[step]
  local midi   = math.floor(cents / 100 + 0.5)
  local detune = cents - midi * 100

  if midi < 0 then
    detune, midi = detune + 100 * midi, 0
  elseif midi > 127 then
    detune, midi = detune + 100 * (midi - 127), 127
  end

  return midi, detune
end

function M.snap(temper, midi, detune)
  return M.stepToMidi(temper, M.midiToStep(temper, midi, detune))
end

--contract: moves by n scale steps under temper, carrying the octave; n may be negative
function M.transposeStep(temper, midi, detune, n)
  local step, oct = M.midiToStep(temper, midi, detune)
  return M.stepToMidi(temper, step + n, oct)
end

----- Display

-- Octave -1 renders as "M" so the cell width stays fixed.
local function octaveLabel(o)
  return o == -1 and 'M' or tostring(o)
end

--contract: bumps displayed octave by 1 when step >= temper.octaveStep (C-variant tail belongs to next octave by label convention)
function M.stepToText(temper, step, octave)
  if step >= temper.octaveStep then octave = octave + 1 end
  return temper.stepNames[step] .. octaveLabel(octave)
end

return M
