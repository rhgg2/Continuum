-- See docs/wiringPage.md for the model.
-- @noindex

--invariant: render + input only — wiringPage draws the canvas and reads keyboard / mouse. It holds no wm reference: every graph query goes through wv, every mutation will go through wv (the manager-facing surface).
--invariant: wiring page is project-wide — bind() takes no take and never re-keys cm; the tracker take and the sampler track are unaffected by switching to / from wiring.
--invariant: the page owns every pixel — node-box geometry, port slot layout, hit-test boxes are all derived here from wv's viewport-independent nodeViews. wv carries label + category + audio/MIDI counts; the page turns those into rects and tints.
--invariant: at Stage 1.3b the page handles add-fx (scope key N, testing-only), drag-to-move (single node, or the whole selection when the grabbed node is selected), and rubber-band selection (replace-only, Esc / empty-click clears). Ports remain hover-only.

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

----- Drag / band state (page-local; ephemeral, never persisted)

-- drag: captured at mousedown-on-node-body. starts maps every node
-- under the drag (just the grabbed one if it's unselected, or the
-- whole selection if the grabbed one is in it) to its origin pos.
-- While IsMouseDown each draws at start + (curMouse - startMouse).
-- Mouseup commits the whole set in one wv:moveNodes (one wm:mutate,
-- one wiringChanged signal).
--
-- band: captured at mousedown-on-empty-canvas. While IsMouseDown, drawn
-- as a translucent rect. Mouseup with movement → wv:setSelection of
-- intersected node ids (replace, not additive); mouseup without movement
-- (a click) clears the selection. Drag and band are mutually exclusive:
-- body-hit wins, port-band hit suppresses both (reserved for wire-pull).
local drag = nil  -- { mx0, my0, starts = { [id] = {x,y}, … } }
local band = nil  -- { mx0, my0 } — current corner is GetMousePos

----- Pixel geometry (page-owned)

-- pos is the node's centre in canvas-local coordinates (origin = centre
-- of the viewport, set up in renderCanvas); rect is laid out symmetrically.
local function nodeRect(nv)
  local hw, hh = NODE_W / 2, NODE_H / 2
  return nv.pos.x - hw, nv.pos.y - hh, nv.pos.x + hw, nv.pos.y + hh
end

----- Drawing

local SELECTED_INFLATE = 2
local SELECTED_STROKE  = 2

local function drawNode(dl, nv, ox, oy, isSelected)
  local lx0, ly0, lx1, ly1 = nodeRect(nv)
  local x0, y0, x1, y1 = ox + lx0, oy + ly0, ox + lx1, oy + ly1
  local fill = chrome.colour('wiring.node.' .. nv.category)
  local text = chrome.colour('text')
  ImGui.DrawList_AddRectFilled(dl, x0, y0, x1, y1, fill, CORNER_R)
  if isSelected then
    ImGui.DrawList_AddRect(dl,
      x0 - SELECTED_INFLATE, y0 - SELECTED_INFLATE,
      x1 + SELECTED_INFLATE, y1 + SELECTED_INFLATE,
      chrome.colour('wiring.node.selected'), CORNER_R, 0, SELECTED_STROKE)
  end
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

-- AABB intersection of a pixel-space band rect against every node's
-- body rect (un-inflated; port bands aren't selectable). Returns the
-- set of intersecting ids — empty table if nothing was caught.
local function nodesInBand(nodeViews, ox, oy, bx0, by0, bx1, by1)
  if bx0 > bx1 then bx0, bx1 = bx1, bx0 end
  if by0 > by1 then by0, by1 = by1, by0 end
  local set = {}
  for _, nv in ipairs(nodeViews) do
    local lx0, ly0, lx1, ly1 = nodeRect(nv)
    local x0, y0, x1, y1 = ox + lx0, oy + ly0, ox + lx1, oy + ly1
    if x1 >= bx0 and x0 <= bx1 and y1 >= by0 and y0 <= by1 then
      set[nv.id] = true
    end
  end
  return set
end

local function renderCanvas(w, h)
  local dl     = ImGui.GetWindowDrawList(ctx)
  local sx, sy = ImGui.GetCursorScreenPos(ctx)
  ImGui.DrawList_AddRectFilled(dl, sx, sy, sx + w, sy + h, chrome.colour('bg'))
  -- Canvas origin is the centre of the viewport: logical (0,0) draws
  -- in the middle, positions extend in all four quadrants from there.
  local ox, oy = sx + math.floor(w / 2), sy + math.floor(h / 2)

  local nodeViews = wv:nodeViews()

  -- In-flight selection preview: while a band is live, nodes its rect
  -- currently intersects render with the selected outline already — the
  -- visual matches what mouseup will commit. Otherwise the committed
  -- selection drives the outline.
  local selection
  if band then
    local mx, my = ImGui.GetMousePos(ctx)
    selection = nodesInBand(nodeViews, ox, oy, band.mx0, band.my0, mx, my)
  else
    selection = wv:selection()
  end

  -- Drag projection: while a drag is live, override every dragged
  -- node's pos by (delta) so geometry below (hit test, draw, hover
  -- band) all see the in-flight positions.
  if drag then
    local mx, my = ImGui.GetMousePos(ctx)
    local dx, dy = mx - drag.mx0, my - drag.my0
    for _, nv in ipairs(nodeViews) do
      local s = drag.starts[nv.id]
      if s then nv.pos.x, nv.pos.y = s.x + dx, s.y + dy end
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
    drawNode(dl, nv, ox, oy, selection[nv.id])
  end
  if hoveredNV then drawHoverPorts(dl, hoveredNV, ox, oy) end
  wv:setHover(hoveredNV and hoveredNV.id or nil)

  -- Drag / band bookkeeping. Mousedown on a node body starts a drag;
  -- mousedown on bare canvas (not over any node's hover region) starts
  -- a rubber-band — clicks landing on a hovered port band do neither,
  -- reserving that surface for the future wire-pull gesture. Mouseup
  -- commits whichever was live.
  if not drag and not band and ImGui.IsMouseClicked(ctx, 0) then
    local bodyHit = nodeUnderMouse(nodeViews, ox, oy)
    if bodyHit then
      local mx, my = ImGui.GetMousePos(ctx)
      local starts = {}
      if selection[bodyHit.id] then
        for _, nv in ipairs(nodeViews) do
          if selection[nv.id] then starts[nv.id] = { x = nv.pos.x, y = nv.pos.y } end
        end
      else
        starts[bodyHit.id] = { x = bodyHit.pos.x, y = bodyHit.pos.y }
      end
      drag = { mx0 = mx, my0 = my, starts = starts }
    elseif not hoveredNV then
      local mx, my = ImGui.GetMousePos(ctx)
      band = { mx0 = mx, my0 = my }
    end
  elseif drag and not ImGui.IsMouseDown(ctx, 0) then
    local mx, my = ImGui.GetMousePos(ctx)
    local dx, dy = mx - drag.mx0, my - drag.my0
    if dx ~= 0 or dy ~= 0 then
      local moves = {}
      for id, s in pairs(drag.starts) do moves[id] = { x = s.x + dx, y = s.y + dy } end
      wv:moveNodes(moves)
    end
    drag = nil
  elseif band and not ImGui.IsMouseDown(ctx, 0) then
    local mx, my = ImGui.GetMousePos(ctx)
    if mx == band.mx0 and my == band.my0 then
      wv:setSelection{}                                        -- empty-canvas click
    else
      wv:setSelection(nodesInBand(nodeViews, ox, oy,
                                  band.mx0, band.my0, mx, my))
    end
    band = nil
  end

  -- Band overlay: drawn last so it floats over nodes and hover ports.
  if band then
    local mx, my = ImGui.GetMousePos(ctx)
    local bx0, by0, bx1, by1 = band.mx0, band.my0, mx, my
    if bx0 > bx1 then bx0, bx1 = bx1, bx0 end
    if by0 > by1 then by0, by1 = by1, by0 end
    ImGui.DrawList_AddRect(dl, bx0, by0, bx1, by1,
      chrome.colour('wiring.node.selected'), 0, 0, 1)
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
function wp:unbind() drag, band = nil, nil end

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
wiring:registerAll{
  wiringAddFx          = function() wv:addFx(0, 0) end,
  wiringClearSelection = function() wv:setSelection{} end,
}
wiring:bindAll{
  wiringAddFx          = { ImGui.Key_N      },
  wiringClearSelection = { ImGui.Key_Escape },
}

return wp
