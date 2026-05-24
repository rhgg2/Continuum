-- Pins the projection contract of newViewContext directly, without
-- going through vm. The context is built by hand from synthetic args so
-- failures localise to newViewContext rather than to vm:rebuild's wiring.
-- vm-integration tests live in vm_grid_spec.

local t = require('support')
local tuning = require('tuning')
local util   = require('util')

---------- BUILDERS

-- Uniform logical grid for 240 ppq/QN, 4 rows/beat, length 3840 ppq.
local function logicalGrid()
  local ppqPerRow = 60
  local length    = 3840
  return length // ppqPerRow, length
end

local function mkCtx(overrides)
  local numRows, length = logicalGrid()
  local args = {
    length     = length,
    numRows    = numRows,
    rowPerBeat = 4,
    ppqPerRow  = 60,
    timeSigs   = { { ppq = 0, num = 4, denom = 4 } },
    temper     = nil,
  }
  for k, v in pairs(overrides or {}) do args[k] = v end
  return util.instantiate('viewContext', args)
end

-- Non-divisor rpb: ppqPerRow is fractional, so row · ppqPerRow lands
-- between integers for most rows. Pins that rowToPPQ / ppqToRow are
-- now both float — the old F4 asymmetry (rowToPPQ rounded at the
-- realisation boundary) is gone; "on the grid" is owned by isOnGrid.
local function mkCtxRpb(rpb, ppqPerQN)
  ppqPerQN        = ppqPerQN or 240
  local ppqPerRow = ppqPerQN / rpb        -- denom = 4 ⇒ resolution*4/denom = ppqPerQN
  local numRows   = rpb * 16              -- 4 bars of content
  local length    = numRows * ppqPerRow
  return mkCtx{
    length     = length,
    numRows    = numRows,
    rowPerBeat = rpb,
    ppqPerRow  = ppqPerRow,
  }
end

return {
  ---------- PPQ ↔ ROW

  {
    name = 'identity swing: ppqToRow / rowToPPQ round-trip on grid-aligned rows',
    run = function()
      local ctx = mkCtx()
      for _, r in ipairs{ 0, 1, 4, 16, 32, 63 } do
        t.eq(ctx:rowToPPQ(r, 1), r * 60, 'rowToPPQ row=' .. r)
        t.eq(ctx:ppqToRow(r * 60, 1), r,  'ppqToRow ppq=' .. r * 60)
      end
    end,
  },

  {
    name = 'identity swing: ppqToRow and rowToPPQ are exact inverses, both returning float',
    run = function()
      local ctx = mkCtx()
      -- 30 ppq is half a row at 60 ppq/row.
      t.truthy(math.abs(ctx:ppqToRow(30, 1) - 0.5) < 1e-9, 'ppqToRow(30) = 0.5')
      -- rowToPPQ(0.5) = 30.0 exact — no rounding at the realisation boundary.
      t.eq(ctx:rowToPPQ(0.5, 1), 30)
      t.eq(ctx:rowToPPQ(0.49, 1), 0.49 * 60)
    end,
  },

  {
    name = 'snapRow snaps fractional ppq to the nearest row',
    run = function()
      local ctx = mkCtx()
      t.eq(ctx:snapRow(0,   1), 0)
      t.eq(ctx:snapRow(29,  1), 0)
      t.eq(ctx:snapRow(30,  1), 1)   -- exact midpoint — floor(0.5+0.5) = 1
      t.eq(ctx:snapRow(31,  1), 1)
      t.eq(ctx:snapRow(89,  1), 1)
      t.eq(ctx:snapRow(90,  1), 2)
    end,
  },

  {
    name = 'ppq above length saturates at numRows; ppq below 0 saturates at 0',
    run = function()
      local ctx = mkCtx()
      t.eq(ctx:ppqToRow(-100,  1), 0)
      t.eq(ctx:ppqToRow(99999, 1), 64)
      t.eq(ctx:rowToPPQ(-1,    1), 0)
      t.eq(ctx:rowToPPQ(99999, 1), 3840)
    end,
  },

  ---------- ROUND-TRIP UNDER NON-DIVISOR RPB
  --
  -- The logical frame is float. rowToPPQ and ppqToRow are exact
  -- inverses; the on-grid threshold lives in ctx:isOnGrid, not in
  -- the projection.

  {
    name = 'snapRow(rowToPPQ(r,c),c) == r under non-divisor rpb',
    run = function()
      for _, rpb in ipairs{ 5, 7 } do
        local ctx = mkCtxRpb(rpb)
        for r = 0, rpb * 4 - 1 do
          t.eq(ctx:snapRow(ctx:rowToPPQ(r, 1), 1), r,
            'rpb=' .. rpb .. ' r=' .. r)
        end
      end
    end,
  },

  {
    name = 'on-grid p round-trips exactly under non-divisor rpb',
    run = function()
      for _, rpb in ipairs{ 5, 7 } do
        local ctx = mkCtxRpb(rpb)
        for r = 0, rpb * 4 - 1 do
          local p = ctx:rowToPPQ(r, 1)
          t.eq(ctx:rowToPPQ(ctx:ppqToRow(p, 1), 1), p,
            'rpb=' .. rpb .. ' r=' .. r .. ' p=' .. p)
        end
      end
    end,
  },

  {
    name = 'ppqToRow ∘ rowToPPQ is the identity (float) under non-divisor rpb',
    -- The old F4 asymmetry came from rowToPPQ flooring at the
    -- realisation boundary; that round is gone, so the round-trip is
    -- exact (modulo IEEE-754 ulps, well under 1e-9).
    run = function()
      for _, rpb in ipairs{ 5, 7 } do
        local ctx = mkCtxRpb(rpb)
        for r = 0, rpb * 4 - 1 do
          local back  = ctx:ppqToRow(ctx:rowToPPQ(r, 1), 1)
          t.truthy(math.abs(back - r) < 1e-9,
            'rpb=' .. rpb .. ' r=' .. r .. ' back=' .. back)
        end
      end
    end,
  },

  ---------- ON-GRID PREDICATE

  {
    name = 'isOnGrid: exact row ppqs are on-grid',
    run = function()
      local ctx = mkCtx()    -- ppqPerRow = 60
      for _, r in ipairs{ 0, 1, 4, 16, 63 } do
        t.truthy(ctx:isOnGrid(ctx:rowToPPQ(r, 1), 1),
          'exact rowToPPQ(' .. r .. ') is on-grid')
      end
    end,
  },

  {
    name = 'isOnGrid: tolerates float drift up to (but not including) 0.5 ppq',
    -- The threshold matches mm's integer raw frame: anything closer
    -- than half a tick to a row boundary collapses to the same raw
    -- onset on flush, so the predicate treats it as on-grid.
    run = function()
      local ctx = mkCtx()    -- row 1 is ppq 60
      t.truthy(ctx:isOnGrid(60,        1), 'on the row')
      t.truthy(ctx:isOnGrid(60 + 0.49, 1), '+0.49 ppq from a row is on-grid')
      t.truthy(ctx:isOnGrid(60 - 0.49, 1), '-0.49 ppq from a row is on-grid')
      t.eq    (ctx:isOnGrid(60 + 0.5,  1), false, '±0.5 ppq is the strict cutoff')
      t.eq    (ctx:isOnGrid(75,        1), false, 'mid-row ppq is off-grid')
    end,
  },

  {
    name = 'isOnGrid: rebuild-inverted ppqs land on-grid under non-divisor rpb',
    -- Mirrors the rebuild path where toLogical(fromLogical(rowPPQ))
    -- carries IEEE-754 drift; isOnGrid must absorb it.
    run = function()
      local ctx = mkCtxRpb(7)
      for r = 0, 27 do
        local p     = ctx:rowToPPQ(r, 1)
        local drift = p + 1e-12
        t.truthy(ctx:isOnGrid(drift, 1),
          'rpb=7 r=' .. r .. ' p+ulp on-grid')
      end
    end,
  },

  ---------- PPQ-PER-ROW

  {
    name = 'ppqPerRow exposes the rebuild frame logical ppq width',
    run = function()
      t.eq(mkCtx():ppqPerRow(), 60)
    end,
  },

  ---------- TEMPERAMENT LENS

  {
    name = 'activeTemper is nil when no temperament is bound',
    run = function()
      t.eq(mkCtx():activeTemper(), nil)
    end,
  },

  {
    name = 'activeTemper returns the bound temperament object',
    run = function()
      local temper = tuning.presets['19EDO']
      t.eq(mkCtx{ temper = temper }:activeTemper(), temper)
    end,
  },

  {
    name = 'noteProjection returns nil when no temperament is bound',
    run = function()
      t.eq(mkCtx():noteProjection({ pitch = 60 }), nil)
    end,
  },

  {
    name = 'noteProjection under 12EDO: pitch 60 maps to C-4 with zero gap',
    run = function()
      local ctx = mkCtx{ temper = tuning.presets['12EDO'] }
      local label, gap, halfGap = ctx:noteProjection({ pitch = 60 })
      t.eq(label, 'C-4')
      t.eq(gap, 0)
      t.eq(halfGap, 50)   -- half of 100¢ between adjacent 12EDO steps
    end,
  },

  {
    name = 'noteProjection signed gap: positive detune yields positive gap (sharp)',
    run = function()
      local ctx = mkCtx{ temper = tuning.presets['12EDO'] }
      local _, gap = ctx:noteProjection({ pitch = 60, detune = 20 })
      t.truthy(gap > 0, 'sharp detune ⇒ positive gap, got ' .. tostring(gap))
      local _, gapDown = ctx:noteProjection({ pitch = 60, detune = -20 })
      t.truthy(gapDown < 0, 'flat detune ⇒ negative gap, got ' .. tostring(gapDown))
    end,
  },

  {
    name = 'noteProjection halfGap is half the cents-distance to the nearest neighbour',
    run = function()
      local temper = tuning.presets['19EDO']
      local ctx = mkCtx{ temper = temper }
      local _, _, halfGap = ctx:noteProjection({ pitch = 60 })   -- midi 60 ⇒ step 1
      -- Step 1 is symmetric: neighbours at -(period - steps[n]) and +steps[2].
      local n        = #temper.cents
      local period   = temper.period
      local left     = temper.cents[n] - period
      local right    = temper.cents[2]
      local expected = math.min(temper.cents[1] - left, right - temper.cents[1]) / 2
      t.eq(halfGap, expected, 'halfGap = half min-neighbour-distance')
    end,
  },

  ---------- TIME SIGNATURE / METERING

  {
    name = 'rowBeatInfo at row 0 under 4/4 reports (bar, beat) = (true, true)',
    run = function()
      local bar, beat = mkCtx():rowBeatInfo(0)
      t.eq(bar, true,  'isBarStart at row 0')
      t.eq(beat, true, 'isBeatStart at row 0')
    end,
  },

  {
    name = 'rowBeatInfo at beat boundary: only beat flag set',
    run = function()
      local ctx = mkCtx()  -- 4 rpb, 4/4 ⇒ rowPerBar = 16
      local bar, beat = ctx:rowBeatInfo(4)
      t.eq(bar,  false, 'row 4 is not a bar start')
      t.eq(beat, true,  'row 4 is a beat start')
    end,
  },

  {
    name = 'rowBeatInfo at bar boundary: both flags set',
    run = function()
      local bar, beat = mkCtx():rowBeatInfo(16)
      t.eq(bar,  true)
      t.eq(beat, true)
    end,
  },

  {
    name = 'rowBeatInfo at non-boundary row: both flags clear',
    run = function()
      local bar, beat = mkCtx():rowBeatInfo(3)
      t.eq(bar,  false)
      t.eq(beat, false)
    end,
  },

  {
    name = 'rowBeatInfo respects mid-take time-sig change',
    run = function()
      -- New ts at ppq=1920 (row 32). 3/4 ⇒ rowPerBar = 12.
      local ctx = mkCtx{
        timeSigs = {
          { ppq = 0,    num = 4, denom = 4 },
          { ppq = 1920, num = 3, denom = 4 },
        },
      }
      local bar, _ = ctx:rowBeatInfo(32)
      t.eq(bar, true, 'row 32 is a bar start under new ts')
      bar, _ = ctx:rowBeatInfo(44)   -- 32 + 12 = next bar under 3/4
      t.eq(bar, true, 'row 44 is the next bar start under 3/4')
      bar, _ = ctx:rowBeatInfo(48)   -- would be a bar under 4/4, not under 3/4
      t.eq(bar, false, 'row 48 is NOT a bar start under 3/4')
    end,
  },

  {
    name = 'barBeatSub at row 0 returns (1, 1, 1, ts)',
    run = function()
      local b, beat, sub, ts = mkCtx():barBeatSub(0)
      t.eq(b, 1); t.eq(beat, 1); t.eq(sub, 1)
      t.eq(ts.num, 4); t.eq(ts.denom, 4)
    end,
  },

  {
    name = 'barBeatSub mid-bar: (bar, beat, sub) walks the row index',
    run = function()
      -- 4 rpb, 4/4 ⇒ row 6 is bar 1, beat 2 (rows 4-7), sub 3 (4+2)
      local b, beat, sub = mkCtx():barBeatSub(6)
      t.eq(b, 1); t.eq(beat, 2); t.eq(sub, 3)
    end,
  },

  {
    name = 'barBeatSub crosses a time-sig change and resumes counting',
    run = function()
      -- 4/4 for 2 bars (32 rows), then 3/4 starting at row 32.
      -- Row 32 is bar 3 of the take, beat 1, sub 1.
      local ctx = mkCtx{
        timeSigs = {
          { ppq = 0,    num = 4, denom = 4 },
          { ppq = 1920, num = 3, denom = 4 },
        },
      }
      local b, beat, sub, ts = ctx:barBeatSub(32)
      t.eq(b, 3, 'first bar after the change is bar 3')
      t.eq(beat, 1); t.eq(sub, 1)
      t.eq(ts.num, 3)
      -- Row 44 = next bar under 3/4
      b, beat, sub = ctx:barBeatSub(44)
      t.eq(b, 4); t.eq(beat, 1); t.eq(sub, 1)
    end,
  },

  ---------- VM ↔ CTX WIRING
  --
  -- These pin that vm:rebuild produces a fresh ctx from the current
  -- snapshot/cfg, and that vm's public projection methods forward to it.
  -- A regression here would mean either the rebuild forgot to refresh
  -- ctx, or a vm:foo forwarder lost its connection to ctx.

  -- Ghost-sampling coverage runs through the vm surface (gridCol.ghosts)
  -- because that's the contract rm consumes. Shape semantics themselves
  -- are owned by midiManager (mm:interpolate); these tests only pin that
  -- the vm→tm→mm pathway wires up correctly and preserves val/refs.

  {
    name = 'ghosts: linear pair populates interior rows with proportional vals',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq = 0,   chan = 1, evType = 'cc', cc = 1, val = 0,   shape = 'linear' },
            { ppq = 240, chan = 1, evType = 'cc', cc = 1, val = 100 },
          },
        },
      }
      local ccCol
      for _, c in ipairs(h.vm.grid.cols) do
        if c.type == 'cc' and c.cc == 1 then ccCol = c end
      end
      t.truthy(ccCol,             'cc column built')
      t.truthy(ccCol.ghosts[1],   'ghost at row 1')
      t.eq(ccCol.ghosts[2].val, 50, 'linear midpoint val')
      t.truthy(ccCol.ghosts[3],   'ghost at row 3')
      t.eq(ccCol.ghosts[0], nil,  'no ghost on row 0 (host A)')
      t.eq(ccCol.ghosts[4], nil,  'no ghost on row 4 (host B)')
    end,
  },

  {
    name = 'ghosts: entries carry fromEvt and toEvt references',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq = 0,   chan = 1, evType = 'cc', cc = 1, val = 0,   shape = 'linear' },
            { ppq = 240, chan = 1, evType = 'cc', cc = 1, val = 100 },
          },
        },
      }
      local ccCol
      for _, c in ipairs(h.vm.grid.cols) do
        if c.type == 'cc' and c.cc == 1 then ccCol = c end
      end
      local g = ccCol.ghosts[2]
      t.eq(g.fromEvt.ppq, 0,   'fromEvt is A (ppq 0)')
      t.eq(g.fromEvt.val, 0,   'fromEvt val is A.val')
      t.eq(g.toEvt.ppq,   240, 'toEvt is B (ppq 240)')
      t.eq(g.toEvt.val,   100, 'toEvt val is B.val')
    end,
  },

  {
    name = 'ghosts: step shape produces no ghosts',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq = 0,   chan = 1, evType = 'cc', cc = 1, val = 0,   shape = 'step' },
            { ppq = 240, chan = 1, evType = 'cc', cc = 1, val = 100 },
          },
        },
      }
      for _, c in ipairs(h.vm.grid.cols) do
        if c.type == 'cc' and c.cc == 1 then
          t.eq(next(c.ghosts or {}), nil, 'no ghosts under step shape')
        end
      end
    end,
  },

  {
    name = 'ghosts: single event yields no ghosts',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq = 0, chan = 1, evType = 'cc', cc = 1, val = 0, shape = 'linear' },
          },
        },
      }
      for _, c in ipairs(h.vm.grid.cols) do
        if c.type == 'cc' and c.cc == 1 then
          t.eq(next(c.ghosts or {}), nil, 'no ghosts without a following pair')
        end
      end
    end,
  },

  {
    name = 'ghosts: non-linear shape routes through tm:interpolate',
    -- Pins that shape other than linear/step actually reaches the
    -- interpolator; t=0.5 under bezier tension 0 ≡ linear midpoint.
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq = 0,   chan = 1, evType = 'cc', cc = 1, val = 0,   shape = 'bezier', tension = 0 },
            { ppq = 240, chan = 1, evType = 'cc', cc = 1, val = 100 },
          },
        },
      }
      local ccCol
      for _, c in ipairs(h.vm.grid.cols) do
        if c.type == 'cc' and c.cc == 1 then ccCol = c end
      end
      t.eq(ccCol.ghosts[2].val, 50, 'bezier@tension=0 midpoint matches linear')
    end,
  },

  {
    name = 'temper resolves via cfg.tempers, falls back to built-in presets, returns nil for unknown names',
    -- findTemper looks in the user lib first then in tuning.presets. The
    -- schema default '12EDO' is a built-in preset name, so it resolves
    -- with no seeding required. Unknown names still resolve to nil.
    run = function(harness)
      local h = harness.mk()
      local def = h.vm:activeTemper()
      t.truthy(def,           'schema-default 12EDO resolves via presets fallback')
      t.eq(def.name, '12EDO')

      h.cm:set('take', 'temper', '19EDO')
      local t19 = h.vm:activeTemper()
      t.truthy(t19,           'built-in preset name resolves without seeding cfg.tempers')
      t.eq(t19.name, '19EDO')

      h.cm:set('take', 'temper', 'NotARealTemperName')
      t.eq(h.vm:activeTemper(), nil, 'unknown name resolves to nil')

      h.vm:setTemper('myCustom', tuning.presets['19EDO'])
      h.cm:set('take', 'temper', 'myCustom')
      t.eq(h.vm:activeTemper().name, '19EDO', 'user-seeded temper resolves')
    end,
  },
}
