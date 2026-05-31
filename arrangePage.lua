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
local painter = require 'painter'

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
-- Empty band between gutter numbers (right-aligned at QN_W) and the first
-- gridline; wide enough to host the edit-cursor / play-head triangles.
local GUTTER_PAD = 14
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

-- Per-takeId quad { fill, border, focusFill, focusBorder } off colourIdx;
-- focus pair brightens to full alpha so picked takes read without losing hue.
local SLOT_FILL_ALPHA = 0.85
local SLOT_BORDER_ALPHA = 0.75
local colourCache = {}
local function slotColours(colourIdx, focused)
  if colourIdx == nil then
    if focused then return 'arrange.orphanFocusFill', 'arrange.orphanFocusBorder' end
    return 'arrange.orphanFill', 'arrange.orphanBorder'
  end
  local quad = colourCache[colourIdx]
  if not quad then
    quad = {
      painter.hue(colourIdx, 0.55, 0.78, SLOT_FILL_ALPHA),
      painter.hue(colourIdx, 0.85, 0.55, SLOT_BORDER_ALPHA),
      painter.hue(colourIdx, 0.30, 0.97, SLOT_FILL_ALPHA),
      painter.hue(colourIdx, 0.92, 0.90, 1.0),
    }
    colourCache[colourIdx] = quad
  end
  if focused then return quad[3], quad[4] end
  return quad[1], quad[2]
end

----- Grid pane

-- Header band sits at the top of both panes (grid + palette). HEADER_PAD
-- is the breathing room above the header text; HEADER_GAP is the slim
-- band of empty space between the header divider and row 0 of the body.
-- Both panes use these constants so the dividers line up across the gap.
local HEADER_PAD = 8
local HEADER_GAP = 4

-- Snap a click's QN down to the top edge of the row box it sits in.
local function floorTo(v, step) return math.floor(v / step) * step end

-- Shared grid geometry for the mouse pass and the paint pass. Both build it
-- from the same cursor position — handleGridMouse draws nothing, so the ImGui
-- layout cursor hasn't moved when renderGrid follows — so both get the same
-- `pg`, the (col, row) → screen transform. A drawn cell and a click on it
-- therefore resolve through one mapping: snap=true pixel-aligns the draw;
-- fromScreen, which never snaps, hands the hit-test the true sub-pixel cell.
local function gridGeom(nTracks)
  local paneLeft, oy = ImGui.GetCursorScreenPos(ctx)
  local ox        = paneLeft + LOOP_PAD
  local _, availH = ImGui.GetContentRegionAvail(ctx)
  local rowH      = math.ceil(math.max(1, ImGui.GetTextLineHeightWithSpacing(ctx)))
  local headerH   = rowH + HEADER_PAD
  local bodyTop   = oy + headerH + HEADER_GAP
  local visRows   = math.max(1, math.floor((oy + availH - bodyTop) / rowH))
  local sr        = (select(1, av:scroll())) or 0
  local pg = painter.new(ctx, chrome, {
    ox = ox + QN_W + GUTTER_PAD, oy = bodyTop - sr * rowH,
    sx = TRACK_W, sy = rowH, snap = true,
  })
  return {
    pg = pg, paneLeft = paneLeft, ox = ox, oy = oy, availH = availH,
    rowH = rowH, headerH = headerH, bodyTop = bodyTop,
    bodyBot = bodyTop + visRows * rowH, visRows = visRows, sr = sr,
    gutterR = pg.ox,                      -- column-0 left edge (snapped)
    gridR   = pg.ox + nTracks * TRACK_W,  -- right edge of the last column
    gridW   = QN_W + GUTTER_PAD + TRACK_W * nTracks,  -- footprint from ox (Dummy)
  }
end

-- Grid mouse pass — runs before renderGrid so the in-flight take, loop
-- and create candidates are in hand when the paint pass relocates the
-- dragged take. In a track column, press a take to focus it then drag —
-- the take rides the cursor; Alt-drag duplicates. In the QN gutter, a
-- no-drag press sets the REAPER edit cursor and a drag sets the loop
-- range. A grid release that dragged no take moves the cursor to the
-- pressed cell; an empty-space press clears focus. Must run inside the
-- ##arrangeGrid child so IsWindowHovered resolves correctly. Also
-- pushes the current row/col extent into av (geometric input). Returns
-- the in-flight drag/loop/create candidates, each nil when not active.
local function handleGridMouse(nTracks)
  local g  = gridGeom(nTracks)
  local pg = g.pg

  av:setGridSize(g.visRows, nTracks)
  av:setMaxCol(nTracks)

  local mx, my     = ImGui.GetMousePos(ctx)
  local mcol, mrow = pg.fromScreen(mx, my)
  local bpr        = av:beatPerRow()
  local myQN       = av:rowToQN(mrow)
  local snapped    = ImGui.GetKeyMods(ctx) & ImGui.Mod_Shift == 0
  local inBody     = my >= g.bodyTop and my <= g.bodyBot
  local inGutter   = mx >= g.paneLeft and mx < g.gutterR

  if ImGui.IsMouseClicked(ctx, 1) and ImGui.IsWindowHovered(ctx)
     and inBody and inGutter then
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
  if ImGui.IsMouseClicked(ctx, 0) and ImGui.IsWindowHovered(ctx) and inBody then
    if inGutter then
      press = { qn = myQN, gutter = true, moved = false }
    else
      local col = math.floor(mcol)
      if col >= 0 and col < nTracks then
        local row = math.min(g.sr + g.visRows - 1, math.floor(mrow))
        local take, mode = av:hitTake(col, myQN, bpr / g.rowH)
        if not take and ImGui.IsMouseDoubleClicked(ctx, 0) then
          press = { qn = floorTo(myQN, bpr), col = col,
                    create = true, moved = false }
        else
          press = {
            qn = myQN, row = row, col = col,
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
                   and av:dragCandidate(press, myQN, snapped) or nil
  local loopCand = (press.moved and press.gutter)
                   and av:gutterLoopCand(press, myQN, snapped) or nil
  local createCand = (press.moved and press.create)
                     and av:createCandidate(press, myQN, snapped) or nil

  if ImGui.IsMouseReleased(ctx, 0) then
    if dragCand then
      if dragCand.fits then av:commitDrag(press, dragCand) end
    elseif loopCand then
      av:setLoopRangeQN(loopCand.loQN, loopCand.hiQN)
    elseif press.create then
      -- Sweep prefills the length in beats; bare double-click uses the default.
      local beats = createCand and createCand.lengthQN or nil
      openCreateModal(press.col, press.qn, beats)
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

local function renderGrid(tracks, nTracks, dragCand, loopCand, createCand)
  local g  = gridGeom(nTracks)
  local pg = g.pg
  local ps = painter.new(ctx, chrome, {})   -- screen space: gutter, header, full-width rules
  local sr, rowH, visRows = g.sr, g.rowH, g.visRows
  local ox, oy, gridR = g.ox, g.oy, g.gridR

  local function rect(x0, y0, x1, y1) return { x0 = x0, y0 = y0, x1 = x1, y1 = y1 } end
  -- Snapped screen edges of a column / row, read off the shared grid transform.
  local function colX(c)  return (pg.toScreen(c, 0)) end
  local function rowYs(r) return select(2, pg.toScreen(0, r)) end

  local curRow, curCol = av:cursorRow(), av:cursorCol()

  -- The right border (gridline at gridR; rightmost take-rect border a
  -- px beyond) sits on the clip boundary — clip past it or it's chopped.
  ps.pushClip(rect(g.paneLeft, oy, gridR + 2, oy + g.availH))

  -- Row tints (bar / phrase). Row 0 (qn = 0) is the strongest phrase
  -- boundary in the project, so it gets the phrase tint too — no qn > 0
  -- guard. Phrase reuses the bar hue (rowBeat) at full opacity so phrases
  -- read stronger than the bars they contain.
  for r = 0, visRows - 1 do
    local qn   = math.floor(av:rowToQN(sr + r) + 0.5)
    local tint = (qn % 64 == 0) and 'arrange.phrase'
              or (qn % 16 == 0) and 'rowBeat'
              or nil
    if tint then
      ps.fill(rect(ox, rowYs(sr + r), gridR, rowYs(sr + r + 1)), tint)
    end
  end

  -- Gridlines, under the take rectangles (whose 1px borders re-state the cell
  -- boundary at the take edge). Verticals are column edges, drawn in (col, row)
  -- through the grid painter; horizontals and the bottom border span the gutter
  -- too, so they're screen-space. Topmost and leftmost outer borders are
  -- omitted and verticals start at row 0, so the header reads as open space.
  for c = 0, nTracks do
    pg.line(c, sr, c, sr + visRows, 'separator', 1)
  end
  ps.line(ox, rowYs(sr + visRows), gridR, rowYs(sr + visRows), 'separator', 1)
  for r = 1, visRows - 1 do
    local y = rowYs(sr + r)
    ps.line(ox, y, gridR, y, 'separator', 1)
  end

  -- Take rectangles, on top of gridlines. Fill exactly the column (edges on
  -- the gridline), 1px border, centred name. Corners come snapped from the
  -- grid painter, so adjacent takes' borders land on the same pixel and
  -- coincide; the ±1px insets are screen-space — a border can't be a
  -- fraction of a column.
  --
  -- Three passes so the cursor cell can paint between fills and names:
  -- the translucent cursor fill lies over the take fill, and names draw
  -- last so they stay crisp over it.
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
    local rx0, rx1 = colX(tk.trackIdx), colX(tk.trackIdx + 1)
    local ry0 = rowYs(math.max(startRow, sr))
    local ry1 = rowYs(math.min(endRow, sr + visRows))
    local fill, border = slotColours(tk.colourIdx, focused)
    if blocked then border = 'arrange.blockedBorder' end
    ps.fill(rect(rx0 + 1, ry0 + 1, rx1, ry1), fill)
    ps.stroke(rect(rx0, ry0, rx1 + 1, ry1 + 1), border, 1)
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
      local gx0, gx1 = colX(press.col), colX(press.col + 1)
      local gy0 = rowYs(math.max(startRow, sr))
      local gy1 = rowYs(math.min(endRow, sr + visRows))
      ps.fill(rect(gx0 + 1, gy0 + 1, gx1, gy1), 'arrange.ghostFill')
      ps.stroke(rect(gx0, gy0, gx1 + 1, gy1 + 1), 'arrange.ghostBorder', 1)
    end
  end

  -- Cursor caret — a horizontal I-beam on the top edge of the cursor
  -- row, spanning the column. Cursor position is a line, not a cell:
  -- mere movement doesn't pick a take, so a cell-shaped highlight
  -- would lie about the model.
  if curRow >= sr and curRow < sr + visRows
     and curCol >= 0 and curCol < nTracks then
    local cx0, cx1 = colX(curCol), colX(curCol + 1)
    local cy    = rowYs(curRow)
    local serif = 4
    local caret = 'arrange.cursorBorder'
    ps.line(cx0 + 1, cy,         cx1 - 1, cy,         caret, 1.5)
    ps.line(cx0 + 1, cy - serif, cx0 + 1, cy + serif, caret, 1.5)
    ps.line(cx1,     cy - serif, cx1,     cy + serif, caret, 1.5)
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
      local x1 = g.paneLeft + 1 + r
      local y1, y2 = rowYs(loTop), rowYs(loBot)
      ps.pathClear()
      ps.pathArcTo(x1, y1 + r, r, 3 * math.pi / 2, math.pi)
      ps.pathLineTo(x1 - r, y1 + r + 1)
      ps.pathLineTo(x1 - r, y2 - r - 1)
      ps.pathArcTo(x1, y2 - r, r, math.pi, math.pi / 2)
      ps.pathStroke('tail', 1.5)
      ps.pathClear()
    end
  end

  -- Take names — last, so they stay crisp over the translucent cursor
  -- fill.
  for _, nd in ipairs(nameDraws) do
    local tw = ps.measure(nd.name)
    local tx = nd.rx0 + math.floor((nd.rx1 - nd.rx0 - tw) / 2)
    ps.pushClip(rect(nd.rx0 + 2, nd.ry0, nd.rx1 - 2, nd.ry1))
    ps.text(tx, nd.ry0 + 1, 'text', nd.name)
    ps.popClip()
  end

  -- Truncation ellipsis — bottom-row glyph for items the relayout pass
  -- shortened below their natural length. Same final-pass treatment as
  -- names so it sits over the cursor fill.
  for _, td in ipairs(truncDraws) do
    local ell = '…'
    local tw  = ps.measure(ell)
    local tx  = td.rx0 + math.floor((td.rx1 - td.rx0 - tw) / 2)
    local ty  = td.ry1 - rowH + 1
    ps.pushClip(rect(td.rx0 + 2, ty, td.rx1 - 2, td.ry1))
    ps.text(tx, ty, 'text', ell)
    ps.popClip()
  end

  -- Edit cursor + play head — equilateral triangles in the gutter, apex 2px
  -- left of the column divider. Play head draws only while the transport runs.
  local TRI_BASE, TRI_H = 7, 7
  local function gutterTri(qn, fill)
    local y    = rowYs(av:qnToRow(qn))
    local apex = pg.ox - 2
    local base = apex - TRI_H
    local half = TRI_BASE / 2
    ps.tri(apex, y, base, y - half, base, y + half, fill)
    ps.polyline({ apex, y, base, y - half, base, y + half },
                'arrange.cursorTriBorder', 1, true)
  end
  gutterTri(av:editCursorQN(), 'arrange.editCursor')
  local playQN = av:playPositionQN()
  if playQN then gutterTri(playQN, 'arrange.playHead') end

  for r = 0, visRows - 1 do
    local label = rowLabel(sr + r)
    local tw    = ps.measure(label)
    ps.text(ox + QN_W - tw - 4, rowYs(sr + r) + 1, 'text', label)
  end

  -- Header track names — sit at the bottom of the header band so the
  -- HEADER_PAD breathing room reads as space above them. Clipped at
  -- cell edges so long names ellipsise into nothing rather than spill.
  local headerTextY = oy + HEADER_PAD
  for c = 0, nTracks - 1 do
    local tr   = tracks[c + 1]
    local name = (tr and tr.name and tr.name ~= '')
                 and tr.name or string.format('Track %d', c + 1)
    local tw   = ps.measure(name)
    local lx   = colX(c) + math.floor((TRACK_W - tw) / 2)
    ps.pushClip(rect(colX(c) + 2, oy, colX(c + 1) - 2, oy + g.headerH))
    ps.text(lx, headerTextY, 'text', name)
    ps.popClip()
  end

  ps.popClip()

  -- Advance the ImGui layout cursor so subsequent siblings know we
  -- consumed the grid's footprint.
  ImGui.Dummy(ctx, g.gridW + LOOP_PAD, g.headerH + HEADER_GAP + visRows * rowH)
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
  local p        = painter.new(ctx, chrome, {})
  local ox, oy   = ImGui.GetCursorScreenPos(ctx)
  local paneW    = (select(1, ImGui.GetContentRegionAvail(ctx)))
  local rowH     = math.max(1, ImGui.GetTextLineHeightWithSpacing(ctx))
  local headerH  = rowH + HEADER_PAD
  local tw       = p.measure(trackLabel)
  local lx       = ox + math.floor((paneW - tw) / 2)
  p.text(lx, oy + HEADER_PAD, 'text', trackLabel)
  p.line(ox, oy + headerH, ox + paneW, oy + headerH, 'text', 1)
  ImGui.Dummy(ctx, paneW, headerH + HEADER_GAP)
end

local function openRenameModal(trackIdx, slotIdx, currentName)
  modalHost:openPrompt{
    title    = 'Rename slot',
    prompt   = 'New name',
    buf      = currentName or '',
    callback = util.atomic('Rename slot', function(name) av:renameSlot(trackIdx, slotIdx, name) end),
  }
end

local function openDeleteModal(trackIdx, slot)
  local key  = av:keyForSlot(slot.idx)
  local name = slot.name ~= '' and slot.name
                              or string.format('(slot %d)', slot.idx)
  modalHost:openConfirm{
    title    = 'Delete slot',
    prompt   = string.format('Delete slot %s "%s"?\nRemoves every instance on the track. (y/n)', key, name),
    callback = util.atomic('Delete slot', function(yes) if yes then av:deleteSlot(trackIdx, slot.idx) end end),
  }
end

-- Default length 8 beats (two bars in 4/4) — musical-sized, not a stub.
local CREATE_DEFAULT_BEATS = 8
function openCreateModal(trackIdx, qnPos, beats)
  local slotIdx = av:nextFreeSlot(trackIdx)
  modalHost:open{
    kind     = 'createSlot',
    title    = 'New take',
    nameBuf  = slotIdx and string.format('%02d', slotIdx) or '',
    beatsBuf = tostring(beats or CREATE_DEFAULT_BEATS),
    callback = util.atomic('Create take', function(nameBuf, beatsBuf)
      local b = math.max(1e-3, tonumber(beatsBuf) or CREATE_DEFAULT_BEATS)
      av:createSlot(trackIdx, qnPos, b, nameBuf)
    end),
  }
end

-- Two-field create modal: name + length-in-beats. OK/Cancel keys are
-- gated on not-appearing so the Cmd+Enter that opened it doesn't self-dismiss.
modalHost:registerKind('createSlot', function(s, close)
  local appearing = ImGui.IsWindowAppearing(ctx)
  ImGui.Text(ctx, 'Name')
  local rvN, nb = ImGui.InputText(ctx, '##createName', s.nameBuf)
  if rvN then s.nameBuf = nb end
  ImGui.Text(ctx, 'Length (beats)')
  if appearing then ImGui.SetKeyboardFocusHere(ctx) end
  local rvB, bb = ImGui.InputText(ctx, '##createBeats', s.beatsBuf)
  if rvB then s.beatsBuf = bb end
  local ok = ImGui.Button(ctx, 'OK')
              or (not appearing and (ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
                                  or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)))
  ImGui.SameLine(ctx)
  local cancel = ImGui.Button(ctx, 'Cancel')
              or (not appearing and ImGui.IsKeyPressed(ctx, ImGui.Key_Escape))
  if ok then close(true, s.nameBuf, s.beatsBuf)
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
    local dragCand, loopCand, createCand = handleGridMouse(nTracks)
    renderGrid(tracks, nTracks, dragCand, loopCand, createCand)
  end
  ImGui.EndChild(ctx)

  -- 1 px vertical rule centred in PANE_GAP so neither pane edge
  -- touches the line. Darkest parchment shade (colour.text =
  -- palette.shade) ties it to the body palette instead of pure black.
  ImGui.SameLine(ctx, 0, 0)
  local sx, sy = ImGui.GetCursorScreenPos(ctx)
  local lineX  = sx + math.floor(PANE_GAP / 2)
  local p      = painter.new(ctx, chrome, {})
  p.line(lineX, sy, lineX, sy + h, 'text', 1)
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
  arrangeCursorUp     = { ImGui.Key_UpArrow   },
  arrangeCursorDown   = { ImGui.Key_DownArrow },
  arrangeCursorLeft   = { ImGui.Key_LeftArrow },
  arrangeCursorRight  = { ImGui.Key_RightArrow},
  arrangePageUp       = { ImGui.Key_PageUp    },
  arrangePageDown     = { ImGui.Key_PageDown  },
  arrangeHome         = { ImGui.Key_Home      },
  arrangeEnd          = { ImGui.Key_End       },
  createSlot          = { { ImGui.Key_Enter, ImGui.Mod_Super } },
  arrangeNudgeBack    = { { ImGui.Key_UpArrow,   ImGui.Mod_Super } },
  arrangeNudgeForward = { { ImGui.Key_DownArrow, ImGui.Mod_Super } },
  arrangeShrinkTake   = { { ImGui.Key_UpArrow,   ImGui.Mod_Super, ImGui.Mod_Shift } },
  arrangeGrowTake     = { { ImGui.Key_DownArrow, ImGui.Mod_Super, ImGui.Mod_Shift } },
  arrangeDeleteTake             = { ImGui.Key_Delete },
  arrangeDive                   = { ImGui.Key_Enter },
  arrangeTakeProperties         = { { ImGui.Key_Backspace, ImGui.Mod_Super } },
  arrangeDuplicateBelow         = { { ImGui.Key_D, ImGui.Mod_Ctrl } },
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
