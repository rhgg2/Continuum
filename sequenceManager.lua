-- See docs/sequenceManager.md for the model.
-- @noindex

--@map:invariant project-wide singleton; pure orchestration over tm/vm/cm — owns no take state of its own
--@map:invariant discovery (takesUsing) reads each take's usedSwings via cm:readTakeKey, never disturbing the active mm/cm; reswing (reswingAll) routes through tm:bindTake so each visited take swaps mm and cm atomically
--@map:invariant takes that have never been bound by continuum (no ctm_config ext data yet) are absent from discovery — accepted bootstrap caveat; the projection populates lazily as users open takes

require 'util'

function newSequenceManager(tm, vm, cm)
  local self = {}

  -- Active take of every MIDI item in the project, in REAPER order.
  local function projectTakes()
    local takes = {}
    for i = 0, reaper.CountMediaItems(0) - 1 do
      local item = reaper.GetMediaItem(0, i)
      local take = item and reaper.GetActiveTake(item)
      if take and reaper.TakeIsMIDI(take) then takes[#takes+1] = take end
    end
    return takes
  end

  --@map:contract reads each take's persisted usedSwings table via cm:readTakeKey; no mm/cm context disturbance
  function self:takesUsing(name)
    local hits = {}
    for _, take in ipairs(projectTakes()) do
      local used = cm:readTakeKey(take, 'usedSwings')
      if used and used[name] then hits[#hits+1] = take end
    end
    return hits
  end

  --@map:contract iterates affected takes via tm:bindTake with opts.markSwingStale=true; that flag drives the post-load rebuild's stale-branch, which rebuilds raw from each event's ppqL under the take's current swing. Restores the original take at the end (no stale-mark — the active take's events are unchanged by the visit).
  function self:reswingAll(name)
    local origTake = tm:currentTake()
    for _, take in ipairs(self:takesUsing(name)) do
      if take ~= origTake then tm:bindTake(take, {markSwingStale=true}) end
    end
    if tm:currentTake() ~= origTake then tm:bindTake(origTake) end
  end

  return self
end
