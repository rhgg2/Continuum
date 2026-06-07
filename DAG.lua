-- Pure structural calculus for the wiring page. M.compile returns a
-- lazy-caching ctx; user-graph predicates stay free-standing. See docs/DAG.md.

-- @noindex

--invariant: M.validate is pure; derivations live on M.compile's ctx
--invariant: REAPER tracks are always stereo; audio I/O is a count of stereo pairs, never channels
--invariant: every user-graph node carries node.ports = { audio={ins,outs,inNames?,outNames?}, midi={ins,outs} } stamped at construction — source={audio={0,1},midi={0,1}}, master={audio={1,0},midi={0,0}}, fx={audio=probeFxIO,midi={1,1}}. The fx midi={1,1} is the optimistic placeholder until probing can read it. No implicit shapes; M.validate keys off node.ports[edge.type] symmetrically per side.
--invariant: master is a singleton node (id='master'); ports.audio.ins is an explicit integer port count (default 1); no audio outs, no MIDI; terminal-only (never `from`)
--shape: userGraph = { nodes = {[id]=userNode}, edges = edge[], nextId = number }
--shape: userNode = { kind='source'|'fx'|'master', pos={x,y}, ports={audio={ins,outs,inNames?,outNames?}, midi={ins,outs}}, trackId?=string, fxIdent?=string, fxDisplay?=string, fxId?=string, busAware?=bool, split?=true }
--invariant: fx nodes carry busAware; wm:addFxNode and M.validate refuse true
--invariant: fxId is nil until materialised; stamped into the node after TrackFX_AddByName succeeds
-- see docs/DAG.md § fxId as incarnation handle
--shape: edge = { type='audio'|'midi', from=id, fromPort=nil|portIdx, to=id, toPort=nil|portIdx, ops?={gain?=number}, primary?=true }
--invariant: edge ops ride as metadata; gain on a sole send-wire folds onto send volume, else CU
-- see docs/DAG.md § CU bridge invariant
--invariant: node.split (fx only): seeds 'split:'..id into srcSet; node+cone get own class/track
--invariant: a split-tagged class never absorbs
--invariant: srcSet unions node.split with derived master-min split markers
--shape: synthNode = { kind='fx', fxIdent=CU_IDENT, fxId?=string, params=table, originNode?=string, originSide?='in'|'out', originConsumer?=string, originTrackKey?=string, inputEdges?=int[] }
-- see docs/DAG.md § synthNode field roles
--shape: outWire = { from=id, fromPort?=int, to=trackKey, toNode=id, toPort?=int, type='audio'|'midi', gain?=number }
--shape: intraConn = { from=id, fromPort?=int, to=id, toPort?=int, type='audio'|'midi' }
--shape: trackSpec = { trackKind='sourceTrack'|'newTrack'|'master'|'scratch', trackId?=string, fxOrder=id[], mainSend=bool, mainSendGain?=number, masterFeed?={from=id, fromPort?=int, toNode=id, toPort?=int}, synthNodes?={[cuId]=synthNode}, outWires=outWire[], intraConns=intraConn[] }
--shape: targetTracks = { [trackKey] = trackSpec }
-- see docs/DAG.md § targetTracks shape
--shape: allocatedSend = { to=trackKey, type='audio'|'midi', gain?=number, srcChan=int, dstChan=int, preFx?=true }; audio src/dstChan are (pair-1)*2, midi are bus 0..127; preFx marks a raw-source-origin (pre-FX) send
--shape: allocatedPinMap = { [fxId] = { ins={[port]={pair,...}}, outs={[port]={pair,...}} } }
--shape: allocatedTracks = { [trackKey] = { trackKind=..., trackId?=..., fxOrder=..., mainSend=..., mainSendGain?=..., masterFeed?=..., sends=allocatedSend[], fxMidiBus?={ [fxId]={inBus,outBus} } (native fx only), pinMaps=allocatedPinMap, nchan=int, mainSendOffs?=int, bracketNodes?={ [bracketId]=synthNode } } }; see docs/DAG.md § allocate for the allocator + bracket model.
local util = require('util')

local CU_IDENT = 'JS:Continuum Utility'
-- Merge CU gain-bank width (utility/Continuum Utility.jsfx). Fan-in past this
-- fans out to a CU cascade; see docs/DAG.md § per-consumer merge.
local MERGE_WIDTH = 16

-- Per-track stream capacity: 64 audio pairs, 128 MIDI buses (REAPER ceilings).
local CAPACITY = { audio = 64, midi = 128 }

-- Stable trackKey for the master-hosted class: the REAPER master carries no
-- wiringTracks entry, so target and snapshot agree on this synthetic key.
local MASTER = '__master__'

local M = {}

----------- PUBLIC

----- validate

--contract: returns nil on success, or { code, ... } describing the first failure; wm:mutate gates persistence on nil
function M.validate(userGraph)
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

----- compile context

-- Lazy ctx factory; derivations memoise into closure-local `cache`.
-- derivedSplits arrives already settled (from deriveMasterSplit); ctx just folds it into srcSet.
local function buildCtx(userGraph, derivedSplits)
  local nodes = userGraph.nodes or {}
  local edges = userGraph.edges or {}
  local cache = { srcSet = {} }
  local ctx = { userGraph = userGraph }

  -- Reverse adjacency: for each node id, the list of input-side node ids.
  local function inbound()
    if cache.inbound then return cache.inbound end
    cache.inbound = {}
    for _, edge in ipairs(edges) do
      util.bucket(cache.inbound, edge.to, edge.from)
    end
    return cache.inbound
  end

  local function srcSet(id)
    if cache.srcSet[id] then return cache.srcSet[id] end
    local set = {}
    local node = nodes[id]
    if node and node.kind == 'source' and node.trackId then
      set[node.trackId] = true
    end
    -- A split marker makes the node its own source: the tag propagates
    -- forward, evicting the node + its cone into their own class.
    if node and (node.split or derivedSplits[id]) then set['split:' .. id] = true end
    for _, parent in ipairs(inbound()[id] or {}) do
      for guid in pairs(srcSet(parent)) do set[guid] = true end
    end
    cache.srcSet[id] = set
    return set
  end

  -- Private: the source-set partition {classKey -> id[]}. Exposed only through
  -- ctx:classOf() and the track-keyed derivations below; never a public seam.
  local function classes()
    if cache.classes then return cache.classes end
    cache.classes, cache.splitClasses = {}, {}
    for id in pairs(nodes) do
      local guids, split = {}, false
      for guid in pairs(srcSet(id)) do
        util.add(guids, guid)
        if guid:sub(1, 6) == 'split:' then split = true end
      end
      table.sort(guids)
      local key = util.key(table.unpack(guids))
      util.bucket(cache.classes, key, id)
      if split then cache.splitClasses[key] = true end
    end
    return cache.classes
  end

  -- Class keys carrying a split tag (a node.split node or its cone). They
  -- never absorb — the split exists to give them their own track.
  local function splitClasses()
    classes()
    return cache.splitClasses
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
                              primaryAudioParents = {} }
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
          fromQ.midiChildren[toCls] = true
        end
      end
    end
    return cache.quotient
  end

  local function absorption()
    if cache.absorption then return cache.absorption end
    local q = quotient()

    -- Direct (one-hop) track for cls under the absorption rule. Returns
    -- nil if cls has no eligible track: zero audio parents, ambiguous
    -- primaries, or multiple non-primary audio parents.
    local function directTrackKey(qEntry)
      local audioParents   = util.keys(qEntry.audioParents)
      local primaryParents = util.keys(qEntry.primaryAudioParents)
      if #primaryParents == 1 then return primaryParents[1] end
      if #primaryParents == 0 and #audioParents == 1 then return audioParents[1] end
      return nil
    end

    local splitClasses = splitClasses()
    local direct = {}
    for cls, qEntry in pairs(q) do
      direct[cls] = not splitClasses[cls] and directTrackKey(qEntry) or nil
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
  -- M.compile marks master split in those cases, so compiled ctx is total. See docs/DAG.md § Master-minimization.
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

  -- The master-hosted class keys to the MASTER sentinel: its track is fixed in
  -- REAPER. Source classes never appear as absorbees (no audio parents).
  function ctx:classTrackKey(cls)
    if cls == self:masterTrackClass() then return MASTER end
    return absorption()[cls] or cls
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

  -- Per gained edge, the volume host (native send/main vol, or kind 'cu');
  -- shared by targetTracks and wm:pokeEdgeGain. See docs/DAG.md § gainHost.
  function ctx:gainHost()
    if cache.gainHost then return cache.gainHost end
    -- The native host a gained edge could land on, with the count key that
    -- decides solubility; nil for untracked-source or same-track edges.
    local function routeOf(edge)
      local from = self:trackKeyOf(edge.from)
      if not from or from == '' then return nil end
      local to = self:trackKeyOf(edge.to)
      if to == MASTER then
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
    for _, edge in ipairs(edges) do
      if edge.type == 'audio' then
        local route = routeOf(edge)
        if route then count[route.key] = (count[route.key] or 0) + 1 end
      end
    end
    local hosts = {}
    for edgeIdx, edge in ipairs(edges) do
      if edge.type == 'audio' and edge.ops and edge.ops.gain then
        local host  = { kind = 'cu', gain = edge.ops.gain }
        local route = routeOf(edge)
        if route and count[route.key] == 1 then util.assign(host, util.pick(route, 'kind cls from to')) end
        hosts[edgeIdx] = host
      end
    end
    cache.gainHost = hosts
    return hosts
  end

  function ctx:capacityErrors()
    local counts  = {}
    for _, edge in ipairs(edges) do
      local fromTrackKey = self:trackKeyOf(edge.from)
      local toTrackKey   = self:trackKeyOf(edge.to)
      if fromTrackKey and fromTrackKey ~= '' and fromTrackKey == toTrackKey then
        counts[fromTrackKey] = counts[fromTrackKey] or { audio = 0, midi = 0 }
        counts[fromTrackKey][edge.type] = counts[fromTrackKey][edge.type] + 1
      end
    end
    local out = {}
    for trackKey, c in pairs(counts) do
      for _, kind in ipairs({ 'audio', 'midi' }) do
        if c[kind] > CAPACITY[kind] then
          util.add(out, { trackKey = trackKey, kind = kind, count = c[kind], budget = CAPACITY[kind] })
        end
      end
    end
    table.sort(out, function(a, b)
      if a.trackKey ~= b.trackKey then return a.trackKey < b.trackKey end
      return a.kind < b.kind
    end)
    return out
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
  -- source/master are the track-IO boundary; only chain members get an fxOrder.
  local function isChainMember(node) return node.kind ~= 'source' and node.kind ~= 'master' end

  -- Partition gained edges: those a native send/main-volume can host (no CU)
  -- from those needing one. Returns the host-marker set + parked native gains.
  local function partitionGains(ctx)
    local hostedNatively, sendGain, mainGain = {}, {}, {}
    for edgeIdx, host in pairs(ctx:gainHost()) do
      if host.kind == 'send' then
        hostedNatively[edgeIdx] = true
        sendGain[util.key(host.from, host.to)] = host.gain
      elseif host.kind == 'mainSend' then
        hostedNatively[edgeIdx] = true
        mainGain[host.cls] = host.gain
      end
    end
    return hostedNatively, sendGain, mainGain
  end

  -- Realise edges into conns + synth merge CUs; audio gain as metadata,
  -- MIDI passes through. See docs/DAG.md § per-consumer merge.
  local function buildConns(ctx, hostedNatively)
    local nodes, edges = ctx.userGraph.nodes, ctx.userGraph.edges
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
    for edgeIdx, edge in ipairs(edges) do
      local conn
      if edge.type == 'midi' then
        conn = { type = 'midi', from = edge.from, to = edge.to }
      else
        local gain = (not hostedNatively[edgeIdx]) and edge.ops and edge.ops.gain or nil
        conn = { type = 'audio', from = edge.from, fromPort = edge.fromPort or 1,
                 to = edge.to, toPort = edge.toPort or 1, gain = gain, edgeIdx = edgeIdx }
      end
      local fromTrackKey, toTrackKey = nodeTrackKey(conn.from), nodeTrackKey(conn.to)
      local group
      if fromTrackKey ~= '' and toTrackKey ~= '' then
        if toTrackKey == MASTER and fromTrackKey ~= MASTER then
          group = groupFor(fromTrackKey, 'master', true)  -- width-1 parent send: pre-sum per producer
        elseif conn.to == 'master' then
          group = groupFor(toTrackKey, 'master', true)    -- in-class master: serial parent send, sum fan-in to one pair
        elseif nodes[conn.to] and nodes[conn.to].kind == 'fx' then
          group = groupFor(toTrackKey, conn.to, false)    -- fx consumer: merge at the consumer trackKey
        end
      end
      if group then util.add(group[conn.type], conn) else util.add(kept, conn) end
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
        for _, f in ipairs(group.audio) do util.add(conns, f) end
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
        -- to one pair. Gains apply at leaves; the root feeds masterFeed.
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
        if mergeN == 1 then firstAudioCu = rootCu end  -- lone CU carries MIDI too
      end

      if not midiCU then
        for _, f in ipairs(group.midi) do util.add(conns, f) end
      else
        -- One N→1 collapse (no width cap — 128-bit mask). Rides the audio CU
        -- only when there's exactly one; a cascade gives MIDI its own CU.
        local cuId = mergeN == 1 and firstAudioCu
                     or mintMerge({ mode = 'merge', nPairs = 1, gains = { 1 }, audioSum = 0 }, nil)
        for _, f in ipairs(group.midi) do util.add(conns, { type = 'midi', from = f.from, to = cuId }) end
        util.add(conns, { type = 'midi', from = cuId, to = group.consumer })
      end
    end

    return conns, synthNodes, cuTrackKey, nodeTrackKey
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
        if fromTrackKey == toTrackKey then
          util.add(route.intraConns, {
            from = conn.from, fromPort = conn.fromPort,
            to   = conn.to,   toPort   = conn.toPort, type = conn.type,
          })
        elseif toTrackKey == MASTER then
          route.mainSend = true
          -- Audio master fan-in arrives pre-merged (≥2 wires → one audioSum CU
          -- output), so masterFeed carries a single producer.
          if conn.type == 'audio' then
            route.masterFeed = { from = conn.from, fromPort = conn.fromPort,
                                 toNode = conn.to, toPort = conn.toPort }
          end
        else
          util.add(route.outWires, {
            from = conn.from, fromPort = conn.fromPort, to = toTrackKey,
            toNode = conn.to, toPort = conn.toPort, type = conn.type,
            gain = conn.type == 'audio' and sendGain[util.key(fromTrackKey, toTrackKey)] or nil,
          })
        end
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
        local parked = chainOf(members, '')  -- '' never carries CUs: sorted, not topo'd
        if #parked > 0 then
          table.sort(parked)
          tracks['__scratch__'] = {
            trackKind = 'scratch', trackId = nil, fxOrder = parked,
            mainSend = false, outWires = {}, intraConns = {},
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
            masterFeed = route.masterFeed,
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
  function M.targetTracks(ctx)
    local hostedNatively, sendGain, mainGain = partitionGains(ctx)
    local conns, synthNodes, cuTrackKey, nodeTrackKey = buildConns(ctx, hostedNatively)
    local routing = routeByTrack(conns, nodeTrackKey, sendGain)
    return assembleTracks(ctx:trackMembers(), ctx.userGraph.nodes,
                          routing, cuTrackKey, synthNodes, mainGain)
  end
end

----- master minimization

-- master class = cone of master's largest dominator whose entry pulls <=1 audio
-- pair per upstream track; one derived split evicts the rest. See docs/DAG.md § Master-minimization.
local function deriveMasterSplit(userGraph)
  local nodes = userGraph.nodes or {}
  local edges = userGraph.edges or {}

  local fwd, rev = {}, {}
  for _, e in ipairs(edges) do
    util.bucket(fwd, e.from, e.to)
    util.bucket(rev, e.to, e.from)
  end

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

  -- fx dominators of master (every source->master path crosses them), largest
  -- cone first. d dominates master iff, with d cut, no source still reaches it.
  local function masterDominators()
    local doms = {}
    for id, node in pairs(nodes) do
      if id ~= 'master' and node.kind == 'fx' and reach(id, fwd, nil)['master'] then
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
      for _ in pairs(reach(id, fwd, nil)) do n = n + 1 end
      coneSize[id] = n
    end
    table.sort(doms, function(a, b)
      if coneSize[a] ~= coneSize[b] then return coneSize[a] > coneSize[b] end
      return a < b
    end)
    return doms
  end

  local base = buildCtx(userGraph, {})

  -- dom is the single entry of its cone, so it alone can pull >=2 audio pairs
  -- from one upstream track. see docs/DAG.md § Master-minimization
  local function pullsMultiPair(dom)
    local cone = reach(dom, fwd, nil)
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

  -- The master class is the cone of the largest dominator with a clean entry;
  -- the master node itself (always single-port) when none qualifies.
  local cut = 'master'
  for _, dom in ipairs(masterDominators()) do
    if not pullsMultiPair(dom) then cut = dom; break end
  end

  -- No natural master class — a lone source shares it, or nothing reaches
  -- master. Mark master itself so it always owns a dedicated, FX-less class.
  local natural = base:masterTrackClass()
  if not natural then return { master = true } end

  -- Emit the cone marker only when the cone is strictly smaller than master's
  -- natural srcSet class — something needs evicting. One marker peels them all.
  local cone = reach(cut, fwd, nil)
  for id, cls in pairs(base:classOf()) do
    if cls == natural and not cone[id] then return { [cut] = true } end
  end
  return {}
end

--contract: assumes M.validate(userGraph)==nil; returns a lazy-caching compile ctx
function M.compile(userGraph)
  return buildCtx(userGraph, deriveMasterSplit(userGraph))
end

----- allocate

-- Linear-scan allocator over one stream's value list (audio pair or MIDI bus).
-- see docs/DAG.md § allocStream internals
local function allocStream(values, startCursor, N, compare, pinAdd)
  local cursor, free = startCursor, {}
  local function claim()
    if free[1] then return table.remove(free, 1) end
    local r = cursor; cursor = r + 1; return r
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
      reg = claim()
    end
    for _, p in ipairs(v.pins or {}) do pinAdd(p.fxId, p.dir, p.port, reg) end
    for _, apply in ipairs(v.applies) do apply(reg) end
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
  for slot = 1, N do
    if releaseAt[slot] then
      for _, r in ipairs(releaseAt[slot]) do release(r) end
      releaseAt[slot] = nil
    end
    placeDefinedAt(slot)
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

-- Per-track live-range allocation, one register file per stream channel:
-- audio pairs (boundary pair 1), midi buses (boundary bus 0). See allocatedTracks shape.
--contract: outWires/intraConns/masterFeed -> sends+pinMaps+nchan+mainSendOffs.
--contract: nodes=userGraph.nodes; synth CUs ride spec.synthNodes, not nodes
function M.allocate(tracks, nodes)
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
    local mf = entry.masterFeed
    if entry.mainSend and mf then
      util.bucket(incoming, MASTER, {
        wire = { toNode = mf.toNode, toPort = mf.toPort, type = 'audio' },
        senderTrackKey = senderTrackKey, isMaster = true })
    end
  end
  for _, list in pairs(incoming) do
    table.sort(list, function(a, b)
      if a.isMaster ~= b.isMaster then return not a.isMaster end
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

  local trackKeys = util.keys(tracks)
  table.sort(trackKeys)

  for _, trackKey in ipairs(trackKeys) do
    local entry, fxSet, slotMap = tracks[trackKey], fxSetOf[trackKey], slotOf[trackKey]
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
    -- Build the value list. ord = insertion serial for stable tiebreak.
    local values, nextOrd = {}, 0
    local function addValue(v) nextOrd = nextOrd + 1; v.ord = nextOrd; util.add(values, v) end

    -- Pair-1 boundary register: source-from (input) and master-to (output)
    -- share pair 1 with non-overlapping lifetimes. See allocatedTracks shape.
    do
      local sfPins, sfLastUse = {}, 0
      local mtPins, mtDef     = {}, math.huge
      for _, ic in ipairs(entry.intraConns or {}) do
        if ic.type == 'audio' then
          if not fxSet[ic.from] and fxSet[ic.to] then
            util.add(sfPins, { fxId = ic.to, dir = 'ins', port = ic.toPort })
            if slotMap[ic.to] > sfLastUse then sfLastUse = slotMap[ic.to] end
          elseif fxSet[ic.from] and not fxSet[ic.to] then
            util.add(mtPins, { fxId = ic.from, dir = 'outs', port = ic.fromPort })
            if slotMap[ic.from] < mtDef then mtDef = slotMap[ic.from] end
          end
        end
      end
      local mf            = entry.masterFeed
      local fxMasterFeed  = entry.mainSend and mf and fxSet[mf.from]
      local hasMasterTo   = #mtPins > 0
      -- Raw source persists on pair 1 to end-of-chain only to feed the parent send
      -- itself (no fx writer); source-out sends tap pre-FX, so they don't reserve it.
      local srcToMaster   = entry.mainSend and not hasMasterTo and not fxMasterFeed
      if srcToMaster then sfLastUse = N + 1 end
      if #sfPins > 0 or srcToMaster then
        addValue({ def = 0, lastUse = sfLastUse, pins = sfPins, assignReg = 1, applies = {} })
      end
      if hasMasterTo then
        addValue({ def = mtDef, lastUse = N + 1, pins = mtPins, assignReg = 1, applies = {} })
      end
    end

    -- One value per fx audio output (fxId, fromPort): the producer writes one
    -- pair, shared by every reader — intra consumers, sends, masterFeed.
    local producerOuts, producerOrder = {}, {}
    local function producerOut(fxId, fromPort)
      local key = util.key(fxId, fromPort or 1)
      local g = producerOuts[key]
      if not g then
        g = { def = slotMap[fxId], lastUse = slotMap[fxId], applies = {},
              pins = { { fxId = fxId, dir = 'outs', port = fromPort } } }
        producerOuts[key] = g
        util.add(producerOrder, key)
      end
      return g
    end

    for _, ic in ipairs(entry.intraConns or {}) do
      if ic.type == 'audio' and fxSet[ic.from] and fxSet[ic.to] then
        local g = producerOut(ic.from, ic.fromPort)
        util.add(g.pins, { fxId = ic.to, dir = 'ins', port = ic.toPort })
        if slotMap[ic.to] > g.lastUse then g.lastUse = slotMap[ic.to] end
      end
    end
    -- Source-out / midi sends keep srcChan=0 from pre-init; no value needed.
    for sendIdx, ow in ipairs(entry.outWires or {}) do
      if ow.type == 'audio' and fxSet[ow.from] then
        local g = producerOut(ow.from, ow.fromPort)
        g.lastUse = N + 1
        util.add(g.applies, function(pair) state.sends[sendIdx].srcChan = (pair - 1) * 2 end)
      end
    end
    -- Parent send reads source pair 1 (NCH=2, no offset), so pin the master-feed
    -- producer there; OFFS is written back when the master track allocates its pin.
    if entry.mainSend then
      local mf = entry.masterFeed
      if mf and fxSet[mf.from] then
        local g = producerOut(mf.from, mf.fromPort)
        g.lastUse, g.assignReg = N + 1, 1
      end
    end
    for _, key in ipairs(producerOrder) do
      local g = producerOuts[key]
      addValue({ def = g.def, lastUse = g.lastUse, pins = g.pins,
                 applies = g.applies, assignReg = g.assignReg })
    end

    -- Stage-2 incoming audio sends: def=0 (parent send pre-fx), released at toNode's slot.
    -- Same-pin sends share one dest pair — REAPER sums at the pin; see docs/DAG.md § incoming-send coalescing.
    if incoming[trackKey] then
      local byPin, pinOrder = {}, {}
      for _, inc in ipairs(incoming[trackKey]) do
        local ow = inc.wire
        if ow.type == 'audio' and fxSet[ow.toNode] then
          local key = util.key(ow.toNode, ow.toPort or 1)
          local g = byPin[key]
          if not g then
            g = { toNode = ow.toNode, toPort = ow.toPort, applies = {} }
            byPin[key] = g; util.add(pinOrder, key)
          end
          local senderTrackKey, sendIdx = inc.senderTrackKey, inc.sendIdx
          util.add(g.applies, inc.isMaster
            and function(pair) alloc[senderTrackKey].mainSendOffs = (pair - 1) * 2 end
            or  function(pair) alloc[senderTrackKey].sends[sendIdx].dstChan = (pair - 1) * 2 end)
        end
      end
      for _, key in ipairs(pinOrder) do
        local g = byPin[key]
        addValue({
          def = 0, lastUse = slotMap[g.toNode],
          pins = { { fxId = g.toNode, dir = 'ins', port = g.toPort } },
          applies = g.applies,
        })
      end
    end

    state.cursor = allocStream(values, 1, N, audioValueCompare, pinAdd)

    ----- midi register file: bus 0 boundary; values are per-producer streams.

    local midiValues, nextMidiOrd = {}, 0
    local function addMidiValue(v) nextMidiOrd = nextMidiOrd + 1; v.ord = nextMidiOrd; util.add(midiValues, v) end

    -- fxInputBus[consumerFxId] = bus the consumer's midi input arrived on; stamped by
    -- source-midi / per-fx producer / stage-2 incoming as their values are assigned.
    local fxInputBus = {}
    local hasMidiOut = {}
    local fxOutputBus = {}

    -- Merge CU midi sink/source tracking: cuIn = union of feeder buses (→ inMask),
    -- cuOut = the CU's own output bus (→ outBus). Stamped alongside fxInputBus.
    local cuIn, cuOut = {}, {}
    local function isMergeCU(id)
      local sn = entry.synthNodes and entry.synthNodes[id]
      return sn ~= nil and sn.params.mode == 'merge'
    end
    local function noteCuIn(consumer, bus)
      if isMergeCU(consumer) then
        local m = cuIn[consumer]; if not m then m = {}; cuIn[consumer] = m end
        m[bus] = true
      end
    end

    -- Source-midi producer pinned to the boundary (bus 0).
    local sourceMidiLastUse, sourceMidiSends, sourceMidiConsumers = 0, {}, {}
    for _, ic in ipairs(entry.intraConns or {}) do
      if ic.type == 'midi' and not fxSet[ic.from] and fxSet[ic.to] then
        if slotMap[ic.to] > sourceMidiLastUse then sourceMidiLastUse = slotMap[ic.to] end
        util.add(sourceMidiConsumers, ic.to)
      end
    end
    -- Source-midi is always bus 0 — pre-stamp so per-fx values defined later inherit it.
    for _, c in ipairs(sourceMidiConsumers) do fxInputBus[c] = 0; noteCuIn(c, 0) end
    for sendIdx, ow in ipairs(entry.outWires or {}) do
      if ow.type == 'midi' and not fxSet[ow.from] then
        util.add(sourceMidiSends, function(bus) state.sends[sendIdx].srcChan = bus end)
      end
    end
    if sourceMidiLastUse > 0 or #sourceMidiSends > 0 then
      local lu = #sourceMidiSends > 0 and (N + 1) or sourceMidiLastUse
      addMidiValue({ def = 0, lastUse = lu, assignReg = 0, applies = sourceMidiSends })
    end

    -- Per-fx producer groups all wires off one fx's midi output: a
    -- non-bus-aware JSFX emits on a single bus regardless of fan-out.
    local fxMidiByProducer = {}
    local function fxMidiProducer(fxId)
      local p = fxMidiByProducer[fxId]
      if not p then
        p = { def = slotMap[fxId], lastUse = slotMap[fxId], applies = {}, consumers = {} }
        fxMidiByProducer[fxId] = p
      end
      return p
    end
    for _, ic in ipairs(entry.intraConns or {}) do
      if ic.type == 'midi' and fxSet[ic.from] then
        hasMidiOut[ic.from] = true
        local p = fxMidiProducer(ic.from)
        if slotMap[ic.to] > p.lastUse then p.lastUse = slotMap[ic.to] end
        util.add(p.consumers, ic.to)
      end
    end
    for sendIdx, ow in ipairs(entry.outWires or {}) do
      if ow.type == 'midi' and fxSet[ow.from] then
        hasMidiOut[ow.from] = true
        local p = fxMidiProducer(ow.from)
        p.lastUse = N + 1
        util.add(p.applies, function(bus) state.sends[sendIdx].srcChan = bus end)
      end
    end
    local fxProducerIds = util.keys(fxMidiByProducer)
    table.sort(fxProducerIds)
    for _, fxId in ipairs(fxProducerIds) do
      local p = fxMidiByProducer[fxId]
      util.add(p.applies, function(bus)
        fxOutputBus[fxId] = bus
        if isMergeCU(fxId) then cuOut[fxId] = bus end
        for _, c in ipairs(p.consumers) do fxInputBus[c] = bus; noteCuIn(c, bus) end
      end)
      addMidiValue({ def = p.def, lastUse = p.lastUse, applies = p.applies })
    end

    -- Stage-2 incoming midi sends pinned at the receiver. Sends to one node coalesce
    -- onto a single bus (REAPER merges midi on a bus); the receiving fx inherits it.
    if incoming[trackKey] then
      local byNode, nodeOrder = {}, {}
      for _, inc in ipairs(incoming[trackKey]) do
        local ow = inc.wire
        if ow.type == 'midi' then
          local toNode = ow.toNode
          local g = byNode[toNode]
          if not g then
            g = { toNode = toNode, applies = {} }
            byNode[toNode] = g; util.add(nodeOrder, toNode)
          end
          local senderTrackKey, sendIdx = inc.senderTrackKey, inc.sendIdx
          util.add(g.applies, function(bus) alloc[senderTrackKey].sends[sendIdx].dstChan = bus end)
        end
      end
      for _, toNode in ipairs(nodeOrder) do
        local g = byNode[toNode]
        util.add(g.applies, function(bus)
          if fxSet[toNode] then fxInputBus[toNode] = bus; noteCuIn(toNode, bus) end
        end)
        addMidiValue({
          def = 0, lastUse = fxSet[toNode] and slotMap[toNode] or (N + 1),
          applies = g.applies,
        })
      end
    end

    allocStream(midiValues, 0, N, midiValueCompare, nil)

    -- Merge CU midi params: inMask = union of feeder buses, outBus = its output bus.
    state.cuMidi = {}
    for _, fxId in ipairs(entry.fxOrder or {}) do
      if isMergeCU(fxId) then
        local lanes = { 0, 0, 0, 0 }
        for bus in pairs(cuIn[fxId] or {}) do
          local lane = (bus >> 5) + 1
          lanes[lane] = lanes[lane] | (1 << (bus & 31))
        end
        state.cuMidi[fxId] = { inMask = lanes, outBus = cuOut[fxId] or 0 }
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
    local splicedFxOrder, bracketNodes = {}, nil
    for _, fxId in ipairs(entry.fxOrder or {}) do
      local node = nodes[fxId]
      local inputBus = fxInputBus[fxId]
      local needs = node and node.kind == 'fx'
        and node.fxIdent and node.fxIdent:sub(1, 3) == 'JS:'
        and not node.busAware
        and inputBus and inputBus ~= 0
      if needs then
        -- in-park routes N→0, parking bus-0 transients on output bus M; out-park swaps 0↔M.
        -- Terminal consumers have no output, so M=N and both sides are the symmetric swap.
        local outputBus = (hasMidiOut[fxId] and fxOutputBus[fxId]) or inputBus
        local bIn, bOut = 'bIn:' .. fxId, 'bOut:' .. fxId
        bracketNodes = bracketNodes or {}
        bracketNodes[bIn]  = { kind = 'fx', fxIdent = CU_IDENT,
                               params = { mode = 'busRoute', from = inputBus, to = outputBus },
                               originNode = fxId, originSide = 'in' }
        bracketNodes[bOut] = { kind = 'fx', fxIdent = CU_IDENT,
                               params = { mode = 'busRoute', from = outputBus, to = outputBus },
                               originNode = fxId, originSide = 'out' }
        util.add(splicedFxOrder, bIn)
        util.add(splicedFxOrder, fxId)
        util.add(splicedFxOrder, bOut)
        -- Identity pair-1 pin maps so audio passes through the brackets.
        state.pinMaps[bIn]  = { ins = { [1] = { 1 } }, outs = { [1] = { 1 } } }
        state.pinMaps[bOut] = { ins = { [1] = { 1 } }, outs = { [1] = { 1 } } }
      else
        util.add(splicedFxOrder, fxId)
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
  return out
end

return M
