-- Repro: eventShiftLeft/Right on a group member. Moving a member sideways
-- is a pattern edit (design/group-aware-editing.md decision 1). Shifting a
-- member OUT of its region must leave one note total (synced) or one
-- standalone + untouched siblings (overridden) -- never a duplicate.

local t = require('support')

local function noteCol(h, chan, lane)
  for i, col in ipairs(h.vm.grid.cols) do
    if col.type == 'note' and col.midiChan == chan
       and (lane == nil or (col.lane or 1) == lane) then return i, col end
  end
end

local function allNotes(h)
  local out = {}
  for _, n in h.fm:notes() do
    if n.evType ~= 'pa' then
      out[#out + 1] = { ppq = n.ppq, chan = n.chan, lane = n.lane,
                        pitch = n.pitch, uuid = n.uuid }
    end
  end
  table.sort(out, function(a, b)
    if a.chan ~= b.chan then return a.chan < b.chan end
    if a.ppq  ~= b.ppq  then return a.ppq  < b.ppq  end
    return (a.lane or 1) < (b.lane or 1)
  end)
  return out
end

local function noteAt(notes, chan, ppq)
  for _, n in ipairs(notes) do
    if n.chan == chan and n.ppq == ppq then return n end
  end
end

-- The grid row of the cell at colIx with the given ppq (ppq/row is not fixed).
local function rowOfPpq(h, colIx, ppq)
  for row, evt in pairs(h.vm.grid.cols[colIx].cells) do
    if evt.ppq == ppq then return row end
  end
end

local function setup(harness)
  local h = harness.mk{
    groups = true,
    seed   = { notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } } },
  }
  local ci = noteCol(h, 1)
  h.ec:setSelection{ row1 = 0, row2 = 0, col1 = ci, col2 = ci, part1 = 'pitch', part2 = 'pitch' }
  local gid = h.gm:markGroup(h.vm:eventsInRect(h.vm:selectionAsRect()), h.vm:selectionAsRect())
  h.ec:selClear()   -- the selection only seeded the rect; the shifts act on the caret cell
  return h, ci, gid
end

return {
  {
    name = 'shift a synced sibling out: one note total, member leaves the pattern',
    run = function(harness)
      local h, ci, gid = setup(harness)
      h.gm:newInstance(gid, { ppq = 960, chan = 1 })
      h.tm:flush()
      h.ec:setPos(rowOfPpq(h, ci, 960), ci)   -- caret on the sibling
      h.cmgr:invoke('eventShiftRight')

      local notes = allNotes(h)
      t.eq(#notes, 1, 'one note total: the member left the pattern, both instances lose it')
      t.eq(notes[1].chan, 2, 'the standalone landed one channel right')
      t.eq(notes[1].ppq, 960, 'at the sibling row (ppq unchanged by a sideways shift)')
      t.eq(notes[1].pitch, 60)
      t.falsy(noteAt(notes, 1, 0), 'origin slot is empty -- the member left the shared pattern')
    end,
  },
  {
    name = 'shift an overridden member out: override peels to reveal the synced note, standalone at dest',
    run = function(harness)
      local h, ci, gid = setup(harness)
      h.gm:newInstance(gid, { ppq = 960, chan = 1 })
      h.tm:flush()
      -- Give the origin instance a local override: a localMode pitch edit.
      h.gm:setLocalMode(true)
      h.gm:assignEvent(1, { pitch = 67 })
      h.tm:flush()
      h.gm:setLocalMode(false)

      h.ec:setPos(rowOfPpq(h, ci, 0), ci)   -- caret on the origin
      h.cmgr:invoke('eventShiftRight')

      -- Moving the overridden member out PEELS the override (revert-to-synced): the
      -- shared note (60) reveals at origin; the dragged value (67) lands standalone at dest.
      local notes = allNotes(h)
      t.eq(#notes, 3, 'synced revealed at origin + untouched sibling + standalone at dest')

      local revealed = noteAt(notes, 1, 0)
      t.truthy(revealed, 'shared note revealed at the origin -- the override was peeled, not hidden')
      t.eq(revealed.pitch, 60, 'it shows the shared group value, not the peeled-off override')

      local moved = noteAt(notes, 2, 0)
      t.truthy(moved, 'standalone at the destination channel')
      t.eq(moved.pitch, 67, 'the standalone carries the overridden value the user was moving')

      local sib = noteAt(notes, 1, 960)
      t.truthy(sib, 'sibling member untouched')
      t.eq(sib.pitch, 60, 'sibling still shows the shared group value')
    end,
  },
}
