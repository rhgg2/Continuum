-- A mirror group may extend off the bottom of the take, but the
-- REALISED concretes are clipped to the take edge: a projected note
-- whose onset lands at or past tm:length() is withheld (it would push
-- REAPER's EOT out and grow the take). The group keeps every member,
-- so a sibling placed fully in-bounds still projects them all, and a
-- withheld member revives the moment an instance brings it on-take.
--
-- This parallels tm's tail clamp (which only bounds note-OFFs); the
-- onset clip lives in gm because gm is the only layer that knows where
-- each projected concrete lands. Pinned against the real
-- newInstance/preflush/reproject path with a faithful fake tm.

local t    = require('support')
local util = require('util')

local TAKE = 4000

local function fakeTm()
  local hooks, staged, seq = {}, { add = {}, assign = {}, del = {} }, 0
  local tm = {}
  function tm:subscribe(sig, fn)  hooks[sig] = fn end
  function tm:addEvent(evt)       staged.add[#staged.add + 1] = evt end
  function tm:assignEvent(evt, u) staged.assign[#staged.assign + 1] = { evt = evt, update = u } end
  function tm:deleteEvent(evt)    staged.del[#staged.del + 1] = evt end
  function tm:length()            return TAKE end
  function tm:flush()
    if hooks.preflush then hooks.preflush({}, {}, {}) end
    for _, e in ipairs(staged.add) do
      if e.uuid == nil then seq = seq + 1; e.uuid = 1000 + seq end
    end
    if hooks.postflush then hooks.postflush() end
  end
  return tm, staged
end

local function mk()
  local tm, staged = fakeTm()
  local gm = util.instantiate('groupManager', { tm = tm, ds = t.fakeDs() })
  return gm, tm, staged
end

local nextUuid = 0
local function note(ppq, pitch)
  nextUuid = nextUuid + 1
  return { evType = 'note', chan = 1, lane = 1, ppq = ppq,
           endppq = ppq + 240, endppqL = ppq + 240, pitch = pitch,
           vel = 100, uuid = nextUuid }
end

-- 960-wide region; members on rows 0/240/480/720.
local function rect() return { ppq = 0, dur = 960, chanLo = 1,
                               streams = { [0] = { ['note:1'] = true } } } end

local function addAt(staged, ppq)
  for _, e in ipairs(staged.add) do if e.ppq == ppq then return e end end
end

return {
  {
    name = 'an instance straddling the take edge writes only on-take concretes',
    run = function()
      local gm, tm, staged = mk()
      local A, B, C, D = note(0, 60), note(240, 62), note(480, 64), note(720, 65)
      local gid = gm:markGroup({ A, B, C, D }, rect())

      -- Anchor 3600 (< TAKE) -> onsets 3600, 3840, 4080, 4320; the take
      -- edge is 4000, so the last two are off-take.
      gm:newInstance(gid, { ppq = 3600, chan = 1 })
      tm:flush()

      for _, e in ipairs(staged.add) do
        t.truthy(e.ppq < TAKE, 'no concrete written at/past the take edge (got ' .. e.ppq .. ')')
      end
      t.truthy(addAt(staged, 3600), 'on-take member 3600 written')
      t.truthy(addAt(staged, 3840), 'on-take member 3840 written')
      t.falsy(addAt(staged, 4080), 'off-take member 4080 withheld')
      t.falsy(addAt(staged, 4320), 'off-take member 4320 withheld')
    end,
  },

  {
    name = 'the group keeps every member -- an in-bounds sibling projects them all',
    run = function()
      local gm, tm, staged = mk()
      local A, B, C, D = note(0, 60), note(240, 62), note(480, 64), note(720, 65)
      local gid = gm:markGroup({ A, B, C, D }, rect())

      gm:newInstance(gid, { ppq = 3600, chan = 1 })   -- clips to 2
      tm:flush()
      staged.add = {}

      -- A sibling fully inside the take projects all four: the off-bottom
      -- clip is per-instance realisation, never a loss of group membership.
      gm:newInstance(gid, { ppq = 960, chan = 1 })
      tm:flush()
      t.eq(#staged.add, 4, 'every member projects when the instance fits')
    end,
  },
}
