-- Pure structural calculus for the wiring page: user graph (wires) and
-- compile graph (per-channel / per-port connections), the lowering that
-- bridges them, and the source-set partition that compiles onto REAPER
-- tracks. See design/wiring.md for the model.
-- @noindex

--invariant: pure module — no state; functions take operands explicitly
--invariant: two graph shapes — user (wires, always stereo audio / 16-ch MIDI) and compile (per-channel audio / per-port MIDI); lower() bridges them
--invariant: source nodes have implicit I/O (one stereo output pair, one MIDI out port); fx nodes carry explicit audio.ins/outs at channel granularity; MIDI is one implicit port on sources/fx
--invariant: master is a singleton node (id='master'); audio.ins explicit (mirrors REAPER master hardware-output channel count); no audio outs, no MIDI; terminal-only (never `from`)
--invariant: wire pairs derive from adjacent channel indices in audio.ins/outs; trailing odd channel = single-channel pair that lowers to a mono connection
--invariant: srcSet and class equivalence are stable under lowering — every Continuum Utility insertion is single-input single-output
--shape: UserGraph = { nodes = {[id]=Node}, edges = Edge[], _nextId = number }
--shape: Node = { kind='source'|'fx'|'master', pos={x,y}, trackGuid?=string, fxIdent?=string, fxDisplay?=string, audio?={ins=string[], outs?=string[]} }
--shape: Edge = { type='audio'|'midi', from=id, fromPort=nil|pairIdx, to=id, toPort=nil|pairIdx, ops?={gain?=number, channelMap?={[1..16]=1..16}}, primary?=true }
--shape: CompileGraph = { nodes = {[id]=CompileNode}, conns = Conn[] }
--shape: CompileNode = { kind='source'|'fx'|'master'|'cu', trackGuid?=string, fxIdent?=string, cuMode?='gain'|'channelRemap'|'monoSum'|'monoReplicate', cuParams?=table }
--shape: Conn = { type='audio'|'midi', from=id, to=id, fromCh?=number, toCh?=number, primary?=true }
local util = require('util')

local M = {}

----- Pair shape helpers (user graph)

-- {'L','R'} -> {2}; {'L','R','L','R'} -> {2,2}; {'L','R','C'} -> {2,1}.
local function pairWidths(channels)
  local widths = {}
  local n = channels and #channels or 0
  for i = 1, n, 2 do
    widths[#widths + 1] = (i + 1 <= n) and 2 or 1
  end
  return widths
end

-- Sources have implicit I/O: one stereo output pair, no audio inputs.
local function audioPairs(node)
  if node.kind == 'source' then
    return { ins = {}, outs = { 2 } }
  end
  return { ins  = pairWidths(node.audio and node.audio.ins),
           outs = pairWidths(node.audio and node.audio.outs) }
end

----------- PUBLIC

----- validate

--contract: returns nil on success, or { code, ... } describing the first failure; wm:mutate gates persistence on nil
function M.validate(user)
  local nodes, edges = user.nodes or {}, user.edges or {}

  local masters = 0
  for _, n in pairs(nodes) do
    if n.kind == 'master' then masters = masters + 1 end
  end
  if masters ~= 1 then
    return { code = 'master_singleton', count = masters }
  end

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
      local fromPairs = audioPairs(fromNode).outs
      local toPairs   = audioPairs(toNode).ins
      -- nil port = implicit pair 1 (single-port shorthand).
      local fromIdx = (#fromPairs > 0) and (edge.fromPort or 1) or nil
      local toIdx   = (#toPairs   > 0) and (edge.toPort   or 1) or nil
      if not fromIdx or fromIdx < 1 or fromIdx > #fromPairs then
        return { code = 'audio_from_port_oob', edge = i,
                 want = edge.fromPort, have = #fromPairs }
      end
      if not toIdx or toIdx < 1 or toIdx > #toPairs then
        return { code = 'audio_to_port_oob', edge = i,
                 want = edge.toPort, have = #toPairs }
      end
    else
      return { code = 'unknown_edge_type', edge = i, type = edge.type }
    end
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

----- lower

-- pair k starts at channel 2k-1; if stereo it covers 2k-1 and 2k, if mono just 2k-1.
local function pairStartCh(pair) return 2 * pair - 1 end

-- Strip user-graph fields the compile graph doesn't need (pos, fxDisplay,
-- the audio shape we've already consumed for pair widths).
local function passthroughNode(node)
  return { kind      = node.kind,
           trackGuid = node.trackGuid,
           fxIdent   = node.fxIdent }
end

--contract: assumes M.validate(user)==nil; lowers wires into per-channel/port conns, materialises CU nodes for ops and mono adapters
function M.lower(user)
  local compile = { nodes = {}, conns = {} }
  local cuN = 0

  local function mintCu(cuNode)
    cuN = cuN + 1
    local id = '_cu_' .. cuN
    compile.nodes[id] = cuNode
    return id
  end

  -- Terminate head into (targetId, targetCh0). targetCh0 unused for MIDI.
  -- head.primary travels with the wire and lands on every conn it produces.
  local function flush(head, targetId, targetCh0)
    if head.type == 'audio' then
      for c = 1, head.width do
        util.add(compile.conns, {
          type = 'audio',
          from = head.id, fromCh = head.ch0 + c - 1,
          to   = targetId, toCh   = targetCh0 + c - 1,
          primary = head.primary,
        })
      end
    else
      util.add(compile.conns, { type = 'midi', from = head.id, to = targetId,
                                primary = head.primary })
    end
  end

  -- Splice a CU into the wire between head and whatever target would follow:
  -- mints the CU, routes head into it (CU inputs always start at ch 1), and
  -- returns the new head positioned at the CU's output. outWidth = the CU's
  -- output channel count (audio only; ignored for MIDI).
  local function splice(head, cuMode, cuParams, outWidth)
    local id = mintCu({ kind = 'cu', cuMode = cuMode, cuParams = cuParams })
    flush(head, id, 1)
    if head.type == 'audio' then
      return { type = 'audio', id = id, ch0 = 1, width = outWidth,
               primary = head.primary }
    end
    return { type = 'midi', id = id, primary = head.primary }
  end

  local function lowerAudioEdge(edge, fromNode, toNode)
    local fromPair  = edge.fromPort or 1
    local toPair    = edge.toPort   or 1
    local fromWidth = audioPairs(fromNode).outs[fromPair]
    local toWidth   = audioPairs(toNode).ins[toPair]

    local head = { type = 'audio', id = edge.from,
                   ch0 = pairStartCh(fromPair), width = fromWidth,
                   primary = edge.primary }

    if edge.ops and edge.ops.gain then
      head = splice(head, 'gain',
                    { gain = edge.ops.gain, channels = head.width },
                    head.width)
    end

    if head.width ~= toWidth then
      local mode = (head.width == 2 and toWidth == 1) and 'monoSum' or 'monoReplicate'
      head = splice(head, mode, nil, toWidth)
    end

    flush(head, edge.to, pairStartCh(toPair))
  end

  local function lowerMidiEdge(edge)
    local head = { type = 'midi', id = edge.from, primary = edge.primary }
    if edge.ops and edge.ops.channelMap then
      head = splice(head, 'channelRemap', { map = edge.ops.channelMap })
    end
    flush(head, edge.to)
  end

  for id, node in pairs(user.nodes or {}) do
    compile.nodes[id] = passthroughNode(node)
  end
  for _, edge in ipairs(user.edges or {}) do
    if edge.type == 'audio' then
      lowerAudioEdge(edge, user.nodes[edge.from], user.nodes[edge.to])
    else
      lowerMidiEdge(edge)
    end
  end
  return compile
end

----- srcSet / classes

-- Reverse adjacency: for each node id, the list of input-side node ids.
-- Stashed on compile so the cost is paid once per graph instance.
local function inboundOf(compile)
  if compile._inbound then return compile._inbound end
  local inbound = {}
  for _, conn in ipairs(compile.conns) do
    util.bucket(inbound, conn.to, conn.from)
  end
  compile._inbound = inbound
  return inbound
end

--contract: set<trackGuid> of source ancestors; memoised on compile (stashes _srcSet, _inbound)
function M.srcSet(compile, nodeId)
  compile._srcSet = compile._srcSet or {}
  local memo, inbound = compile._srcSet, inboundOf(compile)

  local function visit(id)
    if memo[id] then return memo[id] end
    local set = {}
    local node = compile.nodes[id]
    if node and node.kind == 'source' and node.trackGuid then
      set[node.trackGuid] = true
    end
    for _, parent in ipairs(inbound[id] or {}) do
      for guid in pairs(visit(parent)) do set[guid] = true end
    end
    memo[id] = set
    return set
  end
  return visit(nodeId)
end

--contract: partitions compile.nodes by srcSet; classKey = sorted trackGuids joined by '|', '' for empty
function M.classes(compile)
  local out = {}
  for id in pairs(compile.nodes) do
    local guids = {}
    for guid in pairs(M.srcSet(compile, id)) do util.add(guids, guid) end
    table.sort(guids)
    util.bucket(out, table.concat(guids, '|'), id)
  end
  return out
end

----- quotientGraph / absorption / capacityErrors

--contract: class DAG view of compile; each class -> {audio,midi}{Parents,Children} sets; primaryParents ⊆ audioParents, flagged by `primary` wires
function M.quotientGraph(compile, classes)
  local classOf, quotient = {}, {}
  for cls, members in pairs(classes) do
    quotient[cls] = { audioParents = {}, midiParents = {},
                      audioChildren = {}, midiChildren = {},
                      primaryParents = {} }
    for _, id in ipairs(members) do classOf[id] = cls end
  end

  for _, conn in ipairs(compile.conns) do
    local fromCls, toCls = classOf[conn.from], classOf[conn.to]
    if fromCls ~= toCls then
      local toQ, fromQ = quotient[toCls], quotient[fromCls]
      if conn.type == 'audio' then
        toQ.audioParents[fromCls] = true
        if conn.primary then toQ.primaryParents[fromCls] = true end
        fromQ.audioChildren[toCls] = true
      else
        toQ.midiParents[fromCls] = true
        fromQ.midiChildren[toCls] = true
      end
    end
  end
  return quotient
end

-- Direct (one-hop) host for cls under the absorption rule. Returns nil if cls
-- has no eligible host: zero audio parents, ambiguous primaries, or multiple
-- non-primary audio parents.
local function directHost(q)
  local audioParents, primaryParents = {}, {}
  for parent in pairs(q.audioParents)   do util.add(audioParents,   parent) end
  for parent in pairs(q.primaryParents) do util.add(primaryParents, parent) end
  if #primaryParents == 1 then return primaryParents[1] end
  if #primaryParents == 0 and #audioParents == 1 then return audioParents[1] end
  return nil
end

--contract: sparse {[cls]=hostCls}; chains resolved to terminal host; absent = self-hosting; cycle-safe
function M.absorption(quotient)
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

--contract: list of {classKey, kind='audio'|'midi', count} for intra-class conn counts exceeding 64 audio / 128 midi; sorted by classKey then kind
function M.capacityErrors(compile, classes)
  local classOf, counts = {}, {}
  for cls, members in pairs(classes) do
    for _, id in ipairs(members) do classOf[id] = cls end
  end
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

return M
