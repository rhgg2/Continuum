-- See docs/wiringPage.md for the model.
-- @noindex

--invariant: render + input only — wiringPage draws the canvas and reads keyboard / mouse. It holds no wm reference: every graph query goes through wv, every mutation will go through wv (the manager-facing surface).
--invariant: wiring page is project-wide — bind() takes no take and never re-keys cm; the tracker take and the sampler track are unaffected by switching to / from wiring.
--invariant: the page owns every pixel — node-box geometry, port slot layout, hit-test boxes are all derived here from wv's viewport-independent nodeViews. wv carries label + category + audio/MIDI counts; the page turns those into rects and tints.
--invariant: at Stage 1.3d the page draws wires as a pre-pass before nodes — centre-to-centre lines occluded by the rounded rects, midpoint arrow for orientation, parallel wires in the same unordered pair offset perpendicularly with MIDI sorted to the right, non-1 audio ports labelled by number with hover-tooltip names. add-fx / drag / rubber-band unchanged; shift-gated split-band hover drives wire creation, see design/wiring.md.

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
-- (a click) clears the selection.
--
-- wireDraft: captured at mousedown-on-shift-hover. type locks the wire
-- kind at drag-start (shift can release thereafter). descendants is the
-- forward reachability set from fromId, computed once and consulted at
-- hover-time so cycle-forming drop targets get no visual encouragement.
-- Cleared on mouseup (committing the wire if a target was eligible) or
-- on Esc.
--
-- Mousedown precedence: shift-hover (wireDraft) > body-hit (drag) >
-- anywhere else (band). All three are mutually exclusive while live.
local drag      = nil  -- { mx0, my0, starts = { [id] = {x,y}, … } }
local band      = nil  -- { mx0, my0 } — current corner is GetMousePos
local wireDraft = nil  -- { type='audio'|'midi', fromId, fromPort?, descendants }
local shiftWas  = false

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

----- Wire-creation gesture helpers

local AUDIO_BAND_FRAC = 2/3  -- left 2/3 = audio band, right 1/3 = midi band
local TINT_ALPHA      = 0.5  -- midi-band tint over the right 1/3
local HOVER_ALPHA     = 0.4  -- hover overlay tint for either band

local function withAlpha(col, alphaFrac)
  local r, g, b = ImGui.ColorConvertU32ToDouble4(col)
  return ImGui.ColorConvertDouble4ToU32(r, g, b, alphaFrac)
end

local function inRect(px, py, x0, y0, x1, y1)
  return px >= x0 and px <= x1 and py >= y0 and py <= y1
end

-- Per-port hit test for a popped-out audio port row. Mirrors drawPortBand's
-- centred layout. dir='out' for the row below the body, 'in' for above.
local function audioPortHit(nv, mx, my, ox, oy, dir)
  local ports = (dir == 'out') and nv.outs.audio or nv.ins.audio
  local count = #ports
  if count == 0 then return nil end
  local lx0, ly0, lx1, ly1 = nodeRect(nv)
  local rowW = count * PORT_SIZE + (count - 1) * PORT_GAP
  local cx   = math.floor((ox + lx0 + ox + lx1 - rowW) / 2)
  local y    = (dir == 'out') and (oy + ly1 + PORT_BAND_OFFSET)
                              or  (oy + ly0 - PORT_BAND_OFFSET - PORT_SIZE)
  for i = 1, count do
    local px = cx + (i - 1) * (PORT_SIZE + PORT_GAP)
    if inRect(mx, my, px - PORT_HIT_PAD, y - PORT_HIT_PAD,
              px + PORT_SIZE + PORT_HIT_PAD, y + PORT_SIZE + PORT_HIT_PAD) then
      return i
    end
  end
end

-- Which sides of the node have outputs (drives whether the split shows and
-- where a body-click lands). master / midi-only generators / audio-only
-- effects all suppress whichever side has nothing to drag from.
local function sourceSides(nv)
  return { audio = #nv.outs.audio > 0, midi = #nv.outs.midi > 0 }
end

-- Source-side hover (shift held, no draft). Returns {nv, band, portIdx?} or
-- nil. Either band of the body, or a popped-out output port box.
local function shiftHoverHit(nodeViews, mx, my, ox, oy)
  for _, nv in ipairs(nodeViews) do
    local sides = sourceSides(nv)
    if sides.audio or sides.midi then
      local lx0, ly0, lx1, ly1 = nodeRect(nv)
      local bx0, by0 = ox + lx0, oy + ly0
      local bx1, by1 = ox + lx1, oy + ly1
      if inRect(mx, my, bx0, by0, bx1, by1) then
        local band
        if sides.audio and sides.midi then
          band = (mx < bx0 + (bx1 - bx0) * AUDIO_BAND_FRAC) and 'audio' or 'midi'
        else
          band = sides.audio and 'audio' or 'midi'
        end
        return { nv = nv, band = band }
      end
      if sides.audio and #nv.outs.audio > 1 then
        local i = audioPortHit(nv, mx, my, ox, oy, 'out')
        if i then return { nv = nv, band = 'audio', portIdx = i } end
      end
    end
  end
end

-- Target-side hover (draft in flight). Returns {nv, portIdx?} or nil. Audio
-- drafts can also land on a popped-out input port above the target.
local function dropTargetHit(nodeViews, mx, my, ox, oy, draft)
  for _, nv in ipairs(nodeViews) do
    local lx0, ly0, lx1, ly1 = nodeRect(nv)
    if inRect(mx, my, ox + lx0, oy + ly0, ox + lx1, oy + ly1) then
      return { nv = nv }
    end
    if draft.type == 'audio' and #nv.ins.audio > 1 then
      local i = audioPortHit(nv, mx, my, ox, oy, 'in')
      if i then return { nv = nv, portIdx = i } end
    end
  end
end

-- Refuse self / descendants (cycle), midi→master, audio→audio-less target.
-- DAG.validate would catch them too, but hover-time rejection gives instant
-- visual feedback rather than a silent drop with no edge appearing.
local function dropEligible(draft, target)
  if not target then return false end
  if draft.descendants[target.nv.id] then return false end
  if draft.type == 'midi' and target.nv.id == 'master' then return false end
  if draft.type == 'audio' and #target.nv.ins.audio == 0 then return false end
  return true
end

local function drawShiftHoverBands(dl, nv, ox, oy, hoveredBand, isPortHit)
  local lx0, ly0, lx1, ly1 = nodeRect(nv)
  local x0, y0, x1, y1 = ox + lx0, oy + ly0, ox + lx1, oy + ly1
  local sides    = sourceSides(nv)
  local tintCol  = withAlpha(chrome.colour('wiring.port.midi'),     TINT_ALPHA)
  local hoverCol = withAlpha(chrome.colour('wiring.node.selected'), HOVER_ALPHA)

  if sides.audio and sides.midi then
    local split = x0 + (x1 - x0) * AUDIO_BAND_FRAC
    ImGui.DrawList_AddRectFilled(dl, split, y0, x1, y1, tintCol,
      CORNER_R, ImGui.DrawFlags_RoundCornersRight)
    if not isPortHit then
      if hoveredBand == 'audio' then
        ImGui.DrawList_AddRectFilled(dl, x0, y0, split, y1, hoverCol,
          CORNER_R, ImGui.DrawFlags_RoundCornersLeft)
      else
        ImGui.DrawList_AddRectFilled(dl, split, y0, x1, y1, hoverCol,
          CORNER_R, ImGui.DrawFlags_RoundCornersRight)
      end
    end
  elseif sides.midi then
    ImGui.DrawList_AddRectFilled(dl, x0, y0, x1, y1, tintCol, CORNER_R)
  elseif not isPortHit then
    ImGui.DrawList_AddRectFilled(dl, x0, y0, x1, y1, hoverCol, CORNER_R)
  end
end

local function drawDropTargetOverlay(dl, nv, ox, oy, draftType, portIdx)
  local lx0, ly0, lx1, ly1 = nodeRect(nv)
  local x0, y0, x1, y1 = ox + lx0, oy + ly0, ox + lx1, oy + ly1
  local tintCol  = withAlpha(chrome.colour('wiring.port.midi'),     TINT_ALPHA)
  local hoverCol = withAlpha(chrome.colour('wiring.node.selected'), HOVER_ALPHA)
  if draftType == 'midi' then
    ImGui.DrawList_AddRectFilled(dl, x0, y0, x1, y1, tintCol, CORNER_R)
  elseif not portIdx then
    ImGui.DrawList_AddRectFilled(dl, x0, y0, x1, y1, hoverCol, CORNER_R)
  end
end

-- Pop-out audio port rows (outputs below source on shift-hover, inputs above
-- target during an audio draft). MIDI stays implicit on the band itself.
local function drawAudioPortRow(dl, nv, ox, oy, dir)
  local lx0, ly0, lx1, ly1 = nodeRect(nv)
  local ports = (dir == 'out') and nv.outs.audio or nv.ins.audio
  local y     = (dir == 'out') and (oy + ly1 + PORT_BAND_OFFSET)
                              or  (oy + ly0 - PORT_BAND_OFFSET - PORT_SIZE)
  drawPortBand(dl, ox + lx0, ox + lx1, y, ports, {},
    chrome.colour('wiring.port.audio'), chrome.colour('wiring.port.midi'),
    '##port/' .. nv.id .. '/' .. dir)
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

  local mx, my    = ImGui.GetMousePos(ctx)
  local shiftHeld = ImGui.GetKeyMods(ctx) & ImGui.Mod_Shift ~= 0
  -- Pressing shift clears the selection so the wire-creation hover
  -- affordance owns the visual layer. Rising edge only — holding shift
  -- doesn't keep wiping selections the user might rebuild mid-frame.
  if shiftHeld and not shiftWas then wv:setSelection{} end
  shiftWas = shiftHeld

  local nodeViews = wv:nodeViews()

  -- In-flight selection preview: while a band is live, nodes its rect
  -- currently intersects render with the selected outline already — the
  -- visual matches what mouseup will commit. Otherwise the committed
  -- selection drives the outline.
  local selection
  if band then
    selection = nodesInBand(nodeViews, ox, oy, band.mx0, band.my0, mx, my)
  else
    selection = wv:selection()
  end

  -- Drag projection: while a drag is live, override every dragged
  -- node's pos by (delta) so geometry below (wire pre-pass, hit test,
  -- node draw, hover band) all see the in-flight positions.
  if drag then
    local dx, dy = mx - drag.mx0, my - drag.my0
    for _, nv in ipairs(nodeViews) do
      local s = drag.starts[nv.id]
      if s then nv.pos.x, nv.pos.y = s.x + dx, s.y + dy end
    end
  end

  local nodesById = {}
  for _, nv in ipairs(nodeViews) do nodesById[nv.id] = nv end

  -- Existing wires: pre-pass so the rounded node rects below overpaint
  -- the centre. Wire colour reuses the matching port colour role.
  local audioCol = chrome.colour('wiring.port.audio')
  local midiCol  = chrome.colour('wiring.port.midi')
  drawWiresPass(dl, wv:wireViews(), nodesById, ox, oy, audioCol, midiCol)

  -- Wire-creation hover state: source-side while shift is held with no
  -- draft in flight; target-side while a draft is in flight (shift may
  -- have been released). dropTargetHit returns the under-cursor node;
  -- dropEligible then refuses self / descendants / type-mismatched
  -- targets so the hover gives no visual encouragement to invalid drops.
  local sourceHit, targetHit
  if wireDraft then
    local hit = dropTargetHit(nodeViews, mx, my, ox, oy, wireDraft)
    if hit and dropEligible(wireDraft, hit) then targetHit = hit end
  elseif shiftHeld then
    sourceHit = shiftHoverHit(nodeViews, mx, my, ox, oy)
  end

  for _, nv in ipairs(nodeViews) do
    drawNode(dl, nv, ox, oy, selection[nv.id])
    if sourceHit and sourceHit.nv == nv then
      drawShiftHoverBands(dl, nv, ox, oy, sourceHit.band, sourceHit.portIdx ~= nil)
    elseif targetHit and targetHit.nv == nv then
      drawDropTargetOverlay(dl, nv, ox, oy, wireDraft.type, targetHit.portIdx)
    end
  end

  -- Pop-out audio port rows: outputs below source on shift-hover,
  -- inputs above target during an audio draft. MIDI port stays implicit.
  if sourceHit and sourceHit.band == 'audio' and #sourceHit.nv.outs.audio > 1 then
    drawAudioPortRow(dl, sourceHit.nv, ox, oy, 'out')
  end
  if targetHit and wireDraft.type == 'audio' and #targetHit.nv.ins.audio > 1 then
    drawAudioPortRow(dl, targetHit.nv, ox, oy, 'in')
  end

  -- In-flight wire from source-node centre to the cursor.
  if wireDraft then
    local src = nodesById[wireDraft.fromId]
    if src then
      local col = wireDraft.type == 'midi' and midiCol or audioCol
      ImGui.DrawList_AddLine(dl, ox + src.pos.x, oy + src.pos.y, mx, my, col, WIRE_THICK)
    end
  end

  wv:setHover((sourceHit and sourceHit.nv.id)
              or (targetHit and targetHit.nv.id) or nil)

  -- Esc cancels an in-flight draft. Consume the press so the wiring-scope
  -- wiringClearSelection (also bound to Esc) doesn't run on the same key.
  if wireDraft and ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
    wireDraft = nil
  end

  -- Mousedown precedence: shift-hover wins (starts a wire draft); body
  -- hit falls through to drag-to-move; anything else starts a band.
  if not drag and not band and not wireDraft
      and ImGui.IsMouseClicked(ctx, 0) then
    if sourceHit then
      local desc = wv:descendantsOf(sourceHit.nv.id)
      if sourceHit.band == 'midi' then
        wireDraft = { type = 'midi', fromId = sourceHit.nv.id, descendants = desc }
      else
        wireDraft = { type = 'audio', fromId = sourceHit.nv.id,
                      fromPort = sourceHit.portIdx or 1, descendants = desc }
      end
    else
      local bodyHit = nodeUnderMouse(nodeViews, ox, oy)
      if bodyHit then
        local starts = {}
        if selection[bodyHit.id] then
          for _, nv in ipairs(nodeViews) do
            if selection[nv.id] then starts[nv.id] = { x = nv.pos.x, y = nv.pos.y } end
          end
        else
          starts[bodyHit.id] = { x = bodyHit.pos.x, y = bodyHit.pos.y }
        end
        drag = { mx0 = mx, my0 = my, starts = starts }
      else
        band = { mx0 = mx, my0 = my }
      end
    end
  elseif wireDraft and not ImGui.IsMouseDown(ctx, 0) then
    if targetHit then
      wv:addWire{
        type = wireDraft.type,
        from = wireDraft.fromId, fromPort = wireDraft.fromPort,
        to   = targetHit.nv.id,  toPort   = targetHit.portIdx,
      }
    end
    wireDraft = nil
  elseif drag and not ImGui.IsMouseDown(ctx, 0) then
    local dx, dy = mx - drag.mx0, my - drag.my0
    if dx ~= 0 or dy ~= 0 then
      local moves = {}
      for id, s in pairs(drag.starts) do moves[id] = { x = s.x + dx, y = s.y + dy } end
      wv:moveNodes(moves)
    end
    drag = nil
  elseif band and not ImGui.IsMouseDown(ctx, 0) then
    if mx == band.mx0 and my == band.my0 then
      wv:setSelection{}                                        -- empty-canvas click
    else
      wv:setSelection(nodesInBand(nodeViews, ox, oy,
                                  band.mx0, band.my0, mx, my))
    end
    band = nil
  end

  -- Band overlay: drawn last so it floats over nodes and hover affordances.
  if band then
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
function wp:unbind() drag, band, wireDraft, shiftWas = nil, nil, nil, false end

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
