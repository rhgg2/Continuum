-- See docs/arrangePage.md for the model. @noindex

--invariant: render + input only — holds av only, never am; all queries/mutations go through av.
--invariant: key bindings here; command bodies in av; coord pushes the scope on activation.
--shape: body = grid pane (variable width) | fixed-width palette (chrome.palettePane); palette shows slots for the track under av:cursorCol().

local util = require 'util'

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'
local painter = require 'painter'

--contract: arrangePage (the controller) owns the stack (am/av) and hands this renderer av only
local cm, cmgr, chrome, gui, modalHost, av, help, keyQueue =
  (...).cm, (...).cmgr, (...).chrome, (...).gui, (...).modalHost, (...).av, (...).help,
  (...).keyQueue

local ctx = gui and gui.ctx or nil
-- gui.font is monospace (Source Code Pro) attached at context create;
-- we push it for the slot-key cell so 62 base62 keys align in a column.
local monoFont = gui and gui.font or nil
local uiSize   = gui and gui.fontSize and gui.fontSize.ui or 12

local ar = {}

local QN_W, TRACK_W = 32, 72
-- Empty band between gutter numbers (right-aligned at QN_W) and the first
-- gridline, so the numbers don't crowd the grid.
local GUTTER_PAD = 14
-- The loop bracket strokes down the left edge; the grid shifts LOOP_PAD right to clear it.
-- Must exceed the bracket radius (5) plus its 1.5px stroke.
local LOOP_PAD = 7
-- Palette row column widths: monospace key, kind glyph, name fills.
local SLOT_KEY_W, SLOT_KIND_W = 18, 16

-- Forward decl: runGridMouse (in renderGrid below) calls openCreateModal, defined further down.
local openCreateModal

--shape: press = { qn, row, col, take, mode = 'move'|'resizeHead'|'resizeEnd', duplicate, moved, gutter, create } — nil when no button down. Track-col: take/row/col/mode; gutter: qn+gutter=true; dbl-click: qn/col+create=true. moved flips at drag threshold.
--invariant: drag relocates via am:startIsClear; cursor moves only on clean (no-drag) release.
--invariant: gutter press drives REAPER transport — release sets edit cursor, drag sets loop range.
--invariant: double-click on empty space starts a create press; release opens create modal.
local press = nil
local WHEEL_STEP_ROWS   = 1   -- viewport rows panned per mouse-wheel notch
local WHEEL_STEP_COLS   = 0.5   -- viewport cols panned per mouse-wheel notch
local wheelAccumV  = 0   -- fractional vertical wheel carried between frames
local wheelAccumH  = 0   -- fractional horizontal wheel carried between frames

-- Accumulate a fractional wheel delta and drain whole notches off it.
-- Returns the residual accumulator and the integer step to apply.
local function drainWheel(accum, wheel, unitsPerNotch)
  accum = accum + wheel * unitsPerNotch
  local whole = (accum >= 0 and math.floor or math.ceil)(accum)
  return accum - whole, whole
end

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

-- Slot fills come from chrome (chrome.slotFill), shared with the tracker's mini-map.
-- Borders are a uniform neutral, drawn by renderGrid.

----- Audio waveform previews (native REAPER peaks)

-- Per-take peak cache; invalidated on zoom change. hi=nil while async build
-- is in progress; caller draws a flat centre line. Never destroy the source.
local peakCache = {}

-- Window keyed to drawn length (not D_LENGTH) so scale stays fixed on resize:
-- head anchored, tail reveals/hides like a trim.
local function takeWindowSec(take, startQN, lengthQN)
  local startOffs = reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS')
  local rate      = reaper.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
  local drawnSec  = reaper.TimeMap2_QNToTime(0, startQN + lengthQN)
                  - reaper.TimeMap2_QNToTime(0, startQN)
  return startOffs, drawnSec * (rate ~= 0 and rate or 1)
end

-- PCM_Source_GetPeaks: maxes block then mins block, channels interleaved per column;
-- reduce to per-column signed hi/lo. Loops sample ONE source period; others map the window.
--contract: nil for an unreadable source; entry with hi=nil while peaks still build
local function peaksFor(take, startQN, lengthQN, pxPerSec, loop)
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return nil end
  local startOffs, winSec = takeWindowSec(take, startQN, lengthQN)
  if winSec <= 0 then return nil end
  local srcSec = reaper.GetMediaSourceLength(src)
  local wrap   = loop and srcSec > 0 and winSec > srcSec + 1e-6
  local spanStart = wrap and 0 or startOffs
  local spanSec   = wrap and srcSec or winSec
  local cols = math.max(16, math.min(4096, math.floor(spanSec * pxPerSec + 0.5)))

  -- Take pointer is stable+unique, so two takes sharing a source don't collide.
  -- The take under an active resize churns its entry each frame; others stay cached.
  local key = tostring(take)
  local sig = string.format('%.4f:%.4f:%d:%s', spanStart, spanSec, cols, tostring(wrap))
  local hit = peakCache[key]
  if hit and hit.sig ~= sig then hit, peakCache[key] = nil, nil end
  if hit and hit.hi then return hit end

  if not hit then
    hit = { sig = sig, cols = cols, winSec = winSec, srcSec = srcSec,
            startOffs = startOffs, wrap = wrap,
            building = reaper.PCM_Source_BuildPeaks(src, 0) ~= 0 }
    peakCache[key] = hit
  end
  if hit.building then
    if reaper.PCM_Source_BuildPeaks(src, 1) == 0 then
      reaper.PCM_Source_BuildPeaks(src, 2)
      hit.building = false
    else
      return hit
    end
  end

  local nch = math.max(1, reaper.GetMediaSourceNumChannels(src))
  local buf = reaper.new_array(cols * nch * 2); buf.clear()
  reaper.PCM_Source_GetPeaks(src, cols / spanSec, spanStart, nch, cols, 0, buf)
  local minBase, hi, lo = cols * nch, {}, {}
  for i = 0, cols - 1 do
    local h = buf[i * nch + 1] or 0
    local l = buf[minBase + i * nch + 1] or 0
    for c = 1, nch - 1 do
      local mx = buf[i * nch + c + 1] or 0
      local mn = buf[minBase + i * nch + c + 1] or 0
      if mx > h then h = mx end
      if mn < l then l = mn end
    end
    hi[i + 1], lo[i + 1] = h, l
  end
  hit.hi, hit.lo = hi, lo
  return hit
end

----- MIDI note previews (channel→X, time→Y; note-on caps darker than bodies)

-- Notes ride am's project-state cache (tk.notes) — no cache here. Two fixed zone
-- shades: note-on caps a zone below the bodies so attacks read against the sustain.

----- Grid pane

-- Grid header geometry; shares chrome's palette-header HEADER_PAD/HEADER_GAP.
local HEADER_PAD = 8
local HEADER_GAP = 4
-- The band grows from one line to this many for a visible track's name; longer
-- names ellipsise. The palette header stays one line, so a grown band leaves the dividers uneven.
local HEADER_MAX_LINES = 3

-- Snap a click's QN down to the top edge of the row box it sits in.
local function floorTo(v, step) return math.floor(v / step) * step end

-- A track's header label; an unnamed track reads as its 1-based number.
local function trackLabel(tr, col)
  return (tr and tr.name and tr.name ~= '') and tr.name
         or string.format('Track %d', col + 1)
end

-- Shared (col,row)→screen transform for mouse pass and paint pass: both call gridGeom at the
-- same layout-cursor position, so hit-test and draw resolve through one mapping.
local function gridGeom(tracks)
  local nTracks        = #tracks
  local paneLeft, oy   = ImGui.GetCursorScreenPos(ctx)
  local ox             = paneLeft + LOOP_PAD
  local availW, availH = ImGui.GetContentRegionAvail(ctx)
  local rowH           = math.ceil(math.max(1, ImGui.GetTextLineHeightWithSpacing(ctx)))
  local sr, sc         = av:scroll()
  sr, sc               = sr or 0, sc or 0
  local bandLeft       = ox + QN_W + GUTTER_PAD   -- fixed: left edge of the scrolling column band
  local paneR          = paneLeft + availW
  local visCols        = math.max(1, math.floor((paneR - bandLeft) / TRACK_W))
  local lastCol        = math.min(nTracks - 1, sc + visCols)

  -- Header names wrap here, not at the draw, so the band's height and the lines it
  -- holds come from one measurement; only visible columns count, so it settles back as a name scrolls out.
  local function widthOf(s) return (ImGui.CalcTextSize(ctx, s)) end
  local headerLabels, headerLines = {}, 1
  for c = sc, lastCol do
    headerLabels[c] = painter.wrapLines(trackLabel(tracks[c + 1], c), TRACK_W - 4,
                                        HEADER_MAX_LINES, widthOf)
    headerLines = math.max(headerLines, #headerLabels[c])
  end

  local headerH  = rowH * headerLines + HEADER_PAD
  local bodyTop  = oy + headerH + HEADER_GAP
  local visRows  = math.max(1, math.floor((oy + availH - bodyTop) / rowH))
  local pg = painter.new(ctx, chrome, {
    ox = bandLeft - sc * TRACK_W, oy = bodyTop - sr * rowH,
    sx = TRACK_W, sy = rowH, snap = true,
  }, 'arrange')
  return {
    pg = pg, paneLeft = paneLeft, ox = ox, oy = oy, availH = availH,
    headerLabels = headerLabels, headerLines = headerLines,
    rowH = rowH, headerH = headerH, bodyTop = bodyTop,
    bodyBot = bodyTop + visRows * rowH, visRows = visRows, sr = sr,
    sc = sc, visCols = visCols, lastCol = lastCol,
    gutterR = pg.ox + sc * TRACK_W,                        -- fixed gutter right / band left edge
    paneR   = paneR,
    gridR   = math.min(pg.ox + nTracks * TRACK_W, paneR),  -- visible right edge of the band
    gridW   = paneR - paneLeft,                            -- visible footprint (Dummy)
  }
end

-- Runs before renderGrid so in-flight drag/loop/create candidates are ready for the paint pass.
-- Must run inside ##arrangeGrid so IsWindowHovered resolves correctly.
local function handleGridMouse(tracks)
  local g       = gridGeom(tracks)
  local pg      = g.pg
  local nTracks = #tracks

  av:setGridSize(g.visRows, g.visCols)
  av:setMaxCol(nTracks)

  local mx, my     = ImGui.GetMousePos(ctx)
  local mcol, mrow = pg.fromScreen(mx, my)
  local bpr        = av:beatPerRow()
  local myQN       = av:rowToQN(mrow)
  local snapped    = keyQueue:mods() & ImGui.Mod_Shift == 0
  local inBody     = my >= g.bodyTop and my <= g.bodyBot
  local inGutter   = mx >= g.paneLeft and mx < g.gutterR

  if ImGui.IsMouseClicked(ctx, 1) and ImGui.IsWindowHovered(ctx)
     and inBody and inGutter then
    av:clearLoopRange()
  end
  -- Wheel pans the viewport; the cursor stays put (cursor-nav re-follows it).
  -- Fractional trackpad deltas accumulate; whole notches drain off — vertical to rows, horizontal to columns.
  local vWheel, hWheel = ImGui.GetMouseWheel(ctx)
  if (vWheel ~= 0 or hWheel ~= 0) and ImGui.IsWindowHovered(ctx) then
    local rows, cols
    wheelAccumV, rows = drainWheel(wheelAccumV, vWheel, WHEEL_STEP_ROWS)
    wheelAccumH, cols = drainWheel(wheelAccumH, hWheel, WHEEL_STEP_COLS)
    if rows ~= 0 or cols ~= 0 then
      av:scrollBy(-rows, -cols)
    end
  end
  -- After the wheel pan so a manual scroll this frame suspends follow before it runs.
  av:followPlay()
  if ImGui.IsMouseClicked(ctx, 0) and ImGui.IsWindowHovered(ctx) and inBody then
    if inGutter then
      press = { qn = myQN, gutter = true, moved = false }
    else
      local col = math.floor(mcol)
      local row = math.min(g.sr + g.visRows - 1, math.floor(mrow))
      local take, mode
      if col >= 0 and col < nTracks then take, mode = av:hitTake(col, myQN, bpr / g.rowH) end
      local mods      = keyQueue:mods()
      local additive  = mods & ImGui.Mod_Shift ~= 0   -- Shift: extend the selection
      local duplicate = mods & ImGui.Mod_Ctrl  ~= 0   -- Ctrl: a drag duplicates
      if take then
        -- Selected take → drag the whole block; unselected → collapse focus to it.
        -- Shift defers selection to release (toggle), so don't focus now.
        local group = mode == 'move' and av:isSelected(take.take)
        press = {
          qn = myQN, row = row, col = col,
          take = take, mode = mode, moved = false, group = group, add = additive,
          duplicate = mode == 'move' and duplicate,
        }
        if not group and not additive then av:setFocus(take.take) end
      elseif col >= 0 and col < nTracks and ImGui.IsMouseDoubleClicked(ctx, 0) then
        press = { qn = floorTo(myQN, bpr), col = col, create = true, moved = false }
      else
        -- Empty grid (incl. dead space right of the last column): a drag lassos;
        -- a plain click moves the cursor and clears the selection (Shift keeps it).
        press = { qn = myQN, row = row, col = col, mcol = mcol, moved = false, add = additive }
      end
    end
  end
  -- Hover feedback: either edge band (and a resize in flight) shows the NS cursor.
  local function resizeCursor(mode)
    if mode == 'resizeHead' or mode == 'resizeEnd' then
      ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_ResizeNS)
    end
  end
  if press then
    resizeCursor(press.mode)
  elseif ImGui.IsWindowHovered(ctx) and inBody and not inGutter then
    local col = math.floor(mcol)
    if col >= 0 and col < nTracks then
      local _, mode = av:hitTake(col, myQN, bpr / g.rowH)
      resizeCursor(mode)
    end
  end

  if not press then return nil, nil, nil end
  if ImGui.IsMouseDragging(ctx, 0) then press.moved = true end

  local dragCand = (press.moved and press.take)
                   and av:dragCandidate(press, myQN, snapped) or nil
  local loopCand = (press.moved and press.gutter)
                   and av:gutterLoopCand(press, myQN, snapped) or nil
  local createCand = (press.moved and press.create)
                     and av:createCandidate(press, myQN, snapped) or nil
  local lassoCand = (press.moved and not press.take
                     and not press.gutter and not press.create)
                    and av:lassoCandidate(press, mcol, myQN) or nil

  if ImGui.IsMouseReleased(ctx, 0) then
    if dragCand then
      if dragCand.fits then av:commitDrag(press, dragCand) end
    elseif loopCand then
      av:setLoopRangeQN(loopCand.loQN, loopCand.hiQN)
    elseif lassoCand then
      if press.add then av:addToSelection(lassoCand.takes)
      else av:setSelection(lassoCand.takes) end
    elseif press.create then
      -- Sweep prefills the length in beats; bare double-click uses the default.
      local beats = createCand and createCand.lengthQN or nil
      openCreateModal(press.col, press.qn, beats)
    elseif press.gutter then
      -- Floor to the row box's top edge (not the nearest edge) unless Shift is held.
      av:setEditCursorQN(snapped and floorTo(press.qn, bpr) or press.qn)
    else
      av:setCursor(press.row, press.col)
      if press.add then
        -- Shift+click toggles the clicked take; on empty space it keeps the selection.
        if press.take then av:toggleSelected(press.take.take) end
      else
        -- A plain click collapses the selection to the clicked take, or clears on empty space.
        av:setFocus(press.take and press.take.take)
      end
    end
    press = nil
    return nil, nil, nil, nil
  end
  return dragCand, loopCand, createCand, lassoCand
end

local function renderGrid(tracks, dragCand, loopCand, createCand, lassoCand)
  local g  = gridGeom(tracks)
  local pg = g.pg
  local ps = painter.new(ctx, chrome, {}, 'arrange')   -- screen space: gutter, header, full-width rules
  local sr, rowH, visRows = g.sr, g.rowH, g.visRows
  local ox, oy, gridR = g.ox, g.oy, g.gridR
  local sc, lastCol   = g.sc, g.lastCol

  local function rect(x0, y0, x1, y1) return { x0 = x0, y0 = y0, x1 = x1, y1 = y1 } end
  -- Snapped screen edges of a column / row, read off the shared grid transform.
  local function colX(c)  return (pg.toScreen(c, 0)) end
  local function rowYs(r) return select(2, pg.toScreen(0, r)) end

  local curRow, curCol = av:cursorRow(), av:cursorCol()

  -- The right border (gridline at gridR; rightmost take-rect border a
  -- px beyond) sits on the clip boundary — clip past it or it's chopped.
  ps.pushClip(rect(g.paneLeft, oy, gridR + 2, oy + g.availH))

  -- Row tints: phrase (every 64 QN) > bar (every 16 QN). Row 0 gets phrase tint unconditionally.
  -- Phrase reuses rowBeat hue at full opacity so it reads stronger.
  for r = 0, visRows - 1 do
    local qn   = math.floor(av:rowToQN(sr + r) + 0.5)
    local tint = (qn % 64 == 0) and 'arrange.phrase'
              or (qn % 16 == 0) and 'rowBeat'
              or nil
    if tint then
      ps.fill(rect(ox, rowYs(sr + r), gridR, rowYs(sr + r + 1)), tint)
    end
  end

  -- Verticals via grid painter; horizontals and bottom border are screen-space (span the gutter).
  -- Topmost/leftmost outer borders omitted so the header reads as open space.
  for c = sc, lastCol + 1 do
    pg.segment(c, sr, c, sr + visRows, 'separator')
  end
  ps.segment(ox, rowYs(sr + visRows), gridR, rowYs(sr + visRows), 'separator')
  for r = 1, visRows - 1 do
    local y = rowYs(sr + r)
    ps.segment(ox, y, gridR, y, 'separator')
  end

  -- Take rects: snapped corners so adjacent borders coincide; ±1px insets are screen-space.
  -- Three passes (fills → cursor wash → names) so names stay crisp over the wash.
  local selected = av:selectionSet()
  local nameDraws = {}
  local markDraws = {}   -- edge marks: the row marking source elided below the cut

  -- Vertical waveform: time→Y, amplitude→X (centred). ≥1px span per pixel so
  -- near-silence draws a line. fullTop/fullBot = full take edges (may be off-screen).
  local function drawWaveform(tk, startQN, lengthQN, rx0, rx1, yTop, yBot, fullTop, fullBot)
    local fullH = fullBot - fullTop
    if fullH < 2 then return end
    local _, winSec = takeWindowSec(tk.take, startQN, lengthQN)
    if winSec <= 0 then return end
    local pxPerSec = fullH / winSec
    local cx = (rx0 + rx1) * 0.5
    local hw = (rx1 - rx0) * 0.5 - 3
    if hw < 1 then return end
    -- Tile only a genuine loop; a non-loop run past the source shows silence.
    local loop = reaper.GetMediaItemInfo_Value(tk.item, 'B_LOOPSRC') ~= 0
    local pk = peaksFor(tk.take, startQN, lengthQN, pxPerSec, loop)
    if not pk or not pk.hi then
      ps.segment(cx, yTop, cx, yBot, 'arrange.waveform')
      return
    end
    -- A looped take wraps source-time over one period (offset-phased); otherwise
    -- the drawn window maps straight across the sampled span.
    for y = math.floor(yTop), math.floor(yBot) do
      local t = (y - fullTop) / pxPerSec
      local frac = pk.wrap and ((pk.startOffs + t) % pk.srcSec) / pk.srcSec
                            or  t / pk.winSec
      local i   = math.min(pk.cols, math.max(1, math.floor(frac * pk.cols) + 1))
      local hiX = cx + (pk.hi[i] or 0) * hw
      local loX = cx + (pk.lo[i] or 0) * hw
      if hiX - loX < 1 then hiX = loX + 1 end
      ps.segment(loX, y, hiX, y, 'arrange.waveform')
    end
  end

  -- Vertical note bars: channel→X (0..15 absolute), QN→Y. Onset cap marks attacks in legato runs.
  -- yTop/yBot clamp to the visible band so notes past the drawn length don't bleed below.
  local function drawNotes(tk, rx0, rx1, yTop, yBot)
    local notes = tk.notes
    if not notes or #notes == 0 then return end
    local x0, x1 = rx0 + 3, rx1 - 3
    if x1 - x0 < 1 then return end
    for _, nt in ipairs(notes) do
      local onsetY = rowYs(av:qnToRow(tk.startQN + nt.offS))
      local y1     = rowYs(av:qnToRow(tk.startQN + nt.offE))
      if y1 >= yTop and onsetY <= yBot then
        local y0 = onsetY < yTop and yTop or onsetY
        if y1 > yBot then y1 = yBot end
        if y1 - y0 < 1 then y1 = y0 + 1 end
        local x   = x0 + nt.chan / 15 * (x1 - x0)
        ps.segment(x - 1, y0, x - 1, y1, 'arrange.midiNoteBody', 2)
        if onsetY >= yTop then ps.segment(x - 2, onsetY, x + 2, onsetY, 'arrange.midiNoteOn') end
      end
    end
  end

  -- Fill + 1px border; name queued for final pass. Focus = slot focus colours, not thicker border.
  -- blocked paints border red: drag candidate overlaps another take.
  local function drawTakeRect(tk, startQN, lengthQN, headQN, focused, blocked)
    local startRow = av:qnToRow(startQN)
    local endRow   = av:qnToRow(startQN + lengthQN)
    if endRow <= sr or startRow >= sr + visRows then return end
    local rx0, rx1 = colX(tk.trackIdx), colX(tk.trackIdx + 1)
    local visTop, visBot = math.max(startRow, sr), math.min(endRow, sr + visRows)
    local ry0, ry1 = rowYs(visTop), rowYs(visBot)
    local fill   = chrome.slotFill(tk.colourIdx, focused)
    local border = blocked and 'arrange.blockedBorder' or 'arrange.itemBorder'
    ps.fill(rect(rx0 + 1, ry0 + 1, rx1, ry1), fill)
    if tk.kind == 'audio' then
      drawWaveform(tk, startQN, lengthQN, rx0, rx1, ry0 + 1, ry1,
                   rowYs(startRow), rowYs(endRow))
    elseif tk.kind == 'midi' then
      drawNotes(tk, rx0, rx1, ry0 + 1, ry1)
    end
    ps.border(rect(rx0, ry0, rx1 + 1, ry1 + 1), border)
    -- Edge marks: an ellipsis where source is elided and on screen; head leads name, cut trails or folds; beats status bar.
    -- Head, window and cut partition the source: docs/arrangeView.md § Drag geometry: ghost length and fits.
    local sourceQN = (tk.startQN - tk.originQN) + tk.lengthQN + tk.tailQN
    local cutQN    = sourceQN - headQN - lengthQN
    local boxRows = math.floor(visBot - visTop)
    local head    = headQN > 1e-6 and startRow >= sr         and '…'
    local cut     = cutQN  > 1e-6 and endRow <= sr + visRows and '…'
    local cutRow  = cut and boxRows >= 2
    local text    = (head or '') .. (tk.name or '') .. (cut and not cutRow and cut or '')
    if text ~= '' then
      util.add(nameDraws, {
        name = text, rx0 = rx0, rx1 = rx1, ry1 = ry1,
        ry0 = ry0, ty0 = ry0 + 1,
        rows = boxRows - (cutRow and 1 or 0),
      })
    end
    if cutRow then util.add(markDraws,
                            { rx0 = rx0, rx1 = rx1, y = ry1 - rowH + 1, text = cut }) end
  end

  -- Settled takes; takes being moved are held back, painted last at the candidate
  -- range. Duplicate keeps originals here and adds the copies after.
  local moving = {}
  if dragCand and not press.duplicate then
    for _, gh in ipairs(dragCand.ghosts) do moving[gh.take.item] = true end
  end
  local qnLo, qnHi = av:rowToQN(sr), av:rowToQN(sr + visRows)
  for _, tk in ipairs(av:visibleTakes(sc, lastCol, qnLo, qnHi)) do
    if not moving[tk.item] then
      drawTakeRect(tk, tk.startQN, tk.lengthQN, tk.startQN - tk.originQN,
                   selected[tk.take] or (lassoCand and lassoCand.set[tk.take]) or false)
    end
  end
  if dragCand then
    for _, gh in ipairs(dragCand.ghosts) do
      drawTakeRect(gh.take, gh.startQN, gh.lengthQN, gh.headQN, true, not dragCand.fits)
    end
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
      ps.border(rect(gx0, gy0, gx1 + 1, gy1 + 1), 'arrange.ghostBorder')
    end
  end

  -- Rubber band: the in-flight lasso, else the standing Shift+arrow rect. The
  -- lasso's rect is free, not grid-snapped; clip widened to paneR for dead space.
  local band = lassoCand or av:selectBand()
  if band then
    local lx0 = colX(math.max(band.colLo, sc))
    local lx1 = math.min(colX(band.colHi), g.paneR)
    local ly0 = rowYs(math.max(av:qnToRow(band.qnLo), sr))
    local ly1 = rowYs(math.min(av:qnToRow(band.qnHi), sr + visRows))
    if lx1 > lx0 and ly1 > ly0 then
      ps.pushClip(rect(g.paneLeft, oy, g.paneR, oy + g.availH), false)
      ps.fill(rect(lx0, ly0, lx1, ly1), 'band.fill')
      ps.border(rect(lx0, ly0, lx1, ly1), 'band.border')
      ps.popClip()
    end
  end

  -- Cursor column wash: coarse "which track" cue; column only, not a row band, and doesn't
  -- blink. Paints under fills/names — see docs/arrangePage.md § Cursor and focus are separate.
  if curCol >= sc and curCol <= lastCol then
    ps.fill(rect(colX(curCol) + 1, rowYs(sr), colX(curCol + 1), rowYs(sr + visRows)),
            'arrange.cursorWash')
  end

  -- Cursor caret: I-beam on the cursor row's top edge; 2px with serifs so the grid's own
  -- 1px rules don't camouflage it. Blinks ~1s. See docs/arrangePage.md § Cursor and focus are separate.
  local CARET_BLINK = 0.6   -- seconds per on/off half-cycle
  local CARET_THICK, CARET_SERIF = 2, 5
  local caretOn = (reaper.time_precise() % (2 * CARET_BLINK)) < CARET_BLINK
  if curRow >= sr and curRow < sr + visRows
     and curCol >= sc and curCol <= lastCol then
    local cx0, cx1 = colX(curCol), colX(curCol + 1)
    local cy      = rowYs(curRow) - math.floor(CARET_THICK / 2)
    local serifHi, serifLo = cy - CARET_SERIF+1, cy + CARET_SERIF+1
    local caret   = caretOn and 'arrange.cursorOn' or 'arrange.cursorOff'
    ps.segment(cx0, cy, cx1, cy, caret, CARET_THICK)
    ps.segment(cx0, serifHi, cx0, serifLo, caret, CARET_THICK)
    ps.segment(cx1 - CARET_THICK+1, serifHi, cx1 - CARET_THICK+1, serifLo, caret, CARET_THICK)
  end

  -- Loop region: stroked `[` down the gutter left edge, 'tail' colour, no fill.
  -- In-flight gutter drag preempts the committed range so the bracket tracks the mouse.
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

  -- Take names — last, so they stay crisp over the cursor column wash. A name wraps
  -- to one line a grid row, as many as its box holds; the surplus ellipsises on the last line.
  local function widthOf(s) return (ps.measure(s)) end
  for _, nd in ipairs(nameDraws) do
    local lines = painter.wrapLines(nd.name, nd.rx1 - nd.rx0 - 4, math.max(1, nd.rows), widthOf)
    ps.pushClip(rect(nd.rx0 + 2, nd.ry0, nd.rx1 - 2, nd.ry1))
    for i, line in ipairs(lines) do
      local tx = nd.rx0 + math.floor((nd.rx1 - nd.rx0 - widthOf(line)) / 2)
      ps.text(tx, nd.ty0 + (i - 1) * rowH, 'text', line)
    end
    ps.popClip()
  end

  -- Edge marks, in the same final pass as the names so they sit over the cursor wash.
  for _, md in ipairs(markDraws) do
    local tx = md.rx0 + math.floor((md.rx1 - md.rx0 - ps.measure(md.text)) / 2)
    ps.pushClip(rect(md.rx0 + 2, md.y, md.rx1 - 2, md.y + rowH))
    ps.text(tx, md.y, 'text', md.text)
    ps.popClip()
  end

  for r = 0, visRows - 1 do
    local label = rowLabel(sr + r)
    local tw    = ps.measure(label)
    ps.text(ox + QN_W - tw - 4, rowYs(sr + r) + 2, 'text', label)
  end

  -- Header track names sit at the bottom of the band (HEADER_PAD reads as space above),
  -- so a name's last line rests on the divider; gridGeom sized the band to the tallest.
  for c = sc, lastCol do
    local lines = g.headerLabels[c]
    local yTop  = oy + g.headerH - rowH * #lines
    ps.pushClip(rect(colX(c) + 2, oy, colX(c + 1) - 2, oy + g.headerH))
    for i, line in ipairs(lines) do
      local lx = colX(c) + math.floor((TRACK_W - ps.measure(line)) / 2)
      ps.text(lx, yTop + (i - 1) * rowH, 'text', line)
    end
    ps.popClip()
  end

  ps.popClip()

  -- Play head, in the tracker's own yellow; drawn last so nothing hides it,
  -- outside the grid clip so it spans the full pane. Nil while stopped.
  local playQN  = av:playPositionQN()
  local playRow = playQN and av:qnToRow(playQN)
  if playRow and playRow >= sr and playRow < sr + visRows then
    local y = rowYs(playRow)
    ps.segment(g.paneLeft, y, g.paneR, y, 'arrange.playHead')
  end

  -- Advance the ImGui layout cursor so subsequent siblings know we
  -- consumed the grid's footprint.
  ImGui.Dummy(ctx, g.gridW + LOOP_PAD, g.headerH + HEADER_GAP + visRows * rowH)
end

----- Palette pane

-- Locate slot in trackSlots() output (packed array, not indexed by slotIdx).
-- Returns nil when slotIdx is nil or isn't populated.
local function slotEntry(slots, slotIdx)
  if slotIdx == nil then return nil end
  for _, s in ipairs(slots) do
    if s.idx == slotIdx then return s end
  end
  return nil
end

local function paletteTrackLabel(focusedTrack)
  return focusedTrack
    and (focusedTrack.name ~= '' and focusedTrack.name
         or string.format('Track %d', focusedTrack.idx + 1))
    or '(no track)'
end

local function openDeleteModal(trackIdx, slot)
  local key  = av:keyForSlot(slot.idx)
  local name = slot.name ~= '' and slot.name
                              or string.format('(slot %d)', slot.idx)
  modalHost:openConfirm{
    title    = 'Delete slot',
    prompt   = string.format('Delete slot %s "%s"?\nRemoves every instance and discards the parked copy. (y/n)', key, name),
    callback = util.atomic('Delete slot', function(yes) if yes then av:deleteSlot(trackIdx, slot.idx) end end),
  }
end

local function openPruneModal(trackIdx, parked)
  modalHost:openConfirm{
    title    = 'Prune slots',
    prompt   = string.format('Prune %d slot%s with no instance on the grid?\nDiscards each parked copy for good. (y/n)',
                             parked, parked == 1 and '' or 's'),
    callback = util.atomic('Prune slots', function(yes) if yes then av:pruneSlots(trackIdx) end end),
  }
end

-- Length seeds from a drag-sweep when given, else the project-tier newTakeBeats
-- config; the committed length persists back to it.
function openCreateModal(trackIdx, qnPos, beats)
  local slotIdx = av:nextFreeSlot(trackIdx)
  modalHost:open{
    kind     = 'createSlot',
    title    = 'New take',
    nameBuf  = slotIdx and string.format('%02d', slotIdx) or '',
    beatsBuf = tostring(beats or cm:get('newTakeBeats')),
    callback = util.atomic('Create take', function(nameBuf, beatsBuf)
      local b = math.max(1e-3, tonumber(beatsBuf) or cm:get('newTakeBeats'))
      cm:set('project', 'newTakeBeats', b)
      av:createSlot(trackIdx, qnPos, b, nameBuf)
    end),
  }
end

-- Two-field create modal: name + length-in-beats.
modalHost:registerKind('createSlot', function(s, close)
  ImGui.Text(ctx, 'Name')
  if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
  local rvN, nb = ImGui.InputText(ctx, '##createName', s.nameBuf)
  if rvN then s.nameBuf = nb end
  ImGui.Text(ctx, 'Length (beats)')
  local rvB, bb = ImGui.InputText(ctx, '##createBeats', s.beatsBuf)
  if rvB then s.beatsBuf = bb end
  local ok = ImGui.Button(ctx, 'OK')
  ImGui.SameLine(ctx)
  local cancel = ImGui.Button(ctx, 'Cancel')
  if ok or modalHost:takeEnter() then close(true, s.nameBuf, s.beatsBuf)
  elseif cancel or modalHost:takeEscape() then close(false) end
end)

-- The tidy editor. A row's dropdown assigns its slot to a base, and '(keep)' drops it from
-- the assignment, pinning the name it holds; the base list above is edited in place.
local TIDY_KEEP = '(keep)'
-- The base list's fields take a fixed width; the row list caps at TIDY_MAX_ROWS,
-- and the modal auto-fits around the two.
local TIDY_BASE_W, TIDY_LIST_W, TIDY_MAX_ROWS = 170, 340, 14
local TIDY_GUTTER = 8   -- half the gap between columns, which hug their text

local function openTidyModal(trackIdx)
  local bases, assignment = av:seedTidy(trackIdx)
  modalHost:open{
    kind       = 'tidyTrack',
    title      = 'Tidy slot names',
    trackIdx   = trackIdx,
    bases      = bases,
    assignment = assignment,
    newBase    = '',
    callback   = util.atomic('Tidy slots', function(committed)
      av:tidySlots(trackIdx, committed)
    end),
  }
end

-- One base field is active at a time, so a single scratch buffer serves the list, and the
-- edit lands after the walk, as a row's pick does; see docs/arrangePage.md § The tidy editor.
local function drawBaseList(s)
  local edit
  local dropW = ImGui.GetFrameHeight(ctx)

  for i, base in ipairs(s.bases) do
    ImGui.SetNextItemWidth(ctx, TIDY_BASE_W)
    local editing = s.editing and s.editing.index == i
    local rv, buf = ImGui.InputText(ctx, '##base' .. i, editing and s.editing.buf or base)
    if rv then s.editing = { index = i, buf = buf } end
    if ImGui.IsItemDeactivatedAfterEdit(ctx) and s.editing then
      edit = { rename = { from = base, to = s.editing.buf } }
    end
    -- The Enter that deactivated the field belongs to it, so the footer below cannot commit
    -- the tidy on the same press.
    if ImGui.IsItemDeactivated(ctx) then s.editing = nil; modalHost:takeEnter() end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, '\xc3\x97##dropBase' .. i, dropW, 0) then edit = { drop = base } end
  end
  if #s.bases == 0 then ImGui.TextDisabled(ctx, '(none)') end

  ImGui.SetNextItemWidth(ctx, TIDY_BASE_W)
  -- No EnterReturnsTrue: that flag hands back the buffer only on the frame it fires, so
  -- the Add button would read stale text; Enter still deactivates the field, watched for below.
  local _, newBuf = ImGui.InputTextWithHint(ctx, '##newBase', 'new base', s.newBase)
  s.newBase = newBuf
  local entered = ImGui.IsItemDeactivated(ctx) and modalHost:takeEnter()
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, 'Add') or entered then edit = { add = s.newBase } end

  if not edit then return end
  if edit.add    then av:tidyAddBase(s.bases, edit.add); s.newBase = '' end
  if edit.drop   then av:tidyDropBase(s.bases, s.assignment, edit.drop) end
  if edit.rename then av:tidyRenameBase(s.bases, s.assignment, edit.rename.from, edit.rename.to) end
end

-- Plain dimmed labels rather than TableHeadersRow, whose filled bar clashes with the flat chrome.
local TIDY_COLS = { 'Key', 'Name', 'Base', 'Becomes' }

local function drawTidyLabels()
  ImGui.TableNextRow(ctx)
  for _, label in ipairs(TIDY_COLS) do
    ImGui.TableNextColumn(ctx)
    ImGui.TextDisabled(ctx, label)
  end
end

modalHost:registerKind('tidyTrack', function(s, close)
  chrome.headingLabel('Bases')
  drawBaseList(s)
  ImGui.Separator(ctx)

  -- The rows are a snapshot, so a pick lands after the walk and shows next frame.
  local rows  = av:tidyRows(s.trackIdx, s.assignment)
  local listH = math.min(#rows + 1, TIDY_MAX_ROWS) * ImGui.GetFrameHeightWithSpacing(ctx) + 4
  -- Every row offers the same items, so the dropdowns size alike and the column stays flush.
  local items = { TIDY_KEEP }
  for _, base in ipairs(s.bases) do util.add(items, base) end

  local pick
  local _, padY = ImGui.GetStyleVar(ctx, ImGui.StyleVar_CellPadding)
  if ImGui.BeginChild(ctx, '##tidyRows', TIDY_LIST_W, listH) then
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_CellPadding, TIDY_GUTTER, padY)
    if ImGui.BeginTable(ctx, '##tidyList', 4) then
      -- A base is a prefix of the names either side of it, so every column hugs its
      -- content and only the last takes up the slack.
      ImGui.TableSetupColumn(ctx, 'Key',     ImGui.TableColumnFlags_WidthFixed, SLOT_KEY_W)
      ImGui.TableSetupColumn(ctx, 'Name',    ImGui.TableColumnFlags_WidthFixed)
      ImGui.TableSetupColumn(ctx, 'Base',    ImGui.TableColumnFlags_WidthFixed)
      ImGui.TableSetupColumn(ctx, 'Becomes', ImGui.TableColumnFlags_WidthStretch)
      drawTidyLabels()

      for _, row in ipairs(rows) do
        ImGui.TableNextRow(ctx)
        ImGui.TableSetColumnIndex(ctx, 0)
        ImGui.AlignTextToFramePadding(ctx)
        if monoFont then ImGui.PushFont(ctx, monoFont, uiSize) end
        ImGui.Text(ctx, row.key)
        if monoFont then ImGui.PopFont(ctx) end

        ImGui.TableSetColumnIndex(ctx, 1)
        ImGui.AlignTextToFramePadding(ctx)
        ImGui.Text(ctx, row.name ~= '' and row.name or string.format('(slot %d)', row.idx))

        ImGui.TableSetColumnIndex(ctx, 2)
        local picked = chrome.dropdown('tidyBase' .. row.idx, row.base or TIDY_KEEP, items)
        -- Item 1 is '(keep)', which drops the slot from the assignment.
        if picked then pick = { idx = row.idx, base = picked > 1 and items[picked] or nil } end

        ImGui.TableSetColumnIndex(ctx, 3)
        ImGui.AlignTextToFramePadding(ctx)
        -- A preview matching the name it replaces is a no-op; dim it, so what a
        -- commit actually writes is what stands out.
        if row.preview == row.name then ImGui.TextDisabled(ctx, row.preview)
        else ImGui.Text(ctx, row.preview) end
      end
      ImGui.EndTable(ctx)
    end
    ImGui.PopStyleVar(ctx, 1)
  end
  ImGui.EndChild(ctx)
  if pick then s.assignment[pick.idx] = pick.base end

  local padX  = ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
  local gapX  = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing)
  local pairW = ImGui.CalcTextSize(ctx, 'OK') + ImGui.CalcTextSize(ctx, 'Cancel') + padX * 4 + gapX
  ImGui.SetCursorPosX(ctx, (ImGui.GetWindowWidth(ctx) - pairW) / 2)

  local ok = ImGui.Button(ctx, 'OK')
  ImGui.SameLine(ctx)
  local cancel = ImGui.Button(ctx, 'Cancel')
  if ok or modalHost:takeEnter() then close(true, s.assignment)
  elseif cancel or modalHost:takeEscape() then close(false) end
end)

-- Rename and delete are keyboard gestures on the cursor take; prune and tidy are the
-- palette verbs with no take to stand on, so they live here.
local function renderPaletteActions(focusedTrack, slots)
  local parked, midi = 0, 0
  for _, slot in ipairs(slots) do
    if slot.parked then parked = parked + 1 end
    if slot.kind == 'midi' then midi = midi + 1 end
  end
  chrome.disabledIf(parked == 0, function()
    if ImGui.Button(ctx, 'prune##slots') then
      openPruneModal(focusedTrack.idx, parked)
    end
  end)
  ImGui.SameLine(ctx, 0, 4)
  chrome.disabledIf(midi == 0, function()
    if ImGui.Button(ctx, 'tidy##slots') then
      openTidyModal(focusedTrack.idx)
    end
  end)
end

-- Three columns: key (monospace — hotkey), kind glyph, name (UI font).
-- Selectable in col 0 with SpanAllColumns; key text painted on top via SameLine.
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

local function renderPaletteBody(focusedTrack)
  local slots = focusedTrack and av:trackSlots(focusedTrack.idx) or {}
  renderPaletteActions(focusedTrack, slots)
  ImGui.Separator(ctx)
  renderPaletteList(slots)
end

---------- PUBLIC

--shape: ToolbarSegment = { id, heading? (presence = collapsible), render = fn(), visible? = fn() -> bool, pickers? }
local toolbarSegments = {
  {
    id = 'followPlay',
    render = function()
      local changed, on = chrome.checkbox('Follow play', av:followsPlay())
      if changed then av:setFollowPlay(on) end
    end,
  },
}

function ar:toolbarSegments() return toolbarSegments end

----- F1 help placements — modes and zoom pin, the rest flow over the body
-- The modes callout pins under its toolbar checkbox, the zoom pair under the
-- beats/row cell. See docs/help.md § What's where.

help:registerPage('arrange', {
  { group = 'Modes',      anchor = 'toolbar.followPlay', place = 'pin'  },
  { group = 'View',       anchor = 'status.beatPerRow',  place = 'pin'  },
  { group = 'Movement',   anchor = 'body',               place = 'flow' },
  { group = 'Selection',  anchor = 'body',               place = 'flow' },
  { group = 'Takes',      anchor = 'body',               place = 'flow' },
  { group = 'Slots',      anchor = 'body',               place = 'flow' },
  { group = 'Advance',    anchor = 'body',               place = 'flow' },
  { group = 'Loop',       anchor = 'body',               place = 'flow' },
  { group = 'Transport',  anchor = 'body',               place = 'flow' },
  { group = 'Pages',      anchor = 'body',               place = 'flow' },
  { group = 'Global',     anchor = 'body',               place = 'flow' },
})

--invariant: grid is hand-drawn (no ImGui table) — tints, gridlines, take rects, cursor on top.
--contract: pushes parchment body palette (coord popped chrome before); palette tables need it.
--contract: invokes dispatch at end-of-body so arrange-scope keys reach the dispatcher.
function ar:renderBody(_, w, h, dispatch)
  if not ctx then return end

  pushBodyStyles()

  local ox, oy = ImGui.GetCursorScreenPos(ctx)
  help:anchor('body', ox, oy, w, h)

  local tracks  = av:projectTracks()
  local nTracks = #tracks
  if nTracks == 0 then
    ImGui.Text(ctx, '(no tracks in project)')
    av:setGridSize(0, 0)
    popBodyStyles()
    if dispatch then dispatch(self:focusState()) end
    return
  end

  local gridW = chrome.gridWidth(w)
  -- NoNav suppresses the blue nav rect from Tab/arrow focus; NoScroll*
  -- stop the wheel nudging the child — we route the wheel to the cursor.
  if ImGui.BeginChild(ctx, '##arrangeGrid', gridW, h,
                      ImGui.ChildFlags_None,
                      ImGui.WindowFlags_NoNav
                      | ImGui.WindowFlags_NoScrollWithMouse
                      | ImGui.WindowFlags_NoScrollbar) then
    -- The grid reads the mouse directly, bypassing the dispatcher coord suppresses,
    -- so the cheat-sheet gates it here. See docs/help.md § Input while open.
    local dragCand, loopCand, createCand, lassoCand
    if not help:wasOpenAtFrameStart() then
      dragCand, loopCand, createCand, lassoCand = handleGridMouse(tracks)
    end
    renderGrid(tracks, dragCand, loopCand, createCand, lassoCand)
  end
  ImGui.EndChild(ctx)

  local focusedTrack = tracks[av:cursorCol() + 1]
  chrome.palettePane{
    x = ox + gridW, y = oy, h = h,
    label = paletteTrackLabel(focusedTrack),
    draw  = function() renderPaletteBody(focusedTrack) end,
  }

  popBodyStyles()
  if dispatch then dispatch(self:focusState()) end
end

----- Status bar

-- The beats behind the cursor take's edge marks: the grid says an edge is trimmed,
-- and how much it hides is read back here. Empty over an untrimmed take or empty space.
local function trimReadout()
  local tk = av:cursorTake()
  if not tk then return '' end
  local head, tail = tk.startQN - tk.originQN, tk.tailQN
  local parts = {}
  if head > 1e-6 then util.add(parts, string.format('%g above', head)) end
  if tail > 1e-6 then util.add(parts, string.format('%g below', tail)) end
  return table.concat(parts, ', ')
end

-- Length mode names the step it stands in front of, so Ctrl+digit reads back while armed.
-- The step alone is the value, so an edit opens on the number rather than the wording.
local function advanceReadout(step)
  return cm:get('arrangeAdvanceByLength')
     and string.format('take length or %d', step) or tostring(step)
end

local setAdvance = util.atomic('Set advance', function(n) cm:set('project', 'arrangeAdvanceBy', n) end)

local statusSegments = {
  { id = 'row',        label = 'Row',       width = 20,  get = function() return av:cursorRow()  end, format = '%d' },
  { id = 'col',        label = 'Col',       width = 20,  get = function() return av:cursorCol()  end, format = '%d' },
  { id = 'beatPerRow', label = 'Beats/row', width = 20,  get = function() return av:beatPerRow() end, format = '%g',
    set = function(n) av:setBeatPerRow(n) end,
    edit = { kind = 'number', min = 1/4, max = 64, step = 'x2', format = '%g' } },
  { id = 'advance',    label = 'Advance',   width = 20,  get = function() return cm:get('arrangeAdvanceBy') end,
    format = advanceReadout,
    set = setAdvance, edit = { kind = 'number', min = 0, max = 9, format = '%d' } },
  { id = 'trim',       label = 'Trim',      width = 115, get = trimReadout,
    visible = function() return trimReadout() ~= '' end },
  { id = 'replace',    width = 70, get = function() return 'REPLACE' end,
    visible = function() return av:replaceArmed() end },
}

function ar:statusSegments()
  if not ctx then return {} end
  return statusSegments
end

--contract: acceptCmds=false if any item is active; a modal owns the queue instead of gating here.
function ar:focusState()
  if not ctx then return { acceptCmds = false } end
  return { acceptCmds = not ImGui.IsAnyItemActive(ctx) }
end


--invariant: createSlot (Ctrl+Enter) opens the create modal — the only slot-minting gesture.
--invariant: deleteSlot (Ctrl+Delete) takes the slot of the cursor take; the palette carries
-- no per-slot verbs, only prune.
-- cmgr:scope is idempotent — same scope av registers into.
local arrange = cmgr:scope('arrange')

arrange:registerAll {
  createSlot = function()
    openCreateModal(av:cursorCol(), av:rowToQN(av:cursorRow()))
  end,
  deleteSlot = function()
    local trackIdx = av:cursorCol()
    local slot     = slotEntry(av:trackSlots(trackIdx), av:cursorSlot())
    if slot then openDeleteModal(trackIdx, slot) end
  end,
  -- Page-prefixed because the tracker scope registers a toggleFollowPlay of its
  -- own; cmgr.commands is flat, so the shared name clobbered this one's gate.
  arrangeFollowPlay = function() av:setFollowPlay(not av:followsPlay()) end,
}

return ar
