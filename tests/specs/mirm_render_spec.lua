-- 4d render-pass seam: the pure state->theme-key mapping and the
-- mirm:eachInstance read accessor the trackerPage render pass drives.
-- The geometry/draw itself is REAPER-only; what is unit-testable is
-- (a) the mapping is total and stable, (b) eachInstance reports rect /
-- anchor / active faithfully.

local t      = require('support')
local util   = require('util')
local mirror = require('mirror')

local function fakeTm()
  local staged, seq = { add = {} }, 0
  local tm = {}
  function tm:subscribe() end
  function tm:addEvent(e)    staged.add[#staged.add + 1] = e end
  function tm:assignEvent() end
  function tm:deleteEvent() end
  function tm:flush()
    for _, e in ipairs(staged.add) do
      if e.uuid == nil then seq = seq + 1; e.uuid = 1000 + seq end
    end
  end
  return tm
end

local function fakeCm()
  local s = {}
  return { get = function(_, k) return s[k] end,
           set = function(_, _l, k, v) s[k] = v end }
end

local function mk()
  return util.instantiate('mirrorManager', { tm = fakeTm(), cm = fakeCm() })
end

local function note(ppq, lane)
  return { evType = 'note', chan = 1, lane = lane, ppq = ppq,
           endppq = ppq + 240, pitch = 60, vel = 100 }
end

local rect = { ppq = 0, dur = 960, chanLo = 1,
               streams = { [0] = { ['note:1'] = true } } }

return {
  {
    name = 'tintKey: synced has no wash; states split active vs fade',
    run = function()
      t.eq(mirror.tintKey('synced', true),       nil)
      t.eq(mirror.tintKey('overridden', true),  'mirror.overridden.tint')
      t.eq(mirror.tintKey('overridden', false), 'mirror.overridden.fade')
      t.eq(mirror.tintKey('conflicted', true),  'mirror.conflicted.tint')
      t.eq(mirror.tintKey('conflicted', false), 'mirror.conflicted.fade')
    end,
  },
  {
    name = 'outlineKey: conflicted is loud, all else the synced border',
    run = function()
      t.eq(mirror.outlineKey('conflicted'), 'mirror.conflicted.outline')
      t.eq(mirror.outlineKey('synced'),     'mirror.synced.outline')
      t.eq(mirror.outlineKey('overridden'), 'mirror.synced.outline')
    end,
  },
  {
    name = 'eachInstance enumerates every instance with rect+anchor+active',
    run = function()
      local mirm = mk()
      local gid  = mirm:mark({ note(0, 1) }, rect)   -- mark sets active
      mirm:newInstance(gid, { ppq = 960, chan = 1 })
      local all = mirm:eachInstance()
      t.eq(#all, 2, 'two instances enumerated')
      table.sort(all, function(a, b) return a.instId < b.instId end)
      t.eq(all[1].rect, rect,       'rect returned by reference')
      t.eq(all[1].anchor.ppq, 0,    'instance 1 at the region origin')
      t.eq(all[2].anchor.ppq, 960,  'instance 2 at the stamp ppq')
      t.truthy(all[1].active and all[2].active, 'mark made the group active')
    end,
  },
  {
    name = 'eachInstance: a markGroup (no copy) group is inactive',
    run = function()
      local mirm = mk()
      mirm:markGroup({ note(0, 1) }, rect)           -- no active set
      local all = mirm:eachInstance()
      t.eq(#all, 1)
      t.falsy(all[1].active, 'markGroup does not set active')
    end,
  },
}
