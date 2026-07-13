-- wm:samplerReachable — wiring is the authority on whether a take is a tracker
-- take: does its source track's MIDI cone reach a Continuum Sampler. Replaces
-- sampleManager's legacy per-track FX scan.

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

local function fx(ident, display)
  return { kind='fx', fxIdent=ident, fxDisplay=display, pos={x=0,y=0},
           ports={audio={ins=1, outs=1}, midi={ins=1, outs=1}} }
end

local function sampler() return fx('JS:Continuum_Sampler', 'Continuum Sampler') end

local function edge(type, from, to) return { type=type, from=from, to=to } end

return {
  {
    name = 'sampler in the midi cone makes the source a tracker take',
    run = function(harness)
      local h, wm = mkWm(harness)
      local src = seedTrack(h, 'guid-SRC')
      wm:mutate(function(g)
        g.nodes['guid-SRC'] = source('guid-SRC')
        g.nodes.samp = sampler()
        util.add(g.edges, edge('midi',  'guid-SRC', 'samp'))
        util.add(g.edges, edge('audio', 'samp',     'master'))
      end)
      t.truthy(wm:samplerReachable(src), 'midi-reachable sampler => tracker mode')
    end,
  },
  {
    name = 'a sampler reached only over audio does not count',
    run = function(harness)
      local h, wm = mkWm(harness)
      local src = seedTrack(h, 'guid-SRC')
      wm:mutate(function(g)
        g.nodes['guid-SRC'] = source('guid-SRC')
        g.nodes.samp = sampler()
        util.add(g.edges, edge('audio', 'guid-SRC', 'samp'))
        util.add(g.edges, edge('audio', 'samp',     'master'))
      end)
      t.falsy(wm:samplerReachable(src), 'audio-only path is not a tracker take')
    end,
  },
  {
    name = 'sampler reached through a midi fx hop still counts',
    run = function(harness)
      local h, wm = mkWm(harness)
      local src = seedTrack(h, 'guid-SRC')
      wm:mutate(function(g)
        g.nodes['guid-SRC'] = source('guid-SRC')
        g.nodes.thru = fx('VST3:MidiThru', 'MidiThru')
        g.nodes.samp = sampler()
        util.add(g.edges, edge('midi',  'guid-SRC', 'thru'))
        util.add(g.edges, edge('midi',  'thru',     'samp'))
        util.add(g.edges, edge('audio', 'samp',     'master'))
      end)
      t.truthy(wm:samplerReachable(src), 'transitive midi reach finds the sampler')
    end,
  },
  {
    name = 'a track outside the graph is not a tracker take',
    run = function(harness)
      local h, wm = mkWm(harness)
      local stranger = seedTrack(h, 'guid-X')
      t.falsy(wm:samplerReachable(stranger))
    end,
  },
}
