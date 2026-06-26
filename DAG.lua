-- Pure structural calculus for the wiring page. DAG.compile returns a
-- lazy-caching ctx; user-graph predicates stay free-standing. See docs/DAG.md.

-- @noindex

--invariant: DAG.validate is pure; derivations live on DAG.compile's ctx
--invariant: REAPER tracks are always stereo; audio I/O is a count of stereo pairs, never channels
--invariant: every user-graph node carries node.ports={audio={…},midi={ins,outs}} at construction
--invariant: fx midi: JSFX ports come from midirecv/midisend scan; native fx get {1,1}.
--invariant: master is a singleton node (id='master'); ports.audio.ins is an explicit integer port count (default 1); no audio outs, no MIDI; terminal-only (never `from`)
--shape: userGraph = { nodes = {[id]=userNode}, edges = edge[] }  -- node ids are rm guids (read era)
--shape: userNode = { kind='source'|'fx'|'master'|'bus', pos={x,y}, ports={audio={ins,outs,inNames?,outNames?}, midi={ins,outs}}, trackId?=string, fxIdent?=string, fxDisplay?=string, fxId?=string, busAware?=bool, split?=true, orient?='V'|'H' }  -- bus: synthetic id, no source/fx; its summing track's guid lives on the bus record, not the node
--invariant: fx nodes carry busAware; wm:addFxNode and DAG.validate refuse true
--invariant: fxId is nil until materialised; stamped into the node after TrackFX_AddByName succeeds
-- see docs/DAG.md § fxId as incarnation handle
--shape: edge = { type='audio'|'midi', from=id, fromPort=nil|portIdx, to=id, toPort=nil|portIdx, ops?={gain?=number}, primary?=true }
--invariant: edge ops ride as metadata; gain on a sole send-wire folds onto send volume, else CU
-- see docs/DAG.md § CU bridge invariant
--invariant: node.split (fx only): seeds 'split:'..id into srcSet; node+cone get own class/track
--invariant: a split-tagged class never absorbs
--invariant: signal-bearing bus seeds 'bus:'..id; marker never spreads — bus sits alone in its class
--invariant: bus classes absorb in neither direction; a dangling bus is inert (empty srcSet)
--invariant: a class with no audio parents and a lone source-direct midi parent absorbs onto it
--invariant: busses below 2x2 splice out at compile; crossings become direct edges at product gain
--invariant: srcSet unions node.split with derived master-min split markers
--shape: synthNode = { kind='fx', fxIdent=CU_IDENT, fxId?=string, params=table, originNode?=string, originSide?='in'|'out', originConsumer?=string, originTrackKey?=string, inputEdges?=int[] }
-- see docs/DAG.md § synthNode field roles
--shape: outWire = { from=id, fromPort?=int, to=trackKey, toNode=id, toPort?=int, type='audio'|'midi', gain?=number }
--shape: intraConn = { from=id, fromPort?=int, to=id, toPort?=int, type='audio'|'midi' }
--shape: trackSpec = { trackKind='sourceTrack'|'newTrack'|'master'|'scratch', trackId?=string, fxOrder=id[], mainSend=bool,
--shape:   mainSendGain?=number, parentFeed?={from=id, fromPort?=int, toNode=id, toPort?=int, sink=trackKey},
--shape:   synthNodes?={[cuId]=synthNode}, outWires=outWire[], intraConns=intraConn[],
--shape:   pipeMidi?={{from=id, consumer=id},...} }  -- parentFeed.sink is MASTER or folder parent trackKey; pipeMidi = un-gateable crossings
--shape: targetTracks = { [trackKey] = trackSpec }
-- see docs/DAG.md § targetTracks shape
--shape: allocatedSend = { to=trackKey, type='audio'|'midi', gain?=number, srcChan=int, dstChan=int, preFx?=true }; audio src/dstChan are (pair-1)*2, midi are bus 0..127; preFx marks a raw-source-origin (pre-FX) send
--shape: allocatedPinMap = { [fxId] = { ins={[port]={pair,...}}, outs={[port]={pair,...}} } }
--shape: allocatedTracks = { [trackKey] = { trackKind=..., trackId?=..., fxOrder=..., mainSend=..., mainSendGain?=..., sends=allocatedSend[], fxMidiBus?={ [fxId]={inBus,outBus} } (native fx only), pinMaps=allocatedPinMap, nchan=int, mainSendOffs?=int, bracketNodes?={ [bracketId]=synthNode } } }; see docs/DAG.md § allocate for the allocator + bracket model.
local util = require('util')

local CU_IDENT = 'JS:Continuum Utility'
-- Merge CU gain-bank width (utility/Continuum Utility.jsfx). Fan-in past this
-- fans out to a CU cascade; see docs/DAG.md § per-consumer merge.
local MERGE_WIDTH = 16

-- Per-track stream capacity: 64 audio pairs, 126 MIDI buses — REAPER's 128 minus bus 127
-- (bracket parking, docs/DAG.md § allocate) and bus 126 (param-automation CC propagation).
local CAPACITY = { audio = 64, midi = 126 }
local PARK_BUS = 127

-- Stable trackKey for the master-hosted class: the REAPER master carries no
-- wiringTracks entry, so target and snapshot agree on this synthetic key.
local MASTER = '__master__'

local DAG = {}

----------- PUBLIC

----- validate

--contract: returns nil on success, or { code, ... } describing the first failure; wm:mutate gates persistence on nil
function DAG.validate(userGraph)
  local nodes, edges = userGraph.nodes or {}, userGraph.edges or {}

  local masters = 0
  local seenGuid = {}
  for id, n in pairs(nodes) do
    if n.kind == 'master' then masters = masters + 1 end
    if n.kind == 'source' and n.trackId then
      local prior = seenGuid[n.trackId]
      if prior then
        return { code = 'duplicate_source_guid', guid = n.trackId,
                 prior = prior, dup = id }
      end
      seenGuid[n.trackId] = id
    end
    if n.kind == 'fx' and n.busAware then
      return { code = 'ext_midi_bus_user_fx', id = id, ident = n.fxIdent }
    end
    if n.split and n.kind ~= 'fx' then
      return { code = 'split_non_fx', id = id, kind = n.kind }
    end
  end
  if masters ~= 1 then
    return { code = 'master_singleton', count = masters }
  end

  -- Dedupe key per edge: (type, from, to, fromPort_or_1, toPort_or_1).
  -- nil ports resolve to 1 so the shorthand and the explicit form collide.
  local seen = {}
  for i, edge in ipairs(edges) do
    local function fail(code, adds)
      return util.assign({ code = code, edge = i }, adds)
    end
    local fromNode, toNode = nodes[edge.from], nodes[edge.to]
    if not fromNode then return fail('unknown_from', { id = edge.from }) end
    if not toNode   then return fail('unknown_to',   { id = edge.to   }) end
    if edge.type ~= 'audio' and edge.type ~= 'midi' then
      return fail('unknown_edge_type', { type = edge.type })
    end

    -- Port existence per (side, edge.type). One symmetric check
    -- subsumes source-as-sink, master-as-source, midi-to-master,
    -- and "audio edge to an FX with no audio ports."
    local fromOuts = (fromNode.ports[edge.type] or {}).outs or 0
    local toIns    = (toNode.ports[edge.type]   or {}).ins  or 0
    if fromOuts < 1 then
      return fail('no_out_port', { id = edge.from, kind = fromNode.kind, type = edge.type })
    end
    if toIns < 1 then
      return fail('no_in_port',  { id = edge.to,   kind = toNode.kind,   type = edge.type })
    end

    if edge.type == 'midi' then
      if edge.fromPort ~= nil or edge.toPort ~= nil then return fail('midi_port_index') end
    else
      -- nil port = implicit port 1 (single-port shorthand).
      local fromIdx = edge.fromPort or 1
      local toIdx   = edge.toPort   or 1
      if fromIdx < 1 or fromIdx > fromOuts then
        return fail('audio_from_port_oob', { want = edge.fromPort, have = fromOuts })
      end
      if toIdx < 1 or toIdx > toIns then
        return fail('audio_to_port_oob', { want = edge.toPort, have = toIns })
      end
    end

    local fp = edge.type == 'audio' and (edge.fromPort or 1) or 0
    local tp = edge.type == 'audio' and (edge.toPort   or 1) or 0
    local key = util.key(edge.type, edge.from, edge.to, fp, tp)
    if seen[key] then
      return fail('duplicate_edge', { prior = seen[key] })
    end
    seen[key] = i
  end

  -- Cycle detection: directed DFS over the union of audio + midi edges.
  -- A cycle in either layer is a cycle in the dependency graph.
  local adj = {}
  for _, edge in ipairs(edges) do
    util.bucket(adj, edge.from, edge.to)
  end
  local colour = {} -- nil=white, 1=grey, 2=black
  local function visit(id)
    colour[id] = 1
    for _, nxt in ipairs(adj[id] or {}) do
      if colour[nxt] == 1 then return nxt end
      if colour[nxt] == nil then
        local hit = visit(nxt)
        if hit then return hit end
      end
    end
    colour[id] = 2
  end
  for id in pairs(nodes) do
    if colour[id] == nil then
      local hit = visit(id)
      if hit then return { code = 'cycle', at = hit } end
    end
  end

  return nil
end

----- classify

-- Post-hoc component classifier over read's domain (design/wiring-implicit-graph.md
-- § Quarantine): validate's successor on the graphs REAPER allows, not just authorable ones.
--contract: groups non-master nodes into components; feedbackSeeds + busAware tag quarantined ones
--shape: component = { nodes=id[] (sorted), reason=nil|'feedback'|'busAware' }
function DAG.classify(userGraph, feedbackSeeds)
  local nodes, edges = userGraph.nodes or {}, userGraph.edges or {}
  feedbackSeeds = feedbackSeeds or {}

  -- Union over non-master-incident edges only: master is a shared terminal sink bridging no
  -- two track-sets, so excluding it keeps every track whole within a single component.
  local parent = {}
  local function find(x)
    while parent[x] ~= x do parent[x] = parent[parent[x]]; x = parent[x] end
    return x
  end
  for id, n in pairs(nodes) do
    if n.kind ~= 'master' then parent[id] = id end
  end
  for _, e in ipairs(edges) do
    if parent[e.from] and parent[e.to] then parent[find(e.from)] = find(e.to) end
  end

  local byRoot = {}
  for id in pairs(parent) do
    local root = find(id)
    byRoot[root] = byRoot[root] or { nodes = {} }
    util.add(byRoot[root].nodes, id)
  end

  -- A bus-aware fx scans midi_bus itself, corrupting its whole component's bus space, so the
  -- entire track-set is quarantined (design § Quarantine), not just its own track.
  for id, n in pairs(nodes) do
    if n.busAware and byRoot[find(id)] then byRoot[find(id)].reason = 'busAware' end
  end

  -- Feedback-loop tracks (read's Kahn leftovers, seeded by the caller) can't be topo-ordered, so
  -- compile rejects the component; feedback outranks bus-aware where both apply.
  for id in pairs(feedbackSeeds) do
    local root = parent[id] and find(id)
    if root and byRoot[root] then byRoot[root].reason = 'feedback' end
  end

  local components = {}
  for _, comp in pairs(byRoot) do
    table.sort(comp.nodes)
    util.add(components, comp)
  end
  table.sort(components, function(a, b) return a.nodes[1] < b.nodes[1] end)
  return components
end

----- compile context

-- Lazy ctx factory; derivations memoise into closure-local `cache`.
-- derivedSplits arrives already settled (from deriveMasterSplit); ctx just folds it into srcSet.
local function buildCtx(userGraph, derivedSplits)
  local nodes = userGraph.nodes or {}
  local edges = userGraph.edges or {}
  local cache = { srcSet = {}, hasSplit = {}, hasBus = {} }
  local ctx = { userGraph = userGraph }

  -- Forward/reverse adjacency over the edge union, built once per ctx: rev
  -- feeds srcSet's walk, fwd the master-min cone walks (deriveMasterSplit).
  function ctx:adjacency()
    if cache.adjacency then return cache.adjacency end
    local fwd, rev = {}, {}
    for _, edge in ipairs(edges) do
      util.bucket(fwd, edge.from, edge.to)
      util.bucket(rev, edge.to, edge.from)
    end
    cache.adjacency = { fwd = fwd, rev = rev }
    return cache.adjacency
  end

  -- Reverse adjacency: for each node id, the list of input-side node ids.
  local function inbound() return ctx:adjacency().rev end

  -- A bus routes signal only when both sides are wired; one pass over the edges.
  local function busLive(id)
    if not cache.busIO then
      local io = {}
      local function mark(busId, dir)
        local node = nodes[busId]
        if node and node.kind == 'bus' then
          io[busId] = io[busId] or {}
          io[busId][dir] = true
        end
      end
      for _, edge in ipairs(edges) do
        if edge.type == 'audio' then mark(edge.to, 'ins'); mark(edge.from, 'outs') end
      end
      cache.busIO = io
    end
    local io = cache.busIO[id]
    return io and io.ins and io.outs
  end

  local function srcSet(id)
    if cache.srcSet[id] then return cache.srcSet[id] end
    local set = {}
    local node = nodes[id]
    if node and node.kind == 'source' and node.trackId then
      set[node.trackId] = true
    end
    -- A split marker evicts the node + its cone into their own class.
    -- hasSplit mirrors the spread so nothing has to parse the key back.
    if node and (node.split or derivedSplits[id]) then
      set['split:' .. id] = true
      cache.hasSplit[id] = true
    end
    if node and node.kind == 'bus' then
      -- Only ≥2x2 busses survive the splice (empty-set = drift backstop); the marker
      -- never spreads — bus alone in its class, sources pass through to children.
      if not busLive(id) then cache.srcSet[id] = set; return set end
      set['bus:' .. id] = true
      cache.hasBus[id] = true
    end
    for _, parent in ipairs(inbound()[id] or {}) do
      for guid in pairs(srcSet(parent)) do
        if guid:sub(1, 4) ~= 'bus:' then set[guid] = true end
      end
      if cache.hasSplit[parent] then cache.hasSplit[id] = true end
    end
    cache.srcSet[id] = set
    return set
  end

  -- Private: the source-set partition {classKey -> id[]}. Exposed only through
  -- ctx:classOf() and the track-keyed derivations below; never a public seam.
  local function classes()
    if cache.classes then return cache.classes end
    cache.classes, cache.splitClasses, cache.busClasses, cache.sourceTrackId = {}, {}, {}, {}
    for id in pairs(nodes) do
      local guids = {}
      for guid in pairs(srcSet(id)) do util.add(guids, guid) end
      table.sort(guids)
      local key = util.key(table.unpack(guids))
      util.bucket(cache.classes, key, id)
      if cache.hasSplit[id] then cache.splitClasses[key] = true end
      if cache.hasBus[id]   then cache.busClasses[key]   = true end
      local n = nodes[id]
      if n.kind == 'source' and n.trackId then cache.sourceTrackId[key] = n.trackId end
    end
    return cache.classes
  end

  -- Class keys carrying a split tag (a node.split node or its cone). They
  -- never absorb — the split exists to give them their own track.
  local function splitClasses()
    classes()
    return cache.splitClasses
  end

  -- Class keys hosting a bus node: absorption skips them in both directions,
  -- so the buss keeps its own track and the summing track stays fx-less.
  local function busClasses()
    classes()
    return cache.busClasses
  end

  -- {classKey -> trackId} for classes containing a source node (incl. folder parents).
  -- Pinned to that source's REAPER track: never an absorbee; keys to guid even when srcSet is composite.
  local function sourceTrackId()
    classes()
    return cache.sourceTrackId
  end

  function ctx:classOf()
    if cache.classOf then return cache.classOf end
    cache.classOf = {}
    for cls, members in pairs(classes()) do
      for _, id in ipairs(members) do cache.classOf[id] = cls end
    end
    return cache.classOf
  end

  local function quotient()
    if cache.quotient then return cache.quotient end
    cache.quotient = {}
    for cls in pairs(classes()) do
      cache.quotient[cls] = { audioParents = {}, midiParents = {},
                              audioChildren = {}, midiChildren = {},
                              primaryAudioParents = {}, midiSourceParents = {} }
    end
    local classOf = ctx:classOf()
    for _, edge in ipairs(edges) do
      local fromCls, toCls = classOf[edge.from], classOf[edge.to]
      -- Inert vertices ('' class, empty srcSet) carry no signal — skip.
      if fromCls ~= toCls and fromCls ~= '' and toCls ~= '' then
        local toQ, fromQ = cache.quotient[toCls], cache.quotient[fromCls]
        if edge.type == 'audio' then
          toQ.audioParents[fromCls] = true
          if edge.primary then toQ.primaryAudioParents[fromCls] = true end
          fromQ.audioChildren[toCls] = true
        else
          toQ.midiParents[fromCls] = true
          if nodes[edge.from].kind == 'source' then toQ.midiSourceParents[fromCls] = true end
          fromQ.midiChildren[toCls] = true
        end
      end
    end
    return cache.quotient
  end

  local function absorption()
    if cache.absorption then return cache.absorption end
    local q = quotient()

    -- Direct (one-hop) track under the absorption rule. Audio summing picks the host when audio
    -- parents exist; a pure-midi class falls through: a lone source-direct parent wins, else nil.
    local function directTrackKey(qEntry)
      local audioParents   = util.keys(qEntry.audioParents)
      local primaryParents = util.keys(qEntry.primaryAudioParents)
      if #primaryParents == 1 then return primaryParents[1] end
      if #primaryParents == 0 and #audioParents == 1 then return audioParents[1] end
      if #audioParents > 0 then return nil end
      local midiParents       = util.keys(qEntry.midiParents)
      local midiSourceParents = util.keys(qEntry.midiSourceParents)
      if #midiSourceParents == 1 then return midiSourceParents[1] end
      if #midiParents == 1 then return midiParents[1] end
      return nil
    end

    local splitClasses, busClasses, srcTrack = splitClasses(), busClasses(), sourceTrackId()
    local direct = {}
    for cls, qEntry in pairs(q) do
      local target = not (splitClasses[cls] or busClasses[cls] or srcTrack[cls]) and directTrackKey(qEntry) or nil
      direct[cls] = target and not busClasses[target] and target or nil
    end

    local function chainEnd(cls, seen)
      local nextCls = direct[cls]
      if not nextCls or seen[nextCls] then return cls end
      seen[nextCls] = true
      return chainEnd(nextCls, seen)
    end

    cache.absorption = {}
    for cls in pairs(q) do
      if direct[cls] then
        local seen = { [cls] = true }
        cache.absorption[cls] = chainEnd(direct[cls], seen)
      end
    end
    return cache.absorption
  end

  -- The class hosted ON the REAPER master; nil only on a marker-free base ctx.
  -- DAG.compile marks master split in those cases, so compiled ctx is total. See docs/DAG.md § Master-minimization.
  function ctx:masterTrackClass()
    if cache.masterTrackClass ~= nil then return cache.masterTrackClass or nil end
    local mc = self:classOf()['master']
    local result = mc ~= '' and mc or nil
    if result then
      for _, id in ipairs(classes()[mc]) do
        if nodes[id].kind == 'source' then result = nil; break end
      end
    end
    cache.masterTrackClass = result or false
    return result
  end

  -- MASTER for the master class; a source-bearing class pins to its source's guid (its own REAPER
  -- track); else resolve through absorption so an absorbed class lands on its target's real trackKey. See docs/DAG.md § Folder parents.
  function ctx:classTrackKey(cls)
    if cls == self:masterTrackClass() then return MASTER end
    local pinned = sourceTrackId()[cls]
    if pinned then return pinned end
    local absorbed = absorption()[cls]
    if absorbed then return self:classTrackKey(absorbed) end
    return cls
  end

  -- Track key a node id lands on: its class, resolved through absorption.
  function ctx:trackKeyOf(id) return self:classTrackKey(self:classOf()[id]) end

  -- {[trackKey] = id[]} pooling members of every class that resolves to it.
  function ctx:trackMembers()
    if cache.trackMembers then return cache.trackMembers end
    cache.trackMembers = {}
    for cls, members in pairs(classes()) do
      local trackKey   = self:classTrackKey(cls)
      local bucket = cache.trackMembers[trackKey] or {}
      for _, id in ipairs(members) do util.add(bucket, id) end
      cache.trackMembers[trackKey] = bucket
    end
    for _, bucket in pairs(cache.trackMembers) do table.sort(bucket) end
    return cache.trackMembers
  end

  -- Per foldered-child track, the one egress edge that rides its parent send (REAPER has a single
  -- B_MAINSEND per track). Returns { [edgeIdx] = sinkTrackKey }. See docs/DAG.md.
  function ctx:conduit()
    if cache.conduit then return cache.conduit end
    cache.conduit = {}
    local childParent = {}  -- child trackKey -> parent node id (the tree)
    for id, n in pairs(nodes) do
      if n.kind == 'source' and n.parent then childParent[self:trackKeyOf(id)] = n.parent end
    end
    local candidates = {}   -- child trackKey -> { {idx, edge}, ... }
    for idx, edge in ipairs(edges) do
      local parentNode = edge.type == 'audio' and nodes[edge.to]
      if parentNode and parentNode.kind == 'source' and (parentNode.ports.audio.ins or 0) >= 1 then
        local fromTrack = self:trackKeyOf(edge.from)
        if childParent[fromTrack] == edge.to then util.bucket(candidates, fromTrack, { idx = idx, edge = edge }) end
      end
    end
    -- Tie-break among parallels by the stable endpoint key, churn-free across recompiles.
    for _, cand in pairs(candidates) do
      table.sort(cand, function(a, b)
        local ae, be = a.edge, b.edge
        if (ae.toPort or 1)   ~= (be.toPort or 1)   then return (ae.toPort or 1)   < (be.toPort or 1)   end
        if (ae.fromPort or 1) ~= (be.fromPort or 1) then return (ae.fromPort or 1) < (be.fromPort or 1) end
        return ae.from < be.from
      end)
      cache.conduit[cand[1].idx] = self:trackKeyOf(cand[1].edge.to)
    end
    return cache.conduit
  end

  -- Per gained edge, the volume host (native send/main vol, or kind 'cu');
  -- shared by targetTracks and wm:pokeEdgeGain. See docs/DAG.md § gainHost.
  function ctx:gainHost()
    if cache.gainHost then return cache.gainHost end
    local conduit = self:conduit()
    -- The native host a gained edge could land on, with the count key that
    -- decides solubility; nil for untracked-source or same-track edges.
    local function routeOf(edge, edgeIdx)
      local from = self:trackKeyOf(edge.from)
      if not from or from == '' then return nil end
      local to = self:trackKeyOf(edge.to)
      if to == MASTER or conduit[edgeIdx] then  -- a parent send: gain lives on the track's main-send vol
        return { kind = 'mainSend', key = util.key('main', from), cls = from }
      end
      if to and to ~= '' and from ~= to then
        return { kind = 'send', key = util.key('send', from, to), from = from, to = to }
      end
      return nil
    end
    -- A gain lands on a native host only when that host carries exactly one
    -- audio edge, so count every audio edge (gained or not) before deciding any.
    local count = {}
    for edgeIdx, edge in ipairs(edges) do
      if edge.type == 'audio' then
        local route = routeOf(edge, edgeIdx)
        if route then count[route.key] = (count[route.key] or 0) + 1 end
      end
    end
    local hosts = {}
    for edgeIdx, edge in ipairs(edges) do
      if edge.type == 'audio' and edge.ops and edge.ops.gain then
        local host  = { kind = 'cu', gain = edge.ops.gain }
        local route = routeOf(edge, edgeIdx)
        if route and count[route.key] == 1 then util.assign(host, util.pick(route, 'kind cls from to')) end
        hosts[edgeIdx] = host
      end
    end
    cache.gainHost = hosts
    return hosts
  end

  return ctx
end

----- realisation

-- Kahn's over a track's chain members (fx + synth CU; source/master excluded).
-- Tiebreak: Goodman-Hsu local pressure (outMember - inMember), then id.
local function topoIntraTrack(members, conns)
  local memberSet = {}
  for _, id in ipairs(members) do memberSet[id] = true end
  local indeg, succ, inMember = {}, {}, {}
  for id in pairs(memberSet) do indeg[id], succ[id], inMember[id] = 0, {}, 0 end
  for _, conn in ipairs(conns) do
    if memberSet[conn.from] and memberSet[conn.to] then
      indeg[conn.to] = indeg[conn.to] + 1
      inMember[conn.to] = inMember[conn.to] + 1
      util.add(succ[conn.from], conn.to)
    end
  end
  -- Lower score = drains more pairs than it claims; pick that next to keep
  -- the allocator's live set (and thus nchan) small.
  local function sortReady(r)
    table.sort(r, function(a, b)
      local sa = #succ[a] - inMember[a]
      local sb = #succ[b] - inMember[b]
      if sa ~= sb then return sa < sb end
      return a < b
    end)
  end
  local ready = {}
  for id in pairs(memberSet) do if indeg[id] == 0 then util.add(ready, id) end end
  sortReady(ready)
  local out = {}
  while #ready > 0 do
    local id = table.remove(ready, 1)
    util.add(out, id)
    local children = {}
    for _, child in ipairs(succ[id]) do util.add(children, child) end
    table.sort(children)
    for _, child in ipairs(children) do
      indeg[child] = indeg[child] - 1
      if indeg[child] == 0 then util.add(ready, child) end
    end
    sortReady(ready)
  end
  return out
end

do
  -- source/master bound track IO; a bus is a bare summing track — none host an fxOrder.
  local function isChainMember(node)
    return node.kind ~= 'source' and node.kind ~= 'master' and node.kind ~= 'bus'
  end

  -- Native gain hosts keyed for the routing pass: send volume by track pair,
  -- main-send volume by class. CU-hosted gains ride their conns instead.
  local function nativeGains(ctx)
    local sendGain, mainGain = {}, {}
    for _, host in pairs(ctx:gainHost()) do
      if host.kind == 'send' then sendGain[util.key(host.from, host.to)] = host.gain
      elseif host.kind == 'mainSend' then mainGain[host.cls] = host.gain end
    end
    return sendGain, mainGain
  end

  -- Realise edges into conns + synth merge CUs; audio gain as metadata,
  -- MIDI passes through. See docs/DAG.md § per-consumer merge.
  local function buildConns(ctx)
    local nodes, edges = ctx.userGraph.nodes, ctx.userGraph.edges
    local gainHost = ctx:gainHost()
    local conduit  = ctx:conduit()
    local synthNodes, cuTrackKey, conns, cuN = {}, {}, {}, 0
    local function nodeTrackKey(id) return cuTrackKey[id] or ctx:trackKeyOf(id) end
    local function audioConn(from, fp, to, tp, gain)
      util.add(conns, { type = 'audio', from = from, fromPort = fp or 1,
                        to = to, toPort = tp or 1, gain = gain })
    end
    local function mintCU(trackKey, params, origin)
      cuN = cuN + 1
      local cuId = '_cu_' .. cuN
      synthNodes[cuId] = util.assign({ kind = 'fx', fxIdent = CU_IDENT, params = params }, origin)
      cuTrackKey[cuId] = trackKey
      return cuId
    end

    -- A feeder group gathers every conn converging on one (trackKey, consumer)
    -- sink, so the merge logic below can reduce them together.
    local feederGroups, groupKeys, kept = {}, {}, {}
    local function groupFor(trackKey, consumer, isParentSend)
      local key = util.key(trackKey, consumer)
      local group = feederGroups[key]
      if not group then
        group = { trackKey = trackKey, consumer = consumer, isParentSend = isParentSend,
                 audio = {}, midi = {} }
        feederGroups[key] = group; util.add(groupKeys, key)
      end
      return group
    end
    -- A foldered child's midi into its parent (or a parent-resident fx) rides the same atomic
    -- B_MAINSEND as its audio conduit edge — never a second explicit send. Recorded per child for
    -- the family allocator; consumer kind (source = merge to bus 0, fx = distinct) read there.
    local pipeParent, pipeMidi = {}, {}
    for edgeIdx, parentTrackKey in pairs(conduit) do
      pipeParent[nodeTrackKey(edges[edgeIdx].from)] = parentTrackKey
    end
    for edgeIdx, edge in ipairs(edges) do
      local conn
      if edge.type == 'midi' then
        conn = { type = 'midi', from = edge.from, to = edge.to }
      else
        -- A natively-hosted gain (send/main volume) stays off the conn.
        local host = gainHost[edgeIdx]
        local gain = host and host.kind == 'cu' and host.gain or nil
        conn = { type = 'audio', from = edge.from, fromPort = edge.fromPort or 1,
                 to = edge.to, toPort = edge.toPort or 1, gain = gain, edgeIdx = edgeIdx }
      end
      local fromTrackKey, toTrackKey = nodeTrackKey(conn.from), nodeTrackKey(conn.to)
      local group, divert
      if conn.type == 'midi' and toTrackKey ~= '' and pipeParent[fromTrackKey] == toTrackKey then
        divert = true                                   -- rides the pipe; never an explicit send
        util.bucket(pipeMidi, fromTrackKey, { from = conn.from, consumer = conn.to })
      elseif fromTrackKey ~= '' and toTrackKey ~= '' then
        if toTrackKey == MASTER and fromTrackKey ~= MASTER then
          group = groupFor(fromTrackKey, 'master', true)  -- width-1 parent send: pre-sum per producer
        elseif conn.to == 'master' then
          group = groupFor(toTrackKey, 'master', true)    -- in-class master: serial parent send, sum fan-in to one pair
        elseif conduit[edgeIdx] then
          group = groupFor(fromTrackKey, conn.to, true)   -- folder conduit: child rides B_MAINSEND to its parent
        elseif nodes[conn.to] and nodes[conn.to].kind == 'fx' then
          group = groupFor(toTrackKey, conn.to, false)    -- fx consumer: merge at the consumer trackKey
        end
      end
      if divert then -- pipe traffic: no conn, recorded above
      elseif group then util.add(group[conn.type], conn)
      else util.add(kept, conn) end
    end
    conns = kept

    local function sortFeeders(feeders)
      table.sort(feeders, function(a, b)
        if a.from ~= b.from then return a.from < b.from end
        if (a.fromPort or 1) ~= (b.fromPort or 1) then return (a.fromPort or 1) < (b.fromPort or 1) end
        return (a.toPort or 1) < (b.toPort or 1)
      end)
    end
    local function anyGained(feeders)
      for _, f in ipairs(feeders) do if f.gain and f.gain ~= 1 then return true end end
      return false
    end

    table.sort(groupKeys)
    for _, groupKey in ipairs(groupKeys) do
      local group = feederGroups[groupKey]
      sortFeeders(group.audio); sortFeeders(group.midi)
      -- A parent send (to master or a folder parent) marks its summed output so routeByTrack
      -- realises it as B_MAINSEND; in-class master (sink == own track) stays an intra conn.
      local parentSink  = group.isParentSend and nodeTrackKey(group.consumer) or nil
      local marksParent = parentSink ~= nil and parentSink ~= group.trackKey
      -- Audio: matrix sinks merge only when gained; parent sends sum on fan-in ≥2.
      -- MIDI: only same-track producers force a CU (cross-track sends coalesce a bus).
      local audioCU = group.isParentSend and #group.audio >= 2 or
                      (not group.isParentSend and anyGained(group.audio))
      local nIntraMidi = 0
      for _, f in ipairs(group.midi) do
        if nodeTrackKey(f.from) == group.trackKey then nIntraMidi = nIntraMidi + 1 end
      end
      local midiCU = #group.midi >= 2 and nIntraMidi >= 1

      -- A merge CU is identified by (consumer, track). Fan-in past MERGE_WIDTH
      -- cascades into parallel CUs; each past the first gets a '#N' key suffix.
      local mergeN = 0
      local function mintMerge(params, inputEdges)
        mergeN = mergeN + 1
        local key = mergeN == 1 and group.trackKey or (group.trackKey .. '#' .. mergeN)
        return mintCU(group.trackKey, params,
          { originConsumer = group.consumer, originTrackKey = key, inputEdges = inputEdges })
      end
      -- One merge CU over feeders[lo..hi]: window gains (unity default), collect
      -- any edgeIdx for live-gain pokes. audioSum 0 = matrix fan-out, 1 = sum-tree.
      local function chunkCU(feeders, lo, hi, audioSum)
        local gains, inputEdges = {}, {}
        for i = lo, hi do
          gains[i - lo + 1] = feeders[i].gain or 1
          if feeders[i].edgeIdx then util.add(inputEdges, feeders[i].edgeIdx) end
        end
        return mintMerge({ mode = 'merge', nPairs = hi - lo + 1, gains = gains, audioSum = audioSum },
                         #inputEdges > 0 and inputEdges or nil)
      end

      local firstAudioCu  -- carries the MIDI merge too, in the single-CU case
      if not audioCU then
        for _, f in ipairs(group.audio) do
          if marksParent then f.parentSend = true; f.sink = parentSink end
          util.add(conns, f)
        end
      elseif not group.isParentSend then
        -- Matrix-fed: parallel chunk CUs, each ≤MERGE_WIDTH wide. Every
        -- chunk's outputs route to the consumer's pins, which sum the lot.
        for lo = 1, #group.audio, MERGE_WIDTH do
          local hi = math.min(lo + MERGE_WIDTH - 1, #group.audio)
          local cuId = chunkCU(group.audio, lo, hi, 0)
          firstAudioCu = firstAudioCu or cuId
          for i = lo, hi do
            local f = group.audio[i]
            audioConn(f.from, f.fromPort, cuId, i - lo + 1)
            audioConn(cuId, i - lo + 1, group.consumer, f.toPort)
          end
        end
      else
        -- Parent send (matrix-less): a sum-tree of audioSum CUs reduces fan-in
        -- to one pair. Gains apply at leaves; the root feeds parentFeed.
        local toPort = group.audio[1].toPort
        local level = {}
        for _, f in ipairs(group.audio) do
          util.add(level, { from = f.from, fromPort = f.fromPort,
                            gain = f.gain, edgeIdx = f.edgeIdx })
        end
        local rootCu
        while true do
          local nextLevel = {}
          for lo = 1, #level, MERGE_WIDTH do
            local hi = math.min(lo + MERGE_WIDTH - 1, #level)
            local cuId = chunkCU(level, lo, hi, 1)
            for i = lo, hi do audioConn(level[i].from, level[i].fromPort, cuId, i - lo + 1) end
            util.add(nextLevel, { from = cuId, fromPort = 1 })  -- summed to pair 1
          end
          if #nextLevel == 1 then rootCu = nextLevel[1].from; break end
          level = nextLevel
        end
        audioConn(rootCu, 1, group.consumer, toPort)
        if marksParent then conns[#conns].parentSend = true; conns[#conns].sink = parentSink end
        if mergeN == 1 then firstAudioCu = rootCu end  -- lone CU carries MIDI too
      end

      if not midiCU then
        for _, f in ipairs(group.midi) do
          if marksParent then f.parentSend = true end
          util.add(conns, f)
        end
      else
        -- One N→1 collapse (no width cap — 128-bit mask). Rides the audio CU
        -- only when there's exactly one; a cascade gives MIDI its own CU.
        local cuId = mergeN == 1 and firstAudioCu
                     or mintMerge({ mode = 'merge', nPairs = 1, gains = { 1 }, audioSum = 0 }, nil)
        for _, f in ipairs(group.midi) do util.add(conns, { type = 'midi', from = f.from, to = cuId }) end
        local midiOut = { type = 'midi', from = cuId, to = group.consumer }
        if marksParent then midiOut.parentSend = true end
        util.add(conns, midiOut)
      end
    end

    return conns, synthNodes, cuTrackKey, nodeTrackKey, pipeMidi
  end

  -- Deterministic wire ordering shared by every assembled track; optional ports
  -- collate as 0 so present/absent compare stably.
  local function cmpOpt(a, b) return (a or 0) < (b or 0) end
  local function neqOpt(a, b) return (a or 0) ~= (b or 0) end
  local function sortOutWires(outWires)
    table.sort(outWires, function(a, b)
      if a.to     ~= b.to     then return a.to     < b.to     end
      if a.type   ~= b.type   then return a.type   < b.type   end
      if a.from   ~= b.from   then return a.from   < b.from   end
      if neqOpt(a.fromPort, b.fromPort) then return cmpOpt(a.fromPort, b.fromPort) end
      if a.toNode ~= b.toNode then return a.toNode < b.toNode end
      return cmpOpt(a.toPort, b.toPort)
    end)
  end
  local function sortIntraConns(intraConns)
    table.sort(intraConns, function(a, b)
      if a.from ~= b.from then return a.from < b.from end
      if neqOpt(a.fromPort, b.fromPort) then return cmpOpt(a.fromPort, b.fromPort) end
      if a.to   ~= b.to   then return a.to   < b.to   end
      if neqOpt(a.toPort, b.toPort) then return cmpOpt(a.toPort, b.toPort) end
      return a.type < b.type
    end)
  end

  -- Fold every conn onto its source track: same-track → intraConn; master → mainSend;
  -- else → outWire. Keyed by producer so no pre-built entries needed; inert ('') endpoints skipped.
  local function routeByTrack(conns, nodeTrackKey, sendGain)
    local routing = {}
    local function routeOf(trackKey)
      local route = routing[trackKey]
      if not route then
        route = { outWires = {}, intraConns = {}, mainSend = false }
        routing[trackKey] = route
      end
      return route
    end
    for _, conn in ipairs(conns) do
      local fromTrackKey, toTrackKey = nodeTrackKey(conn.from), nodeTrackKey(conn.to)
      if fromTrackKey and fromTrackKey ~= '' and toTrackKey and toTrackKey ~= '' then
        local route = routeOf(fromTrackKey)
        if conn.parentSend then
          route.mainSend = true
          -- Audio fan-in arrives pre-merged (≥2 wires → one audioSum CU output), so
          -- parentFeed carries a single producer; sink is master or the folder parent.
          if conn.type == 'audio' then
            route.parentFeed = { from = conn.from, fromPort = conn.fromPort,
                                 toNode = conn.to, toPort = conn.toPort, sink = conn.sink }
          end
        elseif fromTrackKey == toTrackKey then
          util.add(route.intraConns, {
            from = conn.from, fromPort = conn.fromPort,
            to   = conn.to,   toPort   = conn.toPort, type = conn.type,
          })
        else
          -- conn.gain survives to here only on bus-bound taps sharing a route key
          -- (insoluble for gainHost); sends are per-srcChan, each with its own D_VOL.
          util.add(route.outWires, {
            from = conn.from, fromPort = conn.fromPort, to = toTrackKey,
            toNode = conn.to, toPort = conn.toPort, type = conn.type,
            gain = conn.type == 'audio'
                   and (sendGain[util.key(fromTrackKey, toTrackKey)] or conn.gain) or nil,
          })
        end
      elseif fromTrackKey == '' and toTrackKey == '' then
        -- A fully scratch-internal edge is the one '' conn that realises: a floating
        -- island's intra wire, kept so read can recover it (design § floating islands).
        util.add(routeOf('').intraConns, {
          from = conn.from, fromPort = conn.fromPort,
          to   = conn.to,   toPort   = conn.toPort, type = conn.type,
        })
      end
    end
    return routing
  end

  -- Assemble each per-track spec: trackKind, topo-ordered chain, routed wires, synth nodes.
  -- Track '' is the scratch park; FX-less master is dropped (see docs/DAG.md § Master-minimization).
  local function assembleTracks(trackMembers, nodes, routing, cuTrackKey, synthNodes, mainGain)
    local cusByTrack = {}
    for cuId, trackKey in pairs(cuTrackKey) do
      if trackKey ~= '' then util.bucket(cusByTrack, trackKey, cuId) end
    end
    local function chainOf(members, trackKey)
      local chain = {}
      for _, id in ipairs(members) do
        if isChainMember(nodes[id]) then util.add(chain, id) end
      end
      for _, cuId in ipairs(cusByTrack[trackKey] or {}) do util.add(chain, cuId) end
      return chain
    end

    local tracks = {}
    for trackKey, members in pairs(trackMembers) do
      if trackKey == '' then
        local parked = chainOf(members, '')
        if #parked > 0 then
          -- Floating islands co-resident on scratch: realise each one's intra wiring so read
          -- recovers it; disjoint islands share the chain but never cross (no inter-island conn).
          local route = routing[''] or { intraConns = {} }
          sortIntraConns(route.intraConns)
          tracks['__scratch__'] = {
            trackKind = 'scratch', trackId = nil,
            fxOrder = topoIntraTrack(parked, route.intraConns),
            mainSend = false, outWires = {}, intraConns = route.intraConns,
          }
        end
      else
        local chain = chainOf(members, trackKey)
        local trackKind, trackId = 'newTrack', nil
        for _, id in ipairs(members) do
          local node = nodes[id]
          if node.kind == 'source' then trackKind, trackId = 'sourceTrack', node.trackId end
          if node.kind == 'master' then trackKind = 'master' end
        end
        if trackKind ~= 'master' or #chain > 0 then
          local route = routing[trackKey] or { outWires = {}, intraConns = {}, mainSend = false }
          local synth
          for _, cuId in ipairs(cusByTrack[trackKey] or {}) do
            synth = synth or {}
            synth[cuId] = synthNodes[cuId]
          end
          sortOutWires(route.outWires)
          sortIntraConns(route.intraConns)
          tracks[trackKey] = {
            trackKind = trackKind, trackId = trackId,
            fxOrder = topoIntraTrack(chain, route.intraConns),
            mainSend = route.mainSend, mainSendGain = mainGain[trackKey],
            parentFeed = route.parentFeed,
            outWires = route.outWires, intraConns = route.intraConns,
            synthNodes = synth,
          }
        end
      end
    end
    return tracks
  end

  -- Realisation pass: turns the structural ctx into per-track specs (fxOrder,
  -- wires, synth merge CUs). Reads only the ctx public surface + ctx.userGraph.
  --contract: realisation pass over a compile ctx; returns the targetTracks shape (not cached)
  function DAG.targetTracks(ctx)
    local sendGain, mainGain = nativeGains(ctx)
    local conns, synthNodes, cuTrackKey, nodeTrackKey, pipeMidi = buildConns(ctx)
    local routing = routeByTrack(conns, nodeTrackKey, sendGain)
    local tracks = assembleTracks(ctx:trackMembers(), ctx.userGraph.nodes,
                                  routing, cuTrackKey, synthNodes, mainGain)
    for trackKey, crossings in pairs(pipeMidi) do
      if tracks[trackKey] then tracks[trackKey].pipeMidi = crossings end
    end
    return tracks
  end
end

----- master minimization

-- master class = cone of master's largest dominator whose entry pulls <=1 audio
-- pair per upstream track; one derived split evicts the rest. See docs/DAG.md § Master-minimization.
local function deriveMasterSplit(userGraph)
  local nodes = userGraph.nodes or {}
  local edges = userGraph.edges or {}
  local base = buildCtx(userGraph, {})
  local fwd, rev = base:adjacency().fwd, base:adjacency().rev

  local function reach(start, adj, blocked)
    local seen, stack = { [start] = true }, { start }
    while #stack > 0 do
      for _, nxt in ipairs(adj[table.remove(stack)] or {}) do
        if not seen[nxt] and not (blocked and blocked[nxt]) then
          seen[nxt] = true; stack[#stack + 1] = nxt
        end
      end
    end
    return seen
  end

  -- Forward cones are walked repeatedly (dominators, capacity, the cut) — memoise.
  local cones = {}
  local function coneOf(id)
    if not cones[id] then cones[id] = reach(id, fwd, nil) end
    return cones[id]
  end

  -- fx dominators of master (every source->master path crosses them), largest
  -- cone first. d dominates master iff, with d cut, no source still reaches it.
  local function masterDominators()
    local doms = {}
    for id, node in pairs(nodes) do
      if id ~= 'master' and node.kind == 'fx' and coneOf(id)['master'] then
        local back, dominates = reach('master', rev, { [id] = true }), true
        for up in pairs(back) do
          if nodes[up].kind == 'source' then dominates = false; break end
        end
        if dominates then util.add(doms, id) end
      end
    end
    local coneSize = {}
    for _, id in ipairs(doms) do
      local n = 0
      for _ in pairs(coneOf(id)) do n = n + 1 end
      coneSize[id] = n
    end
    table.sort(doms, function(a, b)
      if coneSize[a] ~= coneSize[b] then return coneSize[a] > coneSize[b] end
      return a < b
    end)
    return doms
  end

  -- dom is the single entry of its cone, so it alone can pull >=2 audio pairs
  -- from one upstream track. see docs/DAG.md § Master-minimization
  local function pullsMultiPair(dom)
    local cone = coneOf(dom)
    local portsByTrack = {}
    for _, e in ipairs(edges) do
      if e.type == 'audio' and e.to == dom and not cone[e.from] then
        local trackKey = base:trackKeyOf(e.from)
        if trackKey ~= '' then
          local ports = portsByTrack[trackKey] or {}
          ports[e.toPort or 1] = true
          portsByTrack[trackKey] = ports
        end
      end
    end
    for _, ports in pairs(portsByTrack) do
      local n = 0
      for _ in pairs(ports) do n = n + 1 end
      if n >= 2 then return true end
    end
    return false
  end

  -- A master-resident node is reachable only via audio parent-send; cross-cone midi can't be
  -- delivered there, so such a dom is ineligible as the cut and gets its own newTrack.
  local function receivesCrossConeMidi(dom)
    local cone = coneOf(dom)
    for _, e in ipairs(edges) do
      if e.type == 'midi' and cone[e.to] and not cone[e.from] then return true end
    end
    return false
  end

  -- The master class is the cone of the largest dominator with a clean entry;
  -- the master node itself (always single-port) when none qualifies.
  local cut = 'master'
  for _, dom in ipairs(masterDominators()) do
    if not pullsMultiPair(dom) and not receivesCrossConeMidi(dom) then cut = dom; break end
  end

  -- No natural master class — a lone source shares it, or nothing reaches
  -- master. Mark master itself so it always owns a dedicated, FX-less class.
  local natural = base:masterTrackClass()
  if not natural then return { master = true } end

  -- Emit the cone marker only when the cone is strictly smaller than master's
  -- natural srcSet class — something needs evicting. One marker peels them all.
  local cone = coneOf(cut)
  for id, cls in pairs(base:classOf()) do
    if cls == natural and not cone[id] then return { [cut] = true } end
  end
  return {}
end

----- bus splice

-- Sub-threshold busses (authored degree < 2×2) splice out before derivation;
-- in×out pairs become direct edges at the product gain. See docs/DAG.md § bus splice.
--shape: spliceProv = { parts = {[splicedIdx]=authoredIdx[]} }  -- a product edge lists every authored tap it folds
local function spliceBusses(userGraph)
  local nodes, edges = userGraph.nodes or {}, userGraph.edges or {}
  local degree = {}
  for id, node in pairs(nodes) do
    if node.kind == 'bus' then degree[id] = { ins = 0, outs = 0 } end
  end
  for _, edge in ipairs(edges) do
    if edge.type == 'audio' then
      local toDeg, fromDeg = degree[edge.to], degree[edge.from]
      if toDeg   then toDeg.ins    = toDeg.ins    + 1 end
      if fromDeg then fromDeg.outs = fromDeg.outs + 1 end
    end
  end
  local sub, subIds = {}, {}
  for id, deg in pairs(degree) do
    if deg.ins < 2 or deg.outs < 2 then sub[id] = true; util.add(subIds, id) end
  end
  if #subIds == 0 then return userGraph end
  table.sort(subIds)  -- deterministic spliced-edge order

  -- Work items carry the authored indexes folded into each edge; splicing a
  -- bus crosses its in-items with its out-items (cycle-free per validate).
  local work = {}
  for idx, edge in ipairs(edges) do
    work[idx] = { edge = edge, parts = { idx } }
  end
  for _, busId in ipairs(subIds) do
    local ins, outs, rest = {}, {}, {}
    for _, item in ipairs(work) do
      if item.edge.to == busId then util.add(ins, item)
      elseif item.edge.from == busId then util.add(outs, item)
      else util.add(rest, item) end
    end
    for _, tapIn in ipairs(ins) do
      for _, tapOut in ipairs(outs) do
        local inGain  = tapIn.edge.ops  and tapIn.edge.ops.gain
        local outGain = tapOut.edge.ops and tapOut.edge.ops.gain
        local gain = (inGain or outGain) and (inGain or 1) * (outGain or 1) or nil
        local parts = {}
        for _, idx in ipairs(tapIn.parts)  do util.add(parts, idx) end
        for _, idx in ipairs(tapOut.parts) do util.add(parts, idx) end
        util.add(rest, { parts = parts, edge = {
          type = 'audio', from = tapIn.edge.from, fromPort = tapIn.edge.fromPort,
          to = tapOut.edge.to, toPort = tapOut.edge.toPort,
          ops = gain and { gain = gain } or nil,
        } })
      end
    end
    work = rest
  end

  local keptNodes, splicedEdges, parts = {}, {}, {}
  for id, node in pairs(nodes) do
    if not sub[id] then keptNodes[id] = node end
  end
  for idx, item in ipairs(work) do
    splicedEdges[idx], parts[idx] = item.edge, item.parts
  end
  return { nodes = keptNodes, edges = splicedEdges }, { parts = parts }
end

--contract: assumes DAG.validate(userGraph)==nil; returns a lazy-caching compile ctx
-- ctx.splice (spliceProv) is present iff sub-threshold busses were spliced out.
function DAG.compile(userGraph)
  local graph, splice = spliceBusses(userGraph)
  local ctx = buildCtx(graph, deriveMasterSplit(graph))
  ctx.splice = splice
  return ctx
end

----- allocate

-- Linear-scan allocator over one stream's value list (audio pair or MIDI bus).
-- see docs/DAG.md § allocStream internals; profile[g] = live count at gap g (capacity crossing weight).
local function allocStream(values, startCursor, N, compare, pinAdd, writeBack, profile)
  local cursor, free, live = startCursor, {}, 0
  -- minReg floors a claim above bus 0: a distinct pipe crossing must never sit on the family's
  -- bus-0 aggregate even when the take has just freed it, or read would mis-merge it (see foldMember).
  local function claim(minReg)
    minReg = minReg or 0
    for i = 1, #free do if free[i] >= minReg then return table.remove(free, i) end end
    local r = cursor >= minReg and cursor or minReg; cursor = r + 1; return r
  end
  -- Sorted-ascending insert so claim() always returns the lowest free register.
  local function release(reg)
    local lo, hi = 1, #free + 1
    while lo < hi do
      local mid = (lo + hi) // 2
      if free[mid] < reg then lo = mid + 1 else hi = mid end
    end
    table.insert(free, lo, reg)
  end
  local releaseAt = {}
  local function placeValue(v)
    local reg
    if v.assignReg ~= nil then
      reg = v.assignReg
      if reg >= cursor then cursor = reg + 1 end
      for i, r in ipairs(free) do if r == reg then table.remove(free, i); break end end
    else
      reg = claim(v.minReg)
    end
    live = live + 1
    for _, p in ipairs(v.pins or {}) do pinAdd(p.fxId, p.dir, p.port, reg) end
    for _, w in ipairs(v.writes or {}) do writeBack(w, reg) end
    if v.lastUse <= N then util.bucket(releaseAt, v.lastUse, reg) end
  end

  local byDef = {}
  for _, v in ipairs(values) do util.bucket(byDef, v.def, v) end
  local function placeDefinedAt(slot)
    if byDef[slot] then
      table.sort(byDef[slot], compare)
      for _, v in ipairs(byDef[slot]) do placeValue(v) end
    end
  end
  placeDefinedAt(0)
  if profile then profile[0] = live end
  for slot = 1, N do
    if releaseAt[slot] then
      for _, r in ipairs(releaseAt[slot]) do release(r); live = live - 1 end
      releaseAt[slot] = nil
    end
    placeDefinedAt(slot)
    if profile then profile[slot] = live end
  end
  return cursor
end

-- Audio packs by pin shape (dir, port, fx) so co-defined values land
-- deterministically; midi has no pins, so lastUse then insertion serial.
local function audioValueCompare(a, c)
  local ap, cp = a.pins[1], c.pins[1]
  if ap.dir ~= cp.dir                 then return ap.dir < cp.dir                 end
  if (ap.port or 1) ~= (cp.port or 1) then return (ap.port or 1) < (cp.port or 1) end
  if ap.fxId ~= cp.fxId               then return ap.fxId < cp.fxId               end
  if a.lastUse ~= c.lastUse           then return a.lastUse < c.lastUse           end
  return a.ord < c.ord
end

local function midiValueCompare(a, c)
  if a.lastUse ~= c.lastUse then return a.lastUse < c.lastUse end
  return a.ord < c.ord
end

-- Keyed group with deterministic first-touch order; `init` is the fresh group.
local function orderedGroup(groups, order, key, init)
  local g = groups[key]
  if not g then g = init; groups[key] = g; util.add(order, key) end
  return g
end

-- Append fn stamping ord = insertion serial, the value-compare tiebreak.
local function ordAppend(list)
  return function(v) v.ord = #list + 1; util.add(list, v) end
end

-- One assignment pass over a fixed partition; returns allocatedTracks + per-track capacity meta.
-- Per-track live-range allocation, one register file per stream (audio pairs b1, midi buses b0).
--contract: outWires/intraConns/parentFeed -> sends+pinMaps+nchan+mainSendOffs.
--contract: nodes=userGraph.nodes; synth CUs ride spec.synthNodes, not nodes
local function allocateOnce(tracks, nodes)
  nodes = nodes or {}
  local fxSetOf, slotOf = {}, {}
  for trackKey, entry in pairs(tracks) do
    fxSetOf[trackKey], slotOf[trackKey] = {}, {}
    for slot, id in ipairs(entry.fxOrder or {}) do
      fxSetOf[trackKey][id], slotOf[trackKey][id] = true, slot
    end
  end

  -- Per-receiver incoming wires (deterministic order) for Stage-2 dstChan claims.
  local incoming = {}
  for senderTrackKey, entry in pairs(tracks) do
    for sendIdx, ow in ipairs(entry.outWires or {}) do
      util.bucket(incoming, ow.to, { wire = ow, senderTrackKey = senderTrackKey, sendIdx = sendIdx })
    end
  end
  -- Parent sends ride the same receiver-decides handshake as ordinary sends but
  -- write OFFS; allocate last so real inputs claim dest pairs first.
  for senderTrackKey, entry in pairs(tracks) do
    local mf = entry.parentFeed
    if entry.mainSend and mf then
      util.bucket(incoming, mf.sink, {
        wire = { toNode = mf.toNode, toPort = mf.toPort, type = 'audio' },
        senderTrackKey = senderTrackKey, isParentSend = true })
    end
  end
  for _, list in pairs(incoming) do
    table.sort(list, function(a, b)
      if a.isParentSend ~= b.isParentSend then return not a.isParentSend end
      if a.senderTrackKey ~= b.senderTrackKey then return a.senderTrackKey < b.senderTrackKey end
      return (a.sendIdx or 0) < (b.sendIdx or 0)
    end)
  end

  -- Pre-init per-track alloc + sends so cross-track Stage-2 write-back has a target.
  local alloc = {}
  for trackKey, entry in pairs(tracks) do
    local sends = {}
    for sendIdx, ow in ipairs(entry.outWires or {}) do
      -- Source-origin audio sends tap raw input pre-FX, freeing pair 1 for the FX
      -- chain's master write; fx-origin sends stay post-FX (read the producer pair).
      local preFx = (ow.type == 'audio' and not fxSetOf[trackKey][ow.from]) or nil
      sends[sendIdx] = { to = ow.to, type = ow.type, gain = ow.gain,
                         srcChan = 0, dstChan = 0, preFx = preFx }
    end
    alloc[trackKey] = { pinMaps = {}, sends = sends, mainSendOffs = entry.mainSend and 0 or nil }
  end

  local meta, perTrack = {}, {}
  local trackKeys = util.keys(tracks)
  table.sort(trackKeys)

  for _, trackKey in ipairs(trackKeys) do
    local entry, slotMap = tracks[trackKey], slotOf[trackKey]
    local state = alloc[trackKey]
    local N = #(entry.fxOrder or {})

    local function pinAdd(fxId, dir, port, pair)
      local pm = state.pinMaps[fxId]
      if not pm then pm = { ins = {}, outs = {} }; state.pinMaps[fxId] = pm end
      local list = pm[dir][port or 1]
      if not list then list = {}; pm[dir][port or 1] = list end
      for _, existing in ipairs(list) do if existing == pair then return end end
      util.add(list, pair)
    end
    -- Uniform flow list: every connection through this track's channel space,
    -- endpoints resolved against the chain once (slot present = chain member).
    --shape: flow = { type, from?, fromPort?, fromSlot?, to?, toPort?, toSlot?, escape?='send'|'feed', sendIdx?, inc?=incoming entry }
    local flows = {}
    for _, ic in ipairs(entry.intraConns or {}) do
      local toSlot = slotMap[ic.to]
      -- Off-chain audio consumer = in-class master feed: rides 'feed' escape like a parent send,
      -- folding into the producer's output value (pinned pair 1, live to N+1).
      util.add(flows, { type = ic.type, escape = (ic.type == 'audio' and not toSlot) and 'feed' or nil,
        from = ic.from, fromPort = ic.fromPort, fromSlot = slotMap[ic.from],
        to   = ic.to,   toPort   = ic.toPort,   toSlot   = toSlot })
    end
    for sendIdx, ow in ipairs(entry.outWires or {}) do
      util.add(flows, { type = ow.type, escape = 'send', sendIdx = sendIdx,
        from = ow.from, fromPort = ow.fromPort, fromSlot = slotMap[ow.from] })
    end
    local mf = entry.parentFeed
    if entry.mainSend and mf then
      util.add(flows, { type = 'audio', escape = 'feed',
        from = mf.from, fromPort = mf.fromPort, fromSlot = slotMap[mf.from] })
    end
    for _, inc in ipairs(incoming[trackKey] or {}) do
      util.add(flows, { type = inc.wire.type, inc = inc, to = inc.wire.toNode,
        toPort = inc.wire.toPort, toSlot = slotMap[inc.wire.toNode] })
    end

    -- Audio assignment outcomes as data: each value's writes land here with its pair.
    local function audioWriteBack(w, pair)
      local chan = (pair - 1) * 2
      if w.kind == 'sendSrc' then state.sends[w.sendIdx].srcChan = chan
      elseif w.kind == 'sendDst' then alloc[w.track].sends[w.sendIdx].dstChan = chan
      else alloc[w.track].mainSendOffs = chan end
    end

    local values = {}
    local addValue = ordAppend(values)

    -- Pair-1 boundary register: raw source (input) shares pair 1 with the chain's master write,
    -- non-overlapping. Master write rides 'feed' into its producer's value; no boundary slot needed.
    local sfPins, sfLastUse = {}, 0
    local feedFlow
    for _, f in ipairs(flows) do
      if f.type == 'audio' then
        if f.escape == 'feed' then feedFlow = f end
        if not f.fromSlot and f.toSlot and not f.inc then
          util.add(sfPins, { fxId = f.to, dir = 'ins', port = f.toPort })
          sfLastUse = math.max(sfLastUse, f.toSlot)
        end
      end
    end
    -- Raw source persists on pair 1 to end-of-chain only to feed the parent send
    -- itself (no fx writer); source-out sends tap pre-FX, so they don't reserve it.
    local srcToMaster = entry.mainSend and not (feedFlow and feedFlow.fromSlot)
    if srcToMaster then sfLastUse = N + 1 end
    if #sfPins > 0 or srcToMaster then
      addValue({ def = 0, lastUse = sfLastUse, pins = sfPins, assignReg = 1 })
    end

    -- One value per fx audio output (fxId, fromPort): one pair shared by every reader.
    -- Boundary-origin sends keep srcChan=0 from pre-init; no value needed for them.
    local producerOuts, producerOrder = {}, {}
    for _, f in ipairs(flows) do
      if f.type == 'audio' and f.fromSlot and (f.toSlot or f.escape) then
        local g = orderedGroup(producerOuts, producerOrder, util.key(f.from, f.fromPort or 1),
          { def = f.fromSlot, lastUse = f.fromSlot, writes = {},
            pins = { { fxId = f.from, dir = 'outs', port = f.fromPort } } })
        if f.toSlot then
          util.add(g.pins, { fxId = f.to, dir = 'ins', port = f.toPort })
          g.lastUse = math.max(g.lastUse, f.toSlot)
        elseif f.escape == 'send' then
          g.lastUse = N + 1
          util.add(g.writes, { kind = 'sendSrc', sendIdx = f.sendIdx })
        else
          -- Pair-1 boundary write -- the in-class master read or a parent send: pin the producer
          -- on pair 1 (NCH=2) live to chain end. A cross-track send's OFFS is set when its sink allocates the pin.
          g.lastUse, g.assignReg = N + 1, 1
        end
      end
    end
    for _, key in ipairs(producerOrder) do addValue(producerOuts[key]) end

    -- Stage-2 incoming audio sends: def=0 (parent send pre-fx), released at toNode's slot.
    -- Same-pin sends share one dest pair — REAPER sums at the pin; see docs/DAG.md § incoming-send coalescing.
    local byPin, pinOrder = {}, {}
    for _, f in ipairs(flows) do
      if f.type == 'audio' and f.inc and f.toSlot then
        local g = orderedGroup(byPin, pinOrder, util.key(f.to, f.toPort or 1),
          { def = 0, lastUse = f.toSlot, writes = {},
            pins = { { fxId = f.to, dir = 'ins', port = f.toPort } } })
        util.add(g.writes, f.inc.isParentSend
          and { kind = 'mainSendOffs', track = f.inc.senderTrackKey }
          or  { kind = 'sendDst', track = f.inc.senderTrackKey, sendIdx = f.inc.sendIdx })
      end
    end
    for _, key in ipairs(pinOrder) do addValue(byPin[key]) end

    local audioProfile = {}
    state.cursor = allocStream(values, 1, N, audioValueCompare, pinAdd, audioWriteBack, audioProfile)

    meta[trackKey] = { N = N, audioUsed = state.cursor - 1, audioProfile = audioProfile }
    perTrack[trackKey] = { entry = entry, state = state, slotMap = slotMap, N = N, flows = flows }
  end

  ----- midi register file (family-wide): the folder pipe makes a parent-send-connected set ONE bus domain.
  -- Bus 0 = merged take aggregate; distinct crossings allocate family-unique. See design/archive/wiring-folders.md § Bus domains.

  -- A foldered child names its parent via parentFeed.sink (a folder conduit, never master).
  local parentOf = {}
  for tk, e in pairs(tracks) do
    local mf = e.parentFeed
    if e.mainSend and mf and mf.sink and mf.sink ~= MASTER and tracks[mf.sink] then
      parentOf[tk] = mf.sink
    end
  end
  local rootOf = {}
  local function familyRoot(tk)
    if not rootOf[tk] then rootOf[tk] = parentOf[tk] and familyRoot(parentOf[tk]) or tk end
    return rootOf[tk]
  end
  local function familyDepth(tk)
    local d, p = 0, tk
    while parentOf[p] do d, p = d + 1, parentOf[p] end
    return d
  end
  local families, familyOrder = {}, {}
  for _, tk in ipairs(trackKeys) do util.add(orderedGroup(families, familyOrder, familyRoot(tk), {}), tk) end

  -- fx -> owning track, for cross-track crossing write-back.
  local trackOfFx = {}
  for tk, e in pairs(tracks) do
    for _, id in ipairs(e.fxOrder or {}) do trackOfFx[id] = tk end
  end

  local midiCtx = {}  -- [tk] = { fxInputBus, fxOutputBus, hasMidiOut, cuIn, cuOut }
  for _, tk in ipairs(trackKeys) do
    midiCtx[tk] = { fxInputBus = {}, fxOutputBus = {}, hasMidiOut = {}, cuIn = {}, cuOut = {} }
  end
  local function isMergeCU(tk, id)
    local sn = tracks[tk].synthNodes and tracks[tk].synthNodes[id]
    return sn ~= nil and sn.params.mode == 'merge'
  end
  local function noteCuIn(tk, consumer, bus)
    if isMergeCU(tk, consumer) then
      local m = midiCtx[tk].cuIn[consumer]
      if not m then m = {}; midiCtx[tk].cuIn[consumer] = m end
      m[bus] = true
    end
  end

  for _, root in ipairs(familyOrder) do
    local members = families[root]
    table.sort(members, function(a, b)
      local da, db = familyDepth(a), familyDepth(b)
      if da ~= db then return da > db end   -- deepest (children) first: a producer precedes its consumer
      return a < b
    end)
    -- Each member owns a contiguous slot block [offset .. offset+N+1]: offset+0 the boundary/take
    -- slot, offset+N+1 the escape sentinel (lastUse past the family end == never released).
    local offset, blockEnd = {}, 0
    for _, tk in ipairs(members) do offset[tk] = blockEnd; blockEnd = blockEnd + perTrack[tk].N + 2 end
    local familyN = blockEnd

    -- Family-wide write-back: each value carries its owning trackKey; a crossing consumer resolves its own.
    local function midiWriteBack(w, bus)
      if w.kind == 'sendSrc' then alloc[w.track].sends[w.sendIdx].srcChan = bus
      elseif w.kind == 'sendDst' then alloc[w.track].sends[w.sendIdx].dstChan = bus
      elseif w.kind == 'busIn' then
        midiCtx[w.track].fxInputBus[w.fxId] = bus; noteCuIn(w.track, w.fxId, bus)
      else -- busProducer: a non-bus-aware JSFX emits on one bus; every reader inherits it
        midiCtx[w.track].fxOutputBus[w.fxId] = bus
        if isMergeCU(w.track, w.fxId) then midiCtx[w.track].cuOut[w.fxId] = bus end
        for _, c in ipairs(w.consumers) do
          local ctk = trackOfFx[c] or w.track
          midiCtx[ctk].fxInputBus[c] = bus; noteCuIn(ctk, c, bus)
        end
      end
    end

    local midiValues = {}
    local addMidiValue = ordAppend(midiValues)
    -- Bus 0 is the family-wide take aggregate (every member's source-take merges here natively).
    local sourceMidi = { def = 0, assignReg = 0, lastUse = 0, writes = {} }
    local producers, producerIds = {}, {}
    local incByNode, incOrder = {}, {}

    local function foldMember(tk)
      local pt = perTrack[tk]
      local off = offset[tk]
      -- A conduit child's bus 0 rides the pipe up and read merges every arrival into the parent, so
      -- every fx producer on a pipe-riding member is floored off bus 0. See docs/DAG.md § Folder parents.
      local ridesPipe = parentOf[tk] ~= nil
      local function fam(slot) return slot and (off + slot) or nil end
      for _, f in ipairs(pt.flows) do
        if f.type == 'midi' then
          local fromSlot, toSlot = fam(f.fromSlot), fam(f.toSlot)
          if f.inc then
            local g = orderedGroup(incByNode, incOrder, f.to, { toSlot = toSlot, writes = {} })
            util.add(g.writes, { kind = 'sendDst', track = f.inc.senderTrackKey, sendIdx = f.inc.sendIdx })
          elseif fromSlot then
            midiCtx[tk].hasMidiOut[f.from] = true
            local g = orderedGroup(producers, producerIds, f.from,
              { def = fromSlot, lastUse = fromSlot, track = tk, writes = {}, consumers = {} })
            if ridesPipe then g.minReg = 1 end
            if f.escape then
              g.lastUse = familyN + 1
              util.add(g.writes, { kind = 'sendSrc', track = tk, sendIdx = f.sendIdx })
            else
              g.lastUse = math.max(g.lastUse, toSlot)
              util.add(g.consumers, f.to)
            end
          elseif f.escape then
            util.add(sourceMidi.writes, { kind = 'sendSrc', track = tk, sendIdx = f.sendIdx })
          elseif toSlot then
            -- Source-midi is always bus 0 — pre-stamp consumers so per-fx values inherit it.
            sourceMidi.lastUse = math.max(sourceMidi.lastUse, toSlot)
            midiCtx[tk].fxInputBus[f.to] = 0; noteCuIn(tk, f.to, 0)
          end
        end
      end
      -- Pipe crossings (the un-gateable identity send). A merge crossing (consumer is the parent
      -- source node) rides bus 0 natively and only holds the aggregate alive into the parent so a
      -- distinct stream cannot reuse bus 0. A distinct crossing folds into its producer's value with
      -- lastUse reaching the consuming parent fx — family-unique by the live-range packing.
      for _, cross in ipairs(pt.entry.pipeMidi or {}) do
        local consumerNode = nodes[cross.consumer]
        if consumerNode and consumerNode.kind == 'source' then
          local pk = cross.consumer
          if offset[pk] then sourceMidi.lastUse = math.max(sourceMidi.lastUse, offset[pk] + perTrack[pk].N + 1) end
        else
          local ctk = trackOfFx[cross.consumer]
          midiCtx[tk].hasMidiOut[cross.from] = true
          local g = orderedGroup(producers, producerIds, cross.from,
            { def = off + pt.slotMap[cross.from], lastUse = off + pt.slotMap[cross.from],
              track = tk, writes = {}, consumers = {} })
          if ridesPipe then g.minReg = 1 end
          if ctk then g.lastUse = math.max(g.lastUse, offset[ctk] + perTrack[ctk].slotMap[cross.consumer]) end
          util.add(g.consumers, cross.consumer)
        end
      end
    end
    for _, tk in ipairs(members) do foldMember(tk) end

    if sourceMidi.lastUse > 0 or #sourceMidi.writes > 0 then
      if #sourceMidi.writes > 0 then sourceMidi.lastUse = familyN + 1 end
      addMidiValue(sourceMidi)
    end
    table.sort(producerIds)
    for _, fxId in ipairs(producerIds) do
      local g = producers[fxId]
      util.add(g.writes, { kind = 'busProducer', track = g.track, fxId = fxId, consumers = g.consumers })
      g.consumers = nil
      addMidiValue(g)
    end
    -- Stage-2 incoming midi sends pinned at the receiver; one node → one bus (REAPER merges on a bus).
    -- In a folder family an incoming send is floored off bus 0 — bus-0 arrival reads back as a phantom native merge.
    local floorIncoming = #members > 1
    for _, toNode in ipairs(incOrder) do
      local g = incByNode[toNode]
      if g.toSlot then util.add(g.writes, { kind = 'busIn', track = trackOfFx[toNode], fxId = toNode }) end
      addMidiValue({ def = 0, lastUse = g.toSlot or (familyN + 1),
                     minReg = floorIncoming and 1 or nil, writes = g.writes })
    end

    local midiProfile = {}
    local midiCursor = allocStream(midiValues, 0, familyN, midiValueCompare, nil, midiWriteBack, midiProfile)
    for _, tk in ipairs(members) do
      meta[tk].midiUsed = midiCursor
      meta[tk].midiProfile = midiProfile
      meta[tk].midiOffset = offset[tk]
      meta[tk].familyRoot = root
    end
  end

  ----- per-track midi post-pass: merge-CU params, native-fx bus surface, JSFX bracket splice.
  for _, trackKey in ipairs(trackKeys) do
    local entry = tracks[trackKey]
    local state = perTrack[trackKey].state
    local mc = midiCtx[trackKey]
    local fxInputBus, fxOutputBus, hasMidiOut = mc.fxInputBus, mc.fxOutputBus, mc.hasMidiOut

    -- Merge CU midi params: inMask = union of feeder buses, outBus = its output bus.
    state.cuMidi = {}
    for _, fxId in ipairs(entry.fxOrder or {}) do
      if isMergeCU(trackKey, fxId) then
        local lanes = { 0, 0, 0, 0 }
        for bus in pairs(mc.cuIn[fxId] or {}) do
          -- Tolerate a transient over-128 bus: an overflowing class may push past lane 4 before
          -- bisection resolves it; this pass is discarded. The final allocation never exceeds 128.
          if bus < 128 then
            local lane = (bus >> 5) + 1
            lanes[lane] = lanes[lane] | (1 << (bus & 31))
          end
        end
        state.cuMidi[fxId] = { inMask = lanes, outBus = mc.cuOut[fxId] or 0 }
      end
    end

    -- Native (non-JS) fx surface their resolved in/out bus for chunk
    -- surgery; brackets handle JS, merge CUs carry their own params.
    state.fxMidiBus = {}
    for _, fxId in ipairs(entry.fxOrder or {}) do
      local node = nodes[fxId]
      if node and node.kind == 'fx' and node.fxIdent and node.fxIdent:sub(1, 3) ~= 'JS:' then
        state.fxMidiBus[fxId] = { inBus = fxInputBus[fxId] or 0, outBus = fxOutputBus[fxId] or 0 }
      end
    end

    ----- bracket post-pass — see docs/DAG.md § allocate
    -- in-park: input→0 (from=-1 silences recv, bus-0 parks on PARK_BUS); out-park restores (retain=0), routes/swallows.
    local splicedFxOrder, bracketNodes = {}, nil
    for _, fxId in ipairs(entry.fxOrder or {}) do
      local node = nodes[fxId]
      local bracketable = entry.trackKind ~= 'scratch'
        and node and node.kind == 'fx'
        and node.fxIdent and node.fxIdent:sub(1, 3) == 'JS:'
        and not node.busAware
      local emitIn, emitOut, inParams, outParams
      if bracketable then
        local midiPorts = node.ports and node.ports.midi
        local canRecv = not midiPorts or (midiPorts.ins  or 0) > 0
        local canSend = not midiPorts or (midiPorts.outs or 0) > 0
        local inBus, outConn = fxInputBus[fxId], hasMidiOut[fxId]
        local outBus = fxOutputBus[fxId] or 0
        local moveIn   = inBus ~= nil and inBus ~= 0
        local blockIn  = canRecv and inBus == nil
        local moveOut  = outConn and outBus ~= 0
        local blockOut = canSend and not outConn
        -- Park bus-0 transit when the fx must not hear it, or when the out-park
        -- would otherwise sweep foreign bus-0 traffic along with the emission.
        local park = moveIn or blockIn or ((moveOut or blockOut) and inBus ~= 0)
        emitIn, emitOut = park, park or moveOut or blockOut
        inParams  = { mode = 'busRoute', from = moveIn and inBus or -1,
                      to = PARK_BUS, retain = 1 }
        outParams = { mode = 'busRoute', from = park and PARK_BUS or -1,
                      to = outConn and outBus or -1, retain = 0 }
      end
      if emitIn then
        bracketNodes = bracketNodes or {}
        local bIn = 'bIn:' .. fxId
        bracketNodes[bIn] = { kind = 'fx', fxIdent = CU_IDENT, params = inParams,
                              originNode = fxId, originSide = 'in' }
        util.add(splicedFxOrder, bIn)
        -- Identity pair-1 pin maps so audio passes through the brackets.
        state.pinMaps[bIn] = { ins = { [1] = { 1 } }, outs = { [1] = { 1 } } }
      end
      util.add(splicedFxOrder, fxId)
      if emitOut then
        bracketNodes = bracketNodes or {}
        local bOut = 'bOut:' .. fxId
        bracketNodes[bOut] = { kind = 'fx', fxIdent = CU_IDENT, params = outParams,
                               originNode = fxId, originSide = 'out' }
        util.add(splicedFxOrder, bOut)
        state.pinMaps[bOut] = { ins = { [1] = { 1 } }, outs = { [1] = { 1 } } }
      end
    end
    state.fxOrder      = bracketNodes and splicedFxOrder or nil
    state.bracketNodes = bracketNodes
  end

  -- Compose: drop intra/out, add sends/pinMaps/nchan. Dedup catches midi sends
  -- to the same dest; audio sends are unique by claim.
  local out = {}
  for trackKey, entry in pairs(tracks) do
    local state = alloc[trackKey]
    local sends, seen = {}, {}
    for _, s in ipairs(state.sends) do
      local k = util.key(s.to, s.type, s.srcChan, s.dstChan, s.preFx)
      if not seen[k] then seen[k] = true; util.add(sends, s) end
    end
    table.sort(sends, function(a, b)
      if a.to      ~= b.to      then return a.to      < b.to      end
      if a.type    ~= b.type    then return a.type    < b.type    end
      if a.srcChan ~= b.srcChan then return a.srcChan < b.srcChan end
      return a.dstChan < b.dstChan
    end)
    for _, pm in pairs(state.pinMaps) do
      for _, dir in ipairs({ 'ins', 'outs' }) do
        for _, list in pairs(pm[dir]) do table.sort(list) end
      end
    end
    local copy = {}
    for k, v in pairs(entry) do
      if k ~= 'outWires' and k ~= 'intraConns' then copy[k] = v end
    end
    if entry.synthNodes then
      local sn = {}
      for cuId, node in pairs(entry.synthNodes) do
        local cm = state.cuMidi and state.cuMidi[cuId]
        if cm then
          sn[cuId] = util.assign({}, node)
          sn[cuId].params = util.assign({}, node.params)
          sn[cuId].params.outBus = cm.outBus
          sn[cuId].params.inMask = cm.inMask
        else
          sn[cuId] = node
        end
      end
      copy.synthNodes = sn
    end
    copy.sends        = sends
    copy.fxMidiBus    = state.fxMidiBus
    copy.pinMaps      = state.pinMaps
    copy.nchan        = math.max(2, (state.cursor - 1) * 2)
    copy.mainSendOffs = state.mainSendOffs
    if state.fxOrder      then copy.fxOrder      = state.fxOrder      end
    if state.bracketNodes then copy.bracketNodes = state.bracketNodes end
    out[trackKey] = copy
  end
  return out, meta
end

----- capacity bisection — design/wiring-implicit-graph.md § Capacity

-- Over-cap classes are bisected along their topo chain at the min-crossing gap (lowest-slot tie-break).
-- Resource-triggered / bandwidth objective; distinct from split-at-node. see docs/DAG.md § Capacity bisection.

local SPLIT_SEP = '#cap#'

-- Cut spec at gap g: fxOrder[1..g] keeps identity; [g+1..] becomes an emergent newTrack.
-- Conns crossing the cut become a forward send; master feed / mainSend follow their producer.
local function bisect(trackKey, spec, g)
  local downSet, upOrder, downOrder = {}, {}, {}
  for i, id in ipairs(spec.fxOrder) do
    if i <= g then util.add(upOrder, id)
    else util.add(downOrder, id); downSet[id] = true end
  end
  local downKey = trackKey .. SPLIT_SEP .. downOrder[1]

  local upIntra, downIntra, upOut, downOut = {}, {}, {}, {}
  for _, ic in ipairs(spec.intraConns or {}) do
    if downSet[ic.to] then
      if downSet[ic.from] then util.add(downIntra, ic)
      else util.add(upOut, { from = ic.from, fromPort = ic.fromPort, to = downKey,
                             toNode = ic.to, toPort = ic.toPort, type = ic.type }) end
    else
      util.add(upIntra, ic)  -- to is up, so from is up too
    end
  end
  for _, ow in ipairs(spec.outWires or {}) do
    util.add(downSet[ow.from] and downOut or upOut, ow)
  end

  local mf = spec.parentFeed
  local feedDown = mf ~= nil and downSet[mf.from] or false
  local upMain  = (mf and not feedDown) or (not mf and spec.mainSend) or false
  local downMain = feedDown

  local upSynth, downSynth
  for cuId, node in pairs(spec.synthNodes or {}) do
    if downSet[cuId] then downSynth = downSynth or {}; downSynth[cuId] = node
    else upSynth = upSynth or {}; upSynth[cuId] = node end
  end

  local upSpec = {
    trackKind = spec.trackKind, trackId = spec.trackId, fxOrder = upOrder,
    mainSend = upMain, mainSendGain = upMain and spec.mainSendGain or nil,
    parentFeed = upMain and mf or nil,
    outWires = upOut, intraConns = upIntra, synthNodes = upSynth,
  }
  local downSpec = {
    trackKind = 'newTrack', trackId = nil, fxOrder = downOrder,
    mainSend = downMain, mainSendGain = downMain and spec.mainSendGain or nil,
    parentFeed = downMain and mf or nil,
    outWires = downOut, intraConns = downIntra, synthNodes = downSynth,
  }
  return upSpec, downSpec, downKey, downSet
end

-- Re-express a folder parent-send as an explicit audio send (leaves the family bus domain).
-- Only folder feeds (sink ~= MASTER) pass here; master sends never convert.
local function toExplicitFeed(spec)
  local pf = spec.parentFeed
  util.add(spec.outWires, { from = pf.from, fromPort = pf.fromPort, to = pf.sink,
                            toNode = pf.toNode, toPort = pf.toPort, type = 'audio',
                            gain = spec.mainSendGain })
  spec.parentFeed, spec.mainSend, spec.mainSendGain = nil, false, nil
end

local function isFolderFeed(spec)
  return spec.parentFeed ~= nil and spec.parentFeed.sink ~= MASTER
end

local function hasMergeCrossing(spec, nodes)
  for _, cross in ipairs(spec.pipeMidi or {}) do
    local n = nodes[cross.consumer]
    if n and n.kind == 'source' then return true end
  end
  return false
end

-- Convert a pipe crossing to an explicit midi send when its producer leaves the family.
-- Bus-0 merges (consumer = parent source node) cannot be reproduced as explicit sends; reaching one here asserts.
local function convertCrossing(spec, cross, nodes, trackOfFx)
  assert(nodes[cross.consumer] and nodes[cross.consumer].kind == 'fx',
    'family eviction cannot move a bus-0 merge crossing off the pipe')
  util.add(spec.outWires, { from = cross.from, to = trackOfFx[cross.consumer],
                            toNode = cross.consumer, type = 'midi' })
end

-- Like bisect, but the down segment leaves the family: its folder feed and pipe crossings
-- go explicit; the pipe-keeping child retains piped crossings. See design/archive/wiring-folders.md § Bus domains.
local function bisectOutOfFamily(trackKey, spec, g, nodes, trackOfFx)
  local up, down, downKey, downSet = bisect(trackKey, spec, g)
  if isFolderFeed(down) then toExplicitFeed(down) end
  local upKeepsPipe = up.mainSend and isFolderFeed(up)
  local upPipe
  for _, cross in ipairs(spec.pipeMidi or {}) do
    if downSet[cross.from] then convertCrossing(down, cross, nodes, trackOfFx)
    elseif upKeepsPipe then upPipe = upPipe or {}; util.add(upPipe, cross)
    else convertCrossing(up, cross, nodes, trackOfFx) end
  end
  up.pipeMidi = upPipe
  return up, down, downKey, downSet
end

-- Pull a leaf member out of its family without splitting: folder feed and crossings go
-- explicit. Used when members are too short to bisect internally.
local function evictMember(spec, nodes, trackOfFx)
  local out = util.assign({}, spec)
  out.outWires = {}
  for _, ow in ipairs(spec.outWires or {}) do util.add(out.outWires, ow) end
  if isFolderFeed(out) then toExplicitFeed(out) end
  out.pipeMidi = nil
  for _, cross in ipairs(spec.pipeMidi or {}) do convertCrossing(out, cross, nodes, trackOfFx) end
  return out
end

local function minCrossingGap(profile, lo, hi)
  local bestGap, bestLive
  for gap = lo, hi do
    if not bestLive or profile[gap] < bestLive then bestGap, bestLive = gap, profile[gap] end
  end
  return bestGap
end

-- A leaf member (nothing parent-sends to it) that is graph-safe to evict whole (no bus-0
-- merge crossing). Deterministic by key.
local function pickEvictableLeaf(members, tracks, nodes)
  local isParent = {}
  for _, tk in ipairs(members) do
    local e = tracks[tk]
    if e.mainSend and e.parentFeed then isParent[e.parentFeed.sink] = true end
  end
  local pick
  for _, tk in ipairs(members) do
    if not isParent[tk] and not hasMergeCrossing(tracks[tk], nodes)
       and (not pick or tk < pick) then pick = tk end
  end
  return pick
end

-- One bisection round. Audio over-cap cuts per track; MIDI over-cap is per FAMILY (folder pipe = ONE
-- bus domain) — at most one eviction per family per round, skipped when an audio cut is pending. nil at fixpoint.
local function splitOverCap(tracks, meta, nodes)
  local trackOfFx, slotOfFx = {}, {}
  for tk, e in pairs(tracks) do
    for slot, id in ipairs(e.fxOrder or {}) do trackOfFx[id] = tk; slotOfFx[id] = slot end
  end

  local cuts, evictions = {}, {}
  for trackKey, m in pairs(meta) do
    if m.audioUsed > CAPACITY.audio and m.N >= 2 then
      cuts[trackKey] = { gap = minCrossingGap(m.audioProfile, 1, m.N - 1) }
    end
  end

  local families = {}
  for tk, m in pairs(meta) do util.bucket(families, m.familyRoot, tk) end
  for _, members in pairs(families) do
    local shared = meta[members[1]]
    local audioCutPending = false
    for _, tk in ipairs(members) do if cuts[tk] then audioCutPending = true end end
    if shared.midiUsed > CAPACITY.midi and not audioCutPending then
      -- A pipe consumer fx must never leave its family — its crossings are still piped to the old parent track.
      -- Floor the cut past the last consumer slot; eviction always falls on the producer side.
      local lastConsumer = {}
      for _, tk in ipairs(members) do
        for _, cross in ipairs(tracks[tk].pipeMidi or {}) do
          local ctk, slot = trackOfFx[cross.consumer], slotOfFx[cross.consumer]
          if ctk and slot then lastConsumer[ctk] = math.max(lastConsumer[ctk] or 0, slot) end
        end
      end
      local bestGap, bestLive, bestMember
      for _, tk in ipairs(members) do
        local mt = meta[tk]
        for g = (lastConsumer[tk] or 0) + 1, mt.N - 1 do
          local fg = mt.midiOffset + g
          if not bestLive or shared.midiProfile[fg] < bestLive then
            bestGap, bestLive, bestMember = g, shared.midiProfile[fg], tk
          end
        end
      end
      if bestMember then cuts[bestMember] = { gap = bestGap, outOfFamily = true }
      else
        local leaf = pickEvictableLeaf(members, tracks, nodes)
        assert(leaf, 'family over MIDI capacity but no graph-safe eviction available')
        evictions[leaf] = true
      end
    end
  end
  if not next(cuts) and not next(evictions) then return nil end

  local out, downByKey = {}, {}
  for trackKey, spec in pairs(tracks) do
    local cut = cuts[trackKey]
    if cut then
      local up, down, downKey, downSet
      if cut.outOfFamily then
        up, down, downKey, downSet = bisectOutOfFamily(trackKey, spec, cut.gap, nodes, trackOfFx)
      else
        up, down, downKey, downSet = bisect(trackKey, spec, cut.gap)
      end
      out[trackKey], out[downKey] = up, down
      downByKey[trackKey] = { key = downKey, set = downSet }
    elseif evictions[trackKey] then
      out[trackKey] = evictMember(spec, nodes, trackOfFx)
    else
      out[trackKey] = spec
    end
  end
  for _, spec in pairs(out) do
    for _, ow in ipairs(spec.outWires or {}) do
      local d = downByKey[ow.to]
      if d and d.set[ow.toNode] then ow.to = d.key end
    end
  end
  return out
end

-- Capacity-resolving allocation: assign, bisect any over-ceiling class/family, re-assign
-- until everything fits. The only entry point; allocateOnce is the inner pass.
function DAG.allocate(tracks, nodes)
  nodes = nodes or {}
  local out, meta = allocateOnce(tracks, nodes)
  local split = splitOverCap(tracks, meta, nodes)
  while split do
    tracks = split
    out, meta = allocateOnce(tracks, nodes)
    split = splitOverCap(tracks, meta, nodes)
  end
  return out
end

return DAG
