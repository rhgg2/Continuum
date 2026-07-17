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

-- pextStore resolves the global file under reaper.GetResourcePath(); point that
-- at a temp dir so the global-scope tests touch a throwaway, not the real config.
local RESOURCE_DIR = (os.getenv('TMPDIR') or '/tmp'):gsub('/+$', '')
local GLOBAL_PATH  = RESOURCE_DIR .. '/continuum-config.lua'

local function readFile(path)
  local f = io.open(path, 'r'); if not f then return nil end
  local content = f:read('*a'); f:close(); return content
end

local function writeFile(path, content)
  local f = assert(io.open(path, 'w')); f:write(content); f:close()
end

local function freshPs()
  local r = fakeReaper.new()
  _G.reaper = r
  r:bindTake(TAKE, TAKE .. '/item', TRACK)
  r._state.projectTracks[#r._state.projectTracks + 1] = TRACK
  r._state.resourcePath = RESOURCE_DIR
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
      r.ValidatePtr2 = function(proj, ptr, ctype)
        if ctype == 'MediaItem_Take*' and ptr == TAKE then return false end
        return realValidate(proj, ptr, ctype)
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
  {
    name = 'global persists as a hand-editable Lua literal and round-trips',
    run = function()
      local ps = freshPs()
      ps:assign('global', 'config', { pbRange = 2, noteLayout = 'colemak' })
      local onDisk = readFile(GLOBAL_PATH)
      t.truthy(onDisk and onDisk:match('^return'), 'disk blob is a load()-able Lua literal')
      t.deepEq(ps:get('global', 'config'), { pbRange = 2, noteLayout = 'colemak' },
        'round-trips back through prettyUnserialise')
      os.remove(GLOBAL_PATH)
    end,
  },
  {
    name = 'a corrupt global file is read as nil and never clobbered',
    run = function()
      local ps = freshPs()
      writeFile(GLOBAL_PATH, 'return {{{ not lua')
      t.eq(ps:get('global', 'config'), nil, 'unparseable file decodes to nil')
      ps:assign('global', 'config', { pbRange = 9 })
      t.eq(readFile(GLOBAL_PATH), 'return {{{ not lua',
        'the locked file is left intact, not overwritten')
      os.remove(GLOBAL_PATH)
    end,
  },
}
