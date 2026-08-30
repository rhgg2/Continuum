-- Ppq-keyed breakpoint curves: the value of one at a ppq, the slice of one to a span, and the two
-- rules by which a curve meets the end of a half-open window. see docs/generators.md § Route-by-window

--invariant: stateless module: pure functions over curves, no module-level state
--invariant: REAPER convention: the shape on a breakpoint governs the segment from it to the next
--invariant: a curve is held both ways -- the first value before it, the last value after it
--shape: breakpoint = { ppq, val, [shape], [tension] }; curve = breakpoints ascending in ppq
--shape: shape ∈ { step, linear, slow, fast-start, fast-end, bezier }; tension only on bezier
local util = require 'util'

local curves = {}

function curves.isCurved(shape)
  return shape and shape ~= 'step' and shape ~= 'linear'
end

function curves.anyNonZero(curve)
  for _, point in ipairs(curve) do if point.val ~= 0 then return true end end
  return false
end

----- Sampling one segment

local sample do
  local BEZIER = {
    { 0.2794, 0.4636,    0.4636 },
    { 0.3442, 0.7704,    0.3384 },
    { 0.4020, 0.9849,    0.2466 },
    { 0.4642, 1.1455,    0.1812 },
    { 0.5326, 1.2647,    0.1353 },
    { 0.6059, 1.3532,    0.1011 },
    { 0.6820, 1.4199,    0.0738 },
    { 0.7604, 1.4714,    0.0515 },
    { 0.8397, 1.5116,    0.0321 },
    { 0.9198, 1.5441,    0.0154 },
    { 1.0000, math.pi / 2, 0 },
  }

  local function bezierSample(tau, t)
    if t <= 0 then return 0 end
    if t >= 1 then return 1 end
    local fi     = util.clamp(math.abs(tau), 0, 1) * 10
    local i      = math.min(math.floor(fi), 9)
    local f      = fi - i
    local r0, r1 = BEZIER[i + 1], BEZIER[i + 2]
    local h      = r0[1] + (r1[1] - r0[1]) * f
    local tL     = r0[2] + (r1[2] - r0[2]) * f
    local tS     = r0[3] + (r1[3] - r0[3]) * f
    local t1, t2 = tS, tL
    if tau < 0 then t1, t2 = tL, tS end
    local ax, ay = h * math.cos(t1), h * math.sin(t1)
    local bx, by = 1 - h * math.cos(t2), 1 - h * math.sin(t2)
    local lo, hi = 0, 1
    for _ = 1, 20 do
      local s = (lo + hi) * 0.5
      local u = 1 - s
      local x = 3 * u * u * s * ax + 3 * u * s * s * bx + s * s * s
      if x < t then lo = s else hi = s end
    end
    local s = (lo + hi) * 0.5
    local u = 1 - s
    return 3 * u * u * s * ay + 3 * u * s * s * by + s * s * s
  end

  -- Fraction of the segment's rise reached at fraction t of its span; an unnamed shape returns
  -- nothing, so interpolating one raises where the arithmetic meets it.
  function sample(shape, tension, t)
    if shape == 'step' then
      return t >= 1 and 1 or 0
    elseif shape == 'linear' then
      return t
    elseif shape == 'slow' then
      return t * t * (3 - 2 * t)
    elseif shape == 'fast-start' then
      local u = 1 - t; return 1 - u * u * u
    elseif shape == 'fast-end' then
      return t * t * t
    elseif shape == 'bezier' then
      return bezierSample(tension or 0, t)
    end
  end
end

-- Value of the pair A -> B at ppq. field defaults to 'val'; pass 'cents' to interpolate the
-- authored cents stream (rebuildPbs seats).
function curves.interpolate(A, B, ppq, field)
  field = field or 'val'
  if not A.shape or A.shape == 'step' then return A[field] end
  local span = B.ppq - A.ppq
  if span == 0 then return A[field] end
  local t = (ppq - A.ppq) / span
  return (A[field] or 0) + sample(A.shape, A.tension, t) * ((B[field] or 0) - (A[field] or 0))
end

----- Whole curves

-- Curve value at ppq: held both ways (first value before, last after), shape interp within.
function curves.eval(curve, ppq)
  if #curve == 0 then return 0 end
  local i = util.firstAfter(curve, ppq)
  local A, B = curve[i - 1], curve[i]
  if not A then return curve[1].val end
  if not B then return A.val end
  return curves.interpolate(A, B, ppq, 'val')
end

-- Slice a ppq-keyed base curve to [startL, endL]: entering/closing values at the edges (shape/tension
-- from the governing point so interpolation carries through), authored points strictly within.
function curves.slice(base, startL, endL)
  if #base == 0 then return {} end
  local function edge(ppq)
    local govern = base[util.firstAfter(base, ppq) - 1]
    return { ppq = ppq, val = curves.eval(base, ppq),
             shape = govern and govern.shape or 'step', tension = govern and govern.tension }
  end
  local pts = { edge(startL) }
  for _, point in ipairs(base) do
    if point.ppq > startL and point.ppq < endL then util.add(pts, point) end
  end
  util.add(pts, edge(endL))
  return pts
end

----- Meeting a half-open window's end

-- A producer hands its target back before the window exits: one step point at eL-1, inside the
-- half-open span, so no close ever lands on the boundary row. see docs/generators.md § Route-by-window
function curves.closeAtWindowEnd(pts, val, sL, eL)
  if eL - 1 <= sL then return pts end
  if pts[#pts] and pts[#pts].ppq == eL - 1 then table.remove(pts) end   -- the close owns the tick
  util.add(pts, { ppq = eL - 1, val = val, shape = 'step' })
  return pts
end

-- A stage's material stops short of the tick closeAtWindowEnd owns: anything at or past the line
-- collapses onto that last tick, so a closing control point survives. see docs/generators.md § Route-by-window
function curves.foldIntoWindow(pts, sL, eL)
  local last, out = eL - 2, {}   -- eL-1 is the close's; eL-2 is the last tick material may hold
  if last < sL then return out end
  for _, p in ipairs(pts) do
    if p.ppq >= sL and p.ppq < last then
      util.add(out, p)
    elseif p.ppq >= last then
      if out[#out] and out[#out].ppq == last then table.remove(out) end   -- one point owns the tick
      util.add(out, util.assign(util.clone(p), { ppq = last }))
    end
  end
  return out
end

return curves
