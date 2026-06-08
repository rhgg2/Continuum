-- Pins guid-preservation when a fan-in re-partitions a RESIDENT user fx onto a
-- new emergent track: the relocation must MOVE the instance (CopyToTrack,
-- is_move=true), not delete+re-add — else the plugin's state is silently lost.
-- This is the A→B→Master + (add C→B) review case. Distinct from
-- wm_track_move_spec, which pins the scratch→source first-wiring move.
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

local function fx(ident)
  return { kind='fx', fxIdent=ident, pos={x=0,y=0},
           ports={audio={ins=1,outs=1}, midi={ins=1,outs=1}} }
end

local function audioEdge(from, to) return { type='audio', from=from, to=to } end

local function apply(wm) wm:applyOps(wm:diff(wm:targetState(), wm:snapshot())) end

return {
  {
    name = 'fan-in re-partition MOVES a resident user fx to its new track (guid stable)',
    run = function(harness)
      local h, wm = mkWm(harness)
      local aTrack = seedSource(h, 'guid-A')

      wm:mutate(function(g)
        g.nodes.a = source('guid-A')
        g.nodes.b = fx('JS:foo')
        util.add(g.edges, audioEdge('a', 'b'))
        util.add(g.edges, audioEdge('b', 'master'))
      end)
      apply(wm)

      local bGuid = wm:graph().nodes.b.fxId
      t.truthy(bGuid, 'B materialised with a guid')
      t.eq(wm:fxTrack(bGuid), aTrack, 'B starts absorbed on the source track')

      -- Second source into B: its class gains a 2nd audio parent, can no longer
      -- absorb, and relocates to an emergent track.
      seedSource(h, 'guid-C')
      wm:mutate(function(g)
        g.nodes.c = source('guid-C')
        util.add(g.edges, audioEdge('c', 'b'))
      end)
      apply(wm)

      t.eq(wm:graph().nodes.b.fxId, bGuid,
        'same fxId after relocation — instance moved, not destroyed+recreated')
      t.truthy(wm:fxTrack(bGuid) ~= aTrack,
        'B actually relocated off the source track (guards against a vacuous pass)')
    end,
  },
}
