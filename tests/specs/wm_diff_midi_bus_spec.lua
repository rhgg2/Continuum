local t    = require('support')
local util = require('util')

-- 3c.3a.1 send-side encode/decode of MIDI bus indices through I_MIDIFLAGS
-- bits 14..21 (src bus) / 22..29 (dst bus). N+1 encoding; 0 reads as bus 0.

-- Full CU slider set: a midi fan-in to one consumer materialises a merge CU,
-- whose params (nPairs/gains/inMask0..3/outBus/audioSum) flatten to CU sliders.
local CU_PARAMS = { 'mode', 'gain', 'from', 'nPairs',
  'gain1', 'gain2', 'gain3', 'gain4', 'gain5', 'gain6', 'gain7', 'gain8',
  'gain9', 'gain10', 'gain11', 'gain12', 'gain13', 'gain14', 'gain15', 'gain16',
  'outBus', 'inMask0', 'inMask1', 'inMask2', 'inMask3', 'audioSum', 'to' }

local function mkWm(harness)
  local h  = harness.mk()
  h.reaper:setFxParamNames('JS:Continuum Utility', CU_PARAMS)
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

-- Mint an fx on scratch (as wm:addFxNode does in production) so the node enters the
-- graph carrying a live guid; reconcile then MOVES it onto its track.
local function mintFx(wm, ident, opts)
  opts = opts or {}
  local r = wm:instantiateFxOnScratch(ident)
  return { kind='fx', fxIdent=ident, fxId=r.fxId, pos={x=0,y=0},
           ports={audio={ins=opts.ins or 1, outs=opts.outs or 1}, midi={ins=1, outs=0}} }
end

local function midiEdge(from, to)
  return { type='midi', from=from, to=to }
end

local function apply(wm)
  wm:applyOps(wm:diff(wm:targetState(), wm:snapshot()))
end

local function decodeBus(field, shift)
  return math.max(0, ((math.floor(field) >> shift) & 0xFF) - 1)
end

return {
  {
    name = 'midi bus: srcChan=0/dstChan=0 leaves I_MIDIFLAGS at 0 (REAPER default)',
    run = function(harness)
      local h, wm = mkWm(harness)
      local trackA = seedSource(h, 'guid-A')
      wm:mutate(function(g)
        g.nodes.sA  = source('guid-A')
        g.nodes.fxB = mintFx(wm, 'JS:b')
        util.add(g.edges, midiEdge('sA', 'fxB'))
      end)
      apply(wm)
      local mf = h.reaper.GetTrackSendInfo_Value(trackA, 0, 0, 'I_MIDIFLAGS')
      t.eq(mf, 0, 'no bus bits written when allocator picks 0/0')
    end,
  },
  {
    name = 'midi bus: two sources into one fx share one receiver bus (coalesced)',
    run = function(harness)
      local h, wm = mkWm(harness)
      local trackA = seedSource(h, 'guid-A')
      local trackB = seedSource(h, 'guid-B')
      wm:mutate(function(g)
        g.nodes.sA  = source('guid-A')
        g.nodes.sB  = source('guid-B')
        g.nodes.fxB = mintFx(wm, 'JS:b')
        util.add(g.edges, midiEdge('sA', 'fxB'))
        util.add(g.edges, midiEdge('sB', 'fxB'))
      end)
      apply(wm)
      local mfA = h.reaper.GetTrackSendInfo_Value(trackA, 0, 0, 'I_MIDIFLAGS')
      local mfB = h.reaper.GetTrackSendInfo_Value(trackB, 0, 0, 'I_MIDIFLAGS')
      local dstChans = { decodeBus(mfA, 22), decodeBus(mfB, 22) }
      table.sort(dstChans)
      t.deepEq(dstChans, { 0, 0 }, 'coalesced onto a shared receiver bus')
      t.eq(decodeBus(mfA, 14), 0, 'srcA on boundary bus 0')
      t.eq(decodeBus(mfB, 14), 0, 'srcB on boundary bus 0')
    end,
  },
  {
    name = 'midi bus: snapshot decodes I_MIDIFLAGS bus bits back into srcChan/dstChan',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      seedSource(h, 'guid-B')
      wm:mutate(function(g)
        g.nodes.sA  = source('guid-A')
        g.nodes.sB  = source('guid-B')
        g.nodes.fxB = mintFx(wm, 'JS:b')
        util.add(g.edges, midiEdge('sA', 'fxB'))
        util.add(g.edges, midiEdge('sB', 'fxB'))
      end)
      apply(wm)
      local snap = wm:snapshot()
      local newTrackKey
      for k, e in pairs(snap) do
        if e.trackKind == 'newTrack' then newTrackKey = k end
      end
      t.truthy(newTrackKey, 'newTrack class present')
      local sendA = snap['guid-A'].sends[1]
      local sendB = snap['guid-B'].sends[1]
      t.eq(sendA.kind, 'midi')
      t.eq(sendA.to,   newTrackKey)
      local dstChans = { sendA.dstChan, sendB.dstChan }
      table.sort(dstChans)
      t.deepEq(dstChans, { 0, 0 }, 'both sends coalesce onto one receiver bus')
    end,
  },
  {
    name = 'midi bus: idempotent — encode-decode roundtrip leaves diff empty on re-apply',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedSource(h, 'guid-A')
      seedSource(h, 'guid-B')
      wm:mutate(function(g)
        g.nodes.sA  = source('guid-A')
        g.nodes.sB  = source('guid-B')
        g.nodes.fxB = mintFx(wm, 'JS:b')
        util.add(g.edges, midiEdge('sA', 'fxB'))
        util.add(g.edges, midiEdge('sB', 'fxB'))
      end)
      apply(wm)
      -- Bus-bit roundtrip is stable iff no setSends op fires on re-apply.
      -- Audio pin defaults on midi-only newTracks may drive setPinMaps;
      -- that's orthogonal to the bus encoding we're testing.
      local ops = wm:diff(wm:targetState(), wm:snapshot())
      for _, op in ipairs(ops) do
        t.eq(op.op == 'setSends', false,
             'no setSends op (bus bits roundtripped); got op=' .. op.op)
      end
    end,
  },
}
