-- Shift-held chord entry: strikes pin the cursor row and stack lanes; a
-- re-struck pitch toggles off (freed lanes reused); tv:chordVelocity sets the
-- last strike's velocity; commit advances once. Drives the real tv:chord*
-- API — gridPane's key drain is a thin router over it.

local t      = require('support')
local tuning = require('tuning')

local function mk(harness, seedNotes)
  local h = harness.mk{
    seed   = { notes = seedNotes or {} },
    config = { take = { currentOctave = 4 } },
  }
  h.vm:setGridSize(80, 40)
  return h
end

-- Lane-indexed onset lookup straight from tm (columns.notes[lane]).
local function laneNoteAt(h, lane, ppq)
  local laneCol = h.tm:getChannel(1).columns.notes[lane]
  for _, evt in ipairs(laneCol and laneCol.events or {}) do
    if evt.ppq == ppq then return evt end
  end
end

local function strike(h, ch) return h.vm:chordStrike(string.byte(ch)) end

-- Count StuffMIDIMessage note-offs (0x80|chan) in the fake reaper's call log.
local function noteOffs(h)
  local n = 0
  for _, c in ipairs(h.reaper._state.calls) do
    if c.fn == 'StuffMIDIMessage' and (c.b1 & 0xF0) == 0x80 then n = n + 1 end
  end
  return n
end

return {
  {
    name = 'strikes stack lanes at the pinned row; commit advances once',
    run = function(harness)
      local h = mk(harness)
      h.ec:setPos(2, 1, 1)   -- row 2 = ppq 120, chan-1 lane-1 pitch stop

      t.truthy(strike(h, 'z'), 'first strike consumed (arms the gesture)')
      t.truthy(strike(h, 'c'), 'second strike consumed')
      t.truthy(strike(h, 'b'), 'third strike consumed')

      t.eq(h.ec:row(), 2, 'cursor pinned while the gesture is live')
      t.eq(laneNoteAt(h, 1, 120).pitch, 60, 'C in lane 1')
      t.eq(laneNoteAt(h, 2, 120).pitch, 64, 'E in lane 2 (sprouted)')
      t.eq(laneNoteAt(h, 3, 120).pitch, 67, 'G in lane 3 (sprouted)')

      h.vm:chordCommit()
      t.falsy(h.vm:chordActive(), 'gesture cleared on commit')
      t.eq(h.ec:row(), 3, 'commit advanced one step')
    end,
  },

  {
    name = 'a re-struck pitch toggles off and frees its lane for reuse',
    run = function(harness)
      local h = mk(harness)
      h.ec:setPos(2, 1, 1)
      strike(h, 'z'); strike(h, 'c')

      t.truthy(strike(h, 'c'), 'toggle strike consumed')
      t.falsy(laneNoteAt(h, 2, 120), 'E toggled off')
      t.truthy(laneNoteAt(h, 1, 120), 'C untouched')

      strike(h, 'b')
      t.eq(laneNoteAt(h, 2, 120).pitch, 67, 'G reused the freed lane 2')
      h.vm:chordCommit()
    end,
  },

  {
    name = 'a pre-existing note of the struck pitch is adopted, not duplicated',
    run = function(harness)
      local h = mk(harness, {
        { ppq = 120, endppq = 240, chan = 1, pitch = 64, vel = 80, detune = 0, delay = 0 },
      })
      h.ec:setPos(2, 1, 1)

      t.truthy(strike(h, 'c'), 'strike on the existing E consumed')
      t.eq(#h.fm:dump().notes, 1, 'no duplicate onset placed')
      t.eq(laneNoteAt(h, 1, 120).vel, 80, 'adopted note keeps its velocity')

      strike(h, 'z')
      t.eq(laneNoteAt(h, 2, 120).pitch, 60, 'next strike skips the adopted lane')

      t.truthy(strike(h, 'c'), 'second E press consumed')
      t.falsy(laneNoteAt(h, 1, 120), 'adopted note toggle-deleted')
      h.vm:chordCommit()
    end,
  },

  {
    name = 'first strike overwrites the occupant pitch and keeps its velocity',
    run = function(harness)
      local h = mk(harness, {
        { ppq = 120, endppq = 240, chan = 1, pitch = 62, vel = 90, detune = 0, delay = 0 },
      })
      h.ec:setPos(2, 1, 1)
      strike(h, 'z')

      local n = laneNoteAt(h, 1, 120)
      t.eq(n.pitch, 60, 'occupant pitch replaced')
      t.eq(n.vel,   90, 'occupant velocity kept')
      t.eq(#h.fm:dump().notes, 1, 'still one note')
      h.vm:chordCommit()
    end,
  },

  {
    name = 'velocity digits write the 16s column onto the last strike',
    run = function(harness)
      local h = mk(harness)
      h.ec:setPos(2, 1, 1)
      strike(h, 'z')

      h.vm:chordVelocity(4)
      t.eq(laneNoteAt(h, 1, 120).vel, 0x40, 'digit 4 → 0x40')
      h.vm:chordVelocity(8)
      t.eq(laneNoteAt(h, 1, 120).vel, 0x7f, 'digit 8 caps at 0x7f')
      h.vm:chordVelocity(0)
      t.eq(laneNoteAt(h, 1, 120).vel, 1, 'digit 0 floors at 01 (vel 0 unrepresentable)')
      h.vm:chordVelocity(9)
      t.eq(laneNoteAt(h, 1, 120).vel, 1, 'digit 9 ignored')

      strike(h, 'c')
      h.vm:chordVelocity(2)
      t.eq(laneNoteAt(h, 2, 120).vel, 0x20, 'velocity targets the newest strike')
      t.eq(laneNoteAt(h, 1, 120).vel, 1,    'earlier strike untouched')

      strike(h, 'c')   -- toggle E off
      h.vm:chordVelocity(3)
      t.eq(laneNoteAt(h, 1, 120).vel, 0x30, 'target falls back to the surviving note')
      h.vm:chordCommit()
    end,
  },

  {
    name = 'an emptied gesture commits without advancing',
    run = function(harness)
      local h = mk(harness)
      h.ec:setPos(2, 1, 1)
      strike(h, 'z')
      strike(h, 'z')   -- toggle the only note off

      t.eq(#h.fm:dump().notes, 0, 'no notes survive')
      h.vm:chordCommit()
      t.eq(h.ec:row(), 2, 'cursor stayed put')
      t.falsy(h.vm:chordActive())
    end,
  },

  {
    name = 'a take switch abandons the gesture without advancing',
    run = function(harness)
      local h = mk(harness)
      h.ec:setPos(2, 1, 1)
      strike(h, 'z')

      h.vm:rebuild(true)   -- takeChanged: the pinned (row, chan) means nothing now
      t.falsy(h.vm:chordActive(), 'gesture abandoned')
      t.eq(h.ec:row(), 0, 'ec reset, no advance on top')
    end,
  },

  {
    name = 'toggle matches on the temper-snapped pitch',
    run = function(harness)
      -- Fixture from vm_temper_entry_spec: a JI temper whose snapping moves
      -- the keyed 12EDO pitch, so a naive raw-pitch toggle match would miss.
      local JI = tuning.derive{
        name = 'JI', periodPitch = '9/4',
        pitches = { '4/4', '5/4', '6/4', '7/4', '8/4' },
        stepNames = {}, periodAsStep = true,
      }
      local h = harness.mk{
        seed   = { notes = {} },
        config = {
          take    = { currentOctave = 4 },
          project = { tempers = { JI = JI }, temper = 'JI' },
        },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(2, 1, 1)

      t.truthy(strike(h, 'z'), 'strike under the temper consumed')
      t.truthy(laneNoteAt(h, 1, 120), 'snapped note placed')
      t.truthy(strike(h, 'z'), 'second press consumed')
      t.falsy(laneNoteAt(h, 1, 120), 'second press toggled the snapped note off')
      t.eq(#h.fm:dump().notes, 0, 'gesture is empty')
      h.vm:chordCommit()
    end,
  },

  {
    name = 'a live gesture suspends the audition timeout; commit drops the voices',
    run = function(harness)
      local h = mk(harness)
      h.ec:setPos(2, 1, 1)
      strike(h, 'z')

      h.reaper:clearCalls()
      h.reaper:tick(2.0)   -- well past AUDITION_TIMEOUT (0.8s)
      h.vm:tick()
      t.eq(noteOffs(h), 0, 'shift held: the tick leaves the voices sounding')

      h.reaper:clearCalls()
      h.vm:chordCommit()
      t.truthy(noteOffs(h) > 0, 'shift release drops the gesture voices')
    end,
  },

  {
    name = 'shadowed shift commands decline while a gesture is live',
    run = function(harness)
      local h = mk(harness)
      h.ec:setPos(2, 1, 1)
      strike(h, 'z')

      t.eq(h.cmgr:invoke('inputSampleUp'), false,
           'inputSampleUp declines — Shift+. must reach the chord drain')
      h.vm:chordCommit()
    end,
  },
}
