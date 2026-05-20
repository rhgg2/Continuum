-- Unified onset+tail pass at tm:rebuild. Same-pitch raw ordering
-- wins: a user-authored delay that pulls a logical-later note BEFORE
-- its logical predecessor in realised time is respected -- the walk
-- treats whoever lands first in raw as the predecessor and retro-clips
-- the other's tail. The clamp only fires on actual collision (raws
-- within 1 tick); ppqL breaks the tie -- the logical-later note
-- yields. Authored `delay` survives untouched; mm.ppq carries the
-- final raw; tv derives `delayC` from (mm.ppq - swing(ppqL)).
--
-- Pins the prod path: cm:set('take','swing','c58') drives the
-- configCallback → markSwingStale → rebuild chain.

local t       = require('support')
local util    = require('util')

local classic58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }

return {
  {
    -- Swap respected: B's -240 delay drops it BEFORE A in raw. No
    -- clamp fires; B is treated as predecessor in realised time. A's
    -- onset unchanged. B's tail retro-clips to A's raw onset (same-
    -- pitch realised-successor). Under c58: ppqL 120 → raw 139,
    -- 180 → 194; B unclamped = 194 + delayToPPQ(-240) = 194 - 58 = 136.
    name = 'authored swap survives: B lands before A in raw, no clamp; A retro-clips B tail',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 120, endppq = 150, ppqL = 120, endppqL = 150,
              chan = 1, lane = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0,    rpb = 4 },
            { ppq = 122, endppq = 240, ppqL = 180, endppqL = 240,
              chan = 1, lane = 1, pitch = 60, vel = 100,
              detune = 0, delay = -240, rpb = 4 },
          },
        },
        config = {
          project = { swings = { ['c58'] = classic58 } },
          take    = { rowPerBeat = 4 },
        },
      }

      h.cm:set('take', 'swing', 'c58')

      local A, B
      for _, x in ipairs(h.fm:dump().notes) do
        if x.ppqL == 120 then A = x end
        if x.ppqL == 180 then B = x end
      end
      t.truthy(A and B,         'both notes survive the cm-driven rebuild')
      t.eq(A.ppq,    139,       'A realised raw at swing(120)')
      t.eq(B.ppq,    136,       'B realised raw at swing(180)+delayToPPQ(-240) -- unclamped')
      t.eq(B.delay, -240,       'authored delay survives')
      t.eq(B.endppq, 139,       "B's tail retro-clipped to A's onset (same-pitch realised-successor)")
    end,
  },

  {
    -- Collision clamp: B's delay just barely lands its raw onto A's.
    -- Tie-break by ppqL -- A (ppqL 120) is predecessor, B (ppqL 180)
    -- clamps to A.raw + 1 = 140. A's tail retro-clips to 140. delayC
    -- carries the give-way: (140 - 194) = -54 ppq = -225 ms-QN.
    name = 'raw collision: ppqL-later note clamps to predecessor + 1; delayC carries give-way',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 120, endppq = 150, ppqL = 120, endppqL = 150,
              chan = 1, lane = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0,    rpb = 4 },
            { ppq = 125, endppq = 240, ppqL = 180, endppqL = 240,
              chan = 1, lane = 1, pitch = 60, vel = 100,
              detune = 0, delay = -230, rpb = 4 },
          },
        },
        config = {
          project = { swings = { ['c58'] = classic58 } },
          take    = { rowPerBeat = 4 },
        },
      }

      h.cm:set('take', 'swing', 'c58')

      local A, B
      for _, x in ipairs(h.fm:dump().notes) do
        if x.ppqL == 120 then A = x end
        if x.ppqL == 180 then B = x end
      end
      t.truthy(A and B,         'both notes survive the cm-driven rebuild')
      t.eq(B.delay, -230,       'authored delay survives the clamp untouched')
      t.eq(B.ppq,    140,       'B clamped to A.raw + 1 on collision')
      t.eq(A.endppq, 140,       "A's tail retro-clipped to B's clamped onset")

      local Bsurf
      for _, e in ipairs(h.tm:getChannel(1).columns.notes[1].events) do
        if e.ppqL == 180 then Bsurf = e end
      end
      t.truthy(Bsurf,           'B projected to tv surface')
      t.eq(Bsurf.delay,  -230,  'tv surface exposes authored delay')
      t.eq(Bsurf.delayC, -225,  'tv surface exposes give-way amount (140-194 ppq in ms-QN)')
    end,
  },
}
