-- See docs/timing.md for the model.
-- @noindex

--invariant: pure module — no module-level state; all functions take operands explicitly
--invariant: two frames: ppqL (logical) and raw ppq (realisation); forward only — ppq = fromLogical(ppqL) + delayToPPQ(delay), endppq = fromLogical(endppqL); see docs/timing.md
--invariant: atoms are pure (u, shift) functions on the unit interval; inverse via Newton (closed form for id)
--invariant: tile period unit is QN (quarter notes); period may be scalar or {num,den}
--invariant: factor order is inner-to-outer: applyFactors walks forward, unapplyFactors walks backward
--invariant: K is the max stretch factor; bounded atoms have posRange/negRange = max |s| (per sign) keeping slope ∈ [1/K, K]
--shape: Atom = { forward = fn(u, shift) -> v, inverse = fn(v, shift) -> u }
--shape: Factor = { atom = string, shift = number_qn, period = number|{num,den}, phase? = number_qn|{num,den} }
--shape: Composite = { phase? = number_qn|{num,den}, factors = Factor[] }   -- bare {} or {factors={}} both denote identity
--shape: ResolvedFactor = { atom = string, shift = number_unit, T = number_ppq, phase? = number_ppq }
--shape: Shape = { factors, a, b, ya, yb, length, identity? }   -- linear ramps on [0,a] and [b,length]; analytic middle on (a,b)
--shape: AtomMeta = { posRange = number, negRange = number, pulsesPerCycle = 1|2 }
local util = require 'util'

local M = {}

-- Project-level max stretch factor: every bounded atom and the composite-
-- boundary ramp pin slope ∈ [1/K, K]. K=60 is well above any realistic
-- note-density-driven injectivity demand on integer PPQ.
M.K = 60

----- Atoms

-- Each atom is a pair of pure unit-interval functions: forward(u, shift)
-- and inverse(v, shift). The smooth family shares the form
-- f(u, s) = u + s·g(u); its inverse is Newton iteration on the residual.
-- Slope bounded in [1/K, K] gives quadratic convergence to machine
-- precision in 3–6 iterations. id is closed-form linear; shuffle's
-- two-harmonic combination has analytic derivative so Newton applies
-- uniformly — no PWL inverse, no special case.

local PI        = math.pi
local TAU       = 2 * PI
local SHUFFLE_K = 2 / (3 * math.sqrt(3))   -- pins |g| = 1 at the extrema
local TOL       = 1e-12
local MAX_ITER  = 20

-- Bracket-augmented Newton on smooth f mapping [0,1] → [0,1]: maintain
-- [lo, hi] bracketing the root by sign of the residual; fall back to
-- bisection whenever a Newton step leaves the bracket. Pure Newton
-- overshoots near slope-min regions (slope → 1/K at the K-bound limit);
-- bracketing forces global convergence while preserving the quadratic
-- end-game once Newton stops escaping.
local function newton(fwd, dfwd, v, s)
  local lo, hi = 0, 1
  local u = v
  for _ = 1, MAX_ITER do
    local r = fwd(u, s) - v
    if r > -TOL and r < TOL then return u end
    if r > 0 then hi = u else lo = u end
    local nu = u - r / dfwd(u, s)
    if nu <= lo or nu >= hi then nu = 0.5 * (lo + hi) end
    u = nu
  end
  return u
end

-- Build a smooth atom from g(u) and g'(u). f(u, s) = u + s·g(u).
local function smooth(g, gp)
  local function fwd(u, s)  return u + s * g(u) end
  local function dfwd(u, s) return 1 + s * gp(u) end
  return {
    forward = fwd,
    inverse = function(v, s) return newton(fwd, dfwd, v, s) end,
  }
end

M.atoms = {
  -- identity-with-shift: f(u, s) = u + s. Slope is 1; endpoints NOT
  -- pinned to [0, 1]. On a tile of period T this gives p → p + T·s, the
  -- substrate for delay. The boundary ramp absorbs the resulting overhang
  -- at the take edges.
  id = {
    forward = function(u, s) return u + s end,
    inverse = function(v, s) return v - s end,
  },

  -- y = u + s·sin(πu); peak +s at u=0.5; slope 1 ± sπ at endpoints. The
  -- reference shape against which the smooth atoms are calibrated.
  classic = smooth(
    function(u) return     math.sin(PI * u) end,
    function(u) return PI * math.cos(PI * u) end),

  -- pocket: smooth flat-top bump. y = u + s·(1 − (2u−1)^6). Peak +s at
  -- u=0.5 with a near-plateau through the central region — events sit
  -- consistently behind the beat across a wide central band.
  pocket = smooth(
    function(u) local d = 2*u - 1; return 1 - d^6 end,
    function(u) local d = 2*u - 1; return    -12 * d^5 end),

  -- lilt: smooth alternating sin. y = u + s·sin(2πu). Peak +s at u=0.25,
  -- trough −s at u=0.75. pulsesPerCycle = 2.
  lilt = smooth(
    function(u) return     math.sin(TAU * u) end,
    function(u) return TAU * math.cos(TAU * u) end),

  -- shuffle: two-harmonic triplet swing, anti-symmetric about u=0.5.
  -- Trough −s at u=1/3, peak +s at u=2/3. SHUFFLE_K pins |extrema| = 1.
  shuffle = smooth(
    function(u) return SHUFFLE_K * (-2*math.sin(TAU*u) + math.sin(2*TAU*u)) end,
    function(u) return SHUFFLE_K * 2*TAU * (math.cos(2*TAU*u) - math.cos(TAU*u)) end),

  -- tilt: smooth asymmetric forward bump. y = u + s·(27/4)·u·(1−u)².
  -- Peak +s at u=1/3 — events near the front get pushed back hardest;
  -- the back two-thirds settle smoothly.
  tilt = smooth(
    function(u) return (27/4) *      u * (1 - u)^2 end,
    function(u) return (27/4) * (1 - u) * (1 - 3*u) end),
}

-- Ranges derive from K: each atom's `shift` is bounded so its slope stays
-- in [1/K, K] over [0, 1]. The constraint slope ∈ [1/K, K] yields
-- s·g'(u) ∈ [−(K−1)/K, K−1] — asymmetric whenever max(g') ≠ |min(g')|.
-- Per sign, the binding side is the slope-min one (1/K), via the opposite
-- extremum of g':
--   s > 0: s·|min(g')| ≤ (K−1)/K   ⟹  posRange = (K−1) / (K · |min(g')|)
--   s < 0: s·max(g')   ≤ (K−1)/K   ⟹  negRange = (K−1) / (K · max(g'))
-- Per-atom derivations:
--   classic  g'=π·cos(πu);            max=π,    min=−π    ⟹ symmetric
--   pocket   g'=−12(2u−1)^5;          max=12,   min=−12   ⟹ symmetric
--   lilt     g'=2π·cos(2πu);          max=2π,   min=−2π   ⟹ symmetric
--   shuffle  g'=(8π/3√3)·[cos(4πu)−cos(2πu)]; max=2·c at u=1/2,
--            min=−9c/8 at cos(2πu)=1/4, where c=8π/(3√3) ⟹ asymmetric (16:9)
--   tilt     g'=(27/4)(1−u)(1−3u);    max=27/4 at u=0,
--            min=−9/4 at u=2/3                            ⟹ asymmetric (3:1)
local K = M.K
M.atomMeta = {
  -- id range = ∞: slope is 1 regardless of shift. The boundary ramp is
  -- what keeps the take's overall slope in bound.
  id      = { posRange = math.huge,                                  negRange = math.huge,                                  pulsesPerCycle = 1 },
  classic = { posRange = (K - 1) / (math.pi * K),                    negRange = (K - 1) / (math.pi * K),                    pulsesPerCycle = 1 },
  pocket  = { posRange = (K - 1) / (12 * K),                         negRange = (K - 1) / (12 * K),                         pulsesPerCycle = 2 },
  lilt    = { posRange = (K - 1) / (2 * math.pi * K),                negRange = (K - 1) / (2 * math.pi * K),                pulsesPerCycle = 2 },
  shuffle = { posRange = math.sqrt(3) * (K - 1) / (3 * math.pi * K), negRange = 9 * (K - 1) / (16 * math.pi * math.sqrt(3) * K), pulsesPerCycle = 1 },
  tilt    = { posRange = 4 * (K - 1) / (9 * K),                      negRange = 4 * (K - 1) / (27 * K),                     pulsesPerCycle = 1 },
}

--contract: returns QN, not PPQ; multiply by resolution at the swing-resolution boundary
function M.atomTilePeriod(factor)
  return M.periodQN(factor.period) * M.atomMeta[factor.atom].pulsesPerCycle
end

----- Composite registry

M.presets = {
  ['id']         = {},
  ['classic-55'] = { factors = { { atom = 'classic', shift = 0.05, period = 1 } } },
  ['classic-58'] = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } },
  ['classic-62'] = { factors = { { atom = 'classic', shift = 0.12, period = 1 } } },
  ['classic-67'] = { factors = { { atom = 'classic', shift = 0.17, period = 1 } } },
  -- Identity-shift = pure delay. shift × period_QN × ppqPerQN = PPQ offset
  -- on the tile-interior; the boundary ramp absorbs the partial-tile
  -- overhang at the take edges.
  ['delay+15']   = { factors = { { atom = 'id', shift =  1/16, period = 1 } } },
  ['delay+30']   = { factors = { { atom = 'id', shift =  1/8,  period = 1 } } },
  ['delay-15']   = { factors = { { atom = 'id', shift = -1/16, period = 1 } } },
  ['delay-30']   = { factors = { { atom = 'id', shift = -1/8,  period = 1 } } },
}

--contract: sole resolution path; tm/vm never read presets. nil result means identity to callers
function M.findShape(name, userLib)
  if not name or not userLib then return nil end
  return userLib[name]
end

--contract: bare {} treated as identity; either missing factors or empty factors with zero phase counts
function M.isIdentity(composite)
  if not composite then return true end
  local fs = composite.factors
  return (composite.phase or 0) == 0 and (not fs or #fs == 0)
end

----- Period helpers

-- Bad shape is a caller bug; fail loudly rather than guessing.
function M.periodQN(period)
  local t = type(period)
  if t == 'number' then return period end
  if t == 'table'  then return period[1] / period[2] end
  error('timing: bad period ' .. tostring(period))
end

-- Uses internal tile periods (period × pulsesPerCycle), so the result is
-- the realised repeat rate, not the user-period.
function M.compositePeriodQN(composite)
  local fs = composite and composite.factors
  if not fs or #fs == 0 then return 1 end
  local nL, dG
  for _, f in ipairs(fs) do
    local p     = f.period
    local mult  = M.atomMeta[f.atom].pulsesPerCycle
    local n     = ((type(p) == 'table') and p[1] or p) * mult
    local d     = (type(p) == 'table') and p[2] or 1
    nL = nL and util.lcm(nL, n) or n
    dG = dG and util.gcd(dG, d) or d
  end
  return nL / dG
end

----- Factor resolution

--contract: Composite + ppqPerQN -> ResolvedFactor[]; folds composite.phase into each factor's effective phase. Sole pre-flight for applyFactors / unapplyFactors and resolveComposite.
function M.resolveFactors(composite, ppqPerQN)
  if not composite or not composite.factors then return {} end
  local cPhaseQN = composite.phase and M.periodQN(composite.phase) or 0
  local out = {}
  for i, f in ipairs(composite.factors) do
    if not M.atoms[f.atom] then error('timing: unknown atom ' .. tostring(f.atom)) end
    local tileQN  = M.atomTilePeriod(f)
    local phaseQN = (f.phase and M.periodQN(f.phase) or 0) + cPhaseQN
    out[i] = {
      atom  = f.atom,
      shift = f.shift / tileQN,
      T     = ppqPerQN * tileQN,
      phase = phaseQN ~= 0 and ppqPerQN * phaseQN or nil,
    }
  end
  return out
end

----- Tile bookkeeping

-- f(u, s) lifted to a tile of period T with optional phase.
local function tileApply(rf, p)
  if rf.T <= 0 then return p end
  local q = rf.phase and (p - rf.phase) or p
  local t = q / rf.T
  local n = math.floor(t)
  local y = rf.T * (n + M.atoms[rf.atom].forward(t - n, rf.shift))
  return rf.phase and (y + rf.phase) or y
end

local function tileUnapply(rf, p)
  if rf.T <= 0 then return p end
  local q = rf.phase and (p - rf.phase) or p
  local t = q / rf.T
  local n = math.floor(t)
  local y = rf.T * (n + M.atoms[rf.atom].inverse(t - n, rf.shift))
  return rf.phase and (y + rf.phase) or y
end

--contract: ppqL -> ppqI; identity-safe on empty factors
function M.applyFactors(factors, ppq)
  for _, rf in ipairs(factors) do ppq = tileApply(rf, ppq) end
  return ppq
end

--contract: ppqI -> ppqL; reverses factor order to invert composition
function M.unapplyFactors(factors, ppq)
  for i = #factors, 1, -1 do ppq = tileUnapply(factors[i], ppq) end
  return ppq
end

----- Composite resolution

-- The Shape covers [0, length] as three regions:
--   linear ramp-on  on [0, a]:        f(x) = x · ya / a
--   analytic middle on (a, b):        f(x) = applyFactors(factors, x)
--   linear ramp-off on [b, length]:   f(x) = yb + (x − b) · (length − yb) / (length − b)
-- Continuity at the seams is automatic: middle at a is applyFactors(a) =
-- ya by construction; same at b. Endpoints pin trivially.
-- Ramp slopes are bounded in [1/K, K] by the walk: extend in by `step =
-- ppqPerQN/60` until the secant from the anchor (origin or right-end)
-- lands in bound.

local function findRampOn(factors, length, step)
  local lo, hi = 1 / M.K, M.K
  local kMax = math.max(1, math.floor(length / step))
  for k = 1, kMax do
    local x = k * step
    local y = M.applyFactors(factors, x)
    local g = y / x
    if g >= lo and g <= hi then return x, y end
  end
  return length, M.applyFactors(factors, length)
end

local function findRampOff(factors, length, step)
  local lo, hi = 1 / M.K, M.K
  local kMax = math.max(1, math.floor(length / step))
  for k = 1, kMax do
    local x = length - k * step
    local y = M.applyFactors(factors, x)
    local g = (length - y) / (length - x)
    if g >= lo and g <= hi then return x, y end
  end
  return 0, M.applyFactors(factors, 0)
end

local function identityShape(length)
  return { factors = {}, a = 0, b = length, ya = 0, yb = length, length = length, identity = true }
end

--contract: identity composite or length≤0 returns an identity-Shape sentinel; otherwise returns Shape{factors, a, b, ya, yb, length}. Consumers eval/invert across both forms.
function M.resolveComposite(composite, length, ppqPerQN)
  if M.isIdentity(composite) or length <= 0 then return identityShape(length) end
  local factors = M.resolveFactors(composite, ppqPerQN)
  local step    = ppqPerQN / 60
  local a, ya   = findRampOn(factors, length, step)
  local b, yb   = findRampOff(factors, length, step)
  -- a ≥ b: ramps overlap. Possible only with extreme tilt + id-shift +
  -- phase combinations; structurally pathological. Fall back so the
  -- slider drag never explodes.
  if a >= b then return identityShape(length) end
  return { factors = factors, a = a, b = b, ya = ya, yb = yb, length = length }
end

--contract: eval routes by x: ramp-on for x≤a, applyFactors for a<x<b, ramp-off for x≥b
function M.eval(S, x)
  if S.identity then return x end
  if x <= S.a then
    return S.a > 0 and (x * S.ya / S.a) or 0
  elseif x >= S.b then
    local L = S.length
    return L > S.b and (S.yb + (x - S.b) * (L - S.yb) / (L - S.b)) or L
  end
  return M.applyFactors(S.factors, x)
end

--contract: invert routes by y: ramp-on inverse for y≤ya, unapplyFactors for ya<y<yb, ramp-off inverse for y≥yb
function M.invert(S, y)
  if S.identity then return y end
  if y <= S.ya then
    return S.ya > 0 and (y * S.a / S.ya) or 0
  elseif y >= S.yb then
    local L = S.length
    return L > S.yb and (S.b + (y - S.yb) * (L - S.b) / (L - S.yb)) or L
  end
  return M.unapplyFactors(S.factors, y)
end

----- Logical grid

--contract: callers must store result as float; vm relies on unrounded rowPPQs for swing-inversion exactness
function M.logPerRow(rpb, denom, resolution)
  return resolution * 4 / (denom * rpb)
end

----- Delay <-> PPQ

--contract: d in signed milli-QN, res in PPQ/QN; nil d treated as 0
function M.delayToPPQ(d, res)
  return util.round(res * (d or 0) / 1000)
end

function M.ppqToDelay(p, res)
  return 1000 * p / res
end

return M
