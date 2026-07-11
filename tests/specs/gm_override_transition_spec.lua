-- Override transitions (docs/groupManager.md "Override transitions").
--
-- Two mechanisms, one principle: a local override pins this instance's
-- visible event at a slot; a group-event existence flip never silently
-- breaks that pin.
--
--  Same-instance, global mode -- "on-ov => local":
--    add-ov    + amend  -> edit the add locally (no propagation)
--    add-ov    + delete -> the local add is just gone
--    assign-ov + amend  -> edit the divergence locally (group untouched)
--    assign-ov + delete -> drop the divergence, rejoin the group value
--    delete-ov + delete -> no-op (unreachable by construction: a hidden
--                          slot has no concrete event to delete -- the
--                          guard only stops a propagating group delete)
--
--  Cross-instance (a SIBLING carries the override):
--    sibling add-ov    + peer global CREATE at that slot -> upgrade to
--                          an assign-ov on the now-real vuid
--    sibling assign-ov + peer global DELETE of that event -> demote to
--                          a materialised add-ov
--
-- Real gm; fake tm/cm as in mirm_propagate_spec. tm:flush(adds,
-- assigns, deletes) drives the real preflush/applyEdit/reproject path.

local t    = require('support')
local util = require('util')

local function fakeTm()
  local hooks, staged, seq = {}, { add = {}, assign = {}, del = {} }, 0
  local tm = {}
  function tm:length()            return math.huge end   -- off-take clip irrelevant here
  function tm:subscribe(sig, fn)  hooks[sig] = fn end
  function tm:requestRebuild()    end
  function tm:addEvent(evt)       staged.add[#staged.add + 1] = evt end
  function tm:assignEvent(evt, u) staged.assign[#staged.assign + 1] = { evt = evt, update = u } end
  function tm:deleteEvent(evt)    staged.del[#staged.del + 1] = evt end
  function tm:flush(adds, assigns, deletes)
    if hooks.preflush then hooks.preflush(adds or {}, assigns or {}, deletes or {}) end
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
local function note(ppq, chan, lane, extra)
  nextUuid = nextUuid + 1
  local n = { evType = 'note', chan = chan, lane = lane, ppq = ppq,
              endppq = ppq + 240, pitch = 60, vel = 100, uuid = nextUuid }
  for k, v in pairs(extra or {}) do n[k] = v end
  return n
end

local function rect(ppq, chan)
  return { ppq = ppq, dur = 960, chanLo = chan,
           streams = { [0] = { ['note:1'] = true } } }
end

-- Pitch of the lone event a fresh probe instance projects (group state
-- as every clean sibling sees it); nil if the group projects nothing.
local function groupPitch(gm, tm, staged, anchorPpq)
  local before = #staged.add
  gm:newInstance(1, { ppq = anchorPpq, chan = 1 })
  tm:flush()
  for i = #staged.add, before + 1, -1 do
    if staged.add[i].evType == 'note' then return staged.add[i].pitch end
  end
  return nil
end

return {
  {
    name = 'assign-ov + global amend stays local: shared group untouched',
    run = function()
      local gm, tm, staged = mk()
      local src = note(0, 1, 1, { pitch = 60 })
      gm:markGroup({ src }, rect(0, 1))
      gm:newInstance(1, { ppq = 960, chan = 1 })
      tm:flush(); staged.add = {}

      gm:setLocalMode(true)                 -- assign-ov on src (instance 1)
      gm:assignEvent(src.uuid, { pitch = 80 })
      tm:flush()
      gm:setLocalMode(false)

      staged.add, staged.assign = {}, {}
      gm:assignEvent(src.uuid, { pitch = 90 })
      tm:flush()

      -- No assign carried pitch 90 onto a foreign event, and the shared
      -- group still projects 60 to a clean probe.
      for _, a in ipairs(staged.assign) do
        if a.update.pitch ~= nil then
          t.eq(a.evt, src, 'only the diverged origin itself moved; no propagation')
        end
      end
      t.eq(groupPitch(gm, tm, staged, 1920), 60,
        'shared group value is untouched by the on-ov edit')
    end,
  },

  {
    name = 'assign-ov + global delete drops the divergence, group survives',
    run = function()
      local gm, tm, staged = mk()
      local src = note(0, 1, 1, { pitch = 60 })
      gm:markGroup({ src }, rect(0, 1))
      gm:newInstance(1, { ppq = 960, chan = 1 })
      tm:flush(); staged.add = {}

      gm:setLocalMode(true)
      gm:assignEvent(src.uuid, { pitch = 80 })
      tm:flush()
      gm:setLocalMode(false)

      staged.add, staged.del = {}, {}
      gm:deleteEvent(src.uuid); tm:flush()    -- delete on the assign-ov

      t.eq(#staged.del, 0,
        'no propagating group delete: the shared event survives')
      t.eq(groupPitch(gm, tm, staged, 1920), 60,
        'group still projects its value to a clean probe')
    end,
  },

  {
    name = 'assign-ov + global delete re-materialises the group note in the acting instance',
    run = function()
      local gm, tm, staged = mk()
      local src = note(0, 1, 1, { pitch = 60 })
      gm:markGroup({ src }, rect(0, 1))      -- instance 1 @ anchor 0
      gm:newInstance(1, { ppq = 960, chan = 1 })
      tm:flush(); staged.add = {}

      gm:setLocalMode(true)
      gm:assignEvent(src.uuid, { pitch = 80 })
      tm:flush()
      gm:setLocalMode(false)

      staged.add, staged.del = {}, {}
      gm:deleteEvent(src.uuid); tm:flush()     -- delete on the assign-ov

      -- Facade delete peels the override but spares the concrete: the surviving
      -- concrete is re-SET to the group value (60) in place, not del+add.
      local back
      for _, a in ipairs(staged.assign) do
        if a.evt == src and a.update.pitch ~= nil then back = a.update.pitch end
      end
      t.eq(back, 60, 'the cell rejoins the group: surviving concrete re-set to the group value')
    end,
  },

  {
    name = 'add-ov + global delete removes the local add (no crash, group intact)',
    run = function()
      local gm, tm, staged = mk()
      local src = note(0, 1, 1)
      gm:markGroup({ src }, rect(0, 1))
      tm:flush(); staged.add = {}

      gm:setLocalMode(true)
      local born = note(480, 1, 1, { pitch = 65 })
      gm:addEvent(born); tm:flush()            -- local-only add in instance 1
      local made
      for _, e in ipairs(staged.add) do if e.ppq == 480 then made = e end end
      staged.add = {}
      gm:setLocalMode(false)

      gm:deleteEvent(made.uuid); tm:flush()    -- delete on the add-ov

      -- The group never carried `born`; a probe still shows only the
      -- single seeded event, and nothing blew up.
      t.eq(groupPitch(gm, tm, staged, 1920), 60,
        'the shared group is unchanged; the add was purely local')
    end,
  },

  {
    name = 'add-ov + global amend edits the add locally, never the group',
    run = function()
      local gm, tm, staged = mk()
      local src = note(0, 1, 1)
      gm:markGroup({ src }, rect(0, 1))
      tm:flush(); staged.add = {}

      gm:setLocalMode(true)
      local born = note(480, 1, 1, { pitch = 65 })
      gm:addEvent(born); tm:flush()
      local made
      for _, e in ipairs(staged.add) do if e.ppq == 480 then made = e end end
      staged.add = {}
      gm:setLocalMode(false)

      gm:assignEvent(made.uuid, { pitch = 70 })
      tm:flush()

      t.eq(groupPitch(gm, tm, staged, 1920), 60,
        'editing the local add did not leak into the shared group')
    end,
  },

  {
    name = 'sibling add-ov upgrades to assign-ov on a peer global create',
    run = function()
      local gm, tm, staged = mk()
      local src = note(0, 1, 1, { pitch = 60 })
      gm:markGroup({ src }, rect(0, 1))              -- instance 1 @ anchor 0
      gm:newInstance(1, { ppq = 960, chan = 1 })     -- instance 2 @ anchor 960
      tm:flush(); staged.add = {}

      -- Instance 2 grows a local add at the (group-frame) empty slot 480.
      gm:setLocalMode(true)
      local sibAdd = note(1440, 1, 1, { pitch = 70 })  -- 960 + 480
      gm:addEvent(sibAdd); tm:flush()
      staged.add, staged.del = {}, {}
      gm:setLocalMode(false)

      -- Instance 1 globally creates a real event at group slot 480.
      local peer = note(480, 1, 1, { pitch = 50 })
      gm:addEvent(peer); tm:flush()

      -- Instance 2 keeps pitch 70 there (add-ov absorbed into an
      -- assign-ov over the new group event), while a clean probe sees 50.
      local kept
      for _, a in ipairs(staged.add) do
        if a.ppq == 1440 then kept = a.pitch end
      end
      t.eq(kept, 70, 'sibling divergence preserved as an assign-ov')
      t.eq(groupPitch(gm, tm, staged, 1920), 50,
        'the new group event propagates to clean instances at 50')
    end,
  },

  {
    name = 'sibling assign-ov demotes to a materialised add on a peer global delete',
    run = function()
      local gm, tm, staged = mk()
      local src = note(0, 1, 1, { pitch = 60 })
      gm:markGroup({ src }, rect(0, 1))              -- instance 1 @ anchor 0
      gm:newInstance(1, { ppq = 960, chan = 1 })     -- instance 2 @ anchor 960
      tm:flush()
      local sib
      for _, e in ipairs(staged.add) do if e.ppq == 960 then sib = e end end
      t.truthy(sib, 'instance 2 has a concrete sibling event')
      staged.add = {}

      -- Instance 2 diverges its copy (assign-ov on the shared vuid).
      gm:setLocalMode(true)
      gm:assignEvent(sib.uuid, { pitch = 88 })
      tm:flush()
      gm:setLocalMode(false)
      staged.add, staged.del = {}, {}

      -- Instance 1 globally deletes the shared event.
      gm:deleteEvent(src.uuid); tm:flush()

      -- The shared event is gone for clean instances, but instance 2
      -- keeps its diverged note (now a materialised local add @ 960/88).
      t.eq(groupPitch(gm, tm, staged, 1920), nil,
        'group event deleted: a clean probe projects nothing')
      local survived
      for _, a in ipairs(staged.add) do
        if a.ppq == 960 then survived = a.pitch end
      end
      t.eq(survived, 88, 'sibling divergence survives as a materialised add')
    end,
  },
}
