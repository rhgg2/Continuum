-- See docs/wiringPage.md for the model.
-- @noindex

--invariant: render + input only — wiringPage draws the canvas and reads keyboard / mouse. It holds no wm reference: every graph query goes through wv, every mutation will go through wv (the manager-facing surface).
--invariant: wiring page is project-wide — bind() takes no take and never re-keys cm; the tracker take and the sampler track are unaffected by switching to / from wiring.
--invariant: the page owns every pixel — node-box geometry, port slot layout, hit-test boxes are all derived here from wv's viewport-independent nodeViews. wv carries label + category + audio/MIDI counts; the page turns those into rects and tints.
--invariant: at Stage 1.3d the page draws wires as a pre-pass before nodes — centre-to-centre lines occluded by the rounded rects, midpoint arrow for orientation, parallel wires in the same unordered pair offset perpendicularly with MIDI sorted to the right, non-1 audio ports labelled by number with hover-tooltip names. add-fx / drag / rubber-band unchanged; ports still hover-only.

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

----- FX-picker modal kind

-- Typeahead picker, hosted as a modalHost kind so it has no anchor
-- requirement (the wiring page has no toolbar button to hang an inline
-- chrome.drawPicker off). Body mirrors drawPicker's filter+matches+cursor
-- shape but draws inside an active BeginPopupModal; flags=NoNav on open
-- kills ImGui's built-in nav highlight so it doesn't fight our cursor.
-- state = { kind, title, items, buf, cursor, callback }; close(true, fx)
-- delivers one entry from `items`.
modalHost:registerKind('wiringFxPicker', function(state, close)
  if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
  ImGui.SetNextItemWidth(ctx, 280)
  local prev = state.buf or ''
  local _, buf = ImGui.InputText(ctx, '##fxFilter', prev)
  state.buf = buf
  local entered = ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
               or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)
  ImGui.Separator(ctx)

  local lf = buf:lower()
  local matches = {}
  for _, fx in ipairs(state.items) do
    if buf == '' or fx.name:lower():find(lf, 1, true) then
      matches[#matches + 1] = fx
    end
  end
  if ImGui.IsWindowAppearing(ctx) or buf ~= prev then state.cursor = 1 end
  local n = #matches
  local cursor = state.cursor or 1
  if n > 0 then
    if     ImGui.IsKeyPressed(ctx, ImGui.Key_DownArrow) then cursor = cursor % n + 1
    elseif ImGui.IsKeyPressed(ctx, ImGui.Key_UpArrow)   then cursor = (cursor - 2) % n + 1
    end
  end
  cursor = math.min(math.max(cursor, 1), math.max(n, 1))
  state.cursor = cursor

  if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
    close(false)
  elseif entered and matches[cursor] then
    close(true, matches[cursor])
  else
    if ImGui.BeginChild(ctx, '##fxList', 280, 240,
                        ImGui.ChildFlags_None, ImGui.WindowFlags_NoNav) then
      for i, fx in ipairs(matches) do
        if ImGui.Selectable(ctx, fx.name, i == cursor) then close(true, fx) end
      end
    end
    ImGui.EndChild(ctx)
  end
end)

local NODE_W           = 96
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

local WIRE_GAP        = 10    -- perpendicular pitch between parallel wires in the same pair-group
local WIRE_THICK      = 1.5
local WIRE_ARROW_LEN  = 9
local WIRE_ARROW_WID  = 7
local WIRE_LABEL_GAP  = 6     -- pixels past the node rect edge for the audio-port-number label
local WIRE_LABEL_PERP = 6     -- perpendicular displacement of the label off the wire so it doesn't sit on the line

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

----- Wire drawing

-- Group wires by unordered pair {idA, idB}; sort each group so audio
-- precedes MIDI (MIDI sits to the right of the canonical-pair line),
-- then by fromPort then toPort. canonA/canonB record the sorted pair
-- direction so all wires in the group share one perpendicular axis
-- regardless of each wire's own direction.
local function wireGroups(wireViews)
  local groups, order = {}, {}
  for _, w in ipairs(wireViews) do
    local a, b = w.from, w.to
    if a > b then a, b = b, a end
    local key = a .. '\0' .. b
    local g = groups[key]
    if not g then
      g = { canonA = a, canonB = b, wires = {} }
      groups[key] = g
      order[#order + 1] = key
    end
    g.wires[#g.wires + 1] = w
  end
  for _, key in ipairs(order) do
    table.sort(groups[key].wires, function(x, y)
      if x.type ~= y.type then return x.type == 'audio' end
      if x.fromPort ~= y.fromPort then return x.fromPort < y.fromPort end
      return x.toPort < y.toPort
    end)
  end
  return groups, order
end

-- Perpendicular scalar for slot i (1-based) of n parallel wires:
-- centred around 0 so a lone wire sits on the centre line.
local function wireOffset(i, n)
  return (i - (n + 1) / 2) * WIRE_GAP
end

-- Distance from a node centre to where a ray in direction (dx,dy)
-- exits the node rect. Used to place the audio-port label just past
-- the rounded body so it stays visible. Approximates the parallel-
-- offset case by NODE_W/H from the centre, which is within WIRE_GAP
-- of the true intersection — close enough for label placement.
local function nodeExitDist(dx, dy)
  local hw, hh = NODE_W / 2, NODE_H / 2
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1 then return 0, 0 end
  local tx = (dx == 0) and math.huge or hw / math.abs(dx)
  local ty = (dy == 0) and math.huge or hh / math.abs(dy)
  return math.min(tx, ty) * len, len
 end

local function drawWireArrow(dl, sx, sy, ex, ey, col)
  local dx, dy = ex - sx, ey - sy
  local len = math.sqrt(dx * dx + dy * dy)
  if len < WIRE_ARROW_LEN then return end
  local ux, uy = dx / len, dy / len
  local px, py = -uy, ux
  local mx, my = (sx + ex) / 2, (sy + ey) / 2
  local half   = WIRE_ARROW_LEN / 2
  local tipx, tipy = mx + ux * half, my + uy * half
  local b1x = mx - ux * half + px * WIRE_ARROW_WID / 2
  local b1y = my - uy * half + py * WIRE_ARROW_WID / 2
  local b2x = mx - ux * half - px * WIRE_ARROW_WID / 2
  local b2y = my - uy * half - py * WIRE_ARROW_WID / 2
  ImGui.DrawList_AddTriangleFilled(dl, tipx, tipy, b1x, b1y, b2x, b2y, col)
end

-- Audio port-number label near (ax,ay), placed along the wire towards
-- (fx,fy) and perpendicular-displaced by (perpX,perpY) * WIRE_LABEL_PERP.
-- Hover-tooltip on the digit shows the port name (synthetic 'in N' /
-- 'out N' until TrackFX_GetIOName lands).
local function drawWireEndLabel(dl, ax, ay, fx, fy, perpX, perpY, portIdx, portName, idStem, col)
  local dx, dy = fx - ax, fy - ay
  local exitD, len = nodeExitDist(dx, dy)
  if len < 1 then return end
  local labelDist = math.min(len * 0.45, exitD + WIRE_LABEL_GAP)
  local t  = labelDist / len
  local lx = ax + t * dx + perpX * WIRE_LABEL_PERP
  local ly = ay + t * dy + perpY * WIRE_LABEL_PERP
  local txt = tostring(portIdx)
  if wireFont then ImGui.PushFont(ctx, wireFont, wireSize) end
  local tw, th = ImGui.CalcTextSize(ctx, txt)
  local tx, ty = math.floor(lx - tw / 2), math.floor(ly - th / 2)
  ImGui.DrawList_AddText(dl, tx, ty, col, txt)
  if wireFont then ImGui.PopFont(ctx) end
  ImGui.SetCursorScreenPos(ctx, tx, ty)
  ImGui.InvisibleButton(ctx, idStem, math.max(tw, 1), math.max(th, 1))
  if portName and ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_ForTooltip) then
    ImGui.SetNextWindowPos(ctx, tx + tw / 2, ty - PORT_TOOLTIP_GAP,
      ImGui.Cond_Always, 0.5, 1.0)
    ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg, chrome.colour('wiring.tooltip.bg'))
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 4, 2)
    if ImGui.BeginTooltip(ctx) then
      ImGui.Text(ctx, portName)
      ImGui.EndTooltip(ctx)
    end
    ImGui.PopStyleVar(ctx, 1)
    ImGui.PopStyleColor(ctx, 1)
  end
end

local function drawWiresPass(dl, wireViews, nodesById, ox, oy, audioCol, midiCol)
  local groups, order = wireGroups(wireViews)
  for _, key in ipairs(order) do
    local g = groups[key]
    local na, nb = nodesById[g.canonA], nodesById[g.canonB]
    if na and nb then
      local vx, vy = nb.pos.x - na.pos.x, nb.pos.y - na.pos.y
      local vlen = math.sqrt(vx * vx + vy * vy)
      if vlen >= 1 then
        local perpX, perpY = -vy / vlen, vx / vlen
        local n = #g.wires
        for i, w in ipairs(g.wires) do
          local fromNV, toNV = nodesById[w.from], nodesById[w.to]
          if fromNV and toNV then
            local s = wireOffset(i, n)
            local offX, offY = perpX * s, perpY * s
            local sx = ox + fromNV.pos.x + offX
            local sy = oy + fromNV.pos.y + offY
            local ex = ox + toNV.pos.x   + offX
            local ey = oy + toNV.pos.y   + offY
            local col = w.type == 'midi' and midiCol or audioCol
            ImGui.DrawList_AddLine(dl, sx, sy, ex, ey, col, WIRE_THICK)
            drawWireArrow(dl, sx, sy, ex, ey, col)
            if w.type == 'audio' then
              -- Push the label perpendicular to the same side the wire's
              -- own offset already sits on, so labels of parallel wires
              -- spread outward rather than collide on the centre line.
              local lpx, lpy
              if s >= 0 then lpx, lpy =  perpX,  perpY
              else            lpx, lpy = -perpX, -perpY end
              local stem = '##wire/' .. w.from .. ':' .. w.fromPort
                                .. '->' .. w.to .. ':' .. w.toPort
              if w.fromPort ~= 1 then
                drawWireEndLabel(dl, sx, sy, ex, ey, lpx, lpy,
                  w.fromPort, w.fromPortName, stem .. '/from', col)
              end
              if w.toPort ~= 1 then
                drawWireEndLabel(dl, ex, ey, sx, sy, lpx, lpy,
                  w.toPort, w.toPortName, stem .. '/to', col)
              end
            end
          end
        end
      end
    end
  end
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
  -- node's pos by (delta) so geometry below (wire pre-pass, hit test,
  -- node draw, hover band) all see the in-flight positions.
  if drag then
    local mx, my = ImGui.GetMousePos(ctx)
    local dx, dy = mx - drag.mx0, my - drag.my0
    for _, nv in ipairs(nodeViews) do
      local s = drag.starts[nv.id]
      if s then nv.pos.x, nv.pos.y = s.x + dx, s.y + dy end
    end
  end

  local nodesById = {}
  for _, nv in ipairs(nodeViews) do nodesById[nv.id] = nv end

  -- Wire pre-pass: lines run centre-to-centre, the rounded node rects
  -- below overpaint the middle. Wire colour reuses the matching port
  -- colour role.
  local audioCol = chrome.colour('wiring.port.audio')
  local midiCol  = chrome.colour('wiring.port.midi')
  drawWiresPass(dl, wv:wireViews(), nodesById, ox, oy, audioCol, midiCol)

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


----- Wiring scope

-- REAPER hands us "Type: Name (Author)" in EnumInstalledFX. The picker
-- row shows the full form (the prefix and author disambiguate same-named
-- plugins from different vendors), but the node label keeps just the bare
-- name so a 90px box has room to read it. Strip on commit, not in wm.
local function shortFxName(s)
  s = s:gsub('^[^:]+:%s*', '')
  s = s:gsub('%s*%([^()]*%)%s*$', '')
  return s
end

local function openFxPicker()
  modalHost:open{
    kind     = 'wiringFxPicker',
    title    = 'Add FX',
    items    = wv:listInstalledFX(),
    flags    = ImGui.WindowFlags_NoNav,
    callback = function(fx)
      wv:addFx(0, 0, { name = shortFxName(fx.name), ident = fx.ident })
    end,
  }
end

local wiring = cmgr:scope('wiring')
wiring:registerAll{
  wiringAddFx          = openFxPicker,
  wiringClearSelection = function() wv:setSelection{} end,
}
wiring:bindAll{
  wiringAddFx          = { ImGui.Key_N      },
  wiringClearSelection = { ImGui.Key_Escape },
}

return wp
