-- gm active-group selector (dupeClip idiom). mark = case 1 (group, no
-- copy). stamp = case 2 (no active: seed group + first copy, group goes
-- active) or case 3 (active live: one more copy, no new group).
-- clearActive drops the pointer so the next stamp seeds afresh.

local t    = require('support')
local util = require('util')

local function fakeTm()
  local hooks, staged, seq = {}, { add = {}, assign = {}, del = {} }, 0
  local tm = {}
  function tm:subscribe(sig, fn)  hooks[sig] = fn end
  function tm:addEvent(evt)       staged.add[#staged.add + 1] = evt end
  function tm:assignEvent(e, u)   staged.assign[#staged.assign + 1] = { evt = e, update = u } end
  function tm:deleteEvent(evt)    staged.del[#staged.del + 1] = evt end
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

local function note(ppq) return { evType = 'note', chan = 1, lane = 1,
  ppq = ppq, endppq = ppq + 240, pitch = 60, vel = 100 } end

local function rect() return { ppq = 0, dur = 960, chanLo = 1,
  streams = { [0] = { ['note:1'] = true } } } end

return {
  {
    name = 'mark seeds a group, copies nothing, and makes it active',
    run = function()
      local gm, staged = mk()
      local gid = gm:mark({ note(0) }, rect())
      t.truthy(gid)
      t.eq(gm:activeGroup(), gid, 'marked group is active')
      t.eq(#staged.add, 0, 'mark does not stage any copy')
    end,
  },

  {
    name = 'stamp with no active seeds group + first copy, returns (gid, iid), goes active',
    run = function()
      local gm, staged = mk()
      local gid, iid = gm:stamp({ note(0) }, rect(), { ppq = 960, chan = 1 })
      t.truthy(gid); t.truthy(iid)
      t.eq(gm:activeGroup(), gid)
      t.eq(#staged.add, 1, 'first copy staged at the anchor')
      t.eq(staged.add[1].ppq, 960)
    end,
  },

  {
    name = 'stamp with active live drops one more copy, no new group (single return)',
    run = function()
      local gm, staged = mk()
      local gid = gm:stamp({ note(0) }, rect(), { ppq = 960, chan = 1 })
      local r2, r3 = gm:stamp({ note(0) }, rect(), { ppq = 1920, chan = 1 })

      t.eq(gm:activeGroup(), gid, 'still the same active group')
      t.eq(r3, nil, 'active path returns instId only, not (gid, iid)')
      t.truthy(r2, 'a fresh instId for the existing group')
      t.eq(#staged.add, 2, 'second stamp added one more copy, not a new group')
      t.eq(staged.add[2].ppq, 1920)
    end,
  },

  {
    name = 'clearActive drops the pointer; the next stamp seeds a fresh group',
    run = function()
      local gm = mk()
      local gid1 = gm:stamp({ note(0) }, rect(), { ppq = 960, chan = 1 })
      gm:clearActive()
      t.eq(gm:activeGroup(), nil)

      -- A fresh group must be seeded at a non-overlapping region (a
      -- re-seed over the cleared group's footprint is rejected).
      local far = { ppq = 2880, dur = 960, chanLo = 1,
                    streams = { [0] = { ['note:1'] = true } } }
      local gid2, iid2 = gm:stamp({ note(0) }, far, { ppq = 3840, chan = 1 })
      t.truthy(iid2, 'new group path returns (gid, iid)')
      t.truthy(gid2 ~= gid1, 'a distinct group, not the cleared one')
      t.eq(gm:activeGroup(), gid2)
    end,
  },
}
