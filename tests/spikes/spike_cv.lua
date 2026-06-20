-- spike_cv.lua
--
-- design/cv.md phase-1 spike. Verifies, on a live scratch chain:
--   simple layer: strip safety, CC-shape render density, slider->param
--   plink, plink keying under FX reorder;
--   cv leg: CC take -> converter take FX -> send -> adapter slider ->
--   plink, end-to-end latency.
--
-- Run as a ReaScript action, ideally bound to a hotkey - each invocation
-- advances one phase:
--
--   1. BUILD SIMPLE  - scratch track [cv_feed, cv_meter, ReaSynth, ReaEQ],
--      MIDI item with drone notes, bank select, CC1, and shaped ramps on
--      the designated lane (CC20). plinks ReaEQ band-1 freq to the feed's
--      value slider. Play it: the freq should follow the ramps. Judge
--      latency by ear/eye, then run again.
--   2. VERIFY SIMPLE - reads the meters (strip + pass-through + density),
--      then moves cv_feed to the end of the chain and back, reading
--      plink.effect at each step to settle index-vs-follow keying.
--   3. BUILD CV LEG  - child track with a CC-only item (CC21) + cv_convert
--      take FX, audio send to spike track ch 3/4, cv_adapter pinned to
--      ch 3, plinked to ReaEQ band-1 gain. Play and judge the cv path.
--   4. CLEANUP       - deletes both tracks, resets phase.

local reaper = reaper
local fmt = string.format

local NS         = 'ctm_cv_spike'
local TRACK_NAME = 'ctm_cv_spike'
local SRC_NAME   = 'ctm_cv_src'

local FEED    = 'JS:Continuum CV/cv_feed.jsfx'
local METER   = 'JS:Continuum CV/cv_meter.jsfx'
local CONVERT = 'JS:Continuum CV/cv_convert.jsfx'
local ADAPTER = 'JS:Continuum CV/cv_adapter.jsfx'
local SYNTH_IDENTS = { 'VST:ReaSynth (Cockos)', 'VST3:ReaSynth (Cockos)', 'ReaSynth' }
local EQ_IDENTS    = { 'VST:ReaEQ (Cockos)', 'VST3:ReaEQ (Cockos)', 'ReaEQ' }

local DESIG_LANE = 20   -- simple layer, inline in the performance take
local CV_LANE    = 21   -- cv leg, in the child CC-only take

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

local function fxIndexByGuid(tr, guid)
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    if reaper.TrackFX_GetFXGUID(tr, i) == guid then return i end
  end
end

local function findParam(tr, fx, pat)
  for p = 0, reaper.TrackFX_GetNumParams(tr, fx) - 1 do
    local _, name = reaper.TrackFX_GetParamName(tr, fx, p)
    if name:match(pat) then return p, name end
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

-- linear shape on every CC of one lane; REAPER may or may not render
-- interpolated events between the authored points - that is the test
local function shapeLane(take, lane)
  local _, _, ccCnt = reaper.MIDI_CountEvts(take)
  for i = 0, ccCnt - 1 do
    local _, _, _, _, _, _, msg2 = reaper.MIDI_GetCC(take, i)
    if msg2 == lane then reaper.MIDI_SetCCShape(take, i, 1, 0, true) end
  end
  reaper.MIDI_Sort(take)
end

-- dense authored ramp (qn 0-8, 9 points), then a sparse 2-point linear
-- span (qn 16-31): if interpolation is rendered, max gap stays small in
-- the sparse span too
local function buildLaneRamps(take, lane)
  for i = 0, 8 do insertCC(take, i, lane, math.floor(i * 127 / 8)) end
  insertCC(take, 16, lane, 127)
  insertCC(take, 31, lane, 0)
  shapeLane(take, lane)
end

local function makeMidiItem(tr)
  local item = reaper.CreateNewMIDIItemInProj(tr, 0, 32, true)
  return reaper.GetActiveTake(item)
end

----- plink

local function plinkSet(tr, fx, param, srcFx, srcParam)
  local base = fmt('param.%d.', param)
  local function set(k, v) reaper.TrackFX_SetNamedConfigParm(tr, fx, base .. k, v) end
  set('mod.active', '1')
  set('mod.baseline', '0')
  set('plink.active', '1')
  set('plink.scale', '1')
  set('plink.offset', '0')
  set('plink.effect', tostring(srcFx))
  set('plink.param', tostring(srcParam))
  for _, k in ipairs{ 'mod.active', 'plink.active', 'plink.effect', 'plink.param', 'plink.scale' } do
    local ok, v = reaper.TrackFX_GetNamedConfigParm(tr, fx, base .. k)
    out(fmt('  set %s%s -> readback %s%s', base, k, tostring(v), ok and '' or ' (READBACK FAILED)'))
  end
end

local function plinkEffect(tr, fx, param)
  local _, v = reaper.TrackFX_GetNamedConfigParm(tr, fx, fmt('param.%d.plink.effect', param))
  return tonumber(v)
end

----- Phases

local function buildSimple()
  out('\n=== phase 1: BUILD SIMPLE ===')
  reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)
  local tr = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
  reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', TRACK_NAME, true)

  local feedIdx = addFx(tr, { FEED })
  addFx(tr, { METER })
  addFx(tr, SYNTH_IDENTS)
  local eqIdx = addFx(tr, EQ_IDENTS)

  local take = makeMidiItem(tr)
  reaper.MIDI_InsertNote(take, false, false, ppqOf(take, 0), ppqOf(take, 16), 0, 48, 96, true)
  reaper.MIDI_InsertNote(take, false, false, ppqOf(take, 16), ppqOf(take, 32), 0, 55, 96, true)
  -- receiver-bound events the feed must NOT strip
  insertCC(take, 0, 0, 0)
  insertCC(take, 0, 32, 0)
  for i = 0, 3 do insertCC(take, 4 + i, 1, 40 + i * 10) end
  buildLaneRamps(take, DESIG_LANE)

  local freqP, freqName = findParam(tr, eqIdx, '^Freq')
  out(fmt('plink target: ReaEQ fx %d param %d (%s) <- cv_feed fx %d param 1 (value slider)',
          eqIdx, freqP, freqName, feedIdx))
  plinkSet(tr, eqIdx, freqP, feedIdx, 1)

  out('Now: hit play. ReaEQ band-1 freq should ride the CC20 ramps')
  out('(dense bars 1-2, then one long sparse linear span). Judge latency')
  out('and smoothness by ear/eye, stop playback, run the script again.')
end

local function verifySimple()
  out('\n=== phase 2: VERIFY SIMPLE ===')
  local tr = findTrack(TRACK_NAME)
  if not tr then out('spike track missing - run cleanup phase and start over') return end
  -- JSFX report their desc line as the FX name, not the filename
  local feed  = fxIndexByName(tr, 'cc feed')
  local meter = fxIndexByName(tr, 'MIDI meter')
  local eq    = fxIndexByName(tr, 'ReaEQ')

  local watched = reaper.TrackFX_GetParam(tr, meter, 1)
  local bank    = reaper.TrackFX_GetParam(tr, meter, 2)
  local other   = reaper.TrackFX_GetParam(tr, meter, 3)
  local notes   = reaper.TrackFX_GetParam(tr, meter, 4)
  out(fmt('strip: designated lane seen downstream %d times  %s',
          watched, watched == 0 and 'PASS' or 'FAIL'))
  out(fmt('pass-through: bank-select %d, other cc %d, note-ons %d  %s',
          bank, other, notes,
          (bank > 0 and other > 0 and notes > 0) and 'PASS' or 'FAIL'))

  local count  = reaper.TrackFX_GetParam(tr, feed, 3)
  local maxgap = reaper.TrackFX_GetParam(tr, feed, 2)
  out(fmt('density: feed saw %d ccs, max gap %.1f ms', count, maxgap))
  out('  (sparse span = 15 QN between authored points; max gap well under')
  out('   that span\'s wall time -> REAPER renders interpolated CC between')
  out('   shaped points; max gap ~= the span -> authored points only)')

  -- plink keying under reorder: move feed to chain end, then back
  local freqP = findParam(tr, eq, '^Freq')
  local feedGuid, eqGuid = reaper.TrackFX_GetFXGUID(tr, feed), reaper.TrackFX_GetFXGUID(tr, eq)
  out(fmt('reorder: plink.effect before move = %d (feed at %d)', plinkEffect(tr, eq, freqP), feed))

  reaper.TrackFX_CopyToTrack(tr, feed, tr, reaper.TrackFX_GetCount(tr) - 1, true)
  local feed2, eq2 = fxIndexByGuid(tr, feedGuid), fxIndexByGuid(tr, eqGuid)
  local effMoved = plinkEffect(tr, eq2, freqP)
  out(fmt('reorder: feed moved to %d; plink.effect now = %s  -> %s',
          feed2, tostring(effMoved),
          effMoved == feed2 and 'FOLLOWS the FX (no re-pointing needed)'
                            or 'INDEX-KEYED (applier must re-point on reorder)'))

  reaper.TrackFX_CopyToTrack(tr, feed2, tr, 0, true)
  local feed3, eq3 = fxIndexByGuid(tr, feedGuid), fxIndexByGuid(tr, eqGuid)
  out(fmt('reorder: feed restored to %d; plink.effect = %s',
          feed3, tostring(plinkEffect(tr, eq3, freqP))))
  out('Play again to confirm modulation still tracks after the round-trip,')
  out('then run the script again for the cv leg.')

  out('\nsame-track-only note: the plink key set (param.X.plink.*) has no')
  out('track addressing at all - effect is a same-chain FX index (or -100')
  out('for MIDI). Cross-track plink does not exist; per-destination')
  out('adapters are confirmed by API shape.')
end

local function buildCvLeg()
  out('\n=== phase 3: BUILD CV LEG ===')
  local dst = findTrack(TRACK_NAME)
  if not dst then out('spike track missing - run cleanup phase and start over') return end

  reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)
  local src = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
  reaper.GetSetMediaTrackInfo_String(src, 'P_NAME', SRC_NAME, true)
  reaper.SetMediaTrackInfo_Value(src, 'B_MAINSEND', 0)  -- DC must not reach the master

  local take = makeMidiItem(src)
  buildLaneRamps(take, CV_LANE)
  local cvtIdx = reaper.TakeFX_AddByName(take, CONVERT, -1)
  reaper.TakeFX_SetParam(take, cvtIdx, 0, CV_LANE)

  reaper.SetMediaTrackInfo_Value(dst, 'I_NCHAN', 4)
  local sendIdx = reaper.CreateTrackSend(src, dst)
  reaper.SetTrackSendInfo_Value(src, 0, sendIdx, 'I_DSTCHAN', 2)    -- ch 3/4
  reaper.SetTrackSendInfo_Value(src, 0, sendIdx, 'I_MIDIFLAGS', 31) -- audio only

  local adIdx = addFx(dst, { ADAPTER })
  reaper.TrackFX_SetPinMappings(dst, adIdx, 0, 0, 1 << 2, 0)  -- input pin <- ch 3
  reaper.TrackFX_SetPinMappings(dst, adIdx, 1, 0, 0, 0)       -- writes no audio

  local eq = fxIndexByName(dst, 'ReaEQ')
  local gainP, gainName = findParam(dst, eq, '^Gain')
  out(fmt('plink target: ReaEQ param %d (%s) <- cv_adapter fx %d param 0', gainP, gainName, adIdx))
  out('(note: adapter sits AFTER ReaEQ in the chain - readback + live test')
  out(' tell us whether a later-in-chain plink source works)')
  plinkSet(dst, eq, gainP, adIdx, 0)

  out('Now: hit play. CC21 on the child track should sweep ReaEQ band-1')
  out('gain via take FX -> send -> adapter -> plink. Judge latency vs the')
  out('inline leg, then run the script again to clean up.')
end

local function cleanup()
  out('\n=== phase 4: CLEANUP ===')
  for _, name in ipairs{ TRACK_NAME, SRC_NAME } do
    local tr = findTrack(name)
    if tr then reaper.DeleteTrack(tr) end
  end
  out('spike tracks deleted; next run starts a fresh cycle')
end

----- Dispatch

local phases = { buildSimple, verifySimple, buildCvLeg, cleanup }
local _, p = reaper.GetProjExtState(0, NS, 'phase')
local phase = tonumber(p) or 0

reaper.Undo_BeginBlock()
phases[phase + 1]()
reaper.Undo_EndBlock('cv spike phase ' .. (phase + 1), -1)
reaper.SetProjExtState(0, NS, 'phase', tostring((phase + 1) % #phases))
