-- 3c.2 — wm:targetState carries the allocator outputs (pinMaps, nchan,
-- mainSendOffs) through projectEntry. The diff/snapshot/apply layers all
-- consume these fields; if they aren't on target entries, every layer
-- downstream silently no-ops on identity.

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

local function fx(ident, opts)
  opts = opts or {}
  return { kind='fx', fxIdent=ident, fxGuid=opts.fxGuid, pos={x=0,y=0},
           ports={audio={ins=opts.ins or 1, outs=opts.outs or 1},
                  midi={ins=1, outs=1}} }
end

local function audioEdge(from, to)
  return { type='audio', from=from, to=to }
end

return {
  {
    -- s→fx1→fx2→master + fx1→fx3→master: fx1's one output pair feeds both
    -- branches (split-share); fx2/fx3 sum to master via a merge CU at chain end.
    name = 'targetState: pinMaps + nchan carried for intra fan-out',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      wm:mutate(function(g)
        g.nodes.s   = source('guid-A')
        g.nodes.fx1 = fx('VST:Fan',    { ins=1, outs=1 })
        g.nodes.fx2 = fx('VST:LegA',   { ins=1, outs=1 })
        g.nodes.fx3 = fx('VST:LegB',   { ins=1, outs=1 })
        util.add(g.edges, audioEdge('s',   'fx1'))
        util.add(g.edges, audioEdge('fx1', 'fx2'))
        util.add(g.edges, audioEdge('fx1', 'fx3'))
        util.add(g.edges, audioEdge('fx2', 'master'))
        util.add(g.edges, audioEdge('fx3', 'master'))
      end)
      local target = wm:targetState()
      local entry  = target['guid-A']
      t.truthy(entry, 'source-track entry present')
      t.eq(entry.nchan,        4, 'fx2/fx3 run live into the merge CU -> 2 pairs')
      t.eq(entry.mainSendOffs, 0, 'parent send reads the merge CU pair (offs 0)')
      t.eq(entry.mainSendNch,  2, 'parent send to master is stereo')
      t.deepEq(entry.pinMaps, {})
      t.deepEq(entry.pinMapsByOrigin['node:fx1'],
               { ins = { [1] = {1} }, outs = { [1] = {1} } })   -- one shared pair
      t.deepEq(entry.pinMapsByOrigin['node:fx2'],
               { ins = { [1] = {1} }, outs = { [1] = {2} } })
      t.deepEq(entry.pinMapsByOrigin['node:fx3'],
               { ins = { [1] = {1} }, outs = { [1] = {1} } })
      t.deepEq(entry.pinMapsByOrigin['merge:master\0guid-A'],
               { ins = { [1] = {2}, [2] = {1} }, outs = { [1] = {1} } })
    end,
  },
  {
    -- Trivial chain: every port routes through pair 1. The projection carries
    -- explicit entries; unwired ports of the fx default to disconnected at apply.
    name = 'targetState: linear source -> fx -> master keeps explicit pair-1 routes',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      wm:mutate(function(g)
        g.nodes.s = source('guid-A')
        g.nodes.f = fx('VST:Lin')
        util.add(g.edges, audioEdge('s', 'f'))
        util.add(g.edges, audioEdge('f', 'master'))
      end)
      local target = wm:targetState()
      local entry  = target['guid-A']
      t.eq(entry.nchan,        2, 'no fresh pair claimed')
      t.eq(entry.mainSendOffs, 0)
      t.eq(entry.mainSendNch,  2)
      t.deepEq(entry.pinMapsByOrigin['node:f'],
               { ins = { [1] = {1} }, outs = { [1] = {1} } })
    end,
  },
}
