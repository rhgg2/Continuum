-- 4d render-pass seam: the pure state->theme-key mapping and the
-- gm:eachInstance read accessor the trackerPage render pass drives.
-- The geometry/draw itself is REAPER-only; what is unit-testable is
-- (a) the mapping is total and stable, (b) eachInstance reports rect /
-- anchor / active faithfully.

local t      = require('support')
local util   = require('util')
local groups = require('groups')

local function mk()
  return util.instantiate('groupManager', { tm = t.fakeTm(), ds = t.fakeDs() })
end

local function note(ppq, lane)
  return { evType = 'note', chan = 1, lane = lane, ppq = ppq,
           endppq = ppq + 240, pitch = 60, vel = 100 }
end

local rect = { ppq = 0, dur = 960, chanLo = 1,
               streams = { [0] = { ['note:1'] = true } } }

return {
  {
    name = 'tintKey: synced has no overlay; deviation states map to .tint',
    run = function()
      t.eq(groups.tintKey('synced'),     nil)
      t.eq(groups.tintKey('overridden'), 'mirror.overridden.tint')
      t.eq(groups.tintKey('conflicted'), 'mirror.conflicted.tint')
    end,
  },
  {
    name = 'regionKey/outlineKey: group hue by default, conflicted is loud',
    run = function()
      t.eq(groups.regionKey(3, 'tint'),    'region.3.tint')
      t.eq(groups.regionKey(1, 'outline'), 'region.1.outline')
      t.eq(groups.outlineKey('conflicted', 5), 'mirror.conflicted.outline')
      t.eq(groups.outlineKey('synced', 5),     'region.5.outline')
    end,
  },
  {
    name = 'eachInstance enumerates every instance with rect+anchor+active',
    run = function()
      local gm = mk()
      local gid  = gm:mark({ note(0, 1) }, rect)   -- mark sets active
      gm:newInstance(gid, { ppq = 960, chan = 1 })
      local all = gm:eachInstance()
      t.eq(#all, 2, 'two instances enumerated')
      table.sort(all, function(a, b) return a.instId < b.instId end)
      t.eq(all[1].rect, rect,       'rect returned by reference')
      t.eq(all[1].anchor.ppq, 0,    'instance 1 at the region origin')
      t.eq(all[2].anchor.ppq, 960,  'instance 2 at the stamp ppq')
      t.truthy(all[1].active and all[2].active, 'mark made the group active')
      t.eq(all[1].colour, 1, 'group 1 -> region hue 1')
    end,
  },
  {
    name = 'eachInstance: a markGroup (no copy) group is inactive',
    run = function()
      local gm = mk()
      gm:markGroup({ note(0, 1) }, rect)           -- no active set
      local all = gm:eachInstance()
      t.eq(#all, 1)
      t.falsy(all[1].active, 'markGroup does not set active')
    end,
  },
}
