-- scratch.lua: stateless gateway to the project's one hidden, muted scratch track.
local t       = require('support')
local harness = require('harness')
local scratch = require('scratch')

return {
  {
    name = 'peek never mints: nil before first use, no track created',
    run = function()
      local reaper = harness.mk().reaper
      local before = reaper.CountTracks(0)
      t.eq(scratch.peek(), nil, 'no scratch yet → peek is nil')
      t.eq(reaper.CountTracks(0), before, 'peek minted nothing')
    end,
  },
  {
    name = 'id mints once, persists, and is idempotent',
    run = function()
      local reaper = harness.mk().reaper
      local before = reaper.CountTracks(0)
      local g1 = scratch.id()
      local g2 = scratch.id()
      t.eq(g1, g2, 'second id returns the same guid')
      t.eq(reaper.CountTracks(0), before + 1, 'exactly one scratch track minted')
      t.eq(select(2, reaper.GetProjExtState(0, 'continuum_wiring', 'scratch')), g1,
           'guid persisted in projext')
    end,
  },
  {
    name = 'track is the handle for the guid; minted hidden and muted',
    run = function()
      local reaper = harness.mk().reaper
      local track  = scratch.track()
      t.eq(reaper.GetTrackGUID(track), scratch.id(), 'track matches id')
      t.eq(reaper.GetMediaTrackInfo_Value(track, 'B_SHOWINMIXER'), 0, 'hidden from mixer')
      t.eq(reaper.GetMediaTrackInfo_Value(track, 'B_SHOWINTCP'),   0, 'hidden from TCP')
      t.eq(reaper.GetMediaTrackInfo_Value(track, 'B_MUTE'),        1, 'muted')
    end,
  },
}
