-- Two-frame boundary at um: caller passes evt.ppq / update.ppq in the
-- logical frame; um stamps ppqL with that value and overwrites ppq
-- with raw via fromLogical(ppq) + delay before mm sees the record.

local t = require('support')

local classic58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }

return {

  {
    name = 'addEvent: caller ppq is logical; um derives raw under swing and stamps ppqL',
    run = function(harness)
      -- c58 maps mid-period (ppq=120, period=240) to raw 139.2 → 139.
      local h = harness.mk{
        config = {
          project = { swings = { ['c58'] = classic58 } },
          take    = { swing = 'c58' },
        },
      }
      h.tm:addEvent({ evType = 'note',
        ppq = 120, endppq = 240,
        chan = 1, pitch = 60, vel = 100,
        detune = 0, delay = 0, lane = 1,
      })
      h.tm:flush()

      local notes = h.fm:dump().notes
      t.eq(#notes, 1, 'one note persisted')
      t.eq(notes[1].ppq,  139, 'raw = fromLogical(ppq) under c58')
      t.eq(notes[1].ppqL, 120, 'ppqL stamped with caller logical ppq')
    end,
  },

  {
    name = 'addEvent: delay shifts raw, leaves ppqL on the logical row',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { ['c58'] = classic58 } },
          take    = { swing = 'c58' },
        },
      }
      -- delay in milli-QN: 125 mQN @ 240 ppq/QN = 30 ppq nudge on note-on.
      h.tm:addEvent({ evType = 'note',
        ppq = 120, endppq = 240,
        chan = 1, pitch = 60, vel = 100,
        detune = 0, delay = 125, lane = 1,
      })
      h.tm:flush()

      local notes = h.fm:dump().notes
      t.eq(notes[1].ppq,    139 + 30, 'raw = fromLogical(ppq) + delayToPPQ(delay)')
      t.eq(notes[1].ppqL,   120,      'ppqL pins logical onset')
      t.eq(notes[1].endppq, 240,      'endppq derives logical→raw (identity at period boundary)')
    end,
  },

  {
    name = 'assignEvent: update.ppq is logical; raw derives via swing, ppqL restamped',
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
      h.tm:assignEvent(n, { ppq = 120 })
      h.tm:flush()

      local notes = h.fm:dump().notes
      t.eq(notes[1].ppq,  139, 'raw = fromLogical(update.ppq)')
      t.eq(notes[1].ppqL, 120, 'ppqL restamped from update.ppq')
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
      h.tm:assignEvent(n, { delay = 125 })
      h.tm:flush()

      local notes = h.fm:dump().notes
      -- raw = round(fromLogical(120)) + delayToPPQ(125) = 139 + 30 = 169.
      t.eq(notes[1].ppq, 169, 'raw forward-derived from evt.ppqL + new delay')
    end,
  },
}
