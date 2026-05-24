-- See docs/wiringView.md for the model.
-- @noindex

--invariant: wiringView owns wm and is the only module that speaks to it — wiringPage runs every graph query and every mutation through wv. Mirrors av→am, vm→tm.
--invariant: wv is the logical view layer — it projects the raw graph into render-ready descriptors (label, port counts split into audio/MIDI) and carries per-session pointers (hover, selection by nodeId). Viewport geometry, screen coordinates, hit-testing, and every ImGui call live in wiringPage. wv never speaks ImGui.
--invariant: hover / selection are nodeId-only and per-session; they don't persist. Camera (pan/zoom) lands here when 1.3b adds the drag UX.

local util = require 'util'

local cm = (...).cm

local wm = util.instantiate('wiringManager', { cm = cm })

local wv = {}

local hoverNodeId     = nil
local selectionNodeId = nil

----- Logical projection (viewport-independent)

local function nodeLabel(node)
  if node.kind == 'master' then return 'master' end
  if node.kind == 'fx'     then return node.fxDisplay or 'fx' end
  if node.kind == 'source' then
    return node.fxDisplay
        or (node.trackGuid and ('src ' .. node.trackGuid:sub(2, 6)))
        or 'source'
  end
  return node.kind or '?'
end

-- audio.ins / audio.outs are integer stereo-port counts; fx/master store
-- them directly. Source nodes default to (0 in, 1 stereo out).
local function audioCount(node, dir)
  if node.kind == 'source' then return dir == 'in' and 0 or 1 end
  local n = node.audio and node.audio[dir == 'in' and 'ins' or 'outs']
  return n or 0
end

-- Per the design doc: master has no MIDI; source / fx carry exactly one
-- MIDI port in each direction.
local function midiCount(node, dir)
  if node.kind == 'master' then return 0 end
  return 1
end

local function nodeView(id, node)
  return {
    id    = id,
    pos   = { x = node.pos.x, y = node.pos.y },
    label = nodeLabel(node),
    ins   = { audio = audioCount(node, 'in'),  midi = midiCount(node, 'in')  },
    outs  = { audio = audioCount(node, 'out'), midi = midiCount(node, 'out') },
  }
end

----------- PUBLIC

----- wm pass-through

function wv:graph() return wm:graph() end
function wv:save()  wm:save() end
function wv:load()  wm:load() end

----- Render-ready, viewport-independent

--shape: nodeView = { id, pos={x,y}, label, ins={audio,midi}, outs={audio,midi} } — everything the page needs to lay out a node, with no viewport / pixel concerns
--contract: returns the list of nodeViews for every node in the current user graph; order unspecified (pairs over graph.nodes)
function wv:nodeViews()
  local g = wm:graph()
  local out = {}
  for id, node in pairs(g.nodes) do util.add(out, nodeView(id, node)) end
  return out
end

----- Logical view-state (nodeId only)

function wv:hover()           return hoverNodeId     end
function wv:setHover(id)      hoverNodeId = id       end
function wv:selection()       return selectionNodeId end
function wv:setSelection(id)  selectionNodeId = id   end

return wv
