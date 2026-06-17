-- Authored delay is intent: vm writes it through unbounded (modulo the
-- ±999 digit-entry cap). tm clamps raw at realisation -- raw ≥ 0 in
-- realiseNoteUpdate, same-pitch onset floor in step 4.8 -- and exposes
-- the realised-frame equivalent as evt.delayC. tp surfaces the
-- divergence (delay ~= delayC) via a small * next to the delay digits.

local t = require('support')

return {

  -- A note ending at item edge used to be uneditable on the delay column
  -- because delayRange capped against item length. Under the unified
  -- model that gate is gone -- authored delay survives.
  {
    name = 'positive delay accepted on a note ending at item length',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 3840, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0 },
          },
        },
        data = { noteDelay = { [1] = { [1] = true } } },
      }
      h.vm:setGridSize(80, 40)

      local col = h.vm.grid.cols[1]
      h.ec:setPos(0, 1, 5)
      h.vm:editEvent(col, col.cells[0], 5, string.byte('5'), false)

      local n = h.fm:dump().notes[1]
      t.eq(n.delay, 500, 'authored delay survives — no bound on delay in vm')
      t.eq(n.ppq, 120, 'realised onset = 0 + delayToPPQ(500) = 120')
    end,
  },

  -- delay past the note's authored end is allowed: intent is preserved,
  -- step 4.8's tail walk gives the realised note its 1-tick minimum.
  -- (Previously delayRange clamped here; now the divergence shows up
  -- via the tp marker rather than a vm-side refusal.)
  {
    name = 'delay past intent-end survives — tail walk handles realisation',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 120, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0 },
          },
        },
        data = { noteDelay = { [1] = { [1] = true } } },
      }
      h.vm:setGridSize(80, 40)

      local col = h.vm.grid.cols[1]
      h.ec:setPos(0, 1, 5)
      h.vm:editEvent(col, col.cells[0], 5, string.byte('9'), false)

      local n = h.fm:dump().notes[1]
      t.eq(n.delay, 900, 'authored delay preserved')
      t.eq(n.ppq, 216, 'realised onset moves past authored end')
      t.eq(n.endppq, 217, 'step 4.8 tail walk pinches endppq up to onset+1')
    end,
  },

  -- Different-pitch column-mate imposes no constraint. Same as before
  -- the rework; pinned to guard against accidental re-introduction.
  {
    name = 'different-pitch next imposes no delay constraint',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0,   endppq = 600, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0 },
            { ppq = 240, endppq = 480, chan = 1, pitch = 64, vel = 80,
              detune = 0, delay = 0 },
          },
        },
        data = { noteDelay = { [1] = { [1] = true } } },
      }
      h.vm:setGridSize(80, 40)

      local col = h.vm.grid.cols[1]
      h.ec:setPos(0, 1, 5)
      h.vm:editEvent(col, col.cells[0], 5, string.byte('9'), false)

      local n = h.fm:dump().notes[1]
      t.eq(n.delay, 900, 'column cap (±999) is the only bound')
      t.eq(n.ppq, 216, 'realised onset = ppq + delayToPPQ(900) = 216')
      t.eq(n.endppq, 600, 'authored tail untouched by cross-lane neighbour')
    end,
  },

  -- Same-pitch prev used to clamp delay HARD at intent end via
  -- delayRange. Under the unified model authored delay survives; the
  -- tail walk clips A's endppq down to B's realised onset instead.
  {
    name = 'same-pitch prev: authored delay survives; A.endppq clips to B.ppq',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0,   endppq = 120, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0   },
            { ppq = 384, endppq = 480, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 600 },
          },
        },
        data = { noteDelay = { [1] = { [1] = true } } },
      }
      h.vm:setGridSize(80, 40)

      local col = h.vm.grid.cols[1]
      local B = col.cells[4]
      h.ec:setPos(4, 1, 5)
      h.vm:editEvent(col, B, 5, string.byte('-'), false)

      local dump = h.fm:dump().notes
      local A, Bafter = dump[1], dump[2]
      t.eq(Bafter.delay, -600, 'authored delay preserved (no vm clamp)')
      t.eq(Bafter.ppq, 96, 'realised onset = 240 + delayToPPQ(-600) = 96')
      t.eq(A.endppq, 96, 'A.endppq clipped to B.ppq by the tail walk')
    end,
  },

  -- Same-pitch lookup is per (chan, pitch). With B in a different lane,
  -- A's tail walk still finds B and clips. Authored delay preserved.
  {
    name = 'same-pitch prev in another column — A.endppq still clips',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0,   endppq = 120, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0,   lane = 1 },
            { ppq = 384, endppq = 480, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 600, lane = 2 },
          },
        },
        data = {
          noteDelay    = { [1] = { [1] = true, [2] = true } },
          extraColumns = { [1] = { notes = 2 } },
        },
      }
      h.vm:setGridSize(80, 40)

      local colB = h.vm.grid.cols[2]
      local B = colB.cells[4]
      h.ec:setPos(4, 2, 5)
      h.vm:editEvent(colB, B, 5, string.byte('-'), false)

      local dump = h.fm:dump().notes
      local A, Bafter = dump[1], dump[2]
      t.eq(Bafter.delay, -600, 'authored delay preserved across lanes')
      t.eq(A.endppq, 96, 'A.endppq clipped via channel-wide same-pitch lookup')
    end,
  },

  -- Same-column same-lane realised-order used to be a delay bound: the
  -- "realised order = logical order within a column" invariant the pb
  -- model leaned on. Under the unified projection that constraint is
  -- dropped: authored swap survives just as same-pitch does. Whoever
  -- lands first in raw becomes the realised predecessor.
  {
    name = 'same-column prev: authored swap survives in raw',
    run = function(harness)
      -- A pitch 60 at ppqL=240, B pitch 64 at ppqL=360 (lane 1, chan 1).
      -- B seeded with delay=-100; user types '9' on the 100s digit →
      -- sign=-1 (from existing negative), newDelay = -900. Old code
      -- clamped at -495. New policy lets it through: B.raw = 360 - 216
      -- = 144 (before A.raw=240). Display still shows B below A; raw
      -- plays B first.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 240, endppq = 360, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0    },
            { ppq = 336, endppq = 720, chan = 1, pitch = 64, vel = 100,
              detune = 0, delay = -100 },
          },
        },
        data = { noteDelay = { [1] = { [1] = true } } },
      }
      h.vm:setGridSize(80, 40)

      local col = h.vm.grid.cols[1]
      local B = col.cells[6]
      h.ec:setPos(6, 1, 5)
      h.vm:editEvent(col, B, 5, string.byte('9'), false)

      local Bafter
      for _, x in ipairs(h.fm:dump().notes) do
        if x.pitch == 64 then Bafter = x end
      end
      t.eq(Bafter.delay, -900, 'authored swap survives — no realised-order bound')
      t.eq(Bafter.ppq, 144, 'B lands at 144, before A at 240')
    end,
  },

  -- Negative delay on a note at intent ppq 0 is still a vm-level no-op
  -- (sign-toggling zero is futile). Distinct from "delay clamps to 0"
  -- which would write -delay and let tm realise it; the early return
  -- skips the assign entirely. Pinned so the guard survives the
  -- delayRange removal.
  {
    name = 'negative-on-zero is a vm no-op (no futile assign)',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0 },
          },
        },
        data = { noteDelay = { [1] = { [1] = true } } },
      }
      h.vm:setGridSize(80, 40)

      local col = h.vm.grid.cols[1]
      h.ec:setPos(0, 1, 5)
      h.vm:editEvent(col, col.cells[0], 5, string.byte('-'), false)

      local n = h.fm:dump().notes[1]
      t.eq(n.delay, 0)
      t.eq(n.ppq, 0)
    end,
  },

  -- Authored delay that pushes raw onset below 0 is clamped by
  -- realiseNoteUpdate (raw must be ≥ 0). The stored delay is unchanged
  -- — intent preserved — and delayC reflects the realised value, so
  -- divergence (delay ~= delayC) flags it for tp's * marker.
  {
    name = 'raw < 0 clamped in tm; delay ~= delayC flags the divergence',
    run = function(harness)
      -- Note at ppqL=60 (row 1), seeded with delay=-100 so the '-' sign
      -- carries through the next digit edit. Typing '5' on the 100s
      -- gives newDelay=-500 (delayPPQ=-120 → raw=-60). realiseNoteUpdate
      -- clamps to 0; delayC = ppqToDelay(0-60, 240) = -250.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 36, ppqL = 60, endppq = 240, endppqL = 240,
              chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = -100 },
          },
        },
        data = { noteDelay = { [1] = { [1] = true } } },
      }
      h.vm:setGridSize(80, 40)

      local col = h.vm.grid.cols[1]
      h.ec:setPos(1, 1, 5)
      h.vm:editEvent(col, col.cells[1], 5, string.byte('5'), false)

      local n = h.fm:dump().notes[1]
      t.eq(n.delay, -500, 'authored delay preserved')
      t.eq(n.ppq, 0, 'raw clamped to 0 (cannot go negative)')

      -- delayC is computed by tm's projection (line 1527).
      local col1 = h.tm:getChannel(1).columns.notes[1]
      local cn = col1.events[1]
      t.eq(cn.delayC, -250, 'delayC reflects the realised onset')
      t.truthy(cn.delay ~= cn.delayC, 'divergence flag fires (delay ~= delayC)')
    end,
  },

  -- Same-pitch raw collision: A's positive delay puts A.raw past B.intent
  -- onset. step 4.8 clamps B to A.ppq+1; B's delayC reports the drift.
  {
    name = 'same-pitch raw collision: step 4.8 clamps B; delayC reflects it',
    run = function(harness)
      -- A at ppqL=0 endppqL=120 with delay=+500 (delayPPQ=120 → A.raw=120).
      -- B at ppqL=120 endppqL=240 same pitch, delay=0 → B.raw=120. Intent
      -- non-overlapping so both share lane 1. Raw collision: byPitch
      -- sorts by raw then ppqL → A first (ppqL=0), B clamped to A.raw+1
      -- = 121. delayC for B = ppqToDelay(121-120, 240) ≈ 4.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 120, ppqL = 0,   endppq = 120, endppqL = 120,
              chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 500 },
            { ppq = 120, ppqL = 120, endppq = 240, endppqL = 240,
              chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0   },
          },
        },
        data = { noteDelay = { [1] = { [1] = true } } },
      }
      h.vm:setGridSize(80, 40)

      local col1 = h.tm:getChannel(1).columns.notes[1]
      local A, B
      for _, e in ipairs(col1.events) do
        if e.ppqL == 0   then A = e end
        if e.ppqL == 120 then B = e end
      end
      t.truthy(A and B, 'both notes share lane 1 (intent non-overlapping)')
      t.eq(B.delay, 0, 'authored delay 0 preserved')
      t.eq(B.delayC, 4, 'delayC reflects step-4.8 onset clamp to 121')
      t.truthy(B.delay ~= B.delayC, 'divergence — B sounds 1 tick after A')
    end,
  },
}
