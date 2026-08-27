-- Note-macro generators: pure expansions of per-note `fx` intent into derived realisation. They never touch
-- swing, raw pb or REAPER -- the seam rounds ppq -> raw, cents -> pb. See docs/generators.md for the model.

-- @noindex

--invariant: pure module, no state; a stage is fn(stream, host, params, ctx) -> { notes, delta }
--invariant: stream and host share one shape; stages read stream, host is the untouched original
--shape: stream/host = { window={startppq,endppq}, chan, lane, id, notes={ {pitch,vel,detune,ppq,endppq,[lane],[intentCents]},.. }, pas={ {ppq,pitch,vel},.. }, ccs={ [cc]={ {ppq,val,shape,[tension]},.. } }, ats={ {ppq,val},.. }, pb={ {ppq,val,shape,[tension]},.. } }
--invariant: pb/ccs are absolute curves over the closed window (edge values seeded); pb val is cents
--invariant: ctx binds resolution, pbRangeCents, nextSameLaneNote -- no notation among them
--invariant: periods are QN per the periodQN convention -- scalar or {num,den}
--shape: result = { notes = { {ppq,endppq,pitch,vel,detune,[intentCents]}, ... }, delta = { {ppq,val,shape,[tension]}, ... } }
--invariant: a derived note's intent is its source's moved by the cents it stands off, else absent
--shape: kinds[kind] = { expand, mode='replace'|'augment', dest='note'|'pb'|<cc>, dests?='any'|'pb'|'cc', label, glyph, defaults, fields }
--shape: field = { field, label, widget, base?, coarse?, min?, max?, options?, when?, kind?, poly?, quantity?='magnitude', signed?, frac? }
--invariant: mode is the stream fold -- replace overwrites the dest channel, augment adds to it
-- The copy shelf (docs/patternEditor.md § The copy shelf): named copies of pattern-param bodies,
-- Save/Load only. Params store bodies inline; nothing references the shelf by name.
--shape: fxPatterns (ds project) = { [name] = { kind='notes'|'curve', lengthPpq, rpb=rowsPerBeat, root?=midiPitch, specs?={ {lane,ppq,endppq,pitch,vel,detune,delay,sample?},.. }, points?={ {ppq,val,shape,tension?},.. } } }
-- A pattern field descriptor may carry poly=true (per-kind, not per-body) to let a note editor author
-- overlapping lanes; absent/false pins every spec to lane 1. chordStamp sets it (a chord's voices).

local util   = require 'util'
local tuning = require 'tuning'

local generators = {}

local function periodTicks(period, resolution)
  local qn = type(period) == 'table' and period[1] / period[2] or period
  return qn * resolution
end

----- Note arithmetic

-- Cents between two notes' realised pitches. The microtonal offset already rides
-- in detune, so this is pure note arithmetic -- no temper needed.
local function interval(a, b)
  return (b.pitch - a.pitch) * 100 + ((b.detune or 0) - (a.detune or 0))
end

-- The inverse: a note displaced by cents, placed back on (pitch, detune). A pitch demand is
-- cents here and never notation steps. see docs/generators.md § The ctx discipline
local function displaced(note, cents)
  return tuning.placeCents(note.pitch * 100 + (note.detune or 0) + cents)
end

-- The name that rides with it: the source's intent moved by the cents this note stands off it.
-- A source carrying none derives none, and the note reads as it sounds; see docs/tuning.md § The written step
local function inherited(src, cents)
  return src.intentCents and src.intentCents + cents
end

--contract: retrig tiles the host window with evenly-spaced same-pitch fxNotes; every hit is derived
--contract: velocity ramps params.ramp per tile from the host vel, clamped 1..127; detune inherited verbatim
local function retrig(stream, host, params, ctx)
  local startL, endL = stream.window[1], stream.window[2]
  local step  = periodTicks(params.period, ctx.resolution)
  local h     = stream.notes[1]
  if not h then return { notes = {}, delta = {} } end   -- empty membership (bare region)
  local ramp  = params.ramp or 0
  local notes = {}
  local i = 0
  while startL + i * step < endL do
    util.add(notes, {
      ppq    = startL + i * step,
      endppq = math.min(startL + (i + 1) * step, endL),
      pitch   = h.pitch,
      vel     = math.max(1, math.min(127, h.vel + i * ramp)),
      detune  = h.detune or 0,
      intentCents = h.intentCents,
    })
    i = i + 1
  end
  return { notes = notes, delta = {} }
end

--contract: trill alternates host pitch with a note `cents` off what it sounds; every hit derived
local function trill(stream, host, params, ctx)
  local startL, endL = stream.window[1], stream.window[2]
  local step  = periodTicks(params.period, ctx.resolution)
  local h     = stream.notes[1]
  if not h then return { notes = {}, delta = {} } end   -- empty membership (bare region)
  -- The alternation note: a cents demand off what the host sounds, whatever the notation names it,
  -- and named from the host's own step moved by that demand.
  local cents = params.cents or 0
  local altPitch, altDetune = displaced(h, cents)
  local altIntent           = inherited(h, cents)
  local notes = {}
  local i = 0
  while startL + i * step < endL do
    local odd = i % 2 == 1   -- even tiles carry the host pitch; odd tiles the alternation
    util.add(notes, {
      ppq    = startL + i * step,
      endppq = math.min(startL + (i + 1) * step, endL),
      pitch   = odd and altPitch  or h.pitch,
      vel     = h.vel,
      detune  = odd and altDetune or (h.detune or 0),
      intentCents = odd and altIntent or h.intentCents,
    })
    i = i + 1
  end
  return { notes = notes, delta = {} }
end

-- Notes sounding at logical tick `t`, ascending by realised pitch (semitone*100 + detune cents).
local function playingAt(events, t)
  local active = {}
  for _, n in ipairs(events) do
    if n.ppq <= t and t < n.endppq then util.add(active, n) end
  end
  table.sort(active, function(a, b)
    return a.pitch * 100 + (a.detune or 0) < b.pitch * 100 + (b.detune or 0)
  end)
  return active
end

-- Which voice of the active set step `i` plays, by direction. updown bounces without
-- repeating the extremes (span 2*(n-1)); up/down wrap.
local function arpIndex(count, dir, i)
  if dir == 'down' then return (count - 1) - i % count end
  if dir == 'updown' and count > 2 then
    local span = 2 * (count - 1)
    local j = i % span
    return j < count and j or span - j
  end
  return i % count
end

--contract: arp samples the sounding notes at each step (period QN), playing one by `dir`
--contract: dir up|down|updown cycles the current active set; an empty active set -> a rest
--contract: hits abut (endppq = next step), clamped to the window; vel/detune from the voice
local function arp(stream, host, params, ctx)
  local startL, endL = stream.window[1], stream.window[2]
  local step = periodTicks(params.period, ctx.resolution)
  local dir  = params.dir or 'up'
  local notes = {}
  local i = 0
  local at = startL
  while at < endL do
    local active = playingAt(stream.notes, at)
    if #active > 0 then
      local src = active[arpIndex(#active, dir, i) + 1]
      util.add(notes, {
        ppq = at, endppq = math.min(at + step, endL),
        pitch = src.pitch, vel = src.vel, detune = src.detune or 0,
        intentCents = src.intentCents,
      })
    end
    i = i + 1
    at = startL + i * step
  end
  return { notes = notes, delta = {} }
end

--contract: ostinato gates the sounding region notes by a stored pattern -- pattern gives onset/dur/vel, each voice its pitch/detune
--contract: every voice sounding at a gate onset emits (none -> rest); the pattern loops from the window start; no lengthPpq -> inert
local function ostinato(stream, host, params, ctx)
  local body = params.pattern
  local loop = body and body.lengthPpq
  if not (body and loop and loop > 0) then return { notes = {}, delta = {} } end
  local startL, endL = stream.window[1], stream.window[2]
  local notes = {}
  local base = startL
  while base < endL do
    for _, spec in ipairs(body.specs or {}) do
      local onset = base + spec.ppq
      if onset >= startL and onset < endL then
        local endppq = math.min(base + spec.endppq, endL)
        for _, voice in ipairs(playingAt(stream.notes, onset)) do
          util.add(notes, { ppq = onset, endppq = endppq, pitch = voice.pitch, vel = spec.vel,
                                detune = voice.detune or 0, intentCents = voice.intentCents })
        end
      end
    end
    base = base + loop
  end
  return { notes = notes, delta = {} }
end

--contract: chord-stamp stamps a poly pattern on each region member; lane-1 is the pattern's root
--contract: every voice moves by the cents root -> trigger; voice keeps trigger vel/window
--contract: a voice is named from the trigger's step moved by its own interval from the root
--contract: no lane-1 note in the pattern -> inert (empty result)
-- Voices carry their authored detune (intent); on one channel only lane 1's detune realises via pb, so a
-- microtonal chord sounds faithfully only in 12-ET -- the hand-authored-chord limit. see docs/tuning.md
local function chordStamp(stream, host, params, ctx)
  local specs = params.pattern and params.pattern.specs
  if not (specs and #specs > 0) then return { notes = {}, delta = {} } end
  local ref                                    -- the chord's root: the pattern's lane-1 note (earliest if several)
  for _, spec in ipairs(specs) do
    if (spec.lane or 1) == 1 and (not ref or spec.ppq < ref.ppq) then ref = spec end
  end
  if not ref then return { notes = {}, delta = {} } end
  local notes = {}
  for _, trig in ipairs(stream.notes) do
    local offset = interval(ref, trig)         -- root -> trigger, in cents
    for _, spec in ipairs(specs) do
      local pitch, detune = displaced(spec, offset)
      -- The voice sounds where the root's interval to the trigger puts it, and is named from
      -- the trigger's own step moved by the voice's interval from the root.
      util.add(notes, { ppq = trig.ppq, endppq = trig.endppq,
                        pitch = pitch, detune = detune, vel = trig.vel,
                        intentCents = inherited(trig, interval(ref, spec)) })
    end
  end
  return { notes = notes, delta = {} }
end

-- The monophonic sequence a host presents, in ppq order. see docs/generators.md § Portamento ¶5-6
local function glideSequence(stream, host, ctx)
  local seq = {}
  for _, note in ipairs(stream.notes) do
    if stream.lane or (note.lane or 1) == 1 then util.add(seq, note) end
  end
  table.sort(seq, function(a, b) return a.ppq < b.ppq end)
  -- The successor is keyed on the original host note's identity, so it reads host, not the folded stream.
  local beyond = stream.lane and ctx.nextSameLaneNote and ctx.nextSameLaneNote(host)
  if beyond then util.add(seq, beyond) end
  return seq
end

-- How long a glide runs: `over` QN outright, or that much per octave of the interval it crosses --
-- one stored fraction read as a duration or as a rate.
local function glideTicks(params, target, resolution)
  local span = periodTicks(params.over, resolution)
  if params.per == 'octave' then span = span * math.abs(target) / 1200 end
  return math.max(1, util.round(span))
end

--contract: portamento glides each abutting pair of the host's monophonic line -> lane-1 pb-delta
--contract: abutment is exact -- the tail must reach the successor's onset, else the pair is silent
--contract: the anchor is the successor's onset; 'in' departs on it, 'away' arrives a tick before it
--contract: an anchor outside the window can only be placed away; a note host's successor always is
--contract: glide spans `over` QN, or that per octave when per='octave'; pb-range clamps the target
--contract: a gap, a unison target, or no successor at all -> that pair contributes nothing
local function slide(stream, host, params, ctx)
  local startL, endL = stream.window[1], stream.window[2]
  local seq   = glideSequence(stream, host, ctx)
  local shape = params.shape or 'slow'
  -- snap keeps the arrival (target) and the handoff (0) on distinct wire ppqs, and holds the stage's
  -- own material below tm's closing tick. see docs/generators.md § Route-by-window
  local close = endL - math.max(1, ctx.resolution / 16)

  local points = {}
  local function at(ppq, val, sh) util.add(points, { ppq = ppq, val = val, shape = sh }) end
  for i = 1, #seq - 1 do
    local a, b   = seq[i], seq[i + 1]
    local anchor = b.ppq
    local target = interval(a, b)
    if ctx.pbRangeCents then target = util.clamp(target, -ctx.pbRangeCents, ctx.pbRangeCents) end
    -- Exact abutment: a region member arrives pre-clipped to its successor's onset, a note host's
    -- endppq is its unclipped authored ceiling, and util.OPEN reaches everything.
    if a.endppq >= anchor and target ~= 0 then
      local span = glideTicks(params, target, ctx.resolution)
      if anchor < endL and params.place == 'in' then
        -- The successor enters on the pitch before it and glides onto its own.
        local arrive = math.min(anchor + span, math.min(b.endppq, endL) - 1, close)
        if arrive > anchor then at(anchor, -target, shape); at(arrive, 0, 'step') end
      else
        -- The departing note carries the bend and hands the channel back on the anchor -- or, where
        -- the anchor is the window's own edge, leaves the handback to tm's close.
        local arrive = math.min(anchor - 1, close)
        local begin  = math.max(arrive - span, a.ppq, startL)
        if arrive > begin then
          at(begin, 0, shape)
          at(arrive, target, 'step')
          if anchor < endL then at(anchor, 0, 'step') end
        end
      end
    end
  end
  if #points == 0 then return { notes = {}, delta = {} } end

  local delta = { { ppq = startL, val = 0, shape = 'step' } }   -- hold true pitch until the first glide
  for _, point in ipairs(points) do
    local last = delta[#delta]
    -- Two breakpoints cannot share a ppq, and a glide long enough opens on the tick the one before
    -- it came to rest: the later shape governs the segment they meet on, and both rest at centre.
    if last.ppq == point.ppq then last.val, last.shape = point.val, point.shape
    else util.add(delta, point) end
  end
  return { notes = {}, delta = delta }
end

----- LFO waves

-- A named wave is a seed body in the same normalized domain the curve editor authors, so choosing
-- one and drawing one are the same act at different distances. see docs/generators.md § Waves

-- One cycle's authored span, in QN, not ticks (docs/generators.md § Waves ¶2 has why). The period
-- stretches the body regardless -- this only fixes the grid a custom curve is edited on.
local WAVE_QN = 4

-- Each wave's turning points over a cycle of L: {ppq, val, shape}, sine/triangle sharing turns but
-- riding 'slow' vs 'linear'; saws phase-shift the ramp so the reset lands inside. see docs/generators.md § Waves
local WAVE_TURNS = {
  sine     = function(L) return { { 0, 0, 'slow' }, { L / 4, 1, 'slow' }, { 3 * L / 4, -1, 'slow' }, { L, 0, 'slow' } } end,
  triangle = function(L) return { { 0, 0, 'linear' }, { L / 4, 1, 'linear' }, { 3 * L / 4, -1, 'linear' }, { L, 0, 'linear' } } end,
  square   = function(L) return { { 0, 1, 'step' }, { L / 2, -1, 'step' }, { L, 1, 'step' } } end,
  -- The peak sits one tick before the drop -- the narrowest a reset can be authored, since two
  -- breakpoints can't share a ppq. see docs/generators.md § Waves ¶6
  sawUp    = function(L) return { { 0, 0, 'linear' }, { L / 2 - 1, 1, 'linear' }, { L / 2, -1, 'linear' }, { L, 0, 'linear' } } end,
  sawDown  = function(L) return { { 0, 0, 'linear' }, { L / 2 - 1, -1, 'linear' }, { L / 2, 1, 'linear' }, { L, 0, 'linear' } } end,
}

--contract: waveBody draws a wave as a loop-closed normalized curve body -- editable as any other
--contract: the body spans WAVE_QN beats of the take's resolution, never a fixed tick count
function generators.waveBody(wave, resolution)
  local L     = WAVE_QN * resolution
  local turns = WAVE_TURNS[wave] or error('unknown lfo wave: ' .. tostring(wave))
  local points = {}
  for _, turn in ipairs(turns(L)) do
    util.add(points, { ppq = util.round(turn[1]), val = turn[2], shape = turn[3] })
  end
  return { kind = 'curve', domain = 'normalized', display = 'bipolar', lengthPpq = L, points = points }
end

-- Editing a named wave's curve stamps its points and flips the stage to custom, so exactly one
-- body is authoritative; custom (or no wave at all) is handed back untouched. see docs/generators.md § Waves
function generators.customise(entry, resolution)
  if entry.wave == nil or entry.wave == 'custom' then return entry end
  local out = util.assign({}, entry)
  out.wave, out.pattern = 'custom', generators.waveBody(entry.wave, resolution)
  return out
end

-- Linear-interpolated normalized value at authored ppq `a`; points ascend in ppq, edges clamp flat.
local function curveAt(points, a)
  if a <= points[1].ppq then return points[1].val end
  for i = 2, #points do
    local prev, cur = points[i - 1], points[i]
    if a <= cur.ppq then
      local span = cur.ppq - prev.ppq
      return span > 0 and prev.val + (cur.val - prev.val) * (a - prev.ppq) / span or cur.val
    end
  end
  return points[#points].val
end

--contract: lfo tiles a normalized curve at 1/period QN, offset + scale map each val, unit-naive
--contract: a named wave is the body expanded; 'custom' (or no wave) reads the stored one
--contract: breakpoints are a displacement from the dest's rest, which the augment fold lays them on
--contract: each cycle stretches the body lengthPpq -> period ticks; both window edges seeded
--contract: onset QN ramps the whole displacement in from rest, linearly from the window start
local function lfo(stream, host, params, ctx)
  local named  = params.wave and params.wave ~= 'custom'
  local body   = named and generators.waveBody(params.wave, ctx.resolution) or params.pattern
  local loop   = body and body.lengthPpq
  local points = body and body.points
  if not (loop and loop > 0 and points and #points > 0) then return { notes = {}, delta = {} } end
  local startL, endL = stream.window[1], stream.window[2]
  local period  = periodTicks(params.period, ctx.resolution)
  local stretch = period / loop
  local offset, amp = params.offset or 0, params.scale or 0
  local onset = (params.onset or 0) * ctx.resolution      -- ramp-in, ticks
  -- The ramp lifts the whole displacement, offset included: the stage arrives from the dest's own
  -- rest rather than snapping to a perch and wobbling there.
  local function val(norm, at)
    local gain = onset > 0 and math.min(1, (at - startL) / onset) or 1
    return util.round(gain * (offset + amp * norm))
  end

  -- Seed startL (phase 0); tile interior cycles, skipping the ppq==loop endpoint (owned by the next
  -- cycle's phase 0, or by the endL seed) so a loop-closed curve emits no duplicate boundary breakpoint.
  local delta = { { ppq = startL, val = val(curveAt(points, 0), startL),
                    shape = points[1].shape, tension = points[1].tension } }
  local base, lastAt = startL, startL
  while base < endL do
    for _, p in ipairs(points) do
      local raw = base + p.ppq * stretch
      if raw > startL and raw < endL and p.ppq < loop then
        -- A cycle squeezed below the tick would collapse a saw's one-tick reset onto its neighbour.
        -- Hold breakpoints a tick apart instead: the shape survives. see docs/generators.md § Waves ¶6
        local at = math.max(raw, lastAt + 1)
        if at < endL then
          util.add(delta, { ppq = at, val = val(p.val, at), shape = p.shape, tension = p.tension })
          lastAt = at
        end
      end
    end
    base = base + period
  end
  local phaseEnd = ((endL - startL) % period) / stretch   -- authored ppq at the window's trailing edge
  util.add(delta, { ppq = endL, val = val(curveAt(points, phaseEnd), endL), shape = 'linear' })
  return { notes = {}, delta = delta }
end

--contract: velPattern rewrites stream-note velocities by a pattern; other fields carry verbatim
--contract: pattern steps per distinct onset (a chord shares one step) and cycles; vel clamps 1..127
local function velPattern(stream, host, params, ctx)
  local ordered = {}
  for _, note in ipairs(stream.notes) do util.add(ordered, note) end
  table.sort(ordered, function(a, b)   -- onset, then realised pitch (playingAt's order)
    if a.ppq ~= b.ppq then return a.ppq < b.ppq end
    return a.pitch * 100 + (a.detune or 0) < b.pitch * 100 + (b.detune or 0)
  end)
  local pattern = params.pattern or { 100 }
  local notes, step, lastOnset = {}, 0, nil
  for _, note in ipairs(ordered) do
    if note.ppq ~= lastOnset then step, lastOnset = step + 1, note.ppq end
    local pct = pattern[(step - 1) % #pattern + 1]
    util.add(notes, { ppq = note.ppq, endppq = note.endppq, pitch = note.pitch,
                      vel = util.clamp(util.round(note.vel * pct / 100), 1, 127),
                      detune = note.detune or 0, intentCents = note.intentCents })
  end
  return { notes = notes, delta = {} }
end

----- Generator registry

-- One entry per kind: the realisation fn (`expand`) plus all metadata a kind ships with. see
-- docs/generators.md § The chain

-- Every periodic kind tempo-syncs the same way, on the `period` widget: `timing.periodLadder`
-- under the arrows, any fraction under the box. see docs/trackerRender.md § A period is a fraction

-- The wave ladder. `Custom` is an `arrival` -- reached by editing the curve, not arrowed to -- and
-- picking it outright fires `rewrite` to re-seed the stage. see docs/generators.md § Waves ¶3
local WAVES = { { l = 'Sine',     v = 'sine' },   { l = 'Triangle', v = 'triangle' },
                { l = 'Square',   v = 'square' }, { l = 'Saw Up',   v = 'sawUp' },
                { l = 'Saw Down', v = 'sawDown' },
                { l = 'Custom',   v = 'custom', arrival = true, rewrite = generators.customise } }
-- One stored fraction, two readings: how long a glide takes, or how long an octave of it takes.
local GLIDE_PER     = { { l = 'Note', v = 'note' }, { l = 'Octave', v = 'octave' } }
local GLIDE_PLACES  = { { l = 'In', v = 'in' }, { l = 'Away', v = 'away' } }
-- REAPER's envelope shapes, less step (no glide) and bezier (its tension has no integer widget).
local GLIDE_SHAPES  = { { l = 'Linear', v = 'linear' },         { l = 'Ease',     v = 'slow' },
                        { l = 'Fast Start', v = 'fast-start' }, { l = 'Fast End', v = 'fast-end' } }
local DIR_OPTIONS   = { { l = 'Up', v = 'up' }, { l = 'Down', v = 'down' }, { l = 'Up/Down', v = 'updown' } }
local VEL_PATTERNS  = { { l = '> .',     v = { 100, 55 } },
                        { l = '> . .',   v = { 100, 55, 70 } },
                        { l = '> . . .', v = { 100, 55, 70, 55 } } }

generators.kinds = {
  retrig = {
    expand = retrig, mode = 'replace', dest = 'note', label = 'Retrig', glyph = 'R',
    defaults = { period = { 1, 4 }, ramp = 0 },
    fields = {
      { field = 'period', label = 'Period', widget = 'period' },
      { field = 'ramp',   label = 'Ramp',   widget = 'int', base = 1, coarse = 10, min = -127, max = 127 },
    },
  },
  trill = {
    expand = trill, mode = 'replace', dest = 'note', label = 'Trill', glyph = 'T',
    defaults = { period = { 1, 4 }, cents = 200 },
    fields = {
      { field = 'period', label = 'Period', widget = 'period' },
      -- cents demand, edited as a step ladder from the host's written step -- a slide's field
      { field = 'cents',  label = 'Interval', widget = 'stepInterval' },
    },
  },
  arp = {
    expand = arp, mode = 'replace', dest = 'note', label = 'Arp', glyph = 'A',
    defaults = { period = { 1, 4 }, dir = 'up' },
    fields = {
      { field = 'period', label = 'Period', widget = 'period' },
      { field = 'dir',    label = 'Dir',    widget = 'choice', options = DIR_OPTIONS },
    },
  },
  ostinato = {
    expand = ostinato, mode = 'replace', dest = 'note', label = 'Ostinato', glyph = 'O',
    defaults = { pattern = { kind = 'notes', specs = {} } },
    fields = {
      { field = 'pattern', label = 'Pattern', widget = 'pattern', kind = 'notes' },
    },
  },
  chordStamp = {
    expand = chordStamp, mode = 'replace', dest = 'note', label = 'Chord', glyph = 'C',
    defaults = { pattern = { kind = 'notes', specs = {} } },
    fields = {
      { field = 'pattern', label = 'Chord', widget = 'pattern', kind = 'notes', poly = true },
    },
  },
  slide = {
    expand = slide, mode = 'augment', dest = 'pb', dests = 'pb', label = 'Portamento', glyph = '/',
    defaults = { over = { 1, 2 }, per = 'note', place = 'in', shape = 'slow' },
    fields = {
      { field = 'over',  label = 'Glide', widget = 'period' },
      { field = 'per',   label = 'Per',   widget = 'choice', options = GLIDE_PER },
      { field = 'place', label = 'Place', widget = 'choice', options = GLIDE_PLACES },
      { field = 'shape', label = 'Shape', widget = 'choice', options = GLIDE_SHAPES },
    },
  },
  velPattern = {
    expand = velPattern, mode = 'replace', dest = 'note', label = 'Vel Pattern', glyph = 'V',
    defaults = { pattern = { 100, 55 } },
    fields = {
      { field = 'pattern', label = 'Pattern', widget = 'choice', options = VEL_PATTERNS },
    },
  },
  lfo = {
    expand = lfo, mode = 'augment', dest = 'pb', dests = 'any', label = 'LFO', glyph = '∿',
    defaults = { wave = 'sine', period = { 1, 4 }, onset = 0 },
    fields = {
      { field = 'wave',    label = 'Wave',   widget = 'choice', options = WAVES },
      -- Always open to edit: a named wave hands the editor its own seed body, and the edit is what
      -- makes that body the truth.
      { field = 'pattern', label = 'Curve',  widget = 'pattern', kind = 'curve' },
      { field = 'period',  label = 'Period', widget = 'period' },
      { field = 'offset',  label = 'Offset', widget = 'int', base = 1, coarse = 8,
        quantity = 'magnitude', signed = true, frac = 0 },     -- the whole cycle's displacement from rest
      { field = 'scale',   label = 'Scale',  widget = 'int', base = 1, coarse = 8,
        quantity = 'magnitude', signed = true, frac = 0.5 },   -- amplitude; a negative mirrors the curve
      { field = 'onset',   label = 'Onset',  widget = 'int', base = 1, coarse = 4, min = 0, max = 16 },   -- QN ramp-in
    },
  },
}

-- Resting base for a cc-augment target with no authored automation: bipolar controllers
-- centre at 64, expression rests wide open, all else at 0. see docs/generators.md § pb and cc
generators.ccDefaultRest = { [8] = 64, [10] = 64, [11] = 127 }
for cc = 71, 79 do generators.ccDefaultRest[cc] = 64 end

-- Which kinds the fx palette offers, in order. Every kind works on either host: a region
-- arpeggiates its covered chord, a single note degenerates cleanly (arp -> retrig, one voice).
generators.modalOrder = { 'retrig', 'trill', 'arp', 'ostinato', 'chordStamp', 'velPattern', 'lfo', 'slide' }

-- One glyph per kind: a letter shapes notes, a wave mark paints a continuous stream. '?' is a
-- kind the registry has lost. see docs/generators.md § Conventions
function generators.glyphOf(kind)
  local meta = generators.kinds[kind]
  return meta and meta.glyph or '?'
end

-- One label per kind, and the one place a kind resolves to a name. A lost kind keeps its own
-- name in the mark: `? arp` says which stage went missing where a bare `?` would not.
function generators.labelOf(kind)
  local meta = generators.kinds[kind]
  return meta and meta.label or ('? ' .. tostring(kind))
end

----- Dest: a per-entry target, and what each target's numbers mean

--contract: dest is a per-entry param; registry dest is only its seed + note-vs-continuous marker
--shape: destProfile = { unit, rest, bipolar, magScale } -- continuous dests only ('pb' | cc number)

-- A fixed musical reference for pb magnitudes: a whole tone, deliberately not the take's bend range.
-- Scaling to the range would make one stage sound different in two takes.
local PB_REFERENCE = 200

function generators.destOf(params)
  local meta = generators.kinds[params.kind]
  return params.dest or (meta and meta.dest)
end

-- Polarity is the controller's own, and its default rest says it: one resting mid-scale swings
-- both ways, one at a rail only runs inward.
function generators.destProfile(dest)
  if dest == 'pb' then return { unit = 'cents', rest = 0, bipolar = true, magScale = PB_REFERENCE } end
  if type(dest) ~= 'number' then return nil end
  local rest    = generators.ccDefaultRest[dest] or 0
  local bipolar = rest > 0 and rest < 127
  return { unit = 'steps', rest = rest, bipolar = bipolar,
           magScale = bipolar and math.min(rest, 127 - rest) or math.max(rest, 127 - rest) }
end

-- The resting base a continuous augment sums onto when the target carries no authored automation.
-- Named despite being one line: the per-chain seed and per-channel fold must agree on this value.
function generators.restFor(dest)
  return generators.destProfile(dest).rest
end

-- Every dest a kind can serve. Fewer than two is no choice at all, and earns no Dest row.
function generators.destsFor(kind)
  local declared = generators.kinds[kind] and generators.kinds[kind].dests
  if not declared then return {} end
  local dests = {}
  if declared ~= 'cc' then dests[1] = 'pb' end
  if declared ~= 'pb' then for cc = 0, 127 do util.add(dests, cc) end end
  return dests
end

-- A field's bounds in the target's own units: a magnitude spans rest outwards as far as the dest
-- swings -- both ways if signed; anything else is fixed-unit and carries its bounds on the descriptor.
function generators.fieldRange(fd, dest)
  if fd.quantity == 'magnitude' then
    local mag = generators.destProfile(dest).magScale
    return fd.signed and -mag or 0, mag
  end
  return fd.min, fd.max
end

local DEST_FIELD = { field = 'dest', label = 'Dest', widget = 'dest' }

-- The rows a stage shows: a synthesised Dest row where the kind can serve more than one target,
-- then the kind's own fields. Synthesised once here rather than repeated per registry entry.
function generators.fieldsFor(entry)
  -- The fields are declared on the registry entry, so a kind the registry has lost has no rows --
  -- the heading alone, which labelOf still names.
  local meta = generators.kinds[entry.kind]
  if not meta then return {} end
  local fields = meta.fields
  if #generators.destsFor(entry.kind) < 2 then return fields end
  local rows = { DEST_FIELD }
  for _, fd in ipairs(fields) do util.add(rows, fd) end
  return rows
end

-- A kind's default entry: the dest it seeds from, its fixed-unit defaults, and every quantity field
-- resolved against that dest -- so one `frac` declaration reads correctly wherever it lands.
function generators.seed(kind)
  local meta  = generators.kinds[kind]
  local entry = util.assign({ kind = kind, dest = meta.dest }, meta.defaults)
  for _, fd in ipairs(meta.fields) do
    if fd.frac then
      local _, fullScale = generators.fieldRange(fd, meta.dest)
      entry[fd.field] = util.round(fd.frac * fullScale)
    end
  end
  return entry
end

-- Point an entry at another dest, carrying its magnitudes over as the same proportion of the new
-- target's swing. Equal references (CC 10 -> CC 8, both resting at 64) leave every value untouched.
function generators.retarget(entry, dest)
  local from = generators.destProfile(generators.destOf(entry)).magScale
  local to   = generators.destProfile(dest).magScale
  local out  = util.assign({}, entry)
  out.dest = dest
  if from == to then return out end
  for _, fd in ipairs(generators.kinds[entry.kind].fields) do
    if fd.quantity == 'magnitude' then out[fd.field] = util.round((entry[fd.field] or 0) * to / from) end
  end
  return out
end

----- Region park predicate + windows

-- A region parks its covered chord iff it carries a note-dest kind: the chain's final note stream
-- stands in for the members (ownership by dest, not mode). A husk (no kinds) parks nothing.
function generators.parksNotes(region)
  for _, params in ipairs(region.fx or {}) do
    if generators.kinds[params.kind] and generators.destOf(params) == 'note' then return true end
  end
  return false
end

-- Continuous targets a chain touches: set keyed 'pb' | <cc number>, empty for a pure-note
-- chain -- phase 5's per-target scopes key off it.
function generators.continuousTargets(fx)
  local targets = {}
  for _, params in ipairs(fx or {}) do
    local dest = generators.kinds[params.kind] and generators.destOf(params)
    if dest and dest ~= 'note' then targets[dest] = true end
  end
  return targets
end

-- The fold mode a chain presents for one continuous target: replace if any live stage targeting it
-- replaces, else augment -- a bypassed stage never counts, so it can't paint an overlapping chain's curve. see docs/generators.md § The chain
function generators.chainDestType(fx, target)
  for _, params in ipairs(fx or {}) do
    local meta = generators.kinds[params.kind]
    if meta and not params.bypass and generators.destOf(params) == target and meta.mode == 'replace' then
      return 'replace'
    end
  end
  return 'augment'
end

--shape: parkWindows -> { {evType='note'|'cc'|'pb', chan, cc?, id, startppq, endppq}, ... } (cc on cc windows only)
-- The single source for "what 4.5 parks over": a note window for a discrete-replace chord, a cc window
-- per continuous cc target and a pb window per continuous pb target (both replace or augment).
function generators.parkWindows(regions)
  local windows = {}
  local function window(evType, region, cc)
    util.add(windows, { evType = evType, chan = region.chan, cc = cc,
                        id = region.uuid,
                        startppq = region.startppq, endppq = region.endppq })
  end
  for _, region in ipairs(regions) do
    -- A note host self-parks via its own note spec, not a region note window -- suppress the note arm
    -- so a note host's region form only contributes continuous (cc/pb) windows.
    if generators.parksNotes(region) and not region.noteHost then window('note', region) end
    for _, params in ipairs(region.fx or {}) do
      local dest = generators.kinds[params.kind] and generators.destOf(params)
      -- cc and pb both park for replace and augment: the summed base + macros seat on the target
      -- lane (cc) or base lane (pb). see docs/generators.md § pb and cc
      if type(dest) == 'number' then window('cc', region, dest)
      elseif dest == 'pb' then window('pb', region) end
    end
  end
  return windows
end

----- Curve thinning (freeze to group)

-- A shape governs the segment to its *right*, so a point is safe to lose only if it and its
-- predecessor both ride linearly; a missing shape counts as non-linear.
local function ridesLinear(p) return p.shape == 'linear' end

-- Douglas-Peucker, measuring vertical deviation rather than perpendicular distance: perpendicular
-- would need a ticks-per-cent aspect ratio, under which "tolerance in cents" means nothing.
--contract: returns a new array of the input point tables themselves -- selects, never invents
--contract: tol bounds vertical error in the curve's own value unit; > tol keeps, == tol collapses
function generators.thinCurve(points, tol)
  local n, keep = #points, {}
  keep[1], keep[n] = true, true
  for i = 2, n - 1 do
    if not (ridesLinear(points[i]) and ridesLinear(points[i - 1])) then keep[i] = true end
  end

  -- Gather every run before recursing into any of them: the walk that reads `keep` must not also
  -- be the walk writing it.
  local runs, open = {}, 1
  for i = 2, n do
    if keep[i] then
      if i > open + 1 then util.add(runs, { first = open, last = i }) end
      open = i
    end
  end

  local function split(first, last)
    local a, b = points[first], points[last]
    local span = b.ppq - a.ppq
    local worst, worstErr = nil, tol   -- a point must beat the tolerance outright to earn its place
    for i = first + 1, last - 1 do
      -- A zero-width span has no chord to measure against, so nothing inside it may be dropped.
      local err = span > 0
        and math.abs(points[i].val - (a.val + (b.val - a.val) * (points[i].ppq - a.ppq) / span))
        or math.huge
      if err > worstErr then worst, worstErr = i, err end
    end
    if not worst then return end
    keep[worst] = true
    split(first, worst)
    split(worst, last)
  end
  for _, run in ipairs(runs) do split(run.first, run.last) end

  local out = {}
  for i = 1, n do
    if keep[i] then util.add(out, points[i]) end
  end
  return out
end

return generators
