-- Disjoint-region invariant. Overlapping mirror groups have no defined
-- semantics (classifyCreate's group adoption is pairs()-order, two
-- groups project the same slot with no cross-group dedup), so markGroup
-- and newInstance reject a region that shares time AND a (channel,
-- streamId) cell with a live instance. Same faithful-fake seam as
-- mirm_seed_conform_spec.

local t    = require('support')
local util = require('util')

local function fakeTm()
  local hooks, staged, seq = {}, { add = {} }, 0
  local tm = {}
  function tm:subscribe(s, fn) hooks[s] = fn end
  function tm:addEvent(e)      staged.add[#staged.add + 1] = e end
  function tm:assignEvent()    end
  function tm:deleteEvent()    end
  function tm:flush()
    if hooks.preflush then hooks.preflush({}, {}, {}) end
    for _, e in ipairs(staged.add) do
      if e.uuid == nil then seq = seq + 1; e.uuid = 1000 + seq end
    end
    if hooks.postflush then hooks.postflush() end
  end
  return tm
end

local function fakeCm()
  local store = {}
  return { get = function(_, k) return store[k] end,
           set = function(_, _l, k, v) store[k] = v end,
           subscribe = function() end }
end

local function mk()
  return util.instantiate('groupManager', { tm = fakeTm(), cm = fakeCm() })
end

local uuid = 0
local function note(chan, lane)
  uuid = uuid + 1
  return { evType = 'note', chan = chan or 1, lane = lane or 1,
           ppq = 0, endppq = 240, pitch = 60, vel = 100, uuid = uuid }
end

-- streamId is `evType:key`; lane N -> 'note:N'.
local function rect(ppq, dur, chanLo, lane)
  return { ppq = ppq, dur = dur, chanLo = chanLo or 1,
           streams = { [0] = { ['note:' .. (lane or 1)] = true } } }
end

local function instanceCount(gm)
  return #gm:eachInstance()
end

return {
  {
    name = 'mark over a live group region is rejected; no group allocated',
    run = function()
      local gm = mk()
      t.truthy(gm:mark({ note() }, rect(0, 480, 1, 1)),
        'first mark seeds a group')
      t.eq(instanceCount(gm), 1, 'one instance live')
      local g, why = gm:mark({ note() }, rect(240, 480, 1, 1))
      t.eq(g, nil, 'overlapping mark rejected')
      t.eq(why, 'overlaps an existing mirror group', 'with a reason')
      t.eq(instanceCount(gm), 1, 'no second group allocated')
    end,
  },
  {
    name = 'same bars, different lane does not conflict',
    run = function()
      local gm = mk()
      gm:mark({ note(1, 1) }, rect(0, 480, 1, 1))
      t.truthy(gm:mark({ note(1, 2) }, rect(0, 480, 1, 2)),
        'a group on a different lane in the same span is allowed')
      t.eq(instanceCount(gm), 2, 'both groups live')
    end,
  },
  {
    name = 'adjacent cascade stack (next = ppq+dur) is allowed',
    run = function()
      local gm = mk()
      local g = gm:duplicateInto(nil, { note() }, rect(0, 480, 1, 1),
                                   { ppq = 480, chan = 1 })
      t.truthy(g, 'seed: group + first copy at [480,960)')
      t.eq(gm:duplicateInto(g, {}, rect(0, 480, 1, 1),
                              { ppq = 960, chan = 1 }), g,
        'a second adjacent copy joins the same group')
      t.eq(instanceCount(gm), 3, 'seed + two copies, no rejection')
    end,
  },
  {
    name = 'a copy landing on an existing sibling is rejected',
    run = function()
      local gm = mk()
      local g = gm:duplicateInto(nil, { note() }, rect(0, 480, 1, 1),
                                   { ppq = 480, chan = 1 })
      local before = instanceCount(gm)
      local instId, why = gm:newInstance(g, { ppq = 240, chan = 1 })
      t.eq(instId, nil, 'a copy overlapping the source region is rejected')
      t.eq(why, 'overlaps an existing mirror group', 'with a reason')
      t.eq(instanceCount(gm), before, 'no instance added')
    end,
  },
}
