-- wm:fxTrack resolves an fx guid to its host MediaTrack via rm:fx + rm:reaperTrack.
-- No wm-side cache: re-resolves through rm on every call, so chain reorders never go stale.
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

local function apply(wm) wm:applyOps(wm:diff(wm:targetState(), wm:snapshot())) end

-- Builds s → f1 → f2 → master on one source track; returns the track and the
-- post-apply graph so callers can read the minted fxGuids.
local function twoFxChain(harness)
  local h, wm = mkWm(harness)
  local track = seedSource(h, 'guid-A')
  wm:mutate(function(g)
    g.nodes.s  = source('guid-A')
    g.nodes.f1 = mintFx(wm, 'JS:foo')
    g.nodes.f2 = mintFx(wm, 'JS:bar')
    util.add(g.edges, audioEdge('s',  'f1'))
    util.add(g.edges, audioEdge('f1', 'f2'))
    util.add(g.edges, audioEdge('f2', 'master'))
  end)
  apply(wm)
  return h, wm, track, wm:graph()
end

return {
  {
    name = 'fxTrack resolves each fx guid to its host MediaTrack',
    run = function(harness)
      local _, wm, track, g = twoFxChain(harness)
      t.eq(wm:fxTrack(g.nodes.f1.fxId), track, 'f1 on the source track')
      t.eq(wm:fxTrack(g.nodes.f2.fxId), track, 'f2 on the source track')
    end,
  },
  {
    name = 'fxTrack re-resolves after the chain grows (no stale host)',
    run = function(harness)
      local _, wm, track = twoFxChain(harness)
      wm:mutate(function(g)
        g.nodes.f0 = mintFx(wm, 'JS:zero')
        g.edges = {}
        util.add(g.edges, audioEdge('s',  'f0'))
        util.add(g.edges, audioEdge('f0', 'f1'))
        util.add(g.edges, audioEdge('f1', 'f2'))
        util.add(g.edges, audioEdge('f2', 'master'))
      end)
      apply(wm)
      local g2 = wm:graph()
      t.eq(wm:fxTrack(g2.nodes.f0.fxId), track, 'new fx still on the source track')
      t.eq(wm:fxTrack(g2.nodes.f2.fxId), track)
    end,
  },
  {
    name = 'fxTrack returns nil for an unknown guid',
    run = function(harness)
      local _, wm = twoFxChain(harness)
      t.eq(wm:fxTrack('{nope}'), nil)
    end,
  },
}
