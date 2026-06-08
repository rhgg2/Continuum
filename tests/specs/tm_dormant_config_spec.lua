-- A dormant tracker (after bindTake(nil)) must ignore the shared cm's
-- configChanged churn. The shared cm is written every frame regardless of
-- the active page -- samplePage's probeMode flips `trackerMode` (transient)
-- against the arrange cursor take. When the tracker has yielded the page,
-- cm.take is nil but mm still holds the last take (the dormant seam), so a
-- rebuild driven off that churn would resolve swing/trackerMode against
-- empty take/track tiers -- the "forgets swing / PC field acts sampler"
-- bug. The gate: tm rebuilds on configChanged only while cm has a bound take.

local t = require('support')

local classic58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }

local function countRebuilds(tm)
  local n = 0
  tm:subscribe('rebuild', function() n = n + 1 end)
  return function() return n end
end

return {
  {
    name = 'dormant tracker (bindTake nil) ignores configChanged churn',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { ['c58'] = classic58 } },
          take    = { swing = 'c58' },
        },
      }
      local rebuilds = countRebuilds(h.tm)

      h.tm:bindTake(nil)
      t.eq(rebuilds(), 0, 'bindTake(nil) itself fires no rebuild')

      -- probeMode-style write to the shared cm while the tracker is dormant.
      h.cm:set('transient', 'trackerMode', true)
      h.cm:set('take', 'swing', 'identity')
      t.eq(rebuilds(), 0, 'dormant tracker ignores configChanged')
    end,
  },

  {
    name = 'detach also makes the tracker dormant',
    run = function(harness)
      local h = harness.mk{
        config = { project = { swings = { ['c58'] = classic58 } } },
      }
      local rebuilds = countRebuilds(h.tm)

      h.tm:detach()
      t.eq(rebuilds(), 0, 'detach fires no rebuild')

      h.cm:set('transient', 'trackerMode', true)
      t.eq(rebuilds(), 0, 'detached tracker ignores configChanged')
    end,
  },

  {
    name = 'bound tracker still rebuilds on configChanged',
    run = function(harness)
      local h = harness.mk{
        config = { project = { swings = { ['c58'] = classic58 } } },
      }
      local rebuilds = countRebuilds(h.tm)

      -- cm has a bound take (harness binds on construct); the gate must not
      -- over-suppress a real edit on the bound take.
      h.cm:set('take', 'swing', 'c58')
      t.truthy(rebuilds() >= 1, 'bound tracker rebuilds on configChanged')
    end,
  },
}
