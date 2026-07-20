-- Pins commit 2b: tm synthesises PCs from per-note `sample` under
-- trackerMode. Realised-time grouping; leftmost lane wins; losers
-- carry `sampleShadowed=true` for renderer dimming. Mutation hooks
-- keep the synthesised stream in lockstep with note edits.

local t = require('support')

local function pcsOnChan(dump, chan)
  local out = {}
  for _, c in ipairs(dump.ccs) do
    if c.evType == 'pc' and c.chan == chan then
      out[#out + 1] = { ppq = c.ppq, val = c.val }
    end
  end
  table.sort(out, function(a, b) return a.ppq < b.ppq end)
  return out
end

-- Locate a note by (chan, pitch) and return its mm handle. mm:notes still
-- yields (loc, evt); we ignore the loc and take the event's uuid.
local function uuidOfNote(mm, chan, pitch)
  for _, n in mm:notes() do
    if n.chan == chan and n.pitch == pitch then return n.uuid end
  end
end

local function laneEvent(tm, chan, lane, i)
  return tm:getChannel(chan).columns.notes[lane].events[i]
end

return {

  ----- Basic synthesis from per-note sample fields

  {
    name = 'three lane-1 notes synthesise three PCs at their realised onsets',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0,   endppq = 240, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0, sample = 1 },
            { ppq = 240, endppq = 480, chan = 1, pitch = 62, vel = 100, detune = 0, delay = 0, sample = 2 },
            { ppq = 480, endppq = 720, chan = 1, pitch = 64, vel = 100, detune = 0, delay = 0, sample = 1 },
          },
        },
        config = { transient = { trackerMode = true } },
      }
      t.deepEq(pcsOnChan(h.fm:dump(), 1),
        { { ppq = 0, val = 1 }, { ppq = 240, val = 2 }, { ppq = 480, val = 1 } })
    end,
  },

  {
    name = 'PC lands at realised ppq, not intent (delay shifts the PC too)',
    run = function(harness)
      -- Add through tm so um shifts ppq into realised — delayToPPQ(500, 240) = 120,
      -- so the realised onset is 100 + 120 = 220, and the PC must land there.
      local h = harness.mk{
        seed = { notes = {} },
        config = { transient = { trackerMode = true } },
      }
      h.tm:addEvent({ evType = 'note',
        ppq = 100, endppq = 300, chan = 1, pitch = 60, vel = 100,
        detune = 0, delay = 500, sample = 7, lane = 1,
      })
      h.tm:flush()
      t.deepEq(pcsOnChan(h.fm:dump(), 1), { { ppq = 220, val = 7 } })
    end,
  },

  ----- Mutation hooks

  {
    name = 'changing sample on a note resyncs its PC val',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0,   endppq = 240, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0, sample = 1 },
            { ppq = 240, endppq = 480, chan = 1, pitch = 62, vel = 100, detune = 0, delay = 0, sample = 2 },
          },
        },
        config = { transient = { trackerMode = true } },
      }
      local tok = uuidOfNote(h.fm, 1, 62)
      h.tm:assignEvent({ uuid = tok }, { sample = 9 })
      h.tm:flush()
      t.deepEq(pcsOnChan(h.fm:dump(), 1),
        { { ppq = 0, val = 1 }, { ppq = 240, val = 9 } })
    end,
  },

  {
    name = 'deleting the only note at a realised ppq drops its PC',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0,   endppq = 240, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0, sample = 1 },
            { ppq = 240, endppq = 480, chan = 1, pitch = 62, vel = 100, detune = 0, delay = 0, sample = 2 },
          },
        },
        config = { transient = { trackerMode = true } },
      }
      local tok = uuidOfNote(h.fm, 1, 62)
      h.tm:deleteEvent(tok)
      h.tm:flush()
      t.deepEq(pcsOnChan(h.fm:dump(), 1), { { ppq = 0, val = 1 } })
    end,
  },

  -- Regression for a stale-loc bug: rebuild's PC synthesis captures the
  -- mm:addCC return value, which is the pre-sort index inside mm:modify;
  -- post-modify, mm reindexes by (ppq, chan, ...). With PCs spanning
  -- chans whose insertion order differs from sort order, captured locs
  -- become stale, and the next flush-time reconcile deletes the wrong
  -- PC. Pin: editing chan-1 sample must NOT clobber chan-2's PC.
  {
    name = 'cross-channel: editing one chan does not clobber another chan\'s PC',
    run = function(harness)
      -- Insertion order during synthesis: chan 1 first (ppq 240), then
      -- chan 2 (ppq 0). Sort order: ppq 0 chan 2, ppq 240 chan 1.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 240, endppq = 480, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0, sample = 1 },
            { ppq = 0,   endppq = 240, chan = 2, pitch = 60, vel = 100, detune = 0, delay = 0, sample = 5 },
          },
        },
        config = { transient = { trackerMode = true } },
      }
      local tok = uuidOfNote(h.fm, 1, 60)
      h.tm:assignEvent({ uuid = tok }, { sample = 9 })
      h.tm:flush()
      t.deepEq(pcsOnChan(h.fm:dump(), 1), { { ppq = 240, val = 9 } })
      t.deepEq(pcsOnChan(h.fm:dump(), 2), { { ppq = 0,   val = 5 } })
    end,
  },

  ----- Off-mode behaviour

  {
    name = 'trackerMode off: user-authored PCs are not touched',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 } },
          ccs   = { { ppq = 100, evType = 'pc', chan = 1, val = 42 } },
        },
      }
      t.deepEq(pcsOnChan(h.fm:dump(), 1), { { ppq = 100, val = 42 } })
    end,
  },

  ----- The bearing rule: bare notes stamp from the prevailing PC, then freeze

  -- Every note bears a sample under trackerMode: a bare note (external or
  -- pre-trackerMode) is stamped from the PC prevailing at its onset at first
  -- rebuild. Inheritance freezes at stamp time — later PC/sample edits
  -- upstream do not re-colour it. see design/interval-dirt-closing.md § 2
  {
    name = 'external note enters trackerMode stamped from the prevailing PC',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 240, endppq = 480, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 } },
          ccs   = { { ppq = 0,   evType = 'pc', chan = 1, val = 11 } },
        },
        config = { transient = { trackerMode = true } },
      }
      local n = h.fm:dump().notes[1]
      t.eq(n.sample, 11, 'bare note stamped with the prevailing PC value')
      local pcs = pcsOnChan(h.fm:dump(), 1)
      local atNoteOnset
      for _, p in ipairs(pcs) do if p.ppq == 240 then atNoteOnset = p end end
      t.eq(atNoteOnset and atNoteOnset.val, 11, 'synthesised PC at note onset reads the stamped sample')
    end,
  },

  {
    name = 'inheritance freezes at stamp time: editing one sample recolours only itself',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0,   endppq = 240, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 },
            { ppq = 480, endppq = 720, chan = 1, pitch = 62, vel = 100, detune = 0, delay = 0 },
          },
          ccs   = { { ppq = 0, evType = 'pc', chan = 1, val = 7 } },
        },
        config = { transient = { trackerMode = true } },
      }
      -- Both notes stamped 7 at first rebuild; recolouring the first must not touch the second.
      h.tm:assignEvent({ uuid = uuidOfNote(h.fm, 1, 60) }, { sample = 3 })
      h.tm:flush()
      t.deepEq(pcsOnChan(h.fm:dump(), 1),
        { { ppq = 0, val = 3 }, { ppq = 480, val = 7 } })
    end,
  },

  ----- All-lanes participate (no lane gating)

  {
    name = 'lane-2 note alone (no simultaneous lane-1) emits its own PC',
    run = function(harness)
      -- Force lane 2 by overlapping same-ppq same-chan notes.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 480, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0, sample = 1 },
            { ppq = 0, endppq = 480, chan = 1, pitch = 64, vel = 100, detune = 0, delay = 0, sample = 5 },
          },
        },
        config = { transient = { trackerMode = true } },
      }
      -- Both notes share realised ppq 0 → leftmost (lane 1) wins.
      -- Move the lane-2 note off by 100 ppq so it has its own group.
      local lane2evt = laneEvent(h.tm, 1, 2, 1)
      h.tm:assignEvent({ uuid = lane2evt.uuid }, { ppq = 100, endppq = 580 })
      h.tm:flush()
      local pcs = pcsOnChan(h.fm:dump(), 1)
      -- Two distinct realised onsets: lane-1 at 0, lane-2 at 100.
      t.deepEq(pcs, { { ppq = 0, val = 1 }, { ppq = 100, val = 5 } })
    end,
  },

  {
    name = 'simultaneous lane-1 and lane-2: leftmost wins, loser is shadowed',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 480, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0, sample = 0xA },
            { ppq = 0, endppq = 480, chan = 1, pitch = 64, vel = 100, detune = 0, delay = 0, sample = 0xB },
          },
        },
        config = { transient = { trackerMode = true } },
      }
      t.deepEq(pcsOnChan(h.fm:dump(), 1), { { ppq = 0, val = 0xA } })
      local lane1 = laneEvent(h.tm, 1, 1, 1)
      local lane2 = laneEvent(h.tm, 1, 2, 1)
      t.falsy(lane1.sampleShadowed, 'lane-1 winner not shadowed')
      t.eq(lane2.sampleShadowed, true, 'lane-2 loser shadowed')
    end,
  },

  {
    name = 'splitting realised ppqs (delay) un-collides chord into two PCs',
    run = function(harness)
      -- Both notes have intent ppq 100 but lane-2 carries delay=-417.
      -- delayToPPQ(-417, 240) = round(240 * -417 / 1000) = -100, so
      -- realised lane-2 = 0, realised lane-1 = 100 — distinct groups.
      local h = harness.mk{
        seed = { notes = {} },
        config = { transient = { trackerMode = true } },
      }
      h.tm:addEvent({ evType = 'note', ppq = 100, endppq = 480, chan = 1, pitch = 60, vel = 100,
                              detune = 0, delay = 0,    sample = 0xA, lane = 1 })
      h.tm:addEvent({ evType = 'note', ppq = 100, endppq = 480, chan = 1, pitch = 64, vel = 100,
                              detune = 0, delay = -417, sample = 0xB, lane = 2 })
      h.tm:flush()
      local pcs = pcsOnChan(h.fm:dump(), 1)
      t.eq(#pcs, 2, 'two PCs at distinct realised ppqs')
      local lane1 = laneEvent(h.tm, 1, 1, 1)
      local lane2 = laneEvent(h.tm, 1, 2, 1)
      t.falsy(lane1.sampleShadowed, 'no shadow when realised ppqs differ')
      t.falsy(lane2.sampleShadowed, 'no shadow when realised ppqs differ')
    end,
  },

  {
    name = 'deleting the shadower un-shadows the survivor and PC val flips',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 480, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0, sample = 0xA },
            { ppq = 0, endppq = 480, chan = 1, pitch = 64, vel = 100, detune = 0, delay = 0, sample = 0xB },
          },
        },
        config = { transient = { trackerMode = true } },
      }
      local shadowerTok = uuidOfNote(h.fm, 1, 60)
      h.tm:deleteEvent(shadowerTok)
      h.tm:flush()
      t.deepEq(pcsOnChan(h.fm:dump(), 1), { { ppq = 0, val = 0xB } })
      -- After delete, the lane-2 survivor's lane assignment may rebalance.
      -- Walk all chan-1 lane events; the surviving pitch-64 note should
      -- have sampleShadowed cleared.
      local survivor
      for _, lane in ipairs(h.tm:getChannel(1).columns.notes) do
        for _, evt in ipairs(lane.events) do
          if evt.pitch == 64 then survivor = evt end
        end
      end
      t.truthy(survivor, 'survivor present')
      t.falsy(survivor.sampleShadowed, 'survivor no longer shadowed')
    end,
  },

  ----- PAs ride the note columns but carry no sample

  -- A PA has no `sample` and never will, so admitting it to PC grouping defaults it
  -- to program 0. The gather reads the raw scratch, which is notes-only.
  {
    name = 'a PA mid-note synthesises no PC of its own',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0, endppq = 480, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0, sample = 5 },
          },
          ccs = {
            { ppq = 240, chan = 1, evType = 'pa', pitch = 60, vel = 90 },
          },
        },
        config = { transient = { trackerMode = true } },
      }
      t.deepEq(pcsOnChan(h.fm:dump(), 1), { { ppq = 0, val = 5 } })
    end,
  },

  -- rebuildPA anchors a PA to its host's lane, so an admitted PA would win the lane
  -- sort against a higher-lane note sharing its ppq -- stealing that note's PC.
  {
    name = 'a lane-1 PA does not outrank a lane-2 note at the same ppq',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0,   endppq = 960, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0, sample = 5 },
            { ppq = 480, endppq = 960, chan = 1, pitch = 64, vel = 100, detune = 0, delay = 0, sample = 3 },
          },
          ccs = {
            { ppq = 480, chan = 1, evType = 'pa', pitch = 60, vel = 90 },
          },
        },
        config = { transient = { trackerMode = true } },
      }
      t.deepEq(pcsOnChan(h.fm:dump(), 1), { { ppq = 0, val = 5 }, { ppq = 480, val = 3 } })
      local stolen
      for _, lane in ipairs(h.tm:getChannel(1).columns.notes) do
        for _, evt in ipairs(lane.events) do
          if evt.pitch == 64 and evt.evType ~= 'pa' then stolen = evt end
        end
      end
      t.truthy(stolen, 'lane-2 note present')
      t.falsy(stolen.sampleShadowed, 'a PA must not shadow a real note')
    end,
  },
}
