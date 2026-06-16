-- Phase 2 (two-frame timing): the rebuild rule. tm reconciles raw ppq
-- with ppqL on every rebuild under three branches:
--   - stale=true  & ppqL present  → raw rebuilt from ppqL (+ delay)
--   - stale=false & raw matches   → no-op (steady state)
--   - stale=false & raw disagrees → ppqL rederived from raw
-- The rpb mark survives as authorship provenance but no longer gates the rule.

local t = require('support')

local classic58 = { factors = { { atom = 'classic', shift = 0.08, period = 1 } } }
local classic67 = { factors = { { atom = 'classic', shift = 0.17, period = 1 } } }

local function noteByPitch(dump, pitch)
  for _, n in ipairs(dump.notes) do if n.pitch == pitch then return n end end
end
local function ccByCC(dump, ccNum)
  for _, c in ipairs(dump.ccs) do
    if c.evType == 'cc' and c.cc == ccNum then return c end
  end
end

return {
  ----- Disagreement / missing-ppqL branch (covers legacy load and external edits)

  {
    name = 'note with no ppqL gets ppqL written on first rebuild',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq = 60, endppq = 180, chan = 1, pitch = 60, vel = 100 },
        }},
      }
      local n = noteByPitch(h.fm:dump(), 60)
      -- Identity swing, delay=0 (defaulted) → ppqL = ppq, endppqL = endppq.
      t.eq(n.ppqL,    60,  'ppqL backfilled from raw')
      t.eq(n.endppqL, 180, 'endppqL backfilled from raw')
    end,
  },

  {
    name = 'note with ppqL disagreeing with raw gets ppqL rederived',
    run = function(harness)
      -- raw=200, ppqL=999 (stale on disk from external edit). Identity
      -- swing, delay=0: predicted=999 vs raw=200 → disagreement →
      -- ppqL becomes toLogical(200) = 200.
      local h = harness.mk{
        seed = { notes = {
          { ppq = 200, endppq = 320, chan = 1, pitch = 60, vel = 100,
            ppqL = 999, endppqL = 1119 },
        }},
      }
      local n = noteByPitch(h.fm:dump(), 60)
      t.eq(n.ppqL,    200, 'ppqL recomputed from raw under identity')
      t.eq(n.endppqL, 320, 'endppqL recomputed from raw under identity')
    end,
  },

  {
    name = 'cc with no ppqL gets ppqL written and uuid allocated',
    run = function(harness)
      local h = harness.mk{
        seed = { ccs = {
          { ppq = 90, evType = 'cc', chan = 1, cc = 7, val = 64 },
        }},
      }
      local c = ccByCC(h.fm:dump(), 7)
      t.eq(c.ppqL, 90, 'ppqL backfilled')
      t.truthy(c.uuid, 'uuid allocated for the metadata stamp')
    end,
  },

  ----- Steady-state (matching ppqL is a no-op)

  {
    name = 'note with matching ppqL is left alone',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq = 120, endppq = 240, chan = 1, pitch = 60, vel = 100,
            ppqL = 120, endppqL = 240 },
        }},
      }
      local n = noteByPitch(h.fm:dump(), 60)
      t.eq(n.ppq,     120)
      t.eq(n.endppq,  240)
      t.eq(n.ppqL,    120, 'ppqL unchanged')
      t.eq(n.endppqL, 240, 'endppqL unchanged')
    end,
  },

  {
    name = 'matching ppqL under c58 is steady-state (predicted=raw within ε)',
    run = function(harness)
      -- c58.fromLogical(120) on rpb=4, res=240 → 139.2 → round 139.
      -- Author the note at raw=139, ppqL=120; rule sees no disagreement.
      local h = harness.mk{
        seed = { notes = {
          { ppq = 139, endppq = 240, chan = 1, pitch = 60, vel = 100,
            ppqL = 120, endppqL = 240 },
        }},
        config = {
          project = { swings = { ['c58'] = classic58 } },
        },
        data = { swing = { global = 'c58' } },
      }
      local n = noteByPitch(h.fm:dump(), 60)
      t.eq(n.ppq,  139, 'raw unchanged under matching swing')
      t.eq(n.ppqL, 120, 'ppqL unchanged')
    end,
  },

  ----- Stale branch (raw rebuilt from ppqL; flag cleared)

  {
    name = 'markSwingStale rebuilds raw from ppqL on next rebuild and clears the flag',
    run = function(harness)
      -- Steady state under c58: raw=139 matches fromLogical_c58(120)=139.
      local h = harness.mk{
        seed = { notes = {
          { ppq = 139, endppq = 240, chan = 1, pitch = 60, vel = 100,
            ppqL = 120, endppqL = 240 },
        }},
        config = {
          project = { swings = { ['c58'] = classic58 } },
        },
        data = { swing = { global = 'c58' } },
      }
      -- Mark stale, then nudge raw out of band. fm:modify fires reload →
      -- tm:rebuild, which sees stale=true and reseats raw from ppqL=120.
      h.tm:markSwingStale(1)
      local _, seed1 = h.fm:notes()()
      h.fm:modify(function() h.fm:assign(seed1.token, { ppq = 100 }) end)

      local n = noteByPitch(h.fm:dump(), 60)
      t.eq(n.ppq,    139, 'raw reseated from ppqL under c58')
      t.eq(n.endppq, 240, 'endppq at period boundary stays at 240')
      t.eq(n.ppqL,   120, 'ppqL preserved')

      -- Flag is consumed: a second nudge without re-marking is treated as
      -- external edit (disagreement), recomputing ppqL from the new raw.
      local _, seed2 = h.fm:notes()()
      h.fm:modify(function() h.fm:assign(seed2.token, { ppq = 100 }) end)
      local n2 = noteByPitch(h.fm:dump(), 60)
      t.eq(n2.ppq, 100, 'raw kept on second nudge (flag was cleared)')
      -- ppqL = toLogical_c58(100) ≠ 120; assert it changed.
      t.truthy(n2.ppqL ~= 120, 'ppqL recomputed from raw — flag is non-sticky')
    end,
  },

  {
    name = 'markSwingStale restamps cc-event loc so column writes route correctly',
    -- Regression: column cc events have `cc` stripped by CC_PROJECT_STRIP,
    -- so the loc-restamp block must source the cc number from the column,
    -- not the event. A bug here only shows up when a stale-swing rebuild
    -- is followed by a column-driven write to the cc.
    run = function(harness)
      local h = harness.mk{
        seed = { ccs = {
          { ppq = 139, evType = 'cc', chan = 1, cc = 7, val = 64,
            ppqL = 120 },
        }},
        config = {
          project = { swings = { ['c58'] = classic58 } },
        },
        data = { swing = { global = 'c58' } },
      }
      h.tm:markSwingStale(1)
      h.fm:modify(function()
        for _, c in h.fm:ccs() do h.fm:assign(c.token, { ppq = 100 }) end
      end)
      t.eq(ccByCC(h.fm:dump(), 7).ppq, 139, 'cc raw reseated from ppqL')

      -- Column event must carry a live loc; route an assign through it.
      local colE = h.tm:getChannel(1).columns.ccs[7].events[1]
      h.tm:assignEvent(colE, { val = 99 })
      h.tm:flush()
      t.eq(ccByCC(h.fm:dump(), 7).val, 99, 'assign routes via restamped loc')
    end,
  },

  {
    name = 'markSwingStale(nil) marks all 16 channels',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq = 139, endppq = 240, chan = 1, pitch = 60, vel = 100,
            ppqL = 120, endppqL = 240 },
          { ppq = 139, endppq = 240, chan = 5, pitch = 64, vel = 100,
            ppqL = 120, endppqL = 240 },
        }},
        config = {
          project = { swings = { ['c58'] = classic58 } },
        },
        data = { swing = { global = 'c58' } },
      }
      h.tm:markSwingStale(nil)
      h.fm:modify(function()
        for _, n in h.fm:notes() do h.fm:assign(n.token, { ppq = 100 }) end
      end)

      local dump = h.fm:dump()
      t.eq(noteByPitch(dump, 60).ppq, 139, 'chan 1 reseated')
      t.eq(noteByPitch(dump, 64).ppq, 139, 'chan 5 reseated')
    end,
  },

  {
    name = 'stale on event without ppqL falls through to disagreement (ppqL written, raw untouched)',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          -- No ppqL. Mark stale before init's rebuild — but tm:rebuild fires
          -- in the constructor before we get a handle, so instead seed and
          -- then mark+rebuild.
          { ppq = 60, endppq = 180, chan = 1, pitch = 60, vel = 100 },
        }},
      }
      -- After mk's rebuild, ppqL was already backfilled (disagreement).
      -- Verify the post-mk state, then mark stale and rebuild — should be
      -- a no-op since raw and ppqL now agree.
      local n1 = noteByPitch(h.fm:dump(), 60)
      t.eq(n1.ppqL, 60)

      h.tm:markSwingStale(1)
      h.tm:rebuild()
      local n2 = noteByPitch(h.fm:dump(), 60)
      t.eq(n2.ppq,  60, 'raw unchanged when ppqL already agrees')
      t.eq(n2.ppqL, 60)
    end,
  },

  ----- Exempt events (fake only — rpb no longer gates the rule)

  {
    name = 'rpb-stamped event with stale ppqL: predicted-check rederives from raw',
    run = function(harness)
      -- rpb marks authorship but does not freeze ppqL. A non-stale channel
      -- whose raw disagrees with predicted is an external REAPER edit;
      -- ppqL follows raw so the next swing change rebuilds raw from a
      -- ppqL that already reflects the user's intent.
      local h = harness.mk{
        seed = { notes = {
          { ppq = 200, endppq = 320, chan = 1, pitch = 60, vel = 100,
            ppqL = 999, endppqL = 1119, rpb = 4 },
        }},
      }
      local n = noteByPitch(h.fm:dump(), 60)
      t.eq(n.ppqL,    200, 'ppqL rederived from raw on disagreement')
      t.eq(n.endppqL, 320, 'endppqL rederived from raw on disagreement')
    end,
  },

  ----- Phase 3 triggers: cm.swing changes flip staleSwing before the
  -- rebuild that follows. swing/colSwing/swings keys flip; everything
  -- else does not. Conservative all-channel marking — channels under
  -- unaffected swings reseat to identical raw and produce no mm write,
  -- which preserves the per-channel observable behaviour.

  {
    name = 'global swing change reseats raw across all channels (ppqL preserved)',
    run = function(harness)
      -- Start at identity, two channels at raw=ppqL=120. Switching
      -- global swing to c58 should reseat raw to fromLogical_c58(120)=139
      -- on both channels.
      local h = harness.mk{
        seed = { notes = {
          { ppq = 120, endppq = 240, chan = 1, pitch = 60, vel = 100,
            ppqL = 120, endppqL = 240 },
          { ppq = 120, endppq = 240, chan = 5, pitch = 64, vel = 100,
            ppqL = 120, endppqL = 240 },
        }},
        config = { project = { swings = { ['c58'] = classic58 } } },
      }
      h.ds:assign('swing', { global = 'c58' })
      local dump = h.fm:dump()
      local n1 = noteByPitch(dump, 60)
      local n5 = noteByPitch(dump, 64)
      t.eq(n1.ppq,  139, 'chan 1 reseated under new global swing')
      t.eq(n1.ppqL, 120, 'chan 1 ppqL preserved')
      t.eq(n5.ppq,  139, 'chan 5 reseated under new global swing')
      t.eq(n5.ppqL, 120, 'chan 5 ppqL preserved')
    end,
  },

  {
    name = 'per-column swing change moves only the named channel',
    run = function(harness)
      -- Two channels at identity. Set colSwing[2]=c67. Chan 1 stays
      -- (no swing applies → reseat to identity is a no-op write); chan 2
      -- reseats under c67: round(0.67·240)=161.
      local h = harness.mk{
        seed = { notes = {
          { ppq = 120, endppq = 240, chan = 1, pitch = 60, vel = 100,
            ppqL = 120, endppqL = 240 },
          { ppq = 120, endppq = 240, chan = 2, pitch = 64, vel = 100,
            ppqL = 120, endppqL = 240 },
        }},
        config = { project = { swings = { ['c67'] = classic67 } } },
      }
      h.ds:assign('swing', { [2] = 'c67' })
      local dump = h.fm:dump()
      t.eq(noteByPitch(dump, 60).ppq, 120, 'chan 1 unmoved (no swing applies)')
      t.eq(noteByPitch(dump, 64).ppq, 161, 'chan 2 reseated under c67')
    end,
  },

  {
    name = 'editing a referenced library entry reseats channels using it',
    run = function(harness)
      -- Chan 1 references library name 'mySwing' (initially c58). Replace
      -- the library entry with a c67 body. The channel's effective shape
      -- changes, so raw must reseat.
      local h = harness.mk{
        seed = { notes = {
          { ppq = 139, endppq = 240, chan = 1, pitch = 60, vel = 100,
            ppqL = 120, endppqL = 240 },
        }},
        config = {
          project = { swings = { ['mySwing'] = classic58 } },
        },
        data = { swing = { global = 'mySwing' } },
      }
      t.eq(noteByPitch(h.fm:dump(), 60).ppq, 139, 'pre: c58 body, raw=139')

      h.cm:set('project', 'swings', { ['mySwing'] = classic67 })
      local n = noteByPitch(h.fm:dump(), 60)
      t.eq(n.ppq,  161, 'raw reseated under new library body (c67)')
      t.eq(n.ppqL, 120, 'ppqL preserved across library edit')
    end,
  },

  {
    name = 'reassigning a column slot to a different library entry reseats that channel',
    run = function(harness)
      -- Library has both c58 and c67. Chan 1 starts referencing c58 via
      -- colSwing; reassign to c67 and verify chan 1 reseats while chan 2
      -- (no colSwing entry) is unaffected.
      local h = harness.mk{
        seed = { notes = {
          { ppq = 139, endppq = 240, chan = 1, pitch = 60, vel = 100,
            ppqL = 120, endppqL = 240 },
          { ppq = 120, endppq = 240, chan = 2, pitch = 64, vel = 100,
            ppqL = 120, endppqL = 240 },
        }},
        config = {
          project = { swings = { ['c58'] = classic58, ['c67'] = classic67 } },
        },
        data = { swing = { [1] = 'c58' } },
      }
      t.eq(noteByPitch(h.fm:dump(), 60).ppq, 139, 'pre: chan 1 under c58')
      t.eq(noteByPitch(h.fm:dump(), 64).ppq, 120, 'pre: chan 2 at identity')

      h.ds:assign('swing', { [1] = 'c67' })
      local dump = h.fm:dump()
      t.eq(noteByPitch(dump, 60).ppq, 161, 'chan 1 reseated under c67')
      t.eq(noteByPitch(dump, 64).ppq, 120, 'chan 2 still identity')
    end,
  },

  ----- 7a granularity: subscriber routes only the affected channels into
  -- markSwingStale. Witnessed by spying on tm:markSwingStale itself — the
  -- raw outcome under all-16 vs granular is identical for round-trip-
  -- consistent (raw, ppqL) pairs, so the call set is the observable.

  {
    name = 'colSwing change marks only altered channels',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq = 139, endppq = 240, chan = 1, pitch = 60, vel = 100, ppqL = 120, endppqL = 240 },
          { ppq = 139, endppq = 240, chan = 2, pitch = 64, vel = 100, ppqL = 120, endppqL = 240 },
        }},
        config = {
          project = { swings = { ['c58'] = classic58, ['c67'] = classic67 } },
        },
        data = { swing = { [1] = 'c58', [2] = 'c58' } },
      }
      local marked = {}
      local orig = h.tm.markSwingStale
      h.tm.markSwingStale = function(self, chan)
        marked[chan or 'all'] = (marked[chan or 'all'] or 0) + 1
        return orig(self, chan)
      end
      h.ds:assign('swing', { [1] = 'c67', [2] = 'c58' })
      t.eq(marked[1],     1,   'chan 1 marked (its colSwing changed)')
      t.eq(marked[2],     nil, 'chan 2 NOT marked (its colSwing unchanged)')
      t.eq(marked['all'], nil, 'no global mark')
    end,
  },

  {
    name = 'swings library edit marks only channels using changed names',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = {
          { ppq = 139, endppq = 240, chan = 1, pitch = 60, vel = 100, ppqL = 120, endppqL = 240 },
          { ppq = 120, endppq = 240, chan = 2, pitch = 64, vel = 100, ppqL = 120, endppqL = 240 },
        }},
        config = {
          project = { swings = { ['a'] = classic58, ['b'] = classic67 } },
        },
        data = { swing = { [1] = 'a' } },
      }
      local marked = {}
      local orig = h.tm.markSwingStale
      h.tm.markSwingStale = function(self, chan)
        marked[chan or 'all'] = (marked[chan or 'all'] or 0) + 1
        return orig(self, chan)
      end
      -- Edit body of 'a' only; 'b' unchanged.
      h.cm:set('project', 'swings', { ['a'] = classic67, ['b'] = classic67 })
      t.eq(marked[1],     1,   'chan 1 (resolves to "a") marked')
      t.eq(marked[2],     nil, 'chan 2 (no colSwing entry) NOT marked')
      t.eq(marked['all'], nil, 'no global mark')
    end,
  },

  {
    name = 'swings library edit of the global-swing name marks all 16',
    run = function(harness)
      local h = harness.mk{
        seed = {},
        config = {
          project = { swings = { ['g'] = classic58 } },
        },
        data = { swing = { global = 'g' } },
      }
      local marked = {}
      local orig = h.tm.markSwingStale
      h.tm.markSwingStale = function(self, chan)
        marked[chan or 'all'] = (marked[chan or 'all'] or 0) + 1
        return orig(self, chan)
      end
      -- Edit 'g' — every channel resolves through the global slot, so all 16.
      h.cm:set('project', 'swings', { ['g'] = classic67 })
      for chan = 1, 16 do
        t.eq(marked[chan], 1, 'chan ' .. chan .. ' marked via global shadow')
      end
    end,
  },

  {
    name = 'global swing change emits a single nil mark (covers all 16)',
    run = function(harness)
      local h = harness.mk{
        seed = {},
        config = { project = { swings = { ['c58'] = classic58 } } },
      }
      local count, sawNil = 0, false
      local orig = h.tm.markSwingStale
      h.tm.markSwingStale = function(self, chan)
        count = count + 1
        if chan == nil then sawNil = true end
        return orig(self, chan)
      end
      h.ds:assign('swing', { global = 'c58' })
      t.eq(count, 1, 'exactly one mark call')
      t.truthy(sawNil, 'mark called with nil (all-16)')
    end,
  },

  {
    name = 'colSwing set to identical value emits no marks',
    run = function(harness)
      local h = harness.mk{
        seed = {},
        config = {
          project = { swings = { ['c58'] = classic58 } },
        },
        data = { swing = { [1] = 'c58' } },
      }
      local count = 0
      local orig = h.tm.markSwingStale
      h.tm.markSwingStale = function(self, chan)
        count = count + 1
        return orig(self, chan)
      end
      h.ds:assign('swing', { [1] = 'c58' })
      t.eq(count, 0, 'no-diff write fires no marks')
    end,
  },

  {
    name = 'non-swing config change does not flip stale (preserves externally-edited raw)',
    run = function(harness)
      -- Steady-state under c58: raw=139, ppqL=120. Simulate an external
      -- piano-roll edit (raw nudged to 100). The reload-rebuild's
      -- disagreement branch rederives ppqL from the new raw — the user's
      -- edit is preserved. Then change a non-swing key (rowPerBeat). If
      -- the trigger wiring incorrectly flips stale on non-swing changes,
      -- the rule would reseat raw FROM ppqL, undoing the user's edit.
      local h = harness.mk{
        seed = { notes = {
          { ppq = 139, endppq = 240, chan = 1, pitch = 60, vel = 100,
            ppqL = 120, endppqL = 240 },
        }},
        config = {
          project = { swings = { ['c58'] = classic58 } },
        },
        data = { swing = { global = 'c58' } },
      }
      local _, seedN = h.fm:notes()()
      h.fm:modify(function() h.fm:assign(seedN.token, { ppq = 100 }) end)
      local n1 = noteByPitch(h.fm:dump(), 60)
      t.eq(n1.ppq, 100, 'external raw edit preserved by disagreement branch')
      local ppqLAfterExternal = n1.ppqL
      t.truthy(ppqLAfterExternal ~= 120, 'ppqL rederived from external raw')

      h.cm:set('take', 'rowPerBeat', 8)
      local n2 = noteByPitch(h.fm:dump(), 60)
      t.eq(n2.ppq,  100,                 'raw preserved across non-swing config change')
      t.eq(n2.ppqL, ppqLAfterExternal,   'ppqL preserved across non-swing config change')
    end,
  },
}
