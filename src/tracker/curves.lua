-- Ppq-keyed breakpoint curves: value at a ppq, slice to a span, and the fold of parallel
-- chain records over one target. See docs/generators.md § Route-by-window, § Multiplicity.

--invariant: stateless module: pure functions over curves, no module-level state
--invariant: REAPER convention: the shape on a breakpoint governs the segment from it to the next
--invariant: a curve is held both ways -- the first value before it, the last value after it
--shape: breakpoint = { ppq, val, [shape], [tension] }; curve = breakpoints ascending in ppq
--shape: shape ∈ { step, linear, slow, fast-start, fast-end, bezier }; tension only on bezier
--shape: chain record = { window = span, curve = curve, mode = 'replace' | 'augment' }
--invariant: a lone covering record folds to its own curve -- unclipped, and not a copy
local util  = require 'util'
local spans = require 'spans'

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

-- A host hands its target back before the window exits: one step point at eL-1, inside the
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

----- Folding parallel chains

-- Sum a held base curve and N macro curves over span [sL, eL) (half-open, so eL never emits).
-- Grid-samples curved segments lacking a closed-form sum; see docs/generators.md § Multiplicity ¶3-4.
function curves.sumStreams(base, macros, span, grid)
  local sL, eL = span[1], span[2]
  local summands = { base }
  for _, m in ipairs(macros) do util.add(summands, m) end
  local function segmentAt(curve, ppq)   -- the bp pair governing ppq; nil B at/beyond the end (held)
    local i = util.firstAfter(curve, ppq)
    return curve[i - 1], curve[i]
  end
  local function sumAt(ppq)
    local v = 0
    for _, c in ipairs(summands) do v = v + curves.eval(c, ppq) end
    return v                                   -- raw: each emission site rounds and clamps in its own units
  end

  -- feature points: span ends plus every constituent bp strictly within, deduped and sorted
  local seen, fps = { [sL] = true, [eL] = true }, { sL, eL }
  for _, c in ipairs(summands) do
    for _, bp in ipairs(c) do
      if bp.ppq > sL and bp.ppq < eL and not seen[bp.ppq] then
        seen[bp.ppq] = true; util.add(fps, bp.ppq)
      end
    end
  end
  table.sort(fps)

  -- Emit each pair's left point; eL bounds the final pair but is never emitted. Densify only where the
  -- sum has no single breakpoint for it: a sole mover keeps its whole segment. see docs/generators.md § Multiplicity
  local pts = {}
  for idx = 1, #fps - 1 do
    local p, q = fps[idx], fps[idx + 1]
    local anyCurved, movers, sole = false, 0, nil
    for _, c in ipairs(summands) do
      local A, B = segmentAt(c, p)
      local s = (A and B) and (A.shape or 'linear') or 'step'
      if s ~= 'step' then movers = movers + 1 end
      if curves.isCurved(s) then
        anyCurved = true
        if A.ppq == p and B.ppq == q then sole = A end
      end
    end
    if movers == 1 and sole then
      util.add(pts, { ppq = p, val = sumAt(p), shape = sole.shape, tension = sole.tension })
    else
      util.add(pts, { ppq = p, val = sumAt(p), shape = movers == 0 and 'step' or 'linear' })
      if anyCurved then
        local g = p + grid
        while g < q do
          util.add(pts, { ppq = g, val = sumAt(g), shape = 'linear' })
          g = g + grid
        end
      end
    end
  end
  return pts
end

local function negated(pts)
  local out = {}
  for _, point in ipairs(pts) do
    util.add(out, { ppq = point.ppq, val = -point.val, shape = point.shape, tension = point.tension })
  end
  return out
end
-- Fold records in storage order (later replace wins, painter fold); all-flat -> empty so stale seats sweep.
-- Kept distinct from foldSub: a whole-span replace emits verbatim, no synthetic edge point. see docs/generators.md § Multiplicity
local function foldWhole(covering, span, base, grid)
  local stream, any = base, false
  for _, rec in ipairs(covering) do
    if #rec.curve > 0 then
      any = true
      if rec.mode == 'replace' then
        stream = rec.curve
      else
        stream = curves.sumStreams(stream, { rec.curve, negated(base) }, span, grid)
      end
    end
  end
  if not any and not curves.anyNonZero(base) then return {} end
  return stream
end

-- Boundaries within `span` where the covering set changes: span ends plus every record edge strictly
-- inside. Between consecutive cuts the active set is constant, so foldWhole's fold is exact there.
local function chainCuts(covering, span)
  local seen, cuts = { [span[1]] = true, [span[2]] = true }, { span[1], span[2] }
  for _, rec in ipairs(covering) do
    for _, edge in ipairs({ rec.window[1], rec.window[2] }) do
      if edge > span[1] and edge < span[2] and not seen[edge] then
        seen[edge] = true; util.add(cuts, edge)
      end
    end
  end
  table.sort(cuts)
  return cuts
end

-- Fold the active records over one sub-span [a,b) with a constant active set; half-open unless closing.
-- A curved replace clipped mid-segment re-interpolates from the slice edge (accepted fidelity loss). see docs/generators.md § Multiplicity
local function foldSub(active, a, b, base, closeHere, grid)
  local subBase = curves.slice(base, a, b)
  local stream, streamed, touched = subBase, false, false
  for _, rec in ipairs(active) do
    if #rec.curve > 0 then
      touched = true
      if rec.mode == 'replace' then
        stream, streamed = rec.curve, false
      else
        stream = curves.sumStreams(stream, { rec.curve, negated(subBase) }, { a, b }, grid)
        streamed = true
      end
    end
  end
  if streamed then return stream end                       -- [a,b): a rec's own close rides in as a breakpoint
  if not touched and not curves.anyNonZero(subBase) then return {} end
  local pts = curves.slice(stream, a, b)                     -- raw replace curve or held base: clip to [a,b]
  if not closeHere and #pts > 0 then table.remove(pts) end -- half-open: the edge belongs to the next sub-span
  return pts
end

-- Fold parallel chains covering `span` in storage order: whole-span records take the verbatim fast path,
-- otherwise sub-split at record edges. Folds over the records' extent; `span` selects the emission. see docs/generators.md § Multiplicity
function curves.foldChains(recs, span, base, grid)
  local covering = spans.overlapping(recs, span)
  if #covering == 1 then return covering[1].curve end
  -- A kept range and a full re-derive of the same material must agree point for point, which they only
  -- do once the dirt cannot decide where segments fall. see docs/generators.md § Multiplicity
  local lo, hi = span[1], span[2]
  for _, rec in ipairs(covering) do
    lo = math.min(lo, rec.window[1]); hi = math.max(hi, rec.window[2])
  end
  local extent = { lo, hi }
  local cuts   = chainCuts(covering, extent)
  local out
  if #cuts == 2 then
    out = foldWhole(covering, extent, base, grid)
  else
    out = {}
    for i = 1, #cuts - 1 do
      local a, b = cuts[i], cuts[i + 1]
      local active = {}
      for _, rec in ipairs(covering) do
        if rec.window[1] <= a and rec.window[2] >= b then util.add(active, rec) end
      end
      local closeHere = i == #cuts - 1   -- every window closes: only the last sub-span keeps its edge
      for _, point in ipairs(foldSub(active, a, b, base, closeHere, grid)) do util.add(out, point) end
    end
  end
  if lo == span[1] and hi == span[2] then return out end
  local emitted = {}
  for _, point in ipairs(out) do
    local inSpan = point.ppq >= span[1] and point.ppq < span[2]
    if inSpan then util.add(emitted, point) end
  end
  return emitted
end

return curves
