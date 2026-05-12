-- Pure-Lua test harness for trackerManager and trackerView. Stubs out
-- REAPER and midiManager; loads the real tm/vm/cm modules unchanged.
--
-- Caller sets package.path (see run.lua) before requiring this module.

local harness = {}

local fakeReaper = require('fakeReaper').new()
_G.reaper = fakeReaper

-- The fake installs newMidiManager globally; mark the real module as
-- already loaded so production require('midiManager') calls are no-ops.
require('fakeMidiManager')
package.loaded['midiManager'] = package.loaded['fakeMidiManager'] or true
require('util')
require('timing')
require('tuning')
require('configManager')
require('trackerManager')
require('commandManager')
require('trackerView')

-- Build a fresh scenario. Keys:
--   seed      : seed payload for the fake mm (notes, ccs, resolution, length, timeSigs)
--   config    : { [level] = { key = value, ... } } written via cm:assign
--   take      : override the opaque take token (default 'take1')
function harness.mk(opts)
  opts = opts or {}

  -- Fresh reaper state per scenario
  fakeReaper = require('fakeReaper').new()
  _G.reaper  = fakeReaper

  local take = opts.take or 'take1'
  local item, track = take .. '/item', take .. '/track'
  fakeReaper:bindTake(take, item, track)

  local mm = newMidiManager({
    take       = take,
    resolution = opts.seed and opts.seed.resolution or 240,
    length     = opts.seed and opts.seed.length     or 3840,
    timeSigs   = opts.seed and opts.seed.timeSigs,
  })

  local cm = newConfigManager()
  cm:setContext(take)
  if opts.config then
    for level, tbl in pairs(opts.config) do cm:assign(level, tbl) end
  end

  if opts.seed then mm:seed(opts.seed) end

  local tm = newTrackerManager(mm, cm)
  local cmgr = newCommandManager(cm)
  local vm = newTrackerView(tm, cm, cmgr)
  cmgr:setActive('tracker')

  return { fm = mm, cm = cm, tm = tm, vm = vm, ec = vm:ec(),
           clipboard = vm:clipboard(), cmgr = cmgr, reaper = fakeReaper }
end

return harness
