-- Phase 4 (two-frame timing): tm derives raw ppq forward from
-- (ppqL, delay). The caller's ppq is no longer trusted as a frame
-- when ppqL is provided — vm's Phase 1 invariant (ppqL pinned on
-- every authoring call) makes ppqL the source of truth, and tm
-- reproduces raw via fromLogical(ppqL) + delay.
--
-- Tests pass intentionally-stale caller ppq alongside correct ppqL
-- under non-identity swing so the forward formula and the
-- caller-trust formula give measurably different answers.

local t = require('support')

local classic58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }

return {

  {
    name = 'addEvent: ppqL drives raw under swing; caller ppq is ignored',
    run = function(harness)
      -- c58 maps mid-period (ppqL=120, period=240) to raw 139.2 → 139.
      local h = harness.mk{
        config = {
          project = { swings = { ['c58'] = classic58 } },
          take    = { swing = 'c58' },
        },
      }
      h.tm:addEvent('note', {
        ppq = 999, endppq = 240,           -- intentionally stale
        ppqL = 120, endppqL = 240,         -- the truth
        chan = 1, pitch = 60, vel = 100,
        detune = 0, delay = 0, lane = 1,
      })
      h.tm:flush()

      local notes = h.fm:dump().notes
      t.eq(#notes, 1, 'one note persisted')
      t.eq(notes[1].ppq, 139, 'raw derived from ppqL via swing, not from caller ppq')
      t.eq(notes[1].ppqL, 120, 'ppqL preserved')
    end,
  },

  {
    name = 'addEvent: ppqL drives raw with delay added on top',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { ['c58'] = classic58 } },
          take    = { swing = 'c58' },
        },
      }
      -- delay in milli-QN: 125 mQN @ 240 ppq/QN = 30 ppq nudge on note-on.
      h.tm:addEvent('note', {
        ppq = 0, endppq = 240,
        ppqL = 120, endppqL = 240,
        chan = 1, pitch = 60, vel = 100,
        detune = 0, delay = 125, lane = 1,
      })
      h.tm:flush()

      local notes = h.fm:dump().notes
      t.eq(notes[1].ppq, 139 + 30, 'raw = swing.fromLogical(ppqL) + delayToPPQ(delay)')
      t.eq(notes[1].endppq, 240, 'endppq stays caller-provided (no delay)')
    end,
  },

  {
    name = 'assignEvent: update.ppqL drives raw; update.ppq is ignored when both provided',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { ['c58'] = classic58 } },
          take    = { swing = 'c58' },
        },
        seed = { notes = {
          { ppq = 0, endppq = 60, ppqL = 0, endppqL = 60,
            chan = 1, pitch = 60, vel = 100 },
        }},
      }
      local n = h.tm:getChannel(1).columns.notes[1].events[1]
      -- Caller asks for ppqL=120 (mid-period under c58 → raw 139),
      -- but passes a stale ppq=999. Forward formula wins.
      h.tm:assignEvent('note', n, { ppq = 999, ppqL = 120 })
      h.tm:flush()

      local notes = h.fm:dump().notes
      t.eq(notes[1].ppq, 139, 'raw rederived from update.ppqL, not update.ppq')
      t.eq(notes[1].ppqL, 120, 'ppqL set from update')
    end,
  },

  {
    name = 'assignEvent: delay-only edit recomputes raw forward from evt.ppqL under swing',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { ['c58'] = classic58 } },
          take    = { swing = 'c58' },
        },
        seed = { notes = {
          -- ppqL=120 under c58 → expected raw 139 after first rebuild.
          { ppq = 139, endppq = 240, ppqL = 120, endppqL = 240,
            chan = 1, pitch = 60, vel = 100, delay = 0 },
        }},
      }
      local n = h.tm:getChannel(1).columns.notes[1].events[1]
      h.tm:assignEvent('note', n, { delay = 125 })
      h.tm:flush()

      local notes = h.fm:dump().notes
      -- raw = round(fromLogical(120)) + delayToPPQ(125) = 139 + 30 = 169.
      t.eq(notes[1].ppq, 169, 'raw forward-derived from evt.ppqL + new delay')
    end,
  },
}
