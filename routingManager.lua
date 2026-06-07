-- See docs/routingManager.md for the model. A thin record abstraction over
-- REAPER's audio/MIDI graph.
--invariant: id is a track/fx GUID string — opaque to callers, stable across reload
--invariant: stateless — ids are guid-backed, so nothing is minted or reset

local util = require('util')

local PROJ = 0

local rm = {}
local installedFxCache = nil  -- reaper's installed-FX set is fixed at runtime

----------- track resolution

-- Stable under reordering. Master matched first since it is absent
-- from the project-track list.
local function locateTrack(id)
  local master = reaper.GetMasterTrack(PROJ)
  if master and reaper.GetTrackGUID(master) == id then return master end
  for i = 0, reaper.CountTracks(PROJ) - 1 do
    local track = reaper.GetTrack(PROJ, i)
    if reaper.GetTrackGUID(track) == id then return track end
  end
end

----------- fx resolution

local function locateFx(id)
  local function indexIn(track)
    for idx = 0, reaper.TrackFX_GetCount(track) - 1 do
      if reaper.TrackFX_GetFXGUID(track, idx) == id then return idx end
    end
  end
  local master = reaper.GetMasterTrack(PROJ)
  if master then local idx = indexIn(master); if idx then return master, idx end end
  for i = 0, reaper.CountTracks(PROJ) - 1 do
    local track = reaper.GetTrack(PROJ, i)
    local idx = indexIn(track)
    if idx then return track, idx end
  end
end

----------- pin maps

-- Pair P occupies channels 2(P-1)/2(P-1)+1. A port owns two pins (left/right bit
-- masks); a pair is connected when its bit is set across both pins.

-- Adjacent set bits collapse to one pair; lLo|hLo merges the port's two pins.
local function decodePairList(track, fxIdx, isoutput, port)
  local lowPin = 2 * (port - 1)
  local mask   = reaper.TrackFX_GetPinMappings(track, fxIdx, isoutput, lowPin)
               | reaper.TrackFX_GetPinMappings(track, fxIdx, isoutput, lowPin + 1)
  local pairs, lastPair = {}, nil
  for bit = 0, 31 do
    if ((mask >> bit) & 1) == 1 then
      local pair = (bit >> 1) + 1
      if pair ~= lastPair then util.add(pairs, pair); lastPair = pair end
    end
  end
  return pairs
end

-- ports = pins/2; disconnected ports (zero mask) dropped — absent ⇒ disconnected.
local function readPinMaps(track, fxIdx)
  local _, ins, outs = reaper.TrackFX_GetIOSize(track, fxIdx)
  local function dirMap(isoutput, pinCount)
    local out = {}
    for port = 1, math.floor(pinCount / 2) do
      local pairList = decodePairList(track, fxIdx, isoutput, port)
      if #pairList > 0 then out[port] = pairList end
    end
    return out
  end
  return { ins = dirMap(0, ins), outs = dirMap(1, outs) }
end

local function pinName(track, fxIdx, dir, pin)
  local ok, v = reaper.TrackFX_GetNamedConfigParm(track, fxIdx, dir .. '_pin_' .. pin)
  return ok and v ~= '' and v or nil
end

-- Port P (1-indexed) groups pins 2(P-1) and 2P-1. "Sidechain L" + "Sidechain R"
-- collapse to "Sidechain"; a mismatched pair keeps the left pin's name.
local function portNames(track, fxIdx, dir, pinCount)
  local out = {}
  for port = 1, math.floor(pinCount / 2) do
    local left  = pinName(track, fxIdx, dir, 2 * (port - 1))     or ''
    local right = pinName(track, fxIdx, dir, 2 * (port - 1) + 1) or ''
    local lPre, rPre = left:match('^(.+)%s+L$'), right:match('^(.+)%s+R$')
    if lPre and lPre == rPre then out[port] = lPre
    else                          out[port] = left ~= '' and left or nil end
  end
  return out
end

local function pinMaskFor(pairList, pinOffset)
  local lo, hi = 0, 0
  for _, pair in ipairs(pairList) do
    local bit = 2 * (pair - 1) + pinOffset
    if bit < 32 then lo = lo | (1 << bit)
    else             hi = hi | (1 << (bit - 32))
    end
  end
  return lo, hi
end

-- Full-replace per fx: ports absent from `pm` are disconnected (zero mask).
local function writePinMaps(track, fxIdx, pm)
  local _, ins, outs = reaper.TrackFX_GetIOSize(track, fxIdx)
  local function dir(isoutput, pinCount, byPort)
    byPort = byPort or {}
    for port = 1, math.floor(pinCount / 2) do
      local pairList = byPort[port] or {}
      for pinOffset = 0, 1 do
        reaper.TrackFX_SetPinMappings(track, fxIdx, isoutput,
                                      2 * (port - 1) + pinOffset, pinMaskFor(pairList, pinOffset))
      end
    end
  end
  dir(0, ins,  pm.ins)
  dir(1, outs, pm.outs)
end

----------- per-fx midi routing

-- No ReaScript API for per-FX in/out bus + output-passthrough; patch the track
-- state chunk directly. See docs/wiringManager.md § Per-FX MIDI routing.

local b64alpha = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local b64dec   = {}
for i = 1, #b64alpha do b64dec[b64alpha:sub(i, i):byte()] = i - 1 end

local function b64decode(s)
  local bytes, buf, bits = {}, 0, 0
  for i = 1, #s do
    local c = s:byte(i)
    if c == 61 then break end  -- '='
    local v = b64dec[c]
    if v then
      buf  = buf * 64 + v
      bits = bits + 6
      if bits >= 8 then
        bits = bits - 8
        local b = buf >> bits
        buf = buf - (b << bits)
        bytes[#bytes + 1] = string.char(b)
      end
    end
  end
  return table.concat(bytes)
end

local function b64encode(s)
  local out, buf, bits = {}, 0, 0
  for i = 1, #s do
    buf  = buf * 256 + s:byte(i)
    bits = bits + 8
    while bits >= 6 do
      bits = bits - 6
      local v = (buf >> bits) & 0x3F
      out[#out + 1] = b64alpha:sub(v + 1, v + 1)
      buf = buf - (v << bits)
    end
  end
  if bits > 0 then
    local v = (buf << (6 - bits)) & 0x3F
    out[#out + 1] = b64alpha:sub(v + 1, v + 1)
  end
  while #out % 4 ~= 0 do out[#out + 1] = '=' end
  return table.concat(out)
end

local function splitChunkLines(s)
  local hasTrailing = s:sub(-1) == '\n'
  local body  = hasTrailing and s or s .. '\n'
  local lines = {}
  for ln in body:gmatch('([^\n]*)\n') do lines[#lines + 1] = ln end
  return lines, hasTrailing
end

local function joinChunkLines(lines, hasTrailing)
  return table.concat(lines, '\n') .. (hasTrailing and '\n' or '')
end

-- Locate the (fxIdx+1)-th non-JS FX block (0-indexed). Returns
-- (firstBase64LineIdx, trailerLineIdx) or nil.
local function findFxBlock(lines, fxIdx)
  local seen = 0
  for i, ln in ipairs(lines) do
    if ln:match('^%s*<VST%s') or ln:match('^%s*<CLAP%s') or ln:match('^%s*<AU%s') then
      if seen == fxIdx then
        local depth = 1
        for j = i + 1, #lines do
          local stripped = lines[j]:match('^%s*(.-)%s*$')
          if stripped == '>' then
            depth = depth - 1
            if depth == 0 then return i + 1, j - 1 end
          elseif stripped:sub(1, 1) == '<' then
            depth = depth + 1
          end
        end
        return
      end
      seen = seen + 1
    end
  end
end

-- Decode line → mutate one byte via fn → re-encode iff changed.
-- No-op preserves the line byte-for-byte (round-trip invariant).
local function mutateByteInBase64Line(line, byteIdx, fn)
  local lead, content, tail = line:match('^(%s*)(%S*)(%s*)$')
  if not content or content == '' then return line end
  local bytes = b64decode(content)
  if byteIdx < 1 or byteIdx > #bytes then return line end
  local b    = bytes:byte(byteIdx)
  local newB = fn(b)
  if newB == b then return line end
  return lead .. b64encode(bytes:sub(1, byteIdx - 1)
                        .. string.char(newB)
                        .. bytes:sub(byteIdx + 1)) .. tail
end

local function setBitInBase64Line(line, byteIdx, mask, on)
  return mutateByteInBase64Line(line, byteIdx, function(b)
    return on and (b | mask) or (b & ~mask)
  end)
end

local function setByteInBase64Line(line, byteIdx, value)
  return mutateByteInBase64Line(line, byteIdx, function() return value end)
end

-- Patch one bit of the wrapper-header mirror at a 1-indexed offset in
-- the FX block's concatenated decoded-base64 stream.
local function patchStreamMirrorBit(lines, firstIdx, lastIdx, streamOffset, mask, on)
  local cursor = 0
  for i = firstIdx, lastIdx do
    local stripped = lines[i]:match('^%s*(.-)%s*$')
    if stripped:match('^[A-Za-z0-9%+/=]+$') then
      local n = #b64decode(stripped)
      if cursor + n >= streamOffset then
        lines[i] = setBitInBase64Line(lines[i], streamOffset - cursor, mask, on)
        return true
      end
      cursor = cursor + n
    end
  end
  return false
end

-- Drive per-FX MIDI routing on the fxIdx-th non-JS FX block. opts =
-- { inBus?, outBus?, inDisabled?, outDisabled? }.
local function setFXMidiRouting(chunk, fxIdx, opts, pinChannels)
  local lines, hasTrailing = splitChunkLines(chunk)
  local first, trailer     = findFxBlock(lines, fxIdx)
  if not first then return chunk, false end
  local mirrorOff = 27 + 8 * pinChannels

  if opts.inDisabled ~= nil then
    lines[trailer] = setBitInBase64Line(lines[trailer], 3, 0x01, opts.inDisabled)
    patchStreamMirrorBit(lines, first, trailer, mirrorOff, 0x01, opts.inDisabled)
  end
  if opts.outDisabled ~= nil then
    lines[trailer] = setBitInBase64Line(lines[trailer], 3, 0x02, opts.outDisabled)
    patchStreamMirrorBit(lines, first, trailer, mirrorOff, 0x02, opts.outDisabled)
  end
  if opts.inBus  ~= nil then lines[trailer] = setByteInBase64Line(lines[trailer], 4, opts.inBus)  end
  if opts.outBus ~= nil then lines[trailer] = setByteInBase64Line(lines[trailer], 5, opts.outBus) end

  return joinChunkLines(lines, hasTrailing), true
end

-- Decode the fxIdx-th non-JS FX block's routing trailer (read counterpart).
-- Returns { inBus, outBus, inDisabled, outDisabled } or nil.
local function readFXMidiRouting(chunk, fxIdx)
  local lines          = splitChunkLines(chunk)
  local first, trailer = findFxBlock(lines, fxIdx)
  if not first then return nil end
  local content = lines[trailer]:match('^%s*(%S*)%s*$')
  if not content or content == '' then return nil end
  local bytes = b64decode(content)
  local flags = bytes:byte(3) or 0
  return { inBus       = bytes:byte(4) or 0,
           outBus      = bytes:byte(5) or 0,
           inDisabled  = (flags & 0x01) ~= 0,
           outDisabled = (flags & 0x02) ~= 0 }
end

----------- fx read

--shape: fx = { id=guid, ident=string, name=string, inPins=int, outPins=int, pinMaps={ins={[port]={pair,...}}, outs=...}, midi={inBus=int, outBus=int, outDisabled=bool} }  -- midi nil for JS fx

-- Display name: a user instance rename wins, else the plugin's own name.
local function fxName(track, idx)
  local renamed, value = reaper.TrackFX_GetNamedConfigParm(track, idx, 'renamed_name')
  if renamed and value ~= '' then return value end
  local _, name = reaper.TrackFX_GetNamedConfigParm(track, idx, 'fx_name')
  return name
end

local function readFx(track, idx)
  local _, ident = reaper.TrackFX_GetNamedConfigParm(track, idx, 'fx_ident')
  local _, inPins, outPins = reaper.TrackFX_GetIOSize(track, idx)
  return {
    id      = reaper.TrackFX_GetFXGUID(track, idx),
    ident   = ident,
    name    = fxName(track, idx),
    inPins  = inPins,
    outPins = outPins,
    pinMaps = readPinMaps(track, idx),
  }
end

local function isJSFX(ident)
  return ident ~= nil and ident:sub(1, 3) == 'JS:'
end

-- Absent trailer ⇒ passthrough defaults; the field is present for every non-JS
-- fx so callers can read routing without a JS-vs-not branch.
local function readMidiRouting(chunk, routingIdx)
  local r = readFXMidiRouting(chunk, routingIdx)
            or { inBus = 0, outBus = 0, outDisabled = false }
  return { inBus = r.inBus, outBus = r.outBus, outDisabled = r.outDisabled }
end

local function readFxChain(track)
  local _, chunk     = reaper.GetTrackStateChunk(track, '', true)
  local out, routing = {}, 0
  for idx = 0, reaper.TrackFX_GetCount(track) - 1 do
    local fx = readFx(track, idx)
    if not isJSFX(fx.ident) then
      fx.midi = readMidiRouting(chunk, routing)
      routing = routing + 1
    end
    util.add(out, fx)
  end
  return out
end

----------- sends

--shape: send = { to=guid, kind='audio'|'midi', gain=number, srcChan=int, dstChan=int, pos='preFx'|'preFader'|'postFader' }  -- track output routing; no id

-- I_SENDMODE: 0 post-fader (post-pan), 1 pre-fx, 3 post-fx pre-fader. 2 is a
-- deprecated post-fader variant, folded to 'postFader'.
local SENDMODE_TO_POS = { [0] = 'postFader', [1] = 'preFx', [3] = 'preFader' }
local POS_TO_SENDMODE = { postFader = 0, preFx = 1, preFader = 3 }

-- A send is midi-only iff its audio source is disabled (I_SRCCHAN == -1);
-- anything else (audio-only, or a dual-stream send) reads as 'audio'.
local function sendKind(track, sendIdx)
  return reaper.GetTrackSendInfo_Value(track, 0, sendIdx, 'I_SRCCHAN') == -1
         and 'midi' or 'audio'
end

-- Audio sends carry channels in I_SRCCHAN/I_DSTCHAN; midi sends pack them into
-- I_MIDIFLAGS (bits 14/22, +1-biased — 0 means all channels).
local function readSendChans(track, sendIdx, kind)
  if kind == 'audio' then
    return math.floor(reaper.GetTrackSendInfo_Value(track, 0, sendIdx, 'I_SRCCHAN')),
           math.floor(reaper.GetTrackSendInfo_Value(track, 0, sendIdx, 'I_DSTCHAN'))
  end
  local mf = math.floor(reaper.GetTrackSendInfo_Value(track, 0, sendIdx, 'I_MIDIFLAGS'))
  return math.max(0, ((mf >> 14) & 0xFF) - 1),
         math.max(0, ((mf >> 22) & 0xFF) - 1)
end

-- One decoder behind read, the reconcile diff, and the gain-drift pass.
local function readSend(track, sendIdx)
  local dst = reaper.GetTrackSendInfo_Value(track, 0, sendIdx, 'P_DESTTRACK')
  local kind = sendKind(track, sendIdx)
  local srcChan, dstChan = readSendChans(track, sendIdx, kind)
  return {
    to      = reaper.GetTrackGUID(dst),
    kind    = kind,
    gain    = reaper.GetTrackSendInfo_Value(track, 0, sendIdx, 'D_VOL'),
    srcChan = srcChan,
    dstChan = dstChan,
    pos     = SENDMODE_TO_POS[math.floor(
                reaper.GetTrackSendInfo_Value(track, 0, sendIdx, 'I_SENDMODE'))]
              or 'postFader',
  }
end

local function readSends(track)
  local out = {}
  for i = 0, reaper.GetTrackNumSends(track, 0) - 1 do
    util.add(out, readSend(track, i))
  end
  return out
end

-- Identity tuple — gain is the mutable value, deliberately absent.
local function sendKey(s)
  return util.key(s.to, s.kind, s.srcChan, s.dstChan, s.pos)
end

local function createSend(track, w)
  local idx = reaper.CreateTrackSend(track, w.dst)
  if w.kind == 'midi' then
    reaper.SetTrackSendInfo_Value(track, 0, idx, 'I_SRCCHAN', -1)
    if w.srcChan ~= 0 or w.dstChan ~= 0 then
      local base  = math.floor(reaper.GetTrackSendInfo_Value(track, 0, idx, 'I_MIDIFLAGS'))
      local flags = (base & 0x3FFF) | ((w.srcChan + 1) << 14) | ((w.dstChan + 1) << 22)
      reaper.SetTrackSendInfo_Value(track, 0, idx, 'I_MIDIFLAGS', flags)
    end
  else
    reaper.SetTrackSendInfo_Value(track, 0, idx, 'I_MIDIFLAGS', 31)
    reaper.SetTrackSendInfo_Value(track, 0, idx, 'I_SRCCHAN', w.srcChan)
    reaper.SetTrackSendInfo_Value(track, 0, idx, 'I_DSTCHAN', w.dstChan)
  end
  reaper.SetTrackSendInfo_Value(track, 0, idx, 'I_SENDMODE', POS_TO_SENDMODE[w.pos] or 3)
end

-- Full-replace: drop/create by sendKey identity, then a separate gain pass
-- because REAPER indices shift under deletion and gains move with the key.
local function reconcileSends(track, sends)
  local current = {}
  for i = 0, reaper.GetTrackNumSends(track, 0) - 1 do
    current[sendKey(readSend(track, i))] = i
  end
  local wanted = {}
  for _, s in ipairs(sends) do
    local dst = locateTrack(s.to)
    if dst then
      local w = { dst = dst, to = s.to, kind = s.kind, gain = s.gain or 1.0,
                  srcChan = s.srcChan or 0, dstChan = s.dstChan or 0,
                  pos = s.pos or 'preFader' }
      wanted[sendKey(w)] = w
    end
  end
  -- Drops right-to-left so REAPER's post-remove index shift stays sane.
  local dropIdx = {}
  for key, idx in pairs(current) do
    if not wanted[key] then util.add(dropIdx, idx) end
  end
  table.sort(dropIdx, function(a, b) return a > b end)
  for _, idx in ipairs(dropIdx) do reaper.RemoveTrackSend(track, 0, idx) end
  for key, w in pairs(wanted) do
    if not current[key] then createSend(track, w) end
  end
  for i = 0, reaper.GetTrackNumSends(track, 0) - 1 do
    local w = wanted[sendKey(readSend(track, i))]
    if w then reaper.SetTrackSendInfo_Value(track, 0, i, 'D_VOL', w.gain) end
  end
end

----------- read

local function trackName(track)
  local _, name = reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', '', false)
  return name
end

local function readMainSend(track)
  local val = function(parm) return reaper.GetMediaTrackInfo_Value(track, parm) end
  return {
    on        = val('B_MAINSEND') ~= 0,
    gain      = val('D_VOL'),
    tgtOffset = val('C_MAINSEND_OFFS'),
    nchan     = val('C_MAINSEND_NCH'),
  }
end

local function readTrack(track, isMaster)
  return {
    id       = reaper.GetTrackGUID(track),
    name     = trackName(track),
    isMaster = isMaster or nil,
    nchan    = reaper.GetMediaTrackInfo_Value(track, 'I_NCHAN'),
    mainSend = readMainSend(track),
    fx       = readFxChain(track),
    sends    = readSends(track),
  }
end

----------- write

local function writeMainSend(track, ms)
  local set = function(parm, value)
    if value ~= nil then reaper.SetMediaTrackInfo_Value(track, parm, value) end
  end
  if ms.on ~= nil then set('B_MAINSEND', ms.on and 1 or 0) end
  set('D_VOL',            ms.gain)
  set('C_MAINSEND_OFFS',  ms.tgtOffset)
  set('C_MAINSEND_NCH',   ms.nchan)
end

-- ident → { [name] = sliderIdx }. Param layout is a property of the plugin
-- type, not the instance, and is session-fixed — a memo, not slot state.
local paramIdxByIdent = {}

local function paramsByName(track, fxIdx)
  local _, ident = reaper.TrackFX_GetNamedConfigParm(track, fxIdx, 'fx_ident')
  local byName = paramIdxByIdent[ident]
  if not byName then
    byName = {}
    for p = 0, 511 do
      local ok, name = reaper.TrackFX_GetParamName(track, fxIdx, p)
      if not ok then break end
      byName[name] = p
    end
    paramIdxByIdent[ident] = byName
  end
  return byName
end

--contract: params keyed by display name; an unknown name raises
local function writeParams(track, fxIdx, params)
  local byName = paramsByName(track, fxIdx)
  for name, value in pairs(params) do
    local idx = byName[name]
    if not idx then error(("routingManager: fx has no param named %q"):format(name)) end
    reaper.TrackFX_SetParam(track, fxIdx, idx, value)
  end
end

-- Absolute fx index → chunk routing index (non-JS blocks only); nil for a JS
-- fx, which has no routing trailer — writing midi to one is a no-op.
local function routingIdxOf(track, fxIdx)
  local _, ident = reaper.TrackFX_GetNamedConfigParm(track, fxIdx, 'fx_ident')
  if isJSFX(ident) then return nil end
  local routing = 0
  for i = 0, fxIdx - 1 do
    local _, prior = reaper.TrackFX_GetNamedConfigParm(track, i, 'fx_ident')
    if not isJSFX(prior) then routing = routing + 1 end
  end
  return routing
end

local function writeMidiRouting(track, fxIdx, midi)
  local routingIdx = routingIdxOf(track, fxIdx)
  if not routingIdx then return end
  local opts = { inBus = midi.inBus, outBus = midi.outBus, outDisabled = midi.outDisabled }
  if next(opts) == nil then return end
  local _, ins, outs = reaper.TrackFX_GetIOSize(track, fxIdx)
  local _, chunk     = reaper.GetTrackStateChunk(track, '', true)
  reaper.SetTrackStateChunk(track, setFXMidiRouting(chunk, routingIdx, opts, ins + outs), true)
end

local function writeTrackFields(track, t)
  if t.name  then reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', t.name, true) end
  if t.nchan then reaper.SetMediaTrackInfo_Value(track, 'I_NCHAN', t.nchan) end
  if t.hidden then
    reaper.SetMediaTrackInfo_Value(track, 'B_SHOWINMIXER', 0)
    reaper.SetMediaTrackInfo_Value(track, 'B_SHOWINTCP',   0)
  end
  if t.mainSend then writeMainSend(track, t.mainSend) end
  if t.sends    then reconcileSends(track, t.sends) end
end

----------------- PUBLIC

function rm:tracks()
  local out = {}
  for i = 0, reaper.CountTracks(PROJ) - 1 do
    util.add(out, readTrack(reaper.GetTrack(PROJ, i), false))
  end
  local master = reaper.GetMasterTrack(PROJ)
  if master then util.add(out, readTrack(master, true)) end
  return out
end

--contract: full record for one track by id (single-track rm:tracks()); nil if the id is gone
function rm:track(id)
  local track = locateTrack(id)
  if not track then return nil end
  return readTrack(track, track == reaper.GetMasterTrack(PROJ))
end

--contract: raw MediaTrack handle for id — escape hatch for reaper ops rm doesn't model; nil if gone
function rm:reaperTrack(id)
  return locateTrack(id)
end

--contract: the master track's guid; resolves master without an rm:tracks() scan
function rm:masterId()
  local master = reaper.GetMasterTrack(PROJ)
  return master and reaper.GetTrackGUID(master) or nil
end

function rm:addTrack(t)
  t = t or {}
  local idx = reaper.CountTracks(PROJ)
  reaper.InsertTrackAtIndex(idx, t.defaults or false)
  local track = reaper.GetTrack(PROJ, idx)
  writeTrackFields(track, t)
  return reaper.GetTrackGUID(track)
end

function rm:assignTrack(id, t)
  local track = locateTrack(id)
  if track then writeTrackFields(track, t) end
end

function rm:deleteTrack(id)
  local track = locateTrack(id)
  if track then reaper.DeleteTrack(track) end
end

function rm:addFx(trackId, t)
  local track = locateTrack(trackId)
  if not track then return end
  local idx = reaper.TrackFX_AddByName(track, t.ident, false, -1)
  if idx < 0 then return end
  local id  = reaper.TrackFX_GetFXGUID(track, idx)
  if t.index and t.index ~= idx then
    reaper.TrackFX_CopyToTrack(track, idx, track, t.index, true)
    idx = t.index
  end
  if t.params then writeParams(track, idx, t.params) end
  return id
end

function rm:assignFx(id, t)
  local track, idx = locateFx(id)
  if not track then return end
  if t.track then
    local dst = locateTrack(t.track)
    if dst then
      reaper.TrackFX_CopyToTrack(track, idx, dst, t.index or reaper.TrackFX_GetCount(dst), true)
      track, idx = locateFx(id)
    end
  elseif t.index and t.index ~= idx then
    reaper.TrackFX_CopyToTrack(track, idx, track, t.index, true)
    idx = t.index
  end
  if t.params  then writeParams(track, idx, t.params)  end
  if t.pinMaps then writePinMaps(track, idx, t.pinMaps) end
  if t.midi    then writeMidiRouting(track, idx, t.midi) end
end

function rm:deleteFx(id)
  local track, idx = locateFx(id)
  if track then reaper.TrackFX_Delete(track, idx) end
end

--contract: ports = pins/2; names L/R-collapsed. {ins,outs,inNames,outNames}; empty if id is gone
function rm:fxPorts(id)
  local track, idx = locateFx(id)
  if not track then return { ins = 0, outs = 0, inNames = {}, outNames = {} } end
  local _, inPins, outPins = reaper.TrackFX_GetIOSize(track, idx)
  inPins, outPins = inPins or 0, outPins or 0
  return {
    ins      = inPins  / 2,
    outs     = outPins / 2,
    inNames  = portNames(track, idx, 'in',  inPins),
    outNames = portNames(track, idx, 'out', outPins),
  }
end

--contract: floats the fx window for id; false if the fx is no longer live
function rm:showFx(id)
  local track, idx = locateFx(id)
  if not track then return false end
  reaper.TrackFX_Show(track, idx, 3)
  return true
end

--contract: enumerates reaper.EnumInstalledFX once, memoised; the set is runtime-fixed
function rm:installedFx()
  if installedFxCache then return installedFxCache end
  local out, i = {}, 0
  while true do
    local ok, name, ident = reaper.EnumInstalledFX(i)
    if not ok then break end
    util.add(out, { ident = ident, name = name })
    i = i + 1
  end
  installedFxCache = out
  return out
end

function rm:transaction(label, fn)
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  fn()
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock2(PROJ, label or '', -1)
end

return rm
