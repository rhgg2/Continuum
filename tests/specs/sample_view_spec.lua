-- Pin-tests for sampleView state management (draw() needs ImGui; rendering verified manually).
-- sv holds sm directly; a fake sm records calls.

local t = require('support')
local util = require('util')

local function fakeSm()
  local rec = {
    assign = {}, previewSlot = {}, previewPath = {}, clearSlot = {},
    stopPreview = 0, listTracksCalls = 0, assignResult = true, tracks = {},
  }
  local sm = {
    assign = function(_, track, slot, path)
      rec.assign[#rec.assign+1] = { track = track, slot = slot, path = path }
      return rec.assignResult
    end,
    previewSlot = function(_, track, slot, bounds)
      rec.previewSlot[#rec.previewSlot+1] = { track = track, slot = slot, bounds = bounds }
    end,
    previewPath = function(_, track, path)
      rec.previewPath[#rec.previewPath+1] = { track = track, path = path }
    end,
    clearSlot = function(_, track, slot)
      rec.clearSlot[#rec.clearSlot+1] = { track = track, slot = slot }
    end,
    stopPreview = function(_, _track) rec.stopPreview = rec.stopPreview + 1 end,
    listTracks  = function(_) rec.listTracksCalls = rec.listTracksCalls + 1; return rec.tracks end,
  }
  return sm, rec
end

local function newSampleView(cm, sm)
  return util.instantiate('sampleView', { cm = cm, sm = sm })
end

return {
  {
    name = "newSampleView starts with no track",
    run = function(harness)
      local sv = newSampleView()
      t.eq(sv:getTrack(), nil, "no track until setTrack")
    end,
  },
  {
    name = "setTrack stores the track",
    run = function(harness)
      local sv = newSampleView()
      sv:setTrack('track1')
      t.eq(sv:getTrack(), 'track1', "getTrack returns what setTrack stored")
    end,
  },
  {
    name = "setTrack(nil) clears the track",
    run = function(harness)
      local sv = newSampleView()
      sv:setTrack('track1')
      sv:setTrack(nil)
      t.eq(sv:getTrack(), nil, "nil clears the stored track")
    end,
  },
  {
    name = "selectedFile starts nil; setSelectedFile stores; setSelectedFile(nil) clears",
    run = function(harness)
      local sv = newSampleView()
      t.eq(sv:getSelectedFile(), nil, "no file until setSelectedFile")
      sv:setSelectedFile('/tmp/kick.wav')
      t.eq(sv:getSelectedFile(), '/tmp/kick.wav', "stored")
      sv:setSelectedFile(nil)
      t.eq(sv:getSelectedFile(), nil, "nil clears it")
    end,
  },
  {
    name = "loadSelectedIntoCurrent is a no-op when no file is selected",
    run = function(harness)
      local h = harness.mk()
      local sm, rec = fakeSm()
      local sv = newSampleView(h.cm, sm)
      t.eq(sv:loadSelectedIntoCurrent(), false, "returns false")
      t.eq(#rec.assign, 0, "sm:assign not invoked")
    end,
  },
  {
    name = "loadSelectedIntoCurrent passes (currentSample, selectedFile) to sm:assign",
    run = function(harness)
      local h = harness.mk()
      local sm, rec = fakeSm()
      local sv = newSampleView(h.cm, sm)
      h.cm:set('transient', 'currentSample', 5)
      sv:setSelectedFile('/x.wav')
      t.eq(sv:loadSelectedIntoCurrent(), true, "returns true")
      t.eq(#rec.assign, 1, "sm:assign called once")
      t.eq(rec.assign[1].slot, 5, "slot is currentSample")
      t.eq(rec.assign[1].path, '/x.wav', "path is selectedFile")
    end,
  },
  {
    name = "loadSelectedIntoCurrent surfaces sm:assign failure",
    run = function(harness)
      local h = harness.mk()
      local sm, rec = fakeSm(); rec.assignResult = false
      local sv = newSampleView(h.cm, sm)
      sv:setSelectedFile('/x.wav')
      t.eq(sv:loadSelectedIntoCurrent(), false, "false propagates from sm:assign")
    end,
  },
  {
    name = "auditionPath(nil) is a no-op",
    run = function(harness)
      local h = harness.mk()
      local sm, rec = fakeSm()
      local sv = newSampleView(h.cm, sm)
      t.eq(sv:auditionPath(nil), false, "returns false")
      t.eq(#rec.previewPath, 0, "sm:previewPath not invoked")
    end,
  },
  {
    name = "auditionPath(p) calls sm:previewPath with that path",
    run = function(harness)
      local h = harness.mk()
      local sm, rec = fakeSm()
      local sv = newSampleView(h.cm, sm)
      sv:setTrack('t1')
      t.eq(sv:auditionPath('/kick.wav'), true, "returns true")
      t.eq(#rec.previewPath, 1, "sm:previewPath called once")
      t.eq(rec.previewPath[1].path, '/kick.wav', "path forwarded")
    end,
  },
  {
    name = "setTrack with cm injected rekeys cm and clears transient currentSample",
    run = function(harness)
      local h = harness.mk()
      h.cm:set('transient', 'currentSample', 5)
      local sv = newSampleView(h.cm, fakeSm())
      local trackB = 'trackB'
      h.reaper._state.trackExt[trackB .. '/P_EXT:ctm_config'] =
        util.serialise({ pbRange = 9 })
      sv:setTrack(trackB)
      t.eq(sv:getTrack(), trackB, 'sv stored the new track')
      t.eq(h.cm:getAt('transient', 'currentSample'), nil,
           'transient currentSample cleared')
      t.eq(h.cm:getAt('track', 'pbRange'), 9,
           'cm now reads track-tier from new track')
    end,
  },
  {
    name = "setTrack with cm and same track still rehydrates cm and clears transient",
    run = function(harness)
      local h = harness.mk()
      local sv = newSampleView(h.cm, fakeSm())
      sv:setTrack('trackA')
      h.cm:set('transient', 'currentSample', 7)
      sv:setTrack('trackA')
      t.eq(h.cm:getAt('transient', 'currentSample'), nil,
           'same-track setTrack still re-primes cm (covers cm:setContext(nil) seam)')
    end,
  },
  {
    name = "listTracks proxies sm:listTracks",
    run = function(harness)
      local h     = harness.mk()
      local sm, rec = fakeSm()
      rec.tracks = { { track = 't1', name = 'Drums' },
                     { track = 't2', name = 'Synth' } }
      local sv = newSampleView(h.cm, sm)
      local got = sv:listTracks()
      t.eq(rec.listTracksCalls, 1, 'sm:listTracks invoked once')
      t.eq(#got,   2,         'two tracks returned')
      t.eq(got[1].name, 'Drums', 'first entry passes through')
    end,
  },
  {
    name = "loadSelectedIntoCurrent advances to next free slot when advanceOnLoad is true",
    run = function(harness)
      local h = harness.mk()
      h.cm:set('global', 'advanceOnLoad', true)
      h.cm:set('transient', 'currentSample', 5)
      h.cm:set('track', 'slotEntries', { [6] = { path = 'x' } })
      local sv = newSampleView(h.cm, fakeSm())
      sv:setSelectedFile('/y.wav')
      sv:loadSelectedIntoCurrent()
      t.eq(h.cm:get('currentSample'), 7, 'skipped occupied slot 6, advanced to 7')
    end,
  },
  {
    name = "loadSelectedIntoCurrent leaves currentSample alone when advanceOnLoad is false",
    run = function(harness)
      local h = harness.mk()
      h.cm:set('global', 'advanceOnLoad', false)
      h.cm:set('transient', 'currentSample', 5)
      local sv = newSampleView(h.cm, fakeSm())
      sv:setSelectedFile('/y.wav')
      sv:loadSelectedIntoCurrent()
      t.eq(h.cm:get('currentSample'), 5, 'stayed on the slot we loaded into')
    end,
  },
  {
    name = "auditionSlot(idx) calls sm:previewSlot(track, idx, 1)",
    run = function(harness)
      local h = harness.mk()
      local sm, rec = fakeSm()
      local sv = newSampleView(h.cm, sm)
      sv:setTrack('t1')
      sv:auditionSlot(7)
      t.eq(#rec.previewSlot, 1, "sm:previewSlot called once")
      t.eq(rec.previewSlot[1].slot, 7, "slot forwarded")
      t.eq(rec.previewSlot[1].bounds, 1, "bounds=1 (honour SH_START/SH_END)")
    end,
  },
}
