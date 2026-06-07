local t    = require('support')
local util = require('util')

local function mkWm(harness)
  local h  = harness.mk()
  local rm = util.instantiate('routingManager')
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
  wm:load()
  return h, wm
end

local function seedSource(h, guid)
  local track = { __label = 'src-' .. guid }
  table.insert(h.reaper._state.projectTracks, track)
  h.reaper._state.trackGuids[track] = guid
  h.cm:writeTrackKey(track, 'wiringTrackKind', 'sourceTrack')
  return track
end

local function source(guid)
  return { kind='source', trackId=guid, pos={x=0,y=0},
           ports={audio={ins=0,outs=1}, midi={ins=0,outs=1}} }
end

local function fx(ident, opts)
  opts = opts or {}
  return { kind='fx', fxIdent=ident, fxId=opts.fxId, pos={x=0,y=0},
           ports={audio={ins=opts.ins or 1, outs=opts.outs or 1},
                  midi={ins=1, outs=1}} }
end

local function audioEdge(from, to)
  return { type='audio', from=from, to=to }
end

return {
  {
    name = 'enableLive: mutate auto-applies — no explicit applyOps call',
    run = function(harness)
      local h, wm = mkWm(harness)
      local track = seedSource(h, 'guid-A')
      wm:enableLive()
      wm:mutate(function(g)
        g.nodes.s = source('guid-A')
        g.nodes.f = fx('JS:foo', nil)
        util.add(g.edges, audioEdge('s', 'f'))
        util.add(g.edges, audioEdge('f', 'master'))
      end)
      t.eq(h.reaper.TrackFX_GetCount(track), 1, 'fx materialised by live reconcile')
      t.truthy(wm:graph().nodes.f.fxId, 'fxId stamped back into graph')
      t.eq(#wm:diff(wm:targetState(), wm:snapshot()), 0,
           'steady state after live apply')
    end,
  },
  {
    name = 'enableLive: initial reconcile syncs REAPER to already-persisted graph',
    run = function(harness)
      local h, wm = mkWm(harness)
      local track = seedSource(h, 'guid-A')
      wm:mutate(function(g)
        g.nodes.s = source('guid-A')
        g.nodes.f = fx('JS:foo', nil)
        util.add(g.edges, audioEdge('s', 'f'))
        util.add(g.edges, audioEdge('f', 'master'))
      end)
      t.eq(h.reaper.TrackFX_GetCount(track), 0, 'REAPER untouched before enableLive')
      wm:enableLive()
      t.eq(h.reaper.TrackFX_GetCount(track), 1, 'enableLive ran one immediate reconcile')
    end,
  },
  {
    name = 'enableLive: idempotent — second call does not double-subscribe',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      local calls = 0
      local original = wm.reconcile
      wm.reconcile = function(self, label) calls = calls + 1; original(self, label) end
      wm:enableLive()        -- subscribe + initial reconcile (+1)
      wm:enableLive()        -- no-op
      wm:mutate(function(g)  -- wiringChanged → exactly one reconcile (+1)
        g.nodes.s = source('guid-A')
        g.nodes.f = fx('JS:foo', nil)
        util.add(g.edges, audioEdge('s', 'f'))
        util.add(g.edges, audioEdge('f', 'master'))
      end)
      -- 2 expected: 1 from enableLive's immediate pass, 1 from the mutate.
      -- The stamp-back mutate inside applyOps runs under `realising` and
      -- suppresses wiringChanged, so it doesn't add a third.
      t.eq(calls, 2, 'reconcile called exactly twice')
    end,
  },
  {
    name = 'enableLive: wm:load fires reconcile too',
    run = function(harness)
      local h, wm = mkWm(harness)
      local track = seedSource(h, 'guid-A')
      wm:enableLive()
      wm:mutate(function(g)
        g.nodes.s = source('guid-A')
        g.nodes.f = fx('JS:foo', nil)
        util.add(g.edges, audioEdge('s', 'f'))
        util.add(g.edges, audioEdge('f', 'master'))
      end)
      local guidAfterMutate = wm:graph().nodes.f.fxId
      -- Wipe the FX out of REAPER behind wm's back; load + auto-reconcile
      -- should detect the drift and re-materialise.
      h.reaper.TrackFX_Delete(track, 0)
      t.eq(h.reaper.TrackFX_GetCount(track), 0, 'cleared')
      wm:load()
      t.eq(h.reaper.TrackFX_GetCount(track), 1, 'load drove reconcile, fx re-added')
      t.truthy(wm:graph().nodes.f.fxId ~= guidAfterMutate
            or wm:graph().nodes.f.fxId == h.reaper.TrackFX_GetFXGUID(track, 0),
           'graph fxId tracks the live FX')
    end,
  },
}
