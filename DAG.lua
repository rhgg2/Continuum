-- Pure structural calculus for the wiring page. M.compile returns a
-- lazy-caching ctx; user-graph predicates stay free-standing. See docs/DAG.md.

-- @noindex

--invariant: M.validate/M.ancestors/M.descendants are pure; derivations live on M.compile's ctx
--invariant: REAPER tracks are always stereo; audio I/O is a count of stereo pairs, never channels
--invariant: every user-graph node carries node.ports = { audio={ins,outs,inNames?,outNames?}, midi={ins,outs} } stamped at construction — source={audio={0,1},midi={0,1}}, master={audio={1,0},midi={0,0}}, fx={audio=probeFxIO,midi={1,1}}. The fx midi={1,1} is the optimistic placeholder until probing can read it. No implicit shapes; M.validate keys off node.ports[edge.type] symmetrically per side.
--invariant: master is a singleton node (id='master'); ports.audio.ins is an explicit integer port count (default 1); no audio outs, no MIDI; terminal-only (never `from`)
--shape: userGraph = { nodes = {[id]=userNode}, edges = edge[], nextId = number }
--shape: userNode = { kind='source'|'fx'|'master', pos={x,y}, ports={audio={ins,outs,inNames?,outNames?}, midi={ins,outs}}, trackGuid?=string, fxIdent?=string, fxDisplay?=string, fxGuid?=string, busAware?=bool, split?=true }
--invariant: fx nodes carry busAware; wm:addFxNode and M.validate refuse true
--invariant: fxGuid is the node's REAPER incarnation handle on fx-kind nodes (mirrors trackGuid on source-kind). nil until first materialised by the wiring applier; stamped into the node after TrackFX_AddByName succeeds. wm:snapshot and wm:targetState bridge user-graph nodes to REAPER FX instances by this guid.
--shape: edge = { type='audio'|'midi', from=id, fromPort=nil|portIdx, to=id, toPort=nil|portIdx, ops?={gain?=number}, primary?=true }
--invariant: edge ops ride as metadata; gain on a sole send-wire folds onto send volume, else CU
-- see docs/DAG.md § CU bridge invariant
--invariant: node.split (fx only): seeds 'split:'..id into srcSet; node+cone get own class/track
--invariant: a split-tagged class never absorbs
--invariant: srcSet unions node.split with derived master-min split markers
--shape: synthNode = { kind='fx', fxIdent=CU_IDENT, fxGuid?=string, params=table, originNode?=string, originSide?='in'|'out', originConsumer?=string, originHost?=string, inputEdges?=int[] }
-- see docs/DAG.md § synthNode field roles
--shape: outWire = { from=id, fromPort?=int, to=hostKey, toNode=id, toPort?=int, type='audio'|'midi', gain?=number }
--shape: intraConn = { from=id, fromPort?=int, to=id, toPort?=int, type='audio'|'midi' }
--shape: targetPlanEntry = { hostKind='sourceTrack'|'newTrack'|'master'|'scratch', trackGuid?=string, fxOrder=id[], mainSend=bool, mainSendGain?=number, masterFeed?={from=id, fromPort?=int}, synthNodes?={[cuId]=synthNode}, outWires=outWire[], intraConns=intraConn[] }
--shape: targetPlan = { [hostKey] = targetPlanEntry }
-- see docs/DAG.md § targetPlan shape
--shape: allocatedSend = { to=hostKey, type='audio'|'midi', gain?=number, srcChan=int, dstChan=int }; audio src/dstChan are (pair-1)*2, midi are bus 0..127
--shape: allocatedPinMap = { [fxId] = { ins={[port]={pair,...}}, outs={[port]={pair,...}} } }
--shape: allocatedPlan = { [hostKey] = { hostKind=..., trackGuid?=..., fxOrder=..., mainSend=..., mainSendGain?=..., masterFeed?=..., sends=allocatedSend[], fxMidiBus?={ [fxId]={inBus,outBus} } (native fx only), pinMaps=allocatedPinMap, nchan=int, mainSendOffs?=int, bracketNodes?={ [bracketId]=synthNode } } }; see docs/DAG.md § allocate for the allocator + bracket model.
local util = require('util')

local CU_IDENT = 'JS:Continuum Utility'
-- Merge CU gain-bank width (utility/Continuum Utility.jsfx). Fan-in past this
-- fans out to a CU cascade; see docs/DAG.md § per-consumer merge.
local MERGE_WIDTH = 16

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
    if n.kind == 'source' and n.trackGuid then
      local prior = seenGuid[n.trackGuid]
      if prior then
        return { code = 'duplicate_source_guid', guid = n.trackGuid,
                 prior = prior, dup = id }
      end
      seenGuid[n.trackGuid] = id
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
    local function error(code, adds)
      return util.assign({ code = code, edge = i }, adds)
    end
    local fromNode, toNode = nodes[edge.from], nodes[edge.to]
    if not fromNode then return error('unknown_from', { id = edge.from }) end
    if not toNode   then return error('unknown_to',   { id = edge.to   }) end
    if edge.type ~= 'audio' and edge.type ~= 'midi' then
      return error('unknown_edge_type', { type = edge.type })
    end

    -- Port existence per (side, edge.type). One symmetric check
    -- subsumes source-as-sink, master-as-source, midi-to-master,
    -- and "audio edge to an FX with no audio ports."
    local fromOuts = (fromNode.ports[edge.type] or {}).outs or 0
    local toIns    = (toNode.ports[edge.type]   or {}).ins  or 0
    if fromOuts < 1 then
      return error('no_out_port', { id = edge.from, kind = fromNode.kind, type = edge.type })
    end
    if toIns < 1 then
      return error('no_in_port',  { id = edge.to,   kind = toNode.kind,   type = edge.type })
    end

    if edge.type == 'midi' then
      if edge.fromPort ~= nil or edge.toPort ~= nil then return error('midi_port_index') end
    else
      -- nil port = implicit port 1 (single-port shorthand).
      local fromIdx = edge.fromPort or 1
      local toIdx   = edge.toPort   or 1
      if fromIdx < 1 or fromIdx > fromOuts then
        return error('audio_from_port_oob', { want = edge.fromPort, have = fromOuts })
      end
      if toIdx < 1 or toIdx > toIns then
        return error('audio_to_port_oob', { want = edge.toPort, have = toIns })
      end
    end

    local fp = edge.type == 'audio' and (edge.fromPort or 1) or 0
    local tp = edge.type == 'audio' and (edge.toPort   or 1) or 0
    local key = edge.type .. '|' .. edge.from .. '|' .. edge.to
                .. '|' .. fp .. '|' .. tp
    if seen[key] then
      return error('duplicate_edge', { prior = seen[key] })
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

----- ancestors / descendants

-- Backward reachability over the user graph. Used by the wiring page at
-- drag-start to disqualify cycle-forming drop targets: a wire from X to
-- Y closes a cycle iff Y already reaches X — i.e. Y is an ancestor of X.
--contract: set { [id]=true } incl sourceId; backward over userGraph.edges; cycle-safe via visited
function M.ancestors(userGraph, sourceId)
  local out, adj = {}, {}
  for _, edge in ipairs(userGraph.edges or {}) do
    util.bucket(adj, edge.to, edge.from)
  end
  local function visit(id)
    if out[id] then return end
    out[id] = true
    for _, nxt in ipairs(adj[id] or {}) do visit(nxt) end
  end
  visit(sourceId)
  return out
end

-- Forward reachability. Mirror of ancestors; used by wire-redraft to
-- forbid cycle-forming new-source candidates when the user drags the
-- from-end of an existing wire: the new source X must not be reachable
-- from the kept destination B, else X→B closes the cycle B→…→X→B.
--contract: set { [id]=true } incl sourceId; forward over userGraph.edges; cycle-safe via visited
function M.descendants(userGraph, sourceId)
  local out, adj = {}, {}
  for _, edge in ipairs(userGraph.edges or {}) do
    util.bucket(adj, edge.from, edge.to)
  end
  local function visit(id)
    if out[id] then return end
    out[id] = true
    for _, nxt in ipairs(adj[id] or {}) do visit(nxt) end
  end
  visit(sourceId)
  return out
end

----- compile context

-- Lazy ctx factory; derivations memoise into closure-local `cache`.
-- derivedSplits arrives already settled (from deriveMasterSplit); ctx just folds it into srcSet.
local function buildCtx(userGraph, derivedSplits)
  local nodes = userGraph.nodes or {}
  local edges = userGraph.edges or {}
  local cache = { srcSet = {} }
  local ctx = {}

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
    if node and node.kind == 'source' and node.trackGuid then
      set[node.trackGuid] = true
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
      local key = table.concat(guids, '|')
      util.bucket(cache.classes, key, id)
      if split then cache.splitClasses[key] = true end
    end
    return cache.classes
  end

  -- Class keys carrying a split tag (a node.split node or its cone). They
  -- never absorb — the split exists to give them their own host.
  local function splitClasses()
    classes()
    return cache.splitClasses
  end

  local function classOf()
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
    local classOf = classOf()
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

    -- Direct (one-hop) host for cls under the absorption rule. Returns
    -- nil if cls has no eligible host: zero audio parents, ambiguous
    -- primaries, or multiple non-primary audio parents.
    local function directHost(qEntry)
      local audioParents, primaryParents = {}, {}
      for parent in pairs(qEntry.audioParents)        do util.add(audioParents,   parent) end
      for parent in pairs(qEntry.primaryAudioParents) do util.add(primaryParents, parent) end
      if #primaryParents == 1 then return primaryParents[1] end
      if #primaryParents == 0 and #audioParents == 1 then return audioParents[1] end
      return nil
    end

    local splitClasses = splitClasses()
    local direct = {}
    for cls, qEntry in pairs(q) do
      direct[cls] = not splitClasses[cls] and directHost(qEntry) or nil
    end

    local function terminal(cls, seen)
      local next_ = direct[cls]
      if not next_ or seen[next_] then return cls end
      seen[next_] = true
      return terminal(next_, seen)
    end

    cache.absorption = {}
    for cls in pairs(q) do
      if direct[cls] then
        local seen = { [cls] = true }
        cache.absorption[cls] = terminal(direct[cls], seen)
      end
    end
    return cache.absorption
  end

  -- The class hosted ON the REAPER master. nil when a lone source shares
  -- master's class (the source track hosts it, routing via its parent send),
  -- or when nothing reaches master (master parks in class '').
  local function masterHostedClass()
    local mc = classOf()['master']
    if not mc or mc == '' then return nil end
    for _, id in ipairs(classes()[mc]) do
      if nodes[id].kind == 'source' then return nil end
    end
    return mc
  end

  -- The master-hosted class is exempt: its host is fixed in REAPER.
  -- Source classes never appear as absorbees (no audio parents in quotient).
  local function resolveHost(cls)
    if cls == masterHostedClass() then return cls end
    return absorption()[cls] or cls
  end

  -- {[hostCls] = id[]} pooling members of every class that resolves to hostCls.
  local function hostMembers()
    if cache.hostMembers then return cache.hostMembers end
    cache.hostMembers = {}
    for cls, members in pairs(classes()) do
      local host   = resolveHost(cls)
      local bucket = cache.hostMembers[host] or {}
      for _, id in ipairs(members) do util.add(bucket, id) end
      cache.hostMembers[host] = bucket
    end
    for _, bucket in pairs(cache.hostMembers) do table.sort(bucket) end
    return cache.hostMembers
  end

  -- Fold-vs-CU decision for each gained edge. Shared by targetPlan and
  -- wm:pokeEdgeGain. See docs/DAG.md § gainSinks.
  local function gainSinks()
    if cache.gainSinks then return cache.gainSinks end
    local classOf = classOf()
    local mhc     = masterHostedClass()
    local function hostOf(id) return resolveHost(classOf[id]) end
    local function isMasterDest(toId)
      return toId == 'master' or (mhc and classOf[toId] == mhc)
    end
    local masterCount, sendCount = {}, {}
    for _, edge in ipairs(edges) do
      if edge.type == 'audio' then
        local fromH = hostOf(edge.from)
        if fromH and fromH ~= '' then
          if isMasterDest(edge.to) then
            masterCount[fromH] = (masterCount[fromH] or 0) + 1
          else
            local toH = hostOf(edge.to)
            if toH and toH ~= '' and fromH ~= toH then
              local k = fromH .. '\0' .. toH
              sendCount[k] = (sendCount[k] or 0) + 1
            end
          end
        end
      end
    end
    local sinks = {}
    for edgeIdx, edge in ipairs(edges) do
      if edge.type == 'audio' and edge.ops and edge.ops.gain then
        local fromH = hostOf(edge.from)
        local sink  = { kind = 'cu', gain = edge.ops.gain }
        if fromH and fromH ~= '' then
          local toH = hostOf(edge.to)
          if isMasterDest(edge.to) then
            if masterCount[fromH] == 1 then sink.kind, sink.cls = 'mainSend', fromH end
          elseif toH and toH ~= '' and fromH ~= toH then
            if sendCount[fromH .. '\0' .. toH] == 1 then
              sink.kind, sink.from, sink.to = 'send', fromH, toH
            end
          end
        end
        sinks[edgeIdx] = sink
      end
    end
    cache.gainSinks = sinks
    return sinks
  end

  local function capacityErrors()
    local classOf = classOf()
    local counts  = {}
    for _, edge in ipairs(edges) do
      local fromHost = resolveHost(classOf[edge.from])
      local toHost   = resolveHost(classOf[edge.to])
      if fromHost and fromHost ~= '' and fromHost == toHost then
        counts[fromHost] = counts[fromHost] or { audio = 0, midi = 0 }
        counts[fromHost][edge.type] = counts[fromHost][edge.type] + 1
      end
    end
    local out = {}
    for host, c in pairs(counts) do
      if c.audio > 64  then util.add(out, { classKey = host, kind = 'audio', count = c.audio }) end
      if c.midi  > 128 then util.add(out, { classKey = host, kind = 'midi',  count = c.midi  }) end
    end
    table.sort(out, function(a, b)
      if a.classKey ~= b.classKey then return a.classKey < b.classKey end
      return a.kind < b.kind
    end)
    return out
  end

  -- Kahn's over a host's chain members (fx + synth CU; source/master excluded).
  -- Tiebreak: Goodman-Hsu local pressure (outMember - inMember), then id.
  local function topoIntraHost(members, conns)
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

  local function targetPlan()
    local classOf     = classOf()
    local hostMembers = hostMembers()

    -- Folded gains ride a native send (no CU); gainSinks names the sink.
    local folded, sendGain, mainGain = {}, {}, {}
    for edgeIdx, sink in pairs(gainSinks()) do
      if sink.kind == 'send' then
        folded[edgeIdx] = true
        sendGain[sink.from .. '\0' .. sink.to] = sink.gain
      elseif sink.kind == 'mainSend' then
        folded[edgeIdx] = true
        mainGain[sink.cls] = sink.gain
      end
    end

    -- Phase A — edges → conns. Audio gain rides the conn as metadata
    -- (stripped to D_VOL when folded); MIDI passes through unchanged.
    local synthNodes, cuHost, conns, cuN = {}, {}, {}, 0
    local mhc = masterHostedClass()
    local function realHost(id) return resolveHost(classOf[id]) end
    local function hostB(id) return cuHost[id] or realHost(id) end
    local function audioConn(from, fp, to, tp, gain)
      util.add(conns, { type = 'audio', from = from, fromPort = fp or 1,
                        to = to, toPort = tp or 1, gain = gain })
    end
    local function mintCU(host, params, origin)
      cuN = cuN + 1
      local cuId = '_cu_' .. cuN
      synthNodes[cuId] = util.assign({ kind = 'fx', fxIdent = CU_IDENT, params = params }, origin)
      cuHost[cuId] = host
      return cuId
    end
    for edgeIdx, edge in ipairs(edges) do
      local op = edge.ops
      if edge.type == 'midi' then
        util.add(conns, { type = 'midi', from = edge.from, to = edge.to })
      else
        local g = (not folded[edgeIdx]) and op and op.gain or nil
        util.add(conns, { type = 'audio', from = edge.from, fromPort = edge.fromPort or 1,
                          to = edge.to, toPort = edge.toPort or 1, gain = g, edgeIdx = edgeIdx })
      end
    end

    -- Phase B — per-consumer merge. Summing model: matrix (REAPER pins sum free)
    -- or internal (MIDI/width-1 send — CU must sum). See docs/DAG.md § same.
    do
      local units, unitKeys, kept = {}, {}, {}
      local function unit(host, consumer, isParentSend)
        local k = host .. '\0' .. consumer
        local u = units[k]
        if not u then
          u = { host = host, consumer = consumer, isParentSend = isParentSend,
                audio = {}, midi = {} }
          units[k] = u; util.add(unitKeys, k)
        end
        return u
      end
      for _, c in ipairs(conns) do
        local fH, tH = hostB(c.from), hostB(c.to)
        local u
        if fH ~= '' and tH ~= '' then
          if mhc and tH == mhc and fH ~= mhc then
            u = unit(fH, 'master', true)         -- width-1 parent send: pre-sum per producer
          elseif c.to == 'master' then
            u = unit(tH, 'master', true)         -- in-class master: parent send is serial, sum fan-in to one pair
          elseif nodes[c.to] and nodes[c.to].kind == 'fx' then
            u = unit(tH, c.to, false)            -- fx consumer: merge at the consumer host
          end
        end
        if u then util.add(u[c.type], c) else util.add(kept, c) end
      end
      conns = kept

      local function sortFeeders(fs)
        table.sort(fs, function(a, b)
          if a.from ~= b.from then return a.from < b.from end
          if (a.fromPort or 1) ~= (b.fromPort or 1) then return (a.fromPort or 1) < (b.fromPort or 1) end
          return (a.toPort or 1) < (b.toPort or 1)
        end)
      end
      local function anyGained(fs)
        for _, f in ipairs(fs) do if f.gain and f.gain ~= 1 then return true end end
        return false
      end

      table.sort(unitKeys)
      for _, k in ipairs(unitKeys) do
        local u = units[k]
        sortFeeders(u.audio); sortFeeders(u.midi)
        -- Audio: matrix sinks merge only when gained; internal sinks (parent
        -- send) sum on any fan-in ≥2. MIDI: one bus ⇒ merge on any fan-in ≥2.
        local audioCU = u.isParentSend and #u.audio >= 2 or
                        (not u.isParentSend and anyGained(u.audio))
        local midiCU  = #u.midi >= 2

        -- A merge CU is identified by (consumer, host). Fan-in past MERGE_WIDTH
        -- cascades into parallel CUs; each past the first gets a '#N' key suffix.
        local mergeN = 0
        local function mintMerge(params, inputEdges)
          mergeN = mergeN + 1
          local key = mergeN == 1 and u.host or (u.host .. '#' .. mergeN)
          return mintCU(u.host, params,
            { originConsumer = u.consumer, originHost = key, inputEdges = inputEdges })
        end

        local firstAudioCu  -- carries the MIDI merge too, in the single-CU case
        if not audioCU then
          for _, f in ipairs(u.audio) do util.add(conns, f) end
        elseif not u.isParentSend then
          -- Matrix-fed: parallel chunk CUs, each ≤MERGE_WIDTH wide. Every
          -- chunk's outputs route to the consumer's pins, which sum the lot.
          for lo = 1, #u.audio, MERGE_WIDTH do
            local hi = math.min(lo + MERGE_WIDTH - 1, #u.audio)
            local gains, inputEdges = {}, {}
            for i = lo, hi do
              gains[i - lo + 1] = u.audio[i].gain or 1
              util.add(inputEdges, u.audio[i].edgeIdx)
            end
            local cuId = mintMerge(
              { mode = 'merge', nPairs = hi - lo + 1, gains = gains, audioSum = 0 },
              inputEdges)
            firstAudioCu = firstAudioCu or cuId
            for i = lo, hi do
              local f = u.audio[i]
              audioConn(f.from, f.fromPort, cuId, i - lo + 1)
              audioConn(cuId, i - lo + 1, u.consumer, f.toPort)
            end
          end
        else
          -- Parent send (matrix-less): a sum-tree of audioSum CUs reduces fan-in
          -- to one pair. Gains apply at leaves; the root feeds masterFeed.
          local toPort = u.audio[1].toPort
          local level = {}
          for _, f in ipairs(u.audio) do
            util.add(level, { from = f.from, fromPort = f.fromPort,
                              gain = f.gain, edgeIdx = f.edgeIdx })
          end
          local rootCu
          while true do
            local nextLevel = {}
            for lo = 1, #level, MERGE_WIDTH do
              local hi = math.min(lo + MERGE_WIDTH - 1, #level)
              local gains, inputEdges = {}, {}
              for i = lo, hi do
                gains[i - lo + 1] = level[i].gain or 1
                if level[i].edgeIdx then util.add(inputEdges, level[i].edgeIdx) end
              end
              local cuId = mintMerge(
                { mode = 'merge', nPairs = hi - lo + 1, gains = gains, audioSum = 1 },
                #inputEdges > 0 and inputEdges or nil)
              for i = lo, hi do audioConn(level[i].from, level[i].fromPort, cuId, i - lo + 1) end
              util.add(nextLevel, { from = cuId, fromPort = 1 })  -- summed to pair 1
            end
            if #nextLevel == 1 then rootCu = nextLevel[1].from; break end
            level = nextLevel
          end
          audioConn(rootCu, 1, u.consumer, toPort)
          if mergeN == 1 then firstAudioCu = rootCu end  -- lone CU carries MIDI too
        end

        if not midiCU then
          for _, f in ipairs(u.midi) do util.add(conns, f) end
        else
          -- One N→1 collapse (no width cap — 128-bit mask). Rides the audio CU
          -- only when there's exactly one; a cascade gives MIDI its own CU.
          local cuId = mergeN == 1 and firstAudioCu
                       or mintMerge({ mode = 'merge', nPairs = 1, gains = { 1 }, audioSum = 0 }, nil)
          for _, f in ipairs(u.midi) do util.add(conns, { type = 'midi', from = f.from, to = cuId }) end
          util.add(conns, { type = 'midi', from = cuId, to = u.consumer })
        end
      end
    end

    local function hostOf(id) return cuHost[id] or resolveHost(classOf[id]) end

    -- Per-host chain members to topo-order: real fx + synth CU (source/master
    -- never appear in fxOrder; they are the track-IO boundary).
    local chainMembers = {}
    for host, members in pairs(hostMembers) do
      if host ~= '' then
        local list = {}
        for _, id in ipairs(members) do
          local k = nodes[id].kind
          if k ~= 'source' and k ~= 'master' then util.add(list, id) end
        end
        chainMembers[host] = list
      end
    end
    for cuId, host in pairs(cuHost) do
      if host ~= '' then
        chainMembers[host] = chainMembers[host] or {}
        util.add(chainMembers[host], cuId)
      end
    end

    -- Plan entries: scratch for inert fx, else host topology + mainSend.
    local plan, masterHostedHost = {}, nil
    for host, members in pairs(hostMembers) do
      if host == '' then
        local parked = {}
        for _, id in ipairs(members) do
          local k = nodes[id].kind
          if k ~= 'master' and k ~= 'source' then util.add(parked, id) end
        end
        if #parked > 0 then
          table.sort(parked)
          plan['__scratch__'] = {
            hostKind = 'scratch', trackGuid = nil, fxOrder = parked,
            mainSend = false, outWires = {}, intraConns = {},
          }
        end
      else
        local hostKind, trackGuid, hasMaster = 'newTrack', nil, false
        for _, id in ipairs(members) do
          local n = nodes[id]
          if n.kind == 'source' then hostKind, trackGuid = 'sourceTrack', n.trackGuid end
          if n.kind == 'master' then hasMaster = true end
        end
        if hasMaster and hostKind ~= 'sourceTrack' then
          hostKind = 'master'
          masterHostedHost = host
        end
        plan[host] = {
          hostKind  = hostKind, trackGuid = trackGuid, fxOrder = nil,
          mainSend  = hasMaster and hostKind == 'sourceTrack',
          mainSendGain = mainGain[host],
          outWires = {}, intraConns = {},
        }
      end
    end

    -- Same-host conn → intraConn; inter-host → outWire (or mainSend lift to
    -- the master-hosted dest). Inert endpoints (host '') carry no signal.
    for _, conn in ipairs(conns) do
      local fromHost, toHost = hostOf(conn.from), hostOf(conn.to)
      if fromHost and fromHost ~= '' and toHost and toHost ~= '' then
        if fromHost == toHost then
          util.add(plan[fromHost].intraConns, {
            from = conn.from, fromPort = conn.fromPort,
            to   = conn.to,   toPort   = conn.toPort,
            type = conn.type,
          })
        elseif toHost == masterHostedHost then
          plan[fromHost].mainSend = true
          -- Audio master fan-in arrives pre-merged (≥2 wires → one audioSum CU
          -- output), so masterFeed carries a single producer.
          if conn.type == 'audio' then
            plan[fromHost].masterFeed = { from = conn.from, fromPort = conn.fromPort }
          end
        else
          util.add(plan[fromHost].outWires, {
            from = conn.from, fromPort = conn.fromPort,
            to   = toHost,
            toNode = conn.to, toPort = conn.toPort,
            type = conn.type,
            gain = conn.type == 'audio'
                   and sendGain[fromHost .. '\0' .. toHost] or nil,
          })
        end
      end
    end

    -- Attach synth CU nodes to their host (host '' CUs are inert, dropped).
    for cuId, host in pairs(cuHost) do
      if plan[host] then
        plan[host].synthNodes = plan[host].synthNodes or {}
        plan[host].synthNodes[cuId] = synthNodes[cuId]
      end
    end

    -- Topo order each host's chain; deterministic sorts on the wire lists.
    local function cmpOpt(a, b) return (a or 0) < (b or 0) end
    local function neqOpt(a, b) return (a or 0) ~= (b or 0) end
    for host, entry in pairs(plan) do
      if entry.hostKind ~= 'scratch' then
        entry.fxOrder = topoIntraHost(chainMembers[host] or {}, entry.intraConns)
        table.sort(entry.outWires, function(a, b)
          if a.to     ~= b.to     then return a.to     < b.to     end
          if a.type   ~= b.type   then return a.type   < b.type   end
          if a.from   ~= b.from   then return a.from   < b.from   end
          if neqOpt(a.fromPort, b.fromPort) then return cmpOpt(a.fromPort, b.fromPort) end
          if a.toNode ~= b.toNode then return a.toNode < b.toNode end
          return cmpOpt(a.toPort, b.toPort)
        end)
        table.sort(entry.intraConns, function(a, b)
          if a.from ~= b.from then return a.from < b.from end
          if neqOpt(a.fromPort, b.fromPort) then return cmpOpt(a.fromPort, b.fromPort) end
          if a.to   ~= b.to   then return a.to   < b.to   end
          if neqOpt(a.toPort, b.toPort) then return cmpOpt(a.toPort, b.toPort) end
          return a.type < b.type
        end)
      end
    end

    -- Stable sentinel key for the master-hosted class — wm:snapshot can't
    -- tag the REAPER master with a project-scoped wiringClass.
    if masterHostedHost then
      plan['__master__'] = plan[masterHostedHost]
      plan[masterHostedHost] = nil
    end
    return plan
  end

  ----------- PUBLIC SURFACE
  function ctx:classes()           return classes()           end
  function ctx:classOf()           return classOf()           end
  function ctx:masterHostedClass() return masterHostedClass() end
  function ctx:resolveHost(cls)    return resolveHost(cls)    end
  function ctx:gainSinks()         return gainSinks()         end
  function ctx:capacityErrors()    return capacityErrors()    end
  function ctx:targetPlan()        return targetPlan()        end

  return ctx
end

----- master minimization

-- master class = cone of master's largest dominator whose entry pulls <=1 audio
-- pair per upstream host; one derived split evicts the rest. See docs/DAG.md § Master-minimization.
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

  -- d is the single entry of its cone, so it alone can pull >=2 audio pairs
  -- from one upstream host. see docs/DAG.md § Master-minimization
  local function dirty(d)
    local cone, classOf = reach(d, fwd, nil), base:classOf()
    local portsByHost = {}
    for _, e in ipairs(edges) do
      if e.type == 'audio' and e.to == d and not cone[e.from] then
        local host = base:resolveHost(classOf[e.from])
        if host ~= '' then
          local ports = portsByHost[host] or {}
          ports[e.toPort or 1] = true
          portsByHost[host] = ports
        end
      end
    end
    for _, ports in pairs(portsByHost) do
      local n = 0
      for _ in pairs(ports) do n = n + 1 end
      if n >= 2 then return true end
    end
    return false
  end

  -- The master class is the cone of the largest dominator with a clean entry;
  -- the master node itself (always single-port) when none qualifies.
  local cut = 'master'
  for _, d in ipairs(masterDominators()) do
    if not dirty(d) then cut = d; break end
  end

  -- Emit the marker only when the cone is strictly smaller than master's natural
  -- srcSet class — something needs evicting. One marker peels them all.
  local natural = base:masterHostedClass()
  if not natural then return {} end
  local cone = reach(cut, fwd, nil)
  for _, id in ipairs(base:classes()[natural]) do
    if not cone[id] then return { [cut] = true } end
  end
  return {}
end

--contract: assumes M.validate(userGraph)==nil; returns a lazy-caching compile ctx
function M.compile(userGraph)
  return buildCtx(userGraph, deriveMasterSplit(userGraph))
end

----- allocate

-- Per-host live-range allocation, one register file per stream channel:
-- audio pairs (boundary pair 1), midi buses (boundary bus 0). See allocatedPlan shape.
--contract: outWires/intraConns/masterFeed -> sends+pinMaps+nchan+mainSendOffs.
--contract: nodes=userGraph.nodes; synth CUs ride planEntry.synthNodes, not nodes
function M.allocate(plan, nodes)
  nodes = nodes or {}
  local fxSetOf, slotOf = {}, {}
  for hostKey, entry in pairs(plan) do
    fxSetOf[hostKey], slotOf[hostKey] = {}, {}
    for slot, id in ipairs(entry.fxOrder or {}) do
      fxSetOf[hostKey][id], slotOf[hostKey][id] = true, slot
    end
  end

  -- Per-receiver incoming wires (deterministic order) for Stage-2 dstChan claims.
  local incoming = {}
  for senderHost, entry in pairs(plan) do
    for sendIdx, ow in ipairs(entry.outWires or {}) do
      incoming[ow.to] = incoming[ow.to] or {}
      util.add(incoming[ow.to], { wire = ow, senderHost = senderHost, sendIdx = sendIdx })
    end
  end
  for _, list in pairs(incoming) do
    table.sort(list, function(a, b)
      if a.senderHost ~= b.senderHost then return a.senderHost < b.senderHost end
      return a.sendIdx < b.sendIdx
    end)
  end

  -- Pre-init per-host alloc + sends so cross-host Stage-2 write-back has a target.
  local alloc = {}
  for hostKey, entry in pairs(plan) do
    local sends = {}
    for sendIdx, ow in ipairs(entry.outWires or {}) do
      sends[sendIdx] = { to = ow.to, type = ow.type, gain = ow.gain, srcChan = 0, dstChan = 0 }
    end
    alloc[hostKey] = { pinMaps = {}, sends = sends, cursor = 1, free = {},
                       midiCursor = 0, midiFree = {}, mainSendOffs = nil }
  end

  local hostKeys = {}
  for hk in pairs(plan) do util.add(hostKeys, hk) end
  table.sort(hostKeys)

  for _, hostKey in ipairs(hostKeys) do
    local entry, fxSet, slotMap = plan[hostKey], fxSetOf[hostKey], slotOf[hostKey]
    local state = alloc[hostKey]
    local N = #(entry.fxOrder or {})

    local function pinAdd(fxId, dir, port, pair)
      local pm = state.pinMaps[fxId]
      if not pm then pm = { ins = {}, outs = {} }; state.pinMaps[fxId] = pm end
      local list = pm[dir][port or 1]
      if not list then list = {}; pm[dir][port or 1] = list end
      for _, existing in ipairs(list) do if existing == pair then return end end
      util.add(list, pair)
    end
    local function claim()
      if state.free[1] then return table.remove(state.free, 1) end
      local p = state.cursor; state.cursor = p + 1; return p
    end
    -- Sorted-ascending insert so claim() always returns the lowest free pair.
    local function release(pair)
      local lo, hi = 1, #state.free + 1
      while lo < hi do
        local mid = (lo + hi) // 2
        if state.free[mid] < pair then lo = mid + 1 else hi = mid end
      end
      table.insert(state.free, lo, pair)
    end

    -- Build the value list. ord = insertion serial for stable tiebreak.
    local values, nextOrd = {}, 0
    local function addValue(v) nextOrd = nextOrd + 1; v.ord = nextOrd; util.add(values, v) end

    -- Pair-1 boundary register: source-from (input) and master-to (output)
    -- share pair 1 with non-overlapping lifetimes. See allocatedPlan shape.
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
      local hasSourceOut = false
      for _, ow in ipairs(entry.outWires or {}) do
        if ow.type == 'audio' and not fxSet[ow.from] then hasSourceOut = true; break end
      end
      local mf            = entry.masterFeed
      local fxMasterFeed  = entry.mainSend and mf and fxSet[mf.from]
      local hasMasterTo   = #mtPins > 0
      -- Source data persists on pair 1 to end-of-chain when nothing
      -- downstream overwrites it (default mainSend with no fx writer).
      local srcToMaster   = entry.mainSend and not hasMasterTo and not fxMasterFeed
      if hasSourceOut or srcToMaster then sfLastUse = N + 1 end
      if #sfPins > 0 or hasSourceOut or srcToMaster then
        addValue({ def = 0, lastUse = sfLastUse, pins = sfPins, assignPair = 1, apply = function() end })
      end
      if hasMasterTo then
        addValue({ def = mtDef, lastUse = N + 1, pins = mtPins, assignPair = 1, apply = function() end })
      end
    end

    -- One value per fx audio output (fxId, fromPort): the producer writes one
    -- pair, shared by every reader — intra consumers, sends, masterFeed.
    local producerOuts, producerOrder = {}, {}
    local function producerOut(fxId, fromPort)
      local key = fxId .. '\0' .. (fromPort or 1)
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
    if entry.mainSend then
      local mf = entry.masterFeed
      if mf and fxSet[mf.from] then
        local g = producerOut(mf.from, mf.fromPort)
        g.lastUse = N + 1
        util.add(g.applies, function(pair) state.mainSendOffs = (pair - 1) * 2 end)
      else
        state.mainSendOffs = 0
      end
    end
    for _, key in ipairs(producerOrder) do
      local g = producerOuts[key]
      addValue({ def = g.def, lastUse = g.lastUse, pins = g.pins,
                 apply = function(pair) for _, f in ipairs(g.applies) do f(pair) end end })
    end

    -- Stage-2 incoming audio sends pinned at the receiver's fx input.
    -- def=0 (the parent send arrives before any fx runs); released at toNode's slot.
    if incoming[hostKey] then
      for _, inc in ipairs(incoming[hostKey]) do
        local ow = inc.wire
        if ow.type == 'audio' and fxSet[ow.toNode] then
          local senderHost, sendIdx = inc.senderHost, inc.sendIdx
          addValue({
            def = 0, lastUse = slotMap[ow.toNode],
            pins = { { fxId = ow.toNode, dir = 'ins', port = ow.toPort } },
            apply = function(pair) alloc[senderHost].sends[sendIdx].dstChan = (pair - 1) * 2 end,
          })
        end
      end
    end

    -- Bucket by def slot; sort within bucket for determinism.
    local byDef = {}
    for _, v in ipairs(values) do
      byDef[v.def] = byDef[v.def] or {}
      util.add(byDef[v.def], v)
    end
    local function sortBucket(b)
      table.sort(b, function(a, c)
        local ap, cp = a.pins[1], c.pins[1]
        if ap.dir ~= cp.dir                     then return ap.dir < cp.dir                     end
        if (ap.port or 1) ~= (cp.port or 1)     then return (ap.port or 1) < (cp.port or 1)     end
        if ap.fxId ~= cp.fxId                   then return ap.fxId < cp.fxId                   end
        if a.lastUse ~= c.lastUse               then return a.lastUse < c.lastUse               end
        return a.ord < c.ord
      end)
    end

    local releaseAt = {}
    local function processValue(v)
      local pair
      if v.assignPair then
        pair = v.assignPair
        if pair >= state.cursor then state.cursor = pair + 1 end
        -- Source-from may have released pair 1 already; lift it back.
        for i, p in ipairs(state.free) do
          if p == pair then table.remove(state.free, i); break end
        end
      else
        pair = claim()
      end
      for _, p in ipairs(v.pins) do pinAdd(p.fxId, p.dir, p.port, pair) end
      v.apply(pair)
      if v.lastUse <= N then
        releaseAt[v.lastUse] = releaseAt[v.lastUse] or {}
        util.add(releaseAt[v.lastUse], pair)
      end
    end

    if byDef[0] then
      sortBucket(byDef[0])
      for _, v in ipairs(byDef[0]) do processValue(v) end
    end
    for slot = 1, N do
      if releaseAt[slot] then
        for _, p in ipairs(releaseAt[slot]) do release(p) end
        releaseAt[slot] = nil
      end
      if byDef[slot] then
        sortBucket(byDef[slot])
        for _, v in ipairs(byDef[slot]) do processValue(v) end
      end
    end

    ----- midi register file: bus 0 boundary; values are per-producer streams.

    local function midiClaim()
      if state.midiFree[1] then return table.remove(state.midiFree, 1) end
      local b = state.midiCursor; state.midiCursor = b + 1; return b
    end
    local function midiRelease(bus)
      local lo, hi = 1, #state.midiFree + 1
      while lo < hi do
        local mid = (lo + hi) // 2
        if state.midiFree[mid] < bus then lo = mid + 1 else hi = mid end
      end
      table.insert(state.midiFree, lo, bus)
    end

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
      addMidiValue({ def = 0, lastUse = lu, assignBus = 0, applies = sourceMidiSends })
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
    local fxProducerIds = {}
    for fxId in pairs(fxMidiByProducer) do util.add(fxProducerIds, fxId) end
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

    -- Stage-2 incoming midi sends pinned at the receiver; sender's dstChan
    -- stamped, and the receiving fx (if any) inherits the bus as its input.
    if incoming[hostKey] then
      for _, inc in ipairs(incoming[hostKey]) do
        local ow = inc.wire
        if ow.type == 'midi' then
          local senderHost, sendIdx = inc.senderHost, inc.sendIdx
          local toNode = ow.toNode
          local lu = fxSet[toNode] and slotMap[toNode] or (N + 1)
          addMidiValue({
            def = 0, lastUse = lu,
            applies = { function(bus)
              alloc[senderHost].sends[sendIdx].dstChan = bus
              if fxSet[toNode] then fxInputBus[toNode] = bus; noteCuIn(toNode, bus) end
            end },
          })
        end
      end
    end

    local midiByDef = {}
    for _, v in ipairs(midiValues) do
      midiByDef[v.def] = midiByDef[v.def] or {}
      util.add(midiByDef[v.def], v)
    end
    local function midiSortBucket(b)
      table.sort(b, function(a, c)
        if a.lastUse ~= c.lastUse then return a.lastUse < c.lastUse end
        return a.ord < c.ord
      end)
    end
    local midiReleaseAt = {}
    local function processMidiValue(v)
      local bus
      if v.assignBus ~= nil then
        bus = v.assignBus
        if bus >= state.midiCursor then state.midiCursor = bus + 1 end
        for i, b in ipairs(state.midiFree) do
          if b == bus then table.remove(state.midiFree, i); break end
        end
      else
        bus = midiClaim()
      end
      for _, apply in ipairs(v.applies) do apply(bus) end
      if v.lastUse <= N then
        midiReleaseAt[v.lastUse] = midiReleaseAt[v.lastUse] or {}
        util.add(midiReleaseAt[v.lastUse], bus)
      end
    end

    if midiByDef[0] then
      midiSortBucket(midiByDef[0])
      for _, v in ipairs(midiByDef[0]) do processMidiValue(v) end
    end
    for slot = 1, N do
      if midiReleaseAt[slot] then
        for _, b in ipairs(midiReleaseAt[slot]) do midiRelease(b) end
        midiReleaseAt[slot] = nil
      end
      if midiByDef[slot] then
        midiSortBucket(midiByDef[slot])
        for _, v in ipairs(midiByDef[slot]) do processMidiValue(v) end
      end
    end

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

    -- Native (non-JS) fx surface their resolved in/out bus for 3c.3b's chunk
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
  -- to the same dest (all 0/0 until 3c.3); audio sends are unique by claim.
  local out = {}
  for hostKey, entry in pairs(plan) do
    local state = alloc[hostKey]
    local sends, seen = {}, {}
    for _, s in ipairs(state.sends) do
      local k = s.to .. '|' .. s.type .. '|' .. s.srcChan .. '|' .. s.dstChan
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
    out[hostKey] = copy
  end
  return out
end

return M
