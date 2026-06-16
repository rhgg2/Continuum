-- Pin-tests for pextStore -- the storage + context + undo engine extracted
-- from configManager. These exercise the engine directly (no schema face):
-- context binding, raw round-trip per backend, and the state-count watcher
-- that catches REAPER undo/redo rewriting P_EXT under us.

local t          = require('support')
local util       = require('util')
local fakeReaper = require('fakeReaper')

local TAKE  = 'pk_take'
local TRACK = 'pk_track'
local SLOT  = 'ctm_config'
local takeExtKey = TAKE .. '/P_EXT:' .. SLOT

local function freshPs()
  local r = fakeReaper.new()
  _G.reaper = r
  r:bindTake(TAKE, TAKE .. '/item', TRACK)
  r._state.projectTracks[#r._state.projectTracks + 1] = TRACK
  local ps = util.instantiate('pextStore')
  ps:setTake(TAKE)
  return ps, r
end

local function bump(r) r._state.projStateCount = r._state.projStateCount + 1 end

return {
  {
    name = 'setTake derives the track from the take item',
    run = function()
      local ps = freshPs()
      t.eq(ps:boundTake(),  TAKE,  'bound take is the one we set')
      t.eq(ps:boundTrack(), TRACK, 'track derived via GetMediaItemTrack')
    end,
  },
  {
    name = 'setTake(nil) clears both take and track',
    run = function()
      local ps = freshPs()
      ps:setTake(nil)
      t.eq(ps:boundTake(),  nil, 'take cleared')
      t.eq(ps:boundTrack(), nil, 'track cleared')
    end,
  },
  {
    name = 'assign / get round-trips each backend scope',
    run = function()
      local ps = freshPs()
      for _, scope in ipairs({ 'take', 'track', 'project', 'global' }) do
        ps:assign(scope, SLOT, { mark = scope, n = 3 })
        t.deepEq(ps:get(scope, SLOT), { mark = scope, n = 3 },
          scope .. ' round-trips through its backend')
      end
    end,
  },
  {
    name = 'get returns nil for an absent blob',
    run = function()
      local ps = freshPs()
      t.eq(ps:get('take', SLOT), nil, 'unset take blob decodes to nil')
    end,
  },
  {
    name = 'getAt / assignAt address a foreign handle',
    run = function()
      local ps = freshPs()
      ps:assignAt('other_take', 'take', SLOT, { from = 'foreign' })
      t.deepEq(ps:getAt('other_take', 'take', SLOT), { from = 'foreign' },
        'foreign-handle write reads back at that handle')
      t.eq(ps:get('take', SLOT), nil, 'bound take untouched by the foreign write')
    end,
  },
  {
    name = 'watcher fires onDiverge for an externally rewritten blob',
    run = function()
      local ps, r = freshPs()
      local fired
      ps:watch({ { scope = 'take', slot = SLOT } },
               function(diverged) fired = diverged end)

      r._state.takeExt[takeExtKey] = util.serialise({ pbRange = 7 })
      bump(r)
      ps:pollUndo()

      t.truthy(fired, 'onDiverge fired')
      t.eq(#fired, 1, 'one blob diverged')
      t.eq(fired[1].scope, 'take', 'the diverged blob is the take blob')
    end,
  },
  {
    name = 'watcher does not fire without a state-count tick',
    run = function()
      local ps, r = freshPs()
      local fired = false
      ps:watch({ { scope = 'take', slot = SLOT } }, function() fired = true end)

      r._state.takeExt[takeExtKey] = util.serialise({ pbRange = 7 })  -- no bump
      ps:pollUndo()

      t.falsy(fired, 'gated on the state counter')
    end,
  },
  {
    name = 'watcher does not fire when the blob is still in sync',
    run = function()
      local ps, r = freshPs()
      local fired = false
      ps:watch({ { scope = 'take', slot = SLOT } }, function() fired = true end)

      bump(r)  -- some unrelated edit ticks the counter
      ps:pollUndo()

      t.falsy(fired, 'no fire when our blob is unchanged')
    end,
  },
  {
    name = 'a bound assign updates the baseline so our own write never self-triggers',
    run = function()
      local ps, r = freshPs()
      local fired = false
      ps:watch({ { scope = 'take', slot = SLOT } }, function() fired = true end)

      ps:assign('take', SLOT, { pbRange = 4 })
      bump(r)
      ps:pollUndo()

      t.falsy(fired, 'baseline tracked our write')
    end,
  },
  {
    name = 'a stale take handle is dropped silently with no fire',
    run = function()
      local ps, r = freshPs()
      ps:assign('take', SLOT, { pbRange = 4 })
      local fired = false
      ps:watch({ { scope = 'take', slot = SLOT } }, function() fired = true end)

      local realValidate = r.ValidatePtr2
      r.ValidatePtr2 = function(_proj, ptr, ctype)
        if ctype == 'MediaItem_Take*' and ptr == TAKE then return false end
        return realValidate(_proj, ptr, ctype)
      end

      bump(r)
      t.truthy(pcall(function() ps:pollUndo() end), 'pollUndo must not crash')
      t.falsy(fired, 'dropping a dead handle is not an external diff')
      t.eq(ps:boundTake(), nil, 'the stale take is cleared')
    end,
  },
  {
    name = 'a group with two diverged blobs fires onDiverge once',
    run = function()
      local ps, r = freshPs()
      local calls, lastCount = 0, 0
      ps:watch({ { scope = 'take', slot = SLOT }, { scope = 'track', slot = SLOT } },
               function(diverged) calls = calls + 1; lastCount = #diverged end)

      r._state.takeExt[takeExtKey]            = util.serialise({ pbRange = 7 })
      r._state.trackExt[TRACK .. '/P_EXT:' .. SLOT] = util.serialise({ pbRange = 9 })
      bump(r)
      ps:pollUndo()

      t.eq(calls, 1,     'the group callback fires exactly once')
      t.eq(lastCount, 2, 'both blobs reported in the one fire')
    end,
  },
}
