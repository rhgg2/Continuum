-- See docs/routingManager.md for the model. A thin record abstraction over
-- REAPER's audio/MIDI graph.
--invariant: id is a track/fx GUID string — opaque to callers, stable across reload
--invariant: stateless but for the scratch it owns (guid in projext) + the fx-meta undo watermark
--invariant: non-native record fields are metadata; rm persists them (see docs/routingManager.md)

local util = require('util')

local PROJ = 0

local rm = {}
local installedFxCache = nil  -- reaper's installed-FX set is fixed at runtime
local metaSeen        = {}   -- store -> last scratch-mirror raw rm:pollUndo saw; resync only on change

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

-- Channels 0-127 span two 64-bit mapping banks: pin `p` covers 0-63, `p + BANK2` covers 64-127.
-- Each Get/Set call yields one bank as lo (0-31) + hi (32-63). 128 = DAG.lua § CAPACITY.
local BANK2 = 0x1000000

-- Adjacent set bits collapse to one pair; the two pins of a port are OR'd together.
local function decodePairList(track, fxIdx, isoutput, port)
  local lowPin = 2 * (port - 1)
  local pairs, lastPair = {}, nil
  for bankIdx = 0, 1 do
    local pinBase = lowPin + bankIdx * BANK2
    local lo0, hi0 = reaper.TrackFX_GetPinMappings(track, fxIdx, isoutput, pinBase)
    local lo1, hi1 = reaper.TrackFX_GetPinMappings(track, fxIdx, isoutput, pinBase + 1)
    local mask     = (lo0 | lo1) | ((hi0 | hi1) << 32)  -- 5.4 >> is logical: top bit safe
    local chanBase = bankIdx * 64
    for bit = 0, 63 do
      if ((mask >> bit) & 1) == 1 then
        local pair = ((chanBase + bit) >> 1) + 1
        if pair ~= lastPair then util.add(pairs, pair); lastPair = pair end
      end
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

-- lo/hi for one bank: channels outside this bank's 64-wide window contribute nothing.
local function pinMaskFor(pairList, pinOffset, bankIdx)
  local chanBase, lo, hi = bankIdx * 64, 0, 0
  for _, pair in ipairs(pairList) do
    local bit = 2 * (pair - 1) + pinOffset - chanBase
    if     bit >= 0  and bit < 32 then lo = lo | (1 << bit)
    elseif bit >= 32 and bit < 64 then hi = hi | (1 << (bit - 32))
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
        local pin = 2 * (port - 1) + pinOffset
        for bankIdx = 0, 1 do
          reaper.TrackFX_SetPinMappings(track, fxIdx, isoutput,
                                        pin + bankIdx * BANK2, pinMaskFor(pairList, pinOffset, bankIdx))
        end
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

-- Concatenate the FX block's base64 content lines into the decoded stream;
-- nested <...> elements and non-base64 lines are skipped.
local function fxBlockStream(lines, firstIdx, lastIdx)
  local parts = {}
  for i = firstIdx, lastIdx do
    local content = lines[i]:match('^%s*(%S*)%s*$')
    if content and content:match('^[A-Za-z0-9%+/=]+$') then
      parts[#parts + 1] = b64decode(content)
    end
  end
  return table.concat(parts)
end

-- Patch the byte at 1-indexed stream offset `off` via `fn`, re-encoding only
-- the base64 line it falls in. Returns true if the offset was in range.
local function patchStreamByte(lines, firstIdx, lastIdx, off, fn)
  local cursor = 0
  for i = firstIdx, lastIdx do
    local content = lines[i]:match('^%s*(%S*)%s*$')
    if content and content:match('^[A-Za-z0-9%+/=]+$') then
      local n = #b64decode(content)
      if cursor + n >= off then
        lines[i] = mutateByteInBase64Line(lines[i], off - cursor, fn)
        return true
      end
      cursor = cursor + n
    end
  end
  return false
end

-- Per-FX MIDI routing = the decoded stream's last 4 bytes <flags><inBus><outBus>00;
-- flags are mirrored at head offset 27+8*pinChannels too. See docs/reaper_midi_routing.md.
local function setFXMidiRouting(chunk, fxIdx, opts, pinChannels)
  local lines, hasTrailing = splitChunkLines(chunk)
  local first, trailer     = findFxBlock(lines, fxIdx)
  if not first then return chunk, false end
  local n = #fxBlockStream(lines, first, trailer)
  if n < 4 then return chunk, false end

  local function setFlag(mask, on)
    local function flip(b) return on and (b | mask) or (b & ~mask) end
    patchStreamByte(lines, first, trailer, n - 3,                flip)
    patchStreamByte(lines, first, trailer, 27 + 8 * pinChannels, flip)
  end
  if opts.inDisabled  ~= nil then setFlag(0x01, opts.inDisabled)  end
  if opts.outDisabled ~= nil then setFlag(0x02, opts.outDisabled) end
  if opts.inBus  ~= nil then patchStreamByte(lines, first, trailer, n - 2, function() return opts.inBus  end) end
  if opts.outBus ~= nil then patchStreamByte(lines, first, trailer, n - 1, function() return opts.outBus end) end

  return joinChunkLines(lines, hasTrailing), true
end

-- Read the fxIdx-th non-JS FX block's routing from the stream's last 4 bytes.
-- Returns { inBus, outBus, inDisabled, outDisabled } or nil if absent.
local function readFXMidiRouting(chunk, fxIdx)
  local lines          = splitChunkLines(chunk)
  local first, trailer = findFxBlock(lines, fxIdx)
  if not first then return nil end
  local stream = fxBlockStream(lines, first, trailer)
  local n = #stream
  if n < 4 then return nil end
  local flags = stream:byte(n - 3)
  return { inBus       = stream:byte(n - 2),
           outBus      = stream:byte(n - 1),
           inDisabled  = (flags & 0x01) ~= 0,
           outDisabled = (flags & 0x02) ~= 0 }
end

----------- fx read

--shape: fx = { id=guid, ident=string, fxType=string, name=string, ins=int, outs=int, inNames={str,...}, outNames={str,...}, pinMaps={ins={[port]={pair,...}}, outs=...}, midi={inBus,outBus,inDisabled,outDisabled} }  -- ident JS-normalised; midi only for VST/AU/CLAP; rm:fx adds trackId

-- Display name: a user instance rename wins, else the plugin's own name.
local function fxName(track, idx)
  local renamed, value = reaper.TrackFX_GetNamedConfigParm(track, idx, 'renamed_name')
  if renamed and value ~= '' then return value end
  local _, name = reaper.TrackFX_GetNamedConfigParm(track, idx, 'fx_name')
  return name
end

local function fxTypeAt(track, idx)
  local _, fxType = reaper.TrackFX_GetNamedConfigParm(track, idx, 'fx_type')
  return fxType
end

-- fx_ident for a JSFX is a bare path ('utility/volume'); the system keys JS on a
-- 'JS:' prefix (CU_IDENT, isJS, readJSFXContent), so restore it via fx_type on read.
local function fxIdentAt(track, idx, fxType)
  local _, ident = reaper.TrackFX_GetNamedConfigParm(track, idx, 'fx_ident')
  if fxType == 'JS' and ident ~= '' and ident:sub(1, 3) ~= 'JS:' then ident = 'JS:' .. ident end
  return ident
end

-- A routing-bearing FX carries a per-FX MIDI routing record in the chunk — exactly
-- the <VST>/<CLAP>/<AU> blocks findFxBlock walks. JS, containers, video have none.
local function isRoutingFx(fxType)
  return fxType ~= nil
     and (fxType:find('^VST') or fxType:find('^AU') or fxType:find('^CLAP')) ~= nil
end

local function readFx(track, idx)
  local fxType = fxTypeAt(track, idx)
  local _, inPins, outPins = reaper.TrackFX_GetIOSize(track, idx)
  inPins, outPins = inPins or 0, outPins or 0
  return {
    id       = reaper.TrackFX_GetFXGUID(track, idx),
    ident    = fxIdentAt(track, idx, fxType),
    fxType   = fxType,
    name     = fxName(track, idx),
    ins      = inPins  / 2,
    outs     = outPins / 2,
    inNames  = portNames(track, idx, 'in',  inPins),
    outNames = portNames(track, idx, 'out', outPins),
    pinMaps  = readPinMaps(track, idx),
  }
end

-- Absent trailer ⇒ passthrough defaults; the field is present for every non-JS
-- fx so callers can read routing without a JS-vs-not branch.
local function readMidiRouting(chunk, routingIdx)
  local r = readFXMidiRouting(chunk, routingIdx)
            or { inBus = 0, outBus = 0, inDisabled = false, outDisabled = false }
  return { inBus = r.inBus, outBus = r.outBus,
           inDisabled = r.inDisabled, outDisabled = r.outDisabled }
end

local function readFxChain(track)
  local _, chunk     = reaper.GetTrackStateChunk(track, '', false)
  local out, routing = {}, 0
  for idx = 0, reaper.TrackFX_GetCount(track) - 1 do
    local fx = readFx(track, idx)
    if isRoutingFx(fx.fxType) then
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

-- paramAutomation's CC-propagation bus; its midi sends (src bus 126) are not wiring's
-- to manage — reconcileSends must never drop them.
local AUTO_BUS = 126

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
    local send = readSend(track, i)
    -- Automation sends stay out of `current`: absent from `wanted` but present here,
    -- the full-replace would otherwise drop them.
    if not (send.kind == 'midi' and send.srcChan == AUTO_BUS) then
      current[sendKey(send)] = i
    end
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

----------- metadata

-- Native = REAPER-backed; any other record key is metadata rm persists.
-- See docs/routingManager.md § Metadata and the scratch track.
local TRACK_NATIVE = {
  id = true, name = true, isMaster = true, nchan = true,
  mainSend = true, fx = true, sends = true, hidden = true, defaults = true,
  hasMidiTake = true,
}
local FX_NATIVE = {
  id = true, ident = true, name = true, ins = true, outs = true,
  inNames = true, outNames = true, pinMaps = true, midi = true,
  trackId = true, params = true, index = true, track = true,
}

local EXT_SECTION  = 'continuum_wiring'
local SCRATCH_GUID = 'scratch'
local META_PEXT    = 'P_EXT:ctm_meta'    -- per-track metadata blob

-- Each store is a {[id]=meta} projext blob mirrored to scratch so REAPER undo reverts it.
-- Stores never share a blob; each consumer reads only the shape it expects.
local META_STORES = {
  fx  = { key = 'fxMeta',  mirror = 'P_EXT:ctm_fxMeta'  },
  bus = { key = 'busMeta', mirror = 'P_EXT:ctm_busMeta' },
}

local function decodeBlob(raw)
  return (raw and raw ~= '') and util.unserialise(raw) or nil
end

local function readTrackMeta(track)
  local _, raw = reaper.GetSetMediaTrackInfo_String(track, META_PEXT, '', false)
  return decodeBlob(raw)
end

-- Patch-merge so a partial write (just pos) never wipes a sibling (split);
-- util.REMOVE clears a field.
local function writeTrackMeta(track, meta)
  local cur = readTrackMeta(track) or {}
  util.assign(cur, meta)
  reaper.GetSetMediaTrackInfo_String(track, META_PEXT, util.serialise(cur), true)
end

local function readMeta(store)
  local _, raw = reaper.GetProjExtState(PROJ, EXT_SECTION, META_STORES[store].key)
  return decodeBlob(raw) or {}
end

-- nil meta deletes the entry; otherwise patch-merge (util.REMOVE clears a field).
local function writeMeta(store, id, meta)
  local def  = META_STORES[store]
  local blob = readMeta(store)
  if meta == nil then
    blob[id] = nil
  else
    blob[id] = blob[id] or {}
    util.assign(blob[id], meta)
    if not next(blob[id]) then blob[id] = nil end
  end
  local raw = util.serialise(blob)
  reaper.SetProjExtState(PROJ, EXT_SECTION, def.key, raw)
  reaper.GetSetMediaTrackInfo_String(rm:scratchTrack(), def.mirror, raw, true)
  metaSeen[store] = raw
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

-- A track's own active MIDI take decides whether its source node emits on bus 0: a folder
-- parent or bare source with no midi take produces nothing there (the out stays wirable).
local function trackHasMidiTake(track)
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local take = reaper.GetActiveTake(reaper.GetTrackMediaItem(track, i))
    if take and reaper.TakeIsMIDI(take) then return true end
  end
  return false
end

local function readTrack(track, isMaster)
  local rec = {
    id       = reaper.GetTrackGUID(track),
    name     = trackName(track),
    number     = reaper.GetMediaTrackInfo_Value(track, 'IP_TRACKNUMBER'),
    folderDepth = reaper.GetMediaTrackInfo_Value(track, 'I_FOLDERDEPTH'),
    isMaster = isMaster or nil,
    nchan    = reaper.GetMediaTrackInfo_Value(track, 'I_NCHAN'),
    mainSend = readMainSend(track),
    fx       = readFxChain(track),
    sends    = readSends(track),
    hasMidiTake = trackHasMidiTake(track),
  }
  util.assign(rec, readTrackMeta(track))
  return rec
end

-- Folder membership is positional (I_FOLDERDEPTH: 1 opens, <0 closes |n|): walk
-- tracks in order, each foldered track's parent is the open-folder stack top.
local function stampParents(records)
  local stack = {}
  for _, rec in ipairs(records) do
    if not rec.isMaster then
      rec.parent = stack[#stack]
      local depth = rec.folderDepth or 0
      if depth == 1 then stack[#stack + 1] = rec.id
      elseif depth < 0 then for _ = 1, -depth do stack[#stack] = nil end end
    end
  end
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

-- Live { [name] = value } for every named param — the read counterpart to writeParams.
local function readParams(track, fxIdx)
  local out = {}
  for name, idx in pairs(paramsByName(track, fxIdx)) do
    out[name] = reaper.TrackFX_GetParam(track, fxIdx, idx)
  end
  return out
end

-- Absolute fx index → chunk routing index (routing-bearing blocks only); nil for a
-- JS/container fx, which has no routing trailer — writing midi to one is a no-op.
local function routingIdxOf(track, fxIdx)
  if not isRoutingFx(fxTypeAt(track, fxIdx)) then return nil end
  local routing = 0
  for i = 0, fxIdx - 1 do
    if isRoutingFx(fxTypeAt(track, i)) then routing = routing + 1 end
  end
  return routing
end

local function writeMidiRouting(track, fxIdx, midi)
  local routingIdx = routingIdxOf(track, fxIdx)
  if not routingIdx then return end
  local opts = { inBus = midi.inBus, outBus = midi.outBus,
                 inDisabled = midi.inDisabled, outDisabled = midi.outDisabled }
  if next(opts) == nil then return end
  local _, ins, outs = reaper.TrackFX_GetIOSize(track, fxIdx)
  -- isundo=false throughout: applyOps brackets an Undo block, so chunk RMW needs no
  -- per-call undo caching. All rm chunk reads/writes share the flag so caches agree.
  local _, chunk     = reaper.GetTrackStateChunk(track, '', false)
  local newChunk = setFXMidiRouting(chunk, routingIdx, opts, ins + outs)
  reaper.SetTrackStateChunk(track, newChunk, false)
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

--contract: lightweight {id, name, number, isMaster} per project track + master; no fx/sends/chunk reads.
function rm:trackLabels()
  local function label(track, isMaster)
    return { id       = reaper.GetTrackGUID(track),
             name     = trackName(track),
             number   = reaper.GetMediaTrackInfo_Value(track, 'IP_TRACKNUMBER'),
             isMaster = isMaster or nil }
  end
  local out = {}
  for i = 0, reaper.CountTracks(PROJ) - 1 do util.add(out, label(reaper.GetTrack(PROJ, i), false)) end
  local master = reaper.GetMasterTrack(PROJ)
  if master then util.add(out, label(master, true)) end
  return out
end

function rm:tracks()
  local out = {}
  for i = 0, reaper.CountTracks(PROJ) - 1 do
    util.add(out, readTrack(reaper.GetTrack(PROJ, i), false))
  end
  local master = reaper.GetMasterTrack(PROJ)
  if master then util.add(out, readTrack(master, true)) end
  local meta = readMeta('fx')
  for _, tr in ipairs(out) do
    for _, fx in ipairs(tr.fx) do util.assign(fx, meta[fx.id]) end
  end
  stampParents(out)
  return out
end

--contract: full record for one track by id (single-track rm:tracks()); nil if the id is gone
function rm:track(id)
  local track = locateTrack(id)
  if not track then return nil end
  local rec  = readTrack(track, track == reaper.GetMasterTrack(PROJ))
  local meta = readMeta('fx')
  for _, fx in ipairs(rec.fx) do util.assign(fx, meta[fx.id]) end
  return rec
end

--contract: ordered live fx ids for a track via TrackFX — no chunk read; nil if the id is gone
--contract: second return: { [id] = ident } over the same chain
function rm:fxIds(id)
  local track = locateTrack(id)
  if not track then return nil end
  local ids, identById = {}, {}
  for i = 0, reaper.TrackFX_GetCount(track) - 1 do
    local fxId = reaper.TrackFX_GetFXGUID(track, i)
    util.add(ids, fxId)
    identById[fxId] = fxIdentAt(track, i, fxTypeAt(track, i))
  end
  return ids, identById
end

--contract: raw MediaTrack handle for id — escape hatch for reaper ops rm doesn't model; nil if gone
function rm:reaperTrack(id)
  return locateTrack(id)
end

--contract: live MediaTrack hosting fx id, resolved without reading its record/chunk; nil if gone
function rm:fxTrack(id)
  return (locateFx(id))
end

--contract: the master track's guid; resolves master without an rm:tracks() scan
function rm:masterId()
  local master = reaper.GetMasterTrack(PROJ)
  return master and reaper.GetTrackGUID(master) or nil
end

-- The persisted scratch guid + live handle, or nil if none minted yet. Never mints.
local function liveScratch()
  local _, guid = reaper.GetProjExtState(PROJ, EXT_SECTION, SCRATCH_GUID)
  if guid == '' then return nil end
  local track = locateTrack(guid)
  if track then return guid, track end
end

--contract: the scratch track's guid, minted on first use; persisted in projext.
--contract: rm owns scratch — it parks orphan fx and carries the fx-meta undo mirror.
function rm:scratchId()
  local guid = liveScratch()
  if guid then return guid end
  guid = rm:addTrack{ name = 'continuum: wiring scratch', hidden = true }
  reaper.SetProjExtState(PROJ, EXT_SECTION, SCRATCH_GUID, guid)
  return guid
end

--contract: raw scratch MediaTrack handle (for P_EXT writes); mints on first use
function rm:scratchTrack()
  return self:reaperTrack(self:scratchId())
end

--contract: pull every meta store's scratch P_EXT mirror back into projext after a
--contract: REAPER undo/redo — projext doesn't reverse natively, the scratch chunk does
function rm:resyncMeta()
  local _, scratch = liveScratch()
  if not scratch then return end
  for _, def in pairs(META_STORES) do
    local _, raw = reaper.GetSetMediaTrackInfo_String(scratch, def.mirror, '', false)
    reaper.SetProjExtState(PROJ, EXT_SECTION, def.key, raw)
  end
end

--contract: per-frame heartbeat — ensures the scratch exists, and on a scratch-chunk
--contract: rewind (REAPER undo/redo) pulls the meta mirrors back into projext
function rm:pollUndo()
  local scratch = self:scratchTrack()
  local changed = false
  for store, def in pairs(META_STORES) do
    local _, raw = reaper.GetSetMediaTrackInfo_String(scratch, def.mirror, '', false)
    if raw ~= metaSeen[store] then metaSeen[store] = raw; changed = true end
  end
  if changed then self:resyncMeta() end
end

function rm:addTrack(t)
  t = t or {}
  local idx = reaper.CountTracks(PROJ)
  -- Pin emergent tracks top-level: if the project ends inside an open folder, an
  -- appended track would become a child and its mainSend retarget to the parent.
  local openDepth = 0
  for i = 0, idx - 1 do
    openDepth = openDepth + reaper.GetMediaTrackInfo_Value(reaper.GetTrack(PROJ, i), 'I_FOLDERDEPTH')
  end
  if openDepth > 0 then
    local last = reaper.GetTrack(PROJ, idx - 1)
    reaper.SetMediaTrackInfo_Value(last, 'I_FOLDERDEPTH',
      reaper.GetMediaTrackInfo_Value(last, 'I_FOLDERDEPTH') - openDepth)
  end
  reaper.InsertTrackAtIndex(idx, t.defaults or false)
  local track = reaper.GetTrack(PROJ, idx)
  writeTrackFields(track, t)
  local meta = util.clone(t, TRACK_NATIVE)
  if next(meta) then writeTrackMeta(track, meta) end
  return reaper.GetTrackGUID(track)
end

function rm:assignTrack(id, t)
  local track = locateTrack(id)
  if not track then return end
  writeTrackFields(track, t)
  local meta = util.clone(t, TRACK_NATIVE)
  if next(meta) then writeTrackMeta(track, meta) end
end

function rm:deleteTrack(id)
  local track = locateTrack(id)
  if track then reaper.DeleteTrack(track) end
end

--contract: targeted live D_VOL on the audio send srcId→dstId; false if no such send is live.
--contract: the partial write assignTrack{sends} (full-replace) can't serve — for live gain pokes.
function rm:setSendGain(srcId, dstId, gain)
  local src, dst = locateTrack(srcId), locateTrack(dstId)
  if not (src and dst) then return false end
  for i = 0, reaper.GetTrackNumSends(src, 0) - 1 do
    if reaper.GetTrackSendInfo_Value(src, 0, i, 'P_DESTTRACK') == dst
       and sendKind(src, i) == 'audio' then
      reaper.SetTrackSendInfo_Value(src, 0, i, 'D_VOL', gain)
      return true
    end
  end
  return false
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
  local meta = util.clone(t, FX_NATIVE)
  if next(meta) then writeMeta('fx', id, meta) end
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
  local meta = util.clone(t, FX_NATIVE)
  if next(meta) then writeMeta('fx', id, meta) end
end

-- Undo-free pin re-assert (no transaction, no meta): repairs the identity-OR a same-cycle
-- I_NCHAN grow stamps onto a just-written pin. See docs/wiringManager.md § Pin re-assert after grow.
function rm:rewritePins(id, pinMaps)
  local track, idx = locateFx(id)
  if track then writePinMaps(track, idx, pinMaps) end
end

--contract: read a named meta store ('fx'|'bus'): whole blob, or one entry when id given
function rm:meta(store, id)
  local blob = readMeta(store)
  if id == nil then return blob end
  return blob[id]
end

--contract: write a named meta store: nil deletes store[id], else patch-merge (util.REMOVE to clear)
function rm:assignMeta(store, id, meta)
  writeMeta(store, id, meta)
end

--contract: batch per-FX MIDI routing for one track in a single chunk Get+Set; writes={{id,midi},...}
function rm:writeChainMidi(trackId, writes)
  local track = locateTrack(trackId)
  if not track then return end
  local _, chunk = reaper.GetTrackStateChunk(track, '', false)
  local changed  = false
  for _, w in ipairs(writes) do
    local _, idx     = locateFx(w.id)
    local routingIdx = idx and routingIdxOf(track, idx)
    if routingIdx then
      local _, ins, outs = reaper.TrackFX_GetIOSize(track, idx)
      local newChunk, ok = setFXMidiRouting(chunk, routingIdx,
        { inBus = w.midi.inBus, outBus = w.midi.outBus,
          inDisabled = w.midi.inDisabled, outDisabled = w.midi.outDisabled }, ins + outs)
      if ok then chunk, changed = newChunk, true end
    end
  end
  if changed then reaper.SetTrackStateChunk(track, chunk, false) end
end

function rm:deleteFx(id)
  local track, idx = locateFx(id)
  if track then reaper.TrackFX_Delete(track, idx) end
end

--contract: fx record by id (ports, names, pinMaps, midi, trackId); nil if gone. Params separate.
function rm:fx(id)
  local track, idx = locateFx(id)
  if not track then return nil end
  local fx = readFx(track, idx)
  fx.trackId = reaper.GetTrackGUID(track)
  if isRoutingFx(fx.fxType) then
    local _, chunk = reaper.GetTrackStateChunk(track, '', false)
    fx.midi = readMidiRouting(chunk, routingIdxOf(track, idx))
  end
  util.assign(fx, readMeta('fx')[id])
  return fx
end

--contract: live { [name] = value } param values for the fx by id; nil if gone.
--contract: the mutable control-state counterpart to the structural rm:fx record.
function rm:params(id)
  local track, idx = locateFx(id)
  return track and readParams(track, idx) or nil
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
