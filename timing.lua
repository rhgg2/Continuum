-- See docs/timing.md for the model.
-- @noindex

--@map:invariant pure module — no module-level state; all functions take operands explicitly
--@map:invariant frames stack: ppqL --[swing]--> ppqI --[+delayToPPQ]--> ppqR
--@map:invariant swing shapes are PWL homeomorphisms of [0,1] fixing endpoints, strictly monotone
--@map:invariant tile period unit is QN (quarter notes); period may be scalar or {num,den}
--@map:invariant factor order is inner-to-outer: applyFactors walks forward, unapplyFactors walks backward
--@map:shape Shape = { {0,0}, {x1,y1}, ..., {1,1} }  -- sorted, strictly increasing x and y
--@map:shape Factor = { atom = string, shift = number_qn, period = number|{num,den} }  -- user-facing composite entry
--@map:shape ResolvedFactor = { S = Shape, T = number_ppq }  -- consumed by applyFactors/unapplyFactors
--@map:shape AtomMeta = { range = number, pulsesPerCycle = 1|2 }  -- range = max |a| keeping shape monotonic

timing = {}
local M = timing

local EPS = 1e-12

----- Atoms

-- 240 = 12·20: principal-pulse breakpoints (1/4, 1/3, 1/2, 2/3, 3/4) land on exact sample points.
local SAMPLES = 240

local function sampled(f)
  local pts = { {0, 0} }
  for i = 1, SAMPLES - 1 do
    local x = i / SAMPLES
    pts[#pts + 1] = { x, f(x) }
  end
  pts[#pts + 1] = { 1, 1 }
  return pts
end

M.atoms = {
  id = function()
    return { {0, 0}, {1, 1} }
  end,

  -- classic: PWL tent, single sharp kink at x=0.5. The reference shape
  -- against which the smooth atoms are calibrated.
  -- classic = function(a)
  --   if not a or a == 0 then return { {0, 0}, {1, 1} } end
  --   return { {0, 0}, {0.5, 0.5 + a}, {1, 1} }
  -- end,

  -- y = x + a·sin(πx); peak +a at x=0.5; slope 1 ± aπ at endpoints. Smooth analogue of the PWL classic.
  classic = function(a)
    if not a or a == 0 then return { {0, 0}, {1, 1} } end
    return sampled(function(x) return x + a * math.sin(math.pi * x) end)
  end,

  -- pocket: smooth flat-top bump. y = x + a·(1 − (2x−1)^6). Peak +a at
  -- x=0.5 with a near-plateau through the central region — the entire
  -- middle is shifted by ≈+a, the corners ramp smoothly to the
  -- endpoints. The "in the pocket" feel: events sit consistently behind
  -- the beat across a wide central band.
  pocket = function(a)
    if not a or a == 0 then return { {0, 0}, {1, 1} } end
    return sampled(function(x)
      local d = 2*x - 1
      return x + a * (1 - d^6)
    end)
  end,

  -- lilt: smooth alternating sin. y = x + a·sin(2πx). Peak +a at
  -- x=0.25, trough −a at x=0.75 — alternating push/pull within each
  -- pair of pulses. pulsesPerCycle = 2.
  lilt = function(a)
    if not a or a == 0 then return { {0, 0}, {1, 1} } end
    return sampled(function(x) return x + a * math.sin(2 * math.pi * x) end)
  end,

  -- shuffle: smooth triplet swing, anti-symmetric about x=0.5.
  -- Two-harmonic combination chosen so the extrema land exactly on the
  -- triplet positions: trough −a at x=1/3, peak +a at x=2/3. The
  -- coefficient k = 2/(3√3) sets |σ| = 1 at those extrema.
  shuffle = function(a)
    if not a or a == 0 then return { {0, 0}, {1, 1} } end
    local k = 2 / (3 * math.sqrt(3))
    return sampled(function(x)
      return x + a * k * (-2*math.sin(2*math.pi*x) + math.sin(4*math.pi*x))
    end)
  end,

  -- tilt: smooth asymmetric bump skewed forward. y = x + a·(27/4)·x·(1−x)².
  -- Peak +a at x=1/3 — events near the front of the cycle get pushed
  -- back hardest, the back two-thirds settle smoothly. Unidirectional
  -- triplet feel; complement to shuffle's anti-symmetric pull-then-push.
  tilt = function(a)
    if not a or a == 0 then return { {0, 0}, {1, 1} } end
    return sampled(function(x) return x + a * (27/4) * x * (1-x)^2 end)
  end,
}

M.atomMeta = {
  id      = { range = 0,                           pulsesPerCycle = 1 },
--  classic = { range = 0.5,                         pulsesPerCycle = 1 },
  classic = { range = 1/math.pi,                   pulsesPerCycle = 1 },
  pocket  = { range = 1/12,                        pulsesPerCycle = 2 },
  lilt    = { range = 1/(2*math.pi),               pulsesPerCycle = 2 },
  shuffle = { range = 9/(16*math.pi*math.sqrt(3)), pulsesPerCycle = 1 },
  tilt    = { range = 4/27,                        pulsesPerCycle = 1 },
}

--@map:contract returns QN, not PPQ; multiply by resolution at the swing-resolution boundary
function M.atomTilePeriod(factor)
  return M.periodQN(factor.period) * M.atomMeta[factor.atom].pulsesPerCycle
end

----- Composite registry

M.presets = {
  ['id']         = {},
  ['classic-55'] = { {atom = 'classic', shift = 0.05, period = 1} },
  ['classic-58'] = { {atom = 'classic', shift = 0.08, period = 1} },
  ['classic-62'] = { {atom = 'classic', shift = 0.12, period = 1} },
  ['classic-67'] = { {atom = 'classic', shift = 0.17, period = 1} },
}

--@map:contract sole resolution path; tm/vm never read presets. nil result means identity to callers
function M.findShape(name, userLib)
  if not name or not userLib then return nil end
  return userLib[name]
end

function M.isIdentity(composite)
  return not composite or #composite == 0
end

----- Period helpers

-- Bad shape is a caller bug; fail loudly rather than guessing.
function M.periodQN(period)
  local t = type(period)
  if t == 'number' then return period end
  if t == 'table'  then return period[1] / period[2] end
  error('timing: bad period ' .. tostring(period))
end

-- Uses internal tile periods (period × pulsesPerCycle), so the result is the realised repeat rate, not the user-period.
function M.compositePeriodQN(composite)
  if not composite or #composite == 0 then return 1 end
  local nL, dG
  for _, f in ipairs(composite) do
    local p     = f.period
    local mult  = M.atomMeta[f.atom].pulsesPerCycle
    local n     = ((type(p) == 'table') and p[1] or p) * mult
    local d     = (type(p) == 'table') and p[2] or 1
    nL = nL and util.lcm(nL, n) or n
    dG = dG and util.gcd(dG, d) or d
  end
  return nL / dG
end

----- Evaluation and inversion

local function lerp(x0, y0, x1, y1, x)
  if x1 == x0 then return y0 end
  return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
end

-- axis = 1 for x (eval), 2 for y (invert).
local function findSegment(S, target, axis)
  local n = #S
  if target <= S[1][axis]     then return 1 end
  if target >= S[n][axis]     then return n - 1 end
  local lo, hi = 1, n - 1
  while lo < hi do
    local mid = (lo + hi + 1) // 2
    if S[mid][axis] <= target then lo = mid else hi = mid - 1 end
  end
  return lo
end

--@map:contract O(log n) binary search; assumes endpoints are pinned exactly to {0,0}/{1,1}
function M.eval(S, x)
  local i = findSegment(S, x, 1)
  return lerp(S[i][1], S[i][2], S[i+1][1], S[i+1][2], x)
end

function M.invert(S, y)
  local i = findSegment(S, y, 2)
  return lerp(S[i][2], S[i][1], S[i+1][2], S[i+1][1], y)
end

----- Group operations

-- Swap (x,y) per control point; monotonicity and endpoints preserved,
-- so no re-sort.
function M.inverse(S)
  local inv = {}
  for i = 1, #S do inv[i] = { S[i][2], S[i][1] } end
  return inv
end

-- Breakpoints of S∘T are T's x-points ∪ T⁻¹(S's x-points): both drive
-- slope changes of the composite.
function M.compose(S, T)
  local xs = {}
  for _, p in ipairs(T) do xs[#xs + 1] = p[1] end
  for _, p in ipairs(S) do xs[#xs + 1] = M.invert(T, p[1]) end
  table.sort(xs)

  local pts = {}
  local last
  for _, x in ipairs(xs) do
    if not last or x - last > EPS then
      pts[#pts + 1] = { x, M.eval(S, M.eval(T, x)) }
      last = x
    end
  end
  -- Pin endpoints exactly against accumulated floating-point drift.
  pts[1][1],      pts[1][2]      = 0, 0
  pts[#pts][1],   pts[#pts][2]   = 1, 1
  return pts
end

----- Tiled extension

-- T <= 0 degrades to identity so callers can drive off empty composites.
--@map:contract every multiple of T is a fixed point; T in PPQ, p in PPQ
function M.tile(S, T, p)
  if T <= 0 then return p end
  local t = p / T
  local n = math.floor(t)
  return T * (n + M.eval(S, t - n))
end

function M.tileInverse(S, T, p)
  if T <= 0 then return p end
  local t = p / T
  local n = math.floor(t)
  return T * (n + M.invert(S, t - n))
end

--@map:contract ppqL -> ppqI; identity-safe on empty factors
function M.applyFactors(factors, ppq)
  for _, f in ipairs(factors) do ppq = M.tile(f.S, f.T, ppq) end
  return ppq
end

--@map:contract ppqI -> ppqL; reverses factor order to invert composition
function M.unapplyFactors(factors, ppq)
  for i = #factors, 1, -1 do
    local f = factors[i]
    ppq = M.tileInverse(f.S, f.T, ppq)
  end
  return ppq
end

----- Logical grid

--@map:contract callers must store result as float; vm relies on unrounded rowPPQs for swing-inversion exactness
function M.logPerRow(rpb, denom, resolution)
  return resolution * 4 / (denom * rpb)
end

----- Delay <-> PPQ

--@map:contract d in signed milli-QN, res in PPQ/QN; nil d treated as 0
function M.delayToPPQ(d, res)
  return util.round(res * (d or 0) / 1000)
end

function M.ppqToDelay(p, res)
  return 1000 * p / res
end

return M
