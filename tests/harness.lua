-- Pure-Lua test harness for trackerManager and trackerView. Runs the REAL
-- midiManager against the fakeReaper: only REAPER, the external boundary, is
-- faked. Seeds are authored through the production write path (mm:modify +
-- mm:add), not poked into a fake mm.
--
-- Caller sets package.path (see run.lua) before requiring this module.

local harness = {}

-- configManager + dataStore global tiers do real io.open on continuum-config.lua /
-- continuum-data.lua; redirect to temp files so specs never clobber the real ones.
local realOpen       = io.open
local globalCfgStub  = os.tmpname()
local globalDataStub = os.tmpname()
io.open = function(path, ...)
  if type(path) == 'string' then
    if path:find('continuum%-config%.lua$') then return realOpen(globalCfgStub, ...)  end
    if path:find('continuum%-data%.lua$')   then return realOpen(globalDataStub, ...) end
  end
  return realOpen(path, ...)
end

local util = require('util')
local newRealMM = require('realMidiManager')()
require('timing')
require('tuning')

local fakeReaper = require('fakeReaper').new()
_G.reaper = fakeReaper

-- Internal util.instantiate('midiManager', …) (e.g. trackerPage) gets the real
-- mm too, so the whole graph runs one implementation.
util._stubs['midiManager'] = function(deps) return newRealMM(deps and deps.take) end

-- Author a seed payload through the production write path. A stamped note
-- (ppqL set) must carry lane/detune/delay or tm crashes at pickStampedLane.
local function seedThrough(mm, payload)
  mm:modify(function()
    for _, n in ipairs(payload.notes or {}) do
      local note = util.clone(n); note.evType = 'note'
      if note.ppqL == nil and note.endppqL ~= nil then note.ppqL = note.ppq end
      if note.ppqL ~= nil then
        note.lane   = note.lane   or 1
        note.detune = note.detune or 0
        note.delay  = note.delay  or 0
      end
      mm:add(note)
    end
    for _, c in ipairs(payload.ccs or {}) do mm:add(util.clone(c)) end
  end)
end

-- Fresh fakeReaper + a real mm bound to its take, carrying :seed/:dump shims.
-- The shared spine of every scenario: harness.mk layers cm/tm/vm on top;
-- harness.bareMM hands back just this. The fiddly take-binding sequence lives
-- in one place on purpose — a second copy would drift.
local function buildMM(opts)
  local seed = opts.seed or {}

  fakeReaper = require('fakeReaper').new()
  _G.reaper  = fakeReaper

  local take       = opts.take or 'take1'
  local resolution = seed.resolution or 240
  local lengthPpq  = seed.length     or 3840

  -- Establish the take's resolution/length/time-sig surface before building the
  -- mm: its constructor loads immediately and reads them.
  fakeReaper:bindTake(take, take .. '/item', take .. '/track', lengthPpq / resolution)
  fakeReaper:setResolution(resolution)
  for _, ts in ipairs(seed.timeSigs or {}) do
    fakeReaper:addTimeSigMarker(fakeReaper.MIDI_GetProjTimeFromPPQPos(take, ts.ppq or 0), ts.num, ts.denom)
  end
  if opts.floatPpq then fakeReaper:setFloatPpq(true) end

  local mm = newRealMM(take)
  mm.seed = function(_, payload) seedThrough(mm, payload) end
  mm.dump = function()
    local notes, ccs = {}, {}
    for _, n in mm:notes() do notes[#notes + 1] = n end
    for _, c in mm:ccs()   do ccs[#ccs + 1]   = c end
    return { notes = notes, ccs = ccs }
  end
  return mm, take, fakeReaper
end

-- A real mm with NO tm/vm wired. mm_* contract specs pin behaviour on a plain
-- cc, which a tm rebuild would otherwise stamp (ppqL → uuid) out from under
-- them. The seed payload doubles as the take surface (resolution/length).
function harness.bareMM(seed)
  local mm = buildMM{ seed = seed }
  if seed then mm:seed(seed) end
  return mm
end

-- Build a fresh scenario. opts keys: seed (notes/ccs + resolution/length/
-- timeSigs), config, data, take, floatPpq, groups. See header for the mm model.
function harness.mk(opts)
  opts = opts or {}
  local seed = opts.seed or {}

  local mm, take = buildMM(opts)

  -- Fresh global-tier stub file per scenario, or one scenario's
  -- cm:set('global', …) leaks into the next.
  realOpen(globalCfgStub, 'w'):close()
  realOpen(globalDataStub, 'w'):close()

  local ps = util.instantiate('pextStore')
  local cm = util.instantiate('configManager', { ps = ps })
  local ds = util.instantiate('dataStore', { ps = ps })
  cm:setContext(take)
  if opts.config then
    for level, tbl in pairs(opts.config) do cm:assign(level, tbl) end
  end
  if opts.data then
    for name, value in pairs(opts.data) do ds:assign(name, value) end
  end

  if seed.notes or seed.ccs then seedThrough(mm, seed) end

  local tm = util.instantiate('trackerManager', { mm = mm, cm = cm, ds = ds })
  local cmgr = util.instantiate('commandManager', { cm = cm })
  -- gm is opt-in: it subscribes to tm flush signals, so wiring it
  -- unconditionally would perturb every tm-unit spec's flush pipeline.
  -- Only region-wired specs need the real group engine.
  local gm = opts.groups
         and util.instantiate('groupManager', { tm = tm, ds = ds }) or nil
  -- pa resolves a take's source track via arrange.ownerTrack; these specs use
  -- only live takes, where the owner is the take's host track.
  local paFacade = { get = function(name)
    if name == 'arrange' then
      return { ownerTrack = function(take) return reaper.GetMediaItemTake_Track(take) end }
    end
  end }
  local ccm = util.instantiate('ccManager')
  local pa = util.instantiate('paramAutomation', { cm = cm, ds = ds, facade = paFacade, ccm = ccm })
  local vm = util.instantiate('trackerView', { tm = tm, cm = cm, ds = ds, cmgr = cmgr, gm = gm, pa = pa })
  cmgr:push('tracker')

  return { fm = mm, cm = cm, ds = ds, tm = tm, vm = vm, ec = vm:ec(), gm = gm, pa = pa, ccm = ccm,
           clipboard = vm:clipboard(), cmgr = cmgr, reaper = fakeReaper }
end

return harness
