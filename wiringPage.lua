-- See docs/wiringPage.md for the model.
-- @noindex

--invariant: render + input only — wiringPage draws the canvas and reads keyboard / mouse. It holds no wm reference: every graph query goes through wv, every mutation will go through wv (the manager-facing surface).
--invariant: wiring page is project-wide — bind() takes no take and never re-keys cm; the tracker take and the sampler track are unaffected by switching to / from wiring.
--invariant: the page owns every pixel — node-box geometry, port slot layout, hit-test boxes are all derived here from wv's viewport-independent nodeViews. wv carries label + category + audio/MIDI counts; the page turns those into rects and tints.
--invariant: at Stage 1.3d the page draws wires as a pre-pass before nodes — centre-to-centre lines occluded by the rounded rects, midpoint arrow for orientation, parallel wires in the same unordered pair offset perpendicularly with MIDI sorted to the right, non-1 audio ports labelled by number with hover-tooltip names. add-fx / drag / rubber-band unchanged; shift-gated port-row hover drives wire creation — per-face layout is [handle ▾][audio chips for ports 2..N centred][midi keyboard], handle pinned to left corner, midi to right corner. body-default = port 1; audio chips render for ports 2..N when N ≤ PORTS_PER_ROW; past that, chips appear only for currently-wired and user-pinned ports while the rest live in the handle's dropdown. top/bottom faces only. See design/wiring.md.

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
local PORTS_PER_ROW    = 4   -- audio rows wrap after this many ports
local MIDI_SLOT_W      = 13  -- keyboard slot is wider/taller than the audio
local MIDI_SLOT_H      = 11  -- 8×8 square; intrinsic icon dimensions
local MIDI_INSET       = 3   -- px between midi icon and popup-right rounded corner
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
local wireDraft = nil  -- { type='audio'|'midi', fromId, fromPort?, ancestors, mx0, my0, fromList, fromAnchor? }
local shiftWas  = false
-- Per-node set of audio port indices the user has explicitly pinned via
-- click-without-drag on a list row. Persists across binds but not across
-- project loads (page-local; future work to lift this into wm so it
-- round-trips with the graph).
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
-- Same envelope as the midi keyboard so the two corner chips read as
-- mirrored. Inert at Slice A1 — A2 wires the hover-dropdown. The band-
-- level bg rect drawn by drawPortRow handles wire occlusion.
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
-- for ports 2..N centred (port 1 lives on the body itself, no chip), midi
-- keyboard pinned to the right. Audio chips render for ports 2..N when
-- N ≤ PORTS_PER_ROW; past that the band shows only currently-wired and
-- user-pinned ports (chip promotion — design/wiring.md). hoverRect =
-- body ∪ slot/handle hit pads, so cursor traversal between zones keeps
-- the hover live. keep
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
    for r = 0, nRows - 1 do
      local first = r * PORTS_PER_ROW + 1
      local last  = math.min(first + PORTS_PER_ROW - 1, nChips)
      local rowN  = last - first + 1
      local rowW  = rowN * PORT_SIZE + (rowN - 1) * PORT_GAP
      local startX = math.floor((bx0 + bx1 - rowW) / 2)
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
    local s = { kind = 'midi', name = midi[1],
                x = bx1 - MIDI_SLOT_W - MIDI_INSET,
                w = MIDI_SLOT_W, h = MIDI_SLOT_H }
    placeOnRow(s)
    slots[#slots + 1] = s
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
  for _, s in ipairs(slots) do extend(s) end
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
local function draftSourceHoverHit(nodeViews, ox, oy)
  if not wireDraft then return nil end
  for _, nv in ipairs(nodeViews) do
    if nv.id == wireDraft.fromId then
      local layout = layoutPortRow(nv, ox, oy, 'out', 0, 0, nil,
                                   wireDraft.fromSide)
      return { nv = nv, layout = layout,
               slot = findLayoutSlot(layout, wireDraft.type,
                                     wireDraft.fromPort) }
    end
  end
end

-- Target-side hover (draft in flight). Same engagedId-priority state
-- machine as shiftHoverHit, type-filtered to the draft. Ancestors are
-- skipped so cycle-blocked targets neither engage nor display.
local function dropTargetHit(nodeViews, mx, my, ox, oy, draft)
  local function consume(pick)
    if pick.list then listOpenId = pick.nv.id end
    engagedId = pick.nv.id
    return pick
  end
  if engagedId and not draft.ancestors[engagedId] then
    for _, nv in ipairs(nodeViews) do
      if nv.id == engagedId then
        local layout = layoutPortRow(nv, ox, oy, 'in', mx, my, draft.type)
        if listOpenId == nv.id and stillEngaged(layout, mx, my) then
          return consume{ nv = nv, layout = layout, list = layout.list,
                          slot = rowHit(layout.list.rows, mx, my) }
        end
        local pick = pickHovered(nv, layout, mx, my, 'in', draft.type)
        if pick then return consume(pick) end
        break
      end
    end
    engagedId, listOpenId = nil, nil
  end
  for _, nv in ipairs(nodeViews) do
    if not draft.ancestors[nv.id] then
      local layout = layoutPortRow(nv, ox, oy, 'in', mx, my, draft.type)
      local pick = pickHovered(nv, layout, mx, my, 'in', draft.type)
      if pick then return consume(pick) end
    end
  end
end

-- Commit-eligibility for a draft against a target hover. The visual
-- overlay is gated separately on ancestor-only (so the spillover list
-- still opens during in-transit hover); only the mouseup commit consults
-- dropEligible, which additionally requires a concrete slot.
local function dropEligible(draft, target)
  return target ~= nil
     and target.slot ~= nil
     and not draft.ancestors[target.nv.id]
end

-- Spillover dropdown popup: filled rounded bg + outline, then row labels
-- with a hover-highlight under the matching row.
local function drawList(dl, list, highlight)
  local r = list.rect
  ImGui.DrawList_AddRectFilled(dl, r[1], r[2], r[3], r[4],
    chrome.colour('wiring.tooltip.bg'), LIST_CORNER_R)
  ImGui.DrawList_AddRect(dl, r[1], r[2], r[3], r[4],
    chrome.colour('wiring.node.selected'), LIST_CORNER_R, 0, 1)
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
-- matching pick.slot (==). When the spillover list is open (pick.list
-- non-nil), audio chips are suppressed — the list carries the same info
-- more legibly while the user is browsing by name; the midi slot stays.
-- The pale popup bg is laid down separately by drawPortRowBg, before nodes.
local function drawPortRow(dl, pick, audioCol, idPrefix)
  local layout, highlight, listOpen =
    pick.layout, pick.slot, pick.list ~= nil
  if layout.handle then drawHandle(dl, layout.handle, layout.side) end
  local hlCol = chrome.colour('wiring.node.selected')
  for i, s in ipairs(layout.slots) do
    if not (listOpen and s.kind == 'audio') then
      drawSlot(dl, s, idPrefix .. '/' .. i, audioCol)
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
  -- dropTargetHit already filters ancestors (cycle-blocked targets neither
  -- engage the spillover nor display). Commit-eligibility (dropEligible)
  -- additionally requires a concrete slot and is checked at mouseup.
  local sourceHit, targetHit, stickyHit, draftSourceHit
  if wireDraft then
    targetHit      = dropTargetHit(nodeViews, mx, my, ox, oy, wireDraft)
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

  -- Draw order: non-front nodes, then popup bgs, then front nodes. The
  -- popup sits above adjacent nodes that happen to fall under its extent,
  -- but the focus node still overpaints the popup's overlap region so the
  -- focus body's near rounded corners read as filled.
  for _, nv in ipairs(nodeViews) do
    if not frontIds[nv.id] then drawNode(dl, nv, ox, oy, selection[nv.id]) end
  end
  for _, p in ipairs(overlays) do drawPortRowBg(dl, p.layout) end
  for _, nv in ipairs(nodeViews) do
    if frontIds[nv.id] then drawNode(dl, nv, ox, oy, selection[nv.id]) end
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

  -- Overlay pass: body outline + port row + optional spillover list for
  -- each engaged node. sourceHit highlights the directly-hovered slot;
  -- targetHit highlights the draft's drop target (default port 1 / midi
  -- by draft type); stickyHit shows the persistent pinned overlay with
  -- its default slot. The nv.id-keyed idPrefix keeps InvisibleButtons
  -- unique across multiple simultaneous overlays.
  for _, p in ipairs(overlays) do
    drawBodyOutline(dl, p.nv, ox, oy)
    drawPortRow(dl, p, audioCol, '##portSlot/' .. p.nv.id)
    if p.list then drawList(dl, p.list, p.slot) end
  end

  -- In-flight draft wire: drawn after the overlay pass so the gesture
  -- floats above any open port-row popout and over body edges. Start
  -- point is the slot centre captured at mousedown (fromAnchor) when the
  -- gesture started on a concrete chip / midi keyboard; for body-default
  -- port 1 there is no chip, so we fall back to the node centre.
  -- Endpoint is the raw cursor.
  if wireDraft then
    local src = nodesById[wireDraft.fromId]
    if src then
      local col = wireDraft.type == 'midi' and midiCol or audioCol
      local a   = wireDraft.fromAnchor
      local sx  = a and a.x or (ox + src.pos.x)
      local sy  = a and a.y or (oy + src.pos.y)
      ImGui.DrawList_AddLine(dl, sx, sy, mx, my, col, WIRE_THICK)
      drawWireArrow(dl, sx, sy, mx, my, col)
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
    -- Any click closes the spillover; re-opening requires another chevron
    -- hover. The pre-click sourceHit (computed above with the still-open
    -- list) is what drives wire-start / pin dispatch in this branch.
    listOpenId = nil
    if sourceHit then
      local slot = sourceHit.slot
      if slot then
        local anc = wv:ancestorsOf(sourceHit.nv.id)
        -- defaultSlot (body-default port 1) has no screen rect; leave
        -- fromAnchor nil so the draft falls back to the node centre.
        local fromAnchor
        if slot.x then
          fromAnchor = { x = slot.x + slot.w / 2, y = slot.y + slot.h / 2 }
        end
        local base = { fromId = sourceHit.nv.id, ancestors = anc,
                       mx0 = mx, my0 = my, fromList = sourceHit.list ~= nil,
                       fromSide = sourceHit.layout.side,
                       fromAnchor = fromAnchor }
        if slot.kind == 'midi' then
          base.type = 'midi'
        else
          base.type, base.fromPort = 'audio', slot.portIdx
        end
        wireDraft = base
      end
      -- slot=nil: cursor on chevron or between list rows; consume the
      -- click (no wire start, no body-drag fall-through).
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
        wv:addWire{
          type = wireDraft.type,
          from = wireDraft.fromId, fromPort = wireDraft.fromPort,
          to   = targetHit.nv.id,
          toPort = (slot.kind == 'audio') and slot.portIdx or nil,
        }
      end
      hoverFreeze = { x = mx, y = my }
    elseif wireDraft.fromList and wireDraft.type == 'audio'
           and wireDraft.fromPort and wireDraft.fromPort >= 2 then
      -- Click-without-drag on a list row: pin the port as a chip so the
      -- user can drag from it like any other chip on subsequent gestures.
      -- Sticky keeps the source node's port row visible after the click,
      -- until shift-release or until natural hover returns to this node.
      pinned[wireDraft.fromId] = pinned[wireDraft.fromId] or {}
      pinned[wireDraft.fromId][wireDraft.fromPort] = true
      sticky = { nodeId = wireDraft.fromId, side = wireDraft.fromSide }
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
