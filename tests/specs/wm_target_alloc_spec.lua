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

local function audioEdge(from, to)
  return { type='audio', from=from, to=to }
end

return {
  {
    -- s→fx1→fx2→master + fx1→fx3→master: fan-out forces non-identity outs/ins;
    -- identity anchors at pair 1 drop in projection. nchan=6, mainSendOffs=0.
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
      t.eq(entry.nchan,        6, 'nchan = max(2, cursor*2) after two intra claims')
      t.eq(entry.mainSendOffs, 0, 'no masterFeed -> offs 0')
      t.deepEq(entry.pinMaps, {})
      t.deepEq(entry.pinMapsByOrigin['node:fx1'],
               { ins = {}, outs = { [1] = {2, 3} } })
      t.deepEq(entry.pinMapsByOrigin['node:fx2'],
               { ins = { [1] = {2} }, outs = {} })
      t.deepEq(entry.pinMapsByOrigin['node:fx3'],
               { ins = { [1] = {3} }, outs = {} })
    end,
  },
  {
    -- Trivial chain: every port is identity. The projection drops all-identity
    -- fxs from pinMapsByOrigin entirely — same shape as snapshot reads back.
    name = 'targetState: linear source -> fx -> master drops all-identity fxs',
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
      t.eq(entry.pinMapsByOrigin['node:f'], nil, 'all-identity fx dropped from projection')
    end,
  },
}
