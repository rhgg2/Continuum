-- tv:clearRegionAt and the group quick-verbs that drive it. A group
-- dropped on populated cells must clear the destination first (gm only
-- re-places its own concretes). The load-bearing case: a note that
-- STARTS before the zone and sustains into it is tail-trimmed to the
-- boundary, never deleted and never left overlapping -- an overlapping
-- survivor spills the projection onto another lane on rebuild, and lane
-- identity is strictly preserved under groups. Real trackerView + real
-- groupManager via harness.mk (the wired path, not a fake).

local t = require('support')

local function noteCol(h, chan)
  for i, col in ipairs(h.vm.grid.cols) do
    if col.type == 'note' and col.midiChan == chan then return i, col end
  end
end

local function byPitch(notes, p)
  for _, n in ipairs(notes) do if n.pitch == p then return n end end
end

local function pitches(notes)
  local s = {}
  for _, n in ipairs(notes) do s[#s + 1] = n.pitch end
  table.sort(s)
  return s
end

return {
  {
    name = 'clearRegionAt: in-zone deleted, pre-zone straddler trimmed (lane kept), outside untouched',
    run = function(harness)
      -- chan-1, single lane, non-overlapping in the seed so all land on
      -- note:1. Zone = [300, 600).
      local h = harness.mk{ groups = true, seed = { notes = {
        { ppq =   0, endppq = 120, chan = 1, pitch = 60, vel = 100 }, -- before
        { ppq = 120, endppq = 360, chan = 1, pitch = 62, vel = 100 }, -- STRADDLER
        { ppq = 420, endppq = 480, chan = 1, pitch = 64, vel = 100 }, -- in-zone
        { ppq = 600, endppq = 660, chan = 1, pitch = 65, vel = 100 }, -- at/after
      } } }

      local strBefore = byPitch(h.fm:dump().notes, 62)
      t.truthy(strBefore, 'straddler present in seed')
      local laneBefore = strBefore.lane

      h.vm:clearRegionAt(
        { ppq = 0, dur = 300, chanLo = 1, streams = { [0] = { ['note:1'] = true } } },
        { ppq = 300, chan = 1 })
      h.tm:flush()

      local notes = h.fm:dump().notes
      t.deepEq(pitches(notes), { 60, 62, 65 },
               'in-zone note (64) deleted; before (60), straddler (62), after (65) survive')

      local str = byPitch(notes, 62)
      t.eq(str.endppq, 300, 'straddler tail trimmed to the zone boundary, not deleted')
      t.eq(str.ppq, 120, 'straddler onset unchanged')
      t.eq(str.lane, laneBefore, 'straddler lane preserved (no spill)')

      t.eq(byPitch(notes, 65).ppq, 600, 'note at hi (exclusive) untouched')
    end,
  },

  {
    name = 'clearRegionAt: a stream not in the rect is left alone',
    run = function(harness)
      local h = harness.mk{ groups = true, seed = { notes = {
        { ppq = 360, endppq = 420, chan = 1, pitch = 60, vel = 100 },
        { ppq = 360, endppq = 420, chan = 2, pitch = 64, vel = 100 },
      } } }
      -- Zone covers chan-1 note:1 only.
      h.vm:clearRegionAt(
        { ppq = 0, dur = 600, chanLo = 1, streams = { [0] = { ['note:1'] = true } } },
        { ppq = 0, chan = 1 })
      h.tm:flush()
      local notes = h.fm:dump().notes
      t.falsy(byPitch(notes, 60), 'chan-1 in-zone note cleared')
      t.truthy(byPitch(notes, 64), 'chan-2 note (stream not in rect) untouched')
    end,
  },

  {
    name = 'groupPaste clears the destination before stamping the projection',
    run = function(harness)
      -- rowPerBeat 4, resolution 240 -> 60 ppq/row. Source: 1-row note
      -- at row 0 (ppq 0). Foreign note sits exactly where the paste
      -- lands (row 10, ppq 600).
      local h = harness.mk{ groups = true, seed = { notes = {
        { ppq =   0, endppq = 60, chan = 1, pitch = 60, vel = 100 },
        { ppq = 600, endppq = 660, chan = 1, pitch = 72, vel = 100 },
      } } }
      local ci = noteCol(h, 1)

      h.ec:setSelection{ row1 = 0, row2 = 0, col1 = ci, col2 = ci,
                         part1 = 'pitch', part2 = 'pitch' }
      h.cmgr:invoke('groupMark')        -- seeds a group at [0,60), sets active
      h.ec:setPos(10, ci, 1)            -- cursor anchor = ppq 600
      h.cmgr:invoke('groupPaste')

      local notes = h.fm:dump().notes
      t.falsy(byPitch(notes, 72), 'foreign note in the paste zone was cleared')
      local landed = byPitch(notes, 60)
      t.truthy(landed, 'projection materialised')
      -- source copy still at 0; the pasted instance at 600.
      local at600
      for _, n in ipairs(notes) do
        if n.pitch == 60 and n.ppq == 600 then at600 = n end
      end
      t.truthy(at600, 'a projected copy landed at the paste anchor')
    end,
  },
}
