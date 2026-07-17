-- Exercises vm editing commands against seeded tm state.

local t    = require('support')
local util = require('util')

return {
  -- Delete on a note's delay stop (selGrp 3, no block selection) resets
  -- the delay metadata to 0 and lets the realisation line shift the
  -- note-on back to the intent row. Endppq is intent in storage and
  -- never carries the delay offset, so it doesn't move when delay is
  -- cleared. The view layer speaks intent only: it must not edit
  -- realised ppq directly.
  {
    name = 'delete on delay stop zeroes delay metadata',
    run = function(harness)
      -- resolution=240, 4 rpb → 1 row = 60 ppq. delay=500 milli-QN = +120 ppq.
      -- Seed realised onset ppq=180 so intent ppq=60 → row 1. Endppq=420
      -- is already intent (= realised end under the new delay model).
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 180, endppq = 420, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 500 },
          },
        },
        data = { noteDelay = { [1] = { [1] = true } } },
      }
      h.vm:setGridSize(80, 40)
      -- Col 1 is chan-1 lane-1 note col with delay enabled (7 stops,
      -- partAt = {pitch×2, vel×2, delay×3}). Stop 5 → first delay stop.
      h.ec:setPos(1, 1, 5)
      h.cmgr:invoke('delete')

      local note = h.fm:dump().notes[1]
      t.eq(note.delay, 0, 'delay metadata zeroed')
      t.eq(note.ppq,   60, 'realised ppq shifted back to intent row')
      t.eq(note.endppq, 420, 'endppq stays put (delay never shifted it)')
    end,
  },

  {
    -- Refactor pin: post-clamp drop in adjustDurationCore. The user
    -- grows past a same-pitch successor; the authored ceiling must move
    -- past, even though tm's universal tail pass clips realised back to
    -- the successor onset. Pre-fix the overlapBounds maxPPQ clamp
    -- silently capped newppq at the successor and the command no-op'd.
    name = 'growNote past a same-pitch successor authors a tail past, tm clips realised',
    run = function(harness)
      local h = harness.mk{ seed = { notes = {
        { ppq = 0,   endppq = 240, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
        { ppq = 240, endppq = 480, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
      } } }
      h.vm:setGridSize(80, 40)

      h.ec:setPos(0, 1, 1)
      h.cmgr:invoke('growNote')

      local A
      for _, e in ipairs(h.tm:getChannel(1).columns.notes[1].events) do
        if e.pitch == 60 and e.ppq == 0 then A = e end
      end
      t.truthy(A, 'A survives')
      t.truthy(A.endppq > 240,
               'authored ceiling shifted past the same-pitch successor (endppq=' ..
               tostring(A.endppq) .. ')')
      t.eq(A.endppqC, 240, 'realised clipped to the successor onset')
    end,
  },

  {
    -- noteOff undo branch: cursor at the rendered tail row reopens the
    -- authored ceiling. Pre-fix wrote `next.ppq or length` (a finite
    -- ceiling at the next blocker); post-fix writes util.OPEN and lets
    -- tm's tail pass re-derive the realised note-off.
    name = 'noteOff at the rendered tail row reopens authored endppq to util.OPEN',
    run = function(harness)
      local h = harness.mk{ seed = { notes = {
        { ppq = 0,   endppq = 180, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
        { ppq = 300, endppq = 420, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
      } } }
      h.vm:setGridSize(80, 40)

      h.ec:setPos(3, 1, 1)   -- ppq 180 = A.endppqC
      h.cmgr:invoke('noteOff')

      local A
      for _, e in ipairs(h.tm:getChannel(1).columns.notes[1].events) do
        if e.pitch == 60 and e.ppq == 0 then A = e end
      end
      t.truthy(A, 'A survives')
      t.eq(A.endppq, util.OPEN, 'authored tail reopened to OPEN')
    end,
  },

  {
    -- Regression (fractional ppqPerRow): the rendered tail's endppqC is
    -- back-mapped through the integer raw frame, so it drifts sub-tick
    -- from rowToPPQ(cursorRow). The undo branch must compare *rows*
    -- (ctx:snapRow), not raw ppq equality, or noteOff can never reopen a
    -- tail to util.OPEN off the integer grid. rpb=7 -> ppqPerRow=240/7;
    -- row 3 = 102.857 ppq, tail seeded at the nearest raw tick 103.
    name = 'noteOff reopens a tail to util.OPEN under fractional ppqPerRow',
    run = function(harness)
      local h = harness.mk{
        config = { take = { rowPerBeat = 7 } },
        seed = { notes = {
          { ppq = 0, endppq = 103, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
        } },
      }
      h.vm:setGridSize(80, 40)

      h.ec:setPos(3, 1, 1)   -- row 3 = the tail's rendered end row
      h.cmgr:invoke('noteOff')

      local A
      for _, e in ipairs(h.tm:getChannel(1).columns.notes[1].events) do
        if e.pitch == 60 and e.ppq == 0 then A = e end
      end
      t.truthy(A, 'A survives')
      t.eq(A.endppq, util.OPEN, 'tail reopened to OPEN despite sub-tick drift')
    end,
  },

  -- End-state invariant: after placing a new note at (chan, pitch, ppq),
  -- no other note on the same (chan, pitch) may still cover ppq. The
  -- invariant is enforced jointly by addNoteEvent's cross-col truncate
  -- (pre-flush, in-memory) and tm:rebuild's group-by-pitch normalisation
  -- (post-flush). Either alone would pass this test; both together keep
  -- col.events consistent throughout a composite operation.
  {
    name = 'placing a new note clears same-pitch coverage in other cols of the channel',
    run = function(harness)
      -- Two note columns on chan 1 via explicit lanes (under the
      -- universal model adjacency alone no longer forces a second lane
      -- — the tail pass would clip A to the next column onset):
      --   A  pitch=60 lane 1 covers [0, 600) → col 1
      --   Y  pitch=64 lane 2 covers [120, 360) → col 2
      -- Typing C at row 8 (ppq=480) in col 2 places a new pitch-60 note
      -- past Y's end. A still covers ppq=480 and must be truncated back —
      -- cross-col, same pitch, same channel.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0,   endppq = 600, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0, lane = 1 },
            { ppq = 120, endppq = 360, chan = 1, pitch = 64, vel = 80,  detune = 0, delay = 0, lane = 2 },
          },
        },
        config = { take = { currentOctave = 4 } },
      }
      h.vm:setGridSize(80, 40)

      local col2 = h.vm.grid.cols[2]
      t.eq(col2.type, 'note')
      t.eq(col2.midiChan, 1)
      t.eq(col2.lane, 2)

      -- Row 8 = ppq 480 (resolution 240, 4 rpb). Stop 1 = note name.
      -- 'z' in colemak = C; currentOctave=4 + octOff=0 → pitch 60.
      h.ec:setPos(8, 2, 1)
      h.vm:editEvent(col2, nil, 1, string.byte('z'), false)

      local notes = h.fm:dump().notes
      local A, newN
      for _, n in ipairs(notes) do
        if     n.ppq == 0   and n.pitch == 60 then A    = n
        elseif n.ppq == 480 and n.pitch == 60 then newN = n end
      end
      t.truthy(A,           'original ppq=0 pitch-60 note survives')
      t.eq(A.endppq, 480,   'A truncated to new note ppq (was 600)')
      t.truthy(newN,        'new C-4 note placed at ppq=480')
    end,
  },

  -- Write-boundary clamp: if a same-(chan, pitch) note starts inside the
  -- new note's body on another column, the new note's endppq must be
  -- clamped to that start at the moment of addition — not merely repaired
  -- post-hoc by rebuild. tm:addEvent owns the invariant.
  {
    name = 'placing a new note clamps its endppq to a same-pitch successor in another col',
    run = function(harness)
      -- Two-lane setup on chan 1:
      --   A  pitch=60, covers [0, 120)        → col 1
      --   Y  pitch=64, covers [0, 600)        → col 2 (forces a 2nd lane)
      --   B  pitch=60, covers [360, 600)      → col 1 (after A, same col)
      -- Typing C at row 1 (ppq=60) in col 2 places a new pitch-60 note.
      -- placeNewNote's same-col seek finds the next pitch-60 note AFTER
      -- ppq=60 in col 2 — there is none, so without cross-col awareness
      -- the new note would run to the take end. B starts at ppq=360 on
      -- col 1, same (chan, pitch): the write-time clamp must shorten
      -- the new note to endppq=360.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0,   endppq = 120, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
            { ppq = 0,   endppq = 600, chan = 1, pitch = 64, vel = 80,  detune = 0, delay = 0 },
            { ppq = 360, endppq = 600, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
          },
        },
        config = { take = { currentOctave = 4 } },
      }
      h.vm:setGridSize(80, 40)

      local col2 = h.vm.grid.cols[2]
      t.eq(col2.lane, 2)

      h.ec:setPos(1, 2, 1)
      h.vm:editEvent(col2, nil, 1, string.byte('z'), false)

      local newN
      for _, n in ipairs(h.fm:dump().notes) do
        if n.ppq == 60 and n.pitch == 60 then newN = n end
      end
      t.truthy(newN,        'new C-4 note placed at ppq=60')
      t.eq(newN.endppq, 360, 'new note endppq clamped to B.ppq (cross-col same-key successor)')
    end,
  },

  -- No-op when delay is already zero: the branch is guarded so the
  -- keystroke doesn't emit a redundant flush.
  -- Single-cell pitch delete extends the predecessor's endppq to the next
  -- note's start when the predecessor was tied to the deleted note.
  {
    name = 'delete on pitch tied predecessor extends to next note',
    run = function(harness)
      -- res=240, 4 rpb → 1 row = 60 ppq. Three sequential same-pitch notes:
      --   A: open (legato, endppqL=util.OPEN) at ppq 0, runs to the
      --      next same-pitch onset
      --   B: rows 2..3 (ppq 120..240)
      --   C: rows 4..5 (ppq 240..360)
      -- A is open, so the universal tail pass clips it to B's onset.
      -- Delete B → A's realised tail regrows to the next same-pitch
      -- onset C.ppq=240. (Legato is util.OPEN now, not implicit
      -- adjacency.)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0,   endppq = 120, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0, endppqL = util.OPEN },
            { ppq = 120, endppq = 240, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
            { ppq = 240, endppq = 360, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
          },
        },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(2, 1, 1) -- row 2 = ppq 120 (B), pitch stop
      h.cmgr:invoke('delete')

      local notes = h.fm:dump().notes
      t.eq(#notes, 2, 'B deleted')
      local A, C
      for _, n in ipairs(notes) do
        if     n.ppq == 0   then A = n
        elseif n.ppq == 240 then C = n end
      end
      t.truthy(A and C, 'A and C survive')
      t.eq(A.endppq, 240, 'open A regrows its realised tail to the next same-pitch onset')
    end,
  },

  -- Onset-only neighbour geometry (overlapBounds): a same-pitch
  -- predecessor with an OPEN authored tail must not bound a duration
  -- edit by its tail. Pre-fix, overlapBounds read tailEnd(prevS) ==
  -- util.OPEN and did math.max(number, 'open') -> error. Post-fix it
  -- bounds by the predecessor's ONSET; tm clips any overrun on rebuild.
  {
    name = 'growNote past an open-tailed same-pitch predecessor does not throw',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0,   endppq = 120, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0, endppqL = util.OPEN },
            { ppq = 240, endppq = 480, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0 },
          },
        },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(4, 1, 1) -- row 4 = ppq 240 = B (same pitch as open A)
      h.cmgr:invoke('growNote')

      local A, B
      for _, n in ipairs(h.fm:dump().notes) do
        if     n.ppq == 0   then A = n
        elseif n.ppq == 240 then B = n end
      end
      t.truthy(A and B, 'both notes survive the duration edit')
      t.truthy(B.endppq > 480, 'B grew its tail (overlapBounds did not throw)')
      t.eq(A.endppq, 240, 'open A still clips to B onset, unbounded by the edit')
    end,
  },

  -- Single-cell vel delete carries forward from the most recent prior event,
  -- including PAs — not just the previous note.
  {
    name = 'delete on vel inherits from a prior PA event',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0,   endppq = 240, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
            { ppq = 240, endppq = 480, chan = 1, pitch = 60, vel = 80,  detune = 0, delay = 0 },
          },
          ccs = {
            { ppq = 120, chan = 1, evType = 'pa', pitch = 60, vel = 70 },
          },
        },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(4, 1, 3) -- row 4 = ppq 240 (note B), vel stop
      h.cmgr:invoke('delete')

      local note
      for _, n in ipairs(h.fm:dump().notes) do
        if n.ppq == 240 then note = n end
      end
      t.truthy(note, 'B survives')
      t.eq(note.vel, 70, 'B.vel inherits from prior PA, not prior note')
    end,
  },

  -- Single-cell pitch delete on a PA cell is a no-op: pitch part targets
  -- notes only, even when the cell under the cursor is a PA.
  {
    name = 'delete on pitch over a PA cell is a no-op',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
          },
          ccs = {
            { ppq = 120, chan = 1, evType = 'pa', pitch = 60, vel = 70 },
          },
        },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(2, 1, 1) -- row 2 = ppq 120 (PA cell), pitch stop
      h.cmgr:invoke('delete')

      local dump = h.fm:dump()
      t.eq(#dump.notes, 1, 'note untouched')
      local stillPA = false
      for _, c in ipairs(dump.ccs) do
        if c.evType == 'pa' and c.ppq == 120 then stillPA = true end
      end
      t.truthy(stillPA, 'PA untouched')
    end,
  },

  -- Selection pitch delete operates on notes only; PAs in the rectangle
  -- are left alone (vel-part delete is the channel for removing PAs).
  -- Host note sits outside the selection so its survival isolates what the
  -- queue function does on its own — no cascade-from-host noise.
  {
    name = 'selection pitch delete leaves PAs alone',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            -- Cell at row 0; covers ppq 0..480 so it hosts the PA.
            { ppq = 0, endppq = 480, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
          },
          ccs = {
            -- Cell at row 2; pitch=60 means hosted by the note above.
            { ppq = 120, chan = 1, evType = 'pa', pitch = 60, vel = 70 },
          },
        },
      }
      h.vm:setGridSize(80, 40)
      -- Selection rows 1..3 (ppq [60, 240)) excludes the host note (row 0)
      -- and includes the PA (row 2).
      h.ec:setSelection{ row1=1, row2=3, col1=1, col2=1, part1='pitch', part2='pitch' }

      h.cmgr:invoke('deleteSel')

      local dump = h.fm:dump()
      t.eq(#dump.notes, 1, 'host note untouched (outside selection)')
      local stillPA = false
      for _, c in ipairs(dump.ccs) do
        if c.evType == 'pa' and c.ppq == 120 then stillPA = true end
      end
      t.truthy(stillPA, 'PA preserved under pitch-part selection delete')
    end,
  },

  -- Selection vel delete removes PAs in the rectangle; notes get vel reset.
  {
    name = 'selection vel delete deletes PAs and resets note vels',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            -- Host note for the PA, sits at row 0 outside the selection.
            { ppq = 0, endppq = 480, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
          },
          ccs = {
            { ppq = 120, chan = 1, evType = 'pa', pitch = 60, vel = 70 },
          },
        },
      }
      h.vm:setGridSize(80, 40)
      -- Rows 1..3 covers the PA cell (row 2) but not the host note (row 0).
      h.ec:setSelection{ row1=1, row2=3, col1=1, col2=1, part1='vel', part2='vel' }

      h.cmgr:invoke('deleteSel')

      local dump = h.fm:dump()
      t.eq(#dump.notes, 1, 'host note survives')
      local paGone = true
      for _, c in ipairs(dump.ccs) do
        if c.evType == 'pa' and c.ppq == 120 then paGone = false end
      end
      t.truthy(paGone, 'PA in vel-part selection deleted')
    end,
  },

  -- Regression: editing the value of an existing PA event must read its
  -- current value from `vel` (the in-memory column shape) and write the
  -- update via `val` (the mm-side field). vm previously read `evt.val`,
  -- which is nil after rebuild — setDigit(nil, ...) crashed on arithmetic.
  {
    name = 'edit existing PA value reads vel and persists via val',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 480, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
          },
          ccs = {
            { ppq = 120, chan = 1, evType = 'pa', pitch = 60, vel = 0x70 },
          },
        },
      }
      h.vm:setGridSize(80, 40)
      local col = h.vm.grid.cols[1]
      local pa = col.cells[2]
      t.truthy(pa and pa.evType == 'pa', 'PA cell at row 2')
      h.ec:setPos(2, 1, 3) -- row 2 = ppq 120 (PA), high vel nibble
      h.vm:editEvent(col, pa, 3, string.byte('5'), false)

      local out
      for _, c in ipairs(h.fm:dump().ccs) do
        if c.evType == 'pa' then out = c end
      end
      t.truthy(out, 'PA survives')
      t.eq(out.vel, 0x50, 'high nibble updated to 5')
    end,
  },

  -- Regression: stamping a PA under non-zero swing must produce a PA
  -- whose display row matches the cursor row, and that single PA must be
  -- deletable in one shot. (Two stamps + two deletes guards against the
  -- "second PA orphans into overflow" failure mode.)
  {
    name = 'PA stamped under swing is reachable and deletable',
    run = function(harness)
      local c58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }
      local hostFrame = { swing = 'c58', colSwing = nil, rpb = 4 }
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 960, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0, frame = hostFrame },
          },
        },
        config = {
          project = { swings = { c58 = c58 } },
          take    = { rowPerBeat = 4 },
        },
        data = { swing = { global = 'c58' } },
      }
      h.vm:setGridSize(80, 40)
      local col = h.vm.grid.cols[1]

      -- Stamp PA at row 1 (off the period boundary under c58).
      h.ec:setPos(1, 1, 3)
      h.vm:editEvent(col, nil, 3, string.byte('5'), false)

      col = h.vm.grid.cols[1]
      local pa = col.cells[1]
      t.truthy(pa and pa.evType == 'pa', 'PA appears at row 1 cell')
      t.eq(col.overflow[1], nil, 'no overflow at row 1')

      -- Stamp another PA at row 2.
      h.ec:setPos(2, 1, 3)
      h.vm:editEvent(h.vm.grid.cols[1], nil, 3, string.byte('7'), false)

      col = h.vm.grid.cols[1]
      t.truthy(col.cells[1] and col.cells[1].evType == 'pa', 'row 1 still PA')
      t.truthy(col.cells[2] and col.cells[2].evType == 'pa', 'row 2 PA')
      t.eq(col.overflow[1], nil, 'no overflow at row 1')
      t.eq(col.overflow[2], nil, 'no overflow at row 2')

      -- Delete row 2 PA.
      h.ec:setPos(2, 1, 3)
      h.cmgr:invoke('delete')

      local survivors = {}
      for _, c in ipairs(h.fm:dump().ccs) do
        if c.evType == 'pa' then survivors[#survivors+1] = c end
      end
      t.eq(#survivors, 1, 'one PA remains after deleting row 2')

      -- Delete row 1 PA.
      h.ec:setPos(1, 1, 3)
      h.cmgr:invoke('delete')
      survivors = {}
      for _, c in ipairs(h.fm:dump().ccs) do
        if c.evType == 'pa' then survivors[#survivors+1] = c end
      end
      t.eq(#survivors, 0, 'all PAs deleted')
    end,
  },

  {
    name = 'delete on delay stop is a no-op when delay is already 0',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 60, endppq = 300, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0 },
          },
        },
        data = { noteDelay = { [1] = { [1] = true } } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(1, 1, 5)
      h.cmgr:invoke('delete')

      local note = h.fm:dump().notes[1]
      t.eq(note.delay, 0)
      t.eq(note.ppq,   60, 'ppq unchanged')
      t.eq(note.endppq, 300, 'endppq unchanged')
    end,
  },
}
