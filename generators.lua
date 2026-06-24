-- Note-macro generators: pure expansions of per-note `fx` intent into
-- derived realisation. A generator never touches swing, raw pb, or
-- REAPER -- it speaks logical frame and intent units only; the rebuild
-- seam rounds ppqL -> raw and maps cents -> pb. See design/note-macros.md
-- § Generators.
-- @noindex

--invariant: pure module -- no module-level state; a generator is fn(host, params, ctx) -> { notes, delta }
--invariant: host = { window={startppqL,endppqL}, events={note,...}, id=uuid, chan }; ctx carries resolution (+ temper later)
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

-- Kinds whose realisation is a continuous delta stream (carrier ccs), not
-- structural notes. Drives the rebuild seam's carrier registration.
M.continuous = { vibrato = true }

--contract: vibrato -> lane-1 pb-delta breakpoints in cents; sine of depth cents at 1/period QN
--contract: ramp-in linear over onset QN; 16 breakpoints/cycle, linear-shaped
function M.vibrato(host, params, ctx)
  local startL, endL = host.window[1], host.window[2]
  local period = periodTicks(params.period, ctx.resolution)   -- ticks per cycle
  local depth  = params.depth or 0
  local onset  = (params.onset or 0) * ctx.resolution          -- ramp-in, ticks
  local step   = period / 16
  local delta  = {}
  local i = 0
  while startL + i * step < endL do
    local at    = startL + i * step
    local phase = (at - startL) / period * 2 * math.pi
    local gain  = onset > 0 and math.min(1, (at - startL) / onset) or 1
    delta[#delta + 1] = { ppqL = at, val = gain * depth * math.sin(phase), shape = 'linear' }
    i = i + 1
  end
  return { notes = {}, delta = delta }
end

return M
