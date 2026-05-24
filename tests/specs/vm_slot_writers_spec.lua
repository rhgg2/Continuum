-- Pin the slot-selection write contract: take-tier holds the actual
-- selection; project-tier 'last*Used' is the seed tv:seedSharedSlots
-- copies onto a fresh take on bind. The old project-tier mirror of
-- 'swing' / 'temper' lived outside REAPER's undo and desynced the
-- picker from the rewound take-tier value on Ctrl-Z, so it was
-- removed -- picker inheritance is now an explicit bind-time seed,
-- not a silent fallthrough.

local t = require('support')
local tuning = require('tuning')

local classic58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }
local classic67 = { factors = { { atom = 'classic', shift = 0.17, period = 1 } } }

return {
  ----------------------------------------------------------------
  -- temper: take tier + lastTemperUsed seed
  ----------------------------------------------------------------
  {
    name = 'setTemperSlot writes take tier and lastTemperUsed seed',
    run = function(harness)
      local h = harness.mk{
        config = { project = { tempers = { ['19EDO'] = tuning.presets['19EDO'] } } },
      }
      h.vm:setTemperSlot('19EDO')
      t.eq(h.cm:getAt('take',    'temper'),         '19EDO', 'take holds the selection')
      t.eq(h.cm:getAt('project', 'lastTemperUsed'), '19EDO', 'project seeds fresh takes')
      t.eq(h.cm:getAt('project', 'temper'),         nil,     'no project-tier mirror of the slot itself')
      t.eq(h.cm:getAt('track',   'temper'),         nil,     'no track-tier mirror either -- per-take')
    end,
  },
  {
    name = 'setTemperSlot(nil) writes the 12EDO sentinel at take and seed',
    run = function(harness)
      local h = harness.mk{ config = { take = { temper = '19EDO' } } }
      h.vm:setTemperSlot(nil)
      t.eq(h.cm:getAt('take',    'temper'),         '12EDO', 'take -> 12EDO sentinel')
      t.eq(h.cm:getAt('project', 'lastTemperUsed'), '12EDO', 'seed records the Off choice')
    end,
  },
  {
    name = 'setTemperSlot("") writes the 12EDO sentinel at take and seed',
    run = function(harness)
      local h = harness.mk{ config = { take = { temper = '19EDO' } } }
      h.vm:setTemperSlot('')
      t.eq(h.cm:getAt('take',    'temper'),         '12EDO', 'take -> 12EDO')
      t.eq(h.cm:getAt('project', 'lastTemperUsed'), '12EDO', 'seed -> 12EDO')
    end,
  },

  ----------------------------------------------------------------
  -- swing: take tier + lastSwingUsed seed
  ----------------------------------------------------------------
  {
    name = 'setSwingSlot writes take tier and lastSwingUsed seed',
    run = function(harness)
      local h = harness.mk{
        config = { project = { swings = { c58 = classic58 } } },
      }
      h.vm:setSwingSlot('c58')
      t.eq(h.cm:getAt('take',    'swing'),         'c58', 'take holds the selection')
      t.eq(h.cm:getAt('project', 'lastSwingUsed'), 'c58', 'project seeds fresh takes')
      t.eq(h.cm:getAt('project', 'swing'),         nil,   'no project-tier mirror of the slot itself')
      t.eq(h.cm:getAt('track',   'swing'),         nil,   'no track-tier mirror either -- per-take')
    end,
  },
  {
    name = 'setSwingSlot(nil) writes the identity sentinel at take and seed',
    run = function(harness)
      local h = harness.mk{ config = { take = { swing = 'c58' } } }
      h.vm:setSwingSlot(nil)
      t.eq(h.cm:getAt('take',    'swing'),         'identity', 'take -> identity')
      t.eq(h.cm:getAt('project', 'lastSwingUsed'), 'identity', 'seed -> identity')
    end,
  },

  ----------------------------------------------------------------
  -- colSwing: track-only, no seed (per-channel maps don't cross tracks)
  ----------------------------------------------------------------
  {
    name = 'setColSwingSlot writes at track only -- project is left alone',
    run = function(harness)
      local h = harness.mk{
        config = { project = { swings = { c58 = classic58 } } },
      }
      h.vm:setColSwingSlot(3, 'c58')
      local trackMap   = h.cm:getAt('track',   'colSwing') or {}
      local projectMap = h.cm:getAt('project', 'colSwing')
      t.eq(trackMap[3], 'c58', 'track holds the per-channel entry')
      t.eq(projectMap, nil,    'project is not mirrored -- no cross-track bleed')
    end,
  },
  {
    name = 'setColSwingSlot preserves entries on other channels',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { c58 = classic58, c67 = classic67 } },
          track   = { colSwing = { [1] = 'c58', [5] = 'c67' } },
        },
      }
      h.vm:setColSwingSlot(3, 'c58')
      local map = h.cm:getAt('track', 'colSwing')
      t.eq(map[1], 'c58', 'channel 1 entry preserved')
      t.eq(map[3], 'c58', 'channel 3 entry written')
      t.eq(map[5], 'c67', 'channel 5 entry preserved')
    end,
  },
  {
    name = 'setColSwingSlot(chan, nil) removes only that channel',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { c58 = classic58, c67 = classic67 } },
          track   = { colSwing = { [1] = 'c58', [3] = 'c58', [5] = 'c67' } },
        },
      }
      h.vm:setColSwingSlot(3, nil)
      local map = h.cm:getAt('track', 'colSwing') or {}
      t.eq(map[1], 'c58', 'siblings survive')
      t.eq(map[3], nil,   'target channel cleared')
      t.eq(map[5], 'c67', 'siblings survive')
    end,
  },

  ----------------------------------------------------------------
  -- Bind-time seed: tv:seedSharedSlots copies last*Used into take tier
  -- for first-encounter takes (created in REAPER outside Continuum, or
  -- pre-existing). No-op when the take already has a value or when no
  -- pick has happened yet.
  ----------------------------------------------------------------
  {
    name = 'seedSharedSlots copies last*Used into take tier when the take has none',
    run = function(harness)
      local h = harness.mk{
        config = { project = { lastSwingUsed = 'c58', lastTemperUsed = '19EDO',
                               swings = { c58 = classic58 },
                               tempers = { ['19EDO'] = tuning.presets['19EDO'] } } },
      }
      h.vm:seedSharedSlots()
      t.eq(h.cm:getAt('take', 'swing'),  'c58',   'swing seeded onto take')
      t.eq(h.cm:getAt('take', 'temper'), '19EDO', 'temper seeded onto take')
    end,
  },
  {
    name = 'seedSharedSlots does not overwrite a deliberate take-tier value',
    run = function(harness)
      local h = harness.mk{
        config = { take    = { swing = 'prior-swing', temper = 'prior-temper' },
                   project = { lastSwingUsed = 'c58', lastTemperUsed = '19EDO' } },
      }
      h.vm:seedSharedSlots()
      t.eq(h.cm:getAt('take', 'swing'),  'prior-swing',  'prior swing preserved')
      t.eq(h.cm:getAt('take', 'temper'), 'prior-temper', 'prior temper preserved')
    end,
  },
  {
    name = 'seedSharedSlots is a no-op when no last*Used has been recorded',
    run = function(harness)
      local h = harness.mk()
      h.vm:seedSharedSlots()
      t.eq(h.cm:getAt('take', 'swing'),  nil, 'no spurious take-tier write')
      t.eq(h.cm:getAt('take', 'temper'), nil, 'no spurious take-tier write')
      t.eq(h.cm:get('swing'),  'identity', 'schema default still surfaces')
      t.eq(h.cm:get('temper'), '12EDO',    'schema default still surfaces')
    end,
  },
}
