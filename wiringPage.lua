-- See docs/wiringPage.md for the model.
-- @noindex

--invariant: render + input only — wiringPage draws the canvas and reads keyboard / mouse. It holds no wm reference: every graph query goes through wv, every mutation will go through wv (the manager-facing surface).
--invariant: wiring page is project-wide — bind() takes no take and never re-keys cm; the tracker take and the sampler track are unaffected by switching to / from wiring.
--invariant: the page owns every pixel — node-box geometry, port slot layout, hit-test boxes are all derived here from wv's viewport-independent nodeViews. wv carries label + category + audio/MIDI counts; the page turns those into rects and tints.
--invariant: at Stage 1.3d the page draws wires as a pre-pass before nodes — centre-to-centre lines occluded by the rounded rects, midpoint arrow for orientation, parallel wires in the same unordered pair offset perpendicularly with MIDI sorted to the right, non-1 audio ports labelled by number with hover-tooltip names. add-fx / drag / rubber-band unchanged; shift-gated port-row hover drives wire creation — per-face layout is [handle ▾][audio chips for ports 2..N centred], handle pinned to left corner; the midi keyboard lives inside the body at its middle-right edge (appears under shift hover, fills the body colour behind itself to overpaint the label) rather than in the band. The popout band only renders when nAudio ≥ 2 — a 1-audio-port node with midi has no band; the body catches default-port hover and the body-internal kbd catches midi. body-default = port 1; audio chips render for ports 2..N when N ≤ PORTS_PER_ROW; past that, chips appear only for currently-wired and user-pinned ports while the rest live in the handle's dropdown. top/bottom faces only. See design/wiring.md.

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
local uiFont   = gui and gui.uiFont or nil
local uiSize   = gui and gui.fontSize and gui.fontSize.ui or 12

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
local PORT_GAP         = 6
local PORT_BAND_OFFSET = 6   -- gap between node edge and the hover-only port row
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
-- wireDraft: captured at the start of any wire-end-following drag. Two
-- entry paths share the state:
--   • shift-hover on a port: forward draft. cursorEnd='to', keptId/
--     keptPort/keptAnchor pin the source end, cursor floats the dest.
--     forbidden = ancestors(keptId).
--   • unmodified click on a wire's end-region: redraft. cursorEnd matches
--     the grabbed side ('from' moves the source end, 'to' moves the
--     dest end). keptId/keptPort identify the surviving end (the side
--     opposite cursorEnd). forbidden is ancestors(kept) when cursorEnd=
--     'to' (kept = source, new dest must not be its ancestor) and
--     descendants(kept) when cursorEnd='from' (kept = dest, new source
--     must not be its descendant). edgeIdx is the index of the edge in
--     g.edges being redrafted; nil for forward drafts.
-- forbidden is the cycle-blocked node set; consulted at hover-time so
-- invalid targets get no visual encouragement. Cleared on mouseup
-- (commit / delete / cancel) or on Esc (cancel).
--
-- Mousedown precedence: shift-hover (new wire) > wire-end-hover (redraft)
-- > body-hit (drag) > anywhere else (band). All mutually exclusive while
-- live.
local drag      = nil  -- { mx0, my0, starts = { [id] = {x,y}, … } }
local band      = nil  -- { mx0, my0 } — current corner is GetMousePos
local wireDraft = nil  -- { type, cursorEnd='to'|'from', keptId, keptPort?, keptSide?, keptAnchor?, forbidden, mx0, my0, fromList, edgeIdx? }
local shiftWas  = false
-- Per-node set of audio port indices the user has explicitly pinned via
-- click-without-drag on a list row, or implicitly by starting a draft
-- from a list row (in which case the chip materialises at mousedown).
-- Persists across binds but not across project loads (page-local;
-- future work to lift this into wm so it round-trips with the graph).
local pinned     = {}   -- pinned[nodeId][portIdx] = true
-- Which node's spillover list is currently engaged. Set when the cursor
-- crosses the chevron; cleared when the cursor leaves chevron + list, or
-- on any mouseclick. Cursor in list area without prior chevron crossing
-- does NOT engage — the popup is gated tight on the chevron.
local listOpenId = nil
-- Node whose port row currently holds hover priority. While set, the
-- cursor-driven hover funcs probe this node first; only when its hover
-- area (body + band, extended by list.hitRect when listOpenId matches)
-- no longer catches the cursor does the per-node scan resume. Stops the
-- popout from flipping to a nearby node mid-gesture when two bodies'
-- hoverRects overlap. Cleared lazily in the fast-path and on unbind.
local engagedId  = nil
-- After a drag-drop mouseup, suppress shift-hover until the cursor next
-- moves. Without this the source-side popout snaps onto whatever node
-- happens to be under the cursor at drop-time, which reads as a flicker.
-- Captured (x, y) lets us detect the next move without per-frame deltas.
local hoverFreeze = nil  -- { x, y } | nil
-- After click-pinning a port from the spillover list, the pinned node's
-- port row stays popped up even when the cursor isn't on it. Cleared on
-- shift-release, on any mouseclick, or when natural hover engages this
-- *same* node (the user has come back to it). Hovering some other node
-- does NOT clear sticky — both overlays render simultaneously. Side is
-- captured at pin-time so the sticky row doesn't flip top/bottom as the
-- cursor moves around the canvas.
local sticky = nil  -- { nodeId, side }

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

local SELECTED_INFLATE = 0   -- outline traces the body edge tightly; >0 leaves a moat where the popup bg bleeds through
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

-- Small piano-keyboard icon (C, C#, D, D#, E): 3 outlined white keys with
-- 2 filled black keys overlaying the C-D and D-E boundaries. Drawn with
-- its top-left at (x,y), occupying MIDI_SLOT_W × MIDI_SLOT_H. Stand-in
-- for the midi tint — later this will gain an in/out arrow to distinguish
-- direction.
local function drawKeyboardIcon(dl, x, y)
  local col      = chrome.colour('text')
  local kw, kh   = 4, 10
  local bw, bh   = 2, 5
  local ix0, iy0 = math.floor(x), math.floor(y)
  for i = 0, 2 do
    local kx = ix0 + i * kw
    ImGui.DrawList_AddRect(dl, kx, iy0, kx + kw + 1, iy0 + kh + 1, col, 0, 0, 1)
  end
  for _, i in ipairs{ 1, 2 } do
    local cx  = ix0 + i * kw
    local bx0 = math.floor(cx - bw / 2)
    ImGui.DrawList_AddRectFilled(dl, bx0, iy0, bx0 + bw + 1, iy0 + bh + 1, col)
  end
end

-- Spillover-list handle: a small chevron pointing outward in the direction
-- the dropdown will open (down on the bottom face, up on the top face).
-- Sized like a band-row chip so it shares the row centreline cleanly. The
-- band-level bg rect drawn by drawPortRow handles wire occlusion.
local function drawHandle(dl, handle, side)
  local col = chrome.colour('text')
  local cx, cy = handle.x + handle.w / 2, handle.y + handle.h / 2
  local hx, hy = 4, 3
  if side == 'bottom' then
    ImGui.DrawList_AddTriangleFilled(dl,
      cx - hx, cy - hy, cx + hx, cy - hy, cx, cy + hy, col)
  else
    ImGui.DrawList_AddTriangleFilled(dl,
      cx - hx, cy + hy, cx + hx, cy + hy, cx, cy - hy, col)
  end
end

-- One port-row slot: the filled audio square or keyboard icon, plus an
-- InvisibleButton (padded outward so the hit area is comfortably larger
-- than the visual) and a tooltip anchored just above. Wire occlusion is
-- handled at the band level by drawPortRow's bgRect, so no per-slot patch.
-- The InvisibleButton advances the layout cursor; renderCanvas's trailing
-- Dummy restores it.
local function drawSlot(dl, slot, idStem, audioCol)
  if slot.kind == 'audio' then
    ImGui.DrawList_AddRectFilled(dl, slot.x, slot.y,
      slot.x + slot.w, slot.y + slot.h, audioCol)
  else
    drawKeyboardIcon(dl, slot.x, slot.y)
  end
  local pad = PORT_HIT_PAD
  ImGui.SetCursorScreenPos(ctx, slot.x - pad, slot.y - pad)
  ImGui.InvisibleButton(ctx, idStem, slot.w + 2 * pad, slot.h + 2 * pad)
  -- AllowWhenBlockedByActiveItem lets target tooltips fire while the
  -- source chip's InvisibleButton is the active item (mid wire-drag).
  local hoverFlags = ImGui.HoveredFlags_ForTooltip
                   | ImGui.HoveredFlags_AllowWhenBlockedByActiveItem
  if slot.name and ImGui.IsItemHovered(ctx, hoverFlags) then
    ImGui.SetNextWindowPos(ctx,
      slot.x + slot.w / 2, slot.y - PORT_TOOLTIP_GAP,
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

-- Selection-style outline around the whole body, used for both source-side
-- and target-side hover — no more split-band shape.
local function drawBodyOutline(dl, nv, ox, oy)
  local lx0, ly0, lx1, ly1 = nodeRect(nv)
  ImGui.DrawList_AddRect(dl,
    ox + lx0 - SELECTED_INFLATE, oy + ly0 - SELECTED_INFLATE,
    ox + lx1 + SELECTED_INFLATE, oy + ly1 + SELECTED_INFLATE,
    chrome.colour('wiring.node.selected'), CORNER_R, 0, SELECTED_STROKE)
end

----- Wire-creation gesture helpers

local function inRect(px, py, x0, y0, x1, y1)
  return px >= x0 and px <= x1 and py >= y0 and py <= y1
end

-- By-name dropdown anchored to a node's handle: one row per audio port
-- (port-index order, names from `audio`). Grows outward from the handle
-- in the band's direction. Uses the small ui font so a 32-row list stays
-- a reasonable height. Rows are chunky boxes with tight bounds (no hit
-- pad), so adjacent-row hit tests don't bleed into each other. The
-- returned hitRect extends LIST_GAP toward the handle so chevron → list
-- traversal has no dead zone even with the handle's hit area sized to
-- the chevron alone.
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
  local n     = #audio
  local listX = handle.x
  local listY = (side == 'bottom') and (handle.y + handle.h + LIST_GAP)
                                    or (handle.y - LIST_GAP - n * rowH)
  local rows = {}
  for i, name in ipairs(audio) do
    rows[i] = { kind = 'audio', portIdx = i, name = name,
                x = listX, y = listY + (i - 1) * rowH,
                w = maxW, h = rowH }
  end
  local rect    = { listX, listY, listX + maxW, listY + n * rowH }
  local hitRect = (side == 'bottom')
                  and { rect[1], rect[2] - LIST_GAP, rect[3], rect[4] }
                  or  { rect[1], rect[2],            rect[3], rect[4] + LIST_GAP }
  return { rows = rows, rect = rect, hitRect = hitRect }
end

-- Per-face layout: handle ▾ pinned to the left body corner, audio chips
-- for ports 2..N centred (port 1 lives on the body itself, no chip). The
-- midi keyboard is body-internal — placed at the middle-right edge with
-- inBody=true — not in the band, so a 1-audio-port + midi node yields no
-- band at all. Audio chips render for ports 2..N when N ≤ PORTS_PER_ROW;
-- past that the band shows only currently-wired and user-pinned ports
-- (chip promotion — design/wiring.md). hoverRect = body ∪ slot/handle
-- hit pads, so cursor traversal between zones keeps the hover live. keep
-- filters mismatched kinds during target-side hover (audio draft hides
-- midi and the handle; midi draft hides audio chips and the handle).
-- forceSide pins the face for sticky overlays (where the cursor isn't
-- over the node so my can't pick the side); natural hover passes nil.
local function layoutPortRow(nv, ox, oy, dir, mx, my, keep, forceSide)
  local lx0, ly0, lx1, ly1 = nodeRect(nv)
  local bx0, by0, bx1, by1 = ox + lx0, oy + ly0, ox + lx1, oy + ly1
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

  -- Chip set: natural ports 2..N when N ≤ PORTS_PER_ROW, plus currently-
  -- wired ports (chip promotion), plus any pinned by the user via click-
  -- without-drag on a list row. Sorted ascending and wrapped onto outward
  -- rows at PORTS_PER_ROW per row.
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
    -- edge. The right corner is free now that midi lives on the body, so
    -- the chip row's centre sits well right of the body centre.
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
    local x0, y0 = s.x - PORT_HIT_PAD, s.y - PORT_HIT_PAD
    local x1, y1 = s.x + s.w + PORT_HIT_PAD, s.y + s.h + PORT_HIT_PAD
    if not bandRect then bandRect = { x0, y0, x1, y1 }
    else
      if x0 < bandRect[1] then bandRect[1] = x0 end
      if y0 < bandRect[2] then bandRect[2] = y0 end
      if x1 > bandRect[3] then bandRect[3] = x1 end
      if y1 > bandRect[4] then bandRect[4] = y1 end
    end
  end
  for _, s in ipairs(slots) do
    if not s.inBody then extend(s) end
  end
  extend(handle)

  -- The handle's by-name dropdown is computed alongside the band so its
  -- area joins hoverRect; this lets the cursor traverse handle → list
  -- without losing engagement with the node.
  local list = layoutList(audio, handle, side)

  local hoverRect = { bx0, by0, bx1, by1 }
  local function unionInto(r)
    if not r then return end
    if r[1] < hoverRect[1] then hoverRect[1] = r[1] end
    if r[2] < hoverRect[2] then hoverRect[2] = r[2] end
    if r[3] > hoverRect[3] then hoverRect[3] = r[3] end
    if r[4] > hoverRect[4] then hoverRect[4] = r[4] end
  end
  -- list.hitRect is intentionally NOT unioned here — cursor-in-list does
  -- not engage the popup. shiftHoverHit / dropTargetHit extend the hover
  -- area with list.hitRect only after the chevron has been crossed.
  unionInto(bandRect)

  -- popup: NODE_W-wide rounded rect that overlaps the body's near edge by
  -- 2*CORNER_R (so the popup's own rounded corners hide inside the body's
  -- solid region; if overlap were just CORNER_R the popup's corner wedge
  -- would line up with the body's corner wedge and the canvas would show
  -- through instead of the popup colour) and extends past the bandRect on
  -- the far side. Drawn before the node so the body overpaints the overlap.
  local POPUP_PAD     = 3
  local POPUP_OVERLAP = 2 * CORNER_R
  local popup
  if bandRect then
    if side == 'bottom' then
      popup = { bx0, by1 - POPUP_OVERLAP, bx1, bandRect[4] + POPUP_PAD }
    else
      popup = { bx0, bandRect[2] - POPUP_PAD, bx1, by0 + POPUP_OVERLAP }
    end
  end

  return { slots = slots, handle = handle, bandRect = bandRect, list = list,
           hoverRect = hoverRect, side = side, popup = popup }
end

local function slotHit(slots, mx, my)
  for _, s in ipairs(slots) do
    if inRect(mx, my,
              s.x - PORT_HIT_PAD, s.y - PORT_HIT_PAD,
              s.x + s.w + PORT_HIT_PAD, s.y + s.h + PORT_HIT_PAD) then
      return s
    end
  end
end

-- Tight hit-test for list rows (no pad — rows are full-height boxes
-- packed back-to-back, so padding would overlap into the neighbour).
local function rowHit(rows, mx, my)
  for _, r in ipairs(rows) do
    if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
      return r
    end
  end
end

-- Default slot when the cursor is over the body alone (no specific slot
-- under it). Audio port 1 if any audio in this direction, else the
-- keyboard. `keep` biases the default for target-side hover: a midi draft
-- defaults to the keyboard, an audio draft to port 1.
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
  return handle
     and inRect(mx, my, handle.x, handle.y,
                handle.x + handle.w, handle.y + handle.h)
end

-- Common hover lookup (body + band only — list engagement is handled by
-- shiftHoverHit / dropTargetHit). Priority: chip/midi → chevron → body-
-- default. A non-nil list on the returned pick signals "chevron just hit,
-- engage this node's list"; the orchestrating caller mutates listOpenId
-- accordingly. Cursor in the list area without a prior chevron crossing
-- is rejected here — the engaged-node fast-path adds list.hitRect to the
-- hover area only after engagement.
local function pickHovered(nv, layout, mx, my, dir, keep)
  local r = layout.hoverRect
  if not inRect(mx, my, r[1], r[2], r[3], r[4]) then return nil end
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

-- True when the cursor is still engaged with a node's open spillover —
-- either on the chevron or anywhere in the list's hit rect.
local function stillEngaged(layout, mx, my)
  local list = layout.list
  if not list then return false end
  if onChevron(layout.handle, mx, my) then return true end
  local r = list.hitRect
  return inRect(mx, my, r[1], r[2], r[3], r[4])
end

-- Source-side hover (shift held, no draft). Manages engagedId: while
-- set, the engaged node has hover priority — its body + band hoverRect
-- (extended by list.hitRect when listOpenId matches) is probed before
-- any other node, so a nearby body's overlapping hoverRect can't steal
-- the popout mid-gesture. Side effect: clears sticky if natural hover
-- lands on the sticky node (the "cursor returned to the pinned node"
-- condition). Hovering some other node leaves sticky alone — both
-- overlays render simultaneously.
local function shiftHoverHit(nodeViews, mx, my, ox, oy)
  local function consume(pick)
    if pick.list then listOpenId = pick.nv.id end
    engagedId = pick.nv.id
    if sticky and sticky.nodeId == pick.nv.id then sticky = nil end
    return pick
  end
  if engagedId then
    for _, nv in ipairs(nodeViews) do
      if nv.id == engagedId then
        local layout = layoutPortRow(nv, ox, oy, 'out', mx, my, nil)
        if listOpenId == nv.id and stillEngaged(layout, mx, my) then
          return consume{ nv = nv, layout = layout, list = layout.list,
                          slot = rowHit(layout.list.rows, mx, my) }
        end
        local pick = pickHovered(nv, layout, mx, my, 'out', nil)
        if pick then return consume(pick) end
        break
      end
    end
    engagedId, listOpenId = nil, nil
  end
  for _, nv in ipairs(nodeViews) do
    if #nv.outs.audio > 0 or #nv.outs.midi > 0 then
      local layout = layoutPortRow(nv, ox, oy, 'out', mx, my, nil)
      local pick = pickHovered(nv, layout, mx, my, 'out', nil)
      if pick then return consume(pick) end
    end
  end
end

-- Build a port-row overlay for the sticky node (the one whose list-row
-- click pinned a port). Cursor-independent: uses the pinned-side stored
-- at click-time so the overlay doesn't flip top/bottom as the cursor
-- moves around. Defaults the slot highlight to port 1 / midi keyboard.
local function stickyHoverHit(nodeViews, ox, oy)
  if not sticky then return nil end
  for _, nv in ipairs(nodeViews) do
    if nv.id == sticky.nodeId
       and (#nv.outs.audio > 0 or #nv.outs.midi > 0) then
      local layout = layoutPortRow(nv, ox, oy, 'out', 0, 0, nil, sticky.side)
      return { nv = nv, layout = layout, slot = defaultSlot(nv, 'out', nil) }
    end
  end
  sticky = nil  -- node no longer exists in the graph
end

-- Keep the draft's source node's port row visible while the click-hold is
-- in flight. Without this the popup flashes off the moment wireDraft is
-- set (mousedown suppresses sourceHit) and back on once sticky is set on
-- mouseup. Highlights the slot the draft started from when it's findable
-- in the chip set (chip click / midi); nil otherwise (list-row pin not
-- yet effective, or body-default port 1).
local function findLayoutSlot(layout, slotKind, portIdx)
  for _, s in ipairs(layout.slots) do
    if s.kind == slotKind
       and (slotKind ~= 'audio' or s.portIdx == portIdx) then
      return s
    end
  end
end
-- Forward-draft only: highlights the kept (source) node's port row so
-- the user sees where the in-flight wire is coming from. Redrafts skip
-- this — the wire being dragged is itself the visual cue for the kept
-- end, and the kept-side popout would clutter the gesture.
local function draftSourceHoverHit(nodeViews, ox, oy)
  if not wireDraft or wireDraft.edgeIdx then return nil end
  for _, nv in ipairs(nodeViews) do
    if nv.id == wireDraft.keptId then
      local layout = layoutPortRow(nv, ox, oy, 'out', 0, 0, nil,
                                   wireDraft.keptSide)
      -- Body-default port 1 has no chip in the layout, so findLayoutSlot
      -- returns nil. Synthesise a default-slot spec so the source node
      -- still reads as engaged (body outline lights up, since no chip
      -- can carry the highlight).
      local slot = findLayoutSlot(layout, wireDraft.type, wireDraft.keptPort)
      if not slot then
        slot = { kind = wireDraft.type, portIdx = wireDraft.keptPort }
      end
      return { nv = nv, layout = layout, slot = slot }
    end
  end
end

-- Target-side hover (draft in flight). Same engagedId-priority state
-- machine as shiftHoverHit, type-filtered to the draft. forbidden
-- entries are skipped so cycle-blocked targets neither engage nor
-- display. Probe direction follows draft.cursorEnd: forward drafts
-- ('to') hunt for in-ports on candidate destinations; backward redrafts
-- ('from') hunt for out-ports on candidate sources.
local function dropTargetHit(nodeViews, mx, my, ox, oy, draft)
  local dir = (draft.cursorEnd == 'to') and 'in' or 'out'
  local function consume(pick)
    if pick.list then listOpenId = pick.nv.id end
    engagedId = pick.nv.id
    return pick
  end
  if engagedId and not draft.forbidden[engagedId] then
    for _, nv in ipairs(nodeViews) do
      if nv.id == engagedId then
        local layout = layoutPortRow(nv, ox, oy, dir, mx, my, draft.type)
        if listOpenId == nv.id and stillEngaged(layout, mx, my) then
          return consume{ nv = nv, layout = layout, list = layout.list,
                          slot = rowHit(layout.list.rows, mx, my) }
        end
        local pick = pickHovered(nv, layout, mx, my, dir, draft.type)
        if pick then return consume(pick) end
        break
      end
    end
    engagedId, listOpenId = nil, nil
  end
  for _, nv in ipairs(nodeViews) do
    if not draft.forbidden[nv.id] then
      local layout = layoutPortRow(nv, ox, oy, dir, mx, my, draft.type)
      local pick = pickHovered(nv, layout, mx, my, dir, draft.type)
      if pick then return consume(pick) end
    end
  end
end

-- Commit-eligibility for a draft against a target hover. The visual
-- overlay is gated separately on forbidden-only (so the spillover list
-- still opens during in-transit hover); only the mouseup commit consults
-- dropEligible, which additionally requires a concrete slot.
local function dropEligible(draft, target)
  return target ~= nil
     and target.slot ~= nil
     and not draft.forbidden[target.nv.id]
end

-- Spillover dropdown popup: filled rounded bg + outline, then row labels
-- with a hover-highlight under the matching row.
local function drawList(dl, list, highlight)
  local r = list.rect
  ImGui.DrawList_AddRectFilled(dl, r[1], r[2], r[3], r[4],
    chrome.colour('wiring.tooltip.bg'), LIST_CORNER_R)
  ImGui.DrawList_AddRect(dl, r[1], r[2], r[3], r[4],
    chrome.colour('separator'), LIST_CORNER_R, 0, 1)
  local txtCol = chrome.colour('text')
  local hlCol  = chrome.colour('wiring.node.selected')
  if uiFont then ImGui.PushFont(ctx, uiFont, uiSize) end
  for _, row in ipairs(list.rows) do
    if row == highlight then
      ImGui.DrawList_AddRectFilled(dl,
        row.x + 1, row.y, row.x + row.w - 1, row.y + row.h, hlCol)
    end
    ImGui.DrawList_AddText(dl,
      row.x + LIST_ROW_PAD_X, row.y + LIST_ROW_PAD_Y,
      txtCol, row.name)
  end
  if uiFont then ImGui.PopFont(ctx) end
end

-- Popup bg for the port-row overlay: a pale rounded rect (same CORNER_R
-- as the node body) overlapping the body's near edge so the body's near
-- rounded corners read as filled rather than canvas-coloured. Drawn
-- BEFORE the node so the body overpaints the overlap region, then the
-- port row + chips + list draw on top.
local function drawPortRowBg(dl, layout)
  local p = layout.popup
  if not p then return end
  ImGui.DrawList_AddRectFilled(dl, p[1], p[2], p[3], p[4],
    chrome.colour('wiring.tooltip.bg'), CORNER_R)
end

-- Draw the handle (if any) and every audio/midi slot. Outlines the slot
-- matching pick.slot (==). Chips render whether or not the spillover
-- list is open; the list extends perpendicular to the chip row so they
-- don't visually collide, and keeping chips visible preserves the
-- caller's mental map of which port each row stands for. The pale popup
-- bg is laid down separately by drawPortRowBg, before nodes.
local function drawPortRow(dl, pick, audioCol, idPrefix)
  local layout, highlight = pick.layout, pick.slot
  if layout.handle then drawHandle(dl, layout.handle, layout.side) end
  local hlCol    = chrome.colour('wiring.node.selected')
  local bodyFill = chrome.colour('wiring.node.' .. pick.nv.category)
  for i, s in ipairs(layout.slots) do
    if s.inBody then
      -- Body-internal kbd: fill body colour behind to overpaint the
      -- label while the gesture is live, then draw the icon. No
      -- InvisibleButton (the body's drag target owns the area) and no
      -- tooltip — the visible icon already conveys 'midi'.
      ImGui.DrawList_AddRectFilled(dl,
        s.x, s.y, s.x + s.w, s.y + s.h, bodyFill)
      drawKeyboardIcon(dl, s.x, s.y)
    else
      drawSlot(dl, s, idPrefix .. '/' .. i, audioCol)
    end
    -- Match by (kind, portIdx) rather than identity: defaultSlot
    -- returns a synthetic spec, not the layout slot, so identity would
    -- fail to highlight the midi keyboard when the cursor is over the
    -- body during a midi draft.
    if highlight and s.kind == highlight.kind
       and (s.kind ~= 'audio' or s.portIdx == highlight.portIdx) then
      ImGui.DrawList_AddRect(dl,
        s.x - SELECTED_INFLATE, s.y - SELECTED_INFLATE,
        s.x + s.w + SELECTED_INFLATE, s.y + s.h + SELECTED_INFLATE,
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

-- Distances along the (offset) segment, measured from (seg.sx, seg.sy),
-- at which the visible part begins (exits the source rect) and ends
-- (enters the target rect), plus the segment length. For parallel wires
-- the two exits are asymmetric: an offset shifting the line toward one
-- node's corner lengthens that node's exit and shortens the other's.
-- Returns nil for sub-pixel segments.
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
-- on top of the line. `placed` accumulates the rects of labels already
-- drawn this frame; the candidate starts at the minimum distance and
-- gets pushed outward along the wire until its AABB clears every entry
-- (capped at len*0.45 — past the midpoint we'd risk colliding with the
-- other end's label, so we accept the overlap there). This subsumes the
-- per-wire-group alternation and also separates labels on unrelated
-- wires sharing a node corner. Hover-tooltip shows the port name
-- (synthetic 'in N' / 'out N' until TrackFX_GetIOName lands).
local function drawWireEndLabel(dl, ax, ay, fx, fy, exitD, portIdx, portName, idStem, col, placed)
  local dx, dy = fx - ax, fy - ay
  local len = math.sqrt(dx * dx + dy * dy)
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

-- One screen segment per wireView, keyed by wireView index (= g.edges
-- index). sx/sy/ex/ey are canvas-local (caller adds origin). offX/offY
-- is the perpendicular displacement from the canonical pair centre line,
-- shared by drawWiresPass and wireExits so highlight geometry and label
-- placement can't drift from drawn geometry.
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

-- Endpoints of the end-region for one side of a wire segment, in
-- canvas-local coordinates. The region starts at the node-rect exit
-- (where the visible wire begins) and walks WIRE_END_HIT pixels inward
-- along the wire. Length is capped at 0.4*visible so short wires don't
-- overlap their two ends. Returns nil for sub-pixel or fully-occluded
-- wires (two adjacent nodes whose bodies touch).
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

-- Returns { edgeIdx, side, keptAnchor = {x,y screen} } if the cursor is
-- within WIRE_END_HIT_PERP of one of the two end-regions across all
-- wires; nil otherwise. Closest wins on ties. keptAnchor is the screen-
-- space position of the OTHER end's node-edge endpoint — the redraft
-- gesture pins the wire there while the cursor drives the grabbed end.
local function wireEndHit(segs, mx, my, ox, oy)
  local best, bestDist
  for i, seg in pairs(segs) do
    for _, side in ipairs({ 'from', 'to' }) do
      local ax, ay, bx, by = endRegion(seg, side)
      if ax then
        local d = pointToSegmentDist(mx, my,
                    ox + ax, oy + ay, ox + bx, oy + by)
        if d <= WIRE_END_HIT_PERP and (not bestDist or d < bestDist) then
          best = {
            edgeIdx    = i,
            side       = side,
            keptAnchor = (side == 'from')
              and { x = ox + seg.ex, y = oy + seg.ey }
              or  { x = ox + seg.sx, y = oy + seg.sy },
          }
          bestDist = d
        end
      end
    end
  end
  return best
end

-- opts.skipEdgeIdx: don't draw this wire (used when redrafting it, since
-- the in-flight draft line replaces it). The wire-end highlight is
-- drawn separately by drawWireEndHighlight after the node pass — nodes
-- overpaint wires here, so an in-pass highlight would be invisible.
local function drawWiresPass(dl, segs, wireViews, ox, oy, audioCol, midiCol, opts)
  opts = opts or {}
  local skip = opts.skipEdgeIdx
  local placedLabels = {}
  for i = 1, #wireViews do
    local seg = segs[i]
    if seg and i ~= skip then
      local w  = seg.w
      local sx, sy = ox + seg.sx, oy + seg.sy
      local ex, ey = ox + seg.ex, oy + seg.ey
      local col = w.type == 'midi' and midiCol or audioCol
      ImGui.DrawList_AddLine(dl, sx, sy, ex, ey, col, WIRE_THICK)
      drawWireArrow(dl, sx, sy, ex, ey, col)
      if w.type == 'audio' then
        local fromD, toD, segLen = wireExits(seg)
        if fromD then
          local stem = '##wire/' .. w.from .. ':' .. w.fromPort
                            .. '->' .. w.to   .. ':' .. w.toPort
          if w.fromPort ~= 1 then
            drawWireEndLabel(dl, sx, sy, ex, ey, fromD,
              w.fromPort, w.fromPortName, stem .. '/from', col,
              placedLabels)
          end
          if w.toPort ~= 1 then
            drawWireEndLabel(dl, ex, ey, sx, sy, segLen - toD,
              w.toPort, w.toPortName, stem .. '/to', col,
              placedLabels)
          end
        end
      end
    end
  end
end

local function drawWireEndHighlight(dl, segs, ox, oy, hover)
  if not hover then return end
  local seg = segs[hover.edgeIdx]
  if not seg then return end
  local ax, ay, bx, by = endRegion(seg, hover.side)
  if not ax then return end
  ImGui.DrawList_AddLine(dl,
    ox + ax, oy + ay, ox + bx, oy + by,
    chrome.colour('wiring.node.selected'), WIRE_END_HIGHLIGHT)
end

-- Compute the draft wire's cursor-end screen position. Decay ratchets
-- on furthest travel from the grab point so dragging back toward the
-- start doesn't re-inflate the offset. Hit-target detection consumes
-- this point so the wire end (not the cursor) is what activates a
-- target node / port: a redraft started with the wire end on the
-- original target naturally reads as still pointing there, and
-- detaches as soon as the decayed end leaves that node.
local function computeDraftEnd(draft, mx, my)
  if not draft.grabDx then return mx, my end
  local tdx, tdy = mx - draft.mx0, my - draft.my0
  local travel = math.sqrt(tdx * tdx + tdy * tdy)
  draft.maxTravel = math.max(draft.maxTravel or 0, travel)
  local decay = math.max(0, 1 - draft.maxTravel / WIRE_GRAB_DECAY)
  return mx + draft.grabDx * decay, my + draft.grabDy * decay
end

-- In-flight draft wire. Drawn last of all (after chips and spillover
-- list) so the user always sees the wire they're dragging on top of
-- every popout decoration — existing wires sit below the popout sleeve
-- by contrast, so only the draft punches through.
-- (cx, cy) is the cursor-end position computed by computeDraftEnd
-- (decayed and possibly pinned to the original endpoint). The kept end
-- is anchored at keptAnchor (slot centre captured at gesture start, or
-- the wire's node-edge endpoint for redrafts); body-default port 1
-- forward drafts have no anchor, so we fall back to the node centre.
-- Arrow direction follows cursorEnd: 'to' draws kept→cursor (forward),
-- 'from' draws cursor→kept (backward).
local function drawDraftWire(dl, draft, nodesById, ox, oy, cx, cy,
                             audioCol, midiCol)
  if not draft then return end
  local src = nodesById[draft.keptId]
  if not src then return end
  local col = draft.type == 'midi' and midiCol or audioCol
  local a   = draft.keptAnchor
  local ax  = a and a.x or (ox + src.pos.x)
  local ay  = a and a.y or (oy + src.pos.y)
  local sx, sy, ex, ey
  if draft.cursorEnd == 'to' then
    sx, sy, ex, ey = ax, ay, cx, cy
  else
    sx, sy, ex, ey = cx, cy, ax, ay
  end
  ImGui.DrawList_AddLine(dl, sx, sy, ex, ey, col, WIRE_THICK)
  drawWireArrow(dl, sx, sy, ex, ey, col)
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

-- nodeUnderMouse keyed to an arbitrary screen point (the decayed draft
-- wire end, typically) rather than the live cursor.
local function nodeAtPoint(nodeViews, px, py, ox, oy)
  for _, nv in ipairs(nodeViews) do
    local lx0, ly0, lx1, ly1 = nodeRect(nv)
    if px >= ox + lx0 and px <= ox + lx1
       and py >= oy + ly0 and py <= oy + ly1 then
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
  -- Releasing shift drops sticky — the pinned port-row overlay only
  -- lives within a single shift press.
  if shiftHeld and not shiftWas then wv:setSelection{} end
  if shiftWas and not shiftHeld then sticky = nil end
  shiftWas = shiftHeld
  if hoverFreeze and (hoverFreeze.x ~= mx or hoverFreeze.y ~= my) then
    hoverFreeze = nil
  end

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

  -- Wire geometry: segs is computed once and shared by the draw pass
  -- and the wire-end hit-test so highlight geometry cannot drift from
  -- drawn geometry. Existing wires draw at the very bottom of the
  -- canvas stack so popout sleeves cleanly occlude them; the in-flight
  -- draft wire draws at the very top so it always reads above the popout.
  local audioCol = chrome.colour('wiring.port.audio')
  local midiCol  = chrome.colour('wiring.port.midi')
  local wireViewsList = wv:wireViews()
  local segs = wireSegments(wireViewsList, nodesById)

  -- Wire-end hover: unmodified mouse near a wire's end-region. Suppressed
  -- during any active gesture so the highlight never fires under a drag.
  local wireEndHover
  if not drag and not band and not wireDraft and not shiftHeld then
    wireEndHover = wireEndHit(segs, mx, my, ox, oy)
  end

  -- Decayed wire-end position drives both the draft visual and the
  -- hit-target / drop-eligibility checks below, so the user can aim
  -- with the wire end rather than the cursor.
  local draftCx, draftCy
  if wireDraft then
    draftCx, draftCy = computeDraftEnd(wireDraft, mx, my)
  end

  -- Wire-creation hover state: source-side while shift is held with no
  -- draft in flight; target-side while a draft is in flight (shift may
  -- have been released). dropTargetHit returns the under-cursor node;
  -- dropEligible then refuses self / descendants / type-mismatched
  -- targets so the hover gives no visual encouragement to invalid drops.
  -- dropTargetHit already filters ancestors (cycle-blocked targets neither
  -- engage the spillover nor display). Commit-eligibility (dropEligible)
  -- additionally requires a concrete slot and is checked at mouseup.
  local sourceHit, targetHit, stickyHit, draftSourceHit
  if wireDraft then
    targetHit      = dropTargetHit(nodeViews, draftCx, draftCy,
                                   ox, oy, wireDraft)
    draftSourceHit = draftSourceHoverHit(nodeViews, ox, oy)
  elseif shiftHeld and not hoverFreeze then
    sourceHit = shiftHoverHit(nodeViews, mx, my, ox, oy)
  end
  if shiftHeld then
    stickyHit = stickyHoverHit(nodeViews, ox, oy)
  end

  -- Assemble overlays, deduped by node id so a node engaged via two paths
  -- (e.g. sticky=A + a fresh draft from A) renders one overlay with one
  -- InvisibleButton namespace. Cursor-driven picks win over persistent
  -- ones: source/target first, then draft-source, then sticky.
  local overlays  = {}
  local frontIds  = {}
  local function add(p)
    if not p or frontIds[p.nv.id] then return end
    overlays[#overlays + 1] = p
    frontIds[p.nv.id] = true
  end
  add(sourceHit)
  add(targetHit)
  add(draftSourceHit)
  add(stickyHit)

  -- Draw order: existing wires first (bottom), then popup sleeves over
  -- them (so the pale sleeve occludes wires entering the engaged node's
  -- popout area), then the in-flight draft wire (in front of the sleeve
  -- so the user always sees the wire they're dragging — even when it
  -- crosses the engaged node's popout area), then ALL nodes (overpainting
  -- both the wires and the draft at the rect edge, so wires read as
  -- emerging from behind the node body). Chips/list draw later in the
  -- overlay pass.
  drawWiresPass(dl, segs, wireViewsList, ox, oy, audioCol, midiCol,
    { skipEdgeIdx = wireDraft and wireDraft.edgeIdx })
  for _, p in ipairs(overlays) do drawPortRowBg(dl, p.layout) end
  drawDraftWire(dl, wireDraft, nodesById, ox, oy, draftCx, draftCy,
                audioCol, midiCol)
  for _, nv in ipairs(nodeViews) do
    drawNode(dl, nv, ox, oy, selection[nv.id])
  end

  -- Wire-end highlight: drawn after the node pass so the accent stroke
  -- sits on top of the node body's near-edge region (the wire-end region
  -- begins at the node-rect exit, but anti-aliasing can spill onto the
  -- body's corner; we overpaint to keep the highlight crisp).
  drawWireEndHighlight(dl, segs, ox, oy, wireEndHover)

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

  -- Overlay pass: body outline + port row + optional spillover list for
  -- each engaged node. sourceHit highlights the directly-hovered slot;
  -- targetHit highlights the draft's drop target (default port 1 / midi
  -- by draft type); stickyHit shows the persistent pinned overlay with
  -- its default slot. The nv.id-keyed idPrefix keeps InvisibleButtons
  -- unique across multiple simultaneous overlays.
  for _, p in ipairs(overlays) do
    -- Body outline marks "the default audio port is the selected slot" —
    -- the slot is a default-port synthetic (no screen rect). Chip hits
    -- carry their own highlight; chevron hits (slot=nil) leave the body
    -- unmarked. Midi defaults are excluded: the body-internal kbd carries
    -- its own highlight (drawPortRow matches by kind), so during a midi
    -- draft / midi redraft the node body stays unhighlighted and only
    -- the keyboard lights up.
    if p.slot and not p.slot.x and p.slot.kind ~= 'midi' then
      drawBodyOutline(dl, p.nv, ox, oy)
    end
    drawPortRow(dl, p, audioCol, '##portSlot/' .. p.nv.id)
    if p.list then drawList(dl, p.list, p.slot) end
  end

  wv:setHover((sourceHit and sourceHit.nv.id)
              or (targetHit and targetHit.nv.id) or nil)

  -- Esc cancels an in-flight draft. Consume the press so the wiring-scope
  -- wiringClearSelection (also bound to Esc) doesn't run on the same key.
  if wireDraft and ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
    wireDraft = nil
  end

  -- Mousedown precedence: shift-hover wins (starts a new wire); wire-end
  -- hover next (starts a redraft); body hit falls through to drag-to-move;
  -- anything else starts a band.
  if not drag and not band and not wireDraft
      and ImGui.IsMouseClicked(ctx, 0) then
    -- Any click closes the spillover; re-opening requires another chevron
    -- hover. The pre-click sourceHit (computed above with the still-open
    -- list) is what drives wire-start / pin dispatch in this branch.
    listOpenId = nil
    if sourceHit then
      local slot = sourceHit.slot
      if slot then
        -- List-row drag: pin the port so a chip materialises in the
        -- band, then re-layout and rebind slot to the new chip. The
        -- wire then anchors at that chip rather than the row (which
        -- sits in menu-space, often far from the node body); the chip
        -- persists after the gesture, so subsequent shift-hovers see it
        -- without needing to reopen the menu.

        if sourceHit.list and slot.kind == 'audio' and slot.portIdx >= 2 then
          local nv = sourceHit.nv
          pinned[nv.id] = pinned[nv.id] or {}
          pinned[nv.id][slot.portIdx] = true
          local relaid = layoutPortRow(nv, ox, oy, 'out', mx, my, nil,
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
          mx0 = mx, my0 = my,
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
      -- Cursor-end screen position at the grab moment; grabDx/grabDy is
      -- the gap to the mouse, decayed over WIRE_GRAB_DECAY px of travel
      -- so the wire end doesn't snap to the cursor at gesture start.
      local endX = ox + (keptIsTo and seg.sx or seg.ex)
      local endY = oy + (keptIsTo and seg.sy or seg.ey)
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
        mx0 = mx, my0 = my,
        grabDx = endX - mx, grabDy = endY - my,
        fromList   = false,
        edgeIdx    = wireEndHover.edgeIdx,
        -- The node + port the cursor end was attached to. Each frame
        -- computeDraftEnd checks whether the (decayed) wire end still
        -- lies inside this node's bbox; while it does, the wire end is
        -- pinned to the original endpoint and mouseup is a no-op.
        originalTargetId = keptIsTo and w.from or w.to,
        originalPort     = (w.type == 'audio')
                             and (keptIsTo and w.fromPort or w.toPort) or nil,
      }
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
    local moved = math.abs(mx - wireDraft.mx0) >= CLICK_THRESH
               or math.abs(my - wireDraft.my0) >= CLICK_THRESH
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
            type = wireDraft.type,
            from = wireDraft.keptId, fromPort = wireDraft.keptPort,
            to   = targetHit.nv.id,
            toPort = port,
          }
        end
      elseif wireDraft.edgeIdx
             and not nodeAtPoint(nodeViews, draftCx, draftCy, ox, oy) then
        -- Redraft dropped on empty canvas deletes the wire. Empty-canvas
        -- is judged by the wire end, not the cursor. Ineligible-target
        -- drops (forbidden node, no slot under wire end) fall through to
        -- the cancel path below.
        wv:removeWireAt(wireDraft.edgeIdx)
      end
      hoverFreeze = { x = mx, y = my }
    elseif wireDraft.fromList and wireDraft.type == 'audio'
           and wireDraft.keptPort and wireDraft.keptPort >= 2 then
      -- Click-without-drag on a list row: pin the port as a chip so the
      -- user can drag from it like any other chip on subsequent gestures.
      -- Sticky keeps the source node's port row visible after the click,
      -- until shift-release or until natural hover returns to this node.
      pinned[wireDraft.keptId] = pinned[wireDraft.keptId] or {}
      pinned[wireDraft.keptId][wireDraft.keptPort] = true
      sticky = { nodeId = wireDraft.keptId, side = wireDraft.keptSide }
    end
    wireDraft  = nil
    listOpenId = nil   -- close any target-side spillover that was open
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
function wp:unbind()
  drag, band, wireDraft, shiftWas = nil, nil, nil, false
  listOpenId, sticky, engagedId, hoverFreeze = nil, nil, nil, nil
end

--contract: turn on live recompile — every wiringChanged drives a diff+apply, plus one immediate reconcile pass to sync REAPER with the persisted graph at boot. Idempotent. Called once from continuum after registration.
function wp:enableLive() wv:enableLive() end

--contract: per-frame poll; drives wm:pollUndo to detect REAPER undo/redo of wiring gestures (scratch P_EXT divergence) and re-issue wiringChanged{kind='load'}. Called from coordinator.frame regardless of which page is active.
function wp:tick() wv:pollUndo() end

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

-- Place an auto-spawned source on the master→cursor ray, pushed past the
-- generator (away from master) just far enough that the two body rects
-- don't collide along the ray. Degenerate (cursor on master): fall back to
-- a horizontal offset.
local SOURCE_PAD = 24
local function sourcePosFor(genX, genY)
  local mxp, myp = findMasterPos()
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
