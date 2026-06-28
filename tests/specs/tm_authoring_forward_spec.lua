-- Two-frame boundary at um: caller passes evt.ppq / update.ppq in the
-- logical frame; um stamps ppqL with that value and overwrites ppq
-- with raw via fromLogical(ppq) + delay before mm sees the record.

local t    = require('support')
local util = require('util')

local classic58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }

return {

  {
    name = 'addEvent: caller ppq is logical; um derives raw under swing and stamps ppqL',
    run = function(harness)
      -- c58 maps mid-period (ppq=120, period=240) to raw 139.2 → 139.
      local h = harness.mk{
        config = {
          project = { swings = { ['c58'] = classic58 } },
        },
        data = { swing = { global = 'c58' } },
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
        },
        data = { swing = { global = 'c58' } },
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
        },
        data = { swing = { global = 'c58' } },
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
        },
        data = { swing = { global = 'c58' } },
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

  -- util.OPEN is authored on endppq, not endppqL. The caller never
  -- touches endppqL; tm stamps it and derives the realised tail.
  {
    name = 'addEvent: caller authors endppq=util.OPEN; tm derives the tail, caller sets no endppqL',
    run = function(harness)
      local h = harness.mk{ seed = { length = 1920, notes = {} } }
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = util.OPEN,
                      chan = 1, pitch = 60, vel = 100 })
      h.tm:flush()
      local ev = h.tm:getChannel(1).columns.notes[1].events[1]
      t.eq(ev.endppq,  util.OPEN, 'authored-open tail survives addEvent on endppq')
      t.eq(ev.endppqC, 1920,      'tm derives the realised tail to take length')
    end,
  },

  {
    name = 'addEvent: open tail renders clipped to the next same-pitch onset, intent stays OPEN',
    run = function(harness)
      local h = harness.mk{ seed = { length = 1920, notes = {} } }
      h.tm:addEvent({ evType = 'note', ppq = 0,   endppq = util.OPEN,
                      chan = 1, pitch = 60, vel = 100 })
      h.tm:addEvent({ evType = 'note', ppq = 480, endppq = 600,
                      chan = 1, pitch = 60, vel = 100 })
      h.tm:flush()
      local function at(p)
        for _, e in ipairs(h.tm:getChannel(1).columns.notes[1].events) do
          if e.ppq == p then return e end
        end
      end
      t.eq(at(0).endppq,  util.OPEN, 'authored intent stays OPEN')
      t.eq(at(0).endppqC, 480,       'render clips to the next same-pitch onset')
    end,
  },

  {
    name = 'assignEvent: endppq=util.OPEN reopens a finite note (caller sets no endppqL)',
    run = function(harness)
      local h = harness.mk{ seed = { length = 1920, notes = {
        { ppq = 0, endppq = 240, ppqL = 0, endppqL = 240,
          chan = 1, pitch = 60, vel = 100 },
      }}}
      local n = h.tm:getChannel(1).columns.notes[1].events[1]
      h.tm:assignEvent(n, { endppq = util.OPEN })
      h.tm:flush()
      local ev = h.tm:getChannel(1).columns.notes[1].events[1]
      t.eq(ev.endppq,  util.OPEN, 'finite note reopened via endppq=util.OPEN')
      t.eq(ev.endppqC, 1920,      'realised tail regrows to take length')
    end,
  },

  -- Dual to realiseNoteUpdate's raw-onset floor (ppq < 0 → 0): authored
  -- endppq that maps past take-end clips raw at takeLen the moment the
  -- update lands in mm. endppqL retains the authored intent; the
  -- divergence surfaces in the logical projection as endppq ~= endppqC.
  -- (Step 4.8 and flush also clamp, this just keeps the staged raw
  -- bounded immediately rather than waiting for the next rebuild.)
  {
    name = 'assignEvent: endppq past take-end is clamped to takeLen; endppqL keeps the authored intent',
    run = function(harness)
      local h = harness.mk{ seed = { length = 480, notes = {
        { ppq = 0, endppq = 120, ppqL = 0, endppqL = 120,
          chan = 1, pitch = 60, vel = 100 },
      }}}
      local n = h.tm:getChannel(1).columns.notes[1].events[1]
      h.tm:assignEvent(n, { endppq = 600 })  -- 120 past take-end
      h.tm:flush()

      local notes = h.fm:dump().notes
      t.eq(notes[1].endppq,  480, 'raw endppq clipped at take length')
      t.eq(notes[1].endppqL, 600, 'authored ceiling preserved past take-end')

      local ev = h.tm:getChannel(1).columns.notes[1].events[1]
      t.eq(ev.endppqC, 480, 'endppqC reflects the realised tail')
    end,
  },
}
