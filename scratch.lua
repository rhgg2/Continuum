-- See docs/scratch.md for the model. A stateless gateway to the project's
-- one hidden, muted scratch track — the shared park for rm's fx-meta undo
-- mirror, wm's orphan fx, and (forthcoming) am's emptied palette slots.
--invariant: identity is the projext guid (continuum_wiring/scratch), not module state — instances interchangeable
--invariant: the track is always hidden + muted; re-located by guid each call (REAPER handles go stale)
--contract: id()/track() mint on first use; peek() never mints

local PROJ        = 0
local EXT_SECTION = 'continuum_wiring'
local GUID_KEY    = 'scratch'

local scratch = {}

----- mint + locate

-- By guid over project tracks (the scratch is never master).
local function locate(guid)
  for i = 0, reaper.CountTracks(PROJ) - 1 do
    local track = reaper.GetTrack(PROJ, i)
    if reaper.GetTrackGUID(track) == guid then return track end
  end
end

-- Append top-level: if the project ends inside an open folder, an appended
-- track joins it and retargets its mainSend to the parent. Copied from
-- rm:addTrack (not called) to keep this module dependency-free; see docs.
local function mint()
  local idx = reaper.CountTracks(PROJ)
  local openDepth = 0
  for i = 0, idx - 1 do
    openDepth = openDepth + reaper.GetMediaTrackInfo_Value(reaper.GetTrack(PROJ, i), 'I_FOLDERDEPTH')
  end
  if openDepth > 0 then
    local last = reaper.GetTrack(PROJ, idx - 1)
    reaper.SetMediaTrackInfo_Value(last, 'I_FOLDERDEPTH',
      reaper.GetMediaTrackInfo_Value(last, 'I_FOLDERDEPTH') - openDepth)
  end
  reaper.InsertTrackAtIndex(idx, false)
  local track = reaper.GetTrack(PROJ, idx)
  reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', 'continuum: scratch', true)
  reaper.SetMediaTrackInfo_Value(track, 'B_SHOWINMIXER', 0)
  reaper.SetMediaTrackInfo_Value(track, 'B_SHOWINTCP',   0)
  reaper.SetMediaTrackInfo_Value(track, 'B_MUTE',        1)
  local guid = reaper.GetTrackGUID(track)
  reaper.SetProjExtState(PROJ, EXT_SECTION, GUID_KEY, guid)
  return guid, track
end

----------- PUBLIC

--contract: persisted guid + live handle, or nil if none minted yet. Never mints.
function scratch.peek()
  local _, guid = reaper.GetProjExtState(PROJ, EXT_SECTION, GUID_KEY)
  if guid == '' then return nil end
  local track = locate(guid)
  if track then return guid, track end
end

--contract: the scratch track's guid, minted (hidden + muted) on first use; persisted in projext.
function scratch.id()
  local guid = scratch.peek()
  return guid or (mint())
end

--contract: the scratch track handle; mints on first use.
function scratch.track()
  local _, track = scratch.peek()
  if track then return track end
  return select(2, mint())
end

return scratch
