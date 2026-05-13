-- Reswing under cm's current swing. Each CC/PB/AT/PC/PA carries an
-- evt.rpb authoring marker; ppqL is the truth, raw is reproduced
-- under cm.swing — no per-event swing stamp, no host-frame borrowing.

local t = require('support')

local classic58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }
local classic67 = { factors = { { atom = 'classic', shift = 0.17, period = 1 } } }

local function findCC(dump, msgType, chan)
  for _, c in ipairs(dump.ccs) do
    if c.msgType == msgType and (chan == nil or c.chan == chan) then return c end
  end
end

return {
  {
    name = 'CC authored under c58 reswings to identity using its ppqL',
    run = function(harness)
      -- Row 2 in rpb=4 has logical ppq 120; under c58 that lands at 139.
      -- Seed coherent under c58, flip take swing off: the stale-arm
      -- rebuild reseats raw to the identity-frame realisation (120),
      -- and the explicit reswingAll no-ops on the now-coherent state.
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq = 139, ppqL = 120,
              chan = 2, msgType = 'cc', cc = 1, val = 64,
              rpb = 4 },
          },
        },
        config = {
          project = { swings = { ['c58'] = classic58 } },
          take    = { swing = 'c58', rowPerBeat = 4 },
        },
      }
      h.cm:remove('take', 'swing')
      h.vm:setGridSize(80, 40)
      h.vm:reswingAll()

      local cc = findCC(h.fm:dump(), 'cc', 2)
      t.truthy(cc, 'cc survives swing change')
      t.eq(cc.ppq, 120, 'cc reswung to identity-frame intent ppq=120')
    end,
  },

  {
    name = 'CC without an rpb stamp is skipped by reswing',
    run = function(harness)
      -- No rpb stamp → reswing has no auth marker; leaves it alone.
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq = 139, chan = 2, msgType = 'cc', cc = 1, val = 64 },
          },
        },
        config = {
          project = { swings = { ['c58'] = classic58 } },
          take    = { swing = 'c58', rowPerBeat = 4 },
        },
      }
      h.vm:setGridSize(80, 40)
      h.vm:reswingAll()

      local cc = findCC(h.fm:dump(), 'cc', 2)
      t.eq(cc.ppq, 139, 'frameless cc untouched')
    end,
  },

  {
    name = 'reswing leaves cc.rpb untouched and reseats raw under cm.swing',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq = 139, ppqL = 120,
              chan = 2, msgType = 'cc', cc = 1, val = 64,
              rpb = 4 },
          },
        },
        config = {
          project = { swings = { ['c58'] = classic58, ['c67'] = classic67 } },
          take    = { swing = 'c67', rowPerBeat = 4 },
        },
      }
      h.vm:setGridSize(80, 40)
      h.vm:reswingAll()

      local cc = findCC(h.fm:dump(), 'cc', 2)
      t.eq(cc.rpb, 4, 'rpb preserved (reswing does not restamp)')
    end,
  },

  {
    name = 'tm:addEvent does NOT auto-stamp rpb (vm/ec own that responsibility)',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { ['c58'] = classic58 } },
          take    = { swing = 'c58', rowPerBeat = 8 },
        },
      }
      h.tm:addEvent('cc', { ppq = 0, chan = 3, cc = 7, val = 100 })
      h.tm:flush()
      local cc = findCC(h.fm:dump(), 'cc', 3)
      t.truthy(cc, 'cc landed')
      t.eq(cc.rpb, nil, 'tm did not stamp rpb — caller must do it')
    end,
  },

  {
    name = 'vm:editEvent on a cc column stamps the current rpb',
    run = function(harness)
      local h = harness.mk{
        seed = {
          -- Existing cc to materialise a cc=11 column on chan 1.
          ccs = { { ppq = 0, chan = 1, msgType = 'cc', cc = 11, val = 0 } },
        },
        config = {
          project = { swings = { ['c58'] = classic58 } },
          take    = { swing = 'c58', rowPerBeat = 8 },
        },
      }
      h.vm:setGridSize(80, 40)

      local ccCol
      for _, col in ipairs(h.vm.grid.cols) do
        if col.type == 'cc' and col.cc == 11 then ccCol = col end
      end
      t.truthy(ccCol, 'cc=11 column present')

      -- Author a new cc one row down (row 1 = ppq 30 under rpb=8).
      h.ec:setPos(1, 1, 1)
      -- Find the col index for ccCol.
      local ccColIdx
      for i, col in ipairs(h.vm.grid.cols) do
        if col == ccCol then ccColIdx = i end
      end
      h.ec:setPos(1, ccColIdx, 1)
      h.vm:editEvent(ccCol, nil, 1, string.byte('5'), false)

      local fresh
      for _, c in ipairs(h.fm:dump().ccs) do
        if c.msgType == 'cc' and c.cc == 11 and c.ppq ~= 0 then fresh = c end
      end
      t.truthy(fresh, 'authored cc landed')
      t.eq(fresh.rpb, 8, 'rpb stamped from take')
    end,
  },

  {
    name = 'PB reswung twice: ppqL + rpb survive the first pass',
    run = function(harness)
      -- assignPb's ppq-change path delete-and-re-adds the pb. If the new
      -- pb doesn't inherit ppqL/rpb, the *next* reswing reads
      -- ppqL=nil and tile() / round() blow up.
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq = 139, ppqL = 120,
              chan = 2, msgType = 'pb', val = 0,
              rpb = 4 },
          },
        },
        config = {
          project = { swings = { ['c58'] = classic58 } },
          take    = { swing = 'c58', rowPerBeat = 4 },
        },
      }
      h.cm:remove('take', 'swing')
      h.vm:setGridSize(80, 40)
      h.vm:reswingAll()
      h.vm:reswingAll()

      local pb = findCC(h.fm:dump(), 'pb', 2)
      t.truthy(pb, 'pb survives both reswings')
      t.eq(pb.ppq, 120, 'pb at identity-target intent ppq=120')
      t.eq(pb.ppqL, 120, 'ppqL preserved across reswing')
      t.eq(pb.rpb, 4, 'rpb preserved across reswing')
    end,
  },

  -- Reswing recomputes intent ppqs but leaves delay alone. If the
  -- new swing closes a gap below the magnitude of an existing delay,
  -- the same realised reorder delayRange now forbids on direct edits
  -- would slip in via reswing. The pass-1.5 clamp in reswingCore
  -- pulls offending delays back to the post-reswing realised-order
  -- bound, so the invariant holds across reswing too.
  {
    name = 'reswing into tighter swing clamps delay to preserve realised order',
    run = function(harness)
      -- A (pitch 60) at row 2, B (pitch 64) at row 3, both lane 1 of
      -- channel 1, both authored under identity (swing = nil). B has
      -- delay = -240 ms-QN (= -58 ppq @ res=240), valid pre-reswing:
      -- A.realised=120, B.realised=122.
      --
      -- Reswing target = c58. Under c58, ppqL 120 → 139,
      -- 180 → 194 (= round(240 * (0.75 + 0.08·sin(π·0.75)))). The
      -- unclamped delay would put B.realised at 194 + (-58) = 136 —
      -- *before* A's 139. Pass 1.5 clamps B.delay to ceil(ppqToDelay
      -- (140 − 194, 240)) = ceil(-225) = -225, landing B.realised at
      -- 140, just after A.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 120, endppq = 150, ppqL = 120, endppqL = 150,
              chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0,
              rpb = 4 },
            { ppq = 122, endppq = 240, ppqL = 180, endppqL = 240,
              chan = 1, pitch = 64, vel = 100, detune = 0, delay = -240,
              rpb = 4 },
          },
        },
        config = {
          project = { swings = { ['c58'] = classic58 } },
          take    = { rowPerBeat = 4 },
        },
      }
      h.cm:set('take', 'swing', 'c58')
      h.vm:setGridSize(80, 40)
      h.vm:reswingAll()

      local Bafter
      for _, x in ipairs(h.fm:dump().notes) do
        if x.pitch == 64 then Bafter = x end
      end
      t.truthy(Bafter, 'B survives reswing')
      t.eq(Bafter.delay, -225,
        'delay clamped at A.realisedOnset + 1 in the post-reswing geometry')
      t.eq(Bafter.ppq, 140, 'realised onset = A.realisedOnset + 1 = 140')
    end,
  },

  {
    name = 'CC rpb metadata surfaces on tm column events after rebuild',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq = 60, chan = 1, msgType = 'cc', cc = 11, val = 50,
              rpb = 4 },
          },
        },
        config = {
          project = { swings = { ['c58'] = classic58 } },
          take    = { swing = 'c58', rowPerBeat = 4 },
        },
      }
      local ch  = h.tm:getChannel(1)
      local col = ch.columns.ccs[11]
      t.truthy(col and col.events[1], 'cc column event present')
      t.eq(col.events[1].rpb, 4,
           'cc.rpb propagated from mm onto tm column event')
    end,
  },
}
