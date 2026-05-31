-- see docs/wiringManager.md § Routing intent record

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

local function fx(ident)
  return { kind='fx', fxIdent=ident, pos={x=0,y=0},
           ports={audio={ins=1,outs=1}, midi={ins=1,outs=1}} }
end

local function audioEdge(from, to) return { type='audio', from=from, to=to } end
local function midiEdge(from, to)  return { type='midi',  from=from, to=to } end

local function apply(wm)
  wm:applyOps(wm:diff(wm:targetState(), wm:snapshot()), 'test')
end

local function instrument(reaper)
  local counts = { reads = 0, writes = 0 }
  local origGet, origSet = reaper.GetTrackStateChunk, reaper.SetTrackStateChunk
  reaper.GetTrackStateChunk = function(...) counts.reads  = counts.reads  + 1; return origGet(...) end
  reaper.SetTrackStateChunk = function(...) counts.writes = counts.writes + 1; return origSet(...) end
  return counts
end

return {
  {
    name = 'intent: re-apply of identical graph touches no chunks',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      wm:mutate(function(g)
        g.nodes.s = source('guid-A')
        g.nodes.f = fx('VST:Foo')
        util.add(g.edges, audioEdge('s', 'f'))
        util.add(g.edges, audioEdge('f', 'master'))
      end)
      apply(wm)
      local counts = instrument(h.reaper)
      apply(wm)
      t.eq(counts.reads,  0, 'intent matches target; no chunk read')
      t.eq(counts.writes, 0, 'intent matches target; no chunk write')
    end,
  },
  {
    name = 'intent: rewire flipping midi-out triggers exactly one Get+Set',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      wm:mutate(function(g)
        g.nodes.s  = source('guid-A')
        g.nodes.f1 = fx('VST:Filter')
        g.nodes.f2 = fx('VST:Synth')
        util.add(g.edges, audioEdge('s',  'f1'))
        util.add(g.edges, midiEdge ('f1', 'f2'))
        util.add(g.edges, audioEdge('f2', 'master'))
      end)
      apply(wm)
      wm:mutate(function(g)
        g.edges = {
          audioEdge('s',  'f1'),
          audioEdge('f1', 'f2'),
          audioEdge('f2', 'master'),
        }
      end)
      local counts = instrument(h.reaper)
      apply(wm)
      t.eq(counts.reads,  1, 'one read for f1 flip')
      t.eq(counts.writes, 1, 'one write for f1 flip')
    end,
  },
  {
    name = 'intent: persists across wm:load (cold start hits no chunks)',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      wm:mutate(function(g)
        g.nodes.s = source('guid-A')
        g.nodes.f = fx('VST:Foo')
        util.add(g.edges, audioEdge('s', 'f'))
        util.add(g.edges, audioEdge('f', 'master'))
      end)
      apply(wm)
      local fresh  = util.instantiate('wiringManager', { cm = h.cm })
      fresh:load()
      local counts = instrument(h.reaper)
      apply(fresh)
      t.eq(counts.reads,  0, 'rehydrated intent; no chunk read')
      t.eq(counts.writes, 0, 'rehydrated intent; no chunk write')
    end,
  },
}
