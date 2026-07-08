-- design/fx-patterns.md P3 step b: tm:bindTake gains opts.skipGuard so the mini
-- checkout stack can bind a take WITHOUT touching the project-scoped guardedTrack
-- record. Unconditional restoreGuarded/guardTrack would un-guard the host's
-- playing track and stamp the scratch track guarded. Pins both paths.

local t = require('support')

local PERF = 'I_PERFFLAGS'

local function perfFlags(reaper, track)
  return reaper.GetMediaTrackInfo_Value(track, PERF)
end

-- Establish a host guard on take1's track, then add a second take (take2) on its
-- own track ready to bind. Returns the two track handles + the host guid.
local function withHostGuard(harness)
  local h = harness.mk()
  -- restoreGuarded resolves the guarded track by guid over the project track
  -- list, so both tracks must be registered for the flag-restore path to run.
  h.reaper:setProjectTracks({ 'take1/track', 'take2/track' })
  h.tm:bindTake('take1')                    -- guardTrack('take1/track'): flags 0 -> 2
  h.reaper:bindTake('take2', 'take2/item', 'take2/track', 16)
  return h, 'take1/track', 'take2/track', h.reaper.GetTrackGUID('take1/track')
end

return {
  {
    name = 'skipGuard bind leaves the host guardedTrack record and both tracks untouched',
    run = function(harness)
      local h, hostTrack, miniTrack, hostGuid = withHostGuard(harness)
      t.eq(perfFlags(h.reaper, hostTrack), 2, 'host track is guarded before the mini bind')

      h.tm:bindTake('take2', { skipGuard = true })

      local rec = h.ds:get('guardedTrack')
      t.truthy(rec, 'guardedTrack record survives a skipGuard bind')
      t.eq(rec.guid, hostGuid, 'the record still names the host track, not the checkout')
      t.eq(perfFlags(h.reaper, hostTrack), 2, 'host track stays guarded')
      t.eq(perfFlags(h.reaper, miniTrack), 0, 'checkout track is never stamped guarded')
    end,
  },

  {
    name = 'a normal bind still guards: host track un-guarded, checkout track stamped',
    run = function(harness)
      local h, hostTrack, miniTrack = withHostGuard(harness)

      h.tm:bindTake('take2')

      local rec = h.ds:get('guardedTrack')
      t.eq(rec.guid, h.reaper.GetTrackGUID(miniTrack), 'the record moves to the newly bound track')
      t.eq(perfFlags(h.reaper, hostTrack), 0, 'the prior guard was restored')
      t.eq(perfFlags(h.reaper, miniTrack), 2, 'the newly bound track is guarded')
    end,
  },
}
