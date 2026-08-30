-- The menu row's geometry (docs/menu.md § The row). A real menu is walked over a
-- synthetic manifest and tree, and its row drawn through the render module onto a
-- fake imgui whose draw calls record, so what was drawn is read back off the list.
--
-- The assertions are relations between the things drawn — a title beside its keycap,
-- a fill covering the member it lies under, a wrapped line one pitch above the last —
-- rather than the module's pads and gaps restated here, so retuning a gap does not
-- break a test that is not about it. The fake's own metrics, a line's height and a
-- glyph's width, are the only numbers.
--
-- The fake chrome hands each colour role a value of its own, so a fill is found by
-- the role it was drawn in rather than by its position in the list.

local t    = require('support')
local util = require('util')

local img = t.imgui()

local LINE, GLYPH = 14, 8           -- the fake's text line height; its width per character
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

-- The level the walk offers at the top: three groups in tree order, then the one
-- top-level leaf. Every assertion about order reads this.
local MEMBERS = { { letter = 'G', title = 'Grid'   }, { letter = 'C', title = 'Column' },
                  { letter = 'R', title = 'Region' }, { letter = 'S', title = 'Save'   } }

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

-- Everything drawn, as the box it occupies, carrying the call that drew it: a fill
-- under a member is drawn before the member, and the order of two boxes says so.
local function rects(role)
  local found = {}
  for index, call in ipairs(drawn) do
    if call.op == 'RectFilled' and (role == nil or call[5] == colourFor(role)) then
      util.add(found, { x0 = call[1], y0 = call[2], x1 = call[3], y1 = call[4],
                        colour = call[5], at = index })
    end
  end
  return found
end

local function texts()
  local found = {}
  for index, call in ipairs(drawn) do
    if call.op == 'Text' then
      local text = tostring(call[4])
      util.add(found, { text = text, x0 = call[1], y0 = call[2],
                        x1 = call[1] + GLYPH * #text, y1 = call[2] + LINE, at = index })
    end
  end
  return found
end

local function boxOf(text)
  for _, box in ipairs(texts()) do if box.text == text then return box end end
end

local function contains(outer, inner)
  return outer.x0 <= inner.x0 and outer.x1 >= inner.x1
     and outer.y0 <= inner.y0 and outer.y1 >= inner.y1
end

-- The keycap a letter sits in: the rect drawn around it in none of the strip's own
-- roles, which is what the chips are.
local function keycapAround(letter)
  for _, rect in ipairs(rects()) do
    local own = rect.colour == colourFor('help.box') or rect.colour == colourFor('menu.rule')
                  or rect.colour == colourFor('menu.highlight')
    if not own and contains(rect, letter) then return rect end
  end
end

return {
  {
    -- The level read off the draw calls it made: each member's letter in a keycap with
    -- its title beside it, the members in the order the level offers them.
    name = 'every member draws as its letter in a keycap beside its title, in level order',
    run = function()
      fresh()
      drawRow(WIDE)

      local previous
      for _, member in ipairs(MEMBERS) do
        local letter, title = boxOf(member.letter), boxOf(member.title)
        t.truthy(letter and title, member.title .. ' draws its letter and its title')
        t.eq(title.y0, letter.y0, member.title .. ' reads on its letter\'s line')
        local keycap = keycapAround(letter)
        t.truthy(keycap, member.title .. '\'s letter sits in a keycap')
        t.truthy(title.x0 > keycap.x1, 'and its title follows the keycap')
        if previous then
          t.truthy(keycap.x0 > previous.x1, member.title .. ' follows the member before it')
        end
        previous = title
      end
    end,
  },

  {
    -- The ground the row stands on: a strip across the row it was given, ruled along its
    -- top edge, holding everything the row draws.
    name = 'the strip spans the row, stands on its floor, and rules its top edge',
    run = function()
      fresh()
      drawRow(WIDE)

      local strip = rects('help.box')[1]
      t.deepEq({ strip.x0, strip.x1 }, { 0, WIDE }, 'the strip spans the row it was given')
      t.eq(strip.y1, BOTTOM, 'and stands on the floor it was given')

      local rules = rects('menu.rule')
      t.eq(#rules, 1, 'one rule is drawn')
      t.deepEq({ rules[1].x0, rules[1].x1 }, { strip.x0, strip.x1 }, 'running the strip\'s full width')
      t.eq(rules[1].y0, strip.y0, 'along its top edge')
      t.eq(rules[1].y1 - rules[1].y0, 1, 'one pixel of it')

      for _, box in ipairs(texts()) do
        t.truthy(contains(strip, box), box.text .. ' is drawn inside the strip')
      end
      local line = boxOf('Grid')
      t.eq(line.y0 - strip.y0, strip.y1 - line.y1, 'the line sits between equal pads')
    end,
  },

  {
    -- What the highlight looks like: a fill under one member's keycap and title together,
    -- which the arrow keys move along the level.
    name = 'the highlighted member wears a fill under it, and only that member',
    run = function()
      fresh()
      drawRow(WIDE)

      local fills = rects('menu.highlight')
      t.eq(#fills, 1, 'exactly one member is filled')
      local letter, title = boxOf('G'), boxOf('Grid')
      t.truthy(contains(fills[1], keycapAround(letter)) and contains(fills[1], title),
               'the fill covers that member\'s keycap and its title together')
      t.truthy(fills[1].at < letter.at, 'and is drawn before them, so it lies under')
      t.truthy(fills[1].x1 < keycapAround(boxOf('C')).x0, 'stopping short of the next member')

      mgr:invoke('menuRight')
      drawRow(WIDE)
      local moved = rects('menu.highlight')[1]
      t.truthy(contains(moved, keycapAround(boxOf('C'))) and contains(moved, boxOf('Column')),
               'Right carries the fill to the next member')
    end,
  },

  {
    -- A level wider than the row it was given: the members pack into as many lines as
    -- they need, the last stands on the floor, and the strip grows upward for the rest.
    name = 'a level too wide for the row wraps upward',
    run = function()
      fresh()
      drawRow(WIDE)
      local oneLine = rects('help.box')[1]
      local oneHigh = oneLine.y1 - oneLine.y0

      drawRow(NARROW)
      local strip = rects('help.box')[1]
      t.eq(strip.y1, BOTTOM, 'the strip still stands on the floor, so it grew upward')

      local ys = {}
      for _, member in ipairs(MEMBERS) do util.add(ys, boxOf(member.title).y0) end
      for index = 2, #ys do
        t.truthy(ys[index] >= ys[index - 1], 'the level reads across and then down, never back up')
      end
      local upper, lower = ys[1], ys[#ys]
      t.truthy(lower >= upper + LINE, 'it took a second line, clear of the first')
      t.eq((strip.y1 - strip.y0) - oneHigh, lower - upper,
           'and the strip grew by exactly the pitch it wrapped by')

      local opens
      for _, member in ipairs(MEMBERS) do
        local letter = boxOf(member.letter)
        if letter.y0 == lower and not opens then opens = letter end
      end
      t.eq(opens.x0, boxOf(MEMBERS[1].letter).x0, 'the wrapped line opens at the same column')
      for _, box in ipairs(texts()) do
        t.truthy(contains(strip, box), box.text .. ' is drawn inside the strip')
      end
    end,
  },
}
