-- Revive-on-type. A group event the *current* instance locally deleted is
-- still alive in the shared group. In global mode, a create on that slot
-- must clear the local delete and overwrite the existing group vuid -- not
-- allocate a fresh vuid, which would leave two coincident group events and
-- corrupt every sibling that never deleted it.
--
-- Same faithful-fake seam as mirm_propagate_spec: real gm rides the fake
-- tm's preflush/postflush; group state is read back by projecting a fresh
-- instance and counting its staged concrete copies.

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
  local tm, staged = fakeTm()
  local gm = util.instantiate('groupManager', { tm = tm, ds = t.fakeDs() })
  return gm, tm, staged
end

local nextUuid = 0
local function note(ppq, chan, lane, pitch)
  nextUuid = nextUuid + 1
  return { evType = 'note', chan = chan, lane = lane, ppq = ppq,
           endppq = ppq + 240, pitch = pitch, vel = 100, uuid = nextUuid }
end

-- One note:1 stream on the anchor channel, four bars-worth wide.
local function rect(ppq, chan)
  return { ppq = ppq, dur = 960, chanLo = chan,
           streams = { [0] = { ['note:1'] = true } } }
end

local function atPpq(list, ppq)
  for _, e in ipairs(list) do if e.ppq == ppq then return e end end
end

return {
  {
    name = 'global create on a slot this instance locally deleted revives the existing group vuid',
    run = function()
      local gm, tm, staged = mk()
      -- Group ABCD: back-to-back lane-1 notes, distinct pitches.
      local abcd = { note(0, 1, 1, 60), note(240, 1, 1, 61),
                     note(480, 1, 1, 62), note(720, 1, 1, 63) }
      local gid = gm:markGroup(abcd, rect(0, 1))

      gm:newInstance(gid, { ppq = 960, chan = 1 })   -- instance Y
      tm:flush()                                        -- commit + stamp uuids
      local yC = atPpq(staged.add, 1440)                -- Y's C (anchor 960 + 480)
      t.truthy(yC, 'Y projected C at 1440')
      staged.add = {}

      -- Locally delete C in Y, then leave local mode.
      gm:setLocalMode(true)
      gm:deleteEvent(yC.uuid); tm:flush()
      gm:setLocalMode(false)

      -- Type a new note over the now-empty C cell in Y (global mode).
      local born = note(1440, 1, 1, 99)
      gm:addEvent(born); tm:flush()

      -- Read the group back via a pristine fresh instance Z.
      staged.add = {}
      local iidZ = gm:newInstance(gid, { ppq = 2880, chan = 1 })
      t.truthy(iidZ, 'Z projects the group')

      t.eq(#staged.add, 4,
        'group still has four events -- C revived in place, no fifth vuid')
      local zC = atPpq(staged.add, 3360)                -- 2880 + 480 (C slot)
      t.truthy(zC, 'C slot still occupied by exactly one event')
      t.eq(zC.pitch, 99, 'C overwritten with the typed note, not a coincident dup')
    end,
  },
}
