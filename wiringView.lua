-- See docs/wiringView.md for the model.
-- @noindex

--invariant: wiringView owns wm and is the only module that speaks to it — wiringPage runs every graph query and every mutation through wv. Mirrors av→am, vm→tm.
--invariant: wv is the logical view layer — it projects the raw graph into render-ready descriptors (label, port counts split into audio/MIDI) and carries per-session pointers (hover, selection by nodeId). Viewport geometry, screen coordinates, hit-testing, and every ImGui call live in wiringPage. wv never speaks ImGui.
--invariant: hover / selection are nodeId-only and per-session; they don't persist. Camera (pan/zoom) lands here when 1.3b adds the drag UX.

local util = require 'util'
local DAG  = require 'DAG'

local cm = (...).cm

local wm = util.instantiate('wiringManager', { cm = cm })

local wv = {}

local hoverNodeId = nil
local selection   = {}  -- set keyed by nodeId → true; replace via setSelection, never mutated in place

----- Logical projection (viewport-independent)

local function nodeLabel(node)
  if node.kind == 'master' then return 'master' end
  if node.kind == 'fx'     then return node.fxDisplay or 'fx' end
  if node.kind == 'source' then
    return (node.trackGuid and wm:trackName(node.trackGuid))
        or node.displayName
        or (node.trackGuid and ('src ' .. node.trackGuid:sub(2, 6)))
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

-- Source nodes get their own category (kind-driven, so a track source reads
-- visually distinct from a synth generator). Other kinds fall out of port
-- shape: no outputs = master/sink; outputs but no audio in = generator;
-- audio in = effect. Drives the colour.wiring.node.<category> fill role.
local function nodeCategory(kind, ins, outs)
  if kind == 'source'              then return 'source'    end
  if #outs.audio + #outs.midi == 0 then return 'master'    end
  if #ins.audio == 0               then return 'generator' end
  return 'effect'
end

-- see docs/wiringView.md § Double-click intent
local function activation(node)
  if node.kind ~= 'fx' or not node.fxGuid then return nil end
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
    label    = nodeLabel(node),
    category = nodeCategory(node.kind, ins, outs),
    activate = activation(node),
    ins      = ins,
    outs     = outs,
  }
end

----------- PUBLIC

----- wm pass-through

function wv:graph()      return wm:graph() end
function wv:save()       wm:save() end
function wv:load()       wm:load() end
function wv:enableLive() wm:enableLive() end
function wv:pollUndo()   wm:pollUndo() end

----- Authoring (slice 1.3b)

--contract: pass-through to wm:addFxNode (Undo block + instantiate + generator there)
function wv:addFx(x, y, fx, opts)
  return wm:addFxNode(x, y, fx, opts)
end

function wv:listInstalledFX() return wm:listInstalledFX() end

----- Navigation (page double-click targets)

--contract: floats the node's FX window; false for non-fx nodes or a stale guid
function wv:openFxWindow(nodeId)
  local node = wm:graph().nodes[nodeId]
  return (node and node.fxGuid and wm:showFxWindow(node.fxGuid)) or false
end

--contract: live MediaTrack hosting nodeId's fx instance, or nil if the guid isn't live.
--contract: caller gates on nodeView.activate=='sampler'.
function wv:samplerTrack(nodeId)
  local node = wm:graph().nodes[nodeId]
  if not (node and node.fxGuid) then return nil end
  return (wm:locateFx(node.fxGuid))
end

--contract: atomically writes node.pos for each {[id]={x,y}} in logical canvas units; missing ids skipped
function wv:moveNodes(moves)
  return wm:mutate(function(g)
    for id, p in pairs(moves) do
      local node = g.nodes[id]
      if node then node.pos.x, node.pos.y = p.x, p.y end
    end
  end)
end

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

--contract: linear gain scalar on edges[idx]; 1.0 default when ops.gain unset or edge is non-audio / missing. Read-only.
function wv:edgeGain(idx)
  local e = wm:graph().edges[idx]
  if not e or e.type ~= 'audio' then return 1.0 end
  return (e.ops and e.ops.gain) or 1.0
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
  return DAG.ancestors(wm:graph(), sourceId)
end

--contract: forward reachability over user.edges; returns { [id]=true } including sourceId
function wv:descendantsOf(sourceId)
  return DAG.descendants(wm:graph(), sourceId)
end

--contract: returns { [portIdx]=true } over audio edges on nodeId for dir ('out'|'in'); midi edges ignored
function wv:wiredPorts(nodeId, dir)
  local endField  = (dir == 'out') and 'from'     or 'to'
  local portField = (dir == 'out') and 'fromPort' or 'toPort'
  local out = {}
  for _, e in ipairs(wm:graph().edges or {}) do
    if e.type == 'audio' and e[endField] == nodeId then
      out[e[portField] or 1] = true
    end
  end
  return out
end

--contract: logical canvas position of the master node as x, y; 0,0 if master is somehow absent
function wv:masterPos()
  local m = wm:graph().nodes.master
  if not m then return 0, 0 end
  return m.pos.x, m.pos.y
end

----- Render-ready, viewport-independent

--shape: nodeView = { id, pos={x,y}, label, category='master'|'generator'|'effect', activate='sampler'|'fx'|nil, ins={audio={name,…},midi={name,…}}, outs={audio={…},midi={…}} } — port lists carry names; counts = #list; activate is the double-click intent
--contract: returns the list of nodeViews for every node in the current user graph; order unspecified (pairs over graph.nodes)
function wv:nodeViews()
  local g = wm:graph()
  local out = {}
  for id, node in pairs(g.nodes) do util.add(out, nodeView(id, node)) end
  return out
end

--shape: wireView = { from, to, type='audio'|'midi', fromPort, toPort, fromPortName, toPortName, primary } — ports are 1-based and always present; names come from the same source as nodeView's port lists, nil if the referenced port has been trimmed off the node
--contract: returns the list of wireViews for every edge in the current user graph; order matches graph.edges
function wv:wireViews()
  local g = wm:graph()
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
    util.add(out, {
      from         = e.from,
      to           = e.to,
      type         = e.type,
      fromPort     = fromPort,
      toPort       = toPort,
      fromPortName = portName(e.from, 'out', e.type, fromPort),
      toPortName   = portName(e.to,   'in',  e.type, toPort),
      primary      = e.primary or nil,
    })
  end
  return out
end

----- Capacity errors

--contract: pass-through of wm:errors; { kind, count, budget, nodeIds }[] per overflowing class
function wv:errors()
  return wm:errors()
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

return wv
