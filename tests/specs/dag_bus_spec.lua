-- Matrix-buss isolation + sub-threshold splice (design/wiring-busses-v2.md § DAG):
-- ≥2x2 bus is classed alone; anything below splices to direct edges at product gains.
local t   = require('support')
local DAG = require('DAG')

local function source(id, guid)
  return id, { kind = 'source', trackId = guid or 'guid-' .. id,
               pos = { x = 0, y = 0 },
               ports = { audio = { ins = 0, outs = 1 },
                         midi  = { ins = 0, outs = 1 } } }
end

local function fx(id, opts)
  opts = opts or {}
  return id, { kind = 'fx', pos = { x = 0, y = 0 },
               fxIdent = 'JS:test', fxDisplay = 'FX',
               ports = { audio = { ins  = opts.ins  or 1,
                                   outs = opts.outs or 1 },
                         midi  = { ins = 1, outs = 1 } } }
end

local function bus(id)
  return id, { kind = 'bus', pos = { x = 0, y = 0 }, orient = 'V',
               ports = { audio = { ins = 1, outs = 1 }, midi = { ins = 0, outs = 0 } } }
end

local function mk(nodes, edges)
  if not nodes.master then
    nodes.master = { kind = 'master', pos = { x = 0, y = 0 },
                     ports = { audio = { ins = 1, outs = 0 }, midi = { ins = 0, outs = 0 } } }
  end
  return { nodes = nodes, edges = edges or {} }
end

local function audio(from, to, gain)
  local e = { type = 'audio', from = from, to = to }
  if gain then e.ops = { gain = gain } end
  return e
end

-- s1, s2 -> bus -> fa, fb -> master: the canonical 2x2 matrix.
local function matrix()
  local ns = {}
  local k, v
  k, v = source('s1', 'g1'); ns[k] = v
  k, v = source('s2', 'g2'); ns[k] = v
  k, v = bus('bus-1');       ns[k] = v
  k, v = fx('fa');           ns[k] = v
  k, v = fx('fb');           ns[k] = v
  return mk(ns, {
    audio('s1', 'bus-1'),
    audio('s2', 'bus-1'),
    audio('bus-1', 'fa'),
    audio('bus-1', 'fb'),
    audio('fa', 'master'),
    audio('fb', 'master'),
  })
end

local BUS_CLS = t.key('bus:bus-1', 'g1', 'g2')

return {
  {
    name = 'signal-bearing bus sits alone in its class; children inherit sources, not the marker',
    run = function()
      local cls = DAG.compile(matrix()):classOf()
      t.eq(cls['bus-1'], BUS_CLS)
      t.eq(cls['fa'], t.key('g1', 'g2'))
      t.eq(cls['fb'], t.key('g1', 'g2'))
    end,
  },
  {
    name = 'bus class never absorbs into its single audio parent class',
    run = function()
      -- fa+fb co-track on g1, so the matrix bus has one audio parent class;
      -- absent the guard it would auto-absorb onto g1's track.
      local ns = {}
      local k, v
      k, v = source('s1', 'g1'); ns[k] = v
      k, v = fx('fa');           ns[k] = v
      k, v = fx('fb');           ns[k] = v
      k, v = bus('bus-1');       ns[k] = v
      k, v = fx('f');            ns[k] = v
      local cx = DAG.compile(mk(ns, {
        audio('s1', 'fa'), audio('s1', 'fb'),
        audio('fa', 'bus-1'), audio('fb', 'bus-1'),
        audio('bus-1', 'f'), audio('bus-1', 'master'),
        audio('f', 'master'),
      }))
      local busCls = t.key('bus:bus-1', 'g1')
      t.eq(cx:classOf()['bus-1'], busCls)
      t.eq(cx:classTrackKey(busCls), busCls)
    end,
  },
  {
    name = 'fx fed solely by the bus keeps its own track — never absorbed onto the summing track',
    run = function()
      local cx = DAG.compile(matrix())
      local faCls = cx:classOf()['fa']
      t.eq(cx:classTrackKey(faCls), faCls)
      local tracks = DAG.targetTracks(cx)
      t.eq(#tracks[BUS_CLS].fxOrder, 0, 'summing track is fx-less')
      t.truthy(tracks[faCls], 'fx class realizes its own track')
    end,
  },
  {
    name = 'matrix realizes one fx-less summing track: in-sends pair 1, out-sends preFx, nchan 2',
    run = function()
      local g = matrix()
      local cx = DAG.compile(g)
      local tracks = DAG.allocate(DAG.targetTracks(cx), g.nodes)
      local bt = tracks[BUS_CLS]
      t.eq(bt.trackKind, 'newTrack')
      t.eq(#bt.fxOrder, 0)
      t.eq(bt.nchan, 2)
      for _, src in ipairs({ 'g1', 'g2' }) do
        local sends = tracks[src].sends
        t.eq(#sends, 1, src .. ': one in-send')
        t.eq(sends[1].to, BUS_CLS)
        t.eq(sends[1].srcChan, 0)
        t.eq(sends[1].dstChan, 0, src .. ': lands on pair 1')
      end
      local fCls = cx:classOf()['fa']
      t.eq(#bt.sends, 2)
      for _, s in ipairs(bt.sends) do
        t.eq(s.to, fCls)
        t.truthy(s.preFx, 'out-send taps pre-fx (the summed input)')
        t.eq(s.srcChan, 0)
      end
    end,
  },
  {
    name = 'gains land natively: in-send, out-send, main-send volumes; no CU anywhere',
    run = function()
      local ns = {}
      local k, v
      k, v = source('s1', 'g1'); ns[k] = v
      k, v = source('s2', 'g2'); ns[k] = v
      k, v = bus('bus-1');       ns[k] = v
      k, v = fx('f');            ns[k] = v
      local cx = DAG.compile(mk(ns, {
        audio('s1', 'bus-1', 0.5),
        audio('s2', 'bus-1'),
        audio('bus-1', 'f', 0.7),
        audio('bus-1', 'master', 0.9),
        audio('f', 'master'),
      }))
      local tracks = DAG.targetTracks(cx)
      local busCls = cx:classOf()['bus-1']
      local fCls   = cx:classOf()['f']
      t.eq(tracks['g1'].outWires[1].gain, 0.5)
      t.eq(tracks['g2'].outWires[1].gain, nil)
      local toF
      for _, w in ipairs(tracks[busCls].outWires) do
        if w.to == fCls then toF = w end
      end
      t.eq(toF.gain, 0.7)
      t.eq(tracks[busCls].mainSendGain, 0.9)
      t.eq(tracks[busCls].parentFeed.from, 'bus-1', 'single master feed, straight from the bus')
      for trackKey, entry in pairs(tracks) do
        t.falsy(entry.synthNodes and next(entry.synthNodes), trackKey .. ': no CU minted')
      end
    end,
  },
  {
    name = 'two matrix taps from one track: each wire keeps its own gain on its own send',
    run = function()
      local ns = {}
      local k, v
      k, v = source('s1', 'g1'); ns[k] = v
      k, v = fx('fa');           ns[k] = v
      k, v = fx('fb');           ns[k] = v
      k, v = bus('bus-1');       ns[k] = v
      k, v = fx('f');            ns[k] = v
      local cx = DAG.compile(mk(ns, {
        audio('s1', 'fa'),
        audio('s1', 'fb'),
        audio('fa', 'bus-1', 0.5),
        audio('fb', 'bus-1', 0.25),
        audio('bus-1', 'master'),
        audio('bus-1', 'f'),
        audio('f', 'master'),
      }))
      local tracks = DAG.targetTracks(cx)
      local gains = {}
      for _, w in ipairs(tracks['g1'].outWires) do gains[w.from] = w.gain end
      t.eq(gains['fa'], 0.5)
      t.eq(gains['fb'], 0.25)
      t.falsy(tracks['g1'].synthNodes and next(tracks['g1'].synthNodes),
              'no CU for the shared route — gains ride the per-srcChan sends')
    end,
  },
  {
    name = 'degenerate busses splice to nothing: no class, no track, no stray wires',
    run = function()
      local function degenerate(extra)
        local ns = {}
        local k, v
        k, v = source('s1', 'g1'); ns[k] = v
        k, v = fx('f');            ns[k] = v
        k, v = bus('bus-1');       ns[k] = v
        local edges = { audio('s1', 'f'), audio('f', 'master') }
        if extra then edges[#edges + 1] = extra end
        return DAG.compile(mk(ns, edges))
      end
      for _, case in ipairs({
        { 'unwired' },
        { 'in-only',  audio('s1', 'bus-1') },
        { 'out-only', audio('bus-1', 'f') },
      }) do
        local name, cx = case[1], degenerate(case[2])
        t.eq(cx:classOf()['bus-1'], nil, name .. ': spliced out of the working graph')
        for trackKey, entry in pairs(DAG.targetTracks(cx)) do
          t.falsy(trackKey:find('bus:', 1, true), name .. ': no bus track')
          for _, w in ipairs(entry.outWires) do
            t.truthy(w.from ~= 'bus-1' and w.toNode ~= 'bus-1', name .. ': no bus outWires')
          end
          for _, c in ipairs(entry.intraConns) do
            t.truthy(c.from ~= 'bus-1' and c.to ~= 'bus-1', name .. ': no bus intraConns')
          end
        end
      end
    end,
  },
  {
    name = 'fan-in splices out: per-source direct sends at in×out product gains',
    run = function()
      local ns = {}
      local k, v
      k, v = source('s1', 'g1'); ns[k] = v
      k, v = source('s2', 'g2'); ns[k] = v
      k, v = source('s3', 'g3'); ns[k] = v
      k, v = bus('bus-1');       ns[k] = v
      k, v = fx('f');            ns[k] = v
      -- s3 feeds master independently so f keeps its own track (no master fold)
      local cx = DAG.compile(mk(ns, {
        audio('s1', 'bus-1', 0.5),
        audio('s2', 'bus-1'),
        audio('bus-1', 'f', 0.75),
        audio('f', 'master'),
        audio('s3', 'master'),
      }))
      t.eq(cx:classOf()['bus-1'], nil, 'bus spliced out of the working graph')
      local tracks = DAG.targetTracks(cx)
      local fCls = cx:classOf()['f']
      local w1, w2 = tracks['g1'].outWires[1], tracks['g2'].outWires[1]
      t.eq(w1.to, fCls); t.eq(w1.toNode, 'f')
      t.eq(w1.gain, 0.375, 's1 crossing at 0.5 × 0.75')
      t.eq(w2.gain, 0.75,  'unset tap defaults to 1')
      for trackKey in pairs(tracks) do
        t.falsy(trackKey:find('bus:', 1, true), 'no summing track')
      end
    end,
  },
  {
    name = 'fan-out splice: crossings carry composed gains + full provenance',
    run = function()
      local ns = {}
      local k, v
      k, v = source('s1', 'g1'); ns[k] = v
      k, v = bus('bus-1');       ns[k] = v
      k, v = fx('fa');           ns[k] = v
      k, v = fx('fb');           ns[k] = v
      -- authored: 1 s1→bus, 2 bus→fa, 3 bus→fb, 4 fa→master, 5 fb→master
      local cx = DAG.compile(mk(ns, {
        audio('s1', 'bus-1', 0.5),
        audio('bus-1', 'fa', 0.75),
        audio('bus-1', 'fb'),
        audio('fa', 'master'),
        audio('fb', 'master'),
      }))
      local crossings = {}
      for idx, e in ipairs(cx.userGraph.edges) do
        if e.from == 's1' then
          crossings[e.to] = { gain = e.ops and e.ops.gain, parts = cx.splice.parts[idx] }
        end
        if e.from == 'fa' and e.to == 'master' then
          t.eq(#cx.splice.parts[idx], 1, 'carried edge maps 1:1')
          t.eq(cx.splice.parts[idx][1], 4)
        end
      end
      t.eq(crossings.fa.gain, 0.375)
      t.eq(crossings.fb.gain, 0.5)
      t.eq(#crossings.fa.parts, 2)
      t.eq(crossings.fa.parts[1], 1); t.eq(crossings.fa.parts[2], 2)
      t.eq(crossings.fb.parts[1], 1); t.eq(crossings.fb.parts[2], 3)
    end,
  },
  {
    name = 'chained fans compose: n→1→m splices to n×m crossings with three-factor gains',
    run = function()
      local ns = {}
      local k, v
      k, v = source('s1', 'g1'); ns[k] = v
      k, v = source('s2', 'g2'); ns[k] = v
      k, v = bus('bus-1');       ns[k] = v
      k, v = bus('bus-2');       ns[k] = v
      k, v = fx('fa');           ns[k] = v
      k, v = fx('fb');           ns[k] = v
      local cx = DAG.compile(mk(ns, {
        audio('s1', 'bus-1', 0.5),
        audio('s2', 'bus-1'),
        audio('bus-1', 'bus-2', 0.25),
        audio('bus-2', 'fa', 0.5),
        audio('bus-2', 'fb'),
        audio('fa', 'master'),
        audio('fb', 'master'),
      }))
      local got = {}
      for idx, e in ipairs(cx.userGraph.edges) do
        if e.from == 's1' or e.from == 's2' then
          got[e.from .. '>' .. e.to] = { gain = e.ops and e.ops.gain,
                                         nParts = #cx.splice.parts[idx] }
        end
      end
      t.eq(got['s1>fa'].gain, 0.0625, '0.5 × 0.25 × 0.5')
      t.eq(got['s1>fb'].gain, 0.125)
      t.eq(got['s2>fa'].gain, 0.125)
      t.eq(got['s2>fb'].gain, 0.25)
      for key, crossing in pairs(got) do
        t.eq(crossing.nParts, 3, key .. ': three authored taps')
      end
    end,
  },
}
