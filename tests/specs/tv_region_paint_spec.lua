-- tv:paintRegionStream -- the region-paint translation. Toggles a
-- column's stream in the active group's rect, hands newly-covered
-- concretes to gm:resizeGroup as `gained`, lets resizeGroup orphan the
-- ones a narrower stream-set drops. Runs the real trackerView + real
-- groupManager: harness.mk wires gm into tv exactly as trackerPage
-- does in production, so this drives the wired path, not a fake.

local t = require('support')

local function noteCol(h, chan)
  for i, col in ipairs(h.vm.grid.cols) do
    if col.type == 'note' and col.midiChan == chan then return i, col end
  end
end

local function chan2Note(h)
  return h.vm:eventsInRect{ ppq = 0, dur = 240, chanLo = 1,
           streams = { [1] = { ['note:1'] = true } } }[1]
end

local TWO = { groups = true, seed = { notes = {
  { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 },
  { ppq = 0, endppq = 240, chan = 2, pitch = 64, vel = 100 },
} } }

return {
  {
    name = 'paint extend adds the column stream to the active group and absorbs its note',
    run = function(harness)
      local h  = harness.mk(TWO)
      local c2 = noteCol(h, 2)
      local seed = { ppq = 0, dur = 240, chanLo = 1,
                     streams = { [0] = { ['note:1'] = true } } }
      local g   = h.gm:mark(h.vm:eventsInRect(seed), seed)
      local iid = h.gm:eachInstance()[1].instId
      local n2  = chan2Note(h)
      t.truthy(n2 and n2.uuid, 'chan-2 note resolved with a uuid')
      t.falsy(h.gm:stateOf(n2.uuid), 'not a member before paint')

      t.truthy(h.vm:paintRegionStream(g, iid, c2, true))
      local r = h.gm:eachInstance()[1].rect
      t.truthy(r.streams[1] and r.streams[1]['note:1'],
               'chan-2 stream added to the rect')
      t.truthy(h.gm:stateOf(n2.uuid),
               'newly-covered concrete absorbed as gained')
    end,
  },

  {
    name = 'paint shrink removes the stream and orphans its note (concrete kept)',
    run = function(harness)
      local h  = harness.mk(TWO)
      local c2 = noteCol(h, 2)
      local seed = { ppq = 0, dur = 240, chanLo = 1,
                     streams = { [0] = { ['note:1'] = true },
                                 [1] = { ['note:1'] = true } } }
      local g   = h.gm:mark(h.vm:eventsInRect(seed), seed)
      local iid = h.gm:eachInstance()[1].instId
      local n2  = chan2Note(h)
      t.truthy(h.gm:stateOf(n2.uuid), 'member before shrink')

      t.truthy(h.vm:paintRegionStream(g, iid, c2, false))
      local r = h.gm:eachInstance()[1].rect
      t.falsy(r.streams[1] and r.streams[1]['note:1'], 'stream removed')
      t.falsy(h.gm:stateOf(n2.uuid), 'note orphaned, no longer managed')
    end,
  },

  {
    name = 'paint is idempotent: re-painting an already-on stream is a no-op true',
    run = function(harness)
      local h  = harness.mk{ groups = true, seed = { notes = {
        { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 },
      } } }
      local c1   = noteCol(h, 1)
      local seed = { ppq = 0, dur = 240, chanLo = 1,
                     streams = { [0] = { ['note:1'] = true } } }
      local g   = h.gm:mark(h.vm:eventsInRect(seed), seed)
      local iid = h.gm:eachInstance()[1].instId
      local before = h.gm:eachInstance()[1].rect.streams

      t.eq(h.vm:paintRegionStream(g, iid, c1, true), true,
           'extending an already-on stream returns true without resizing')
      t.deepEq(h.gm:eachInstance()[1].rect.streams, before,
               'rect streams unchanged')
    end,
  },

  {
    name = 'unknown group is a silent nil (ec carries no geometry)',
    run = function(harness)
      local h  = harness.mk{ groups = true, seed = { notes = {
        { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 },
      } } }
      local c1 = noteCol(h, 1)
      t.eq(h.vm:paintRegionStream(999, 1, c1, true), nil)
    end,
  },
}
