-- Pure structural calculus for the wiring page: user graph (wires) and
-- compile graph (port-to-port connections), the lowering that bridges
-- them, and the source-set partition that compiles onto REAPER tracks.
-- M.compile(user) returns a context closing over the lowered graph
-- and lazily caching classes / classOf / inbound / srcSet / quotient
-- / absorption; the user-graph predicates (validate, ancestors,
-- lower) stay free-standing.
-- See design/wiring.md for the model.
-- @noindex

--invariant: M.validate / M.ancestors / M.lower are pure user-graph predicates; every compile-side derivation lives on the ctx returned by M.compile(user), which caches the lowered graph and its derivations lazily
--invariant: REAPER tracks are always stereo; audio I/O is a count of stereo ports, never channels. Two graph shapes — user (wires) and compile (port-to-port conns); lower() bridges them.
--invariant: every user-graph node carries node.audio={ins, outs?} stamped at construction — sources={ins=0,outs=1}, master={ins=1}, fx from probeFxIO. No implicit shapes; readers index node.audio directly. MIDI stays implicit (one port on fx both ways, out-only on sources, none on master).
--invariant: master is a singleton node (id='master'); audio.ins is an explicit integer port count (default 1); no audio outs, no MIDI; terminal-only (never `from`)
--invariant: srcSet and class equivalence are stable under lowering — every Continuum Utility insertion is single-input single-output
--shape: UserGraph = { nodes = {[id]=Node}, edges = Edge[], _nextId = number }
--shape: Node = { kind='source'|'fx'|'master', pos={x,y}, audio={ins=number, outs?=number}, trackGuid?=string, fxIdent?=string, fxDisplay?=string, fxGuid?=string }
--invariant: fxGuid is the node's REAPER incarnation handle on fx-kind nodes (mirrors trackGuid on source-kind). nil until first materialised by the wiring applier; stamped into the node after TrackFX_AddByName succeeds. wm:snapshot and wm:targetState bridge user-graph nodes to REAPER FX instances by this guid.
--shape: Edge = { type='audio'|'midi', from=id, fromPort=nil|portIdx, to=id, toPort=nil|portIdx, ops?={gain?=number, channelMap?={[1..16]=1..16}}, primary?=true, _opFxGuid?=string }
--invariant: when an edge carries ops (gain / channelMap), lower splices one CU bridge per op-bundle into the wire — a kind='fx' compile node with fxIdent=CU_IDENT and a wm-owned params payload ({mode='gain'|'channelRemap', ...}). _opFxGuid is the CU instance's bridge identity in REAPER; lower copies it onto the bridge's fxGuid, and the applier stamps it back via wm:mutate after TrackFX_AddByName (mirrors node.fxGuid on user-graph fx nodes).
--shape: CompileGraph = { nodes = {[id]=CompileNode}, conns = Conn[] }
--shape: CompileNode = { kind='source'|'fx'|'master', trackGuid?=string, fxIdent?=string, fxGuid?=string, params?=table }; params is the wm-owned param payload on synthesised CU bridges ({mode='gain'|'channelRemap', ...mode-specific})
--shape: Conn = { type='audio'|'midi', from=id, to=id, fromPort?=number, toPort?=number, primary?=true }
--shape: TargetPlan = { [hostKey] = { hostKind='sourceTrack'|'newTrack'|'master'|'scratch', trackGuid?=string, fxOrder=id[], mainSend=bool, sends={ {to=hostKey, type='audio'|'midi'}, ... } } }; hostKey is the classKey for real classes or the sentinel '__scratch__' for the parked-inert pool
local util = require('util')

local CU_IDENT = 'JS:Continuum Utility'

local M = {}

----- Strip user-graph fields the compile graph doesn't need (pos,
-- fxDisplay, the audio shape).
local function passthroughNode(node)
  return { kind      = node.kind,
           trackGuid = node.trackGuid,
           fxIdent   = node.fxIdent }
end

----- Private compile-side helpers (consumed by ctx)

-- Reverse adjacency: for each node id, the list of input-side node ids.
local function inboundOf(compile)
  local inbound = {}
  for _, conn in ipairs(compile.conns) do
    util.bucket(inbound, conn.to, conn.from)
  end
  return inbound
end

local function classesOf(compile, srcSetFor)
  local out = {}
  for id in pairs(compile.nodes) do
    local guids = {}
    for guid in pairs(srcSetFor(id)) do util.add(guids, guid) end
    table.sort(guids)
    util.bucket(out, table.concat(guids, '|'), id)
  end
  return out
end

local function classOfMap(classes)
  local out = {}
  for cls, members in pairs(classes) do
    for _, id in ipairs(members) do out[id] = cls end
  end
  return out
end

local function quotientGraphOf(compile, classOf, classes)
  local quotient = {}
  for cls in pairs(classes) do
    quotient[cls] = { audioParents = {}, midiParents = {},
                      audioChildren = {}, midiChildren = {},
                      primaryAudioParents = {} }
  end
  for _, conn in ipairs(compile.conns) do
    local fromCls, toCls = classOf[conn.from], classOf[conn.to]
    if fromCls ~= toCls then
      local toQ, fromQ = quotient[toCls], quotient[fromCls]
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
  return quotient
end

-- Direct (one-hop) host for cls under the absorption rule. Returns nil
-- if cls has no eligible host: zero audio parents, ambiguous primaries,
-- or multiple non-primary audio parents.
local function directHost(q)
  local audioParents, primaryParents = {}, {}
  for parent in pairs(q.audioParents)        do util.add(audioParents,   parent) end
  for parent in pairs(q.primaryAudioParents) do util.add(primaryParents, parent) end
  if #primaryParents == 1 then return primaryParents[1] end
  if #primaryParents == 0 and #audioParents == 1 then return audioParents[1] end
  return nil
end

local function absorptionOf(quotient)
  local direct = {}
  for cls, q in pairs(quotient) do direct[cls] = directHost(q) end

  local function terminal(cls, seen)
    local next_ = direct[cls]
    if not next_ or seen[next_] then return cls end
    seen[next_] = true
    return terminal(next_, seen)
  end

  local out = {}
  for cls in pairs(quotient) do
    if direct[cls] then
      local seen = { [cls] = true }
      out[cls] = terminal(direct[cls], seen)
    end
  end
  return out
end

local function capacityErrorsOf(compile, classOf)
  local counts = {}
  for _, conn in ipairs(compile.conns) do
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

-- Topo over intra-class fx/cu members (sources/master excluded — they
-- don't appear in REAPER FX chains). Kahn's; ties broken by sorted id
-- for spec determinism.
local function topoIntraClass(compile, members, classOf, cls)
  local memberSet = {}
  for _, id in ipairs(members) do
    local k = compile.nodes[id].kind
    if k ~= 'source' and k ~= 'master' then memberSet[id] = true end
  end
  local indeg, succ = {}, {}
  for id in pairs(memberSet) do indeg[id], succ[id] = 0, {} end
  for _, conn in ipairs(compile.conns) do
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

local function targetPlanOf(compile, classes, classOf)
  local plan, masterHosted = {}, {}

  for cls, members in pairs(classes) do
    if cls == '' then
      local parked = {}
      for _, id in ipairs(members) do
        local k = compile.nodes[id].kind
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
        local n = compile.nodes[id]
        if n.kind == 'source' then hostKind, trackGuid = 'sourceTrack', n.trackGuid end
        if n.kind == 'master' then hasMaster = true end
      end
      if hasMaster and hostKind == 'newTrack' then
        hostKind = 'master'
        masterHosted[cls] = true
      end
      plan[cls] = {
        hostKind  = hostKind, trackGuid = trackGuid, fxOrder = nil,
        mainSend  = hasMaster and hostKind ~= 'master', sends = {},
      }
    end
  end

  local seenSend = {}
  for _, conn in ipairs(compile.conns) do
    local fromCls, toCls = classOf[conn.from], classOf[conn.to]
    if fromCls ~= toCls and fromCls ~= '' and toCls ~= '' then
      if masterHosted[toCls] then
        if conn.type == 'audio' then plan[fromCls].mainSend = true end
      else
        local key = fromCls .. '|' .. toCls .. '|' .. conn.type
        if not seenSend[key] then
          seenSend[key] = true
          util.add(plan[fromCls].sends, { to = toCls, type = conn.type })
        end
      end
    end
  end

  for cls, members in pairs(classes) do
    if cls ~= '' then
      plan[cls].fxOrder = topoIntraClass(compile, members, classOf, cls)
      table.sort(plan[cls].sends, function(a, b)
        if a.to ~= b.to then return a.to < b.to end
        return a.type < b.type
      end)
    end
  end
  return plan
end

----------- PUBLIC

----- validate

--contract: returns nil on success, or { code, ... } describing the first failure; wm:mutate gates persistence on nil
function M.validate(user)
  local nodes, edges = user.nodes or {}, user.edges or {}

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
    local fromNode, toNode = nodes[edge.from], nodes[edge.to]
    if not fromNode then
      return { code = 'unknown_from', edge = i, id = edge.from }
    end
    if not toNode then
      return { code = 'unknown_to', edge = i, id = edge.to }
    end
    if toNode.kind == 'source' then
      return { code = 'source_as_sink', edge = i, id = edge.to }
    end
    if fromNode.kind == 'master' then
      return { code = 'master_as_source', edge = i, id = edge.from }
    end
    if edge.type == 'midi' and toNode.kind == 'master' then
      return { code = 'midi_to_master', edge = i }
    end

    if edge.type == 'midi' then
      if edge.fromPort ~= nil or edge.toPort ~= nil then
        return { code = 'midi_port_index', edge = i }
      end
    elseif edge.type == 'audio' then
      local fromOuts = fromNode.audio.outs or 0
      local toIns    = toNode.audio.ins   or 0
      -- nil port = implicit port 1 (single-port shorthand).
      local fromIdx = (fromOuts > 0) and (edge.fromPort or 1) or nil
      local toIdx   = (toIns    > 0) and (edge.toPort   or 1) or nil
      if not fromIdx or fromIdx < 1 or fromIdx > fromOuts then
        return { code = 'audio_from_port_oob', edge = i,
                 want = edge.fromPort, have = fromOuts }
      end
      if not toIdx or toIdx < 1 or toIdx > toIns then
        return { code = 'audio_to_port_oob', edge = i,
                 want = edge.toPort, have = toIns }
      end
    else
      return { code = 'unknown_edge_type', edge = i, type = edge.type }
    end

    local fp = edge.type == 'audio' and (edge.fromPort or 1) or 0
    local tp = edge.type == 'audio' and (edge.toPort   or 1) or 0
    local key = edge.type .. '|' .. edge.from .. '|' .. edge.to
                .. '|' .. fp .. '|' .. tp
    if seen[key] then
      return { code = 'duplicate_edge', edge = i, prior = seen[key] }
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

----- ancestors

-- Backward reachability over the user graph. Used by the wiring page at
-- drag-start to disqualify cycle-forming drop targets: a wire from X to
-- Y closes a cycle iff Y already reaches X — i.e. Y is an ancestor of X.
--contract: set { [id]=true } incl sourceId; backward over user.edges; cycle-safe via visited
function M.ancestors(user, sourceId)
  local out, adj = {}, {}
  for _, edge in ipairs(user.edges or {}) do
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

----- lower

--contract: assumes M.validate(user)==nil; lowers each wire to one port-to-port (audio) or node-to-node (midi) conn, splicing a CU node per wire-level op
function M.lower(user)
  local compile = { nodes = {}, conns = {} }
  local cuN = 0

  local function mintCu(cuNode)
    cuN = cuN + 1
    local id = '_cu_' .. cuN
    compile.nodes[id] = cuNode
    return id
  end

  local function flush(head, targetId, targetPort)
    if head.type == 'audio' then
      util.add(compile.conns, {
        type = 'audio', from = head.id, to = targetId,
        fromPort = head.port, toPort = targetPort, primary = head.primary,
      })
    else
      util.add(compile.conns, { type = 'midi', from = head.id, to = targetId,
                                primary = head.primary })
    end
  end

  -- Splice a CU bridge into the wire: a kind='fx' node carrying
  -- fxIdent=CU_IDENT and the wm-owned params payload. fxGuid is copied
  -- off the source edge so the pipeline can match the bridge across
  -- compiles without index tracking.
  local function splice(head, params, sourceEdge)
    local id = mintCu({ kind = 'fx', fxIdent = CU_IDENT,
                        fxGuid = sourceEdge._opFxGuid,
                        params = params })
    flush(head, id, head.type == 'audio' and 1 or nil)
    if head.type == 'audio' then
      return { type = 'audio', id = id, port = 1, primary = head.primary }
    end
    return { type = 'midi', id = id, primary = head.primary }
  end

  local function lowerAudioEdge(edge)
    local head = { type = 'audio', id = edge.from,
                   port = edge.fromPort or 1, primary = edge.primary }
    if edge.ops and edge.ops.gain then
      head = splice(head, { mode = 'gain', gain = edge.ops.gain }, edge)
    end
    flush(head, edge.to, edge.toPort or 1)
  end

  local function lowerMidiEdge(edge)
    local head = { type = 'midi', id = edge.from, primary = edge.primary }
    if edge.ops and edge.ops.channelMap then
      head = splice(head, { mode = 'channelRemap', map = edge.ops.channelMap }, edge)
    end
    flush(head, edge.to)
  end

  for id, node in pairs(user.nodes or {}) do
    compile.nodes[id] = passthroughNode(node)
  end
  for _, edge in ipairs(user.edges or {}) do
    if edge.type == 'audio' then lowerAudioEdge(edge)
    else                          lowerMidiEdge(edge)
    end
  end
  return compile
end

----- compile context

--contract: assumes M.validate(user)==nil; returns a ctx closing over M.lower(user) with lazy caches for classes, classOf, inbound, srcSet (per-id), quotient, absorption. ctx:srcSet(id) returns the same table across calls (referential cache).
function M.compile(user)
  local compile = M.lower(user)
  local classes, classOf, inbound, quotient, absorption
  local srcSet = {}

  local function inboundCache()
    inbound = inbound or inboundOf(compile)
    return inbound
  end

  local function srcSetOf(id)
    if srcSet[id] then return srcSet[id] end
    local set = {}
    local node = compile.nodes[id]
    if node and node.kind == 'source' and node.trackGuid then
      set[node.trackGuid] = true
    end
    for _, parent in ipairs(inboundCache()[id] or {}) do
      for guid in pairs(srcSetOf(parent)) do set[guid] = true end
    end
    srcSet[id] = set
    return set
  end

  local ctx = {}

  function ctx:graph()    return compile end
  function ctx:inbound()  return inboundCache() end
  function ctx:srcSet(id) return srcSetOf(id) end

  function ctx:classes()
    classes = classes or classesOf(compile, srcSetOf)
    return classes
  end

  function ctx:classOf()
    classOf = classOf or classOfMap(self:classes())
    return classOf
  end

  function ctx:quotient()
    quotient = quotient or quotientGraphOf(compile, self:classOf(), self:classes())
    return quotient
  end

  function ctx:absorption()
    absorption = absorption or absorptionOf(self:quotient())
    return absorption
  end

  function ctx:capacityErrors()
    return capacityErrorsOf(compile, self:classOf())
  end

  function ctx:targetPlan()
    return targetPlanOf(compile, self:classes(), self:classOf())
  end

  return ctx
end

return M
