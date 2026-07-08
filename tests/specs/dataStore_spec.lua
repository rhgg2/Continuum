-- Pin-tests for dataStore -- the per-key document face over pextStore, exercised
-- in isolation (no configManager). Covers registry-scoped round-trips, the
-- continuum-data.lua global file, foreign-handle access, the dataChanged signal,
-- undo divergence, and context-rebind cache drops.

local t          = require('support')
local util       = require('util')
local fakeReaper = require('fakeReaper')

local TAKE  = 'ds_take'
local TRACK = 'ds_track'

-- dataStore's global file resolves under reaper.GetResourcePath(); point that at a
-- temp dir so the global-scope tests touch a throwaway, not the real continuum-data.
local RESOURCE_DIR = (os.getenv('TMPDIR') or '/tmp'):gsub('/+$', '')
local DATA_PATH    = RESOURCE_DIR .. '/continuum-data.lua'

local function readFile(path)
  local f = io.open(path, 'r'); if not f then return nil end
  local c = f:read('*a'); f:close(); return c
end

local function freshDs()
  local r = fakeReaper.new()
  _G.reaper = r
  r:bindTake(TAKE, TAKE .. '/item', TRACK)
  r._state.projectTracks[#r._state.projectTracks + 1] = TRACK
  r._state.resourcePath = RESOURCE_DIR
  os.remove(DATA_PATH)
  local ps = util.instantiate('pextStore')
  local ds = util.instantiate('dataStore', { ps = ps })
  ps:setTake(TAKE)
  return ds, ps, r
end

local function bump(r) r._state.projStateCount = r._state.projStateCount + 1 end

return {
  {
    name = 'assign / get round-trips each scope through its backend',
    run = function()
      local ds = freshDs()
      ds:assign('groups',         { a = 1 })     -- take
      ds:assign('slotEntries',    { 'x' })       -- track
      ds:assign('arrangeColours', { [7] = 3 })   -- project
      ds:assign('fxPatterns',     { p1 = { kind = 'notes' } })  -- project
      ds:assign('paramFrecency',  { p = 9 })     -- global
      t.deepEq(ds:get('groups'),         { a = 1 },   'take key round-trips')
      t.deepEq(ds:get('slotEntries'),    { 'x' },     'track key round-trips')
      t.deepEq(ds:get('arrangeColours'), { [7] = 3 }, 'project key round-trips')
      t.deepEq(ds:get('fxPatterns'),     { p1 = { kind = 'notes' } }, 'project pattern lib round-trips')
      t.deepEq(ds:get('paramFrecency'),  { p = 9 },   'global key round-trips')
    end,
  },
  {
    name = 'an unset key reads as nil',
    run = function()
      local ds = freshDs()
      t.eq(ds:get('groups'), nil, 'absent take blob is nil')
    end,
  },
  {
    name = 'an unknown name raises on every entry point',
    run = function()
      local ds = freshDs()
      t.falsy(pcall(function() ds:get('nope') end),       'get rejects an unregistered name')
      t.falsy(pcall(function() ds:assign('nope', 1) end), 'assign rejects too')
    end,
  },
  {
    name = 'delete clears a per-key blob back to nil, not {}',
    run = function()
      local ds = freshDs()
      ds:assign('groups', { a = 1 })
      ds:delete('groups')
      t.eq(ds:get('groups'), nil, 'deleted take key reads nil')
    end,
  },
  {
    name = 'util.REMOVE on assign deletes, matching delete',
    run = function()
      local ds = freshDs()
      ds:assign('arrangeNaturalLenQN', 12)
      ds:assign('arrangeNaturalLenQN', util.REMOVE)
      t.eq(ds:get('arrangeNaturalLenQN'), nil, 'REMOVE clears the blob')
    end,
  },
  {
    name = 'reads deep-clone out; callers cannot mutate ds state',
    run = function()
      local ds = freshDs()
      ds:assign('groups', { a = { 1 } })
      local got = ds:get('groups')
      got.a[1] = 99
      t.deepEq(ds:get('groups'), { a = { 1 } }, 'mutating a read does not reach the cache')
    end,
  },
  {
    name = 'the global scope persists as a load()-able continuum-data.lua',
    run = function()
      local ds = freshDs()
      ds:assign('paramFrecency', { fx = { n = 3 } })
      local onDisk = readFile(DATA_PATH)
      t.truthy(onDisk and onDisk:match('^return'), 'global blob is a Lua literal')
      t.deepEq(ds:get('paramFrecency'), { fx = { n = 3 } }, 'round-trips off disk')
    end,
  },
  {
    name = 'per-key take blobs are isolated -- one write does not share a slot',
    run = function()
      local ds, _, r = freshDs()
      ds:assign('groups',    { g = 1 })
      ds:assign('noteDelay', { d = 2 })
      t.truthy(r._state.takeExt[TAKE .. '/P_EXT:ctm_data.groups'],    'groups has its own slot')
      t.truthy(r._state.takeExt[TAKE .. '/P_EXT:ctm_data.noteDelay'], 'noteDelay has its own slot')
    end,
  },
  {
    name = 'getAt / assignAt address a foreign handle',
    run = function()
      local ds = freshDs()
      ds:assignAt('other_track', 'slotEntries', { 'foreign' })
      t.deepEq(ds:getAt('other_track', 'slotEntries'), { 'foreign' },
        'foreign write reads back at that handle')
      t.eq(ds:get('slotEntries'), nil, 'bound track untouched by the foreign write')
    end,
  },
  {
    name = 'assign fires dataChanged { scope, name }',
    run = function()
      local ds = freshDs()
      local seen
      ds:subscribe('dataChanged', function(p) seen = p end)
      ds:assign('groups', { a = 1 })
      t.deepEq(seen, { scope = 'take', name = 'groups' }, 'one targeted fire')
    end,
  },
  {
    name = 'an undo tick that rewinds a blob fires dataChanged for that key',
    run = function()
      local ds, ps, r = freshDs()
      ds:assign('groups', { a = 1 })
      local seen
      ds:subscribe('dataChanged', function(p) seen = p end)
      r._state.takeExt[TAKE .. '/P_EXT:ctm_data.groups'] = util.serialise({ a = 2 })
      bump(r)
      ps:pollUndo()
      t.deepEq(seen, { scope = 'take', name = 'groups', invalidate = true }, 'watcher named the diverged key')
      t.deepEq(ds:get('groups'), { a = 2 }, 'cache reloaded to the rewound value')
    end,
  },
  {
    name = 'contextChanged drops take/track caches so the next read reloads',
    run = function()
      local ds, ps, r = freshDs()
      ds:assign('groups', { a = 1 })
      r:bindTake('take2', 'take2/item', 'track2')
      r._state.takeExt['take2/P_EXT:ctm_data.groups'] = util.serialise({ a = 9 })
      ps:setTake('take2')
      t.deepEq(ds:get('groups'), { a = 9 }, 'read reflects the new context')
    end,
  },
}
