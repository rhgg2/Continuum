-- spike_fx_io_size.lua
--
-- Calibrate: does TrackFX_GetIOSize report mono channels or stereo
-- pairs, and does (27 + 16 * pinPairs) match the observed mirror-flag
-- offset for the selected track's FX[FX_IDX]?
--
-- Run with ReaEQ, Falcon, Softube Modular (etc) selected in turn.
-- Compare 'mirror_offset (1-indexed)' against your known calibration
-- (ReaEQ=59, Softube-5pair=107, Falcon-17pair=299).

local reaper = reaper
local fmt    = string.format

local FX_IDX = 0

local function out(s) reaper.ShowConsoleMsg(tostring(s) .. '\n') end

local track = reaper.GetSelectedTrack(0, 0)
if not track then
  reaper.MB('Select a track first.', 'spike_fx_io_size', 0)
  return
end
if reaper.TrackFX_GetCount(track) <= FX_IDX then
  reaper.MB(fmt('No FX at index %d.', FX_IDX), 'spike_fx_io_size', 0)
  return
end

local _, fxName = reaper.TrackFX_GetFXName(track, FX_IDX)
local retval, inputPins, outputPins = reaper.TrackFX_GetIOSize(track, FX_IDX)

reaper.ClearConsole()
out('=== TrackFX_GetIOSize calibration ===')
out('FX:                ' .. (fxName or '?'))
out(fmt('retval (plug type):%d', retval))
out(fmt('inputPins:         %d', inputPins))
out(fmt('outputPins:        %d', outputPins))
out('')
out('Hypothesis A: pins are MONO channels')
do
  local pairs_ = (inputPins + outputPins) // 2
  out(fmt('  pinPairs = (in + out)/2 = %d', pairs_))
  out(fmt('  predicted mirror offset (1-indexed) = 27 + 16*%d = %d',
          pairs_, 27 + 16 * pairs_))
end
out('Hypothesis B: pins are STEREO pairs already')
do
  local pairs_ = inputPins + outputPins
  out(fmt('  pinPairs = in + out = %d', pairs_))
  out(fmt('  predicted mirror offset (1-indexed) = 27 + 16*%d = %d',
          pairs_, 27 + 16 * pairs_))
end
