local t    = require('support')
local util = require('util')

local function mkWm(harness)
  local h  = harness.mk()
  local wm = util.instantiate('wiringManager', { cm = h.cm })
  wm:load()
  return h, wm
end

local function seedSource(h, guid)
  local track = { __label = 'src-' .. guid }
  table.insert(h.reaper._state.projectTracks, track)
  h.reaper._state.trackGuids[track] = guid
  h.cm:writeTrackKey(track, 'wiringHostKind', 'sourceTrack')
  return track
end

local function source(guid)
  return { kind='source', trackGuid=guid, pos={x=0,y=0},
           ports={audio={ins=0,outs=1}, midi={ins=0,outs=1}} }
end

local function fx(ident, opts)
  opts = opts or {}
  return { kind='fx', fxIdent=ident, fxGuid=opts.fxGuid, pos={x=0,y=0},
           ports={audio={ins=opts.ins or 1, outs=opts.outs or 1},
                  midi={ins=1, outs=1}} }
end

local function audioEdge(from, to, extra)
  local e = { type='audio', from=from, to=to }
  if extra then for k, v in pairs(extra) do e[k] = v end end
  return e
end

local function apply(wm, label)
  wm:applyOps(wm:diff(wm:targetState(), wm:snapshot()), label)
end

return {
  {
    name = 'apply: bare materialise — AddByName, stamp fxGuid onto user node',
    run = function(harness)
      local h, wm = mkWm(harness)
      local track = seedSource(h, 'guid-A')
      wm:mutate(function(g)
        g.nodes.s = source('guid-A')
        g.nodes.f = fx('JS:foo', nil)
        util.add(g.edges, audioEdge('s', 'f'))
        util.add(g.edges, audioEdge('f', 'master'))
      end)
      apply(wm)
      t.eq(h.reaper.TrackFX_GetCount(track), 1)
      local _, ident = h.reaper.TrackFX_GetFXName(track, 0)
      t.eq(ident, 'JS:foo')
      t.eq(wm:graph().nodes.f.fxGuid, h.reaper.TrackFX_GetFXGUID(track, 0),
           'minted guid stamped onto user node')
    end,
  },
  {
    name = 'apply: idempotent — re-diff yields zero ops after first apply',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      wm:mutate(function(g)
        g.nodes.s = source('guid-A')
        g.nodes.f = fx('JS:foo', nil)
        util.add(g.edges, audioEdge('s', 'f'))
        util.add(g.edges, audioEdge('f', 'master'))
      end)
      apply(wm)
      t.eq(#wm:diff(wm:targetState(), wm:snapshot()), 0,
           'steady state after apply')
    end,
  },
  {
    name = 'apply: dropping an fx node deletes by guid; siblings keep their slots',
    run = function(harness)
      local h, wm = mkWm(harness)
      local track = seedSource(h, 'guid-A')
      wm:mutate(function(g)
        g.nodes.s = source('guid-A')
        g.nodes.a = fx('JS:a', nil)
        g.nodes.b = fx('JS:b', nil)
        util.add(g.edges, audioEdge('s', 'a'))
        util.add(g.edges, audioEdge('a', 'b'))
        util.add(g.edges, audioEdge('b', 'master'))
      end)
      apply(wm)
      t.eq(h.reaper.TrackFX_GetCount(track), 2, 'both FX added')
      local aGuid = wm:graph().nodes.a.fxGuid

      wm:mutate(function(g)
        g.nodes.b = nil
        local kept = {}
        for _, e in ipairs(g.edges) do
          if e.from ~= 'b' and e.to ~= 'b' then util.add(kept, e) end
        end
        util.add(kept, audioEdge('a', 'master'))
        g.edges = kept
      end)
      apply(wm)
      t.eq(h.reaper.TrackFX_GetCount(track), 1, 'b dropped')
      t.eq(h.reaper.TrackFX_GetFXGUID(track, 0), aGuid, 'a survived in slot 0')
    end,
  },
  {
    name = 'apply: reorder moves via CopyToTrack rather than re-add',
    run = function(harness)
      local h, wm = mkWm(harness)
      local track = seedSource(h, 'guid-A')
      wm:mutate(function(g)
        g.nodes.s = source('guid-A')
        g.nodes.a = fx('JS:a', nil)
        g.nodes.b = fx('JS:b', nil)
        util.add(g.edges, audioEdge('s', 'a'))
        util.add(g.edges, audioEdge('a', 'b'))
        util.add(g.edges, audioEdge('b', 'master'))
      end)
      apply(wm)
      local aGuid = wm:graph().nodes.a.fxGuid
      local bGuid = wm:graph().nodes.b.fxGuid

      wm:mutate(function(g)
        g.edges = {
          audioEdge('s', 'b'),
          audioEdge('b', 'a'),
          audioEdge('a', 'master'),
        }
      end)
      apply(wm)
      t.eq(h.reaper.TrackFX_GetCount(track), 2, 'no new FX added')
      t.eq(h.reaper.TrackFX_GetFXGUID(track, 0), bGuid, 'b moved to slot 0')
      t.eq(h.reaper.TrackFX_GetFXGUID(track, 1), aGuid, 'a now at slot 1')
    end,
  },
  {
    name = 'apply: CU bridge — params pushed, stamp lands on edge.opFxGuid',
    run = function(harness)
      local h, wm = mkWm(harness)
      local track = seedSource(h, 'guid-A')
      h.reaper:setFxParamNames('JS:Continuum Utility', { 'mode', 'gain' })
      wm:mutate(function(g)
        g.nodes.s = source('guid-A')
        g.nodes.f = fx('JS:foo', nil)
        util.add(g.edges, audioEdge('s', 'f', { ops = { gain = 0.5 } }))
        util.add(g.edges, audioEdge('f', 'master'))
      end)
      apply(wm)
      t.eq(h.reaper.TrackFX_GetCount(track), 2, 'CU + fx materialised')
      local _, cuIdent = h.reaper.TrackFX_GetFXName(track, 0)
      t.eq(cuIdent, 'JS:Continuum Utility')
      local sets = {}
      for _, c in ipairs(h.reaper._state.calls) do
        if c.fn == 'TrackFX_SetParam' and c.track == track and c.fxIdx == 0 then
          sets[c.paramIdx] = c.value
        end
      end
      t.eq(sets[0], 1,   'mode slider set to 1 (gain)')
      t.eq(sets[1], 0.5, 'gain slider set to 0.5')
      local gainEdge
      for _, e in ipairs(wm:graph().edges) do
        if e.ops and e.ops.gain then gainEdge = e end
      end
      t.eq(gainEdge.opFxGuid, h.reaper.TrackFX_GetFXGUID(track, 0),
           'guid stamped onto originating edge')
    end,
  },
  {
    name = 'apply: inter-class fan-in creates an audio send with midi disabled',
    run = function(harness)
      -- s1→fxA→fxB, s2→fxB. fxB's class is the merge of {A,B}, so it lives
      -- on a newTrack; classes A and B both send audio to it.
      local h, wm = mkWm(harness)
      local trackA = seedSource(h, 'guid-A')
      seedSource(h, 'guid-B')
      wm:mutate(function(g)
        g.nodes.sA  = source('guid-A')
        g.nodes.sB  = source('guid-B')
        g.nodes.fxA = fx('JS:a')
        g.nodes.fxB = fx('JS:b', { ins = 2 })
        util.add(g.edges, audioEdge('sA',  'fxA'))
        util.add(g.edges, audioEdge('fxA', 'fxB', { toPort = 2 }))
        util.add(g.edges, audioEdge('sB',  'fxB', { toPort = 1 }))
        -- No fxB→master — wiring it would put fxB in master's class and host
        -- it on REAPER's master, so no newTrack/sends would be emitted.
      end)
      apply(wm)
      local newTrack
      for i = 0, h.reaper.CountTracks(0) - 1 do
        local tr = h.reaper.GetTrack(0, i)
        if h.cm:readTrackKey(tr, 'wiringHostKind') == 'newTrack' then
          newTrack = tr; break
        end
      end
      t.truthy(newTrack, 'newTrack created to host fxB')
      t.eq(h.reaper.GetTrackNumSends(trackA, 0), 1, 'trackA→newTrack send')
      t.eq(h.reaper.GetTrackSendInfo_Value(trackA, 0, 0, 'P_DESTTRACK'), newTrack)
      local mf = h.reaper.GetTrackSendInfo_Value(trackA, 0, 0, 'I_MIDIFLAGS')
      t.eq(math.floor(mf) % 32, 31, 'midi disabled on audio send')
    end,
  },
  {
    name = 'apply: realising flag suppresses wiringChanged during stamp-back',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      wm:mutate(function(g)
        g.nodes.s = source('guid-A')
        g.nodes.f = fx('JS:foo', nil)
        util.add(g.edges, audioEdge('s', 'f'))
        util.add(g.edges, audioEdge('f', 'master'))
      end)
      local fires = 0
      wm:subscribe('wiringChanged', function() fires = fires + 1 end)
      apply(wm)
      t.eq(fires, 0, 'stamp-back does not fire wiringChanged')
    end,
  },
  {
    name = 'apply: connecting an existing fan-in fx to master migrates it onto REAPER master',
    run = function(harness)
      -- Two-source fan-in into a merge fx (no edge to master): the merge sits
      -- on its own newTrack; sources audio-send into it. Adding fx→master in
      -- the user graph collapses fx into master's class (same srcSet), so the
      -- realiser must move fx onto the REAPER master, delete the abandoned
      -- newTrack, and fold each source's audio-to-fx send into mainSend.
      local h, wm = mkWm(harness)
      local trackA = seedSource(h, 'guid-A')
      local trackB = seedSource(h, 'guid-B')
      wm:mutate(function(g)
        g.nodes.sA  = source('guid-A')
        g.nodes.sB  = source('guid-B')
        g.nodes.gA  = fx('JS:gA')
        g.nodes.gB  = fx('JS:gB')
        g.nodes.mix = fx('JS:mix', { ins = 2 })
        util.add(g.edges, audioEdge('sA', 'gA'))
        util.add(g.edges, audioEdge('sB', 'gB'))
        util.add(g.edges, audioEdge('gA', 'mix', { toPort = 1 }))
        util.add(g.edges, audioEdge('gB', 'mix', { toPort = 2 }))
      end)
      apply(wm)
      local mixTrack
      for i = 0, h.reaper.CountTracks(0) - 1 do
        local tr = h.reaper.GetTrack(0, i)
        if h.cm:readTrackKey(tr, 'wiringHostKind') == 'newTrack' then
          mixTrack = tr; break
        end
      end
      t.truthy(mixTrack, 'pre-state: newTrack hosts the merge fx')

      wm:mutate(function(g) util.add(g.edges, audioEdge('mix', 'master')) end)
      apply(wm)

      local master = h.reaper.GetMasterTrack(0)
      local migrated
      for i = 0, h.reaper.TrackFX_GetCount(master) - 1 do
        local _, ident = h.reaper.TrackFX_GetFXName(master, i)
        if ident == 'JS:mix' then migrated = i; break end
      end
      t.truthy(migrated, 'merge fx is now on the REAPER master')
      t.eq(wm:graph().nodes.mix.fxGuid, h.reaper.TrackFX_GetFXGUID(master, migrated),
           'graph fxGuid rewritten to the master-side instance')
      local survives
      for i = 0, h.reaper.CountTracks(0) - 1 do
        if h.reaper.GetTrack(0, i) == mixTrack then survives = true end
      end
      t.eq(survives, nil, 'abandoned newTrack deleted')
      t.eq(h.reaper.GetMediaTrackInfo_Value(trackA, 'B_MAINSEND'), 1, 'source A main-sends to master')
      t.eq(h.reaper.GetMediaTrackInfo_Value(trackB, 'B_MAINSEND'), 1, 'source B main-sends to master')
      t.eq(h.reaper.GetTrackNumSends(trackA, 0), 0, 'source A has no regular sends')
      t.eq(h.reaper.GetTrackNumSends(trackB, 0), 0, 'source B has no regular sends')
    end,
  },
  {
    name = 'apply: removing fx→master moves fx back off the master onto a fresh newTrack',
    run = function(harness)
      -- Reverse of the migration above: start with the master-hosted state,
      -- remove the fx→master edge, and assert the realiser drains master,
      -- creates a newTrack, and reinstates the source→fx sends.
      local h, wm = mkWm(harness)
      local trackA = seedSource(h, 'guid-A')
      local trackB = seedSource(h, 'guid-B')
      wm:mutate(function(g)
        g.nodes.sA  = source('guid-A')
        g.nodes.sB  = source('guid-B')
        g.nodes.mix = fx('JS:mix', { ins = 2 })
        util.add(g.edges, audioEdge('sA', 'mix', { toPort = 1 }))
        util.add(g.edges, audioEdge('sB', 'mix', { toPort = 2 }))
        util.add(g.edges, audioEdge('mix', 'master'))
      end)
      apply(wm)
      local master = h.reaper.GetMasterTrack(0)
      t.eq(h.reaper.TrackFX_GetCount(master), 1, 'pre-state: mix lives on master')

      wm:mutate(function(g)
        local kept = {}
        for _, e in ipairs(g.edges) do
          if not (e.from == 'mix' and e.to == 'master') then util.add(kept, e) end
        end
        g.edges = kept
      end)
      apply(wm)

      t.eq(h.reaper.TrackFX_GetCount(master), 0, 'master drained')
      local mixTrack
      for i = 0, h.reaper.CountTracks(0) - 1 do
        local tr = h.reaper.GetTrack(0, i)
        if h.cm:readTrackKey(tr, 'wiringHostKind') == 'newTrack' then
          mixTrack = tr; break
        end
      end
      t.truthy(mixTrack, 'fresh newTrack now hosts mix')
      t.eq(h.reaper.TrackFX_GetCount(mixTrack), 1)
      local _, ident = h.reaper.TrackFX_GetFXName(mixTrack, 0)
      t.eq(ident, 'JS:mix')
      t.eq(h.reaper.GetMediaTrackInfo_Value(trackA, 'B_MAINSEND'), 0, 'source A no longer main-sends')
      t.eq(h.reaper.GetMediaTrackInfo_Value(trackB, 'B_MAINSEND'), 0, 'source B no longer main-sends')
      t.eq(h.reaper.GetTrackNumSends(trackA, 0), 1, 'source A→newTrack restored')
      t.eq(h.reaper.GetTrackNumSends(trackB, 0), 1, 'source B→newTrack restored')
      t.eq(h.reaper.GetTrackSendInfo_Value(trackA, 0, 0, 'P_DESTTRACK'), mixTrack)
    end,
  },
}
