-- Pure structural calculus for the wiring page: user graph (wires) and
-- compile graph (per-channel / per-port connections), the lowering that
-- bridges them, and the source-set partition that compiles onto REAPER
-- tracks. See design/wiring.md for the model.
-- @noindex

--invariant: pure module — no state; functions take operands explicitly
--invariant: two graph shapes — user (wires, always stereo audio / 16-ch MIDI) and compile (per-channel audio / per-port MIDI); lower() bridges them
--invariant: source nodes have implicit I/O (one stereo output pair, one MIDI out port); fx nodes carry explicit audio.ins/outs at channel granularity; MIDI is one implicit port everywhere
--invariant: wire pairs derive from adjacent channel indices in audio.ins/outs; trailing odd channel = single-channel pair that lowers to a mono connection
--invariant: srcSet and class equivalence are stable under lowering — every Continuum Utility insertion is single-input single-output
--shape: UserGraph = { nodes = {[id]=Node}, edges = Edge[], _nextId = number }
--shape: Node = { kind='source'|'fx', pos={x,y}, trackGuid?=string, fxIdent?=string, fxDisplay?=string, audio?={ins=string[], outs=string[]} }
--shape: Edge = { type='audio'|'midi', from=id, fromPort=nil|pairIdx, to=id, toPort=nil|pairIdx, ops?={gain?=number, channelMap?={[1..16]=1..16}}, primary?=true }
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
    local bucket = adj[edge.from]
    if not bucket then bucket = {}; adj[edge.from] = bucket end
    bucket[#bucket + 1] = edge.to
  end
  local color = {} -- nil=white, 1=grey, 2=black
  local function visit(id)
    color[id] = 1
    for _, nxt in ipairs(adj[id] or {}) do
      if color[nxt] == 1 then return nxt end
      if color[nxt] == nil then
        local hit = visit(nxt)
        if hit then return hit end
      end
    end
    color[id] = 2
  end
  for id in pairs(nodes) do
    if color[id] == nil then
      local hit = visit(id)
      if hit then return { code = 'cycle', at = hit } end
    end
  end

  return nil
end

return M
