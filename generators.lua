-- Note-macro generators: pure expansions of per-note `fx` intent into
-- derived realisation. A generator never touches swing, raw pb, or
-- REAPER -- it speaks logical frame and intent units only; the rebuild
-- seam rounds ppqL -> raw and maps cents -> pb. See design/archive/note-macros.md
-- § Generators.
-- @noindex

--invariant: pure module -- no module-level state; a generator is fn(host, params, ctx) -> { notes, delta }
--invariant: host = windowed channel input streams: notes, pas, ccs, ats (logical, intent units)
--shape: host = { window={startppqL,endppqL}, chan, lane, id, notes={ {pitch,vel,detune,ppqL,endppqL},.. }, pas={ {ppqL,pitch,vel},.. }, ccs={ [cc]={ {ppqL,val},.. } }, ats={ {ppqL,val},.. } }
--invariant: ctx binds resolution, pbRangeCents, nextSameLaneNote(host), step(pitch,detune,n)
--invariant: periods are QN per the periodQN convention -- scalar or {num,den}
--shape: result = { notes = { {ppqL,endppqL,pitch,vel,detune}, ... }, delta = { {ppqL,val,shape,[tension]}, ... } }
--shape: kinds[kind] = { expand, mode='replace'|'augment', dest='note'|'pb'|<cc>, label, defaults, fields }

local generators = {}

local function periodTicks(period, resolution)
  local qn = type(period) == 'table' and period[1] / period[2] or period
  return qn * resolution
end

--contract: retrig fills the host window with evenly-spaced same-pitch fxNotes 2..N (host is fxNote 1)
--contract: velocity ramps params.ramp per fxNote, clamped 1..127; detune inherited from the host verbatim
local function retrig(host, params, ctx)
  local startL, endL = host.window[1], host.window[2]
  local step  = periodTicks(params.period, ctx.resolution)
  local h     = host.notes[1]
  local ramp  = params.ramp or 0
  local notes = {}
  local i = 1
  while startL + i * step < endL do
    notes[#notes + 1] = {
      ppqL    = startL + i * step,
      endppqL = math.min(startL + (i + 1) * step, endL),
      pitch   = h.pitch,
      vel     = math.max(1, math.min(127, h.vel + i * ramp)),
      detune  = h.detune or 0,
    }
    i = i + 1
  end
  return { notes = notes, delta = {} }
end

--contract: trill alternates host pitch with a note `step` scale-steps away (via ctx.step); host is fxNote 1
local function trill(host, params, ctx)
  local startL, endL = host.window[1], host.window[2]
  local step  = periodTicks(params.period, ctx.resolution)
  local h     = host.notes[1]
  -- The alternation note: `step` scale steps from the host, resolved through the temper.
  local altPitch, altDetune = ctx.step(h.pitch, h.detune or 0, params.step or 0)
  local notes = {}
  local i = 1
  while startL + i * step < endL do
    local odd = i % 2 == 1   -- fxNote 1 (the host) is even tile 0; odd tiles carry the alternation
    notes[#notes + 1] = {
      ppqL    = startL + i * step,
      endppqL = math.min(startL + (i + 1) * step, endL),
      pitch   = odd and altPitch  or h.pitch,
      vel     = h.vel,
      detune  = odd and altDetune or (h.detune or 0),
    }
    i = i + 1
  end
  return { notes = notes, delta = {} }
end

-- Notes sounding at logical tick `t`, ascending by realised pitch (semitone*100 + detune cents).
local function playingAt(events, t)
  local active = {}
  for _, n in ipairs(events) do
    if n.ppqL <= t and t < n.endppqL then active[#active + 1] = n end
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
--contract: hits abut (endppqL = next step), clamped to the window; vel/detune from the voice
local function arp(host, params, ctx)
  local startL, endL = host.window[1], host.window[2]
  local step = periodTicks(params.period, ctx.resolution)
  local dir  = params.dir or 'up'
  local notes = {}
  local i = 0
  local at = startL
  while at < endL do
    local active = playingAt(host.notes, at)
    if #active > 0 then
      local src = active[arpIndex(#active, dir, i) + 1]
      notes[#notes + 1] = {
        ppqL = at, endppqL = math.min(at + step, endL),
        pitch = src.pitch, vel = src.vel, detune = src.detune or 0,
      }
    end
    i = i + 1
    at = startL + i * step
  end
  return { notes = notes, delta = {} }
end

-- 14-bit carrier priority: MSB n, LSB n+32 (REAPER interpolates only that pair).
-- Unlikely-authored first; conventional last. see design/archive/note-macros.md § Delta-code allocation
local CARRIER_PRIORITY = {
  20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,  -- undefined / general (coldest)
  3, 9, 14, 15,                                     -- other undefined
  16, 17, 18, 19,                                   -- general purpose
  12, 13, 6,                                        -- effect control, data entry
  2, 4, 5, 8,                                        -- breath, foot, portamento, balance
  1, 11, 10, 7, 0,                                  -- conventional (last)
}

--contract: first priority MSB n where neither n nor n+32 is in `occupied`; nil if saturated
function generators.allocateCarrier(occupied)
  for _, n in ipairs(CARRIER_PRIORITY) do
    if not occupied[n] and not occupied[n + 32] then return n end
  end
end

--contract: vibrato -> lane-1 pb-delta breakpoints in cents; sine of depth cents at 1/period QN
--contract: breakpoints at sine extrema, 'slow'-shaped; linear ramp-in over onset QN
--contract: carrier returns to 0 (centre) at window end -- no residual bend on the channel
local function vibrato(host, params, ctx)
  local startL, endL = host.window[1], host.window[2]
  local period = periodTicks(params.period, ctx.resolution)   -- ticks per cycle
  local depth  = params.depth or 0
  local onset  = (params.onset or 0) * ctx.resolution          -- ramp-in, ticks

  -- Extrema-only breakpoints; 'slow' bridges each pair as a half-cosine.
  -- Anchored at 0 both ends; the terminal 0 re-centres the channel carrier.
  local delta = { { ppqL = startL, val = 0, shape = 'slow' } }
  local k  = 0
  local at = startL + period / 4
  while at < endL do
    local gain = onset > 0 and math.min(1, (at - startL) / onset) or 1
    local sign = k % 2 == 0 and 1 or -1
    delta[#delta + 1] = { ppqL = at, val = sign * gain * depth, shape = 'slow' }
    k  = k + 1
    at = startL + period / 4 + k * period / 2
  end
  delta[#delta + 1] = { ppqL = endL, val = 0, shape = 'slow' }
  return { notes = {}, delta = delta }
end

-- Cents between two notes' realised pitches. The microtonal offset already rides
-- in detune, so this is pure note arithmetic -- no temper needed.
local function interval(a, b)
  return (b.pitch - a.pitch) * 100 + ((b.detune or 0) - (a.detune or 0))
end

--contract: slide glide-in -> lane-1 pb-delta; slur to target over `over` QN; re-centres at end
--contract: target 'next' = interval to next same-lane note; 'fixed' = params.cents; pb-range clamps
--contract: no next note or unison target -> empty delta (carrier untouched)
local function slide(host, params, ctx)
  local startL, endL = host.window[1], host.window[2]
  local h = host.notes[1]
  local target
  if params.target == 'next' then
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
  -- the carrier reconcile keys on (cc, ppq). see design/archive/note-macros.md § Continuous realisation
  local snap   = math.max(1, ctx.resolution / 16)
  local over   = periodTicks(params.over, ctx.resolution)
  local arrive = math.max(startL, endL - snap)
  local glideStart = math.max(startL, arrive - over)

  local delta = {}
  local function bp(ppqL, val, shape) delta[#delta + 1] = { ppqL = ppqL, val = val, shape = shape } end
  bp(startL, 0, glideStart > startL and 'square' or 'slow')   -- hold true pitch until the slur
  if glideStart > startL then bp(glideStart, 0, 'slow') end   -- slur begins (half-cosine ease)
  bp(arrive, target, 'square')                                -- arrived; hold to the handoff
  bp(endL, 0, 'square')                                       -- re-centre: next note sounds true
  return { notes = {}, delta = delta }
end

----- Generator registry

-- One entry per kind: the realisation fn (`expand`) plus all metadata a kind ships with. `mode`
-- (replace|augment) and `dest` ('note' for structural kinds, else the continuous wire target) are
-- independent axes -- today every continuous kind is augment, but continuous-replace (A4) and
-- discrete-augment are expressible. `dest` is a default hint the user may override per fx-entry
-- later. The fxEdit modal builds itself from label / defaults / fields.

-- Shared QN-fraction period ladder; every periodic kind tempo-syncs the same way.
local PERIODS = { { l = '1/2', v = { 1, 2 } }, { l = '1/3', v = { 1, 3 } },
                  { l = '1/4', v = { 1, 4 } }, { l = '1/6', v = { 1, 6 } },
                  { l = '1/8', v = { 1, 8 } } }
local SLIDE_TARGETS = { { l = 'Next', v = 'next' }, { l = 'Fixed', v = 'fixed' } }
local DIR_OPTIONS   = { { l = 'Up', v = 'up' }, { l = 'Down', v = 'down' }, { l = 'Up/Down', v = 'updown' } }

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
}

-- Which kinds the fxEdit modal offers, in order. arp is registered (region-usable) but not yet
-- surfaced -- a chord arp wants a region host and a host-aware kind list (deferred).
generators.modalOrder = { 'retrig', 'trill', 'vibrato', 'slide' }

return generators
