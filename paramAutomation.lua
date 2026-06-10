-- paramAutomation.lua
--
-- The simple automation layer's applier (design/cv.md § simple layer).
-- Bindings live at the cm take tier; this module realises them into
-- REAPER: a 'Continuum CC' JSFX pinned at each involved track's chain
-- head (filter bank strips authored CCs onto the automation bus at the
-- origin; listen bank turns bus CCs into plink-source sliders), bus
-- sends fanning the automation bus out to bound tracks, and plinks
-- from value sliders to target params.

--invariant: automation bus is 126 — 127 is wiring's parking bus, wiring allocates 0..125
--invariant: authored (chan,lane) codes are track-unique across takes; bus codes project-unique
--shape: binding = { busCode=int, trackGuid=str, fxGuid=str, param=int, scale=num, offset=num, label=str }
--shape: trackSpec = { filter={ {src=code,dst=code},... }, listen={ {code,fxGuid,param,scale,offset},... }, sends={dstGuid,...} }
--contract: apply() is a full-project idempotent reconcile; mirror-matching tracks are untouched
local util = require 'util'
local cm, facade = (...).cm, (...).facade

local AUTO_BUS  = 126
local CC_IDENT  = 'JS:Continuum CC'
local SLOTS     = 16
local META_PEXT = 'P_EXT:ctm_paramAuto'
local TOP_LANE  = 119   -- 120..127 are channel-mode messages

-- Continuum CC.jsfx param banks: value sliders, then src/dst/listen codes.
local P_VALUE, P_SRC, P_DST, P_LISTEN = 0, 16, 32, 48

local pa = {}

----- REAPER lookups

local function trackByGuid(guid)
  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    if reaper.GetTrackGUID(track) == guid then return track end
  end
end

local function fxIndexByGuid(track, guid)
  for i = 0, reaper.TrackFX_GetCount(track) - 1 do
    if reaper.TrackFX_GetFXGUID(track, i) == guid then return i end
  end
end

-- fx_ident for a JSFX is the bare Effects-relative path (cf. routingManager fxIdentAt)
local function ccNodeIndex(track)
  for i = 0, reaper.TrackFX_GetCount(track) - 1 do
    local _, fxType = reaper.TrackFX_GetNamedConfigParm(track, i, 'fx_type')
    if fxType == 'JS' then
      local _, ident = reaper.TrackFX_GetNamedConfigParm(track, i, 'fx_ident')
      if ident == 'Continuum CC' then return i end
    end
  end
end

local function eachTake(visit)
  for i = 0, reaper.CountMediaItems(0) - 1 do
    local item = reaper.GetMediaItem(0, i)
    for t = 0, reaper.CountTakes(item) - 1 do
      local take = reaper.GetTake(item, t)
      if take then visit(take) end
    end
  end
end

local function boundTrack()
  local take = cm:boundTake()
  return take and reaper.GetMediaItemTake_Track(take)
end

----- Gather + desired specs

local function gatherBindings()
  local bindings = {}
  eachTake(function(take)
    local cfg = cm:readTakeKey(take, 'paramAutomation')
    if not cfg or not next(cfg) then return end
    local srcGuid = reaper.GetTrackGUID(reaper.GetMediaItemTake_Track(take))
    for chan, lanes in pairs(cfg) do
      for lane, b in pairs(lanes) do
        bindings[#bindings + 1] = {
          srcTrackGuid = srcGuid, chan = chan, lane = lane,
          busCode = b.busCode, trackGuid = b.trackGuid, fxGuid = b.fxGuid,
          param = b.param, scale = b.scale, offset = b.offset, label = b.label,
        }
      end
    end
  end)
  return bindings
end

-- Pure: bindings -> { [trackGuid] = trackSpec }. Pooled duplicates collapse
-- via the seen-keys; slot order is sorted for a stable REAPER image.
function pa.computeDesired(bindings)
  local specs, seen = {}, {}
  local function spec(guid)
    specs[guid] = specs[guid] or { filter = {}, listen = {}, sends = {} }
    return specs[guid]
  end
  local function once(...)
    local key = util.key(...)
    if seen[key] then return false end
    seen[key] = true
    return true
  end
  for _, b in ipairs(bindings) do
    local srcCode = (b.chan - 1) * 128 + b.lane
    if once('f', b.srcTrackGuid, srcCode) then
      table.insert(spec(b.srcTrackGuid).filter, { src = srcCode, dst = b.busCode })
    end
    if once('l', b.trackGuid, b.busCode) then
      table.insert(spec(b.trackGuid).listen,
        { code = b.busCode, fxGuid = b.fxGuid, param = b.param,
          scale = b.scale, offset = b.offset })
    end
    if b.srcTrackGuid ~= b.trackGuid and once('s', b.srcTrackGuid, b.trackGuid) then
      table.insert(spec(b.srcTrackGuid).sends, b.trackGuid)
    end
  end
  for _, s in pairs(specs) do
    table.sort(s.filter, function(a, b) return a.src < b.src end)
    table.sort(s.listen, function(a, b) return a.code < b.code end)
    table.sort(s.sends)
  end
  return specs
end

----- Apply

local function readMirror(track)
  local ok, raw = reaper.GetSetMediaTrackInfo_String(track, META_PEXT, '', false)
  if not ok or raw == '' then return nil end
  local parsed, val = pcall(util.unserialise, raw)
  return parsed and val or nil
end

local function writeMirror(track, spec)
  reaper.GetSetMediaTrackInfo_String(track, META_PEXT, spec and util.serialise(spec) or '', true)
end

local function setPlink(track, fxIdx, param, ccIdx, slot, scale, offset)
  local base = ('param.%d.'):format(param)
  local function set(k, v) reaper.TrackFX_SetNamedConfigParm(track, fxIdx, base .. k, tostring(v)) end
  set('mod.active', 1)
  set('mod.baseline', 0)
  set('plink.active', 1)
  set('plink.scale', scale)
  set('plink.offset', offset)
  set('plink.effect', ccIdx)
  set('plink.param', P_VALUE + slot)
end

local function clearPlink(track, fxIdx, param)
  local base = ('param.%d.'):format(param)
  reaper.TrackFX_SetNamedConfigParm(track, fxIdx, base .. 'plink.active', '0')
  reaper.TrackFX_SetNamedConfigParm(track, fxIdx, base .. 'mod.active', '0')
end

local function writeBanks(track, ccIdx, spec)
  if #spec.filter > SLOTS or #spec.listen > SLOTS then
    util.print('paramAutomation: more than ' .. SLOTS .. ' slots on one track; extras dropped')
  end
  for s = 0, SLOTS - 1 do
    local f, l = spec.filter[s + 1], spec.listen[s + 1]
    reaper.TrackFX_SetParam(track, ccIdx, P_SRC + s,    f and f.src  or -1)
    reaper.TrackFX_SetParam(track, ccIdx, P_DST + s,    f and f.dst  or -1)
    reaper.TrackFX_SetParam(track, ccIdx, P_LISTEN + s, l and l.code or -1)
  end
end

-- Ours by signature: midi-only send whose src bus is the automation bus.
-- Encoding mirrors routingManager createSend/readSendChans (bits 14/22, +1-biased).
local function reconcileAutoSends(track, dstGuids)
  local want = {}
  for _, guid in ipairs(dstGuids) do want[guid] = true end
  for i = reaper.GetTrackNumSends(track, 0) - 1, 0, -1 do
    if reaper.GetTrackSendInfo_Value(track, 0, i, 'I_SRCCHAN') == -1 then
      local flags = math.floor(reaper.GetTrackSendInfo_Value(track, 0, i, 'I_MIDIFLAGS'))
      if ((flags >> 14) & 0xFF) - 1 == AUTO_BUS then
        local dst = reaper.GetTrackSendInfo_Value(track, 0, i, 'P_DESTTRACK')
        local guid = dst and reaper.GetTrackGUID(dst)
        if guid and want[guid] then
          want[guid] = nil
        else
          reaper.RemoveTrackSend(track, 0, i)
        end
      end
    end
  end
  for guid in pairs(want) do
    local dst = trackByGuid(guid)
    if dst then
      local idx = reaper.CreateTrackSend(track, dst)
      reaper.SetTrackSendInfo_Value(track, 0, idx, 'I_SRCCHAN', -1)
      local base = math.floor(reaper.GetTrackSendInfo_Value(track, 0, idx, 'I_MIDIFLAGS'))
      reaper.SetTrackSendInfo_Value(track, 0, idx, 'I_MIDIFLAGS',
        (base & 0x3FFF) | ((AUTO_BUS + 1) << 14) | ((AUTO_BUS + 1) << 22))
    end
  end
end

local function applyTrack(track, spec, mirror)
  if not spec then
    local ccIdx = ccNodeIndex(track)
    if ccIdx then reaper.TrackFX_Delete(track, ccIdx) end
    reconcileAutoSends(track, {})
    writeMirror(track, nil)
    return
  end

  local ccIdx = ccNodeIndex(track)
  if not ccIdx then
    ccIdx = reaper.TrackFX_AddByName(track, CC_IDENT, false, -1)
    if ccIdx < 0 then error('paramAutomation: Continuum CC.jsfx not found in Effects') end
  end
  if ccIdx ~= 0 then
    reaper.TrackFX_CopyToTrack(track, ccIdx, track, 0, true)
    ccIdx = 0
  end
  writeBanks(track, ccIdx, spec)

  -- stale plinks first: targets the mirror linked that the new spec doesn't
  local live = {}
  for _, l in ipairs(spec.listen) do live[util.key(l.fxGuid, l.param)] = true end
  for _, old in ipairs(mirror and mirror.listen or {}) do
    if not live[util.key(old.fxGuid, old.param)] then
      local fxIdx = fxIndexByGuid(track, old.fxGuid)
      if fxIdx then clearPlink(track, fxIdx, old.param) end
    end
  end
  for s, l in ipairs(spec.listen) do
    if s > SLOTS then break end
    local fxIdx = fxIndexByGuid(track, l.fxGuid)
    if fxIdx then setPlink(track, fxIdx, l.param, ccIdx, s - 1, l.scale, l.offset) end
  end

  reconcileAutoSends(track, spec.sends)
  writeMirror(track, spec)
end

----- Allocation

-- Authored lanes are track-unique across takes (the filter bank is shared per
-- track): used = bound lanes, user cc columns, and event-bearing ccs on the
-- channel, across every take on the track.
local function usedLanes(srcTrack, chan)
  local used = {}
  eachTake(function(take)
    if reaper.GetMediaItemTake_Track(take) ~= srcTrack then return end
    local cfg = cm:readTakeKey(take, 'paramAutomation') or {}
    for lane in pairs(cfg[chan] or {}) do used[lane] = true end
    local extras = cm:readTakeKey(take, 'extraColumns') or {}
    for cc in pairs((extras[chan] or {}).ccs or {}) do used[cc] = true end
    if reaper.TakeIsMIDI(take) then
      local _, _, ccCount = reaper.MIDI_CountEvts(take)
      for i = 0, ccCount - 1 do
        local _, _, _, _, chanmsg, evChan, msg2 = reaper.MIDI_GetCC(take, i)
        if chanmsg == 0xB0 and evChan == chan - 1 then used[msg2] = true end
      end
    end
  end)
  return used
end

local function allocLane(srcTrack, chan)
  local used = usedLanes(srcTrack, chan)
  for cc = TOP_LANE, 0, -1 do
    if not used[cc] then return cc end
  end
end

local function allocBusCode()
  local used = {}
  eachTake(function(take)
    local cfg = cm:readTakeKey(take, 'paramAutomation') or {}
    for _, lanes in pairs(cfg) do
      for _, b in pairs(lanes) do used[b.busCode] = true end
    end
  end)
  for code = 0, 16 * 128 - 1 do
    if not used[code] then return code end
  end
end

----------- PUBLIC

--contract: no-op (and no undo point) when every track's mirror already matches
function pa:apply()
  local specs = pa.computeDesired(gatherBindings())
  local dirty = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    local spec, mirror = specs[reaper.GetTrackGUID(track)], readMirror(track)
    if not util.deepEq(spec, mirror) then
      dirty[#dirty + 1] = { track = track, spec = spec, mirror = mirror }
    end
  end
  if #dirty == 0 then return end
  util.atomic('Param automation', function()
    for _, d in ipairs(dirty) do applyTrack(d.track, d.spec, d.mirror) end
  end)()
end

--contract: chan is the tracker's 1-based channel; returns the allocated cc lane, or nil + reason
function pa:automate(chan, target)
  local srcTrack = boundTrack()
  if not srcTrack then return nil end
  local lane = allocLane(srcTrack, chan)
  if not lane then return nil, 'no free cc lane on channel ' .. chan end
  local busCode = allocBusCode()
  if not busCode then return nil, 'automation bus full' end
  local cfg = cm:get('paramAutomation')
  cfg[chan] = cfg[chan] or {}
  cfg[chan][lane] = {
    busCode = busCode,
    trackGuid = target.trackGuid, fxGuid = target.fxGuid, param = target.param,
    scale = 1, offset = 0, label = target.label,
  }
  cm:set('take', 'paramAutomation', cfg)
  self:apply()
  return lane
end

function pa:unautomate(chan, lane)
  local cfg = cm:get('paramAutomation')
  if not (cfg[chan] and cfg[chan][lane]) then return end
  cfg[chan][lane] = nil
  if not next(cfg[chan]) then cfg[chan] = nil end
  cm:set('take', 'paramAutomation', cfg)
  self:apply()
end

function pa:binding(chan, lane)
  local cfg = cm:get('paramAutomation')
  return cfg[chan] and cfg[chan][lane]
end

--contract: palette rows from the wiring facade's cone walk; {} without a take or wiring
function pa:targets()
  local srcTrack = boundTrack()
  local wiring = facade and facade.get('wiring')
  if not (srcTrack and wiring and wiring.paramTargets) then return {} end
  return wiring.paramTargets(srcTrack)
end

function pa:params(trackGuid, fxGuid)
  local track = trackByGuid(trackGuid)
  local fxIdx = track and fxIndexByGuid(track, fxGuid)
  if not fxIdx then return {} end
  local params = {}
  for p = 0, reaper.TrackFX_GetNumParams(track, fxIdx) - 1 do
    local _, name = reaper.TrackFX_GetParamName(track, fxIdx, p)
    params[#params + 1] = { index = p, name = name }
  end
  return params
end

return pa
