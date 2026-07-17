-- Phase 3 pin (design/same-pitch-enforcement.md item 3) -- load-dedup runs
-- sidecar binding first so voicing verdicts nudge distinct voices apart.

local t = require('support')

local realMM = require('realMidiManager')()

local function freshTake()
  local fakeReaper = require('fakeReaper').new()
  _G.reaper = fakeReaper
  local take = 'take-load-dedup'
  fakeReaper:bindTake(take, take .. '/item', take .. '/track')
  return take, fakeReaper
end

-- Notation sidecar for a note; uuids stay in 0-9 so %d doubles as base36.
local function notation(ppq, chan, pitch, uuid)
  return { ppq = ppq, eventtype = 15,
           msg = ('NOTE %d %d custom ctm_%d'):format(chan - 1, pitch, uuid) }
end

local function loadWithCapture(take)
  local captured, order = {}, {}
  local mm = realMM(nil)
  mm:subscribe('notesDeduped',       function(d) captured.deduped = d.events end)
  mm:subscribe('collisionsResolved', function(d)
    captured.collisions = d.events
    order[#order + 1] = 'collisions'
  end)
  mm:subscribe('reload', function() order[#order + 1] = 'reload' end)
  mm:load(take)
  return mm, captured, order
end

local function notesOut(mm)
  local out = {}
  for _, n in mm:notes() do out[#out + 1] = n end
  return out
end

return {
  {
    name = 'raw-colliding notes with distinct detune load as two nudged voices',
    run = function()
      local take, reaper = freshTake()
      reaper:seedMidi(take, {
        notes = { { ppq = 0, endppq = 480, chan = 0, pitch = 60, vel = 100 },
                  { ppq = 0, endppq = 480, chan = 0, pitch = 60, vel = 90 } },
        texts = { notation(0, 1, 60, 1), notation(0, 1, 60, 2) },
      })
      t.seedMeta(take, 1, { ppqL = 0, detune = -50 })
      t.seedMeta(take, 2, { ppqL = 0, detune = 50 })

      local mm, captured, order = loadWithCapture(take)

      local notes = notesOut(mm)
      t.eq(#notes, 2, 'both voices survive')
      t.deepEq({ notes[1].ppq, notes[2].ppq }, { 0, 1 }, 'onsets separated')
      local detunes = {}
      for _, n in ipairs(notes) do detunes[n.detune] = true end
      t.truthy(detunes[-50] and detunes[50], 'both intents survive')
      t.eq(captured.deduped, nil, 'nothing eaten')
      t.eq(#captured.collisions, 1)
      t.eq(captured.collisions[1].kind, 'nudged')
      t.truthy(mm:byUuid(captured.collisions[1].uuid), 'the nudged voice resolves by uuid')
      t.deepEq(order, { 'collisions', 'reload' }, 'collisionsResolved fires before reload')
    end,
  },

  {
    name = 'foreign MIDI (no sidecars) still collapses to the longer note',
    run = function()
      local take, reaper = freshTake()
      reaper:seedMidi(take, {
        notes = { { ppq = 0, endppq = 240, chan = 0, pitch = 60, vel = 100 },
                  { ppq = 0, endppq = 480, chan = 0, pitch = 60, vel = 90 } },
        texts = {},
      })

      local mm, captured = loadWithCapture(take)

      local notes = notesOut(mm)
      t.eq(#notes, 1, 'duplicate collapses')
      t.eq(notes[1].endppq, 480, 'longer survives')
      t.eq(captured.collisions, nil, 'no nudge for true duplicates')
      t.deepEq(captured.deduped, { { ppq = 0, chan = 1, pitch = 60, droppedCount = 1 } })
    end,
  },

  {
    name = "killed duplicate's metadata is dropped from eventMeta",
    run = function()
      local take, reaper = freshTake()
      reaper:seedMidi(take, {
        notes = { { ppq = 0, endppq = 480, chan = 0, pitch = 60, vel = 100 },
                  { ppq = 0, endppq = 240, chan = 0, pitch = 60, vel = 100 } },
        texts = { notation(0, 1, 60, 1), notation(0, 1, 60, 2) },
      })
      t.seedMeta(take, 1, { ppqL = 0, detune = 25 })
      t.seedMeta(take, 2, { ppqL = 0, detune = 25 })

      local mm, captured = loadWithCapture(take)

      local notes = notesOut(mm)
      t.eq(#notes, 1, 'true duplicates collapse')
      t.eq(notes[1].endppq, 480, 'longer survives')
      t.eq(notes[1].detune, 25, 'intent survives on the winner')
      t.eq(#captured.deduped, 1, 'kill reports as notesDeduped')
      local meta = t.loadMeta(take)
      t.truthy(meta[notes[1].uuid] and meta[notes[1].uuid].detune == 25,
               "survivor's metadata persists")
      local killedUuid = notes[1].uuid == 1 and 2 or 1
      t.eq(meta[killedUuid], nil, "killed duplicate's metadata swept")
    end,
  },
}
