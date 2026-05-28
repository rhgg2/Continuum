-- Integration: wm:applyOps reconciles the per-FX "MIDI output disabled"
-- bit (0x02) against the user graph. An fx node with no outgoing midi
-- edge has the bit set; with an outgoing midi edge, cleared. CU bridges
-- and foreign JSFX are skipped (no routing trailer, and not counted in
-- the routing-index walk). See docs/reaper_midi_routing.md.

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

local function audioEdge(from, to, extra)
  local e = { type='audio', from=from, to=to }
  if extra then for k, v in pairs(extra) do e[k] = v end end
  return e
end
local function midiEdge(from, to)
  return { type='midi', from=from, to=to }
end

local function apply(wm) wm:applyOps(wm:diff(wm:targetState(), wm:snapshot()), 'test') end

local function routingFlag(h, track, idx)
  local entry = h.reaper._state.fxByTrack[track] and
                h.reaper._state.fxByTrack[track][idx + 1]
  return entry and entry.routingBytes and entry.routingBytes.flag
end

return {
  {
    name = 'fxRouting/apply: audio-only fx gets midi-out disabled',
    run = function(harness)
      local h, wm = mkWm(harness)
      local track = seedSource(h, 'guid-A')
      wm:mutate(function(g)
        g.nodes.s = source('guid-A')
        g.nodes.f = fx('VST:Foo', nil)
        util.add(g.edges, audioEdge('s', 'f'))
        util.add(g.edges, audioEdge('f', 'master'))
      end)
      apply(wm)
      local flag = routingFlag(h, track, 0)
      t.truthy(flag, 'chunk written, routing bytes captured')
      t.eq(flag & 0x02, 0x02, 'output-disabled bit set on audio-only fx')
    end,
  },
  {
    -- s -audio-> f1 -midi-> f2 -audio-> master.
    -- master.midi.ins = 0, so a midi edge to master would fail validation;
    -- the midi consumer must be another fx with a midi-in port.
    name = 'fxRouting/apply: midi-emitter has bit clear, midi-tail has bit set',
    run = function(harness)
      local h, wm = mkWm(harness)
      local track = seedSource(h, 'guid-A')
      wm:mutate(function(g)
        g.nodes.s  = source('guid-A')
        g.nodes.f1 = fx('VST:Filter', nil)
        g.nodes.f2 = fx('VST:Synth',  nil)
        util.add(g.edges, audioEdge('s',  'f1'))
        util.add(g.edges, midiEdge ('f1', 'f2'))
        util.add(g.edges, audioEdge('f2', 'master'))
      end)
      apply(wm)
      local function flagFor(ident)
        for i = 0, h.reaper.TrackFX_GetCount(track) - 1 do
          local _, id = h.reaper.TrackFX_GetFXName(track, i)
          if id == ident then return routingFlag(h, track, i) end
        end
      end
      local f1Flag, f2Flag = flagFor('VST:Filter'), flagFor('VST:Synth')
      t.truthy(f1Flag, 'f1 routing bytes captured')
      t.truthy(f2Flag, 'f2 routing bytes captured')
      t.eq(f1Flag & 0x02, 0,    'f1 has outgoing midi edge — bit clear')
      t.eq(f2Flag & 0x02, 0x02, 'f2 has no outgoing midi edge — bit set')
    end,
  },
  {
    name = 'fxRouting/apply: removing the midi edge flips f1 from clear to set',
    run = function(harness)
      local h, wm = mkWm(harness)
      local track = seedSource(h, 'guid-A')
      wm:mutate(function(g)
        g.nodes.s  = source('guid-A')
        g.nodes.f1 = fx('VST:Filter', nil)
        g.nodes.f2 = fx('VST:Synth',  nil)
        util.add(g.edges, audioEdge('s',  'f1'))
        util.add(g.edges, midiEdge ('f1', 'f2'))
        util.add(g.edges, audioEdge('f2', 'master'))
      end)
      apply(wm)
      local function flagFor(ident)
        for i = 0, h.reaper.TrackFX_GetCount(track) - 1 do
          local _, id = h.reaper.TrackFX_GetFXName(track, i)
          if id == ident then return routingFlag(h, track, i) end
        end
      end
      t.eq(flagFor('VST:Filter') & 0x02, 0, 'f1 bit clear initially')
      wm:mutate(function(g)
        g.edges = {
          audioEdge('s',  'f1'),
          audioEdge('f1', 'f2'),
          audioEdge('f2', 'master'),
        }
      end)
      apply(wm)
      t.eq(flagFor('VST:Filter') & 0x02, 0x02,
           'f1 bit flipped to set after midi edge swapped for audio')
    end,
  },
  {
    name = 'fxRouting/apply: CU bridge JSFX is not patched and not counted',
    run = function(harness)
      -- Edge carries an `ops` payload, so the lowering inserts a CU bridge
      -- (JS:Continuum Utility) at slot 0; the user fx lands at slot 1. The
      -- VST fx is routing-index 0 and gets patched; CU has no routingBytes.
      local h, wm = mkWm(harness)
      local track = seedSource(h, 'guid-A')
      h.reaper:setFxParamNames('JS:Continuum Utility', { 'mode', 'gain' })
      wm:mutate(function(g)
        g.nodes.s = source('guid-A')
        g.nodes.f = fx('VST:Foo', nil)
        util.add(g.edges, audioEdge('s', 'f', { ops = { gain = 0.5 } }))
        util.add(g.edges, audioEdge('f', 'master'))
      end)
      apply(wm)
      local _, slot0Ident = h.reaper.TrackFX_GetFXName(track, 0)
      t.eq(slot0Ident, 'JS:Continuum Utility', 'CU bridge at slot 0')
      t.eq(routingFlag(h, track, 0), nil, 'CU JSFX never patched')
      local fxFlag = routingFlag(h, track, 1)
      t.truthy(fxFlag, 'VST fx routing bytes captured')
      t.eq(fxFlag & 0x02, 0x02, 'VST fx (routing-index 0) patched as output-disabled')
    end,
  },
}
