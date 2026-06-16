-- Pin the swing/temper slot-write contract: swing is the take's document-data
-- map; defaultSwing/lastTemperUsed are the config seeds tv:seedSharedSlots copies in.

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
  -- swing: take map 'global' slot + defaultSwing seed at project & track
  {
    name = 'setSwingSlot writes the take map global slot and seeds defaultSwing at project + track',
    run = function(harness)
      local h = harness.mk{
        config = { project = { swings = { c58 = classic58 } } },
      }
      h.vm:setSwingSlot('c58')
      t.eq(h.ds:get('swing').global,                     'c58', 'take map holds the take-wide swing')
      t.eq(h.cm:getAt('project', 'defaultSwing').global, 'c58', 'project seed records it')
      t.eq(h.cm:getAt('track',   'defaultSwing').global, 'c58', 'track seed records it')
    end,
  },
  {
    name = 'setSwingSlot(nil) writes the identity sentinel into the take map and seed',
    run = function(harness)
      local h = harness.mk{ data = { swing = { global = 'c58' } } }
      h.vm:setSwingSlot(nil)
      t.eq(h.ds:get('swing').global,                     'identity', 'take map -> identity')
      t.eq(h.cm:getAt('project', 'defaultSwing').global, 'identity', 'seed -> identity')
    end,
  },

  ----------------------------------------------------------------
  -- per-channel swing: take map channel slot + track seed only (project never carries per-channel)
  {
    name = 'setColSwingSlot writes the channel into the take map and the track seed only',
    run = function(harness)
      local h = harness.mk{
        config = { project = { swings = { c58 = classic58 } } },
      }
      h.vm:setColSwingSlot(3, 'c58')
      t.eq(h.ds:get('swing')[3],                           'c58', 'take map holds the per-channel entry')
      t.eq((h.cm:getAt('track', 'defaultSwing') or {})[3], 'c58', 'track seed records the channel')
      t.eq(h.cm:getAt('project', 'defaultSwing'),          nil,   'project seed untouched -- no cross-track bleed')
    end,
  },
  {
    name = 'setColSwingSlot preserves entries on other channels',
    run = function(harness)
      local h = harness.mk{
        config = { project = { swings = { c58 = classic58, c67 = classic67 } } },
        data   = { swing = { [1] = 'c58', [5] = 'c67' } },
      }
      h.vm:setColSwingSlot(3, 'c58')
      local map = h.ds:get('swing')
      t.eq(map[1], 'c58', 'channel 1 entry preserved')
      t.eq(map[3], 'c58', 'channel 3 entry written')
      t.eq(map[5], 'c67', 'channel 5 entry preserved')
    end,
  },
  {
    name = 'setColSwingSlot(chan, nil) removes only that channel',
    run = function(harness)
      local h = harness.mk{
        config = { project = { swings = { c58 = classic58, c67 = classic67 } } },
        data   = { swing = { [1] = 'c58', [3] = 'c58', [5] = 'c67' } },
      }
      h.vm:setColSwingSlot(3, nil)
      local map = h.ds:get('swing') or {}
      t.eq(map[1], 'c58', 'siblings survive')
      t.eq(map[3], nil,   'target channel cleared')
      t.eq(map[5], 'c67', 'siblings survive')
    end,
  },

  ----------------------------------------------------------------
  -- Bind-time seed: tv:seedSharedSlots copies defaultSwing/lastTemperUsed into a fresh take
  {
    name = 'seedSharedSlots copies defaultSwing/lastTemperUsed into a fresh take',
    run = function(harness)
      local h = harness.mk{
        config = { project = { defaultSwing = { global = 'c58' }, lastTemperUsed = '19EDO',
                               swings = { c58 = classic58 },
                               tempers = { ['19EDO'] = tuning.presets['19EDO'] } } },
      }
      h.vm:seedSharedSlots()
      t.eq(h.ds:get('swing').global,     'c58',   'swing seeded onto the take map')
      t.eq(h.cm:getAt('take', 'temper'), '19EDO', 'temper seeded onto take')
    end,
  },
  {
    name = 'seedSharedSlots does not overwrite a take that already has swing/temper',
    run = function(harness)
      local h = harness.mk{
        config = { take    = { temper = 'prior-temper' },
                   project = { defaultSwing = { global = 'c58' }, lastTemperUsed = '19EDO' } },
        data   = { swing = { global = 'prior-swing' } },
      }
      h.vm:seedSharedSlots()
      t.eq(h.ds:get('swing').global,     'prior-swing',  'prior swing preserved')
      t.eq(h.cm:getAt('take', 'temper'), 'prior-temper', 'prior temper preserved')
    end,
  },
  {
    name = 'seedSharedSlots is a no-op when no seed tier has been recorded',
    run = function(harness)
      local h = harness.mk()
      h.vm:seedSharedSlots()
      t.eq(h.ds:get('swing'),            nil, 'no spurious swing map written')
      t.eq(h.cm:getAt('take', 'temper'), nil, 'no spurious temper write')
      t.eq(h.cm:get('temper'), '12EDO', 'schema default still surfaces')
    end,
  },
}
