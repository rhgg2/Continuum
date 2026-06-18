-- Pin-tests for configManager's schema enforcement and ownership contract.
-- Covers: unknown-key rejection at every API entry; silent prune of unknown
-- keys on persistence load; deep-copy at read AND write boundaries so
-- callers never alias cm's internal state.

local t = require('support')
local util = require('util')

return {
  --------------------------------------------------------------------
  -- Unknown-key rejection at the API boundary
  --------------------------------------------------------------------
  {
    name = 'cm:get on an unknown key raises',
    run = function(harness)
      local h = harness.mk()
      local ok, err = pcall(function() h.cm:get('nonsense') end)
      t.falsy(ok, 'get should raise on unknown key')
      t.truthy(tostring(err):find('nonsense'), 'error mentions the key, got: ' .. tostring(err))
    end,
  },
  {
    name = 'cm:set on an unknown key raises',
    run = function(harness)
      local h = harness.mk()
      local ok = pcall(function() h.cm:set('take', 'nonsense', 1) end)
      t.falsy(ok, 'set should raise on unknown key')
    end,
  },
  {
    name = 'take-tier write with no bound take is a silent no-op (dormant seam)',
    run = function(harness)
      local h = harness.mk()
      h.cm:setContext(nil)  -- bindTake(nil) dormant seam: no take context
      local said = {}
      local realPrint = _G.print
      _G.print = function(...) said[#said + 1] = table.concat({ ... }, ' ') end
      local ok = pcall(function() h.cm:set('take', 'tempers', { a = true }) end)
      _G.print = realPrint
      t.truthy(ok, 'no-take take-tier write must not raise')
      for _, line in ipairs(said) do
        t.falsy(line:find('No take context'),
          'must not log a lost-write error; derived take config is benign')
      end
    end,
  },
  {
    name = 'cm:remove on an unknown key raises',
    run = function(harness)
      local h = harness.mk()
      local ok = pcall(function() h.cm:remove('take', 'nonsense') end)
      t.falsy(ok, 'remove should raise on unknown key')
    end,
  },
  {
    name = 'cm:assign rejects updates that contain unknown keys',
    run = function(harness)
      local h = harness.mk()
      local ok = pcall(function()
        h.cm:assign('take', { pbRange = 4, nonsense = 1 })
      end)
      t.falsy(ok, 'assign should raise if any update key is unknown')
      -- And the partial update must not have been applied.
      t.eq(h.cm:get('pbRange'), 2, 'schema default survives rejected assign')
    end,
  },
  {
    name = 'cm:getAt on an unknown key raises',
    run = function(harness)
      local h = harness.mk()
      local ok = pcall(function() h.cm:getAt('take', 'nonsense') end)
      t.falsy(ok, 'getAt with unknown key should raise')
    end,
  },
  {
    name = 'cm:getAt full-level read does not require a key',
    run = function(harness)
      local h = harness.mk{
        config = { take = { pbRange = 7 } },
      }
      local tbl = h.cm:getAt('take')
      t.eq(tbl.pbRange, 7, 'full-level read returns the cache for that level')
    end,
  },

  --------------------------------------------------------------------
  -- Schema defaults are the source of truth
  --------------------------------------------------------------------
  {
    -- Pin the mechanism (no level has set → schema default surfaces) on
    -- one structurally-meaningful key. pbRange feeds detune/pb arithmetic
    -- downstream, so its default leaking would break unrelated tests
    -- loudly. Other defaults (defaultVelocity, noteLayout, …) are UX
    -- choices and shouldn't be pinned here — that just makes tests fight
    -- with everyday tweaks.
    name = 'schema default surfaces when no level has set the key',
    run = function(harness)
      local h = harness.mk()
      t.eq(h.cm:get('pbRange'), 2, 'pbRange default surfaces with no level set')
    end,
  },
  {
    name = 'null-defaulted keys are declared but return nil',
    run = function(harness)
      local h = harness.mk()
      -- 'sampleBrowserRoot' is null-defaulted. Real global state can leak
      -- into the harness, so first clear all tiers, then verify the schema
      -- declaration surfaces as nil rather than raising.
      for _, level in ipairs({'global', 'project', 'track', 'take', 'transient'}) do
        pcall(function() h.cm:remove(level, 'sampleBrowserRoot') end)
      end
      local ok, v = pcall(function() return h.cm:get('sampleBrowserRoot') end)
      t.truthy(ok,  'get on null-defaulted key does not raise')
      t.eq(v, nil, 'null-defaulted key returns nil when no tier has set it')
    end,
  },

  --------------------------------------------------------------------
  -- Persistence load silently prunes unknown keys
  --------------------------------------------------------------------
  {
    -- A user's on-disk take may carry stale keys from a rename; we must
    -- be tolerant at load. Write raw ext-state that includes a stale key,
    -- then build a fresh cm and confirm it survives and has only declared
    -- keys in its cache.
    name = 'unknown keys in persisted data are pruned on load',
    run = function(harness)
      local h = harness.mk()
      -- Reach directly at the fake reaper's take ext-state to plant a
      -- stale key alongside a valid one.
      local serialised = util.serialise({ pbRange = 5, legacyKey = 'oops' })
      local take = 'take1'
      h.reaper._state.takeExt[take .. '/P_EXT:ctm_config'] = serialised

      -- Fresh cm sharing the same reaper state.
      local cm2 = util.instantiate('configManager', { ps = util.instantiate('pextStore') })
      cm2:setContext(take)
      t.eq(cm2:get('pbRange'), 5, 'known key survived the load')
      local ok = pcall(function() return cm2:get('legacyKey') end)
      t.falsy(ok, 'stale key is not reachable through get (would raise if tried)')
      -- And a write to an unrelated valid key must not resurrect legacyKey.
      cm2:set('take', 'rowPerBeat', 9)
      local raw = h.reaper._state.takeExt[take .. '/P_EXT:ctm_config']
      t.falsy(raw:find('legacyKey'), 'legacyKey was pruned on load and did not round-trip: ' .. raw)
    end,
  },

  --------------------------------------------------------------------
  -- Ownership: cm:get returns a fresh deep copy
  --------------------------------------------------------------------
  {
    name = 'cm:get returns a deep copy — caller mutation does not leak',
    run = function(harness)
      local h = harness.mk{
        config = { take = { tempers = { [1] = { notes = 2 } } } },
      }
      local a = h.cm:get('tempers')
      a[1].notes = 999
      a[5] = { notes = 7 }
      local b = h.cm:get('tempers')
      t.eq(b[1].notes, 2,   'inner field is independent across get calls')
      t.eq(b[5], nil,       'outer key added by caller does not appear in cm')
    end,
  },
  {
    name = 'cm:get of a default table returns a fresh table each call',
    run = function(harness)
      local h = harness.mk()
      local a = h.cm:get('tempers')
      a[3] = { notes = 1 }
      local b = h.cm:get('tempers')
      t.eq(b[3], nil, 'mutation of one get return does not pollute the default')
    end,
  },
  {
    name = 'cm:set deep-copies the incoming value — caller mutation after set does not leak',
    run = function(harness)
      local h = harness.mk()
      local outer = { [1] = { notes = 3 } }
      h.cm:set('take', 'tempers', outer)
      outer[1].notes = 999
      outer[7] = { notes = 1 }
      local stored = h.cm:get('tempers')
      t.eq(stored[1].notes, 3, 'cm kept its own copy; post-set mutation by caller did not leak')
      t.eq(stored[7], nil,     'post-set addition by caller did not leak')
    end,
  },

  --------------------------------------------------------------------
  -- Level merge still works
  --------------------------------------------------------------------
  {
    name = 'more specific level overrides less specific',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { pbRange = 3 },
          take    = { pbRange = 5 },
        },
      }
      t.eq(h.cm:get('pbRange'), 5, 'take overrides project')
    end,
  },
  {
    name = 'remove at a level falls back to the next less-specific level',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { pbRange = 3 },
          take    = { pbRange = 5 },
        },
      }
      h.cm:remove('take', 'pbRange')
      t.eq(h.cm:get('pbRange'), 3, 'after take remove, project value is effective')
      h.cm:remove('project', 'pbRange')
      t.eq(h.cm:get('pbRange'), 2, 'after project remove, schema default is effective')
    end,
  },

  --------------------------------------------------------------------
  -- transient tier: most-specific, never persisted
  --------------------------------------------------------------------
  {
    name = 'transient is the most-specific level (overrides take)',
    run = function(harness)
      local h = harness.mk{
        config = {
          take      = { pbRange = 5 },
          transient = { pbRange = 7 },
        },
      }
      t.eq(h.cm:get('pbRange'), 7, 'transient overrides take')
      h.cm:remove('transient', 'pbRange')
      t.eq(h.cm:get('pbRange'), 5, 'after transient remove, take value is effective')
    end,
  },
  {
    name = 'transient writes do not persist across cm reconstruction',
    run = function(harness)
      local h = harness.mk{
        config = { take = { pbRange = 5 } },
      }
      h.cm:set('transient', 'pbRange', 9)
      t.eq(h.cm:get('pbRange'), 9, 'transient write is visible on this cm')
      -- Rebuild a cm against the same take: persisted tiers reload from
      -- ext-state, transient must come up empty.
      local cm2 = util.instantiate('configManager', { ps = util.instantiate('pextStore') })
      cm2:setContext('take1')
      t.eq(cm2:get('pbRange'), 5, 'fresh cm sees take but no transient leak')
      t.eq(cm2:getAt('transient', 'pbRange'), nil, 'transient cache is empty on reload')
    end,
  },
  --------------------------------------------------------------------
  -- clearTake / setTrack: take-independent context for sample view
  --------------------------------------------------------------------
  {
    name = 'clearTake empties take cache; lower tiers and track tier survive',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { pbRange = 3 },
          track   = { pbRange = 4 },
          take    = { pbRange = 5 },
        },
      }
      t.eq(h.cm:get('pbRange'), 5, 'take wins to begin with')
      h.cm:clearTake()
      t.eq(h.cm:get('pbRange'), 4, 'after clearTake, track tier is effective')
      t.eq(h.cm:getAt('take', 'pbRange'), nil, 'take cache is empty')
      t.eq(h.cm:getAt('track', 'pbRange'), 4, 'track cache survives')
      t.eq(h.cm:getAt('project', 'pbRange'), 3, 'project cache survives')
    end,
  },
  {
    name = 'setTrack rebinds the track tier to a different track\'s P_EXT',
    run = function(harness)
      local h = harness.mk{
        config = { track = { pbRange = 4 } },
      }
      -- Plant a different value on a second track via raw ext-state.
      local otherTrack = 'other/track'
      h.reaper._state.trackExt[otherTrack .. '/P_EXT:ctm_config'] =
        util.serialise({ pbRange = 9 })

      t.eq(h.cm:getAt('track', 'pbRange'), 4, 'track1 value initially')
      h.cm:setTrack(otherTrack)
      t.eq(h.cm:getAt('track', 'pbRange'), 9, 'track-tier now reflects otherTrack')
    end,
  },
  {
    name = 'setTrack is independent of take — take cache stays put',
    run = function(harness)
      local h = harness.mk{
        config = { take = { pbRange = 5 } },
      }
      h.cm:setTrack('some/other/track')
      t.eq(h.cm:getAt('take', 'pbRange'), 5, 'take cache untouched by setTrack')
    end,
  },
  {
    name = 'clearTake and setTrack both fire configChanged (keyless)',
    run = function(harness)
      local h = harness.mk()
      local seen = {}
      h.cm:subscribe('configChanged', function(d) seen[#seen+1] = d end)
      h.cm:clearTake()
      h.cm:setTrack('another/track')
      t.eq(#seen, 2,            'two broadcasts')
      t.eq(seen[1].key,   nil,  'clearTake carries no key')
      t.eq(seen[1].level, nil,  'clearTake carries no level')
      t.eq(seen[2].key,   nil,  'setTrack carries no key')
      t.eq(seen[2].level, nil,  'setTrack carries no level')
    end,
  },

  --------------------------------------------------------------------
  -- mergeTiers: per-subkey union across defaults + tiers
  --
  -- These specs use project/take rather than global because the
  -- 'global' tier persists through real io.open (CONFIG_GLOBAL_PATH);
  -- the fake reaper covers project/track/take only. Merge semantics
  -- are identical across tiers, so this loses no coverage.
  --------------------------------------------------------------------
  {
    -- Without the flag, take's table-value replaces project's
    -- entirely (the existing whole-value overlay). With the flag,
    -- entries union per sub-key. This is the read-path libraries
    -- like swings/tempers rely on once presets live in the global
    -- tier and users save their own project-tier swings.
    name = 'mergeTiers unions tier tables per sub-key',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { a = { tag = 'p-a' }, b = { tag = 'p-b' } } },
          take    = { swings = { b = { tag = 't-b' }, c = { tag = 't-c' } } },
        },
      }
      -- Default semantics: take replaces project wholesale.
      local plain = h.cm:get('swings')
      t.eq(plain.a, nil,        'plain get: take shadows project')
      t.eq(plain.b.tag, 't-b',  'plain get: take value present')
      t.eq(plain.c.tag, 't-c',  'plain get: take value present')

      -- Merged semantics: per-sub-key union, more-specific wins.
      local merged = h.cm:get('swings', { mergeTiers = true })
      t.eq(merged.a.tag, 'p-a', 'merged: project-only entry surfaces')
      t.eq(merged.b.tag, 't-b', 'merged: take wins on collision')
      t.eq(merged.c.tag, 't-c', 'merged: take-only entry present')
    end,
  },
  {
    name = 'mergeTiers returns a fresh deep copy',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { a = { tag = 'p-a' } } },
          take    = { swings = { b = { tag = 't-b' } } },
        },
      }
      local a = h.cm:get('swings', { mergeTiers = true })
      a.a.tag = 'mutated'
      a.zzz = { tag = 'new' }
      local b = h.cm:get('swings', { mergeTiers = true })
      t.eq(b.a.tag, 'p-a', 'inner field is independent across calls')
      t.eq(b.zzz, nil,     'top-level mutation does not leak')
    end,
  },
  {
    name = 'mergeTiers with no tier contributions returns the schema default',
    -- swings carries a non-empty default (the system preset catalogue).
    -- A fresh harness with no tier writes must surface those entries
    -- through the merged read — this is what makes presets-as-default
    -- visible to every project.
    run = function(harness)
      local h = harness.mk()
      local merged = h.cm:get('swings', { mergeTiers = true })
      t.truthy(merged['classic-58'],
        'classic-58 default surfaces under merge with no tier writes')
    end,
  },
  {
    name = 'mergeTiers default + tier writes union per sub-key',
    run = function(harness)
      local h = harness.mk{
        config = { project = { swings = { ['my-groove'] = { tag = 'p' } } } },
      }
      local merged = h.cm:get('swings', { mergeTiers = true })
      t.truthy(merged['classic-58'],    'default preset still present')
      t.eq(merged['my-groove'].tag, 'p','project entry present')
    end,
  },
  {
    name = 'mergeTiers: tier write on a default-named key wins',
    run = function(harness)
      local h = harness.mk{
        config = { project = { swings = { ['classic-58'] = { tag = 'override' } } } },
      }
      local merged = h.cm:get('swings', { mergeTiers = true })
      t.eq(merged['classic-58'].tag, 'override',
        'project override beats default for the same name')
      t.truthy(merged['classic-55'],
        'other defaults untouched by overlapping override')
    end,
  },

  -- seedGlobalFromDefault: lazily materialise the global library from the
  -- catalogue the first time it is read; synthetic floor (identity/12EDO) excluded.
  {
    name = 'cm:seedGlobalFromDefault seeds the global library from the catalogue when empty',
    run = function(harness)
      local h = harness.mk()
      t.eq(next(h.cm:getAt('global', 'swings') or {}), nil, 'global swings starts empty')
      h.cm:seedGlobalFromDefault('swings', { identity = true })
      local g = h.cm:getAt('global', 'swings')
      t.truthy(g['classic-58'], 'a catalogue preset is now a global entry')
      t.eq(g['identity'], nil,  'the synthetic floor is excluded from the seed')
    end,
  },
  {
    name = 'cm:seedGlobalFromDefault is a no-op once the global library exists',
    run = function(harness)
      local h = harness.mk{ config = { global = { swings = { mine = { factors = {} } } } } }
      h.cm:seedGlobalFromDefault('swings', { identity = true })
      local g = h.cm:getAt('global', 'swings')
      t.eq(g['classic-58'], nil, 'catalogue not injected over a populated library')
      t.truthy(g['mine'],        'the existing entry survives untouched')
    end,
  },
  {
    name = 'cm:seedGlobalFromDefault seeds tempers from the EDO catalogue',
    run = function(harness)
      local h = harness.mk()
      h.cm:seedGlobalFromDefault('tempers', { ['12EDO'] = true })
      local g = h.cm:getAt('global', 'tempers')
      t.truthy(g['19EDO'], 'an EDO preset is now a global temper')
      t.eq(g['12EDO'], nil, 'the synthetic floor is excluded')
    end,
  },

  {
    name = 'cm fires changes with their level on the broadcast',
    run = function(harness)
      local h = harness.mk()
      local seen = {}
      h.cm:subscribe('configChanged', function(changed) table.insert(seen, changed) end)
      h.cm:set('take', 'pbRange', 4)
      h.cm:remove('take', 'pbRange')
      h.cm:assign('transient', { pbRange = 3 })
      t.eq(seen[1].level, 'take',      'set carries level=take')
      t.eq(seen[1].key,   'pbRange',   'set carries key=pbRange')
      t.eq(seen[2].level, 'take',      'remove carries level=take')
      t.eq(seen[3].level, 'transient', 'assign carries level=transient')
      t.eq(seen[3].key,   nil,         'assign has no key (keyless broadcast)')
    end,
  },
}
