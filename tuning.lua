-- See docs/tuning.md for the model.
-- @noindex

--invariant: pure coordinate-system module: no module state, no take state, no pb / detune realisation logic
--invariant: intent / realisation split — owns intent (cents-typed detune); pb realisation is tm's domain
--invariant: detune is cents throughout; raw 14-bit pb conversion is tm's flush boundary, never here
--invariant: cents[1] is the unison (0); nameless step displays as degree-octave via M.stepToText
--invariant: octave parameters are MIDI-relative (C4 → 4), not period-index
--shape: Temper = {name=string, period=cents, cents=number[ascending], stepNames=string[], octaveStep=int, cellWidth=int}
local M = {}

----- Temperament presets

-- octaveStep: first step whose label reads as the next octave's C. Scans from
-- the end for the last non-C name; nameless scale → bump at period (n+1).
local function computeOctaveStep(stepNames, n)
  for i = n, 1, -1 do
    local nm = stepNames[i]
    if nm and nm ~= '' and nm:sub(1, 1) ~= 'C' then return i + 1 end
  end
  return n + 1
end

-- cellWidth: widest step label width (named: utf8 len; nameless: digits+dash).
-- Tracker pitch cell sizes to this so long names and >9-step scales fit.
local function computeCellWidth(stepNames, n)
  local widest = 0
  for i = 1, n do
    local nm   = stepNames[i]
    local base = (nm and nm ~= '') and utf8.len(nm) or (#tostring(i) + 1)
    if base > widest then widest = base end
  end
  return widest + 1
end

--contract: stamps octaveStep + cellWidth from cents/stepNames on every edit. Pure; returns temper.
function M.derive(temper)
  local n = #temper.cents
  temper.octaveStep = computeOctaveStep(temper.stepNames or {}, n)
  temper.cellWidth  = computeCellWidth(temper.stepNames or {}, n)
  return temper
end

local function edo(n, names)
  local cents = {}
  for i = 1, n do cents[i] = math.floor((i - 1) * 1200 / n + 0.5) end
  return M.derive{
    name      = n .. 'EDO',
    period    = 1200,
    cents     = cents,
    stepNames = names,
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

--contract: looks up name in userLib first, then falls back to built-in M.presets; returns nil only if name is missing or unknown to both. Lets the '12EDO' sentinel resolve even when userLib is empty.
function M.findTemper(name, userLib)
  if not name then return nil end
  return (userLib and userLib[name]) or M.presets[name]
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

--contract: name ⇒ name+octave (C-4); blank/absent ⇒ degree-octave (7-4). Octave +1 at octaveStep.
function M.stepToText(temper, step, octave)
  if step >= temper.octaveStep then octave = octave + 1 end
  local name = temper.stepNames and temper.stepNames[step]
  if name and name ~= '' then return name .. octaveLabel(octave) end
  return step .. '-' .. octaveLabel(octave)
end

return M
