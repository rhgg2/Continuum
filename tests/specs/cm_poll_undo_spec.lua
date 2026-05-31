-- Pin-tests for cm:pollUndo -- the per-frame watcher that catches REAPER
-- undo / redo of take + track P_EXT writes. REAPER rewinds P_EXT
-- directly, bypassing cm; without the watcher, cm's cache stays stale
-- and subscribers (toolbar, view layer) keep displaying the post-edit
-- value after a Ctrl-Z.

local t    = require('support')
local util = require('util')

local function bumpState(r) r._state.projStateCount = r._state.projStateCount + 1 end
local function takeExtKey(take) return tostring(take) .. '/P_EXT:ctm_config' end

return {
  {
    name = 'pollUndo refreshes take cache when P_EXT changed under us',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('take', 'pbRange', 4)
      t.eq(h.cm:get('pbRange'), 4, 'cache holds the just-written value')

      -- Simulate REAPER undo: P_EXT reverts to a different serialised form.
      h.reaper._state.takeExt[takeExtKey('take1')] =
        util.serialise({ pbRange = 7 })
      bumpState(h.reaper)

      h.cm:pollUndo()
      t.eq(h.cm:get('pbRange'), 7, 'cache refreshed from the rewound P_EXT')
    end,
  },
  {
    name = 'pollUndo fires configChanged reload on external diff',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('take', 'pbRange', 4)

      local fired
      h.cm:subscribe('configChanged', function(payload) fired = payload end)

      h.reaper._state.takeExt[takeExtKey('take1')] =
        util.serialise({ pbRange = 7 })
      bumpState(h.reaper)
      h.cm:pollUndo()

      t.truthy(fired,        'configChanged fired')
      t.eq(fired.key,   nil, 'payload is the reload shape (no key)')
      t.eq(fired.level, nil, 'payload is the reload shape (no level)')
    end,
  },
  {
    name = 'pollUndo no-ops when state count has not changed',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('take', 'pbRange', 4)

      -- Tamper with P_EXT but do NOT bump the state counter -- the watcher
      -- gates on the counter, so this must be invisible.
      h.reaper._state.takeExt[takeExtKey('take1')] =
        util.serialise({ pbRange = 7 })

      local fired = false
      h.cm:subscribe('configChanged', function() fired = true end)
      h.cm:pollUndo()

      t.falsy(fired,                'no fire without a state-count tick')
      t.eq(h.cm:get('pbRange'), 4, 'cache stays as last written')
    end,
  },
  {
    name = 'pollUndo does not fire when state ticked but our P_EXT is in sync',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('take', 'pbRange', 4)

      -- Some unrelated REAPER edit (e.g. user moved an item) ticks the
      -- state counter but our P_EXT is untouched.
      bumpState(h.reaper)

      local fired = false
      h.cm:subscribe('configChanged', function() fired = true end)
      h.cm:pollUndo()

      t.falsy(fired, 'no fire when our P_EXT is still in sync')
    end,
  },
  {
    -- Take deleted in REAPER: cm's handle goes stale before coord's tick()
    -- ValidatePtr2 watcher fires. Without self-validation, pollUndo crashes.
    name = 'pollUndo drops a stale take handle silently and does not crash',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('take', 'pbRange', 4)
      bumpState(h.reaper)

      local realValidate = h.reaper.ValidatePtr2
      h.reaper.ValidatePtr2 = function(_proj, ptr, ctype)
        if ctype == 'MediaItem_Take*' and ptr == 'take1' then return false end
        return realValidate(_proj, ptr, ctype)
      end

      local fired = false
      h.cm:subscribe('configChanged', function() fired = true end)
      t.truthy(pcall(function() h.cm:pollUndo() end),
        'pollUndo must not crash on a stale take pointer')
      t.falsy(fired,
        'no fire from cm itself; upstream tick() drives the propagation')
    end,
  },
}
