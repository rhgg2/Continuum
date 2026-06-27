-- generators.lua: carrier MSB allocation (unlikely-authored-first, 14-bit pair free;
-- see design/archive/note-macros.md § Delta-code allocation) and slide glide-in envelope.

local t = require('support')
local generators = require('generators')

local function occ(list)
  local s = {}
  for _, v in ipairs(list) do s[v] = true end
  return s
end

local function bandTaken(lo, hi)
  local s = {}
  for n = lo, hi do s[n] = true end
  return s
end

-- A slide host (pitch 60) and a ctx supplying the next same-lane note + pb ceiling.
local function slideCtx(nextNote, pbRangeCents)
  return { resolution = 240, pbRangeCents = pbRangeCents or 200,
           nextSameLaneNote = function() return nextNote end }
end
local function slideHost(detune)
  return { window = { 0, 240 }, events = { { pitch = 60, vel = 100, detune = detune or 0 } } }
end
local slideP = { kind = 'slide', over = { 1, 2 }, target = 'next' }

return {

  {
    name = 'an empty channel draws the coldest code first (20)',
    run = function()
      t.eq(generators.allocateCarrier({}), 20)
    end,
  },

  {
    name = 'a taken MSB code is skipped to the next priority code',
    run = function()
      t.eq(generators.allocateCarrier(occ{ 20 }), 21)
    end,
  },

  {
    name = 'a taken LSB partner (n+32) disqualifies the whole pair',
    run = function()
      -- 52 = 20+32, so the (20,52) pair is unusable; 21 is the next free pair.
      t.eq(generators.allocateCarrier(occ{ 52 }), 21)
    end,
  },

  {
    name = 'the cold band exhausted falls through to the next undefined code (3)',
    run = function()
      t.eq(generators.allocateCarrier(bandTaken(20, 31)), 3)
    end,
  },

  {
    name = 'conventional codes are the last resort -- bank-select (0) is the final pick',
    run = function()
      local taken = bandTaken(0, 63)
      taken[0], taken[32] = nil, nil   -- free only the (0,32) pair
      t.eq(generators.allocateCarrier(taken), 0)
    end,
  },

  {
    name = 'a saturated band returns nil',
    run = function()
      t.eq(generators.allocateCarrier(bandTaken(0, 63)), nil)
    end,
  },

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
    name = 'trill tiles the window, alternating host pitch with the stepped note (host is fxNote 1)',
    run = function()
      local seen
      local ctx = { resolution = 240,
                    step = function(p, d, n) seen = { p, d, n }; return p + n, (d or 0) + 7 end }
      local host = { window = { 0, 240 }, events = { { pitch = 60, vel = 100, detune = 0 } } }
      local out = generators.kinds.trill.expand(host, { kind = 'trill', period = { 1, 4 }, step = 2 }, ctx)
      t.eq(#out.delta, 0, 'structural: no continuous delta')
      t.deepEq(seen, { 60, 0, 2 }, 'ctx.step receives the host pitch, detune, and step count')
      t.eq(#out.notes, 3, '1/4-QN period over a 1-QN window: 3 fxNotes (host is fxNote 1)')
      local n = out.notes
      t.deepEq({ n[1].ppqL, n[2].ppqL, n[3].ppqL }, { 60, 120, 180 }, 'tiled onsets')
      t.deepEq({ n[1].endppqL, n[2].endppqL, n[3].endppqL }, { 120, 180, 240 }, 'tails clip to next / window end')
      t.deepEq({ n[1].pitch, n[2].pitch, n[3].pitch }, { 62, 60, 62 }, 'odd tiles step; even tiles return to host')
      t.deepEq({ n[1].detune, n[2].detune, n[3].detune }, { 7, 0, 7 }, 'stepped detune on odd; host detune on even')
      t.eq(n[1].vel, 100, 'host velocity carried (no ramp)')
    end,
  },

  {
    name = 'trill carries host detune verbatim on the return (even) tiles',
    run = function()
      local ctx = { resolution = 240, step = function(p, d, n) return p + n, 99 end }
      local host = { window = { 0, 240 }, events = { { pitch = 60, vel = 80, detune = 12 } } }
      local out = generators.kinds.trill.expand(host, { kind = 'trill', period = { 1, 4 }, step = 1 }, ctx)
      t.eq(out.notes[2].detune, 12, 'even tile inherits the host detune')
      t.eq(out.notes[1].detune, 99, 'odd tile takes the stepped detune')
    end,
  },

}
