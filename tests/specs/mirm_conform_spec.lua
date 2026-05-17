-- mirm owns the conform MARKER (not the clip — tm does that). Per
-- instance, exactly the last-in-lane note of each note stream is
-- conform=true; earlier members are not. When a later note appears in
-- a lane the previously-last member is demoted (conform=false) and the
-- new last promoted. conform is a per-instance realisation marker: it
-- is never a shared group field (not in SCALARS, never via toGroup).
--
-- Drives the real preflush/postflush seam via the fake tm, as in
-- mirm_propagate_spec.

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
  return util.instantiate('mirrorManager', { tm = tm, cm = fakeCm() }), tm, staged
end

local function note(ppq, lane, pitch)
  return { evType = 'note', chan = 1, lane = lane, ppq = ppq,
           endppq = ppq + 240, pitch = pitch or 60, vel = 100 }
end

local function byPpq(adds, ppq)
  for _, e in ipairs(adds) do if e.ppq == ppq then return e end end
end

return {
  {
    name = 'newInstance flags only the last note in each lane as conform',
    run = function()
      local mirm, _, staged = mk()
      local sel = { note(0, 1, 60), note(240, 1, 62), note(480, 1, 64),
                    note(120, 2, 67) }
      local rect = { ppq = 0, dur = 960, chanLo = 1,
                     streams = { [0] = { ['note:1'] = true, ['note:2'] = true } } }
      local gid = mirm:markGroup(sel, rect)
      mirm:newInstance(gid, { ppq = 960, chan = 1 })

      t.eq(#staged.add, 4)
      -- anchor 960: lane1 -> 960,1200,1440 ; lane2 -> 1080
      t.falsy (byPpq(staged.add,  960).conform, 'lane1 first not conform')
      t.falsy (byPpq(staged.add, 1200).conform, 'lane1 middle not conform')
      t.truthy(byPpq(staged.add, 1440).conform, 'lane1 last is conform')
      t.truthy(byPpq(staged.add, 1080).conform, 'lane2 sole note is conform')
    end,
  },

  {
    name = 'a single-note instance: that note is conform',
    run = function()
      local mirm, tm, staged = mk()
      local gid = mirm:markGroup({ note(0, 1, 60) },
        { ppq = 0, dur = 960, chanLo = 1,
          streams = { [0] = { ['note:1'] = true } } })
      mirm:newInstance(gid, { ppq = 960, chan = 1 })
      t.eq(#staged.add, 1)
      t.truthy(staged.add[1].conform, 'the only note overruns -> conform')
    end,
  },

  {
    name = 'appending a later group note demotes the old last and promotes the new',
    run = function()
      local mirm, tm, staged = mk()
      local src = note(0, 1, 60)
      local gid = mirm:markGroup({ src },
        { ppq = 0, dur = 960, chanLo = 1,
          streams = { [0] = { ['note:1'] = true } } })
      mirm:newInstance(gid, { ppq = 960, chan = 1 })   -- sibling copy
      tm:flush()                                       -- stamp uuids
      t.truthy(byPpq(staged.add, 960).conform, 'sibling sole note starts conform')
      staged.add, staged.assign = {}, {}

      -- Create a later note in the region (lane 1, selected stream).
      local born = note(480, 1, 65)
      tm:flush({ { evt = born } }, {}, {})

      -- Sibling: new note added at 1440 (480 rebased to anchor 960),
      -- conform; the old sibling note at 960 demoted to conform=false.
      local added = byPpq(staged.add, 1440)
      t.truthy(added, 'sibling gets the created note')
      t.truthy(added.conform, 'the new last-in-lane note is conform')

      local demoted
      for _, a in ipairs(staged.assign) do
        if a.evt.ppq == 960 and a.update.conform == false then demoted = a end
      end
      t.truthy(demoted, 'old sibling last-in-lane note demoted (conform=false)')
    end,
  },
}
