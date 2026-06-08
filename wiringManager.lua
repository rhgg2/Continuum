-- See docs/wiringManager.md for the model.
-- @noindex

--invariant: fx-kind nodes carry fxId; addFxNode mints it via instantiateFxOnScratch
--invariant: CU bridges arrive at the applier with nil fxId; reconcileFXChain mints them
--invariant: fxId is the stable bridge identity; snapshot/targetState match fxOrder by it
--invariant: wm deletes an FX instance only when its owning node or CU bridge leaves the graph
--invariant: trackKey changes are moves; TrackFX_CopyToTrack(is_move=true) preserves plugin state
--shape: snapshotPinMap = { ins={[port]={pair,...}}, outs={[port]={pair,...}} }
--shape: snapshotSend = { to=trackKey, kind='audio'|'midi', gain?=number, srcChan=int, dstChan=int, pos='preFx'|'preFader'|'postFader' }
--shape: snapshotFxOrigin = {kind='node',id=string}|{kind='bracketIn'|'bracketOut',id=string}|{kind='merge',consumer=string,trackKey=trackKey}
--shape: snapshotFxEntry = { id?=string, ident=string, ins?=int, outs?=int, params?=table, origin?=snapshotFxOrigin, midi?={inBus=int,outBus=int,outDisabled=bool}, pinMaps?=snapshotPinMap }  -- ins/outs are audio pair counts, for read
--shape: wiringSnapshot = { [trackKey] = { trackKind='sourceTrack'|'newTrack'|'master'|'scratch', id?=string, nchan?=int, mainSend={on=bool,gain?,tgtOffset?,nchan?}, fx=snapshotFxEntry[], sends=snapshotSend[] } }; rm:tracks() record + wm ownership/trackKey overlay. see docs/wiringManager.md § wiringSnapshot.
--shape: wiringOp = { op='createTrack'|'deleteTrack'|'setFXChain'|'setMainSend'|'setSends'|'setNchan'|'setPinMaps'|'moveFxAcrossTracks', ... }
-- full-replace ops; see docs/wiringManager.md § wiringOp for per-op field detail.
--invariant: authoring via wm:mutate — validate+swap+persist+fire; graph+wiringChanged always pass.
--invariant: master is graph.nodes['master']; freshGraph seeds it; DAG.validate enforces singleton.
--invariant: scratch is rm-owned (rm:scratchId/Track); wm parks fx + mirrors the undo blob there
--invariant: scratch hosts FX with no compile-graph track — disconnected or lowered-parked

local util = require 'util'
local DAG  = require 'DAG'
local fs   = require 'fs'

local cm = (...).cm
local rm = (...).rm

local wm = {}
local fire = util.installHooks(wm)

local userGraph = nil
local liveLabel = nil     -- non-nil iff live mode is on; carries the default undo label
local lastScratchRaw = nil -- serialised graph last mirrored to scratch P_EXT; pollUndo compares against it

local SCRATCH_KEY = '__scratch__'  -- scratch's logical trackKey; its guid is rm-owned
local CU_IDENT    = 'JS:Continuum Utility'

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

-- True iff JSFX desc declares ext_midi_bus=1 (the FX scans midi_bus itself,
-- escaping our allocator). Skips // comments; frontier prevents `=10` match.
local function parseJSFXBusAware(content)
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

--contract: re-reads the persisted graph, fires wiringChanged{kind='load'}; scratch is rm-owned
function wm:load()
  setGraph(readPersisted())
  fire('wiringChanged', { kind = 'load' })
end

--contract: persists in-memory graph to project tier; mutate calls this, callers don't
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
function wm:readJSFXContent(ident)
  if not (ident and ident:sub(1, 3) == 'JS:') then return nil end
  local path = fs.join(reaper.GetResourcePath(), 'Effects/' .. ident:sub(4))
  local f = io.open(path, 'rb')
  if not f then return nil end
  local content = f:read('*a')
  f:close()
  return content
end

-- Exposed for unit tests; production paths use `wm:isUserAddRefused` below.
wm.parseJSFXBusAware = parseJSFXBusAware

--contract: refuses JSFX whose desc declares ext_midi_bus=1; nil on accept, structured err on refuse
function wm:checkUserAddable(ident)
  if not (ident and ident:sub(1, 3) == 'JS:') then return nil end
  if parseJSFXBusAware(self:readJSFXContent(ident)) then
    return { code = 'ext_midi_bus_user_fx', ident = ident }
  end
end

--contract: AddByName on scratch + keep; returns {fxId, ins, outs, inNames, outNames}
--contract: unknown ident → fxId=nil, ins=outs=0, empty name lists
function wm:instantiateFxOnScratch(ident)
  local fxId = rm:addFx(rm:scratchId(), { ident = ident })
  if not fxId then return { fxId = nil, ins = 0, outs = 0, inNames = {}, outNames = {} } end
  local rec = rm:fx(fxId)
  return { fxId = fxId, ins = rec.ins, outs = rec.outs,
           inNames = rec.inNames, outNames = rec.outNames }
end

--contract: the scratch track id (rm-owned, ensured on first use)
function wm:scratchId()
  return rm:scratchId()
end

--contract: true iff `track` is the live scratch track
function wm:isScratchTrack(track)
  local id = self:scratchId()
  return id ~= nil and rm:reaperTrack(id) == track
end

--contract: true iff `track` is wiring-owned (scratch/spawned newTrack); arrange hides these
function wm:isWiringOwnedTrack(track)
  if self:isScratchTrack(track) then return true end
  local guid = track and reaper.GetTrackGUID(track)
  if not guid then return false end
  for _, id in pairs(cm:get('wiringTracks') or {}) do
    if id == guid then return true end
  end
  return false
end

--contract: { [trackId] = name } for every project track + master; one rm:tracks() pass
function wm:trackNames()
  local out = {}
  for _, tr in ipairs(rm:tracks()) do out[tr.id] = tr.name end
  return out
end

--contract: raw MediaTrack hosting the fx instance guid, or nil if the guid isn't live.
function wm:fxTrack(fxId)
  local rec = rm:fx(fxId)
  return rec and rm:reaperTrack(rec.trackId) or nil
end

--contract: floats the FX window for the instance guid; false if the guid is no longer live
function wm:showFxWindow(fxId)
  return rm:showFx(fxId)
end

--contract: appends a source track via rm and returns its id; called outside mutate.
-- snapshot derives source identity from graph source nodes, not a tag. see docs/wiringManager.md § createSourceTrack
function wm:createSourceTrack(opts)
  return rm:addTrack{ name = opts and opts.name, defaults = true }
end

-- Strips the "Type: " prefix and a trailing balanced-paren author / out-count
-- ("... (Cockos)", "... (2 outs)"); %b() so a nested paren can't end it early.
local function shortFxName(s)
  s = s:gsub('^[^:]+:%s*', '')
  s = s:gsub('%s*%b().*$', '')
  return s
end

--contract: one Undo block around instantiate + mutate; stamps fxId on the new fx-node
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
        fxId    = io.fxId,
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
          trackId   = sourceGuid,
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
  local track = node.trackId and rm:reaperTrack(node.trackId)
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
    if node.trackId then rm:deleteTrack(node.trackId) end
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
        trackId   = guid,
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

-- Decode CU slider floats (rm:fx params, by display name) into wm/CU vocabulary;
-- only the meaningful subset per mode, so the snapshot diff ignores stale lanes.
local function readCuParams(params)
  local modeInt = math.floor(params.mode + 0.5)
  local modeStr = ({ [0] = 'busRoute', [1] = 'merge' })[modeInt] or 'merge'
  if modeStr == 'busRoute' then
    return { mode = modeStr,
             from = math.floor(params.from + 0.5),
             to   = math.floor(params.to + 0.5) }
  end
  local nPairs = math.floor(params.nPairs + 0.5)
  local gains, inMask = {}, {}
  for i = 1, nPairs do gains[i] = params['gain' .. i] end
  for i = 0, 3 do inMask[i + 1] = math.floor(params['inMask' .. i] + 0.5) end
  return { mode = modeStr, nPairs = nPairs, gains = gains,
           audioSum = math.floor(params.audioSum + 0.5),
           outBus   = math.floor(params.outBus + 0.5),
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
      if n.fxId             then ownedGuids[n.fxId]             = true end
      if n.midiInBracketGuid  then ownedGuids[n.midiInBracketGuid]  = true end
      if n.midiOutBracketGuid then ownedGuids[n.midiOutBracketGuid] = true end
    end
    if n.mergeGuids then
      for _, g in pairs(n.mergeGuids) do ownedGuids[g] = true end
    end
  end

  -- (id → trackKey/trackKind) from wm state, not tags: source nodes carry their
  -- track's id (== its trackKey); newTracks resolve through wiringTracks, scratch via rm.
  local keyByGuid, kindByKey = {}, {}
  for _, n in pairs(userGraph.nodes) do
    if n.kind == 'source' and n.trackId then
      keyByGuid[n.trackId] = n.trackId
      kindByKey[n.trackId] = 'sourceTrack'
    end
  end
  for trackKey, id in pairs(cm:get('wiringTracks') or {}) do
    keyByGuid[id], kindByKey[trackKey] = trackKey, 'newTrack'
  end
  local scratch = rm:scratchId()
  keyByGuid[scratch], kindByKey[SCRATCH_KEY] = SCRATCH_KEY, 'scratch'

  local function snapFx(fx)
    local entry = { id = fx.id, ident = fx.ident, ins = fx.ins, outs = fx.outs }
    if fx.pinMaps and (next(fx.pinMaps.ins) or next(fx.pinMaps.outs)) then
      entry.pinMaps = fx.pinMaps
    end
    if isJS(fx.ident) then
      if fx.ident == CU_IDENT then
        local params = rm:params(fx.id)
        if params then entry.params = flattenCuParams(readCuParams(params)) end
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
      local entry = { id = node.fxId, ident = node.fxIdent }
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
        entry.ins, entry.outs = node.ports.audio.ins, node.ports.audio.outs
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
  if     spec.trackKind == 'sourceTrack' then id = spec.trackId
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

--contract: pure; scratch id via rm; derives wiringSnapshot from DAG.targetTracks
-- see docs/wiringManager.md
function wm:targetState()
  ensureLoaded()
  local cx = DAG.compile(userGraph)
  local nodes = userGraph.nodes
  local tracks = DAG.allocate(DAG.targetTracks(cx), nodes)
  local scratchGuid = rm:scratchId()
  local out = {}
  for trackKey, entry in pairs(tracks) do
    out[trackKey] = projectEntry(entry, nodes, scratchGuid)
  end
  return out
end

----- read : wiringSnapshot -> userGraph (design/wiring-implicit-graph.md § Plan)

-- Pass 3b: audio + CU collapse + gain + full midi-bus walk (fan-in, merge, brackets)
-- onto edge.ops.gain; node ids are rm ids. Pure.
local MASTER_KEY = '__master__'
local function readGraph(snap)
  local nodes = {
    master = { kind = 'master',
               ports = { audio = { ins = 1, outs = 0 }, midi = { ins = 0, outs = 0 } } },
  }
  local edges = {}

  -- Refs carry an accumulated gain; folding multiplies, unity stays absent so a
  -- clean edge reads back clean. addAudioEdge lands the product on edge.ops.gain.
  local function foldGain(ref, g)
    if not g or g == 1 then return ref end
    return { node = ref.node, port = ref.port, gain = (ref.gain or 1) * g }
  end
  local function addAudioEdge(ref, to, toPort)
    local e = { type = 'audio', from = ref.node, fromPort = ref.port, to = to, toPort = toPort }
    if ref.gain and ref.gain ~= 1 then e.ops = { gain = ref.gain } end
    util.add(edges, e)
  end

  -- MIDI merge CU (utility/Continuum Utility.jsfx @block mode 1): every producer on a
  -- masked input bus is rewritten onto outBus; masked buses clear, others pass through.
  local function mergeMidi(live, cu)
    local outBus, masked = cu.outBus, {}
    for lane = 1, 4 do
      local bits = cu.inMask[lane] or 0
      for bit = 0, 31 do
        if (bits >> bit) & 1 == 1 then masked[(lane - 1) * 32 + bit] = true end
      end
    end
    local unioned = {}
    for bus in pairs(masked) do
      for _, ref in ipairs(live[bus] or {}) do util.add(unioned, ref) end
      if bus ~= outBus then live[bus] = nil end
    end
    if not masked[outBus] then
      for _, ref in ipairs(live[outBus] or {}) do util.add(unioned, ref) end
    end
    live[outBus] = #unioned > 0 and unioned or nil
  end

  -- BusRoute CU (Continuum Utility @block mode 0): from->0, 0->to, others pass; from!=to
  -- retains `from`. Wrapped JSFX reads bus 0, so brackets are midi-transparent on read.
  local function busRouteMidi(live, from, to)
    local out = {}
    for bus, list in pairs(live) do out[bus] = list end
    out[0] = live[from]
    if from == to then
      out[to] = live[0]
    else
      out[from] = live[from]
      local joined = {}
      for _, r in ipairs(live[0] or {}) do util.add(joined, r) end
      for _, r in ipairs(live[to] or {}) do util.add(joined, r) end
      out[to] = #joined > 0 and joined or nil
    end
    return out
  end

  -- Incoming routing per track: explicit audio sends + the parent send. REAPER
  -- pins the parent send to channels 1-2, so its source is always pair 1.
  local incoming = {}
  local function addIncoming(toKey, inc)
    incoming[toKey] = incoming[toKey] or {}
    util.add(incoming[toKey], inc)
  end
  for fromKey, entry in pairs(snap) do
    for _, s in ipairs(entry.sends or {}) do
      if s.kind == 'audio' then
        addIncoming(s.to, { from = fromKey, srcPair = s.srcChan // 2 + 1,
                            dstPair = s.dstChan // 2 + 1, gain = s.gain })
      elseif s.kind == 'midi' then
        addIncoming(s.to, { from = fromKey, midi = true,
                            srcBus = s.srcChan, dstBus = s.dstChan })
      end
    end
    if entry.mainSend and entry.mainSend.on then
      addIncoming(MASTER_KEY, { from = fromKey, toMaster = true, srcPair = 1,
                                dstPair = (entry.mainSend.tgtOffset or 0) // 2 + 1,
                                gain = entry.mainSend.gain })
    end
  end

  -- Non-master tracks in sender-before-receiver order (Kahn over explicit
  -- sends); the master track walks last, fed by every parent send.
  local function nonMasterOrder()
    local indeg, children, keys = {}, {}, {}
    for k, e in pairs(snap) do
      if e.trackKind ~= 'master' and e.trackKind ~= 'scratch' then
        keys[#keys + 1] = k; indeg[k] = 0; children[k] = {}
      end
    end
    for _, k in ipairs(keys) do
      for _, inc in ipairs(incoming[k] or {}) do
        if not inc.toMaster and indeg[inc.from] ~= nil then
          indeg[k] = indeg[k] + 1
          util.add(children[inc.from], k)
        end
      end
    end
    local ready, out = {}, {}
    for _, k in ipairs(keys) do if indeg[k] == 0 then util.add(ready, k) end end
    local placed = {}
    while #ready > 0 do
      table.sort(ready)
      local k = table.remove(ready, 1)
      util.add(out, k); placed[k] = true
      for _, c in ipairs(children[k]) do
        indeg[c] = indeg[c] - 1
        if indeg[c] == 0 then util.add(ready, c) end
      end
    end
    return out
  end

  local tails = {}  -- trackKey -> { audio={[pair]=ref[]}, midi={[bus]=ref[]} }; ref = { node, port?, gain? }
  local function walkTrack(trackKey, entry)
    local liveAudio, liveMidi = {}, {}
    local function feed(pair, ref)
      liveAudio[pair] = liveAudio[pair] or {}
      util.add(liveAudio[pair], ref)
    end
    local function feedMidi(bus, ref)
      liveMidi[bus] = liveMidi[bus] or {}
      util.add(liveMidi[bus], ref)
    end

    local inc = incoming[trackKey]
    if inc then
      for _, i in ipairs(inc) do
        local tail = tails[i.from] or {}
        if i.midi then
          for _, ref in ipairs((tail.midi or {})[i.srcBus] or {}) do feedMidi(i.dstBus, ref) end
        else
          for _, ref in ipairs((tail.audio or {})[i.srcPair] or {}) do feed(i.dstPair, foldGain(ref, i.gain)) end
        end
      end
    elseif entry.trackKind ~= 'master' then
      -- No inputs => a source: emits audio on pair 1 and midi on bus 0.
      local sid = entry.id
      nodes[sid] = { kind = 'source', trackId = entry.id,
                     ports = { audio = { ins = 0, outs = 1 }, midi = { ins = 0, outs = 1 } } }
      feed(1, { node = sid, port = 1 })
      feedMidi(0, { node = sid })
    end

    -- A merge/bracket CU mints no node: audio outputs carry upstream producers (gain-
    -- folded), midi remap moves producers between buses. See design § What read does.
    local function collapseCu(fxe)
      local cu = readCuParams(fxe.params or {})
      local pinMaps = fxe.pinMaps or { ins = {}, outs = {} }
      local inProducers = {}
      for port, prs in pairs(pinMaps.ins or {}) do
        local gain, list = cu.gains and cu.gains[port] or 1, {}
        for _, pair in ipairs(prs) do
          for _, ref in ipairs(liveAudio[pair] or {}) do util.add(list, foldGain(ref, gain)) end
        end
        inProducers[port] = list
      end
      -- audioSum 1 = sum-tree: every input collapses onto output pair 1; otherwise
      -- the matrix/bracket diagonal carries input port i straight to output port i.
      local outProducers = inProducers
      if cu.audioSum == 1 then
        local summed = {}
        for _, list in pairs(inProducers) do for _, ref in ipairs(list) do util.add(summed, ref) end end
        outProducers = { summed }
      end
      for port, prs in pairs(pinMaps.outs or {}) do
        for _, pair in ipairs(prs) do liveAudio[pair] = outProducers[port] or {} end
      end
      -- MIDI: merge unions masked input buses onto outBus; busRoute swaps from/0/to.
      if cu.mode == 'merge' then mergeMidi(liveMidi, cu)
      else liveMidi = busRouteMidi(liveMidi, cu.from, cu.to) end
    end

    for _, fxe in ipairs(entry.fx or {}) do
      if fxe.ident == CU_IDENT then
        collapseCu(fxe)
      else
        local id = fxe.id
        nodes[id] = { kind = 'fx', fxIdent = fxe.ident, fxId = id,
                      ports = { audio = { ins = fxe.ins or 0, outs = fxe.outs or 0 },
                                midi = { ins = 1, outs = 1 } } }
        local pinMaps = fxe.pinMaps or { ins = {}, outs = {} }
        for port, prs in pairs(pinMaps.ins or {}) do
          for _, pair in ipairs(prs) do
            for _, ref in ipairs(liveAudio[pair] or {}) do addAudioEdge(ref, id, port) end
          end
        end
        -- MIDI: read inBus -> edges; an fx drives its outBus when midi-out is enabled,
        -- else clears it (bus stops here). Plain JSFX has no stored midi -> bus 0, relays.
        local m = fxe.midi
        local inBus, outBus = m and m.inBus or 0, m and m.outBus or 0
        for _, ref in ipairs(liveMidi[inBus] or {}) do
          util.add(edges, { type = 'midi', from = ref.node, to = id })
        end
        for port, prs in pairs(pinMaps.outs or {}) do
          for _, pair in ipairs(prs) do liveAudio[pair] = { { node = id, port = port } } end
        end
        liveMidi[outBus] = not (m and m.outDisabled) and { { node = id } } or nil
      end
    end

    tails[trackKey] = { audio = liveAudio, midi = liveMidi }
  end

  for _, k in ipairs(nonMasterOrder()) do walkTrack(k, snap[k]) end
  walkTrack(MASTER_KEY, snap[MASTER_KEY] or { trackKind = 'master', fx = {} })

  -- The master node is the master track's output (pair 1).
  for _, ref in ipairs((tails[MASTER_KEY].audio or {})[1] or {}) do addAudioEdge(ref, 'master', nil) end

  return { nodes = nodes, edges = edges, nextId = 1 }
end

wm.readGraph = readGraph  -- exposed for unit tests; wm:read drives it from the live snapshot

--contract: reconstructs the user graph from REAPER routing; node ids are rm ids
-- (3b: audio + CU collapse + gain + full midi-bus walk; quarantine TODO)
function wm:read()
  return readGraph(self:snapshot())
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
                        fxId         = e.id,
                        fromTrackKind  = s.trackKind, fromTrackGuid = s.id,
                        toTrackKind    = t_.trackKind, toTrackGuid   = t_.id,
                        toTrackKey     = trackKey })
      end
    end
  end

  -- Per-class field diffs. A trackKind transition is treated as fresh: every
  -- field op fires unconditionally so the new track gets fully populated.
  for trackKey, t_ in pairs(target) do
    local s = snap[trackKey]
    local fresh = not s or trackChanged[trackKey]
    if fresh or not fxOrderEq(t_.fx, s.fx) then
      util.add(ops, { op = 'setFXChain', trackKey = trackKey,
                      trackKind = t_.trackKind,
                      trackId = t_.id, fx = t_.fx })
    end
    local tNchan = t_.nchan or 2
    local sNchan = (s and s.nchan) or 2
    if tNchan ~= sNchan then
      util.add(ops, { op = 'setNchan', trackKey = trackKey,
                      trackKind = t_.trackKind, trackId = t_.id,
                      value = tNchan })
    end
    if not pinMapsEq(t_, s) then
      util.add(ops, { op = 'setPinMaps', trackKey = trackKey,
                      trackKind = t_.trackKind, trackId = t_.id,
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
                      trackKind = t_.trackKind, trackId = t_.id,
                      value = tOn, gain = tGain, offs = tOffs, nch = tNch })
    end
    if fresh or not sendsEq(t_.sends, s.sends) then
      util.add(ops, { op = 'setSends', trackKey = trackKey,
                      trackKind = t_.trackKind,
                      trackId = t_.id, sends = t_.sends })
    end
  end

  -- Drain/delete last so final reads of going-away tracks have run first.
  -- newTrack hosts get deleteTrack; undeletable hosts (source/master/scratch) need setFXChain [] to drain.
  for trackKey, s in pairs(snap) do
    local abandoned = not target[trackKey] or trackChanged[trackKey]
    if abandoned then
      if s.trackKind == 'newTrack' then
        util.add(ops, { op = 'deleteTrack', trackId = s.id, trackKey = trackKey })
      elseif #s.fx > 0 then
        util.add(ops, { op = 'setFXChain', trackKey = trackKey,
                        trackKind = s.trackKind, trackId = s.id, fx = {} })
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
      util.add(out, { fxId = fx.id, ident = fx.ident, absIdx = i - 1 })
    end
  end
  return out
end

-- Inline stamp/clear of minted/retracted fx guids onto userGraph (no mutate transaction):
-- stamping a guid never changes structure, so validation and wiringChanged are skipped.
local function stampOrigin(origin, guid)
  local nodes = userGraph.nodes
  if     origin.kind == 'node'       then nodes[origin.id].fxId             = guid
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
  if origin.kind == 'node'       then return nodes[origin.id] and nodes[origin.id].fxId end
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
      if n.fxId             then owners[n.fxId]             = { node = n, field = 'fxId' } end
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
  for _, c in ipairs(current) do liveGuids[c.fxId] = true end
  for _, t in ipairs(target) do
    if t.id and not liveGuids[t.id] then t.id = nil end
  end

  -- 1. Drop owned entries absent from target (right-to-left keeps absIdx valid).
  local targetGuids = {}
  for _, t in ipairs(target) do if t.id then targetGuids[t.id] = true end end
  for i = #current, 1, -1 do
    local guid = current[i].fxId
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
      util.add(current, { fxId = guid, ident = t.ident, absIdx = insertAt })
    end
  end

  -- 3. Permute the owned subsequence to target order via rm:assignFx{index};
  --    the contiguous-block invariant fixes each target slot at firstOwnedAbs+(d-1).
  current = ownedSubsequence(liveChain(), ownedGuids)
  local firstOwnedAbs = current[1] and current[1].absIdx
  for d = 1, #target do
    if current[d].fxId ~= target[d].id then
      local fromIdx
      for j = d + 1, #current do
        if current[j].fxId == target[d].id then fromIdx = j; break end
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
      if n.fxId              then s[n.fxId]              = true end
      if n.midiInBracketGuid   then s[n.midiInBracketGuid]   = true end
      if n.midiOutBracketGuid  then s[n.midiOutBracketGuid]  = true end
    end
    if n.mergeGuids then
      for _, g in pairs(n.mergeGuids) do s[g] = true end
    end
  end
  return s
end

--contract: walks ops in order inside one rm:transaction; setFXChain mints guids via rm:addFx
--contract: stamps them inline without firing wiringChanged; params/midi/pinMaps write through rm
function wm:applyOps(ops, label)
  ensureLoaded()
  rm:transaction(label or 'wiring: apply', function()
    local wiringTracks = cm:get('wiringTracks') or {}
    local ownedGuids   = ownedGuidsFrom(userGraph, cm:get('wiringOwnedFx'))
    local owners       = buildGuidOwners()
    local graphDirty   = false

    -- Master is absent from wiringTracks, so resolve its id via rm and note which
    -- trackKeys it hosts; send-destination resolution maps those to it below.
    local masterGuid = rm:masterId()
    local masterKeys = {}
    for _, op in ipairs(ops) do
      if op.trackKind == 'master' and op.trackKey then masterKeys[op.trackKey] = true end
    end

    -- Addressing: source is self-keyed (trackKey == id), so unmapped keys resolve to themselves;
    -- newTracks via wiringTracks, master via masterKeys. Scratch ops carry their guid in op.trackId.
    local function keyToId(trackKey)
      if masterKeys[trackKey] then return masterGuid end
      return wiringTracks[trackKey] or trackKey
    end
    local function resolveId(kind, id, trackKey)
      if id then return id end
      if kind == 'master' then return masterGuid end
      return keyToId(trackKey)
    end

    for _, op in ipairs(ops) do
      if op.op == 'createTrack' then
        wiringTracks[op.trackKey] = rm:addTrack({ name = 'continuum: ' .. op.trackKey })
      elseif op.op == 'deleteTrack' then
        rm:deleteTrack(op.trackId)
        wiringTracks[op.trackKey] = nil
      elseif op.op == 'setMainSend' then
        local id = resolveId(op.trackKind, op.trackId, op.trackKey)
        if id then
          local mainSend = { on = op.value, gain = op.gain or 1.0 }
          if op.value then
            mainSend.tgtOffset = op.offs or 0
            mainSend.nchan     = op.nch or 2
          end
          rm:assignTrack(id, { mainSend = mainSend })
        end
      elseif op.op == 'setNchan' then
        local id = resolveId(op.trackKind, op.trackId, op.trackKey)
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
        local guid = resolveId(op.trackKind, op.trackId, op.trackKey)
        if guid and reconcileFXChain(guid, op.fx, ownedGuids, owners) then
          graphDirty = true
        end
      elseif op.op == 'moveFxAcrossTracks' then
        local toId = resolveId(op.toTrackKind, op.toTrackGuid, op.toTrackKey)
        if toId then rm:assignFx(op.fxId, { track = toId }) end
      elseif op.op == 'setSends' then
        local id = resolveId(op.trackKind, op.trackId, op.trackKey)
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

    -- wiringTracks now reflects this pass's create/delete (scratch is rm-owned, not keyed here).
    cm:set('project', 'wiringTracks', wiringTracks)

    -- Mirror to scratch P_EXT inside the transaction so REAPER's undo captures the
    -- graph + addressing alongside FX/track ops; pollUndo watches lastScratchRaw.
    local scratch = rm:scratchTrack()
    cm:writeTrackKey(scratch, 'wiringGraph',   userGraph)
    cm:writeTrackKey(scratch, 'wiringOwnedFx', owned)
    cm:writeTrackKey(scratch, 'wiringTracks',  wiringTracks)
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

-- trackKey → opaque id for the live-poke path: a source is self-keyed, newTracks resolve
-- through wiringTracks, scratch + master through rm.
local function idForKey(trackKey)
  if trackKey == SCRATCH_KEY  then return rm:scratchId() end
  if trackKey == '__master__' then return rm:masterId() end
  return (cm:get('wiringTracks') or {})[trackKey] or trackKey
end

local function pokeGainTarget(target, gain)
  if target.kind == 'mergeCU' then
    local consumer = userGraph.nodes[target.consumerId]
    local guid = consumer and consumer.mergeGuids and consumer.mergeGuids[target.trackKey]
    if not guid then return false end
    rm:assignFx(guid, { params = { ['gain' .. target.slot] = gain } })
    return true
  elseif target.kind == 'mainSend' then
    local id = idForKey(target.cls)
    if not rm:reaperTrack(id) then return false end
    rm:assignTrack(id, { mainSend = { gain = gain } })
    return true
  elseif target.kind == 'send' then
    return rm:setSendGain(idForKey(target.from), idForKey(target.to), gain)
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
  rm:transaction('wiring: edge gain', function()
    edge.ops = edge.ops or {}
    edge.ops.gain = gain
    self:pokeEdgeGain(edgeIdx, gain)
    self:save()
    local scratch = rm:scratchTrack()
    cm:writeTrackKey(scratch, 'wiringGraph', userGraph)
    lastScratchRaw = cm:readTrackRaw(scratch)
  end)
  return true
end

--contract: delegates to rm:installedFx — raw REAPER "Type: Name (Author)" rows, memoised there
function wm:listInstalledFX()
  return rm:installedFx()
end

--contract: on scratch-chunk divergence, restores the cm project tier and fires load
-- see docs/wiringManager.md § pollUndo
function wm:pollUndo()
  local scratch = rm:scratchTrack()   -- handle from rm; the heartbeat lives in rm:pollUndo
  local raw = cm:readTrackRaw(scratch)
  if raw == lastScratchRaw then return end
  local mirrored = cm:readTrackKey(scratch, 'wiringGraph')
  if not mirrored then
    -- Fresh/empty scratch. If we had mirrored before, it was lost (manual delete or
    -- undo past creation) and rm re-minted it — reconcile to rebuild + re-park fx.
    if lastScratchRaw then
      lastScratchRaw = nil
      fire('wiringChanged', { kind = 'load' })
    end
    return
  end
  cm:set('project', 'wiringGraph',  mirrored)
  cm:set('project', 'wiringOwnedFx', cm:readTrackKey(scratch, 'wiringOwnedFx') or {})
  cm:set('project', 'wiringTracks',  cm:readTrackKey(scratch, 'wiringTracks') or {})
  setGraph(nil)
  lastScratchRaw = raw
  fire('wiringChanged', { kind = 'load' })
end

--contract: one reconcile pass — diff targetState vs snapshot, applyOps under the given undo label
function wm:reconcile(label)
  self:applyOps(self:diff(self:targetState(), self:snapshot()), label or 'wiring: reconcile')
end

--contract: idempotent; hooks wiringChanged so mutate/load reconciles + one immediate sync pass.
function wm:enableLive(label)
  if liveLabel then return end
  liveLabel = label or 'wiring: apply'
  self:subscribe('wiringChanged', function(payload)
    self:reconcile(payload.kind == 'load' and 'wiring: reconcile (load)' or liveLabel)
  end)
  self:reconcile('wiring: reconcile (enable)')
end

return wm
