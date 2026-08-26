-- Test-only generator kinds, registered into the production registry on require (harness pulls this
-- in, so every spec has them) and inert until a spec names one. They stay off `modalOrder`, so the
-- palette never offers them, and a name here shadows a production kind of the same name.
--
-- Most fx specs need only *a* continuous augment to park, seat, reconcile and sweep. Keying them on
-- a production kind makes every change to that kind a spec edit, on assertions that were never about
-- it -- so `sine`, which the LFO absorbed, stays here as the stand-in: geometry simple enough to
-- assert on directly. Depth at the extrema of each cycle, `slow` between them, zero at both window
-- edges, and a linear ramp-in over `onset` QN.

local util       = require 'util'
local generators = require 'generators'

local function periodTicks(period, resolution)
  local qn = type(period) == 'table' and period[1] / period[2] or period
  return qn * resolution
end

--contract: sine -> delta breakpoints in the dest's own units; depth at 1/period QN, unit-naive
--contract: breakpoints at the extrema, 'slow'-shaped; linear ramp-in over onset QN; 0 at both edges
local function sine(stream, host, params, ctx)
  local startL, endL = stream.window[1], stream.window[2]
  local period = periodTicks(params.period, ctx.resolution)
  local depth  = params.depth or 0
  local onset  = (params.onset or 0) * ctx.resolution

  local delta = { { ppq = startL, val = 0, shape = 'slow' } }
  local k  = 0
  local at = startL + period / 4
  while at < endL do
    local gain = onset > 0 and math.min(1, (at - startL) / onset) or 1
    local sign = k % 2 == 0 and 1 or -1
    util.add(delta, { ppq = at, val = sign * gain * depth, shape = 'slow' })
    k  = k + 1
    at = startL + period / 4 + k * period / 2
  end
  util.add(delta, { ppq = endL, val = 0, shape = 'slow' })
  return { notes = {}, delta = delta }
end

local PERIODS = { { l = '1/2', v = { 1, 2 } }, { l = '1/3', v = { 1, 3 } },
                  { l = '1/4', v = { 1, 4 } }, { l = '1/6', v = { 1, 6 } },
                  { l = '1/8', v = { 1, 8 } } }

generators.kinds.sine = {
  -- '~' rather than the LFO's own wave mark: the glyph-uniqueness invariant covers the whole registry,
  -- fixtures included, and a stand-in must not be the kind it stands in for.
  expand = sine, mode = 'augment', dest = 'pb', dests = 'any', label = 'Sine', glyph = '~',
  defaults = { period = { 1, 2 }, onset = 1 },
  fields = {
    { field = 'period', label = 'Period', widget = 'choice', options = PERIODS },
    { field = 'depth',  label = 'Depth',  widget = 'int', base = 1, coarse = 10,
      quantity = 'magnitude', frac = 0.15 },
    { field = 'onset',  label = 'Onset',  widget = 'int', base = 1, coarse = 4, min = 0, max = 16 },
  },
}

return generators.kinds.sine
