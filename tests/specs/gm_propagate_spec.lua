-- Stateful mirror manager (gm). Wraps the pure mirror core with anchor
-- maths and rides tm's preflush/postflush seam: a staged edit landing in a
-- group's region mutates the shared group, reprojects every sibling
-- instance, and stages the diff back through tm so it commits in the same
-- mm:modify.
--
-- gm is a constructor chunk (util.instantiate('groupManager', {tm,cm})).
-- The fake tm captures the seam handlers and records staged peer ops;
-- flush(trio) fires preflush, fakes mm uuid-stamping on staged adds, then
-- fires postflush.

local t      = require('support')
local util   = require('util')

local function fakeTm()
  local hooks, staged, seq = {}, { add = {}, assign = {}, del = {} }, 0
  local tm = {}
  function tm:length()              return math.huge end   -- off-take clip irrelevant here
  function tm:subscribe(sig, fn)    hooks[sig] = fn end
  function tm:addEvent(evt)         staged.add[#staged.add + 1] = evt end
  function tm:assignEvent(evt, u)   staged.assign[#staged.assign + 1] = { evt = evt, update = u } end
  function tm:deleteEvent(evt)      staged.del[#staged.del + 1] = evt end
  function tm:flush(adds, assigns, deletes)
    if hooks.preflush then hooks.preflush(adds or {}, assigns or {}, deletes or {}) end
    for _, e in ipairs(staged.add) do
      if e.uuid == nil then seq = seq + 1; e.uuid = 1000 + seq end
    end
    if hooks.postflush then hooks.postflush() end
  end
  return tm, staged, hooks
end

local function mk()
  local tm, staged, hooks = fakeTm()
  local gm = util.instantiate('groupManager', { tm = tm, ds = t.fakeDs() })
  return gm, tm, staged, hooks
end

local nextUuid = 0
local function note(ppq, chan, lane, extra)
  nextUuid = nextUuid + 1
  local n = { evType = 'note', chan = chan, lane = lane, ppq = ppq,
              endppq = ppq + 240, pitch = 60, vel = 100, uuid = nextUuid }
  for k, v in pairs(extra or {}) do n[k] = v end
  return n
end

-- One note:1 stream on the anchor channel, a bar wide.
local function rect(ppq, chan)
  return { ppq = ppq, dur = 960, chanLo = chan,
           streams = { [0] = { ['note:1'] = true } } }
end

return {
  {
    name = 'newInstance stages a concrete copy of every group event at the new anchor',
    run = function()
      local gm, _, staged = mk()
      local sel = { note(0, 1, 1, { pitch = 64 }), note(240, 1, 1, { pitch = 67 }) }
      local gid = gm:markGroup(sel, rect(0, 1))
      local iid = gm:newInstance(gid, { ppq = 960, chan = 1 })

      t.truthy(iid, 'newInstance returns an instId')
      t.eq(#staged.add, 2)
      local ppqs = { staged.add[1].ppq, staged.add[2].ppq }
      table.sort(ppqs)
      t.deepEq(ppqs, { 960, 1200 })            -- group 0/240 rebased to anchor 960
      t.eq(staged.add[1].chan, 1)
      t.eq(staged.add[1].evType, 'note')
    end,
  },

  {
    name = 'newInstance rejects a projection whose channel falls out of range',
    run = function()
      local gm = mk()
      local gid = gm:markGroup({ note(0, 1, 1) }, rect(0, 1))
      local iid, reason = gm:newInstance(gid, { ppq = 0, chan = 17 })
      t.falsy(iid)
      t.eq(reason, 'channel out of range')
    end,
  },

  {
    name = 'a staged edit inside one instance propagates to the sibling via the group',
    run = function()
      local gm, tm, staged = mk()
      local src = note(0, 1, 1, { pitch = 60 })
      local gid = gm:markGroup({ src }, rect(0, 1))
      gm:newInstance(gid, { ppq = 960, chan = 1 })
      tm:flush()                                -- commit the mirrored add; stamp its uuid
      staged.add = {}

      gm:assignEvent(src.uuid, { pitch = 72 })
      tm:flush()

      -- Replay model: reproject round-trips EVERY instance from the
      -- pristine group -- the sibling's copy AND the user-touched
      -- origin. (conform-marker reconciles, {conform=...}, filtered.)
      local bySibling, byOrigin
      for _, a in ipairs(staged.assign) do
        if a.update.pitch ~= nil then
          if a.evt.ppq == 960 then bySibling = a else byOrigin = a end
        end
      end
      t.truthy(bySibling, 'the sibling copy is reprojected')
      t.eq(bySibling.update.pitch, 72)
      t.eq(bySibling.evt.chan, 1)
      t.truthy(byOrigin and byOrigin.evt == src,
        'the user-touched origin is round-tripped from the group too')
      t.eq(byOrigin.update.pitch, 72)
    end,
  },

  {
    name = 'a moved group note carries its tail to the sibling (endppq shifts with ppq)',
    run = function()
      local gm, tm, staged = mk()
      local src = note(0, 1, 1, { endppqL = 240 })  -- ceiling 240 (finite intent)
      local gid = gm:markGroup({ src }, rect(0, 1))
      gm:newInstance(gid, { ppq = 960, chan = 1 })
      tm:flush(); staged.add = {}

      -- A move authors a new ceiling. The facade hands gm tv's AUTHORED
      -- update (logical onset in ppq, intent ceiling in endppq); gm stages
      -- each instance's intent as endppq. Start 0->480, ceiling ->720.
      gm:assignEvent(src.uuid, { ppq = 480, endppq = 720 })
      tm:flush()

      local bySibling, byOrigin
      for _, a in ipairs(staged.assign) do
        if a.update.ppq ~= nil then
          if a.evt == src then byOrigin = a else bySibling = a end
        end
      end
      t.truthy(bySibling, 'sibling note reprojected')
      t.eq(bySibling.update.ppq, 1440, 'sibling start shifts to anchor 960 + 480')
      t.eq(bySibling.update.endppq, 1680, 'sibling ceiling shifts rigidly (960+480+240), staged on endppq')
      t.eq(bySibling.update.endppqL, nil, 'gm stages endppq only; endppqL is tm-private')
      t.truthy(byOrigin, 'the user-touched origin is round-tripped too')
      t.eq(byOrigin.update.ppq, 480, 'origin restaged at its own anchor 0 + 480')
      t.eq(byOrigin.update.endppq, 720, 'origin ceiling moves rigidly with it, staged on endppq')
    end,
  },

  {
    name = 'a create inside the region on a selected stream propagates to siblings',
    run = function()
      local gm, tm, staged = mk()
      local src = note(0, 1, 1)
      local gid = gm:markGroup({ src }, rect(0, 1))
      gm:newInstance(gid, { ppq = 960, chan = 1 })
      tm:flush(); staged.add = {}

      local born = note(480, 1, 1, { pitch = 65 })   -- inside region, note:1 selected
      gm:addEvent(born); tm:flush()

      -- reproject is sole writer: BOTH the acting instance (anchor 0) and the
      -- sibling (anchor 960) materialise the adopted create.
      t.eq(#staged.add, 2, 'acting instance and sibling both materialise the create')
      local sib
      for _, a in ipairs(staged.add) do if a.ppq == 1440 then sib = a end end
      t.truthy(sib, 'sibling copy at 1440 (480 rebased to anchor 960)')
      t.eq(sib.pitch, 65)
    end,
  },

  {
    name = 'a create on a stream the region does not select is ignored',
    run = function()
      local gm, tm, staged = mk()
      local gid = gm:markGroup({ note(0, 1, 1) }, rect(0, 1))
      gm:newInstance(gid, { ppq = 960, chan = 1 })
      tm:flush(); staged.add = {}

      gm:addEvent(note(480, 1, 2)); tm:flush()  -- lane 2 -> note:2, unselected

      t.eq(#staged.add, 0)
    end,
  },

  {
    name = 'localMode keeps the edit local: no propagation, shared group untouched',
    run = function()
      local gm, tm, staged = mk()
      local src = note(0, 1, 1, { pitch = 60 })
      local gid = gm:markGroup({ src }, rect(0, 1))
      gm:newInstance(gid, { ppq = 960, chan = 1 })
      tm:flush(); staged.add = {}

      gm:setLocalMode(true)
      gm:assignEvent(src.uuid, { pitch = 99 })
      tm:flush()

      -- localMode contains the edit to its own instance. The replay
      -- model still round-trips the origin's OWN event from its
      -- per-instance projection, but no OTHER instance -- nor the shared
      -- group -- may see pitch 99: every pitch assign must target the
      -- user-touched origin event itself, never the sibling's copy.
      for _, a in ipairs(staged.assign) do
        if a.update.pitch ~= nil then
          t.eq(a.evt, src, 'only the origin itself is restaged; no propagation')
          t.eq(a.update.pitch, 99)
        end
      end

      -- The shared group is untouched: a fresh instance still shows pitch 60.
      gm:setLocalMode(false)
      local iid = gm:newInstance(gid, { ppq = 1920, chan = 1 })
      t.truthy(iid)
      t.eq(staged.add[#staged.add].pitch, 60)
    end,
  },

  {
    name = 'editing a localMode-added event after leaving localMode does not crash',
    run = function()
      local gm, tm, staged = mk()
      local src = note(0, 1, 1, { pitch = 60 })
      local gid = gm:markGroup({ src }, rect(0, 1))
      gm:newInstance(gid, { ppq = 960, chan = 1 })
      tm:flush(); staged.add = {}

      gm:setLocalMode(true)
      local born = note(480, 1, 1, { pitch = 65 })   -- inside region
      gm:addEvent(born); tm:flush()                  -- local-only add
      local made
      for _, e in ipairs(staged.add) do if e.ppq == 480 then made = e end end
      staged.add = {}

      gm:setLocalMode(false)
      -- Editing the local-only add: group.events[vuid] is nil (it lives in
      -- instance.adds), so the non-local assign branch must not util.assign nil.
      gm:assignEvent(made.uuid, { pitch = 70 })
      tm:flush()

      local iid = gm:newInstance(gid, { ppq = 1920, chan = 1 })
      t.truthy(iid, 'shared group still projectable; the local add stayed local')
    end,
  },
}
