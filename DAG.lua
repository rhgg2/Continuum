-- Pure structural calculus for the wiring page: user graph (wires) and
-- lowered graph (port-to-port connections), the lowering that bridges
-- them, and the source-set partition that compiles onto REAPER tracks.
-- M.compile(userGraph) returns a context closing over the lowered graph
-- and lazily caching classes / classOf / inbound / srcSet / quotient
-- / absorption; the user-graph predicates (validate, ancestors,
-- lower) stay free-standing.
-- See design/wiring.md for the model.
-- @noindex

--invariant: M.validate / M.ancestors / M.lower are pure user-graph predicates; every compile-side derivation lives on the ctx returned by M.compile(userGraph), which caches the lowered graph and its derivations lazily
--invariant: REAPER tracks are always stereo; audio I/O is a count of stereo ports, never channels. Two graph shapes — user (wires) and lowered (port-to-port conns); lower() bridges them.
--invariant: every user-graph node carries node.ports = { audio={ins,outs,inNames?,outNames?}, midi={ins,outs} } stamped at construction — source={audio={0,1},midi={0,1}}, master={audio={1,0},midi={0,0}}, fx={audio=probeFxIO,midi={1,1}}. The fx midi={1,1} is the optimistic placeholder until probing can read it. No implicit shapes; M.validate keys off node.ports[edge.type] symmetrically per side.
--invariant: master is a singleton node (id='master'); ports.audio.ins is an explicit integer port count (default 1); no audio outs, no MIDI; terminal-only (never `from`)
--invariant: srcSet and class equivalence are stable under lowering — every Continuum Utility insertion is single-input single-output
--shape: userGraph = { nodes = {[id]=userNode}, edges = edge[], nextId = number }
--shape: userNode = { kind='source'|'fx'|'master', pos={x,y}, ports={audio={ins,outs,inNames?,outNames?}, midi={ins,outs}}, trackGuid?=string, fxIdent?=string, fxDisplay?=string, fxGuid?=string }
--invariant: fxGuid is the node's REAPER incarnation handle on fx-kind nodes (mirrors trackGuid on source-kind). nil until first materialised by the wiring applier; stamped into the node after TrackFX_AddByName succeeds. wm:snapshot and wm:targetState bridge user-graph nodes to REAPER FX instances by this guid.
--shape: edge = { type='audio'|'midi', from=id, fromPort=nil|portIdx, to=id, toPort=nil|portIdx, ops?={gain?=number, channelMap?={[1..16]=1..16}}, primary?=true, opFxGuid?=string }
--invariant: an edge's gain/channelMap op lowers to a CU bridge (kind='fx', fxIdent=CU_IDENT, params={mode=...}, originEdgeIdx, fxGuid=opFxGuid). A gain bridge sitting on the SOLE wire realised as a send (track→track) or the parent/master send folds onto that send's native volume (see ctx:gainSinks) and is dropped from fxOrder — no CU materialised; otherwise the bridge is materialised and the applier stamps opFxGuid back via wm:mutate. channelMap bridges never fold (a send carries no remap).
--shape: lowerGraph = { nodes = {[id]=lowerNode}, conns = conn[] }
--shape: lowerNode = { kind='source'|'fx'|'master', trackGuid?=string, fxIdent?=string, fxGuid?=string, params?=table, originEdgeIdx?=int }; params is the wm-owned param payload on synthesised CU bridges ({mode='gain'|'channelRemap', ...mode-specific}); originEdgeIdx is set on synthesised CU bridges (indexing back into userGraph.edges so the applier can stamp the minted opFxGuid onto the originating edge)
--shape: conn = { type='audio'|'midi', from=id, to=id, fromPort?=number, toPort?=number, primary?=true }
--shape: targetPlan = { [hostKey] = { hostKind='sourceTrack'|'newTrack'|'master'|'scratch', trackGuid?=string, fxOrder=id[], mainSend=bool, sends={ {to=hostKey, type='audio'|'midi'}, ... } } }; hostKey is the classKey for sourceTrack/newTrack hosts, '__scratch__' for parked-inert, '__master__' for the master-hosted class (sentinel because the REAPER master can't carry a project-scoped wiringClass tag the way other tracks can)
local util = require('util')

local CU_IDENT = 'JS:Continuum Utility'

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

----- lower

--contract: assumes M.validate(userGraph)==nil; lowers each wire to one port-to-port (audio) or node-to-node (midi) conn, splicing a CU node per wire-level op
function M.lower(userGraph)
  local lowerGraph = { nodes = {}, conns = {} }
  local cuN = 0

  local function mintCu(cuNode)
    cuN = cuN + 1
    local id = '_cu_' .. cuN
    lowerGraph.nodes[id] = cuNode
    return id
  end

  local function flush(head, targetId, targetPort)
    if head.type == 'audio' then
      util.add(lowerGraph.conns, {
        type = 'audio', from = head.id, to = targetId,
        fromPort = head.port, toPort = targetPort, primary = head.primary,
      })
    else
      util.add(lowerGraph.conns, { type = 'midi', from = head.id, to = targetId,
                                   primary = head.primary })
    end
  end

  -- Splice a CU bridge into the wire: a kind='fx' node carrying
  -- fxIdent=CU_IDENT and the wm-owned params payload. fxGuid is copied
  -- off the source edge so the pipeline can match the bridge across
  -- compiles without index tracking.
  local function splice(head, params, sourceEdge, edgeIdx)
    local id = mintCu({ kind = 'fx', fxIdent = CU_IDENT,
                        fxGuid = sourceEdge.opFxGuid,
                        params = params,
                        originEdgeIdx = edgeIdx })
    flush(head, id, head.type == 'audio' and 1 or nil)
    if head.type == 'audio' then
      return { type = 'audio', id = id, port = 1, primary = head.primary }
    end
    return { type = 'midi', id = id, primary = head.primary }
  end

  local function lowerAudioEdge(edge, edgeIdx)
    local head = { type = 'audio', id = edge.from,
                   port = edge.fromPort or 1, primary = edge.primary }
    if edge.ops and edge.ops.gain then
      head = splice(head, { mode = 'gain', gain = edge.ops.gain }, edge, edgeIdx)
    end
    flush(head, edge.to, edge.toPort or 1)
  end

  local function lowerMidiEdge(edge, edgeIdx)
    local head = { type = 'midi', id = edge.from, primary = edge.primary }
    if edge.ops and edge.ops.channelMap then
      head = splice(head, { mode = 'channelRemap', map = edge.ops.channelMap }, edge, edgeIdx)
    end
    flush(head, edge.to)
  end

  for id, node in pairs(userGraph.nodes or {}) do
    lowerGraph.nodes[id] = util.pick(node, 'kind trackGuid fxIdent fxGuid')
  end
  for edgeIdx, edge in ipairs(userGraph.edges or {}) do
    if edge.type == 'audio' then lowerAudioEdge(edge, edgeIdx)
    else                          lowerMidiEdge(edge, edgeIdx)
    end
  end
  return lowerGraph
end

----- compile context

--contract: assumes M.validate(userGraph)==nil; returns a ctx closing over M.lower(userGraph) with lazy caches for classes, classOf, inbound, srcSet (per-id), quotient, absorption. ctx:srcSet(id) returns the same table across calls (referential cache).
function M.compile(userGraph)
  local lowerGraph = M.lower(userGraph)
  local cache = { srcSet = {} }
  local ctx = {}

  function ctx:graph() return lowerGraph end

  -- Reverse adjacency: for each node id, the list of input-side node ids.
  function ctx:inbound()
    if cache.inbound then return cache.inbound end
    cache.inbound = {}
    for _, conn in ipairs(lowerGraph.conns) do
      util.bucket(cache.inbound, conn.to, conn.from)
    end
    return cache.inbound
  end

  function ctx:srcSet(id)
    if cache.srcSet[id] then return cache.srcSet[id] end
    local set = {}
    local node = lowerGraph.nodes[id]
    if node and node.kind == 'source' and node.trackGuid then
      set[node.trackGuid] = true
    end
    for _, parent in ipairs(self:inbound()[id] or {}) do
      for guid in pairs(self:srcSet(parent)) do set[guid] = true end
    end
    cache.srcSet[id] = set
    return set
  end

  function ctx:classes()
    if cache.classes then return cache.classes end
    cache.classes = {}
    for id in pairs(lowerGraph.nodes) do
      local guids = {}
      for guid in pairs(self:srcSet(id)) do util.add(guids, guid) end
      table.sort(guids)
      util.bucket(cache.classes, table.concat(guids, '|'), id)
    end
    return cache.classes
  end

  function ctx:classOf()
    if cache.classOf then return cache.classOf end
    cache.classOf = {}
    for cls, members in pairs(self:classes()) do
      for _, id in ipairs(members) do cache.classOf[id] = cls end
    end
    return cache.classOf
  end

  function ctx:quotient()
    if cache.quotient then return cache.quotient end
    cache.quotient = {}
    for cls in pairs(self:classes()) do
      cache.quotient[cls] = { audioParents = {}, midiParents = {},
                              audioChildren = {}, midiChildren = {},
                              primaryAudioParents = {} }
    end
    local classOf = self:classOf()
    for _, conn in ipairs(lowerGraph.conns) do
      local fromCls, toCls = classOf[conn.from], classOf[conn.to]
      if fromCls ~= toCls then
        local toQ, fromQ = cache.quotient[toCls], cache.quotient[fromCls]
        if conn.type == 'audio' then
          toQ.audioParents[fromCls] = true
          if conn.primary then toQ.primaryAudioParents[fromCls] = true end
          fromQ.audioChildren[toCls] = true
        else
          toQ.midiParents[fromCls] = true
          fromQ.midiChildren[toCls] = true
        end
      end
    end
    return cache.quotient
  end

  function ctx:absorption()
    if cache.absorption then return cache.absorption end
    local q = self:quotient()

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

    local direct = {}
    for cls, qEntry in pairs(q) do direct[cls] = directHost(qEntry) end

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
  function ctx:masterHostedClass()
    local mc = self:classOf()['master']
    if not mc or mc == '' then return nil end
    for _, id in ipairs(self:classes()[mc]) do
      if lowerGraph.nodes[id].kind == 'source' then return nil end
    end
    return mc
  end

  -- Where each gained wire's volume lands, keyed by originEdgeIdx. If the
  -- bridge sits on the wire that becomes a send (track→track) or the
  -- parent/master send AND is the sole audio contributor there, the gain folds
  -- onto that send's native volume ({kind='send'|'mainSend'}) and no CU
  -- materialises; intra-class routing or several wires collapsing onto one
  -- send keep the CU ({kind='cu'}). targetPlan and wm:pokeEdgeGain share this
  -- one decision so the fold rule lives in a single place.
  function ctx:gainSinks()
    if cache.gainSinks then return cache.gainSinks end
    local classOf = self:classOf()
    local mhc     = self:masterHostedClass()
    local function isMasterDest(conn)
      return conn.to == 'master' or (mhc and classOf[conn.to] == mhc)
    end
    local outConn, masterCount, sendCount = {}, {}, {}
    for _, conn in ipairs(lowerGraph.conns) do
      outConn[conn.from] = outConn[conn.from] or conn
      if conn.type == 'audio' then
        local fromCls, toCls = classOf[conn.from], classOf[conn.to]
        if fromCls and fromCls ~= '' then
          if isMasterDest(conn) then
            masterCount[fromCls] = (masterCount[fromCls] or 0) + 1
          elseif toCls and toCls ~= '' and fromCls ~= toCls then
            local k = fromCls .. '\0' .. toCls
            sendCount[k] = (sendCount[k] or 0) + 1
          end
        end
      end
    end
    local sinks = {}
    for id, node in pairs(lowerGraph.nodes) do
      if node.params and node.params.mode == 'gain' and node.originEdgeIdx then
        local conn    = outConn[id]
        local fromCls = classOf[id]
        local sink    = { kind = 'cu', cuId = id, gain = node.params.gain }
        if conn and fromCls and fromCls ~= '' then
          local toCls = classOf[conn.to]
          if isMasterDest(conn) then
            if masterCount[fromCls] == 1 then sink.kind, sink.cls = 'mainSend', fromCls end
          elseif toCls and toCls ~= '' and fromCls ~= toCls then
            if sendCount[fromCls .. '\0' .. toCls] == 1 then
              sink.kind, sink.from, sink.to = 'send', fromCls, toCls
            end
          end
        end
        sinks[node.originEdgeIdx] = sink
      end
    end
    cache.gainSinks = sinks
    return sinks
  end

  function ctx:capacityErrors()
    local classOf = self:classOf()
    local counts  = {}
    for _, conn in ipairs(lowerGraph.conns) do
      local cls = classOf[conn.from]
      if cls and cls == classOf[conn.to] then
        counts[cls] = counts[cls] or { audio = 0, midi = 0 }
        counts[cls][conn.type] = counts[cls][conn.type] + 1
      end
    end
    local out = {}
    for cls, c in pairs(counts) do
      if c.audio > 64  then util.add(out, { classKey = cls, kind = 'audio', count = c.audio }) end
      if c.midi  > 128 then util.add(out, { classKey = cls, kind = 'midi',  count = c.midi  }) end
    end
    table.sort(out, function(a, b)
      if a.classKey ~= b.classKey then return a.classKey < b.classKey end
      return a.kind < b.kind
    end)
    return out
  end

  -- Topo over intra-class fx/cu members (sources/master excluded —
  -- they don't appear in REAPER FX chains). Kahn's; ties broken by
  -- sorted id for spec determinism. Private to targetPlan.
  local function topoIntraClass(members, cls, folded)
    local classOf = ctx:classOf()
    local memberSet = {}
    for _, id in ipairs(members) do
      local k = lowerGraph.nodes[id].kind
      if k ~= 'source' and k ~= 'master' and not (folded and folded[id]) then
        memberSet[id] = true
      end
    end
    local indeg, succ = {}, {}
    for id in pairs(memberSet) do indeg[id], succ[id] = 0, {} end
    for _, conn in ipairs(lowerGraph.conns) do
      if memberSet[conn.from] and memberSet[conn.to]
         and classOf[conn.from] == cls and classOf[conn.to] == cls then
        indeg[conn.to] = indeg[conn.to] + 1
        util.add(succ[conn.from], conn.to)
      end
    end
    local ready = {}
    for id in pairs(memberSet) do if indeg[id] == 0 then util.add(ready, id) end end
    table.sort(ready)
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
      table.sort(ready)
    end
    return out
  end

  function ctx:targetPlan()
    local allClasses = self:classes()
    local classOf    = self:classOf()
    local plan, masterHosted = {}, {}

    -- Folded bridges (gainSinks) drop from fxOrder; their gain rides the send.
    local folded, sendGain, mainGain = {}, {}, {}
    for _, sink in pairs(self:gainSinks()) do
      if sink.kind == 'send' then
        folded[sink.cuId] = true
        sendGain[sink.from .. '\0' .. sink.to] = sink.gain
      elseif sink.kind == 'mainSend' then
        folded[sink.cuId] = true
        mainGain[sink.cls] = sink.gain
      end
    end

    for cls, members in pairs(allClasses) do
      if cls == '' then
        local parked = {}
        for _, id in ipairs(members) do
          local k = lowerGraph.nodes[id].kind
          if k ~= 'master' and k ~= 'source' then util.add(parked, id) end
        end
        if #parked > 0 then
          table.sort(parked)
          plan['__scratch__'] = {
            hostKind = 'scratch', trackGuid = nil, fxOrder = parked,
            mainSend = false, sends = {},
          }
        end
      else
        local hostKind, trackGuid, hasMaster = 'newTrack', nil, false
        for _, id in ipairs(members) do
          local n = lowerGraph.nodes[id]
          if n.kind == 'source' then hostKind, trackGuid = 'sourceTrack', n.trackGuid end
          if n.kind == 'master' then hasMaster = true end
        end
        if hasMaster and hostKind ~= 'sourceTrack' then
          hostKind = 'master'
          masterHosted[cls] = true
        end
        plan[cls] = {
          hostKind  = hostKind, trackGuid = trackGuid, fxOrder = nil,
          mainSend  = hasMaster and hostKind == 'sourceTrack',
          mainSendGain = mainGain[cls], sends = {},
        }
      end
    end

    local seenSend = {}
    for _, conn in ipairs(lowerGraph.conns) do
      local fromCls, toCls = classOf[conn.from], classOf[conn.to]
      if fromCls ~= toCls and fromCls ~= '' and toCls ~= '' then
        if masterHosted[toCls] then
          if conn.type == 'audio' then plan[fromCls].mainSend = true end
        else
          local key = fromCls .. '|' .. toCls .. '|' .. conn.type
          if not seenSend[key] then
            seenSend[key] = true
            util.add(plan[fromCls].sends, {
              to = toCls, type = conn.type,
              gain = conn.type == 'audio' and sendGain[fromCls .. '\0' .. toCls] or nil,
            })
          end
        end
      end
    end

    for cls, members in pairs(allClasses) do
      if cls ~= '' then
        plan[cls].fxOrder = topoIntraClass(members, cls, folded)
        table.sort(plan[cls].sends, function(a, b)
          if a.to ~= b.to then return a.to < b.to end
          return a.type < b.type
        end)
      end
    end

    -- Stable sentinel key for the master-hosted class so wm:snapshot can
    -- find the matching entry without tagging the REAPER master itself with
    -- a project-scoped wiringClass. At most one class is master-hosted.
    for cls in pairs(masterHosted) do
      plan['__master__'] = plan[cls]
      plan[cls] = nil
    end
    return plan
  end

  return ctx
end

return M
