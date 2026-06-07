-- See docs/wiringManager.md for the model.
-- @noindex

--invariant: fx-kind nodes carry fxGuid; addFxNode mints it via instantiateFxOnScratch
--invariant: CU bridges arrive at the applier with nil fxGuid; reconcileFXChain mints them
--invariant: fxGuid is the stable bridge identity; snapshot/targetState match fxOrder by it
--invariant: wm deletes an FX instance only when its owning node or CU bridge leaves the graph
--invariant: trackKey changes are moves; TrackFX_CopyToTrack(is_move=true) preserves plugin state
--shape: snapshotPinMap = { ins={[port]={pair,...}}, outs={[port]={pair,...}} }
--shape: snapshotSend = { to=trackKey, kind='audio'|'midi', gain?=number, srcChan=int, dstChan=int, pos='preFx'|'preFader'|'postFader' }
--shape: snapshotFxOrigin = {kind='node',id=string}|{kind='edge',idx=int}|{kind='bracketIn'|'bracketOut',id=string}
--shape: snapshotFxEntry = { id?=string, ident=string, params?=table, origin?=snapshotFxOrigin, midi?={inBus=int,outBus=int,outDisabled=bool}, pinMaps?=snapshotPinMap }
--shape: wiringSnapshot = { [trackKey] = { trackKind='sourceTrack'|'newTrack'|'master'|'scratch', id?=string, nchan?=int, mainSend={on=bool,gain?,tgtOffset?,nchan?}, fx=snapshotFxEntry[], sends=snapshotSend[] } }; rm:tracks() record + wm ownership/trackKey overlay. see docs/wiringManager.md § wiringSnapshot.
--shape: wiringOp = { op='createTrack'|'deleteTrack'|'setFXChain'|'setMainSend'|'setSends'|'setNchan'|'setPinMaps'|'setExtState'|'moveFxAcrossTracks', ... }
-- full-replace ops; see docs/wiringManager.md § wiringOp for per-op field detail.
--invariant: every authoring gesture goes through wm:mutate — clone draft, mutate, validate via DAG.validate, swap + persist + fire on success, return false+err on failure. The on-disk graph and the wiringChanged broadcast have therefore always passed validation.
--invariant: master node is a regular entry in graph.nodes under the fixed id 'master'; freshGraph materialises it on first load of an empty project; DAG.validate enforces the singleton.
--invariant: scratch is a hidden REAPER track tagged cm 'wiringScratch'='1' (find-or-create lazily)
--invariant: scratch hosts FX with no compile-graph track — disconnected or lowered-parked

local util = require 'util'
local DAG  = require 'DAG'
local fs   = require 'fs'

local cm = (...).cm
local rm = (...).rm

local wm = {}
local fire = util.installHooks(wm)

local userGraph = nil
local scratchTrack = nil  -- hidden trackKey for disconnected/orphan FX nodes; reset by wm:load
local pokeParamCache = {} -- persistent paramIdx cache for the pokeEdgeGain hot path
local liveLabel = nil     -- non-nil iff live mode is on; carries the default undo label
local lastScratchRaw = nil -- serialised graph last mirrored to scratch P_EXT; pollUndo compares against it
local fxLocations = {}     -- fxGuid → {track, fxIdx}; restamped each applyOps so locateFx needn't sweep the project

local SCRATCH_NAME = 'continuum: wiring scratch'
local SCRATCH_KEY  = '__scratch__'
local CU_IDENT     = 'JS:Continuum Utility'

local function isJS(ident)
  return ident ~= nil and ident:sub(1, 3) == 'JS:'
end

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

local compiledCache = nil  -- { graph, ctx, reach } | nil; cleared on every graph swap

local function setGraph(g) userGraph = g; compiledCache = nil end

local function ensureLoaded()
  if not userGraph then setGraph(readPersisted()) end
end

----- compiled-graph cache: one clone+compile per structural change, pulled by wv

local function buildReach(g)
  local forward, reverse = {}, {}
  for _, edge in ipairs(g.edges or {}) do
    util.bucket(forward, edge.from, edge.to)
    util.bucket(reverse, edge.to,   edge.from)
  end
  return { forward = forward, reverse = reverse }
end

-- Lazy past ensureLoaded so the nil reload-sentinel resolves before any compile.
local function ensureCompiled()
  ensureLoaded()
  if not compiledCache then
    local snap = util.deepClone(userGraph)
    compiledCache = { graph = snap, ctx = DAG.compile(snap), reach = buildReach(snap) }
  end
  return compiledCache
end

-- The single project-track scan wm is allowed: handle↔guid↔trackKey addressing
-- rides on cm ext-state tags rm won't expose. see docs/wiringManager.md § the addressing seam
local function eachTrack(visit)
  for i = 0, reaper.CountTracks(0) - 1 do
    if visit(reaper.GetTrack(0, i)) then return end
  end
end

local function findScratchTrack()
  local found
  eachTrack(function(track)
    if cm:readTrackKey(track, 'wiringScratch') == '1' then found = track; return true end
  end)
  return found
end

local function createScratchTrack()
  local track = wm:trackByGuid(rm:addTrack{ name = SCRATCH_NAME, hidden = true })
  cm:writeTrackKey(track, 'wiringScratch', '1')  -- tag via the seam: cm needs a live handle
  return track
end

local function ensureScratchTrack()
  if scratchTrack then return scratchTrack end
  scratchTrack = findScratchTrack() or createScratchTrack()
  return scratchTrack
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
  setGraph(readPersisted())
  scratchTrack   = nil
  fxLocations    = {}
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

--contract: cached deep clone of the user graph; one clone per structural change, read-only
function wm:viewGraph() return ensureCompiled().graph end

--contract: cached { forward, reverse } adjacency over viewGraph.edges for reachability walks
function wm:reach()     return ensureCompiled().reach end

-- Live, uncloned: fastGainCommit writes ops.gain without a wiringChanged,
-- so the cached viewGraph would lag a fader drag.
--contract: live gain on audio edges[idx]; 1.0 if unset/non-audio/absent; reads userGraph uncloned
function wm:edgeGain(idx)
  ensureLoaded()
  local e = userGraph.edges[idx]
  if not e or e.type ~= 'audio' then return 1.0 end
  return (e.ops and e.ops.gain) or 1.0
end

--contract: clone-validate-swap; DAG.validate failure returns false,err with no state change;
--contract: on success persists and fires wiringChanged{kind='mutate'}
function wm:mutate(mutator)
  ensureLoaded()
  local draft = util.deepClone(userGraph)
  mutator(draft)
  local err = DAG.validate(draft)
  if err then return false, err end
  setGraph(draft)
  self:save()
  fire('wiringChanged', { kind = 'mutate' })
  return true
end

-- One DAG ctx for the loaded graph, shared across :classes/:capacityErrors.
local function compile()
  ensureLoaded()
  return DAG.compile(userGraph)
end

--contract: capacity overflows joined to user-graph node ids
--shape: {kind,count,budget,nodeIds={[id]=true}}[]
--invariant: synthesised CU ids filtered; returns {} within budget
function wm:errors()
  local ctx     = compile()
  local members = ctx:trackMembers()
  local out = {}
  for _, err in ipairs(ctx:capacityErrors()) do
    local nodeIds = {}
    for _, id in ipairs(members[err.trackKey] or {}) do
      if userGraph.nodes[id] then nodeIds[id] = true end
    end
    util.add(out, { kind = err.kind, count = err.count, budget = err.budget, nodeIds = nodeIds })
  end
  return out
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
  local fxGuid = rm:addFx(reaper.GetTrackGUID(scratchTrack), { ident = ident })
  if not fxGuid then return { fxGuid = nil, ins = 0, outs = 0, inNames = {}, outNames = {} } end
  local ports = rm:fxPorts(fxGuid)
  ports.fxGuid = fxGuid
  return ports
end

--contract: linear scan; returns the MediaTrack with this GUID, or nil if the project no longer holds one
function wm:trackByGuid(guid)
  local found
  eachTrack(function(track)
    if reaper.GetTrackGUID(track) == guid then found = track; return true end
  end)
  return found
end

--contract: { [trackGuid] = name } for every project track + master; one rm:tracks() pass
function wm:trackNames()
  local out = {}
  for _, tr in ipairs(rm:tracks()) do out[tr.id] = tr.name end
  return out
end

-- Visit every (track, fxIdx) in the project, master chain last; stops early
-- when visit returns truthy.
local function eachProjectFx(visit)
  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    for fxIdx = 0, reaper.TrackFX_GetCount(track) - 1 do
      if visit(track, fxIdx) then return end
    end
  end
  local master = reaper.GetMasterTrack(0)
  for fxIdx = 0, reaper.TrackFX_GetCount(master) - 1 do
    if visit(master, fxIdx) then return end
  end
end

-- applyOps is the authoritative moment a guid's slot is known, so the index is
-- restamped there and locateFx reads it instead of sweeping on every call.
local function rebuildFxLocations()
  fxLocations = {}
  eachProjectFx(function(track, fxIdx)
    fxLocations[reaper.TrackFX_GetFXGUID(track, fxIdx)] = { track = track, fxIdx = fxIdx }
  end)
end

--contract: returns track, fxIdx for the instance guid or nil.
--contract: index-first (restamped at applyOps); sweeps once on miss/drift, repopulating.
function wm:locateFx(fxGuid)
  local hit = fxLocations[fxGuid]
  if hit and reaper.TrackFX_GetFXGUID(hit.track, hit.fxIdx) == fxGuid then
    return hit.track, hit.fxIdx
  end
  local foundTrack, foundIdx
  eachProjectFx(function(track, fxIdx)
    if reaper.TrackFX_GetFXGUID(track, fxIdx) == fxGuid then
      foundTrack, foundIdx = track, fxIdx
      return true
    end
  end)
  fxLocations[fxGuid] = foundTrack and { track = foundTrack, fxIdx = foundIdx } or nil
  return foundTrack, foundIdx
end

--contract: floats the FX window for the instance guid; false if the guid is no longer live
function wm:showFxWindow(fxGuid)
  return rm:showFx(fxGuid)
end

--contract: appends a source track via rm, tags wiringTrackKind=sourceTrack, returns GUID.
-- Called outside mutate. see docs/wiringManager.md § createSourceTrack
function wm:createSourceTrack(opts)
  local guid  = rm:addTrack{ name = opts and opts.name, defaults = true }
  local track = self:trackByGuid(guid)
  cm:writeTrackKey(track, 'wiringTrackKind', 'sourceTrack')  -- tag via the seam
  return guid
end

-- Strips the "Type: " prefix and a trailing balanced-paren author / out-count
-- ("... (Cockos)", "... (2 outs)"); %b() so a nested paren can't end it early.
local function shortFxName(s)
  s = s:gsub('^[^:]+:%s*', '')
  s = s:gsub('%s*%b().*$', '')
  return s
end

--contract: one Undo block around instantiate + mutate; stamps fxGuid on the new fx-node
--contract: generators (io.ins==0) also spawn sourceTrack + source-node + midi edge
--contract: returns new fx-node id; nil+err on validate failure or ext_midi_bus refusal
function wm:addFxNode(x, y, fx, opts)
  ensureLoaded()
  local addErr = self:checkUserAddable(fx.ident)
  if addErr then return nil, addErr end
  local display = fx.name and shortFxName(fx.name) or fx.ident
  local newId, ok, err
  rm:transaction('wiring: add ' .. display, function()
    local io         = self:instantiateFxOnScratch(fx.ident)
    local autoSource = io.ins == 0 and not (opts and opts.autoSource == false)
    local sourceGuid = autoSource and self:createSourceTrack{ name = display } or nil
    ok, err = self:mutate(function(g)
      local fxId = 'n' .. g.nextId
      g.nextId = g.nextId + 1
      newId = fxId
      g.nodes[fxId] = {
        kind      = 'fx',
        pos       = { x = x, y = y },
        fxIdent   = fx.ident,
        fxDisplay = display,
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
          displayName = display,
          ports       = { audio = { ins = 0, outs = 1 },
                          midi  = { ins = 0, outs = 1 } },
        }
        util.add(g.edges, { type = 'midi', from = sourceId, to = fxId })
      end
    end)
  end)
  if not ok then return nil, err end
  return newId
end

--contract: deletes a source node + incident edges and its REAPER track in one Undo block.
-- Reconcile never deletes sourceTracks (protects authored takes), so deletion is explicit
-- here. Refuses with false, takeCount when the track holds takes unless force is set.
function wm:deleteSource(nodeId, force)
  ensureLoaded()
  local node = userGraph.nodes[nodeId]
  if not node or node.kind ~= 'source' then return false end
  local track = node.trackGuid and self:trackByGuid(node.trackGuid)
  local takes = track and reaper.CountTrackMediaItems(track) or 0
  if takes > 0 and not force then return false, takes end
  rm:transaction('wiring: delete source', function()
    self:mutate(function(g)
      g.nodes[nodeId] = nil
      local kept = {}
      for _, e in ipairs(g.edges) do
        if e.from ~= nodeId and e.to ~= nodeId then util.add(kept, e) end
      end
      g.edges = kept
    end)
    if node.trackGuid then rm:deleteTrack(node.trackGuid) end
  end)
  return true
end

--contract: creates source track + node at opts.pos in one Undo block; returns node id or nil+err
function wm:addSourceNode(opts)
  ensureLoaded()
  opts = opts or {}
  local newId, ok, err
  rm:transaction('wiring: add source', function()
    local guid = self:createSourceTrack{ name = opts.name }
    ok, err = self:mutate(function(g)
      newId = 'n' .. g.nextId
      g.nextId = g.nextId + 1
      local pos = opts.pos or { x = 0, y = 0 }
      g.nodes[newId] = {
        kind        = 'source',
        pos         = { x = pos.x, y = pos.y },
        trackGuid   = guid,
        displayName = opts.name,
        ports       = { audio = { ins = 0, outs = 1 },
                        midi  = { ins = 0, outs = 1 } },
      }
    end)
  end)
  if not ok then return nil, err end
  return newId
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

-- CU params live at stable slider indices; cache the {name=idx} map on
-- first sight so readCuParams doesn't re-enumerate per snap.
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

-- Live CU param mirror so fxOrderEq is honest (mode/bank drift drives reconcile,
-- not noise). rm:tracks() doesn't read params — the CU encoding is wm/CU-private.
local function readCuParams(track, fxIdx)
  local idx     = cuParamIdx(track, fxIdx)
  local modeInt = math.floor(reaper.TrackFX_GetParam(track, fxIdx, idx.mode) + 0.5)
  local modeStr = ({ [0] = 'busRoute', [1] = 'merge' })[modeInt] or 'merge'
  if modeStr == 'busRoute' then
    return { mode = modeStr,
             from = math.floor(reaper.TrackFX_GetParam(track, fxIdx, idx.from) + 0.5),
             to   = math.floor(reaper.TrackFX_GetParam(track, fxIdx, idx.to) + 0.5) }
  end
  local nPairs = math.floor(reaper.TrackFX_GetParam(track, fxIdx, idx.nPairs) + 0.5)
  local gains, inMask = {}, {}
  for i = 1, nPairs do gains[i] = reaper.TrackFX_GetParam(track, fxIdx, idx['gain' .. i]) end
  for i = 0, 3 do inMask[i + 1] = math.floor(reaper.TrackFX_GetParam(track, fxIdx, idx['inMask' .. i]) + 0.5) end
  return { mode = modeStr, nPairs = nPairs, gains = gains,
           audioSum = math.floor(reaper.TrackFX_GetParam(track, fxIdx, idx.audioSum) + 0.5),
           outBus   = math.floor(reaper.TrackFX_GetParam(track, fxIdx, idx.outBus) + 0.5),
           inMask   = inMask }
end

-- CU bridge params arrive in wm/CU vocabulary; rm:writeParams wants flat {sliderName=number}.
-- Flatten at the read/derive boundary so op payload and rm speak one shape.
local CU_MODE_TO_FLOAT = { busRoute = 0, merge = 1 }
local function flattenCuParams(params)
  local flat = {}
  for k, v in pairs(params) do
    if k == 'gains' then
      for i, g in ipairs(v) do flat['gain' .. i] = g end
    elseif k == 'inMask' then
      for i, lane in ipairs(v) do flat['inMask' .. (i - 1)] = lane end
    elseif k == 'mode' and type(v) == 'string' then
      local f = CU_MODE_TO_FLOAT[v]
      if not f then error(("unknown CU mode %q"):format(v)) end
      flat.mode = f
    else
      flat[k] = v
    end
  end
  return flat
end

--contract: rm:tracks() overlaid with wm ownership — owned fx only, re-keyed by
-- trackKey, send dsts remapped guid→trackKey; foreign tracks/fx/sends invisible. Read-only.
function wm:snapshot()
  ensureLoaded()
  -- Ownership = current-graph guids ∪ persisted wiringOwnedFx set, so an fx
  -- whose node was removed stays visible until wm:diff emits its delete.
  local ownedGuids = {}
  for k in pairs(cm:get('wiringOwnedFx') or {}) do ownedGuids[k] = true end
  for _, n in pairs(userGraph.nodes) do
    if n.kind == 'fx' then
      if n.fxGuid             then ownedGuids[n.fxGuid]             = true end
      if n.midiInBracketGuid  then ownedGuids[n.midiInBracketGuid]  = true end
      if n.midiOutBracketGuid then ownedGuids[n.midiOutBracketGuid] = true end
    end
    if n.mergeGuids then
      for _, g in pairs(n.mergeGuids) do ownedGuids[g] = true end
    end
  end

  -- (guid → trackKey/trackKind) from ext-state tags; needs live MediaTrack
  -- handles. sourceTrack keys on guid, newTrack on wiringTrack tag, scratch on singleton key.
  local keyByGuid, kindByKey = {}, {}
  eachTrack(function(track)
    local guid      = reaper.GetTrackGUID(track)
    local trackKind = cm:readTrackKey(track, 'wiringTrackKind')
    local trackKey
    if trackKind == 'sourceTrack' then
      trackKey = guid
    elseif trackKind == 'newTrack' then
      trackKey = cm:readTrackKey(track, 'wiringTrack')
    elseif cm:readTrackKey(track, 'wiringScratch') == '1' then
      trackKey, trackKind = SCRATCH_KEY, 'scratch'
    end
    if trackKey then keyByGuid[guid] = trackKey; kindByKey[trackKey] = trackKind end
  end)

  local function snapFx(fx)
    local entry = { id = fx.id, ident = fx.ident }
    if fx.pinMaps and (next(fx.pinMaps.ins) or next(fx.pinMaps.outs)) then
      entry.pinMaps = fx.pinMaps
    end
    if isJS(fx.ident) then
      if fx.ident == CU_IDENT then
        local track, fxIdx = self:locateFx(fx.id)
        if track then entry.params = flattenCuParams(readCuParams(track, fxIdx)) end
      end
    else
      entry.midi = fx.midi
    end
    return entry
  end
  local function ownedFx(fxList)
    local out = {}
    for _, fx in ipairs(fxList) do
      if ownedGuids[fx.id] then util.add(out, snapFx(fx)) end
    end
    return out
  end
  -- Sends to a managed dst only; re-key .to guid→trackKey, drop midi gain
  -- (only audio sends carry a written D_VOL).
  local function ownedSends(sendList)
    local out = {}
    for _, s in ipairs(sendList) do
      local key = keyByGuid[s.to]
      if key then
        util.add(out, { to = key, kind = s.kind,
                        gain = s.kind == 'audio' and s.gain or nil,
                        srcChan = s.srcChan, dstChan = s.dstChan, pos = s.pos })
      end
    end
    return out
  end

  local snap = {}
  for _, tr in ipairs(rm:tracks()) do
    local trackKey = keyByGuid[tr.id]
    if trackKey then
      local isScratch = kindByKey[trackKey] == 'scratch'
      snap[trackKey] = {
        trackKind = kindByKey[trackKey],
        id        = tr.id,
        nchan     = tr.nchan,
        mainSend  = isScratch and { on = false } or tr.mainSend,
        fx        = ownedFx(tr.fx),
        sends     = isScratch and {} or ownedSends(tr.sends),
      }
    elseif tr.isMaster then
      -- Master is a singleton with no ext-state tag; surface it only when it
      -- hosts owned fx, so wm:diff can see transitions on/off master.
      local masterFx = ownedFx(tr.fx)
      if #masterFx > 0 then
        snap['__master__'] = { trackKind = 'master', nchan = tr.nchan,
                               mainSend = { on = false }, fx = masterFx, sends = {} }
      end
    end
  end
  return snap
end

-- pinMaps nest inline on each fx entry; an unmaterialised entry (id=nil) carries
-- them too, and the applier resolves its guid through the freshly-stamped graph.
local function projectEntry(spec, compileNodes, scratchGuid)
  local synth    = spec.synthNodes or {}
  local brackets = spec.bracketNodes or {}
  local function resolveNode(id) return compileNodes[id] or synth[id] or brackets[id] end
  local fx, entryByCompileId = {}, {}
  for _, id in ipairs(spec.fxOrder) do
    local node = resolveNode(id)
    if node and node.kind == 'fx' then
      local entry = { id = node.fxGuid, ident = node.fxIdent }
      if node.originSide then
        local consumer = compileNodes[node.originNode] or {}
        entry.id = node.originSide == 'in'
                   and consumer.midiInBracketGuid
                   or  consumer.midiOutBracketGuid
        entry.params = flattenCuParams(node.params)
        entry.origin = { kind = node.originSide == 'in' and 'bracketIn' or 'bracketOut',
                         id = node.originNode }
      elseif node.originConsumer then
        local consumer = compileNodes[node.originConsumer] or {}
        entry.id = consumer.mergeGuids and consumer.mergeGuids[node.originTrackKey]
        entry.params = flattenCuParams(node.params)
        entry.origin = { kind = 'merge', consumer = node.originConsumer, trackKey = node.originTrackKey }
      else
        entry.origin = { kind = 'node', id = id }
        if not isJS(node.fxIdent) then
          local bus = spec.fxMidiBus and spec.fxMidiBus[id]
          entry.midi = { inBus = bus and bus.inBus or 0, outBus = bus and bus.outBus or 0,
                         outDisabled = not nodeHasMidiOut(userGraph, id) }
        end
      end
      entryByCompileId[id] = entry
      util.add(fx, entry)
    end
  end
  for compileId, pm in pairs(spec.pinMaps or {}) do
    local entry = entryByCompileId[compileId]
    if entry then entry.pinMaps = util.deepClone(pm) end
  end
  local sends = {}
  for _, s in ipairs(spec.sends or {}) do
    util.add(sends, { to = s.to, kind = s.type, gain = s.gain,
                      srcChan = s.srcChan, dstChan = s.dstChan,
                      pos = s.preFx and 'preFx' or 'preFader' })
  end
  local id
  if     spec.trackKind == 'sourceTrack' then id = spec.trackGuid
  elseif spec.trackKind == 'scratch'     then id = scratchGuid end
  return {
    trackKind = spec.trackKind,
    id        = id,
    fx        = fx,
    mainSend  = { on = not not spec.mainSend, gain = spec.mainSendGain,
                  tgtOffset = spec.mainSendOffs,
                  nchan = spec.mainSend and 2 or nil },   -- parent send to master is always stereo
    sends     = sends,
    nchan     = spec.nchan,
  }
end

--contract: pure (reads only GetTrackGUID on scratch); derives wiringSnapshot from DAG.targetTracks
-- see docs/wiringManager.md
function wm:targetState()
  ensureLoaded()
  local cx = DAG.compile(userGraph)
  local nodes = userGraph.nodes
  local tracks = DAG.allocate(DAG.targetTracks(cx), nodes)
  local scratchGuid = scratchTrack and reaper.GetTrackGUID(scratchTrack)
  local out = {}
  for trackKey, entry in pairs(tracks) do
    out[trackKey] = projectEntry(entry, nodes, scratchGuid)
  end
  return out
end

local function sendKey(s)
  return util.key(s.to, s.kind, s.srcChan, s.dstChan, s.pos)
end

local function fxOrderEq(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    local x, y = a[i], b[i]
    if x.id ~= y.id or x.ident ~= y.ident             then return false end
    if not util.deepEq(x.midi   or {}, y.midi   or {}) then return false end
    if not util.deepEq(x.params or {}, y.params or {}) then return false end
  end
  return true
end

local function sendsEq(a, b)
  if #a ~= #b then return false end
  -- Set-equality on the identity (to, kind, srcChan, dstChan, pos); gain is the
  -- value so D_VOL drift drives setSends. pos lets pre-/post-FX sends coexist.
  local byKey = {}
  for _, s in ipairs(a) do byKey[sendKey(s)] = s.gain or 1.0 end
  for _, s in ipairs(b) do
    local k = sendKey(s)
    if byKey[k] == nil or byKey[k] ~= (s.gain or 1.0) then return false end
  end
  return true
end

-- pinMaps live on fx entries now; an unmaterialised target fx (no id) can't be
-- represented in snap (snap fx are all live) so any pinMap it carries must drift.
local function pinMapsEq(t_, s)
  local function byGuid(entry)
    local out, unrepresentable = {}, false
    for _, fx in ipairs(entry.fx) do
      if fx.pinMaps and (next(fx.pinMaps.ins) or next(fx.pinMaps.outs)) then
        if fx.id then out[fx.id] = fx.pinMaps else unrepresentable = true end
      end
    end
    return out, unrepresentable
  end
  local tPM, tUnrep = byGuid(t_)
  if tUnrep then return false end
  local sPM = s and (byGuid(s)) or {}
  local keys = {}
  for k in pairs(tPM) do keys[k] = true end
  for k in pairs(sPM) do keys[k] = true end
  for k in pairs(keys) do
    if not util.deepEq(tPM[k] or { ins = {}, outs = {} },
                       sPM[k] or { ins = {}, outs = {} }) then return false end
  end
  return true
end

--contract: pure structural diff → wiringOp[] that carries snap to target.
-- Op order and deletion rules: see docs/wiringManager.md § diff op ordering
function wm:diff(target, snap)
  local ops = {}

  local trackChanged = {}
  for trackKey, t_ in pairs(target) do
    local s = snap[trackKey]
    if s and s.trackKind ~= t_.trackKind then trackChanged[trackKey] = true end
  end

  -- Creates (order before mutates so setSends can reference fresh hosts).
  -- Both target-only newTracks and track-transitions-to-newTrack mint a track.
  for trackKey, t_ in pairs(target) do
    local s = snap[trackKey]
    if (not s or trackChanged[trackKey]) and t_.trackKind == 'newTrack' then
      util.add(ops, { op = 'createTrack', trackKey = trackKey, trackKind = 'newTrack' })
    end
  end

  -- Cross-track move pass: relocate guids whose track changed via is_move=true,
  -- emitted before per-class setFXChain (see --shape wiringOp above for WHY).
  local snapGuidToTrack = {}
  for trackKey, s in pairs(snap) do
    for _, e in ipairs(s.fx) do
      if e.id then snapGuidToTrack[e.id] = trackKey end
    end
  end
  for trackKey, t_ in pairs(target) do
    for _, e in ipairs(t_.fx) do
      local fromKey = e.id and snapGuidToTrack[e.id]
      if fromKey and fromKey ~= trackKey then
        local s = snap[fromKey]
        util.add(ops, { op = 'moveFxAcrossTracks',
                        fxGuid         = e.id,
                        fromTrackKind  = s.trackKind, fromTrackGuid = s.id,
                        toTrackKind    = t_.trackKind, toTrackGuid   = t_.id,
                        toTrackKey     = trackKey })
      end
    end
  end

  -- Per-class field diffs. A trackKind transition is treated as fresh: every
  -- field op + setExtState fires unconditionally so the new track gets fully
  -- populated.
  for trackKey, t_ in pairs(target) do
    local s = snap[trackKey]
    local fresh = not s or trackChanged[trackKey]
    if fresh or not fxOrderEq(t_.fx, s.fx) then
      util.add(ops, { op = 'setFXChain', trackKey = trackKey,
                      trackKind = t_.trackKind,
                      trackGuid = t_.id, fx = t_.fx })
    end
    local tNchan = t_.nchan or 2
    local sNchan = (s and s.nchan) or 2
    if tNchan ~= sNchan then
      util.add(ops, { op = 'setNchan', trackKey = trackKey,
                      trackKind = t_.trackKind, trackGuid = t_.id,
                      value = tNchan })
    end
    if not pinMapsEq(t_, s) then
      util.add(ops, { op = 'setPinMaps', trackKey = trackKey,
                      trackKind = t_.trackKind, trackGuid = t_.id,
                      fx = t_.fx })
    end
    local tm = t_.mainSend or {}
    local sm = (s and s.mainSend) or {}
    local tOn   = tm.on and true or false
    local sOn   = sm.on and true or false
    local tGain = tm.gain or 1.0
    local sGain = sm.gain or 1.0
    local tOffs = (tOn and tm.tgtOffset) or 0
    local sOffs = (sOn and sm.tgtOffset) or 0
    local tNch  = (tOn and tm.nchan) or 0
    local sNch  = (sOn and sm.nchan) or 0
    if (fresh and (tOn or tGain ~= 1.0))
       or (not fresh and (tOn ~= sOn or tGain ~= sGain
                                     or tOffs ~= sOffs or tNch ~= sNch)) then
      util.add(ops, { op = 'setMainSend', trackKey = trackKey,
                      trackKind = t_.trackKind, trackGuid = t_.id,
                      value = tOn, gain = tGain, offs = tOffs, nch = tNch })
    end
    if fresh or not sendsEq(t_.sends, s.sends) then
      util.add(ops, { op = 'setSends', trackKey = trackKey,
                      trackKind = t_.trackKind,
                      trackGuid = t_.id, sends = t_.sends })
    end
    -- ExtState writes only on creation/track-transition-in: sourceTrack gets wiringTrackKind only
    -- (own guid is already the key); newTrack also needs wiringTrack for its multi-guid key.
    if fresh and t_.trackKind == 'sourceTrack' then
      util.add(ops, { op = 'setExtState', trackKey = trackKey,
                      key = 'wiringTrackKind', value = 'sourceTrack' })
    elseif fresh and t_.trackKind == 'newTrack' then
      util.add(ops, { op = 'setExtState', trackKey = trackKey,
                      key = 'wiringTrackKind', value = 'newTrack' })
      util.add(ops, { op = 'setExtState', trackKey = trackKey,
                      key = 'wiringTrack', value = trackKey })
    end
  end

  -- Drains/deletes last so any final reads of going-away tracks have already
  -- run. A snap entry is abandoned if absent from target, or if its track
  -- changed: newTrack hosts get deleteTrack (which kills any owned FX with the
  -- track); undeletable hosts (sourceTrack/master/scratch) with surviving
  -- owned FX need an explicit setFXChain to [] to drain them.
  for trackKey, s in pairs(snap) do
    local abandoned = not target[trackKey] or trackChanged[trackKey]
    if abandoned then
      if s.trackKind == 'newTrack' then
        util.add(ops, { op = 'deleteTrack', trackGuid = s.id })
      elseif #s.fx > 0 then
        util.add(ops, { op = 'setFXChain', trackKey = trackKey,
                        trackKind = s.trackKind, trackGuid = s.id, fx = {} })
      end
    end
  end

  return ops
end

----- Apply ops (Stage 2)

local function ownedSubsequence(fxChain, ownedGuids)
  local out = {}
  for i, fx in ipairs(fxChain) do
    if ownedGuids[fx.id] then
      util.add(out, { fxGuid = fx.id, ident = fx.ident, absIdx = i - 1 })
    end
  end
  return out
end

-- Inline stamp/clear of minted/retracted fx guids onto userGraph (no mutate transaction):
-- stamping a guid never changes structure, so validation and wiringChanged are skipped.
local function stampOrigin(origin, guid)
  local nodes = userGraph.nodes
  if     origin.kind == 'node'       then nodes[origin.id].fxGuid             = guid
  elseif origin.kind == 'bracketIn'  then nodes[origin.id].midiInBracketGuid  = guid
  elseif origin.kind == 'bracketOut' then nodes[origin.id].midiOutBracketGuid = guid
  elseif origin.kind == 'merge' then
    local n = nodes[origin.consumer]
    n.mergeGuids = n.mergeGuids or {}
    n.mergeGuids[origin.trackKey] = guid
  end
end

-- Read-side inverse of stampOrigin: the guid an origin resolves to once
-- setFXChain has stamped it, so setPinMaps can address an id-less entry.
local function originGuid(origin)
  local nodes = userGraph.nodes
  if origin.kind == 'node'       then return nodes[origin.id] and nodes[origin.id].fxGuid end
  if origin.kind == 'bracketIn'  then return nodes[origin.id] and nodes[origin.id].midiInBracketGuid end
  if origin.kind == 'bracketOut' then return nodes[origin.id] and nodes[origin.id].midiOutBracketGuid end
  if origin.kind == 'merge' then
    local n = nodes[origin.consumer]
    return n and n.mergeGuids and n.mergeGuids[origin.trackKey]
  end
end

-- guid → the user-graph field carrying it, so a retracted fx clears its stamp.
local function buildGuidOwners()
  local owners = {}
  for _, n in pairs(userGraph.nodes) do
    if n.kind == 'fx' then
      if n.fxGuid             then owners[n.fxGuid]             = { node = n, field = 'fxGuid' } end
      if n.midiInBracketGuid  then owners[n.midiInBracketGuid]  = { node = n, field = 'midiInBracketGuid' } end
      if n.midiOutBracketGuid then owners[n.midiOutBracketGuid] = { node = n, field = 'midiOutBracketGuid' } end
    end
    if n.mergeGuids then
      for trackKey, g in pairs(n.mergeGuids) do owners[g] = { node = n, mergeKey = trackKey } end
    end
  end
  return owners
end

-- Clear a retracted guid's stamp; returns true iff a field was actually cleared.
local function clearOwner(owners, guid)
  local o = owners[guid]
  if not o then return false end
  if o.mergeKey then
    o.node.mergeGuids[o.mergeKey] = nil
    if not next(o.node.mergeGuids) then o.node.mergeGuids = nil end
  else
    o.node[o.field] = nil
  end
  return true
end

-- Reconcile the owned FX subsequence of `trackId` to `target` via rm. Owned FX stay
-- contiguous (new FX inserts just after last owned); mints stamp the graph inline.
local function reconcileFXChain(trackId, target, ownedGuids, owners)
  local dirty = false
  local function liveChain() local r = rm:track(trackId); return r and r.fx or {} end
  local chain   = liveChain()
  local current = ownedSubsequence(chain, ownedGuids)

  -- Stale-guid sweep: a target entry whose id isn't live in REAPER (reload,
  -- manual delete, drift) drops to nil so it re-materialises and re-stamps.
  local liveGuids = {}
  for _, c in ipairs(current) do liveGuids[c.fxGuid] = true end
  for _, t in ipairs(target) do
    if t.id and not liveGuids[t.id] then t.id = nil end
  end

  -- 1. Drop owned entries absent from target (right-to-left keeps absIdx valid).
  local targetGuids = {}
  for _, t in ipairs(target) do if t.id then targetGuids[t.id] = true end end
  for i = #current, 1, -1 do
    local guid = current[i].fxGuid
    if not targetGuids[guid] then
      rm:deleteFx(guid)
      ownedGuids[guid] = nil
      if clearOwner(owners, guid) then dirty = true end
      table.remove(current, i)
    end
  end

  -- 2. Materialise id-less targets at the slot just after the last owned entry;
  --    rm:addFx appends, moves into place, and returns the minted guid.
  for _, t in ipairs(target) do
    if not t.id then
      local insertAt = (#current > 0) and (current[#current].absIdx + 1)
                       or #chain
      local guid = rm:addFx(trackId, { ident = t.ident, index = insertAt })
      t.id = guid
      ownedGuids[guid] = true
      stampOrigin(t.origin, guid)
      dirty = true
      util.add(current, { fxGuid = guid, ident = t.ident, absIdx = insertAt })
    end
  end

  -- 3. Permute the owned subsequence to target order via rm:assignFx{index};
  --    the contiguous-block invariant fixes each target slot at firstOwnedAbs+(d-1).
  current = ownedSubsequence(liveChain(), ownedGuids)
  local firstOwnedAbs = current[1] and current[1].absIdx
  for d = 1, #target do
    if current[d].fxGuid ~= target[d].id then
      local fromIdx
      for j = d + 1, #current do
        if current[j].fxGuid == target[d].id then fromIdx = j; break end
      end
      rm:assignFx(target[d].id, { index = firstOwnedAbs + (d - 1) })
      local moved = current[fromIdx]
      table.remove(current, fromIdx)
      table.insert(current, d, moved)
      for i = 1, #current do current[i].absIdx = firstOwnedAbs + (i - 1) end
    end
  end

  -- 4. Push params (flat sliders) and per-FX MIDI routing now the chain is in
  --    final order; rm resolves both by guid and owns the chunk surgery.
  for _, t in ipairs(target) do
    local assign = {}
    if t.params then assign.params = t.params end
    if t.midi   then assign.midi   = t.midi   end
    if next(assign) then rm:assignFx(t.id, assign) end
  end

  return dirty
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
  return s
end

local function buildTrackKeyToTrack()
  local out = {}
  eachTrack(function(track)
    local trackKind = cm:readTrackKey(track, 'wiringTrackKind')
    if trackKind == 'sourceTrack' then
      out[reaper.GetTrackGUID(track)] = track
    elseif trackKind == 'newTrack' then
      local k = cm:readTrackKey(track, 'wiringTrack')
      if k then out[k] = track end
    elseif cm:readTrackKey(track, 'wiringScratch') == '1' then
      out[SCRATCH_KEY] = track
    end
  end)
  return out
end

--contract: walks ops in order inside one rm:transaction; setFXChain mints guids via rm:addFx
--contract: stamps them inline without firing wiringChanged; params/midi/pinMaps write through rm
function wm:applyOps(ops, label)
  ensureLoaded()
  rm:transaction(label or 'wiring: apply', function()
    local trackKeyToTrack = buildTrackKeyToTrack()
    local ownedGuids      = ownedGuidsFrom(userGraph, cm:get('wiringOwnedFx'))
    local owners          = buildGuidOwners()
    local graphDirty      = false

    -- Master is absent from the project-track scan, so resolve its guid via rm and note
    -- which trackKeys it hosts; send-destination resolution maps those to it below.
    local masterGuid = rm:masterId()
    local masterKeys = {}
    for _, op in ipairs(ops) do
      if op.trackKind == 'master' and op.trackKey then masterKeys[op.trackKey] = true end
    end

    -- Addressing seam: rm speaks guid ids, wm speaks trackKey/trackGuid. keyToId maps a
    -- send destination's trackKey → guid (master via masterKeys); resolveId an op's host.
    local function keyToId(trackKey)
      if masterKeys[trackKey] then return masterGuid end
      local track = trackKeyToTrack[trackKey]
      return track and reaper.GetTrackGUID(track)
    end
    local function resolveId(kind, guid, trackKey)
      if guid then return guid end
      if kind == 'master' then return masterGuid end
      return keyToId(trackKey)
    end

    for _, op in ipairs(ops) do
      if op.op == 'createTrack' then
        local id = rm:addTrack({ name = 'continuum: ' .. op.trackKey })
        trackKeyToTrack[op.trackKey] = self:trackByGuid(id)
      elseif op.op == 'deleteTrack' then
        rm:deleteTrack(op.trackGuid)
      elseif op.op == 'setExtState' then
        local t = trackKeyToTrack[op.trackKey]
        if t then cm:writeTrackKey(t, op.key, op.value) end
      elseif op.op == 'setMainSend' then
        local id = resolveId(op.trackKind, op.trackGuid, op.trackKey)
        if id then
          local mainSend = { on = op.value, gain = op.gain or 1.0 }
          if op.value then
            mainSend.tgtOffset = op.offs or 0
            mainSend.nchan     = op.nch or 2
          end
          rm:assignTrack(id, { mainSend = mainSend })
        end
      elseif op.op == 'setNchan' then
        local id = resolveId(op.trackKind, op.trackGuid, op.trackKey)
        if id then rm:assignTrack(id, { nchan = op.value }) end
      elseif op.op == 'setPinMaps' then
        -- setFXChain has stamped+pruned the graph, so op.fx is the live owned set.
        -- Full-replace: a port absent from an entry's map is disconnected.
        for _, e in ipairs(op.fx) do
          local guid = e.id or originGuid(e.origin)
          if guid then
            rm:assignFx(guid, { pinMaps = e.pinMaps or { ins = {}, outs = {} } })
          end
        end
      elseif op.op == 'setFXChain' then
        local guid = resolveId(op.trackKind, op.trackGuid, op.trackKey)
        if guid and reconcileFXChain(guid, op.fx, ownedGuids, owners) then
          graphDirty = true
        end
      elseif op.op == 'moveFxAcrossTracks' then
        local toId = resolveId(op.toTrackKind, op.toTrackGuid, op.toTrackKey)
        if toId then rm:assignFx(op.fxGuid, { track = toId }) end
      elseif op.op == 'setSends' then
        local id = resolveId(op.trackKind, op.trackGuid, op.trackKey)
        if id then
          local sends = {}
          for _, s in ipairs(op.sends) do
            local toId = keyToId(s.to)
            if toId then
              util.add(sends, { to = toId, kind = s.kind, gain = s.gain,
                                srcChan = s.srcChan, dstChan = s.dstChan, pos = s.pos })
            end
          end
          rm:assignTrack(id, { sends = sends })
        end
      end
    end

    -- Stamps/clears mutated userGraph in place; persist + invalidate the compiled
    -- cache without firing (no structural change, no reconcile re-entry).
    if graphDirty then setGraph(userGraph); self:save() end

    -- Persist the post-apply owned-guid set: anything in the graph is still
    -- in REAPER (orphans were deleted in reconcileFXChain and dropped from graph).
    local owned = ownedGuidsFrom(userGraph)
    cm:set('project', 'wiringOwnedFx', owned)
    rebuildFxLocations()

    -- Mirror to scratch P_EXT inside the transaction so REAPER's undo captures
    -- the graph alongside FX/track ops; pollUndo watches lastScratchRaw for divergence.
    local scratch = ensureScratchTrack()
    cm:writeTrackKey(scratch, 'wiringGraph',  userGraph)
    cm:writeTrackKey(scratch, 'wiringOwnedFx', owned)
    lastScratchRaw = cm:readTrackRaw(scratch)
  end)
end

-- Gain routing derived once per structural change from the cached ctx.
-- Merge-CU entries carry consumerId/trackKey (not a guid); mergeGuids are stamped live by applyOps.
--shape: routing[edgeIdx] = {kind='mergeCU',consumerId,trackKey,slot} | {kind='mainSend',cls} | {kind='send',from,to}
local function gainRouting()
  local cache = ensureCompiled()
  if cache.routing then return cache.routing end
  local ctx, routing = cache.ctx, {}
  for _, spec in pairs(DAG.targetTracks(ctx)) do
    for _, sn in pairs(spec.synthNodes or {}) do
      for slot, edgeIdx in ipairs(sn.inputEdges or {}) do
        routing[edgeIdx] = { kind = 'mergeCU', consumerId = sn.originConsumer,
                             trackKey = sn.originTrackKey, slot = slot }
      end
    end
  end
  for edgeIdx, host in pairs(ctx:gainHost()) do
    if not routing[edgeIdx] then
      if host.kind == 'mainSend' then
        routing[edgeIdx] = { kind = 'mainSend', cls = host.cls }
      elseif host.kind == 'send' then
        routing[edgeIdx] = { kind = 'send', from = host.from, to = host.to }
      end
    end
  end
  cache.routing = routing
  return routing
end

-- Master isn't in CountTracks/GetTrack; probe it first or a master-resident CU misses every frame.
local function pokeCuParam(guid, paramName, value)
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
  if probe(reaper.GetMasterTrack(0)) then return true end
  for i = 0, reaper.CountTracks(0) - 1 do
    if probe(reaper.GetTrack(0, i)) then return true end
  end
  return false
end

local function pokeGainTarget(target, gain)
  if target.kind == 'mergeCU' then
    local consumer = userGraph.nodes[target.consumerId]
    local guid = consumer and consumer.mergeGuids and consumer.mergeGuids[target.trackKey]
    return guid ~= nil and pokeCuParam(guid, 'gain' .. target.slot, gain) or false
  end
  local byTrackKey = buildTrackKeyToTrack()
  if target.kind == 'mainSend' then
    local track = byTrackKey[target.cls]
    if not track then return false end
    reaper.SetMediaTrackInfo_Value(track, 'D_VOL', gain)
    return true
  elseif target.kind == 'send' then
    local src, dst = byTrackKey[target.from], byTrackKey[target.to]
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

--contract: pokes the live gain for an edge via cached routing; no mutate/signal/undo.
-- see docs/wiringManager.md § pokeEdgeGain routing
function wm:pokeEdgeGain(edgeIdx, gain)
  local target = gainRouting()[edgeIdx]
  return target ~= nil and pokeGainTarget(target, gain) or false
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

--contract: delegates to rm:installedFx — raw REAPER "Type: Name (Author)" rows, memoised there
function wm:listInstalledFX()
  return rm:installedFx()
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
  setGraph(nil)
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
