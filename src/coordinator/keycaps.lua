-- See docs/help.md § What's where for the model.
-- @noindex

-- Keycap chips and the box of chip rows they sit in: draw calls return
-- geometry instead of taking a callback; see docs/help.md § What's where.

--shape: cluster = { width, sep, chips = { { w, cells = { { text, w } } } } } -- one shortcut's chips
--shape: row = { cluster, route?, label, accent } -- a box row: its chips, its route's chip, the text beside them, its cue
--shape: accent = { chips = { [chipIndex] = true }, text } -- chips in the title colour, text replacing their glyphs
--shape: placed = { x, y, endX, chips = { { x, y, w, h } }, route? = placed } -- where a drawn cluster landed
--contract: theme carries bg, border, title, key, label and chip; new() derives fill and outline
--contract: a wash below 1 scales the alpha of everything a chip draws, for keys not pressable now
local ImGui = require 'imgui' '0.10'
local util  = require 'util'

local keycaps = {}

keycaps.BOX_R, keycaps.CHIP_R = 3, 2   -- corner radii, shared with what a caller draws alongside

local PAD, ROW_GAP, KEY_GAP = 6, 2, 12   -- box inset; between rows; between the key column and the labels
local CHIP_PADX_INNER, CHIP_PADX_OUTER, SEP_GAP = 0, 2, 4
local TEXT_PADX = 3   -- a text chip's own margin: no square floor to stand its glyphs off the edge
local CHIP_MIN_RATIO, CHIP_ALPHA = 0.9, 0xcc   -- a cell's square floor as a fraction of the line; chip fill alpha
local SEP = '/'

local function withAlpha(rgba, a) return (rgba & 0xFFFFFF00) | math.floor(a) end
local function washed(rgba, wash) return withAlpha(rgba, (rgba & 0xFF) * wash) end

function keycaps.new(ctx, dl, theme, wash)
  wash = wash or 1
  local lineH   = ImGui.GetTextLineHeight(ctx)
  local capBg   = washed(withAlpha(theme.chip, CHIP_ALPHA), wash)
  local capLine = washed(withAlpha(theme.border, 0x66), wash)
  local keyInk  = washed(theme.key, wash)
  local caps    = { lineH = lineH, capBg = capBg, capLine = capLine }

  -- One chord's chip: a run of word chars shares a cell, a symbol takes its own square.
  local function chordChip(chord)
    local cells, chipW, run = {}, CHIP_PADX_OUTER * 2, nil
    local function cell(text)
      local cellW = math.max((ImGui.CalcTextSize(ctx, text)) + CHIP_PADX_INNER, lineH * CHIP_MIN_RATIO)
      util.add(cells, { text = text, w = cellW })
      chipW = chipW + cellW
    end
    for _, code in utf8.codes(chord) do
      local glyph = utf8.char(code)
      if #glyph == 1 and glyph:match('%w') then
        run = (run or '') .. glyph
      else
        if run then cell(run); run = nil end
        cell(glyph)
      end
    end
    if run then cell(run) end
    return { w = chipW, cells = cells }
  end

  -- Lays a shortcut's chips (separator-joined, one per binding) out into
  -- geometry for drawCluster.
  function caps.cluster(keys, sep)
    sep = sep or SEP
    local sepW, chips, total = ImGui.CalcTextSize(ctx, sep), {}, 0
    for index, chord in ipairs(keys) do
      local chip = chordChip(chord)
      util.add(chips, chip)
      total = total + chip.w + (index > 1 and SEP_GAP * 2 + sepW or 0)
    end
    return { width = total, chips = chips, sep = sep }
  end

  -- A cluster of one chip holding text as typed: no square per symbol, so a route's
  -- leading '/' keeps its natural width. See docs/help.md § What's where.
  function caps.textCluster(text)
    local cellW = (ImGui.CalcTextSize(ctx, text)) + TEXT_PADX * 2
    local chip  = { w = cellW, cells = { { text = text, w = cellW } } }
    return { width = chip.w, chips = { chip }, sep = SEP }
  end

  -- The rounded, bordered ground a box stands on, drawn on its own for a caller
  -- whose contents are not chip rows.
  function caps.panel(x0, y0, x1, y1)
    ImGui.DrawList_AddRectFilled(dl, x0, y0, x1, y1, theme.bg, keycaps.BOX_R)
    ImGui.DrawList_AddRect(dl, x0, y0, x1, y1, theme.border, keycaps.BOX_R)
  end

  -- Draws a cluster at (x, y) and reports where its chips landed; an accented
  -- chip takes the title colour, its text (if any) replacing that chip's glyphs.
  function caps.drawCluster(cluster, x, y, accent)
    local sepW, cursorX, placed = ImGui.CalcTextSize(ctx, cluster.sep), x, {}
    for index, chip in ipairs(cluster.chips) do
      if index > 1 then
        ImGui.DrawList_AddText(dl, cursorX + SEP_GAP, y, keyInk, cluster.sep)
        cursorX = cursorX + SEP_GAP * 2 + sepW
      end
      local x2   = cursorX + chip.w
      local ink  = accent ~= nil and accent.chips[index] and theme.title or nil
      ImGui.DrawList_AddRectFilled(dl, cursorX, y, x2, y + lineH, capBg, keycaps.CHIP_R)
      ImGui.DrawList_AddRect(dl, cursorX, y, x2, y + lineH, ink or capLine, keycaps.CHIP_R)
      if ink and accent.text then
        local textW = ImGui.CalcTextSize(ctx, accent.text)
        ImGui.DrawList_AddText(dl, cursorX + (chip.w - textW) / 2, y, ink, accent.text)
      else
        local glyphX = cursorX + CHIP_PADX_OUTER
        for _, cell in ipairs(chip.cells) do
          local textW = ImGui.CalcTextSize(ctx, cell.text)
          ImGui.DrawList_AddText(dl, glyphX + (cell.w - textW) / 2, y, ink or keyInk, cell.text)
          glyphX = glyphX + cell.w
        end
      end
      util.add(placed, { x = cursorX, y = y, w = chip.w, h = lineH })
      cursorX = x2
    end
    return { x = x, y = y, endX = cursorX, chips = placed }
  end

  -- A box's geometry over rows already laid out: three columns, each as wide as its
  -- widest row, and the route's dropped where no row carries one.
  function caps.box(title, rows)
    local keyW, routeW, labelW = 0, 0, 0
    for _, row in ipairs(rows) do
      keyW   = math.max(keyW, row.cluster.width)
      routeW = math.max(routeW, row.route and row.route.width or 0)
      labelW = math.max(labelW, (ImGui.CalcTextSize(ctx, row.label)))
    end
    local routeX = keyW + KEY_GAP
    local labelX = routeX + (routeW > 0 and routeW + KEY_GAP or 0)
    local titleW = ImGui.CalcTextSize(ctx, title)
    return { title = title, rows = rows, routeX = routeX, labelX = labelX,
             w = math.max(titleW, labelX + labelW) + PAD * 2,
             h = PAD * 2 + lineH * (#rows + 1) + ROW_GAP * #rows }
  end

  -- Draws a box at (x, y) and reports each row's placed cluster, its route's placement
  -- hung off it, in row order.
  function caps.drawBox(box, x, y)
    caps.panel(x, y, x + box.w, y + box.h)
    local rowY, placed = y + PAD, {}
    ImGui.DrawList_AddText(dl, x + PAD, rowY, theme.title, box.title)
    rowY = rowY + lineH + ROW_GAP
    for _, row in ipairs(box.rows) do
      local keys = caps.drawCluster(row.cluster, x + PAD, rowY, row.accent)
      if row.route then keys.route = caps.drawCluster(row.route, x + PAD + box.routeX, rowY) end
      util.add(placed, keys)
      ImGui.DrawList_AddText(dl, x + PAD + box.labelX, rowY, theme.label, row.label)
      rowY = rowY + lineH + ROW_GAP
    end
    return placed
  end

  return caps
end

return keycaps
