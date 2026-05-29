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

--contract: transform.sx/sy default 1, ox/oy default 0; scale must be non-zero (fromScreen divides).
function M.new(ctx, chrome, transform)
  local ox, oy = transform.ox or 0, transform.oy or 0
  local sx, sy = transform.sx or 1, transform.sy or 1
  local dl     = ImGui.GetWindowDrawList(ctx)
  local colour = chrome.colour

  local function toScreen(lx, ly)   return ox + lx * sx, oy + ly * sy end
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

  return p
end

--contract: returns an opaque colour token (not a bare int); pass to a draw method's colour arg.
-- The idx-th visually-distinct hue: golden-ratio rotation throws adjacent
-- indices to opposite sides of the wheel. sat/val/alpha tone it.
function M.hue(idx, sat, val, alpha)
  local h = ((idx + 1) * 0.6180339887498949) % 1.0
  local r, g, b = ImGui.ColorConvertHSVtoRGB(h, sat, val)
  return { u32 = ImGui.ColorConvertDouble4ToU32(r, g, b, alpha) }
end

return M
