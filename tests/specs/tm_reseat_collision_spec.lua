-- Pins the voice the reseat's own nudge used to protect, now that the nudge is gone.
--
-- rebuildInternals recomputes raw from logical for a stale-swing channel, and that
-- recompute can land two distinct-ppqL same-pitch notes on one raw. It separated them
-- itself until 2026-07-17, on the claim that mm's dedup would otherwise eat a voice.
-- It no longer needs to, and these pin the voice it stopped protecting.
--
-- Two layers below it each separate this collision, and each is sufficient alone:
-- the tail walk (in-pass, same mm:batch nest) and mm's backstop (at the outermost
-- unwind). Disabling either leaves these green; disabling BOTH lands two voices on
-- raw 194 -- which is how the pin was verified, and why no case here names the layer
-- that delivers it. In production the walk goes first and the backstop finds nothing,
-- exactly as its contract promises. see docs/trackerManager.md § Same-pitch onset separation

local t = require('support')

local classic58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }

-- Delay, not swing, is what collides them: swing.fromLogical is injective, so it can never
-- map two seats onto one raw by itself. It moves them relative to a delay that stays put --
-- c58 sends ppqL 120 -> 139 and 180 -> 194, and the 229 ms-QN delay (= +55 ppq @ res 240)
-- carries the first onto the second. Authored under identity they sit apart, at 175 and 180.
local function reswungOntoOneRaw(harness)
  local h = harness.mk{
    seed = {
      notes = {
        { ppq = 175, endppq = 180, ppqL = 120, endppqL = 180,
          chan = 1, pitch = 60, vel = 100, detune = 0, delay = 229, rpb = 4 },
        { ppq = 180, endppq = 240, ppqL = 180, endppqL = 240,
          chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0, rpb = 4 },
      },
    },
    config = {
      project = { swings = { ['c58'] = classic58 } },
      take    = { rowPerBeat = 4 },
    },
  }
  h.ds:assign('swing', { global = 'c58' })   -- the production reswing path: dataChanged -> markSwingStale
  return h
end

local function ppqsOf(mm)
  local out = {}
  for _, n in mm:notes() do out[#out + 1] = n.ppq end
  table.sort(out)
  return out
end

return {

  {
    name = 'a reseat collapsing two same-pitch voices onto one raw keeps both',
    run = function(harness)
      local h = reswungOntoOneRaw(harness)

      local ppqs = ppqsOf(h.fm)
      t.eq(#ppqs, 2, 'both voices survived the reseat -- neither was deduped away')
      t.truthy(ppqs[1] ~= ppqs[2], 'and they hold distinct raws: ' .. table.concat(ppqs, ', '))
    end,
  },

  {
    name = 'the reseat commits the collision and the pass below it settles the geometry',
    run = function(harness)
      local h = reswungOntoOneRaw(harness)

      -- The reseat commits 194 twice, verbatim; whichever layer gets there first breaks
      -- the tie at +1. Both do it by the same voicing rule, so the geometry is the same.
      t.deepEq(ppqsOf(h.fm), { 194, 195 }, 'separated in the same pass that collided them')
    end,
  },

  {
    name = 'the reseat leaves intent alone: only raw moves',
    run = function(harness)
      local h = reswungOntoOneRaw(harness)

      local seats = {}
      for _, n in h.fm:notes() do seats[#seats + 1] = n.ppqL end
      table.sort(seats)
      -- The separation is realisation-only. Were it to reach ppqL, the next reswing would
      -- compound it -- and the nudged note would drift a tick per swing change, forever.
      t.deepEq(seats, { 120, 180 }, 'authored seats untouched by the collision or its fix')
    end,
  },

}
