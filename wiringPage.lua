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
local LABEL_PAD        = 4   -- inner horizontal padding for the wrapped name
local LABEL_MAX_LINES  = 2
local LABEL_ELLIPSIS   = '…'
local PORT_SIZE        = 8
local PORT_GAP         = 4
local PORT_BAND_OFFSET = 6   -- gap between node edge and the hover-only port row
local PORT_HIT_PAD     = 4   -- hit area extends this far beyond the visual square on each side
local PORT_TOOLTIP_GAP = 4   -- pixels between port top and tooltip bottom edge
local KEYBOARD_GAP     = 6   -- gap between node right edge and the midi keyboard icon

-- How far port geometry reaches past a node edge. Drives the node-level
-- hover inflation so the row stays drawn while the mouse is anywhere in
-- the padded hit area.
local PORT_REACH = PORT_BAND_OFFSET + PORT_SIZE + PORT_HIT_PAD

local WIRE_GAP        = 14    -- perpendicular pitch between parallel wires in the same pair-group
local WIRE_THICK      = 1
local WIRE_ARROW_LEN  = 9
local WIRE_ARROW_WID  = 8
local WIRE_LABEL_SIZE = 10    -- font size for the audio-port-number label (smaller than node labels)
local WIRE_LABEL_PAD  = 1     -- pixels of clearance between digit and the enclosing bg patch
local WIRE_LABEL_LEAD = 6     -- gap from node rect edge to label's near edge, measured along wire (consistent across wire angles)

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
-- kind at drag-start (shift can release thereafter). ancestors is the
-- backward reachability set from fromId — dropping on any of them would
-- close a cycle (Y→…→fromId already exists). Computed once at drag-start
-- and consulted at hover-time so cycle-forming targets get no visual
-- encouragement. Cleared on mouseup (committing the wire if a target was
-- eligible) or on Esc.
--
-- Mousedown precedence: shift-hover (wireDraft) > body-hit (drag) >
-- anywhere else (band). All three are mutually exclusive while live.
local drag      = nil  -- { mx0, my0, starts = { [id] = {x,y}, … } }
local band      = nil  -- { mx0, my0 } — current corner is GetMousePos
local wireDraft = nil  -- { type='audio'|'midi', fromId, fromPort?, ancestors }
local shiftWas  = false

-- Last canvas origin, captured at the top of renderCanvas. Lets openFxPicker
-- (called from the N-key dispatch path, which runs after renderCanvas exits)
-- recover logical mouse coords from screen-space GetMousePos.
local canvasOrigin = { ox = 0, oy = 0 }

-- Forward decl: renderCanvas's RMB handler calls openFxPicker, defined below
-- the public API alongside the wiring-scope command registrations.
local openFxPicker

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

-- Split a single whitespace-free word into pieces at CamelCase boundaries
-- (lowercase byte immediately followed by uppercase byte). Plugin names are
-- ASCII in practice, so byte-class checks are sufficient.
local function camelSplit(word)
  local pieces, last = {}, 1
  for i = 2, #word do
    local prev, cur = word:byte(i - 1), word:byte(i)
    if prev >= 97 and prev <= 122 and cur >= 65 and cur <= 90 then
      pieces[#pieces + 1] = word:sub(last, i - 1)
      last = i
    end
  end
  pieces[#pieces + 1] = word:sub(last)
  return pieces
end

-- Tokenise into atoms with per-pair separators. Each atom is a string;
-- seps[k] is the joiner that goes between atoms[k] and atoms[k+1] when
-- they stay on the same line. ' ' between whitespace-separated words,
-- '' between CamelCase pieces of one word (so re-joined lines have no
-- inserted space at the case boundary).
local function atomise(text)
  local atoms, seps = {}, {}
  for word in text:gmatch('%S+') do
    local pieces = camelSplit(word)
    for j, piece in ipairs(pieces) do
      atoms[#atoms + 1] = piece
      if #atoms > 1 then
        seps[#atoms - 1] = (j == 1) and ' ' or ''
      end
    end
  end
  return atoms, seps
end

-- Greedy word-wrap into at most LABEL_MAX_LINES lines bounded by maxW.
-- Breaks at whitespace and CamelCase boundaries; the final line ends in
-- LABEL_ELLIPSIS when the remainder doesn't fit. Assumes the desired font
-- is already pushed (CalcTextSize uses it).
local function wrapLabel(text, maxW)
  local function widthOf(s) return (ImGui.CalcTextSize(ctx, s)) end
  local function ellipsise(s)
    for n = #s, 0, -1 do
      local cand = s:sub(1, n) .. LABEL_ELLIPSIS
      if widthOf(cand) <= maxW then return cand end
    end
    return LABEL_ELLIPSIS
  end

  local atoms, seps = atomise(text)
  if #atoms == 0 then return { '' } end

  local lines, lineStart, cur = {}, {}, nil
  for i, atom in ipairs(atoms) do
    if widthOf(atom) > maxW then
      if cur then lines[#lines + 1] = cur; cur = nil end
      lineStart[#lines + 1] = i
      lines[#lines + 1] = ellipsise(atom)
    elseif cur == nil then
      cur = atom
      lineStart[#lines + 1] = i
    else
      local cand = cur .. (seps[i - 1] or '') .. atom
      if widthOf(cand) <= maxW then
        cur = cand
      else
        lines[#lines + 1] = cur
        cur = atom
        lineStart[#lines + 1] = i
      end
    end
  end
  if cur then lines[#lines + 1] = cur end

  if #lines <= LABEL_MAX_LINES then return lines end

  -- Overflow: keep the first LABEL_MAX_LINES-1 lines verbatim; pack the
  -- remaining atoms into the final line with a trailing ellipsis.
  local out = {}
  for k = 1, LABEL_MAX_LINES - 1 do out[k] = lines[k] end
  local startIdx, packed = lineStart[LABEL_MAX_LINES], nil
  for i = startIdx, #atoms do
    local sep = (i == startIdx) and '' or (seps[i - 1] or '')
    local cand = packed and (packed .. sep .. atoms[i]) or atoms[i]
    if widthOf(cand .. LABEL_ELLIPSIS) <= maxW then packed = cand else break end
  end
  out[LABEL_MAX_LINES] = packed and (packed .. LABEL_ELLIPSIS) or ellipsise(atoms[startIdx])
  return out
end

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
  local lines = wrapLabel(nv.label, NODE_W - 2 * LABEL_PAD)
  local lineH = select(2, ImGui.CalcTextSize(ctx, 'Mg'))
  local blockH = lineH * #lines
  local yTop = y0 + math.floor((NODE_H - blockH) / 2)
  for i, line in ipairs(lines) do
    local tw = ImGui.CalcTextSize(ctx, line)
    ImGui.DrawList_AddText(dl,
      x0 + math.floor((NODE_W - tw) / 2),
      yTop + (i - 1) * lineH,
      text, line)
  end
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

----- Wire-creation gesture helpers

local AUDIO_BAND_FRAC = 2/3  -- left 2/3 = audio band, right 1/3 = midi band

local function inRect(px, py, x0, y0, x1, y1)
  return px >= x0 and px <= x1 and py >= y0 and py <= y1
end

-- Which side of a body rect the cursor is closest to. Used for the
-- drop-target popout: the user can approach a target from any direction,
-- so the port row hangs off whichever edge is nearest the cursor.
local function nearestSide(mx, my, x0, y0, x1, y1)
  local dT, dB = math.abs(my - y0), math.abs(my - y1)
  local dL, dR = math.abs(mx - x0), math.abs(mx - x1)
  local d = math.min(dT, dB, dL, dR)
  if     d == dT then return 'top'
  elseif d == dB then return 'bottom'
  elseif d == dL then return 'left'
  else                return 'right' end
end

-- Pop-out audio port positions. side='bottom'/'top' lays out a horizontal
-- row centred on the body's x range; 'left'/'right' lays out a vertical
-- column centred on the y range. Returns the port name list and a parallel
-- list of {x,y} top-left corners. Shared by hit-test and draw so both stay
-- in lock-step.
local function audioPortPositions(nv, ox, oy, dir, side)
  local lx0, ly0, lx1, ly1 = nodeRect(nv)
  local x0, y0, x1, y1 = ox + lx0, oy + ly0, ox + lx1, oy + ly1
  local ports = (dir == 'out') and nv.outs.audio or nv.ins.audio
  local count = #ports
  local positions = {}
  if count == 0 then return ports, positions end
  if side == 'top' or side == 'bottom' then
    local rowW   = count * PORT_SIZE + (count - 1) * PORT_GAP
    local startX = math.floor((x0 + x1 - rowW) / 2)
    local y      = (side == 'bottom') and (y1 + PORT_BAND_OFFSET)
                                      or  (y0 - PORT_BAND_OFFSET - PORT_SIZE)
    for i = 1, count do
      positions[i] = { x = startX + (i - 1) * (PORT_SIZE + PORT_GAP), y = y }
    end
  else
    local colH   = count * PORT_SIZE + (count - 1) * PORT_GAP
    local startY = math.floor((y0 + y1 - colH) / 2)
    local x      = (side == 'right') and (x1 + PORT_BAND_OFFSET)
                                     or  (x0 - PORT_BAND_OFFSET - PORT_SIZE)
    for i = 1, count do
      positions[i] = { x = x, y = startY + (i - 1) * (PORT_SIZE + PORT_GAP) }
    end
  end
  return ports, positions
end

local function audioPortHit(nv, mx, my, ox, oy, dir, side)
  local _, positions = audioPortPositions(nv, ox, oy, dir, side)
  for i, p in ipairs(positions) do
    if inRect(mx, my, p.x - PORT_HIT_PAD, p.y - PORT_HIT_PAD,
              p.x + PORT_SIZE + PORT_HIT_PAD, p.y + PORT_SIZE + PORT_HIT_PAD) then
      return i
    end
  end
end

-- Which sides of the node have OUTPUTS (drives the source-side band shape).
local function sourceSides(nv)
  return { audio = #nv.outs.audio > 0, midi = #nv.outs.midi > 0 }
end

-- Which sides of the node have INPUTS (drives the target-side band shape).
local function targetSides(nv)
  return { audio = #nv.ins.audio > 0, midi = #nv.ins.midi > 0 }
end

-- Source-side hover (shift held, no draft). Returns {nv, band, portIdx?} or
-- nil. Either band of the body, or a popped-out output port box. Source
-- popout always hangs below — drag-FROM is stable, no need to chase the
-- cursor with the row.
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
        local i = audioPortHit(nv, mx, my, ox, oy, 'out', 'bottom')
        if i then return { nv = nv, band = 'audio', portIdx = i } end
      end
    end
  end
end

-- Target-side hover (draft in flight). Returns {nv, side, portIdx?} or nil.
-- side is which body edge the cursor is closest to — drives where an audio
-- draft's input popout shows. Audio drafts also accept a popped-out input
-- port hanging off that side.
local function dropTargetHit(nodeViews, mx, my, ox, oy, draft)
  for _, nv in ipairs(nodeViews) do
    local lx0, ly0, lx1, ly1 = nodeRect(nv)
    local x0, y0, x1, y1 = ox + lx0, oy + ly0, ox + lx1, oy + ly1
    if inRect(mx, my, x0, y0, x1, y1) then
      return { nv = nv, side = nearestSide(mx, my, x0, y0, x1, y1) }
    end
    if draft.type == 'audio' and #nv.ins.audio > 1 then
      local side = nearestSide(mx, my, x0, y0, x1, y1)
      local i = audioPortHit(nv, mx, my, ox, oy, 'in', side)
      if i then return { nv = nv, side = side, portIdx = i } end
    end
  end
end

-- Refuse self / ancestors (cycle), and any target lacking an input port
-- of the draft's type. DAG.validate would catch them too, but hover-time
-- rejection gives instant visual feedback rather than a silent drop with
-- no edge appearing.
local function dropEligible(draft, target)
  if not target then return false end
  if draft.ancestors[target.nv.id] then return false end
  if draft.type == 'midi'  and #target.nv.ins.midi  == 0 then return false end
  if draft.type == 'audio' and #target.nv.ins.audio == 0 then return false end
  return true
end

----- Wire-creation overlays

-- Audio-band / midi-band sub-rect of the body. sides tells us whether the
-- node has both kinds of I/O (in the relevant direction) — if so the band
-- is half the body; otherwise the band spans the whole body.
local function bandRect(nv, ox, oy, sides, band)
  local lx0, ly0, lx1, ly1 = nodeRect(nv)
  local x0, y0, x1, y1 = ox + lx0, oy + ly0, ox + lx1, oy + ly1
  if sides.audio and sides.midi then
    local split = math.floor(x0 + (x1 - x0) * AUDIO_BAND_FRAC)
    if band == 'audio' then return x0, y0, split, y1, 'left' end
    return split, y0, x1, y1, 'right'
  end
  return x0, y0, x1, y1, 'both'
end

-- Selection-style outline around the band the cursor is on. Only the
-- outer-body corners round; the split edge between audio and midi stays
-- sharp.
local function drawBandOutline(dl, nv, ox, oy, sides, band)
  local x0, y0, x1, y1, round = bandRect(nv, ox, oy, sides, band)
  local flags
  if     round == 'left'  then flags = ImGui.DrawFlags_RoundCornersLeft
  elseif round == 'right' then flags = ImGui.DrawFlags_RoundCornersRight
  else                         flags = ImGui.DrawFlags_RoundCornersAll
  end
  ImGui.DrawList_AddRect(dl,
    x0 - SELECTED_INFLATE, y0 - SELECTED_INFLATE,
    x1 + SELECTED_INFLATE, y1 + SELECTED_INFLATE,
    chrome.colour('wiring.node.selected'), CORNER_R, flags, SELECTED_STROKE)
end

-- Anchor point for the midi keyboard icon — just outside the body's
-- right edge, vertically centred. The icon is a small external marker,
-- not an in-body overlay.
local function keyboardAnchor(nv, ox, oy)
  local _, ly0, lx1, ly1 = nodeRect(nv)
--  return ox + lx1 + KEYBOARD_GAP, oy + (ly0 + ly1) / 2
  return ox + lx1 - KEYBOARD_GAP * 1.5 - 8, oy + ly0 + KEYBOARD_GAP * 1.5
end

-- Small piano-keyboard icon (C, C#, D, D#, E): 3 outlined white keys with
-- 2 filled black keys overlaying the C-D and D-E boundaries. Drawn with
-- its left edge at `left` and vertical centre at `vertCenter`. Stand-in
-- for the midi tint — later this will gain an in/out arrow to distinguish
-- direction.
local function drawKeyboardIcon(dl, left, vertCenter)
  local col    = chrome.colour('text')
  local kw, kh = 4, 10
  local bw, bh = 2, 5
  local ix0    = math.floor(left)
  local iy0    = math.floor(vertCenter - kh / 2)
  for i = 0, 2 do
    local x = ix0 + i * kw
    ImGui.DrawList_AddRect(dl, x, iy0, x + kw+1, iy0 + kh+1, col, 0, 0, 1)
  end
  for _, i in ipairs{1, 2} do
    local cx  = ix0 + i * kw
    local bx0 = math.floor(cx - bw / 2)
    ImGui.DrawList_AddRectFilled(dl, bx0, iy0, bx0 + bw+1, iy0 + bh+1, col)
  end
end

-- Pop-out audio port row (or column). Highlights `highlightIdx` with a
-- selection-style outline — port 1 by default, or the directly-hovered
-- port. dir='out' for source outputs, 'in' for target inputs; side picks
-- which body edge the row hangs off.
local function drawAudioPortRow(dl, nv, ox, oy, dir, side, highlightIdx)
  local ports, positions = audioPortPositions(nv, ox, oy, dir, side)
  local audioCol = chrome.colour('wiring.port.audio')
  local hlCol    = chrome.colour('wiring.node.selected')
  for i, p in ipairs(positions) do
    drawPort(dl, p.x, p.y, audioCol,
      '##port/' .. nv.id .. '/' .. dir .. '/' .. i, ports[i])
    if i == highlightIdx then
      ImGui.DrawList_AddRect(dl,
        p.x - SELECTED_INFLATE, p.y - SELECTED_INFLATE,
        p.x + PORT_SIZE + SELECTED_INFLATE, p.y + PORT_SIZE + SELECTED_INFLATE,
        hlCol, 0, 0, SELECTED_STROKE)
    end
  end
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
  -- Within a pair-group, sort audio wires by labelling cost so the
  -- cheap-to-draw ones take the low slots near the node: 1-1 (no
  -- labels) first, then 1-n (one label), then n-1 (one label), then
  -- n-m (two labels). MIDI sorts after audio and carries no ports.
  local function labelClass(w)
    return (w.fromPort == 1 and 0 or 2) + (w.toPort == 1 and 0 or 1)
  end
  for _, key in ipairs(order) do
    table.sort(groups[key].wires, function(x, y)
      if x.type ~= y.type then return x.type == 'audio' end
      if x.type ~= 'audio' then return false end
      local cx, cy = labelClass(x), labelClass(y)
      if cx ~= cy then return cx < cy end
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
  -- The eye reads an isoceles triangle's centre as its centroid (1/3
  -- from the base, 2/3 from the tip). Anchor the centroid on the wire
  -- midpoint so the arrow looks centred along the wire, not biased
  -- forward by L/6. The +0.5 lateral offset moves all three vertices
  -- onto pixel centres rather than boundaries, which empirically
  -- removes the top-left fill rule's asymmetric exclusion of the
  -- bottom-right diagonal.
  local mx, my   = (sx + ex) / 2 + 0.5, (sy + ey) / 2 + 0.5
  local tipDist  = WIRE_ARROW_LEN * 2 / 3
  local baseDist = WIRE_ARROW_LEN / 3
  local halfW    = WIRE_ARROW_WID / 2
  local tipx, tipy = mx + ux * tipDist,  my + uy * tipDist
  local bx,   by   = mx - ux * baseDist, my - uy * baseDist
  local b1x = bx + px * halfW
  local b1y = by + py * halfW
  local b2x = bx - px * halfW
  local b2y = by - py * halfW
  ImGui.DrawList_AddTriangleFilled(dl, tipx, tipy, b1x, b1y, b2x, b2y, col)
end

-- Audio port-number label as a tight bg-filled patch sized to the
-- digit's bbox, placed up the wire past the node's exit point. The
-- fill occludes the wire segment behind it so the digit reads cleanly
-- on top of the line. For parallel wires, slots alternate between two
-- along-wire positions (near and far, separated by 2*WIRE_GAP): odd i
-- sits at LEAD, even i at LEAD+2*WIRE_GAP. That guarantees axis-aligned
-- rects on adjacent parallel wires never overlap (perp 10 + along 20 vs
-- a ~10×14 rect). Hover-tooltip shows the port name (synthetic 'in N' /
-- 'out N' until TrackFX_GetIOName lands).
local function drawWireEndLabel(dl, ax, ay, fx, fy, i, n, portIdx, portName, idStem, col)
  local dx, dy = fx - ax, fy - ay
  local exitD, len = nodeExitDist(dx, dy)
  if len < 1 then return end
  local txt = tostring(portIdx)
  if wireFont then ImGui.PushFont(ctx, wireFont, WIRE_LABEL_SIZE) end
  local tw, th = ImGui.CalcTextSize(ctx, txt)
  local hw = math.ceil(tw / 2) + WIRE_LABEL_PAD
  local hh = math.ceil(th / 2) + WIRE_LABEL_PAD
  -- Half-extent of the axis-aligned rect projected onto the wire axis:
  -- letting the gap be measured from the projected near edge keeps the
  -- visible LEAD constant whether the wire is horizontal or vertical.
  local proj = (hw * math.abs(dx) + hh * math.abs(dy)) / len
  local slot = ((i - 1) % 2 == 0) and 0 or (2 * WIRE_LABEL_LEAD)
  local labelDist = math.min(len * 0.45, exitD + WIRE_LABEL_LEAD + proj + slot)
  local t  = labelDist / len
  local cx = ax + t * dx
  local cy = ay + t * dy
  local x0, y0, x1, y1 = cx - hw, cy - hh, cx + hw, cy + hh
  ImGui.DrawList_AddRectFilled(dl, x0, y0, x1, y1, chrome.colour('bg'))
  ImGui.DrawList_AddText(dl,
    math.floor(cx - tw / 2), math.floor(cy - th / 2), col, txt)
  if wireFont then ImGui.PopFont(ctx) end
  ImGui.SetCursorScreenPos(ctx, x0, y0)
  ImGui.InvisibleButton(ctx, idStem, 2 * hw, 2 * hh)
  if portName and ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_ForTooltip) then
    ImGui.SetNextWindowPos(ctx, cx, y0 - PORT_TOOLTIP_GAP,
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
              local stem = '##wire/' .. w.from .. ':' .. w.fromPort
                                .. '->' .. w.to .. ':' .. w.toPort
              if w.fromPort ~= 1 then
                drawWireEndLabel(dl, sx, sy, ex, ey, i, n,
                  w.fromPort, w.fromPortName, stem .. '/from', col)
              end
              if w.toPort ~= 1 then
                drawWireEndLabel(dl, ex, ey, sx, sy, i, n,
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
  canvasOrigin.ox, canvasOrigin.oy = ox, oy

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

  -- In-flight draft wire: drawn in the same pre-pass slot as committed
  -- wires so the source body (and the target body, when the cursor is
  -- over one) overpaint it. Endpoint is the raw cursor — body occlusion
  -- handles the clipping for free.
  if wireDraft then
    local src = nodesById[wireDraft.fromId]
    if src then
      local col = wireDraft.type == 'midi' and midiCol or audioCol
      ImGui.DrawList_AddLine(dl, ox + src.pos.x, oy + src.pos.y, mx, my, col, WIRE_THICK)
    end
  end

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
  end

  -- Capacity-overflow overlay: union of node-id sets across every error
  -- entry, stroked after the selection outline so error-and-selected nodes
  -- read as red (triage colour wins).
  local errs = wv:errors()
  if #errs > 0 then
    local errorIds = {}
    for _, err in ipairs(errs) do
      for id in pairs(err.nodeIds) do errorIds[id] = true end
    end
    local errCol = chrome.colour('wiring.node.error')
    for _, nv in ipairs(nodeViews) do
      if errorIds[nv.id] then
        local lx0, ly0, lx1, ly1 = nodeRect(nv)
        ImGui.DrawList_AddRect(dl,
          ox + lx0 - SELECTED_INFLATE, oy + ly0 - SELECTED_INFLATE,
          ox + lx1 + SELECTED_INFLATE, oy + ly1 + SELECTED_INFLATE,
          errCol, CORNER_R, 0, SELECTED_STROKE)
      end
    end
  end

  -- Source-side overlay: outline the hovered band; keyboard icon over the
  -- midi region whenever the source has midi outs.
  if sourceHit then
    local sides = sourceSides(sourceHit.nv)
    drawBandOutline(dl, sourceHit.nv, ox, oy, sides, sourceHit.band)
    if sides.midi then
      drawKeyboardIcon(dl, keyboardAnchor(sourceHit.nv, ox, oy))
    end
  end

  -- Target-side overlay: body gets the selection-style outline as the
  -- universal drop-target cue; midi drafts additionally show the keyboard
  -- icon over the midi region. The in-flight wire endpoint and the port
  -- popout (below) are the further cues for audio drafts.
  if targetHit then
    local lx0, ly0, lx1, ly1 = nodeRect(targetHit.nv)
    ImGui.DrawList_AddRect(dl,
      ox + lx0 - SELECTED_INFLATE, oy + ly0 - SELECTED_INFLATE,
      ox + lx1 + SELECTED_INFLATE, oy + ly1 + SELECTED_INFLATE,
      chrome.colour('wiring.node.selected'), CORNER_R, 0, SELECTED_STROKE)
    if wireDraft.type == 'midi' then
      local sides = targetSides(targetHit.nv)
      if sides.midi then
        drawKeyboardIcon(dl, keyboardAnchor(targetHit.nv, ox, oy))
      end
    end
  end

  -- Pop-out audio port rows: source outputs hang below the body on
  -- shift-hover; target inputs hang off whichever body edge is nearest the
  -- cursor during an audio draft. Default highlight = port 1 (the port the
  -- wire lands on if mouseup happens on the body); explicit port hover
  -- moves the highlight.
  if sourceHit and sourceHit.band == 'audio' and #sourceHit.nv.outs.audio > 1 then
    drawAudioPortRow(dl, sourceHit.nv, ox, oy, 'out', 'bottom',
      sourceHit.portIdx or 1)
  end
  if targetHit and wireDraft.type == 'audio' and #targetHit.nv.ins.audio > 1 then
    drawAudioPortRow(dl, targetHit.nv, ox, oy, 'in', targetHit.side,
      targetHit.portIdx or 1)
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
      local anc = wv:ancestorsOf(sourceHit.nv.id)
      if sourceHit.band == 'midi' then
        wireDraft = { type = 'midi', fromId = sourceHit.nv.id, ancestors = anc }
      else
        wireDraft = { type = 'audio', fromId = sourceHit.nv.id,
                      fromPort = sourceHit.portIdx or 1, ancestors = anc }
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

  -- Right-click anywhere on the canvas opens the FX picker, anchored at the
  -- cursor — same code path as the N-key shortcut, just with explicit coords.
  if not drag and not band and not wireDraft
      and ImGui.IsMouseClicked(ctx, 1) then
    openFxPicker(mx - ox, my - oy)
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
  local errs = wv:errors()
  if #errs == 0 then
    ImGui.Text(ctx, 'wiring')
  else
    ImGui.Text(ctx, ('wiring — %d capacity error%s')
                    :format(#errs, #errs == 1 and '' or 's'))
  end
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

-- REAPER hands us "Type: Name (Author)" — or, for multi-out plugins,
-- "Type: Name (Author) (N outs)" — in EnumInstalledFX, and either
-- parenthetical may itself contain balanced parens (e.g. a vendor written
-- "Modartt SAS (France)"). The picker row shows the full form to
-- disambiguate same-named plugins from different vendors; the node label
-- drops the prefix and everything from the first balanced () onward.
-- Strip on commit, not in wm.
local function shortFxName(s)
  s = s:gsub('^[^:]+:%s*', '')
  s = s:gsub('%s*%b().*$', '')
  return s
end

local function findMasterPos()
  for _, nv in ipairs(wv:nodeViews()) do
    if nv.id == 'master' then return nv.pos.x, nv.pos.y end
  end
  return 0, 0
end

-- Place an auto-spawned source on the master→cursor ray, pulled back from
-- the generator just far enough that the two body rects don't collide along
-- the ray. Degenerate (cursor on master): fall back to a horizontal offset.
local SOURCE_PAD = 24
local function sourcePosFor(genX, genY)
  local mxp, myp = findMasterPos()
  local dx, dy = genX - mxp, genY - myp
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1 then return genX - NODE_W - SOURCE_PAD, genY end
  local ux, uy = dx / len, dy / len
  local tx = (ux == 0) and math.huge or (NODE_W / 2 / math.abs(ux))
  local ty = (uy == 0) and math.huge or (NODE_H / 2 / math.abs(uy))
  local exit = math.min(tx, ty)
  local sep  = 2 * exit + SOURCE_PAD
  return genX - ux * sep, genY - uy * sep
end

openFxPicker = function(x, y)
  if x == nil then
    local mx, my = ImGui.GetMousePos(ctx)
    x, y = mx - canvasOrigin.ox, my - canvasOrigin.oy
  end
  local sx, sy = sourcePosFor(x, y)
  modalHost:open{
    kind     = 'wiringFxPicker',
    title    = 'Add FX',
    items    = wv:listInstalledFX(),
    flags    = ImGui.WindowFlags_NoNav,
    callback = function(fx)
      wv:addFx(x, y, { name = shortFxName(fx.name), ident = fx.ident },
               { sourcePos = { x = sx, y = sy } })
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
