local t    = require('support')
local util = require('util')

local function mkWm(harness)
  local h  = harness.mk()
  local rm = util.instantiate('routingManager', { ds = h.ds })
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

local function mintFx(wm, ident, opts)
  opts = opts or {}
  local r = wm:instantiateFxOnScratch(ident)
  return { kind='fx', fxIdent=ident, fxId=r.fxId, pos={x=0,y=0},
           ports={audio={ins=opts.ins or 1, outs=opts.outs or 1}, midi={ins=0, outs=0}} }
end

local function audioEdge(from, to) return { type='audio', from=from, to=to } end

local function drainDeferred(h)
  local q = h.reaper._state.deferred
  h.reaper._state.deferred = {}
  for _, fn in ipairs(q) do fn() end
  return #q
end

-- A source track hosting one materialised fx; returns the harness, wm, track, and the fx guid.
local function seedFx(harness)
  local h, wm = mkWm(harness)
  local track = seedSource(h, 'guid-A')
  h.reaper:setFxIO('JS:foo', { ins=4, outs=4 })
  wm:mutate(function(g)
    g.nodes.s = source('guid-A')
    g.nodes.f = mintFx(wm, 'JS:foo', { ins=2 })
    util.add(g.edges, audioEdge('s', 'f'))
    util.add(g.edges, audioEdge('f', 'master'))
  end)
  wm:applyOps(wm:diff(wm:targetState(), wm:snapshot()))
  h.reaper._state.deferred = {}  -- drop any scheduling from the initial materialisation
  return h, wm, track, wm:graph().nodes.f.fxId
end

local function nchanOp(value)
  return { op='setNchan', trackKey='guid-A', trackKind='sourceTrack', trackId='guid-A', value=value }
end
local function pinMapsOp(fxId)
  return { op='setPinMaps', trackKey='guid-A', trackKind='sourceTrack', trackId='guid-A',
           fx = { { id=fxId, ident='JS:foo', pinMaps = { ins={[1]={2}}, outs={} } } } }
end

return {
  {
    name = 'grow + setPinMaps schedules one off-cycle pin re-assert',
    run = function(harness)
      local h, wm, _track, fxId = seedFx(harness)
      wm:applyOps({ nchanOp(4), pinMapsOp(fxId) }, 'grow')
      t.eq(#h.reaper._state.deferred, 1, 'a pin re-assert was scheduled')
    end,
  },
  {
    name = 'the deferred re-assert restores the intended map after a grow OR-corrupts it',
    run = function(harness)
      local h, wm, track, fxId = seedFx(harness)
      wm:applyOps({ nchanOp(4), pinMapsOp(fxId) }, 'grow')
      -- Port 1 routes to pair 2 (pins 0,1 -> bits 2,3). Simulate REAPER's grow: OR the
      -- newly-exposed channel-2 identity (bit 4) onto pin 0, as the same-cycle write would.
      local pin0 = h.reaper.TrackFX_GetPinMappings(track, 0, 0, 0)
      h.reaper.TrackFX_SetPinMappings(track, 0, 0, 0, pin0 | (1 << 4), 0)
      drainDeferred(h)
      local lo0 = h.reaper.TrackFX_GetPinMappings(track, 0, 0, 0)
      local lo1 = h.reaper.TrackFX_GetPinMappings(track, 0, 0, 1)
      t.eq(lo0 | lo1, (1 << 2) | (1 << 3), 'intended map re-asserted; the spurious OR bit is gone')
    end,
  },
  {
    name = 'grow with no setPinMaps schedules nothing (grow alone is harmless)',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      h.reaper._state.deferred = {}
      wm:applyOps({ nchanOp(4) }, 'grow only')
      t.eq(#h.reaper._state.deferred, 0)
    end,
  },
  {
    name = 'setPinMaps with no grow schedules nothing (no OR without a grow)',
    run = function(harness)
      local h, wm, _track, fxId = seedFx(harness)
      wm:applyOps({ pinMapsOp(fxId) }, 'pins only')
      t.eq(#h.reaper._state.deferred, 0)
    end,
  },
}
