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
  h.cm:writeTrackKey(track, 'wiringTrackKind', 'sourceTrack')
  return track
end

local function source(guid)
  return { kind='source', trackGuid=guid, pos={x=0,y=0},
           ports={audio={ins=0,outs=1}, midi={ins=0,outs=1}} }
end

local function fx(ident)
  return { kind='fx', fxIdent=ident, pos={x=0,y=0},
           ports={audio={ins=1,outs=1}, midi={ins=1,outs=1}} }
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
    g.nodes.f1 = fx('JS:foo')
    g.nodes.f2 = fx('JS:bar')
    util.add(g.edges, audioEdge('s',  'f1'))
    util.add(g.edges, audioEdge('f1', 'f2'))
    util.add(g.edges, audioEdge('f2', 'master'))
  end)
  apply(wm)
  return h, wm, track, wm:graph()
end

return {
  {
    name = 'locateFx resolves each fx to (track, fxIdx) after recompile',
    run = function(harness)
      local _, wm, track, g = twoFxChain(harness)
      local tr1, idx1 = wm:locateFx(g.nodes.f1.fxGuid)
      t.eq(tr1, track, 'f1 on the source track'); t.eq(idx1, 0, 'f1 at idx 0')
      local tr2, idx2 = wm:locateFx(g.nodes.f2.fxGuid)
      t.eq(tr2, track, 'f2 on the source track'); t.eq(idx2, 1, 'f2 at idx 1')
    end,
  },
  {
    name = 'warm index hit validates one slot — no full-chain scan',
    run = function(harness)
      local _, wm, _, g = twoFxChain(harness)
      local real, calls = reaper.TrackFX_GetFXGUID, 0
      reaper.TrackFX_GetFXGUID = function(a, b) calls = calls + 1; return real(a, b) end
      wm:locateFx(g.nodes.f2.fxGuid)
      reaper.TrackFX_GetFXGUID = real
      t.eq(calls, 1, 'recompile-stamped index — locate is a single validating read')
    end,
  },
  {
    name = 'recompile re-stamps fxIdx when the chain grows (no stale index)',
    run = function(harness)
      local _, wm = twoFxChain(harness)
      wm:mutate(function(g)
        g.nodes.f0 = fx('JS:zero')
        g.edges = {}
        util.add(g.edges, audioEdge('s',  'f0'))
        util.add(g.edges, audioEdge('f0', 'f1'))
        util.add(g.edges, audioEdge('f1', 'f2'))
        util.add(g.edges, audioEdge('f2', 'master'))
      end)
      apply(wm)
      local g2 = wm:graph()
      t.eq(select(2, wm:locateFx(g2.nodes.f1.fxGuid)), 1, 'f1 shifted to idx 1')
      t.eq(select(2, wm:locateFx(g2.nodes.f2.fxGuid)), 2, 'f2 shifted to idx 2')
    end,
  },
}
