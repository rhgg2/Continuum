-- Note-macro generators: pure expansions of per-note `fx` intent into derived realisation. They never
-- touch swing, raw pb or REAPER -- the seam rounds ppq -> raw, cents -> pb. see design/archive/note-macros.md

-- @noindex

--invariant: pure module, no state; a stage is fn(stream, host, params, ctx) -> { notes, delta }
--invariant: stream and host share one shape; stages read stream, host is the untouched original
--shape: stream/host = { window={startppq,endppq}, chan, lane, id, notes={ {pitch,vel,detune,ppq,endppq},.. }, pas={ {ppq,pitch,vel},.. }, ccs={ [cc]={ {ppq,val,shape,[tension]},.. } }, ats={ {ppq,val},.. }, pb={ {ppq,val,shape,[tension]},.. } }
--invariant: pb/ccs are absolute curves over the closed window (edge values seeded); pb val is cents
--invariant: ctx binds resolution, pbRangeCents, nextSameLaneNote, step(p,d,n), stepsBetween(a,b)
--invariant: periods are QN per the periodQN convention -- scalar or {num,den}
--shape: result = { notes = { {ppq,endppq,pitch,vel,detune}, ... }, delta = { {ppq,val,shape,[tension]}, ... } }
--shape: kinds[kind] = { expand, mode='replace'|'augment', dest='note'|'pb'|<cc>, dests?='any'|'pb'|'cc', label, glyph, defaults, fields }
--shape: field = { field, label, widget, base?, coarse?, min?, max?, options?, when?, kind?, poly?, quantity?='magnitude', signed?, frac? }
--invariant: mode is the stream fold -- replace overwrites the dest channel, augment adds to it
-- The copy shelf (design/fx-patterns.md § P4): named copies of pattern-param bodies, Save/Load
-- only. Params store bodies inline (§ P3.5); nothing references the shelf by name.
--shape: fxPatterns (ds project) = { [name] = { kind='notes'|'curve', lengthPpq, rpb=rowsPerBeat, root?=midiPitch, specs?={ {lane,ppq,endppq,pitch,vel,detune,delay,sample?},.. }, points?={ {ppq,val,shape,tension?},.. } } }
-- A pattern field descriptor may carry poly=true (per-kind, not per-body) to let a note editor author
-- overlapping lanes; absent/false pins every spec to lane 1. chordStamp sets it (a chord's voices).

local util = require 'util'

local generators = {}

local function periodTicks(period, resolution)
  local qn = type(period) == 'table' and period[1] / period[2] or period
  return qn * resolution
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
    })
    i = i + 1
  end
  return { notes = notes, delta = {} }
end

--contract: trill alternates host pitch with a note `step` scale-steps away (via ctx.step); every hit derived
local function trill(stream, host, params, ctx)
  local startL, endL = stream.window[1], stream.window[2]
  local step  = periodTicks(params.period, ctx.resolution)
  local h     = stream.notes[1]
  if not h then return { notes = {}, delta = {} } end   -- empty membership (bare region)
  -- The alternation note: `step` scale steps from the host, resolved through the temper.
  local altPitch, altDetune = ctx.step(h.pitch, h.detune or 0, params.step or 0)
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
          util.add(notes, { ppq = onset, endppq = endppq,
                                pitch = voice.pitch, vel = spec.vel, detune = voice.detune or 0 })
        end
      end
    end
    base = base + loop
  end
  return { notes = notes, delta = {} }
end

--contract: chord-stamp stamps a poly pattern on each region member; lane-1 is the pattern's root
--contract: rebase whole temper steps via ctx.stepsBetween+ctx.step; voice keeps trigger vel/window
--contract: no lane-1 note in the pattern -> inert (empty result)
-- Voices carry true temper-step detune (intent); on one channel only lane 1's detune realises via pb, so a
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
    local steps = ctx.stepsBetween(ref, trig)  -- root -> trigger, in whole temper steps
    for _, spec in ipairs(specs) do
      local pitch, detune = ctx.step(spec.pitch, spec.detune or 0, steps)
      util.add(notes, { ppq = trig.ppq, endppq = trig.endppq,
                        pitch = pitch, detune = detune, vel = trig.vel })
    end
  end
  return { notes = notes, delta = {} }
end

--contract: sine -> delta breakpoints in the dest's own units; depth at 1/period QN, unit-naive
--contract: breakpoints at sine extrema, 'slow'-shaped; linear ramp-in over onset QN
--contract: a terminal 0 at window end eases the last extremum back -- shape, not reset (tm closes)
local function sine(stream, host, params, ctx)
  local startL, endL = stream.window[1], stream.window[2]
  local period = periodTicks(params.period, ctx.resolution)   -- ticks per cycle
  local depth  = params.depth or 0
  local onset  = (params.onset or 0) * ctx.resolution          -- ramp-in, ticks

  -- Extrema-only breakpoints; 'slow' bridges each pair as a half-cosine. Anchored at 0 both ends: the
  -- terminal 0 is the half-cosine ease off the last extremum, not the re-centre (tm closes the window).
  local delta = { { ppq = startL, val = 0, shape = 'slow' } }
  local k  = 0
  local at = startL + period / 4
  while at < endL do
    local gain = onset > 0 and math.min(1, (at - startL) / onset) or 1
    local sign = k % 2 == 0 and 1 or -1
    util.add(delta, { ppq = at, val = sign * gain * depth, shape = 'slow' })
    k  = k + 1
    at = startL + period / 4 + k * period / 2
  end
  util.add(delta, { ppq = endL, val = 0, shape = 'slow' })
  return { notes = {}, delta = delta }
end

-- Cents between two notes' realised pitches. The microtonal offset already rides
-- in detune, so this is pure note arithmetic -- no temper needed.
local function interval(a, b)
  return (b.pitch - a.pitch) * 100 + ((b.detune or 0) - (a.detune or 0))
end

--contract: slide glide-in -> lane-1 pb-delta; slur to target over `over` QN (tm closes the window)
--contract: target 'next' = interval to next same-lane note; 'fixed' = params.cents; pb-range clamps
--contract: no next note or unison target -> empty delta (channel untouched)
local function slide(stream, host, params, ctx)
  local startL, endL = stream.window[1], stream.window[2]
  local h = stream.notes[1]
  local target
  if params.target == 'next' then
    -- keyed on the original host note's identity, so it reads host, not the folded stream
    local nxt = ctx.nextSameLaneNote and ctx.nextSameLaneNote(host)
    if not nxt then return { notes = {}, delta = {} } end
    target = interval(h, nxt)
  else
    target = params.cents or 0
  end
  local maxBend = ctx.pbRangeCents
  if maxBend then target = math.max(-maxBend, math.min(maxBend, target)) end
  if target == 0 then return { notes = {}, delta = {} } end

  -- snap keeps the arrival (target) and the handoff (0) on distinct wire ppqs --
  -- the seat reconcile keys on ppq. see docs/generators.md § pb and cc
  local snap   = math.max(1, ctx.resolution / 16)
  local over   = periodTicks(params.over, ctx.resolution)
  local arrive = math.max(startL, endL - snap)
  local glideStart = math.max(startL, arrive - over)

  local delta = {}
  local function bp(ppq, val, shape) util.add(delta, { ppq = ppq, val = val, shape = shape }) end
  bp(startL, 0, glideStart > startL and 'step' or 'slow')   -- hold true pitch until the slur
  if glideStart > startL then bp(glideStart, 0, 'slow') end   -- slur begins (half-cosine ease)
  bp(arrive, target, 'step')                                -- arrived; hold to tm's close at endL-1
  return { notes = {}, delta = delta }
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
--contract: breakpoints are a displacement from the dest's rest, which the augment fold lays them on
--contract: each cycle stretches the body lengthPpq -> period ticks; both window edges seeded
local function lfo(stream, host, params, ctx)
  local body   = params.pattern
  local loop   = body and body.lengthPpq
  local points = body and body.points
  if not (loop and loop > 0 and points and #points > 0) then return { notes = {}, delta = {} } end
  local startL, endL = stream.window[1], stream.window[2]
  local period  = periodTicks(params.period, ctx.resolution)
  local stretch = period / loop
  local offset, amp = params.offset or 0, params.scale or 0
  local function val(norm) return util.round(offset + amp * norm) end

  -- Seed startL (phase 0); tile interior cycles, skipping the ppq==loop endpoint (owned by the next
  -- cycle's phase 0, or by the endL seed) so a loop-closed curve emits no duplicate boundary breakpoint.
  local delta = { { ppq = startL, val = val(curveAt(points, 0)),
                    shape = points[1].shape, tension = points[1].tension } }
  local base = startL
  while base < endL do
    for _, p in ipairs(points) do
      local at = base + p.ppq * stretch
      if at > startL and at < endL and p.ppq < loop then
        util.add(delta, { ppq = at, val = val(p.val), shape = p.shape, tension = p.tension })
      end
    end
    base = base + period
  end
  local phaseEnd = ((endL - startL) % period) / stretch   -- authored ppq at the window's trailing edge
  util.add(delta, { ppq = endL, val = val(curveAt(points, phaseEnd)), shape = 'linear' })
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
                      detune = note.detune or 0 })
  end
  return { notes = notes, delta = {} }
end

----- Generator registry

-- One entry per kind: the realisation fn (`expand`) plus all metadata a kind ships with. see
-- docs/generators.md § The chain

-- Shared QN-fraction period ladder; every periodic kind tempo-syncs the same way.
local PERIODS = { { l = '1/2', v = { 1, 2 } }, { l = '1/3', v = { 1, 3 } },
                  { l = '1/4', v = { 1, 4 } }, { l = '1/6', v = { 1, 6 } },
                  { l = '1/8', v = { 1, 8 } } }
local SLIDE_TARGETS = { { l = 'Next', v = 'next' }, { l = 'Fixed', v = 'fixed' } }
local DIR_OPTIONS   = { { l = 'Up', v = 'up' }, { l = 'Down', v = 'down' }, { l = 'Up/Down', v = 'updown' } }
local VEL_PATTERNS  = { { l = '> .',     v = { 100, 55 } },
                        { l = '> . .',   v = { 100, 55, 70 } },
                        { l = '> . . .', v = { 100, 55, 70, 55 } } }

generators.kinds = {
  retrig = {
    expand = retrig, mode = 'replace', dest = 'note', label = 'Retrig', glyph = 'R',
    defaults = { period = { 1, 4 }, ramp = 0 },
    fields = {
      { field = 'period', label = 'Period', widget = 'choice', options = PERIODS },
      { field = 'ramp',   label = 'Ramp',   widget = 'int', base = 1, coarse = 10, min = -127, max = 127 },
    },
  },
  trill = {
    expand = trill, mode = 'replace', dest = 'note', label = 'Trill', glyph = 'T',
    defaults = { period = { 1, 4 }, step = 2 },
    fields = {
      { field = 'period', label = 'Period', widget = 'choice', options = PERIODS },
      { field = 'step',   label = 'Step',   widget = 'int', base = 1, coarse = 12, min = -24, max = 24 },  -- signed scale steps
    },
  },
  arp = {
    expand = arp, mode = 'replace', dest = 'note', label = 'Arp', glyph = 'A',
    defaults = { period = { 1, 4 }, dir = 'up' },
    fields = {
      { field = 'period', label = 'Period', widget = 'choice', options = PERIODS },
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
  sine = {
    expand = sine, mode = 'augment', dest = 'pb', dests = 'any', label = 'Sine', glyph = '∿',
    defaults = { period = { 1, 2 }, onset = 1 },
    fields = {
      { field = 'period', label = 'Period', widget = 'choice', options = PERIODS },
      { field = 'depth',  label = 'Depth',  widget = 'int', base = 1, coarse = 10,
        quantity = 'magnitude', frac = 0.15 },   -- 30 cents on pb, 9 steps on a bipolar cc
      { field = 'onset',  label = 'Onset',  widget = 'int', base = 1, coarse = 4,  min = 0, max = 16 },   -- QN ramp-in
    },
  },
  slide = {
    expand = slide, mode = 'augment', dest = 'pb', dests = 'pb', label = 'Slide', glyph = '/',
    defaults = { over = { 1, 2 }, target = 'next' },
    fields = {
      { field = 'over',   label = 'Glide',    widget = 'choice', options = PERIODS },
      { field = 'target', label = 'To',       widget = 'choice', options = SLIDE_TARGETS },
      -- cents demand, edited as host-relative temper steps; shown only for a fixed slide.
      { field = 'cents',  label = 'Interval', widget = 'stepInterval',
        when = function(e) return e.target == 'fixed' end },
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
    expand = lfo, mode = 'augment', dest = 'pb', dests = 'any', label = 'Curve LFO', glyph = '~',
    defaults = { period = { 1, 4 },
                 pattern = { kind = 'curve', domain = 'normalized', display = 'bipolar', points = {} } },
    fields = {
      { field = 'pattern', label = 'Curve',  widget = 'pattern', kind = 'curve' },
      { field = 'period',  label = 'Period', widget = 'choice', options = PERIODS },
      { field = 'offset',  label = 'Offset', widget = 'int', base = 1, coarse = 8,
        quantity = 'magnitude', signed = true, frac = 0 },     -- the whole cycle's displacement from rest
      { field = 'scale',   label = 'Scale',  widget = 'int', base = 1, coarse = 8,
        quantity = 'magnitude', signed = true, frac = 0.5 },   -- amplitude; a negative mirrors the curve
    },
  },
}

-- Resting base for a cc-augment target with no authored automation: bipolar controllers
-- centre at 64, expression rests wide open, all else at 0. see docs/generators.md § pb and cc
generators.ccDefaultRest = { [8] = 64, [10] = 64, [11] = 127 }
for cc = 71, 79 do generators.ccDefaultRest[cc] = 64 end

-- Which kinds the fx palette offers, in order. Every kind works on either host: a region
-- arpeggiates its covered chord, a single note degenerates cleanly (arp -> retrig, one voice).
generators.modalOrder = { 'retrig', 'trill', 'arp', 'ostinato', 'chordStamp', 'velPattern', 'sine', 'slide', 'lfo' }

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
-- chain -- phase 5's per-target scopes key off it. see design/interval-dirt.md § phase 5
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
-- predecessor both ride linearly; a missing shape counts as non-linear. see design/archive/fx-freeze.md § Freeze to group
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
