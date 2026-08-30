-- The menu row's geometry (docs/menu.md § The row). A real menu is walked over a
-- synthetic manifest and tree, and its row drawn through the render module onto a
-- fake imgui whose draw calls record: the keycap letters, the titles beside them,
-- the highlight's fill and the wrap are all read off the call list.
--
-- The fake chrome hands each colour role a value of its own, so a fill is found by
-- the role it was drawn in rather than by its position in the list.

local t    = require('support')
local util = require('util')

local img = t.imgui()

local LINE = 14                     -- the fake's text line height
local PAD, ROW_GAP = 6, 2           -- the band's inset; between wrapped lines
local LETTER_GAP, MEMBER_GAP = 6, 18
local HL_PAD = 3
local GLYPH  = 8                    -- the fake's width per character
local CHIP_W = LINE * 0.9 + 2 * 2   -- a lone letter floors to a square, plus the outer pads

local BOTTOM, WIDE, NARROW = 300, 400, 200

img.GetForegroundDrawList = function() return 'dl' end
img.GetTextLineHeight     = function() return LINE end
img.CalcTextSize          = function(_, s) return GLYPH * #tostring(s), LINE end

-- The draw calls record rather than no-op; each entry keeps the arguments past the
-- drawlist, so a rect reads as its corners and then its colour.
local drawn = {}
for _, name in ipairs({ 'DrawList_AddRectFilled', 'DrawList_AddRect', 'DrawList_AddText' }) do
  local op = name:match('^DrawList_Add(.+)$')
  img[name] = function(_, ...) util.add(drawn, { op = op, ... }) end
end

-- A distinct value per role, so the role a rect was drawn in is recoverable from it.
local roles, nextColour = {}, 0x1000
local function colourFor(role)
  if not roles[role] then nextColour = nextColour + 0x100; roles[role] = nextColour end
  return roles[role]
end
local fakeChrome = { colour = colourFor }

local ctx = {}
local mgr, menu, render

-- One tree node in the shape manifest.lua's `item` builds.
local function node(name) return { name = name, desc = name .. ' commands', children = {} } end

-- Rebind imgui to ours before loading: earlier specs' preloads cache a different
-- fake, so drop the imgui-capturing modules and re-require (curveEditor idiom).
--
-- The surface is three groups, each holding one verb a level down, and one
-- top-level leaf: a level of four members whose titles are of known width.
local function fresh()
  package.preload['imgui'] = function() return function(_) return img end end
  for _, m in ipairs({ 'imgui', 'keycaps' }) do package.loaded[m] = nil end
  mgr = util.instantiate('commandManager', {})
  mgr:register('save', function() end)
  for _, name in ipairs({ 'editSwing', 'addColumn', 'fillRegion' }) do
    mgr:scope('page'):register(name, function() end)
  end
  mgr:installManifest({
    global = { File = { { name = 'save', label = 'Save the project', path = 'Save' } } },
    page   = { Edit = {
      { name = 'editSwing',  label = 'Edit swing',  path = 'Grid/Swing'   },
      { name = 'addColumn',  label = 'Add column',  path = 'Column/Add'   },
      { name = 'fillRegion', label = 'Fill region', path = 'Region/Fill'  },
    } },
  }, img)
  mgr:installTree{ node('Grid'), node('Column'), node('Region') }
  mgr:push('page')
  menu   = util.instantiate('menu', { cmgr = mgr })
  render = util.instantiate('menuRender', { ctx = ctx, chrome = fakeChrome, menu = menu })
  mgr:invoke('openMenu')
end

local function drawRow(width)
  drawn = {}
  render:draw(0, BOTTOM, width or WIDE)
end

-- The rects filled in a given role, in draw order.
local function filled(role)
  local found = {}
  for _, call in ipairs(drawn) do
    if call.op == 'RectFilled' and call[5] == colourFor(role) then
      util.add(found, { x0 = call[1], y0 = call[2], x1 = call[3], y1 = call[4] })
    end
  end
  return found
end

local function textAt(text)
  for _, call in ipairs(drawn) do
    if call.op == 'Text' and call[4] == text then return { x = call[1], y = call[2] } end
  end
end

-- A chip's width is the line height times a fraction, so a position derived from
-- it is compared to the pixel rather than to the bit.
local function near(actual, expected, msg)
  t.truthy(math.abs(actual - expected) < 0.001,
           msg .. ' (' .. tostring(actual) .. ' vs ' .. tostring(expected) .. ')')
end

return {
  {
    -- The row read off the draw calls it made: a band on the body's floor, and on it
    -- each member's letter in a keycap with its title a gap past it. The numbers are
    -- the row's own pads and gaps, in the fake's units.
    name = 'the level lays out as keycap letters and titles on one line',
    run = function()
      fresh()
      t.truthy(GLYPH < LINE * 0.9, 'a glyph is narrower than the chip\'s square floor (precondition)')
      drawRow(WIDE)

      local band = filled('help.box')[1]
      t.deepEq({ band.x0, band.x1 }, { 0, WIDE }, 'the band spans the row it was given')
      t.eq(band.y1, BOTTOM, 'and stands on the body\'s floor')
      t.eq(BOTTOM - band.y0, PAD * 2 + LINE, 'one line tall')

      local rowY = band.y0 + PAD
      local letter, grid = textAt('G'), textAt('Grid')
      t.eq(letter.y, rowY, 'the first member\'s letter sits on the line')
      near(letter.x, PAD + 2 + (LINE * 0.9 - GLYPH) / 2, 'centred in its keycap')
      t.eq(grid.y, rowY, 'its title reads on the same line')
      near(grid.x, PAD + CHIP_W + LETTER_GAP, 'a gap past the keycap')

      local column = textAt('Column')
      near(column.x, grid.x + GLYPH * #'Grid' + MEMBER_GAP + CHIP_W + LETTER_GAP,
           'and the next member follows a member gap on')
      t.deepEq({ textAt('Region').y, textAt('Save').y }, { rowY, rowY },
               'the groups in tree order, then the top-level leaf')
    end,
  },

  {
    -- What the highlight looks like: a fill in its own role, bracketing one member's
    -- keycap and title together, which the arrow keys move along the level.
    name = 'the highlighted member wears a fill, and only that member',
    run = function()
      fresh()
      drawRow(WIDE)

      local fills = filled('menu.highlight')
      t.eq(#fills, 1, 'exactly one member is filled')
      local grid = textAt('Grid')
      near(fills[1].x0, PAD - HL_PAD, 'the fill opens a little before the keycap')
      near(fills[1].x1, grid.x + GLYPH * #'Grid' + HL_PAD, 'and closes a little past the title')
      t.eq(fills[1].y1 - fills[1].y0, LINE, 'standing one line tall')

      mgr:invoke('menuRight')
      drawRow(WIDE)
      local moved = filled('menu.highlight')[1]
      near(moved.x0, textAt('Column').x - CHIP_W - LETTER_GAP - HL_PAD,
           'Right carries the fill to the next member')
    end,
  },

  {
    -- A level wider than the row it was given: the members pack into as many lines as
    -- they need, the last stands on the floor, and the band grows upward for the rest.
    name = 'a level too wide for the row wraps upward',
    run = function()
      fresh()
      drawRow(NARROW)

      local band = filled('help.box')[1]
      t.eq(BOTTOM - band.y0, PAD * 2 + LINE * 2 + ROW_GAP, 'the band stands two lines tall')
      t.eq(band.y1, BOTTOM, 'still on the floor, so it grew upward')

      local upper, lower = band.y0 + PAD, band.y0 + PAD + LINE + ROW_GAP
      t.deepEq({ textAt('Grid').y, textAt('Column').y }, { upper, upper },
               'the first two members take the upper line')
      t.deepEq({ textAt('Region').y, textAt('Save').y }, { lower, lower },
               'and the rest read below them')
      t.eq(lower + LINE, BOTTOM - PAD, 'the last line sits on the row\'s floor')
      t.eq(textAt('Region').x, textAt('Grid').x, 'a wrapped line opens at the same column')
      t.truthy(textAt('Column').x + GLYPH * #'Column' <= NARROW - PAD,
               'and every title is drawn inside the row')
    end,
  },
}
