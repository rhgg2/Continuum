-- See docs/samplePage.md for the model. @noindex
--
-- samplePage is the sample page's controller — the object coord drives. It owns
-- the stack (sm/sv) and delegates all rendering to sampleRender. The two roles —
-- manage the stack vs. draw it — live in separate modules; the renderer is handed
-- only sv and never reaches sm.

--contract: builds the substack (sm/sv local, only sv leaves); lifecycle drives sm/sv directly
--contract: owns its active track: the renderer's picker sets sv; probe take comes from the arrange facade in tick
--contract: render hooks delegate to sampleRender
local fs   = require 'fs'
local util = require 'util'

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end

local cm, ds, cmgr, chrome, gui, facade =
  (...).cm, (...).ds, (...).cmgr, (...).chrome, (...).gui, (...).facade

local function arrange() return facade.get('arrange') end

-- sm/sv stay local to this chunk; only sv leaves, handed to the renderer, so the
-- renderer can't reach sm — every slot query and mutation flows through sv.
local sm = util.instantiate('sampleManager', { fileOps = fs.fileOps, cm = cm, ds = ds })
local sv = util.instantiate('sampleView',    { cm = cm, ds = ds, sm = sm })
local sr = util.instantiate('sampleRender',
  { sv = sv, cm = cm, ds = ds, cmgr = cmgr, chrome = chrome, gui = gui })

local sp = {}

----------- PUBLIC

----- Page lifecycle (track ops on sv, JSFX poll on sm)

--contract: bind re-keys cm to the page's track on every activation (seeds a default on the first)
-- The shared cm is re-keyed by whichever page is active, so re-assert ours each
-- time even when sv already remembers a track -- a prior tracker unbind nulled it.
function sp:bind()
  local track = sv:getTrack()
  if not track then
    local tracks = sv:listTracks()
    track = tracks[1] and tracks[1].track or nil
  end
  if track then sv:setTrack(track) end
end

--contract: setTrack re-keys cm to the given track via sv; the sample facade and the picker drive it
function sp:setTrack(track)
  if track then sv:setTrack(track) end
end

--contract: listTracks proxies sm:listTracks via sv — coord queries this to seed its active sampler track on first activation
function sp:listTracks() return sv:listTracks() end

--contract: unbind reverts any preview-in-place but leaves cm and sv state alone — the next bind can resume on the same track
function sp:unbind() sr:closeTransients() end

--contract: tick runs every frame; watchPath + sm:tick always; probeMode skipped if no current take
function sp:tick()
  local take = arrange().currentTake()
  if take then sm:probeMode(take) end
  sm:watchPath()
  sm:tick()
end

facade.publish('sample', { setTrack = function(track) sp:setTrack(track) end })

----- Page interface — render delegates to the renderer
function sp:toolbarSegments()               return sr:toolbarSegments() end
function sp:renderBody(ctx, w, h, dispatch) return sr:renderBody(ctx, w, h, dispatch) end
function sp:renderStatusBar(ctx)            return sr:renderStatusBar(ctx) end
function sp:focusState()                    return sr:focusState() end

return sp
