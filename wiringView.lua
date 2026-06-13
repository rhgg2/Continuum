-- See docs/wiringView.md for the model.
-- @noindex

--invariant: wv is the sole speaker to wm (injected by wiringPage); all graph ops route through wv.
--invariant: wv is the logical view layer — it projects the raw graph into render-ready descriptors (label, port counts split into audio/MIDI) and carries per-session pointers (hover, selection by nodeId). Viewport geometry, screen coordinates, hit-testing, and every ImGui call live in wiringPage. wv never speaks ImGui.
--invariant: hover / selection are nodeId-only and per-session; they don't persist. Camera (pan/zoom) lands here when 1.3b adds the drag UX.

local util = require 'util'

local cm = (...).cm
local wm = (...).wm

local wv = {}

local hoverNodeId = nil
local selection   = {}  -- set keyed by nodeId → true; replace via setSelection, never mutated in place

-- wv's structural projection of wm's compiled graph, pulled lazily after a
-- structural change. Live gain stays out -- edgeGain reads wm uncloned.
local viewGraph, viewReach, sourceLabels, busRecords

local function ensureView()
  if not viewGraph then
    viewGraph  = wm:viewGraph()
    viewReach  = wm:reach()
    busRecords = wm:busRecords()
    -- Resolve live source-track names once per structural pull; nodeLabel reads this
    -- map so per-frame projection never hits REAPER. Renames land on the next rebuild.
    sourceLabels = {}
    local names = wm:trackNames()
    for id, node in pairs(viewGraph.nodes) do
      if node.kind == 'source' and node.trackId then
        sourceLabels[id] = names[node.trackId]
      end
    end
  end
  return viewGraph
end

-- Breadth-first set { [id]=true } over an adjacency table, seed included.
local function reachSet(adj, sourceId)
  local out = {}
  local function visit(id)
    if out[id] then return end
    out[id] = true
    for _, nxt in ipairs(adj[id] or {}) do visit(nxt) end
  end
  visit(sourceId)
  return out
end

----- Logical projection (viewport-independent)

local function nodeLabel(id, node)
  if node.kind == 'master' then return 'master' end
  if node.kind == 'bus'    then return 'buss' end
  if node.kind == 'fx'     then return node.fxDisplay or 'fx' end
  if node.kind == 'source' then
    return sourceLabels[id]
        or node.displayName
        or (node.trackId and ('src ' .. node.trackId:sub(2, 6)))
        or 'source'
  end
  return node.kind or '?'
end

-- node.ports.audio.{ins,outs} are integer stereo-port counts stamped
-- at node construction (source={0,1}, master={1,0}, fx from
-- probeFxIO). The view projects each count as a list of names —
-- synthetic 'in 1' / 'out 1' baseline today; once wm queries
-- TrackFX_GetIOName it will override per-port via
-- node.ports.audio.inNames / outNames.
local function audioPorts(node, dir)
  local audio      = node.ports.audio
  local countField = dir == 'in' and 'ins'     or 'outs'
  local nameField  = dir == 'in' and 'inNames' or 'outNames'
  local n          = audio[countField] or 0
  local names      = audio[nameField]
  local prefix     = dir == 'in' and 'in' or 'out'
  local list = {}
  for i = 1, n do list[i] = (names and names[i]) or (prefix .. ' ' .. i) end
  return list
end

-- MIDI port counts are stamped on node.ports.midi at construction
-- (master={0,0}, source={0,1}, fx={1,1} — the fx pair is an optimistic
-- placeholder until probing can read it). The view projects the count
-- as a synthetic-name list, the same shape as audioPorts.
local function midiPorts(node, dir)
  local n = node.ports.midi[dir == 'in' and 'ins' or 'outs'] or 0
  local list = {}
  for _ = 1, n do util.add(list, 'midi') end
  return list
end

-- Kind-driven categories: buss→bar, source→source; other kinds from port shape
-- (no outs→master, no audio-in→generator, audio-in→effect). Drives colour fill role.
local function nodeCategory(kind, ins, outs)
  if kind == 'source'              then return 'source'    end
  if kind == 'bus'                 then return 'bus'       end
  if #outs.audio + #outs.midi == 0 then return 'master'    end
  if #ins.audio == 0               then return 'generator' end
  return 'effect'
end

-- see docs/wiringView.md § Double-click intent
local function activation(node)
  if node.kind ~= 'fx' or not node.fxId then return nil end
  if node.fxDisplay and node.fxDisplay:find('Continuum Sampler', 1, true) then
    return 'sampler'
  end
  return 'fx'
end

local function nodeView(id, node)
  local ins  = { audio = audioPorts(node, 'in'),  midi = midiPorts(node, 'in')  }
  local outs = { audio = audioPorts(node, 'out'), midi = midiPorts(node, 'out') }
  return {
    id       = id,
    pos      = { x = node.pos.x, y = node.pos.y },
    label    = nodeLabel(id, node),
    category = nodeCategory(node.kind, ins, outs),
    activate = activation(node),
    ins      = ins,
    outs     = outs,
    orient   = node.orient,
  }
end

----------- PUBLIC

----- wm pass-through

function wv:graph()      return wm:graph() end
function wv:load()       wm:load() end
function wv:enableLive() wm:enableLive() end
function wv:syncExternal() wm:syncExternal() end

----- Authoring (slice 1.3b)

--contract: pass-through to wm:addFxNode (Undo block + instantiate + generator there)
function wv:addFx(x, y, fx, opts)
  return wm:addFxNode(x, y, fx, opts)
end

--contract: pass-through to wm:addSourceNode (standalone source track + node); returns node id
function wv:addSource(opts)
  return wm:addSourceNode(opts)
end

--contract: pass-through to wm:deleteSource; false+takeCount when track has takes and force is false
function wv:deleteSource(nodeId, force)
  return wm:deleteSource(nodeId, force)
end

function wv:listInstalledFX() return wm:listInstalledFX() end

----- Navigation (page double-click targets)

--contract: floats the node's FX window; false for non-fx nodes or a stale guid
function wv:openFxWindow(nodeId)
  local node = ensureView().nodes[nodeId]
  return (node and node.fxId and wm:showFxWindow(node.fxId)) or false
end

--contract: live MediaTrack hosting nodeId's fx instance, or nil if the guid isn't live.
--contract: caller gates on nodeView.activate=='sampler'.
function wv:samplerTrack(nodeId)
  local node = ensureView().nodes[nodeId]
  if not (node and node.fxId) then return nil end
  return wm:fxTrack(node.fxId)
end

--contract: node pos / record-buss pos for {[id]={x,y}} via wm:moveNodes; unknown ids skipped
function wv:moveNodes(moves)
  return wm:moveNodes(moves)
end

--contract: buss bar move/resize — writes node pos + record pos & axial ext via wm:moveBus
function wv:moveBus(id, pos, ext)
  return wm:moveBus(id, pos, ext)
end

--contract: pass-through to wm:insertBus {pos,orient,node,port,dir}; mints + re-points; returns id
function wv:insertBus(spec) return wm:insertBus(spec) end

--contract: pass-through to wm:addBusNode; mints unwired buss at (x,y); orient defaults 'V'
function wv:addBusNode(x, y, orient) return wm:addBusNode({ x = x, y = y }, orient) end

--contract: pass-through to wm:rotateBus — flips the buss's V↔H orientation
function wv:rotateBus(id) return wm:rotateBus(id) end

--contract: pass-through to wm:deleteBus — node, incident edges, record, one Undo block
function wv:deleteBus(nodeId) return wm:deleteBus(nodeId) end

--contract: stashes wireView w's source-tag offset {x,y} (consumer-relative) via wm; decoration only
function wv:setSourceTagPos(w, offset) return wm:setSourceTagPos(w.from, wm.srcTagKey(w), offset) end

--contract: appends wire; midi: ports nil; audio: ports default to 1; fires wiringChanged via wm:mutate
function wv:addWire(spec)
  return wm:mutate(function(g)
    local edge = { type = spec.type, from = spec.from, to = spec.to }
    if spec.type == 'audio' then
      edge.fromPort = spec.fromPort or 1
      edge.toPort   = spec.toPort   or 1
    end
    util.add(g.edges, edge)
  end)
end

--contract: removes the edge at g.edges[idx]; no-op if idx is out of range; fires wiringChanged via wm:mutate
function wv:removeWireAt(idx)
  return wm:mutate(function(g)
    if g.edges[idx] then table.remove(g.edges, idx) end
  end)
end

--contract: removes node and incident edges atomically; no-op if id absent; fires wiringChanged
function wv:deleteNode(nodeId)
  return wm:mutate(function(g)
    g.nodes[nodeId] = nil
    local kept = {}
    for _, e in ipairs(g.edges) do
      if e.from ~= nodeId and e.to ~= nodeId then util.add(kept, e) end
    end
    g.edges = kept
  end)
end

--contract: rewrites one end of g.edges[idx] in place; side ∈ {'from','to'}; target = { id, port? }; port ignored for midi edges; single wiringChanged
function wv:rewireEdgeEnd(idx, side, target)
  return wm:mutate(function(g)
    local e = g.edges[idx]
    if not e then return end
    if side == 'from' then
      e.from = target.id
      if e.type == 'audio' then e.fromPort = target.port or 1 end
    else
      e.to = target.id
      if e.type == 'audio' then e.toPort = target.port or 1 end
    end
  end)
end

--contract: live pass-through to wm:edgeGain; 1.0 when ops.gain unset or edge non-audio/missing.
function wv:edgeGain(idx)
  return wm:edgeGain(idx)
end

--contract: writes ops.gain on audio edges[idx]; fast path when poke hosts, else wm:mutate
function wv:setEdgeGain(idx, gain)
  if wm:pokeEdgeGain(idx, gain) then return wm:fastGainCommit(idx, gain) end
  return wm:mutate(function(g)
    local e = g.edges[idx]
    if not e or e.type ~= 'audio' then return end
    e.ops = e.ops or {}
    e.ops.gain = gain
  end)
end

--contract: live pass-through to wm:pokeEdgeGain. Returns true if the CU exists and was poked; false if caller must materialise via setEdgeGain first.
function wv:pokeEdgeGain(idx, gain) return wm:pokeEdgeGain(idx, gain) end

--contract: sets edges[idx].primary via wm:mutate; coerced to true/nil (nil-not-false per DAG).
function wv:setEdgePrimary(idx, primary)
  return wm:mutate(function(g)
    local e = g.edges[idx]
    if not e then return end
    e.primary = primary and true or nil
  end)
end

----- Topology queries

--contract: backward reachability over user.edges; returns { [id]=true } including sourceId
function wv:ancestorsOf(sourceId)
  ensureView()
  return reachSet(viewReach.reverse, sourceId)
end

--contract: forward reachability over user.edges; returns { [id]=true } including sourceId
function wv:descendantsOf(sourceId)
  ensureView()
  return reachSet(viewReach.forward, sourceId)
end

--contract: returns { [portIdx]=true } over audio edges on nodeId for dir ('out'|'in'); midi edges ignored
function wv:wiredPorts(nodeId, dir)
  local endField  = (dir == 'out') and 'from'     or 'to'
  local portField = (dir == 'out') and 'fromPort' or 'toPort'
  local out = {}
  for _, e in ipairs(ensureView().edges or {}) do
    if e.type == 'audio' and e[endField] == nodeId then
      out[e[portField] or 1] = true
    end
  end
  return out
end

--contract: logical canvas position of the master node as x, y; 0,0 if master is somehow absent
function wv:masterPos()
  local m = ensureView().nodes.master
  if not m then return 0, 0 end
  return m.pos.x, m.pos.y
end

----- Render-ready, viewport-independent

--shape: nodeView = { id, pos={x,y}, label, category='master'|'source'|'generator'|'effect'|'bus', activate='sampler'|'fx'|nil, ins={audio={name,…},midi={name,…}}, outs={audio={…},midi={…}}, orient?='V'|'H' } — port lists carry names; counts = #list; activate is the double-click intent
--contract: returns the list of nodeViews for every node in the current user graph; order unspecified (pairs over graph.nodes)
function wv:nodeViews()
  local g = ensureView()
  local out = {}
  for id, node in pairs(g.nodes) do util.add(out, nodeView(id, node)) end
  return out
end

--shape: busView = { id, pos={x,y}, orient='V'|'H', ext={lo,hi}?, matrix=true? } — projects the bus node; ext = hand-sized bar span (axial offsets from pos), nil = auto-fit; record pos as fallback
--contract: one busView per buss record; pos/orient from the node when present, else the record
function wv:busViews()
  local g = ensureView()
  local out = {}
  for busId, rec in pairs(busRecords) do
    local node = g.nodes[busId]
    util.add(out, {
      id     = busId,
      pos    = node and { x = node.pos.x, y = node.pos.y } or { x = rec.pos.x, y = rec.pos.y },
      orient = node and node.orient or rec.orient or 'V',
      ext    = rec.ext,
      matrix = node and true or nil,
    })
  end
  return out
end

-- Edge → bus stamp: membership is structural — an endpoint on a bus node; `to` end wins.
local function busTag(e, fromNode, toNode)
  if e.type ~= 'audio' then return nil end
  if toNode and toNode.kind == 'bus' then return { busId = e.to, bussedEnd = 'to' } end
  if fromNode and fromNode.kind == 'bus' then return { busId = e.from, bussedEnd = 'from' } end
end

--shape: wireView = { from, to, type='audio'|'midi', fromPort, toPort, fromPortName, toPortName, primary, fromKind='source'|'fx'|'master', fromLabel, fromOffset={x,y}?, bus={busId,bussedEnd='to'|'from'}? } — see docs/wiringView.md § wireView shape
-- see docs/wiringView.md § wireView fromKind/fromLabel
--contract: returns the list of wireViews for every edge in the current user graph; order matches graph.edges
function wv:wireViews()
  local g = ensureView()
  local function portName(nodeId, dir, kind, idx)
    if kind == 'midi' then return 'midi' end
    local node = g.nodes[nodeId]
    if not node then return nil end
    return audioPorts(node, dir)[idx]
  end
  local out = {}
  for _, e in ipairs(g.edges or {}) do
    local fromPort = e.fromPort or 1
    local toPort   = e.toPort   or 1
    local fromNode = g.nodes[e.from]
    local fromOffset = fromNode and fromNode.kind == 'source' and fromNode.tagPos
                         and fromNode.tagPos[wm.srcTagKey(e)] or nil
    local bus = busTag(e, fromNode, g.nodes[e.to])
    util.add(out, {
      from         = e.from,
      to           = e.to,
      type         = e.type,
      fromPort     = fromPort,
      toPort       = toPort,
      fromPortName = portName(e.from, 'out', e.type, fromPort),
      toPortName   = portName(e.to,   'in',  e.type, toPort),
      primary      = e.primary or nil,
      fromKind     = fromNode and fromNode.kind,
      fromLabel    = fromNode and nodeLabel(e.from, fromNode),
      fromOffset   = fromOffset,
      bus          = bus,
    })
  end
  return out
end

----- Logical view-state (nodeId only)

function wv:hover()             return hoverNodeId       end
function wv:setHover(id)        hoverNodeId = id         end

--contract: returns the live selection set { [id]=true, … }; callers read, never mutate
function wv:selection()         return selection         end
--contract: replaces selection wholesale; pass {} to clear. Defensive shallow-copies the input.
function wv:setSelection(idSet)
  local copy = {}
  for id in pairs(idSet or {}) do copy[id] = true end
  selection = copy
end

----- Lifecycle: cache pulled on every structural change

-- Lazy sibling of tv:rebuild: invalidate, don't re-pull. The next render
-- read repopulates via ensureView, so a signal without a render compiles nothing.
--contract: drops the view cache; next read re-pulls from wm. Driven by wiringChanged.
function wv:rebuild()
  viewGraph, viewReach, sourceLabels, busRecords = nil, nil, nil, nil
end

wm:subscribe('wiringChanged', function() wv:rebuild() end)

return wv
