-- The eighty-eight-note take docs/sonority.md § The solve times the walk over, as
-- the tracker holds it: the note events of every column of slot 00, read off tv.grid.cols
-- through the bridge, with the render clip as each note's end. Eighty-eight notes over
-- sixteen columns, sixty-six strands, under the thirteen-pitch Diamond the take is retuned
-- to.
--
-- The five-part take of tests/specs/sonority_spec.lua is a different fixture, and timing
-- the walk on it measures a different problem: this take's held notes leave the walk's
-- cursor lagging, so a relaxation here reads sixty springs over five and a half open onsets
-- where the five-part take reads seventeen over one and a half.
--
-- Returns { strands, notation, target, notes }, and is loaded from the repo root:
--   package.path = './?.lua;tests/spikes/springs/?.lua;' .. package.path
--   local take = require('take')

local tuning   = require('tuning')
local sonority = require('sonority')

-- The notation the take is written in, and the target the retune modal was left on --
-- facility 'moves', key 1, sonority size 5, harmonic lock 1, purity 8.
local notation = tuning.presets['12EDO']
local target   = tuning.moves{ pitches = { '1/1', '16/15', '10/9', '9/8', '6/5', '5/4',
                                           '4/3', '3/2', '8/5', '5/3', '16/9', '9/5',
                                           '15/8' } }

-- { ppq, endppqC, pitch, detune } per note, in column order.
local notes = {
  {     0, 12288, 36,  -3.057703895 }, { 12288, 15360, 36,  -3.409135835 },
  { 18432, 21504, 36,  -3.409135835 }, { 24576, 27648, 38,  -2.020043320 },
  { 30720, 33792, 40,   1.581197548 }, { 33792, 36864, 48,  14.984171880 },
  { 36864, 39936, 41,  12.962491570 }, { 43008, 46080, 43,  16.833232160 },
  { 49152, 52224, 45,   1.292042430 }, { 55296, 58368, 55,  -2.431342570 },
  { 58368, 61440, 54, -13.855627770 }, { 61440, 64512, 53,   5.978462941 },
  { 64512, 67584, 54,  -1.761772060 }, { 67584, 70656, 52,  -5.699451061 },
  { 70656, 73728, 54,  -1.849254502 }, { 73728, 76800, 50,  11.771362000 },
  { 76800, 79872, 54,  -1.798408347 }, { 79872, 82944, 48,   7.898373424 },
  { 82944, 86016, 54,  -1.783036196 }, { 86016, 89088, 36,   7.898373424 },
  { 89088, 95232, 54,  -1.887600184 }, { 95232, 98304, 54,  17.298605860 },

  {     0,  6144, 56,  10.411012020 }, {  6144, 12288, 54, -12.793135330 },
  { 12288, 18432, 56,  10.247059820 }, { 18432, 21504, 51,  11.931551660 },
  { 21504, 24576, 54, -14.210190010 }, { 24576, 30720, 56,   7.862499789 },
  { 30720, 33792, 52,   1.581197548 }, { 33792, 36864, 51,   9.223763093 },
  { 36864, 43008, 55,  -4.416541466 }, { 43008, 49152, 52,   1.573410933 },
  { 49152, 52224, 56,   9.008811213 }, { 52224, 55296, 54, -13.960840860 },
  { 55296, 58368, 54, -13.941204130 }, { 58368, 61440, 53,  -6.193975508 },
  { 61440, 67584, 56, -19.259857380 }, { 67584, 73728, 54,  -1.849254502 },
  { 73728, 79872, 52,  -5.737550634 }, { 79872, 82944, 54,  -1.782548606 },
  { 82944, 86016, 54,  -1.783036196 }, { 86016, 89088, 56, -19.140291380 },
  { 89088, 92160, 52,  -5.862858243 }, { 92160, 95232, 54,  -1.887600184 },
  { 95232, 95846, 54,  17.298605860 }, { 95846, 98304, 56,  20.921804330 },

  {     0,  6144, 36,  -3.057703895 }, {  6144, 12288, 40, -16.746262940 },
  { 12288, 18432, 43,  -1.466230046 }, { 18432, 24576, 36,  -3.409135835 },
  { 24576, 30720, 41,  13.603028280 }, { 30720, 36864, 43,  -4.136835339 },
  { 36864, 43008, 36,  15.027432080 }, { 43008, 49152, 41,  14.183913470 },
  { 49152, 55296, 43,  -2.713657509 }, { 55296, 61440, 36,  -4.366233910 },
  { 61440, 67584, 40,  -5.667930700 }, { 67584, 73728, 43,   9.780558857 },
  { 73728, 79872, 36,   7.898373424 }, { 79872, 86016, 40,  -5.672129195 },
  { 86016, 92160, 43,   9.828785234 }, { 92160, 98304, 41,   5.759618361 },

  {     0,  2458, 48,  -3.057703895 }, {  2458,  4915, 55,  -1.123045458 },
  {  4915,  7373, 53,  -4.976059533 }, {  7373,  9830, 55,  -1.067221309 },
  {  9830, 12288, 52, -16.746262940 }, { 12288, 14746, 55,  -1.466230046 },
  { 14746, 24576, 57, -18.967285810 }, { 24576, 27034, 55,  -3.723970935 },
  { 27034, 36864, 57,  -0.193928093 }, { 36864, 39322, 55,  -4.416541466 },
  { 39322, 49152, 57,  -0.450164127 }, { 49152, 51610, 55,  -2.713657509 },
  { 51610, 61440, 57,   1.292042430 }, { 61440, 63898, 55,   9.865464534 },
  { 63898, 73728, 57,  -7.647964402 }, { 73728, 76186, 55,   9.718425039 },
  { 76186, 86016, 57,  -7.663106003 }, { 86016, 88474, 55,   9.828785234 },
  { 88474, 95846, 57,  -7.720606797 }, { 95846, 98304, 57,  -7.807252861 },

  {     0, 12288, 72,  -3.057703895 }, { 12288, 24576, 72,  -3.409135835 },
  { 24576, 36864, 74,  -2.020043320 }, { 36864, 49152, 72,  15.027432080 },
  { 49152, 61440, 74,  -0.654006964 }, { 61440, 98304, 72,   7.898373424 },
}

-- What trackerView's strandsOf hands the solve: the render clip as the note's end, and the
-- step-class of the notation it is written in.
--
-- The detune each note carries is what the last retune left on it, and under this notation it
-- says nothing: both places it enters -- the class, and the seat sonority.seats reads -- snap
-- to the step first, and nothing here sits more than 21 cents off its 12-EDO step. Zeroing it
-- returns the take's cents to the last bit. It is kept because it is the take as the tracker
-- holds it, and because it stops being inert under an uneven notation.
local clipped = {}
for k, note in ipairs(notes) do
  clipped[k] = { ppq = note[1], endppq = note[2], pitch = note[3], detune = note[4] }
end

local strands = sonority.strands(clipped, function(note)
  return tuning.stepClass(notation, note)
end)

return { strands = strands, notation = notation, target = target, notes = notes }
