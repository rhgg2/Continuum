-- Integration: wm:applyOps reconciles per-FX MIDI routing against the user graph;
-- wm:snapshot decodes it back. See docs/wiringManager.md § Routing as ground truth.

local t    = require('support')
local util = require('util')

local CU_PARAMS = { 'mode', 'gain', 'bus', 'nPairs',
  'gain1', 'gain2', 'gain3', 'gain4', 'gain5', 'gain6', 'gain7', 'gain8',
  'gain9', 'gain10', 'gain11', 'gain12', 'gain13', 'gain14', 'gain15', 'gain16',
  'outBus', 'inMask0', 'inMask1', 'inMask2', 'inMask3', 'audioSum' }

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

-- Mint an fx on scratch (as wm:addFxNode does in production) so the node enters the
-- graph carrying a live guid; reconcile then MOVES it onto its track.
local function mintFx(wm, ident, opts)
  opts = opts or {}
  local r = wm:instantiateFxOnScratch(ident)
  return { kind='fx', fxIdent=ident, fxId=r.fxId, pos={x=0,y=0},
           ports={audio={ins=opts.ins or 1, outs=opts.outs or 1}, midi={ins=1, outs=1}} }
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

-- Fall back to the fake's default (0x10) for non-JS FX when no write
-- happened; JS plugins have no routing trailer at all so return nil.
local function routingFlag(h, track, idx)
  local entry = h.reaper._state.fxByTrack[track] and
                h.reaper._state.fxByTrack[track][idx + 1]
  if not entry then return nil end
  if entry.routingBytes then return entry.routingBytes.flag end
  local ident = type(entry) == 'table' and entry.ident or entry
  if ident and ident:sub(1, 3) == 'JS:' then return nil end
  return 0x10
end

return {
  {
    name = 'fxRouting/apply: audio-only fx gets midi-out disabled',
    run = function(harness)
      local h, wm = mkWm(harness)
      local track = seedSource(h, 'guid-A')
      wm:mutate(function(g)
        g.nodes.s = source('guid-A')
        g.nodes.f = mintFx(wm, 'VST:Foo', nil)
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
        g.nodes.f1 = mintFx(wm, 'VST:Filter', nil)
        g.nodes.f2 = mintFx(wm, 'VST:Synth',  nil)
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
        g.nodes.f1 = mintFx(wm, 'VST:Filter', nil)
        g.nodes.f2 = mintFx(wm, 'VST:Synth',  nil)
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
      h.reaper:setFxParamNames('JS:Continuum Utility', CU_PARAMS)
      wm:mutate(function(g)
        g.nodes.s = source('guid-A')
        g.nodes.f = mintFx(wm, 'VST:Foo', nil)
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
  {
    name = 'fxRouting/apply: snapshot decodes routing back; re-apply emits no setFXChain',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      wm:mutate(function(g)
        g.nodes.s = source('guid-A')
        g.nodes.f = mintFx(wm, 'VST:Foo', nil)
        util.add(g.edges, audioEdge('s', 'f'))
        util.add(g.edges, audioEdge('f', 'master'))
      end)
      apply(wm)
      -- snapshot decodes the chunk the apply wrote; it must agree with the
      -- target intent so fxOrderEq sees no drift on the next reconcile.
      local snap   = wm:snapshot()
      local target = wm:targetState()
      local sEntry = snap['guid-A'].fx[1]
      local tEntry = target['guid-A'].fx[1]
      t.eq(sEntry.ident, 'VST:Foo')
      t.eq(sEntry.midi.outDisabled, true, 'audio-only fx decoded as output-disabled')
      t.deepEq(sEntry.midi, tEntry.midi, 'decoded routing matches target')
      for _, op in ipairs(wm:diff(target, snap)) do
        t.eq(op.op == 'setFXChain', false, 'routing roundtripped; got op=' .. op.op)
      end
    end,
  },
}
