-- The projection contract of the time context, built by hand from synthetic args so a failure
-- localises here and not in tm:rebuild's wiring. The tm-integration tests are tm_swing_spec
-- (the projection under edits) and tm_length_swing_spec (the length as a projection input).
-- see docs/timing.md § The time context

local t      = require('support')
local util   = require('util')
local timing = require('timing')

local PPQ_PER_QN = 240
local LENGTH     = 3840

-- Two composites, steep enough that a displacement clears rounding, and different enough from
-- each other that composing them in the wrong order is visible.
local steep  = { factors = { { atom = 'classic', shift = 0.2,  period = 1 } } }
local gentle = { factors = { { atom = 'classic', shift = 0.05, period = 2 } } }

local function mkCtx(overrides)
  local args = {
    length     = LENGTH,
    ppqPerQN   = PPQ_PER_QN,
    swings     = { steep = steep, gentle = gentle },
    assignment = {},
  }
  for k, v in pairs(overrides or {}) do args[k] = v end
  return util.instantiate('timeContext', args)
end

-- An onset in the tile's second half, where the classic atom's displacement is largest.
local INTERIOR = 1899

return {
  {
    name = 'the frames agree at both ends of the take',
    run = function()
      local ctx = mkCtx{ assignment = { global = 'steep' } }
      t.truthy(ctx:fromLogical(1, INTERIOR) ~= INTERIOR,
        'precondition: the composite displaces an interior onset')
      t.eq(ctx:fromLogical(1, 0), 0, 'the origin is a fixed point')
      t.eq(ctx:fromLogical(1, LENGTH), LENGTH, "the take's end is a fixed point")
    end,
  },

  {
    name = 'toLogical inverts fromLogical',
    run = function()
      local ctx = mkCtx{ assignment = { global = 'gentle', [1] = 'steep' } }
      for _, ppqL in ipairs{ 1, 240, 601, 1899, 2400, 3839 } do
        local back = ctx:toLogical(1, ctx:fromLogical(1, ppqL))
        t.truthy(math.abs(back - ppqL) <= 1,
          'round trip through the realisation frame returns the logical onset: ' .. ppqL)
      end
    end,
  },

  {
    name = 'the column layer is inner and the global outer',
    run = function()
      -- The two atoms share a tile boundary at INTERIOR, where the order is invisible; 300 sits
      -- where the layers disagree by several ppq, so composing them the other way is a red.
      local ONSET  = 300
      local ctx    = mkCtx{ assignment = { global = 'gentle', [1] = 'steep' } }
      local outer  = timing.resolveComposite(gentle, LENGTH, PPQ_PER_QN)
      local inner  = timing.resolveComposite(steep,  LENGTH, PPQ_PER_QN)
      local Ec     = util.round(timing.eval(outer, timing.eval(inner, ONSET)))
      local wrong  = util.round(timing.eval(inner, timing.eval(outer, ONSET)))
      t.truthy(Ec ~= wrong, 'precondition: the two layers do not commute at this onset')
      t.eq(ctx:fromLogical(1, ONSET), Ec, 'the projection is global after column')
    end,
  },

  {
    name = 'a channel with no assignment projects identically',
    run = function()
      local ctx = mkCtx{ assignment = { [1] = 'steep' } }
      t.truthy(ctx:fromLogical(1, INTERIOR) ~= INTERIOR,
        'precondition: the assigned channel is displaced')
      t.eq(ctx:fromLogical(2, INTERIOR), INTERIOR, 'an unassigned channel is the identity')
      t.eq(ctx:toLogical(2, INTERIOR), INTERIOR, 'and its inverse likewise')
    end,
  },

  {
    name = 'the length is an input to the projection',
    run = function()
      -- The composite's ramps run to (length, length), so the same onset under two lengths is
      -- two different realisations, each inside its own end. This is what makes a resize a
      -- swing change. see docs/timing.md § The time context
      local long  = mkCtx{ assignment = { global = 'steep' } }
      local short = mkCtx{ assignment = { global = 'steep' }, length = 1900 }
      t.eq(long:length(), LENGTH, 'the context carries the span it resolved over')
      t.eq(short:length(), 1900, 'and the short one carries its own')
      t.truthy(long:fromLogical(1, INTERIOR) ~= short:fromLogical(1, INTERIOR),
        'the same logical onset realises differently under two lengths')
      t.truthy(long:fromLogical(1, INTERIOR) <= LENGTH, 'each realisation lands inside its end')
      t.truthy(short:fromLogical(1, INTERIOR) <= 1900, 'each realisation lands inside its end')
    end,
  },

  {
    name = 'a lengthless take projects identically',
    run = function()
      local ctx = mkCtx{ assignment = { global = 'steep' }, length = 0 }
      t.eq(ctx:fromLogical(1, INTERIOR), INTERIOR, 'no span to resolve over, so no displacement')
    end,
  },

  {
    name = 'the offset is a realisation-frame nudge',
    run = function()
      -- A note's delay shifts the raw note-on and nothing else: it is added after the projection,
      -- not carried through it. see docs/timing.md § Delay: per-note nudge
      local ctx   = mkCtx{ assignment = { global = 'steep' } }
      local delay = 17
      t.eq(ctx:fromLogical(1, INTERIOR, delay), ctx:fromLogical(1, INTERIOR) + delay,
        'the offset adds in the realisation frame')
      t.truthy(ctx:fromLogical(1, INTERIOR + delay) ~= ctx:fromLogical(1, INTERIOR, delay),
        'precondition: nudging the logical onset instead would land elsewhere')
    end,
  },

  {
    name = 'fromLogical is integer-valued',
    run = function()
      local ctx = mkCtx{ assignment = { global = 'steep' } }
      for _, ppqL in ipairs{ 100.4, 1899.75, 2400.5 } do
        local ppq = ctx:fromLogical(1, ppqL)
        t.eq(ppq, math.floor(ppq), 'the realisation frame is integer-valued: ' .. ppqL)
      end
    end,
  },
}
