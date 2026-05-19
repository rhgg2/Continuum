-- Projection symmetry: the column-projection step must expose BOTH the
-- onset and the tail in the logical frame, never raw.
--
-- Before: step 5 projected only evt.ppq = round(ppqL); evt.endppq was
-- left as the tail pass's CLIPPED RAW value. So a tv consumer reading
-- evt.endppq got a swung, clipped realisation while evt.ppq was logical
-- -- the asymmetry this suite pins shut.
--
-- After: evt.endppq = round(endppqL) (authored logical ceiling,
-- UNCLIPPED; util.OPEN stays OPEN). evt.endppqC = clipped logical
-- ceiling (render-only; the tp tail build is the sole consumer). Raw
-- never appears on the tv surface.
--
-- Real tm, real cm under a non-identity swing (classic-55) so a raw
-- leak is detectable: logical 600 and swung-raw(600) differ.

local t       = require('support')
local util    = require('util')
local harness = require('harness')

local C55 = { config = {
  project = { swings = { ['c55'] = {
    factors = { { atom = 'classic', shift = 0.05, period = 1 } } } } },
  take    = { swing = 'c55' },
} }

local function probe() return harness.mk(C55).tm end

local function seeded(notes)
  return harness.mk{
    config = C55.config,
    seed   = { length = 7680, resolution = 240, notes = notes },
  }
end

local function noteAt(tm, pitch)
  for _, e in ipairs(tm:getChannel(1).columns.notes[1].events) do
    if e.pitch == pitch then return e end
  end
end

return {
  {
    name = 'finite clipped note: endppq is authored logical, endppqC is clipped logical, neither is raw',
    run = function()
      local p = probe()
      -- A authored long (endppqL 600); B at logical 360 same pitch
      -- clips A's raw tail. Authored intent must survive on endppq.
      local h = seeded{
        { ppq = p:fromLogical(1, 180), endppq = p:fromLogical(1, 600),
          ppqL = 180, endppqL = 600, chan = 1, lane = 1,
          pitch = 60, vel = 100, uuid = 1 },
        { ppq = p:fromLogical(1, 360), endppq = p:fromLogical(1, 480),
          ppqL = 360, endppqL = 480, chan = 1, lane = 1,
          pitch = 60, vel = 100, uuid = 2 },
      }
      local a = noteAt(h.tm, 60)

      t.eq(a.ppq, 180, 'onset projected to logical')
      t.eq(a.endppq, 600, 'endppq is the authored logical ceiling, unclipped')
      t.eq(a.endppqC, 360, 'endppqC is the clipped logical ceiling (next same-pitch onset)')

      -- The leak guard: under classic-55, raw(600) != 600. If projection
      -- regressed to leaving raw on the surface, endppq would equal one
      -- of these swung values, not the integer logical 600.
      t.truthy(p:fromLogical(1, 600) ~= 600, 'precondition: swing is non-identity')
      t.truthy(a.endppq ~= p:fromLogical(1, 600), 'endppq is not raw(authored)')
      t.truthy(a.endppqC ~= p:fromLogical(1, 360), 'endppqC is not raw(clipped)')
    end,
  },

  {
    name = 'open tail: endppq stays util.OPEN, endppqC is the clipped logical render position',
    run = function()
      local p = probe()
      -- A open; B at logical 360 same pitch is the only blocker, so the
      -- rendered tail clips there while authored intent stays OPEN.
      local h = seeded{
        { ppq = p:fromLogical(1, 180), endppq = p:fromLogical(1, 240),
          ppqL = 180, endppqL = util.OPEN, chan = 1, lane = 1,
          pitch = 60, vel = 100, uuid = 1 },
        { ppq = p:fromLogical(1, 360), endppq = p:fromLogical(1, 480),
          ppqL = 360, endppqL = 480, chan = 1, lane = 1,
          pitch = 60, vel = 100, uuid = 2 },
      }
      local a = noteAt(h.tm, 60)

      t.eq(a.endppq, util.OPEN, 'open authored tail stays OPEN on the surface')
      t.eq(a.endppqC, 360, 'endppqC clips the open tail to the next same-pitch onset')
    end,
  },
}
