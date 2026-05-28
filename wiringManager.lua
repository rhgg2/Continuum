-- See docs/wiringManager.md for the model.
-- @noindex

--invariant: every fx-kind node carries fxGuid (nil pre-materialisation, stamped by the applier after TrackFX_AddByName). This is the only stable bridge identity between the user graph and a REAPER FX instance — snapshot and targetState match by it.
--shape: wiringSnapshot = { [classKey] = { hostKind='sourceTrack'|'newTrack'|'master'|'scratch', trackGuid?=string, fxOrder={ {fxGuid?=string, ident=string, params?=table, origin?={kind='node',id=string}|{kind='edge',idx=int}, midiOut?=bool}, ... }, mainSend=bool, sends={ {to=classKey, type='audio'|'midi'}, ... } } }; emitted by wm:snapshot and wm:targetState in matching shape so wm:diff can compare element-wise. fxOrder entries carrying `params` are wm-owned CU bridges (synthesised kind='fx' nodes from DAG.lower); snapshot never reads params back from REAPER, so any target with `params` drives setFXChain on every reconcile pass. `origin` is stamped on every target-side fxOrder entry by projectEntry so the applier knows where to write minted guids back; snap entries do not carry it and fxOrderEq ignores it. `midiOut` is set on both sides only for non-JS kind='node' entries — target derives it from the user graph (nodeHasMidiOut), snap from the FXCHAIN routing trailer's 0x02 bit; mismatch drives setFXChain so the applier reconciles the per-FX output-disabled bit.
--shape: wiringOp = { op='createTrack'|'deleteTrack'|'setFXChain'|'setMainSend'|'setSends'|'setExtState', ... }; full-replace ops, not incremental. setFXChain entries with fxGuid=nil mean 'instantiate ident, stamp guid back to graph' (interpreted by the applier).
--invariant: every authoring gesture goes through wm:mutate — clone draft, mutate, validate via DAG.validate, swap + persist + fire on success, return false+err on failure. The on-disk graph and the wiringChanged broadcast have therefore always passed validation.
--invariant: master node is a regular entry in graph.nodes under the fixed id 'master'; freshGraph materialises it on first load of an empty project; DAG.validate enforces the singleton.
--invariant: scratch track is a hidden REAPER track tagged via cm key 'wiringScratch'='1'; wm:load() and wm:probeFxIO() find-or-create it; future use is to host FX nodes with no compile-graph track of their own. Probing-via-instantiate is a Stage-1 bootstrapping affordance — the differ in Stage 2+ will read I/O off the real production FX instance and back-fill the node.

local util = require 'util'
local DAG  = require 'DAG'

local cm = (...).cm

local wm = {}
local fire = util.installHooks(wm)

local userGraph = nil
local installedFx = nil   -- session cache; reaper's installed-FX set is fixed at runtime
local scratchTrack = nil  -- hidden host for the probe (and, later, orphan FX nodes); reset by wm:load
local fxIO = {}           -- session cache: fxIdent → { ins, outs, inNames, outNames }
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

----------- PUBLIC

--contract: re-reads wiringGraph from cm (rebuilding master via freshGraph if empty), ensures the scratch track, fires wiringChanged{kind='load'}; drops the prior scratch handle (project may have changed)
function wm:load()
  userGraph = readPersisted()
  scratchTrack = nil
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

--contract: { ins, outs, inNames, outNames } in stereo ports for fxIdent; instantiates on the scratch track, reads TrackFX_GetIOSize + in_pin_X/out_pin_X via TrackFX_GetNamedConfigParm, deletes, caches by ident. Unknown ident → ins=outs=0 with empty name lists.
function wm:probeFxIO(ident)
  if fxIO[ident] then return fxIO[ident] end
  ensureScratchTrack()
  reaper.PreventUIRefresh(1)
  local fxIdx = reaper.TrackFX_AddByName(scratchTrack, ident, false, -1)
  local result
  if fxIdx < 0 then
    result = { ins = 0, outs = 0, inNames = {}, outNames = {} }
  else
    local _, inPins, outPins = reaper.TrackFX_GetIOSize(scratchTrack, fxIdx)
    inPins, outPins = inPins or 0, outPins or 0
    result = {
      ins      = inPins  / 2,
      outs     = outPins / 2,
      inNames  = portNames(scratchTrack, fxIdx, 'in',  inPins),
      outNames = portNames(scratchTrack, fxIdx, 'out', outPins),
    }
    reaper.TrackFX_Delete(scratchTrack, fxIdx)
  end
  reaper.PreventUIRefresh(-1)
  fxIO[ident] = result
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

----- FX MIDI routing surgery (state chunk)
--
-- REAPER has no ReaScript getter or setter for the per-FX MIDI input
-- bus / output bus / replace-or-merge mode encoded inside each
-- `<VST ...>` block in an FXCHAIN. The applier patches the chunk
-- directly when it needs to disable an FX's MIDI output bus. The
-- encoding is documented in docs/reaper_midi_routing.md; fixtures live
-- in design/midi-routing-fixtures.md and are pinned by fx_routing_spec.

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

-- Walk a track-state chunk and return a 0-indexed array of flag bytes,
-- one per non-JS FX block in chain order (the trailer byte that holds
-- the routing bits including 0x02 output-disabled). Lets wm:snapshot
-- read REAPER's view of routing state so wm:diff catches drift.
local function decodeChainFlags(chunk)
  local lines = splitChunkLines(chunk)
  local out, routingIdx = {}, 0
  local i = 1
  while i <= #lines do
    local ln = lines[i]
    if ln:match('^%s*<VST%s') or ln:match('^%s*<CLAP%s') or ln:match('^%s*<AU%s') then
      local depth, j, trailer = 1, i + 1, nil
      while j <= #lines do
        local s = lines[j]:match('^%s*(.-)%s*$')
        if s == '>' then
          depth = depth - 1
          if depth == 0 then break end
        elseif s:sub(1, 1) == '<' then
          depth = depth + 1
        elseif depth == 1 and s:match('^[A-Za-z0-9%+/=]+$') then
          trailer = s
        end
        j = j + 1
      end
      if trailer then
        local bytes = b64decode(trailer)
        if #bytes >= 6 then out[routingIdx] = bytes:byte(3) end
      end
      routingIdx = routingIdx + 1
      i = (depth == 0) and (j + 1) or (i + 1)
    else
      i = i + 1
    end
  end
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

local function setBitInBase64Line(line, byteIdx, mask, on)
  local lead, content, tail = line:match('^(%s*)(%S*)(%s*)$')
  if not content or content == '' then return line end
  local bytes = b64decode(content)
  if byteIdx < 1 or byteIdx > #bytes then return line end
  local b = bytes:byte(byteIdx)
  local newB = on and (b | mask) or (b & ~mask)
  if newB == b then return line end
  local patched = bytes:sub(1, byteIdx - 1)
               .. string.char(newB)
               .. bytes:sub(byteIdx + 1)
  return lead .. b64encode(patched) .. tail
end

-- Patch the 0x02 bit at a 1-indexed offset in the FX block's
-- concatenated decoded-base64 stream. Walks the content lines between
-- firstIdx and lastIdx inclusive, finds the line containing the offset
-- by accumulating decoded lengths, and mutates that single line.
-- Returns true if the offset landed inside a line; false otherwise.
local function patchStreamByte02(lines, firstIdx, lastIdx, streamOffset, on)
  local cursor = 0
  for i = firstIdx, lastIdx do
    local stripped = lines[i]:match('^%s*(.-)%s*$')
    if stripped:match('^[A-Za-z0-9%+/=]+$') then
      local n = #b64decode(stripped)
      if cursor + n >= streamOffset then
        lines[i] = setBitInBase64Line(lines[i], streamOffset - cursor, 0x02, on)
        return true
      end
      cursor = cursor + n
    end
  end
  return false
end

-- Drive the "output bus disabled" bit (0x02) on the fxIdx-th non-JS FX
-- block of an FXCHAIN-bearing track-state chunk: `disabled=true` sets
-- it, `disabled=false` clears it. Read-modify-write on that single
-- bit; every other flag bit, in_bus, and out_bus are preserved. The
-- flag lives in two places that REAPER keeps in sync and reads from
-- separately:
--   * the trailer line (last base64 content line of the VST block),
--     byte 3 of the decoded 6-byte trailer;
--   * a mirror at a fixed offset inside REAPER's wrapper header at the
--     head of the concatenated decoded stream: 1-indexed offset
--     `27 + 8 * pinChannels`, where pinChannels = inputPins+outputPins
--     (mono channels) as reported by TrackFX_GetIOSize. Trailer-only
--     writes do NOT take effect — the mirror is read by REAPER.
-- Idempotent. Pure: no state, no reaper deps — pinChannels comes from
-- the call site, which has the live track + fx index.
function wm.setFXOutputDisabled(chunk, fxIdx, disabled, pinChannels)
  local lines, hasTrailing = splitChunkLines(chunk)
  local first, trailer     = findFxBlock(lines, fxIdx)
  if not first then return chunk, false end

  lines[trailer] = setBitInBase64Line(lines[trailer], 3, 0x02, disabled)
  patchStreamByte02(lines, first, trailer, 27 + 8 * pinChannels, disabled)

  return joinChunkLines(lines, hasTrailing), true
end

-- True iff `graph` has any edge with type='midi' leaving `nodeId`. The
-- predicate that drives per-FX MIDI-out reconcile: a fx node with no
-- outgoing midi edge has its output bus disabled by the applier.
-- Stamped onto target fxOrder entries; snap reads the chunk for its
-- mirror, so wm:diff catches predicate drift in either direction.
local function nodeHasMidiOut(graph, nodeId)
  for _, e in ipairs(graph.edges) do
    if e.from == nodeId and e.type == 'midi' then return true end
  end
  return false
end

----- Snapshot / target / diff (Stage 2)

-- Walk the chain of one track, returning { {fxGuid, ident, midiOut?}, ... }
-- for FX whose guid appears in ownedGuids. midiOut comes from the chunk's
-- routing trailer (cleared 0x02 ⇒ midiOut=true); only non-JS entries carry
-- it. CU instances (JS) ride the same ownership predicate; the applier
-- persists their guid on the originating edge so subsequent snapshots
-- recognise them like any fx node.
local function ownedChain(track, ownedGuids)
  local _, chunk = reaper.GetTrackStateChunk(track, '', false)
  local flagAt   = decodeChainFlags(chunk)
  local out, routingIdx = {}, 0
  for fxIdx = 0, reaper.TrackFX_GetCount(track) - 1 do
    local _, ident = reaper.TrackFX_GetFXName(track, fxIdx)
    local guid     = reaper.TrackFX_GetFXGUID(track, fxIdx)
    local isJS     = ident and ident:sub(1, 3) == 'JS:'
    if ownedGuids[guid] then
      local entry = { fxGuid = guid, ident = ident }
      if not isJS then
        local flag    = flagAt[routingIdx]
        entry.midiOut = not (flag and (flag & 0x02) ~= 0)
      end
      util.add(out, entry)
    end
    if not isJS then routingIdx = routingIdx + 1 end
  end
  return out
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
      util.add(out, { to = dstClass, type = sendType(track, i) })
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
    if n.kind == 'fx' and n.fxGuid then ownedGuids[n.fxGuid] = true end
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
    snap[classKey] = {
      hostKind  = hostKind,
      trackGuid = reaper.GetTrackGUID(track),
      fxOrder   = ownedChain(track, ownedGuids),
      mainSend  = not isScratch
                  and reaper.GetMediaTrackInfo_Value(track, 'B_MAINSEND') ~= 0
                  or false,
      sends     = isScratch and {} or readSendsClass(track, byTrack),
    }
  end

  -- The REAPER master is a project-wide singleton, not enumerated by
  -- CountTracks/GetTrack. Synthesise a snap entry under '__master__' when
  -- any wm-owned FX live on master so wm:diff can detect transitions onto
  -- or off the master host.
  if reaper.GetMasterTrack then
    local master = reaper.GetMasterTrack(0)
    local masterChain = ownedChain(master, ownedGuids)
    if #masterChain > 0 then
      snap['__master__'] = {
        hostKind = 'master', trackGuid = nil, fxOrder = masterChain,
        mainSend = false, sends = {},
      }
    end
  end
  return snap
end

-- Project the DAG's TargetPlan entry into the wiringSnapshot shape.
-- Every kind='fx' compile node maps to one fxOrder entry; CU bridges
-- (also kind='fx', synthesised by lower with `params` set) flow through
-- uniformly. trackGuid decorated for the hosts we can identify.
local function projectEntry(planEntry, compileNodes, scratchGuid)
  local fxOrder = {}
  for _, id in ipairs(planEntry.fxOrder) do
    local node = compileNodes[id]
    if node.kind == 'fx' then
      local entry = { fxGuid = node.fxGuid, ident = node.fxIdent }
      if node.params then
        entry.params = util.deepClone(node.params)
        entry.origin = { kind = 'edge', idx = node.originEdgeIdx }
      else
        entry.origin = { kind = 'node', id = id }
        if not (node.fxIdent and node.fxIdent:sub(1, 3) == 'JS:') then
          entry.midiOut = nodeHasMidiOut(userGraph, id)
        end
      end
      util.add(fxOrder, entry)
    end
  end
  local trackGuid
  if     planEntry.hostKind == 'sourceTrack' then trackGuid = planEntry.trackGuid
  elseif planEntry.hostKind == 'scratch'     then trackGuid = scratchGuid end
  return {
    hostKind  = planEntry.hostKind,
    trackGuid = trackGuid,
    fxOrder   = fxOrder,
    mainSend  = planEntry.mainSend,
    sends     = util.deepClone(planEntry.sends),
  }
end

--contract: derives the wiringSnapshot REAPER should look like, by lowering the user graph and projecting DAG.targetPlan into snapshot shape. fxGuid on each fx entry comes from the user graph (nil for unmaterialised nodes). Pure — no REAPER reads except GetTrackGUID on the scratch track.
function wm:targetState()
  ensureLoaded()
  local cx = DAG.compile(userGraph)
  local plan = cx:targetPlan()
  local scratchGuid = scratchTrack and reaper.GetTrackGUID(scratchTrack)
  local out = {}
  for classKey, entry in pairs(plan) do
    out[classKey] = projectEntry(entry, cx:graph().nodes, scratchGuid)
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
  -- Order-insensitive: REAPER's send order isn't semantically meaningful.
  local seen = {}
  for _, s in ipairs(a) do seen[s.to .. '|' .. s.type] = (seen[s.to .. '|' .. s.type] or 0) + 1 end
  for _, s in ipairs(b) do
    local k = s.to .. '|' .. s.type
    if not seen[k] or seen[k] == 0 then return false end
    seen[k] = seen[k] - 1
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
    if (fresh and t_.mainSend) or (not fresh and t_.mainSend ~= s.mainSend) then
      util.add(ops, { op = 'setMainSend', classKey = classKey,
                      hostKind = t_.hostKind,
                      trackGuid = t_.trackGuid, value = t_.mainSend })
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
local CU_MODE_TO_FLOAT = { gain = 1, channelRemap = 2 }

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
    end
    local pIdx = resolveParamIdx(track, fxIdx, ident, k, cache)
    reaper.TrackFX_SetParam(track, fxIdx, pIdx, paramValueAsFloat(k, v))
  end
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

  -- 5. Reconcile per-FX "MIDI output disabled" (0x02) against the user
  --    graph. `midiOut` is stamped on target entries by projectEntry only
  --    for kind='node' fx; CU bridges and foreign FX have no midiOut and
  --    no routing trailer, so they're skipped on both sides. One chunk
  --    round-trip per track per reconcile pass.
  local nodeTargets = {}
  for d, tgt in ipairs(target) do
    if tgt.midiOut ~= nil then
      util.add(nodeTargets, { absIdx = current[d].absIdx, midiOut = tgt.midiOut })
    end
  end
  if #nodeTargets > 0 then
    local absToRouting, routingIdx = {}, 0
    for i = 0, reaper.TrackFX_GetCount(track) - 1 do
      local _, ident = reaper.TrackFX_GetFXName(track, i)
      if not (ident and ident:sub(1, 3) == 'JS:') then
        absToRouting[i] = routingIdx
        routingIdx = routingIdx + 1
      end
    end
    local _, chunk = reaper.GetTrackStateChunk(track, '', false)
    for _, nt in ipairs(nodeTargets) do
      local rIdx = absToRouting[nt.absIdx]
      if rIdx then
        local _, inputPins, outputPins =
          reaper.TrackFX_GetIOSize(track, nt.absIdx)
        chunk = wm.setFXOutputDisabled(chunk, rIdx, not nt.midiOut,
                                       inputPins + outputPins)
      end
    end
    reaper.SetTrackStateChunk(track, chunk, false)
  end
end

local function reconcileSends(track, target, classKeyToTrack)
  local current = {}
  for i = 0, reaper.GetTrackNumSends(track, 0) - 1 do
    local dst = reaper.GetTrackSendInfo_Value(track, 0, i, 'P_DESTTRACK')
    local typ = sendType(track, i)
    current[dst] = current[dst] or {}
    current[dst][typ] = i
  end
  local wanted = {}
  for _, s in ipairs(target) do
    local dst = classKeyToTrack[s.to]
    if dst then
      wanted[dst] = wanted[dst] or {}
      wanted[dst][s.type] = true
    end
  end
  local drops = {}
  for dst, byType in pairs(current) do
    for typ, idx in pairs(byType) do
      if not (wanted[dst] and wanted[dst][typ]) then
        util.add(drops, idx)
      end
    end
  end
  table.sort(drops, function(a, b) return a > b end)
  for _, idx in ipairs(drops) do
    reaper.RemoveTrackSend(track, 0, idx)
  end
  for dst, byType in pairs(wanted) do
    for typ in pairs(byType) do
      if not (current[dst] and current[dst][typ]) then
        local idx = reaper.CreateTrackSend(track, dst)
        if typ == 'midi' then
          reaper.SetTrackSendInfo_Value(track, 0, idx, 'I_SRCCHAN', -1)
        else
          reaper.SetTrackSendInfo_Value(track, 0, idx, 'I_MIDIFLAGS', 31)
        end
      end
    end
  end
end

local function ownedGuidsFrom(graph, persisted)
  local s = {}
  if persisted then
    for k in pairs(persisted) do s[k] = true end
  end
  for _, n in pairs(graph.nodes) do
    if n.kind == 'fx' and n.fxGuid then s[n.fxGuid] = true end
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
      if t then reaper.SetMediaTrackInfo_Value(t, 'B_MAINSEND', op.value and 1 or 0) end
    elseif op.op == 'setFXChain' then
      local t = resolveTrack(op)
      if t then reconcileFXChain(t, op.fxOrder, ownedGuids, stamps, paramIdxCache) end
    elseif op.op == 'setSends' then
      local t = resolveTrack(op)
      if t then reconcileSends(t, op.sends, classKeyToTrack) end
    end
  end

  if #stamps > 0 then
    realising = true
    self:mutate(function(g)
      for _, st in ipairs(stamps) do
        if st.origin.kind == 'node' then
          g.nodes[st.origin.id].fxGuid = st.guid
        else
          g.edges[st.origin.idx].opFxGuid = st.guid
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

--contract: writes the CU 'gain' param on edges[idx]'s materialised bridge via TrackFX_SetParam; returns true on success, false if the edge has no opFxGuid or it can't be resolved in any track's chain. No mutate, no signal, no undo block — for the live-drag hot path; caller bracket-commits with wv:setEdgeGain.
function wm:pokeEdgeGain(edgeIdx, gain)
  ensureLoaded()
  local edge = userGraph.edges[edgeIdx]
  if not edge or not edge.opFxGuid then return false end
  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    for fxIdx = 0, reaper.TrackFX_GetCount(track) - 1 do
      if reaper.TrackFX_GetFXGUID(track, fxIdx) == edge.opFxGuid then
        local pIdx = resolveParamIdx(track, fxIdx, CU_IDENT, 'gain', {})
        reaper.TrackFX_SetParam(track, fxIdx, pIdx, gain)
        return true
      end
    end
  end
  return false
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
