-- Commit 1 lifecycle verbs on the real groupManager (fake tm/cm, the
-- same faithful seam as gm_active_spec):
--   deleteInstance -- stage tm deletes, last instance drops the group;
--   moveInstance   -- re-place concretes through the anchor dual, the
--                     moving instance excluded from its own collision;
--   resizeGroup    -- Model A re-origin, leaving members orphaned (not
--                     deleted), gained members absorbed from the actor.

local t    = require('support')
local util = require('util')

local function fakeTm()
  local hooks, staged, seq = {}, { add = {}, assign = {}, del = {} }, 0
  local tm = {}
  function tm:subscribe(sig, fn) hooks[sig] = fn end
  function tm:addEvent(evt)      staged.add[#staged.add + 1] = evt end
  function tm:assignEvent(e, u)  staged.assign[#staged.assign + 1] = { evt = e, update = u } end
  function tm:deleteEvent(evt)   staged.del[#staged.del + 1] = evt end
  function tm:flush()
    if hooks.preflush then hooks.preflush({}, {}, {}) end
    for _, e in ipairs(staged.add) do
      if e.uuid == nil then seq = seq + 1; e.uuid = 1000 + seq end
    end
    if hooks.postflush then hooks.postflush() end
  end
  return tm, staged
end

local function fakeCm()
  local store = {}
  return { get = function(_, k) return store[k] end,
           set = function(_, _l, k, v) store[k] = v end }
end

local function mk()
  local tm, staged = fakeTm()
  return util.instantiate('groupManager', { tm = tm, cm = fakeCm() }), staged
end

local function note(ppq, uuid, lane)
  return { evType = 'note', chan = 1, lane = lane or 1, ppq = ppq,
           endppq = ppq + 240, pitch = 60, vel = 100, uuid = uuid }
end

local function rect(ppq, dur, lane)
  return { ppq = ppq, dur = dur, chanLo = 1,
           streams = { [0] = { ['note:' .. (lane or 1)] = true } } }
end

local function instOf(gm, groupId)
  local out = {}
  for _, r in ipairs(gm:eachInstance()) do
    if r.groupId == groupId then out[#out + 1] = r end
  end
  return out
end

return {
  ----- deleteInstance

  {
    name = 'deleteInstance: unknown group / instance -> nil, reason',
    run = function()
      local gm = mk()
      local g = gm:mark({ note(0, 1) }, rect(0, 480))
      local ok, why = gm:deleteInstance(999, 1)
      t.eq(ok, nil); t.eq(why, 'no such group')
      local ok2, why2 = gm:deleteInstance(g, 999)
      t.eq(ok2, nil); t.eq(why2, 'no such instance')
    end,
  },

  {
    name = 'deleteInstance non-last: stages deletes, instance gone, group stays',
    run = function()
      local gm, staged = mk()
      local g = gm:duplicateInto(nil, { note(0, 1) }, rect(0, 480),
                                   { ppq = 480, chan = 1 })
      staged.tm = nil
      gm:newInstance(g, { ppq = 960, chan = 1 })
      local before = #instOf(gm, g)
      t.truthy(before >= 2, 'group has multiple instances')
      local copies = instOf(gm, g)
      local victim = copies[#copies].instId
      t.truthy(gm:deleteInstance(g, victim), 'delete succeeds')
      t.truthy(#staged.del >= 1, 'a concrete delete was staged')
      t.eq(#instOf(gm, g), before - 1, 'one fewer instance')
    end,
  },

  {
    name = 'deleteInstance last: group dropped, active pointer cleared',
    run = function()
      local gm = mk()
      local g = gm:mark({ note(0, 1) }, rect(0, 480))
      t.eq(gm:activeGroup(), g, 'mark made it active')
      local only = instOf(gm, g)[1].instId
      t.truthy(gm:deleteInstance(g, only))
      t.eq(#instOf(gm, g), 0, 'group has no instances')
      t.eq(gm:activeGroup(), nil, 'active pointer cleared')
    end,
  },

  ----- moveInstance

  {
    name = 'moveInstance: unknown -> nil, reason',
    run = function()
      local gm = mk()
      local g = gm:mark({ note(0, 1) }, rect(0, 480))
      t.eq(({ gm:moveInstance(999, 1, { ppq = 0, chan = 1 }) })[2], 'no such group')
      t.eq(({ gm:moveInstance(g, 999, { ppq = 0, chan = 1 }) })[2], 'no such instance')
    end,
  },

  {
    name = 'moveInstance re-places projected concretes at the new anchor',
    run = function()
      local gm, staged = mk()
      local src = note(0, 1)
      local g   = gm:mark({ src }, rect(0, 480))
      local iid = instOf(gm, g)[1].instId
      t.truthy(gm:moveInstance(g, iid, { ppq = 240, chan = 1 }))
      t.eq(instOf(gm, g)[1].anchor.ppq, 240, 'anchor moved')
      local hit
      for _, a in ipairs(staged.assign) do if a.evt == src then hit = a end end
      t.truthy(hit, 'a re-place assign was staged for the concrete')
      t.eq(hit.update.ppq, 240, 'concrete re-placed to anchor.ppq + groupEvt.ppq')
    end,
  },

  {
    name = 'moveInstance rejects out-of-channel-range, instance untouched',
    run = function()
      local gm = mk()
      local g   = gm:mark({ note(0, 1) }, rect(0, 480))
      local iid = instOf(gm, g)[1].instId
      local ok, why = gm:moveInstance(g, iid, { ppq = 0, chan = 99 })
      t.eq(ok, nil); t.eq(why, 'channel out of range')
      t.eq(instOf(gm, g)[1].anchor.chan, 1, 'anchor unchanged')
    end,
  },

  {
    name = 'moveInstance rejects a collision with another group',
    run = function()
      local gm = mk()
      local a = gm:mark({ note(0, 1) }, rect(0, 480))      -- [0,480)
      local b = gm:mark({ note(0, 2) }, rect(960, 480))    -- [960,1440)
      t.truthy(a and b and a ~= b, 'two disjoint groups')
      local bIid = instOf(gm, b)[1].instId
      local ok, why = gm:moveInstance(b, bIid, { ppq = 0, chan = 1 })
      t.eq(ok, nil); t.eq(why, 'overlaps an existing mirror group')
      t.eq(instOf(gm, b)[1].anchor.ppq, 960, 'b not moved')
    end,
  },

  {
    name = 'moveInstance self-exclusion: overlap with its own old span is allowed',
    run = function()
      local gm = mk()
      local g   = gm:mark({ note(0, 1) }, rect(0, 480))    -- span [0,480)
      local iid = instOf(gm, g)[1].instId
      t.truthy(gm:moveInstance(g, iid, { ppq = 240, chan = 1 }),
        'a move whose new span overlaps its own old span is not a self-collision')
    end,
  },

  ----- resizeGroup

  {
    name = 'resizeGroup: unknown / vanishing region -> nil, reason',
    run = function()
      local gm = mk()
      local g = gm:mark({ note(0, 1) }, rect(0, 480))
      t.eq(({ gm:resizeGroup(999, 1, {}) })[2], 'no such group')
      t.eq(({ gm:resizeGroup(g, 999, {}) })[2], 'no such instance')
      local iid = instOf(gm, g)[1].instId
      t.eq(({ gm:resizeGroup(g, iid, { endDelta = -480 }) })[2],
        'region would vanish')
    end,
  },

  {
    name = 'resizeGroup end-trim: a member leaving is orphaned, not deleted',
    run = function()
      local gm, staged = mk()
      local g = gm:mark({ note(0, 1), note(480, 2) }, rect(0, 960))
      local iid = instOf(gm, g)[1].instId
      t.truthy(gm:stateOf(2), 'note 2 starts group-managed')
      t.truthy(gm:resizeGroup(g, iid, { endDelta = -600 }))  -- newDur 360
      t.eq(gm:stateOf(2), nil, 'note 2 left the group')
      t.truthy(gm:stateOf(1), 'note 1 still in the group')
      t.eq(#staged.del, 0, 'a leaving member is NOT deleted, just unmanaged')
      t.eq(instOf(gm, g)[1].rect.dur, 360, 'rect end moved in')
    end,
  },

  {
    name = 'resizeGroup start-trim re-origins (Model A): anchors slide, member leaves',
    run = function()
      local gm = mk()
      local g = gm:mark({ note(0, 1), note(480, 2) }, rect(0, 960))
      local iid = instOf(gm, g)[1].instId
      local anchor0 = instOf(gm, g)[1].anchor.ppq
      t.truthy(gm:resizeGroup(g, iid, { startDelta = 240 }))
      t.eq(instOf(gm, g)[1].anchor.ppq, anchor0 + 240,
        'every anchor shifts by startDelta')
      t.eq(instOf(gm, g)[1].rect.dur, 720, 'region shorter by startDelta')
      t.eq(gm:stateOf(1), nil, 'note 1 fell before the new start, orphaned')
      t.truthy(gm:stateOf(2), 'note 2 re-origined and still inside')
    end,
  },

  {
    name = 'resizeGroup gained: actor concretes absorbed, fanned to siblings',
    run = function()
      local gm, staged = mk()
      local g = gm:duplicateInto(nil, { note(0, 1) }, rect(0, 480),
                                   { ppq = 2000, chan = 1 })  -- seed + copy, clear of the grown span
      local seedIid = instOf(gm, g)[1].instId
      local extra = note(720, 9001)               -- a plain event under the actor
      t.eq(gm:stateOf(9001), nil, 'not group-managed yet')
      local addsBefore = #staged.add
      t.truthy(gm:resizeGroup(g, seedIid,
        { endDelta = 480, gained = { extra } }))   -- newDur 960, covers 720
      t.truthy(gm:stateOf(9001), 'absorbed into the group')
      t.truthy(#staged.add > addsBefore,
        'the sibling instance got a fanned-out copy of the gained event')
    end,
  },

  {
    name = 'resizeGroup rejects when a resized instance would hit another group',
    run = function()
      local gm = mk()
      local a = gm:mark({ note(0, 1) }, rect(0, 480))      -- [0,480)
      local b = gm:mark({ note(0, 2) }, rect(1000, 480))   -- [1000,1480)
      local aIid = instOf(gm, a)[1].instId
      local ok, why = gm:resizeGroup(a, aIid, { endDelta = 700 })  -- ->[0,1180)
      t.eq(ok, nil); t.eq(why, 'overlaps an existing mirror group')
      t.eq(instOf(gm, a)[1].rect.dur, 480, 'rect unchanged on rejection')
    end,
  },

  {
    name = 'resizeGroup rejects growing one instance into a sibling',
    run = function()
      local gm = mk()
      local g  = gm:duplicateInto(nil, { note(0, 1) }, rect(0, 480),
                                    { ppq = 480, chan = 1 })  -- inst1 [0,480), inst2 [480,960)
      local seedIid
      for _, r in ipairs(instOf(gm, g)) do
        if r.anchor.ppq == 0 then seedIid = r.instId end
      end
      local ok, why = gm:resizeGroup(g, seedIid, { endDelta = 240 }) -- ->[0,720) over inst2
      t.eq(ok, nil); t.eq(why, 'overlaps an existing mirror group')
      t.eq(instOf(gm, g)[1].rect.dur, 480, 'rect unchanged on sibling collision')
    end,
  },

}
