-- read-side of wiring busses v2: a trackId-flagged track mints the kind='bus'
-- node back under its synthetic id (design/wiring-busses-v2.md § Persistence).
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

local function fx(ident, opts)
  opts = opts or {}
  return { kind='fx', fxIdent=ident, fxId=opts.fxId, pos={x=0,y=0},
           ports={audio={ins=opts.ins or 1, outs=opts.outs or 1},
                  midi={ins=1, outs=1}} }
end

local function bus()
  return { kind='bus', pos={x=0,y=0}, orient='V',
           ports={audio={ins=1,outs=1}, midi={ins=0,outs=0}} }
end

local function edgeSet(g)
  local out = {}
  for _, e in ipairs(g.edges) do
    local gain = e.ops and e.ops.gain
    out[#out+1] = string.format('%s %s.%s->%s.%s%s',
      e.type, e.from, e.fromPort or '-', e.to, e.toPort or '-',
      gain and (' @' .. gain) or '')
  end
  table.sort(out)
  return out
end

-- The summing track is the one fx-less newTrack in the target; flag it with
-- the guid the bus record carries.
local function flagBusTrack(target, guid)
  for trackKey, entry in pairs(target) do
    if entry.trackKind == 'newTrack' and #entry.fx == 0 then
      entry.id = guid
      return trackKey
    end
  end
end

return {
  {
    name = 'matrix round-trip: flagged track mints the bus, gains land on the right edges',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      seedSource(h, 'guid-B')
      wm:mutate(function(g)
        g.nodes.sa = source('guid-A')
        g.nodes.sb = source('guid-B')
        g.nodes['bus-1'] = bus()
        g.nodes.f = fx('VST:F', { fxId = 'g-f' })
        util.add(g.edges, { type='audio', from='sa', to='bus-1', ops={gain=0.5} })
        util.add(g.edges, { type='audio', from='sb', to='bus-1' })
        util.add(g.edges, { type='audio', from='bus-1', to='f', ops={gain=0.7} })
        util.add(g.edges, { type='audio', from='bus-1', to='master', ops={gain=0.9} })
        util.add(g.edges, { type='audio', from='f', to='master' })
      end)
      local target = wm:targetState()
      t.truthy(flagBusTrack(target, 'guid-bus'), 'summing track present in target')
      local rg = wm.readGraph(target, { ['bus-1'] = { trackId = 'guid-bus' } })
      t.eq(rg.nodes['bus-1'].kind, 'bus')
      t.eq(rg.nodes['bus-1'].ports.audio.ins,  1)
      t.eq(rg.nodes['bus-1'].ports.audio.outs, 1)
      t.deepEq(edgeSet(rg), {
        'audio bus-1.1->g-f.1 @0.7',
        'audio bus-1.1->master.- @0.9',
        'audio g-f.1->master.-',
        'audio guid-A.1->bus-1.1 @0.5',
        'audio guid-B.1->bus-1.1',
      })
    end,
  },
  {
    name = 'flagged track with no incoming sends still mints the bus node',
    run = function(harness)
      local _, wm = mkWm(harness)
      local snap = {
        ['__master__'] = { trackKind = 'master', fx = {} },
        ['orphan']     = { trackKind = 'newTrack', id = 'guid-bus', fx = {}, sends = {},
                           mainSend = { on = false } },
      }
      local rg = wm.readGraph(snap, { ['bus-1'] = { trackId = 'guid-bus' } })
      t.eq(rg.nodes['bus-1'].kind, 'bus', 'bus minted with no inputs')
      t.falsy(rg.nodes['guid-bus'], 'no source node minted for the flagged track')
      t.eq(#rg.edges, 0)
    end,
  },
}
