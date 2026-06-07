-- 3c.2 — wm:targetState carries the allocator outputs (pinMaps, nchan,
-- mainSendOffs) through projectEntry. The diff/snapshot/apply layers all
-- consume these fields; if they aren't on target entries, every layer
-- downstream silently no-ops on identity.

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

-- pinMaps nest on fx entries now; find one by its compile origin.
local function pinmapByNode(entry, id)
  for _, e in ipairs(entry.fx) do
    if e.origin and e.origin.kind == 'node' and e.origin.id == id then return e.pinMaps end
  end
end
local function pinmapByMerge(entry, consumer, trackKey)
  for _, e in ipairs(entry.fx) do
    if e.origin and e.origin.kind == 'merge'
       and e.origin.consumer == consumer and e.origin.trackKey == trackKey then return e.pinMaps end
  end
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
      t.eq(entry.nchan,              4, 'fx2/fx3 run live into the merge CU -> 2 pairs')
      t.eq(entry.mainSend.tgtOffset, 0, 'parent send reads the merge CU pair (offs 0)')
      t.eq(entry.mainSend.nchan,     2, 'parent send to master is stereo')
      t.deepEq(pinmapByNode(entry, 'fx1'),
               { ins = { [1] = {1} }, outs = { [1] = {1} } })   -- one shared pair
      t.deepEq(pinmapByNode(entry, 'fx2'),
               { ins = { [1] = {1} }, outs = { [1] = {2} } })
      t.deepEq(pinmapByNode(entry, 'fx3'),
               { ins = { [1] = {1} }, outs = { [1] = {1} } })
      t.deepEq(pinmapByMerge(entry, 'master', 'guid-A'),
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
      t.eq(entry.nchan,              2, 'no fresh pair claimed')
      t.eq(entry.mainSend.tgtOffset, 0)
      t.eq(entry.mainSend.nchan,     2)
      t.deepEq(pinmapByNode(entry, 'f'),
               { ins = { [1] = {1} }, outs = { [1] = {1} } })
    end,
  },
}
