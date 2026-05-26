-- See docs/wiringManager.md for the model.
-- @noindex

--invariant: project-wide singleton; the user graph lives in one cm project-tier key (wiringGraph). No per-take or per-track state at Stage 1; wiringClass is declared for the Stage 2 differ but unread here.
--invariant: every authoring gesture goes through wm:mutate — clone draft, mutate, validate via DAG.validate, swap + persist + fire on success, return false+err on failure. The on-disk graph and the wiringChanged broadcast have therefore always passed validation.
--invariant: master node is a regular entry in graph.nodes under the fixed id 'master'; freshGraph materialises it on first load of an empty project; DAG.validate enforces the singleton.
--invariant: scratch track is a hidden REAPER track tagged via cm key 'wiringScratch'='1'; wm:load() and wm:probeFxIO() find-or-create it; future use is to host FX nodes with no compile-graph track of their own. Probing-via-instantiate is a Stage-1 bootstrapping affordance — the differ in Stage 2+ will read I/O off the real production FX instance and back-fill the node.

local util = require 'util'
local DAG  = require 'DAG'

local cm = (...).cm

local wm = {}
local fire = util.installHooks(wm)

local _graph = nil
local _installedFx = nil  -- session cache; reaper's installed-FX set is fixed at runtime
local _scratchTrack = nil -- hidden host for the probe (and, later, orphan FX nodes); reset by wm:load
local _fxIO = {}          -- session cache: fxIdent → { ins, outs, inNames, outNames }

local SCRATCH_NAME = 'continuum: wiring scratch'

----- Helpers

local function freshGraph()
  return {
    nodes = {
      master = { kind = 'master', pos = { x = 0, y = 0 },
                 audio = { ins = 1 } },
    },
    edges = {},
    _nextId = 1,
  }
end

local function readPersisted()
  local g = cm:get('wiringGraph')
  if g and g.nodes then return g end
  return freshGraph()
end

local function ensureLoaded()
  if not _graph then _graph = readPersisted() end
end

local function findScratchTrack()
  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    if cm:readTrackKey(track, 'wiringScratch') == '1' then return track end
  end
end

local function createScratchTrack()
  reaper.PreventUIRefresh(1)
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, false)
  local track = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', SCRATCH_NAME, true)
  reaper.SetMediaTrackInfo_Value(track, 'B_SHOWINMIXER', 0)
  reaper.SetMediaTrackInfo_Value(track, 'B_SHOWINTCP',   0)
  cm:writeTrackKey(track, 'wiringScratch', '1')
  reaper.PreventUIRefresh(-1)
  return track
end

local function ensureScratchTrack()
  if _scratchTrack then return _scratchTrack end
  _scratchTrack = findScratchTrack() or createScratchTrack()
  return _scratchTrack
end

local function pinName(track, fxIdx, dir, pinIdx)
  local ok, v = reaper.TrackFX_GetNamedConfigParm(track, fxIdx, dir .. '_pin_' .. pinIdx)
  return ok and v or nil
end

-- Port P (1-indexed) groups pin 2(P-1) and 2P-1.
-- "Sidechain L" + "Sidechain R" → "Sidechain"; mismatched pair → left pin name.
local function portNames(track, fxIdx, dir, pinCount)
  local out = {}
  for p = 1, pinCount / 2 do
    local left  = pinName(track, fxIdx, dir, (p - 1) * 2)     or ''
    local right = pinName(track, fxIdx, dir, (p - 1) * 2 + 1) or ''
    local lPre  = left :match('^(.+)%s+L$')
    local rPre  = right:match('^(.+)%s+R$')
    if lPre and lPre == rPre then out[p] = lPre
    else                          out[p] = left ~= '' and left or nil end
  end
  return out
end

----------- PUBLIC

--contract: re-reads wiringGraph from cm (rebuilding master via freshGraph if empty), ensures the scratch track, fires wiringChanged{kind='load'}; drops the prior scratch handle (project may have changed)
function wm:load()
  _graph = readPersisted()
  _scratchTrack = nil
  ensureScratchTrack()
  fire('wiringChanged', { kind = 'load' })
end

--contract: persists the current in-memory graph to the project tier; mutate calls this, callers normally don't
function wm:save()
  cm:set('project', 'wiringGraph', _graph)
end

--contract: returns a deep copy of the user graph; caller mutations never leak into wm state
function wm:graph()
  ensureLoaded()
  return util.deepClone(_graph)
end

--contract: clone-validate-swap; on DAG.validate failure returns false,err with no state change and no signal; on success persists and fires wiringChanged{kind='mutate'}
function wm:mutate(mutator)
  ensureLoaded()
  local draft = util.deepClone(_graph)
  mutator(draft)
  local err = DAG.validate(draft)
  if err then return false, err end
  _graph = draft
  self:save()
  fire('wiringChanged', { kind = 'mutate' })
  return true
end

--contract: returns DAG.lower of the current user graph; pure, no caching at Stage 1
function wm:compile()
  ensureLoaded()
  return DAG.lower(_graph)
end

--contract: list of intra-class capacity overflows on the lowered compile graph; empty when the user graph is within budget
function wm:errors()
  local compile = self:compile()
  return DAG.capacityErrors(compile, DAG.classes(compile))
end

--contract: { ins, outs, inNames, outNames } in stereo ports for fxIdent; instantiates on the scratch track, reads TrackFX_GetIOSize + in_pin_X/out_pin_X via TrackFX_GetNamedConfigParm, deletes, caches by ident. Unknown ident → ins=outs=0 with empty name lists.
function wm:probeFxIO(ident)
  if _fxIO[ident] then return _fxIO[ident] end
  ensureScratchTrack()
  reaper.PreventUIRefresh(1)
  local fxIdx = reaper.TrackFX_AddByName(_scratchTrack, ident, false, -1)
  local result
  if fxIdx < 0 then
    result = { ins = 0, outs = 0, inNames = {}, outNames = {} }
  else
    local _, inPins, outPins = reaper.TrackFX_GetIOSize(_scratchTrack, fxIdx)
    inPins, outPins = inPins or 0, outPins or 0
    result = {
      ins      = inPins  / 2,
      outs     = outPins / 2,
      inNames  = portNames(_scratchTrack, fxIdx, 'in',  inPins),
      outNames = portNames(_scratchTrack, fxIdx, 'out', outPins),
    }
    reaper.TrackFX_Delete(_scratchTrack, fxIdx)
  end
  reaper.PreventUIRefresh(-1)
  _fxIO[ident] = result
  return result
end

--contract: linear scan; returns the MediaTrack with this GUID, or nil if the project no longer holds one
function wm:trackByGuid(guid)
  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    if reaper.GetTrackGUID(track) == guid then return track end
  end
end

--contract: live REAPER track name for guid (renames propagate); nil if the track is gone
function wm:trackName(guid)
  local track = self:trackByGuid(guid)
  if not track then return nil end
  local _, name = reaper.GetTrackName(track)
  return name
end

--contract: inserts a track just before scratch (named opts.name); returns its GUID; outside mutate
function wm:createSourceTrack(opts)
  ensureScratchTrack()
  reaper.PreventUIRefresh(1)
  local insertIdx = math.floor(reaper.GetMediaTrackInfo_Value(_scratchTrack, 'IP_TRACKNUMBER')) - 1
  reaper.InsertTrackAtIndex(insertIdx, true)
  local track = reaper.GetTrack(0, insertIdx)
  if opts and opts.name then
    reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', opts.name, true)
  end
  reaper.PreventUIRefresh(-1)
  return reaper.GetTrackGUID(track)
end

--contract: enumerates reaper.EnumInstalledFX once per wm instance; name is raw REAPER "Type: Name (Author)"
function wm:listInstalledFX()
  if _installedFx then return _installedFx end
  local out, i = {}, 0
  while true do
    local ok, name, ident = reaper.EnumInstalledFX(i)
    if not ok then break end
    util.add(out, { name = name, ident = ident })
    i = i + 1
  end
  _installedFx = out
  return out
end

return wm
