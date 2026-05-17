-- Step 1 of the mirror replay model: a tracker edit on a concrete
-- instance event is transferred into the GROUP frame, then tv's legato
-- rule is applied within the group's own event set so group.events
-- stays the canonical pristine pattern.
--
-- Observed through the real preflush/reproject seam, asserted via what
-- reproject stages onto the *sibling* (mirm_propagate's idiom). The
-- decisive case is a group-level delete *growing* the predecessor:
-- Step 2's project clip-only pass can never grow a tail, so this can
-- only come from group-frame deleteFixups. The create case is a
-- consistency pin of the combined reprojection.

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
local function note(ppq, pitch, dur)
  nextUuid = nextUuid + 1
  return { evType = 'note', chan = 1, lane = 1, ppq = ppq,
           endppq = ppq + (dur or 240), pitch = pitch, vel = 100, uuid = nextUuid }
end

-- One note:1 stream on ch1, a wide region so rect.dur is never the
-- binding backstop in these cases.
local function rect() return { ppq = 0, dur = 2000, chanLo = 1,
                               streams = { [0] = { ['note:1'] = true } } } end

-- The B-pitched assign reprojected onto the sibling (anchor 1000); its
-- dur is the group-frame truth rebased.
local function siblingB(staged)
  for _, a in ipairs(staged.assign) do
    if a.evt.pitch == 62 and a.update.endppq ~= nil then
      return a.update.endppq - (a.update.ppq or a.evt.ppq)
    end
  end
end

return {
  {
    name = 'a group-level delete grows the predecessor in the group frame (ABC.D -> B to D)',
    run = function()
      local mirm, tm, staged = mk()
      local A, B, C, D = note(0, 60), note(240, 62), note(480, 64), note(720, 65)
      local gid = mirm:markGroup({ A, B, C, D }, rect())
      mirm:newInstance(gid, { ppq = 1000, chan = 1 })  -- sibling Y
      tm:flush(); staged.add, staged.assign, staged.del = {}, {}, {}

      tm:flush({}, {}, { { evt = C } })                -- non-local delete of C

      t.eq(siblingB(staged), 480,
        'B legato-grew to D onset in group frame -> dur 480 on the sibling')
      local delPitches = {}
      for _, e in ipairs(staged.del) do delPitches[e.pitch] = true end
      t.truthy(delPitches[64], 'C is deleted on the sibling too')
    end,
  },

  {
    name = 'a group-level create clips the predecessor it lands inside (group frame)',
    run = function()
      local mirm, tm, staged = mk()
      local A = note(0, 60, 480)                        -- A overruns to 480
      local gid = mirm:markGroup({ A }, rect())
      mirm:newInstance(gid, { ppq = 1000, chan = 1 })
      tm:flush(); staged.add, staged.assign, staged.del = {}, {}, {}

      local born = note(240, 62, 240)                   -- created at group ppq 240
      tm:flush({ { evt = born } }, {}, {})

      -- A's tail must be the group-frame legato result (clipped to the
      -- new note's onset, 240), reprojected onto the sibling.
      local aDur
      for _, a in ipairs(staged.assign) do
        if a.evt.pitch == 60 and a.update.endppq ~= nil then
          aDur = a.update.endppq - (a.update.ppq or a.evt.ppq)
        end
      end
      t.eq(aDur, 240, 'A clipped to the inserted note in the group frame')
    end,
  },

  {
    name = 'a create that lands last-in-lane gets an infinite group tail (runs to end of take)',
    run = function()
      local mirm, tm, staged = mk()
      local A = note(0, 60, 240)
      local gid = mirm:markGroup({ A }, rect())
      mirm:newInstance(gid, { ppq = 1000, chan = 1 })
      tm:flush(); staged.add, staged.assign, staged.del = {}, {}, {}

      local born = note(240, 62, 240)                   -- created after A: last in lane
      tm:flush({ { evt = born } }, {}, {})

      -- The sibling copy: project clips the infinite group dur to
      -- patternLen (fake tm:length 4000), not the 240 birth dur.
      local bornDur, bornConform
      for _, e in ipairs(staged.add) do
        if e.pitch == 62 then
          bornDur, bornConform = e.endppq - e.ppq, e.conform
        end
      end
      t.eq(bornDur, 4000 - 240, 'birth dur discarded; tail runs to end of take')
      t.truthy(bornConform, 'last-in-lane copy is conform-marked')

      -- An explicit length (adjustDuration/noteOff) is a non-create
      -- assign: it must be kept, not re-opened to infinite.
      staged.add, staged.assign, staged.del = {}, {}, {}
      tm:flush({}, { { evt = born, update = { ppq = born.ppq, endppq = born.ppq + 360 } } }, {})
      local kept
      for _, a in ipairs(staged.assign) do
        if a.evt.pitch == 62 and a.update.endppq ~= nil then
          kept = a.update.endppq - (a.update.ppq or a.evt.ppq)
        end
      end
      t.eq(kept, 360, 'explicit duration adjust is preserved on the last-in-lane note')
    end,
  },

}
