-- wm:paramTargets — the cone walk feeding the tracker's param palette.
-- From a source track: midi-reachable fx come first flagged generator,
-- audio-only fx follow in flow order; fx outside the cone and tracks
-- outside the graph yield nothing.

local t    = require('support')
local util = require('util')

local function mkWm(harness)
  local h  = harness.mk()
  local rm = util.instantiate('routingManager', { ds = h.ds })
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
  wm:load()
  return h, wm
end

local function seedTrack(h, guid)
  local track = { __label = guid }
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
           ports={audio={ins=1, outs=1}, midi={ins=1, outs=1}} }
end

local function edge(type, from, to) return { type=type, from=from, to=to } end

return {

  {
    name = 'midi cone first as generators, audio fx after, off-cone excluded',
    run = function(harness)
      local h, wm = mkWm(harness)
      local srcTrack = seedTrack(h, 'guid-SRC')
      seedTrack(h, 'guid-S2')
      local host = seedTrack(h, 'guid-HOST')
      h.reaper:setTrackFX(host, { { ident = 'VST3:Synth' }, { ident = 'VST3:EQ' },
                                  { ident = 'VST3:Other' } })
      h.reaper:setFxGuid(host, 0, 'fxS')
      h.reaper:setFxGuid(host, 1, 'fxE')
      h.reaper:setFxGuid(host, 2, 'fxO')

      -- Source node ids ARE track guids in the live graph; paramTargets
      -- enters the walk via g.nodes[sourceTrackGuid].
      wm:mutate(function(g)
        g.nodes['guid-SRC'] = source('guid-SRC')
        g.nodes['guid-S2']  = source('guid-S2')
        g.nodes.fxS = fx('VST3:Synth')
        g.nodes.fxE = fx('VST3:EQ')
        g.nodes.fxO = fx('VST3:Other')
        util.add(g.edges, edge('midi',  'guid-SRC', 'fxS'))
        util.add(g.edges, edge('audio', 'fxS',      'fxE'))
        util.add(g.edges, edge('audio', 'fxE',      'master'))
        util.add(g.edges, edge('audio', 'guid-S2',  'fxO'))
        util.add(g.edges, edge('audio', 'fxO',      'master'))
      end)

      local rows = wm:paramTargets(srcTrack)
      t.eq(#rows, 2, 'both cone fx; source/master/off-cone are not rows')
      t.eq(rows[1].fxGuid, 'fxS', 'midi cone first')
      t.truthy(rows[1].generator)
      t.eq(rows[1].trackGuid, 'guid-HOST')
      t.eq(rows[1].name, 'VST3:Synth')
      t.eq(rows[2].fxGuid, 'fxE', 'audio-only fx after generators')
      t.falsy(rows[2].generator)
    end,
  },

  {
    name = 'a track outside the graph yields no rows',
    run = function(harness)
      local h, wm = mkWm(harness)
      local stranger = seedTrack(h, 'guid-X')
      t.deepEq(wm:paramTargets(stranger), {})
    end,
  },

}
