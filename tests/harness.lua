-- Pure-Lua test harness for trackerManager and trackerView. Stubs out
-- REAPER and midiManager; loads the real tm/vm/cm modules unchanged.
--
-- Caller sets package.path (see run.lua) before requiring this module.

local harness = {}

local fakeReaper = require('fakeReaper').new()
_G.reaper = fakeReaper

-- configManager's global tier uses real io.open on ctm_cfg.txt, bypassing fakeReaper.
-- Redirect those opens to a temp file so specs never clobber the real config.
local realOpen      = io.open
local globalCfgStub = os.tmpname()
io.open = function(path, ...)
  if type(path) == 'string' and path:find('ctm_cfg%.txt$') then
    return realOpen(globalCfgStub, ...)
  end
  return realOpen(path, ...)
end

require('fakeMidiManager')
local util = require('util')

-- Route every util.instantiate('midiManager', …) — including the one
-- inside trackerPage — through the fake. Production code still asks for
-- 'midiManager' by name; the stub registry swaps it out without the
-- production graph having to know.
util._stubs['midiManager'] = function(deps) return newMidiManager(deps) end
require('timing')
require('tuning')


-- Build a fresh scenario. Keys:
--   seed      : seed payload for the fake mm (notes, ccs, resolution, length, timeSigs)
--   config    : { [level] = { key = value, ... } } written via cm:assign
--   take      : override the opaque take token (default 'take1')
function harness.mk(opts)
  opts = opts or {}

  -- Fresh reaper state per scenario; global-tier stub file likewise, or
  -- one scenario's cm:set('global', …) leaks into the next.
  fakeReaper = require('fakeReaper').new()
  _G.reaper  = fakeReaper
  realOpen(globalCfgStub, 'w'):close()

  local take = opts.take or 'take1'
  local item, track = take .. '/item', take .. '/track'
  fakeReaper:bindTake(take, item, track)

  local mm = newMidiManager({
    take       = take,
    resolution = opts.seed and opts.seed.resolution or 240,
    length     = opts.seed and opts.seed.length     or 3840,
    timeSigs   = opts.seed and opts.seed.timeSigs,
  })

  local ps = util.instantiate('pextStore')
  local cm = util.instantiate('configManager', { ps = ps })
  cm:setContext(take)
  if opts.config then
    for level, tbl in pairs(opts.config) do cm:assign(level, tbl) end
  end

  if opts.seed then mm:seed(opts.seed) end

  local tm = util.instantiate('trackerManager', { mm = mm, cm = cm })
  local cmgr = util.instantiate('commandManager', { cm = cm })
  -- gm is opt-in: it subscribes to tm flush signals, so wiring it
  -- unconditionally would perturb every tm-unit spec's flush pipeline.
  -- Only region-wired specs need the real group engine.
  local gm = opts.groups
         and util.instantiate('groupManager', { tm = tm, cm = cm }) or nil
  local pa = util.instantiate('paramAutomation', { cm = cm })
  local vm = util.instantiate('trackerView', { tm = tm, cm = cm, cmgr = cmgr, gm = gm, pa = pa })
  cmgr:push('tracker')

  return { fm = mm, cm = cm, tm = tm, vm = vm, ec = vm:ec(), gm = gm, pa = pa,
           clipboard = vm:clipboard(), cmgr = cmgr, reaper = fakeReaper }
end

return harness
