-- painter: coordinate-parametrised, colour-disciplined drawlist binder.
-- A recording ImGui stub captures DrawList_* calls so we can assert that
-- positions convert through the transform, colours resolve by NAME, and the
-- font path uses AddTextEx (no stack push) while measure pushes/pops.

local t = require('support')

local calls
local function rec(name)
  return function(...) calls[#calls + 1] = { fn = name, args = { ... } } end
end

local fakeImGui = {}
for _, n in ipairs{
  'DrawList_AddRectFilled', 'DrawList_AddRect', 'DrawList_AddText',
  'DrawList_AddTextEx', 'DrawList_AddLine', 'DrawList_AddTriangleFilled',
  'PushFont', 'PopFont',
} do fakeImGui[n] = rec(n) end
fakeImGui.GetWindowDrawList = function(_) return 'DL' end
fakeImGui.CalcTextSize = function(_, s)
  calls[#calls + 1] = { fn = 'CalcTextSize', args = { s } }
  return #s * 7, 13
end

package.preload['imgui'] = function() return function(_) return fakeImGui end end

local painter = require('painter')

-- chrome stub: colour(name) -> 'col:'..name, so an assertion of the resolved
-- value proves the NAME reached chrome (not a pre-resolved int).
local chrome = { colour = function(name) return 'col:' .. name end }

-- ox=100 oy=200 sx=2 sy=3 — distinct per axis so a swapped axis is caught.
local function mk() return painter.new('CTX', chrome, { ox = 100, oy = 200, sx = 2, sy = 3 }) end

local function last() return calls[#calls] end
local function has(fn)
  for _, c in ipairs(calls) do if c.fn == fn then return true end end
  return false
end

return {
  {
    name = 'toScreen / fromScreen are inverse — one transform, no drift',
    run = function()
      calls = {}
      local p = mk()
      t.eq(p.ox, 100); t.eq(p.sx, 2)
      local sx, sy = p.toScreen(3, 4)
      t.eq(sx, 106); t.eq(sy, 212)
      local lx, ly = p.fromScreen(sx, sy)
      t.eq(lx, 3); t.eq(ly, 4)
    end,
  },
  {
    name = 'fill converts both corners, resolves colour by name, passes rounding',
    run = function()
      calls = {}
      mk().fill({ x0 = 1, y0 = 1, x1 = 3, y1 = 4 }, 'bg', 5)
      t.deepEq(last(), { fn = 'DrawList_AddRectFilled',
        args = { 'DL', 102, 203, 106, 212, 'col:bg', 5 } })
    end,
  },
  {
    name = 'stroke maps corners but leaves thickness / rounding in screen px',
    run = function()
      calls = {}
      mk().stroke({ x0 = 1, y0 = 1, x1 = 3, y1 = 4 }, 'sep', 2, 4)
      t.deepEq(last(), { fn = 'DrawList_AddRect',
        args = { 'DL', 102, 203, 106, 212, 'col:sep', 4, 0, 2 } })
    end,
  },
  {
    name = 'line and tri convert every endpoint',
    run = function()
      calls = {}
      local p = mk()
      p.line(1, 1, 3, 4, 'wire', 1)
      t.deepEq(last(), { fn = 'DrawList_AddLine',
        args = { 'DL', 102, 203, 106, 212, 'col:wire', 1 } })
      p.tri(1, 1, 3, 1, 2, 4, 'arrow')
      t.deepEq(last(), { fn = 'DrawList_AddTriangleFilled',
        args = { 'DL', 102, 203, 106, 203, 104, 212, 'col:arrow' } })
    end,
  },
  {
    name = 'text without a font uses AddText at the mapped position',
    run = function()
      calls = {}
      mk().text(1, 1, 'text', 'hi')
      t.deepEq(last(), { fn = 'DrawList_AddText',
        args = { 'DL', 102, 203, 'col:text', 'hi' } })
    end,
  },
  {
    name = 'text with a font uses AddTextEx and never pushes the font stack',
    run = function()
      calls = {}
      mk().text(1, 1, 'text', 'hi', 'WIRE', 14)
      t.deepEq(last(), { fn = 'DrawList_AddTextEx',
        args = { 'DL', 'WIRE', 14, 102, 203, 'col:text', 'hi' } })
      t.falsy(has('PushFont'), 'AddTextEx path must not push the font stack')
    end,
  },
  {
    name = 'measure without a font reads CalcTextSize directly',
    run = function()
      calls = {}
      local w, h = mk().measure('hello')
      t.eq(w, 35); t.eq(h, 13)
      t.falsy(has('PushFont'), 'default font needs no push')
    end,
  },
  {
    name = 'measure with a font brackets CalcTextSize in Push/PopFont',
    run = function()
      calls = {}
      local w = mk().measure('hi', 'WIRE', 14)
      t.eq(w, 14)
      t.deepEq(calls, {
        { fn = 'PushFont',     args = { 'CTX', 'WIRE', 14 } },
        { fn = 'CalcTextSize', args = { 'hi' } },
        { fn = 'PopFont',      args = { 'CTX' } },
      })
    end,
  },
}
