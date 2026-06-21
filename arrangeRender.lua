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
local cm, cmgr, chrome, gui, modalHost, av =
  (...).cm, (...).cmgr, (...).chrome, (...).gui, (...).modalHost, (...).av

local ctx = gui and gui.ctx or nil
-- gui.font is monospace (Source Code Pro) attached at context create;
-- we push it for the slot-key cell so 62 base62 keys align in a column.
local monoFont = gui and gui.font or nil
local uiSize   = gui and gui.fontSize and gui.fontSize.ui or 12

local ar = {}

local QN_W, TRACK_W = 32, 72
-- Empty band between gutter numbers (right-aligned at QN_W) and the first
-- gridline; wide enough to host the edit-cursor / play-head triangles.
local GUTTER_PAD = 14
-- The loop bracket strokes down the left edge; the grid shifts LOOP_PAD right to clear it.
-- Must exceed the bracket radius (5) plus its 1.5px stroke.
local LOOP_PAD = 7
-- Palette row column widths: monospace key, kind glyph, name fills.
local SLOT_KEY_W, SLOT_KIND_W = 18, 16

-- Forward decl: runGridMouse (in renderGrid below) calls openCreateModal, defined further down.
local openCreateModal

--shape: press = { qn, row, col, take, mode = 'move'|'resizeEnd', duplicate, moved, gutter, create } — nil when no button down. Track-col: take/row/col/mode; gutter: qn+gutter=true; dbl-click: qn/col+create=true. moved flips at drag threshold.
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
local function drainWheel(accum, wheel, step)
  accum = accum + wheel * step
  local step = (accum >= 0 and math.floor or math.ceil)(accum)
  return accum - step, step
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

-- Per-takeId fill pair { fill, focusFill } off colourIdx; focus brightens to read
-- without losing hue. Borders are a uniform neutral, drawn by renderGrid.
local SLOT_FILL_ALPHA = 1
local colourCache = {}
local function slotFill(colourIdx, focused)
  if colourIdx == nil then
    return focused and 'arrange.orphanFocusFill' or 'arrange.orphanFill'
  end
  local pair = colourCache[colourIdx]
  if not pair then
    pair = {
      painter.hue(colourIdx, 0.08, 0.77, SLOT_FILL_ALPHA),
      painter.hue(colourIdx, 0.1,  0.84, SLOT_FILL_ALPHA),
    }
    colourCache[colourIdx] = pair
  end
  return focused and pair[2] or pair[1]
end

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

-- Grid header geometry; must match chrome's palette-header HEADER_PAD/HEADER_GAP
-- so the grid and palette dividers line up across PANE_GAP.
local HEADER_PAD = 8
local HEADER_GAP = 4

-- Snap a click's QN down to the top edge of the row box it sits in.
local function floorTo(v, step) return math.floor(v / step) * step end

-- Shared (col,row)→screen transform for mouse pass and paint pass: both call gridGeom at the
-- same layout-cursor position, so hit-test and draw resolve through one mapping.
local function gridGeom(nTracks)
  local paneLeft, oy   = ImGui.GetCursorScreenPos(ctx)
  local ox             = paneLeft + LOOP_PAD
  local availW, availH = ImGui.GetContentRegionAvail(ctx)
  local rowH           = math.ceil(math.max(1, ImGui.GetTextLineHeightWithSpacing(ctx)))
  local headerH        = rowH + HEADER_PAD
  local bodyTop        = oy + headerH + HEADER_GAP
  local visRows        = math.max(1, math.floor((oy + availH - bodyTop) / rowH))
  local sr, sc         = av:scroll()
  sr, sc               = sr or 0, sc or 0
  local bandLeft       = ox + QN_W + GUTTER_PAD   -- fixed: left edge of the scrolling column band
  local paneR          = paneLeft + availW
  local visCols        = math.max(1, math.floor((paneR - bandLeft) / TRACK_W))
  local pg = painter.new(ctx, chrome, {
    ox = bandLeft - sc * TRACK_W, oy = bodyTop - sr * rowH,
    sx = TRACK_W, sy = rowH, snap = true,
  }, 'arrange')
  return {
    pg = pg, paneLeft = paneLeft, ox = ox, oy = oy, availH = availH,
    rowH = rowH, headerH = headerH, bodyTop = bodyTop,
    bodyBot = bodyTop + visRows * rowH, visRows = visRows, sr = sr,
    sc = sc, visCols = visCols,
    lastCol = math.min(nTracks - 1, sc + visCols),
    gutterR = pg.ox + sc * TRACK_W,                        -- fixed gutter right / band left edge
    paneR   = paneR,
    gridR   = math.min(pg.ox + nTracks * TRACK_W, paneR),  -- visible right edge of the band
    gridW   = paneR - paneLeft,                            -- visible footprint (Dummy)
  }
end

-- Runs before renderGrid so in-flight drag/loop/create candidates are ready for the paint pass.
-- Must run inside ##arrangeGrid so IsWindowHovered resolves correctly.
local function handleGridMouse(nTracks)
  local g  = gridGeom(nTracks)
  local pg = g.pg

  av:setGridSize(g.visRows, g.visCols)
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
      local mods      = ImGui.GetKeyMods(ctx)
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

local function renderGrid(tracks, nTracks, dragCand, loopCand, createCand, lassoCand)
  local g  = gridGeom(nTracks)
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
  -- Three passes (fills → cursor fill → names) so names stay crisp over the cursor tint.
  local selected = av:selectionSet()
  local nameDraws = {}
  local truncDraws = {}   -- ellipsis decoration for items truncated below natural

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
  local function drawTakeRect(tk, startQN, lengthQN, focused, blocked)
    local startRow = av:qnToRow(startQN)
    local endRow   = av:qnToRow(startQN + lengthQN)
    if endRow <= sr or startRow >= sr + visRows then return end
    local rx0, rx1 = colX(tk.trackIdx), colX(tk.trackIdx + 1)
    local ry0 = rowYs(math.max(startRow, sr))
    local ry1 = rowYs(math.min(endRow, sr + visRows))
    local fill   = slotFill(tk.colourIdx, focused)
    local border = blocked and 'arrange.blockedBorder' or 'arrange.itemBorder'
    ps.fill(rect(rx0 + 1, ry0 + 1, rx1, ry1), fill)
    if tk.kind == 'audio' then
      drawWaveform(tk, startQN, lengthQN, rx0, rx1, ry0 + 1, ry1,
                   rowYs(startRow), rowYs(endRow))
    elseif tk.kind == 'midi' then
      drawNotes(tk, rx0, rx1, ry0 + 1, ry1)
    end
    ps.border(rect(rx0, ry0, rx1 + 1, ry1 + 1), border)
    if tk.name and tk.name ~= '' then
      nameDraws[#nameDraws + 1] = {
        name = tk.name, rx0 = rx0, rx1 = rx1, ry0 = ry0, ry1 = ry1,
      }
    end
    -- Truncation indicator: downstream take cuts this one short. Show only when box > 1 row
    -- so the ellipsis doesn't displace the name.
    if lengthQN + 1e-6 < tk.naturalLenQN and endRow - startRow > 1 then
      truncDraws[#truncDraws + 1] = { rx0 = rx0, rx1 = rx1, ry1 = ry1 }
    end
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
      drawTakeRect(tk, tk.startQN, tk.lengthQN,
                   selected[tk.take] or (lassoCand and lassoCand.set[tk.take]) or false)
    end
  end
  if dragCand then
    for _, gh in ipairs(dragCand.ghosts) do
      drawTakeRect(gh.take, gh.startQN, gh.lengthQN, true, not dragCand.fits)
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

  -- Lasso rubber band: free rect anchored at the press and drag points, not
  -- grid-snapped; clip widened to paneR so it can reach the dead space.
  if lassoCand then
    local lx0 = colX(math.max(lassoCand.colLo, sc))
    local lx1 = math.min(colX(lassoCand.colHi), g.paneR)
    local ly0 = rowYs(math.max(av:qnToRow(lassoCand.qnLo), sr))
    local ly1 = rowYs(math.min(av:qnToRow(lassoCand.qnHi), sr + visRows))
    if lx1 > lx0 and ly1 > ly0 then
      ps.pushClip(rect(g.paneLeft, oy, g.paneR, oy + g.availH), false)
      ps.fill(rect(lx0, ly0, lx1, ly1), 'band.fill')
      ps.border(rect(lx0, ly0, lx1, ly1), 'band.border')
      ps.popClip()
    end
  end

  -- Cursor caret: horizontal I-beam on the top edge of the cursor row.
  -- Cell-shaped highlight would lie about the model; blinks ~1s so it stays findable.
  local CARET_BLINK = 0.75   -- seconds per on/off half-cycle
  local caretOn = (reaper.time_precise() % (2 * CARET_BLINK)) < CARET_BLINK
  if curRow >= sr and curRow < sr + visRows
     and curCol >= sc and curCol <= lastCol then
    local cx0, cx1 = colX(curCol), colX(curCol + 1)
    local cy    = rowYs(curRow)
    local serif = 2
    local caret = caretOn and 'arrange.cursorOn' or 'arrange.cursorOff'
    ps.segment(cx0, cy,         cx1, cy,         caret)
    ps.segment(cx0, cy - serif, cx0, cy + serif+1, caret)
    ps.segment(cx1, cy - serif, cx1, cy + serif+1, caret)
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

  -- Take names — last, so they stay crisp over the translucent cursor
  -- fill.
  for _, nd in ipairs(nameDraws) do
    local tw = ps.measure(nd.name)
    local tx = nd.rx0 + math.floor((nd.rx1 - nd.rx0 - tw) / 2)
    ps.pushClip(rect(nd.rx0 + 2, nd.ry0, nd.rx1 - 2, nd.ry1))
    ps.text(tx, nd.ry0 + 1, 'text', nd.name)
    ps.popClip()
  end

  -- Truncation ellipsis: bottom-row glyph for items shortened below natural length.
  -- Final-pass draw so it sits over the cursor fill.
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
    local apex = g.gutterR - 2
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
    ps.text(ox + QN_W - tw - 4, rowYs(sr + r) + 2, 'text', label)
  end

  -- Header track names at the bottom of the header band (HEADER_PAD reads as space above).
  -- Clipped at cell edges so long names ellipsise rather than spill.
  local headerTextY = oy + HEADER_PAD
  for c = sc, lastCol do
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

-- Locate slot in trackSlots() output (packed array, not indexed by slotIdx).
-- Returns nil when no slot is focused or the focused slot index isn't populated.
local function focusedSlotEntry(slots, slotIdx)
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
    prompt   = string.format('Delete slot %s "%s"?\nRemoves every instance and discards the parked copy. (y/n)', key, name),
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

-- The tracker's "new take below" gesture, owned here so it shares the
-- createSlot modal; the cursor lands on the new take and the tracker rebinds.
local NEW_TAKE_DEFAULT_BEATS = 4
local function arrangeNewTakeBelow()
  local params = av:newTakeBelowParams(); if not params then return end
  modalHost:open{
    kind     = 'createSlot',
    title    = 'New take',
    nameBuf  = '',
    beatsBuf = tostring(NEW_TAKE_DEFAULT_BEATS),
    callback = util.atomic('Create take', function(nameBuf, beatsBuf)
      local b = math.max(1e-3, tonumber(beatsBuf) or NEW_TAKE_DEFAULT_BEATS)
      av:createTakeBelow(params.trackIdx, params.destQN, b, nameBuf)
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
  local slots       = focusedTrack and av:trackSlots(focusedTrack.idx) or {}
  local focusedSlot = focusedSlotEntry(slots, av:paletteSlot())
  renderPaletteActions(focusedTrack, focusedSlot)
  ImGui.Separator(ctx)
  renderPaletteList(slots)
end

----------- PUBLIC

-- The controller's 'arrange' facade routes its newTakeBelow entry here so the
-- gesture shares the createSlot modal that lives with the rest of the renderer.
function ar:newTakeBelow() arrangeNewTakeBelow() end

--shape: ToolbarSegment = { id, render = fn() }
local toolbarSegments = {
  {
    id = 'followPlay',
    render = function()
      local changed, on = chrome.checkbox('Follow play', av:followsPlay())
      if changed then av:setFollowPlay(on) end
    end,
  },
  {
    id = 'beatsPerRow',
    render = function()
      ImGui.AlignTextToFramePadding(ctx)
      chrome.headingLabel('BPR')
      ImGui.SameLine(ctx, 0, 8)
      local changed, n = chrome.numberStepper('bpr', av:beatPerRow(),
        { min = 1/4, max = 64, format = '%g', digits = 4, align = 'center' })
      if changed then av:setBeatPerRow(n) end
    end,
  },
}

function ar:toolbarSegments() return toolbarSegments end

--invariant: grid is hand-drawn (no ImGui table) — tints, gridlines, take rects, cursor on top.
--contract: pushes parchment body palette (coord popped chrome before); palette tables need it.
--contract: invokes dispatch at end-of-body so arrange-scope keys reach the dispatcher.
function ar:renderBody(_, w, h, dispatch)
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

  local ox, oy = ImGui.GetCursorScreenPos(ctx)
  local gridW  = chrome.gridWidth(w)
  -- NoNav suppresses the blue nav rect from Tab/arrow focus; NoScroll*
  -- stop the wheel nudging the child — we route the wheel to the cursor.
  if ImGui.BeginChild(ctx, '##arrangeGrid', gridW, h,
                      ImGui.ChildFlags_None,
                      ImGui.WindowFlags_NoNav
                      | ImGui.WindowFlags_NoScrollWithMouse
                      | ImGui.WindowFlags_NoScrollbar) then
    local dragCand, loopCand, createCand, lassoCand = handleGridMouse(nTracks)
    renderGrid(tracks, nTracks, dragCand, loopCand, createCand, lassoCand)
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

function ar:renderStatusBar(_)
  if not ctx then return end
  ImGui.Text(ctx, string.format(
    'arrange | row %d  col %d  | %g beats/row | Advance: %d',
    av:cursorRow(), av:cursorCol(), av:beatPerRow(),
    cm:get('arrangeAdvanceBy')))
end

--contract: acceptCmds=false if picker active, any item active, or modal was open at frame start.
function ar:focusState()
  if not ctx then return { suppressKbd = false, acceptCmds = false } end
  local pa = chrome and chrome.pickerIsActive() or false
  return {
    suppressKbd = pa,
    acceptCmds  = (not pa)
                  and not ImGui.IsAnyItemActive(ctx)
                  and not modalHost:wasOpenAtFrameStart(),
  }
end


--invariant: createSlot (Ctrl+Enter) opens the create modal — the only slot-minting gesture.
-- cmgr:scope is idempotent — same scope av registers into.
local arrange = cmgr:scope('arrange')

arrange:registerAll {
  createSlot = function()
    openCreateModal(av:cursorCol(), av:rowToQN(av:cursorRow()))
  end,
  toggleFollowPlay = function() av:setFollowPlay(not av:followsPlay()) end,
  arrangeSetBeatPerRow = function()
    modalHost:openPrompt{
      title    = 'Beats per row',
      prompt   = '0.25 – 64',
      buf      = tostring(av:beatPerRow()),
      callback = function(buf)
        local n = tonumber(buf); if n then av:setBeatPerRow(n) end
      end,
    }
  end,
}

-- Cursor-nav and take-edit commands reuse the tracker scope's keys but not its names:
-- cmgr.commands is flat, so a shared name would overwrite the other scope's gate.
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
  arrangeDeleteAdvance          = { ImGui.Key_Period },
  arrangeDive                   = { ImGui.Key_Enter },
  arrangeTakeProperties         = { { ImGui.Key_Backspace, ImGui.Mod_Super } },
  arrangeDuplicateBelow         = { { ImGui.Key_D, ImGui.Mod_Ctrl } },
  arrangeDuplicateUnpooledBelow = { { ImGui.Key_Enter, ImGui.Mod_Super, ImGui.Mod_Shift } },
  arrangeSetLoopStart           = { { ImGui.Key_B, ImGui.Mod_Ctrl } },
  arrangeSetLoopEnd             = { { ImGui.Key_E, ImGui.Mod_Ctrl } },
  arrangePlayFromCursor         = { ImGui.Key_F6 },
  toggleFollowPlay              = { { ImGui.Key_F, ImGui.Mod_Super } },
  arrangeClearLoop              = { ImGui.Key_Escape },
  arrangeClearSelection         = { { ImGui.Key_G, ImGui.Mod_Ctrl } },
  arrangeZoomIn                 = { { ImGui.Key_Equal, ImGui.Mod_Super } },
  arrangeZoomOut                = { { ImGui.Key_Minus, ImGui.Mod_Super } },
  arrangeSetBeatPerRow          = { { ImGui.Key_Z,     ImGui.Mod_Super } },
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
for i = 0, 9 do
  binds['arrangeAdvanceBy' .. i] = { { ImGui.Key_0 + i, ImGui.Mod_Ctrl } }
end
arrange:bindAll(binds)

return ar
