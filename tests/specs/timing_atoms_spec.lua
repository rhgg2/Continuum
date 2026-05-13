-- Atoms are pure unit-interval functions {forward, inverse}. forward
-- pins endpoints (id excepted), is monotone on [0,1] for in-range
-- shift, and inverse closes the round-trip to machine precision via
-- Newton iteration. resolveFactors lifts atoms to a tiled
-- ResolvedFactor[]; applyFactors / unapplyFactors consume it.

local t = require('support')
local util   = require('util')
local timing = require('timing')

local SMOOTH = { 'classic', 'pocket', 'lilt', 'shuffle', 'tilt' }

-- Where the atom's principal sits, in QN. For PPC=1 atoms this is the
-- principal feature within pulse 1; for PPC=2 atoms it sits at unit-x=0.5
-- of the tile.
local principalQN = {
  classic = function(P) return 0.5 * P end,
  pocket  = function(P) return P end,
  lilt    = function(P) return 0.5 * P end,
  shuffle = function(P) return (2/3) * P end,
  tilt    = function(P) return (1/3) * P end,
}

return {
  ---------- atomTilePeriod

  {
    name = 'atomTilePeriod doubles for lilt and pocket, passes through for the rest',
    run = function()
      t.eq(timing.atomTilePeriod{ atom = 'classic', shift = 0, period = 1 }, 1)
      t.eq(timing.atomTilePeriod{ atom = 'shuffle', shift = 0, period = 1 }, 1)
      t.eq(timing.atomTilePeriod{ atom = 'tilt',    shift = 0, period = 1 }, 1)
      t.eq(timing.atomTilePeriod{ atom = 'lilt',    shift = 0, period = 1 }, 2)
      t.eq(timing.atomTilePeriod{ atom = 'lilt',    shift = 0, period = 3 }, 6)
      t.eq(timing.atomTilePeriod{ atom = 'pocket',  shift = 0, period = 1 }, 2)
      t.eq(timing.atomTilePeriod{ atom = 'pocket',  shift = 0, period = 3 }, 6)
    end,
  },

  ---------- forward / inverse contract

  {
    name = 'forward(u, 0) = u for every atom (zero-shift identity)',
    run = function()
      for _, name in ipairs{ 'id', 'classic', 'pocket', 'lilt', 'shuffle', 'tilt' } do
        local atom = timing.atoms[name]
        for _, u in ipairs{ 0, 0.13, 0.5, 0.97, 1 } do
          t.truthy(math.abs(atom.forward(u, 0) - u) < 1e-12,
            name .. ' forward(' .. u .. ', 0) ≠ ' .. u)
        end
      end
    end,
  },

  {
    name = 'smooth atoms pin endpoints: forward(0, s) = 0 and forward(1, s) = 1',
    run = function()
      for _, name in ipairs(SMOOTH) do
        local atom = timing.atoms[name]
        local meta = timing.atomMeta[name]
        for _, s in ipairs{ 0.95 * meta.posRange, -0.95 * meta.negRange } do
          t.truthy(math.abs(atom.forward(0, s)) < 1e-12,
            name .. ' forward(0, ' .. s .. ') ≠ 0')
          t.truthy(math.abs(atom.forward(1, s) - 1) < 1e-12,
            name .. ' forward(1, ' .. s .. ') ≠ 1')
        end
      end
    end,
  },

  {
    name = 'id forward shifts; inverse undoes it',
    run = function()
      local atom = timing.atoms.id
      for _, s in ipairs{ -0.2, 0, 0.07, 0.5 } do
        for _, u in ipairs{ -0.3, 0, 0.5, 1, 1.4 } do
          t.truthy(math.abs(atom.forward(u, s) - (u + s)) < 1e-12,
            'id.forward(' .. u .. ', ' .. s .. ')')
          t.truthy(math.abs(atom.inverse(u + s, s) - u) < 1e-12,
            'id.inverse round-trip at u=' .. u .. ' s=' .. s)
        end
      end
    end,
  },

  {
    name = 'smooth inverses close the round-trip to machine precision',
    -- Newton on f(u, s) = u + s·g(u) seeded at u₀=v; bracket-augmented
    -- to handle the slope-min regions where pure Newton overshoots.
    -- 1e-9 leaves ample margin against MAX_ITER=20.
    run = function()
      for _, name in ipairs(SMOOTH) do
        local atom = timing.atoms[name]
        local meta = timing.atomMeta[name]
        for _, s in ipairs{ 0.95 * meta.posRange, -0.95 * meta.negRange } do
          for _, u in ipairs{ 0, 0.07, 0.21, 0.33, 0.5, 0.67, 0.79, 0.93, 1 } do
            local v     = atom.forward(u, s)
            local round = atom.inverse(v, s)
            t.truthy(math.abs(round - u) < 1e-9,
              name .. ' s=' .. s .. ' u=' .. u ..
              ': round-trip ' .. tostring(round))
          end
        end
      end
    end,
  },

  {
    name = 'forward is strictly monotone on [0, 1] for in-range shift',
    -- Sample at 200 points and check finite-difference. Slope is
    -- bounded by atom range; at 0.95·range the bound is ≈ 1/(K·1.05) > 0.
    run = function()
      local N = 200
      for _, name in ipairs(SMOOTH) do
        local atom = timing.atoms[name]
        local meta = timing.atomMeta[name]
        for _, s in ipairs{ 0.95 * meta.posRange, -0.95 * meta.negRange } do
          local prev = atom.forward(0, s)
          for i = 1, N do
            local cur = atom.forward(i / N, s)
            t.truthy(cur > prev,
              name .. ' s=' .. s .. ' non-monotone at i=' .. i ..
              ': ' .. prev .. ' → ' .. cur)
            prev = cur
          end
        end
      end
    end,
  },

  {
    name = 'analytic slope stays within [1/K, K] at max in-range shift',
    -- Finite-difference at a fine grid agrees with the analytic derivative
    -- to O(h²); with h=1/400 the gap is < 1e-6, well below the K-bound
    -- tolerance. Each sign uses its own range — asymmetric for shuffle/tilt.
    run = function()
      local K  = timing.K
      local lo = 1 / K
      local hi = K
      local N  = 400
      local h  = 1 / N
      for _, name in ipairs(SMOOTH) do
        local atom = timing.atoms[name]
        local meta = timing.atomMeta[name]
        for _, s in ipairs{ meta.posRange, -meta.negRange } do
          for i = 0, N - 1 do
            local u  = i / N
            local g  = (atom.forward(u + h, s) - atom.forward(u, s)) / h
            t.truthy(g >= lo - 1e-6 and g <= hi + 1e-6,
              name .. ' s=' .. s .. ' u=' .. u ..
              ': slope ' .. tostring(g) .. ' outside K bound')
          end
        end
      end
    end,
  },

  ---------- resolveFactors / applyFactors integration

  {
    name = 'principal lands at nominal + shift, atom-independent',
    run = function()
      for _, atom in ipairs{ 'classic', 'pocket', 'lilt', 'shuffle', 'tilt' } do
        for _, P in ipairs{ 1, 2, 4 } do
          for _, shift in ipairs{ 0.05, 0.10 } do
            local factors = timing.resolveFactors(
              { factors = { { atom = atom, shift = shift, period = P } } }, 1)
            local nominal = principalQN[atom](P)
            local got     = timing.applyFactors(factors, nominal)
            local want    = nominal + shift
            t.truthy(math.abs(got - want) < 1e-9,
              atom .. ' P=' .. P .. ' shift=' .. shift ..
              ': principal landed at ' .. tostring(got) .. ', want ' .. tostring(want))
          end
        end
      end
    end,
  },

  {
    name = 'shift is period-decoupled: same shift, different periods, both land shift away',
    run = function()
      local f1 = timing.resolveFactors(
        { factors = { { atom = 'classic', shift = 0.1, period = 1 } } }, 1)
      local f4 = timing.resolveFactors(
        { factors = { { atom = 'classic', shift = 0.1, period = 4 } } }, 1)
      t.truthy(math.abs(timing.applyFactors(f1, 0.5) - 0.6) < 1e-9, 'P=1')
      t.truthy(math.abs(timing.applyFactors(f4, 2.0) - 2.1) < 1e-9, 'P=4')
    end,
  },

  {
    name = 'classic-58 preset matches the legacy 0.58 mapping',
    run = function()
      local factors = timing.resolveFactors(timing.presets['classic-58'], 1)
      t.truthy(math.abs(timing.applyFactors(factors, 0.5) - 0.58) < 1e-9)
    end,
  },

  {
    name = 'identity atom shift = 0: pass-through',
    run = function()
      local factors = timing.resolveFactors(
        { factors = { { atom = 'id', shift = 0, period = 1 } } }, 1)
      for _, p in ipairs{ 0, 0.25, 0.5, 0.99, 1.0, 1.25 } do
        t.truthy(math.abs(timing.applyFactors(factors, p) - p) < 1e-9)
      end
    end,
  },

  {
    name = 'identity atom shift ≠ 0: constant output translation, period-scaled',
    -- The substrate for delay. apply gives p → p + ppqPerQN·shift everywhere,
    -- regardless of period (id slope is 1).
    run = function()
      for _, period in ipairs{ 1, 2, 4 } do
        for _, shift in ipairs{ 0.05, -0.03 } do
          local factors = timing.resolveFactors(
            { factors = { { atom = 'id', shift = shift, period = period } } }, 240)
          local want = 240 * shift
          for _, p in ipairs{ 0, 60, 120, 240, 481, 1000 } do
            local got = timing.applyFactors(factors, p)
            t.truthy(math.abs(got - (p + want)) < 1e-9,
              'period=' .. period .. ' shift=' .. shift ..
              ' p=' .. p .. ': got ' .. tostring(got) ..
              ', want ' .. tostring(p + want))
          end
        end
      end
    end,
  },

  {
    name = 'identity atom shift ≠ 0: apply/unapply round-trip',
    run = function()
      local factors = timing.resolveFactors(
        { factors = { { atom = 'id', shift = 0.07, period = 1 } } }, 240)
      for _, p in ipairs{ 0, 13, 60, 121, 240, 481, 1000 } do
        local round = timing.unapplyFactors(factors, timing.applyFactors(factors, p))
        t.truthy(math.abs(round - p) < 1e-9,
          'round-trip at p=' .. p .. ' gave ' .. tostring(round))
      end
    end,
  },

  ---------- per-factor phase

  {
    name = 'per-factor phase: shifts the fixed-point lattice from {kT} to {phase + kT}',
    run = function()
      local factors = timing.resolveFactors(
        { factors = { { atom = 'classic', shift = 0.08, period = 1, phase = 0.25 } } }, 240)
      for _, p in ipairs{ 60, 300, 540 } do
        local got = timing.applyFactors(factors, p)
        t.truthy(math.abs(got - p) < 1e-9,
          'fixed point at p=' .. p .. ' gave ' .. tostring(got))
      end
      local mid = timing.applyFactors(factors, 180)
      t.truthy(math.abs(mid - 180) > 1, 'non-fixed point should move, got ' .. mid)
    end,
  },

  {
    name = 'per-factor phase: apply/unapply round-trip',
    run = function()
      local factors = timing.resolveFactors(
        { factors = { { atom = 'classic', shift = 0.08, period = 1, phase = 0.3 } } }, 240)
      for _, p in ipairs{ 0, 30, 72, 119, 240, 361, 480, 961 } do
        local round = timing.unapplyFactors(factors, timing.applyFactors(factors, p))
        t.truthy(math.abs(round - p) < 1e-9,
          'round-trip at p=' .. p .. ' gave ' .. tostring(round))
      end
    end,
  },

  {
    name = 'per-factor phase: phase = nil and phase = 0 are equivalent',
    run = function()
      local fNil = timing.resolveFactors(
        { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }, 240)
      local fZer = timing.resolveFactors(
        { factors = { { atom = 'classic', shift = 0.08, period = 1, phase = 0 } } }, 240)
      for _, p in ipairs{ 0, 30, 60, 119, 120, 240, 361, 480 } do
        local a = timing.applyFactors(fNil, p)
        local b = timing.applyFactors(fZer, p)
        t.truthy(math.abs(a - b) < 1e-9,
          'p=' .. p .. ': nil=' .. tostring(a) .. ' zero=' .. tostring(b))
      end
    end,
  },

  ---------- K-bound and ranges

  {
    name = 'K constant is exposed and atom ranges are derived from it',
    -- shuffle and tilt are asymmetric: g' has unequal max and |min|, so
    -- each sign hits the slope-min wall at a different |s|.
    run = function()
      local K = timing.K
      t.truthy(K and K > 1, 'timing.K should be a finite > 1, got ' .. tostring(K))
      local cases = {
        { name = 'classic', pos = (K - 1) / (math.pi * K),
                            neg = (K - 1) / (math.pi * K) },
        { name = 'pocket',  pos = (K - 1) / (12 * K),
                            neg = (K - 1) / (12 * K) },
        { name = 'lilt',    pos = (K - 1) / (2 * math.pi * K),
                            neg = (K - 1) / (2 * math.pi * K) },
        { name = 'shuffle', pos = math.sqrt(3) * (K - 1) / (3 * math.pi * K),
                            neg = 9 * (K - 1) / (16 * math.pi * math.sqrt(3) * K) },
        { name = 'tilt',    pos = 4 * (K - 1) / (9 * K),
                            neg = 4 * (K - 1) / (27 * K) },
      }
      for _, c in ipairs(cases) do
        local m = timing.atomMeta[c.name]
        t.truthy(math.abs(m.posRange - c.pos) < 1e-12,
          c.name .. ' posRange ' .. m.posRange .. ' ≠ ' .. c.pos)
        t.truthy(math.abs(m.negRange - c.neg) < 1e-12,
          c.name .. ' negRange ' .. m.negRange .. ' ≠ ' .. c.neg)
      end
    end,
  },

  {
    name = 'existing presets stay within their K-bounded atom ranges',
    run = function()
      for name, comp in pairs(timing.presets) do
        for _, f in ipairs((comp or {}).factors or {}) do
          local tilePeriod = timing.atomTilePeriod(f)
          local a          = f.shift / tilePeriod
          local m          = timing.atomMeta[f.atom]
          t.truthy(a >= -m.negRange - 1e-12 and a <= m.posRange + 1e-12,
            'preset ' .. name .. ' atom ' .. f.atom ..
            ' a=' .. tostring(a) ..
            ' outside [-' .. tostring(m.negRange) .. ', ' .. tostring(m.posRange) .. ']')
        end
      end
    end,
  },

  ---------- logPerRow

  {
    name = 'logPerRow handles non-divisor rpbs (returns float, no truncation)',
    run = function()
      local v = timing.logPerRow(7, 4, 240)
      t.truthy(math.abs(v - 240/7) < 1e-12, 'rpb=7: ' .. tostring(v))
    end,
  },
}
