-- See docs/painter.md for the model.
-- @noindex

-- A colour-disciplined drawlist binder parametrised over a coordinate system.
--
-- painter.new is handed an affine transform (origin + per-axis scale); its
-- draw methods then take LOGICAL coordinates and convert through that one
-- transform. The same painter exposes toScreen / fromScreen, so a page's
-- hit-test resolves clicks through the identical map the draw pass used —
-- the forward map and its inverse have a single source and cannot drift.
--
-- A colour is passed by NAME and resolved through chrome.colour: the project
-- keeps colours in named config. Genuinely computed colours — the golden-
-- ratio slot hues — have no name, so painter.hue mints them as opaque {u32}
-- tokens; a draw method takes a name or a token and raises on a bare int, so
-- the named-colour discipline can't be bypassed by hand-packing one. Stroke
-- widths, corner radii and font sizes are screen-space and pass through
-- unconverted; only positions are mapped.
--
-- Per-axis affine (screen = origin + logical * scale) is enough for every
-- page: tracker cells, arrange track/row, wiring's centre-origin canvas all
-- differ only in origin and scale.

local ImGui = require 'imgui' '0.10'

local M = {}

----- Rotated text

-- The drawlist API has no rotated text and no vertex access, so a rotated
-- label is LICE-rasterised once into a white texture (alpha = coverage).
local OVERSAMPLE = 2   -- rasterise at 2x, draw half-size: retina stays crisp

local rotatedCache = {}   -- size .. ':' .. text -> {img, w, h} | false: LICE path unavailable

local function rasteriseRotated(ctx, s, size)
  local fontH = size * OVERSAMPLE
  local bmpW, bmpH = (fontH + 2) * (utf8.len(s) or #s), fontH + 4
  local bmp  = reaper.JS_LICE_CreateBitmap(true, bmpW, bmpH)
  local gdi  = reaper.JS_GDI_CreateFont(fontH, 400, 0, false, false, false,
    reaper.GetOS():find('Win') and 'Segoe UI' or 'Helvetica Neue')
  local lice = reaper.JS_LICE_CreateFont()
  reaper.JS_LICE_SetFontFromGDI(lice, gdi, '')
  reaper.JS_LICE_SetFontColor(lice, 0xFF000000)
  reaper.JS_LICE_SetFontBkColor(lice, 0xFFFFFFFF)
  reaper.JS_LICE_Clear(bmp, 0xFFFFFFFF)
  reaper.JS_LICE_DrawText(bmp, lice, s, #s, 0, 0, bmpW, bmpH)

  -- Black on white → coverage off the green channel; the texture stays
  -- white so the draw-time tint supplies the colour.
  local coverage, texW = {}, 0
  for y = 0, bmpH - 1 do
    for x = 0, bmpW - 1 do
      local cov = 255 - (math.floor(reaper.JS_LICE_GetPixel(bmp, x, y)) >> 8 & 0xFF)
      if cov > 0 and x >= texW then texW = x + 1 end
      coverage[y * bmpW + x] = cov
    end
  end
  reaper.JS_LICE_DestroyFont(lice)
  reaper.JS_GDI_DeleteObject(gdi)
  reaper.JS_LICE_DestroyBitmap(bmp)
  if texW == 0 then return false end

  texW = math.min(bmpW, texW + 2)
  local pixels = reaper.new_array(texW * bmpH)
  for y = 0, bmpH - 1 do
    for x = 0, texW - 1 do
      pixels[y * texW + x + 1] = 0xFFFFFF00 + coverage[y * bmpW + x]
    end
  end
  local img = ImGui.CreateImageFromSize(texW, bmpH)
  ImGui.Image_SetPixels_Array(img, 0, 0, texW, bmpH, pixels)
  ImGui.Attach(ctx, img)
  return { img = img, w = texW, h = bmpH }
end

-- pcall doubles as the js_ReaScriptAPI presence check; a failure caches
-- false so callers fall back for good.
local function rotatedTex(ctx, s, size)
  local key = size .. ':' .. s
  if rotatedCache[key] == nil then
    local ok, tex = pcall(rasteriseRotated, ctx, s, size)
    rotatedCache[key] = ok and tex or false
  end
  return rotatedCache[key]
end

--contract: strip (w,h) in screen px for textUp at this size; nil when the LICE path is unavailable
function M.measureRotated(ctx, s, size)
  local tex = rotatedTex(ctx, s, size)
  if not tex then return nil end
  return tex.h / OVERSAMPLE, tex.w / OVERSAMPLE
end

--contract: sx/sy default 1 and must be non-zero (fromScreen divides); ox/oy default 0.
function M.new(ctx, chrome, transform)
  -- ox/oy round to whole pixels so an integer logical coord lands on a pixel
  -- boundary; sx/sy pass through (a page may scale by a fractional zoom).
  local ox, oy = math.floor((transform.ox or 0) + 0.5), math.floor((transform.oy or 0) + 0.5)
  local sx, sy = transform.sx or 1, transform.sy or 1
  local snap   = transform.snap
  local dl     = ImGui.GetWindowDrawList(ctx)
  local colour = chrome.colour

  -- snap=true rounds a converted position to whole pixels — for a pixel-aligned
  -- grid whose fractional logical coords (an off-row take edge) would otherwise
  -- land between pixels and blur. fromScreen never snaps: a hit-test wants the
  -- true sub-pixel logical position, not the drawn cell's rounded one.
  local function toScreen(lx, ly)
    local px, py = ox + lx * sx, oy + ly * sy
    if not snap then return px, py end
    return math.floor(px + 0.5), math.floor(py + 0.5)
  end
  local function fromScreen(px, py) return (px - ox) / sx, (py - oy) / sy end

  local p = { ox = ox, oy = oy, sx = sx, sy = sy,
              toScreen = toScreen, fromScreen = fromScreen }

  -- A name resolves through chrome; a {u32} token (minted by painter.hue for
  -- the rare computed colour) passes its packed value through. A bare int is
  -- rejected on purpose — it's the one way to smuggle an unnamed colour past
  -- the palette, the very discipline this binder exists to keep.
  local function col(c)
    if type(c) == 'string' then return colour(c) end
    if type(c) == 'table'  then return c.u32      end
    error('painter: colour must be a name or a painter token, not a raw int')
  end

  function p.fill(r, name, rounding)
    local x0, y0 = toScreen(r.x0, r.y0)
    local x1, y1 = toScreen(r.x1, r.y1)
    ImGui.DrawList_AddRectFilled(dl, x0, y0, x1, y1, col(name), rounding or 0)
  end

  function p.stroke(r, name, thick, rounding)
    local x0, y0 = toScreen(r.x0, r.y0)
    local x1, y1 = toScreen(r.x1, r.y1)
    ImGui.DrawList_AddRect(dl, x0, y0, x1, y1, col(name), rounding or 0, 0, thick or 1)
  end

  -- A given font draws via AddTextEx (font passed to the draw call, no stack
  -- push); nil font draws in the current font.
  function p.text(x, y, name, s, font, size)
    local sx_, sy_ = toScreen(x, y)
    if font then
      ImGui.DrawList_AddTextEx(dl, font, size, sx_, sy_, col(name), s)
    else
      ImGui.DrawList_AddText(dl, sx_, sy_, col(name), s)
    end
  end

  function p.line(x0, y0, x1, y1, name, thick)
    local ax, ay = toScreen(x0, y0)
    local bx, by = toScreen(x1, y1)
    ImGui.DrawList_AddLine(dl, ax, ay, bx, by, col(name), thick or 1)
  end

  function p.tri(x0, y0, x1, y1, x2, y2, name)
    local ax, ay = toScreen(x0, y0)
    local bx, by = toScreen(x1, y1)
    local cx, cy = toScreen(x2, y2)
    ImGui.DrawList_AddTriangleFilled(dl, ax, ay, bx, by, cx, cy, col(name))
  end

  --contract: centre is logical; radius is screen px so the dot stays round under non-uniform scale.
  function p.circle(x, y, r, name, segments)
    local cx, cy = toScreen(x, y)
    ImGui.DrawList_AddCircleFilled(dl, cx, cy, r, col(name), segments or 0)
  end

  -- pts is a flat list of LOGICAL coords {x0,y0,x1,y1,...}; each pair converts.
  -- closed joins last->first. new_array wants screen coords, so convert first.
  function p.polyline(pts, name, thick, closed)
    local screen = {}
    for i = 1, #pts, 2 do
      screen[i], screen[i + 1] = toScreen(pts[i], pts[i + 1])
    end
    local flags = closed and ImGui.DrawFlags_Closed or ImGui.DrawFlags_None
    ImGui.DrawList_AddPolyline(dl, reaper.new_array(screen), col(name), flags, thick or 1)
  end

  -- Clip stack: corners convert like any rect; intersect defaults true
  -- (nest within the current clip), pass false to replace it.
  function p.pushClip(r, intersect)
    local x0, y0 = toScreen(r.x0, r.y0)
    local x1, y1 = toScreen(r.x1, r.y1)
    ImGui.DrawList_PushClipRect(dl, x0, y0, x1, y1, intersect ~= false)
  end

  function p.popClip() ImGui.DrawList_PopClipRect(dl) end

  -- Path builder for open polylines with arc corners (the loop/tail
  -- bracket). Points are logical and convert; a radius is screen px like a
  -- corner radius and angles pass through, so arcs assume uniform scale.
  function p.pathClear() ImGui.DrawList_PathClear(dl) end

  function p.pathLineTo(x, y)
    local px, py = toScreen(x, y)
    ImGui.DrawList_PathLineTo(dl, px, py)
  end

  --contract: centre is logical; radius is screen px and angles pass through, so arcs need sx==sy.
  function p.pathArcTo(cx, cy, r, a0, a1)
    local x, y = toScreen(cx, cy)
    ImGui.DrawList_PathArcTo(dl, x, y, r, a0, a1)
  end

  function p.pathStroke(name, thick)
    ImGui.DrawList_PathStroke(dl, col(name), ImGui.DrawFlags_None, thick or 1)
  end

  -- CalcTextSize has no font parameter — it measures in the pushed font — so
  -- measuring in a specific font means pushing it for the call. Pass the same
  -- (font, size) used to draw, or the widths drift from the drawn glyphs.
  function p.measure(s, font, size)
    if not font then return ImGui.CalcTextSize(ctx, s) end
    ImGui.PushFont(ctx, font, size)
    local w, h = ImGui.CalcTextSize(ctx, s)
    ImGui.PopFont(ctx)
    return w, h
  end

  -- Rotated −π/2 (reads bottom-to-top, glyph tops left): the corner
  -- permutation IS the rotation — the horizontal raster maps TL → bottom-left.
  --contract: x is the strip's horizontal centre, yBottom its bottom edge; size is screen px
  --contract: returns false (drawing nothing) when the LICE path is unavailable; callers fall back
  function p.textUp(x, yBottom, name, s, size)
    local tex = rotatedTex(ctx, s, size)
    if not tex then return false end
    local cx, by = toScreen(x, yBottom)
    local sw, sh = tex.h / OVERSAMPLE, tex.w / OVERSAMPLE
    local x0, yB = math.floor(cx - sw / 2), math.floor(by)
    ImGui.DrawList_AddImageQuad(dl, tex.img,
      x0, yB,   x0, yB - sh,   x0 + sw, yB - sh,   x0 + sw, yB,
      0, 0, 1, 0, 1, 1, 0, 1, col(name))
    return true
  end

  return p
end

-- HSV→RGB in pure Lua so hue and hueNative share one (r,g,b) source —
-- the ImGui pack and the REAPER native pack must agree per idx.
local function hsvToRgb(h, s, v)
  local i = math.floor(h * 6)
  local f = h * 6 - i
  local p = v * (1 - s)
  local q = v * (1 - f * s)
  local t = v * (1 - (1 - f) * s)
  i = i % 6
  if i == 0 then return v, t, p end
  if i == 1 then return q, v, p end
  if i == 2 then return p, v, t end
  if i == 3 then return p, q, v end
  if i == 4 then return t, p, v end
  return v, p, q
end

local function hueRGB(idx, sat, val)
  local h = ((idx + 1) * 0.6180339887498949) % 1.0
  return hsvToRgb(h, sat, val)
end

--contract: returns an opaque colour token (not a bare int); pass to a draw method's colour arg.
-- The idx-th visually-distinct hue: golden-ratio rotation throws adjacent
-- indices to opposite sides of the wheel. sat/val/alpha tone it.
function M.hue(idx, sat, val, alpha)
  local r, g, b = hueRGB(idx, sat, val)
  return { u32 = ImGui.ColorConvertDouble4ToU32(r, g, b, alpha) }
end

--contract: REAPER native int (|0x1000000 set) for I_CUSTOMCOLOR; (sat,val) match the grid fill hue.
function M.hueNative(idx)
  local r, g, b = hueRGB(idx, 0.55, 0.78)
  return reaper.ColorToNative(
    math.floor(r * 255 + 0.5),
    math.floor(g * 255 + 0.5),
    math.floor(b * 255 + 0.5)) | 0x1000000
end

return M
