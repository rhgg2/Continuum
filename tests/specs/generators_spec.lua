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

-- Curve points positionally: {ppq, val, shape?, tension?}; shape defaults to linear, the one kind
-- thinCurve is allowed to drop.
local function pts(rows)
  local out = {}
  for i, r in ipairs(rows) do
    out[i] = { ppq = r[1], val = r[2], shape = r[3] or 'linear', tension = r[4] }
  end
  return out
end

return {

  ----- The glyph vocabulary: the fx column's one-character badge per kind

  {
    name = 'every registered kind carries a glyph, one codepoint, shared with no other kind',
    run = function()
      local seen = {}
      for kind, meta in pairs(generators.kinds) do
        t.truthy(meta.glyph, kind .. ' carries a glyph')
        t.eq(utf8.len(meta.glyph), 1, kind .. "'s glyph is one codepoint -- the fx column is one cell wide")
        t.falsy(seen[meta.glyph], ('%s cannot share a glyph with %s'):format(kind, tostring(seen[meta.glyph])))
        seen[meta.glyph] = kind
      end
    end,
  },

  {
    name = 'glyphOf resolves off the registry, and falls back for a kind the registry has lost',
    run = function()
      t.eq(generators.glyphOf('sine'), '∿', 'a registered kind draws as its own glyph')
      t.eq(generators.glyphOf('nosuchkind'), '?', 'an unregistered kind draws as unknown')
    end,
  },

  {
    name = 'labelOf resolves off the registry, and keeps a lost kind\'s name in the mark',
    run = function()
      t.eq(generators.labelOf('sine'), generators.kinds.sine.label, 'a registered kind reads its own label')
      t.eq(generators.labelOf('nosuchkind'), '? nosuchkind',
           'a lost kind says which stage went missing, where a bare ? would not')
    end,
  },

  {
    name = 'fieldsFor gives a lost kind no rows',
    run = function()
      t.eq(#generators.fieldsFor{ kind = 'nosuchkind' }, 0,
           'the fields were declared on the registry entry, so a kind without one has none')
    end,
  },

  ----- slide: glide-in envelope

  {
    name = 'slide glides in: flat hold, slur to the interval, then hand off to tm\'s close',
    run = function()
      -- res 240, over 1/2 QN: snap 15 -> arrive 225, glideStart 225-120 = 105.
      local out = expand('slide', slideHost(), slideP, slideCtx{ pitch = 62, detune = 0 })
      local d = out.delta
      t.eq(#out.notes, 0, 'continuous: no structural notes')
      t.eq(d[1].ppq, 0);   t.eq(d[1].val, 0, 'starts flat at centre')
      t.eq(d[2].ppq, 105); t.eq(d[2].val, 0, 'slur begins after the flat hold')
      t.eq(d[2].shape, 'slow', 'slur eases (slow / half-cosine)')
      t.eq(d[3].ppq, 225); t.eq(d[3].val, 200, 'arrives at the +200c interval before the handoff')
      t.eq(#d, 3, 'and stops -- tm closes the window, so the generator authors no handoff of its own')
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

  ----- trill: window tiling + a cents alternation

  {
    name = 'trill tiles the window from its start, alternating host pitch with the cents demand',
    run = function()
      local ctx = { resolution = 240 }
      local host = { window = { 0, 240 }, notes = { { pitch = 60, vel = 100, detune = 0 } } }
      local out = expand('trill', host, { kind = 'trill', period = { 1, 4 }, cents = 200 }, ctx)
      t.eq(#out.delta, 0, 'structural: no continuous delta')
      t.eq(#out.notes, 4, '1/4-QN period over a 1-QN window: 4 fxNotes (all hits derived)')
      local n = out.notes
      t.deepEq({ n[1].ppq, n[2].ppq, n[3].ppq, n[4].ppq }, { 0, 60, 120, 180 }, 'tiled onsets from the window start')
      t.deepEq({ n[1].endppq, n[2].endppq, n[3].endppq, n[4].endppq }, { 60, 120, 180, 240 }, 'tails clip to next / window end')
      t.deepEq({ n[1].pitch, n[2].pitch, n[3].pitch, n[4].pitch }, { 60, 62, 60, 62 }, 'even tiles carry the host pitch; odd tiles the demand')
      t.deepEq({ n[1].detune, n[2].detune, n[3].detune, n[4].detune }, { 0, 0, 0, 0 }, 'a whole-semitone demand places with no detune')
      t.eq(n[2].vel, 100, 'host velocity carried (no ramp)')
    end,
  },

  {
    name = 'trill measures its demand from what the host sounds, detune and all',
    run = function()
      local ctx = { resolution = 240 }
      local host = { window = { 0, 240 }, notes = { { pitch = 60, vel = 80, detune = 12 } } }
      local out = expand('trill', host, { kind = 'trill', period = { 1, 4 }, cents = 130 }, ctx)
      t.eq(out.notes[1].detune, 12, 'even tile inherits the host detune')
      t.eq(out.notes[2].pitch, 61, 'the odd tile places 6142 cents on the nearest pitch')
      t.eq(out.notes[2].detune, 42, 'and carries the remainder as detune')
    end,
  },

  {
    name = 'a trill\'s tiles each name a step of their own -- the host\'s, and the demand above it',
    run = function()
      local ctx = { resolution = 240 }
      -- Written C, sounding 60 cents sharp of it, where a solve left it.
      local host = { window = { 0, 240 }, notes = {
        { pitch = 60, vel = 100, detune = 60, intentCents = 6000 },
      } }
      local out = expand('trill', host, { kind = 'trill', period = { 1, 4 }, cents = 200 }, ctx)
      local n = out.notes
      t.deepEq({ n[1].intentCents, n[2].intentCents, n[3].intentCents, n[4].intentCents },
        { 6000, 6200, 6000, 6200 },
        'the even tiles keep the host\'s written step; the odd ones stand a whole tone above it')
    end,
  },

  {
    name = 'a trill off a host with no intent derives none -- the field stays sparse',
    run = function()
      local ctx = { resolution = 240 }
      local host = { window = { 0, 240 }, notes = { { pitch = 60, vel = 100, detune = 0 } } }
      local out = expand('trill', host, { kind = 'trill', period = { 1, 4 }, cents = 200 }, ctx)
      t.eq(out.notes[1].intentCents, nil, 'nothing to inherit, so nothing stored')
      t.eq(out.notes[2].intentCents, nil, 'and the alternation reads as it sounds')
    end,
  },

  ----- park predicate + windows: the single source for "what 4.5 parks over"

  {
    name = 'parksNotes is true for any note-dest kind, false for a continuous kind / husk',
    run = function()
      t.eq(generators.parksNotes{ fx = { { kind = 'retrig' } } }, true,  'retrig replaces notes')
      t.eq(generators.parksNotes{ fx = { { kind = 'sine' } } }, false, 'sine augments pb')
      t.eq(generators.parksNotes{ fx = {} }, false, 'a husk parks nothing')
    end,
  },

  {
    name = 'parkWindows emits an evType-tagged window per continuous/replace target (note discrete, cc, pb augment)',
    run = function()
      generators.kinds.ccrep = { mode = 'replace', dest = 10 }   -- fixture: no built-in cc-replace kind
      local windows = generators.parkWindows{
        { chan = 1, startppq = 0,  endppq = 240, uuid = 'chord', fx = { { kind = 'arp' } } },   -- discrete replace -> note window
        { chan = 3, startppq = 60, endppq = 120, uuid = 'rep',   fx = { { kind = 'ccrep' } } }, -- cc target (replace) -> cc window
        { chan = 5, startppq = 0,  endppq = 240, uuid = 'wave',  fx = { { kind = 'sine' } } },  -- pb augment -> pb window
        { chan = 7, fx = {} },                                                                  -- husk -> neither
      }
      generators.kinds.ccrep = nil
      t.deepEq(windows, {
        { evType = 'note', chan = 1, id = 'chord', startppq = 0, endppq = 240 },
        { evType = 'cc', chan = 3, cc = 10, id = 'rep', startppq = 60, endppq = 120 },
        { evType = 'pb', chan = 5, id = 'wave', startppq = 0, endppq = 240 },
      }, 'note for the discrete chord, cc for the cc target, pb for the augment gesture')
    end,
  },

  {
    name = 'the ownership predicates ignore bypass: a bypassed chain still parks and still scopes its target',
    run = function()
      t.eq(generators.parksNotes{ fx = { { kind = 'arp', bypass = true } } }, true,
        'bypass changes the realisation, never the authored notes -- the chord stays parked')
      t.deepEq(generators.parkWindows{
        { chan = 1, startppq = 0, endppq = 240, uuid = 'chord', fx = { { kind = 'arp', bypass = true } } },
      }, { { evType = 'note', chan = 1, id = 'chord', startppq = 0, endppq = 240 } },
        'the window stands: the chain re-seats the parked chord verbatim')
      t.deepEq(generators.continuousTargets{ { kind = 'sine', bypass = true } }, { pb = true },
        'a bypassed chain still emits a re-seat record, so the dirt gate must keep scoping the target')
    end,
  },

  {
    name = 'chainDestType demotes a bypassed replace stage to augment, and only that stage',
    run = function()
      generators.kinds.pbrep = { mode = 'replace', dest = 'pb' }   -- fixture: the built-in pb kinds all augment
      t.eq(generators.chainDestType({ { kind = 'pbrep' } }, 'pb'), 'replace',
        'a live replace stage sets the chain mode')
      t.eq(generators.chainDestType({ { kind = 'pbrep', bypass = true } }, 'pb'), 'augment',
        'bypassed it has nothing to say -- an augment record folds as a zero delta instead of painting the base')
      t.eq(generators.chainDestType({ { kind = 'pbrep', bypass = true }, { kind = 'pbrep' } }, 'pb'), 'replace',
        'one live replace stage still claims the chain: the demotion is per stage, not per chain')
      generators.kinds.pbrep = nil
    end,
  },

  ----- dest: a per-entry target, and what each target's numbers mean

  {
    name = 'destOf falls back to the registry dest; a dest param overrides it',
    run = function()
      t.eq(generators.destOf{ kind = 'sine' }, 'pb', 'no param: the kind seeds the dest')
      t.eq(generators.destOf{ kind = 'sine', dest = 74 }, 74, 'the param wins')
      t.eq(generators.destOf{ kind = 'retrig' }, 'note', 'note kinds resolve through the same door')
    end,
  },

  {
    name = 'fieldsFor prepends a Dest row only where the kind can serve more than one target',
    run = function()
      local wave = generators.fieldsFor{ kind = 'sine' }
      t.eq(wave[1].field, 'dest', "an any-dest kind's 129 targets earn a Dest row")
      t.eq(wave[1].widget, 'dest', 'drawn by the dest picker, not a stepper')
      t.eq(#wave, #generators.kinds.sine.fields + 1, "the kind's own fields follow it")
      t.eq(generators.fieldsFor{ kind = 'retrig' }[1].field, 'period', 'a note kind declares no dests -- no row')
      t.eq(generators.fieldsFor{ kind = 'slide' }[1].field, 'over', 'pb-bound: one option is no choice')
    end,
  },

  {
    name = 'retarget between dests of equal reference leaves the magnitudes alone',
    run = function()
      local out = generators.retarget({ kind = 'sine', period = { 1, 2 }, depth = 32, dest = 10 }, 8)
      t.eq(out.dest, 8, 'the entry points at the new controller')
      t.eq(out.depth, 32, 'pan and balance both rest at 64 -- the same 63-step swing, nothing to rescale')
    end,
  },

  {
    name = 'retarget rescales magnitudes by proportion of the dest reference',
    run = function()
      local toPan = generators.retarget({ kind = 'sine', period = { 1, 2 }, depth = 30, onset = 1 }, 10)
      t.eq(toPan.depth, 9, '30 of pb\'s 200-cent reference -> 9 of pan\'s 63 steps')
      local toMod = generators.retarget({ kind = 'sine', period = { 1, 2 }, depth = 32, dest = 10 }, 1)
      t.eq(toMod.depth, 65, 'the mod wheel rests at a rail: 32 of 63 -> 65 of its whole 127 run')
    end,
  },

  {
    name = 'fieldRange spans both ways for a signed magnitude, one way for an unsigned one',
    run = function()
      local lo, hi = generators.fieldRange({ quantity = 'magnitude', signed = true }, 10)
      t.eq(lo, -63, 'signed: as far below rest as above')
      t.eq(hi, 63,  'and no further either way than the dest swings')
      t.eq(generators.fieldRange({ quantity = 'magnitude' }, 10), 0, 'unsigned: a span, starting at nothing')
    end,
  },

  {
    name = 'retarget carries a signed magnitude across with its sign intact',
    run = function()
      local toPan = generators.retarget({ kind = 'lfo', scale = 100 }, 10)
      t.eq(toPan.scale, 32, "100 of pb's 200-cent reference -> 32 of pan's 63 steps")
      local mirrored = generators.retarget({ kind = 'lfo', scale = -100 }, 10)
      t.eq(mirrored.scale, -31, 'a mirrored curve stays mirrored (round-half-up puts the exact half at -31)')
    end,
  },

  {
    name = 'parkWindows follows the dest param, not the registry (a retargeted pb kind parks cc)',
    run = function()
      local windows = generators.parkWindows{
        { chan = 1, startppq = 0, endppq = 240, fx = { { kind = 'sine', dest = 74 } } },
      }
      t.deepEq(windows, { { evType = 'cc', chan = 1, cc = 74, startppq = 0, endppq = 240 } },
               "the entry's dest decides the window type")
    end,
  },

  ----- sine: one gesture, either domain -- cents on pb, cc steps on a controller

  {
    name = 'sine on a cc dest tiles the window with extrema in cc steps, anchored 0 at both ends',
    run = function()
      -- res 240, period 1/2 QN -> cycle 120 ticks; extrema at period/4 = 30, then every 60.
      -- The body never learns which dest it serves: depth arrives already in the target's units.
      local out = expand('sine', { window = { 0, 240 } },
                         { kind = 'sine', period = { 1, 2 }, depth = 32, dest = 10 }, { resolution = 240 })
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

  ----- chord-stamp: stamp a poly note pattern onto every member, rebased by cents

  {
    name = 'chord-stamp rebases the pattern chord onto each member; lane-1 note lands on the trigger',
    run = function()
      local ctx = {}
      local chord = { kind = 'notes', specs = {
        { lane = 1, ppq = 0, endppq = 240, pitch = 60, vel = 100 },   -- root C
        { lane = 2, ppq = 0, endppq = 240, pitch = 64, vel = 100 },   -- E
        { lane = 3, ppq = 0, endppq = 240, pitch = 67, vel = 100 },   -- G
      } }
      local host = { window = { 0, 240 }, notes = {
        { pitch = 62, vel = 90, detune = 0, ppq = 0, endppq = 240 },  -- trigger: D
      } }
      local out = expand('chordStamp', host, { kind = 'chordStamp', pattern = chord }, ctx)
      t.eq(#out.notes, 3, 'one derived note per chord voice')
      t.deepEq({ out.notes[1].pitch, out.notes[2].pitch, out.notes[3].pitch }, { 62, 66, 69 },
        'C-E-G rooted on C, rebased so the root lands on D -> D-F#-A')
      t.eq(out.notes[1].vel, 90, 'every voice takes the trigger velocity, not the pattern vel')
      t.eq(out.notes[1].ppq, 0);  t.eq(out.notes[1].endppq, 240)   -- vertical stamp: the trigger's window
    end,
  },

  {
    name = 'chord-stamp moves every voice by the cents from its root to the trigger',
    run = function()
      -- A chord typed with its thirds and fifths bent off equal temperament, so a move that
      -- respelled it through a notation would show as an altered interval.
      local chord = { kind = 'notes', specs = {
        { lane = 1, ppq = 0, endppq = 240, pitch = 60, vel = 80, detune = 0 },
        { lane = 2, ppq = 0, endppq = 240, pitch = 64, vel = 80, detune = -14 },
        { lane = 3, ppq = 0, endppq = 240, pitch = 67, vel = 80, detune = 2 },
      } }
      -- The trigger sounds 40 cents sharp of D, where a solve left it.
      local host = { window = { 0, 240 }, notes = {
        { pitch = 62, vel = 90, detune = 40, ppq = 0, endppq = 240 },
      } }
      local out = expand('chordStamp', host, { kind = 'chordStamp', pattern = chord }, {})
      local function cents(n) return n.pitch * 100 + n.detune end
      t.eq(cents(out.notes[1]), 6240, 'the root lands where the trigger sounds, drift included')
      t.eq(cents(out.notes[2]) - cents(out.notes[1]), 386, 'the bent third is preserved exactly')
      t.eq(cents(out.notes[3]) - cents(out.notes[1]), 702, 'and the bent fifth')
      t.eq(out.notes[2].pitch, 66, 'each voice places on its nearest pitch')
      t.eq(out.notes[2].detune, 26, 'with the remainder as detune')
    end,
  },

  {
    name = 'chord-stamp fires a chord on every region member (all lanes are triggers)',
    run = function()
      local ctx = {}
      local chord = { kind = 'notes', specs = {
        { lane = 1, ppq = 0, endppq = 240, pitch = 60, vel = 100 },
        { lane = 2, ppq = 0, endppq = 240, pitch = 67, vel = 100 },   -- a fifth above the root
      } }
      local host = { window = { 0, 480 }, notes = {
        { pitch = 60, vel = 100, detune = 0, ppq = 0,   endppq = 240 },
        { pitch = 62, vel = 100, detune = 0, ppq = 240, endppq = 480 },
      } }
      local out = expand('chordStamp', host, { kind = 'chordStamp', pattern = chord }, ctx)
      t.eq(#out.notes, 4, 'two voices stamped on each of two members')
      t.deepEq({ out.notes[1].ppq, out.notes[3].ppq }, { 0, 240 }, 'each chord sits at its trigger onset')
      t.deepEq({ out.notes[1].pitch, out.notes[2].pitch }, { 60, 67 }, 'first chord rooted on C')
      t.deepEq({ out.notes[3].pitch, out.notes[4].pitch }, { 62, 69 }, 'second chord rooted on D')
    end,
  },

  {
    name = 'chord-stamp with no lane-1 note in the pattern is inert (no root to rebase from)',
    run = function()
      local chord = { kind = 'notes', specs = {
        { lane = 2, ppq = 0, endppq = 240, pitch = 64, vel = 80 },
      } }
      local host = { window = { 0, 240 }, notes = {
        { pitch = 62, vel = 90, detune = 0, ppq = 0, endppq = 240 },
      } }
      local out = expand('chordStamp', host, { kind = 'chordStamp', pattern = chord }, {})
      t.eq(#out.notes, 0, 'no lane-1 reference -> nothing stamped')
    end,
  },

  {
    name = 'chord-stamp voices name the trigger\'s step plus their own interval from the root',
    run = function()
      local chord = { kind = 'notes', specs = {
        { lane = 1, ppq = 0, endppq = 240, pitch = 60, vel = 80, detune = 0 },
        { lane = 2, ppq = 0, endppq = 240, pitch = 64, vel = 80, detune = -14 },
        { lane = 3, ppq = 0, endppq = 240, pitch = 67, vel = 80, detune = 2 },
      } }
      -- Written D, sounding 40 cents sharp of it.
      local host = { window = { 0, 240 }, notes = {
        { pitch = 62, vel = 90, detune = 40, ppq = 0, endppq = 240, intentCents = 6200 },
      } }
      local out = expand('chordStamp', host, { kind = 'chordStamp', pattern = chord }, {})
      t.deepEq({ out.notes[1].intentCents, out.notes[2].intentCents, out.notes[3].intentCents },
        { 6200, 6586, 6902 },
        'each voice stands its own authored interval above the step the trigger was written on')
    end,
  },

  ----- The intent a derivation carries: a derived note's name is its source's, moved

  {
    name = 'the kinds that copy a pitch copy the intent standing beside it',
    run = function()
      local ctx  = { resolution = 240 }
      local host = { window = { 0, 240 }, notes = {
        { pitch = 60, vel = 100, detune = 60, ppq = 0, endppq = 240, intentCents = 6000 },
      } }
      t.eq(expand('retrig', host, { kind = 'retrig', period = { 1, 2 } }, ctx).notes[1].intentCents,
        6000, 'a retrig tile is the host note struck again')
      t.eq(expand('arp', host, { kind = 'arp', period = { 1, 2 }, dir = 'up' }, ctx).notes[1].intentCents,
        6000, 'an arp plays the voices it found, names and all')
      t.eq(expand('velPattern', host, { kind = 'velPattern', pattern = { 50 } }, ctx).notes[1].intentCents,
        6000, 'a velocity pass rewrites one field and carries the rest')
    end,
  },

  ----- lfo: tile a normalized curve, displaced from the dest's rest by offset + scale

  {
    name = 'lfo tiles the curve at 1/period QN, mapping each val by offset + scale, edges seeded',
    run = function()
      -- res 240, period 1 QN -> 240-tick cycle == lengthPpq (stretch 1); window is two cycles.
      local out = expand('lfo', { window = { 0, 480 } },
        { kind = 'lfo', period = { 1, 1 }, offset = 64, scale = 63, pattern = triangle() },
        { resolution = 240 })
      t.eq(#out.notes, 0, 'continuous: no structural notes')
      local d = out.delta
      t.eq(d[1].ppq, 0);      t.eq(d[1].val, 1,   'start seed maps norm -1 -> offset-scale (1)')
      t.eq(d[#d].ppq, 480);   t.eq(d[#d].val, 1,  'end seed closes the loop back to the start value')
      local peaks, mid = 0, {}
      for _, bp in ipairs(d) do
        if bp.val == 127 then peaks = peaks + 1 end   -- norm +1 -> offset+scale, at ppq 120 & 360
        if bp.val == 64  then mid[#mid + 1] = bp.ppq end
      end
      t.eq(peaks, 2, 'the +1 apex recurs once per tiled cycle')
      t.truthy(#mid >= 2, 'the norm-0 midpoints land on offset (64)')
    end,
  },

  {
    name = 'lfo maps norm in whatever units the dest counts in -- cents on pb',
    run = function()
      local out = expand('lfo', { window = { 0, 240 } },
        { kind = 'lfo', period = { 1, 1 }, offset = 0, scale = 100, pattern = triangle() },
        { resolution = 240 })
      t.eq(out.delta[1].val, -100, 'norm -1 -> 100 cents below rest; the body knows nothing of 0..127')
      local peak
      for _, bp in ipairs(out.delta) do if bp.ppq == 120 then peak = bp.val end end
      t.eq(peak, 100, 'norm +1 -> 100 cents above rest')
    end,
  },

  {
    name = 'lfo does not clamp -- the body holds no dest knowledge, and the cc seat clamps',
    run = function()
      local out = expand('lfo', { window = { 0, 240 } },
        { kind = 'lfo', period = { 1, 1 }, offset = 64, scale = 100, pattern = triangle() },
        { resolution = 240 })
      t.eq(out.delta[1].val, -36, 'offset 64 - scale 100 runs below a cc floor, and is emitted as it is')
      local sawHi = false
      for _, bp in ipairs(out.delta) do if bp.val == 164 then sawHi = true end end
      t.truthy(sawHi, 'offset 64 + scale 100 runs above the ceiling, likewise')
    end,
  },

  {
    name = 'lfo with an empty or lengthless curve is inert (no delta)',
    run = function()
      local base = { kind = 'lfo', period = { 1, 1 }, offset = 64, scale = 63 }
      local empty = expand('lfo', { window = { 0, 240 } },
        util.assign({}, base, { pattern = { kind = 'curve', lengthPpq = 240, points = {} } }), { resolution = 240 })
      t.eq(#empty.delta, 0, 'no points -> nothing to emit')
      local lengthless = expand('lfo', { window = { 0, 240 } },
        util.assign({}, base, { pattern = { kind = 'curve', points = { { ppq = 0, val = 0 } } } }), { resolution = 240 })
      t.eq(#lengthless.delta, 0, 'no lengthPpq -> no cycle to tile')
    end,
  },

  ----- thinCurve: bounded Douglas-Peucker over the linear runs

  {
    name = 'thinCurve returns a degenerate curve verbatim -- endpoints are never candidates',
    run = function()
      t.eq(#generators.thinCurve({}, 1e9), 0, 'nothing in, nothing out')
      local one = pts{ {0,5} }
      local outOne = generators.thinCurve(one, 1e9)
      t.eq(#outOne, 1); t.eq(outOne[1], one[1], 'the lone point is an endpoint, so it is kept')
      t.eq(#generators.thinCurve(pts{ {0,0}, {240,40} }, 1e9), 2, 'both endpoints survive any tolerance')
    end,
  },

  {
    name = 'thinCurve collapses a collinear linear run to its endpoints',
    run = function()
      local points = pts{ {0,0}, {120,10}, {240,20}, {360,30}, {480,40} }
      local out = generators.thinCurve(points, 0)
      t.eq(#out, 2, 'every interior point sits exactly on the chord')
      t.eq(out[1], points[1], 'the result selects the input tables themselves, not copies of them')
      t.eq(out[2], points[5])
    end,
  },

  {
    name = 'thinCurve drops a spike whose vertical error only meets the tolerance',
    run = function()
      -- Chord at ppq 120 is 10, so the spike is off by exactly 2.
      t.eq(#generators.thinCurve(pts{ {0,0}, {120,12}, {240,20} }, 2), 2, 'err == tol collapses')
    end,
  },

  {
    name = 'thinCurve keeps a spike whose vertical error exceeds the tolerance',
    run = function()
      t.eq(#generators.thinCurve(pts{ {0,0}, {120,13}, {240,20} }, 2), 3, 'err 3 > tol 2 is real detail')
    end,
  },

  {
    name = 'thinCurve keeps a stepped run whole, collinear though its points are',
    run = function()
      local points = pts{ {0,0,'step'}, {120,10,'step'}, {240,20,'step'} }
      t.eq(#generators.thinCurve(points, 100), 3, 'dropping 120 would move the jump, not just the chord')
    end,
  },

  {
    name = 'thinCurve rides a curved point through with its tension intact',
    run = function()
      local points = pts{ {0,0}, {120,10,'bezier',0.5}, {240,20} }
      local out = generators.thinCurve(points, 100)
      t.eq(#out, 3)
      t.eq(out[2].tension, 0.5, 'no field copy -- the point table itself is what rides through')
    end,
  },

  {
    name = 'thinCurve lets a non-linear point pin its successor as well as itself',
    run = function()
      local points = pts{ {0,0,'bezier',0.5}, {120,10}, {240,20} }
      t.eq(#generators.thinCurve(points, 100), 3,
        'the middle point sits on the chord, but it closes the bezier segment')
    end,
  },

  {
    name = 'thinCurve treats a missing shape as non-linear -- under-thin over silently ramping',
    run = function()
      local points = { { ppq = 0, val = 0 }, { ppq = 120, val = 10 }, { ppq = 240, val = 20 } }
      t.eq(#generators.thinCurve(points, 100), 3, 'the wire default is step, so nil is a hard keep')
    end,
  },

  {
    name = 'thinCurve keeps a stack of coincident points -- a zero-width span has no chord',
    run = function()
      local points = pts{ {0,0}, {0,50}, {0,100} }
      t.eq(#generators.thinCurve(points, 1e9), 3, 'nothing to measure against, so nothing may go')
    end,
  },

  {
    name = 'thinCurve gives a dual-point pair no special protection',
    run = function()
      -- The pair sits one tick apart, per tm's DUAL_POINT_TICK (a tm local, not exported).
      local points = pts{ {0,0}, {119,50}, {120,50}, {240,100} }
      t.eq(#generators.thinCurve(points, 0), 4, 'off the chord by 0.42, so tol 0 keeps the pair')
      t.eq(#generators.thinCurve(points, 1), 2, 'tol 1 swallows it -- a vertical jump is not a shape')
    end,
  },

}
