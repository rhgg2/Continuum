-- See docs/trackerPage.md for the model. The grid + lane render core, lifted
-- out of trackerRender (P1, design/fx-patterns.md). The host wires it with tv
-- + the shared services and an inputAllowed() gate, and keeps the toolbar,
-- param palette, fx strip, commands and the renderBody orchestration.

--invariant: grid render + input only; tracker state lives in tv/ec, never cached here
--invariant: col.x == nil is the visibility predicate; per-column draws must gate on it
--invariant: cell coords 0-indexed; header rows at -HEADER, row-num gutter at -GUTTER
--invariant: page-persistent state: gridX/Y, dragging, laneConsumed, paintLast
--contract: host supplies inputAllowed() -- folds modal/picker/item-active/palette/strip gates
local util   = require 'util'
local groups = require 'groups'

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui   = require 'imgui' '0.10'
local painter = require 'painter'

local cm, cmgr, chrome, gui, tv, inputAllowed =
  (...).cm, (...).cmgr, (...).chrome, (...).gui, (...).tv, (...).inputAllowed

---------- PRIVATE

local GUTTER      = 5    -- in grid chars: 3-char row num + spacer + region slot
local HEADER      = 3    -- header rows, fixed; vertical param names truncate to fit, never grow it

local gridX       = nil
local gridY       = nil
local gridOriginX = 0
local gridOriginY = 0
local gridWidth   = 0
local gridHeight  = 0
local gridPainter = nil   -- cell painter, rebuilt each frame in drawTracker; hit-test reads its fromScreen so draw and hit can't drift

local chanX, chanW, chanOrder, totalWidth = {}, {}, {}, 0

--contract: clears col.x on every col before assigning; off-screen cols stay nil
local function layoutColumns(cols, scrollCol)
  for _, col in ipairs(cols) do col.x = nil end
  local cX, cW, cOrder = {}, {}, {}
  local cx = 0
  for i = scrollCol, #cols do
    local col = cols[i]
    if cx + col.width > gridWidth then break end
    col.x = cx
    local chan = col.midiChan
    if cX[chan] == nil then
      cX[chan] = cx
      util.add(cOrder, chan)
    end
    cW[chan] = (cx + col.width) - cX[chan]
    cx = cx + col.width + 1
  end
  return cX, cW, cOrder, math.max(0, cx - 1)
end

local ctx, font, uiFont = gui.ctx, gui.font, gui.uiFont
local dragging    = false   -- tracker-grid selection drag: click → held → release
local curveEditor = util.instantiate('curveEditor', { ctx = ctx, chrome = chrome, page = 'tracker' })
local laneConsumed = false

local paintLast   = nil     -- region-paint per-cell debounce

----- Cell renderers

local function renderNote(evt, col, row)
  local function noteName(pitch)
    local NOTE_NAMES = {'C-','C#','D-','D#','E-','F-','F#','G-','G#','A-','A#','B-'}
    local oct = math.floor(pitch / 12) - 1
    local octChar = oct >= 0 and tostring(oct) or 'M'
    return NOTE_NAMES[(pitch % 12) + 1] .. octChar
  end

  local function rightAlign(s, w)
    local pad = w - utf8.len(s)
    return pad > 0 and string.rep(' ', pad) .. s or s
  end

  local showDelay   = col and col.showDelay
  local showSample  = col and col.trackerMode
  local cellWidth   = tv:cellWidth()
  local octaveWidth = tv:octaveWidth()
  local blank      = string.rep('·', cellWidth)   -- cellWidth dots = empty pitch field

  if not evt then
    local s = blank .. (showSample and ' ··' or '') .. ' ··'
    if showDelay then s = s .. ' ···' end
    return s
  end

  local label
  if evt.evType ~= 'pa' then
    local note, octave = tv:noteProjection(evt)
    if note then
      -- Both parts right-aligned in their own fields (note field = cellWidth -
      -- octaveWidth) so the separator and octave units keep fixed columns.
      label = rightAlign(note, cellWidth - octaveWidth) .. rightAlign(octave, octaveWidth)
    else
      label = rightAlign(noteName(evt.pitch), cellWidth)
    end
  end
  local isPA      = evt.evType == 'pa'
  local noteTxt   = isPA and blank or label
  local velTxt    = evt.vel and string.format('%02X', evt.vel) or '··'
  local sampleTxt = showSample and (' ' .. (isPA and '··' or string.format('%02X', evt.sample or 0))) or ''
  local text      = noteTxt .. sampleTxt .. ' ' .. velTxt

  -- Sample digits at cellWidth+2, +3 (after note label + trailing space).
  -- Shadowed and negative-delay overrides occupy disjoint ranges.
  local overrides
  if showSample and evt.sampleShadowed then
    overrides = { [cellWidth + 2] = 'shadowed', [cellWidth + 3] = 'shadowed' }
  end

  -- delayC is the realised-frame delay; divergence (delay ~= delayC) means
  -- the authored intent couldn't be realised (raw clamped at 0 or by
  -- the tail walk's same-pitch onset floor). tp signals it with a small star.
  local divergent = evt.delayC ~= nil and evt.delayC ~= (evt.delay or 0)

  if showDelay then
    local d = evt.delay or 0
    if d == 0 then
      return text .. ' ···', nil, overrides, divergent
    end
    text = text .. ' ' .. string.format('%03d', math.floor(math.abs(d)))
    if d < 0 then
      local n = utf8.len(text)   -- display columns, not bytes (note label may be multibyte)
      overrides = overrides or {}
      overrides[n-2], overrides[n-1], overrides[n] = 'negative', 'negative', 'negative'
    end
  end
  return text, nil, overrides, divergent
end

local function renderPB(evt)
  if evt and not evt.hidden and evt.val then
    if evt.val < 0 then return string.format('%04d', math.floor(math.abs(evt.val))), 'negative'
    else return string.format('%04d', math.floor(evt.val)) end
  else return '····' end
end

local function renderCC(evt)
  if evt and evt.val then return string.format('%02X', evt.val)
  else return '··' end
end

-- One glyph per fx kind; the fx-region cell shows the region's primary kind.
local FX_GLYPH = { retrig = 'R', trill = 'T', vibrato = 'V', slide = 'S', arp = 'A', fill = 'F' }
local function renderFx(evt)
  if not evt then return '·' end   -- one-glyph column: empty cell is a single dot, like renderCC
  return FX_GLYPH[evt.kind] or '~', 'accent'
end

local renderFns = {
  note = renderNote,
  pb   = renderPB,
  cc   = renderCC,
  pa   = renderCC,
  at   = renderCC,
  pc   = renderCC,
  fx   = renderFx,
}

local function renderCell(evt, col, row)
  local fn = renderFns[col.type]
  if fn then return fn(evt, col, row) end
end

-- Offset of the gap before the 3 delay digits in a note cell (* marker slot).
-- Layout: pitch(W) + optional sample(3) + ' ' + vel(2); W = active cellWidth.
local function delayMarkerOffset(col, cellWidth)
  return cellWidth + (col.trackerMode and 3 or 0) + 1 + 2
end

-- The fx badge sits in the pre-vel separator slot -- one column inboard of
-- the delay-marker slot, so the two markers never collide.
local function fxMarkerOffset(col, cellWidth)
  return cellWidth + (col.trackerMode and 3 or 0)
end

----- Drawing

-- A cell adapter over the shared painter: methods speak grid CELLS (integer
-- col/row), the painter maps them to screen through one transform. gX/gY are
-- odd integers, so an integer cell already lands on a whole pixel; snap rounds
-- the fractional cases (centred text, the inset cursor box) crisp, the way the
-- old per-call math.floor did. text is monospace by cell, not by glyph advance.
local function printer(ctx, gX, gY, x0, y0)
  local p  = painter.new(ctx, chrome, { ox = x0, oy = y0, sx = gX, sy = gY, snap = true }, 'tracker')
  local pt = {}

  -- One glyph per cell: advance by a whole cell so the grid stays aligned
  -- regardless of the font's natural glyph advance.
  local function cellText(lx, ly, txt, colour, font, size)
    local i = 0
    for char in txt:gmatch(utf8.charpattern) do
      p.text(lx + i, ly, colour, char, font, size)
      i = i + 1
    end
  end

  -- Logical x that centres txt (measured at font/size) across cells x1..x2.
  local function centreX(x1, x2, txt, font, size)
    return x1 + ((x2 - x1 + 1) - p.measure(txt, font, size) / gX) / 2
  end

  function pt:text(x, y, txt, colour, font)
    cellText(x, y, txt, colour, font, font and 15 or nil)
  end

  function pt:textCentred(x1, x2, y, txt, colour)
    cellText(centreX(x1, x2, txt), y, txt, colour)
  end

  function pt:textCentredSmall(x1, x2, y, txt, size, colour, fnt)
    fnt = fnt or font
    p.text(centreX(x1, x2, txt, fnt, size), y, colour, txt, fnt, size)
  end

  -- A bound cc column's header: the param name one glyph per line, reading
  -- down, bottom-anchored where the horizontal labels sit.
  function pt:textVertical(x1, x2, yBottom, txt, font, size, colour)
    local glyphs = {}
    for char in txt:gmatch(utf8.charpattern) do glyphs[#glyphs + 1] = char end
    for i, char in ipairs(glyphs) do
      p.text(centreX(x1, x2, char, font, size),
             yBottom - (#glyphs - i + 1) * size / gY, colour, char, font, size)
    end
  end

  -- Small glyph centred in a single cell: the * tp drops by a note whose
  -- authored delay could not be realised (delay ~= delayC).
  function pt:smallGlyph(x, y, txt, size, colour)
    local lx = x + (1 - p.measure(txt, font, size) / gX) / 2
    local ly = y + (1 - size / gY) / 2
    p.text(lx, ly, colour, txt, font, size)
  end

  function pt:vLine(x, y1, y2, colour)
    p.segment(x, y1, x, y2 + 1, colour)
  end

  function pt:hLine(x1, x2, y, colour, yOff)
    local ly = y + (yOff or 0)
    p.segment(x1, ly, x2 + 1, ly, colour)
  end

  function pt:box(x1, x2, y1, y2, colour)
    p.fill({ x0 = x1, y0 = y1, x1 = x2 + 1, y1 = y2 + 1 }, colour)
  end

  return pt, p   -- p: the raw painter, for cell-edge strokes and the hit-test inverse
end

--contract: returns 0 when laneStrip.visible is false; layout and draw branch on this
local function laneStripRows()
  if not cm:get('laneStrip.visible') then return 0 end
  return cm:get('laneStrip.rows') or 0
end

-- Local-mode wash: dim the whole grid except a hole at the instance the caret sits
-- inside (`hole`, grid units); nil hole washes everything. Overlays the cell pass.
local function drawLocalScrim(draw, hole, w, h)
  if not hole then draw:box(0, w - 1, 0, h - 1, 'localScrim'); return end
  if hole.y1 > 0     then draw:box(0, w - 1, 0, hole.y1 - 1, 'localScrim') end
  if hole.y2 < h - 1 then draw:box(0, w - 1, hole.y2 + 1, h - 1, 'localScrim') end
  if hole.x1 > 0     then draw:box(0, hole.x1 - 1, hole.y1, hole.y2, 'localScrim') end
  if hole.x2 < w - 1 then draw:box(hole.x2 + 1, w - 1, hole.y1, hole.y2, 'localScrim') end
end

-- Vertical param-name header. Names read top-to-bottom, one glyph per row
-- vertically; names trim to VNAME_MAX chars as a hard upper bound.
local VNAME_MAX = 14

local function vnameSize() return math.floor(gui.fontSize.ui * 0.8) end

-- Bottom gap under a vertical name, in rows: clear of the grid's top rule
-- with a couple of px of breathing room.
local function vnameGap() return 0.35 + 5 / gridY end

-- Rotated param name, trimmed to fit the fixed header. Binary search finds
-- the longest prefix whose rotated strip fits, exact under variable-width fonts.
local function vname(label)
  local cut = utf8.offset(label, VNAME_MAX + 1)
  label = cut and label:sub(1, cut - 1) or label

  local len = utf8.len(label) or #label
  if len == 0 then return label end
  local budget = (HEADER - vnameGap()) * gridY

  local function prefixFitting(n)
    local c = utf8.offset(label, n + 1)
    local s = c and label:sub(1, c - 1) or label
    local _, stripH = painter.measureRotated(ctx, s, vnameSize())
    return (stripH or n * gui.fontSize.ui) <= budget, s
  end

  local full, whole = prefixFitting(len)
  if full then return whole end

  local lo, hi, best = 1, len, nil
  while lo <= hi do
    local mid = (lo + hi) // 2
    local fits, s = prefixFitting(mid)
    if fits then best, lo = s, mid + 1 else hi = mid - 1 end
  end
  return best or (select(2, prefixFitting(1)))
end

--contract: must run before draws reading chanX/chanW/chanOrder/totalWidth/gridHeight
--contract: calls tv:setGridSize so tv scroll math sees the live viewport
local function computeLayout(budgetW, budgetH)
  local grid = tv.grid
  local _, scrollCol = tv:scroll()

  if not gridX then
    local charW, charH = ImGui.CalcTextSize(ctx, 'W')
    gridX = 2 * math.ceil(charW / 2) - 1
    gridY = 2 * math.ceil(charH / 2) - 1
  end

  gridWidth  = math.max(1, math.floor(budgetW / gridX) - GUTTER)
  local laneRows = laneStripRows()
  gridHeight = math.max(1, math.floor(budgetH / gridY) - HEADER - 1 - laneRows)
  tv:setGridSize(gridWidth, gridHeight)

  chanX, chanW, chanOrder, totalWidth = layoutColumns(grid.cols, scrollCol)
end

----- Lane strip

--invariant: lane strip renders only cc/pb/at; other types show as tinted background
local laneRenderable = { cc = true, pb = true, at = true }

local LANE_ROW_MIN = 3
local LANE_ROW_MAX = 32

--contract: publishes laneConsumed=true if curve editor claimed input this frame
--contract: handleMouse short-circuits on laneConsumed
local function drawLaneStrip()

  local laneRows = laneStripRows()
  if laneRows <= 0 then laneConsumed = false; return end

  local px, py    = ImGui.GetCursorScreenPos(ctx)
  local x0        = px + GUTTER * gridX
  local y0        = py
  local w         = totalWidth * gridX
  local h         = laneRows  * gridY
  local p         = painter.new(ctx, chrome, {}, 'tracker')
  local scrollRow = select(1, tv:scroll())
  local numRows   = tv.grid.numRows or 0
  -- rowSpan = rows actually rendered (matches grid below).
  local rowSpan   = math.max(1, math.min(gridHeight, numRows - scrollRow))
  local function rowToX(row) return x0 + (row - scrollRow) / rowSpan * w end

  local pad  = gridY / 2
  local yTop = y0 + pad
  local yBot = y0 + h - pad

  if w > 0 then
    for row = scrollRow, scrollRow + rowSpan - 1 do
      local x = math.floor(rowToX(row))
      local isBar, isBeat = tv:rowBeatInfo(row)
      if isBar or isBeat then
        local x2 = math.floor(rowToX(row + 1))
        p.fill({ x0 = x, y0 = yTop, x1 = x2, y1 = yBot }, isBar and 'rowBarStart' or 'rowBeat')
      end
      p.segment(x, yTop, x, yBot, 'laneRowDivider')
    end
  end

  -- Claim the curve rect as a real item so empty-space drags don't
  -- fall through to the parent window. IsItemActive keeps the strip
  -- "hovered" through a held drag even if the mouse leaves the rect.
  local cbX, cbY = ImGui.GetCursorScreenPos(ctx)
  ImGui.SetCursorScreenPos(ctx, x0, yTop)
  ImGui.InvisibleButton(ctx, '##laneStripHit', math.max(1, w), math.max(1, yBot - yTop))
  local stripHovered = ImGui.IsItemHovered(ctx) or ImGui.IsItemActive(ctx)
  ImGui.SetCursorScreenPos(ctx, cbX, cbY)

  laneConsumed = false
  local colIdx = tv:ec():col()
  local col    = tv.grid.cols[colIdx]
  if w > 0 and col and laneRenderable[col.type] then
    local chan = col.midiChan
    local visible = {}
    for _, evt in ipairs(col.events) do
      if not evt.hidden then util.add(visible, evt) end
    end

    local vMin, vMax
    if col.type == 'pb' then
      local cents = (cm:get('pbRange') or 2) * 100
      vMin, vMax = -cents, cents
    else
      vMin, vMax = 0, 127
    end

    laneConsumed = curveEditor:frame {
      rect     = { x0 = x0, yTop = yTop, w = w, h = yBot - yTop },
      vMin = vMin, vMax = vMax,
      tMin = scrollRow, tMax = scrollRow + rowSpan,
      events    = visible,
      tOf       = function(evt) return tv:ppqToRow(evt.ppq, chan) end,
      -- t is in row-space; map fracT back to ppq before sampling so
      -- tv:rowToPPQ's integer rounding doesn't plateau the curve.
      evalCurve = function(A, B, fracT)
        local fracP = A.ppq + fracT * (B.ppq - A.ppq)
        return tv:sampleCurve(A, B, fracP)
      end,
      snap    = function(t) return util.round(t) end,
      hovered = stripHovered,
      dragId  = colIdx,
      colours = {
        axis         = 'laneAxis',
        envelope     = 'laneEnvelope',
        anchor       = 'laneAnchor',
        anchorActive = 'laneAnchorActive',
      },
      callbacks = {
        onMove     = function(idx, newT, newVal) tv:moveLaneEvent(col, idx, newT, newVal) end,
        onMoveFree = function(idx, newT, newVal) tv:moveLaneEvent(col, idx, newT, newVal) end,
        onInsert   = function(t, val) return tv:addLaneEvent(col, colIdx, tv:rowToPPQ(t, chan), val) end,
        onDelete     = function(idx)      tv:deleteLaneEvent(col, idx) end,
        onTension    = function(idx, tau) tv:setLaneTension (col, idx, tau) end,
        onCycleShape = function(idx)      tv:cycleLaneShape (col, idx) end,
      },
    }
  end

  if w > 0 then
    p.stroke({ x0 = x0, y0 = yTop, x1 = x0 + w, y1 = yBot }, 'rowBeat', 1)
  end

  ImGui.Dummy(ctx, (totalWidth + GUTTER) * gridX, h)

  local cx, cy = ImGui.GetCursorScreenPos(ctx)
  local rows = cm:get('laneStrip.rows') or 0
  ImGui.SetCursorScreenPos(ctx, px - 2, yTop)
  chrome.pushChromeStyles()
  if ImGui.SmallButton(ctx, '-##laneRows') then
    cm:set('global', 'laneStrip.rows', math.max(LANE_ROW_MIN, rows - 1))
  end
  ImGui.SameLine(ctx, 0, 2)
  if ImGui.SmallButton(ctx, '+##laneRows') then
    cm:set('global', 'laneStrip.rows', math.min(LANE_ROW_MAX, rows + 1))
  end
  chrome.popChromeStyles()
  ImGui.SetCursorScreenPos(ctx, cx, cy)
end

--contract: assumes computeLayout ran this frame; reads chanX/W/Order, gridOriginX/Y
-- Bottom header row for a note column: one ui-font label per part, centred
-- over that part's char span (PITCH/VEL/DELAY/SAMP). Replaces the old lane number.
local PART_LABEL = { pitch = 'PITCH', sample = 'SAMP', vel = 'VEL', delay = 'DELAY' }

local function notePartHeaders(col)
  local headers, partAt, stopPos = {}, col.partAt, col.stopPos
  local s = 1
  while s <= #partAt do
    local name, e = partAt[s], s
    while e < #partAt and partAt[e + 1] == name do e = e + 1 end
    headers[#headers + 1] = {
      x1 = col.x + stopPos[s], x2 = col.x + stopPos[e], label = PART_LABEL[name],
    }
    s = e + 1
  end
  return headers
end

local function drawTracker()
  local grid = tv.grid
  local ec = tv:ec()
  local cursorRow, cursorCol, cursorStop = ec:pos()
  local scrollRow, scrollCol, lastVisCol = tv:scroll()

  local px, py = ImGui.GetCursorScreenPos(ctx)
  gridOriginX  = px + GUTTER * gridX
  gridOriginY  = py + HEADER * gridY

  local numRows = grid.numRows or 0
  local draw, p = printer(ctx, gridX, gridY, gridOriginX, gridOriginY)
  gridPainter = p
  -- Screen-space painter (identity transform) for draws sized in pixels, not
  -- cells: the tail bracket's arc radius and the temperament rule's tick. Colour
  -- by name like any painter; positions pass straight through unconverted.
  local screenPainter = painter.new(ctx, chrome, {}, 'tracker')

  -- Solo (amber) wins over mute (red): audibility semantic.
  draw:text(-GUTTER, -HEADER, 'Row', 'accent')
  -- Channel banner centres over the note columns only — automation/cc
  -- columns protrude past them and would pull the label off-centre.
  local noteSpan = {}
  for _, col in ipairs(grid.cols) do
    if col.x and col.type == 'note' then
      local span = noteSpan[col.midiChan]
      if span then span.x2 = col.x + col.width - 1
      else noteSpan[col.midiChan] = { x1 = col.x, x2 = col.x + col.width - 1 } end
    end
  end
  for chan = 1, 16 do
    local span = noteSpan[chan]
    if span then
      local key = tv:isChannelSoloed(chan) and 'solo'
               or tv:isChannelMuted(chan)  and 'mute'
               or 'tracker.chanHeader'
      draw:textCentred(span.x1, span.x2, -HEADER, 'Ch ' .. chan, key)
    end
  end
  for _, col in ipairs(grid.cols) do
    if col.x then
      local xr = col.x + col.width - 1
      local binding = col.type == 'cc' and tv:paramBinding(col.midiChan, col.cc)
      if binding then
        local vertical = vname(binding.label)
        if not p.textUp((col.x + xr + 1) / 2, -vnameGap(), 'text', vertical, vnameSize()) then
          draw:textVertical(col.x, xr, -vnameGap(), vertical, uiFont, gui.fontSize.ui, 'text')
        end
      else
        draw:textCentred(col.x, xr, -2.1, col.label, 'text')
        if col.type == 'note' then
          for _, h in ipairs(notePartHeaders(col)) do
            draw:textCentredSmall(h.x1, h.x2, -1.2 + 2 / gridY, h.label, vnameSize(), 'tracker.partHeader', uiFont)
          end
        elseif col.type == 'cc' then
          draw:textCentredSmall(col.x, xr, -1.2 + 2 / gridY, tostring(col.cc), vnameSize(), 'tracker.partHeader', uiFont)
        end
      end
    end
  end

  draw:hLine(-GUTTER, totalWidth - 1, 0, 'text', -0.25)

  -- for i = 1, #chanOrder - 1 do
  --   local chan = chanOrder[i]
  --   draw:vLine(chanX[chan] + chanW[chan], -HEADER, gridHeight - 1, 'separator')
  -- end

  for y = 0, gridHeight - 1 do
    local row = scrollRow + y
    if row >= numRows then break end

    local isBarStart, isBeatStart = tv:rowBeatInfo(row)

    if isBarStart or isBeatStart then
      local style = isBarStart and 'rowBarStart' or 'rowBeat'
      for chan = 1, 16 do
        if chanX[chan] then
          draw:box(chanX[chan], chanX[chan] + chanW[chan] - 1, y, y, style)
        end
      end
    end

    local rowNumCol = (isBeatStart and 'text') or 'inactive'
    draw:text(-GUTTER, y, string.format('%03d', row), rowNumCol)
  end

  -- Mirror regions. Before tails/cells so per-cell text reads over the
  -- wash. A per-group hue washes the whole instance area (membership =
  -- selected streams x time span), clipped to the take edge; overridden/
  -- conflicted cells overpaint a louder state colour. The wash is always
  -- on (group viz). Outlines are crisp (painter border): a 2px region-
  -- cursor instance while armed, a 1px instance the caret sits inside
  -- outside region mode (a "you are here"), and any conflicted instance
  -- in any mode -- a data problem worth seeing.
  local logPerRow = tv:logPerRow()
  local cursorPpq = cursorRow * logPerRow
  local inRegion  = tv:ec():isInRegionMode()
  local rc        = inRegion and tv:ec():regionCursor()
  local movePrev  = tv:movePreview()
  local isLocal   = tv:localMode()
  local localHole
  for _, inst in ipairs(tv:eachInstance()) do
    local rect  = inst.rect
    local deleted = {}                 -- srcCol -> { [row] = true }: delete-override blanks
    for _, d in ipairs(tv:deletedCells(inst.groupId, inst.instId)) do
      deleted[d.col] = deleted[d.col] or {}
      deleted[d.col][d.row] = true
    end
    local previewing = movePrev and movePrev.groupId == inst.groupId
                                and movePrev.instId == inst.instId
    local shift      = previewing and movePrev.delta or 0
    local chanOrigin = inst.anchor.chan + (previewing and movePrev.chanDelta or 0)
    local laneOrigin = (inst.anchor.laneDelta or 0) + (previewing and movePrev.laneDelta or 0)
    local ppqLo = inst.anchor.ppq + shift * logPerRow
    local ppqHi = ppqLo + rect.dur
    local yLo = math.max(math.floor(ppqLo / logPerRow + 0.5) - scrollRow, 0)
    local yHi = math.min(math.floor(ppqHi / logPerRow + 0.5) - scrollRow, gridHeight, numRows - scrollRow)
    if yHi > yLo then
      local baseTint = groups.regionKey(inst.colour, 'tint')
      local xMin, xMax, conflicted, cursorIn
      for x, col in ipairs(grid.cols) do
        if col.x then
          local off, sid = tv:streamRefAt(x, chanOrigin, laneOrigin)
          if off and rect.streams[off] and rect.streams[off][sid] then
            local x1, x2 = col.x, col.x + col.width - 1
            xMin = math.min(xMin or x1, x1)
            xMax = math.max(xMax or x2, x2)
            draw:box(x1, x2, yLo, yHi - 1, baseTint)
            local srcCol = (previewing and movePrev.destSrc[x]) or x
            local cells  = grid.cols[srcCol] and grid.cols[srcCol].cells
            for y = yLo, yHi - 1 do
              local row = scrollRow + y - shift
              local evt = cells and cells[row]
              local st  = evt and evt.uuid and tv:stateOf(evt.uuid)
              if st == 'conflicted' then conflicted = true end
              local key = st and groups.tintKey(st)
              if key then draw:box(x1, x2, y, y, key)
              elseif not evt and deleted[srcCol] and deleted[srcCol][row] then
                draw:box(x1, x2, y, y, groups.tintKey('overridden'))
              end
            end
            if x == cursorCol and cursorPpq >= ppqLo and cursorPpq < ppqHi then
              cursorIn = true
            end
          end
        end
      end
      if xMin then
        local isCursorInst = rc and rc.groupId == inst.groupId
                                and rc.instId == inst.instId
        local plainCursorIn = cursorIn and not inRegion
        if conflicted or isCursorInst or plainCursorIn then
          local outlineName = groups.outlineKey(
            conflicted and 'conflicted' or 'synced', inst.colour)
          p.border({ x0 = xMin, y0 = yLo, x1 = xMax + 1, y1 = yHi }, outlineName, isCursorInst and 2 or 1)
        end
        if isLocal and cursorIn then
          localHole = { x1 = xMin, x2 = xMax, y1 = yLo, y2 = yHi - 1 }
        end
      end
    end
  end

  local viewTop  = scrollRow
  local viewBot  = scrollRow + gridHeight
  for _, col in ipairs(grid.cols) do
    if col.x and col.tails then
      for _, tail in ipairs(col.tails) do
        if tail.endRow > viewTop and tail.startRow < viewBot then
          local y1 = gridOriginY + math.max(tail.startRow - scrollRow, 0) * gridY
          local y2 = gridOriginY + math.min(tail.endRow - scrollRow, gridHeight) * gridY
          local x1 = gridOriginX + col.x * gridX
          local r  = 5
          screenPainter.pathClear()
          screenPainter.pathArcTo(x1, y1 + r, r, 3 * math.pi / 2, math.pi)
          screenPainter.pathLineTo(x1 - r, y1 + r + 1)
          screenPainter.pathLineTo(x1 - r, y2 - r - 1)
          screenPainter.pathArcTo(x1, y2 - r, r, math.pi, math.pi / 2)
          screenPainter.pathStroke('tail', 1.5)
          screenPainter.pathClear()
        end
      end
    end
  end

  local cellWidth = tv:cellWidth()
  for y = 0, gridHeight - 1 do
    local row = scrollRow + y
    if row >= numRows then break end
    for x, col in ipairs(grid.cols) do
      if col.x then
        local evt = col.cells and col.cells[row]
        local previewGhost
        if movePrev then
          local srcCol = movePrev.destSrc[x]
          local dstLo  = movePrev.srcLo + movePrev.delta
          local dstHi  = dstLo + (movePrev.srcHi - movePrev.srcLo)
          if srcCol and row >= dstLo and row < dstHi then
            local sc = grid.cols[srcCol]
            evt, previewGhost = sc and sc.cells and sc.cells[row - movePrev.delta], true
          elseif movePrev.srcMember[x] and row >= movePrev.srcLo and row < movePrev.srcHi then
            evt, previewGhost = nil, true
          end
        end
        local ghost = not evt and not previewGhost and col.ghosts and col.ghosts[row]
        local text, textCol, overrides, divergent
        if ghost then
          local cellCol
          text, cellCol = renderCell({ val = ghost.val }, col, row)
          textCol = cellCol == 'negative' and 'ghostNegative' or 'ghost'
        else
          text, textCol, overrides, divergent = renderCell(evt, col, row)
          if col.overflow and col.overflow[row] then textCol, overrides = 'overflow', nil end
          textCol = textCol or 'text'
          if textCol == 'text' and col.offGrid and col.offGrid[row] then
            textCol = 'offGrid'
          end
          if previewGhost and evt then textCol, overrides, divergent = 'ghost', nil, false end
        end
        local muted = tv:isChannelEffectivelyMuted(col.midiChan)
        if muted then textCol, overrides, divergent = 'inactive', nil, false end
        if not text then text = '' end
        local cx, i = col.x, 0
        for ch in text:gmatch(utf8.charpattern) do
          i = i + 1
          local c = (overrides and overrides[i]) or (ch == '·' and 'inactive' or textCol)
          draw:text(cx, y, ch, c)
          cx = cx + 1
        end
        if divergent and col.showDelay then
          draw:smallGlyph(col.x + delayMarkerOffset(col, cellWidth)-0.1, y-0.3, '*', 14, textCol)
        end
        if evt and evt.fx and evt.fx[1] and col.type == 'note' and not muted and not previewGhost then
          draw:smallGlyph(col.x + fxMarkerOffset(col, cellWidth)-0.1, y-0.3, '*', 14, textCol)
        end
      end
    end
  end

  if tv:activeTemper() then
    for _, col in ipairs(grid.cols) do
      if col.x and col.type == 'note' and col.cells then
        local x0 = gridOriginX + col.x * gridX
        local x1 = x0 + cellWidth * gridX
        local cx = (x0 + x1) / 2
        local halfW = (x1 - x0) / 2 - 1
        for y = 0, gridHeight - 1 do
          local row = scrollRow + y
          if row >= numRows then break end
          local evt = col.cells[row]
          if evt and evt.pitch then
            local _, _, gap, halfGap = tv:noteProjection(evt)
            if gap and gap ~= 0 and halfGap > 0 then
              local yTop = gridOriginY + y * gridY + 1
              local offset = util.clamp(gap / halfGap, -1, 1) * halfW
              screenPainter.line(x0, yTop, x1, yTop, 'accent', 1)
              local tickX = cx + offset
              screenPainter.line(tickX, yTop - 1, tickX, yTop + 2, 'accent', 1)
            end
          end
        end
      end
    end
  end

  -- Scrim spans only populated rows; blank space past the take's end stays clear.
  if isLocal then
    drawLocalScrim(draw, localHole, totalWidth, math.min(gridHeight, math.max(numRows - scrollRow, 0)))
  end

  if ec:hasSelection() then
    local r1, r2, c1i, c2i = ec:region()
    if c2i >= scrollCol and c1i <= lastVisCol then
      local yFrom = math.max(r1 - scrollRow, 0)
      local yTo   = math.min(r2 - scrollRow, gridHeight - 1)
      local c1, c2 = grid.cols[c1i], grid.cols[c2i]
      local s1   = ec:selectionStopSpan(c1i)
      local _,s2 = ec:selectionStopSpan(c2i)
      local x1 = c1.x and c1.x + c1.stopPos[s1]  or 0
      local x2 = c2.x and c2.x + c2.stopPos[s2]  or totalWidth
      draw:box(x1, x2, yFrom, yTo, 'selection')
    end
  end

  local col = grid.cols[cursorCol]
  if col and col.x then
    local stopOffset = (col.stopPos and col.stopPos[cursorStop]) or 0
    local charX = col.x + stopOffset
    local charY = cursorRow - scrollRow
    draw:box(charX, charX, charY+0.1, charY-0.1, 'cursor')
    local evt = col.cells and col.cells[cursorRow]
    local text = renderCell(evt, col, cursorRow)
    local ch = utf8.offset(text, stopOffset + 1) and text:sub(utf8.offset(text, stopOffset + 1), utf8.offset(text, stopOffset + 2) - 1) or ''
    if ch ~= '' then draw:text(charX, charY, ch, 'cursorText') end
  end

  -- Reserve content space so ImGui knows the drawable area
  ImGui.Dummy(ctx, (totalWidth + GUTTER) * gridX, (gridHeight + HEADER) * gridY)
end

----- Input

-- Screen point -> (fractional column, integer row) through the grid painter's
-- inverse, so a click resolves against the exact transform the draw pass used.
local function cellAt(mouseX, mouseY)
  local lx, ly = gridPainter.fromScreen(mouseX, mouseY)
  return lx, math.floor(ly)
end

--contract: returns (col, stop, fracX) or (nil, nil, fracX)
--invariant: fracX is separate so callers distinguish 'past last col' from 'inside col N'
local function nearestStop(mouseX, mouseY)
  local grid = tv.grid
  local fracX = cellAt(mouseX, mouseY)
  local bestCol, bestStop, bestDist = nil, nil, math.huge
  for i, col in ipairs(grid.cols) do
    if col.x then
      for s, pos in ipairs(col.stopPos) do
        local dist = math.abs(fracX - col.x - pos - 0.5)
        if dist < bestDist then
          bestCol, bestStop, bestDist = i, s, dist
        end
      end
    end
  end
  return bestCol, bestStop, fracX
end

-- Cell edits use the KEY stream (not the OS char queue): IsKeyPressed(repeat)
-- autorepeats every key uniformly; the char queue dropped repeats under macOS.
local editKeys = {}
do
  local function add(key, byte) editKeys[#editKeys + 1] = { key = key, char = byte } end
  for i = 0, 25 do add(ImGui.Key_A + i, string.byte('a') + i) end
  for d = 0, 9 do
    add(ImGui.Key_0 + d,      string.byte('0') + d)
    add(ImGui.Key_Keypad0 + d, string.byte('0') + d)
  end
  add(ImGui.Key_Minus,     string.byte('-'))
  add(ImGui.Key_KeypadSubtract, string.byte('-'))
  add(ImGui.Key_Comma,     string.byte(','))
  add(ImGui.Key_Period,    string.byte('.'))
  add(ImGui.Key_Semicolon, string.byte(';'))
  add(ImGui.Key_Apostrophe, string.byte("'"))
end

-- Only the newest held edit key autorepeats; without this a held chord would
-- re-enter all its keys interleaved (the OS char queue only repeated the last).
local lastEditKey

---------- PUBLIC

local gridPane = {}

-- Draw pass: computeLayout twice (lane-drag callbacks may rebuild grid.cols,
-- so drawTracker needs a fresh layout), with the grid font pushed throughout.
--invariant: lane-strip drag callbacks may flush tv.grid.cols and clear col.x
function gridPane:draw(gridW, gridH)
  ImGui.PushFont(ctx, font, 15)
  computeLayout(gridW, gridH)
  drawLaneStrip()
  computeLayout(gridW, gridH)
  drawTracker()
  ImGui.PopFont(ctx)
end

-- Grid geometry for the host's help:anchor (which spans grid + palette).
function gridPane:geom()
  return { originX = gridOriginX, originY = gridOriginY, height = gridHeight, cellH = gridY }
end

--contract: bails if laneConsumed; lane strip wins gestures over the tracker grid
--contract: right-click on channel-label row toggles mute
--contract: click on label rows selects channel/column
--contract: body click moves cursor and arms drag
function gridPane:handleMouse()
  if laneConsumed then return end

  local grid = tv.grid
  local ec = tv:ec()
  local cursorRow, cursorCol, cursorStop = ec:pos()
  local scrollRow, scrollCol, lastVisCol = tv:scroll()

  local clicked      = ImGui.IsMouseClicked(ctx, 0)
  local rightClicked = ImGui.IsMouseClicked(ctx, 1)
  local held         = ImGui.IsMouseDown(ctx, 0)

  -- Region sculpt paint: shift-drag adds the column's stream to the
  -- active group, alt-drag removes it; debounced per cell via paintLast.
  local rc = ec:regionCursor()
  if ec:isInRegionMode() and rc and held and ImGui.IsWindowHovered(ctx) then
    local mods = ImGui.GetKeyMods(ctx)
    local add  = (mods & ImGui.Mod_Shift) ~= 0
    local sub  = (mods & ImGui.Mod_Alt)   ~= 0
    if add or sub then
      local mouseX, mouseY = ImGui.GetMousePos(ctx)
      local _, charY = cellAt(mouseX, mouseY)
      if charY >= 0 and charY < gridHeight then
        local col  = nearestStop(mouseX, mouseY)
        local cell = col and (col .. (add and '+' or '-'))
        if col and cell ~= paintLast then
          paintLast = cell
          tv:paintRegionStream(rc.groupId, rc.instId, col, add)
        end
      end
      return
    end
  elseif ec:isInRegionMode() and not held then
    paintLast = nil
  end

  if rightClicked and ImGui.IsWindowHovered(ctx) then
    local mouseX, mouseY = ImGui.GetMousePos(ctx)
    local _, charY = cellAt(mouseX, mouseY)
    local col, _, fracX = nearestStop(mouseX, mouseY)
    if col and charY == -HEADER and fracX >= 0 then
      local last = grid.cols[col]
      if fracX < last.x + last.width + 1 then
        tv:toggleChannelMute(last.midiChan)
      end
    end
    return
  end

  if clicked and ImGui.IsWindowHovered(ctx) then
    local mouseX, mouseY = ImGui.GetMousePos(ctx)
    local _, charY = cellAt(mouseX, mouseY)
    local col, stop, fracX = nearestStop(mouseX, mouseY)
    if not col then return end
    if charY < -HEADER or charY >= gridHeight then return end
    if fracX < 0 then return end
    local last = grid.cols[col]
    if fracX >= last.x + last.width + 1 then return end

    -- Mouse bypasses cmgr's DUP_KEEP sweep, so the cascade lifetime is
    -- enforced here by hand. A plain reposition click is the mouse
    -- equivalent of a cursor move -- DUP_KEEP keeps the run across it,
    -- so don't clear here. Only a genuine RE-selection ends the run:
    -- label-row select, shift-extend (both below) and drag (in the
    -- dragging branch). Mirrors cursor-key behaviour.

    if charY < 0 then
      tv:endReselectCascades()   -- label-row select is a re-selection
      if charY == -HEADER then ec:selectChannel(last.midiChan)
      else ec:selectColumn(col) end
      return
    end

    local shift = ImGui.GetKeyMods(ctx) & ImGui.Mod_Shift ~= 0

    if shift then
      tv:endReselectCascades()   -- shift-extend is a re-selection
      ec:extendTo(scrollRow + charY, col, stop)
    else
      ec:selClear()
      ec:setPos(scrollRow + charY, col, stop)
      dragging = true
    end

  elseif dragging and held then
    local mouseX, mouseY = ImGui.GetMousePos(ctx)
    local fracX, charY = cellAt(mouseX, mouseY)
    local row = scrollRow + charY
    local rightEdge = grid.cols[lastVisCol].x + grid.cols[lastVisCol].width

    local col, stop
    if fracX < 0 then
      col, stop = cursorCol, cursorStop - 1
      if stop < 1 then
        if col > 1 then col = col - 1; stop = #grid.cols[col].stopPos
        else stop = 1 end
      end
    elseif fracX >= rightEdge then
      col, stop = cursorCol, cursorStop + 1
      if stop > #grid.cols[cursorCol].stopPos then
        if col < #grid.cols then col = col + 1; stop = 1
        else stop = #grid.cols[col].stopPos end
      end
    else
      col, stop = nearestStop(mouseX, mouseY)
      if not col then return end
    end

    -- Only start selection once cursor moves to a different position
    if row ~= cursorRow or col ~= cursorCol or stop ~= cursorStop then
      tv:endReselectCascades()   -- drag-select is a new selection
      ec:extendTo(row, col, stop)
    end

  elseif dragging and not held then
    dragging = false
  end

  if ImGui.IsWindowHovered(ctx) then
    local wheel,wheelH  = ImGui.GetMouseWheel(ctx)
    if wheel ~= 0 then
      local n = util.round(math.abs(wheel) / 2)
      if n > 0 then
        local name = wheel > 0 and 'cursorUp' or 'cursorDown'
        for _ = 1, n do cmgr:invoke(name) end
      end
    end
    if wheelH ~= 0 then
      local n = util.round(math.abs(wheelH))
      if n > 0 then
        local name = wheelH > 0 and 'cursorLeft' or 'cursorRight'
        for _ = 1, n do cmgr:invoke(name) end
      end
    end
  end
end

-- commandHeld gates note entry per key: a key bound to both a command and note
-- entry (e.g. '.' = delete) fires the command; unrelated keys still enter.
--contract: no-op unless inputAllowed(); host folds modal/picker/item-active/palette/strip
--contract: every fresh press enters; only lastEditKey autorepeats
--contract: scans editKeys per frame; reads ec/grid fresh (editEvent may rebuild)
--contract: a note key typed while armed exits region mode then enters (execute-through)
function gridPane:handleKeys(kr)
  if not inputAllowed() then return end
  local ec = tv:ec()
  local commandHeld = kr.commandHeld

  if ImGui.GetKeyMods(ctx) == ImGui.Mod_None and not cmgr:isPrefixActive() then
    for _, entry in ipairs(editKeys) do
      if not commandHeld[entry.key] then
        local fresh  = ImGui.IsKeyPressed(ctx, entry.key, false)
        local repeated = ImGui.IsKeyPressed(ctx, entry.key, true)
        if fresh or (repeated and entry.key == lastEditKey) then
          if ec:isInRegionMode() then ec:regionExit() end   -- a typed note executes through
          if ec:isSticky() then ec:selClear(); break end
          if fresh then lastEditKey = entry.key end
          local row, colIdx, stop = ec:pos()
          local c = tv.grid.cols[colIdx]
          if c then tv:editEvent(c, c.cells and c.cells[row], stop, entry.char) end
        end
      end
    end
  end
end

return gridPane
