-- Integration repro driving the REAL tracker delete command, so
-- trackerView's queueDeleteNotes (column legato) and trackerManager's
-- conform-tail pass both run, wired to a real mirrorManager.
--
-- AB in col1 rows 0-1 (B last-in-lane, open tail to take end). Mirror-
-- duplicate down: instance 2 at rows 2-3, sharing chan|lane -- so the
-- single column holds [A1, B1, A2, B2] interleaved. Single-cell delete
-- (the '.' command) of the duplicate's A2 must not shrink the
-- duplicate's B2: the column legato would grow the conform predecessor
-- B1 over the instance-boundary hole, and that endppq leaks into the
-- shared group as a duration edit collapsing B's infinite tail.

local t    = require('support')
local util = require('util')

local LPR      = 60                        -- resolution 240, rpb 4, denom 4
local TAKE_LEN = 3840
local NOTE_COL = 1                          -- chan-1 note column

local function rect()
  return { ppq = 0, dur = 2 * LPR, chanLo = 1,
           streams = { [0] = { ['note:1'] = true } } }
end

local function noteAt(notes, ppq, pitch)
  for _, n in ipairs(notes) do
    if n.ppq == ppq and n.pitch == pitch then return n end
  end
end

return {
  {
    name = 'single-cell delete of the duplicate A must not shrink the duplicate B',
    run = function(harness)
      local h = harness.mk{
        seed = { length = TAKE_LEN, resolution = 240, notes = {
          { ppq = 0,   endppq = LPR,      ppqL = 0,   endppqL = LPR,
            chan = 1, pitch = 60, vel = 100, lane = 1, uuid = 1 },
          { ppq = LPR, endppq = TAKE_LEN, ppqL = LPR, endppqL = TAKE_LEN,
            chan = 1, pitch = 62, vel = 100, lane = 1, uuid = 2 },
        } },
      }
      local mirm = util.instantiate('mirrorManager', { tm = h.tm, cm = h.cm })

      local evA, evB = h.tm:byUuid(1), h.tm:byUuid(2)
      for _, e in ipairs{ evA, evB } do e.chan = 1; e.lane = e.lane or 1 end
      local gid = mirm:markGroup({ evA, evB }, rect())
      mirm:newInstance(gid, { ppq = 2 * LPR, chan = 1 })   -- rows 2-3
      h.tm:flush()

      local before = h.fm:dump().notes
      local copyA  = noteAt(before, 2 * LPR, 60)            -- row 2
      local copyB  = noteAt(before, 3 * LPR, 62)            -- row 3
      t.truthy(copyA and copyB, 'duplicate A and B materialised')
      t.eq(copyB.endppq, TAKE_LEN,
        'duplicate B runs to take length before the delete')

      -- The real '.' command: clears selection, deletes the cell, advances.
      h.ec:setPos(2, NOTE_COL, 1)                           -- on duplicate A
      h.cmgr:invoke('delete')

      local after  = h.fm:dump().notes
      local copyB2 = noteAt(after, 3 * LPR, 62)
      t.truthy(copyB2, 'duplicate B still present')
      t.eq(copyB2.endppq, TAKE_LEN,
        'duplicate B keeps its take-length tail -- not collapsed to 2 rows')
      t.falsy(noteAt(after, 2 * LPR, 60), 'duplicate A is gone')
      t.falsy(noteAt(after, 0, 60),
        'instance 1 A propagated-deleted too (global mode)')
    end,
  },
}
