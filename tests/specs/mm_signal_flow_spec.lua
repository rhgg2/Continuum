-- Pin-tests for the mm → tm signal split landed in the callbacks revamp.
--
-- Contract under test:
--   * mm fires `takeSwapped` only when mm:load receives a different take,
--     and always BEFORE its `reload` fire on that load.
--   * mm fires `reload` on every load, with no payload.
--   * tm forwards `takeSwapped` to its own subscribers and consumes the
--     flag transiently, calling tm:rebuild(true) on the next reload.
--   * tm fires `rebuild` (no payload) on every rebuild.
--   * The takeSwapped flag is one-shot: a subsequent same-take reload
--     does not re-fire takeSwapped and tm:rebuild sees takeChanged=false.

local t = require('support')
local harness = require('harness')

-- Records the sequence of signals fired on a single owner. Listener order
-- across owners is non-deterministic (set iteration), so each owner gets
-- its own stream and ordering assertions stay within one source.
local function recordOn(owner, signals)
  local stream = {}
  for _, sig in ipairs(signals) do
    owner:subscribe(sig, function() stream[#stream+1] = sig end)
  end
  return stream
end

return {
  {
    name = 'mm:load with a different take fires mm.takeSwapped before mm.reload',
    run = function()
      local h = harness.mk()
      local mmStream = recordOn(h.fm, { 'takeSwapped', 'reload' })
      local tmStream = recordOn(h.tm, { 'takeSwapped', 'rebuild' })

      h.fm:load('different-take')

      t.eq(table.concat(mmStream, ','), 'takeSwapped,reload',
        'mm fires takeSwapped before reload')
      t.eq(table.concat(tmStream, ','), 'takeSwapped,rebuild',
        'tm forwards takeSwapped before its own rebuild')
    end,
  },

  {
    name = 'mm:load with the same take fires reload only',
    run = function()
      local h = harness.mk()
      local mmStream = recordOn(h.fm, { 'takeSwapped', 'reload' })
      local tmStream = recordOn(h.tm, { 'takeSwapped', 'rebuild' })

      h.fm:load(h.fm:take())

      t.eq(table.concat(mmStream, ','), 'reload', 'no takeSwapped on same-take reload')
      t.eq(table.concat(tmStream, ','), 'rebuild', 'tm forwards reload→rebuild only')
    end,
  },

  {
    name = 'takeSwapped is one-shot: next same-take reload sees takeChanged=false',
    run = function()
      local h = harness.mk()
      -- Spy on tm:rebuild's argument by wrapping the method.
      local seen = {}
      local orig = h.tm.rebuild
      h.tm.rebuild = function(self, takeChanged)
        seen[#seen+1] = takeChanged or false
        return orig(self, takeChanged)
      end

      h.fm:load('different-take')   -- expect tm:rebuild(true)
      h.fm:load('different-take')   -- same take — expect tm:rebuild(false)

      t.eq(seen[1], true,  'first load saw takeChanged=true')
      t.eq(seen[2], false, 'second load saw takeChanged=false')
    end,
  },

  {
    -- Slice 2: consumers keep an incremental cache across a modify but must full-reload
    -- after a wholesale re-read. The payload's `wholesale` bit is that discriminator.
    name = 'mm.reload carries wholesale: true from load, false from modify',
    run = function()
      -- bareMM: no tm, so the only reloads are the ones this case drives. (Wired to tm, the foreign
      -- note below would draw a second reload as tm stamps it back through mm:modify.)
      local fm = harness.bareMM{ notes = { { ppq = 0, endppq = 240, chan = 3, pitch = 60, vel = 100 } } }
      local payloads = {}
      fm:subscribe('reload', function(data) payloads[#payloads+1] = data end)

      -- A foreign write behind mm's back, so load genuinely re-reads: re-reading replaces every event
      -- object, which is what wholesale announces. (A load finding the take unchanged gates -- below.)
      reaper.MIDI_InsertNote(fm:take(), false, false, 0, 240, 2, 64, 100, false)
      fm:load(fm:take())            -- full re-read of the take's events
      t.eq(#payloads, 1, 'load fired reload once')
      t.eq(payloads[1] and payloads[1].wholesale, true, 'load reload is wholesale')

      fm:modify(function() end)     -- in-place; a consumer's incremental cache stays valid
      t.eq(#payloads, 2, 'modify fired reload once')
      t.eq(payloads[2].wholesale, false, 'modify reload is not wholesale')
    end,
  },

  {
    name = 'tm.rebuild forwards takeChanged (so gm can reload take-tier state)',
    run = function()
      local h = harness.mk()
      local count, lastPayload = 0, 'unset'
      h.tm:subscribe('rebuild', function(data) count = count + 1; lastPayload = data end)
      h.fm:load('different-take')
      t.eq(count, 1, 'rebuild fired exactly once')
      t.eq(lastPayload, true, 'rebuild payload carries takeChanged from the take swap')
    end,
  },

  {
    name = 'multiple subscribers on the same signal both fire',
    run = function()
      local h = harness.mk()
      local a, b = 0, 0
      h.fm:subscribe('reload', function() a = a + 1 end)
      h.fm:subscribe('reload', function() b = b + 1 end)
      h.fm:load(h.fm:take())
      t.eq(a, 1)
      t.eq(b, 1)
    end,
  },

  {
    -- Dirt spine (design/archive/dirty-channels.md § Scheme): reload names channels touched.
    -- bareMM: no tm rebuild pipeline to fire follow-on reloads over the payload.
    name = 'mm.reload chans: an add marks only the touched channel',
    run = function()
      local fm = harness.bareMM()
      local last
      fm:subscribe('reload', function(data) last = data end)
      fm:modify(function()
        fm:add{ evType = 'note', ppq = 0, endppq = 240, chan = 3, pitch = 60, vel = 100 }
      end)
      t.eq(last.wholesale, false, 'modify reload is incremental')
      t.deepEq(last.chans, { [3] = true }, 'only chan 3 marked')
    end,
  },

  {
    name = 'mm.reload chans: an assign changing chan marks both old and new',
    run = function()
      local fm = harness.bareMM{ notes = { { ppq = 0, endppq = 240, chan = 3, pitch = 60, vel = 100 } } }
      local _, note = fm:notes()()
      local tok = fm:tokenOf(note)
      local last
      fm:subscribe('reload', function(data) last = data end)
      fm:modify(function() fm:assign(tok, { chan = 5 }) end)
      t.deepEq(last.chans, { [3] = true, [5] = true }, 'a chan move dirties both source and dest')
    end,
  },

  {
    name = 'mm.reload chans: a wholesale load carries no chans (nil = all 16)',
    run = function()
      local fm = harness.bareMM()
      local last
      fm:subscribe('reload', function(data) last = data end)
      reaper.MIDI_InsertNote(fm:take(), false, false, 0, 240, 2, 64, 100, false)   -- foreign write: a real re-read
      fm:load(fm:take())
      t.eq(last.wholesale, true, 'load is wholesale')
      t.eq(last.chans, nil, 'wholesale carries no per-chan set — tm reads nil as all 16')
    end,
  },

  {
    -- The converged-rebind gate (design/archive/incremental-rebuild.md § The take-hash gate): a load whose
    -- take still holds the bytes the model was built from re-reads nothing, so no event object is
    -- replaced -- not wholesale -- and no content moved, so no channel is dirty. tm carries its frame.
    name = 'mm.reload: a load finding the take converged gates — not wholesale, no dirty chans',
    run = function()
      local fm = harness.bareMM{ notes = { { ppq = 0, endppq = 240, chan = 3, pitch = 60, vel = 100 } } }
      local last
      fm:subscribe('reload', function(data) last = data end)
      fm:load(fm:take())
      t.eq(last.wholesale, false, 'the take is unchanged: nothing was re-parsed')
      t.deepEq(last.chans, {}, 'and nothing is dirty')
    end,
  },

  -- `flushed` = mm reprojected the take (a self-write). Consumers keying baselines
  -- off take content (the trackerPage watcher) resync on it instead of reading the
  -- write as an external mutation.
  {
    name = 'mm.flushed fires after reload on a structural modify, not on a clean one',
    run = function()
      local fm = harness.bareMM()
      local stream = recordOn(fm, { 'reload', 'flushed' })
      fm:modify(function() end)     -- clean: nothing structural, no reprojection
      t.eq(table.concat(stream, ','), 'reload', 'clean modify does not fire flushed')
      fm:modify(function()
        fm:add{ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 }
      end)
      t.eq(table.concat(stream, ','), 'reload,reload,flushed',
        'structural modify fires flushed after reload')
    end,
  },

  {
    name = 'mm.flushed fires on a load that reprojected the take, silent on the clean re-load',
    run = function()
      local h = harness.mk()
      -- Bare note, no sidecars: load mints a uuid, dirties, reprojects.
      h.reaper:seedMidi(h.fm:take(),
        { notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } } })
      local fired = 0
      h.fm:subscribe('flushed', function() fired = fired + 1 end)
      h.fm:load(h.fm:take())
      t.eq(fired, 1, 'normalising load fired flushed')
      h.fm:load(h.fm:take())        -- sidecars now present: clean read, no write
      t.eq(fired, 1, 'clean re-load did not fire flushed')
    end,
  },
}
