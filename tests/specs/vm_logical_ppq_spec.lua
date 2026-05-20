-- Pins the ppqL invariant across vm's authoring + editing paths.
--
-- Storage model: every event Continuum stamps carries ppqL (and
-- endppqL for notes), the canonical authoring-grid position
-- pre-swing, pre-delay; evt.rpb marks it as authored.
-- Mutation rules:
--   - snap-to-row              writes ppqL = row * logPerRow
--   - shift-by-row              ppqL += rowDelta * logPerRow
--   - delay nudge               ppqL unchanged, rpb unchanged
--   - reswing                   ppqL unchanged, raw re-applied, rpb unchanged

local t = require('support')

local classic58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }

local function noteByPitch(dump, pitch)
  for _, n in ipairs(dump.notes) do if n.pitch == pitch then return n end end
end

local function ccByCC(dump, cc)
  for _, c in ipairs(dump.ccs) do if c.cc == cc then return c end end
end

return {

  ---------- AUTHORING

  {
    name = 'fresh note at cursor row r writes ppqL = r·logPerRow in current frame',
    run = function(harness)
      local h = harness.mk{ config = { take = { rowPerBeat = 4, currentOctave = 4 } } }
      h.vm:setGridSize(80, 40)

      -- C-4 at row 2, col 1, no swing → logical = realised = 120.
      h.ec:setPos(2, 1, 1)
      h.vm:editEvent(h.vm.grid.cols[1], nil, 1, string.byte('z'), false)

      local n = noteByPitch(h.fm:dump(), 60)
      t.truthy(n, 'note authored')
      t.eq(n.ppq,         120, 'realised ppq at row 2')
      t.eq(n.ppqL, 120, 'logical ppq pins authoring row')
      t.eq(n.rpb,         4,   'rpb stamped from take')
    end,
  },

  {
    name = 'fresh note under c58 stamps ppqL at the logical row, ppq at the swung position',
    run = function(harness)
      local h = harness.mk{
        config = {
          project = { swings = { c58 = classic58 } },
          take    = { swing = 'c58', rowPerBeat = 4, currentOctave = 4 },
        },
      }
      h.vm:setGridSize(80, 40)

      -- Row 2 = mid-period under c58: logical=120, realised≈139.
      h.ec:setPos(2, 1, 1)
      h.vm:editEvent(h.vm.grid.cols[1], nil, 1, string.byte('z'), false)

      local n = noteByPitch(h.fm:dump(), 60)
      t.eq(n.ppqL, 120,   'logical pins row 2 (60 * 2)')
      t.truthy(math.abs(n.ppq - 139) <= 1,
        'realised lands at swung position, got ' .. n.ppq)
      t.eq(n.rpb, 4, 'rpb stamped from take')
    end,
  },

  {
    name = 'fresh cc at cursor row writes ppqL at row * logPerRow',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = { { ppq = 0, chan = 1, evType = 'cc', cc = 11, val = 0 } },
        },
        config = { take = { rowPerBeat = 8 } },
      }
      h.vm:setGridSize(80, 40)

      -- Find the cc=11 column.
      local ccColIdx
      for i, col in ipairs(h.vm.grid.cols) do
        if col.type == 'cc' and col.cc == 11 then ccColIdx = i end
      end
      h.ec:setPos(3, ccColIdx, 1)  -- row 3 in rpb=8 → logPerRow=30, logical=90
      h.vm:editEvent(h.vm.grid.cols[ccColIdx], nil, 1, string.byte('5'), false)

      local fresh
      for _, c in ipairs(h.fm:dump().ccs) do
        if c.cc == 11 and c.ppq ~= 0 then fresh = c end
      end
      t.truthy(fresh, 'cc authored')
      t.eq(fresh.ppq,         90, 'realised ppq at row 3')
      t.eq(fresh.ppqL, 90, 'ppqL pins row 3 (30 * 3)')
    end,
  },

  ---------- DELAY NUDGE

  {
    name = 'delay nudge shifts realised onset but leaves end + ppqL intact',
    run = function(harness)
      -- Note covers intent ppq 120..360 (duration 240). Delay 500
      -- milli-QN = 120 ppq fits below the duration-1 collapse bound.
      local h = harness.mk{
        seed = {
          notes = {
            { ppq = 120, endppq = 360, chan = 1, pitch = 60, vel = 100,
              ppqL = 120, endppqL = 360,
              rpb = 4 },
          },
        },
        config = { take = { rowPerBeat = 4, noteDelay = { [1] = { [1] = true } } } },
      }
      h.vm:setGridSize(80, 40)

      -- Edit delay on the existing note. Note delay is decimal, stops 5..7.
      -- Set first nibble of delay magnitude to 5 → +500 ms-QN = 120 ppq.
      local cells = h.vm.grid.cols[1].cells
      local note  = cells[2]
      h.vm:editEvent(h.vm.grid.cols[1], note, 5, string.byte('5'), false)

      local n = noteByPitch(h.fm:dump(), 60)
      t.eq(n.ppqL, 120,    'ppqL untouched by delay nudge')
      t.eq(n.endppqL, 360, 'endppqL untouched by delay nudge')
      t.eq(n.delay, 500,          'delay applied (milli-QN, first digit slot)')
      t.eq(n.ppq,    240,         'realised onset shifted by delay')
      t.eq(n.endppq, 360,         'endppq stays put — delay shifts only the note-on')
    end,
  },

  ---------- PASTE TRUNCATE

  -- Paste no longer pre-trims a note that overhangs into the paste
  -- region: endppq is authored intent now. The note keeps its ceiling
  -- (endppqL); tm's universal tail pass clips the realised endppq to
  -- the pasted onset, and regrows it if the paste is later removed.
  {
    name = 'pasteSingle does not shrink an overhung note: intent survives, tm clips the realised tail',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          -- Long note rows 0..8 (ppq 0..480) at rpb=4. Will be truncated.
          { ppq = 0,   endppq = 480, chan = 1, pitch = 60, vel = 100,
            detune = 0, delay = 0 },
          -- Source note at row 10 — copied and pasted into the long note's tail.
          { ppq = 600, endppq = 660, chan = 1, pitch = 62, vel = 100,
            detune = 0, delay = 0 },
        }},
        config = { take = { rowPerBeat = 4 } },
      }
      h.vm:setGridSize(80, 40)

      h.ec:setPos(10, 1, 1)             -- on the source note
      h.cmgr:invoke('copy')
      h.ec:setPos(4, 1, 1)              -- inside long note's tail
      h.cmgr:invoke('paste')

      local long = noteByPitch(h.fm:dump(), 60)
      t.truthy(long, 'long note survived')
      t.eq(long.endppq,  240, 'realised tail clipped to the pasted onset by tm')
      t.eq(long.endppqL, 480, 'intent ceiling survives -- paste does not shrink it')
    end,
  },

  -- Same for multi-col paste: the overhung notes keep their intent;
  -- tm clips the realised tails to the pasted onset.
  {
    name = 'pasteMulti does not shrink overhung notes: intent survives, tm clips the realised tails',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          -- Two long notes on chans 1 & 2, both will be truncated.
          { ppq = 0, endppq = 480, chan = 1, pitch = 60, vel = 100,
            detune = 0, delay = 0 },
          { ppq = 0, endppq = 480, chan = 2, pitch = 64, vel = 100,
            detune = 0, delay = 0 },
          -- Two source notes on chans 1 & 2 to drive multi-col paste.
          { ppq = 600, endppq = 660, chan = 1, pitch = 62, vel = 100,
            detune = 0, delay = 0 },
          { ppq = 600, endppq = 660, chan = 2, pitch = 65, vel = 100,
            detune = 0, delay = 0 },
        }},
        config = { take = { rowPerBeat = 4 } },
      }
      h.vm:setGridSize(80, 40)

      -- Multi-col copy: row 10, cols 1..2 pitch part.
      h.ec:setSelection{ row1=10, row2=10, col1=1, col2=2,
                          part1='pitch', part2='pitch' }
      h.cmgr:invoke('copy')
      h.ec:setPos(4, 1, 1)
      h.cmgr:invoke('paste')

      local long1 = noteByPitch(h.fm:dump(), 60)
      local long2 = noteByPitch(h.fm:dump(), 64)
      t.eq(long1.endppq,  240, 'chan-1 realised tail clipped by tm')
      t.eq(long1.endppqL, 480, 'chan-1 intent ceiling survives')
      t.eq(long2.endppq,  240, 'chan-2 realised tail clipped by tm')
      t.eq(long2.endppqL, 480, 'chan-2 intent ceiling survives')
    end,
  },

  ---------- CROSS-RPB COHERENCE  (F1 / Class B)
  --
  -- Whenever a note's tail (or head) is rewritten, frame must travel
  -- with it: writing endppqL alone in current frame's units while
  -- frame still says rpb_old leaves (ppqL/endppqL, frame) incoherent.
  -- Each pin below seeds a note whose `frame.rpb` differs from the
  -- take's current `rowPerBeat` and exercises one editing mechanic.

  -- Tail-stamp path (covers applyNoteOff, adjustDurationCore,
  -- queueDeleteNotes survivor, placeNewNote truncate-last, paste
  -- truncate-last — all flow through assignTail now).
  {
    name = 'noteOff under cross-rpb restamps frame and lands endppqL on current grid',
    run = function(harness)
      -- Note authored at rpb=8 (logPerRow=30, row 8 → ppqL=240).
      -- Take is now at rpb=4 (logPerRow=60). Cursor on row 2 (ppq=120).
      local h = harness.mk{
        seed = { notes = {
          { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
            ppqL = 0, endppqL = 240,
            rpb = 8 },
        }},
        config = { take = { rowPerBeat = 4 } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(2, 1, 1)
      h.cmgr:invoke('noteOff')

      local n = noteByPitch(h.fm:dump(), 60)
      t.eq(n.endppq,    120, 'tail clipped to cursor ppq')
      t.eq(n.endppqL,   120, 'endppqL = row 2 * logPerRow_new (60)')
      t.eq(n.rpb,       4,   'rpb restamped to current')
    end,
  },

  -- Spanning row-shift path (insertRow / deleteRow): different from
  -- assignTail's row-map derivation: uses dLogical math + swing.
  {
    name = 'insertRow into a cross-rpb note rewrites tail with frame restamped',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          -- Note spans rows 0..4 in current frame (rpb=4): ppq 0..240.
          -- Frame.rpb=8 (cross-rpb).
          { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
            ppqL = 0, endppqL = 240,
            rpb = 8 },
        }},
        config = { take = { rowPerBeat = 4 } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(2, 1, 1)        -- inside the note's tail
      h.cmgr:invoke('insertRow')  -- pushes the spanning tail down by 1 row

      local n = noteByPitch(h.fm:dump(), 60)
      t.eq(n.endppq,    300, 'spanning tail extended by 1 row (60 ppq)')
      t.eq(n.endppqL,   300, 'endppqL coherent with new rpb')
      t.eq(n.rpb,       4,   'spanning note rpb restamped via assignTail')
    end,
  },

  -- Universal tail model: with an AGREEING onset (ppqL matches raw),
  -- the logical frame is trusted and endppqL is authoritative intent.
  -- The rebuild rule no longer pulls endppqL back from raw (the old
  -- endppq↔endppqL consistency check went with `conform`); instead the
  -- tail pass derives raw FROM endppqL. So a present endppqL is the
  -- ceiling and raw realises up to it -- there is no "stale endppqL"
  -- to fix, endppqL IS the truth. (An onset disagreement would mark
  -- the frame external/stale and rederive both from raw -- covered by
  -- tm_rebuild_rule_spec.)
  {
    name = 'agreeing onset: endppqL is authoritative intent, raw realises up to it',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq = 60, endppq = 240, chan = 1, pitch = 60, vel = 100,
            delay = 0, detune = 0,
            ppqL = 60, endppqL = 999 },
        }},
        config = { take = { rowPerBeat = 4 } },
      }
      h.vm:setGridSize(80, 40)

      local n = noteByPitch(h.fm:dump(), 60)
      t.eq(n.endppqL, 999, 'endppqL is intent — onset agrees, so it is trusted, not rederived')
      t.eq(n.endppq,  999, 'raw realises up to the authored ceiling (no blocker, within take length)')
    end,
  },

  -- Reswing operates in absolute logical-ppq: ppqL is the truth, raw
  -- is reproduced. It never changes rpb (rpb is a view concern, not a
  -- swing-target) and never rebases ppqL — events stay where authored.
  {
    name = 'reswing leaves ppqL and rpb untouched on cross-rpb event',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq = 60, endppq = 120, chan = 1, pitch = 60, vel = 100,
            ppqL = 60, endppqL = 120,
            rpb = 8 },
        }},
        config = { take = { rowPerBeat = 4 } },
      }
      h.vm:setGridSize(80, 40)
      h.tm:markSwingStale(nil); h.tm:rebuild(false)

      local n = noteByPitch(h.fm:dump(), 60)
      t.eq(n.ppqL,    60,  'ppqL preserved across reswing')
      t.eq(n.endppqL, 120, 'endppqL preserved across reswing')
      t.eq(n.rpb,     8,   'rpb preserved (reswing does not restamp)')
    end,
  },

  ---------- PA STAMPING
  --
  -- PA stamps the take's current rpb (same as any authored event).
  -- Swing is take-global, no longer per-event, so PAs carry no
  -- per-event swing context — cm's current swing handles realisation.

  {
    name = "PA emitted on a sustain row stamps the take's current rpb",
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          -- Host: cross-rpb vs. take; covers rows 0..4.
          { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
            ppqL = 0, endppqL = 240,
            delay = 0, detune = 0, rpb = 8 },
        }},
        config = {
          project = { swings = { c58 = classic58 } },
          take    = { swing = nil, rowPerBeat = 4 },
        },
      }
      h.vm:setGridSize(80, 40)
      -- Cursor on row 2 (mid-sustain), col 1, vel stop (kind='vel', stop=3).
      h.ec:setPos(2, 1, 3)
      h.vm:editEvent(h.vm.grid.cols[1], nil, 3, string.byte('5'), false)

      local pa
      for _, c in ipairs(h.fm:dump().ccs) do
        if c.evType == 'pa' then pa = c end
      end
      t.truthy(pa, 'PA emitted on sustain-row vel edit')
      t.eq(pa.rpb, 4, 'PA stamps current rpb')
    end,
  },

  ---------- RESWING ROUND-TRIP

  {
    name = 'reswing under same swing is a no-op on ppqL',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq = 139, ppqL = 120,
              chan = 1, evType = 'cc', cc = 1, val = 64,
              frame = { swing = 'c58', colSwing = nil, rpb = 4 } },
          },
        },
        config = {
          project = { swings = { c58 = classic58 } },
          take    = { swing = 'c58', rowPerBeat = 4 },
        },
      }
      h.vm:setGridSize(80, 40)
      h.tm:markSwingStale(nil); h.tm:rebuild(false)

      local c = ccByCC(h.fm:dump(), 1)
      t.eq(c.ppqL, 120, 'ppqL unchanged across same-swing reswing')
      -- realised re-applied; under same swing it's the same realised value
      -- (modulo rounding).
      t.truthy(math.abs(c.ppq - 139) <= 1, 'realised within ε of original')
    end,
  },
}
