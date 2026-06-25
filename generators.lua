-- Note-macro generators: pure expansions of per-note `fx` intent into
-- derived realisation. A generator never touches swing, raw pb, or
-- REAPER -- it speaks logical frame and intent units only; the rebuild
-- seam rounds ppqL -> raw and maps cents -> pb. See design/note-macros.md
-- § Generators.
-- @noindex

--invariant: pure module -- no module-level state; a generator is fn(host, params, ctx) -> { notes, delta }
--invariant: host = { window={startppqL,endppqL}, events={note,...}, id=uuid, chan }
--invariant: ctx binds resolution, pbRangeCents, nextLane1Note(host) -- flush-time
--invariant: periods are QN per the periodQN convention -- scalar or {num,den}
--shape: result = { notes = { {ppqL,endppqL,pitch,vel,detune}, ... }, delta = { {ppqL,val,shape,[tension]}, ... } }

local M = {}

local function periodTicks(period, resolution)
  local qn = type(period) == 'table' and period[1] / period[2] or period
  return qn * resolution
end

--contract: retrig fills the host window with evenly-spaced same-pitch fxNotes 2..N (host is fxNote 1)
--contract: velocity ramps params.ramp per fxNote, clamped 1..127; detune inherited from the host verbatim
function M.retrig(host, params, ctx)
  local startL, endL = host.window[1], host.window[2]
  local step  = periodTicks(params.period, ctx.resolution)
  local h     = host.events[1]
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

-- Kinds whose realisation is a continuous delta stream (carrier ccs), not structural notes.
-- Value = wire target ('pb' or cc number); truthy = "is continuous". Drives carrier allocation.
M.continuous = { vibrato = 'pb', slide = 'pb' }

-- 14-bit carrier priority: MSB n, LSB n+32 (REAPER interpolates only that pair).
-- Unlikely-authored first; conventional last. see design/note-macros.md § Delta-code allocation
local CARRIER_PRIORITY = {
  20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,  -- undefined / general (coldest)
  3, 9, 14, 15,                                     -- other undefined
  16, 17, 18, 19,                                   -- general purpose
  12, 13, 6,                                        -- effect control, data entry
  2, 4, 5, 8,                                        -- breath, foot, portamento, balance
  1, 11, 10, 7, 0,                                  -- conventional (last)
}

--contract: first priority MSB n where neither n nor n+32 is in `occupied`; nil if saturated
function M.allocateCarrier(occupied)
  for _, n in ipairs(CARRIER_PRIORITY) do
    if not occupied[n] and not occupied[n + 32] then return n end
  end
end

--contract: vibrato -> lane-1 pb-delta breakpoints in cents; sine of depth cents at 1/period QN
--contract: breakpoints at sine extrema, 'slow'-shaped; linear ramp-in over onset QN
--contract: carrier returns to 0 (centre) at window end -- no residual bend on the channel
function M.vibrato(host, params, ctx)
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
--contract: target 'next' = interval to next lane-1 note; numeric = fixed cents; pbRangeCents clamps
--contract: no next note or unison target -> empty delta (carrier untouched)
function M.slide(host, params, ctx)
  local startL, endL = host.window[1], host.window[2]
  local h = host.events[1]
  local target
  if params.target == 'next' then
    local nxt = ctx.nextLane1Note and ctx.nextLane1Note(h)
    if not nxt then return { notes = {}, delta = {} } end
    target = interval(h, nxt)
  else
    target = params.target or 0
  end
  local maxBend = ctx.pbRangeCents
  if maxBend then target = math.max(-maxBend, math.min(maxBend, target)) end
  if target == 0 then return { notes = {}, delta = {} } end

  -- snap keeps the arrival (target) and the handoff (0) on distinct wire ppqs --
  -- the carrier reconcile keys on (cc, ppq). see design/note-macros.md § Continuous realisation
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

return M
