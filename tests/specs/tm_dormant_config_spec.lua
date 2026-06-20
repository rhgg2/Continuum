-- A dormant tracker must ignore shared cm's configChanged churn (any page can write it).
-- See docs/trackerManager.md § Dormant seam for the invariant this pins.

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
        config = { project = { swings = { ['c58'] = classic58 } } },
        data   = { swing = { global = 'c58' } },
      }
      local rebuilds = countRebuilds(h.tm)

      h.tm:bindTake(nil)
      t.eq(rebuilds(), 0, 'bindTake(nil) itself fires no rebuild')

      -- probeMode-style write to the shared cm while the tracker is dormant.
      h.cm:set('transient', 'trackerMode', true)
      h.ds:assign('swing', { global = 'identity' })
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
    name = 'bound tracker still rebuilds on a swing edit',
    run = function(harness)
      local h = harness.mk{
        config = { project = { swings = { ['c58'] = classic58 } } },
      }
      local rebuilds = countRebuilds(h.tm)

      -- cm has a bound take (harness binds on construct); the gate must not
      -- over-suppress a real edit on the bound take.
      h.ds:assign('swing', { global = 'c58' })
      t.truthy(rebuilds() >= 1, 'bound tracker rebuilds on a swing edit')
    end,
  },
}
