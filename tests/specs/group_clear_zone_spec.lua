-- tv:clearRegionAt and the group quick-verbs that drive it. A group
-- dropped on populated cells must clear the destination first (gm only
-- re-places its own concretes). The load-bearing case: a note that
-- STARTS before the zone and sustains into it is tail-trimmed to the
-- boundary, never deleted and never left overlapping -- an overlapping
-- survivor spills the projection onto another lane on rebuild, and lane
-- identity is strictly preserved under groups. Real trackerView + real
-- groupManager via harness.mk (the wired path, not a fake).

local t    = require('support')
local util = require('util')

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
    name = 'clearRegionAt: in-zone deleted, pre-zone straddler keeps authored tail, outside untouched',
    run = function(harness)
      -- chan-1, single lane, non-overlapping in the seed so all land on
      -- note:1. Zone = [300, 600). Authored intent on the straddler is
      -- left alone -- tm's universal tail pass clips realised on rebuild.
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
      t.eq(str.endppq, 360, 'straddler authored tail untouched by the clear')
      t.eq(str.ppq, 120, 'straddler onset unchanged')
      t.eq(str.lane, laneBefore, 'straddler lane preserved')

      t.eq(byPitch(notes, 65).ppq, 600, 'note at hi (exclusive) untouched')
    end,
  },

  {
    -- OPEN straddler: authored endppq is util.OPEN, so 'prev.endppq > lo'
    -- throws pre-fix. Post-fix the OPEN tail counts as spanning into the
    -- zone and trims to the boundary, matching the clear-zone contract.
    name = 'clearRegionAt trims an open-tailed straddler to the zone boundary',
    run = function(harness)
      local h = harness.mk{ groups = true, seed = { notes = {
        { ppq = 0, endppq = 120, ppqL = 0, endppqL = util.OPEN,
          chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0,
          lane = 1, rpb = 4 },
      } } }

      h.vm:clearRegionAt(
        { ppq = 0, dur = 300, chanLo = 1, streams = { [0] = { ['note:1'] = true } } },
        { ppq = 300, chan = 1 })
      h.tm:flush()

      local A
      for _, e in ipairs(h.tm:getChannel(1).columns.notes[1].events) do
        if e.pitch == 60 then A = e end
      end
      t.truthy(A, 'OPEN straddler survives the clear')
      t.eq(A.endppq, util.OPEN,
           'OPEN authored intent is non-committed; the clear leaves it alone')
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
      h.cmgr:invoke('copy')             -- copy seeds the group source rect [0,60)
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

  {
    name = 'a wired move previews non-destructively, then clears + relocates on exit',
    run = function(harness)
      -- 60 ppq/row. 1-row group at row 0; a foreign note two rows down, where
      -- the group lands after two nudges. The sweep is render-only until exit.
      local h = harness.mk{ groups = true, seed = { notes = {
        { ppq =   0, endppq =  60, chan = 1, pitch = 60, vel = 100 }, -- group member
        { ppq = 120, endppq = 180, chan = 1, pitch = 72, vel = 100 }, -- foreign, 2 rows down
      } } }
      local ci   = noteCol(h, 1)
      local seed = { ppq = 0, dur = 60, chanLo = 1, streams = { [0] = { ['note:1'] = true } } }
      h.gm:mark(h.vm:eventsInRect(seed), seed)

      h.ec:setPos(0, ci, 1)
      h.ec:regionArm()                 -- arms on the instance under the caret
      t.truthy(h.ec:isInRegionMode(), 'armed')

      h.cmgr:invoke('nudgeForward')    -- preview +1 row
      h.cmgr:invoke('nudgeForward')    -- preview +2 rows: over the foreign note

      local notes = h.fm:dump().notes
      t.truthy(byPitch(notes, 72), 'foreign note still present during preview (non-destructive)')
      t.eq(byPitch(notes, 60).ppq, 0, 'member not yet relocated during preview')

      h.cmgr:invoke('regionExit')      -- commit on leaving the mode
      notes = h.fm:dump().notes
      t.falsy(byPitch(notes, 72), 'foreign note the group swept onto cleared on commit')
      local m = byPitch(notes, 60)
      t.truthy(m, 'member survived')
      t.eq(m.ppq, 120, 'member relocated to the new anchor on commit')
    end,
  },

  {
    name = 'clearMoveGap on an overlapping nudge spares the cells the source still covers',
    run = function(harness)
      -- 2-row rect +1 row: source covers [60,120), so only the leading gap [120,180) is
      -- clearable -- own notes in the overlap must survive (whole-dest clear would eat them).
      local h = harness.mk{ groups = true, seed = { notes = {
        { ppq =  60, endppq = 100, chan = 1, pitch = 60, vel = 100 }, -- overlap, spared
        { ppq = 120, endppq = 160, chan = 1, pitch = 62, vel = 100 }, -- leading gap, wiped
      } } }
      h.vm:clearMoveGap(
        { ppq = 0, dur = 120, chanLo = 1, streams = { [0] = { ['note:1'] = true } } },
        { ppq = 0, chan = 1 }, { ppq = 60, chan = 1 })
      h.tm:flush()
      local notes = h.fm:dump().notes
      t.truthy(byPitch(notes, 60), 'overlap cell (own notes live here) spared')
      t.falsy (byPitch(notes, 62), 'leading-gap foreign note wiped')
    end,
  },

  {
    name = 'committing a move that hangs off the take withholds the off-take member; a later move revives it',
    run = function(harness)
      -- 60 ppq/row, take 240 (rows 0..3). 2-row group; committed at the last row
      -- its lower member falls off-take -- writing it would push REAPER's EOT.
      local h = harness.mk{ groups = true, seed = { length = 240, notes = {
        { ppq =  0, endppq =  40, chan = 1, pitch = 60, vel = 100 }, -- group row 0
        { ppq = 60, endppq = 100, chan = 1, pitch = 62, vel = 100 }, -- group row 1
      } } }
      local ci   = noteCol(h, 1)
      local seed = { ppq = 0, dur = 120, chanLo = 1, streams = { [0] = { ['note:1'] = true } } }
      h.gm:mark(h.vm:eventsInRect(seed), seed)

      h.ec:setPos(0, ci, 1)
      h.ec:regionArm()
      h.cmgr:invoke('nudgeForward')
      h.cmgr:invoke('nudgeForward')
      h.cmgr:invoke('nudgeForward')   -- preview row 3: lower member would land off-take
      h.cmgr:invoke('regionExit')     -- commit

      local notes = h.fm:dump().notes
      t.truthy(byPitch(notes, 60), 'on-take member present')
      t.eq(byPitch(notes, 60).ppq, 180, 'top member at the last take row')
      t.falsy(byPitch(notes, 62), 'off-take member withheld (take did not grow)')

      h.ec:setPos(3, ci, 1)
      h.ec:regionArm()
      h.cmgr:invoke('nudgeBack')      -- preview row 2: lower member back on-take
      h.cmgr:invoke('regionExit')     -- commit
      notes = h.fm:dump().notes
      t.truthy(byPitch(notes, 62), 'withheld member revived on return')
      t.eq(byPitch(notes, 62).ppq, 180, 'revived at its in-take ppq')
    end,
  },

  {
    name = 'tv:movePreview reports the armed drag geometry; nil when idle',
    run = function(harness)
      local h = harness.mk{ groups = true, seed = { notes = {
        { ppq = 0, endppq = 60, chan = 1, pitch = 60, vel = 100 },
      } } }
      local ci   = noteCol(h, 1)
      local seed = { ppq = 0, dur = 120, chanLo = 1, streams = { [0] = { ['note:1'] = true } } }
      h.gm:mark(h.vm:eventsInRect(seed), seed)
      h.ec:setPos(0, ci, 1)
      h.ec:regionArm()
      t.eq(h.vm:movePreview(), nil, 'no preview before any nudge')

      h.cmgr:invoke('nudgeForward')
      local mp = h.vm:movePreview()
      t.truthy(mp, 'preview active after a nudge')
      t.eq(mp.delta, 1, 'delta is the nudged row count')
      t.eq(mp.chanDelta, 0, 'no channel delta from a pure row nudge')
      t.eq(mp.srcLo, 0, 'source span starts at the anchor row')
      t.eq(mp.srcHi, 2, 'source span ends at anchor + durRows')
      t.truthy(mp.srcMember[ci], 'the source member column is flagged')
      t.eq(mp.destSrc[ci], ci, 'a row-only move maps each column to itself')
    end,
  },

  {
    name = 'a channel move clears the destination channel, relocates the member, preserves lane',
    run = function(harness)
      -- group member on chan 1; a foreign note on chan 2 where the group lands.
      local h = harness.mk{ groups = true, seed = { notes = {
        { ppq = 0, endppq = 60, chan = 1, pitch = 60, vel = 100 }, -- group member
        { ppq = 0, endppq = 60, chan = 2, pitch = 72, vel = 100 }, -- foreign on chan 2
      } } }
      local ci   = noteCol(h, 1)
      local seed = { ppq = 0, dur = 60, chanLo = 1, streams = { [0] = { ['note:1'] = true } } }
      h.gm:mark(h.vm:eventsInRect(seed), seed)

      h.ec:setPos(0, ci, 1)
      h.ec:regionArm()
      h.cmgr:invoke('eventShiftRight')   -- preview onto chan 2

      local mp = h.vm:movePreview()
      t.eq(mp.chanDelta, 1, 'preview reports one channel over')
      t.eq(mp.destSrc[noteCol(h, 2)], ci, 'chan-2 destination ghosts from the chan-1 source')

      local notes = h.fm:dump().notes
      t.truthy(byPitch(notes, 72), 'foreign chan-2 note present during preview (non-destructive)')
      t.eq(byPitch(notes, 60).chan, 1, 'member not yet relocated during preview')

      h.cmgr:invoke('regionExit')        -- commit on leaving the mode
      notes = h.fm:dump().notes
      t.falsy(byPitch(notes, 72), 'foreign chan-2 note cleared on commit')
      local m = byPitch(notes, 60)
      t.truthy(m, 'member survived')
      t.eq(m.chan, 2, 'member relocated to channel 2')
      t.eq(m.lane, 1, 'lane preserved across the channel move')
    end,
  },
}
