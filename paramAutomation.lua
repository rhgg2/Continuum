-- paramAutomation.lua
-- Simple automation applier (design/cv.md § simple layer); bindings at ds take scope, realised via JSFX + bus sends + plinks.

--invariant: automation bus is 126 — 127 is wiring's parking bus, wiring allocates 0..125
--invariant: authored (chan,lane) codes are track-unique across takes; bus codes project-unique
--shape: binding = { busCode=int, trackGuid=str, fxGuid=str, param=int, scale=num, offset=num, label=str }
--shape: trackSpec = { filter={ {src=code,dst=code},... }, listen={ {code,fxGuid,param,scale,offset},... }, sends={dstGuid,...} }
--shape: paramFrecency (ds global) = { [fxIdent] = { n=int, params={ [name]={s=num,n0=int} } } }
--contract: apply() is a full-project idempotent reconcile; mirror-matching tracks are untouched
local util = require 'util'
local cm, ds, facade, ccm = (...).cm, (...).ds, (...).facade, (...).ccm

-- Source-track resolution is logical, not physical: a parked take hosts on the
-- scratch track, but its automation belongs to the track owning its slot.
local function arrange() return facade and facade.get('arrange') end
local function ownerTrack(take) return take and arrange().ownerTrack(take) end

local AUTO_BUS  = 126
local SLOTS     = 16
local META_PEXT = 'P_EXT:ctm_paramAuto'
local TOP_LANE  = 119   -- 120..127 are channel-mode messages

-- Continuum CC.jsfx param banks: value sliders, then src/dst/listen codes.
local P_VALUE, P_SRC, P_DST, P_LISTEN = 0, 16, 32, 48

local pa = {}

----- REAPER lookups

local function trackByGuid(guid)
  -- Master is absent from the project-track list but hosts cone fx (bus comp on
  -- the mix) — matched first, mirroring routingManager's locateTrack.
  local master = reaper.GetMasterTrack(0)
  if master and reaper.GetTrackGUID(master) == guid then return master end
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

local function resolveFx(trackGuid, fxGuid)
  local track = trackByGuid(trackGuid)
  local fxIdx = track and fxIndexByGuid(track, fxGuid)
  if fxIdx then return track, fxIdx end
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
  return ownerTrack(cm:boundTake())
end

----- Gather + desired specs

local function gatherBindings()
  local bindings = {}
  eachTake(function(take)
    local cfg = ds:getAt(take, 'paramAutomation')
    if not cfg or not next(cfg) then return end
    local srcGuid = reaper.GetTrackGUID(ownerTrack(take))
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
  -- stale plinks first: targets the mirror linked that the new spec doesn't
  local live = {}
  for _, l in ipairs(spec and spec.listen or {}) do live[util.key(l.fxGuid, l.param)] = true end
  for _, old in ipairs(mirror and mirror.listen or {}) do
    if not live[util.key(old.fxGuid, old.param)] then
      local fxIdx = fxIndexByGuid(track, old.fxGuid)
      if fxIdx then clearPlink(track, fxIdx, old.param) end
    end
  end

  if not spec then
    -- ccm reaps the node only when no producer still claims it; if the add bank
    -- holds it, release hands back the surviving index so we clear just our range.
    local ccIdx = ccm:release('pa', track)
    if ccIdx then writeBanks(track, ccIdx, { filter = {}, listen = {} }) end
    reconcileAutoSends(track, {})
    writeMirror(track, nil)
    return
  end

  local ccIdx = ccm:claim('pa', track)
  writeBanks(track, ccIdx, spec)

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
    if ownerTrack(take) ~= srcTrack then return end
    local cfg = ds:getAt(take, 'paramAutomation') or {}
    for lane in pairs(cfg[chan] or {}) do used[lane] = true end
    local extras = ds:getAt(take, 'extraColumns') or {}
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
    local cfg = ds:getAt(take, 'paramAutomation') or {}
    for _, lanes in pairs(cfg) do
      for _, b in pairs(lanes) do used[b.busCode] = true end
    end
  end)
  for code = 0, 16 * 128 - 1 do
    if not used[code] then return code end
  end
end

----- Frecency + param cache

-- Frecency decays per plugin-use, not per day: each bump advances the
-- ident's counter and rebases the score, so an unused month costs nothing.
local DECAY = 0.9

local paramCache  = {}   -- [fxGuid] = { count, params, gen, sorted }
local frecencyGen = 0    -- bumped on every frecency write; stales sorted caches

local function fxIdentAt(track, fxIdx)
  local _, ident = reaper.TrackFX_GetNamedConfigParm(track, fxIdx, 'fx_ident')
  return ident ~= '' and ident or nil
end

--contract: pure, stable: decayed score desc, then param index; fxScores may be nil
function pa.frecencyOrder(params, fxScores)
  local sorted = { table.unpack(params) }
  if not fxScores then return sorted end
  local function score(prm)
    local entry = fxScores.params[prm.name]
    return entry and entry.s * DECAY ^ (fxScores.n - entry.n0) or 0
  end
  table.sort(sorted, function(a, b)
    local sa, sb = score(a), score(b)
    if sa ~= sb then return sa > sb end
    return a.index < b.index
  end)
  return sorted
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
  local cfg = ds:get('paramAutomation') or {}
  cfg[chan] = cfg[chan] or {}
  cfg[chan][lane] = {
    busCode = busCode,
    trackGuid = target.trackGuid, fxGuid = target.fxGuid, param = target.param,
    scale = 1, offset = 0, label = target.label,
  }
  ds:assign('paramAutomation', cfg)
  self:apply()
  return lane
end

function pa:unautomate(chan, lane)
  local cfg = ds:get('paramAutomation') or {}
  if not (cfg[chan] and cfg[chan][lane]) then return end
  cfg[chan][lane] = nil
  if not next(cfg[chan]) then cfg[chan] = nil end
  ds:assign('paramAutomation', cfg)
  self:apply()
end

function pa:binding(chan, lane)
  local cfg = ds:get('paramAutomation') or {}
  return cfg[chan] and cfg[chan][lane]
end

--contract: palette rows from the wiring facade's cone walk; {} without a take or wiring
function pa:targets()
  local srcTrack = boundTrack()
  local wiring = facade and facade.get('wiring')
  if not (srcTrack and wiring and wiring.paramTargets) then return {} end
  return wiring.paramTargets(srcTrack)
end

--contract: cached per fxGuid (param-count change invalidates); frecency-hot params first
function pa:params(trackGuid, fxGuid)
  local track, fxIdx = resolveFx(trackGuid, fxGuid)
  if not track then return {} end
  local count  = reaper.TrackFX_GetNumParams(track, fxIdx)
  local cached = paramCache[fxGuid]
  if not (cached and cached.count == count) then
    local params = {}
    for p = 0, count - 1 do
      local _, name = reaper.TrackFX_GetParamName(track, fxIdx, p)
      params[p + 1] = { index = p, name = name }
    end
    cached = { count = count, params = params }
    paramCache[fxGuid] = cached
  end
  if cached.gen ~= frecencyGen then
    cached.gen    = frecencyGen
    cached.sorted = pa.frecencyOrder(cached.params,
      (ds:get('paramFrecency') or {})[fxIdentAt(track, fxIdx)])
  end
  return cached.sorted
end

--contract: advances the ident's use counter; the param's score decays to it, then +1
function pa:bumpFrecency(trackGuid, fxGuid, paramName)
  local track, fxIdx = resolveFx(trackGuid, fxGuid)
  local ident = track and fxIdentAt(track, fxIdx)
  if not ident then return end
  local all = ds:get('paramFrecency') or {}
  local fxScores = all[ident] or { n = 0, params = {} }
  local n = fxScores.n + 1
  local entry = fxScores.params[paramName]
  fxScores.params[paramName] =
    { s = (entry and entry.s * DECAY ^ (n - entry.n0) or 0) + 1, n0 = n }
  fxScores.n = n
  all[ident] = fxScores
  ds:assign('paramFrecency', all)
  frecencyGen = frecencyGen + 1
end

--contract: floats the fx ui; true only when pa floated it — caller owns popping it down
function pa:floatFx(trackGuid, fxGuid)
  local track, fxIdx = resolveFx(trackGuid, fxGuid)
  if not track or reaper.TrackFX_GetFloatingWindow(track, fxIdx) then return false end
  reaper.TrackFX_Show(track, fxIdx, 3)
  return true
end

function pa:unfloatFx(trackGuid, fxGuid)
  local track, fxIdx = resolveFx(trackGuid, fxGuid)
  if track then reaper.TrackFX_Show(track, fxIdx, 2) end
end

--contract: last-touched track-fx param as guids + name; nil for take/container/input fx
function pa:lastTouched()
  local ok, trackIdx, itemIdx, _, fxIdx, param = reaper.GetTouchedOrFocusedFX(0)
  if not (ok and itemIdx == -1 and trackIdx >= 0 and fxIdx & 0x3000000 == 0) then return nil end
  local track = reaper.GetTrack(0, trackIdx)
  if not track then return nil end
  local _, name = reaper.TrackFX_GetParamName(track, fxIdx, param)
  return { trackGuid = reaper.GetTrackGUID(track),
           fxGuid    = reaper.TrackFX_GetFXGUID(track, fxIdx),
           param     = param, name = name }
end

return pa
