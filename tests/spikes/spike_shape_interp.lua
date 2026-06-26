-- spike_shape_interp.lua
--
-- design/archive/note-macros.md shape-interpolation spike. Settled (2026-06-21):
-- REAPER reads an n/n+32 CC pair as one 14-bit value and interpolates
-- that, so sparse MSB-shaped breakpoints deliver smooth full-resolution
-- 14-bit downstream. Result recorded in note-macros.md § Open questions;
-- this file is the harness behind it.
--
-- A 14-bit ramp (0 -> 16383) is authored two ways and read back at
-- shape_probe.jsfx, which reconstructs the value, emits it as pitch bend
-- (audible glide on ReaSynth), and meters density + coherence:
--
--   A - MSB-SHAPED : sparse breakpoints, msb lane LINEAR-shaped, lsb
--       lane SQUARE. Interpolate only the high bits; the low bits step at
--       breakpoints, never ramp (a ramped lsb would saw across each
--       127->0 wrap). REAPER's pair interpolation makes this full-res.
--   B - DENSE SQUARE : V sampled every 1/32 QN, msb+lsb co-located square
--       steps. The explicit-control reference; A matched it.
--
-- Run as a ReaScript action, ideally hotkey-bound - each invocation
-- advances one phase: BUILD A -> (play) -> VERIFY A -> BUILD B ->
-- (play) -> VERIFY B -> CLEANUP. Play once per build, no loop (the probe
-- resets its meters in @init).
--
-- shape_probe.jsfx must live where REAPER's FX browser finds it - put it
-- in the same Effects folder as the cv_*.jsfx (shown as 'Continuum CV').

local reaper = reaper
local fmt = string.format

local NS         = 'ctm_shape_spike'
local TRACK_NAME = 'ctm_shape_spike'

local PROBE        = 'JS:Continuum CV/shape_probe.jsfx'
local SYNTH_IDENTS = { 'VST:ReaSynth (Cockos)', 'VST3:ReaSynth (Cockos)', 'ReaSynth' }

local MSB_LANE = 20             -- chan 0 -> probe msbcode 20
local LSB_LANE = MSB_LANE + 32  -- MIDI 14-bit convention: LSB = MSB + 32 (52)
local SPAN_QN  = 16
local STEP_QN  = 0.03125   -- 1/32 QN -> ~15 ms at 120 bpm

local function out(s) reaper.ShowConsoleMsg(tostring(s) .. '\n') end

----- Lookup helpers

local function findTrack(name)
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, trName = reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', '', false)
    if trName == name then return tr end
  end
end

local function fxIndexByName(tr, frag)
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    local _, name = reaper.TrackFX_GetFXName(tr, i, '')
    if name:find(frag, 1, true) then return i end
  end
end

local function addFx(tr, idents)
  for _, ident in ipairs(idents) do
    local idx = reaper.TrackFX_AddByName(tr, ident, false, -1)
    if idx >= 0 then return idx, ident end
  end
  error('could not instantiate any of: ' .. table.concat(idents, ', '))
end

----- MIDI authoring

local function ppqOf(take, qn) return reaper.MIDI_GetPPQPosFromProjQN(take, qn) end

local function insertCC(take, qn, lane, val)
  reaper.MIDI_InsertCC(take, false, false, ppqOf(take, qn), 0xB0, 0, lane, val)
end

local function setLaneShape(take, lane, shape)
  local _, _, ccCnt = reaper.MIDI_CountEvts(take)
  for i = 0, ccCnt - 1 do
    local _, _, _, _, _, _, msg2 = reaper.MIDI_GetCC(take, i)
    if msg2 == lane then reaper.MIDI_SetCCShape(take, i, shape, 0, true) end
  end
  reaper.MIDI_Sort(take)
end

local function makeItem(tr)
  local item = reaper.CreateNewMIDIItemInProj(tr, 0, SPAN_QN, true)
  local take = reaper.GetActiveTake(item)
  reaper.MIDI_InsertNote(take, false, false, ppqOf(take, 0), ppqOf(take, SPAN_QN), 0, 60, 96, true)
  return take
end

-- A: msb lane LINEAR-shaped (REAPER interpolates high bits), lsb lane SQUARE
-- (low bits step at breakpoints; a ramped lsb would saw across 127->0 wraps).
local function authorShaped(take)
  local pts = SPAN_QN  -- one breakpoint per QN
  for i = 0, pts do
    local qn = i * SPAN_QN / pts
    local v  = math.floor(i / pts * 16383)
    insertCC(take, qn, MSB_LANE, v >> 7)
    insertCC(take, qn, LSB_LANE, v & 127)
  end
  setLaneShape(take, MSB_LANE, 1)  -- linear: REAPER interpolates the high bits
  setLaneShape(take, LSB_LANE, 0)  -- square: low bits step, never ramp
end

-- B: co-located square steps sampling the true 14-bit ramp. Square is
-- REAPER's default CC shape, so the node sees exactly these values.
local function authorDense(take)
  local steps = math.floor(SPAN_QN / STEP_QN)
  for i = 0, steps do
    local qn = i * STEP_QN
    local v  = math.floor(i / steps * 16383)
    insertCC(take, qn, MSB_LANE, v >> 7)
    insertCC(take, qn, LSB_LANE, v & 127)
  end
  reaper.MIDI_Sort(take)
end

----- Build / verify

local function buildTrack()
  local existing = findTrack(TRACK_NAME)
  if existing then reaper.DeleteTrack(existing) end
  reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)
  local tr = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
  reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', TRACK_NAME, true)

  local probe = addFx(tr, { PROBE })
  reaper.TrackFX_SetParam(tr, probe, 0, MSB_LANE)  -- msbcode
  reaper.TrackFX_SetParam(tr, probe, 1, LSB_LANE)  -- lsbcode
  reaper.TrackFX_SetParam(tr, probe, 2, 1)         -- emitpb
  addFx(tr, SYNTH_IDENTS)
  return tr
end

local function build(label, author)
  out(fmt('\n=== BUILD %s ===', label))
  local tr = buildTrack()
  author(makeItem(tr))
  out('Now: stop, move the cursor to the item start, hit play ONCE (no')
  out('loop). You should hear a held C glide as pitch bend follows the')
  out(fmt('14-bit ramp. Judge smoothness by ear, stop, run again to verify %s.', label))
end

local function verify(label)
  out(fmt('\n=== VERIFY %s ===', label))
  local tr = findTrack(TRACK_NAME)
  if not tr then out('spike track missing - run cleanup and start over') return end
  local probe = fxIndexByName(tr, 'shape probe')
  if not probe then out('shape_probe.jsfx not on the track') return end

  local count     = reaper.TrackFX_GetParam(tr, probe, 3)
  local maxgap    = reaper.TrackFX_GetParam(tr, probe, 4)
  local maxstep   = reaper.TrackFX_GetParam(tr, probe, 5)
  local reversals = reaper.TrackFX_GetParam(tr, probe, 6)
  local peakval   = reaper.TrackFX_GetParam(tr, probe, 7)

  out(fmt('density:   %d update points, max gap %.2f ms', count, maxgap))
  out(fmt('coherence: max step %d (of 16383), reversals %d', maxstep, reversals))
  out(fmt('peak value reached: %d  (full ramp tops out at 16383)', peakval))
  out('')
  out('read it as: reversals 0 = monotonic, no wrap glitch. max step is')
  out('the resolution grain - small = fine 14-bit, ~128 = msb-only steps.')
  out('max gap is the smoothness ceiling (REAPER ~25 ms interp for linear;')
  out('= authored spacing for square). Then run again for the next phase.')
end

local function cleanup()
  out('\n=== CLEANUP ===')
  local tr = findTrack(TRACK_NAME)
  if tr then reaper.DeleteTrack(tr) end
  out('spike track deleted; next run starts a fresh cycle')
end

----- Dispatch

local phases = {
  function() build('A (msb-shaped)', authorShaped) end,
  function() verify('A (msb-shaped)') end,
  function() build('B (dense square)', authorDense) end,
  function() verify('B (dense square)') end,
  cleanup,
}

local _, p = reaper.GetProjExtState(0, NS, 'phase')
local phase = tonumber(p) or 0

reaper.Undo_BeginBlock()
phases[phase + 1]()
reaper.Undo_EndBlock('shape spike phase ' .. (phase + 1), -1)
reaper.SetProjExtState(0, NS, 'phase', tostring((phase + 1) % #phases))
