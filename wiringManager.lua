-- See docs/wiringManager.md for the model.
-- @noindex

--invariant: every fx-kind node carries fxGuid (nil pre-materialisation, stamped by the applier after TrackFX_AddByName). This is the only stable bridge identity between the user graph and a REAPER FX instance — snapshot and targetState match by it.
--shape: WiringSnapshot = { [classKey] = { hostKind='sourceTrack'|'newTrack'|'master'|'scratch', trackGuid?=string, fxOrder={ {fxGuid?=string, ident=string, params?=table}, ... }, mainSend=bool, sends={ {to=classKey, type='audio'|'midi'}, ... } } }; emitted by wm:snapshot and wm:targetState in matching shape so wm:diff can compare element-wise. fxOrder entries carrying `params` are wm-owned CU bridges (synthesised kind='fx' nodes from DAG.lower); snapshot never reads params back from REAPER, so any target with `params` drives setFXChain on every reconcile pass.
--shape: WiringOp = { op='createTrack'|'deleteTrack'|'setFXChain'|'setMainSend'|'setSends'|'setExtState', ... }; full-replace ops, not incremental. setFXChain entries with fxGuid=nil mean 'instantiate ident, stamp guid back to graph' (interpreted by the applier).
--invariant: every authoring gesture goes through wm:mutate — clone draft, mutate, validate via DAG.validate, swap + persist + fire on success, return false+err on failure. The on-disk graph and the wiringChanged broadcast have therefore always passed validation.
--invariant: master node is a regular entry in graph.nodes under the fixed id 'master'; freshGraph materialises it on first load of an empty project; DAG.validate enforces the singleton.
--invariant: scratch track is a hidden REAPER track tagged via cm key 'wiringScratch'='1'; wm:load() and wm:probeFxIO() find-or-create it; future use is to host FX nodes with no compile-graph track of their own. Probing-via-instantiate is a Stage-1 bootstrapping affordance — the differ in Stage 2+ will read I/O off the real production FX instance and back-fill the node.

local util = require 'util'
local DAG  = require 'DAG'

local cm = (...).cm

local wm = {}
local fire = util.installHooks(wm)

local _graph = nil
local _installedFx = nil  -- session cache; reaper's installed-FX set is fixed at runtime
local _scratchTrack = nil -- hidden host for the probe (and, later, orphan FX nodes); reset by wm:load
local _fxIO = {}          -- session cache: fxIdent → { ins, outs, inNames, outNames }

local SCRATCH_NAME = 'continuum: wiring scratch'
local SCRATCH_KEY  = '__scratch__'
local CU_IDENT     = 'JS:Continuum Utility'

----- Helpers

local function freshGraph()
  return {
    nodes = {
      master = { kind = 'master', pos = { x = 0, y = 0 },
                 audio = { ins = 1 } },
    },
    edges = {},
    _nextId = 1,
  }
end

local function readPersisted()
  local g = cm:get('wiringGraph')
  if g and g.nodes then return g end
  return freshGraph()
end

local function ensureLoaded()
  if not _graph then _graph = readPersisted() end
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
  if _scratchTrack then return _scratchTrack end
  _scratchTrack = findScratchTrack() or createScratchTrack()
  return _scratchTrack
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
  _graph = readPersisted()
  _scratchTrack = nil
  ensureScratchTrack()
  fire('wiringChanged', { kind = 'load' })
end

--contract: persists the current in-memory graph to the project tier; mutate calls this, callers normally don't
function wm:save()
  cm:set('project', 'wiringGraph', _graph)
end

--contract: returns a deep copy of the user graph; caller mutations never leak into wm state
function wm:graph()
  ensureLoaded()
  return util.deepClone(_graph)
end

--contract: clone-validate-swap; on DAG.validate failure returns false,err with no state change and no signal; on success persists and fires wiringChanged{kind='mutate'}
function wm:mutate(mutator)
  ensureLoaded()
  local draft = util.deepClone(_graph)
  mutator(draft)
  local err = DAG.validate(draft)
  if err then return false, err end
  _graph = draft
  self:save()
  fire('wiringChanged', { kind = 'mutate' })
  return true
end

--contract: returns DAG.lower of the current user graph; pure, no caching at Stage 1
function wm:compile()
  ensureLoaded()
  return DAG.lower(_graph)
end

--contract: list of intra-class capacity overflows on the lowered compile graph; empty when the user graph is within budget
function wm:errors()
  local compile = self:compile()
  return DAG.capacityErrors(compile, DAG.classes(compile))
end

--contract: { ins, outs, inNames, outNames } in stereo ports for fxIdent; instantiates on the scratch track, reads TrackFX_GetIOSize + in_pin_X/out_pin_X via TrackFX_GetNamedConfigParm, deletes, caches by ident. Unknown ident → ins=outs=0 with empty name lists.
function wm:probeFxIO(ident)
  if _fxIO[ident] then return _fxIO[ident] end
  ensureScratchTrack()
  reaper.PreventUIRefresh(1)
  local fxIdx = reaper.TrackFX_AddByName(_scratchTrack, ident, false, -1)
  local result
  if fxIdx < 0 then
    result = { ins = 0, outs = 0, inNames = {}, outNames = {} }
  else
    local _, inPins, outPins = reaper.TrackFX_GetIOSize(_scratchTrack, fxIdx)
    inPins, outPins = inPins or 0, outPins or 0
    result = {
      ins      = inPins  / 2,
      outs     = outPins / 2,
      inNames  = portNames(_scratchTrack, fxIdx, 'in',  inPins),
      outNames = portNames(_scratchTrack, fxIdx, 'out', outPins),
    }
    reaper.TrackFX_Delete(_scratchTrack, fxIdx)
  end
  reaper.PreventUIRefresh(-1)
  _fxIO[ident] = result
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
  local insertIdx = math.floor(reaper.GetMediaTrackInfo_Value(_scratchTrack, 'IP_TRACKNUMBER')) - 1
  reaper.InsertTrackAtIndex(insertIdx, true)
  local track = reaper.GetTrack(0, insertIdx)
  if opts and opts.name then
    reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', opts.name, true)
  end
  cm:writeTrackKey(track, 'wiringHostKind', 'sourceTrack')
  reaper.PreventUIRefresh(-1)
  return reaper.GetTrackGUID(track)
end

----- Snapshot / target / diff (Stage 2)

-- Walk the chain of one track, returning { {fxGuid, ident}, ... } for FX
-- whose guid appears in ownedGuids. CU instances ride the same predicate;
-- the applier persists their guid on the originating edge so subsequent
-- snapshots recognise them like any fx node.
local function ownedChain(track, ownedGuids)
  local out = {}
  for fxIdx = 0, reaper.TrackFX_GetCount(track) - 1 do
    local guid = reaper.TrackFX_GetFXGUID(track, fxIdx)
    if ownedGuids[guid] then
      local _, ident = reaper.TrackFX_GetFXName(track, fxIdx)
      util.add(out, { fxGuid = guid, ident = ident })
    end
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

--contract: walks every project track, builds a WiringSnapshot of REAPER's current state restricted to wm-owned things (tracks tagged wiringHostKind; FX whose guids appear in the user graph (fx nodes) or edge ops (CUs); sends whose dst is itself a managed track). Foreign tracks/FX/sends are invisible. Read-only.
function wm:snapshot()
  ensureLoaded()
  local ownedGuids = {}
  for _, n in pairs(_graph.nodes) do
    if n.kind == 'fx' and n.fxGuid then ownedGuids[n.fxGuid] = true end
  end
  for _, e in ipairs(_graph.edges) do
    if e._opFxGuid then ownedGuids[e._opFxGuid] = true end
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
  return snap
end

-- Project the DAG's TargetPlan entry into the WiringSnapshot shape.
-- Every kind='fx' compile node maps to one fxOrder entry; CU bridges
-- (also kind='fx', synthesised by lower with `params` set) flow through
-- uniformly. trackGuid decorated for the hosts we can identify.
local function projectEntry(planEntry, compileNodes, scratchGuid)
  local fxOrder = {}
  for _, id in ipairs(planEntry.fxOrder) do
    local node = compileNodes[id]
    if node.kind == 'fx' then
      local entry = { fxGuid = node.fxGuid, ident = node.fxIdent }
      if node.params then entry.params = util.deepClone(node.params) end
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

-- CompileNode is a stripped Node (see DAG.passthroughNode). It loses
-- fxGuid; re-attach from the user graph so targetState carries the bridge
-- identity all the way through. CU bridges already carry fxGuid from
-- lower (copied off the source edge's _opFxGuid).
local function attachFxGuids(compile, graph)
  for id, n in pairs(compile.nodes) do
    if n.kind == 'fx' and graph.nodes[id] then
      n.fxGuid = graph.nodes[id].fxGuid
    end
  end
end

--contract: derives the WiringSnapshot REAPER should look like, by lowering the user graph and projecting DAG.targetPlan into snapshot shape. fxGuid on each fx entry comes from the user graph (nil for unmaterialised nodes). Pure — no REAPER reads except GetTrackGUID on the scratch track.
function wm:targetState()
  ensureLoaded()
  local compile = DAG.lower(_graph)
  attachFxGuids(compile, _graph)
  local classes = DAG.classes(compile)
  local plan    = DAG.targetPlan(compile, classes)
  local scratchGuid = _scratchTrack and reaper.GetTrackGUID(_scratchTrack)
  local out = {}
  for classKey, entry in pairs(plan) do
    out[classKey] = projectEntry(entry, compile.nodes, scratchGuid)
  end
  return out
end

local function fxOrderEq(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    local x, y = a[i], b[i]
    if x.fxGuid ~= y.fxGuid or x.ident ~= y.ident then return false end
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

--contract: pure structural diff producing a WiringOp[] that, applied, would carry snap to target. Order: creates first (so subsequent setSends can reference fresh tracks), then setFXChain / setMainSend / setSends / setExtState, then deletes. snap entries absent from target with hostKind='newTrack' are deleted; sourceTrack/scratch are never deleted (project artefacts).
function wm:diff(target, snap)
  local ops = {}
  -- Creates (order before mutates so setSends can reference fresh hosts).
  for classKey, t_ in pairs(target) do
    if not snap[classKey] and t_.hostKind == 'newTrack' then
      util.add(ops, { op = 'createTrack', classKey = classKey, hostKind = 'newTrack' })
    end
  end
  -- Per-class field diffs.
  for classKey, t_ in pairs(target) do
    local s = snap[classKey]
    local exists = s ~= nil
    if not exists or not fxOrderEq(t_.fxOrder, s.fxOrder) then
      util.add(ops, { op = 'setFXChain', classKey = classKey,
                      trackGuid = t_.trackGuid, fxOrder = util.deepClone(t_.fxOrder) })
    end
    if (not exists and t_.mainSend) or (exists and t_.mainSend ~= s.mainSend) then
      util.add(ops, { op = 'setMainSend', classKey = classKey,
                      trackGuid = t_.trackGuid, value = t_.mainSend })
    end
    if not exists or not sendsEq(t_.sends, s.sends) then
      util.add(ops, { op = 'setSends', classKey = classKey,
                      trackGuid = t_.trackGuid, sends = util.deepClone(t_.sends) })
    end
    -- ExtState writes only on creation. sourceTrack hosts get only
    -- wiringHostKind (the track's own guid is the classKey already);
    -- newTrack hosts also need wiringClass to carry the multi-guid key.
    if not exists and t_.hostKind == 'sourceTrack' then
      util.add(ops, { op = 'setExtState', classKey = classKey,
                      key = 'wiringHostKind', value = 'sourceTrack' })
    elseif not exists and t_.hostKind == 'newTrack' then
      util.add(ops, { op = 'setExtState', classKey = classKey,
                      key = 'wiringHostKind', value = 'newTrack' })
      util.add(ops, { op = 'setExtState', classKey = classKey,
                      key = 'wiringClass', value = classKey })
    end
  end
  -- Deletes (last so any final reads of going-away tracks have already run).
  for classKey, s in pairs(snap) do
    if not target[classKey] and s.hostKind == 'newTrack' then
      util.add(ops, { op = 'deleteTrack', trackGuid = s.trackGuid })
    end
  end
  return ops
end

--contract: enumerates reaper.EnumInstalledFX once per wm instance; name is raw REAPER "Type: Name (Author)"
function wm:listInstalledFX()
  if _installedFx then return _installedFx end
  local out, i = {}, 0
  while true do
    local ok, name, ident = reaper.EnumInstalledFX(i)
    if not ok then break end
    util.add(out, { name = name, ident = ident })
    i = i + 1
  end
  _installedFx = out
  return out
end

return wm
