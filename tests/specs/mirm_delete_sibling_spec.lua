-- Deleting both notes of a mirror instance must propagate BOTH deletes
-- to the sibling. Repro: AB group at instance 1; mirror-duplicate down
-- (instance 2); delete instance 2's A then its B. The sibling's A AND B
-- must both be staged for deletion -- the reported bug left the sibling
-- B alive (a stray B in the source region).

local t    = require('support')
local util = require('util')

local function fakeTm()
  local hooks, staged, seq = {}, { add = {}, assign = {}, del = {} }, 0
  local tm = {}
  function tm:subscribe(sig, fn)  hooks[sig] = fn end
  function tm:addEvent(evt)       staged.add[#staged.add + 1] = evt end
  function tm:assignEvent(evt, u) staged.assign[#staged.assign + 1] = { evt = evt, update = u } end
  function tm:deleteEvent(evt)    staged.del[#staged.del + 1] = evt end
  function tm:length()            return 4000 end
  function tm:flush(adds, assigns, deletes)
    if hooks.preflush then hooks.preflush(adds or {}, assigns or {}, deletes or {}) end
    for _, e in ipairs(staged.add) do
      if e.uuid == nil then seq = seq + 1; e.uuid = 1000 + seq end
    end
    if hooks.postflush then hooks.postflush() end
  end
  return tm, staged, hooks
end

local function fakeCm()
  local store = {}
  return { get = function(_, k) return store[k] end,
           set = function(_, _l, k, v) store[k] = v end }
end

local function mk()
  local tm, staged = fakeTm()
  local mirm = util.instantiate('mirrorManager', { tm = tm, cm = fakeCm() })
  return mirm, tm, staged
end

local nextUuid = 0
local function note(ppq, pitch)
  nextUuid = nextUuid + 1
  return { evType = 'note', chan = 1, lane = 1, ppq = ppq,
           endppq = ppq + 240, pitch = pitch, vel = 100, uuid = nextUuid }
end
local function rect() return { ppq = 0, dur = 960, chanLo = 1,
                               streams = { [0] = { ['note:1'] = true } } } end

-- The instance-2 copy at a given ppq among the staged adds.
local function copyAt(staged, ppq)
  for _, e in ipairs(staged.add) do if e.ppq == ppq then return e end end
end

local function delPitches(staged)
  local s = {}
  for _, e in ipairs(staged.del) do s[e.pitch] = true end
  return s
end

return {
  {
    name = 'deleting both instance notes one flush at a time propagates both deletes',
    run = function()
      local mirm, tm, staged = mk()
      local A, B = note(0, 60), note(240, 62)
      local gid = mirm:markGroup({ A, B }, rect())
      mirm:newInstance(gid, { ppq = 960, chan = 1 })       -- instance 2
      tm:flush()
      local copyA = copyAt(staged, 960)
      local copyB = copyAt(staged, 1200)
      t.truthy(copyA and copyB, 'instance 2 materialised A and B')
      staged.add, staged.assign, staged.del = {}, {}, {}

      tm:flush({}, {}, { { evt = copyA } })                -- delete copy A
      t.truthy(delPitches(staged)[60], 'sibling A deleted after first delete')
      staged.del = {}

      tm:flush({}, {}, { { evt = copyB } })                -- delete copy B
      t.truthy(delPitches(staged)[62], 'sibling B deleted after second delete')
    end,
  },

  {
    name = 'deleting both instance notes in one flush propagates both deletes',
    run = function()
      local mirm, tm, staged = mk()
      local A, B = note(0, 60), note(240, 62)
      local gid = mirm:markGroup({ A, B }, rect())
      mirm:newInstance(gid, { ppq = 960, chan = 1 })
      tm:flush()
      local copyA = copyAt(staged, 960)
      local copyB = copyAt(staged, 1200)
      staged.add, staged.assign, staged.del = {}, {}, {}

      tm:flush({}, {}, { { evt = copyA }, { evt = copyB } })
      local d = delPitches(staged)
      t.truthy(d[60], 'sibling A deleted')
      t.truthy(d[62], 'sibling B deleted')
    end,
  },

  {
    name = 'deleting the predecessor must not shrink an infinite last-in-lane tail',
    run = function()
      local mirm, tm, staged = mk()
      -- A adopted (finite); B *created* into the region so it is the
      -- last-in-lane note with an infinite group tail (runs to take end).
      local A = note(0, 60)
      local gid = mirm:markGroup({ A }, rect())
      local B = note(240, 62)
      tm:flush({ { evt = B } }, {}, {})                    -- create B: infinite tail
      mirm:newInstance(gid, { ppq = 960, chan = 1 })       -- instance 2
      tm:flush()
      local copyA = copyAt(staged, 960)
      t.truthy(copyA, 'instance 2 copy of A materialised')
      staged.add, staged.assign, staged.del = {}, {}, {}

      tm:flush({}, {}, { { evt = copyA } })                -- delete instance 2's A

      -- A fresh instance reveals the shared group's B tail: it must still
      -- run to take length (4000), not have collapsed to B's 240 dur.
      mirm:newInstance(gid, { ppq = 2000, chan = 1 })
      local freshB
      for _, e in ipairs(staged.add) do if e.pitch == 62 then freshB = e end end
      t.truthy(freshB, 'fresh instance projected B')
      t.eq(freshB.endppq - freshB.ppq, 4000 - 240,
        'B keeps its infinite (take-length) group tail after the delete')
    end,
  },
}
