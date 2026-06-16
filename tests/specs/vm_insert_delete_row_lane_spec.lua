-- L2 lane stability under insertRow/deleteRow with non-identity swing.
-- Each event's new ppq is recomputed from `swing.fromLogical`, which
-- rounds independently per event. Two diff-pitch col-mates sitting at
-- exactly `lenient` pre-edit overlap can land past it post-shift.

local t    = require('support')
local util = require('util')

local classic58 = { { atom = 'classic', shift = 0.08, period = 1 } }

return {

  {
    name = 'insertRow under c58 keeps threshold-brushing diff-pitch col-mates in lane 1',
    run = function(harness)
      -- Both events authored under c58. Pre-edit intent overlap is
      -- exactly lenient (225 − 210 = 15). insertRow shifts both
      -- ppqLs by +60 (one row at rpb=4); the rounded c58.fromLogical
      -- of A.endppqL pushes its tail up to 264 while B's onset only
      -- rises to 244. Post overlap = 20 > 15 → on current code, B
      -- drifts to lane 2. Conform clips A's tail to 244 + 15 = 259.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 139, endppq = 225, ppqL = 120, endppqL = 200,
              chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0,
              lane = 1,
              rpb = 4 },
            { ppq = 210, endppq = 480, ppqL = 183, endppqL = 480,
              chan = 1, pitch = 64, vel = 100, detune = 0, delay = 0,
              lane = 1,
              rpb = 4 },
          },
        },
        config = {
          project = { swings = { ['c58'] = classic58 } },
          take    = { rowPerBeat = 4 },
        },
        data = { swing = { global = 'c58' } },
      }
      h.vm:setGridSize(80, 40)

      -- Cursor on row 0 of chan-1 lane-1; insertRow with no selection
      -- inserts one row at the cursor.
      h.ec:setPos(0, 1, 1)
      h.cmgr:invoke('insertRow')

      local notes = h.fm:dump().notes
      table.sort(notes, function(a, b) return a.pitch < b.pitch end)
      local A, B = notes[1], notes[2]
      t.eq(A.lane, 1, 'A still in lane 1 after insertRow')
      t.eq(B.lane, 1, 'B still in lane 1 — no drift')

      local lenient = 15
      t.truthy((A.endppq - B.ppq) <= lenient,
               'A tail clipped within lenient: A.endppq=' .. A.endppq ..
               ', B.ppq=' .. B.ppq)
    end,
  },

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
