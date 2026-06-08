-- Exercises tm:rebuild against seeded mm state.

local t = require('support')

return {
  {
    name = 'empty take has 16 channels each with one empty lane',
    run = function(harness)
      local h = harness.mk()
      for chan = 1, 16 do
        local ch = h.tm:getChannel(chan)
        t.truthy(ch, 'channel exists')
        t.eq(#ch.columns.notes, 1, 'one note lane by default')
        t.eq(#ch.columns.notes[1].events, 0, 'lane is empty')
      end
    end,
  },

  {
    name = 'a single note surfaces as one lane-1 event',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } },
        },
      }
      local ch = h.tm:getChannel(1)
      t.eq(#ch.columns.notes, 1, 'one note column')
      local col = ch.columns.notes[1]
      -- tm strips `chan` and `lane` from column events — channel is
      -- implied by the column's position in the grid.
      t.eventsMatch(col.events, { { ppq = 0, endppq = 240, pitch = 60, vel = 100 } })
    end,
  },

  {
    name = 'tm seeds detune and delay metadata on rebuild',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } },
        },
      }
      local note = h.fm:dump().notes[1]
      t.eq(note.detune, 0, 'detune seeded to 0')
      t.eq(note.delay,  0, 'delay seeded to 0')
    end,
  },

  {
    name = 'existing detune/delay survive rebuild (defaults do not clobber)',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
              detune = 37, delay = -15 },
          },
        },
      }
      local note = h.fm:dump().notes[1]
      t.eq(note.detune, 37, 'existing detune preserved')
      t.eq(note.delay, -15, 'existing delay preserved')
    end,
  },

  {
    name = 'partial metadata: only the missing field is defaulted',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
              detune = 25 },  -- delay missing
          },
        },
      }
      local note = h.fm:dump().notes[1]
      t.eq(note.detune, 25, 'detune preserved')
      t.eq(note.delay, 0, 'missing delay defaulted to 0')
    end,
  },

  {
    name = 'a second rebuild after seeding is a no-op on metadata',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } },
        },
      }
      -- First rebuild (driven by seed) has already populated defaults. A
      -- manual second rebuild must leave them stable.
      h.tm:rebuild()
      local note = h.fm:dump().notes[1]
      t.eq(note.detune, 0)
      t.eq(note.delay, 0)
    end,
  },

  {
    name = 'rebuild from a seeded detuned note + matching fake pb keeps pb hidden',
    run = function(harness)
      -- Cents-to-raw under default pbRange=2 semitones: 50¢ → raw 2048.
      local rawFor50 = 2048
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
              detune = 50, delay = 0 },
          },
          ccs = {
            { ppq = 0, chan = 1, evType = 'pb', val = rawFor50, fake = true },
          },
        },
      }
      -- pb column hidden because the only pb is the absorber.
      local ch = h.tm:getChannel(1)
      t.falsy(ch.columns.pb, 'pb column hidden for fake-only pb')
      -- Note still visible in col-1 with its detune intact.
      t.eq(ch.columns.notes[1].events[1].detune, 50)
    end,
  },

  {
    name = 'fake pb sits at host logical (Phase 6 col-event projection)',
    run = function(harness)
      -- Host note: intent ppq=0, delay=500 → 120 ppq nudge at res=240,
      -- so mm stores both the note and its absorber at ppq=120. The
      -- column event projects to the logical frame: host surfaces at
      -- ppqL=0 and the absorber follows, stamped with host's ppqL by
      -- step 4.8.
      local rawFor50 = 2048
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 120, endppq = 360, chan = 1, pitch = 60, vel = 100,
              detune = 50, delay = 500, ppqL = 0, endppqL = 240 },
          },
          ccs = {
            { ppq = 120, chan = 1, evType = 'pb', val = rawFor50, fake = true },
            -- A visible pb later on so the pb column surfaces at all.
            { ppq = 480, chan = 1, evType = 'pb', val = 0 },
          },
        },
      }
      local ch = h.tm:getChannel(1)
      t.eq(ch.columns.notes[1].events[1].ppq, 0,
        'note surfaces at logical ppq=0')

      t.truthy(ch.columns.pb, 'pb column surfaces (visible pb present)')
      local fakeDisp
      for _, e in ipairs(ch.columns.pb.events) do
        if e.hidden then fakeDisp = e end
      end
      t.truthy(fakeDisp, 'fake pb display event present in column')
      t.eq(fakeDisp.ppq,   0,   'absorber tracks host logical')
      t.eq(fakeDisp.delay, nil, 'no delay field on absorber column event')
    end,
  },

  {
    name = 'overlapping notes on the same pitch/channel are truncated',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0,   endppq = 480, chan = 1, pitch = 60, vel = 100 },
            { ppq = 240, endppq = 480, chan = 1, pitch = 60, vel = 100 },
          },
        },
      }
      local notes = h.fm:dump().notes
      -- First note should now end at 240 (start of the second).
      local first = notes[1].ppq < notes[2].ppq and notes[1] or notes[2]
      t.eq(first.endppq, 240, 'first note truncated at successor start')
    end,
  },

  {
    name = 'distinct pitches on same ppq share a channel in separate lanes',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 },
            { ppq = 0, endppq = 240, chan = 1, pitch = 64, vel = 100 },
          },
        },
      }
      local ch = h.tm:getChannel(1)
      t.eq(#ch.columns.notes, 2, 'two lanes allocated for coincident notes')
    end,
  },

  {
    name = 'a pb event populates the pb column with logical cents',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = { { ppq = 0, chan = 1, evType = 'pb', val = 4096 } },
        },
      }
      local ch = h.tm:getChannel(1)
      t.truthy(ch.columns.pb, 'pb column exists')
      -- Default pbRange = 2 semitones = 200 cents. val 4096 / 8192 * 200 = 100.
      t.eventsMatch(ch.columns.pb.events, { { ppq = 0, val = 100 } })
    end,
  },

  {
    -- Column allocation lives in intent space: delay is realisation-only
    -- and must not influence which lane a note lands in. Two notes with
    -- the same intent onset must spill regardless of their delays.
    name = 'same intent onset with different delays still spills to a new lane',
    run = function(harness)
      -- At resolution 240, delay=500 → +120 PPQ realised shift.
      -- Both notes share intent ppq=240; B's realised onset is 360.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 240, endppq = 360, chan = 1, pitch = 60, vel = 100, delay = 0   },
            { ppq = 360, endppq = 360, chan = 1, pitch = 64, vel = 100, delay = 500 },
          },
        },
      }
      local ch = h.tm:getChannel(1)
      t.eq(#ch.columns.notes, 2,
        'shared intent onset spills to a second lane even when delays differ')
    end,
  },

  {
    -- Converse: notes whose REALISED onsets coincide (purely because of
    -- delay) but whose intents are disjoint should share a lane. Without
    -- the intent-space rule the same-tick reject would force a spill.
    name = 'realised collision via delay does not force a spill if intents are disjoint',
    run = function(harness)
      -- A: intent [0, 120), realised onset 0.
      -- B: intent [240, 480), realised onset 0 (delay = -1000 → -240 PPQ at res 240).
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 120, chan = 1, pitch = 60, vel = 100, delay = 0     },
            { ppq = 0, endppq = 480, chan = 1, pitch = 64, vel = 100, delay = -1000 },
          },
        },
      }
      local ch = h.tm:getChannel(1)
      t.eq(#ch.columns.notes, 1,
        'intent-disjoint notes share a lane despite realised collision')
      t.eq(#ch.columns.notes[1].events, 2, 'both notes live in lane 1')
    end,
  },

  {
    -- Pins forward-compat for the cc/pb/pa projection. Routing fields
    -- (chan, evType, cc) belong to the destination col and are stripped;
    -- everything else on the source mm-level event — including future
    -- metadata fields not known here — must ride through to col.events.
    -- The previous implementation used per-evType allowlists that
    -- silently dropped any unknown field.
    name = 'arbitrary metadata on cc/pb/pa survives the projection',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 480, chan = 1, pitch = 60, vel = 100,
              detune = 0, delay = 0 },
          },
          ccs = {
            { ppq = 100, chan = 1, evType = 'cc', cc = 74, val = 64,
              mood = 'blue', tag = 42 },
            { ppq = 200, chan = 1, evType = 'pb', val = 0,
              mood = 'green', tag = 7 },
            { ppq = 300, chan = 1, evType = 'pa', pitch = 60, vel = 90,
              mood = 'red',  tag = 99 },
          },
        },
      }
      local ch = h.tm:getChannel(1)

      local ccEvt = ch.columns.ccs[74].events[1]
      t.eq(ccEvt.mood, 'blue', 'cc custom field rides through projection')
      t.eq(ccEvt.tag,  42,     'cc tag rides through projection')

      t.truthy(ch.columns.pb, 'pb column surfaces')
      local pbEvt = ch.columns.pb.events[1]
      t.eq(pbEvt.mood, 'green', 'pb custom field rides through projection')
      t.eq(pbEvt.tag,  7,       'pb tag rides through projection')

      -- pa is attached to the host note's column, alongside the note.
      local paEvt
      for _, e in ipairs(ch.columns.notes[1].events) do
        if e.type == 'pa' then paEvt = e end
      end
      t.truthy(paEvt, 'pa event projected onto host-pitch note col')
      t.eq(paEvt.mood, 'red', 'pa custom field rides through projection')
      t.eq(paEvt.tag,  99,    'pa tag rides through projection')
    end,
  },

  {
    name = 'tm:addEvent + flush round-trips through mm',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0, lane = 1 })
      h.tm:flush()

      local dump = h.fm:dump()
      t.eq(#dump.notes, 1, 'one note persisted to mm')
      t.eventsMatch(dump.notes, { { ppq = 0, endppq = 240, pitch = 60, vel = 100 } })

      local ch = h.tm:getChannel(1)
      t.eq(#ch.columns.notes[1].events, 1, 'tm sees the new note on rebuild')
    end,
  },

  {
    name = 'delete-then-add in a single flush leaves one note at new ppq',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } },
        },
      }
      local before = h.tm:getChannel(1).columns.notes[1].events[1]
      h.tm:deleteEvent(before)
      h.tm:addEvent({ evType = 'note', ppq = 480, endppq = 720, chan = 1, pitch = 62, vel = 90, detune = 0, delay = 0, lane = 1 })
      h.tm:flush()

      local dump = h.fm:dump()
      t.eq(#dump.notes, 1, 'one note after flush')
      t.eventsMatch(dump.notes, { { ppq = 480, endppq = 720, pitch = 62, vel = 90 } })
    end,
  },

  {
    -- Regression: opening a tail (endppq → util.OPEN) must keep attached PAs.
    -- stampEndppq's provisional ppq+1 must not flow into resizeNote as cullEnd.
    name = 'dormant tracker (dead take) ignores a foreign configChanged instead of rebuilding',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
                       delay = 0, ppqL = 0, endppqL = 240 } },
        },
      }
      t.eq(#h.tm:getChannel(1).columns.notes[1].events, 1, 'note present before take death')

      -- Take deleted under us: mm self-heals take() to nil but keeps stale
      -- notes (the dangling-take seam). resolution() now reads nil.
      h.fm:unload()
      t.falsy(h.tm:currentTake(), 'take is dead')

      -- Arrange writes a foreign-track config key on take-delete, firing
      -- configChanged through tm's real subscriber. Must not rebuild.
      h.cm:writeTrackKey('take1/track', 'arrangeSlots', {})

      t.eq(#h.tm:getChannel(1).columns.notes[1].events, 1,
        'last frame retained, no crash on dead-take rebuild')
    end,
  },

  {
    name = 'opening a note tail (util.OPEN) keeps its attached PAs',
    run = function(harness)
      local util = require('util')
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 480, chan = 1, pitch = 60, vel = 100 } },
          ccs = {
            { ppq = 100, chan = 1, evType = 'pa', pitch = 60, vel = 90 },
            { ppq = 200, chan = 1, evType = 'pa', pitch = 60, vel = 80 },
            { ppq = 300, chan = 1, evType = 'pa', pitch = 60, vel = 70 },
          },
        },
      }
      local note = h.tm:getChannel(1).columns.notes[1].events[1]
      h.tm:assignEvent(note, { endppq = util.OPEN })
      h.tm:flush()

      local pas = 0
      for _, cc in ipairs(h.fm:dump().ccs) do
        if cc.evType == 'pa' then pas = pas + 1 end
      end
      t.eq(pas, 3, 'all three PAs survive the open-tail edit')
    end,
  },
}
