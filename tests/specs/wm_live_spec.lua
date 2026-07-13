local t    = require('support')
local util = require('util')

local function mkWm(harness)
  local h  = harness.mk()
  local rm = util.instantiate('routingManager', { ds = h.ds })
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
  wm:load()
  return h, wm
end

local function seedSource(h, guid)
  local track = { __label = 'src-' .. guid }
  table.insert(h.reaper._state.projectTracks, track)
  h.reaper._state.trackGuids[track] = guid
  return track
end

local function source(guid)
  return { kind='source', trackId=guid, pos={x=0,y=0},
           ports={audio={ins=0,outs=1}, midi={ins=0,outs=1}} }
end

-- Mint an fx on scratch (as wm:addFxNode does in production) so the node enters the
-- graph carrying a live guid; reconcile then MOVES it onto its track.
local function mintFx(wm, ident, opts)
  opts = opts or {}
  local r = wm:instantiateFxOnScratch(ident)
  return { kind='fx', fxIdent=ident, fxId=r.fxId, pos={x=0,y=0},
           ports={audio={ins=opts.ins or 1, outs=opts.outs or 1}, midi={ins=0, outs=0}} }
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
        g.nodes.f = mintFx(wm, 'JS:foo', nil)
        util.add(g.edges, audioEdge('s', 'f'))
        util.add(g.edges, audioEdge('f', 'master'))
      end)
      t.eq(h.reaper.TrackFX_GetCount(track), 1, 'fx materialised by live reconcile')
      t.truthy(wm:graph().nodes.f.fxId, 'fx carries its scratch-minted guid')
      t.eq(#wm:diff(wm:targetState(), wm:snapshot()), 0,
           'steady state after live apply')
    end,
  },
  {
    name = 'enableLive: a pos-only moveNodes skips reconcile',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      wm:enableLive()
      wm:mutate(function(g) g.nodes.s = source('guid-A') end)

      -- reconcile always computes targetState; spy on it to witness whether the move
      -- triggers one. Positions are decoration (persisted separately), so it must not.
      local reconciles = 0
      local realTargetState = wm.targetState
      wm.targetState = function(self) reconciles = reconciles + 1; return realTargetState(self) end

      t.truthy(wm:moveNodes({ s = { x = 99, y = 42 } }), 'move succeeded')
      t.eq(reconciles, 0, 'pos-only move fired no reconcile')
      t.eq(wm:graph().nodes.s.pos.x, 99, 'position written to the graph')
    end,
  },
  {
    name = 'enableLive: initial reconcile syncs REAPER to already-persisted graph',
    run = function(harness)
      local h, wm = mkWm(harness)
      local track = seedSource(h, 'guid-A')
      wm:mutate(function(g)
        g.nodes.s = source('guid-A')
        g.nodes.f = mintFx(wm, 'JS:foo', nil)
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
        g.nodes.f = mintFx(wm, 'JS:foo', nil)
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
    name = 'wm:load re-reads REAPER; a behind-the-back FX delete drops from the graph',
    run = function(harness)
      local h, wm = mkWm(harness)
      local track = seedSource(h, 'guid-A')
      wm:enableLive()
      wm:mutate(function(g)
        g.nodes.s = source('guid-A')
        g.nodes.f = mintFx(wm, 'JS:foo', nil)
        util.add(g.edges, audioEdge('s', 'f'))
        util.add(g.edges, audioEdge('f', 'master'))
      end)
      local guidAfterMutate = wm:graph().nodes.f.fxId
      t.truthy(guidAfterMutate, 'fx materialised')
      -- Wipe the FX out of REAPER behind wm's back. read is the store, so load reflects
      -- REAPER truthfully: the vanished fx is simply not read back (no re-materialise churn).
      h.reaper.TrackFX_Delete(track, 0)
      t.eq(h.reaper.TrackFX_GetCount(track), 0, 'cleared')
      wm:load()
      t.eq(h.reaper.TrackFX_GetCount(track), 0, 'load did not re-add the deleted fx')
      local hasFx = false
      for _, n in pairs(wm:graph().nodes) do if n.kind == 'fx' then hasFx = true end end
      t.falsy(hasFx, 'graph no longer carries the vanished fx')
    end,
  },
}
