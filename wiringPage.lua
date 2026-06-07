-- See docs/wiringPage.md for the model.
-- @noindex

--invariant: render + input only — wiringPage draws the canvas and reads keyboard / mouse. It holds no wm reference: every graph query goes through wv, every mutation will go through wv (the manager-facing surface).
--invariant: wiring page is project-wide — bind() takes no take and never re-keys cm; the tracker take and the sampler track are unaffected by switching to / from wiring.
--invariant: the page owns every pixel — node-box geometry, port slot layout, hit-test boxes are all derived here from wv's viewport-independent nodeViews. wv carries label + category + audio/MIDI counts; the page turns those into rects and tints.
--invariant: wires draw as a pre-pass before nodes — centre-to-centre lines occluded by the bodies; parallel wires in one unordered pair are offset perpendicularly, MIDI sorted to the right.
--invariant: port rows are top/bottom only. See docs/wiringPage.md § The port band.

local util = require 'util'

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'
local painter = require 'painter'

local cm, cmgr, chrome, gui, modalHost =
  (...).cm, (...).cmgr, (...).chrome, (...).gui, (...).modalHost

local ctx      = gui and gui.ctx or nil
local wireFont = gui and gui.wireFont or nil
local wireSize = gui and gui.fontSize and gui.fontSize.wire or 14
local uiFont   = gui and gui.uiFont or nil
local uiSize   = gui and gui.fontSize and gui.fontSize.ui or 12

local rm = util.instantiate('routingManager')
local wm = util.instantiate('wiringManager', { cm = cm, rm = rm })
local wv = util.instantiate('wiringView', { cm = cm, cmgr = cmgr, wm = wm })

local wp = {}

local NODE_W           = 96
local NODE_H           = 60
local CORNER_R         = 5
local LABEL_PAD        = 4   -- inner horizontal padding for the wrapped name
local LABEL_MAX_LINES  = 2
local LABEL_ELLIPSIS   = '…'
local PORT_SIZE        = 8
local PORT_GAP         = 6
local PORT_BAND_OFFSET = 4   -- gap between node edge and the hover-only port row
local PORT_HIT_PAD     = 4   -- hit area extends this far beyond the visual square on each side
local PORT_TOOLTIP_GAP = 4   -- pixels between port top and tooltip bottom edge
local PORTS_PER_ROW    = 5   -- audio rows wrap after this many ports
local MIDI_SLOT_W      = 13  -- keyboard slot is wider/taller than the audio
local MIDI_SLOT_H      = 11  -- 8×8 square; intrinsic icon dimensions
local MIDI_INSET       = 3   -- px between the body-internal midi icon and the node's right edge
local HANDLE_W         = 13  -- spillover-list chevron, mirrors midi slot envelope
local HANDLE_H         = 11
local HANDLE_INSET     = 4   -- slightly more inset than midi so the caret reads as off-edge
local PORT_ROW_H       = 11  -- tallest slot in the row; defines the shared centreline
local LIST_GAP         = 4   -- pixel gap between handle and dropdown list; the list.hitRect extends back across this gap so chevron-to-list traversal has no dead zone
local CLICK_THRESH     = 4   -- mouseup within this many pixels of mousedown counts as a click, not a drag
local LIST_ROW_PAD_X   = 8
local LIST_ROW_PAD_Y   = 1
local LIST_PAD_Y       = 6   -- extra slack at the list rect's top + bottom, beyond the first/last row's own LIST_ROW_PAD_Y
local LIST_CORNER_R    = 4

local WIRE_GAP        = 14    -- perpendicular pitch between parallel wires in the same pair-group
local WIRE_THICK      = 1
local WIRE_ARROW_LEN  = 9
local WIRE_ARROW_WID  = 8
local WIRE_LABEL_SIZE = 10    -- font size for the audio-port-number label (smaller than node labels)
local WIRE_LABEL_PAD  = 1     -- pixels of clearance between digit and the enclosing bg patch
local WIRE_LABEL_LEAD = 6     -- gap from node rect edge to label's near edge, measured along wire (consistent across wire angles)
local WIRE_END_HIT      = 20  -- length of the rewire/delete hit + highlight band at each wire end (canvas px); clamped to 0.4*wirelen so short wires don't overlap
local WIRE_END_HIT_PERP = 6   -- perpendicular tolerance from the wire centreline for the end-hit
local WIRE_END_HIGHLIGHT = 3  -- stroke width for the highlight overpaint
local WIRE_GRAB_DECAY   = 40  -- redraft start-jump absorber: at mousedown the cursor end of the wire stays at its old position; the gap to the cursor decays linearly over this many pixels of travel
local WIRE_FADER_HIT     = 8   -- screen-px radius around the mid-wire arrow centroid for LMB/RMB hit-test (audio wires only)
local WIRE_FADER_W       = 20  -- strip / knob / hit-rect width (px); centred on the arrow centroid so it covers the triangle
local WIRE_FADER_H       = 140 -- strip / hit-rect height (px); centred vertically on the arrow centroid
local WIRE_FADER_KNOB_H  = 20  -- knob slab height (px); spans the full strip width
local WIRE_FADER_HIT_PAD = 10  -- px to inflate the visibility hit rect on each side, so the fader stays open through small cursor excursions outside the strip
local WIRE_FADER_TOP_DB  = 18  -- top of strip = +18 dB; 0 dB at 75% of travel; below ~5% snaps to -inf
local WIRE_FADER_WHEEL_DB        = 0.5  -- dB per wheel notch (coarse, default)
local WIRE_FADER_WHEEL_DB_FINE   = 0.1  -- dB per wheel notch with Shift
local WIRE_FADER_WHEEL_IDLE_FRAMES = 6  -- commit one setEdgeGain after this many wheel-idle frames so a scroll gesture is one undo entry

local STUB_LEN  = 40    -- canvas px from the consumer rect edge to the stub's far end, along the away-from-master axis
local TAG_GAP   = 3     -- visual gap from the stub's far end to the track-name tag's nearest edge
local TAG_VIS_H = 0.62  -- visible glyph band as a fraction of measured line height (trims ascent/descent slack)

-- Palette pane geometry, mirroring arrangePage's body split.
local PALETTE_W  = 200
local PANE_GAP   = 11   -- 1px vrule sits centred here; neither pane edge touches it
local HEADER_PAD = 8    -- breathing room above the palette header text
local HEADER_GAP = 4    -- space between the header divider and the first row

----- Drag / band state (page-local; ephemeral, never persisted)
-- The gesture state machine — mousedown precedence, what each table
-- captures, forbidden-set and sticky/pin semantics — is the model in
-- docs/wiringPage.md. The shapes below are the only at-site reference.
local drag      = nil  -- { mx0, my0, starts = { [id] = {x,y}, … } }
local band      = nil  -- { mx0, my0 } — current corner is GetMousePos
local wireDraft = nil  -- { type?, cursorEnd='to'|'from', keptId, keptPort?, keptSide?, keptAnchor?, forbidden, mx0, my0, fromList, edgeIdx?, fromPalette?, keptLabel? }
local shiftWas  = false
local pinned     = {}   -- pinned[nodeId][portIdx] = true (promoted to a standing chip)
local listOpenId = nil  -- node whose spillover list is engaged (chevron-gated)
local engagedId  = nil  -- node holding hover priority, probed before the per-node scan
local hoverFreeze = nil  -- { x, y } | nil — suppresses shift-hover until the cursor moves
local sticky = nil  -- { nodeId, side } — pinned node's port row, kept visible post-click
local fader = nil  -- { edgeIdx, rect={x0,y0,x1,y1}, hitRect, currentLin, valueAtClick?, dragging?, wheelPending?, wheelIdleFrames? }
local wireMenu = nil  -- { edgeIdx, anchorX, anchorY } — set on RMB-on-triangle; cleared when BeginPopup returns false
local nodeMenu = nil  -- { nodeId, anchorX, anchorY } — set on RMB-on-body; cleared when BeginPopup returns false
local paletteSource = nil  -- nodeId the palette del button acts on; cleared when the row vanishes
local fxPicker = nil  -- { x, y, sx, sy, anchorSX?, anchorSY?, buf, cursor, items } — RMB/N-key add-FX popup; cleared when BeginPopup returns false

-- Last canvas origin, captured at the top of renderCanvas. Lets openFxPicker
-- (called from the N-key dispatch path, which runs after renderCanvas exits)
-- recover logical mouse coords from screen-space GetMousePos.
local canvasOrigin = { ox = 0, oy = 0 }

-- Forward decls: renderCanvas's RMB handler opens the FX picker and its render
-- block draws it; both are defined below alongside the wiring-scope commands.
local openFxPicker, renderFxPicker

----- Pixel geometry (page-owned)

-- One axis-aligned rect struct shared by every hit test and fill, so the
-- two can't drift; boxRect lifts an {x,y,w,h} slot/row into one.
local function rect(x0, y0, x1, y1) return { x0 = x0, y0 = y0, x1 = x1, y1 = y1 } end
local function inRect(px, py, r)
  return px >= r.x0 and px <= r.x1 and py >= r.y0 and py <= r.y1
end
local function boxRect(b, pad)
  pad = pad or 0
  return rect(b.x - pad, b.y - pad, b.x + b.w + pad, b.y + b.h + pad)
end
local function unionRect(acc, r)
  if r.x0 < acc.x0 then acc.x0 = r.x0 end
  if r.y0 < acc.y0 then acc.y0 = r.y0 end
  if r.x1 > acc.x1 then acc.x1 = r.x1 end
  if r.y1 > acc.y1 then acc.y1 = r.y1 end
end

-- Node body as a canvas-local rect centred on pos. The painter adds the
-- viewport origin at draw and hit-tests use the canvas-local mouse, so one
-- struct serves both and they can't drift.
local function nodeBox(nv)
  local hw, hh = NODE_W / 2, NODE_H / 2
  return rect(nv.pos.x - hw, nv.pos.y - hh, nv.pos.x + hw, nv.pos.y + hh)
end

----- Drawing

local SELECTED_INFLATE = 0   -- outline traces the body edge tightly; >0 leaves a moat where the popup bg bleeds through
local SELECTED_STROKE  = 2

-- Accent outline for a node body (selection / hover / error). SELECTED_INFLATE
-- widens the rect so a >0 moat lets the popup bg bleed through the stroke.
local function strokeNodeRect(p, r, name)
  p.stroke(rect(r.x0 - SELECTED_INFLATE, r.y0 - SELECTED_INFLATE,
                r.x1 + SELECTED_INFLATE, r.y1 + SELECTED_INFLATE),
           name, SELECTED_STROKE, CORNER_R)
end

-- Split a word at CamelCase boundaries. Plugin names are ASCII in practice,
-- so raw byte-class checks (no utf8) are sufficient.
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

-- Tokenise into atoms with per-pair separators: seps[k] joins atoms[k..k+1]
-- when they share a line. ' ' between words, '' between CamelCase pieces of
-- one word, so a re-joined line has no space at the case boundary.
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

--contract: caller must have pushed the target font — CalcTextSize measures against the current font.
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

  -- Overflow: keep the first LABEL_MAX_LINES-1 lines, pack the rest into
  -- the final line with a trailing ellipsis.
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

local function drawNode(p, nv, isSelected)
  local r = nodeBox(nv)
  p.fill(r, 'wiring.node.' .. nv.category, CORNER_R)
  if isSelected then
    strokeNodeRect(p, r, 'wiring.node.selected')
  end
  -- The wrapLabel / CalcTextSize measurements read the pushed font, so the
  -- block push stays; the per-line draws inherit that current font.
  if wireFont then ImGui.PushFont(ctx, wireFont, wireSize) end
  local lines = wrapLabel(nv.label, NODE_W - 2 * LABEL_PAD)
  local lineH = select(2, ImGui.CalcTextSize(ctx, 'Mg'))
  local blockH = lineH * #lines
  local yTop = r.y0 + math.floor((NODE_H - blockH) / 2)
  for i, line in ipairs(lines) do
    local tw = ImGui.CalcTextSize(ctx, line)
    p.text(r.x0 + math.floor((NODE_W - tw) / 2),
           yTop + (i - 1) * lineH, 'text', line)
  end
  if wireFont then ImGui.PopFont(ctx) end
end

-- Piano-keyboard icon (C, C#, D, D#, E): 3 outlined white keys, 2 filled
-- black keys over the C-D and D-E gaps. Hard to read off the geometry alone.
local function drawKeyboardIcon(p, x, y)
  local kw, kh   = 4, 10
  local bw, bh   = 2, 5
  local ix0, iy0 = math.floor(x), math.floor(y)
  for i = 0, 2 do
    local kx = ix0 + i * kw
    p.stroke(rect(kx, iy0, kx + kw + 1, iy0 + kh + 1), 'text', 1, 0)
  end
  for _, i in ipairs{ 1, 2 } do
    local cx  = ix0 + i * kw
    local bx0 = math.floor(cx - bw / 2)
    p.fill(rect(bx0, iy0, bx0 + bw + 1, iy0 + bh + 1), 'text')
  end
end

-- Spillover-list chevron, pointing the way the dropdown opens (down on the
-- bottom face, up on top). Sized like a chip so it shares the row centreline.
local function drawHandle(p, handle, side)
  local cx, cy = handle.x + handle.w / 2, handle.y + handle.h / 2
  local hx, hy = 4, 3
  if side == 'bottom' then
    p.tri(cx - hx, cy - hy, cx + hx, cy - hy, cx, cy + hy, 'text')
  else
    p.tri(cx - hx, cy + hy, cx + hx, cy + hy, cx, cy - hy, 'text')
  end
end

-- A port-row slot: audio square or keyboard icon, an InvisibleButton (padded
-- so the hit area beats the visual), and a tooltip. The InvisibleButton
-- advances the layout cursor; renderCanvas's trailing Dummy restores it.
local function drawSlot(p, slot, idStem)
  if slot.kind == 'audio' then
    p.fill(boxRect(slot), 'wiring.port.audio')
  else
    drawKeyboardIcon(p, slot.x, slot.y)
  end
  -- InvisibleButton + tooltip are screen-space ImGui widgets, so map the
  -- slot's canvas-local corner back through the painter to anchor them.
  local ssx, ssy = p.toScreen(slot.x, slot.y)
  local pad = PORT_HIT_PAD
  ImGui.SetCursorScreenPos(ctx, ssx - pad, ssy - pad)
  ImGui.InvisibleButton(ctx, idStem, slot.w + 2 * pad, slot.h + 2 * pad)
  -- AllowWhenBlockedByActiveItem lets target tooltips fire while the
  -- source chip's InvisibleButton is the active item (mid wire-drag).
  local hoverFlags = ImGui.HoveredFlags_ForTooltip
                   | ImGui.HoveredFlags_AllowWhenBlockedByActiveItem
  if slot.name and ImGui.IsItemHovered(ctx, hoverFlags) then
    ImGui.SetNextWindowPos(ctx,
      ssx + slot.w / 2, ssy - PORT_TOOLTIP_GAP,
      ImGui.Cond_Always, 0.5, 1.0)
    ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg, chrome.colour('wiring.tooltip.bg'))
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 4, 2)
    if ImGui.BeginTooltip(ctx) then
      ImGui.Text(ctx, slot.name)
      ImGui.EndTooltip(ctx)
    end
    ImGui.PopStyleVar(ctx, 1)
    ImGui.PopStyleColor(ctx, 1)
  end
end

local function drawBodyOutline(p, nv)
  strokeNodeRect(p, nodeBox(nv), 'wiring.node.selected')
end

----- Wire-creation gesture helpers

-- By-name dropdown anchored to the handle. Rows are tight-bound (no hit pad)
-- so neighbours don't bleed; hitRect reaches LIST_GAP back so chevron→list has no dead zone.
local function layoutList(audio, handle, side)
  if not handle or #audio < 2 then return nil end
  if uiFont then ImGui.PushFont(ctx, uiFont, uiSize) end
  local _, lineH = ImGui.CalcTextSize(ctx, 'Mg')
  local rowH = math.floor(lineH + 2 * LIST_ROW_PAD_Y)
  local maxW = handle.w
  for _, name in ipairs(audio) do
    local w = ImGui.CalcTextSize(ctx, name) + 2 * LIST_ROW_PAD_X
    if w > maxW then maxW = w end
  end
  if uiFont then ImGui.PopFont(ctx) end
  local n        = #audio
  local listX    = handle.x
  local totalH   = n * rowH + 2 * LIST_PAD_Y
  local rectY0   = (side == 'bottom') and (handle.y + handle.h + LIST_GAP)
                                       or (handle.y - LIST_GAP - totalH)
  local rectY1   = rectY0 + totalH
  local rowsY0   = rectY0 + LIST_PAD_Y
  local rows = {}
  for i, name in ipairs(audio) do
    rows[i] = { kind = 'audio', portIdx = i, name = name,
                x = listX, y = rowsY0 + (i - 1) * rowH,
                w = maxW, h = rowH }
  end
  local listRect = rect(listX, rectY0, listX + maxW, rectY1)
  local hitRect = (side == 'bottom')
                  and rect(listRect.x0, listRect.y0 - LIST_GAP, listRect.x1, listRect.y1)
                  or  rect(listRect.x0, listRect.y0,            listRect.x1, listRect.y1 + LIST_GAP)
  return { rows = rows, rect = listRect, hitRect = hitRect }
end

--contract: face = forceSide, else derived from my; keep hides the mismatched kind during target hover.
--shape: returns { slots, handle, bandRect, list, hoverRect, side, popup } (all canvas-local).
local function layoutPortRow(nv, dir, mx, my, keep, forceSide)
  local b = nodeBox(nv)
  local bx0, by0, bx1, by1 = b.x0, b.y0, b.x1, b.y1
  local audio = (dir == 'out') and nv.outs.audio or nv.ins.audio
  local midi  = (dir == 'out') and nv.outs.midi  or nv.ins.midi
  local nAudio     = #audio
  local showHandle = (nAudio >= 2) and (keep ~= 'midi')
  local showMidi   = (#midi >= 1) and (keep ~= 'audio')

  local side  = forceSide
             or ((my < (by0 + by1) / 2) and 'top' or 'bottom')
  local sign  = (side == 'bottom') and 1 or -1
  local edge  = (side == 'bottom') and by1 or by0
  local depth = edge + sign * PORT_BAND_OFFSET

  -- All slots in a given row share the row's horizontal centreline so the
  -- chevron, squares and keyboard read as aligned despite differing heights.
  local function rowCentre(rowIdx)
    return depth + sign * (rowIdx * (PORT_ROW_H + PORT_BAND_OFFSET)
                           + PORT_ROW_H / 2)
  end
  local function placeOnRow(slot, rowIdx)
    slot.y = math.floor(rowCentre(rowIdx or 0) - slot.h / 2)
  end

  -- Chip set: ports 2..N when N ≤ PORTS_PER_ROW, plus currently-wired and
  -- user-pinned ports (chip promotion). Sorted, wrapped at PORTS_PER_ROW/row.
  local chipSet = {}
  if showHandle then
    if nAudio <= PORTS_PER_ROW then
      for i = 2, nAudio do chipSet[i] = true end
    end
    local function union(set)
      if not set then return end
      for k in pairs(set) do
        if k >= 2 and k <= nAudio then chipSet[k] = true end
      end
    end
    union(wv:wiredPorts(nv.id, dir))
    union(pinned[nv.id])
  end
  local chipPorts = {}
  for k in pairs(chipSet) do chipPorts[#chipPorts + 1] = k end
  table.sort(chipPorts)

  local handle
  if showHandle then
    handle = { kind = 'handle', x = bx0 + HANDLE_INSET,
               w = HANDLE_W, h = HANDLE_H }
    placeOnRow(handle)
  end

  local slots = {}
  local nChips = #chipPorts
  if nChips > 0 then
    local nRows = math.ceil(nChips / PORTS_PER_ROW)
    -- Chips centred between the handle's right edge and the body's right
    -- edge — the right corner is free with midi living on the body.
    local chipL = handle.x + handle.w + 2
    local chipR = bx1 - MIDI_INSET
    for r = 0, nRows - 1 do
      local first = r * PORTS_PER_ROW + 1
      local last  = math.min(first + PORTS_PER_ROW - 1, nChips)
      local rowN  = last - first + 1
      local rowW  = rowN * PORT_SIZE + (rowN - 1) * PORT_GAP
      local startX = math.floor((chipL + chipR - rowW) / 2)
      for k = 0, rowN - 1 do
        local portIdx = chipPorts[first + k]
        local s = {
          kind = 'audio', portIdx = portIdx, name = audio[portIdx],
          x = startX + k * (PORT_SIZE + PORT_GAP),
          w = PORT_SIZE, h = PORT_SIZE,
        }
        placeOnRow(s, r)
        slots[#slots + 1] = s
      end
    end
  end
  if showMidi then
    slots[#slots + 1] = {
      kind = 'midi', name = midi[1], inBody = true,
      x = bx1 - MIDI_SLOT_W - MIDI_INSET,
      y = math.floor((by0 + by1 - MIDI_SLOT_H) / 2),
      w = MIDI_SLOT_W, h = MIDI_SLOT_H,
    }
  end

  -- bandRect is the slot/handle bbox (with hit pad); the band-level bg
  -- rect drawn behind everything occludes wires passing under the row.
  -- hoverRect = body ∪ bandRect so cursor traversal between zones stays live.
  local bandRect
  local function extend(s)
    if not s then return end
    local r = boxRect(s, PORT_HIT_PAD)
    if not bandRect then bandRect = r else unionRect(bandRect, r) end
  end
  for _, s in ipairs(slots) do
    if not s.inBody then extend(s) end
  end
  extend(handle)

  -- The handle's by-name dropdown is computed alongside the band so its
  -- area joins hoverRect; this lets the cursor traverse handle → list
  -- without losing engagement with the node.
  local list = layoutList(audio, handle, side)

  local hoverRect = rect(bx0, by0, bx1, by1)
  -- list.hitRect is intentionally NOT unioned here — cursor-in-list does
  -- not engage the popup. shiftHoverHit / dropTargetHit extend the hover
  -- area with list.hitRect only after the chevron has been crossed.
  if bandRect then unionRect(hoverRect, bandRect) end

  -- popup overlaps the body's near edge by 2*CORNER_R so its rounded corners
  -- hide inside the body — at just CORNER_R the two corner wedges align and
  -- canvas shows through. Drawn before the node so the body overpaints it.
  local POPUP_PAD     = 1
  local POPUP_OVERLAP = 2 * CORNER_R
  local popup
  if bandRect then
    if side == 'bottom' then
      popup = rect(bx0, by1 - POPUP_OVERLAP, bx1, bandRect.y1 + POPUP_PAD)
    else
      popup = rect(bx0, bandRect.y0 - POPUP_PAD, bx1, by0 + POPUP_OVERLAP)
    end
  end

  return { slots = slots, handle = handle, bandRect = bandRect, list = list,
           hoverRect = hoverRect, side = side, popup = popup }
end

local function slotHit(slots, mx, my)
  for _, s in ipairs(slots) do
    if inRect(mx, my, boxRect(s, PORT_HIT_PAD)) then
      return s
    end
  end
end

-- Tight hit-test for list rows (no pad — rows are full-height boxes
-- packed back-to-back, so padding would overlap into the neighbour).
local function rowHit(rows, mx, my)
  for _, r in ipairs(rows) do
    if inRect(mx, my, boxRect(r)) then
      return r
    end
  end
end

-- Default slot for body-only hover: audio port 1, else the keyboard. `keep`
-- biases it for target hover — a midi draft defaults to the keyboard.
local function defaultSlot(nv, dir, keep)
  local audio = (dir == 'out') and nv.outs.audio or nv.ins.audio
  local midi  = (dir == 'out') and nv.outs.midi  or nv.ins.midi
  if keep ~= 'midi' and #audio > 0 then
    return { kind = 'audio', portIdx = 1, name = audio[1] }
  end
  if keep ~= 'audio' and #midi > 0 then
    return { kind = 'midi', name = midi[1] }
  end
end

-- Cursor over the chevron's visible bounds (no pad — popup gating is tight).
local function onChevron(handle, mx, my)
  return handle and inRect(mx, my, boxRect(handle))
end

-- Hover lookup over body + band only (list engagement is chevron-gated in
-- engagedHover). A non-nil .list on the pick means "chevron hit, open the list".
local function pickHovered(nv, layout, mx, my, dir, keep)
  if not inRect(mx, my, layout.hoverRect) then return nil end
  local hit = slotHit(layout.slots, mx, my)
  if hit then
    return { nv = nv, layout = layout, slot = hit }
  end
  if onChevron(layout.handle, mx, my) then
    return { nv = nv, layout = layout, slot = nil, list = layout.list }
  end
  local def = defaultSlot(nv, dir, keep)
  if def then
    return { nv = nv, layout = layout, slot = def }
  end
end

local function stillEngaged(layout, mx, my)
  local list = layout.list
  if not list then return false end
  if onChevron(layout.handle, mx, my) then return true end
  return inRect(mx, my, list.hitRect)
end

-- Engaged-priority hover scan shared by source-side (shift) and target-side
-- (draft) drafting: the engaged node is probed before the forward scan so a
-- neighbour's overlapping hoverRect can't steal an open popout mid-gesture.
local function engagedHover(nodeViews, mx, my, cfg)
  local dir, keep = cfg.dir, cfg.keep
  local function consume(pick)
    if pick.list then listOpenId = pick.nv.id end
    engagedId = pick.nv.id
    if cfg.onConsume then cfg.onConsume(pick) end
    return pick
  end
  local function refine(pick, nv)
    if cfg.refine then pick = cfg.refine(pick, nv) end
    -- A body-default synthetic slot (no .x) caught in the popout's empty
    -- space is cleared so the body outline doesn't read as a target;
    -- engagement holds, so the popout stays open.
    if pick and pick.slot and not pick.slot.x then
      if not inRect(mx, my, nodeBox(nv)) then
        pick.slot = nil
      end
    end
    return pick
  end
  -- No eligibility re-check on the engaged node: consume only sets engagedId
  -- on an eligible node and neither predicate flips mid-gesture (out-port
  -- counts static, draft.forbidden fixed at creation), so it stays eligible.
  if engagedId then
    for _, nv in ipairs(nodeViews) do
      if nv.id == engagedId then
        local layout = layoutPortRow(nv, dir, mx, my, keep)
        if listOpenId == nv.id and stillEngaged(layout, mx, my) then
          return consume{ nv = nv, layout = layout, list = layout.list,
                          slot = rowHit(layout.list.rows, mx, my) }
        end
        local pick = pickHovered(nv, layout, mx, my, dir, keep)
        if pick then return consume(refine(pick, nv)) end
        break
      end
    end
    engagedId, listOpenId = nil, nil
  end
  for _, nv in ipairs(nodeViews) do
    if cfg.eligible(nv) then
      local layout = layoutPortRow(nv, dir, mx, my, keep)
      local pick = pickHovered(nv, layout, mx, my, dir, keep)
      if pick then return consume(refine(pick, nv)) end
    end
  end
end

-- Source-side hover (shift, no draft). onConsume drops sticky when hover
-- returns to the pinned node so the overlays don't double up; narrowOnMidi
-- re-lays-out midi-only so the in-body keyboard stands alone.
local function shiftHoverHit(nodeViews, mx, my)
  local function narrowOnMidi(pick, nv)
    if pick and pick.slot and pick.slot.kind == 'midi' then
      pick.layout = layoutPortRow(nv, 'out', mx, my, 'midi')
    end
    return pick
  end
  return engagedHover(nodeViews, mx, my, {
    dir = 'out', keep = nil,
    eligible = function(nv) return #nv.outs.audio > 0 or #nv.outs.midi > 0 end,
    refine = narrowOnMidi,
    onConsume = function(pick)
      if sticky and sticky.nodeId == pick.nv.id then sticky = nil end
    end,
  })
end

-- Port-row overlay for the sticky (pinned) node. Cursor-independent: uses the
-- side stored at pin-time so it doesn't flip top/bottom as the cursor moves.
local function stickyHoverHit(nodeViews)
  if not sticky then return nil end
  for _, nv in ipairs(nodeViews) do
    if nv.id == sticky.nodeId
       and (#nv.outs.audio > 0 or #nv.outs.midi > 0) then
      local layout = layoutPortRow(nv, 'out', 0, 0, nil, sticky.side)
      return { nv = nv, layout = layout, slot = defaultSlot(nv, 'out', nil) }
    end
  end
  sticky = nil  -- node no longer exists in the graph
end

local function findLayoutSlot(layout, slotKind, portIdx)
  for _, s in ipairs(layout.slots) do
    if s.kind == slotKind
       and (slotKind ~= 'audio' or s.portIdx == portIdx) then
      return s
    end
  end
end
-- Forward-draft only: keeps the source node's port row visible during the
-- click-hold (else the popout flashes off when wireDraft is set, back at
-- mouseup). Redrafts skip it; in the band gap the kept-slot highlight clears.
local function draftSourceHoverHit(nodeViews, mx, my)
  if not wireDraft or wireDraft.edgeIdx then return nil end
  for _, nv in ipairs(nodeViews) do
    if nv.id == wireDraft.keptId then
      local layout = layoutPortRow(nv, 'out', mx, my,
                                   wireDraft.type, wireDraft.keptSide)
      local inBand = inRect(mx, my, layout.hoverRect)
                 and not inRect(mx, my, nodeBox(nv))
                 and not slotHit(layout.slots, mx, my)
                 and not onChevron(layout.handle, mx, my)
      if inBand then
        return { nv = nv, layout = layout, slot = nil }
      end
      -- Body-default port 1 has no chip, so synthesise a default-slot spec
      -- so the source still reads as engaged (body outline carries the mark).
      local slot = findLayoutSlot(layout, wireDraft.type, wireDraft.keptPort)
      if not slot then
        slot = { kind = wireDraft.type, portIdx = wireDraft.keptPort }
      end
      return { nv = nv, layout = layout, slot = slot }
    end
  end
end

-- Target-side hover (draft in flight). dir follows cursorEnd ('to' seeks
-- in-ports on destinations, 'from' out-ports on sources); forbidden
-- (cycle-blocked) nodes are ineligible, so they neither engage nor display.
local function dropTargetHit(nodeViews, mx, my, draft)
  return engagedHover(nodeViews, mx, my, {
    dir = (draft.cursorEnd == 'to') and 'in' or 'out',
    keep = draft.type,
    eligible = function(nv) return not draft.forbidden[nv.id] end,
  })
end

-- Commit-eligibility (mouseup only); also requires a concrete slot. The visual
-- overlay is gated separately on forbidden-only, so the list still opens mid-hover.
local function dropEligible(draft, target)
  return target ~= nil
     and target.slot ~= nil
     and not draft.forbidden[target.nv.id]
end

local function drawList(p, list, highlight)
  local r = list.rect
  p.fill(r, 'wiring.tooltip.bg', LIST_CORNER_R)
  p.stroke(r, 'separator', 1, LIST_CORNER_R)
  for _, row in ipairs(list.rows) do
    if row == highlight then
      p.fill(rect(row.x + 1, row.y, row.x + row.w - 1, row.y + row.h),
             'wiring.node.selected')
    end
    p.text(row.x + LIST_ROW_PAD_X, row.y + LIST_ROW_PAD_Y,
           'text', row.name, uiFont, uiSize)
  end
end

-- Pale rounded bg for the port-row overlay, overlapping the body's near edge
-- so the body's near corners read as filled, not canvas. Drawn BEFORE the
-- node so the body overpaints the overlap.
local function drawPortRowBg(p, layout)
  local popup = layout.popup
  if not popup then return end
  p.fill(popup, 'wiring.tooltip.bg', CORNER_R)
end

-- Draws the handle and every slot, outlining the one matching pick.slot. Chips
-- stay visible with the list open (it extends perpendicular) so the port→row map holds.
local function drawPortRow(p, pick, idPrefix)
  local layout, highlight = pick.layout, pick.slot
  if layout.handle then drawHandle(p, layout.handle, layout.side) end
  local bodyName = 'wiring.node.' .. pick.nv.category
  for i, s in ipairs(layout.slots) do
    if s.inBody then
      -- Body-internal kbd: fill body colour to overpaint the label, then the
      -- icon. No InvisibleButton (the body owns the drag area) or tooltip.
      p.fill(boxRect(s), bodyName)
      drawKeyboardIcon(p, s.x, s.y)
    else
      drawSlot(p, s, idPrefix .. '/' .. i)
    end
    -- Match by (kind, portIdx), not identity: defaultSlot returns a synthetic
    -- spec, so identity would miss the midi kbd on a body-hover midi draft.
    if highlight and s.kind == highlight.kind
       and (s.kind ~= 'audio' or s.portIdx == highlight.portIdx) then
      p.stroke(rect(s.x - SELECTED_INFLATE, s.y - SELECTED_INFLATE,
                    s.x + s.w + SELECTED_INFLATE, s.y + s.h + SELECTED_INFLATE),
               'wiring.node.selected', SELECTED_STROKE, 0)
    end
  end
end

----- Wire drawing

-- Group wires by unordered pair. canonA/canonB fix the sorted pair direction
-- so every wire in the group shares one perpendicular axis regardless of its
-- own direction. (Within-group sort order is set below.)
local function wireGroups(wireViews)
  local groups, order = {}, {}
  for _, w in ipairs(wireViews) do
    local a, b = w.from, w.to
    if a > b then a, b = b, a end
    local key = util.key(a, b)
    local g = groups[key]
    if not g then
      g = { canonA = a, canonB = b, wires = {} }
      groups[key] = g
      order[#order + 1] = key
    end
    g.wires[#g.wires + 1] = w
  end
  -- Sort audio wires by labelling cost so the cheap ones take the low slots
  -- near the node (1-1 < 1-n/n-1 < n-m); MIDI sorts after audio.
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

-- Distances along the (offset) segment where the visible part begins (exits
-- the source rect) and ends (enters the target), plus length. Parallel-wire
-- offsets make the two exits asymmetric. nil for sub-pixel segments.
local function wireExits(seg)
  local dx, dy = seg.ex - seg.sx, seg.ey - seg.sy
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1 then return nil end
  local hw, hh = NODE_W / 2, NODE_H / 2
  local offX, offY = seg.offX or 0, seg.offY or 0
  -- Param along the ray (rdx,rdy) from a point (px,py) inside an axis-
  -- aligned rect centred at the origin at which the ray exits.
  local function exitParam(rdx, rdy, px, py)
    local txWall = (rdx > 0) and hw or -hw
    local tyWall = (rdy > 0) and hh or -hh
    local tx = (rdx ~= 0) and (txWall - px) / rdx or math.huge
    local ty = (rdy ~= 0) and (tyWall - py) / rdy or math.huge
    return math.min(tx, ty)
  end
  -- Source rect centred at (sx - offX, sy - offY): at t=0 the segment
  -- point relative to the centre is (offX, offY). Target rect mirror:
  -- walk backward from t=1 in direction (-dx,-dy) with the same offset.
  local tFrom = exitParam(dx, dy, offX, offY)
  local tTo   = 1 - exitParam(-dx, -dy, offX, offY)
  return tFrom * len, tTo * len, len
end

local function drawWireArrow(p, sx, sy, ex, ey, name)
  local dx, dy = ex - sx, ey - sy
  local len = math.sqrt(dx * dx + dy * dy)
  if len < WIRE_ARROW_LEN then return end
  local ux, uy = dx / len, dy / len
  local px, py = -uy, ux
  -- Anchor the centroid (not the tip) on the wire midpoint, else the arrow
  -- looks biased forward by L/6. The +0.5 offset lands vertices on pixel
  -- centres, fixing the top-left fill rule dropping the bottom-right diagonal.
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
  p.tri(tipx, tipy, b1x, b1y, b2x, b2y, name)
end

-- Port-number label: a bg patch (occludes the wire behind the digit), pushed
-- clear of labels already `placed` this frame and capped at len*0.45 so it
-- can't collide with the other end's. Replaces the old per-group alternation.
local function drawWireEndLabel(p, ax, ay, fx, fy, exitD, portIdx, portName, idStem, name, placed)
  local dx, dy = fx - ax, fy - ay
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1 then return end
  local txt = tostring(portIdx)
  local tw, th = p.measure(txt, wireFont, WIRE_LABEL_SIZE)
  local hw = math.ceil(tw / 2) + WIRE_LABEL_PAD
  local hh = math.ceil(th / 2) + WIRE_LABEL_PAD
  -- Half-extent of the axis-aligned rect projected onto the wire axis:
  -- letting the gap be measured from the projected near edge keeps the
  -- visible LEAD constant whether the wire is horizontal or vertical.
  local proj = (hw * math.abs(dx) + hh * math.abs(dy)) / len
  local ux, uy = dx / len, dy / len
  local maxDist = len * 0.45
  local labelDist = math.min(maxDist, exitD + WIRE_LABEL_LEAD + proj)
  -- Smallest positive push along (ux,uy) that separates a candidate at
  -- (cx,cy) from existing rect e on one axis. math.huge if axis-aligned
  -- separation in that direction is impossible (wire parallel to axis).
  local function axisPush(c, ec, sumH, u)
    if u == 0 then return math.huge end
    local fwd, bwd = (ec + sumH - c) / u, (ec - sumH - c) / u
    local best = math.huge
    if fwd > 0 then best = math.min(best, fwd) end
    if bwd > 0 then best = math.min(best, bwd) end
    return best
  end
  for _ = 1, 64 do
    local cx, cy = ax + labelDist * ux, ay + labelDist * uy
    local hit
    for _, e in ipairs(placed) do
      if math.abs(cx - e.cx) < hw + e.hw
         and math.abs(cy - e.cy) < hh + e.hh then
        hit = e; break
      end
    end
    if not hit then break end
    local push = math.min(axisPush(cx, hit.cx, hw + hit.hw, ux),
                          axisPush(cy, hit.cy, hh + hit.hh, uy))
    if push == math.huge then break end
    labelDist = labelDist + push + 0.5
    if labelDist >= maxDist then labelDist = maxDist; break end
  end
  local cx, cy = ax + labelDist * ux, ay + labelDist * uy
  local x0, y0, x1, y1 = cx - hw, cy - hh, cx + hw, cy + hh
  placed[#placed + 1] = { cx = cx, cy = cy, hw = hw, hh = hh }
  p.fill(rect(x0, y0, x1, y1), 'bg')
  p.text(math.floor(cx - tw / 2), math.floor(cy - th / 2),
         name, txt, wireFont, WIRE_LABEL_SIZE)
  -- InvisibleButton + tooltip are screen-space widgets; map the label's
  -- canvas-local box back through the painter to anchor them.
  local btnX, btnY = p.toScreen(x0, y0)
  local tipX       = p.toScreen(cx, cy)
  ImGui.SetCursorScreenPos(ctx, btnX, btnY)
  ImGui.InvisibleButton(ctx, idStem, 2 * hw, 2 * hh)
  if portName and ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_ForTooltip) then
    ImGui.SetNextWindowPos(ctx, tipX, btnY - PORT_TOOLTIP_GAP,
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

-- One canvas-local segment per wireView, keyed by index. offX/offY is the
-- perpendicular displacement from the pair centre line, shared with wireExits
-- so highlight + label geometry can't drift from the drawn line.
local function wireSegments(wireViews, nodesById)
  local segs = {}
  local idxOf = {}
  for i, w in ipairs(wireViews) do idxOf[w] = i end
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
        for slotI, w in ipairs(g.wires) do
          local fromNV, toNV = nodesById[w.from], nodesById[w.to]
          if fromNV and toNV then
            local s = wireOffset(slotI, n)

            local offX, offY = perpX * s, perpY * s
            segs[idxOf[w]] = {
              w    = w,
              sx   = fromNV.pos.x + offX, sy = fromNV.pos.y + offY,
              ex   = toNV.pos.x   + offX, ey = toNV.pos.y   + offY,
              offX = offX, offY = offY,
            }
          end
        end
      end
    end
  end
  return segs
end

-- End-region endpoints for one side of a wire (canvas-local): from the node-
-- rect exit, WIRE_END_HIT px inward. Capped at 0.4*visible so a short wire's
-- two ends don't overlap. nil for sub-pixel / fully-occluded wires.
local function endRegion(seg, side)
  local fromD, toD, len = wireExits(seg)
  if not fromD then return nil end
  local visible = toD - fromD
  if visible < 2 then return nil end
  local L = math.min(WIRE_END_HIT, 0.4 * visible)
  local ux, uy = (seg.ex - seg.sx) / len, (seg.ey - seg.sy) / len
  if side == 'from' then
    local x0, y0 = seg.sx + ux * fromD, seg.sy + uy * fromD
    return x0, y0, x0 + ux * L, y0 + uy * L
  end
  local x0, y0 = seg.sx + ux * toD, seg.sy + uy * toD
  return x0, y0, x0 - ux * L, y0 - uy * L
end

local function pointToSegmentDist(px, py, ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  local len2 = dx * dx + dy * dy
  if len2 < 1e-6 then
    local ex, ey = px - ax, py - ay
    return math.sqrt(ex * ex + ey * ey)
  end
  local t = ((px - ax) * dx + (py - ay) * dy) / len2
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  local cx, cy = ax + t * dx, ay + t * dy
  local ex, ey = px - cx, py - cy
  return math.sqrt(ex * ex + ey * ey)
end

-- Nearest end-region within WIRE_END_HIT_PERP of the cursor, or nil. Returns
-- { edgeIdx, side, keptAnchor }: keptAnchor is the OTHER end's node-edge point
-- (screen), where the redraft pins the wire while the cursor drives this end.
local function wireEndHit(segs, mx, my)
  local best, bestDist
  for i, seg in pairs(segs) do
    for _, side in ipairs({ 'from', 'to' }) do
      local ax, ay, bx, by = endRegion(seg, side)
      if ax then
        local d = pointToSegmentDist(mx, my, ax, ay, bx, by)
        if d <= WIRE_END_HIT_PERP and (not bestDist or d < bestDist) then
          best = {
            edgeIdx    = i,
            side       = side,
            keptAnchor = (side == 'from')
              and { x = seg.ex, y = seg.ey }
              or  { x = seg.sx, y = seg.sy },
          }
          bestDist = d
        end
      end
    end
  end
  return best
end

-- opts.skipEdgeIdx skips the wire being redrafted (the draft line replaces it).
-- The highlight draws separately after the node pass — nodes overpaint wires
-- here, so an in-pass highlight would be invisible.
local function drawWiresPass(p, segs, wireViews, opts)
  opts = opts or {}
  local skip = opts.skipEdgeIdx
  local placedLabels = {}
  for i = 1, #wireViews do
    local seg = segs[i]
    if seg and i ~= skip then
      local w  = seg.w
      local sx, sy = seg.sx, seg.sy
      local ex, ey = seg.ex, seg.ey
      local name = w.type == 'midi' and 'wiring.port.midi' or 'wiring.port.audio'
      p.line(sx, sy, ex, ey, name, WIRE_THICK)
      drawWireArrow(p, sx, sy, ex, ey, name)
      if w.type == 'audio' then
        local fromD, toD, segLen = wireExits(seg)
        if fromD then
          local stem = '##wire/' .. w.from .. ':' .. w.fromPort
                            .. '->' .. w.to   .. ':' .. w.toPort
          if w.fromPort ~= 1 then
            drawWireEndLabel(p, sx, sy, ex, ey, fromD,
              w.fromPort, w.fromPortName, stem .. '/from', name,
              placedLabels)
          end
          if w.toPort ~= 1 then
            drawWireEndLabel(p, ex, ey, sx, sy, segLen - toD,
              w.toPort, w.toPortName, stem .. '/to', name,
              placedLabels)
          end
        end
      end
    end
  end
end

local function drawWireEndHighlight(p, segs, hover)
  if not hover then return end
  local seg = segs[hover.edgeIdx]
  if not seg then return end
  local ax, ay, bx, by = endRegion(seg, hover.side)
  if not ax then return end
  p.line(ax, ay, bx, by, 'wiring.node.selected', WIRE_END_HIGHLIGHT)
end

-- Cursor-end position with the grab-offset decayed over WIRE_GRAB_DECAY px,
-- ratcheting on furthest travel. See docs/wiringPage.md (the wire end leads
-- the cursor) for why this point, not the cursor, drives hit-testing.
local function computeDraftEnd(draft, mx, my)
  if not draft.grabDx then return mx, my end
  local tdx, tdy = mx - draft.mx0, my - draft.my0
  local travel = math.sqrt(tdx * tdx + tdy * tdy)
  draft.maxTravel = math.max(draft.maxTravel or 0, travel)
  local decay = math.max(0, 1 - draft.maxTravel / WIRE_GRAB_DECAY)
  return mx + draft.grabDx * decay, my + draft.grabDy * decay
end

----- Mid-wire fader (audio wires only)

-- Industry-shaped fader law: finest resolution near unity, coarser low,
-- hard floor below p=0.05. (p: 0=bottom, 1=top.)
local function dbFromP(p)
  if p <= 0.05 then return -math.huge end
  if p <  0.25 then return 100 * (p - 0.25) - 40   end
  if p <  0.50 then return 112 * (p - 0.50) - 12   end
  if p <  0.75 then return  48 * (p - 0.75)        end
  return (WIRE_FADER_TOP_DB / 0.25) * (p - 0.75)
end

local function pFromDb(db)
  if db == -math.huge or db <= -60 then return 0 end
  if db <  -40 then return 0.25 + (db + 40) / 100 end
  if db <  -12 then return 0.50 + (db + 12) / 112 end
  if db <    0 then return 0.75 + db / 48          end
  return 0.75 + db * 0.25 / WIRE_FADER_TOP_DB
end

local function linToDb(lin) if lin <= 0 then return -math.huge end; return 20 * math.log(lin, 10) end
local function dbToLin(db)  if db == -math.huge then return 0 end;  return 10 ^ (db / 20) end

local function arrowMidHit(segs, mx, my)
  for i, seg in pairs(segs) do
    if seg.w.type == 'audio' then
      local cx = (seg.sx + seg.ex) / 2 + 0.5
      local cy = (seg.sy + seg.ey) / 2 + 0.5
      local dx, dy = mx - cx, my - cy
      if dx*dx + dy*dy <= WIRE_FADER_HIT * WIRE_FADER_HIT then
        return i, cx, cy
      end
    end
  end
end

local function faderRectAt(ax, ay)
  local hw, hh = WIRE_FADER_W / 2, WIRE_FADER_H / 2
  return ax - hw, ay - hh, ax + hw, ay + hh
end

local function pixelYToLin(my, stripY0)
  local p = 1 - (my - stripY0) / WIRE_FADER_H
  if p < 0 then p = 0 elseif p > 1 then p = 1 end
  return dbToLin(dbFromP(p))
end

local function drawFader(p, f)
  local r = f.rect
  p.fill(r, 'bg')
  p.stroke(r, 'wiring.port.audio', 1, 1)
  -- Unity tick: faint horizontal line where 0 dB sits on the strip.
  local unityY = r.y0 + (1 - pFromDb(0)) * WIRE_FADER_H
  p.line(r.x0, unityY, r.x1, unityY, 'wiring.port.audio', 1)
  local pos    = pFromDb(linToDb(f.currentLin))
  local indY   = r.y0 + (1 - pos) * WIRE_FADER_H
  local kHalfH = WIRE_FADER_KNOB_H / 2
  p.fill(rect(r.x0+1, indY - kHalfH, r.x1-1, indY + kHalfH), 'wiring.node.selected', 1)
  p.stroke(rect(r.x0+1, indY - kHalfH, r.x1-1, indY + kHalfH), 'bg', 1, 1)
  local db  = linToDb(f.currentLin)
  local txt = (db == -math.huge) and '-inf dB' or string.format('%+.1f dB', db)
  p.text(r.x1 + 4, indY - uiSize / 2, 'text', txt, uiFont, uiSize)
end

-- In-flight draft wire (draw order in docs/wiringPage.md). Kept end anchors at
-- keptAnchor, or the node centre when a body-default forward draft has none.
local function drawDraftWire(p, draft, nodesById, cx, cy)
  if not draft then return end
  local src = nodesById[draft.keptId]
  if not src then return end
  local name = draft.type == 'midi' and 'wiring.port.midi' or 'wiring.port.audio'
  local a   = draft.keptAnchor
  local ax  = a and a.x or src.pos.x
  local ay  = a and a.y or src.pos.y
  local sx, sy, ex, ey
  if draft.cursorEnd == 'to' then
    sx, sy, ex, ey = ax, ay, cx, cy
  else
    sx, sy, ex, ey = cx, cy, ax, ay
  end
  p.line(sx, sy, ex, ey, name, WIRE_THICK)
  drawWireArrow(p, sx, sy, ex, ey, name)
end

local function drawTagAt(p, cx, cy, label)
  local tw, th = p.measure(label, wireFont, WIRE_LABEL_SIZE)
  p.text(math.floor(cx - tw / 2), math.floor(cy - th / 2), 'wiring.source.label',
         label, wireFont, WIRE_LABEL_SIZE)
end

-- Track name at a source stub's far end: neutral, tiny wire-label font, set a
-- fixed gap from where the stub wire crosses the (visible) text box.
local function drawSourceTag(p, ax, ay, ux, uy, label)
  local tw, th = p.measure(label, wireFont, WIRE_LABEL_SIZE)
  local hw, hh = tw / 2, th * TAG_VIS_H / 2
  -- Centre-to-edge distance along the wire where it crosses the box (ray/box
  -- intersection, not the axis projection), so the gap holds at every angle.
  local tx     = (ux ~= 0) and hw / math.abs(ux) or math.huge
  local ty     = (uy ~= 0) and hh / math.abs(uy) or math.huge
  local cross  = math.min(tx, ty)
  local cx, cy = ax + ux * (TAG_GAP + cross), ay + uy * (TAG_GAP + cross)
  drawTagAt(p, cx, cy, label)
end

-- Source-origin edges render as labelled stubs, not wires: a short lead off the
-- consumer rect away from master, tag at the far end. Fan-out offsets via wireOffset.
local function drawSourceStubs(p, wireViews, nodesById)
  local byConsumer, order = {}, {}
  for _, w in ipairs(wireViews) do
    if w.fromKind == 'source' then
      local stubs = byConsumer[w.to]
      if not stubs then stubs = {}; byConsumer[w.to] = stubs; util.add(order, w.to) end
      util.add(stubs, w)
    end
  end
  local mxp, myp = wv:masterPos()
  local hw, hh   = NODE_W / 2, NODE_H / 2
  for _, consumerId in ipairs(order) do
    local consumer = nodesById[consumerId]
    if consumer then
      local stubs  = byConsumer[consumerId]
      local dx, dy = consumer.pos.x - mxp, consumer.pos.y - myp
      local len    = math.sqrt(dx * dx + dy * dy)
      local ux, uy = 1, 0
      if len >= 1 then ux, uy = dx / len, dy / len end
      local perpX, perpY = -uy, ux
      local exitDist = math.min((ux ~= 0) and hw / math.abs(ux) or math.huge,
                                (uy ~= 0) and hh / math.abs(uy) or math.huge)
      for i, w in ipairs(stubs) do
        local s = wireOffset(i, #stubs)
        local nearX = consumer.pos.x + perpX * s + ux * exitDist
        local nearY = consumer.pos.y + perpY * s + uy * exitDist
        local farX, farY = nearX + ux * STUB_LEN, nearY + uy * STUB_LEN
        local name = w.type == 'midi' and 'wiring.port.midi' or 'wiring.port.audio'
        p.line(farX, farY, nearX, nearY, name, WIRE_THICK)
        drawWireArrow(p, farX, farY, nearX, nearY, name)
        drawSourceTag(p, farX, farY, ux, uy, w.fromLabel or 'source')
      end
    end
  end
end

-- Node under the mouse by un-inflated body rect (not the inflated port-reveal
-- rect) — used to start a drag. nil over empty canvas or a port band.
local function nodeUnderMouse(nodeViews, mx, my)
  for _, nv in ipairs(nodeViews) do
    if inRect(mx, my, nodeBox(nv)) then
      return nv
    end
  end
end

-- nodeUnderMouse keyed to an arbitrary screen point (the decayed draft
-- wire end, typically) rather than the live cursor.
local function nodeAtPoint(nodeViews, px, py)
  for _, nv in ipairs(nodeViews) do
    if inRect(px, py, nodeBox(nv)) then
      return nv
    end
  end
end

-- Node ids whose body rect (un-inflated — port bands aren't selectable)
-- intersects the band. Empty set if nothing caught.
local function nodesInBand(nodeViews, bx0, by0, bx1, by1)
  if bx0 > bx1 then bx0, bx1 = bx1, bx0 end
  if by0 > by1 then by0, by1 = by1, by0 end
  local set = {}
  for _, nv in ipairs(nodeViews) do
    local r = nodeBox(nv)
    if r.x1 >= bx0 and r.x0 <= bx1 and r.y1 >= by0 and r.y0 <= by1 then
      set[nv.id] = true
    end
  end
  return set
end

local function renderCanvas(w, h)
  -- Canvas origin = viewport centre (logical 0,0 in the middle). The painter
  -- carries it, so draw helpers use canvas-local coords and the same transform
  -- maps the mouse back for hit-testing.
  local sx, sy = ImGui.GetCursorScreenPos(ctx)
  local ox, oy = sx + math.floor(w / 2), sy + math.floor(h / 2)
  canvasOrigin.ox, canvasOrigin.oy = ox, oy
  local p = painter.new(ctx, chrome, { ox = ox, oy = oy })
  local vx0, vy0 = p.fromScreen(sx, sy)
  local vx1, vy1 = p.fromScreen(sx + w, sy + h)
  p.fill(rect(vx0, vy0, vx1, vy1), 'bg')

  local mx, my   = ImGui.GetMousePos(ctx)
  local lmx, lmy = p.fromScreen(mx, my)
  -- Body split added a palette child; gate every press-start on canvas hover
  -- so a palette click can't begin a canvas band/drag/menu. Mouseup stays open.
  local overCanvas = ImGui.IsWindowHovered(ctx)
  local shiftHeld = ImGui.GetKeyMods(ctx) & ImGui.Mod_Shift ~= 0
  -- Shift clears the selection (rising edge only) so the wire-creation hover
  -- owns the visual layer; releasing shift drops sticky (a pinned overlay
  -- lives for one shift press).
  if shiftHeld and not shiftWas then wv:setSelection{} end
  if shiftWas and not shiftHeld then sticky = nil end
  shiftWas = shiftHeld
  if hoverFreeze and (hoverFreeze.x ~= mx or hoverFreeze.y ~= my) then
    hoverFreeze = nil
  end
  -- A deliberate click cancels the post-commit freeze, so a shift-click can
  -- start the next wire from the just-dropped node without first jiggling.
  if hoverFreeze and ImGui.IsMouseClicked(ctx, 0) then hoverFreeze = nil end

  -- Sources render as labelled stubs (drawSourceStubs), never as bodies — drop
  -- them from every body pass: draw, drag, band, hit-test, errors.
  local nodeViews = {}
  for _, nv in ipairs(wv:nodeViews()) do
    if nv.category ~= 'source' then util.add(nodeViews, nv) end
  end

  -- While a band is live, preview the selection: nodes its rect intersects
  -- render selected already, matching what mouseup commits.
  local selection
  if band then
    selection = nodesInBand(nodeViews, band.mx0, band.my0, lmx, lmy)
  else
    selection = wv:selection()
  end

  -- While a drag is live, override each dragged node's pos so all geometry
  -- below sees the in-flight positions.
  if drag then
    local dx, dy = lmx - drag.mx0, lmy - drag.my0
    for _, nv in ipairs(nodeViews) do
      local s = drag.starts[nv.id]
      if s then nv.pos.x, nv.pos.y = s.x + dx, s.y + dy end
    end
  end

  local nodesById = {}
  for _, nv in ipairs(nodeViews) do nodesById[nv.id] = nv end

  -- segs is built once, shared by the draw pass and every hit-test so
  -- geometry can't drift. Draw order is in docs/wiringPage.md.
  local wireViewsList = wv:wireViews()
  local segs = wireSegments(wireViewsList, nodesById)

  -- Wire-end hover: unmodified mouse near a wire's end-region. Suppressed
  -- during any active gesture so the highlight never fires under a drag.
  local wireEndHover
  if not drag and not band and not wireDraft and not shiftHeld then
    wireEndHover = wireEndHit(segs, lmx, lmy)
  end

  -- Tick a live fader drag: poke per frame, commit one setEdgeGain on
  -- release if the value moved from where the click set it.
  if fader and fader.dragging then
    local lin = pixelYToLin(lmy, fader.rect.y0)
    fader.currentLin = lin
    wv:pokeEdgeGain(fader.edgeIdx, lin)
    if not ImGui.IsMouseDown(ctx, 0) then
      if fader.currentLin ~= fader.valueAtClick then
        wv:setEdgeGain(fader.edgeIdx, fader.currentLin)
      end
      fader.dragging = false
    end
  end
  local arrowHitIdx
  if not drag and not band and not wireDraft and not shiftHeld
     and not (fader and fader.dragging) then
    arrowHitIdx = arrowMidHit(segs, lmx, lmy)
  end
  -- Fader visibility: drag overrides, triangle anchors, hitRect persists.
  -- Opening is click-driven (below): this block only keeps / closes.
  local stillVisible = false
  if fader then
    if fader.dragging then
      stillVisible = true
    elseif arrowHitIdx == fader.edgeIdx then
      stillVisible = true
    elseif inRect(lmx, lmy, fader.hitRect) then
      stillVisible = true
    end
  end
  if stillVisible then
    if not fader.dragging and not fader.wheelPending then
      fader.currentLin = wv:edgeGain(fader.edgeIdx)
    end
  else
    if fader and fader.wheelPending then
      wv:setEdgeGain(fader.edgeIdx, fader.currentLin)
    end
    fader = nil
  end
  if fader and wireEndHover and wireEndHover.edgeIdx == fader.edgeIdx then
    wireEndHover = nil
  end

  -- The decayed wire end (not the cursor) drives the draft visual and the
  -- hit / eligibility checks below — see docs/wiringPage.md.
  local draftCx, draftCy
  if wireDraft then
    draftCx, draftCy = computeDraftEnd(wireDraft, lmx, lmy)
  end

  -- Source-side hover while shift held; target-side while a draft is live.
  -- dropTargetHit filters cycle-blocked nodes; commit also needs a concrete slot.
  local sourceHit, targetHit, stickyHit, draftSourceHit
  if wireDraft then
    targetHit      = dropTargetHit(nodeViews, draftCx, draftCy, wireDraft)
    draftSourceHit = draftSourceHoverHit(nodeViews, draftCx, draftCy)
  elseif shiftHeld and not hoverFreeze then
    sourceHit = shiftHoverHit(nodeViews, lmx, lmy)
  end
  if shiftHeld then
    stickyHit = stickyHoverHit(nodeViews)
  end

  -- One overlay per node id; cursor-driven picks (source/target) beat the
  -- persistent draft-source and sticky ones.
  local overlays  = {}
  local frontIds  = {}
  local function add(pick)
    if not pick or frontIds[pick.nv.id] then return end
    overlays[#overlays + 1] = pick
    frontIds[pick.nv.id] = true
  end
  add(sourceHit)
  add(targetHit)
  add(draftSourceHit)
  add(stickyHit)

  -- z-stack (docs/wiringPage.md): wires < sleeves < draft < nodes.
  drawWiresPass(p, segs, wireViewsList,
    { skipEdgeIdx = wireDraft and wireDraft.edgeIdx })
  drawSourceStubs(p, wireViewsList, nodesById)
  for _, pick in ipairs(overlays) do drawPortRowBg(p, pick.layout) end
  drawDraftWire(p, wireDraft, nodesById, draftCx, draftCy)
  for _, nv in ipairs(nodeViews) do
    drawNode(p, nv, selection[nv.id])
  end

  -- A palette drag carries a floating source tag at the cursor (on top of
  -- nodes) — it commits to a stub on drop. The wire-type is undecided here.
  if wireDraft and wireDraft.fromPalette then
    drawTagAt(p, draftCx, draftCy, wireDraft.keptLabel)
  end

  -- After the node pass: nodes overpaint wires, so an in-pass highlight (and
  -- its AA spill onto the body corner) would be clipped.
  drawWireEndHighlight(p, segs, wireEndHover)

  if fader then drawFader(p, fader) end

  -- Error outline stroked after selection so error-and-selected reads red.
  local errs = wv:errors()
  if #errs > 0 then
    local errorIds = {}
    for _, err in ipairs(errs) do
      for id in pairs(err.nodeIds) do errorIds[id] = true end
    end
    for _, nv in ipairs(nodeViews) do
      if errorIds[nv.id] then
        strokeNodeRect(p, nodeBox(nv), 'wiring.node.error')
      end
    end
  end

  -- Overlay pass per engaged node. idPrefix is nv.id-keyed so InvisibleButtons
  -- stay unique across simultaneous overlays.
  for _, pick in ipairs(overlays) do
    -- Body outline only for a body-default audio slot (no chip to carry the
    -- mark). Chevron hits and midi (the kbd self-highlights) leave it unmarked.
    if pick.slot and not pick.slot.x and pick.slot.kind ~= 'midi' then
      drawBodyOutline(p, pick.nv)
    end
    drawPortRow(p, pick, '##portSlot/' .. pick.nv.id)
    if pick.list then drawList(p, pick.list, pick.slot) end
  end

  wv:setHover((sourceHit and sourceHit.nv.id)
              or (targetHit and targetHit.nv.id) or nil)

  -- Esc cancels an in-flight draft. Consume the press so the wiring-scope
  -- wiringClearSelection (also bound to Esc) doesn't run on the same key.
  if wireDraft and ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
    wireDraft = nil
  end

  -- LMB on the triangle opens at the current value, warps the OS cursor to
  -- the knob, and dragging=true suppresses the in-strip jump-set below.
  local arrowLmbClicked = arrowHitIdx and not fader and not wireMenu
    and ImGui.IsMouseClicked(ctx, 0)
  if arrowLmbClicked then
    local seg = segs[arrowHitIdx]
    local ax  = (seg.sx + seg.ex) / 2 + 0.5
    local ay  = (seg.sy + seg.ey) / 2 + 0.5
    local x0, y0, x1, y1 = faderRectAt(ax, ay)
    local pad = WIRE_FADER_HIT_PAD
    local cur = wv:edgeGain(arrowHitIdx)
    fader = {
      edgeIdx      = arrowHitIdx,
      rect         = rect(x0, y0, x1, y1),
      hitRect      = rect(x0 - pad, y0 - pad, x1 + pad, y1 + pad),
      currentLin   = cur,
      valueAtClick = cur,
      dragging     = true,
    }
    if not wv:pokeEdgeGain(arrowHitIdx, cur) then
      wv:setEdgeGain(arrowHitIdx, cur)
    end
    -- Warp the OS cursor onto the knob. The OS↔ImGui delta at the click
    -- moment converts; macOS's bottom-up screen y needs the vertical flip.
    if reaper.JS_Mouse_SetPosition then
      local knobP = pFromDb(linToDb(cur))
      local knobImX, knobImY = p.toScreen((x0 + x1) / 2,
                                          y0 + (1 - knobP) * WIRE_FADER_H)
      local osMx, osMy = reaper.GetMousePosition()
      local os       = reaper.GetOS()
      local yFlip    = (os:find('OSX') or os:find('macOS')) and -1 or 1
      reaper.JS_Mouse_SetPosition(
        math.floor(osMx + (knobImX - mx) + 0.5),
        math.floor(osMy + yFlip * (knobImY - my) + 0.5))
    end
  end

  -- Before the click branch: a double-click also raises IsMouseClicked, which
  -- would otherwise jump the fader to the second press's y.
  local faderDblClicked = fader and not fader.dragging
    and ImGui.IsMouseDoubleClicked(ctx, 0)
    and inRect(lmx, lmy, fader.rect)
  if faderDblClicked then
    fader.currentLin = 1.0
    wv:setEdgeGain(fader.edgeIdx, 1.0)
  end

  -- In-strip click owns the mouse: jump the value, start a drag, and
  -- materialise the CU (setEdgeGain) if it doesn't exist yet.
  local faderClicked = fader and not fader.dragging and not faderDblClicked
    and ImGui.IsMouseClicked(ctx, 0)
    and inRect(lmx, lmy, fader.rect)
  if faderClicked then
    local clickLin = pixelYToLin(lmy, fader.rect.y0)
    fader.valueAtClick = wv:edgeGain(fader.edgeIdx)
    fader.currentLin   = clickLin
    fader.dragging     = true
    if not wv:pokeEdgeGain(fader.edgeIdx, clickLin) then
      wv:setEdgeGain(fader.edgeIdx, clickLin)
    end
  end
  local faderConsumed = arrowLmbClicked or faderClicked or faderDblClicked

  -- Debounce to one setEdgeGain per scroll gesture so undo coalesces; the
  -- close-branch above commits if the cursor leaves before the window elapses.
  if fader and not fader.dragging then
    local wheelV = select(1, ImGui.GetMouseWheel(ctx))
    if wheelV ~= 0 and inRect(lmx, lmy, fader.rect) then
      local step = shiftHeld and WIRE_FADER_WHEEL_DB_FINE or WIRE_FADER_WHEEL_DB
      local db   = linToDb(fader.currentLin)
      if db == -math.huge then db = -60 end
      db = math.min(WIRE_FADER_TOP_DB, db + wheelV * step)
      local lin = (db <= -60) and 0 or dbToLin(db)
      fader.currentLin = lin
      if not wv:pokeEdgeGain(fader.edgeIdx, lin) then
        wv:setEdgeGain(fader.edgeIdx, lin)
      end
      fader.wheelPending    = true
      fader.wheelIdleFrames = 0
    elseif fader.wheelPending then
      fader.wheelIdleFrames = (fader.wheelIdleFrames or 0) + 1
      if fader.wheelIdleFrames > WIRE_FADER_WHEEL_IDLE_FRAMES then
        wv:setEdgeGain(fader.edgeIdx, fader.currentLin)
        fader.wheelPending = false
      end
    end
  end

  -- Double-click a node body: sampler dives to sample page, other fx floats
  -- its FX window. dblConsumed blocks this press from starting a drag.
  local dblConsumed = false
  if not shiftHeld and not wireDraft and not fader and overCanvas
     and ImGui.IsMouseDoubleClicked(ctx, 0) then
    local hit = nodeUnderMouse(nodeViews, lmx, lmy)
    if hit then
      dblConsumed = true  -- a node was hit: never fall through to a body-drag
      if hit.activate == 'sampler' then
        local track = wv:samplerTrack(hit.id)
        if track then cmgr:invoke('diveToSampler', track) end
      elseif hit.activate == 'fx' then
        wv:openFxWindow(hit.id)
      end
    end
  end

  -- Mousedown precedence (docs/wiringPage.md): shift-hover > wire-end >
  -- body-drag > band.
  if not faderConsumed and not dblConsumed and not drag and not band
      and not wireDraft and overCanvas and ImGui.IsMouseClicked(ctx, 0) then
    -- Any click closes the spillover. The pre-click sourceHit (list still open)
    -- drives dispatch here.
    listOpenId = nil
    if sourceHit then
      local slot = sourceHit.slot
      if slot then
        -- Pin the port → a chip materialises in the band; rebind slot to it so
        -- the wire anchors at the chip (near the body), not the far-off list
        -- row, and the chip persists for later gestures.

        if sourceHit.list and slot.kind == 'audio' and slot.portIdx >= 2 then
          local nv = sourceHit.nv
          pinned[nv.id] = pinned[nv.id] or {}
          pinned[nv.id][slot.portIdx] = true
          local relaid = layoutPortRow(nv, 'out', lmx, lmy, nil,
                                       sourceHit.layout.side)
          slot = findLayoutSlot(relaid, 'audio', slot.portIdx) or slot
        end
        -- defaultSlot (body-default port 1) has no screen rect; leave
        -- keptAnchor nil so the draft falls back to the node centre.
        local keptAnchor
        if slot.x then
          keptAnchor = { x = slot.x + slot.w / 2, y = slot.y + slot.h / 2 }
        end
        local base = {
          cursorEnd  = 'to',
          keptId     = sourceHit.nv.id,
          keptSide   = sourceHit.layout.side,
          keptAnchor = keptAnchor,
          forbidden  = wv:ancestorsOf(sourceHit.nv.id),
          mx0 = lmx, my0 = lmy,
          fromList   = sourceHit.list ~= nil,
        }
        if slot.kind == 'midi' then
          base.type = 'midi'
        else
          base.type, base.keptPort = 'audio', slot.portIdx
        end
        wireDraft = base
      end
      -- slot=nil: cursor on chevron or between list rows; consume the
      -- click (no wire start, no body-drag fall-through).
    elseif wireEndHover then
      local seg      = segs[wireEndHover.edgeIdx]
      local w        = seg.w
      local keptIsTo = (wireEndHover.side == 'from')
      local keptId   = keptIsTo and w.to or w.from
      local grabbedId   = keptIsTo and w.from or w.to
      local grabbedPort = (w.type == 'audio')
                            and (keptIsTo and w.fromPort or w.toPort) or nil
      -- grabDx/grabDy = gap to the mouse, decayed over travel so the end
      -- doesn't snap to the cursor. Anchor non-body ports at the chip centre,
      -- not the body — a body-centre anchor retargets the redraft to port 1.
      local endX = keptIsTo and seg.sx or seg.ex
      local endY = keptIsTo and seg.sy or seg.ey
      if grabbedPort and grabbedPort > 1 then
        local grabbedNV = nodesById[grabbedId]
        if grabbedNV then
          local layout = layoutPortRow(grabbedNV,
                                       keptIsTo and 'out' or 'in',
                                       lmx, lmy, 'audio')
          local chip = findLayoutSlot(layout, 'audio', grabbedPort)
          if chip and chip.x then
            endX = chip.x + chip.w / 2
            endY = chip.y + chip.h / 2
          end
        end
      end
      wireDraft = {
        type       = w.type,
        cursorEnd  = wireEndHover.side,
        keptId     = keptId,
        keptPort   = (w.type == 'audio')
                       and (keptIsTo and w.toPort or w.fromPort) or nil,
        keptAnchor = wireEndHover.keptAnchor,
        forbidden  = keptIsTo
                       and wv:descendantsOf(keptId)
                       or  wv:ancestorsOf(keptId),
        mx0 = lmx, my0 = lmy,
        grabDx = endX - lmx, grabDy = endY - lmy,
        fromList   = false,
        edgeIdx    = wireEndHover.edgeIdx,
        -- Node+port the end was attached to; while the decayed end stays in
        -- this node's bbox the wire is pinned there and mouseup is a no-op.
        originalTargetId = grabbedId,
        originalPort     = grabbedPort,
      }
    else
      local bodyHit = nodeUnderMouse(nodeViews, lmx, lmy)
      if bodyHit then
        local starts = {}
        if selection[bodyHit.id] then
          for _, nv in ipairs(nodeViews) do
            if selection[nv.id] then starts[nv.id] = { x = nv.pos.x, y = nv.pos.y } end
          end
        else
          starts[bodyHit.id] = { x = bodyHit.pos.x, y = bodyHit.pos.y }
        end
        drag = { mx0 = lmx, my0 = lmy, starts = starts }
      else
        band = { mx0 = lmx, my0 = lmy }
      end
    end
  elseif wireDraft and not ImGui.IsMouseDown(ctx, 0) then
    local moved = wireDraft.fromPalette
               or math.abs(lmx - wireDraft.mx0) >= CLICK_THRESH
               or math.abs(lmy - wireDraft.my0) >= CLICK_THRESH
    if moved then
      if dropEligible(wireDraft, targetHit) then
        local slot = targetHit.slot
        local port = (slot.kind == 'audio') and slot.portIdx or nil
        local sameAsOrigin = wireDraft.edgeIdx
                             and targetHit.nv.id == wireDraft.originalTargetId
                             and (slot.kind ~= 'audio'
                                  or port == wireDraft.originalPort)
        if sameAsOrigin then
          -- Rewiring to the same node + port the wire already had: no-op,
          -- skip the mutation so we don't burn an undo entry on it.
        elseif wireDraft.edgeIdx then
          wv:rewireEdgeEnd(wireDraft.edgeIdx, wireDraft.cursorEnd,
                           { id = targetHit.nv.id, port = port })
        else
          wv:addWire{
            type = wireDraft.type or slot.kind,
            from = wireDraft.keptId, fromPort = wireDraft.keptPort,
            to   = targetHit.nv.id,
            toPort = port,
          }
        end
      elseif wireDraft.edgeIdx
             and not nodeAtPoint(nodeViews, draftCx, draftCy) then
        -- Redraft onto empty canvas (judged by the wire end) deletes the wire.
        -- Ineligible-target drops fall through to cancel below.
        wv:removeWireAt(wireDraft.edgeIdx)
      end
      hoverFreeze = { x = mx, y = my }
    elseif wireDraft.fromList and wireDraft.type == 'audio'
           and wireDraft.keptPort and wireDraft.keptPort >= 2 then
      -- Click-without-drag on a list row pins the port as a chip; sticky keeps
      -- the row visible until shift-release or hover returns here.
      pinned[wireDraft.keptId] = pinned[wireDraft.keptId] or {}
      pinned[wireDraft.keptId][wireDraft.keptPort] = true
      sticky = { nodeId = wireDraft.keptId, side = wireDraft.keptSide }
    end
    wireDraft  = nil
    listOpenId = nil   -- close any target-side spillover that was open
  elseif drag and not ImGui.IsMouseDown(ctx, 0) then
    local dx, dy = lmx - drag.mx0, lmy - drag.my0
    if dx ~= 0 or dy ~= 0 then
      local moves = {}
      for id, s in pairs(drag.starts) do moves[id] = { x = s.x + dx, y = s.y + dy } end
      wv:moveNodes(moves)
    end
    drag = nil
  elseif band and not ImGui.IsMouseDown(ctx, 0) then
    if lmx == band.mx0 and lmy == band.my0 then
      wv:setSelection{}                                        -- empty-canvas click
    else
      wv:setSelection(nodesInBand(nodeViews,
                                  band.mx0, band.my0, lmx, lmy))
    end
    band = nil
  end

  -- RMB precedence: triangle → per-wire menu; node body → node menu; empty
  -- canvas → FX picker (same code path as the N-key shortcut).
  if not drag and not band and not wireDraft
      and overCanvas and ImGui.IsMouseClicked(ctx, 1) then
    if arrowHitIdx and not wireMenu and not fader then
      local seg = segs[arrowHitIdx]
      local ax  = (seg.sx + seg.ex) / 2 + 0.5
      local ay  = (seg.sy + seg.ey) / 2 + 0.5
      wireMenu = { edgeIdx = arrowHitIdx, anchorX = ax, anchorY = ay }
      ImGui.OpenPopup(ctx, '##wiringWireMenu')
    else
      local bodyHit = nodeUnderMouse(nodeViews, lmx, lmy)
      if bodyHit and not nodeMenu then
        nodeMenu = { nodeId = bodyHit.id, anchorX = lmx, anchorY = lmy }
        ImGui.OpenPopup(ctx, '##wiringNodeMenu')
      else
        openFxPicker(lmx, lmy, { x = mx, y = my })
      end
    end
  end

  -- Wire menu: ImGui popup centred on the cursor; closes on cursor-leave of
  -- the window rect (and on click-outside, ImGui's default).
  if wireMenu then
    local screenX, screenY = p.toScreen(wireMenu.anchorX, wireMenu.anchorY)
    ImGui.SetNextWindowPos(ctx, screenX, screenY, ImGui.Cond_Appearing, 0.5, 0.5)
    chrome.pushChromeWindow()
    ImGui.PushStyleColor(ctx, ImGui.Col_Border, chrome.colour('separator'))
    if ImGui.BeginPopup(ctx, '##wiringWireMenu') then
      local wire = wireViewsList[wireMenu.edgeIdx]
      local changed, v = chrome.checkbox('Primary', wire and wire.primary or false)
      if changed then wv:setEdgePrimary(wireMenu.edgeIdx, v) end
      -- Skip close-on-leave until the layout has settled, otherwise the
      -- first-frame default size doesn't yet contain the cursor.
      if not ImGui.IsWindowAppearing(ctx) then
        local wx, wy = ImGui.GetWindowPos(ctx)
        local ww, wh = ImGui.GetWindowSize(ctx)
        if not (mx >= wx and mx <= wx + ww and my >= wy and my <= wy + wh) then
          ImGui.CloseCurrentPopup(ctx)
        end
      end
      ImGui.EndPopup(ctx)
    else
      wireMenu = nil
    end
    ImGui.PopStyleColor(ctx, 1)
    chrome.popChromeWindow()
  end

  -- Node menu: mirrors the wire menu — cursor-anchored popup, closes on
  -- cursor-leave of the window rect (and click-outside, ImGui's default).
  if nodeMenu then
    local screenX, screenY = p.toScreen(nodeMenu.anchorX, nodeMenu.anchorY)
    ImGui.SetNextWindowPos(ctx, screenX, screenY, ImGui.Cond_Appearing, 0, 0)
    chrome.pushChromeWindow()
    ImGui.PushStyleColor(ctx, ImGui.Col_Border, chrome.colour('separator'))
    if ImGui.BeginPopup(ctx, '##wiringNodeMenu') then
      if ImGui.Selectable(ctx, 'Delete node') then
        wv:deleteNode(nodeMenu.nodeId)
        ImGui.CloseCurrentPopup(ctx)
      end
      if not ImGui.IsWindowAppearing(ctx) then
        local wx, wy = ImGui.GetWindowPos(ctx)
        local ww, wh = ImGui.GetWindowSize(ctx)
        if not (mx >= wx and mx <= wx + ww and my >= wy and my <= wy + wh) then
          ImGui.CloseCurrentPopup(ctx)
        end
      end
      ImGui.EndPopup(ctx)
    else
      nodeMenu = nil
    end
    ImGui.PopStyleColor(ctx, 1)
    chrome.popChromeWindow()
  end

  -- FX picker: cursor-anchored (RMB) or viewport-centred (N-key) non-modal
  -- popup. Non-modal means no background dim and click-outside closes it.
  if fxPicker then
    if fxPicker.anchorSX then
      ImGui.SetNextWindowPos(ctx, fxPicker.anchorSX, fxPicker.anchorSY,
                             ImGui.Cond_Appearing, 0, 0)
    else
      local cx, cy = ImGui.Viewport_GetCenter(ImGui.GetWindowViewport(ctx))
      ImGui.SetNextWindowPos(ctx, cx, cy, ImGui.Cond_Appearing, 0.5, 0.5)
    end
    chrome.pushChromeWindow()
    ImGui.PushStyleColor(ctx, ImGui.Col_Border, chrome.colour('separator'))
    if ImGui.BeginPopup(ctx, '##wiringFxPicker', ImGui.WindowFlags_NoNav) then
      renderFxPicker(fxPicker)
      ImGui.EndPopup(ctx)
    else
      fxPicker = nil
    end
    ImGui.PopStyleColor(ctx, 1)
    chrome.popChromeWindow()
  end

  -- Band overlay: drawn last so it floats over nodes and hover affordances.
  if band then
    local bx0, by0, bx1, by1 = band.mx0, band.my0, lmx, lmy
    if bx0 > bx1 then bx0, bx1 = bx1, bx0 end
    if by0 > by1 then by0, by1 = by1, by0 end
    p.stroke(rect(bx0, by0, bx1, by1), 'wiring.node.selected', 1, 0)
  end

  -- Port InvisibleButtons moved the layout cursor; rewind so the sizing Dummy
  -- reserves from the canvas origin.
  ImGui.SetCursorScreenPos(ctx, sx, sy)
  ImGui.Dummy(ctx, w, h)
end

local function pushBodyStyles()
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, chrome.colour('text'))
end
local function popBodyStyles() ImGui.PopStyleColor(ctx, 1) end

----- Palette pane

-- Hand-drawn header so its band matches the canvas's by construction: both panes
-- share renderBody's `oy`, so the divider aligns across PANE_GAP without measuring.
local function renderPaletteHeader()
  local p       = painter.new(ctx, chrome, {})
  local ox, oy  = ImGui.GetCursorScreenPos(ctx)
  local paneW   = (select(1, ImGui.GetContentRegionAvail(ctx)))
  local rowH    = math.max(1, ImGui.GetTextLineHeightWithSpacing(ctx))
  local headerH = rowH + HEADER_PAD
  local label   = 'sources'
  local tw      = p.measure(label)
  p.text(ox + math.floor((paneW - tw) / 2), oy + HEADER_PAD, 'text', label)
  p.line(ox, oy + headerH, ox + paneW, oy + headerH, 'text', 1)
  ImGui.Dummy(ctx, paneW, headerH + HEADER_GAP)
end

local function openAddSourceModal()
  modalHost:openPrompt{
    title    = 'New source',
    prompt   = 'Track name',
    buf      = '',
    callback = function(name)
      if name and name ~= '' then wv:addSource{ name = name } end
    end,
  }
end

-- Delete tries unforced first; a take-bearing track comes back refused with a
-- count, which opens a confirm that re-issues the delete with force.
local function deleteSourceGuarded(nodeId, label)
  local ok, takes = wv:deleteSource(nodeId)
  if ok then return end
  modalHost:openConfirm{
    title    = 'Delete source',
    prompt   = string.format('"%s" has %d take%s. Delete the track anyway? (y/n)',
                             label, takes, takes == 1 and '' or 's'),
    callback = function(yes) if yes then wv:deleteSource(nodeId, true) end end,
  }
end

local function renderPaletteActions(focused)
  if ImGui.Button(ctx, 'add##source') then openAddSourceModal() end
  ImGui.SameLine(ctx, 0, 4)
  chrome.disabledIf(focused == nil, function()
    if ImGui.Button(ctx, 'del##source') then
      deleteSourceGuarded(focused.id, focused.label)
    end
  end)
end

local function renderPaletteList(sources)
  if #sources == 0 then
    ImGui.TextDisabled(ctx, '(no sources)')
    return
  end
  for _, src in ipairs(sources) do
    if ImGui.Selectable(ctx, src.label .. '##src' .. src.id, paletteSource == src.id) then
      paletteSource = src.id
    end
    -- Drag a palette row to start a type-agnostic forward draft; the drop
    -- port's kind (audio|midi) decides the edge type. See docs/wiringPage.md.
    if not wireDraft and ImGui.IsItemActive(ctx)
       and ImGui.IsMouseDragging(ctx, 0) then
      wireDraft = {
        cursorEnd   = 'to',
        keptId      = src.id,
        forbidden   = wv:ancestorsOf(src.id),
        fromPalette = true,
        keptLabel   = src.label,
      }
    end
  end
end

local function renderPalette()
  local sources, focused = {}, nil
  for _, nv in ipairs(wv:nodeViews()) do
    if nv.category == 'source' then
      util.add(sources, nv)
      if nv.id == paletteSource then focused = nv end
    end
  end
  -- Stale focus (row deleted, or never set) greys out del.
  if not focused then paletteSource = nil end

  -- Buttons want toolbar colours; body styles are already pushed at renderBody level.
  chrome.pushChromeStyles()
  renderPaletteHeader()
  renderPaletteActions(focused)
  ImGui.Separator(ctx)
  renderPaletteList(sources)
  chrome.popChromeStyles()
end

----------- PUBLIC

--contract: bind takes no take — wiring is project-wide. coord may call with no args (or a take, ignored).
function wp:bind() end
function wp:unbind()
  drag, band, wireDraft, shiftWas = nil, nil, nil, false
  listOpenId, sticky, engagedId, hoverFreeze = nil, nil, nil, nil
  fader, wireMenu = nil, nil
end

--contract: turn on live recompile — every wiringChanged drives a diff+apply, plus one immediate reconcile pass to sync REAPER with the persisted graph at boot. Idempotent. Called once from continuum after registration.
function wp:enableLive() wv:enableLive() end

--contract: per-frame poll; drives wm:pollUndo to detect REAPER undo/redo of wiring gestures (scratch P_EXT divergence) and re-issue wiringChanged{kind='load'}. Called from coordinator.frame regardless of which page is active.
function wp:tick() wv:pollUndo() end

function wp:renderToolbarBits(_) end

--contract: body = wiring canvas | source palette; dispatch at end-of-body routes wiring-scope keys.
function wp:renderBody(_, w, h, dispatch)
  if not ctx then return end
  pushBodyStyles()

  local canvasW = math.max(120, w - PALETTE_W - PANE_GAP)
  if ImGui.BeginChild(ctx, '##wiringCanvas', canvasW, h,
                      ImGui.ChildFlags_None,
                      ImGui.WindowFlags_NoNav) then
    renderCanvas(canvasW, h)
  end
  ImGui.EndChild(ctx)

  -- 1px vrule centred in PANE_GAP so neither pane edge touches it; 'text' ties it
  -- to the body palette, matching arrangePage.
  ImGui.SameLine(ctx, 0, 0)
  local sx, sy = ImGui.GetCursorScreenPos(ctx)
  local lineX  = sx + math.floor(PANE_GAP / 2)
  local p      = painter.new(ctx, chrome, {})
  p.line(lineX, sy, lineX, sy + h, 'text', 1)
  ImGui.Dummy(ctx, PANE_GAP, h)
  ImGui.SameLine(ctx, 0, 0)

  if ImGui.BeginChild(ctx, '##wiringPalette', PALETTE_W, h,
                      ImGui.ChildFlags_None,
                      ImGui.WindowFlags_NoNav) then
    renderPalette()
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

--contract: acceptCmds=false if any picker active, any item active, or modal open at frame start.
function wp:focusState()
  if not ctx then return { suppressKbd = false, acceptCmds = false } end
  local pa = chrome and chrome.pickerIsActive() or false
  return {
    suppressKbd = pa,
    acceptCmds  = (not pa)
                  and not ImGui.IsAnyItemActive(ctx)
                  and not fxPicker
                  and not modalHost:wasOpenAtFrameStart(),
  }
end


----- Wiring scope

-- Place an auto-spawned source on the master→cursor ray, pushed past the
-- generator far enough that the two body rects don't collide. Degenerate
-- (cursor on master): horizontal offset.
local SOURCE_PAD = 24
local function sourcePosFor(genX, genY)
  local mxp, myp = wv:masterPos()
  local dx, dy = genX - mxp, genY - myp
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1 then return genX + NODE_W + SOURCE_PAD, genY end
  local ux, uy = dx / len, dy / len
  local tx = (ux == 0) and math.huge or (NODE_W / 2 / math.abs(ux))
  local ty = (uy == 0) and math.huge or (NODE_H / 2 / math.abs(uy))
  local exit = math.min(tx, ty)
  local sep  = 2 * exit + SOURCE_PAD
  return genX + ux * sep, genY + uy * sep
end

-- anchor (optional) = { x, y } screen coords for the popup; nil → viewport-centred.
openFxPicker = function(x, y, anchor)
  if x == nil then
    local mx, my = ImGui.GetMousePos(ctx)
    x, y = mx - canvasOrigin.ox, my - canvasOrigin.oy
  end
  local sx, sy = sourcePosFor(x, y)
  fxPicker = {
    x = x, y = y, sx = sx, sy = sy,
    anchorSX = anchor and anchor.x, anchorSY = anchor and anchor.y,
    buf = '', cursor = 1, items = wv:listInstalledFX(),
  }
  ImGui.OpenPopup(ctx, '##wiringFxPicker')
end

-- Defer the gesture so the picker's close paints before the live
-- recompile/reconcile stall — wm:addFxNode keeps its single Undo block.
local function commitFx(pck, fx)
  ImGui.CloseCurrentPopup(ctx)
  fxPicker = nil
  reaper.defer(function()
    wv:addFx(pck.x, pck.y, { name = fx.name, ident = fx.ident },
             { sourcePos = { x = pck.sx, y = pck.sy } })
  end)
end

renderFxPicker = function(pck)
  if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
  ImGui.SetNextItemWidth(ctx, 280)
  local prev = pck.buf
  local _, buf = ImGui.InputText(ctx, '##fxFilter', prev)
  pck.buf = buf
  local entered = ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
               or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)
  ImGui.Separator(ctx)

  local lf = buf:lower()
  local matches = {}
  for _, fx in ipairs(pck.items) do
    if buf == '' or fx.name:lower():find(lf, 1, true) then
      matches[#matches + 1] = fx
    end
  end
  if ImGui.IsWindowAppearing(ctx) or buf ~= prev then pck.cursor = 1 end
  local n = #matches
  local cursor = pck.cursor or 1
  if n > 0 then
    if     ImGui.IsKeyPressed(ctx, ImGui.Key_DownArrow) then cursor = cursor % n + 1
    elseif ImGui.IsKeyPressed(ctx, ImGui.Key_UpArrow)   then cursor = (cursor - 2) % n + 1
    end
  end
  cursor = math.min(math.max(cursor, 1), math.max(n, 1))
  pck.cursor = cursor

  if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
    ImGui.CloseCurrentPopup(ctx)
    fxPicker = nil
  elseif entered and matches[cursor] then
    commitFx(pck, matches[cursor])
  else
    if ImGui.BeginChild(ctx, '##fxList', 280, 240,
                        ImGui.ChildFlags_None, ImGui.WindowFlags_NoNav) then
      for i, fx in ipairs(matches) do
        if ImGui.Selectable(ctx, fx.name, i == cursor) then commitFx(pck, fx) end
      end
    end
    ImGui.EndChild(ctx)
  end
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
