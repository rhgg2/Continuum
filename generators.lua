-- Note-macro generators: pure expansions of per-note `fx` intent into derived realisation. They never
-- touch swing, raw pb or REAPER -- the seam rounds ppq -> raw, cents -> pb. see design/archive/note-macros.md

-- @noindex

--invariant: pure module, no state; a stage is fn(stream, host, params, ctx) -> { notes, delta }
--invariant: stream and host share one shape; stages read stream, host is the untouched original
--shape: stream/host = { window={startppq,endppq}, chan, lane, id, notes={ {pitch,vel,detune,ppq,endppq},.. }, pas={ {ppq,pitch,vel},.. }, ccs={ [cc]={ {ppq,val,shape},.. } }, ats={ {ppq,val},.. }, pb={ {ppq,val,shape},.. } }
--invariant: pb/ccs are absolute curves over the closed window (edge values seeded); pb val is cents
--invariant: ctx binds resolution, pbRangeCents, nextSameLaneNote(host), step(pitch,detune,n)
--invariant: periods are QN per the periodQN convention -- scalar or {num,den}
--shape: result = { notes = { {ppq,endppq,pitch,vel,detune}, ... }, delta = { {ppq,val,shape,[tension]}, ... } }
--shape: kinds[kind] = { expand, mode='replace'|'augment', dest='note'|'pb'|<cc>, label, defaults, fields }
--invariant: mode is the stream fold -- replace overwrites the dest channel, augment adds to it
-- P2 store (design/fx-patterns.md § Data model): the project pattern library a `pattern`/`curve`
-- generator param names into. No consumer yet; re-homes to patternStore at P3.
--shape: fxPatterns (ds project) = { [name] = { kind='notes'|'curve', lengthPpq, root?=midiPitch, specs?={ {lane=1,ppq,endppq,pitch,vel,detune,delay,sample?},.. }, points?={ {ppq,val,shape,tension?},.. } } }

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

--contract: vibrato -> lane-1 pb-delta breakpoints in cents; sine of depth cents at 1/period QN
--contract: breakpoints at sine extrema, 'slow'-shaped; linear ramp-in over onset QN
--contract: returns to 0 (centre) at window end -- no residual bend on the channel
local function vibrato(stream, host, params, ctx)
  local startL, endL = stream.window[1], stream.window[2]
  local period = periodTicks(params.period, ctx.resolution)   -- ticks per cycle
  local depth  = params.depth or 0
  local onset  = (params.onset or 0) * ctx.resolution          -- ramp-in, ticks

  -- Extrema-only breakpoints; 'slow' bridges each pair as a half-cosine.
  -- Anchored at 0 both ends; the terminal 0 re-centres the channel.
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

--contract: slide glide-in -> lane-1 pb-delta; slur to target over `over` QN; re-centres at end
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
  -- the seat reconcile keys on ppq. see design/note-macros-v2.md § Continuous pb
  local snap   = math.max(1, ctx.resolution / 16)
  local over   = periodTicks(params.over, ctx.resolution)
  local arrive = math.max(startL, endL - snap)
  local glideStart = math.max(startL, arrive - over)

  local delta = {}
  local function bp(ppq, val, shape) util.add(delta, { ppq = ppq, val = val, shape = shape }) end
  bp(startL, 0, glideStart > startL and 'step' or 'slow')   -- hold true pitch until the slur
  if glideStart > startL then bp(glideStart, 0, 'slow') end   -- slur begins (half-cosine ease)
  bp(arrive, target, 'step')                                -- arrived; hold to the handoff
  bp(endL, 0, 'step')                                       -- re-centre: next note sounds true
  return { notes = {}, delta = delta }
end

--contract: auto-pan -> cc-delta breakpoints in cc steps; sine of depth steps at 1/period QN
--contract: extrema-only, 'slow'-shaped; anchored 0 at both ends so the channel re-centres
local function autopan(stream, host, params, ctx)
  local startL, endL = stream.window[1], stream.window[2]
  local period = periodTicks(params.period, ctx.resolution)
  local depth  = params.depth or 0
  local delta  = { { ppq = startL, val = 0, shape = 'slow' } }
  local k, at = 0, startL + period / 4
  while at < endL do
    local sign = k % 2 == 0 and 1 or -1
    util.add(delta, { ppq = at, val = sign * depth, shape = 'slow' })
    k  = k + 1
    at = startL + period / 4 + k * period / 2
  end
  util.add(delta, { ppq = endL, val = 0, shape = 'slow' })
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

--contract: lfo tiles a normalized curve at 1/period QN, mapping each val by centre + scale
--contract: emits absolute cc breakpoints (augment onto rest), clamped 0..127; dest cc1, no UI yet
--contract: each cycle stretches the body lengthPpq -> period ticks; both window edges seeded
local function lfo(stream, host, params, ctx)
  local body   = params.pattern
  local loop   = body and body.lengthPpq
  local points = body and body.points
  if not (loop and loop > 0 and points and #points > 0) then return { notes = {}, delta = {} } end
  local startL, endL = stream.window[1], stream.window[2]
  local period  = periodTicks(params.period, ctx.resolution)
  local stretch = period / loop
  local centre, amp = params.centre or 64, params.scale or 0
  local function ccVal(norm) return util.clamp(util.round(centre + amp * norm), 0, 127) end

  -- Seed startL (phase 0); tile interior cycles, skipping the ppq==loop endpoint (owned by the next
  -- cycle's phase 0, or by the endL seed) so a loop-closed curve emits no duplicate boundary breakpoint.
  local delta = { { ppq = startL, val = ccVal(curveAt(points, 0)), shape = points[1].shape } }
  local base = startL
  while base < endL do
    for _, p in ipairs(points) do
      local at = base + p.ppq * stretch
      if at > startL and at < endL and p.ppq < loop then
        delta[#delta + 1] = { ppq = at, val = ccVal(p.val), shape = p.shape, tension = p.tension }
      end
    end
    base = base + period
  end
  local phaseEnd = ((endL - startL) % period) / stretch   -- authored ppq at the window's trailing edge
  delta[#delta + 1] = { ppq = endL, val = ccVal(curveAt(points, phaseEnd)), shape = 'linear' }
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
-- design/note-macros-v2.md § The fx chain

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
    expand = retrig, mode = 'replace', dest = 'note', label = 'Retrig',
    defaults = { period = { 1, 4 }, ramp = 0 },
    fields = {
      { field = 'period', label = 'Period', widget = 'choice', options = PERIODS },
      { field = 'ramp',   label = 'Ramp',   widget = 'int', base = 1, coarse = 10, min = -127, max = 127 },
    },
  },
  trill = {
    expand = trill, mode = 'replace', dest = 'note', label = 'Trill',
    defaults = { period = { 1, 4 }, step = 2 },
    fields = {
      { field = 'period', label = 'Period', widget = 'choice', options = PERIODS },
      { field = 'step',   label = 'Step',   widget = 'int', base = 1, coarse = 12, min = -24, max = 24 },  -- signed scale steps
    },
  },
  arp = {
    expand = arp, mode = 'replace', dest = 'note', label = 'Arp',
    defaults = { period = { 1, 4 }, dir = 'up' },
    fields = {
      { field = 'period', label = 'Period', widget = 'choice', options = PERIODS },
      { field = 'dir',    label = 'Dir',    widget = 'choice', options = DIR_OPTIONS },
    },
  },
  ostinato = {
    expand = ostinato, mode = 'replace', dest = 'note', label = 'Ostinato',
    defaults = { pattern = { kind = 'notes', specs = {} } },
    fields = {
      { field = 'pattern', label = 'Pattern', widget = 'pattern', kind = 'notes' },
    },
  },
  vibrato = {
    expand = vibrato, mode = 'augment', dest = 'pb', label = 'Vibrato',
    defaults = { period = { 1, 2 }, depth = 30, onset = 1 },
    fields = {
      { field = 'period', label = 'Period', widget = 'choice', options = PERIODS },
      { field = 'depth',  label = 'Depth',  widget = 'int', base = 1, coarse = 10, min = 0, max = 200 },  -- cents
      { field = 'onset',  label = 'Onset',  widget = 'int', base = 1, coarse = 4,  min = 0, max = 16 },   -- QN ramp-in
    },
  },
  slide = {
    expand = slide, mode = 'augment', dest = 'pb', label = 'Slide',
    defaults = { over = { 1, 2 }, target = 'next' },
    fields = {
      { field = 'over',   label = 'Glide',    widget = 'choice', options = PERIODS },
      { field = 'target', label = 'To',       widget = 'choice', options = SLIDE_TARGETS },
      -- cents demand, edited as host-relative temper steps; shown only for a fixed slide.
      { field = 'cents',  label = 'Interval', widget = 'stepInterval',
        when = function(e) return e.target == 'fixed' end },
    },
  },
  autopan = {
    expand = autopan, mode = 'augment', dest = 10, label = 'Auto-pan',
    defaults = { period = { 1, 2 }, depth = 32 },
    fields = {
      { field = 'period', label = 'Period', widget = 'choice', options = PERIODS },
      { field = 'depth',  label = 'Depth',  widget = 'int', base = 1, coarse = 10, min = 0, max = 63 },  -- cc steps from centre
    },
  },
  velPattern = {
    expand = velPattern, mode = 'replace', dest = 'note', label = 'Vel Pattern',
    defaults = { pattern = { 100, 55 } },
    fields = {
      { field = 'pattern', label = 'Pattern', widget = 'choice', options = VEL_PATTERNS },
    },
  },
  lfo = {
    expand = lfo, mode = 'augment', dest = 1, label = 'LFO',
    defaults = { period = { 1, 4 }, centre = 64, scale = 63,
                 pattern = { kind = 'curve', domain = 'normalized', display = 'bipolar', points = {} } },
    fields = {
      { field = 'pattern', label = 'Curve',  widget = 'pattern', kind = 'curve' },
      { field = 'period',  label = 'Period', widget = 'choice', options = PERIODS },
      { field = 'centre',  label = 'Centre', widget = 'int', base = 1, coarse = 8, min = 0,    max = 127 },
      { field = 'scale',   label = 'Scale',  widget = 'int', base = 1, coarse = 8, min = -127, max = 127 },  -- amplitude, cc steps
    },
  },
}

-- Resting base for a cc-augment target with no authored automation: bipolar controllers
-- centre at 64, expression rests wide open, all else at 0. see design/note-macros-v2.md § Continuous cc
generators.ccDefaultRest = { [8] = 64, [10] = 64, [11] = 127 }
for cc = 71, 79 do generators.ccDefaultRest[cc] = 64 end

-- Which kinds the fxEdit modal offers, in order. Every kind works on either host: a region
-- arpeggiates its covered chord, a single note degenerates cleanly (arp -> retrig, one voice).
generators.modalOrder = { 'retrig', 'trill', 'arp', 'ostinato', 'velPattern', 'vibrato', 'slide', 'autopan', 'lfo' }

----- Region park predicate + windows

-- A region parks its covered chord iff it carries a note-dest kind: the chain's final note stream
-- stands in for the members (ownership by dest, not mode). A husk (no kinds) parks nothing.
function generators.parksNotes(region)
  for _, params in ipairs(region.fx or {}) do
    local meta = generators.kinds[params.kind]
    if meta and meta.dest == 'note' then return true end
  end
  return false
end

-- Continuous targets a chain touches: set keyed 'pb' | <cc number>, empty for a pure-note
-- chain -- phase 5's per-target scopes key off it. see design/interval-dirt.md § phase 5
function generators.continuousTargets(fx)
  local targets = {}
  for _, params in ipairs(fx or {}) do
    local meta = generators.kinds[params.kind]
    if meta and meta.dest ~= 'note' then targets[meta.dest] = true end
  end
  return targets
end

-- The fold mode a chain presents for one continuous target: replace if any stage targeting it
-- replaces, else augment -- drives cross-chain layering (a later replace wins). see design/note-macros-v2.md § The fx chain
function generators.chainDestType(fx, target)
  for _, params in ipairs(fx or {}) do
    local meta = generators.kinds[params.kind]
    if meta and meta.dest == target and meta.mode == 'replace' then return 'replace' end
  end
  return 'augment'
end

--shape: parkWindows -> { {evType='note'|'cc'|'pb', chan, cc?, startppq, endppq}, ... } (cc on cc windows only)
-- The single source for "what 4.5 parks over": a note window for a discrete-replace chord, a cc window
-- per continuous cc target and a pb window per continuous pb target (both replace or augment).
function generators.parkWindows(regions)
  local windows = {}
  local function window(evType, region, cc)
    util.add(windows, { evType = evType, chan = region.chan, cc = cc,
                        startppq = region.startppq, endppq = region.endppq })
  end
  for _, region in ipairs(regions) do
    -- A note host self-parks via its own note spec, not a region note window -- suppress the note arm
    -- so a note host's region form only contributes continuous (cc/pb) windows.
    if generators.parksNotes(region) and not region.noteHost then window('note', region) end
    for _, params in ipairs(region.fx or {}) do
      local meta = generators.kinds[params.kind]
      if meta then
        -- cc and pb both park for replace and augment: the summed base + macros seat on the target
        -- lane (cc) or base lane (pb). see design/note-macros-v2.md § Continuous cc / § Continuous pb
        if type(meta.dest) == 'number' then window('cc', region, meta.dest)
        elseif meta.dest == 'pb' then window('pb', region) end
      end
    end
  end
  return windows
end

return generators
