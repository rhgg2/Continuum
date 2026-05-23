-- See docs/arrangePage.md for the model.
-- @noindex

--invariant: render + input only — arrangePage draws the grid and palette and reads keyboard / mouse. It holds no am reference: every project query and every state mutation goes through av.
--invariant: arrange page is project-wide — bind() takes no take and never re-keys cm; the tracker take and the sampler track are unaffected by switching to / from arrange.
--invariant: the arrange scope's key bindings live here; the command bodies live in av. coord pushes the scope on activation. Names overlap the tracker scope's arrow commands but scopes don't stack — only one is active at a time. createSlot is registered here too — it drives this page's modal.
--invariant: body splits horizontally into a grid pane (variable width) and a fixed-width palette pane (PALETTE_W). The palette shows slots for the focused track, i.e. the track under av:cursorCol() — no separate "focused track" pointer.

local util = require 'util'

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'

local cm, cmgr, chrome, gui, onDive, onTakeProperties, modalHost =
  (...).cm, (...).cmgr, (...).chrome, (...).gui, (...).onDive, (...).onTakeProperties, (...).modalHost

local ctx = gui and gui.ctx or nil
-- gui.font is monospace (Source Code Pro) attached at context create;
-- we push it for the slot-key cell so 62 base62 keys align in a column.
local monoFont = gui and gui.font or nil
local uiSize   = gui and gui.fontSize and gui.fontSize.ui or 12

local av = util.instantiate('arrangeView',
  { cm = cm, cmgr = cmgr, onDive = onDive, onTakeProperties = onTakeProperties })

local ap = {}

local PALETTE_W = 200
-- Gap between grid and palette panes; the 1px vrule sits in the
-- middle of the gap so neither pane edge touches the line.
local PANE_GAP  = 11
local QN_W, TRACK_W = 32, 72
-- Empty band between the gutter numbers and the first vertical
-- gridline. Numbers stay right-aligned at QN_W; the first track
-- column starts QN_W + GUTTER_PAD pixels in.
local GUTTER_PAD = 8
-- The loop bracket — the tracker's tail `[` — strokes down the left edge
-- of the grid; the whole grid shifts LOOP_PAD pixels right to clear it.
-- Must exceed the bracket radius (5) plus its 1.5px stroke.
local LOOP_PAD = 7
-- Palette row column widths: monospace key, kind glyph, name fills.
local SLOT_KEY_W, SLOT_KIND_W = 18, 16

-- Forward decl: runGridMouse (in renderGrid below) calls openCreateModal, defined further down.
local openCreateModal

--shape: press = { qn, row, col, take, mode = 'move'|'resizeEnd', duplicate, moved, gutter, create } — mouse-down snapshot, nil when no button is down over the grid. A track-column press carries `take`/`row`/`col`/`mode`; a QN-gutter press carries `qn` and `gutter = true` only; an empty-space double-click carries `qn`/`col` and `create = true`. `row`/`col` is the pressed cell, applied to the cursor on a no-drag grid release; `moved` flips once ImGui's drag threshold is crossed.
--invariant: mouse drag relocates a take freely — the candidate is validated by am:startIsClear, so a drag may carry a take past a neighbour into any space whose start position is not already claimed. The moved edge snaps to a row box unless Shift is held; Alt at mouse-down duplicates instead of moving. Pressing a take focuses it. The cursor moves only on release, and only when no take was dragged — it then lands on the pressed cell; a drag (even one blocked by a start collision) leaves the cursor put. An empty-space press with no drag also clears focus.
--invariant: a press in the QN gutter drives the REAPER transport, not the grid — a no-drag release sets the edit cursor, a drag sets the loop range; both endpoints snap to row boxes unless Shift is held. The arrange grid cursor and take focus are untouched. A right-click in the gutter clears the loop range.
--invariant: a double-click on empty grid space starts a create press — the drag previews a ghost take, release opens the create modal seeded with the swept column / start row / row count. A bare double-click opens it with the default row count.
local press = nil
local WHEEL_ROWS   = 1   -- cursor rows moved per mouse-wheel notch
local wheelAccum   = 0   -- fractional wheel carried between frames
local BLOCKED_BORDER  -- lazy: red border for a drag that would overlap
local EDIT_LINE       -- lazy: REAPER edit-cursor rule across all tracks
local PLAY_LINE       -- lazy: yellow play-head rule
local CREATE_GHOST    -- lazy { fill, border }: double-click-drag take preview

----- Style + draw helpers

local function pushBodyStyles()
  ImGui.PushStyleColor(ctx, ImGui.Col_Text,             chrome.colour('text'))
  ImGui.PushStyleColor(ctx, ImGui.Col_TableHeaderBg,    chrome.colour('bg'))
  ImGui.PushStyleColor(ctx, ImGui.Col_TableRowBg,       chrome.colour('bg'))
  ImGui.PushStyleColor(ctx, ImGui.Col_TableRowBgAlt,    chrome.colour('bg'))
  ImGui.PushStyleColor(ctx, ImGui.Col_TableBorderLight, chrome.colour('separator'))
  ImGui.PushStyleColor(ctx, ImGui.Col_TableBorderStrong,chrome.colour('separator'))
end
local function popBodyStyles() ImGui.PopStyleColor(ctx, 6) end

-- Row label = QN at the row's top edge. beatPerRow is integer-valued
-- in normal use (1, 4, 8, 16); show the QN as an integer.
local function rowLabel(row)
  return string.format('%4d', math.floor(av:rowToQN(row) + 0.5))
end

-- Per-slot colours. Golden-ratio hue rotation gives 62 visually-distinct
-- hues without a hand-picked palette; pooled instances share a hue
-- because they share slotIdx. Orphans (slotIdx = nil) get neutral grey.
-- Each entry is a quad { fill, border, focusFill, focusBorder }: the
-- focus pair lightens the fill and brightens the border to full opacity
-- so the focused take reads as picked-out without losing its hue.
local SLOT_FILL_ALPHA = 0.85
local SLOT_BORDER_ALPHA = 0.75
local slotColourCache = {}
local ORPHAN  -- lazy { fill, border, focusFill, focusBorder }
local function slotColours(slotIdx, focused)
  local quad
  if slotIdx == nil then
    ORPHAN = ORPHAN or {
      ImGui.ColorConvertDouble4ToU32(0.50, 0.50, 0.50, 0.35),
      ImGui.ColorConvertDouble4ToU32(0.30, 0.30, 0.30, 1.0),
      ImGui.ColorConvertDouble4ToU32(0.85, 0.85, 0.85, 0.55),
      ImGui.ColorConvertDouble4ToU32(0.97, 0.97, 0.97, 1.0),
    }
    quad = ORPHAN
  else
    quad = slotColourCache[slotIdx]
    if not quad then
      local PHI = 0.6180339887498949
      local h   = ((slotIdx + 1) * PHI) % 1.0
      local function hue(s, v, a)
        local r, g, b = ImGui.ColorConvertHSVtoRGB(h, s, v)
        return ImGui.ColorConvertDouble4ToU32(r, g, b, a)
      end
      quad = {
        hue(0.55, 0.78, SLOT_FILL_ALPHA),
        hue(0.85, 0.55, SLOT_BORDER_ALPHA),
        hue(0.30, 0.97, SLOT_FILL_ALPHA),
        hue(0.92, 0.90, 1.0),
      }
      slotColourCache[slotIdx] = quad
    end
  end
  if focused then return quad[3], quad[4] end
  return quad[1], quad[2]
end

----- Grid pane (hand-drawn — ImGui tables fight row-spanning shapes)

-- Header band sits at the top of both panes (grid + palette). HEADER_PAD
-- is the breathing room above the header text; HEADER_GAP is the slim
-- band of empty space between the header divider and row 0 of the body.
-- Both panes use these constants so the dividers line up across the gap.
local HEADER_PAD = 8
local HEADER_GAP = 4

-- Snap a click's QN down to the top edge of the row box it sits in.
local function floorTo(v, step) return math.floor(v / step) * step end

local function renderGrid(tracks, nTracks)
  local dl       = ImGui.GetWindowDrawList(ctx)
  local paneLeft, oy = ImGui.GetCursorScreenPos(ctx)
  local ox           = paneLeft + LOOP_PAD
  local _, availH = ImGui.GetContentRegionAvail(ctx)
  local rowH     = math.max(1, ImGui.GetTextLineHeightWithSpacing(ctx))
  local headerH  = rowH + HEADER_PAD
  local bodyTop  = oy + headerH + HEADER_GAP
  local visRows  = math.max(1, math.floor((oy + availH - bodyTop) / rowH))
  local bodyBot  = bodyTop + visRows * rowH
  local gridW    = QN_W + GUTTER_PAD + TRACK_W * nTracks
  local gridR    = ox + gridW

  av:setGridSize(visRows, nTracks)
  av:setMaxCol(nTracks)

  local sr      = (select(1, av:scroll())) or 0

  local textCol     = chrome.colour('text')
  local sepCol      = chrome.colour('separator')
  local dividerCol  = textCol  -- matches the tracker's header divider
  -- Phrase tint reuses bar tint's hue at full opacity (rowBeat is
  -- palette.highlight at alpha 0.4) so phrases read stronger than
  -- the bars they contain.
  local barTint    = chrome.colour('rowBeat')
  local cr, cg, cb = ImGui.ColorConvertU32ToDouble4(barTint)
  local phraseTint = ImGui.ColorConvertDouble4ToU32(cr, cg, cb, 1.0)

  local function trackLeft(c)  return ox + QN_W + GUTTER_PAD + c * TRACK_W end
  local function trackRight(c) return trackLeft(c) + TRACK_W                end
  local function rowY(row)     return bodyTop + (row - sr) * rowH end

  -- Mouse: in a track column, press a take to focus it then drag — the
  -- take rides the cursor (the take pass below draws it at the
  -- candidate, not its committed position); Alt-drag duplicates. In the
  -- QN gutter, a no-drag press sets the REAPER edit cursor and a drag
  -- sets the loop range. A grid release that dragged no take moves the
  -- cursor to the pressed cell; an empty-space press clears focus. Runs
  -- before the take pass so the candidate is in hand when the pass
  -- relocates the dragged take. Returns the in-flight take drag, loop
  -- drag and create drag, each nil when not active.
  local function runGridMouse()
    local mx, my  = ImGui.GetMousePos(ctx)
    local bpr     = av:beatPerRow()
    local yToQN   = function(y) return (sr + (y - bodyTop) / rowH) * bpr end
    local gutterR = trackLeft(0)
    local snapped = ImGui.GetKeyMods(ctx) & ImGui.Mod_Shift == 0

    if ImGui.IsMouseClicked(ctx, 1) and ImGui.IsWindowHovered(ctx)
       and my >= bodyTop and my <= bodyBot
       and mx >= paneLeft and mx < gutterR then
      av:clearLoopRange()
    end
    -- Wheel scrolls by moving the cursor: a detached viewport scroll
    -- would be pulled back to the cursor by followViewport next frame.
    -- Fractional trackpad deltas accumulate; whole rows drain off.
    local wheel = ImGui.GetMouseWheel(ctx)
    if wheel ~= 0 and ImGui.IsWindowHovered(ctx) then
      wheelAccum = wheelAccum + wheel * WHEEL_ROWS
      local trunc = wheelAccum >= 0 and math.floor or math.ceil
      local rows  = trunc(wheelAccum)
      if rows ~= 0 then
        wheelAccum = wheelAccum - rows
        av:setCursor(av:cursorRow() - rows, av:cursorCol())
      end
    end
    if ImGui.IsMouseClicked(ctx, 0) and ImGui.IsWindowHovered(ctx)
       and my >= bodyTop and my <= bodyBot then
      if mx >= paneLeft and mx < gutterR then
        press = { qn = yToQN(my), gutter = true, moved = false }
      else
        local col = math.floor((mx - gutterR) / TRACK_W)
        if col >= 0 and col < nTracks then
          local row = math.min(visRows - 1, math.floor((my - bodyTop) / rowH))
          local qn = yToQN(my)
          local take, mode = av:hitTake(col, qn, bpr / rowH)
          if not take and ImGui.IsMouseDoubleClicked(ctx, 0) then
            press = { qn = floorTo(qn, bpr), col = col,
                      create = true, moved = false }
          else
            press = {
              qn = qn, row = sr + row, col = col,
              take = take, mode = mode, moved = false,
              duplicate = mode == 'move'
                          and (ImGui.GetKeyMods(ctx) & ImGui.Mod_Alt ~= 0),
            }
            -- Focus the take on press, so a drag visibly carries it.
            if take then av:setFocus(take.take) end
          end
        end
      end
    end
    if not press then return nil, nil, nil end
    if (press.take or press.gutter or press.create)
       and ImGui.IsMouseDragging(ctx, 0) then
      press.moved = true
    end

    local dragCand = (press.moved and press.take)
                     and av:dragCandidate(press, yToQN(my), snapped) or nil
    local loopCand = (press.moved and press.gutter)
                     and av:gutterLoopCand(press, yToQN(my), snapped) or nil
    local createCand = (press.moved and press.create)
                       and av:createCandidate(press, yToQN(my), snapped) or nil

    if ImGui.IsMouseReleased(ctx, 0) then
      if dragCand then
        if dragCand.fits then av:commitDrag(press, dragCand) end
      elseif loopCand then
        av:setLoopRangeQN(loopCand.loQN, loopCand.hiQN)
      elseif press.create then
        -- Sweep prefills the row count; bare double-click uses the default.
        local rows = createCand
                     and math.floor(createCand.lengthQN / bpr + 0.5) or nil
        openCreateModal(press.col, press.qn, rows)
      elseif press.gutter then
        -- Floor to the row box's top edge (not the nearest edge) unless Shift is held.
        av:setEditCursorQN(snapped and floorTo(press.qn, bpr) or press.qn)
      else
        av:setCursor(press.row, press.col)
        if not press.take then av:setFocus(nil) end
      end
      press = nil
      return nil, nil, nil
    end
    return dragCand, loopCand, createCand
  end
  local dragCand, loopCand, createCand = runGridMouse()
  local curRow, curCol = av:cursorRow(), av:cursorCol()

  -- The right border (gridline at gridR; rightmost take-rect border a
  -- px beyond) sits on the clip boundary — clip past it or it's chopped.
  ImGui.DrawList_PushClipRect(dl, paneLeft, oy, gridR + 2, oy + availH, true)

  -- Row tints (bar / phrase). Row 0 (qn = 0) is the strongest phrase
  -- boundary in the project, so it gets the phrase tint too — no qn > 0
  -- guard.
  for r = 0, visRows - 1 do
    local qn = math.floor(av:rowToQN(sr + r) + 0.5)
    local tint = (qn % 64 == 0) and phraseTint
              or (qn % 16 == 0) and barTint
              or nil
    if tint then
      ImGui.DrawList_AddRectFilled(dl,
        ox, bodyTop + r * rowH, gridR, bodyTop + (r + 1) * rowH, tint)
    end
  end

  -- Gridlines first — take rectangles occlude them within their span,
  -- and their 1px borders re-state the cell boundary at the take edge.
  -- Topmost and leftmost outer borders are intentionally omitted; verticals
  -- start at row 0, not the header band, so the header reads as open space.
  for c = 0, nTracks do
    local lx = trackLeft(c)
    ImGui.DrawList_AddLine(dl, lx, bodyTop, lx, bodyBot, sepCol, 1)
  end
  ImGui.DrawList_AddLine(dl, gridR, bodyTop, gridR, bodyBot, sepCol, 1)
  ImGui.DrawList_AddLine(dl, ox, oy + headerH,  gridR, oy + headerH,  dividerCol, 1)
  ImGui.DrawList_AddLine(dl, ox, bodyBot,       gridR, bodyBot,       sepCol, 1)
  for r = 1, visRows - 1 do
    local y = bodyTop + r * rowH
    ImGui.DrawList_AddLine(dl, ox, y, gridR, y, sepCol, 1)
  end

  -- Take rectangles, drawn on top of gridlines. Fill exactly the column
  -- (edges coincide with the gridline), 1px border, centred name. Coords
  -- snap to integer pixels so adjacent takes' borders land on the same
  -- pixel row/column and visually coincide — without the snap, fractional
  -- rowH antialiases the shared edge across two pixel rows.
  --
  -- Three passes so the cursor cell can paint between fills and names:
  -- the translucent cursor fill lies over the take fill, and names draw
  -- last so they stay crisp over it.
  local function snap(v) return math.floor(v + 0.5) end
  local focusHandle = av:focus()
  local nameDraws = {}
  local truncDraws = {}   -- ellipsis decoration for items truncated below natural

  -- One take rectangle at an arbitrary QN range: fill, 1px border,
  -- name queued for the final pass. Focus reads as the slot's focus
  -- colours, not a thicker border. `blocked` paints the border red —
  -- a drag whose candidate range overlaps another take.
  local function drawTakeRect(tk, startQN, lengthQN, focused, blocked)
    local startRow = av:qnToRow(startQN)
    local endRow   = av:qnToRow(startQN + lengthQN)
    if endRow <= sr or startRow >= sr + visRows then return end
    local rx0, rx1 = snap(trackLeft(tk.trackIdx)), snap(trackRight(tk.trackIdx))
    local ry0 = snap(rowY(math.max(startRow, sr)))
    local ry1 = snap(rowY(math.min(endRow, sr + visRows)))
    local fill, border = slotColours(tk.slotIdx, focused)
    if blocked then
      BLOCKED_BORDER = BLOCKED_BORDER
        or ImGui.ColorConvertDouble4ToU32(0.80, 0.16, 0.16, 0.95)
      border = BLOCKED_BORDER
    end
    ImGui.DrawList_AddRectFilled(dl, rx0+1, ry0+1, rx1, ry1, fill)
    ImGui.DrawList_AddRect(dl, rx0, ry0, rx1+1, ry1+1, border, 0, 0, 1)
    if tk.name and tk.name ~= '' then
      nameDraws[#nameDraws + 1] = {
        name = tk.name, rx0 = rx0, rx1 = rx1, ry0 = ry0, ry1 = ry1,
      }
    end
    -- Truncation indicator: a downstream take is cutting this one short of
    -- its natural extent. Show only when the box is tall enough to spare a
    -- bottom row — a single-row box would lose its name to the ellipsis.
    if lengthQN + 1e-6 < tk.naturalLenQN and endRow - startRow > 1 then
      truncDraws[#truncDraws + 1] = { rx0 = rx0, rx1 = rx1, ry1 = ry1 }
    end
  end

  -- Settled takes; the dragged take is held back (a move would draw it
  -- twice) and painted last, on top, at its candidate range. A
  -- duplicate keeps its original here and adds the copy after.
  for c = 0, nTracks - 1 do
    for _, tk in ipairs(av:tracksTakes(c)) do
      local relocating = dragCand and not press.duplicate
                         and tk.item == press.take.item
      if not relocating then
        drawTakeRect(tk, tk.startQN, tk.lengthQN, tk.take == focusHandle)
      end
    end
  end
  if dragCand then
    drawTakeRect(press.take, dragCand.startQN, dragCand.lengthQN,
                 true, not dragCand.fits)
  end

  -- Ghost preview of the take the in-flight double-click-drag will create.
  if createCand then
    local startRow = av:qnToRow(createCand.startQN)
    local endRow   = av:qnToRow(createCand.startQN + createCand.lengthQN)
    if endRow > sr and startRow < sr + visRows then
      CREATE_GHOST = CREATE_GHOST or {
        fill   = ImGui.ColorConvertDouble4ToU32(0.95, 0.93, 0.80, 0.35),
        border = ImGui.ColorConvertDouble4ToU32(0.45, 0.42, 0.30, 0.90),
      }
      local gx0 = snap(trackLeft(press.col))
      local gx1 = snap(trackRight(press.col))
      local gy0 = snap(rowY(math.max(startRow, sr)))
      local gy1 = snap(rowY(math.min(endRow, sr + visRows)))
      ImGui.DrawList_AddRectFilled(dl, gx0+1, gy0+1, gx1, gy1, CREATE_GHOST.fill)
      ImGui.DrawList_AddRect(dl, gx0, gy0, gx1+1, gy1+1, CREATE_GHOST.border, 0, 0, 1)
    end
  end

  -- Cursor caret — a horizontal I-beam on the top edge of the cursor
  -- row, spanning the column. Cursor position is a line, not a cell:
  -- mere movement doesn't pick a take, so a cell-shaped highlight
  -- would lie about the model.
  if curRow >= sr and curRow < sr + visRows
     and curCol >= 0 and curCol < nTracks then
    local cx0   = snap(trackLeft(curCol))
    local cx1   = snap(trackRight(curCol))
    local cy    = snap(rowY(curRow))
    local serif = 4
    local col   = chrome.colour('arrangeCursorBorder')
    ImGui.DrawList_AddLine(dl, cx0 + 1, cy, cx1-1,     cy,        col, 2)
    ImGui.DrawList_AddLine(dl, cx0 + 1, cy - serif,  cx0 +1, cy + serif, col, 2)
    ImGui.DrawList_AddLine(dl, cx1, cy - serif,  cx1, cy + serif, col, 2)
  end

  -- Loop region — the tracker's tail bracket: a stroked `[` down the
  -- left of the gutter, chrome 'tail' colour, no fill. An in-flight
  -- gutter drag preempts the committed range so the bracket tracks the
  -- mouse before release.
  local loopLo, loopHi
  if loopCand then
    loopLo, loopHi = loopCand.loQN, loopCand.hiQN
  else
    loopLo, loopHi = av:loopRangeQN()
  end
  if loopLo then
    local loTop, loBot = av:qnToRow(loopLo), av:qnToRow(loopHi)
    if loBot > sr and loTop < sr + visRows then
      local r  = 5
      local x1 = paneLeft + 1 + r
      local y1, y2 = snap(rowY(loTop)), snap(rowY(loBot))
      ImGui.DrawList_PathClear(dl)
      ImGui.DrawList_PathArcTo(dl, x1, y1 + r, r, 3 * math.pi / 2, math.pi)
      ImGui.DrawList_PathLineTo(dl, x1 - r, y1 + r + 1)
      ImGui.DrawList_PathLineTo(dl, x1 - r, y2 - r - 1)
      ImGui.DrawList_PathArcTo(dl, x1, y2 - r, r, math.pi, math.pi / 2)
      ImGui.DrawList_PathStroke(dl, chrome.colour('tail'), ImGui.DrawFlags_None, 1.5)
      ImGui.DrawList_PathClear(dl)
    end
  end

  -- Take names — last, so they stay crisp over the translucent cursor
  -- fill.
  for _, nd in ipairs(nameDraws) do
    local tw = ImGui.CalcTextSize(ctx, nd.name)
    local tx = nd.rx0 + math.floor((nd.rx1 - nd.rx0 - tw) / 2)
    ImGui.DrawList_PushClipRect(dl, nd.rx0 + 2, nd.ry0, nd.rx1 - 2, nd.ry1, true)
    ImGui.DrawList_AddText(dl, tx, nd.ry0 + 1, textCol, nd.name)
    ImGui.DrawList_PopClipRect(dl)
  end

  -- Truncation ellipsis — bottom-row glyph for items the relayout pass
  -- shortened below their natural length. Same final-pass treatment as
  -- names so it sits over the cursor fill.
  for _, td in ipairs(truncDraws) do
    local ell = '…'
    local tw  = ImGui.CalcTextSize(ctx, ell)
    local tx  = td.rx0 + math.floor((td.rx1 - td.rx0 - tw) / 2)
    local ty  = td.ry1 - rowH + 1
    ImGui.DrawList_PushClipRect(dl, td.rx0 + 2, ty, td.rx1 - 2, td.ry1, true)
    ImGui.DrawList_AddText(dl, tx, ty, textCol, ell)
    ImGui.DrawList_PopClipRect(dl)
  end

  -- Edit cursor + play head — full-width rules on top of takes and
  -- names. The play head is yellow and drawn only while the transport
  -- runs; the grid clip rect already in force trims an off-screen rule.
  local function qnRule(qn, colour)
    local y = snap(rowY(av:qnToRow(qn)))
    ImGui.DrawList_AddLine(dl, ox, y, gridR, y, colour, 1)
  end
  EDIT_LINE = EDIT_LINE
    or ImGui.ColorConvertDouble4ToU32(0.20, 0.20, 0.26, 0.85)
  qnRule(av:editCursorQN(), EDIT_LINE)
  local playQN = av:playPositionQN()
  if playQN then
    PLAY_LINE = PLAY_LINE
      or ImGui.ColorConvertDouble4ToU32(1.00, 0.85, 0.10, 0.95)
    qnRule(playQN, PLAY_LINE)
  end

  for r = 0, visRows - 1 do
    local label = rowLabel(sr + r)
    local tw    = ImGui.CalcTextSize(ctx, label)
    ImGui.DrawList_AddText(dl,
      ox + QN_W - tw - 4, bodyTop + r * rowH + 1, textCol, label)
  end

  -- Header track names — sit at the bottom of the header band so the
  -- HEADER_PAD breathing room reads as space above them. Clipped at
  -- cell edges so long names ellipsise into nothing rather than spill.
  local headerTextY = oy + HEADER_PAD
  for c = 0, nTracks - 1 do
    local tr   = tracks[c + 1]
    local name = (tr and tr.name and tr.name ~= '')
                 and tr.name or string.format('Track %d', c + 1)
    local tw   = ImGui.CalcTextSize(ctx, name)
    local lx   = trackLeft(c) + math.floor((TRACK_W - tw) / 2)
    ImGui.DrawList_PushClipRect(dl,
      trackLeft(c) + 2, oy, trackRight(c) - 2, oy + headerH, true)
    ImGui.DrawList_AddText(dl, lx, headerTextY, textCol, name)
    ImGui.DrawList_PopClipRect(dl)
  end

  ImGui.DrawList_PopClipRect(dl)

  -- Advance the ImGui layout cursor so subsequent siblings know we
  -- consumed the grid's footprint.
  ImGui.Dummy(ctx, gridW + LOOP_PAD, headerH + HEADER_GAP + visRows * rowH)
end

----- Palette pane

-- Locate the slot entry in trackSlots() output (a packed array, not
-- indexed by slotIdx). Returns nil when no slot is focused or the
-- focused slot index isn't currently populated.
local function focusedSlotEntry(slots, slotIdx)
  if slotIdx == nil then return nil end
  for _, s in ipairs(slots) do
    if s.idx == slotIdx then return s end
  end
  return nil
end

-- Hand-drawn so the header band height (HEADER_PAD + rowH) and the
-- divider position match the grid's by construction — both panes start
-- at the same `oy` (they share the renderBody row), so the divider
-- lines up across the PANE_GAP without measurement.
local function renderPaletteHeader(focusedTrack)
  local trackLabel = focusedTrack
    and (focusedTrack.name ~= '' and focusedTrack.name
         or string.format('Track %d', focusedTrack.idx + 1))
    or '(no track)'
  local dl       = ImGui.GetWindowDrawList(ctx)
  local ox, oy   = ImGui.GetCursorScreenPos(ctx)
  local paneW    = (select(1, ImGui.GetContentRegionAvail(ctx)))
  local rowH     = math.max(1, ImGui.GetTextLineHeightWithSpacing(ctx))
  local headerH  = rowH + HEADER_PAD
  local textCol  = chrome.colour('text')
  local tw       = ImGui.CalcTextSize(ctx, trackLabel)
  local lx       = ox + math.floor((paneW - tw) / 2)
  ImGui.DrawList_AddText(dl, lx, oy + HEADER_PAD, textCol, trackLabel)
  ImGui.DrawList_AddLine(dl, ox, oy + headerH, ox + paneW, oy + headerH, textCol, 1)
  ImGui.Dummy(ctx, paneW, headerH + HEADER_GAP)
end

local function openRenameModal(trackIdx, slotIdx, currentName)
  modalHost:openPrompt{
    title    = 'Rename slot',
    prompt   = 'New name',
    buf      = currentName or '',
    callback = function(name) av:renameSlot(trackIdx, slotIdx, name) end,
  }
end

local function openDeleteModal(trackIdx, slot)
  local key  = av:keyForSlot(slot.idx)
  local name = slot.name ~= '' and slot.name
                              or string.format('(slot %d)', slot.idx)
  modalHost:openConfirm{
    title    = 'Delete slot',
    prompt   = string.format('Delete slot %s "%s"?\nRemoves every instance on the track. (y/n)', key, name),
    callback = function(yes) if yes then av:deleteSlot(trackIdx, slot.idx) end end,
  }
end

-- Default length 4 rows — matches the design's default phrase length
-- ("create something musical-sized, not a one-row stub"). User can
-- override in the modal.
local CREATE_DEFAULT_ROWS = 4
function openCreateModal(trackIdx, qnPos, rows)
  modalHost:open{
    kind     = 'createSlot',
    title    = 'New take',
    nameBuf  = '',
    rowsBuf  = tostring(rows or CREATE_DEFAULT_ROWS),
    callback = function(nameBuf, rowsBuf)
      local rowsN = math.max(1, math.floor(tonumber(rowsBuf) or CREATE_DEFAULT_ROWS))
      av:createSlot(trackIdx, qnPos, rowsN * av:beatPerRow(), nameBuf)
    end,
  }
end

-- Two-field create modal: name + row count. Built-in prompt/confirm
-- don't fit; the renderer converts rowsBuf at close, so the page-level
-- callback gets the raw strings and applies its own defaulting/floor.
modalHost:registerKind('createSlot', function(s, close)
  if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
  ImGui.Text(ctx, 'Name')
  local commitN, nb = ImGui.InputText(ctx, '##createName', s.nameBuf,
                                      ImGui.InputTextFlags_EnterReturnsTrue)
  s.nameBuf = nb
  ImGui.Text(ctx, 'Length (rows)')
  local commitR, rb = ImGui.InputText(ctx, '##createRows', s.rowsBuf,
                                      ImGui.InputTextFlags_EnterReturnsTrue)
  s.rowsBuf = rb
  local ok     = commitN or commitR or ImGui.Button(ctx, 'OK')
  ImGui.SameLine(ctx)
  local cancel = ImGui.Button(ctx, 'Cancel') or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape)
  if ok then close(true, s.nameBuf, s.rowsBuf)
  elseif cancel then close(false) end
end)

local function renderPaletteActions(focusedTrack, focusedSlot)
  local trackIdx = focusedTrack and focusedTrack.idx
  local canActOnSlot = focusedSlot ~= nil

  chrome.disabledIf(not canActOnSlot, function()
    if ImGui.Button(ctx, 'rename##slot') then
      openRenameModal(trackIdx, focusedSlot.idx, focusedSlot.name)
    end
  end)
  ImGui.SameLine(ctx, 0, 4)
  chrome.disabledIf(not canActOnSlot, function()
    if ImGui.Button(ctx, 'del##slot') then
      openDeleteModal(trackIdx, focusedSlot)
    end
  end)
end

-- Three columns so the key/kind/name align vertically across rows
-- without depending on a monospace font for the whole line. The key
-- cell uses the monospace font (it's a hotkey to press); kind and
-- name use the default UI font. Selectable lives in col 0 with
-- SpanAllColumns so the entire row is the click target; we paint the
-- key text on top with SameLine.
local function renderPaletteList(slots)
  if #slots == 0 then
    ImGui.TextDisabled(ctx, '(no slots)')
    return
  end
  local sel = av:paletteSlot()
  if not ImGui.BeginTable(ctx, '##paletteList', 3) then return end
  ImGui.TableSetupColumn(ctx, '', ImGui.TableColumnFlags_WidthFixed,   SLOT_KEY_W)
  ImGui.TableSetupColumn(ctx, '', ImGui.TableColumnFlags_WidthFixed,   SLOT_KIND_W)
  ImGui.TableSetupColumn(ctx, '', ImGui.TableColumnFlags_WidthStretch)

  for _, slot in ipairs(slots) do
    ImGui.TableNextRow(ctx)
    ImGui.TableSetColumnIndex(ctx, 0)
    if ImGui.Selectable(ctx, '##slot' .. slot.idx, sel == slot.idx,
                        ImGui.SelectableFlags_SpanAllColumns) then
      av:setPaletteSlot(slot.idx)
    end
    ImGui.SameLine(ctx, 0, 0)
    if monoFont then ImGui.PushFont(ctx, monoFont, uiSize) end
    ImGui.Text(ctx, av:keyForSlot(slot.idx))
    if monoFont then ImGui.PopFont(ctx) end

    ImGui.TableSetColumnIndex(ctx, 1)
    ImGui.Text(ctx, slot.kind == 'midi' and 'M' or 'A')

    ImGui.TableSetColumnIndex(ctx, 2)
    ImGui.Text(ctx, slot.name ~= '' and slot.name
                    or string.format('(slot %d)', slot.idx))
  end
  ImGui.EndTable(ctx)
end

local function renderPalette(tracks)
  -- tracks is 1-based; cursorCol is 0-based track index.
  local focusedTrack = tracks[av:cursorCol() + 1]
  local slots        = focusedTrack and av:trackSlots(focusedTrack.idx) or {}
  local focusedSlot  = focusedSlotEntry(slots, av:paletteSlot())

  -- Push chrome styles inside the palette child so buttons get
  -- toolbar colours, FrameBorderSize, etc. Body styles (parchment
  -- text + tables) already in effect from the renderBody-level push.
  chrome.pushChromeStyles()
  renderPaletteHeader(focusedTrack)
  renderPaletteActions(focusedTrack, focusedSlot)
  ImGui.Separator(ctx)
  renderPaletteList(slots)
  chrome.popChromeStyles()
end

----------- PUBLIC

--contract: bind takes no take — arrange is project-wide. coord may call with no args (or a take, ignored).
function ap:bind() end
function ap:unbind() end

--contract: positions cursor on the take wrapping `reaperTake` and focuses it; no-op if not on grid.
function ap:revealTake(reaperTake) av:revealTake(reaperTake) end

--contract: seeds cursor/focus from am:initialCursor (first selected take, else edit cursor).
function ap:seedCursorFromReaper() av:seedCursor() end

function ap:renderToolbarBits(_) end

--invariant: grid is hand-drawn (no ImGui table) — tints, gridlines, take rects per slot, cursor on top.
--contract: pushes parchment body palette (coord popped chrome before body draw); palette tables below need it.
--contract: invokes dispatch at end-of-body so arrange-scope keys reach the dispatcher.
function ap:renderBody(_, w, h, dispatch)
  if not ctx then return end

  pushBodyStyles()

  local tracks  = av:projectTracks()
  local nTracks = #tracks
  if nTracks == 0 then
    ImGui.Text(ctx, '(no tracks in project)')
    av:setGridSize(0, 0)
    popBodyStyles()
    if dispatch then dispatch(self:focusState()) end
    return
  end

  local gridW = math.max(120, w - PALETTE_W - PANE_GAP)
  -- WindowFlags_NoNav suppresses the blue nav rect that Tab/arrow
  -- focus would otherwise draw around the whole grid child.
  if ImGui.BeginChild(ctx, '##arrangeGrid', gridW, h,
                      ImGui.ChildFlags_None,
                      ImGui.WindowFlags_NoNav) then
    renderGrid(tracks, nTracks)
  end
  ImGui.EndChild(ctx)

  -- 1 px vertical rule centred in PANE_GAP so neither pane edge
  -- touches the line. Darkest parchment shade (colour.text =
  -- palette.shade) ties it to the body palette instead of pure black.
  ImGui.SameLine(ctx, 0, 0)
  local sx, sy = ImGui.GetCursorScreenPos(ctx)
  local lineX  = sx + math.floor(PANE_GAP / 2)
  ImGui.DrawList_AddLine(ImGui.GetWindowDrawList(ctx),
    lineX, sy, lineX, sy + h, chrome.colour('text'), 1)
  ImGui.Dummy(ctx, PANE_GAP, h)
  ImGui.SameLine(ctx, 0, 0)

  if ImGui.BeginChild(ctx, '##arrangePalette', PALETTE_W, h,
                      ImGui.ChildFlags_None,
                      ImGui.WindowFlags_NoNav) then
    renderPalette(tracks)
  end
  ImGui.EndChild(ctx)

  popBodyStyles()
  if dispatch then dispatch(self:focusState()) end
end

function ap:renderStatusBar(_)
  if not ctx then return end
  ImGui.Text(ctx, string.format(
    'arrange | row %d  col %d  | %g beats/row',
    av:cursorRow(), av:cursorCol(), av:beatPerRow()))
end

--contract: acceptCmds=false if picker active, any item active, or modal was open at frame start.
function ap:focusState()
  if not ctx then return { suppressKbd = false, acceptCmds = false } end
  local pa = chrome and chrome.pickerIsActive() or false
  return {
    suppressKbd = pa,
    acceptCmds  = (not pa)
                  and not ImGui.IsAnyItemActive(ctx)
                  and not modalHost:wasOpenAtFrameStart(),
  }
end

function ap:handleInput() end
function ap:save()        end
function ap:load()        end

--invariant: createSlot (Ctrl+Enter) opens the create modal — the only slot-minting gesture. Slots have no existence apart from items on the grid; the palette's rename / delete buttons act on existing slots.
-- cmgr:scope is idempotent — same scope av registers into.
local arrange = cmgr:scope('arrange')

arrange:registerAll {
  createSlot = function()
    openCreateModal(av:cursorCol(), av:rowToQN(av:cursorRow()))
  end,
}

-- The cursor-nav and take-edit commands reuse the tracker scope's keys
-- but not its names: cmgr.commands is flat, so a shared name would
-- overwrite the other scope's gate (see reference_commandmanager_limits).
local binds = {
  arrangeCursorUp     = { { ImGui.Key_UpArrow    } },
  arrangeCursorDown   = { { ImGui.Key_DownArrow  } },
  arrangeCursorLeft   = { { ImGui.Key_LeftArrow  } },
  arrangeCursorRight  = { { ImGui.Key_RightArrow } },
  arrangePageUp       = { { ImGui.Key_PageUp   } },
  arrangePageDown     = { { ImGui.Key_PageDown } },
  arrangeHome         = { { ImGui.Key_Home     } },
  arrangeEnd          = { { ImGui.Key_End      } },
  createSlot          = { { ImGui.Key_Enter, ImGui.Mod_Super } },
  arrangeNudgeBack    = { { ImGui.Key_UpArrow,   ImGui.Mod_Super } },
  arrangeNudgeForward = { { ImGui.Key_DownArrow, ImGui.Mod_Super } },
  arrangeShrinkTake   = { { ImGui.Key_UpArrow,   ImGui.Mod_Super, ImGui.Mod_Shift } },
  arrangeGrowTake     = { { ImGui.Key_DownArrow, ImGui.Mod_Super, ImGui.Mod_Shift } },
  arrangeDeleteTake             = { { ImGui.Key_Delete } },
  arrangeDive                   = { { ImGui.Key_Tab }, { ImGui.Key_Enter }, { ImGui.Key_KeypadEnter } },
  arrangeTakeProperties         = { { ImGui.Key_Backspace, ImGui.Mod_Super } },
  arrangeDuplicateBelow         = { { ImGui.Key_D, ImGui.Mod_Super } },
  arrangeDuplicateUnpooledBelow = { { ImGui.Key_Enter, ImGui.Mod_Super, ImGui.Mod_Shift } },
}

-- Place-command keys: 0..9 → digit keys, 10..35 → letters, 36..61 →
-- Shift+letter. ImGui.Key_0 + n and Key_A + n are contiguous.
local function placeKey(slotIdx)
  if slotIdx < 10 then return { ImGui.Key_0 + slotIdx } end
  if slotIdx < 36 then return { ImGui.Key_A + (slotIdx - 10) } end
  return { ImGui.Key_A + (slotIdx - 36), ImGui.Mod_Shift }
end
for i = 0, 61 do
  binds['drop' .. av:keyForSlot(i)] = { placeKey(i) }
end
arrange:bindAll(binds)

return ap
