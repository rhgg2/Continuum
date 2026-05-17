-- Override transitions (docs/mirrorManager.md "Override transitions").
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
-- Real mirm; fake tm/cm as in mirm_propagate_spec. tm:flush(adds,
-- assigns, deletes) drives the real preflush/applyEdit/reproject path.

local t    = require('support')
local util = require('util')

local function fakeTm()
  local hooks, staged, seq = {}, { add = {}, assign = {}, del = {} }, 0
  local tm = {}
  function tm:subscribe(sig, fn)  hooks[sig] = fn end
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
local function groupPitch(mirm, tm, staged, anchorPpq)
  local before = #staged.add
  mirm:newInstance(1, { ppq = anchorPpq, chan = 1 })
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
      local mirm, tm, staged = mk()
      local src = note(0, 1, 1, { pitch = 60 })
      mirm:markGroup({ src }, rect(0, 1))
      mirm:newInstance(1, { ppq = 960, chan = 1 })
      tm:flush(); staged.add = {}

      mirm:setLocalMode(true)                 -- assign-ov on src (instance 1)
      tm:flush({}, { { evt = src, update = { pitch = 80 } } }, {})
      mirm:setLocalMode(false)

      staged.add, staged.assign = {}, {}
      tm:flush({}, { { evt = src, update = { pitch = 90 } } }, {})

      -- No assign carried pitch 90 onto a foreign event, and the shared
      -- group still projects 60 to a clean probe.
      for _, a in ipairs(staged.assign) do
        if a.update.pitch ~= nil then
          t.eq(a.evt, src, 'only the diverged origin itself moved; no propagation')
        end
      end
      t.eq(groupPitch(mirm, tm, staged, 1920), 60,
        'shared group value is untouched by the on-ov edit')
    end,
  },

  {
    name = 'assign-ov + global delete drops the divergence, group survives',
    run = function()
      local mirm, tm, staged = mk()
      local src = note(0, 1, 1, { pitch = 60 })
      mirm:markGroup({ src }, rect(0, 1))
      mirm:newInstance(1, { ppq = 960, chan = 1 })
      tm:flush(); staged.add = {}

      mirm:setLocalMode(true)
      tm:flush({}, { { evt = src, update = { pitch = 80 } } }, {})
      mirm:setLocalMode(false)

      staged.add, staged.del = {}, {}
      tm:flush({}, {}, { { evt = src } })     -- delete on the assign-ov

      t.eq(#staged.del, 0,
        'no propagating group delete: the shared event survives')
      t.eq(groupPitch(mirm, tm, staged, 1920), 60,
        'group still projects its value to a clean probe')
    end,
  },

  {
    name = 'assign-ov + global delete re-materialises the group note in the acting instance',
    run = function()
      local mirm, tm, staged = mk()
      local src = note(0, 1, 1, { pitch = 60 })
      mirm:markGroup({ src }, rect(0, 1))      -- instance 1 @ anchor 0
      mirm:newInstance(1, { ppq = 960, chan = 1 })
      tm:flush(); staged.add = {}

      mirm:setLocalMode(true)
      tm:flush({}, { { evt = src, update = { pitch = 80 } } }, {})
      mirm:setLocalMode(false)

      staged.add, staged.del = {}, {}
      tm:flush({}, {}, { { evt = src } })      -- delete on the assign-ov

      -- The user's delete removed the concrete; dropping the divergence
      -- must rejoin the group, so the acting instance re-adds the
      -- group-projected note (pitch 60) at its own slot.
      local back
      for _, a in ipairs(staged.add) do
        if a.ppq == 0 and a.evType == 'note' then back = a.pitch end
      end
      t.eq(back, 60, 'the cell rejoins the group: group note resurfaces here')
    end,
  },

  {
    -- tv is mirror-unaware: deleting Q stages, in the same flush, a
    -- legato GROW of the predecessor P's concrete (it sees a hole). The
    -- group frame re-clips P to the still-present original's onset, but
    -- P's grown *concrete* must be clipped back too or it overlaps the
    -- resurfaced note and tv bumps it to a sibling lane. reproject only
    -- re-drives a concrete when the group geometry changed; P's did not
    -- (only the note's identity at the onset did), so the projection
    -- shadow must be refreshed from the live concrete first.
    name = 'assign-ov + global delete clips the legato predecessor back',
    run = function()
      local mirm, tm, staged = mk()
      -- p is long enough to already be legato-clipped to q's onset in
      -- the group steady state, so its group dur never moves across the
      -- delete flush -- only its concrete (tv-grown) does.
      local p = note(0,   1, 1, { endppq = 960 })  -- predecessor, same lane
      local q = note(480, 1, 1)                     -- slot that gets diverged
      mirm:markGroup({ p, q }, rect(0, 1))   -- instance 1 @ anchor 0
      tm:flush(); staged.add, staged.assign = {}, {}

      mirm:setLocalMode(true)               -- diverge q (assign-ov)
      tm:flush({}, { { evt = q, update = { pitch = 80 } } }, {})
      mirm:setLocalMode(false)
      staged.add, staged.assign, staged.del = {}, {}, {}

      -- Global delete of q, with tv's legato-on-delete growing p over
      -- the vacated span (assigns before deletes, as in preflush).
      tm:flush({}, { { evt = p, update = { endppq = 720 } } },
                    { { evt = q } })

      local clip
      for _, a in ipairs(staged.assign) do
        if a.evt == p then clip = a.update.endppq end
      end
      t.eq(clip, 480, 'predecessor concrete clipped back to the original onset')

      local back
      for _, a in ipairs(staged.add) do
        if a.ppq == 480 and a.evType == 'note' then back = a.pitch end
      end
      t.eq(back, 60, 'the original resurfaces at its own slot, lane intact')
    end,
  },

  {
    name = 'add-ov + global delete removes the local add (no crash, group intact)',
    run = function()
      local mirm, tm, staged = mk()
      local src = note(0, 1, 1)
      mirm:markGroup({ src }, rect(0, 1))
      tm:flush(); staged.add = {}

      mirm:setLocalMode(true)
      local born = note(480, 1, 1, { pitch = 65 })
      tm:flush({ { evt = born } }, {}, {})     -- local-only add in instance 1
      tm:flush(); staged.add = {}
      mirm:setLocalMode(false)

      tm:flush({}, {}, { { evt = born } })     -- delete on the add-ov

      -- The group never carried `born`; a probe still shows only the
      -- single seeded event, and nothing blew up.
      t.eq(groupPitch(mirm, tm, staged, 1920), 60,
        'the shared group is unchanged; the add was purely local')
    end,
  },

  {
    name = 'add-ov + global amend edits the add locally, never the group',
    run = function()
      local mirm, tm, staged = mk()
      local src = note(0, 1, 1)
      mirm:markGroup({ src }, rect(0, 1))
      tm:flush(); staged.add = {}

      mirm:setLocalMode(true)
      local born = note(480, 1, 1, { pitch = 65 })
      tm:flush({ { evt = born } }, {}, {})
      tm:flush(); staged.add = {}
      mirm:setLocalMode(false)

      tm:flush({}, { { evt = born, update = { pitch = 70 } } }, {})

      t.eq(groupPitch(mirm, tm, staged, 1920), 60,
        'editing the local add did not leak into the shared group')
    end,
  },

  {
    name = 'sibling add-ov upgrades to assign-ov on a peer global create',
    run = function()
      local mirm, tm, staged = mk()
      local src = note(0, 1, 1, { pitch = 60 })
      mirm:markGroup({ src }, rect(0, 1))              -- instance 1 @ anchor 0
      mirm:newInstance(1, { ppq = 960, chan = 1 })     -- instance 2 @ anchor 960
      tm:flush(); staged.add = {}

      -- Instance 2 grows a local add at the (group-frame) empty slot 480.
      mirm:setLocalMode(true)
      local sibAdd = note(1440, 1, 1, { pitch = 70 })  -- 960 + 480
      tm:flush({ { evt = sibAdd } }, {}, {})
      tm:flush(); staged.add, staged.del = {}, {}
      mirm:setLocalMode(false)

      -- Instance 1 globally creates a real event at group slot 480.
      local peer = note(480, 1, 1, { pitch = 50 })
      tm:flush({ { evt = peer } }, {}, {})

      -- Instance 2 keeps pitch 70 there (add-ov absorbed into an
      -- assign-ov over the new group event), while a clean probe sees 50.
      local kept
      for _, a in ipairs(staged.add) do
        if a.ppq == 1440 then kept = a.pitch end
      end
      t.eq(kept, 70, 'sibling divergence preserved as an assign-ov')
      t.eq(groupPitch(mirm, tm, staged, 1920), 50,
        'the new group event propagates to clean instances at 50')
    end,
  },

  {
    name = 'sibling assign-ov demotes to a materialised add on a peer global delete',
    run = function()
      local mirm, tm, staged = mk()
      local src = note(0, 1, 1, { pitch = 60 })
      mirm:markGroup({ src }, rect(0, 1))              -- instance 1 @ anchor 0
      mirm:newInstance(1, { ppq = 960, chan = 1 })     -- instance 2 @ anchor 960
      tm:flush()
      local sib
      for _, e in ipairs(staged.add) do if e.ppq == 960 then sib = e end end
      t.truthy(sib, 'instance 2 has a concrete sibling event')
      staged.add = {}

      -- Instance 2 diverges its copy (assign-ov on the shared vuid).
      mirm:setLocalMode(true)
      tm:flush({}, { { evt = sib, update = { pitch = 88 } } }, {})
      mirm:setLocalMode(false)
      staged.add, staged.del = {}, {}

      -- Instance 1 globally deletes the shared event.
      tm:flush({}, {}, { { evt = src } })

      -- The shared event is gone for clean instances, but instance 2
      -- keeps its diverged note (now a materialised local add @ 960/88).
      t.eq(groupPitch(mirm, tm, staged, 1920), nil,
        'group event deleted: a clean probe projects nothing')
      local survived
      for _, a in ipairs(staged.add) do
        if a.ppq == 960 then survived = a.pitch end
      end
      t.eq(survived, 88, 'sibling divergence survives as a materialised add')
    end,
  },
}
