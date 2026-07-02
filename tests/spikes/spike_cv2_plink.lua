-- spike_cv2_plink.lua
--
-- design/cv-2.md plink-via-MIDI spike leg (gates phase 3). The spine
-- decodes all parameter modulation through native MIDI plink
-- (plink.effect = -100 + plink.midi_*), which cv.md confirmed at
-- API-shape level only. Run as a ReaScript action; each invocation
-- advances one phase:
--
--   1. BASELINE    - dest track [ReaSynth, ReaEQ], authored CC20 ramps on
--                    the plain stream, plink on ReaEQ band-1 freq set by
--                    API with first-guess midi_* values. Proves the midi_*
--                    path works API-written and that a chain-head stream
--                    reaches a plink on a non-head FX.
--   2. DUMP PLAIN  - hand-link CC20 (plain) in the param-mod dialog first;
--                    this run dumps every plink.*/learn.* key to learn the
--                    UI's own encoding (chan/bus indexing).
--   3. DUMP 14BIT  - same after flipping the UI link to CC 20 (14-bit);
--                    the dump is stored and replayed by phase 4.
--   4. BUS 126     - source track: cv2_emit (14-bit slow narrow ramp) ->
--                    midi-only send on bus 126; replays the stored config
--                    with midi_bus=126 (retries 127 in-run if dead). A
--                    poller measures the param step: ~1/16383 = 14-bit
--                    reads, ~1/127 = MSB only, no movement = bus fail.
--   5. STRIP PROBE - cv2_strip at the dest chain head consumes the coded
--                    lane. Param still moving = plink reads the raw track
--                    input (a filter node cannot shield it); dead = plink
--                    reads the chain stream at the FX position.
--   6. IN-CHAIN    - send muted, strip gone, cv2_emit at the dest chain
--                    head: does a same-chain upstream emitter reach the
--                    plink? Go/no-go for the in-chain sum realization.
--   7. HOLD        - emitter frozen (delta-suppressed = silent); poller
--                    watches the param for 30 s while you seek, loop-wrap
--                    and stop/start. Any movement is logged; none = plink
--                    holds the last value.
--   8. CLEANUP     - delete both tracks, reset all spike state.

local reaper = reaper
local fmt = string.format

local NS       = 'ctm_cv2_spike'
local DST_NAME = 'ctm_cv2_dst'
local SRC_NAME = 'ctm_cv2_src'

local EMIT  = 'JS:Continuum CV spike - cv2 coded emitter (bus-126 plink source)'
local STRIP = 'JS:Continuum CV spike - cv2 lane strip (chain-stream shield probe)'
local SYNTH_IDENTS = { 'VST:ReaSynth (Cockos)', 'VST3:ReaSynth (Cockos)', 'ReaSynth' }
local EQ_IDENTS    = { 'VST:ReaEQ (Cockos)', 'VST3:ReaEQ (Cockos)', 'ReaEQ' }

local LANE = 20    -- MSB cc; the LSB rides LANE+32
local BUS  = 126   -- the spine (JSFX 0-based bus)

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

local function shapeLane(take, lane)
  local _, _, ccCnt = reaper.MIDI_CountEvts(take)
  for i = 0, ccCnt - 1 do
    local _, _, _, _, _, _, msg2 = reaper.MIDI_GetCC(take, i)
    if msg2 == lane then reaper.MIDI_SetCCShape(take, i, 1, 0, true) end
  end
  reaper.MIDI_Sort(take)
end

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

----- plink config

local PLINK_KEYS = { 'active', 'scale', 'offset', 'effect', 'param',
                     'midi_bus', 'midi_chan', 'midi_msg', 'midi_msg2' }
local OTHER_KEYS = { 'mod.active', 'mod.baseline', 'mod.visible',
                     'learn.midi1', 'learn.midi2', 'learn.mode', 'learn.flags' }

local function dumpParamMod(tr, fx, param)
  local base = fmt('param.%d.', param)
  local plinkVals = {}
  local function rd(key)
    local ok, v = reaper.TrackFX_GetNamedConfigParm(tr, fx, base .. key)
    out(fmt('  %s%s = %s', base, key, ok and v or '(unreadable)'))
    return ok and v or nil
  end
  for _, k in ipairs(PLINK_KEYS) do plinkVals['plink.' .. k] = rd('plink.' .. k) end
  for _, k in ipairs(OTHER_KEYS) do rd(k) end
  return plinkVals
end

-- ordered: effect must be -100 before midi_* keys are meaningful
local function setParamMod(tr, fx, param, orderedKv)
  local base = fmt('param.%d.', param)
  for _, pair in ipairs(orderedKv) do
    reaper.TrackFX_SetNamedConfigParm(tr, fx, base .. pair[1], tostring(pair[2]))
  end
end

local function applyStoredPlink(tr, fx, param, busVal)
  local _, blob = reaper.GetProjExtState(0, NS, 'plink14')
  if blob == '' then return false end
  local orderedKv = { { 'mod.active', 1 }, { 'mod.baseline', 0 } }
  for k, v in blob:gmatch('([%w_.]+)=([^;]*)') do
    if k == 'plink.midi_bus' then v = tostring(busVal) end
    orderedKv[#orderedKv + 1] = { k, v }
  end
  setParamMod(tr, fx, param, orderedKv)
  return true
end

----- Param poller (defer loop; polling phases return before it finishes)

local function pollParam(tr, fx, param, seconds, label, verbose, onDone)
  local t0 = reaper.time_precise()
  local last = reaper.TrackFX_GetParamNormalized(tr, fx, param)
  local changes, minStep = 0, math.huge
  local function tick()
    local v = reaper.TrackFX_GetParamNormalized(tr, fx, param)
    if v ~= last then
      changes = changes + 1
      local step = math.abs(v - last)
      if step < minStep then minStep = step end
      if verbose then
        out(fmt('  %5.1fs  %.6f -> %.6f  (playstate %d)',
                reaper.time_precise() - t0, last, v, reaper.GetPlayState()))
      end
      last = v
    end
    if reaper.time_precise() - t0 < seconds then
      reaper.defer(tick)
    else
      out(fmt('%s: %d changes over %ds, min step %s', label, changes, seconds,
              minStep < math.huge and fmt('%.6f', minStep) or 'n/a'))
      onDone(changes, minStep)
    end
  end
  tick()
end

----- Emitter setup

-- sliders: 1 lane, 2 mode(1=14-bit), 3 period s, 4 freeze, 5 order(1=LSB first),
-- 6 bus, 7 depth counts, 8 base counts. Narrow slow ramp: 1024 counts over 8 s
-- crosses 8 MSB buckets, and poller-visible steps stay far under 7-bit grain.
local function setEmitter(tr, fx)
  local vals = { LANE, 1, 8, 0, 1, BUS, 1024, 8192 }
  for i, v in ipairs(vals) do reaper.TrackFX_SetParam(tr, fx, i - 1, v) end
end

----- Phases

local function buildBaseline()
  out('\n=== phase 1: BASELINE (API-set midi_* link, plain stream) ===')
  reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)
  local tr = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
  reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', DST_NAME, true)
  addFx(tr, SYNTH_IDENTS)
  local eqIdx = addFx(tr, EQ_IDENTS)

  local take = makeMidiItem(tr)
  reaper.MIDI_InsertNote(take, false, false, ppqOf(take, 0), ppqOf(take, 16), 0, 48, 96, true)
  reaper.MIDI_InsertNote(take, false, false, ppqOf(take, 16), ppqOf(take, 32), 0, 55, 96, true)
  buildLaneRamps(take, LANE)

  local freqP, freqName = findParam(tr, eqIdx, '^Freq')
  out(fmt('target: ReaEQ fx %d param %d (%s), chain position %d (not head)',
          eqIdx, freqP, freqName, eqIdx))
  setParamMod(tr, eqIdx, freqP, {
    { 'mod.active', 1 }, { 'mod.baseline', 0 },
    { 'plink.active', 1 }, { 'plink.scale', 1 }, { 'plink.offset', 0 },
    { 'plink.effect', -100 },
    { 'plink.midi_bus', 0 }, { 'plink.midi_chan', 0 },
    { 'plink.midi_msg', 176 }, { 'plink.midi_msg2', LANE },
  })
  out('readback:')
  dumpParamMod(tr, eqIdx, freqP)
  out('\nPlay: the freq should ride the CC20 ramps (API-written midi_* +')
  out('chain-head stream -> non-head plink). Then hand-relink the SAME')
  out('param via the param-mod dialog: MIDI link, CC 20 plain - even if')
  out('the API guess works, phase 2 wants the UI\'s own encoding. Run again.')
end

local function dumpPlain()
  out('\n=== phase 2: DUMP AFTER UI PLAIN-CC LINK ===')
  local dst = findTrack(DST_NAME)
  if not dst then out('dest track missing - run cleanup and start over') return end
  local eq = fxIndexByName(dst, 'ReaEQ')
  local freqP = findParam(dst, eq, '^Freq')
  out('(expects the link hand-set in the UI: CC 20, plain)')
  dumpParamMod(dst, eq, freqP)
  out('\nNow flip the same link to CC 20 (14-bit) in the dialog, run again.')
end

local function dump14bit()
  out('\n=== phase 3: DUMP AFTER UI 14-BIT LINK ===')
  local dst = findTrack(DST_NAME)
  if not dst then out('dest track missing - run cleanup and start over') return end
  local eq = fxIndexByName(dst, 'ReaEQ')
  local freqP = findParam(dst, eq, '^Freq')
  out('(expects the link hand-set in the UI: CC 20, 14-bit)')
  local vals = dumpParamMod(dst, eq, freqP)
  local parts = {}
  for _, k in ipairs(PLINK_KEYS) do
    local v = vals['plink.' .. k]
    if v then parts[#parts + 1] = fmt('plink.%s=%s', k, v) end
  end
  reaper.SetProjExtState(0, NS, 'plink14', table.concat(parts, ';'))
  out('\n14-bit key set stored; diff it against phase 2 by eye - the delta')
  out('IS the 14-bit encoding. Run again to build the bus-126 rig.')
end

local function buildBus126()
  out('\n=== phase 4: BUS 126 CROSS-TRACK (stored 14-bit config replayed) ===')
  local dst = findTrack(DST_NAME)
  if not dst then out('dest track missing - run cleanup and start over') return end
  local _, blob = reaper.GetProjExtState(0, NS, 'plink14')
  if blob == '' then out('no stored 14-bit dump - phases 2-3 must run first') return end

  -- baseline item off the stream: from here only coded traffic drives the param
  local item = reaper.GetTrackMediaItem(dst, 0)
  if item then reaper.DeleteTrackMediaItem(dst, item) end

  reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)
  local src = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
  reaper.GetSetMediaTrackInfo_String(src, 'P_NAME', SRC_NAME, true)
  reaper.SetMediaTrackInfo_Value(src, 'B_MAINSEND', 0)

  local emitIdx = addFx(src, { EMIT })
  setEmitter(src, emitIdx)

  local sendIdx = reaper.CreateTrackSend(src, dst)
  reaper.SetTrackSendInfo_Value(src, 0, sendIdx, 'I_SRCCHAN', -1)  -- midi only
  local flags = math.floor(reaper.GetTrackSendInfo_Value(src, 0, sendIdx, 'I_MIDIFLAGS'))
  reaper.SetTrackSendInfo_Value(src, 0, sendIdx, 'I_MIDIFLAGS',
    (flags & 0x3FFF) | ((BUS + 1) << 14) | ((BUS + 1) << 22))

  local eq = fxIndexByName(dst, 'ReaEQ')
  local freqP = findParam(dst, eq, '^Freq')

  local function verdict(minStep)
    if minStep < 0.002 then
      out('-> 14-BIT reads CONFIRMED (step ~1/16383)')
    elseif minStep < 0.02 then
      out('-> moves at 7-bit grain: MSB read, LSB IGNORED')
    else
      out('-> moves, but the step size fits neither width - inspect by hand')
    end
    out('Flip the emitter\'s pair-order slider and re-watch the param for')
    out('glitches (LSB-first is canonical). Then run again: strip probe.')
  end

  local function attempt(busVal, onFail)
    applyStoredPlink(dst, eq, freqP, busVal)
    out(fmt('stored config applied with plink.midi_bus=%d; polling 8 s...', busVal))
    pollParam(dst, eq, freqP, 8, fmt('midi_bus=%d', busVal), false,
      function(changes, minStep)
        if changes == 0 then onFail()
        else
          reaper.SetProjExtState(0, NS, 'busval', tostring(busVal))
          verdict(minStep)
        end
      end)
  end

  attempt(BUS, function()
    out('no movement with midi_bus=126 - retrying 127 (key may be 1-based)')
    attempt(BUS + 1, function()
      out('-> no movement on either: plink does NOT read JSFX-bus traffic.')
      out('   The spine\'s native-decode leg FAILS - back to the design.')
    end)
  end)
end

local function stripProbe()
  out('\n=== phase 5: STRIP PROBE (chain stream vs raw input) ===')
  local dst = findTrack(DST_NAME)
  if not dst then out('dest track missing - run cleanup and start over') return end
  local stripIdx = addFx(dst, { STRIP })
  reaper.TrackFX_CopyToTrack(dst, stripIdx, dst, 0, true)  -- to chain head
  reaper.TrackFX_SetParam(dst, 0, 0, LANE)
  reaper.TrackFX_SetParam(dst, 0, 1, BUS)
  local eq = fxIndexByName(dst, 'ReaEQ')
  local freqP = findParam(dst, eq, '^Freq')
  out('strip at the chain head consumes the coded lane; polling 8 s...')
  pollParam(dst, eq, freqP, 8, 'strip probe', false, function(changes)
    local stripped = math.floor(
      reaper.TrackFX_GetParam(dst, fxIndexByName(dst, 'cv2 lane strip'), 2))
    out(fmt('strip consumed %d events', stripped))
    if stripped == 0 then
      out('-> strip saw NO coded traffic: send-delivered bus events do not')
      out('   enter the chain MIDI stream (in-chain consumers are blind to them)')
    elseif changes > 0 then
      out('-> param STILL MOVES with the lane stripped from the chain:')
      out('   plink reads the RAW TRACK INPUT - a filter node cannot shield it')
    else
      out('-> param went dead: plink reads the CHAIN STREAM at the FX position')
      out('   (upstream FX can shield or rewrite what a plink sees)')
    end
    out('run again for the in-chain probe.')
  end)
end

local function inChainProbe()
  out('\n=== phase 6: IN-CHAIN EMITTER (go/no-go for the in-chain sum) ===')
  local dst, src = findTrack(DST_NAME), findTrack(SRC_NAME)
  if not (dst and src) then out('spike tracks missing - run cleanup and start over') return end
  reaper.SetTrackSendInfo_Value(src, 0, 0, 'B_MUTE', 1)
  local stripIdx = fxIndexByName(dst, 'cv2 lane strip')
  if stripIdx then reaper.TrackFX_Delete(dst, stripIdx) end
  local emitIdx = addFx(dst, { EMIT })
  reaper.TrackFX_CopyToTrack(dst, emitIdx, dst, 0, true)
  setEmitter(dst, 0)
  reaper.TrackFX_SetParam(dst, 0, 7, 2048)  -- distinct base: movement provably ours
  local eq = fxIndexByName(dst, 'ReaEQ')
  local freqP = findParam(dst, eq, '^Freq')
  out('send muted; emitter now sits at the DEST chain head; polling 8 s...')
  pollParam(dst, eq, freqP, 8, 'in-chain probe', false, function(changes)
    if changes > 0 then
      out('-> same-chain FX emission REACHES the plink: in-chain sum viable')
    else
      out('-> plink is BLIND to same-chain FX MIDI: fan-in must realize')
      out('   cross-track (own code per contributor + sum node) in every case')
    end
    out('run again for the hold test.')
  end)
end

local function holdTest()
  out('\n=== phase 7: HOLD ACROSS SEEK / LOOP / STOP ===')
  local dst, src = findTrack(DST_NAME), findTrack(SRC_NAME)
  if not (dst and src) then out('spike tracks missing - run cleanup and start over') return end
  local dstEmit = fxIndexByName(dst, 'cv2 coded emitter')
  if dstEmit then reaper.TrackFX_Delete(dst, dstEmit) end
  reaper.SetTrackSendInfo_Value(src, 0, 0, 'B_MUTE', 0)
  local srcEmit = fxIndexByName(src, 'cv2 coded emitter')
  local eq = fxIndexByName(dst, 'ReaEQ')
  local freqP = findParam(dst, eq, '^Freq')
  out('wire live for 3 s so a fresh value lands...')
  pollParam(dst, eq, freqP, 3, 'pre-freeze (should move)', false, function()
    reaper.TrackFX_SetParam(src, srcEmit, 3, 1)
    out('emitter FROZEN - the wire is now silent (delta suppression).')
    out('Next 30 s: seek around, play a loop across a wrap, stop + restart.')
    pollParam(dst, eq, freqP, 30, 'hold test', true, function(changes)
      local final = reaper.TrackFX_GetParamNormalized(dst, eq, freqP)
      if changes == 0 then
        out('-> plink HELD across seek/loop/stop: encoder silence is safe')
      elseif final < 0.01 then
        out('-> value fell to BASELINE: plink drops its hold on transport;')
        out('   encoders must re-emit on play-start')
      else
        out(fmt('-> value moved to %.4f, not baseline: the ENCODER re-asserted',
                final))
        out('   on transport (its state reset); plink itself held. Safe.')
      end
      out('run again to clean up.')
    end)
  end)
end

local function cleanup()
  out('\n=== phase 8: CLEANUP ===')
  for _, name in ipairs{ DST_NAME, SRC_NAME } do
    local tr = findTrack(name)
    if tr then reaper.DeleteTrack(tr) end
  end
  reaper.SetProjExtState(0, NS, 'plink14', '')
  reaper.SetProjExtState(0, NS, 'busval', '')
  out('spike tracks deleted; next run starts a fresh cycle')
end

----- Dispatch

local phases = { buildBaseline, dumpPlain, dump14bit, buildBus126,
                 stripProbe, inChainProbe, holdTest, cleanup }
local _, p = reaper.GetProjExtState(0, NS, 'phase')
local phase = tonumber(p) or 0

reaper.Undo_BeginBlock()
phases[phase + 1]()
reaper.Undo_EndBlock('cv2 plink spike phase ' .. (phase + 1), -1)
reaper.SetProjExtState(0, NS, 'phase', tostring((phase + 1) % #phases))
