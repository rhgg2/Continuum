-- Groups × swing: the gm→tm intent/realisation seam under a non-identity
-- swing. Real tm, real cm (classic-55 take swing), real gm wired into
-- the production flush pipeline.
--
-- The incident: groupManager.updToInstance is a LOGICAL caller -- it
-- builds instance-frame updates with ppq/endppq in the authoring grid
-- and emits endppqL as the intent ceiling. tm.realiseNoteUpdate used to
-- treat the mere PRESENCE of endppqL (or ppqL) as the "caller already
-- computed raw" bypass, skipping swing on update.ppq. So a propagated
-- reproject `set` placed a sibling's note-on at its logical position
-- read as raw -- off-grid by exactly the swing displacement (the
-- reported "row 2 copy lands off-grid in row 9" under classic-55).
--
-- Fix: the bypass is an explicit, consumed-and-stripped `rawTime` flag,
-- not the presence of a data stamp. Logical callers (gm) no longer trip
-- it; the genuine raw caller (reswing/rescale) sets it.

local t    = require('support')
local util = require('util')
local harness = require('harness')

-- classic-55: principal at x=0.5 maps to 0.55 of the period.
local C55 = { config = {
  project = { swings = { ['c55'] = {
    factors = { { atom = 'classic', shift = 0.05, period = 1 } } } } },
  take    = { swing = 'c55' },
}, groups = true }

-- resolution 240, rpb 4, denom 4 -> logPerRow 60; period 1 QN = 240.
local LPR = 60

-- One probe scenario to resolve the swung raw for a logical position
-- without hand-coding the closed form -- the same transform tm uses.
local function probe()
  return harness.mk(C55).tm
end

local function seededHarness(notes)
  return harness.mk{
    config = C55.config,
    groups = true,
    seed   = { length = 7680, resolution = 240, notes = notes },
  }
end

return {
  ----- End-to-end: the real gm propagation path under classic-55.

  {
    name = 'newInstance copies land on the swung grid (add path guard)',
    run = function()
      local p   = probe()
      -- Two finite notes inside an 8-row region, authored on-grid.
      local seed = {
        { ppq = p:fromLogical(1, 180), endppq = p:fromLogical(1, 360),
          ppqL = 180, endppqL = 360, chan = 1, lane = 1,
          pitch = 60, vel = 100, uuid = 1 },
        { ppq = p:fromLogical(1, 300), endppq = p:fromLogical(1, 420),
          ppqL = 300, endppqL = 420, chan = 1, lane = 1,
          pitch = 64, vel = 100, uuid = 2 },
      }
      local h  = seededHarness(seed)
      local gm = h.gm

      -- Source events as production gm callers see them: the vm grid,
      -- logical frame (NOT tm:byUuid, whose .ppq is raw).
      local rect = { ppq = 0, dur = 8 * LPR, chanLo = 1,
                     streams = { [0] = { ['note:1'] = true } } }
      local src = h.vm:eventsInRect(rect)
      t.eq(#src, 2, 'both source notes found in the region')

      local gid = gm:markGroup(src, rect)
      gm:newInstance(gid, { ppq = 960, chan = 1 })   -- a region far below
      h.tm:flush()

      local function copyAt(pitch, logical)
        for _, n in ipairs(h.fm:dump().notes) do
          if n.pitch == pitch and n.ppq == h.tm:fromLogical(1, logical) then
            return n
          end
        end
      end
      t.truthy(copyAt(60, 1140), 'A copy on the swung grid at logical 1140')
      t.truthy(copyAt(64, 1260), 'B copy on the swung grid at logical 1260')
    end,
  },

  {
    name = 'a propagated reproject set keeps siblings on the swung grid',
    run = function()
      local p    = probe()
      local seed = {
        { ppq = p:fromLogical(1, 180), endppq = p:fromLogical(1, 360),
          ppqL = 180, endppqL = 360, chan = 1, lane = 1,
          pitch = 60, vel = 100, uuid = 1 },
      }
      local h  = seededHarness(seed)
      local gm = h.gm

      local rect = { ppq = 0, dur = 8 * LPR, chanLo = 1,
                     streams = { [0] = { ['note:1'] = true } } }
      local src = h.vm:eventsInRect(rect)
      local gid    = gm:markGroup(src, rect)
      local instId = gm:newInstance(gid, { ppq = 960, chan = 1 })
      h.tm:flush()

      local function siblingRaw()
        local want = h.tm:fromLogical(1, 1140)
        for _, n in ipairs(h.fm:dump().notes) do
          if n.pitch == 60 and n.ppq ~= h.tm:fromLogical(1, 180) then
            return n.ppq, want
          end
        end
      end
      local before, onGrid = siblingRaw()
      t.eq(before, onGrid, 'sibling starts on the swung grid')

      -- Re-origin the shared rect from the start edge: every anchor and
      -- every group-event ppq shift so realised positions MUST hold.
      -- This drives reproject -> a position-changing `set` for every
      -- event through updToInstance (the buggy seam).
      t.truthy(gm:resizeGroup(gid, instId, { startDelta = LPR }),
        'startDelta resize accepted')
      h.tm:flush()

      local after = siblingRaw()
      t.eq(after, onGrid,
        'sibling still on the swung grid after the propagated set ' ..
        '(bug: it jumps to the unswung logical position)')
    end,
  },

  ----- Unit pins on tm's public API with the exact update shapes
  ----- groupManager.updToInstance emits. Production surface, not a fake.

  {
    name = 'assignEvent: a logical (ppq+endppqL) update swings the onset',
    run = function()
      local p    = probe()
      local h    = seededHarness{
        { ppq = p:fromLogical(1, 180), endppq = p:fromLogical(1, 360),
          ppqL = 180, endppqL = 360, chan = 1, lane = 1,
          pitch = 60, vel = 100, uuid = 1 },
      }
      local n = h.tm:byUuid(1)
      -- updToInstance's finite-note shape: logical onset + intent ceiling.
      h.tm:assignEvent(n, { ppq = 300, endppqL = 480, endppq = 480 })
      h.tm:flush()

      local moved = h.fm:dump().notes[1]
      t.eq(moved.ppq, h.tm:fromLogical(1, 300),
        'onset swung to the realised grid')
      t.truthy(moved.ppq ~= 300,
        'swing actually applied (bug threads 300 through unswung)')
    end,
  },

  {
    name = 'assignEvent: reopening (endppqL=REMOVE) still swings the onset',
    run = function()
      local p = probe()
      local h = seededHarness{
        { ppq = p:fromLogical(1, 180), endppq = p:fromLogical(1, 360),
          ppqL = 180, endppqL = 360, chan = 1, lane = 1,
          pitch = 60, vel = 100, uuid = 1 },
      }
      local n = h.tm:byUuid(1)
      -- updToInstance's open shape: clear the ceiling, provisional tail.
      h.tm:assignEvent(n, { ppq = 300, open = true,
                            endppqL = util.REMOVE, endppq = 301 })
      h.tm:flush()

      local moved = h.fm:dump().notes[1]
      t.eq(moved.ppq, h.tm:fromLogical(1, 300),
        'open-note onset swung, not threaded through unswung')
      t.eq(h.tm:byUuid(1).endppqL, nil,
        'ceiling cleared -- the note is unbounded again')
    end,
  },

  {
    name = 'assignEvent: explicit rawTime threads caller raw unmodified',
    run = function()
      local p = probe()
      local h = seededHarness{
        { ppq = p:fromLogical(1, 180), endppq = p:fromLogical(1, 360),
          ppqL = 180, endppqL = 360, chan = 1, lane = 1,
          pitch = 60, vel = 100, uuid = 1 },
      }
      local n = h.tm:byUuid(1)
      -- The genuine raw caller (reswing/rescale): a CONSISTENT (ppqL,
      -- raw) pair already computed. tm must thread raw straight through,
      -- not swing it a second time (raw -> fromLogical(raw)).
      local rawOn, rawOff = p:fromLogical(1, 300), p:fromLogical(1, 480)
      h.tm:assignEvent(n, { ppq = rawOn, ppqL = 300,
                            endppq = rawOff, endppqL = 480, rawTime = true })
      h.tm:flush()

      local moved = h.fm:dump().notes[1]
      t.eq(moved.ppq, rawOn, 'raw onset threaded unmodified (no second swing)')
      t.truthy(moved.ppq ~= h.tm:fromLogical(1, rawOn),
        'a second swing would have moved it; it did not')
      t.eq(moved.endppq, rawOff, 'raw note-off threaded unmodified')
      t.eq(h.tm:byUuid(1).ppqL, 300, 'caller logical stamp kept')
      t.eq(h.tm:byUuid(1).rawTime, nil, 'flag stripped, never persisted')
    end,
  },
}
