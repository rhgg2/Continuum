-- insertRow/deleteRow across the open-tail sentinel: `shiftPlan` must
-- never do arithmetic on `util.OPEN`. The authored tail stays open over
-- the shift and tm re-derives the realised note-off.

local t    = require('support')
local util = require('util')

return {

  {
    -- Regression: an open-tailed note (endppq == util.OPEN) shifted by
    -- insertRow. shiftPlan must NOT do arithmetic on the OPEN sentinel
    -- (math.min(util.OPEN + dLogical, ...) throws); the authored tail
    -- stays open across the shift and tm re-derives the realised
    -- note-off. Pre-fix this test errors in shiftPlan.
    name = 'insertRow over an open-tailed note keeps endppq == util.OPEN',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 240, endppq = 480, ppqL = 240, endppqL = util.OPEN,
              chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0,
              lane = 1, rpb = 4 },
          },
        },
      }
      h.vm:setGridSize(80, 40)

      h.ec:setPos(0, 1, 1)
      h.cmgr:invoke('insertRow')

      local note
      for _, e in ipairs(h.tm:getChannel(1).columns.notes[1].events) do
        if e.pitch == 60 then note = e end
      end
      t.truthy(note, 'open note survives insertRow')
      t.eq(note.endppq, util.OPEN,
           'authored tail stays open across the shift')
      t.truthy(note.ppq > 240,
           'onset shifted down by the inserted row (ppq=' ..
           tostring(note.ppq) .. ')')
    end,
  },

  {
    -- Spanning case (onset before C, OPEN tail crosses C). Pre-fix:
    -- `spanning.endppq > C` throws ('open' > number). Post-fix: skip
    -- the trim block -- open stays open across the insert.
    name = 'insertRow over an open-tailed spanning note keeps endppq == util.OPEN',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 120, ppqL = 0, endppqL = util.OPEN,
              chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0,
              lane = 1, rpb = 4 },
          },
        },
      }
      h.vm:setGridSize(80, 40)

      h.ec:setPos(4, 1, 1)
      h.cmgr:invoke('insertRow')

      local note
      for _, e in ipairs(h.tm:getChannel(1).columns.notes[1].events) do
        if e.pitch == 60 then note = e end
      end
      t.truthy(note, 'open spanning note survives')
      t.eq(note.endppq, util.OPEN,
           'authored tail stays open across the insert')
      t.eq(note.ppq, 0, 'onset before the insertion point unchanged')
    end,
  },

  {
    -- Mirror: deleteRow with the spanning note's tail OPEN. Pre-fix
    -- throws on the same `endppq > C` comparison.
    name = 'deleteRow bracketing an open-tailed spanning note keeps endppq == util.OPEN',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 120, ppqL = 0, endppqL = util.OPEN,
              chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0,
              lane = 1, rpb = 4 },
          },
        },
      }
      h.vm:setGridSize(80, 40)

      h.ec:setPos(4, 1, 1)
      h.cmgr:invoke('deleteRow')

      local note
      for _, e in ipairs(h.tm:getChannel(1).columns.notes[1].events) do
        if e.pitch == 60 then note = e end
      end
      t.truthy(note, 'open spanning note survives')
      t.eq(note.endppq, util.OPEN,
           'authored tail stays open across the delete')
      t.eq(note.ppq, 0, 'onset before the deletion point unchanged')
    end,
  },

}
