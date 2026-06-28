-- Repro: select an empty col1/row1, duplicateMirror (empty group + one
-- sibling), then type a note into instance 1 whose tail overruns the
-- group bound into the sibling's region.
--
-- conform is a per-instance REALISATION marker: the last-in-lane note of
-- every instance — the origin region included — may overrun its region,
-- and tm clips its realised note-off. But reproject reconciles the marker
-- only on non-origin instances ("the origin's geometry is the user's
-- own"). conform is not geometry; it's realisation. So the origin's
-- overrunning note never gets clipped, physically collides (same pitch)
-- with the projected sibling copy at the next region, and the column
-- allocator bumps one into lane 2.
--
-- The asymmetry the user observed — "if I add the note to the SECOND
-- instance it correctly truncates the first instance's copy" — is the
-- same bug seen from the other side: editing instance 2 makes instance 1
-- non-origin, so its copy DOES get reconciled and clipped.
--
-- Drives the real preflush/postflush seam via the fake tm, as in
-- mirm_propagate_spec / mirm_conform_spec.

local t    = require('support')
local util = require('util')

local function fakeTm()
  local hooks, staged, seq = {}, { add = {}, assign = {}, del = {} }, 0
  local tm = {}
  function tm:length()            return math.huge end   -- off-take clip irrelevant here
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

local function mk()
  local tm, staged = fakeTm()
  return util.instantiate('groupManager', { tm = tm, ds = t.fakeDs() }), tm, staged
end

local nextUuid = 0
local function note(ppq, chan, lane, extra)
  nextUuid = nextUuid + 1
  local n = { evType = 'note', chan = chan, lane = lane, ppq = ppq,
              endppq = ppq + 240, pitch = 60, vel = 100, uuid = nextUuid }
  for k, v in pairs(extra or {}) do n[k] = v end
  return n
end

-- One note:1 stream on the anchor channel, a bar (960) wide.
local function rect(ppq, chan)
  return { ppq = ppq, dur = 960, chanLo = chan,
           streams = { [0] = { ['note:1'] = true } } }
end

return {
  {
    -- Replay model (Step 3): the origin is round-tripped like every
    -- sibling. A user edit lands in the group frame; reproject re-drives
    -- EVERY instance's concrete event — the user-touched one included —
    -- from the pristine group projection, so the value written back is
    -- the clean group-frame computation, not whatever the distorted
    -- instance happened to hold. Edit A via the origin and B via the
    -- sibling in one flush: each edit reaches the other instance AND is
    -- restaged onto its own touched event from the group.
    name = 'a same-flush edit in two instances round-trips both, origin included',
    run = function()
      local gm, tm, staged = mk()

      local a = note(0,   1, 1, { pitch = 60 })
      local b = note(480, 1, 1, { pitch = 62 })
      local gid = gm:markGroup({ a, b }, rect(0, 1))
      gm:newInstance(gid, { ppq = 960, chan = 1 })   -- sibling at 960
      tm:flush()                                       -- stamp sibling uuids

      -- The sibling's own copies of A and B (rebased to anchor 960).
      local sibA, sibB
      for _, e in ipairs(staged.add) do
        if e.ppq == 960  then sibA = e end
        if e.ppq == 1440 then sibB = e end
      end
      t.truthy(sibA and sibB, 'sibling has copies of both notes')
      staged.add, staged.assign = {}, {}

      -- One flush: A edited via the origin, B edited via the sibling.
      tm:flush({}, { { evt = a,    update = { pitch = 70 } },
                      { evt = sibB, update = { pitch = 80 } } }, {})

      local function assignFor(target)
        for _, op in ipairs(staged.assign) do
          if op.evt == target then return op.update end
        end
      end

      -- A's edit reaches the sibling's copy; B's reaches the origin's;
      -- and each user-touched event is itself restaged from the pristine
      -- group projection (origin round-tripped like every sibling).
      t.eq((assignFor(sibA) or {}).pitch, 70,
        "sibling's copy of A tracks the origin edit")
      t.eq((assignFor(b) or {}).pitch, 80,
        "origin's copy of B tracks the sibling edit")
      t.eq((assignFor(a) or {}).pitch, 70,
        'the user-touched origin A is restaged from the group')
      t.eq((assignFor(sibB) or {}).pitch, 80,
        'the user-touched sibling B is restaged from the group')
    end,
  },

  {
    -- End-to-end on the REAL tm (universal tail pass). Empty
    -- duplicateMirror (group + sibling at 960), then type a note into
    -- instance 1 [0,960) whose raw tail overruns into the sibling region
    -- [960,1920). There is no conform marker now: tm's universal pass
    -- clips every note's realised note-off. The typed note is open
    -- (a fresh create), so once the sibling copy is committed it clips
    -- to that same-pitch onset; the open sibling, with no follower,
    -- runs to take length. One extra rebuild lets the typed note see
    -- the freshly-committed sibling. No lane-2 bump.
    name = 'instance 1 clips its overrun to instance 2 (real tm, no lane-2 bump)',
    run = function(harness)
      local h = harness.mk{ seed = { length = 1500, notes = {} } }
      local gm = util.instantiate('groupManager', { tm = h.tm, ds = h.ds })

      local rect = { ppq = 0, dur = 960, chanLo = 1,
                     streams = { [0] = { ['note:1'] = true } } }
      gm:stamp({}, rect, { ppq = 960, chan = 1 })   -- group + sibling
      h.tm:flush()

      -- Type a note into instance 1 whose tail runs past 960 into the
      -- sibling region.
      h.tm:addEvent{ evType = 'note', chan = 1, pitch = 60,
                     ppq = 0, endppq = 1500, vel = 100 }
      h.tm:flush()
      -- With `conform` removed the mirror-origin note is not
      -- force-clipped against its own sibling copy: its AUTHORED tail
      -- stays where the user typed it (1500). The universal tail pass
      -- still clips the *realised* tail to the sibling onset (960).
      -- Projection surfaces both: endppq = authored intent, endppqC =
      -- the clipped logical the renderer draws.

      local function lane(n)
        local out = {}
        for _, ev in ipairs(h.tm:getChannel(1).columns.notes[n].events) do
          if ev.evType ~= 'pa' then out[#out + 1] = ev end
        end
        return out
      end

      local notes2 = h.tm:getChannel(1).columns.notes[2]
      t.falsy(notes2 and #lane(2) > 0,
        'no lane-2 bump: instance 1 and its sibling copy do not collide')

      local l1 = lane(1)
      t.eq(#l1, 2, 'instance 1 note + its sibling copy, both in lane 1')
      table.sort(l1, function(x, y) return x.ppq < y.ppq end)
      t.eq(l1[1].ppq, 0,   'instance 1 note at its onset')
      t.eq(l1[2].ppq, 960, 'sibling copy rebased to anchor 960')
      -- The tv surface is logical-only: endppq is the AUTHORED ceiling,
      -- endppqC the clipped logical the renderer draws.
      t.eq(l1[1].endppq,  1500, 'instance 1 keeps its authored tail (typed to 1500)')
      t.eq(l1[1].endppqC, 960,  'instance 1 renders clipped to the sibling onset')
      t.eq(l1[2].endppq, util.OPEN,
           'the sibling copy keeps its open authored intent on the surface')
      t.eq(l1[2].endppqC, 1500,
           'the open sibling renders (endppqC) to take length')
      t.falsy(l1[1].conform or l1[2].conform,
           'no conform field -- tm derives the realised tail universally')
    end,
  },
}
