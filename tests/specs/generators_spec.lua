-- generators.lua: slide glide-in envelope.

local t = require('support')
local util = require('util')
local generators = require('generators')

-- Kinds run alone here, so the chain state equals the original: stream == host (the chain head).
local function expand(kind, hostRec, params, ctx)
  return generators.kinds[kind].expand(hostRec, hostRec, params, ctx)
end

-- A slide host (pitch 60) and a ctx supplying the next same-lane note + pb ceiling.
local function slideCtx(nextNote, pbRangeCents)
  return { resolution = 240, pbRangeCents = pbRangeCents or 200,
           nextSameLaneNote = function() return nextNote end }
end
local function slideHost(detune)
  return { window = { 0, 240 }, notes = { { pitch = 60, vel = 100, detune = detune or 0 } } }
end
local slideP = { kind = 'slide', over = { 1, 2 }, target = 'next' }

-- A loop-closed triangle in the normalized domain (-1 .. +1 .. -1), one QN long.
local function triangle()
  return { kind = 'curve', domain = 'normalized', lengthPpq = 240, points = {
    { ppq = 0,   val = -1, shape = 'linear' }, { ppq = 60,  val = 0, shape = 'linear' },
    { ppq = 120, val = 1,  shape = 'linear' }, { ppq = 180, val = 0, shape = 'linear' },
    { ppq = 240, val = -1, shape = 'linear' },
  } }
end

return {

  ----- slide: glide-in envelope

  {
    name = 'slide glides in: flat hold, slur to the interval, re-centre at the window end',
    run = function()
      -- res 240, over 1/2 QN: snap 15 -> arrive 225, glideStart 225-120 = 105.
      local out = expand('slide', slideHost(), slideP, slideCtx{ pitch = 62, detune = 0 })
      local d = out.delta
      t.eq(#out.notes, 0, 'continuous: no structural notes')
      t.eq(d[1].ppq, 0);   t.eq(d[1].val, 0, 'starts flat at centre')
      t.eq(d[2].ppq, 105); t.eq(d[2].val, 0, 'slur begins after the flat hold')
      t.eq(d[2].shape, 'slow', 'slur eases (slow / half-cosine)')
      t.eq(d[3].ppq, 225); t.eq(d[3].val, 200, 'arrives at the +200c interval before the handoff')
      t.eq(d[4].ppq, 240); t.eq(d[4].val, 0, 're-centres at the handoff -- next note sounds true')
    end,
  },

  {
    name = 'slide interval includes detune (the microtonal offset rides in detune, not pitch)',
    run = function()
      local out = expand('slide', slideHost(0), slideP, slideCtx{ pitch = 60, detune = 50 })
      t.eq(out.delta[3].val, 50, 'a same-pitch note 50c sharp yields a 50c slide')
    end,
  },

  {
    name = 'slide clamps the target to ctx.pbRangeCents (a pb can only bend so far)',
    run = function()
      local out = expand('slide', slideHost(), slideP, slideCtx({ pitch = 72 }, 200))
      t.eq(out.delta[3].val, 200, 'a 1200c interval clamps to the 200c pb ceiling')
    end,
  },

  {
    name = "slide.target='fixed' is a fixed-cents bend (cents demand, no next-note lookup)",
    run = function()
      local out = expand('slide', slideHost(), { kind = 'slide', over = { 1, 2 }, target = 'fixed', cents = 150 },
                         slideCtx(nil))
      t.eq(out.delta[3].val, 150, 'fixed cents ignores the next-note resolution')
    end,
  },

  {
    name = "slide.target='next' with no following note yields no delta (carrier untouched)",
    run = function()
      local out = expand('slide', slideHost(), slideP, slideCtx(nil))
      t.eq(#out.delta, 0, 'no next note: nothing to slide to')
    end,
  },

  {
    name = 'slide to a unison next note yields no delta (zero interval)',
    run = function()
      local out = expand('slide', slideHost(), slideP, slideCtx{ pitch = 60, detune = 0 })
      t.eq(#out.delta, 0, 'gliding to the same pitch is a no-op')
    end,
  },

  ----- trill: window tiling + temper-resolved alternation

  {
    name = 'trill tiles the window from its start, alternating host pitch with the stepped note',
    run = function()
      local seen
      local ctx = { resolution = 240,
                    step = function(p, d, n) seen = { p, d, n }; return p + n, (d or 0) + 7 end }
      local host = { window = { 0, 240 }, notes = { { pitch = 60, vel = 100, detune = 0 } } }
      local out = expand('trill', host, { kind = 'trill', period = { 1, 4 }, step = 2 }, ctx)
      t.eq(#out.delta, 0, 'structural: no continuous delta')
      t.deepEq(seen, { 60, 0, 2 }, 'ctx.step receives the host pitch, detune, and step count')
      t.eq(#out.notes, 4, '1/4-QN period over a 1-QN window: 4 fxNotes (all hits derived)')
      local n = out.notes
      t.deepEq({ n[1].ppq, n[2].ppq, n[3].ppq, n[4].ppq }, { 0, 60, 120, 180 }, 'tiled onsets from the window start')
      t.deepEq({ n[1].endppq, n[2].endppq, n[3].endppq, n[4].endppq }, { 60, 120, 180, 240 }, 'tails clip to next / window end')
      t.deepEq({ n[1].pitch, n[2].pitch, n[3].pitch, n[4].pitch }, { 60, 62, 60, 62 }, 'even tiles carry the host pitch; odd tiles step')
      t.deepEq({ n[1].detune, n[2].detune, n[3].detune, n[4].detune }, { 0, 7, 0, 7 }, 'host detune on even; stepped detune on odd')
      t.eq(n[2].vel, 100, 'host velocity carried (no ramp)')
    end,
  },

  {
    name = 'trill carries host detune verbatim on the return (even) tiles',
    run = function()
      local ctx = { resolution = 240, step = function(p, d, n) return p + n, 99 end }
      local host = { window = { 0, 240 }, notes = { { pitch = 60, vel = 80, detune = 12 } } }
      local out = expand('trill', host, { kind = 'trill', period = { 1, 4 }, step = 1 }, ctx)
      t.eq(out.notes[1].detune, 12, 'even tile inherits the host detune')
      t.eq(out.notes[2].detune, 99, 'odd tile takes the stepped detune')
    end,
  },

  ----- park predicate + windows: the single source for "what 4.5 parks over"

  {
    name = 'parksNotes is true for any note-dest kind, false for a continuous kind / husk',
    run = function()
      t.eq(generators.parksNotes{ fx = { { kind = 'retrig' } } }, true,  'retrig replaces notes')
      t.eq(generators.parksNotes{ fx = { { kind = 'vibrato' } } }, false, 'vibrato augments pb')
      t.eq(generators.parksNotes{ fx = {} }, false, 'a husk parks nothing')
    end,
  },

  {
    name = 'parkWindows emits an evType-tagged window per continuous/replace target (note discrete, cc, pb augment)',
    run = function()
      generators.kinds.ccrep = { mode = 'replace', dest = 10 }   -- fixture: no built-in cc-replace kind
      local windows = generators.parkWindows{
        { chan = 1, startppq = 0,  endppq = 240, fx = { { kind = 'arp' } } },     -- discrete replace -> note window
        { chan = 3, startppq = 60, endppq = 120, fx = { { kind = 'ccrep' } } },   -- cc target (replace) -> cc window
        { chan = 5, startppq = 0,  endppq = 240, fx = { { kind = 'vibrato' } } }, -- pb augment -> pb window
        { chan = 7, fx = {} },                                                    -- husk -> neither
      }
      generators.kinds.ccrep = nil
      t.deepEq(windows, {
        { evType = 'note', chan = 1, startppq = 0, endppq = 240 },
        { evType = 'cc', chan = 3, cc = 10, startppq = 60, endppq = 120 },
        { evType = 'pb', chan = 5, startppq = 0, endppq = 240 },
      }, 'note for the discrete chord, cc for the cc target, pb for the augment gesture')
    end,
  },

  ----- autopan: a cc-dest sine LFO (vibrato's shape, cc steps not cents)

  {
    name = 'autopan tiles the window with sine extrema in cc steps, anchored 0 at both ends',
    run = function()
      -- res 240, period 1/2 QN -> cycle 120 ticks; extrema at period/4 = 30, then every 60.
      local out = expand('autopan', { window = { 0, 240 } },
                         { kind = 'autopan', period = { 1, 2 }, depth = 32 }, { resolution = 240 })
      t.eq(#out.notes, 0, 'continuous: no structural notes')
      local d = out.delta
      t.eq(d[1].ppq, 0);    t.eq(d[1].val, 0,   'anchored at centre (0) at the window start')
      t.eq(d[2].ppq, 30);   t.eq(d[2].val, 32,  'first extreme is +depth cc steps')
      t.eq(d[3].ppq, 90);   t.eq(d[3].val, -32, 'next extreme is -depth')
      t.eq(d[2].shape, 'slow', 'extrema bridged by slow (half-cosine)')
      t.eq(d[#d].ppq, 240); t.eq(d[#d].val, 0,  're-centres to 0 at the window end')
    end,
  },

  ----- velPattern: a transformer -- reads the note stream, rewrites velocities

  {
    name = 'velPattern cycles its percent pattern per distinct onset; a chord shares one step',
    run = function()
      local stream = { window = { 0, 240 }, notes = {
        { pitch = 60, vel = 100, detune = 0, ppq = 0,   endppq = 60 },
        { pitch = 64, vel = 100, detune = 0, ppq = 0,   endppq = 60 },    -- chord mate: same step
        { pitch = 60, vel = 100, detune = 0, ppq = 60,  endppq = 120 },
        { pitch = 60, vel = 100, detune = 0, ppq = 120, endppq = 180 },
      } }
      local out = expand('velPattern', stream, { kind = 'velPattern', pattern = { 100, 50 } }, {})
      t.eq(#out.delta, 0, 'structural: no continuous delta')
      local vels = {}
      for i, n in ipairs(out.notes) do vels[i] = n.vel end
      t.deepEq(vels, { 100, 100, 50, 100 }, 'the chord shares step 1; later onsets cycle 50/100')
      t.eq(out.notes[2].pitch, 64, 'every other field carries verbatim')
      t.eq(stream.notes[3].vel, 100, 'the input stream is not mutated -- stages emit new events')
    end,
  },

  {
    name = 'velPattern walks onset order regardless of input order, clamping vel to 1..127',
    run = function()
      local stream = { window = { 0, 240 }, notes = {
        { pitch = 60, vel = 100, detune = 0, ppq = 120, endppq = 180 },   -- listed out of order
        { pitch = 60, vel = 100, detune = 0, ppq = 0,   endppq = 60 },
      } }
      local out = expand('velPattern', stream, { kind = 'velPattern', pattern = { 140, 0 } }, {})
      t.deepEq({ out.notes[1].ppq, out.notes[2].ppq }, { 0, 120 }, 'ordered by onset, not input order')
      t.eq(out.notes[1].vel, 127, '140% of 100 clamps to 127')
      t.eq(out.notes[2].vel, 1,   '0% clamps up to the audible floor')
    end,
  },

  ----- Ostinato: gate the sounding region notes; pattern supplies onset/dur/vel, each voice its pitch

  {
    name = 'ostinato tracks the sounding pitch across the region, not just the first note',
    run = function()
      local host = { window = { 0, 480 }, notes = {
        { pitch = 60, vel = 100, detune = 0, ppq = 0,   endppq = 240 },
        { pitch = 67, vel = 100, detune = 0, ppq = 240, endppq = 480 },
      } }
      local pattern = { kind = 'notes', lengthPpq = 240, specs = { { ppq = 0, endppq = 60, vel = 90 } } }
      local out = expand('ostinato', host, { kind = 'ostinato', pattern = pattern }, {})
      t.eq(#out.notes, 2, 'one gate per loop over a two-loop window')
      t.deepEq({ out.notes[1].pitch, out.notes[2].pitch }, { 60, 67 },
        'each gate takes the pitch sounding at its onset -- pitch changes are followed')
      t.eq(out.notes[1].vel, 90, 'velocity comes from the pattern spec, not the host note')
    end,
  },

  {
    name = 'ostinato rests when no region note sounds at the gate onset',
    run = function()
      local host = { window = { 0, 480 }, notes = {
        { pitch = 60, vel = 100, detune = 0, ppq = 0, endppq = 240 },
      } }
      local pattern = { kind = 'notes', lengthPpq = 240, specs = { { ppq = 0, endppq = 60, vel = 100 } } }
      local out = expand('ostinato', host, { kind = 'ostinato', pattern = pattern }, {})
      t.eq(#out.notes, 1, 'the second loop gate falls in the gap -> rest, no note')
      t.eq(out.notes[1].ppq, 0, 'only the gate over the sounding note emits')
    end,
  },

  {
    name = 'ostinato emits one gated note per sounding voice (a chord -> multiple lanes)',
    run = function()
      local host = { window = { 0, 240 }, notes = {
        { pitch = 60, vel = 100, detune = 0,  ppq = 0, endppq = 240 },
        { pitch = 64, vel = 100, detune = 25, ppq = 0, endppq = 240 },
      } }
      local pattern = { kind = 'notes', lengthPpq = 240, specs = { { ppq = 0, endppq = 60, vel = 80 } } }
      local out = expand('ostinato', host, { kind = 'ostinato', pattern = pattern }, {})
      t.eq(#out.notes, 2, 'both voices gate at the onset')
      t.deepEq({ out.notes[1].pitch, out.notes[2].pitch }, { 60, 64 }, 'ascending by pitch')
      t.eq(out.notes[2].detune, 25, 'detune rides the voice, not the pattern')
    end,
  },

  ----- lfo: tile a normalized curve onto an absolute cc via centre + scale

  {
    name = 'lfo tiles the curve at 1/period QN, mapping each val by centre + scale, edges seeded',
    run = function()
      -- res 240, period 1 QN -> 240-tick cycle == lengthPpq (stretch 1); window is two cycles.
      local out = expand('lfo', { window = { 0, 480 } },
        { kind = 'lfo', period = { 1, 1 }, centre = 64, scale = 63, pattern = triangle() },
        { resolution = 240 })
      t.eq(#out.notes, 0, 'continuous: no structural notes')
      local d = out.delta
      t.eq(d[1].ppq, 0);      t.eq(d[1].val, 1,   'start seed maps norm -1 -> centre-scale (1)')
      t.eq(d[#d].ppq, 480);   t.eq(d[#d].val, 1,  'end seed closes the loop back to the start value')
      local peaks, mid = 0, {}
      for _, bp in ipairs(d) do
        if bp.val == 127 then peaks = peaks + 1 end   -- norm +1 -> centre+scale, at ppq 120 & 360
        if bp.val == 64  then mid[#mid + 1] = bp.ppq end
      end
      t.eq(peaks, 2, 'the +1 apex recurs once per tiled cycle')
      t.truthy(#mid >= 2, 'the norm-0 midpoints land on centre (64)')
    end,
  },

  {
    name = 'lfo clamps centre +/- scale to 0..127',
    run = function()
      local out = expand('lfo', { window = { 0, 240 } },
        { kind = 'lfo', period = { 1, 1 }, centre = 64, scale = 100, pattern = triangle() },
        { resolution = 240 })
      t.eq(out.delta[1].val, 0, 'centre 64 - scale 100 clamps up to 0')
      local sawHi = false
      for _, bp in ipairs(out.delta) do if bp.val == 127 then sawHi = true end end
      t.truthy(sawHi, 'centre 64 + scale 100 clamps down to 127')
    end,
  },

  {
    name = 'lfo with an empty or lengthless curve is inert (no delta)',
    run = function()
      local base = { kind = 'lfo', period = { 1, 1 }, centre = 64, scale = 63 }
      local empty = expand('lfo', { window = { 0, 240 } },
        util.assign({}, base, { pattern = { kind = 'curve', lengthPpq = 240, points = {} } }), { resolution = 240 })
      t.eq(#empty.delta, 0, 'no points -> nothing to emit')
      local lengthless = expand('lfo', { window = { 0, 240 } },
        util.assign({}, base, { pattern = { kind = 'curve', points = { { ppq = 0, val = 0 } } } }), { resolution = 240 })
      t.eq(#lengthless.delta, 0, 'no lengthPpq -> no cycle to tile')
    end,
  },

}
