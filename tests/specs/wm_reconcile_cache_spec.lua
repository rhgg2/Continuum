local t    = require('support')
local util = require('util')

local function mkWm(harness)
  local h  = harness.mk()
  local rm = util.instantiate('routingManager')
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
  wm:load()
  return h, wm, rm
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

local function mintFx(wm, ident)
  local r = wm:instantiateFxOnScratch(ident)
  return { kind='fx', fxIdent=ident, fxId=r.fxId, pos={x=0,y=0},
           ports={audio={ins=1, outs=1}, midi={ins=1, outs=1}} }
end

-- A self-driven authoring gesture: source → fx → master, materialised by live reconcile.
local function wireSimple(wm)
  wm:mutate(function(g)
    g.nodes.s = source('guid-A')
    g.nodes.f = mintFx(wm, 'JS:foo')
    util.add(g.edges, { type='audio', from='s', to='f' })
    util.add(g.edges, { type='audio', from='f', to='master' })
  end)
end

-- Count rm:tracks() calls — the ~80ms decode the cache exists to elide.
local function trackReadSpy(rm)
  local n, real = 0, rm.tracks
  rm.tracks = function(self, ...) n = n + 1; return real(self, ...) end
  return function() return n end
end

return {
  {
    name = 'cold reconcile reads tracks once — applyOps no longer re-reads',
    run = function(harness)
      local h, wm, rm = mkWm(harness)
      local reads = trackReadSpy(rm)
      wm:enableLive()  -- one cold reconcile: snapshot reads, applyOps seeds from newTrackIds
      t.eq(reads(), 1, 'snapshot read once; applyOps did not re-read')
    end,
  },
  {
    name = 'warm self-driven re-wire reads tracks zero times',
    run = function(harness)
      local h, wm, rm = mkWm(harness)
      seedSource(h, 'guid-A')
      wm:enableLive()
      wireSimple(wm)            -- materialises f (a mint — this reconcile reads)
      local reads = trackReadSpy(rm)
      local ok = wm:mutate(function(g)   -- pure gain edit: no mint, no track change
        for _, e in ipairs(g.edges) do
          if e.from == 'f' and e.to == 'master' then e.ops = { gain = 0.5 } end
        end
      end)
      t.truthy(ok, 'gain re-wire applied')
      t.eq(reads(), 0, 'no REAPER read on a pure self-driven re-wire (served from the cache)')
    end,
  },
  {
    name = 'cache stays truthful: a fresh snapshot still equals target after a cached apply',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      wm:enableLive()
      wireSimple(wm)
      t.eq(#wm:diff(wm:targetState(), wm:snapshot()), 0,
           'REAPER actually reached target via the cache path')
    end,
  },
  {
    name = 'syncExternal invalidates the cache → next reconcile reads',
    run = function(harness)
      local h, wm, rm = mkWm(harness)
      seedSource(h, 'guid-A')
      wm:enableLive()
      wireSimple(wm)                       -- cache warm
      local reads = trackReadSpy(rm)
      h.reaper._state.projStateCount = h.reaper._state.projStateCount + 1
      wm:syncExternal()                    -- external move → drop cache, fire load → reconcile
      t.truthy(reads() >= 1, 'a real snapshot was taken after external invalidation')
    end,
  },
  {
    name = 'load invalidates the cache → reconcile reads REAPER, not stale intent',
    run = function(harness)
      local h, wm, rm = mkWm(harness)
      seedSource(h, 'guid-A')
      wm:enableLive()
      wireSimple(wm)                       -- cache warm
      local reads = trackReadSpy(rm)
      wm:load()                            -- fires load → reconcile; must not trust the cache
      t.truthy(reads() >= 1, 'load forced a fresh read')
    end,
  },
}
