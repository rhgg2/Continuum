-- timing.resolveComposite returns a Shape with linear ramps on
-- [0, a] / [b, length] and an analytic middle on (a, b). Endpoints are
-- pinned; slopes stay in [1/K, K]; round-trip is exact via Newton.
-- Tests assert semantics through eval/invert rather than the Shape's
-- internal layout.

local t = require('support')
local util   = require('util')
local timing = require('timing')

local function evalAt(S, x)  return timing.eval(S, x)   end
local function invAt(S, y)   return timing.invert(S, y) end

-- Test fixtures: literal composites pinned by name. The canonical
-- catalogue now lives in configManager's swings default; these specs
-- exercise the timing math, not the catalogue, so the small literal
-- subset they need lives here.
local FIX = {
  ['classic-58'] = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } },
  ['delay+15']   = { factors = { { atom = 'id', shift =  1/16, period = 1 } } },
  ['delay+30']   = { factors = { { atom = 'id', shift =  1/8,  period = 1 } } },
  ['delay-15']   = { factors = { { atom = 'id', shift = -1/16, period = 1 } } },
  ['delay-30']   = { factors = { { atom = 'id', shift = -1/8,  period = 1 } } },
}

return {
  {
    name = 'identity composite: eval and invert are identity over [0, length]',
    run = function()
      local L = 1000
      local S = timing.resolveComposite({}, L, 240)
      for _, p in ipairs{ 0, 1, 250, 500, 999, L } do
        t.truthy(math.abs(evalAt(S, p) - p) < 1e-9, 'eval ' .. p)
        t.truthy(math.abs(invAt(S, p) - p) < 1e-9, 'invert ' .. p)
      end
    end,
  },

  {
    name = 'length = 0: degenerate Shape evaluates trivially',
    run = function()
      local S = timing.resolveComposite(FIX['classic-58'], 0, 240)
      t.truthy(math.abs(evalAt(S, 0)) < 1e-9, 'eval(0) at L=0')
    end,
  },

  {
    name = 'endpoints are pinned: eval(0)=0, eval(L)=L, and invert agrees',
    run = function()
      local L = 960
      local S = timing.resolveComposite(FIX['classic-58'], L, 240)
      t.truthy(math.abs(evalAt(S, 0))     < 1e-9, 'eval(0) = ' .. evalAt(S, 0))
      t.truthy(math.abs(evalAt(S, L) - L) < 1e-9, 'eval(L) = ' .. evalAt(S, L))
      t.truthy(math.abs(invAt(S, 0))      < 1e-9, 'invert(0) = ' .. invAt(S, 0))
      t.truthy(math.abs(invAt(S, L) - L)  < 1e-9, 'invert(L) = ' .. invAt(S, L))
    end,
  },

  {
    name = 'id-shift (a > 0): interior tile boundaries land at p + T·a',
    -- Period=1QN ⇒ T=240 PPQ. a=0.1 ⇒ shift adds 24 PPQ. Length spans 4
    -- tiles; the three interior tile boundaries (240, 480, 720) sit
    -- comfortably in the analytic middle and carry the full +24 offset.
    run = function()
      local L = 960
      local S = timing.resolveComposite(
        { factors = { { atom = 'id', shift = 0.1, period = 1 } } },
        L, 240)
      for _, p in ipairs{ 240, 480, 720 } do
        local y = evalAt(S, p)
        t.truthy(math.abs(y - (p + 24)) < 1e-9,
          'p=' .. p .. ': got ' .. y .. ', want ' .. (p + 24))
      end
    end,
  },

  {
    name = 'id-shift: mid-tile interior carries the +T·a offset',
    -- 120 sits well inside the analytic middle for a 960 PPQ take. With
    -- T=240 and a=0.1, applyFactors(120) = 144.
    run = function()
      local S = timing.resolveComposite(
        { factors = { { atom = 'id', shift = 0.1, period = 1 } } },
        960, 240)
      t.truthy(math.abs(evalAt(S, 0)) < 1e-9, 'eval(0) pinned')
      local y = evalAt(S, 120)
      t.truthy(math.abs(y - 144) < 1e-9,
        'p=120 mid-tile: got ' .. y .. ', want 144 (= 120 + T·a)')
    end,
  },

  {
    name = 'eval-derived secant slopes stay within [1/K, K] across the take',
    -- Ramps are bounded by construction; the analytic middle's slope is
    -- bounded by atom range × tile-period. Sample at fine resolution and
    -- check finite-difference slopes.
    run = function()
      local K  = timing.K
      local L  = 960
      local cs = {
        FIX['classic-58'],
        { factors = { { atom = 'id',     shift = 0.1, period = 1 } } },
        { factors = { { atom = 'id',     shift = 0.1, period = 1 },
                      { atom = 'classic',shift = 0.08,period = 1 } } },
      }
      local step = 4
      for _, c in ipairs(cs) do
        local S    = timing.resolveComposite(c, L, 240)
        local prev = evalAt(S, 0)
        for x = step, L, step do
          local cur = evalAt(S, x)
          local g   = (cur - prev) / step
          t.truthy(g >= 1/K - 1e-6 and g <= K + 1e-6,
            'slope ' .. g .. ' near x=' .. x .. ' outside K bound')
          prev = cur
        end
      end
    end,
  },

  {
    name = 'eval/invert round-trip is exact across the take',
    run = function()
      local L = 960
      local S = timing.resolveComposite(FIX['classic-58'], L, 240)
      for _, p in ipairs{ 0, 1, 73, 240, 481, 720, 959, L } do
        local round = invAt(S, evalAt(S, p))
        t.truthy(math.abs(round - p) < 1e-9,
          'p=' .. p .. ': round-trip ' .. round)
      end
    end,
  },

  {
    name = 'tile-aligned classic: interior matches un-clipped applyFactors',
    -- length = exactly one tile. classic shift=0.08 maps unit-x=0.5 to 0.58
    -- ⇒ 240·0.58 = 139.2 PPQ at the tile midpoint, which lands in the
    -- analytic middle.
    run = function()
      local S = timing.resolveComposite(FIX['classic-58'], 240, 240)
      local y = evalAt(S, 120)
      t.truthy(math.abs(y - 139.2) < 1e-9, 'midpoint: ' .. y)
    end,
  },

  {
    name = 'delay presets: tile-interior carries shift × T_ppq, sign respected',
    run = function()
      local L = 960
      local cases = {
        { name = 'delay+15', delta =  15 },
        { name = 'delay+30', delta =  30 },
        { name = 'delay-15', delta = -15 },
        { name = 'delay-30', delta = -30 },
      }
      for _, c in ipairs(cases) do
        local S = timing.resolveComposite(FIX[c.name], L, 240)
        t.truthy(math.abs(evalAt(S, 0))     < 1e-9, c.name .. ' eval(0) pinned')
        t.truthy(math.abs(evalAt(S, L) - L) < 1e-9, c.name .. ' eval(L) pinned')
        local p = 480
        local y = evalAt(S, p)
        t.truthy(math.abs(y - (p + c.delta)) < 1e-9,
          c.name .. ' p=' .. p .. ': got ' .. y .. ', want ' .. (p + c.delta))
      end
    end,
  },

  {
    name = 'composite.phase slides every factor lattice additively',
    run = function()
      local L  = 960
      local Sa = timing.resolveComposite(
        { factors = { { atom = 'classic', shift = 0.08, period = 1, phase = 0.10 } } },
        L, 240)
      local Sb = timing.resolveComposite(
        { phase = 0.10,
          factors = { { atom = 'classic', shift = 0.08, period = 1 } } },
        L, 240)
      for _, p in ipairs{ 60, 180, 300, 420, 540, 660, 780, 900 } do
        local ya = evalAt(Sa, p)
        local yb = evalAt(Sb, p)
        t.truthy(math.abs(ya - yb) < 1e-9,
          'p=' .. p .. ': factor-phase ' .. ya .. ' ≠ composite-phase ' .. yb)
      end
      local Sc = timing.resolveComposite(
        { phase = 0.04,
          factors = { { atom = 'classic', shift = 0.08, period = 1, phase = 0.06 } } },
        L, 240)
      for _, p in ipairs{ 120, 360, 600, 840 } do
        t.truthy(math.abs(evalAt(Sc, p) - evalAt(Sa, p)) < 1e-9,
          'additive p=' .. p)
      end
    end,
  },

  {
    name = 'composed factors: id-shift + classic round-trip + endpoints pinned',
    run = function()
      local L = 1920
      local c = { factors = {
        { atom = 'id',      shift = 0.05, period = 4 },
        { atom = 'classic', shift = 0.08, period = 1 },
      } }
      local S = timing.resolveComposite(c, L, 240)
      t.truthy(math.abs(evalAt(S, 0))     < 1e-9, 'eval(0) pinned')
      t.truthy(math.abs(evalAt(S, L) - L) < 1e-9, 'eval(L) pinned')
      for _, p in ipairs{ 0, 137, 480, 961, 1500, L } do
        local round = invAt(S, evalAt(S, p))
        t.truthy(math.abs(round - p) < 1e-9,
          'composite p=' .. p .. ': round-trip ' .. round)
      end
    end,
  },
}
