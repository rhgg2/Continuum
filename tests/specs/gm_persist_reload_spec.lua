-- Persistence reload: gm reads `groups` once at construction —
-- before any take is bound (continuum builds the stack with no take), so
-- that read is always empty. The take-changed rebuild must re-read cm and
-- rehydrate the runtime projection (proj / locByUuid / nextGroupId) from
-- the persisted `groups` + `uuids`, or restored groups are inert and a
-- fresh markGroup clobbers group 1.

local t    = require('support')
local util = require('util')

local nextUuid = 0
local function note(ppq, chan, lane, extra)
  nextUuid = nextUuid + 1
  local n = { evType = 'note', chan = chan, lane = lane, ppq = ppq,
              endppq = ppq + 240, pitch = 60, vel = 100, uuid = nextUuid }
  for k, v in pairs(extra or {}) do n[k] = v end
  return n
end

local function rect(ppq, chan)
  return { ppq = ppq, dur = 960, chanLo = chan,
           streams = { [0] = { ['note:1'] = true } } }
end

-- Round-trips the persisted blob through util.serialise/unserialise, as
-- the real take tier does. util.OPEN (= math.huge) round-trips by an
-- explicit "inf" literal, so an open lane tail survives the reload as a
-- number, not a string. The group frame still uses nil-dur to express
-- "open" (no ceiling), independent of how endppqL is persisted.
local function serialisingDs()
  local store = {}
  return {
    get = function(_, name) return store[name] end,
    assign = function(_, name, v)
      store[name] = util.unserialise(util.serialise(v))
    end,
    subscribe = function() end,
  }
end

return {
  {
    name = 'an open last-in-lane group note survives the serialised reload',
    run = function()
      local ds = serialisingDs()

      -- Session 1: stamp a group + sibling, then a global create whose
      -- group event lands last-in-lane (open tail -> math.huge dur).
      local tmA, stagedA = t.fakeTm()
      local A   = util.instantiate('groupManager', { tm = tmA, ds = ds })
      local src = note(0, 1, 1)
      local gid = A:markGroup({ src }, rect(0, 1))
      A:newInstance(gid, { ppq = 960, chan = 1 })
      tmA:flush()

      local born = note(480, 1, 1, { pitch = 65 })  -- inside region, last in lane
      tmA:flush({ { evt = born } }, {}, {})

      local uuidMap = { [src.uuid] = src, [born.uuid] = born }
      for _, e in ipairs(stagedA.add) do uuidMap[e.uuid] = e end

      -- Session 2: fresh gm sharing the (serialised) cm. Without the
      -- finite-dur normalisation rehydrate raises in mirror.project.
      local tmB = t.fakeTm({ uuidMap = uuidMap })
      local B   = util.instantiate('groupManager', { tm = tmB, ds = ds })
      tmB:fireRebuild(true)

      t.eq(#B:eachInstance(), 2, 'group + its mirrored instance rehydrated')
      t.truthy(B:stateOf(src.uuid), 'origin reverse-lookup rehydrated')
    end,
  },
  {
    name = 'a persisted group rehydrates on the take-changed rebuild',
    run = function()
      local ds = t.fakeDs()

      -- Session 1: stamp a group + one mirrored instance, commit (persists).
      local tmA, stagedA = t.fakeTm()
      local A   = util.instantiate('groupManager', { tm = tmA, ds = ds })
      local src = note(0, 1, 1, { pitch = 60 })
      local gid = A:markGroup({ src }, rect(0, 1))
      A:newInstance(gid, { ppq = 960, chan = 1 })
      tmA:flush()                                  -- stamps the add uuid; postflush persists
      local addEvt = stagedA.add[1]
      t.truthy(addEvt and addEvt.uuid, 'mirrored add got a uuid')

      -- Session 2: a fresh gm sharing cm; its tm resolves the durable
      -- uuids mm would have re-minted on the reloaded take.
      local tmB, stagedB = t.fakeTm({ uuidMap = { [src.uuid] = src, [addEvt.uuid] = addEvt } })
      local B = util.instantiate('groupManager', { tm = tmB, ds = ds })

      tmB:fireRebuild(true)

      t.eq(#B:eachInstance(), 2, 'group + its mirrored instance rehydrated')
      t.truthy(B:stateOf(src.uuid), 'origin reverse-lookup rehydrated')

      -- nextGroupId advanced past the persisted group (no clobber).
      local gid2 = B:markGroup({ note(0, 1, 1) }, rect(2000, 1))
      t.eq(gid2, gid + 1, 'nextGroupId restored, not reset to 1')

      -- Propagation lives end to end: edit the origin, sibling reprojects.
      B:assignEvent(src.uuid, { pitch = 72 })
      tmB:flush()
      local bySibling, byOrigin
      for _, a in ipairs(stagedB.assign) do
        if a.update.pitch ~= nil then
          if a.evt == addEvt then bySibling = a
          elseif a.evt == src then byOrigin = a end
        end
      end
      t.truthy(bySibling, 'the mirrored instance event reprojected after rehydrate')
      t.eq(bySibling.update.pitch, 72)
      t.truthy(byOrigin and byOrigin.update.pitch == 72,
        'the user-touched origin is round-tripped from the group too')
    end,
  },
  {
    name = 'REAPER undo: a ds invalidate rehydrates gm from the rewound blob',
    run = function()
      -- Ctrl-Z path: ds fires dataChanged invalidate=true; gm must re-read
      -- or its `groups` dict still shows pre-undo geometry.
      local ds = t.fakeDs()
      local tmA = t.fakeTm()
      local A   = util.instantiate('groupManager', { tm = tmA, ds = ds })
      local src = note(0, 1, 1)
      local gid = A:markGroup({ src }, rect(0, 1))
      A:newInstance(gid, { ppq = 960, chan = 1 })
      tmA:flush()
      t.eq(#A:eachInstance(), 2, 'baseline: group + its mirrored instance')

      ds._rewind('groups', nil)

      t.eq(#A:eachInstance(), 0, 'gm rehydrated from rewound cm: no instances')
      t.eq(A:stateOf(src.uuid), nil, 'origin reverse-lookup cleared')
    end,
  },
}
