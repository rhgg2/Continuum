-- generators.lua: slide glide-in envelope.

local t = require('support')
local generators = require('generators')

-- A slide host (pitch 60) and a ctx supplying the next same-lane note + pb ceiling.
local function slideCtx(nextNote, pbRangeCents)
  return { resolution = 240, pbRangeCents = pbRangeCents or 200,
           nextSameLaneNote = function() return nextNote end }
end
local function slideHost(detune)
  return { window = { 0, 240 }, notes = { { pitch = 60, vel = 100, detune = detune or 0 } } }
end
local slideP = { kind = 'slide', over = { 1, 2 }, target = 'next' }

return {

  ----- slide: glide-in envelope

  {
    name = 'slide glides in: flat hold, slur to the interval, re-centre at the window end',
    run = function()
      -- res 240, over 1/2 QN: snap 15 -> arrive 225, glideStart 225-120 = 105.
      local out = generators.kinds.slide.expand(slideHost(), slideP, slideCtx{ pitch = 62, detune = 0 })
      local d = out.delta
      t.eq(#out.notes, 0, 'continuous: no structural notes')
      t.eq(d[1].ppqL, 0);   t.eq(d[1].val, 0, 'starts flat at centre')
      t.eq(d[2].ppqL, 105); t.eq(d[2].val, 0, 'slur begins after the flat hold')
      t.eq(d[2].shape, 'slow', 'slur eases (slow / half-cosine)')
      t.eq(d[3].ppqL, 225); t.eq(d[3].val, 200, 'arrives at the +200c interval before the handoff')
      t.eq(d[4].ppqL, 240); t.eq(d[4].val, 0, 're-centres at the handoff -- next note sounds true')
    end,
  },

  {
    name = 'slide interval includes detune (the microtonal offset rides in detune, not pitch)',
    run = function()
      local out = generators.kinds.slide.expand(slideHost(0), slideP, slideCtx{ pitch = 60, detune = 50 })
      t.eq(out.delta[3].val, 50, 'a same-pitch note 50c sharp yields a 50c slide')
    end,
  },

  {
    name = 'slide clamps the target to ctx.pbRangeCents (a pb can only bend so far)',
    run = function()
      local out = generators.kinds.slide.expand(slideHost(), slideP, slideCtx({ pitch = 72 }, 200))
      t.eq(out.delta[3].val, 200, 'a 1200c interval clamps to the 200c pb ceiling')
    end,
  },

  {
    name = "slide.target='fixed' is a fixed-cents bend (cents demand, no next-note lookup)",
    run = function()
      local out = generators.kinds.slide.expand(slideHost(), { kind = 'slide', over = { 1, 2 }, target = 'fixed', cents = 150 },
                                   slideCtx(nil))
      t.eq(out.delta[3].val, 150, 'fixed cents ignores the next-note resolution')
    end,
  },

  {
    name = "slide.target='next' with no following note yields no delta (carrier untouched)",
    run = function()
      local out = generators.kinds.slide.expand(slideHost(), slideP, slideCtx(nil))
      t.eq(#out.delta, 0, 'no next note: nothing to slide to')
    end,
  },

  {
    name = 'slide to a unison next note yields no delta (zero interval)',
    run = function()
      local out = generators.kinds.slide.expand(slideHost(), slideP, slideCtx{ pitch = 60, detune = 0 })
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
      local out = generators.kinds.trill.expand(host, { kind = 'trill', period = { 1, 4 }, step = 2 }, ctx)
      t.eq(#out.delta, 0, 'structural: no continuous delta')
      t.deepEq(seen, { 60, 0, 2 }, 'ctx.step receives the host pitch, detune, and step count')
      t.eq(#out.notes, 4, '1/4-QN period over a 1-QN window: 4 fxNotes (all hits derived)')
      local n = out.notes
      t.deepEq({ n[1].ppqL, n[2].ppqL, n[3].ppqL, n[4].ppqL }, { 0, 60, 120, 180 }, 'tiled onsets from the window start')
      t.deepEq({ n[1].endppqL, n[2].endppqL, n[3].endppqL, n[4].endppqL }, { 60, 120, 180, 240 }, 'tails clip to next / window end')
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
      local out = generators.kinds.trill.expand(host, { kind = 'trill', period = { 1, 4 }, step = 1 }, ctx)
      t.eq(out.notes[1].detune, 12, 'even tile inherits the host detune')
      t.eq(out.notes[2].detune, 99, 'odd tile takes the stepped detune')
    end,
  },

  ----- park predicate + windows: the single source for "what 4.5 parks over"

  {
    name = 'parksNotes is true for a discrete-replace kind, false for augment / husk',
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
      local out = generators.kinds.autopan.expand({ window = { 0, 240 } },
                    { kind = 'autopan', period = { 1, 2 }, depth = 32 }, { resolution = 240 })
      t.eq(#out.notes, 0, 'continuous: no structural notes')
      local d = out.delta
      t.eq(d[1].ppqL, 0);    t.eq(d[1].val, 0,   'anchored at centre (0) at the window start')
      t.eq(d[2].ppqL, 30);   t.eq(d[2].val, 32,  'first extreme is +depth cc steps')
      t.eq(d[3].ppqL, 90);   t.eq(d[3].val, -32, 'next extreme is -depth')
      t.eq(d[2].shape, 'slow', 'extrema bridged by slow (half-cosine)')
      t.eq(d[#d].ppqL, 240); t.eq(d[#d].val, 0,  're-centres to 0 at the window end')
    end,
  },

}
