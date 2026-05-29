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
  'DrawList_PushClipRect', 'DrawList_PopClipRect',
  'DrawList_PathClear', 'DrawList_PathLineTo', 'DrawList_PathArcTo', 'DrawList_PathStroke',
  'DrawList_AddCircleFilled', 'DrawList_AddPolyline',
  'PushFont', 'PopFont',
} do fakeImGui[n] = rec(n) end
fakeImGui.DrawFlags_None   = 0
fakeImGui.DrawFlags_Closed = 1
-- painter.polyline hands its converted screen coords to reaper.new_array; the
-- real one returns an FFI buffer, so pass the flat array straight through to
-- let a test assert on the converted coordinates.
reaper = reaper or {}
reaper.new_array = function(a) return a end
fakeImGui.GetWindowDrawList = function(_) return 'DL' end
fakeImGui.CalcTextSize = function(_, s)
  calls[#calls + 1] = { fn = 'CalcTextSize', args = { s } }
  return #s * 7, 13
end
-- Pure colour maths for painter.hue: HSV passthrough packed into one int, so a
-- test can prove hue mints a distinct token per index without a real ImGui.
fakeImGui.ColorConvertHSVtoRGB    = function(h, s, v)    return h, s, v end
fakeImGui.ColorConvertDouble4ToU32 = function(r, g, b, a) return r * 1e6 + g * 1e3 + b + a end

package.preload['imgui'] = function() return function(_) return fakeImGui end end
-- An earlier spec's run loads painter (via wiringPage) and imgui under a
-- different fake; drop both from the cache so painter rebinds to the recording
-- stub above rather than whatever was cached first.
package.loaded['imgui']   = nil
package.loaded['painter'] = nil

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
    name = 'circle maps the centre but keeps the radius in screen px',
    run = function()
      calls = {}
      mk().circle(1, 1, 5, 'dot')
      t.deepEq(last(), { fn = 'DrawList_AddCircleFilled',
        args = { 'DL', 102, 203, 5, 'col:dot', 0 } })
    end,
  },
  {
    name = 'polyline converts every logical pair; closed sets the closed flag',
    run = function()
      calls = {}
      local p = mk()
      p.polyline({ 1, 1, 3, 4 }, 'wire', 1.5)
      t.deepEq(last(), { fn = 'DrawList_AddPolyline',
        args = { 'DL', { 102, 203, 106, 212 }, 'col:wire', 0, 1.5 } })
      p.polyline({ 1, 1, 3, 4 }, 'wire', 1, true)
      t.eq(last().args[4], 1)
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
  {
    name = 'a name routes through chrome; a token passes its packed colour straight through',
    run = function()
      calls = {}
      local p = mk()
      p.fill({ x0 = 1, y0 = 1, x1 = 3, y1 = 4 }, 'bg')
      t.eq(last().args[6], 'col:bg')
      p.fill({ x0 = 1, y0 = 1, x1 = 3, y1 = 4 }, { u32 = 999 })
      t.eq(last().args[6], 999)
    end,
  },
  {
    name = 'a bare int colour is rejected — the one way to bypass the palette',
    run = function()
      local ok, err = pcall(function()
        mk().fill({ x0 = 1, y0 = 1, x1 = 3, y1 = 4 }, 0xFF00FF00)
      end)
      t.falsy(ok, 'a raw int must raise')
      t.truthy(tostring(err):match('raw int'), 'the error names the offence')
    end,
  },
  {
    name = 'painter.hue mints an opaque token; golden-ratio rotation makes adjacent indices distinct',
    run = function()
      local a = painter.hue(0, 0.5, 0.7, 1.0)
      local b = painter.hue(1, 0.5, 0.7, 1.0)
      t.eq(type(a), 'table')
      t.truthy(a.u32 ~= nil, 'token carries a packed colour')
      t.truthy(a.u32 ~= b.u32, 'different indices give different hues')
    end,
  },
  {
    name = 'pushClip converts both corners; intersect defaults true, explicit false respected',
    run = function()
      calls = {}
      local p = mk()
      p.pushClip({ x0 = 1, y0 = 1, x1 = 3, y1 = 4 })
      t.deepEq(last(), { fn = 'DrawList_PushClipRect', args = { 'DL', 102, 203, 106, 212, true } })
      p.pushClip({ x0 = 1, y0 = 1, x1 = 3, y1 = 4 }, false)
      t.eq(last().args[6], false)
      p.popClip()
      t.deepEq(last(), { fn = 'DrawList_PopClipRect', args = { 'DL' } })
    end,
  },
  {
    name = 'ox/oy round to whole pixels; sx/sy pass through unrounded',
    run = function()
      calls = {}
      local p = painter.new('CTX', chrome, { ox = 100.4, oy = 200.6, sx = 2, sy = 3 })
      t.eq(p.ox, 100); t.eq(p.oy, 201)
      t.eq(p.sx, 2);   t.eq(p.sy, 3)
      local x, y = p.toScreen(1, 1)
      t.eq(x, 102); t.eq(y, 204)
    end,
  },
  {
    name = 'snap rounds toScreen output for fractional logical coords; fromScreen stays exact',
    run = function()
      calls = {}
      local p = painter.new('CTX', chrome, { ox = 0, oy = 0, sx = 2, sy = 3, snap = true })
      local x, y = p.toScreen(0.5, 0.5)
      t.eq(x, 1); t.eq(y, 2)
      local lx, ly = p.fromScreen(1, 2)
      t.eq(lx, 0.5); t.eq(ly, 2 / 3)
    end,
  },
  {
    name = 'path: points convert, arc keeps screen-px radius and raw angles, stroke resolves colour by name',
    run = function()
      calls = {}
      local p = mk()
      p.pathClear()
      t.deepEq(last(), { fn = 'DrawList_PathClear', args = { 'DL' } })
      p.pathLineTo(3, 4)
      t.deepEq(last(), { fn = 'DrawList_PathLineTo', args = { 'DL', 106, 212 } })
      p.pathArcTo(1, 1, 5, 0, 3.14)
      t.deepEq(last(), { fn = 'DrawList_PathArcTo', args = { 'DL', 102, 203, 5, 0, 3.14 } })
      p.pathStroke('tail', 1.5)
      t.deepEq(last(), { fn = 'DrawList_PathStroke', args = { 'DL', 'col:tail', 0, 1.5 } })
    end,
  },
}
