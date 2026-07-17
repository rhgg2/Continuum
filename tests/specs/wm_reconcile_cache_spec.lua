local t    = require('support')
local util = require('util')

local function mkWm(harness)
  local h  = harness.mk()
  local rm = util.instantiate('routingManager', { ds = h.ds })
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
  -- Test JSFX scan as audio-only so load/syncExternal re-reads stay bracket-free.
  wm.readJSFXContent = function() return 'desc:plain\n@sample\nspl0 *= 1;\n' end
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
           ports={audio={ins=1, outs=1}, midi={ins=0, outs=0}} }
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

-- Count rm:tracks() calls — the ~80ms decode the model exists to elide.
local function trackReadSpy(rm)
  local n, real = 0, rm.tracks
  rm.tracks = function(self, ...) n = n + 1; return real(self, ...) end
  return function() return n end
end

return {
  {
    name = 'enableLive after load takes no read — the load snapshot seeded the model',
    run = function(harness)
      local _, wm, rm = mkWm(harness)
      local reads = trackReadSpy(rm)
      wm:enableLive()  -- reconcile diffs the model load seeded; applyOps seeds from newTrackIds
      t.eq(reads(), 0, 'no fresh read: load\'s snapshot is the model; applyOps did not re-read')
    end,
  },
  {
    name = 'minting an FX warms the model, not invalidates it: add-FX takes no full read',
    run = function(harness)
      local h, wm, rm = mkWm(harness)
      seedSource(h, 'guid-A')
      local reads = trackReadSpy(rm)
      wm:enableLive()           -- model already seeded by load
      wireSimple(wm)            -- mint refreshes one track; the reconcile diffs the model
      t.eq(reads(), 0, 'the mint spliced the scratch entry in; no whole-project re-read')
    end,
  },
  {
    name = 'warm pure re-wire reads tracks zero times',
    run = function(harness)
      local h, wm, rm = mkWm(harness)
      seedSource(h, 'guid-A')
      wm:enableLive()
      wireSimple(wm)            -- materialises f
      local reads = trackReadSpy(rm)
      local ok = wm:mutate(function(g)   -- pure gain edit: no mint, no track change
        for _, e in ipairs(g.edges) do
          if e.from == 'f' and e.to == 'master' then e.ops = { gain = 0.5 } end
        end
      end)
      t.truthy(ok, 'gain re-wire applied')
      t.eq(reads(), 0, 'no REAPER read on a pure self-driven re-wire (served from the model)')
    end,
  },
  {
    name = 'model stays truthful: a fresh snapshot still equals target after a mint+apply',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      wm:enableLive()
      wireSimple(wm)
      t.eq(#wm:diff(wm:targetState(), wm:snapshot()), 0,
           'REAPER actually reached target via the model path')
    end,
  },
  {
    name = 'fastGainCommit mirrors into the model: a follow-up reconcile re-issues no gain write',
    run = function(harness)
      local h, wm, rm = mkWm(harness)
      seedSource(h, 'guid-A')
      wm:enableLive()
      wireSimple(wm)
      local idx
      for i, e in ipairs(wm:graph().edges) do
        if e.from == 'f' and e.to == 'master' then idx = i end
      end
      t.truthy(wm:fastGainCommit(idx, 0.5), 'gain committed')
      local writes, real = 0, rm.assignTrack
      rm.assignTrack = function(self, ...) writes = writes + 1; return real(self, ...) end
      wm:reconcile()
      t.eq(writes, 0, 'model already carries the gain; reconcile rewrote nothing')
    end,
  },
  {
    name = 'syncExternal invalidates the model → next reconcile reads',
    run = function(harness)
      local h, wm, rm = mkWm(harness)
      seedSource(h, 'guid-A')
      wm:enableLive()
      wireSimple(wm)                       -- cache warm
      local reads = trackReadSpy(rm)
      h.reaper._state.projStateCount = h.reaper._state.projStateCount + 1
      wm:syncExternal()                    -- external move → drop cache, fire load → reconcile
      t.eq(reads(), 1, 'one real snapshot after external invalidation, shared by read + reconcile')
    end,
  },
  {
    name = 'load invalidates the model → reconcile reads REAPER, not stale intent',
    run = function(harness)
      local h, wm, rm = mkWm(harness)
      seedSource(h, 'guid-A')
      wm:enableLive()
      wireSimple(wm)                       -- cache warm
      local reads = trackReadSpy(rm)
      wm:load()                            -- fires load → reconcile; must not trust the cache
      t.eq(reads(), 1, 'load forced exactly one fresh read, shared by read + reconcile')
    end,
  },
}
