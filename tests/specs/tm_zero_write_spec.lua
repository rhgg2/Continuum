-- Zero-write convergence: a converged FULL re-derive stages zero mm writes and
-- zero ds writes. This is the fixpoint that terminates the rebuild self-trigger
-- loop -- a rebuild's own ds:assign fires 'dataChanged', which re-enters
-- tm:rebuild; the loop halts only because a converged pass writes nothing.
-- Pre-phase step 3 of design/rebuild-pipeline.md.
--
-- Distinct from tm_gate_parity's pin: that asserts a gated rebuild's OUTPUT
-- equals a forced full re-derive's. Byte-identical output can still hide a
-- no-op overwrite (assign the same value back); this counts the writes
-- themselves. The deepEq guards at the fxParked/prevWindows assign sites and
-- the content-keyed reconcile are the production mechanism; this pins they hold.
--
-- Pinned on both interval-dirt phase-0 fixtures so the property spans both take
-- shapes: the macro-heavy glasswork (fx/pbs/ccs-bound -- all 9 generators, an
-- fx chain, a canon group, 53EDO detune) and the dense single-channel
-- HAMMERKLAVIER (internals/tails-bound -- thousands of notes on one channel,
-- injected as a raw-MIDI import). See design/interval-dirt.md § Phase 0 and
-- docs/bridge-cookbook.md § Import.

local t = require('support')
local glasswork = require('fixtures.glasswork')

-- The test project's ppq-per-quarter (docs/bridge-cookbook.md § profiling); the
-- resolution both blobs' absolute ppq positions were captured at.
local RES = 12288

local specDir = debug.getinfo(1, 'S').source:match('^@?(.*)/[^/]+$')

----- Write-counting a converged full re-derive

-- Settle to the output of a full re-derive, then count a SECOND full re-derive.
-- Two full re-derives over identical (mm, ds) inputs: the second must be silent,
-- or the derivation is not a true fixpoint. mm writes flow through add/assign/
-- delete (mmBatch.commit early-returns on an empty batch); ds writes through
-- assign. tm holds the same mm/ds tables the harness exposes, so wrapping the
-- fields intercepts every pipeline write.
local function assertConverges(h, msg)
  h.tm:rebuild(true)                       -- settle: the state a full re-derive lands in
  local mmW, dsW = 0, 0
  local mm, ds = h.fm, h.ds
  local add, assign, del, dsAssign = mm.add, mm.assign, mm.delete, ds.assign
  mm.add    = function(...) mmW = mmW + 1; return add(...)      end
  mm.assign = function(...) mmW = mmW + 1; return assign(...)   end
  mm.delete = function(...) mmW = mmW + 1; return del(...)      end
  ds.assign = function(...) dsW = dsW + 1; return dsAssign(...) end
  h.tm:rebuild(true)                       -- the converged pass: must write nothing
  mm.add, mm.assign, mm.delete, ds.assign = add, assign, del, dsAssign
  t.eq(mmW, 0, msg .. ' [mm writes on converged full re-derive]')
  t.eq(dsW, 0, msg .. ' [ds writes on converged full re-derive]')
end

-- A raw-MIDI blob stores note-on/off as separate delta-timed events; walk the
-- deltas to the last event's ppq so the injected take gets a source long enough
-- to hold every note (the trailing 12 bytes are the all-notes-off tail).
local function readBlob(relPath)
  local f = assert(io.open(specDir .. '/' .. relPath, 'rb'))
  local raw = f:read('a'); f:close()
  local pos, ppq = 1, 0
  while pos < #raw - 12 do
    local offset, _, _, np = string.unpack('i4Bs4', raw, pos)
    ppq, pos = ppq + offset, np
  end
  return raw, ppq
end

return {
  {
    name = 'converged glasswork (macro: generators, fx chain, canon, 53EDO) re-derives with zero writes',
    run = function(harness)
      local h = harness.mk{
        config = { project = { swings = { c58 = glasswork.classic58 }, temper = '53EDO' } },
        data   = { swing = { global = 'c58' } },
        seed   = { resolution = RES, length = glasswork.LENGTH },
        groups = true,
      }
      glasswork.build(h.tm, h.gm)

      -- Liveness across all three axes, so a zero count is a real fixpoint and
      -- not two empty frames agreeing. chan 1 is a retrig host (24 authored
      -- notes -> many fxNotes); pb is 53EDO detune realised; chan 16 is a canon.
      local dump = h.fm:dump()
      local nCh1, nPb, nCanon16 = 0, 0, 0
      for _, n in ipairs(dump.notes) do if n.chan == 1  then nCh1 = nCh1 + 1 end
                                         if n.chan == 16 then nCanon16 = nCanon16 + 1 end end
      for _, c in ipairs(dump.ccs)   do if c.evType == 'pb' then nPb = nPb + 1 end end
      t.truthy(nCh1 > 24,     'retrig fx expanded chan 1 beyond its authored notes')
      t.truthy(nPb > 0,       '53EDO detune realised into pb streams')
      t.truthy(nCanon16 > 0,  'canon instances present on chan 16')

      assertConverges(h, 'glasswork')
    end,
  },

  {
    name = 'converged HAMMERKLAVIER (dense single-channel import) re-derives with zero writes',
    run = function(harness)
      local raw, maxPpq = readBlob('../fixtures/hammerklavier.rawmidi')
      local h = harness.mk{ seed = { resolution = RES, length = maxPpq + RES } }

      -- Inject the stripped raw-MIDI blob and drive the import (mm re-reads the
      -- foreign take, tm stamps it to the settled internal columns -- "state 2"
      -- in docs/bridge-cookbook.md § Import). This is the writing pass; the
      -- forced re-derives inside assertConverges are the fixpoint being pinned.
      local take = h.fm:take()
      h.reaper.MIDI_SetAllEvts(take, raw)
      h.reaper.MIDI_Sort(take)
      h.tm:reloadFromReaper()

      local dump = h.fm:dump()
      local perChan = {}
      for _, n in ipairs(dump.notes) do perChan[n.chan] = (perChan[n.chan] or 0) + 1 end
      t.truthy((perChan[1] or 0) > 1000, 'the dense take imported: >1000 notes on chan 1')

      assertConverges(h, 'HAMMERKLAVIER')
    end,
  },
}
