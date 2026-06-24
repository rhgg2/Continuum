-- ccManager.lua
-- Owns the per-track Continuum CC node (Continuum CC.jsfx): resolve, pin at head, reap.

--invariant: the node exists iff a producer claims it; release reaps it when the last claim drops
--shape: claims = { [producer:str] = { [trackGuid:str] = MediaTrack } }
--contract: claim pins the node at index 0, records the producer's claim, returns 0
--contract: release drops the claim; returns the surviving node index, or nil if it reaped/absent
--reaper: TrackFX_AddByName/CopyToTrack/Delete; node = fx_type JS with fx_ident 'Continuum CC'

local CC_ADDNAME = 'JS:Continuum CC'  -- TrackFX_AddByName argument
local CC_IDENT   = 'Continuum CC'     -- parsed fx_ident, matched on lookup

local ccm = {}
local claims = {}   -- producer -> { guid -> track }

-- fx_ident for a JSFX is the bare Effects-relative path (cf. routingManager fxIdentAt)
local function nodeIndex(track)
  for i = 0, reaper.TrackFX_GetCount(track) - 1 do
    local _, fxType = reaper.TrackFX_GetNamedConfigParm(track, i, 'fx_type')
    if fxType == 'JS' then
      local _, ident = reaper.TrackFX_GetNamedConfigParm(track, i, 'fx_ident')
      if ident == CC_IDENT then return i end
    end
  end
end

function ccm:claim(producer, track)
  claims[producer] = claims[producer] or {}
  claims[producer][reaper.GetTrackGUID(track)] = track
  local idx = nodeIndex(track)
  if not idx then
    idx = reaper.TrackFX_AddByName(track, CC_ADDNAME, false, -1)
    if idx < 0 then error('ccManager: Continuum CC.jsfx not found in Effects') end
  end
  if idx ~= 0 then
    reaper.TrackFX_CopyToTrack(track, idx, track, 0, true)
    idx = 0
  end
  return idx
end

function ccm:release(producer, track)
  local guid = reaper.GetTrackGUID(track)
  if claims[producer] then claims[producer][guid] = nil end
  for _, set in pairs(claims) do
    if set[guid] then return nodeIndex(track) end
  end
  local idx = nodeIndex(track)
  if idx then reaper.TrackFX_Delete(track, idx) end
end

return ccm
