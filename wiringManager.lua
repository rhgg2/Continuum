-- See docs/wiringManager.md for the model.
-- @noindex

--invariant: fx-kind nodes carry fxGuid; addFxNode mints it via instantiateFxOnScratch
--invariant: CU bridges arrive at the applier with nil fxGuid; reconcileFXChain mints them
--invariant: fxGuid is the stable bridge identity; snapshot/targetState match fxOrder by it
--invariant: wm deletes an FX instance only when its owning node or CU bridge leaves the graph
--invariant: host changes are moves; TrackFX_CopyToTrack(is_move=true) preserves plugin state
--shape: snapshotPinMap = { ins={[port]={pair,...}}, outs={[port]={pair,...}} }
--shape: snapshotSend = { to=classKey, type='audio'|'midi', gain?=number, srcChan=int, dstChan=int }
--shape: snapshotFxOrigin = {kind='node',id=string}|{kind='edge',idx=int}|{kind='bracketIn'|'bracketOut',id=string}
--shape: snapshotFxEntry = { fxGuid?=string, ident=string, params?=table, origin?=snapshotFxOrigin, midiOut?=bool }
--shape: wiringSnapshot = { [classKey] = { hostKind='sourceTrack'|'newTrack'|'master'|'scratch', trackGuid?=string, fxOrder=snapshotFxEntry[], mainSend=bool, mainSendGain?=number, mainSendOffs?=int, sends=snapshotSend[], nchan?=int, pinMaps?={ [fxGuid]=snapshotPinMap }, pinMapsByOrigin?={ [originKey]=snapshotPinMap } } }; see design/wiring.md § wiringSnapshot.
--shape: wiringOp = { op='createTrack'|'deleteTrack'|'setFXChain'|'setMainSend'|'setSends'|'setNchan'|'setPinMaps'|'setExtState'|'moveFxAcrossHosts', ... }; full-replace ops, not incremental. setFXChain entries with fxGuid=nil mean 'instantiate ident, stamp guid back to graph' (interpreted by the applier). moveFxAcrossHosts relocates a live FX from one host to another with TrackFX_CopyToTrack(is_move=true); emitted before per-class setFXChain ops so subsequent per-track reconcile sees the FX already at the destination. setNchan / setPinMaps emit between setFXChain and setMainSend so the applier has fxGuids stamped before pin-map writes and the track has channels allocated before pin maps land. setMainSend carries offs (C_MAINSEND_OFFS) when mainSend=true; setPinMaps carries both fxGuid-keyed and origin-keyed maps so unmaterialised fxs lift through the stamps table.
--invariant: every authoring gesture goes through wm:mutate — clone draft, mutate, validate via DAG.validate, swap + persist + fire on success, return false+err on failure. The on-disk graph and the wiringChanged broadcast have therefore always passed validation.
--invariant: master node is a regular entry in graph.nodes under the fixed id 'master'; freshGraph materialises it on first load of an empty project; DAG.validate enforces the singleton.
--invariant: scratch is a hidden REAPER track tagged cm 'wiringScratch'='1' (find-or-create lazily)
--invariant: scratch hosts FX with no compile-graph track — disconnected or lowered-parked

local util = require 'util'
local DAG  = require 'DAG'
local fs   = require 'fs'

local cm = (...).cm

local wm = {}
local fire = util.installHooks(wm)

local userGraph = nil
local installedFx = nil   -- session cache; reaper's installed-FX set is fixed at runtime
local scratchTrack = nil  -- hidden host for disconnected/orphan FX nodes; reset by wm:load
local pokeParamCache = {} -- persistent paramIdx cache for the pokeEdgeGain hot path
local appliedMidiOut = {} -- [fxGuid] = bool, last value we wrote (nil = never) — see docs/wiringManager.md § Routing intent record
local realising = false   -- true during applyOps's stamp-back mutate, gating wiringChanged
local liveLabel = nil     -- non-nil iff live mode is on; carries the default undo label
local lastScratchRaw = nil -- serialised graph last mirrored to scratch P_EXT; pollUndo compares against it

local SCRATCH_NAME = 'continuum: wiring scratch'
local SCRATCH_KEY  = '__scratch__'
local CU_IDENT     = 'JS:Continuum Utility'

----- Helpers

local function freshGraph()
  return {
    nodes = {
      master = { kind = 'master', pos = { x = 0, y = 0 },
                 ports = { audio = { ins = 1, outs = 0 },
                           midi  = { ins = 0, outs = 0 } } },
    },
    edges = {},
    nextId = 1,
  }
end

local function readPersisted()
  local g = cm:get('wiringGraph')
  if g and g.nodes then return g end
  return freshGraph()
end

local function ensureLoaded()
  if not userGraph then userGraph = readPersisted() end
end

local function findScratchTrack()
  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    if cm:readTrackKey(track, 'wiringScratch') == '1' then return track end
  end
end

local function createScratchTrack()
  reaper.PreventUIRefresh(1)
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, false)
  local track = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', SCRATCH_NAME, true)
  reaper.SetMediaTrackInfo_Value(track, 'B_SHOWINMIXER', 0)
  reaper.SetMediaTrackInfo_Value(track, 'B_SHOWINTCP',   0)
  cm:writeTrackKey(track, 'wiringScratch', '1')
  reaper.PreventUIRefresh(-1)
  return track
end

local function ensureScratchTrack()
  if scratchTrack then return scratchTrack end
  scratchTrack = findScratchTrack() or createScratchTrack()
  return scratchTrack
end

local function pinName(track, fxIdx, dir, pinIdx)
  local ok, v = reaper.TrackFX_GetNamedConfigParm(track, fxIdx, dir .. '_pin_' .. pinIdx)
  return ok and v or nil
end

-- Port P (1-indexed) groups pin 2(P-1) and 2P-1.
-- "Sidechain L" + "Sidechain R" → "Sidechain"; mismatched pair → left pin name.
local function portNames(track, fxIdx, dir, pinCount)
  local out = {}
  for p = 1, pinCount / 2 do
    local left  = pinName(track, fxIdx, dir, (p - 1) * 2)     or ''
    local right = pinName(track, fxIdx, dir, (p - 1) * 2 + 1) or ''
    local lPre  = left :match('^(.+)%s+L$')
    local rPre  = right:match('^(.+)%s+R$')
    if lPre and lPre == rPre then out[p] = lPre
    else                          out[p] = left ~= '' and left or nil end
  end
  return out
end

-- True iff JSFX desc declares ext_midi_bus=1 (the FX scans midi_bus itself,
-- escaping our allocator). Skips // comments; frontier prevents `=10` match.
local function parseJsfxBusAware(content)
  if not content then return false end
  for line in content:gmatch('[^\r\n]+') do
    local stripped = line:match('^%s*(.-)%s*$') or ''
    if stripped:sub(1, 2) ~= '//'
       and stripped:match('^ext_midi_bus%s*=%s*1%f[%D]') then
      return true
    end
  end
  return false
end

----------- PUBLIC

--contract: re-reads wiringGraph from cm (rebuilding master via freshGraph if empty), ensures the scratch track, fires wiringChanged{kind='load'}; drops the prior scratch handle (project may have changed)
function wm:load()
  userGraph      = readPersisted()
  appliedMidiOut = cm:get('wiringMidiOutApplied') or {}
  scratchTrack   = nil
  ensureScratchTrack()
  fire('wiringChanged', { kind = 'load' })
end

--contract: persists the current in-memory graph to the project tier; mutate calls this, callers normally don't
function wm:save()
  cm:set('project', 'wiringGraph', userGraph)
end

--contract: returns a deep copy of the user graph; caller mutations never leak into wm state
function wm:graph()
  ensureLoaded()
  return util.deepClone(userGraph)
end

--contract: clone-validate-swap; on DAG.validate failure returns false,err with no state change and no signal; on success persists and fires wiringChanged{kind='mutate'} unless wm is mid-realisation (the applier's stamp-back path sets `realising` so it doesn't re-enter the live-recompile loop)
function wm:mutate(mutator)
  ensureLoaded()
  local draft = util.deepClone(userGraph)
  mutator(draft)
  local err = DAG.validate(draft)
  if err then return false, err end
  userGraph = draft
  self:save()
  if not realising then fire('wiringChanged', { kind = 'mutate' }) end
  return true
end

--contract: returns DAG.compile context around the current user graph; lazy caches live on the ctx, so reusing it across :classes/:capacityErrors/:targetPlan computes each derivation once
function wm:compile()
  ensureLoaded()
  return DAG.compile(userGraph)
end

--contract: list of intra-class capacity overflows on the lowered compile graph; empty when the user graph is within budget
function wm:errors()
  return self:compile():capacityErrors()
end

--contract: read JSFX desc file for ident from REAPER's Effects dir; nil if non-JS or read fails
function wm:readJsfxContent(ident)
  if not (ident and ident:sub(1, 3) == 'JS:') then return nil end
  local path = fs.join(reaper.GetResourcePath(), 'Effects/' .. ident:sub(4))
  local f = io.open(path, 'rb')
  if not f then return nil end
  local content = f:read('*a')
  f:close()
  return content
end

-- Exposed for unit tests; production paths use `wm:isUserAddRefused` below.
wm.parseJsfxBusAware = parseJsfxBusAware

--contract: refuses JSFX whose desc declares ext_midi_bus=1; nil on accept, structured err on refuse
function wm:checkUserAddable(ident)
  if not (ident and ident:sub(1, 3) == 'JS:') then return nil end
  if parseJsfxBusAware(self:readJsfxContent(ident)) then
    return { code = 'ext_midi_bus_user_fx', ident = ident }
  end
end

--contract: AddByName on scratch + keep; returns {fxGuid, ins, outs, inNames, outNames}
--contract: unknown ident → fxGuid=nil, ins=outs=0, empty name lists
function wm:instantiateFxOnScratch(ident)
  ensureScratchTrack()
  reaper.PreventUIRefresh(1)
  local fxIdx = reaper.TrackFX_AddByName(scratchTrack, ident, false, -1)
  local result
  if fxIdx < 0 then
    result = { fxGuid = nil, ins = 0, outs = 0, inNames = {}, outNames = {} }
  else
    local _, inPins, outPins = reaper.TrackFX_GetIOSize(scratchTrack, fxIdx)
    inPins, outPins = inPins or 0, outPins or 0
    result = {
      fxGuid   = reaper.TrackFX_GetFXGUID(scratchTrack, fxIdx),
      ins      = inPins  / 2,
      outs     = outPins / 2,
      inNames  = portNames(scratchTrack, fxIdx, 'in',  inPins),
      outNames = portNames(scratchTrack, fxIdx, 'out', outPins),
    }
  end
  reaper.PreventUIRefresh(-1)
  return result
end

--contract: linear scan; returns the MediaTrack with this GUID, or nil if the project no longer holds one
function wm:trackByGuid(guid)
  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    if reaper.GetTrackGUID(track) == guid then return track end
  end
end

--contract: live REAPER track name for guid (renames propagate); nil if the track is gone
function wm:trackName(guid)
  local track = self:trackByGuid(guid)
  if not track then return nil end
  local _, name = reaper.GetTrackName(track)
  return name
end

--contract: inserts a track just before scratch (named opts.name), tags it with wiringHostKind=sourceTrack so wm:snapshot recognises it (classKey is the track's own GUID for source hosts); returns its GUID; outside mutate
function wm:createSourceTrack(opts)
  ensureScratchTrack()
  reaper.PreventUIRefresh(1)
  local insertIdx = math.floor(reaper.GetMediaTrackInfo_Value(scratchTrack, 'IP_TRACKNUMBER')) - 1
  reaper.InsertTrackAtIndex(insertIdx, true)
  local track = reaper.GetTrack(0, insertIdx)
  if opts and opts.name then
    reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', opts.name, true)
  end
  cm:writeTrackKey(track, 'wiringHostKind', 'sourceTrack')
  reaper.PreventUIRefresh(-1)
  return reaper.GetTrackGUID(track)
end

--contract: one Undo block around instantiate + mutate; stamps fxGuid on the new fx-node
--contract: generators (io.ins==0) also spawn sourceTrack + source-node + midi edge
--contract: returns new fx-node id; nil+err on validate failure or ext_midi_bus refusal
function wm:addFxNode(x, y, fx, opts)
  ensureLoaded()
  local addErr = self:checkUserAddable(fx.ident)
  if addErr then return nil, addErr end
  reaper.Undo_BeginBlock()
  local io         = self:instantiateFxOnScratch(fx.ident)
  local sourceGuid = (io.ins == 0) and self:createSourceTrack{ name = fx.name } or nil
  local newId
  local ok, err = self:mutate(function(g)
    local fxId = 'n' .. g.nextId
    g.nextId = g.nextId + 1
    newId = fxId
    g.nodes[fxId] = {
      kind      = 'fx',
      pos       = { x = x, y = y },
      fxIdent   = fx.ident,
      fxDisplay = fx.name,
      fxGuid    = io.fxGuid,
      busAware  = false,
      ports     = {
        audio = { ins      = io.ins,     outs     = io.outs,
                  inNames  = io.inNames, outNames = io.outNames },
        midi  = { ins = 1, outs = 1 },
      },
    }
    if sourceGuid then
      local sourceId = 'n' .. g.nextId
      g.nextId = g.nextId + 1
      local sp = (opts and opts.sourcePos) or { x = x - 140, y = y }
      g.nodes[sourceId] = {
        kind        = 'source',
        pos         = { x = sp.x, y = sp.y },
        trackGuid   = sourceGuid,
        displayName = fx.name,
        ports       = { audio = { ins = 0, outs = 1 },
                        midi  = { ins = 0, outs = 1 } },
      }
      util.add(g.edges, { type = 'midi', from = sourceId, to = fxId })
    end
  end)
  reaper.Undo_EndBlock2(0, 'wiring: add ' .. (fx.name or fx.ident), -1)
  if not ok then return nil, err end
  return newId
end

----- FX MIDI routing surgery (state chunk)

-- No ReaScript API for per-FX in/out bus + disable bits — patches the
-- chunk directly. See docs/wiringManager.md § Per-FX MIDI routing.

local fxRoutingAlpha = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local fxRoutingDec   = {}
for i = 1, #fxRoutingAlpha do fxRoutingDec[fxRoutingAlpha:sub(i, i):byte()] = i - 1 end

local function b64decode(s)
  local bytes, buf, bits = {}, 0, 0
  for i = 1, #s do
    local c = s:byte(i)
    if c == 61 then break end  -- '='
    local v = fxRoutingDec[c]
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
      out[#out + 1] = fxRoutingAlpha:sub(v + 1, v + 1)
      buf = buf - (v << bits)
    end
  end
  if bits > 0 then
    local v = (buf << (6 - bits)) & 0x3F
    out[#out + 1] = fxRoutingAlpha:sub(v + 1, v + 1)
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

-- CU params live at stable slider indices; cache the {name=idx} map on
-- first sight so ownedChain doesn't re-enumerate per snap.
local cuParamIdxCache = nil
local function cuParamIdx(track, fxIdx)
  if cuParamIdxCache then return cuParamIdxCache end
  local out = {}
  for p = 0, 31 do
    local ok, name = reaper.TrackFX_GetParamName(track, fxIdx, p)
    if not ok then break end
    out[name] = p
  end
  cuParamIdxCache = out
  return out
end

-- Locate the (fxIdx+1)-th non-JS FX block in the chunk (0-indexed).
-- Returns (firstBase64LineIdx, trailerLineIdx) or nil.
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
-- { inBus?, outBus?, inDisabled?, outDisabled? }; see docs/wiringManager.md § Per-FX MIDI routing.
function wm.setFXMidiRouting(chunk, fxIdx, opts, pinChannels)
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

-- True iff `graph` has any edge with type='midi' leaving `nodeId`.
-- Drives target.midiOut for non-JS fx in projectEntry.
local function nodeHasMidiOut(graph, nodeId)
  for _, e in ipairs(graph.edges) do
    if e.from == nodeId and e.type == 'midi' then return true end
  end
  return false
end

----- Snapshot / target / diff (Stage 2)

-- Adjacent set bits collapse to one pair; lLo|hLo merges the port's two pins.
local function decodePairList(track, fxIdx, isoutput, port)
  local lowPin = 2 * (port - 1)
  local lLo    = reaper.TrackFX_GetPinMappings(track, fxIdx, isoutput, lowPin)
  local hLo    = reaper.TrackFX_GetPinMappings(track, fxIdx, isoutput, lowPin + 1)
  local mask   = lLo | hLo
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
local function readPinMapsForFx(track, fxIdx)
  local _, ins, outs = reaper.TrackFX_GetIOSize(track, fxIdx)
  local function dirMap(isoutput, pinCount)
    local ports, out = math.floor(pinCount / 2), {}
    for port = 1, ports do
      local pairList = decodePairList(track, fxIdx, isoutput, port)
      if #pairList > 0 then out[port] = pairList end
    end
    return out
  end
  return { ins = dirMap(0, ins), outs = dirMap(1, outs) }
end

-- Walk `track`'s chain, returning (fxOrder, pinMaps) for owned fx; disconnected
-- pin maps are dropped (absent ⇒ disconnected). See docs/wiringManager.md.
local function ownedChain(track, ownedGuids)
  local out, pinMaps = {}, {}
  for fxIdx = 0, reaper.TrackFX_GetCount(track) - 1 do
    local _, ident = reaper.TrackFX_GetFXName(track, fxIdx)
    local guid     = reaper.TrackFX_GetFXGUID(track, fxIdx)
    local isJS     = ident and ident:sub(1, 3) == 'JS:'
    if ownedGuids[guid] then
      local entry = { fxGuid = guid, ident = ident }
      if not isJS then
        local applied = appliedMidiOut[guid]
        entry.midiOut = applied == nil or applied
      elseif ident == CU_IDENT then
        -- Mirror live CU params so fxOrderEq is honest; without it every reconcile spuriously emits setFXChain.
        local idx     = cuParamIdx(track, fxIdx)
        local modeInt = math.floor(reaper.TrackFX_GetParam(track, fxIdx, idx.mode) + 0.5)
        local modeStr = ({ [0] = 'gain', [1] = 'channelRemap',
                           [2] = 'busRoute', [3] = 'merge' })[modeInt] or 'gain'
        if modeStr == 'busRoute' then
          entry.params = { mode = modeStr,
                           from = math.floor(reaper.TrackFX_GetParam(track, fxIdx, idx.from) + 0.5),
                           to   = math.floor(reaper.TrackFX_GetParam(track, fxIdx, idx.to) + 0.5) }
        elseif modeStr == 'merge' then
          local nPairs = math.floor(reaper.TrackFX_GetParam(track, fxIdx, idx.nPairs) + 0.5)
          local gains, inMask = {}, {}
          for i = 1, nPairs do gains[i] = reaper.TrackFX_GetParam(track, fxIdx, idx['gain' .. i]) end
          for i = 0, 3 do inMask[i + 1] = math.floor(reaper.TrackFX_GetParam(track, fxIdx, idx['inMask' .. i]) + 0.5) end
          entry.params = { mode = modeStr, nPairs = nPairs, gains = gains,
                           audioSum = math.floor(reaper.TrackFX_GetParam(track, fxIdx, idx.audioSum) + 0.5),
                           outBus   = math.floor(reaper.TrackFX_GetParam(track, fxIdx, idx.outBus) + 0.5),
                           inMask   = inMask }
        else
          entry.params = { mode = modeStr,
                           gain = reaper.TrackFX_GetParam(track, fxIdx, idx.gain) }
        end
      end
      util.add(out, entry)
      local pm = readPinMapsForFx(track, fxIdx)
      if next(pm.ins) or next(pm.outs) then pinMaps[guid] = pm end
    end
  end
  return out, pinMaps
end

-- Audio if I_MIDIFLAGS low-5-bits == 31 (midi disabled); midi if I_SRCCHAN
-- == -1 (audio disabled). Anything carrying both reads as 'audio' —
-- defensive; the differ doesn't model dual-stream sends.
local function sendType(track, sendIdx)
  local srcChan   = reaper.GetTrackSendInfo_Value(track, 0, sendIdx, 'I_SRCCHAN')
  local midiFlags = reaper.GetTrackSendInfo_Value(track, 0, sendIdx, 'I_MIDIFLAGS')
  local midiOff = (math.floor(midiFlags) % 32) == 31
  if srcChan == -1 then return 'midi' end
  if midiOff           then return 'audio' end
  return 'audio'
end

local function readSendsClass(track, byTrack)
  local out = {}
  for i = 0, reaper.GetTrackNumSends(track, 0) - 1 do
    local dst = reaper.GetTrackSendInfo_Value(track, 0, i, 'P_DESTTRACK')
    local dstClass = byTrack[dst]
    if dstClass then
      local typ   = sendType(track, i)
      local entry = { to = dstClass, type = typ, srcChan = 0, dstChan = 0 }
      if typ == 'audio' then
        entry.srcChan = math.floor(reaper.GetTrackSendInfo_Value(track, 0, i, 'I_SRCCHAN'))
        entry.dstChan = math.floor(reaper.GetTrackSendInfo_Value(track, 0, i, 'I_DSTCHAN'))
        entry.gain    = reaper.GetTrackSendInfo_Value(track, 0, i, 'D_VOL')
      else
        local mf = math.floor(reaper.GetTrackSendInfo_Value(track, 0, i, 'I_MIDIFLAGS'))
        entry.srcChan = math.max(0, ((mf >> 14) & 0xFF) - 1)
        entry.dstChan = math.max(0, ((mf >> 22) & 0xFF) - 1)
      end
      util.add(out, entry)
    end
  end
  return out
end

--contract: walks every project track, builds a wiringSnapshot of REAPER's current state restricted to wm-owned things (tracks tagged wiringHostKind; FX whose guids appear in the user graph (fx nodes) or edge ops (CUs); sends whose dst is itself a managed track). Foreign tracks/FX/sends are invisible. Read-only.
function wm:snapshot()
  ensureLoaded()
  -- Ownership = current-graph guids ∪ persisted wiringOwnedFx set. The
  -- persisted set keeps previously-realised FX visible to snapshot after
  -- their owning node has been removed from the graph, so wm:diff can
  -- emit the delete op on the next reconcile pass.
  local ownedGuids = {}
  for k in pairs(cm:get('wiringOwnedFx') or {}) do ownedGuids[k] = true end
  for _, n in pairs(userGraph.nodes) do
    if n.kind == 'fx' then
      if n.fxGuid              then ownedGuids[n.fxGuid]              = true end
      if n.midiInBracketGuid   then ownedGuids[n.midiInBracketGuid]   = true end
      if n.midiOutBracketGuid  then ownedGuids[n.midiOutBracketGuid]  = true end
    end
    if n.mergeGuids then
      for _, g in pairs(n.mergeGuids) do ownedGuids[g] = true end
    end
  end
  for _, e in ipairs(userGraph.edges) do
    if e.opFxGuid then ownedGuids[e.opFxGuid] = true end
  end
  -- First pass: discover managed tracks + their (classKey, hostKind), so
  -- the second pass can resolve send destinations by track → classKey.
  -- sourceTrack hosts derive classKey from their own GUID (singleton class);
  -- newTrack hosts must carry wiringClass explicitly (multi-guid key).
  local snap, byTrack, byKind = {}, {}, {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    local hostKind = cm:readTrackKey(track, 'wiringHostKind')
    local classKey
    if hostKind == 'sourceTrack' then
      classKey = reaper.GetTrackGUID(track)
    elseif hostKind == 'newTrack' then
      classKey = cm:readTrackKey(track, 'wiringClass')
    elseif cm:readTrackKey(track, 'wiringScratch') == '1' then
      classKey, hostKind = SCRATCH_KEY, 'scratch'
    end
    if classKey then
      byTrack[track]   = classKey
      byKind[classKey] = hostKind
    end
  end
  for track, classKey in pairs(byTrack) do
    local hostKind  = byKind[classKey]
    local isScratch = hostKind == 'scratch'
    local fxOrder, pinMaps = ownedChain(track, ownedGuids)
    local mainSend = not isScratch
                     and reaper.GetMediaTrackInfo_Value(track, 'B_MAINSEND') ~= 0
                     or false
    snap[classKey] = {
      hostKind     = hostKind,
      trackGuid    = reaper.GetTrackGUID(track),
      fxOrder      = fxOrder,
      mainSend     = mainSend,
      mainSendGain = not isScratch
                     and reaper.GetMediaTrackInfo_Value(track, 'D_VOL')
                     or nil,
      mainSendOffs = mainSend
                     and math.floor(reaper.GetMediaTrackInfo_Value(track, 'C_MAINSEND_OFFS'))
                     or nil,
      nchan        = math.floor(reaper.GetMediaTrackInfo_Value(track, 'I_NCHAN')),
      pinMaps      = pinMaps,
      sends        = isScratch and {} or readSendsClass(track, byTrack),
    }
  end

  -- The REAPER master is a project-wide singleton, not enumerated by
  -- CountTracks/GetTrack. Synthesise a snap entry under '__master__' when
  -- any wm-owned FX live on master so wm:diff can detect transitions onto
  -- or off the master host.
  if reaper.GetMasterTrack then
    local master = reaper.GetMasterTrack(0)
    local masterChain, masterPinMaps = ownedChain(master, ownedGuids)
    if #masterChain > 0 then
      snap['__master__'] = {
        hostKind = 'master', trackGuid = nil, fxOrder = masterChain,
        mainSend = false, sends = {},
        nchan    = math.floor(reaper.GetMediaTrackInfo_Value(master, 'I_NCHAN')),
        pinMaps  = masterPinMaps,
      }
    end
  end
  return snap
end

-- Same key shape as wm:applyOps stamps, so the pin-map applier can
-- resolve unmaterialised fxs through stampsByOrigin[originKey].
local function originKey(origin)
  if origin.kind == 'node'      then return 'node:' .. origin.id end
  if origin.kind == 'bracketIn' then return 'bracketIn:'  .. origin.id end
  if origin.kind == 'bracketOut' then return 'bracketOut:' .. origin.id end
  if origin.kind == 'merge' then return 'merge:' .. origin.consumer .. '\0' .. origin.host end
  return 'edge:' .. origin.idx
end

-- pinMaps forks by materialisation: fxGuid-keyed entries land in pinMaps,
-- unmaterialised ones (no fxGuid yet) in pinMapsByOrigin for the applier.
local function projectEntry(planEntry, compileNodes, scratchGuid)
  local synth    = planEntry.synthNodes or {}
  local brackets = planEntry.bracketNodes or {}
  local function resolveNode(id) return compileNodes[id] or synth[id] or brackets[id] end
  local fxOrder, originByCompileId = {}, {}
  for _, id in ipairs(planEntry.fxOrder) do
    local node = resolveNode(id)
    if node and node.kind == 'fx' then
      local entry = { fxGuid = node.fxGuid, ident = node.fxIdent }
      if node.originSide then
        local consumer = compileNodes[node.originNode] or {}
        local stamp = node.originSide == 'in'
                      and consumer.midiInBracketGuid
                      or  consumer.midiOutBracketGuid
        entry.fxGuid = stamp
        entry.params = util.deepClone(node.params)
        entry.origin = { kind = node.originSide == 'in' and 'bracketIn' or 'bracketOut',
                         id = node.originNode }
      elseif node.originConsumer then
        local consumer = compileNodes[node.originConsumer] or {}
        entry.fxGuid = consumer.mergeGuids and consumer.mergeGuids[node.originHost]
        entry.params = util.deepClone(node.params)
        entry.origin = { kind = 'merge', consumer = node.originConsumer, host = node.originHost }
      elseif node.params then
        entry.params = util.deepClone(node.params)
        entry.origin = { kind = 'edge', idx = node.originEdgeIdx }
      else
        entry.origin = { kind = 'node', id = id }
        if not (node.fxIdent and node.fxIdent:sub(1, 3) == 'JS:') then
          entry.midiOut = nodeHasMidiOut(userGraph, id)
        end
      end
      originByCompileId[id] = entry
      util.add(fxOrder, entry)
    end
  end
  local pinMaps, pinMapsByOrigin = {}, {}
  for compileId, pm in pairs(planEntry.pinMaps or {}) do
    local entry = originByCompileId[compileId]
    if entry then
      local target = entry.fxGuid and pinMaps or pinMapsByOrigin
      local key    = entry.fxGuid or originKey(entry.origin)
      target[key]  = util.deepClone(pm)
    end
  end
  local trackGuid
  if     planEntry.hostKind == 'sourceTrack' then trackGuid = planEntry.trackGuid
  elseif planEntry.hostKind == 'scratch'     then trackGuid = scratchGuid end
  return {
    hostKind         = planEntry.hostKind,
    trackGuid        = trackGuid,
    fxOrder          = fxOrder,
    mainSend         = planEntry.mainSend,
    mainSendGain     = planEntry.mainSendGain,
    mainSendOffs     = planEntry.mainSendOffs,
    sends            = util.deepClone(planEntry.sends),
    nchan            = planEntry.nchan,
    pinMaps          = pinMaps,
    pinMapsByOrigin  = pinMapsByOrigin,
  }
end

--contract: pure (reads only GetTrackGUID on scratch); derives wiringSnapshot from DAG.targetPlan
-- see docs/wiringManager.md
function wm:targetState()
  ensureLoaded()
  local cx = DAG.compile(userGraph)
  local nodes = userGraph.nodes
  local plan = DAG.allocate(cx:targetPlan(), nodes)
  local scratchGuid = scratchTrack and reaper.GetTrackGUID(scratchTrack)
  local out = {}
  for classKey, entry in pairs(plan) do
    out[classKey] = projectEntry(entry, nodes, scratchGuid)
  end
  return out
end

local function fxOrderEq(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    local x, y = a[i], b[i]
    if x.fxGuid  ~= y.fxGuid  or x.ident ~= y.ident    then return false end
    if x.midiOut ~= y.midiOut                          then return false end
    if not util.deepEq(x.params or {}, y.params or {}) then return false end
  end
  return true
end

local function sendsEq(a, b)
  if #a ~= #b then return false end
  -- Set-equality on the 4-tuple identity (to, type, srcChan, dstChan); gain
  -- rides as the value so D_VOL drift drives a setSends.
  local byKey = {}
  for _, s in ipairs(a) do
    local k = s.to .. '|' .. s.type .. '|' .. s.srcChan .. '|' .. s.dstChan
    byKey[k] = s.gain or 1.0
  end
  for _, s in ipairs(b) do
    local k = s.to .. '|' .. s.type .. '|' .. s.srcChan .. '|' .. s.dstChan
    if byKey[k] == nil or byKey[k] ~= (s.gain or 1.0) then return false end
  end
  return true
end

-- snap can only key pinMaps by fxGuid, so any target.pinMapsByOrigin
-- (unmaterialised fxs) is by definition unrepresented in snap and must drift.
local function pinMapsEq(t_, s)
  if t_.pinMapsByOrigin and next(t_.pinMapsByOrigin) then return false end
  local tPM, sPM = t_.pinMaps or {}, (s and s.pinMaps) or {}
  local keys = {}
  for k in pairs(tPM) do keys[k] = true end
  for k in pairs(sPM) do keys[k] = true end
  for k in pairs(keys) do
    if not util.deepEq(tPM[k] or { ins = {}, outs = {} },
                       sPM[k] or { ins = {}, outs = {} }) then return false end
  end
  return true
end

--contract: pure structural diff producing a wiringOp[] that, applied, would carry snap to target. Order: creates first (so subsequent setSends can reference fresh tracks), then host-transition drains, then setFXChain / setMainSend / setSends / setExtState, then deletes. snap entries absent from target — or with a changed hostKind — and hostKind='newTrack' are deleted; sourceTrack/scratch/master are never deleted (project artefacts) but get drained on host transition. setFXChain/setMainSend/setSends ops carry hostKind so the applier can resolve master without a classKey tag (the REAPER master can't be tagged like a user track).
function wm:diff(target, snap)
  local ops = {}

  local hostChanged = {}
  for classKey, t_ in pairs(target) do
    local s = snap[classKey]
    if s and s.hostKind ~= t_.hostKind then hostChanged[classKey] = true end
  end

  -- Creates (order before mutates so setSends can reference fresh hosts).
  -- Both target-only newTracks and host-transitions-to-newTrack mint a track.
  for classKey, t_ in pairs(target) do
    local s = snap[classKey]
    if (not s or hostChanged[classKey]) and t_.hostKind == 'newTrack' then
      util.add(ops, { op = 'createTrack', classKey = classKey, hostKind = 'newTrack' })
    end
  end

  -- Cross-host move pass: relocate guids whose host changed via is_move=true,
  -- emitted before per-class setFXChain (see --shape wiringOp above for WHY).
  local snapGuidToHost = {}
  for classKey, s in pairs(snap) do
    for _, e in ipairs(s.fxOrder) do
      if e.fxGuid then snapGuidToHost[e.fxGuid] = classKey end
    end
  end
  for classKey, t_ in pairs(target) do
    for _, e in ipairs(t_.fxOrder) do
      local fromKey = e.fxGuid and snapGuidToHost[e.fxGuid]
      if fromKey and fromKey ~= classKey then
        local s = snap[fromKey]
        util.add(ops, { op = 'moveFxAcrossHosts',
                        fxGuid        = e.fxGuid,
                        fromHostKind  = s.hostKind, fromTrackGuid = s.trackGuid,
                        toHostKind    = t_.hostKind, toTrackGuid  = t_.trackGuid,
                        toClassKey    = classKey })
      end
    end
  end

  -- Per-class field diffs. A hostKind transition is treated as fresh: every
  -- field op + setExtState fires unconditionally so the new host gets fully
  -- populated.
  for classKey, t_ in pairs(target) do
    local s = snap[classKey]
    local fresh = not s or hostChanged[classKey]
    if fresh or not fxOrderEq(t_.fxOrder, s.fxOrder) then
      util.add(ops, { op = 'setFXChain', classKey = classKey,
                      hostKind = t_.hostKind,
                      trackGuid = t_.trackGuid, fxOrder = util.deepClone(t_.fxOrder) })
    end
    local tNchan = t_.nchan or 2
    local sNchan = (s and s.nchan) or 2
    if tNchan ~= sNchan then
      util.add(ops, { op = 'setNchan', classKey = classKey,
                      hostKind = t_.hostKind, trackGuid = t_.trackGuid,
                      value = tNchan })
    end
    if not pinMapsEq(t_, s) then
      util.add(ops, { op = 'setPinMaps', classKey = classKey,
                      hostKind = t_.hostKind, trackGuid = t_.trackGuid,
                      pinMaps         = util.deepClone(t_.pinMaps         or {}),
                      pinMapsByOrigin = util.deepClone(t_.pinMapsByOrigin or {}) })
    end
    local tGain = t_.mainSendGain or 1.0
    local sGain = (s and s.mainSendGain) or 1.0
    local tOffs = (t_.mainSend and t_.mainSendOffs) or 0
    local sOffs = (s and s.mainSend and s.mainSendOffs) or 0
    if (fresh and (t_.mainSend or tGain ~= 1.0))
       or (not fresh and (t_.mainSend ~= s.mainSend or tGain ~= sGain
                                                    or tOffs ~= sOffs)) then
      util.add(ops, { op = 'setMainSend', classKey = classKey,
                      hostKind = t_.hostKind, trackGuid = t_.trackGuid,
                      value = t_.mainSend, gain = tGain, offs = tOffs })
    end
    if fresh or not sendsEq(t_.sends, s.sends) then
      util.add(ops, { op = 'setSends', classKey = classKey,
                      hostKind = t_.hostKind,
                      trackGuid = t_.trackGuid, sends = util.deepClone(t_.sends) })
    end
    -- ExtState writes only on creation/host-transition-in. sourceTrack hosts
    -- get only wiringHostKind (the track's own guid is the classKey already);
    -- newTrack hosts also need wiringClass to carry the multi-guid key.
    if fresh and t_.hostKind == 'sourceTrack' then
      util.add(ops, { op = 'setExtState', classKey = classKey,
                      key = 'wiringHostKind', value = 'sourceTrack' })
    elseif fresh and t_.hostKind == 'newTrack' then
      util.add(ops, { op = 'setExtState', classKey = classKey,
                      key = 'wiringHostKind', value = 'newTrack' })
      util.add(ops, { op = 'setExtState', classKey = classKey,
                      key = 'wiringClass', value = classKey })
    end
  end

  -- Drains/deletes last so any final reads of going-away tracks have already
  -- run. A snap entry is abandoned if absent from target, or if its host
  -- changed: newTrack hosts get deleteTrack (which kills any owned FX with the
  -- track); undeletable hosts (sourceTrack/master/scratch) with surviving
  -- owned FX need an explicit setFXChain to [] to drain them.
  for classKey, s in pairs(snap) do
    local abandoned = not target[classKey] or hostChanged[classKey]
    if abandoned then
      if s.hostKind == 'newTrack' then
        util.add(ops, { op = 'deleteTrack', trackGuid = s.trackGuid })
      elseif #s.fxOrder > 0 then
        util.add(ops, { op = 'setFXChain', classKey = classKey,
                        hostKind = s.hostKind, trackGuid = s.trackGuid, fxOrder = {} })
      end
    end
  end

  return ops
end

----- Apply ops (Stage 2)

-- CU JSFX exposes 'mode' as an enum slider; this table is the wm/CU bridge
-- contract that maps a mode-string in `params` to the slider's float value.
-- Lives here (not in DAG) because lowering is pure and shouldn't know about
-- the JSFX's numeric encoding.
local CU_MODE_TO_FLOAT = { gain = 0, channelRemap = 1, busRoute = 2, merge = 3 }

local function paramValueAsFloat(name, value)
  if name == 'mode' and type(value) == 'string' then
    local f = CU_MODE_TO_FLOAT[value]
    if not f then error(("unknown CU mode %q"):format(value)) end
    return f
  end
  if type(value) == 'number' then return value end
  error(("cannot push param %q with non-numeric value %q"):format(name, tostring(value)))
end

local function resolveParamIdx(track, fxIdx, ident, paramName, cache)
  cache[ident] = cache[ident] or {}
  if cache[ident][paramName] ~= nil then return cache[ident][paramName] end
  for p = 0, 511 do
    local ok, name = reaper.TrackFX_GetParamName(track, fxIdx, p)
    if not ok then break end
    if name == paramName then
      cache[ident][paramName] = p
      return p
    end
  end
  error(("FX %q has no param named %q"):format(ident, paramName))
end

local function pushParams(track, fxIdx, ident, params, cache)
  for k, v in pairs(params) do
    -- channelRemap.map is a 16-entry table, not a single slider; deferred
    -- until the channelRemap mode is exercised end-to-end.
    if k == 'map' then
      error('CU channelRemap param push deferred to follow-up slice')
    elseif k == 'gains' then
      -- Merge gain bank: one slider per pair (gain1..gainN).
      for i, g in ipairs(v) do
        local pIdx = resolveParamIdx(track, fxIdx, ident, 'gain' .. i, cache)
        reaper.TrackFX_SetParam(track, fxIdx, pIdx, g)
      end
    elseif k == 'inMask' then
      -- Merge midi input-bus mask: four 32-bit lanes inMask0..inMask3.
      for i, lane in ipairs(v) do
        local pIdx = resolveParamIdx(track, fxIdx, ident, 'inMask' .. (i - 1), cache)
        reaper.TrackFX_SetParam(track, fxIdx, pIdx, lane)
      end
    else
    local pIdx = resolveParamIdx(track, fxIdx, ident, k, cache)
    reaper.TrackFX_SetParam(track, fxIdx, pIdx, paramValueAsFloat(k, v))
    end
  end
end

-- Pair P sits on channels 2(P-1) (left) and 2(P-1)+1 (right); each port's two
-- pins carry the left- and right-bit masks respectively, ORed across pairs.
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
local function writePinMapsForFx(track, fxIdx, pm)
  local _, ins, outs = reaper.TrackFX_GetIOSize(track, fxIdx)
  local function dir(isoutput, pinCount, byPort)
    byPort = byPort or {}
    for port = 1, math.floor(pinCount / 2) do
      local pairList = byPort[port] or {}
      for pinOffset = 0, 1 do
        local lo, hi = pinMaskFor(pairList, pinOffset)
        reaper.TrackFX_SetPinMappings(track, fxIdx, isoutput,
                                      2 * (port - 1) + pinOffset, lo, hi)
      end
    end
  end
  dir(0, ins,  pm.ins)
  dir(1, outs, pm.outs)
end

local function ownedSubsequence(track, ownedGuids)
  local out = {}
  for fxIdx = 0, reaper.TrackFX_GetCount(track) - 1 do
    local guid = reaper.TrackFX_GetFXGUID(track, fxIdx)
    if ownedGuids[guid] then
      local _, ident = reaper.TrackFX_GetFXName(track, fxIdx)
      util.add(out, { fxGuid = guid, ident = ident, absIdx = fxIdx })
    end
  end
  return out
end

-- Reconcile the OWNED subsequence of `track`'s FX chain to `target`. Foreign
-- (non-owned) FX keep their absolute positions; owned FX is treated as a
-- contiguous block: new owned FX inserts at "just after last owned", so the
-- block stays contiguous and doesn't interleave with user-managed plugins.
local function reconcileFXChain(track, target, ownedGuids, stamps, paramIdxCache)
  local current = ownedSubsequence(track, ownedGuids)

  -- Stale-guid sweep: a target entry whose fxGuid isn't live in REAPER (project
  -- reload, manual delete, drift) is reset to nil so step 2 re-materialises it
  -- and step 3's stamp-back rewrites the user graph with the fresh guid.
  local liveGuids = {}
  for _, c in ipairs(current) do liveGuids[c.fxGuid] = true end
  for _, t in ipairs(target) do
    if t.fxGuid and not liveGuids[t.fxGuid] then t.fxGuid = nil end
  end

  -- 1. Drop owned entries absent from target (right-to-left keeps absIdx valid).
  local targetGuids = {}
  for _, t in ipairs(target) do
    if t.fxGuid then targetGuids[t.fxGuid] = true end
  end
  for i = #current, 1, -1 do
    if not targetGuids[current[i].fxGuid] then
      reaper.TrackFX_Delete(track, current[i].absIdx)
      table.remove(current, i)
    end
  end

  -- 2. Materialise unmaterialised targets at the slot just after the last
  --    owned entry. AddByName appends; CopyToTrack(move=true) moves into place.
  for _, t in ipairs(target) do
    if not t.fxGuid then
      local insertAt = (#current > 0)
                       and (current[#current].absIdx + 1)
                       or  reaper.TrackFX_GetCount(track)
      local addedIdx = reaper.TrackFX_AddByName(track, t.ident, false, -1)
      if addedIdx < 0 then
        error('TrackFX_AddByName failed for ' .. tostring(t.ident))
      end
      if addedIdx ~= insertAt then
        reaper.TrackFX_CopyToTrack(track, addedIdx, track, insertAt, true)
      end
      local minted = reaper.TrackFX_GetFXGUID(track, insertAt)
      t.fxGuid = minted
      ownedGuids[minted] = true
      util.add(stamps, { origin = t.origin, guid = minted })
      util.add(current, { fxGuid = minted, ident = t.ident, absIdx = insertAt })
    end
  end

  -- 3. Permute the owned subsequence to match target order. Naive selection
  --    sort via CopyToTrack(move=true); contiguous-block invariant lets us
  --    re-derive absIdx from firstOwnedAbs after each swap.
  current = ownedSubsequence(track, ownedGuids)
  local firstOwnedAbs = current[1] and current[1].absIdx
  for d = 1, #target do
    if current[d].fxGuid ~= target[d].fxGuid then
      local fromIdx
      for j = d + 1, #current do
        if current[j].fxGuid == target[d].fxGuid then fromIdx = j; break end
      end
      reaper.TrackFX_CopyToTrack(track,
        current[fromIdx].absIdx, track, current[d].absIdx, true)
      local moved = current[fromIdx]
      table.remove(current, fromIdx)
      table.insert(current, d, moved)
      for i = 1, #current do current[i].absIdx = firstOwnedAbs + (i - 1) end
    end
  end

  -- 4. Push wm-owned params for every target entry that carries them.
  for d, t in ipairs(target) do
    if t.params then
      pushParams(track, current[d].absIdx, t.ident, t.params, paramIdxCache)
    end
  end

  -- 5. Reconcile per-FX MIDI passthrough (0x02) via the intent record.
  --    See docs/wiringManager.md § Routing intent record.
  local flips = {}
  for d, tgt in ipairs(target) do
    local guid = current[d].fxGuid
    if tgt.midiOut ~= nil and guid then
      local applied   = appliedMidiOut[guid]
      local effective = applied == nil or applied
      if tgt.midiOut ~= effective then
        flips[#flips + 1] = { fxGuid  = guid,
                              absIdx  = current[d].absIdx,
                              midiOut = tgt.midiOut }
      end
    end
  end
  if #flips > 0 then
    local absToRouting, routingIdx = {}, 0
    for i = 0, reaper.TrackFX_GetCount(track) - 1 do
      local _, ident = reaper.TrackFX_GetFXName(track, i)
      if not (ident and ident:sub(1, 3) == 'JS:') then
        absToRouting[i] = routingIdx
        routingIdx = routingIdx + 1
      end
    end
    local _, chunk = reaper.GetTrackStateChunk(track, '', true)
    for _, f in ipairs(flips) do
      local rIdx = absToRouting[f.absIdx]
      if rIdx then
        local _, inputPins, outputPins = reaper.TrackFX_GetIOSize(track, f.absIdx)
        chunk = wm.setFXMidiRouting(chunk, rIdx, { outDisabled = not f.midiOut },
                                    inputPins + outputPins)
      end
    end
    reaper.SetTrackStateChunk(track, chunk, true)
    for _, f in ipairs(flips) do appliedMidiOut[f.fxGuid] = f.midiOut end
  end
end

local function reconcileSends(track, target, classKeyToTrack)
  local function sendKey(dst, typ, src, dstCh)
    return tostring(dst) .. '|' .. typ .. '|' .. src .. '|' .. dstCh
  end
  local function readChans(idx, typ)
    if typ == 'audio' then
      return math.floor(reaper.GetTrackSendInfo_Value(track, 0, idx, 'I_SRCCHAN')),
             math.floor(reaper.GetTrackSendInfo_Value(track, 0, idx, 'I_DSTCHAN'))
    end
    local mf = math.floor(reaper.GetTrackSendInfo_Value(track, 0, idx, 'I_MIDIFLAGS'))
    return math.max(0, ((mf >> 14) & 0xFF) - 1),
           math.max(0, ((mf >> 22) & 0xFF) - 1)
  end
  local current = {}
  for i = 0, reaper.GetTrackNumSends(track, 0) - 1 do
    local dst = reaper.GetTrackSendInfo_Value(track, 0, i, 'P_DESTTRACK')
    local typ = sendType(track, i)
    local src, dstCh = readChans(i, typ)
    current[sendKey(dst, typ, src, dstCh)] = { idx = i }
  end
  local wanted = {}
  for _, s in ipairs(target) do
    local dst = classKeyToTrack[s.to]
    if dst then
      wanted[sendKey(dst, s.type, s.srcChan, s.dstChan)] =
        { dst = dst, typ = s.type, srcChan = s.srcChan, dstChan = s.dstChan,
          gain = s.gain or 1.0 }
    end
  end
  -- Drops right-to-left so REAPER's post-remove index shift stays sane.
  local dropIdx = {}
  for key, cur in pairs(current) do
    if not wanted[key] then util.add(dropIdx, cur.idx) end
  end
  table.sort(dropIdx, function(a, b) return a > b end)
  for _, idx in ipairs(dropIdx) do reaper.RemoveTrackSend(track, 0, idx) end
  -- Wiring sends are post-FX pre-fader (I_SENDMODE=3); audio writes channels.
  for key, w in pairs(wanted) do
    if not current[key] then
      local idx = reaper.CreateTrackSend(track, w.dst)
      if w.typ == 'midi' then
        reaper.SetTrackSendInfo_Value(track, 0, idx, 'I_SRCCHAN', -1)
        if w.srcChan ~= 0 or w.dstChan ~= 0 then
          local base = math.floor(reaper.GetTrackSendInfo_Value(track, 0, idx, 'I_MIDIFLAGS'))
          local flags = (base & 0x3FFF) | ((w.srcChan + 1) << 14) | ((w.dstChan + 1) << 22)
          reaper.SetTrackSendInfo_Value(track, 0, idx, 'I_MIDIFLAGS', flags)
        end
      else
        reaper.SetTrackSendInfo_Value(track, 0, idx, 'I_MIDIFLAGS', 31)
        reaper.SetTrackSendInfo_Value(track, 0, idx, 'I_SRCCHAN', w.srcChan)
        reaper.SetTrackSendInfo_Value(track, 0, idx, 'I_DSTCHAN', w.dstChan)
      end
      reaper.SetTrackSendInfo_Value(track, 0, idx, 'I_SENDMODE', 3)
    end
  end
  -- Gain drift: indices may have shifted; re-locate each by 4-tuple key.
  for i = 0, reaper.GetTrackNumSends(track, 0) - 1 do
    local dst = reaper.GetTrackSendInfo_Value(track, 0, i, 'P_DESTTRACK')
    local typ = sendType(track, i)
    local src, dstCh = readChans(i, typ)
    local w = wanted[sendKey(dst, typ, src, dstCh)]
    if w and typ == 'audio' then
      reaper.SetTrackSendInfo_Value(track, 0, i, 'D_VOL', w.gain)
    end
  end
end

local function ownedGuidsFrom(graph, persisted)
  local s = {}
  if persisted then
    for k in pairs(persisted) do s[k] = true end
  end
  for _, n in pairs(graph.nodes) do
    if n.kind == 'fx' then
      if n.fxGuid              then s[n.fxGuid]              = true end
      if n.midiInBracketGuid   then s[n.midiInBracketGuid]   = true end
      if n.midiOutBracketGuid  then s[n.midiOutBracketGuid]  = true end
    end
    if n.mergeGuids then
      for _, g in pairs(n.mergeGuids) do s[g] = true end
    end
  end
  for _, e in ipairs(graph.edges) do
    if e.opFxGuid then s[e.opFxGuid] = true end
  end
  return s
end

local function buildClassKeyToTrack()
  local out = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    local hostKind = cm:readTrackKey(track, 'wiringHostKind')
    if hostKind == 'sourceTrack' then
      out[reaper.GetTrackGUID(track)] = track
    elseif hostKind == 'newTrack' then
      local k = cm:readTrackKey(track, 'wiringClass')
      if k then out[k] = track end
    elseif cm:readTrackKey(track, 'wiringScratch') == '1' then
      out[SCRATCH_KEY] = track
    end
  end
  return out
end

local function scratchIndex()
  local scratch = ensureScratchTrack()
  for i = 0, reaper.CountTracks(0) - 1 do
    if reaper.GetTrack(0, i) == scratch then return i end
  end
end

local function createNewTrack(classKey)
  reaper.PreventUIRefresh(1)
  local insertAt = scratchIndex() or reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(insertAt, false)
  local track = reaper.GetTrack(0, insertAt)
  reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', 'continuum: ' .. classKey, true)
  reaper.PreventUIRefresh(-1)
  return track
end

--contract: walks ops in their emitted order inside one Undo_BeginBlock. setFXChain materialises nil-fxGuid entries via TrackFX_AddByName and stamps minted guids back into the user graph through a wm:mutate that's gated by `realising` so the live-recompile loop sees no signal. Param push resolves slider index by TrackFX_GetParamName and raises on unknown names.
function wm:applyOps(ops, label)
  ensureLoaded()
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local classKeyToTrack = buildClassKeyToTrack()
  local ownedGuids      = ownedGuidsFrom(userGraph, cm:get('wiringOwnedFx'))
  local stamps          = {}
  local paramIdxCache   = {}

  -- The REAPER master isn't tagged with wiringClass (it's a singleton), so
  -- classKeyToTrack only learns about it via the ops about to be applied.
  -- Pre-register under every classKey hosted on master so reconcileSends can
  -- resolve send destinations targeting a master-hosted class.
  local masterTrack = reaper.GetMasterTrack and reaper.GetMasterTrack(0) or nil
  if masterTrack then
    for _, op in ipairs(ops) do
      if op.hostKind == 'master' and op.classKey then
        classKeyToTrack[op.classKey] = masterTrack
      end
    end
  end

  -- Resolve the host track for a per-class op. master uses hostKind;
  -- snap-derived drain ops carry the snap trackGuid; target newTrack ops
  -- have trackGuid=nil and resolve via classKeyToTrack (populated by
  -- createTrack for fresh ones, by wiringClass scan for pre-existing).
  local function resolveTrack(op)
    if op.hostKind == 'master' then return masterTrack end
    if op.trackGuid then return self:trackByGuid(op.trackGuid) end
    return classKeyToTrack[op.classKey]
  end

  for _, op in ipairs(ops) do
    if op.op == 'createTrack' then
      classKeyToTrack[op.classKey] = createNewTrack(op.classKey)
    elseif op.op == 'deleteTrack' then
      local t = self:trackByGuid(op.trackGuid)
      if t then reaper.DeleteTrack(t) end
    elseif op.op == 'setExtState' then
      local t = classKeyToTrack[op.classKey]
      if t then cm:writeTrackKey(t, op.key, op.value) end
    elseif op.op == 'setMainSend' then
      local t = resolveTrack(op)
      if t then
        reaper.SetMediaTrackInfo_Value(t, 'B_MAINSEND', op.value and 1 or 0)
        reaper.SetMediaTrackInfo_Value(t, 'D_VOL', op.gain or 1.0)
        if op.value then
          reaper.SetMediaTrackInfo_Value(t, 'C_MAINSEND_OFFS', op.offs or 0)
        end
      end
    elseif op.op == 'setNchan' then
      local t = resolveTrack(op)
      if t then reaper.SetMediaTrackInfo_Value(t, 'I_NCHAN', op.value) end
    elseif op.op == 'setPinMaps' then
      local t = resolveTrack(op)
      if t then
        -- Newly stamped guids join ownedPlus so a same-apply setPinMaps lands
        -- on fxs minted by the preceding setFXChain.
        local guidByOrigin, ownedPlus = {}, {}
        for g in pairs(ownedGuids) do ownedPlus[g] = true end
        for _, st in ipairs(stamps) do
          guidByOrigin[originKey(st.origin)] = st.guid
          ownedPlus[st.guid] = true
        end
        local merged = {}
        for fxGuid, pm in pairs(op.pinMaps)         do merged[fxGuid] = pm end
        for oKey,   pm in pairs(op.pinMapsByOrigin) do
          local fxGuid = guidByOrigin[oKey]
          if fxGuid then merged[fxGuid] = pm end
        end
        for fxIdx = 0, reaper.TrackFX_GetCount(t) - 1 do
          local guid = reaper.TrackFX_GetFXGUID(t, fxIdx)
          if ownedPlus[guid] then
            writePinMapsForFx(t, fxIdx, merged[guid] or { ins = {}, outs = {} })
          end
        end
      end
    elseif op.op == 'setFXChain' then
      local t = resolveTrack(op)
      if t then reconcileFXChain(t, op.fxOrder, ownedGuids, stamps, paramIdxCache) end
    elseif op.op == 'moveFxAcrossHosts' then
      local fromTrack = (op.fromHostKind == 'master') and masterTrack
                        or self:trackByGuid(op.fromTrackGuid)
      local toTrack   = (op.toHostKind   == 'master') and masterTrack
                        or (op.toTrackGuid and self:trackByGuid(op.toTrackGuid))
                        or classKeyToTrack[op.toClassKey]
      if fromTrack and toTrack then
        local srcIdx
        for fxIdx = 0, reaper.TrackFX_GetCount(fromTrack) - 1 do
          if reaper.TrackFX_GetFXGUID(fromTrack, fxIdx) == op.fxGuid then
            srcIdx = fxIdx; break
          end
        end
        if srcIdx then
          local dstIdx = reaper.TrackFX_GetCount(toTrack)
          reaper.TrackFX_CopyToTrack(fromTrack, srcIdx, toTrack, dstIdx, true)
        end
      end
    elseif op.op == 'setSends' then
      local t = resolveTrack(op)
      if t then reconcileSends(t, op.sends, classKeyToTrack) end
    end
  end

  -- A wire whose gain folded to a native send owns no CU bridge; drop any
  -- stale opFxGuid (left from when the wire was intra-class) so the live-drag
  -- hot path resolves it as folded, not as a vanished CU.
  local ctx = DAG.compile(userGraph)
  local clearGuid = {}
  for edgeIdx, sink in pairs(ctx:gainSinks()) do
    local e = userGraph.edges[edgeIdx]
    if sink.kind ~= 'cu' and e and e.opFxGuid then clearGuid[edgeIdx] = true end
  end

  -- Per-consumer merge guids dangle when gain folds to a native send or fan-in
  -- drops to one. wantedMerge names still-active (consumer,host) pairs; rest swept.
  local wantedMerge = {}
  for _, hostEntry in pairs(ctx:targetPlan()) do
    for _, sn in pairs(hostEntry.synthNodes or {}) do
      if sn.originConsumer then
        wantedMerge[sn.originConsumer] = wantedMerge[sn.originConsumer] or {}
        wantedMerge[sn.originConsumer][sn.originHost] = true
      end
    end
  end

  -- Any node whose host fired setFXChain this pass without naming its brackets
  -- has had them removed from REAPER; clear the stale stamps on the user node.
  local bracketClassed, aliveBracketGuids = {}, {}
  for _, st in ipairs(stamps) do
    if st.origin.kind == 'bracketIn' or st.origin.kind == 'bracketOut' then
      aliveBracketGuids[st.guid] = true
    end
  end
  for _, op in ipairs(ops) do
    if op.op == 'setFXChain' then
      for _, ft in ipairs(op.fxOrder) do
        if ft.origin and ft.origin.kind == 'node' then bracketClassed[ft.origin.id] = true end
        if ft.fxGuid and ft.origin and
           (ft.origin.kind == 'bracketIn' or ft.origin.kind == 'bracketOut') then
          aliveBracketGuids[ft.fxGuid] = true
        end
      end
    end
  end

  if #stamps > 0 or next(clearGuid) or next(bracketClassed) then
    realising = true
    self:mutate(function(g)
      for _, st in ipairs(stamps) do
        if     st.origin.kind == 'node'       then g.nodes[st.origin.id].fxGuid              = st.guid
        elseif st.origin.kind == 'bracketIn'  then g.nodes[st.origin.id].midiInBracketGuid   = st.guid
        elseif st.origin.kind == 'bracketOut' then g.nodes[st.origin.id].midiOutBracketGuid  = st.guid
        elseif st.origin.kind == 'merge' then
          local n = g.nodes[st.origin.consumer]
          n.mergeGuids = n.mergeGuids or {}
          n.mergeGuids[st.origin.host] = st.guid
        else                                       g.edges[st.origin.idx].opFxGuid           = st.guid end
      end
      for idx in pairs(clearGuid) do g.edges[idx].opFxGuid = nil end
      for id, n in pairs(g.nodes) do
        if n.mergeGuids then
          for host in pairs(n.mergeGuids) do
            if not (wantedMerge[id] and wantedMerge[id][host]) then n.mergeGuids[host] = nil end
          end
          if not next(n.mergeGuids) then n.mergeGuids = nil end
        end
      end
      for nodeId in pairs(bracketClassed) do
        local n = g.nodes[nodeId]
        if n then
          if n.midiInBracketGuid  and not aliveBracketGuids[n.midiInBracketGuid]  then n.midiInBracketGuid  = nil end
          if n.midiOutBracketGuid and not aliveBracketGuids[n.midiOutBracketGuid] then n.midiOutBracketGuid = nil end
        end
      end
    end)
    realising = false
  end

  -- Persist the post-apply owned-guid set: anything still in the graph is
  -- still in REAPER (orphans got deleted in reconcileFXChain and dropped
  -- out of the graph in the mutator that removed them).
  local owned = ownedGuidsFrom(userGraph)
  cm:set('project', 'wiringOwnedFx', owned)
  for guid in pairs(appliedMidiOut) do
    if not owned[guid] then appliedMidiOut[guid] = nil end
  end
  cm:set('project', 'wiringMidiOutApplied', appliedMidiOut)

  -- Mirror to scratch P_EXT inside the same Undo_BeginBlock so REAPER's undo
  -- captures the graph alongside FX/track ops. SetProjExtState doesn't
  -- participate in undo, so the project tier alone would leave the persisted
  -- graph stale after a cmd-Z. pollUndo watches lastScratchRaw for divergence.
  local scratch = ensureScratchTrack()
  cm:writeTrackKey(scratch, 'wiringGraph',  userGraph)
  cm:writeTrackKey(scratch, 'wiringOwnedFx', owned)
  lastScratchRaw = cm:readTrackRaw(scratch)

  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock2(0, label or 'wiring: apply', -1)
end

--contract: pokes the live gain for edges[idx] with no mutate/signal/undo block (drag hot path). A materialised CU bridge → TrackFX_SetParam on 'gain'; a folded edge → D_VOL on its native sink (gainSinks: track→track send, or the from-track fader for the parent/master send). false when nothing hosts it yet (caller materialises via wv:setEdgeGain).
function wm:pokeEdgeGain(edgeIdx, gain)
  ensureLoaded()
  local edge = userGraph.edges[edgeIdx]
  if not edge then return false end
  local function probeAndSet(guid, paramName, value)
    local function probe(track)
      if not track then return false end
      for fxIdx = 0, reaper.TrackFX_GetCount(track) - 1 do
        if reaper.TrackFX_GetFXGUID(track, fxIdx) == guid then
          local pIdx = resolveParamIdx(track, fxIdx, CU_IDENT, paramName, pokeParamCache)
          reaper.TrackFX_SetParam(track, fxIdx, pIdx, value)
          return true
        end
      end
      return false
    end
    -- Master isn't in CountTracks/GetTrack; probe it first or a master-resident CU misses every frame.
    if probe(reaper.GetMasterTrack(0)) then return true end
    for i = 0, reaper.CountTracks(0) - 1 do
      if probe(reaper.GetTrack(0, i)) then return true end
    end
    return false
  end

  local ctx = DAG.compile(userGraph)

  -- Intra/master merge CU: no per-edge guid. Resolve the consumer + this edge's
  -- slot from the compiled plan, then poke gain{slot} on the per-consumer guid.
  if edge.type == 'audio' then
    for _, hostEntry in pairs(ctx:targetPlan()) do
      for _, sn in pairs(hostEntry.synthNodes or {}) do
        for slot, e in ipairs(sn.inputEdges or {}) do
          if e == edgeIdx then
            local consumer = userGraph.nodes[sn.originConsumer]
            local guid = consumer and consumer.mergeGuids
                         and consumer.mergeGuids[sn.originHost]
            return guid ~= nil and probeAndSet(guid, 'gain' .. slot, gain) or false
          end
        end
      end
    end
  end

  -- Folded: the gain lives on a native send. gainSinks names the sink so the
  -- hot path and targetPlan agree on where it lands.
  local sink = ctx:gainSinks()[edgeIdx]
  if not sink then return false end
  local byClass = buildClassKeyToTrack()
  if sink.kind == 'mainSend' then
    local track = byClass[sink.cls]
    if not track then return false end
    reaper.SetMediaTrackInfo_Value(track, 'D_VOL', gain)
    return true
  elseif sink.kind == 'send' then
    local src, dst = byClass[sink.from], byClass[sink.to]
    if src and dst then
      for i = 0, reaper.GetTrackNumSends(src, 0) - 1 do
        if reaper.GetTrackSendInfo_Value(src, 0, i, 'P_DESTTRACK') == dst
           and sendType(src, i) == 'audio' then
          reaper.SetTrackSendInfo_Value(src, 0, i, 'D_VOL', gain)
          return true
        end
      end
    end
  end
  return false
end

--contract: in-place gain commit + scratch mirror, one Undo block, no wiringChanged/reconcile
function wm:fastGainCommit(edgeIdx, gain)
  ensureLoaded()
  local edge = userGraph.edges[edgeIdx]
  if not edge or edge.type ~= 'audio' then return false end
  reaper.Undo_BeginBlock()
  edge.ops = edge.ops or {}
  edge.ops.gain = gain
  self:pokeEdgeGain(edgeIdx, gain)
  self:save()
  local scratch = ensureScratchTrack()
  cm:writeTrackKey(scratch, 'wiringGraph', userGraph)
  lastScratchRaw = cm:readTrackRaw(scratch)
  reaper.Undo_EndBlock2(0, 'wiring: edge gain', -1)
  return true
end

--contract: enumerates reaper.EnumInstalledFX once per wm instance; name is raw REAPER "Type: Name (Author)"
function wm:listInstalledFX()
  if installedFx then return installedFx end
  local out, i = {}, 0
  while true do
    local ok, name, ident = reaper.EnumInstalledFX(i)
    if not ok then break end
    util.add(out, { name = name, ident = ident })
    i = i + 1
  end
  installedFx = out
  return out
end

--contract: detects REAPER undo/redo of a wiring gesture by diffing scratch P_EXT against lastScratchRaw; on diff, mirrors scratch back to project tier, drops the in-memory graph, fires wiringChanged{kind='load'}. If scratch was deleted (manual or undo past its creation), reconciler recreates it on the next reconcile pass — so here we just clear the handle and let the live loop catch up.
function wm:pollUndo()
  if not scratchTrack then return end
  if reaper.ValidatePtr2 and not reaper.ValidatePtr2(0, scratchTrack, 'MediaTrack*') then
    scratchTrack, lastScratchRaw = nil, nil
    fire('wiringChanged', { kind = 'load' })
    return
  end
  local raw = cm:readTrackRaw(scratchTrack)
  if raw == lastScratchRaw then return end
  local mirrored = cm:readTrackKey(scratchTrack, 'wiringGraph')
  if not mirrored then return end
  cm:set('project', 'wiringGraph',  mirrored)
  cm:set('project', 'wiringOwnedFx', cm:readTrackKey(scratchTrack, 'wiringOwnedFx') or {})
  userGraph = nil
  lastScratchRaw = raw
  fire('wiringChanged', { kind = 'load' })
end

--contract: one reconcile pass — diff targetState against snapshot and applyOps the result under the given undo label
function wm:reconcile(label)
  self:applyOps(self:diff(self:targetState(), self:snapshot()), label or 'wiring: reconcile')
end

--contract: idempotent. Subscribes wm to its own wiringChanged so every mutate/load drives wm:reconcile, then runs one immediate pass to put REAPER in sync with the persisted graph.
function wm:enableLive(label)
  if liveLabel then return end
  liveLabel = label or 'wiring: apply'
  self:subscribe('wiringChanged', function(payload)
    self:reconcile(payload.kind == 'load' and 'wiring: reconcile (load)' or liveLabel)
  end)
  self:reconcile('wiring: reconcile (enable)')
end

return wm
