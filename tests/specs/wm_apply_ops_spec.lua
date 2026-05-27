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
}
