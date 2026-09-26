-- Pins commit 2b: tm synthesises PCs from per-note `sample` under
-- trackerMode. Realised-time grouping; leftmost lane wins; losers
-- carry `sampleShadowed=true` for renderer dimming. Mutation hooks
-- keep the synthesised stream in lockstep with note edits.

local t          = require('support')
local generators = require('generators')

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
  return tm:getChannel(chan).onTake.notes[lane].events[i]
end

-- The PCs on a channel below `ppq` -- the span the kept host owns in the case at the foot of this file.
local function pcsBelow(h, chan, ppq)
  local out = {}
  for _, p in ipairs(pcsOnChan(h.fm:dump(), chan)) do
    if p.ppq < ppq then out[#out + 1] = p end
  end
  return out
end

-- The chan's pcs in mm keyed by ppq, as { uuid, val, derived }.
local function pcsByPpq(h, chan)
  local out = {}
  for _, c in ipairs(h.fm:dump().ccs) do
    if c.evType == 'pc' and c.chan == chan then
      out[c.ppq] = { uuid = c.uuid, val = c.val, derived = c.derived }
    end
  end
  return out
end

-- The chan's pc column as { ppq, val }, or nil when the channel carries none.
local function pcColumn(h, chan)
  local col = h.tm:getChannel(chan).onTake.pc
  if not col then return nil end
  local out = {}
  for _, e in ipairs(col.events) do out[#out + 1] = { ppq = e.ppq, val = e.val } end
  return out
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
  -- upstream do not re-colour it. see design/archive/interval-dirt-closing.md § 2
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
    name = 'seed-dirty add: a bare mid-session note is reached and stamped',
    run = function(harness)
      -- A pre-stamped note establishes derivedInputs, so the initial rebuild is
      -- wholesale; the mid-session add then lands as a single seed and keeps the
      -- channel seed-dirty -- the branch stampSamples must still reach and stamp.
      -- The stamped value is 5, not the seed pc's authored 9: authored PCs do not
      -- survive synthesis, so what the at-or-before seek finds is the derived PC the
      -- seed note's own sample 5 produced. What this pins is reachability -- an
      -- unstamped seed note bears a sample rather than staying nil.
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0, sample = 5 } },
          ccs   = { { ppq = 240, evType = 'pc', chan = 1, val = 9 } },
        },
        config = { transient = { trackerMode = true } },
      }
      h.tm:addEvent({ evType = 'note',
        ppq = 480, endppq = 720, chan = 1, pitch = 62, vel = 100,
        detune = 0, delay = 0, lane = 1,
      })
      h.tm:flush()
      local added
      for _, n in ipairs(h.fm:dump().notes) do
        if n.pitch == 62 then added = n end
      end
      t.eq(added and added.sample, 5, 'bare seed-add note is reached by stampSamples and bears a sample')
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

  ----- Seed-scoped closure (interval dirt)

  {
    name = 'seed closure: moving a note relocates its PC and leaves neighbours alone',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0,   endppq = 240, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0, sample = 1 },
            { ppq = 240, endppq = 480, chan = 1, pitch = 62, vel = 100, detune = 0, delay = 0, sample = 2 },
            { ppq = 480, endppq = 720, chan = 1, pitch = 64, vel = 100, detune = 0, delay = 0, sample = 3 },
          },
        },
        config = { transient = { trackerMode = true } },
      }
      -- The move's snapshot (240) and live (720) positions fall in different closure spans:
      -- the old PC must go, the new one appear, and the untouched neighbour's PC stand.
      h.tm:assignEvent({ uuid = uuidOfNote(h.fm, 1, 62) }, { ppq = 720, endppq = 960 })
      h.tm:flush()
      t.deepEq(pcsOnChan(h.fm:dump(), 1),
        { { ppq = 0, val = 1 }, { ppq = 480, val = 3 }, { ppq = 720, val = 2 } })
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
    -- Leftmost lane wins, and the lane is the rank -- not the order the records happened to be
    -- gathered in. The two coincide whenever an onset's authored notes share a logical row, so this
    -- fixture pulls them apart: the lane-2 note is written a row earlier and the lane-1 note delayed
    -- back onto it, which gathers lane 2 first and leaves lane 1 the leftmost.
    name = 'leftmost lane wins an onset its two notes reached from different rows',
    run = function(harness)
      local h = harness.mk{ config = { transient = { trackerMode = true } } }
      -- delayToPPQ(-250, 240) = -60, so the logical-240 note realises at 180 beside the other.
      h.tm:addEvent({ evType = 'note', ppq = 240, endppq = 480, chan = 1, pitch = 60, vel = 100,
                      detune = 0, delay = -250, lane = 1, sample = 0xA })
      h.tm:addEvent({ evType = 'note', ppq = 180, endppq = 480, chan = 1, pitch = 64, vel = 100,
                      detune = 0, delay = 0, lane = 2, sample = 0xB })
      h.tm:flush()
      t.deepEq(pcsOnChan(h.fm:dump(), 1), { { ppq = 180, val = 0xA } },
        'the lane-1 sample programs the onset the two share')
      t.eq(laneEvent(h.tm, 1, 2, 1).sampleShadowed, true, 'and the lane-2 note is dimmed behind it')
    end,
  },

  {
    -- Lane ranks the authored records among themselves and says nothing about a derived one, which
    -- holds no lane at all: authored first, whatever column it was written in, then derived output in
    -- emission order. The authored note here is on lane 2 precisely so that a rank reading the lane
    -- number alone would put the derived hit first -- and it sits outside the region's span, with a
    -- delay carrying its realised onset back onto the hit's, so that the two share a group without
    -- the region's parking taking the authored half away.
    name = 'an authored note and a derived note at one onset: the authored sample wins',
    run = function(harness)
      local h = harness.mk{ config = { transient = { trackerMode = true } } }
      generators.kinds.oneHit = {
        expand = function()
          return { notes = { { ppq = 180, endppq = 240, pitch = 67, vel = 100, detune = 0 } }, delta = {} }
        end,
        mode = 'replace', dest = 'note', label = 'OneHit', defaults = {}, fields = {},
      }
      -- delayToPPQ(-250, 240) = -60, so the logical-240 note realises at 180, the hit's own onset.
      h.tm:addEvent({ evType = 'note', ppq = 240, endppq = 480, chan = 1, pitch = 60, vel = 100,
                      detune = 0, delay = -250, lane = 2, sample = 0xA })
      h.tm:flush()
      h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, ppq = 0, endppq = 240,
                                   fx = { { kind = 'oneHit' } } } })
      h.tm:rebuild()
      generators.kinds.oneHit = nil

      local derived = {}
      for _, n in ipairs(h.fm:dump().notes) do if n.derived then derived[#derived + 1] = n end end
      t.eq(#derived, 1, 'fixture check: the region emitted its one hit')
      t.eq(derived[1].ppq, 180, 'fixture check: onto the authored note\'s realised onset')

      t.deepEq(pcsOnChan(h.fm:dump(), 1), { { ppq = 180, val = 0xA } },
        'the authored sample is what the onset programs')
      t.falsy(laneEvent(h.tm, 1, 2, 1).sampleShadowed, 'the authored note won, so nothing dims it')
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
      for _, lane in ipairs(h.tm:getChannel(1).onTake.notes) do
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
      for _, lane in ipairs(h.tm:getChannel(1).onTake.notes) do
        for _, evt in ipairs(lane.events) do
          if evt.pitch == 64 and evt.evType ~= 'pa' then stolen = evt end
        end
      end
      t.truthy(stolen, 'lane-2 note present')
      t.falsy(stolen.sampleShadowed, 'a PA must not shadow a real note')
    end,
  },

  -- Keep by omission (docs/trackerManager.md § The host gate): a host the pass keeps re-emits nothing, so
  -- the PCs its derived notes own reach synthesis off um's index or not at all. A neighbour that runs
  -- puts derived output in the pass, which takes the channel's PC reconcile wholesale -- and a record
  -- set missing the kept host's notes then reads its PCs as unclaimed and deletes them.
  {
    name = 'a kept host\'s derived PCs stand while a neighbour re-runs the channel',
    run = function(harness)
      local h = harness.mk{ config = { transient = { trackerMode = true } } }
      -- Both hosts are retrigs: replace-mode, so both park, and every note below 480 is derived.
      h.tm:addEvent({ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
                      detune = 0, delay = 0, lane = 1, sample = 7,
                      fx = { { kind = 'retrig', period = { 1, 4 } } } })
      h.tm:addEvent({ evType = 'note', ppq = 480, endppq = 720, chan = 1, pitch = 67, vel = 100,
                      detune = 0, delay = 0, lane = 1, sample = 3,
                      fx = { { kind = 'retrig', period = { 1, 4 } } } })
      h.tm:flush()

      local before = pcsBelow(h, 1, 480)
      t.truthy(#before >= 2, 'fixture check: the first host\'s tiles own PCs of their own')
      for _, n in ipairs(h.fm:dump().notes) do
        if n.chan == 1 and n.ppq < 480 then
          t.truthy(n.derived, 'fixture check: no authored note sits under those onsets to hold them up')
        end
      end

      -- ppq 700 is inside the second host\'s window and outside the first\'s: the neighbour re-runs,
      -- the first host is kept, and its output takes the channel\'s PC pass wholesale.
      h.tm:addEvent({ evType = 'note', ppq = 700, endppq = 720, chan = 1, pitch = 72, vel = 100,
                      detune = 0, delay = 0, lane = 1 })
      h.tm:flush()

      t.deepEq(pcsBelow(h, 1, 480), before, 'the kept host\'s PCs stand: nothing of the pass names them')
    end,
  },

  ----- The pc column holds authored pcs alone

  -- Synthesised pcs are emission output and live in mm alone (docs/trackerManager.md § CC walk);
  -- the pc column is intent, so a take whose every pc is synthesised carries none. The load
  -- pass walks before synthesis mints anything, so it is the wholesale re-pass that meets them.
  {
    name = 'synthesised pcs sit in mm and not in the pc column',
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
      t.deepEq(pcsOnChan(h.fm:dump(), 1), { { ppq = 0, val = 1 }, { ppq = 240, val = 2 } },
        'fixture check: both notes synthesised their pcs')
      h.tm:rebuild(true)
      t.eq(pcColumn(h, 1), nil, 'no pc column: nothing authored sits in it')
    end,
  },

  -- Reconcile keys its previous emission in the raw frame the prediction carries: a pc whose note
  -- is delayed sits at a raw onset its logical row does not name, and a pass over its span keeps it.
  {
    name = 'a delayed note\'s pc survives a re-pass over its span with its uuid',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0,   endppq = 240, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0,   sample = 1 },
            { ppq = 250, endppq = 480, chan = 1, pitch = 62, vel = 100, detune = 0, delay = 100, sample = 2 },
          },
        },
        config = { transient = { trackerMode = true } },
      }
      local before = pcsByPpq(h, 1)[250]
      t.truthy(before, 'fixture check: the delayed note synthesised a pc at its raw onset')
      local note = h.tm:getChannel(1).onTake.notes[1].events[2]
      t.truthy(note.ppq ~= 250, 'fixture check: the note\'s logical row differs from its raw onset')

      h.tm:assignEvent({ uuid = uuidOfNote(h.fm, 1, 62) }, { vel = 90 })
      h.tm:flush()

      local after = pcsByPpq(h, 1)[250]
      t.eq(after and after.uuid, before.uuid, 'the pc stands: not deleted and re-minted')
    end,
  },

  {
    name = 'a sample edit reconciles its own span: neighbours keep their pcs',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0,   endppq = 240, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0, sample = 1 },
            { ppq = 240, endppq = 480, chan = 1, pitch = 62, vel = 100, detune = 0, delay = 0, sample = 2 },
            { ppq = 480, endppq = 720, chan = 1, pitch = 64, vel = 100, detune = 0, delay = 0, sample = 3 },
          },
        },
        config = { transient = { trackerMode = true } },
      }
      local before = pcsByPpq(h, 1)
      h.tm:assignEvent({ uuid = uuidOfNote(h.fm, 1, 62) }, { sample = 9 })
      h.tm:flush()
      local after = pcsByPpq(h, 1)
      t.eq(after[0].uuid,   before[0].uuid,   'the first pc stands')
      t.eq(after[480].uuid, before[480].uuid, 'the last pc stands')
      t.eq(after[240].val, 9, 'the middle pc takes the new sample')
    end,
  },

  {
    name = 'trackerMode off: an authored pc sits in the pc column at its row',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 } },
          ccs   = { { ppq = 100, evType = 'pc', chan = 1, val = 42 } },
        },
      }
      t.deepEq(pcColumn(h, 1), { { ppq = 100, val = 42 } })
    end,
  },

  -- Outside trackerMode emission synthesises no pcs, so the synthesised pcs of the previous
  -- emission leave mm (docs/trackerManager.md § PC synthesis). The
  -- mode is wiring-derived per bind, so a rebind is how a take leaves it; note.sample is the
  -- intent, and a rebind back into the mode synthesises the same stream again.
  {
    name = 'leaving trackerMode deletes the synthesised pcs, and re-entering restores them',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq = 0,   endppq = 240, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0, sample = 3 },
          { ppq = 240, endppq = 480, chan = 1, pitch = 62, vel = 100, detune = 0, delay = 0, sample = 5 },
        } },
        config = { transient = { trackerMode = true } },
      }
      local synthesised = { { ppq = 0, val = 3 }, { ppq = 240, val = 5 } }
      t.deepEq(pcsOnChan(h.fm:dump(), 1), synthesised, 'fixture check: the mode synthesised both pcs')
      local take = h.tm:currentTake()

      h.tm:bindTake(nil)
      h.tm:bindTake(take, { trackerMode = false })
      t.deepEq(pcsOnChan(h.fm:dump(), 1), {}, 'out of the mode, no pc sounds')
      t.eq(pcColumn(h, 1), nil, 'and the column has nothing to seat')

      h.tm:bindTake(nil)
      h.tm:bindTake(take, { trackerMode = true })
      t.deepEq(pcsOnChan(h.fm:dump(), 1), synthesised, 'back in the mode, the samples synthesise again')
    end,
  },

  -- A take saved under the mode and opened outside it: the sweep takes the synthesised pc on the
  -- first pass and leaves the authored one where it was.
  {
    name = 'trackerMode off: a loaded synthesised pc leaves mm, an authored pc stands',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0, sample = 3 } },
          ccs   = { { ppq = 0,   evType = 'pc', chan = 1, val = 3,  derived = 'pc' },
                    { ppq = 100, evType = 'pc', chan = 1, val = 42 } },
        },
      }
      t.deepEq(pcsOnChan(h.fm:dump(), 1), { { ppq = 100, val = 42 } }, 'only the authored pc is left in mm')
      t.deepEq(pcColumn(h, 1), { { ppq = 100, val = 42 } }, 'and it keeps its seat in the column')
    end,
  },

  -- Under trackerMode synthesis consumes an authored pc: the stamp reads it into the bare notes it
  -- prevails over, and synthesis deletes it from mm and its column (docs/trackerManager.md
  -- § PC synthesis). A pc column then exists only where extraColumns asks.
  {
    name = 'a consumed authored pc leaves mm and the pc column',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 240, endppq = 480, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 } },
          ccs   = { { ppq = 0,   evType = 'pc', chan = 1, val = 11 } },
        },
        config = { transient = { trackerMode = true } },
      }
      t.deepEq(pcsOnChan(h.fm:dump(), 1), { { ppq = 240, val = 11 } },
        'the authored pc is gone; the note it stamped programs its onset')
      t.eq(pcColumn(h, 1), nil, 'and no column is left to hold nothing')
    end,
  },

  {
    name = 'a consumed authored pc leaves a wanted pc column empty',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { { ppq = 240, endppq = 480, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0 } },
          ccs   = { { ppq = 0,   evType = 'pc', chan = 1, val = 11 } },
        },
        data   = { extraColumns = { [1] = { notes = 1, pc = true } } },
        config = { transient = { trackerMode = true } },
      }
      t.deepEq(pcsOnChan(h.fm:dump(), 1), { { ppq = 240, val = 11 } },
        'fixture check: the authored pc was consumed')
      t.deepEq(pcColumn(h, 1), {}, 'extraColumns keeps the column, and it holds nothing')
    end,
  },

  {
    name = 'an authored pc written mid-session is consumed on its flush',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 0,   endppq = 240, chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0, sample = 1 },
            { ppq = 480, endppq = 720, chan = 1, pitch = 62, vel = 100, detune = 0, delay = 0, sample = 2 },
          },
        },
        config = { transient = { trackerMode = true } },
      }
      h.tm:addEvent({ evType = 'pc', ppq = 240, chan = 1, val = 42 })
      h.tm:flush()
      t.deepEq(pcsOnChan(h.fm:dump(), 1), { { ppq = 0, val = 1 }, { ppq = 480, val = 2 } },
        'the authored pc is gone from mm')
      for _, e in ipairs((pcColumn(h, 1)) or {}) do
        t.truthy(e.ppq ~= 240, 'and absent from the pc column')
      end
    end,
  },
}
