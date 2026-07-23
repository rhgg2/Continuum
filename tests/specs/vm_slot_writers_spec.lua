-- Pin the swing/temper slot-write contract: swing is the take's document-data map
-- (defaultSwing is the config seed); temper is a view-only multi-tier config key.

local t = require('support')
local tuning = require('tuning')

local classic58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }
local classic67 = { factors = { { atom = 'classic', shift = 0.17, period = 1 } } }

return {
  ----- temper: one view-only key written across take, track and project
  {
    name = 'setTemperSlot writes the pick to take, track and project tiers',
    run = function(harness)
      local h = harness.mk{
        config = { project = { tempers = { ['19EDO'] = tuning.presets['19EDO'] } } },
      }
      h.vm:setTemperSlot('19EDO')
      t.eq(h.cm:getAt('take',    'temper'), '19EDO', 'take freezes this take\'s pick')
      t.eq(h.cm:getAt('track',   'temper'), '19EDO', 'track carries the rolling default')
      t.eq(h.cm:getAt('project', 'temper'), '19EDO', 'project carries the rolling default')
    end,
  },
  {
    name = 'setTemperSlot(nil) writes the 12EDO sentinel across the tiers',
    run = function(harness)
      local h = harness.mk{ config = { take = { temper = '19EDO' } } }
      h.vm:setTemperSlot(nil)
      t.eq(h.cm:getAt('take',    'temper'), '12EDO', 'take -> 12EDO sentinel')
      t.eq(h.cm:getAt('project', 'temper'), '12EDO', 'project -> 12EDO sentinel')
    end,
  },
  {
    name = 'setTemperSlot("") writes the 12EDO sentinel across the tiers',
    run = function(harness)
      local h = harness.mk{ config = { take = { temper = '19EDO' } } }
      h.vm:setTemperSlot('')
      t.eq(h.cm:getAt('take',  'temper'), '12EDO', 'take -> 12EDO')
      t.eq(h.cm:getAt('track', 'temper'), '12EDO', 'track -> 12EDO')
    end,
  },
  {
    name = 'setTemperSlot localizes a catalogue temper into the project library',
    run = function(harness)
      local h = harness.mk()   -- 19EDO lives in the factory catalogue, not in project
      t.eq((h.cm:getAt('project', 'tempers') or {})['19EDO'], nil, 'absent from project to start')
      h.vm:setTemperSlot('19EDO')
      t.truthy(h.cm:getAt('project', 'tempers')['19EDO'], 'the resolved temper is copied into project')
    end,
  },
  {
    name = 'setTemperSlot(nil) never localizes the 12EDO floor',
    run = function(harness)
      local h = harness.mk()
      h.vm:setTemperSlot(nil)
      t.eq((h.cm:getAt('project', 'tempers') or {})['12EDO'], nil, '12EDO stays synthetic')
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
    name = 'setSwingSlot localizes a catalogue preset into the project library',
    run = function(harness)
      local h = harness.mk()   -- classic-58 lives in the catalogue, not in project
      t.eq((h.cm:getAt('project', 'swings') or {})['classic-58'], nil, 'absent from project to start')
      h.vm:setSwingSlot('classic-58')
      local composite = h.cm:getAt('project', 'swings')['classic-58']
      t.truthy(composite and composite.factors, 'the resolved composite is copied into project')
    end,
  },
  {
    name = 'setSwingSlot(nil) never localizes the identity floor',
    run = function(harness)
      local h = harness.mk()
      h.vm:setSwingSlot(nil)
      t.eq((h.cm:getAt('project', 'swings') or {})['identity'], nil, 'identity stays synthetic')
    end,
  },
  {
    name = 'setColSwingSlot localizes a catalogue preset into the project library',
    run = function(harness)
      local h = harness.mk()
      h.vm:setColSwingSlot(3, 'classic-58')
      t.truthy(h.cm:getAt('project', 'swings')['classic-58'], 'channel pick localizes too')
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
  -- Bind-time seed: tv:seedSharedSlots copies defaultSwing into a fresh take's swing map
  {
    name = 'seedSharedSlots copies defaultSwing into a fresh take\'s swing map',
    run = function(harness)
      local h = harness.mk{
        config = { project = { defaultSwing = { global = 'c58' },
                               swings = { c58 = classic58 } } },
      }
      h.vm:seedSharedSlots()
      t.eq(h.ds:get('swing').global, 'c58', 'swing seeded onto the take map')
    end,
  },
  {
    name = 'seedSharedSlots does not overwrite a take that already has a swing map',
    run = function(harness)
      local h = harness.mk{
        config = { project = { defaultSwing = { global = 'c58' } } },
        data   = { swing = { global = 'prior-swing' } },
      }
      h.vm:seedSharedSlots()
      t.eq(h.ds:get('swing').global, 'prior-swing', 'prior swing preserved')
    end,
  },
  {
    name = 'seedSharedSlots materialises the identity floor when no seed tier is set',
    run = function(harness)
      local h = harness.mk()
      h.vm:seedSharedSlots()
      t.eq(h.ds:get('swing').global, 'identity', 'unseeded take is pinned to Off, not left nil')
    end,
  },
  {
    -- Regression: Off take must not inherit a later-written default; materialising
    -- identity on first bind is what makes the no-op guard block every rebind.
    name = 'seedSharedSlots: a take left at Off is not re-seeded after the default changes',
    run = function(harness)
      local h = harness.mk()
      h.vm:seedSharedSlots()                                   -- first bind: Off materialised
      h.cm:set('project', 'defaultSwing', { global = 'c58' })  -- another take picks a swing
      h.cm:set('track',   'defaultSwing', { global = 'c58' })
      h.vm:seedSharedSlots()                                   -- rebind the Off take
      t.eq(h.ds:get('swing').global, 'identity', 'Off sticks; default pollution ignored')
    end,
  },
}
