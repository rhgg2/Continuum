-- See docs/wiringPage.md for the model.
-- @noindex

--invariant: render + input only — wiringPage draws the canvas and reads keyboard / mouse. It holds no wm reference: every graph query goes through wv, every mutation will go through wv (the manager-facing surface).
--invariant: wiring page is project-wide — bind() takes no take and never re-keys cm; the tracker take and the sampler track are unaffected by switching to / from wiring.
--invariant: the page owns every pixel — node-box geometry, port slot layout, hit-test boxes are all derived here from wv's viewport-independent nodeViews. wv carries label + category + audio/MIDI counts; the page turns those into rects and tints.
--invariant: at Stage 1.3b the page handles add-fx (scope key N, testing-only) and drag-to-move single node. Selection (rubber-band, multi) arrives in the next slice; ports remain hover-only.

local util = require 'util'

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'

local cm, cmgr, chrome, gui, modalHost =
  (...).cm, (...).cmgr, (...).chrome, (...).gui, (...).modalHost

local ctx      = gui and gui.ctx or nil
local wireFont = gui and gui.wireFont or nil
local wireSize = gui and gui.fontSize and gui.fontSize.wire or 14

local wv = util.instantiate('wiringView', { cm = cm, cmgr = cmgr })

local wp = {}

local NODE_W           = 90
local NODE_H           = 60
local CORNER_R         = 5
local PORT_SIZE        = 8
local PORT_GAP         = 4
local PORT_BAND_OFFSET = 6   -- gap between node edge and the hover-only port row
local PORT_HIT_PAD     = 4   -- hit area extends this far beyond the visual square on each side
local PORT_TOOLTIP_GAP = 4   -- pixels between port top and tooltip bottom edge

-- How far port geometry reaches past a node edge. Drives the node-level
-- hover inflation so the row stays drawn while the mouse is anywhere in
-- the padded hit area.
local PORT_REACH = PORT_BAND_OFFSET + PORT_SIZE + PORT_HIT_PAD

----- Drag state (page-local; ephemeral, never persisted)

-- Captured at mousedown-on-node. While IsMouseDown, the node draws at
-- start + (curMouse - startMouse). On mouseup we commit through
-- wv:moveNode (one wm:mutate, one wiringChanged signal).
local drag = nil  -- { id, mx0, my0, x0, y0 }

----- Pixel geometry (page-owned)

-- pos is the node's centre in canvas-local coordinates (origin = centre
-- of the viewport, set up in renderCanvas); rect is laid out symmetrically.
local function nodeRect(nv)
  local hw, hh = NODE_W / 2, NODE_H / 2
  return nv.pos.x - hw, nv.pos.y - hh, nv.pos.x + hw, nv.pos.y + hh
end

----- Drawing

local function drawNode(dl, nv, ox, oy)
  local lx0, ly0, lx1, ly1 = nodeRect(nv)
  local x0, y0, x1, y1 = ox + lx0, oy + ly0, ox + lx1, oy + ly1
  local fill = chrome.colour('wiring.node.' .. nv.category)
  local text = chrome.colour('text')
  ImGui.DrawList_AddRectFilled(dl, x0, y0, x1, y1, fill, CORNER_R)
  if wireFont then ImGui.PushFont(ctx, wireFont, wireSize) end
  local tw, th = ImGui.CalcTextSize(ctx, nv.label)
  ImGui.DrawList_AddText(dl,
    x0 + math.floor((NODE_W - tw) / 2),
    y0 + math.floor((NODE_H - th) / 2),
    text, nv.label)
  if wireFont then ImGui.PopFont(ctx) end
end

-- One port: filled square + invisible button (padded outward so the
-- hit area is comfortably larger than the 8px visual) and a tooltip
-- anchored right above the port. The InvisibleButton advances the
-- layout cursor; caller restores it before reserving canvas area.
local function drawPort(dl, px, y, colour, idStem, name)
  ImGui.DrawList_AddRectFilled(dl, px, y, px + PORT_SIZE, y + PORT_SIZE, colour)
  local hit = PORT_SIZE + 2 * PORT_HIT_PAD
  ImGui.SetCursorScreenPos(ctx, px - PORT_HIT_PAD, y - PORT_HIT_PAD)
  ImGui.InvisibleButton(ctx, idStem, hit, hit)
  if ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_ForTooltip) then
    ImGui.SetNextWindowPos(ctx,
      px + PORT_SIZE / 2, y - PORT_TOOLTIP_GAP,
      ImGui.Cond_Always, 0.5, 1.0)
    ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg, chrome.colour('wiring.tooltip.bg'))
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 4, 2)
    if ImGui.BeginTooltip(ctx) then
      ImGui.Text(ctx, name)
      ImGui.EndTooltip(ctx)
    end
    ImGui.PopStyleVar(ctx, 1)
    ImGui.PopStyleColor(ctx, 1)
  end
end

-- Horizontal row of port squares centred over [x0,x1] at vertical `y`.
-- Audio squares first, then MIDI; either list may be empty.
local function drawPortBand(dl, x0, x1, y, audio, midi, audioCol, midiCol, idPrefix)
  local total = #audio + #midi
  if total == 0 then return end
  local rowW = total * PORT_SIZE + (total - 1) * PORT_GAP
  local cx   = math.floor((x0 + x1 - rowW) / 2)
  for i, name in ipairs(audio) do
    local px = cx + (i - 1) * (PORT_SIZE + PORT_GAP)
    drawPort(dl, px, y, audioCol, idPrefix .. '/a/' .. i, name)
  end
  for i, name in ipairs(midi) do
    local px = cx + (#audio + i - 1) * (PORT_SIZE + PORT_GAP)
    drawPort(dl, px, y, midiCol, idPrefix .. '/m/' .. i, name)
  end
end

local function drawHoverPorts(dl, nv, ox, oy)
  local lx0, ly0, lx1, ly1 = nodeRect(nv)
  local x0, y0, x1, y1 = ox + lx0, oy + ly0, ox + lx1, oy + ly1
  local audioCol = chrome.colour('wiring.port.audio')
  local midiCol  = chrome.colour('wiring.port.midi')
  drawPortBand(dl, x0, x1,
    y0 - PORT_BAND_OFFSET - PORT_SIZE,
    nv.ins.audio,  nv.ins.midi,  audioCol, midiCol,
    '##port/' .. nv.id .. '/in')
  drawPortBand(dl, x0, x1,
    y1 + PORT_BAND_OFFSET,
    nv.outs.audio, nv.outs.midi, audioCol, midiCol,
    '##port/' .. nv.id .. '/out')
end

-- Identify the node whose body the mouse is over (un-inflated rect);
-- used to start a drag, distinct from the inflated rect that drives
-- port reveal. Returns nil if the mouse is over empty canvas (or a
-- port band).
local function nodeUnderMouse(nodeViews, ox, oy)
  for _, nv in ipairs(nodeViews) do
    local lx0, ly0, lx1, ly1 = nodeRect(nv)
    if ImGui.IsMouseHoveringRect(ctx,
         ox + lx0, oy + ly0, ox + lx1, oy + ly1) then
      return nv
    end
  end
end

local function renderCanvas(w, h)
  local dl     = ImGui.GetWindowDrawList(ctx)
  local sx, sy = ImGui.GetCursorScreenPos(ctx)
  ImGui.DrawList_AddRectFilled(dl, sx, sy, sx + w, sy + h, chrome.colour('bg'))
  -- Canvas origin is the centre of the viewport: logical (0,0) draws
  -- in the middle, positions extend in all four quadrants from there.
  local ox, oy = sx + math.floor(w / 2), sy + math.floor(h / 2)

  local nodeViews = wv:nodeViews()

  -- Drag projection: while a drag is live, override the dragged node's
  -- pos in this frame's nodeViews so geometry below (hit test, draw,
  -- hover band) all see the in-flight position.
  if drag then
    for _, nv in ipairs(nodeViews) do
      if nv.id == drag.id then
        local mx, my = ImGui.GetMousePos(ctx)
        nv.pos.x = drag.x0 + (mx - drag.mx0)
        nv.pos.y = drag.y0 + (my - drag.my0)
        break
      end
    end
  end

  -- Hover region includes the port bands above/below the node (plus
  -- the per-port hit padding) so the mouse can dwell on a port without
  -- the hover dropping and erasing the port mid-aim.
  local hoverInflate = PORT_REACH
  local hoveredNV = nil
  for _, nv in ipairs(nodeViews) do
    local lx0, ly0, lx1, ly1 = nodeRect(nv)
    if ImGui.IsMouseHoveringRect(ctx,
         ox + lx0, oy + ly0 - hoverInflate,
         ox + lx1, oy + ly1 + hoverInflate) then
      hoveredNV = nv
    end
    drawNode(dl, nv, ox, oy)
  end
  if hoveredNV then drawHoverPorts(dl, hoveredNV, ox, oy) end
  wv:setHover(hoveredNV and hoveredNV.id or nil)

  -- Drag bookkeeping. Drag starts on a click whose body-hit lands on
  -- a node (not on a port band — port hits are reserved for future
  -- wire-pull). Drag ends on mouseup, committing the projected pos.
  if not drag and ImGui.IsMouseClicked(ctx, 0) then
    local bodyHit = nodeUnderMouse(nodeViews, ox, oy)
    if bodyHit then
      local mx, my = ImGui.GetMousePos(ctx)
      drag = { id = bodyHit.id, mx0 = mx, my0 = my,
               x0 = bodyHit.pos.x, y0 = bodyHit.pos.y }
    end
  elseif drag and not ImGui.IsMouseDown(ctx, 0) then
    local mx, my = ImGui.GetMousePos(ctx)
    local fx, fy = drag.x0 + (mx - drag.mx0), drag.y0 + (my - drag.my0)
    if fx ~= drag.x0 or fy ~= drag.y0 then wv:moveNode(drag.id, fx, fy) end
    drag = nil
  end

  -- Port InvisibleButtons advance the layout cursor; rewind it so the
  -- canvas-sizing Dummy reserves from the canvas origin, not from
  -- wherever the last port landed.
  ImGui.SetCursorScreenPos(ctx, sx, sy)
  ImGui.Dummy(ctx, w, h)
end

local function pushBodyStyles()
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, chrome.colour('text'))
end
local function popBodyStyles() ImGui.PopStyleColor(ctx, 1) end

----------- PUBLIC

--contract: bind takes no take — wiring is project-wide. coord may call with no args (or a take, ignored).
function wp:bind() end
function wp:unbind() drag = nil end

function wp:renderToolbarBits(_) end

--contract: pushes body palette, draws the canvas, invokes dispatch at end-of-body so wiring-scope keys (when 1.3b adds them) reach the dispatcher.
function wp:renderBody(_, w, h, dispatch)
  if not ctx then return end
  pushBodyStyles()
  if ImGui.BeginChild(ctx, '##wiringCanvas', w, h,
                      ImGui.ChildFlags_None,
                      ImGui.WindowFlags_NoNav) then
    renderCanvas(w, h)
  end
  ImGui.EndChild(ctx)
  popBodyStyles()
  if dispatch then dispatch(self:focusState()) end
end

function wp:renderStatusBar(_)
  if not ctx then return end
  ImGui.Text(ctx, 'wiring')
end

--contract: acceptCmds=false if picker active, any item active, or modal was open at frame start.
function wp:focusState()
  if not ctx then return { suppressKbd = false, acceptCmds = false } end
  local pa = chrome and chrome.pickerIsActive() or false
  return {
    suppressKbd = pa,
    acceptCmds  = (not pa)
                  and not ImGui.IsAnyItemActive(ctx)
                  and not modalHost:wasOpenAtFrameStart(),
  }
end


----- Wiring scope (slice 1.3b)

local wiring = cmgr:scope('wiring')
wiring:registerAll{ wiringAddFx = function() wv:addFx(0, 0) end }
wiring:bindAll    { wiringAddFx = { ImGui.Key_N } }

return wp
