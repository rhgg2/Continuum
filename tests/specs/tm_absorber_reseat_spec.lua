-- Phase 5 (two-frame timing): absorbers stop carrying their own delay
-- and reseat from the host's raw on every rebuild.
--
--   - mm-side: absorber.ppq is host's raw, set by reconcileBoundary on
--     edits and reseated post-rule when the rule moves the host.
--   - column-side: no delay field → tidyCol is a no-op for absorbers.
--     They surface at host raw, while the host note surfaces at host
--     intent. Hidden absorbers don't render, so the divergence is
--     invisible to consumers (Phase 6 collapses it entirely).

local t = require('support')

local classic58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }

local rawFor50 = 2048  -- under default pbRange=2 semitones, 50¢ → raw 2048.

local function fakeIn(dump)
  for _, c in ipairs(dump.ccs) do
    if c.evType == 'pb' and c.fake then return c end
  end
end

return {

  {
    name = 'delayed lane-1 host with detune jump → absorber tracks host logical (Phase 6)',
    run = function(harness)
      -- Host: ppqL=0, delay=500 mQN at res=240 → 120 ppq nudge → raw=120.
      -- Seeded absorber co-located at raw=120 in mm; col-event projects
      -- to the host's logical (0) under Phase 6.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 120, endppq = 360, chan = 1, pitch = 60, vel = 100,
              detune = 50, delay = 500, ppqL = 0, endppqL = 240 },
          },
          ccs = {
            { ppq = 120, chan = 1, evType = 'pb', val = rawFor50, fake = true },
            { ppq = 480, chan = 1, evType = 'pb', val = 0 },  -- visible, surfaces column
          },
        },
      }
      local fk = fakeIn(h.fm:dump())
      t.eq(fk.ppq, 120, 'mm absorber stays at host raw')
      t.eq(fk.ppqL, 0,  'mm absorber stamped with host ppqL by step 4.8')

      local ch = h.tm:getChannel(1)
      local fakeDisp
      for _, e in ipairs(ch.columns.pb.events) do
        if e.hidden then fakeDisp = e end
      end
      t.truthy(fakeDisp, 'fake pb projected into pb column as hidden display event')
      t.eq(fakeDisp.ppq, 0,    'column projection at host logical')
      t.eq(fakeDisp.delay, nil, 'no delay field on absorber column event')
    end,
  },

  {
    name = 'swing change reseats absorber alongside its host',
    run = function(harness)
      -- Steady state under c58: host ppqL=120, raw=139 (mid-period bow).
      -- Absorber co-located at raw=139, marked fake.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 139, endppq = 240, chan = 1, pitch = 60, vel = 100,
              detune = 50, delay = 0, ppqL = 120, endppqL = 240 },
          },
          ccs = {
            { ppq = 139, chan = 1, evType = 'pb', val = rawFor50, fake = true },
            { ppq = 480, chan = 1, evType = 'pb', val = 0 },
          },
        },
        config = {
          project = { swings = { ['c58'] = classic58 } },
          take    = { swing = 'c58' },
        },
      }
      -- Sanity: the rule left both at 139 under c58.
      t.eq(fakeIn(h.fm:dump()).ppq, 139, 'absorber starts at host raw under c58')

      -- Drop swing to identity. cm.swing change fires configChanged on
      -- the 'swing' key, which marks all channels stale and triggers the
      -- rebuild — the rule reseats raw from ppqL under the new (identity)
      -- snapshot.
      h.cm:remove('take', 'swing')

      local dump = h.fm:dump()
      local note = dump.notes[1]
      t.eq(note.ppq,  120, 'host raw reseated from ppqL under identity swing')
      t.eq(note.ppqL, 120, 'host ppqL preserved')

      local fk = fakeIn(dump)
      t.eq(fk.ppq, 120, 'absorber reseated to host new raw — moves together')
    end,
  },

  {
    name = 'delay change on host moves absorber to new raw',
    run = function(harness)
      -- Host at ppq=0, ppqL=0, delay=0, detune=50 → absorber seated by
      -- addNote at ppq=0. Now bump delay; realiseNoteUpdate forwards raw
      -- to 60 (delayToPPQ(250) at res=240); resizeNote drops/recreates
      -- the absorber at the new seat.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
              detune = 50, delay = 0, ppqL = 0, endppqL = 240 },
          },
          ccs = {
            { ppq = 0, chan = 1, evType = 'pb', val = rawFor50, fake = true },
          },
        },
      }
      local n = h.tm:getChannel(1).columns.notes[1].events[1]
      h.tm:assignEvent('note', n, { delay = 250 })
      h.tm:flush()

      local dump = h.fm:dump()
      t.eq(dump.notes[1].ppq, 60,  'host raw shifted by delay (60 ppq nudge)')
      t.eq(fakeIn(dump).ppq,  60,  'absorber follows host to new raw')
    end,
  },

  {
    name = 'removing the detune jump drops the absorber (I2 second clause)',
    run = function(harness)
      -- Two lane-1 notes; detune jumps at the second's onset, absorber there.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0,   endppq = 240, chan = 1, pitch = 60, vel = 100,
              detune = 0,  delay = 0, ppqL = 0,   endppqL = 240 },
            { ppq = 240, endppq = 480, chan = 1, pitch = 62, vel = 100,
              detune = 50, delay = 0, ppqL = 240, endppqL = 480 },
          },
          ccs = {
            { ppq = 240, chan = 1, evType = 'pb', val = rawFor50, fake = true },
          },
        },
      }
      t.truthy(fakeIn(h.fm:dump()), 'absorber present at the jump')

      -- Flatten the jump: set the second note's detune to 0.
      local second
      for _, n in ipairs(h.tm:getChannel(1).columns.notes[1].events) do
        if n.pitch == 62 then second = n end
      end
      h.tm:assignEvent('note', second, { detune = 0 })
      h.tm:flush()

      t.falsy(fakeIn(h.fm:dump()), 'absorber dropped — no jump remains')
    end,
  },
}
