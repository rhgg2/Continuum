-- Exercises tm's swing transforms via tm:fromLogical / tm:toLogical
-- (the public swing entry points). Contract: missing slots pass through;
-- column is inner and global is outer (see design/swing.md). The
-- eval/invert round-trip itself is timed-level — see timing_composite_spec.

local t = require('support')
local timing = require('timing')

local classic58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }
local classic67 = { factors = { { atom = 'classic', shift = 0.17, period = 1 } } }

return {
  {
    name = 'no slot configured ⇒ fromLogical / toLogical are identity',
    run = function(harness)
      local h = harness.mk()
      for _, p in ipairs{ 0, 60, 120, 240, 480, 961 } do
        t.eq(h.tm:fromLogical(1, p), p, 'fromLogical at ' .. p)
        t.eq(h.tm:toLogical(1, p),   p, 'toLogical at ' .. p)
      end
    end,
  },

  {
    name = 'global classic-58 fixes period boundaries and bows the interior',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { ['c58'] = classic58 } },
        },
        data = { swing = { global = 'c58' } },
      }
      -- 240 ppq/QN, period 1 QN = 240 ppq. Boundaries are fixed.
      t.eq(h.tm:fromLogical(1, 0),   0,   'origin fixed')
      t.eq(h.tm:fromLogical(1, 240), 240, 'period boundary fixed')
      t.eq(h.tm:fromLogical(1, 480), 480, 'two periods in, still fixed')
      -- Mid-period maps to 0.58 of the period = 139.2 → 139 rounded.
      t.eq(h.tm:fromLogical(1, 120), 139, 'mid-period rounds to 139')
    end,
  },

  {
    name = 'offset is added inside the round (folds with delay-ppq)',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { ['c58'] = classic58 } },
        },
        data = { swing = { global = 'c58' } },
      }
      -- fromLogical(1,120) = 139.2; +0.6 = 139.8 → 140 rounded.
      t.eq(h.tm:fromLogical(1, 120, 0.6), 140,
        'rounding folds the offset, not the bare fromLogical')
    end,
  },

  {
    name = 'colSwing applies only to the named channel',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { ['c67'] = classic67 } },
        },
        data = { swing = { [2] = 'c67' } },
      }
      t.eq(h.tm:fromLogical(1, 120), 120, 'chan 1 unswung')
      -- 0.67 · 240 = 160.8 → 161 rounded.
      t.eq(h.tm:fromLogical(2, 120), 161, 'chan 2 mid-period rounds to 161')
    end,
  },

  {
    name = 'column is inner, global is outer (order matters)',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { ['c58'] = classic58, ['c67'] = classic67 } },
        },
        data = { swing = { global = 'c58', [1] = 'c67' } },
      }
      -- Compose by hand using the factor build tm uses, so the ordering
      -- pin doesn't depend on the closed form of the active atom.
      local res = h.tm:resolution()
      local fc58 = timing.resolveFactors(classic58, res)
      local fc67 = timing.resolveFactors(classic67, res)
      local colInner = timing.applyFactors(fc58, timing.applyFactors(fc67, 120))
      local colOuter = timing.applyFactors(fc67, timing.applyFactors(fc58, 120))

      t.eq(h.tm:fromLogical(1, 120), math.floor(colInner + 0.5),
        'tm:fromLogical matches column-inner ordering (rounded)')
      t.truthy(math.abs(colInner - colOuter) > 1e-6,
        'orders should produce distinguishable results: ' ..
        tostring(colInner) .. ' vs ' .. tostring(colOuter))
    end,
  },

  {
    name = 'missing slot name falls back to identity',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { ['c58'] = classic58 } },
        },
        data = { swing = { global = 'mysterious' } },  -- name not in the lib
      }
      t.eq(h.tm:fromLogical(1, 120), 120, 'unknown slot name passes through')
    end,
  },

  {
    name = 'identity composite (empty array) acts as pass-through',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { ['identity'] = {} } },
        },
        data = { swing = { global = 'identity' } },
      }
      t.eq(h.tm:fromLogical(1, 120), 120, 'empty composite is identity')
    end,
  },

  {
    name = 'cache invalidates across a swing edit',
    run = function(harness)
      local h = harness.mk{
        config = { project = { swings = { ['c58'] = classic58 } } },
      }
      t.eq(h.tm:fromLogical(1, 120), 120, 'no swing yet')
      h.ds:assign('swing', { global = 'c58' })
      t.eq(h.tm:fromLogical(1, 120), 139, 'swing took effect after rebuild')
    end,
  },
}
