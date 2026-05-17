-- A group two channels wide, note lane 1 in each, notes at the same onset.
-- The group-frame slot/lane identity must include the channel offset:
-- streamId alone is evType:key (lane), so two channels at the same lane and
-- onset collapse to one slot. mirror.project's slot-dedup then conflicts the
-- higher-vuid (rightmost) note out of `desired`, so it never projects into a
-- copy and never propagates -- only the leftmost channel mirrors.
--
-- Same faithful-fake seam as mirm_propagate_spec.

local t    = require('support')
local util = require('util')

local function fakeTm()
  local hooks, staged, seq = {}, { add = {}, assign = {}, del = {} }, 0
  local tm = {}
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

local function fakeCm()
  local store = {}
  return {
    get = function(_, k) return store[k] end,
    set = function(_, _lvl, k, v) store[k] = v end,
  }
end

local function mk()
  local tm, staged = fakeTm()
  local mirm = util.instantiate('mirrorManager', { tm = tm, cm = fakeCm() })
  return mirm, tm, staged
end

local nextUuid = 0
local function note(chan, ppq, endppq, pitch)
  nextUuid = nextUuid + 1
  return { evType = 'note', chan = chan, lane = 1, ppq = ppq,
           endppq = endppq, pitch = pitch, vel = 100, uuid = nextUuid }
end

local function rect2ch()
  return { ppq = 0, dur = 480, chanLo = 1,
           streams = { [0] = { ['note:1'] = true },
                       [1] = { ['note:1'] = true } } }
end

local function copyNotesByChan(staged)
  local byChan = {}
  for _, e in ipairs(staged.add) do
    if e.evType == 'note' and e.ppq == 480 then
      byChan[e.chan] = (byChan[e.chan] or 0) + 1
    end
  end
  return byChan
end

return {
  {
    name = 'a two-channel group projects both channels into a duplicate copy',
    run = function()
      local mirm, tm, staged = mk()
      local c1 = note(1, 0, 240, 60)
      local c2 = note(2, 0, 240, 67)

      -- Cascade seed: nil group -> markGroup + first copy one region below
      -- at the same chanLo, so the copy spans chan 1 and chan 2 too.
      mirm:duplicateInto(nil, { c1, c2 }, rect2ch(), { ppq = 480, chan = 1 })
      tm:flush()

      local byChan = copyNotesByChan(staged)
      t.eq(byChan[1], 1, 'copy has the channel-1 note')
      t.eq(byChan[2], 1, 'copy has the channel-2 note (not conflicted out)')
    end,
  },
}
