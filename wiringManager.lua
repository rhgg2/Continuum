-- See docs/wiringManager.md for the model.
-- @noindex

--invariant: fx node id == its fxId (from instantiateFxOnScratch); source node id == track guid
--invariant: CU bridges arrive at the applier with nil fxId; reconcileFXChain mints them
--invariant: fxId is the stable bridge identity; snapshot/targetState match fxOrder by it
--invariant: wm deletes an FX instance only when its owning node or CU bridge leaves the graph
--invariant: trackKey changes are moves; TrackFX_CopyToTrack(is_move=true) preserves plugin state
--shape: snapshotPinMap = { ins={[port]={pair,...}}, outs={[port]={pair,...}} }
--shape: snapshotSend = { to=trackKey, kind='audio'|'midi', gain?=number, srcChan=int, dstChan=int, pos='preFx'|'preFader'|'postFader' }
--shape: snapshotFxOrigin = {kind='bracketIn'|'bracketOut',id=string}|{kind='merge',consumer=string,trackKey=trackKey}  -- CU bridges only; node fx carry their fxId as id
--shape: snapshotFxEntry = { id?=string, ident=string, name?=string, ins?=int, outs?=int, params?=table, origin?=snapshotFxOrigin, midi?={inBus=int,outBus=int,inDisabled=bool,outDisabled=bool}, pinMaps?=snapshotPinMap, busAware?=bool }  -- ins/outs are audio pair counts, for read; name feeds fxDisplay
--shape: wiringSnapshot = { [trackKey] = { trackKind='sourceTrack'|'newTrack'|'master'|'scratch', id?=string, parent?=guid, nchan?=int, hasMidiTake?=bool, mainSend={on=bool,gain?,tgtOffset?,nchan?}, fx=snapshotFxEntry[], sends=snapshotSend[] } }; rm:tracks() record + trackKey overlay (full chain, no ownership filter). see docs/wiringManager.md § wiringSnapshot.
--shape: wiringOp = { op='createTrack'|'deleteTrack'|'setFXChain'|'setMainSend'|'setSends'|'setNchan'|'setPinMaps'|'moveFxAcrossTracks', ... }
-- full-replace ops; see docs/wiringManager.md § wiringOp for per-op field detail.
--invariant: authoring via wm:mutate — validate+swap+fire; REAPER realises via reconcile.
--invariant: master is graph.nodes['master']; readGraph seeds it; DAG.validate enforces singleton.
--invariant: scratch is rm-owned (rm:scratchId/Track); wm parks fx there
--invariant: a newTrack carries its trackKey in its metadata; snapshot recovers addressing
--invariant: scratch hosts FX with no compile-graph track — disconnected or lowered-parked

local util = require 'util'
local DAG  = require 'DAG'
local fs   = require 'fs'

local rm = (...).rm

local wm = {}
local fire = util.installHooks(wm)

local userGraph = nil
local liveLabel = nil     -- non-nil iff live mode is on; carries the default undo label
local lastStateCount = nil -- REAPER project state count at our last write; syncExternal rereads when it moves
local newTrackIds = {}    -- { trackKey → id }; newTrack addressing, refreshed by snapshot/applyOps
local actualState = nil   -- in-memory model of REAPER's actual side (the diff's "actual"); local writes
                          -- keep it truthful, external writes nil it. see docs § actual-state model
local refreshStateTrack   -- assigned below; used by createSourceTrack/instantiateFxOnScratch (defined late)

local SCRATCH_KEY = '__scratch__'  -- scratch's logical trackKey; its guid is rm-owned
local CU_IDENT    = 'JS:Continuum Utility'
local CC_IDENT    = 'JS:Continuum CC'  -- paramAutomation's node — invisible to read/diff/apply
local AUTO_BUS    = 126                -- its CC-propagation bus; sends on it aren't wiring's

local function isJS(ident)
  return ident ~= nil and ident:sub(1, 3) == 'JS:'
end

----- Helpers

local compiledCache = nil  -- { graph, ctx, reach } | nil; cleared on every graph swap

local function setGraph(g) userGraph = g; compiledCache = nil end

-- Seeds userGraph from REAPER without a load; seeds actualState from read's snapshot too,
-- so the reconcile diffs against the model instead of paying a second rm:tracks() pass.
local function ensureLoaded()
  if not userGraph then
    local graph, snap = wm:read()
    setGraph(graph)
    actualState = snap
  end
end

-- Out-of-band REAPER writes call this to rebaseline the state count, so syncExternal won't reread our
-- own edit. The actualState model stays truthful via each write site, not by dropping it here.
local function markState()
  if reaper.GetProjectStateChangeCount then lastStateCount = reaper.GetProjectStateChangeCount(0) end
end

----- compiled-graph cache: one clone+compile per structural change, pulled by wv

local function adjacencies(g)
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
    local snap  = util.deepClone(userGraph)
    local ctx   = DAG.compile(snap)
    local reach = adjacencies(snap)
    compiledCache = { graph = snap, ctx = ctx, reach = reach }
  end
  return compiledCache
end

-- JSFX midi traits: busAware iff ext_midi_bus=1, recv/send iff midirecv/midisend present
-- (midisyx counts as send). Unreadable source → assume both recv and send.
local function parseJSFXMidiTraits(content)
  if not content then return { busAware = false, recv = true, send = true } end
  local traits = { busAware = false, recv = false, send = false }
  for line in content:gmatch('[^\r\n]+') do
    local code = line:gsub('//.*', '')
    if code:match('^%s*ext_midi_bus%s*=%s*1%f[%D]') then traits.busAware = true end
    if code:find('midirecv', 1, true) then traits.recv = true end
    if code:find('midisend', 1, true) or code:find('midisyx', 1, true) then
      traits.send = true
    end
  end
  return traits
end
local function parseJSFXBusAware(content)
  return parseJSFXMidiTraits(content).busAware
end

-- One disk read per ident, memoised for the session (a JSFX's midi traits are static).
local jsfxTraitsMemo = {}
local function jsfxTraits(ident)
  if not jsfxTraitsMemo[ident] then
    jsfxTraitsMemo[ident] = parseJSFXMidiTraits(wm:readJSFXContent(ident))
  end
  return jsfxTraitsMemo[ident]
end

-- Native fx keep the optimistic {1,1}; a JSFX's real midi surface comes from the scan.
local function fxMidiPorts(ident)
  if not isJS(ident) then return { ins = 1, outs = 1 } end
  local traits = jsfxTraits(ident)
  return { ins = traits.recv and 1 or 0, outs = traits.send and 1 or 0 }
end

----------- PUBLIC

--contract: reconstructs the graph from REAPER via read, fires wiringChanged{kind='load'}
function wm:load()
  setGraph(nil)
  ensureLoaded()
  fire('wiringChanged', { kind = 'load' })
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

local pruneSourceTags, mirrorBusTaps  -- defined below; decoration GC + tap write-through on mutates

--contract: clone-validate-swap; DAG.validate failure returns false,err with no state change;
--contract: on success swaps + fires wiringChanged{kind}; REAPER realises via reconcile
function wm:mutate(mutator, kind)
  ensureLoaded()
  local draft = util.deepClone(userGraph)
  mutator(draft)
  local err = DAG.validate(draft)
  if err then return false, err end
  setGraph(draft)
  if kind ~= 'move' then
    if kind ~= 'bus' then pruneSourceTags(userGraph) end
    mirrorBusTaps(userGraph)
  end
  fire('wiringChanged', { kind = kind or 'mutate' })
  return true
end

-- Decoration (pos, source tags) is not routing: persist to the rm meta store (fx GUID for fx-nodes,
-- track GUID for source/master) — orthogonal to the differ, so a decoration-only change skips reconcile.
local function persistNodeMeta(node, meta)
  if node.kind == 'fx' then
    if node.fxId then rm:assignFx(node.fxId, meta) end
  elseif node.kind == 'master' then
    local masterId = rm:masterId()
    if masterId then rm:assignTrack(masterId, meta) end
  elseif node.trackId then
    rm:assignTrack(node.trackId, meta)
  end
end

-- Source-tag offsets key by out-edge identity (type + consumer + port): one source
-- fans to many consumers, each tag its own; wiringView writes through this same key.
local function srcTagKey(e)
  return e.type .. '/' .. e.to .. '/' .. (e.toPort or 1)
end
wm.srcTagKey = srcTagKey

-- A deleted or retargeted out-edge orphans its source-tag key; recreating that edge
-- would otherwise resurrect the stale offset. Drop keys with no live edge, persist.
function pruneSourceTags(g)
  for id, node in pairs(g.nodes) do
    if node.tagPos then
      local live = {}
      for _, e in ipairs(g.edges) do
        if e.from == id then live[srcTagKey(e)] = true end
      end
      local dropped
      for key in pairs(node.tagPos) do
        if not live[key] then node.tagPos[key] = nil; dropped = true end
      end
      if dropped then
        if next(node.tagPos) == nil then node.tagPos = nil end
        persistNodeMeta(node, { tagPos = node.tagPos or util.REMOVE })
      end
    end
  end
end

--contract: buss move/resize — writes the bus node pos + persists pos & axial ext to the bus store
function wm:moveBus(id, pos, ext)
  local ok, err = self:mutate(function(g)
    local node = g.nodes[id]
    if node then node.pos.x, node.pos.y = pos.x, pos.y end
  end, 'move')
  if not ok then return false, err end
  rm:assignMeta('bus', id, { pos = { x = pos.x, y = pos.y }, ext = ext })
  return true
end

--contract: writes node pos per {[id]={x,y}} + persists busses to the bus store; unknown ids skipped
function wm:moveNodes(moves)
  local ok, err = self:mutate(function(g)
    for id, p in pairs(moves) do
      local node = g.nodes[id]
      if node then node.pos.x, node.pos.y = p.x, p.y end
    end
  end, 'move')
  if not ok then return false, err end
  for id, p in pairs(moves) do
    local node = userGraph.nodes[id]
    if node and node.kind == 'bus' then rm:assignMeta('bus', id, { pos = node.pos })
    elseif node then persistNodeMeta(node, { pos = node.pos })
    end
  end
  return true
end

-- The record's taps are a write-through mirror of the bus node's incident audio edges —
-- below 2×2 they are the persistence carrier that mints the edges back on read.
function mirrorBusTaps(g)
  local recs = rm:meta('bus')
  local taps = {}
  for busId in pairs(recs) do
    if g.nodes[busId] then taps[busId] = { ins = {}, outs = {} } end
  end
  for _, e in ipairs(g.edges) do
    if e.type == 'audio' then
      local gain = e.ops and e.ops.gain
      local intoBus, outOfBus = taps[e.to], taps[e.from]
      if intoBus  then util.add(intoBus.ins,   { node = e.from, port = e.fromPort or 1, gain = gain }) end
      if outOfBus then util.add(outOfBus.outs, { node = e.to,   port = e.toPort   or 1, gain = gain }) end
    end
  end
  for busId, mirror in pairs(taps) do
    local rec = recs[busId]
    if not (util.deepEq(rec.ins, mirror.ins) and util.deepEq(rec.outs, mirror.outs)) then
      rm:assignMeta('bus', busId, mirror)
    end
  end
end

--contract: persists pos to node.tagPos[key] (consumer-relative); source tag decoration only
function wm:setSourceTagPos(nodeId, key, pos)
  local ok = self:mutate(function(g)
    local node = g.nodes[nodeId]
    if node then
      node.tagPos = node.tagPos or {}
      node.tagPos[key] = pos
    end
  end, 'move')
  if not ok then return false end
  local node = userGraph.nodes[nodeId]
  if node then persistNodeMeta(node, { tagPos = node.tagPos }) end
  return true
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
wm.parseJSFXBusAware   = parseJSFXBusAware
wm.parseJSFXMidiTraits = parseJSFXMidiTraits

--contract: refuses JSFX whose desc declares ext_midi_bus=1; nil on accept, structured err on refuse
function wm:checkUserAddable(ident)
  if not (ident and ident:sub(1, 3) == 'JS:') then return nil end
  if jsfxTraits(ident).busAware then
    return { code = 'ext_midi_bus_user_fx', ident = ident }
  end
end

--contract: AddByName on scratch + keep; returns {fxId, ins, outs, inNames, outNames}
--contract: unknown ident → fxId=nil, ins=outs=0, empty name lists
function wm:instantiateFxOnScratch(ident)
  local fxId = rm:addFx(rm:scratchId(), { ident = ident })
  if not fxId then return { fxId = nil, ins = 0, outs = 0, inNames = {}, outNames = {} } end
  markState()
  -- minted on scratch out of band; splice the scratch entry back so the model stays truthful and the
  -- next reconcile's diff relocates the instance onto its real track.
  refreshStateTrack(rm:scratchId(), SCRATCH_KEY, 'scratch')
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
  for _, id in pairs(newTrackIds) do
    if id == guid then return true end
  end
  return false
end

--contract: { [trackId] = name } for every project track + master; one rm:trackLabels() pass
-- An unnamed track falls back to its REAPER number ("Track 3") — a label only, no real rename.
function wm:trackNames()
  local out = {}
  local tracks = rm:trackLabels()
  for _, tr in ipairs(tracks) do
    out[tr.id] = tr.name ~= '' and tr.name
      or (not tr.isMaster and tr.number and ('Track ' .. math.floor(tr.number)))
      or tr.name
  end
  return out
end

--contract: raw MediaTrack hosting the fx instance guid, or nil if the guid isn't live.
-- Resolve the host track directly via rm: reading the full fx record (rm:fx)
-- cost ~100ms/plugin (chunk + pin reads) and ran every frame via paramTargets.
function wm:fxTrack(fxId)
  return rm:fxTrack(fxId)
end

--contract: floats the FX window for the instance guid; false if the guid is no longer live
function wm:showFxWindow(fxId)
  return rm:showFx(fxId)
end

--contract: fx rows in sourceTrack's cone, flow order: midi-cone (generator=true) first, then audio
--contract: row = { fxGuid, name, trackGuid, generator? }; {} when sourceTrack isn't a graph node
function wm:paramTargets(sourceTrack)
  local sourceId = sourceTrack and reaper.GetTrackGUID(sourceTrack)
  local g = self:viewGraph()
  if not (sourceId and g.nodes[sourceId]) then return {} end

  local forward, forwardMidi = {}, {}
  for _, e in ipairs(g.edges) do
    util.bucket(forward, e.from, e.to)
    if e.type == 'midi' then util.bucket(forwardMidi, e.from, e.to) end
  end

  local function reachable(adj)
    local seen, queue, i = { [sourceId] = true }, { sourceId }, 1
    while queue[i] do
      for _, to in ipairs(adj[queue[i]] or {}) do
        if not seen[to] then seen[to] = true; util.add(queue, to) end
      end
      i = i + 1
    end
    return seen
  end
  local cone, midiCone = reachable(forward), reachable(forwardMidi)

  -- Kahn restricted to the cone for flow order; sorted ready keeps parallel branches deterministic.
  -- Feedback-quarantined members never drain to indegree 0 and drop out — they aren't bindable.
  local indeg = {}
  for id in pairs(cone) do indeg[id] = 0 end
  for _, e in ipairs(g.edges) do
    if cone[e.from] and cone[e.to] then indeg[e.to] = indeg[e.to] + 1 end
  end
  local ready, order = {}, {}
  for id in pairs(cone) do if indeg[id] == 0 then util.add(ready, id) end end
  while #ready > 0 do
    table.sort(ready)
    local id = table.remove(ready, 1)
    util.add(order, id)
    for _, to in ipairs(forward[id] or {}) do
      if cone[to] then
        indeg[to] = indeg[to] - 1
        if indeg[to] == 0 then util.add(ready, to) end
      end
    end
  end

  local generators, audioFx = {}, {}
  for _, id in ipairs(order) do
    local node = g.nodes[id]
    if node.kind == 'fx' then
      local track = self:fxTrack(id)
      if track then
        local row = { fxGuid = id, name = node.fxDisplay or node.fxIdent,
                      trackGuid = reaper.GetTrackGUID(track) }
        if midiCone[id] then row.generator = true; util.add(generators, row)
        else util.add(audioFx, row) end
      end
    end
  end
  for _, row in ipairs(audioFx) do util.add(generators, row) end
  return generators
end

--contract: appends a source track via rm and returns its id; called outside mutate.
-- snapshot derives source identity from graph source nodes, not a tag. see docs/wiringManager.md § createSourceTrack
function wm:createSourceTrack(opts)
  local id = rm:addTrack{ name = opts and opts.name, defaults = true }
  markState()
  refreshStateTrack(id, id, 'sourceTrack')  -- source trackKey == its guid; keep the model truthful
  return id
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
    if not io.fxId then ok, err = false, { code = 'fx_instantiate_failed', ident = fx.ident }; return end
    local midiPorts  = fxMidiPorts(fx.ident)
    local autoSource = io.ins == 0 and midiPorts.ins > 0
                       and not (opts and opts.autoSource == false)
    local sourceGuid = autoSource and self:createSourceTrack{ name = display } or nil
    ok, err = self:mutate(function(g)
      newId = io.fxId
      g.nodes[io.fxId] = {
        kind      = 'fx',
        pos       = { x = x, y = y },
        fxIdent   = fx.ident,
        fxDisplay = display,
        fxId    = io.fxId,
        busAware  = false,
        ports     = {
          audio = { ins      = io.ins,     outs     = io.outs,
                    inNames  = io.inNames, outNames = io.outNames },
          midi  = midiPorts,
        },
      }
      if sourceGuid then
        local sp = (opts and opts.sourcePos) or { x = x - 140, y = y }
        g.nodes[sourceGuid] = {
          kind        = 'source',
          pos         = { x = sp.x, y = sp.y },
          trackId   = sourceGuid,
          displayName = display,
          ports       = { audio = { ins = 0, outs = 1 },
                          midi  = { ins = 0, outs = 1 } },
        }
        util.add(g.edges, { type = 'midi', from = sourceGuid, to = io.fxId })
      end
    end)
    if ok then
      local fxNode = userGraph.nodes[io.fxId]
      persistNodeMeta(fxNode, { pos = fxNode.pos })
      if sourceGuid then
        local srcNode = userGraph.nodes[sourceGuid]
        persistNodeMeta(srcNode, { pos = srcNode.pos })
      end
    end
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
  markState()
  if actualState and node.trackId then actualState[node.trackId] = nil end
  return true
end

--contract: deletes a buss node + incident edges and clears its decoration record, in one Undo block
function wm:deleteBus(nodeId)
  ensureLoaded()
  local node = userGraph.nodes[nodeId]
  if not node or node.kind ~= 'bus' then return false end
  rm:transaction('wiring: delete buss', function()
    self:mutate(function(g)
      g.nodes[nodeId] = nil
      local kept = {}
      for _, e in ipairs(g.edges) do
        if e.from ~= nodeId and e.to ~= nodeId then util.add(kept, e) end
      end
      g.edges = kept
    end)
    rm:assignMeta('bus', nodeId, nil)
  end)
  markState()
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
      newId = guid
      local pos = opts.pos or { x = 0, y = 0 }
      g.nodes[guid] = {
        kind        = 'source',
        pos         = { x = pos.x, y = pos.y },
        trackId   = guid,
        displayName = opts.name,
        ports       = { audio = { ins = 0, outs = 1 },
                        midi  = { ins = 0, outs = 1 } },
      }
    end)
    if ok then
      local node = userGraph.nodes[guid]
      persistNodeMeta(node, { pos = node.pos })
    end
  end)
  if not ok then return nil, err end
  return newId
end

-- Buss ids are synthetic and stable for the buss's life: nodes and records share the
-- 'bus-N' space, so a fresh id collides with neither carrier.
local function nextBusId(g)
  local maxN = 0
  local function scan(id)
    local n = tostring(id):match('^bus%-(%d+)$')
    if n then maxN = math.max(maxN, tonumber(n)) end
  end
  for id in pairs(g.nodes) do scan(id) end
  for id in pairs(rm:meta('bus')) do scan(id) end
  return 'bus-' .. (maxN + 1)
end

--contract: mints a placed, unwired buss node + its decoration record; orient defaults 'V'
function wm:addBusNode(pos, orient)
  ensureLoaded()
  orient = orient or 'V'
  local newId, ok, err
  rm:transaction('wiring: add buss', function()
    ok, err = self:mutate(function(g)
      newId = nextBusId(g)
      g.nodes[newId] = {
        kind   = 'bus',
        pos    = { x = pos.x, y = pos.y },
        orient = orient,
        ports  = { audio = { ins = 1, outs = 1 }, midi = { ins = 0, outs = 0 } },
      }
    end, 'bus')
    if ok then rm:assignMeta('bus', newId, { pos = { x = pos.x, y = pos.y }, orient = orient,
                                             ins = {}, outs = {} }) end
  end)
  if not ok then return nil, err end
  return newId
end

--contract: flips a buss's orientation V↔H on node + decoration record; returns true or nil+err
function wm:rotateBus(id)
  local flipped
  local ok, err = self:mutate(function(g)
    local node = g.nodes[id]
    if node and node.kind == 'bus' then
      flipped = node.orient == 'H' and 'V' or 'H'
      node.orient = flipped
    end
  end, 'move')
  if not ok then return nil, err end
  if flipped then rm:assignMeta('bus', id, { orient = flipped }) end
  return true
end

--contract: mints a buss node mid-wire: re-points the (node,port,dir) edge ends through it +
--contract: a unity trunk edge — audio-identical under the splice; returns id, or nil+err
function wm:insertBus(spec)
  ensureLoaded()
  local newId = nextBusId(userGraph)
  local ok, err
  rm:transaction('wiring: add buss', function()
    -- record first, so the mutate's tap mirror finds it
    rm:assignMeta('bus', newId, { pos = { x = spec.pos.x, y = spec.pos.y },
                                  orient = spec.orient or 'V' })
    ok, err = self:mutate(function(g)
      g.nodes[newId] = {
        kind   = 'bus',
        pos    = { x = spec.pos.x, y = spec.pos.y },
        orient = spec.orient or 'V',
        ports  = { audio = { ins = 1, outs = 1 }, midi = { ins = 0, outs = 0 } },
      }
      local atIn = spec.dir == 'in'
      for _, e in ipairs(g.edges) do
        if e.type == 'audio' then
          if atIn and e.to == spec.node and (e.toPort or 1) == spec.port then
            e.to, e.toPort = newId, 1
          elseif not atIn and e.from == spec.node and (e.fromPort or 1) == spec.port then
            e.from, e.fromPort = newId, 1
          end
        end
      end
      if atIn then
        util.add(g.edges, { type = 'audio', from = newId, fromPort = 1,
                            to = spec.node, toPort = spec.port })
      else
        util.add(g.edges, { type = 'audio', from = spec.node, fromPort = spec.port,
                            to = newId, toPort = 1 })
      end
    end)
    if not ok then rm:assignMeta('bus', newId, nil) end
  end)
  if not ok then return nil, err end
  return newId
end

--shape: busRecord = { pos={x,y}, orient='V'|'H', ext={lo,hi}?, ins={{node,port,gain?},…}, outs={…}, trackId? } — ext = hand-sized bar span (axial offsets from pos); taps mirror the node's edges; trackId iff matrix
--contract: deep copy of the 'bus' meta store: { [busId] = busRecord }
function wm:busRecords()
  return util.deepClone(rm:meta('bus'))
end

-- True iff `graph` has any edge with type='midi' leaving `nodeId`.
-- Drives target.midiOut for non-JS fx in projectEntry.
local function nodeHasMidiOut(graph, nodeId)
  for _, e in ipairs(graph.edges) do
    if e.from == nodeId and e.type == 'midi' then return true end
  end
  return false
end

-- True iff `graph` has any edge with type='midi' entering `nodeId`. Drives midi
-- inDisabled: an fx with no midi-in must not inherit source bus 0 (the phantom).
local function nodeHasMidiIn(graph, nodeId)
  for _, e in ipairs(graph.edges) do
    if e.to == nodeId and e.type == 'midi' then return true end
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
             to   = math.floor(params.to + 0.5),
             retain = params.retain and math.floor(params.retain + 0.5) or 1 }
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

-- One rm fx record → snapshotFxEntry: CU bridges carry decoded params, JSFX a busAware flag;
-- native fx carry midi routing. fxId is the identity the differ matches fxOrder by.
local function snapFx(fx)
  local entry = { id = fx.id, ident = fx.ident, name = fx.name, ins = fx.ins, outs = fx.outs }
  if fx.pinMaps and (next(fx.pinMaps.ins) or next(fx.pinMaps.outs)) then
    entry.pinMaps = fx.pinMaps
  end
  if fx.ident == CU_IDENT then
    local params = rm:params(fx.id)
    if params then entry.params = flattenCuParams(readCuParams(params)) end
  elseif isJS(fx.ident) then
    if jsfxTraits(fx.ident).busAware then entry.busAware = true end
  else
    entry.midi = fx.midi
  end
  return entry
end

-- Every fx on a managed track is wm's (whole-track-set quarantine): surface the full chain so the
-- differ's full-replace can prune — except paramAutomation's CC node, hidden from read and diff.
local function snapFxList(fxList)
  local out = {}
  for _, fx in ipairs(fxList) do
    if fx.ident ~= CC_IDENT then util.add(out, snapFx(fx)) end
  end
  return out
end

-- Sends to a managed dst only, re-keyed .to guid→trackKey via the caller's map; midi gain dropped
-- (only audio sends carry a written D_VOL). paramAutomation's bus-126 sends aren't wiring's: hidden.
local function ownedSends(sendList, keyByGuid)
  local out = {}
  for _, s in ipairs(sendList) do
    local key = keyByGuid[s.to]
    local automation = s.kind == 'midi' and s.srcChan == AUTO_BUS
    if key and not automation then
      util.add(out, { to = key, kind = s.kind,
                      gain = s.kind == 'audio' and s.gain or nil,
                      srcChan = s.srcChan, dstChan = s.dstChan, pos = s.pos })
    end
  end
  return out
end

-- One rm track record → wiringSnapshot entry. Scratch is forced main-off/sendless (it only parks
-- fx); other tracks re-key their sends via keyByGuid. Shared by snapshot's loop and state refreshes.
local function stateEntry(rec, trackKey, kind, keyByGuid)
  local isScratch = kind == 'scratch'
  return {
    trackKind = kind,
    id        = rec.id,
    parent    = rec.parent,
    nchan     = rec.nchan,
    hasMidiTake = rec.hasMidiTake,
    mainSend  = isScratch and { on = false } or rec.mainSend,
    fx        = snapFxList(rec.fx),
    sends     = isScratch and {} or ownedSends(rec.sends, keyByGuid),
  }
end

-- guid→trackKey over the current model, for re-keying a refreshed track's sends.
local function keyByGuidFromState()
  local out = {}
  if actualState then
    for key, entry in pairs(actualState) do
      if entry.id then out[entry.id] = key end
    end
  end
  return out
end

-- Re-read one live track into the model after a local write (cheap: one track, not the whole
-- project). No-op when the model is cold — the next reconcile takes a full snapshot.
function refreshStateTrack(id, trackKey, kind)
  if not actualState then return end
  local rec = rm:track(id)
  if rec then actualState[trackKey] = stateEntry(rec, trackKey, kind, keyByGuidFromState()) end
end

--contract: rm:tracks() re-keyed by trackKey, send dsts remapped guid→trackKey; every fx on a
-- managed track surfaces (full chain — adoption is free, no ownership filter). Read-only.
function wm:snapshot(tracks)
  -- No ensureLoaded: read() calls snapshot, recursion guard.

  -- (id → trackKey/trackKind). newTracks carry their own trackKey on meta (recovered in the
  -- pre-pass below); scratch is rm-owned; sources are inferred structurally — design § What read does.
  local keyByGuid, kindByKey = {}, {}
  local scratch = rm:scratchId()
  keyByGuid[scratch], kindByKey[SCRATCH_KEY] = SCRATCH_KEY, 'scratch'

  local trackList = tracks or rm:tracks()
  -- Pre-pass: assign trackKeys before building entries so send dsts resolve regardless of order.
  -- A newTrack carries its own meta trackKey; refresh the addressing map idForKey reads.
  local nt = {}
  for _, tr in ipairs(trackList) do
    if tr.trackKey and not keyByGuid[tr.id] then
      keyByGuid[tr.id], kindByKey[tr.trackKey] = tr.trackKey, 'newTrack'
      nt[tr.trackKey] = tr.id
    end
  end
  newTrackIds = nt
  -- Everything else managed (non-scratch/newTrack/master) is a source; read mints a source
  -- node only without incoming sends.
  for _, tr in ipairs(trackList) do
    if not keyByGuid[tr.id] and not tr.isMaster then
      keyByGuid[tr.id], kindByKey[tr.id] = tr.id, 'sourceTrack'
    end
  end

  local snap = {}
  for _, tr in ipairs(trackList) do
    local trackKey = keyByGuid[tr.id]
    if trackKey then
      snap[trackKey] = stateEntry(tr, trackKey, kindByKey[trackKey], keyByGuid)
    elseif tr.isMaster then
      -- Master is a singleton with no ext-state tag; surface it only when it
      -- hosts fx, so wm:diff can see transitions on/off master.
      local masterFx = snapFxList(tr.fx)
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
        entry.ins, entry.outs = node.ports.audio.ins, node.ports.audio.outs
        if not isJS(node.fxIdent) then
          local bus = spec.fxMidiBus and spec.fxMidiBus[id]
          entry.midi = { inBus = bus and bus.inBus or 0, outBus = bus and bus.outBus or 0,
                         inDisabled  = not nodeHasMidiIn(userGraph, id),
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

-- Pass 3c: audio + CU collapse + gain + full midi-bus walk (fan-in, merge, brackets), then
-- component classification (bus-aware + feedback quarantine). Node ids are rm ids. Pure.
local MASTER_KEY = '__master__'
--invariant: folder parent reads as a source summing children; child midi takes wire into the parent
local function readGraph(snap, busMeta)
  -- trackId-flagged records key the matrix mint by the snapshot entry's guid.
  local busByTrack = {}
  for busId, rec in pairs(busMeta or {}) do
    if rec.trackId then busByTrack[rec.trackId] = busId end
  end
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

  -- BusRoute CU mode 0: from->0, 0->to; -1 is "no bus"; retain=0 moves rather than copies.
  -- Wrapped JSFX reads bus 0, so brackets are midi-transparent on read.
  local function busRouteMidi(live, cu)
    local from, to = cu.from, cu.to
    if from == 0 then return live end  -- degenerate: bus-0 events re-land on bus 0
    local out = {}
    for bus, list in pairs(live) do out[bus] = list end
    out[0] = from >= 0 and live[from] or nil
    if from > 0 and (cu.retain == 0 or from == to) then out[from] = nil end
    if to >= 0 then
      if to == from then
        out[to] = live[0]
      else
        local joined = {}
        for _, r in ipairs(live[0] or {}) do util.add(joined, r) end
        for _, r in ipairs(live[to] or {}) do util.add(joined, r) end
        out[to] = #joined > 0 and joined or nil
      end
    end
    return out
  end

  -- Incoming routing per track: explicit audio sends + the parent send (channels 1-2 => pair 1).
  -- A foldered child main-sends into its parent (folderSinks), not master; send is atomic — audio + all-bus midi.
  local incoming, folderSinks = {}, {}
  local function addIncoming(toKey, inc)
    incoming[toKey] = incoming[toKey] or {}
    util.add(incoming[toKey], inc)
  end
  for fromKey, entry in pairs(snap) do
    for _, s in ipairs(entry.sends or {}) do
      if s.kind == 'audio' then
        addIncoming(s.to, { from = fromKey, srcPair = s.srcChan // 2 + 1,
                            dstPair = s.dstChan // 2 + 1, gain = s.gain,
                            preFx = s.pos == 'preFx' or nil })
      elseif s.kind == 'midi' then
        addIncoming(s.to, { from = fromKey, midi = true,
                            srcBus = s.srcChan, dstBus = s.dstChan,
                            preFx = s.pos == 'preFx' or nil })
      end
    end
    if entry.mainSend and entry.mainSend.on then
      if entry.parent then
        folderSinks[entry.parent] = true
        addIncoming(entry.parent, { from = fromKey, parentSend = true, srcPair = 1,
                                    dstPair = (entry.mainSend.tgtOffset or 0) // 2 + 1,
                                    gain = entry.mainSend.gain })
      else
        addIncoming(MASTER_KEY, { from = fromKey, toMaster = true, srcPair = 1,
                                  dstPair = (entry.mainSend.tgtOffset or 0) // 2 + 1,
                                  gain = entry.mainSend.gain })
      end
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
    local cyclic = {}
    for _, k in ipairs(keys) do if not placed[k] then util.add(cyclic, k) end end
    table.sort(cyclic)
    return out, cyclic
  end

  local tails = {}  -- trackKey -> { audio={[pair]=ref[]}, midi={[bus]=ref[]} }; ref = { node, port?, gain? }
  local preTails = {}  -- pre-fx tap (track input) for preFx sends; source raw on pair 1 / bus 0
  local feedbackSeeds = {}  -- node ids on cyclic (Kahn-leftover) tracks; classify tags their component
  local function walkTrack(trackKey, entry, isCyclic)
    local liveAudio, liveMidi = {}, {}
    local function feed(pair, ref)
      liveAudio[pair] = liveAudio[pair] or {}
      util.add(liveAudio[pair], ref)
    end
    local function feedMidi(bus, ref)
      liveMidi[bus] = liveMidi[bus] or {}
      util.add(liveMidi[bus], ref)
    end

    local busId = entry.id and busByTrack[entry.id] or nil
    local inc = incoming[trackKey]
    if inc then
      for _, i in ipairs(inc) do
        local tail = (i.preFx and preTails or tails)[i.from] or {}
        if i.midi then
          for _, ref in ipairs((tail.midi or {})[i.srcBus] or {}) do feedMidi(i.dstBus, ref) end
        else
          for _, ref in ipairs((tail.audio or {})[i.srcPair] or {}) do feed(i.dstPair, foldGain(ref, i.gain)) end
          if i.parentSend then
            -- The parent send is atomic: all-bus midi rides the pipe identity-mapped, so a
            -- parent fx listening on bus n meets the child's bus-n producer directly.
            for bus, refs in pairs(tail.midi or {}) do
              for _, ref in ipairs(refs) do feedMidi(bus, ref) end
            end
          end
        end
      end
    end

    if folderSinks[trackKey] then
      -- Folder parent: audio sums onto pair 1; midi splits by bus (see the bus-0/bus-N comment below).
      local sid = entry.id
      nodes[sid] = { kind = 'source', trackId = entry.id, parent = entry.parent,
                     ports = { audio = { ins = 1, outs = 1 }, midi = { ins = 1, outs = 1 } } }
      if isCyclic then feedbackSeeds[sid] = true end
      for _, refs in pairs(liveAudio) do
        for _, ref in ipairs(refs) do addAudioEdge(ref, sid, 1) end
      end
      liveAudio = {}
      feed(1, { node = sid, port = 1 })
      -- Bus 0 aggregates into the node (the take merge, re-emitted on bus 0); buses >=1 are distinct
      -- streams passed through identity-mapped — a parent/ancestor fx edges direct, unread buses none.
      local childMidi = liveMidi
      liveMidi = {}
      for _, ref in ipairs(childMidi[0] or {}) do
        util.add(edges, { type = 'midi', from = ref.node, to = sid })
      end
      for bus, refs in pairs(childMidi) do
        if bus ~= 0 then
          for _, ref in ipairs(refs) do feedMidi(bus, ref) end
        end
      end
      if entry.hasMidiTake or childMidi[0] then feedMidi(0, { node = sid }) end
    elseif not inc and not busId and entry.trackKind ~= 'master' and entry.trackKind ~= 'scratch' then
      -- No inputs => a source (scratch excepted: a known fx bin, walked as floating islands).
      -- Emits audio on pair 1; midi on bus 0 only with a midi take (the out stays wirable).
      local sid = entry.id
      nodes[sid] = { kind = 'source', trackId = entry.id, parent = entry.parent,
                     ports = { audio = { ins = 0, outs = 1 }, midi = { ins = 0, outs = 1 } } }
      if isCyclic then feedbackSeeds[sid] = true end
      feed(1, { node = sid, port = 1 })
      if entry.hasMidiTake then feedMidi(0, { node = sid }) end
    end

    -- A flagged track realizes a buss: accumulated inputs become its in-edges, the
    -- summed tail (pair 1) becomes the buss ref. MIDI does not pass through.
    if busId then
      nodes[busId] = { kind = 'bus',
                       ports = { audio = { ins = 1, outs = 1 }, midi = { ins = 0, outs = 0 } } }
      if isCyclic then feedbackSeeds[busId] = true end
      for _, refs in pairs(liveAudio) do
        for _, ref in ipairs(refs) do addAudioEdge(ref, busId, 1) end
      end
      liveAudio = { { { node = busId, port = 1 } } }
      liveMidi  = {}
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
      -- MIDI: merge unions masked input buses onto outBus; busRoute remaps from/0/to.
      if cu.mode == 'merge' then mergeMidi(liveMidi, cu)
      else liveMidi = busRouteMidi(liveMidi, cu) end
    end

    -- Snapshot the track input (pre-fx) so a preFx source send taps the raw signal,
    -- not the post-fx tail an on-track fx would otherwise leave on the pair.
    local preAudio, preMidi = {}, {}
    for pair, list in pairs(liveAudio) do preAudio[pair] = list end
    for bus,  list in pairs(liveMidi)  do preMidi[bus]   = list end
    preTails[trackKey] = { audio = preAudio, midi = preMidi }

    for _, fxe in ipairs(entry.fx or {}) do
      if fxe.ident == CU_IDENT then
        collapseCu(fxe)
      else
        local id = fxe.id
        nodes[id] = { kind = 'fx', fxIdent = fxe.ident, fxId = id, busAware = fxe.busAware or nil,
                      fxDisplay = fxe.name and shortFxName(fxe.name) or nil,
                      ports = { audio = { ins = fxe.ins or 0, outs = fxe.outs or 0 },
                                midi = fxMidiPorts(fxe.ident) } }
        if isCyclic then feedbackSeeds[id] = true end
        local pinMaps = fxe.pinMaps or { ins = {}, outs = {} }
        for port, prs in pairs(pinMaps.ins or {}) do
          for _, pair in ipairs(prs) do
            for _, ref in ipairs(liveAudio[pair] or {}) do addAudioEdge(ref, id, port) end
          end
        end
        -- MIDI: native fx read stored routing; a JSFX's surface is the midirecv/midisend
        -- scan — no recv: deaf (bus 0 passes), no send: drains bus 0 without re-emitting.
        local m = fxe.midi
        local inBus, outBus = m and m.inBus or 0, m and m.outBus or 0
        local hears  = m and not m.inDisabled
        local drives = m and not m.outDisabled
        if not m then
          local traits = isJS(fxe.ident) and jsfxTraits(fxe.ident)
                         or { recv = true, send = true }
          hears, drives = traits.recv, traits.send
        end
        if hears then
          for _, ref in ipairs(liveMidi[inBus] or {}) do
            util.add(edges, { type = 'midi', from = ref.node, to = id })
          end
        end
        for port, prs in pairs(pinMaps.outs or {}) do
          for _, pair in ipairs(prs) do liveAudio[pair] = { { node = id, port = port } } end
        end
        if drives then liveMidi[outBus] = { { node = id } }
        elseif hears or m then liveMidi[outBus] = nil end
      end
    end

    tails[trackKey] = { audio = liveAudio, midi = liveMidi }
  end

  local placedOrder, cyclicOrder = nonMasterOrder()
  for _, k in ipairs(placedOrder) do walkTrack(k, snap[k]) end
  -- Feedback-loop tracks (Kahn leftovers) are walked too so their nodes surface for the view;
  -- their emitted forward edges keep the component connected and feedbackSeeds tags it.
  for _, k in ipairs(cyclicOrder) do walkTrack(k, snap[k], true) end
  -- Floating islands live on scratch: walk it as a pure fx bin (no source rule), recovering
  -- its fx + intra edges. design/wiring-implicit-graph.md § floating islands (option 3).
  if snap[SCRATCH_KEY] then walkTrack(SCRATCH_KEY, snap[SCRATCH_KEY]) end
  walkTrack(MASTER_KEY, snap[MASTER_KEY] or { trackKind = 'master', fx = {} })

  -- The master node is the master track's output (pair 1).
  for _, ref in ipairs((tails[MASTER_KEY].audio or {})[1] or {}) do addAudioEdge(ref, 'master', nil) end

  -- Sub-threshold busses have no carrier track: the record's taps mint the node + its
  -- edges, and each in×out crossing consumes the direct send the splice realized it as.
  local mintIds = {}
  for busId in pairs(busMeta or {}) do
    if not nodes[busId] then util.add(mintIds, busId) end
  end
  if #mintIds > 0 then
    table.sort(mintIds)  -- deterministic minted-edge order
    local byKey = {}
    for idx, e in ipairs(edges) do
      if e.type == 'audio' then
        util.bucket(byKey, util.key(e.from, e.fromPort or 1, e.to, e.toPort or 1), idx)
      end
    end
    local minted = {}
    for _, busId in ipairs(mintIds) do
      minted[busId] = true
      nodes[busId] = { kind = 'bus',
                       ports = { audio = { ins = 1, outs = 1 }, midi = { ins = 0, outs = 0 } } }
    end
    -- Taps whose node vanished are skipped here and GC'd at the next mutate's mirror.
    local function liveTaps(list)
      local out = {}
      for _, tap in ipairs(list or {}) do
        if nodes[tap.node] then util.add(out, tap) end
      end
      return out
    end
    local consumed, busTaps = {}, {}
    for _, busId in ipairs(mintIds) do
      local rec = busMeta[busId]
      local ins, outs = liveTaps(rec.ins), liveTaps(rec.outs)
      busTaps[busId] = { ins = ins, outs = outs }
      for _, tapIn in ipairs(ins) do
        for _, tapOut in ipairs(outs) do
          local pool = byKey[util.key(tapIn.node, tapIn.port or 1, tapOut.node, tapOut.port or 1)]
          for _, idx in ipairs(pool or {}) do
            if not consumed[idx] then consumed[idx] = true; break end
          end
        end
      end
    end
    if next(consumed) then
      local kept = {}
      for idx, e in ipairs(edges) do
        if not consumed[idx] then util.add(kept, e) end
      end
      edges = kept
    end
    for _, busId in ipairs(mintIds) do
      for _, tap in ipairs(busTaps[busId].ins) do
        addAudioEdge({ node = tap.node, port = tap.port, gain = tap.gain }, busId, 1)
      end
      for _, tap in ipairs(busTaps[busId].outs) do
        -- an out-tap onto another minted buss is that buss's in-tap: minted once, there
        if not minted[tap.node] then
          addAudioEdge({ node = busId, port = 1, gain = tap.gain }, tap.node, tap.port)
        end
      end
    end
  end

  local graph = { nodes = nodes, edges = edges }
  graph.components = DAG.classify(graph, feedbackSeeds)
  return graph
end

wm.readGraph = readGraph  -- exposed for unit tests; wm:read drives it from the live snapshot

-- Decoration is orthogonal to routing: positions live in the rm meta store, never the routing
-- snapshot. Stamp them back after the pure read; absent meta (never-placed) defaults to origin.
local function stampDecoration(g, tracks, busMeta)
  local trackRec, fxRec = {}, {}
  for _, tr in ipairs(tracks) do
    trackRec[tr.id] = tr
    for _, f in ipairs(tr.fx) do fxRec[f.id] = f end
  end
  local masterId = rm:masterId()
  for id, node in pairs(g.nodes) do
    if node.kind == 'bus' then
      local rec = busMeta and busMeta[id]
      node.pos    = (rec and rec.pos) and { x = rec.pos.x, y = rec.pos.y } or { x = 0, y = 0 }
      node.orient = rec and rec.orient or 'V'
    else
      local rec
      if     node.kind == 'fx'     then rec = fxRec[id]
      elseif node.kind == 'master' then rec = masterId and trackRec[masterId]
      else                              rec = trackRec[id] end
      node.pos    = (rec and rec.pos) and { x = rec.pos.x, y = rec.pos.y } or { x = 0, y = 0 }
      node.tagPos = rec and rec.tagPos and util.deepClone(rec.tagPos) or nil
    end
  end
end

--contract: reconstructs the user graph from REAPER routing; node ids are rm ids
--contract: second return is the wiringSnapshot it consumed — callers seed the actual-state model
-- (3c: + component classification — bus-aware + feedback quarantine; decoration stamped from meta)
function wm:read()
  rm:scratchId()  -- ensure scratch before listing, so the snapshot matches a fresh one
  local tracks  = rm:tracks()
  local snap    = self:snapshot(tracks)
  local busMeta = rm:meta('bus')
  local g = readGraph(snap, busMeta)
  stampDecoration(g, tracks, busMeta)
  return g, snap
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

-- Inline stamp/clear of CU-bridge guids onto userGraph: stamping never changes structure,
-- so it skips the mutate transaction. Node fx already carry their guid, so only bridges stamp.
local function stampOrigin(origin, guid)
  local nodes = userGraph.nodes
  if     origin.kind == 'bracketIn'  then nodes[origin.id].midiInBracketGuid  = guid
  elseif origin.kind == 'bracketOut' then nodes[origin.id].midiOutBracketGuid = guid
  elseif origin.kind == 'merge' then
    local n = nodes[origin.consumer]
    n.mergeGuids = n.mergeGuids or {}
    n.mergeGuids[origin.trackKey] = guid
  end
end

-- Read-side inverse of stampOrigin: the guid a CU-bridge origin resolves to once
-- setFXChain has stamped it, so setPinMaps can address an id-less entry.
local function originGuid(origin)
  local nodes = userGraph.nodes
  if origin.kind == 'bracketIn'  then return nodes[origin.id] and nodes[origin.id].midiInBracketGuid end
  if origin.kind == 'bracketOut' then return nodes[origin.id] and nodes[origin.id].midiOutBracketGuid end
  if origin.kind == 'merge' then
    local n = nodes[origin.consumer]
    return n and n.mergeGuids and n.mergeGuids[origin.trackKey]
  end
end

-- guid → the user-graph field carrying it, so a retracted CU bridge clears its stamp.
local function buildGuidOwners()
  local owners = {}
  for _, n in pairs(userGraph.nodes) do
    if n.kind == 'fx' then
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

-- Full-replace `trackId`'s FX chain to `target` via rm. Whole-track-set quarantine means the
-- live chain is wm's working set: live fx absent from target are deleted, id-less bridges minted.
local function reconcileFXChain(trackId, target, owners)
  local dirty = false
  -- Structural reasoning needs only ordered live fx ids — no chunk read. paramAutomation's
  -- head-pinned CC node is filtered out; `pinned` offsets absolute indices past it below.
  local pinned = 0
  local function liveChain()
    local ids, identById = rm:fxIds(trackId)
    local out = {}
    pinned = 0
    for _, fxId in ipairs(ids or {}) do
      if identById[fxId] == CC_IDENT then pinned = pinned + 1
      else util.add(out, fxId) end
    end
    return out
  end
  local chain = liveChain()

  -- Stale-id sweep: a target entry whose id isn't live in REAPER (a retracted CU
  -- bridge, reload, drift) drops to nil so it re-materialises and re-stamps.
  local liveIds = {}
  for _, fxId in ipairs(chain) do liveIds[fxId] = true end
  for _, t in ipairs(target) do
    if t.id and not liveIds[t.id] then t.id = nil end
  end

  -- 1. Delete live fx absent from target (right-to-left keeps indices valid).
  local targetIds = {}
  for _, t in ipairs(target) do if t.id then targetIds[t.id] = true end end
  for i = #chain, 1, -1 do
    local fxId = chain[i]
    if not targetIds[fxId] then
      rm:deleteFx(fxId)
      if clearOwner(owners, fxId) then dirty = true end
      table.remove(chain, i)
    end
  end

  -- 2. Materialise id-less targets (CU bridges) appended at the chain end;
  --    rm:addFx appends and returns the minted id.
  for _, t in ipairs(target) do
    if not t.id then
      local fxId = rm:addFx(trackId, { ident = t.ident, index = #chain + pinned })
      t.id = fxId
      stampOrigin(t.origin, fxId)
      dirty = true
      util.add(chain, fxId)
    end
  end

  -- 3. Permute to target order via rm:assignFx{index}; the owned chain is contiguous
  --    past the pinned CC head, so target slot d fixes at abs idx d-1+pinned.
  chain = liveChain()
  for d = 1, #target do
    if chain[d] ~= target[d].id then
      local fromIdx
      for j = d + 1, #chain do
        if chain[j] == target[d].id then fromIdx = j; break end
      end
      rm:assignFx(target[d].id, { index = d - 1 + pinned })
      local moved = chain[fromIdx]
      table.remove(chain, fromIdx)
      table.insert(chain, d, moved)
    end
  end

  -- 4. Push params (flat sliders) and per-FX MIDI routing now the chain is in final
  --    order; midi batches into one chunk surgery, params write through per fx.
  for _, t in ipairs(target) do
    if t.params then rm:assignFx(t.id, { params = t.params }) end
  end
  local writes = {}
  for _, t in ipairs(target) do
    if t.midi then util.add(writes, { id = t.id, midi = t.midi }) end
  end
  if #writes > 0 then rm:writeChainMidi(trackId, writes) end

  return dirty
end

--contract: walks ops in order inside one rm:transaction; setFXChain mints guids via rm:addFx
--contract: stamps them inline without firing wiringChanged; params/midi/pinMaps write through rm
function wm:applyOps(ops, label)
  ensureLoaded()
  rm:transaction(label or 'wiring: apply', function()
    -- newTrack addressing carries over from the preceding snapshot/apply (newTrackIds); no re-read.
    -- An external mutation would bump the state count → syncExternal reloads → newTrackIds refreshes.
    local wiringTracks = util.clone(newTrackIds)
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
    -- newTracks via the rebuilt map, master via masterKeys. Scratch ops carry their guid in op.trackId.
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
        wiringTracks[op.trackKey] = rm:addTrack({ name = 'continuum: ' .. op.trackKey,
                                                  trackKey = op.trackKey })
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
        if guid and reconcileFXChain(guid, op.fx, owners) then
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

    -- Stamps/clears mutated userGraph in place; invalidate the compiled cache
    -- without firing (no structural change, no reconcile re-entry).
    if graphDirty then setGraph(userGraph) end

    -- This pass's create/delete is the live newTrack addressing; idForKey reads it on the poke path.
    newTrackIds = wiringTracks
  end)
  markState()  -- our own write; don't let syncExternal reread it
end

-- A spliced product edge maps back to its authored taps: each tap collects the
-- crossings it participates in, so a lone-side poke fans out (the group fader).
local function authoredRouting(routing, spliceParts)
  local authored = {}
  for splicedIdx, target in pairs(routing) do
    local parts = spliceParts[splicedIdx]
    if #parts == 1 then
      authored[parts[1]] = target
    else
      for _, tapIdx in ipairs(parts) do
        local entry = authored[tapIdx]
        if not entry then entry = { kind = 'product', crossings = {} }; authored[tapIdx] = entry end
        util.add(entry.crossings, { target = target, parts = parts })
      end
    end
  end
  return authored
end

-- Gain routing derived once per structural change from the cached ctx.
-- Merge-CU entries carry consumerId/trackKey (not a guid); mergeGuids are stamped live by applyOps.
--shape: routing[edgeIdx] = {kind='mergeCU',consumerId,trackKey,slot} | {kind='mainSend',cls} | {kind='send',from,to} | {kind='product',crossings={{target,parts=int[]},…}}
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
  -- ctx edge indexes are spliced-graph indexes; callers poke authored taps.
  if ctx.splice then routing = authoredRouting(routing, ctx.splice.parts) end
  cache.routing = routing
  return routing
end

-- trackKey → opaque id for the live-poke path: a source is self-keyed, newTracks resolve
-- through the in-memory addressing map (refreshed by snapshot/applyOps), scratch + master via rm.
local function idForKey(trackKey)
  if trackKey == SCRATCH_KEY  then return rm:scratchId() end
  if trackKey == '__master__' then return rm:masterId() end
  return newTrackIds[trackKey] or trackKey
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

-- Mirror a live gain poke into the model so the next reconcile sees no spurious change.
local function setStateGain(target, gain)
  if not actualState then return end
  if target.kind == 'mergeCU' then
    local consumer = userGraph.nodes[target.consumerId]
    local guid = consumer and consumer.mergeGuids and consumer.mergeGuids[target.trackKey]
    for _, entry in pairs(actualState) do
      for _, fx in ipairs(entry.fx) do
        if fx.id == guid then fx.params = fx.params or {}; fx.params['gain' .. target.slot] = gain end
      end
    end
  elseif target.kind == 'mainSend' then
    local entry = actualState[target.cls]
    if entry and entry.mainSend then entry.mainSend.gain = gain end
  elseif target.kind == 'send' then
    local entry = actualState[target.from]
    for _, s in ipairs(entry and entry.sends or {}) do
      if s.to == target.to and s.kind == 'audio' then s.gain = gain end
    end
  end
end

-- A crossing's realized volume: the product of its taps' gains, the poked tap
-- riding the live drag value (its ops.gain is only written at commit).
local function crossingGain(parts, pokedIdx, pokedGain)
  local vol = 1
  for _, idx in ipairs(parts) do
    vol = vol * (idx == pokedIdx and pokedGain or wm:edgeGain(idx))
  end
  return vol
end

--contract: pokes the live gain for an edge via cached routing; no mutate/signal/undo.
-- see docs/wiringManager.md § pokeEdgeGain routing
function wm:pokeEdgeGain(edgeIdx, gain)
  local target = gainRouting()[edgeIdx]
  if not target then return false end
  if target.kind ~= 'product' then
    local ok = pokeGainTarget(target, gain)
    if ok then markState(); setStateGain(target, gain) end
    return ok
  end
  local allOk, any = true, false
  for _, crossing in ipairs(target.crossings) do
    local vol = crossingGain(crossing.parts, edgeIdx, gain)
    if pokeGainTarget(crossing.target, vol) then
      any = true; setStateGain(crossing.target, vol)
    else
      allOk = false
    end
  end
  if any then markState() end
  return allOk
end

--contract: in-place gain commit + scratch mirror, one Undo block, no wiringChanged/reconcile
function wm:fastGainCommit(edgeIdx, gain)
  ensureLoaded()
  local edge = userGraph.edges[edgeIdx]
  if not edge or edge.type ~= 'audio' then return false end
  rm:transaction('wiring: edge gain', function()
    edge.ops = edge.ops or {}
    edge.ops.gain = gain
    mirrorBusTaps(userGraph)
    self:pokeEdgeGain(edgeIdx, gain)
  end)
  markState()
  return true
end

--contract: delegates to rm:installedFx — raw REAPER "Type: Name (Author)" rows, memoised there
function wm:listInstalledFX()
  return rm:installedFx()
end

--contract: rereads the graph from routing when REAPER's project state moved without us — undo/redo
--contract: or a manual routing edit. Our own writes rebaseline (markState), so they never trigger.
-- see docs/wiringManager.md § external sync
function wm:syncExternal()
  local count = reaper.GetProjectStateChangeCount and reaper.GetProjectStateChangeCount(0)
  if not count or count == lastStateCount then return end
  lastStateCount = count
  setGraph(nil)
  actualState = nil  -- an external mutation moved REAPER under us; the model is now a lie
  fire('wiringChanged', { kind = 'load' })
end

-- After a self-driven apply REAPER equals the applied target; overlay realised track ids so the
-- model stands in for a fresh snapshot on the next reconcile. see docs/wiringManager.md § actual-state model
local function rememberApplied()
  local snap       = wm:targetState()
  local masterGuid = rm:masterId()
  for trackKey, entry in pairs(snap) do
    if     entry.trackKind == 'newTrack' then entry.id = newTrackIds[trackKey]
    elseif entry.trackKind == 'master'   then entry.id = masterGuid end
  end
  return snap
end

-- A matrix buss record carries its summing track's guid: stamped once the track exists,
-- cleared when its class loses one. Never on the node, so the id survives fan⇄matrix.
local function stampBusTracks()
  for busId, rec in pairs(rm:meta('bus')) do
    local trackId
    if userGraph.nodes[busId] then
      trackId = newTrackIds[ensureCompiled().ctx:trackKeyOf(busId)]
    end
    if rec.trackId ~= trackId then
      rm:assignMeta('bus', busId, { trackId = trackId or util.REMOVE })
    end
  end
end

--contract: one reconcile pass — diff targetState vs the actual side (the actualState model or a
--contract: fresh snapshot), applyOps, then refresh the model for the next self-driven reconcile
function wm:reconcile(label)
  local target = self:targetState()
  local snap   = actualState or self:snapshot()
  local ops    = self:diff(target, snap)
  self:applyOps(ops, label or 'wiring: reconcile')
  stampBusTracks()
  actualState  = rememberApplied()
end

--contract: idempotent; hooks wiringChanged so mutate/load reconciles + one immediate sync pass.
function wm:enableLive(label)
  if liveLabel then return end
  liveLabel = label or 'wiring: apply'
  -- Positions are decoration (persisted to the rm meta store, orthogonal to the
  -- differ): a pos-only move yields zero diff ops, so skip the reconcile entirely.
  self:subscribe('wiringChanged', function(payload)
    if payload.kind == 'move' then return end
    self:reconcile(payload.kind == 'load' and 'wiring: reconcile (load)' or liveLabel)
  end)
  self:reconcile('wiring: reconcile (enable)')
end

return wm
