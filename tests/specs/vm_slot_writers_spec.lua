-- Pin the dual-level write contract for slot selections (temper, swing,
-- colSwing). The view-picker UI depends on:
--   - temper / swing: write at project AND track, so a fresh take on a
--     new track inherits the most recent selection (project), while
--     siblings on an existing track inherit from their track.
--   - colSwing: track-only — per-channel maps shouldn't bleed across
--     tracks via the project mirror.

local t = require('support')
local tuning = require('tuning')

local classic58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }
local classic67 = { factors = { { atom = 'classic', shift = 0.17, period = 1 } } }

return {
  ----------------------------------------------------------------
  -- temper: project + track mirror
  ----------------------------------------------------------------
  {
    name = 'setTemperSlot writes the slot at BOTH project and track',
    run = function(harness)
      local h = harness.mk{
        config = { project = { tempers = { ['19EDO'] = tuning.presets['19EDO'] } } },
      }
      h.vm:setTemperSlot('19EDO')
      t.eq(h.cm:getAt('project', 'temper'), '19EDO', 'project mirror set')
      t.eq(h.cm:getAt('track',   'temper'), '19EDO', 'track  selection set')
    end,
  },
  {
    name = 'setTemperSlot(nil) writes the 12EDO sentinel at BOTH project and track',
    -- Sentinel write (not cm:remove) is what blocks cross-take bleed: a
    -- removed key falls through to whatever the other take last wrote
    -- to project. '12EDO' resolves no-op via tuning.presets.
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { temper = '19EDO',
                      tempers = { ['19EDO'] = tuning.presets['19EDO'] } },
          track   = { temper = '19EDO' },
        },
      }
      h.vm:setTemperSlot(nil)
      t.eq(h.cm:getAt('project', 'temper'), '12EDO', 'project mirror -> 12EDO sentinel')
      t.eq(h.cm:getAt('track',   'temper'), '12EDO', 'track selection -> 12EDO sentinel')
    end,
  },
  {
    name = 'setTemperSlot("") writes the 12EDO sentinel at BOTH project and track',
    run = function(harness)
      local h = harness.mk{
        config = { project = { temper = '19EDO' }, track = { temper = '19EDO' } },
      }
      h.vm:setTemperSlot('')
      t.eq(h.cm:getAt('project', 'temper'), '12EDO', 'project mirror -> 12EDO')
      t.eq(h.cm:getAt('track',   'temper'), '12EDO', 'track selection -> 12EDO')
    end,
  },

  ----------------------------------------------------------------
  -- swing: project + track mirror
  ----------------------------------------------------------------
  {
    name = 'setSwingSlot writes the slot at BOTH project and track',
    run = function(harness)
      local h = harness.mk{
        config = { project = { swings = { c58 = classic58 } } },
      }
      h.vm:setSwingSlot('c58')
      t.eq(h.cm:getAt('project', 'swing'), 'c58', 'project mirror set')
      t.eq(h.cm:getAt('track',   'swing'), 'c58', 'track  selection set')
    end,
  },
  {
    name = 'setSwingSlot(nil) writes the identity sentinel at BOTH project and track',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swing = 'c58', swings = { c58 = classic58 } },
          track   = { swing = 'c58' },
        },
      }
      h.vm:setSwingSlot(nil)
      t.eq(h.cm:getAt('project', 'swing'), 'identity', 'project mirror -> identity sentinel')
      t.eq(h.cm:getAt('track',   'swing'), 'identity', 'track selection -> identity sentinel')
    end,
  },

  ----------------------------------------------------------------
  -- colSwing: track-only, no project mirror
  ----------------------------------------------------------------
  {
    name = 'setColSwingSlot writes at track only — project is left alone',
    run = function(harness)
      local h = harness.mk{
        config = { project = { swings = { c58 = classic58 } } },
      }
      h.vm:setColSwingSlot(3, 'c58')
      local trackMap   = h.cm:getAt('track',   'colSwing') or {}
      local projectMap = h.cm:getAt('project', 'colSwing')
      t.eq(trackMap[3], 'c58', 'track holds the per-channel entry')
      t.eq(projectMap, nil,    'project is not mirrored — no cross-track bleed')
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
  -- Inheritance: the *point* of the project mirror
  ----------------------------------------------------------------
  {
    -- After picking on track A, a fresh track (no track-level value)
    -- should see the most recent selection through the project tier.
    name = 'project mirror lets a track with no own value inherit the most recent pick',
    run = function(harness)
      local h = harness.mk{
        config = { project = { tempers = { ['31EDO'] = tuning.presets['31EDO'] } } },
      }
      h.vm:setTemperSlot('31EDO')

      -- Drop the track-level entry to simulate switching to a track that
      -- has never had an explicit pick. cm:get must fall through to project.
      h.cm:remove('track', 'temper')
      t.eq(h.cm:get('temper'), '31EDO',
           'fresh-track view sees the most recent selection via project')
    end,
  },

  ----------------------------------------------------------------
  -- No-bleed: explicit-off sentinel at the take blocks project-tier
  -- inheritance. This is the bug the sentinel migration exists to fix:
  -- nil-at-tier used to fall through silently, letting another take's
  -- swing pick contaminate a take that had explicitly chosen "Off".
  ----------------------------------------------------------------
  {
    name = 'no-bleed: setSwingSlot(nil) records identity, blocks later project-tier writes',
    run = function(harness)
      local h = harness.mk{
        config = { project = { swings = { ['classic-55'] = classic55 } } },
      }
      h.vm:setSwingSlot(nil)
      t.eq(h.cm:getAt('track', 'swing'), 'identity',
           'Off persisted as identity sentinel at the track tier')
      t.eq(h.cm:getAt('project', 'swing'), 'identity',
           'Off persisted at project tier too (mirroring intact)')

      -- Simulate another take on the same project writing a different swing
      -- to the project tier (this is what tv:setSwingSlot('classic-55') does
      -- when invoked from another take).
      h.cm:set('project', 'swing', 'classic-55')

      t.eq(h.cm:get('swing'), 'identity',
           'track-tier identity sentinel blocks fall-through to project')
    end,
  },
  {
    name = 'no-bleed: setTemperSlot(nil) records 12EDO, blocks later project-tier writes',
    run = function(harness)
      local h = harness.mk{
        config = { project = { tempers = { ['31EDO'] = tuning.presets['31EDO'] } } },
      }
      h.vm:setTemperSlot(nil)
      t.eq(h.cm:getAt('track', 'temper'), '12EDO',
           '12EDO sentinel at track tier')

      h.cm:set('project', 'temper', '31EDO')

      t.eq(h.cm:get('temper'), '12EDO',
           'track-tier 12EDO blocks fall-through to project')
    end,
  },
}
