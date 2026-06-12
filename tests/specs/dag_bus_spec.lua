-- Matrix-buss isolation (design/wiring-busses-v2.md § DAG): a signal-bearing
-- kind='bus' node sits alone in its class, absorbs in neither direction, and
-- realizes as one fx-less summing track with native per-tap gains.
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
    name = 'bus class never absorbs into its single audio parent',
    run = function()
      -- 1-in bus: absent the guard, one audio parent (g1) would auto-absorb it.
      local ns = {}
      local k, v
      k, v = source('s1', 'g1'); ns[k] = v
      k, v = bus('bus-1');       ns[k] = v
      k, v = fx('f');            ns[k] = v
      local cx = DAG.compile(mk(ns, {
        audio('s1', 'bus-1'), audio('bus-1', 'f'), audio('f', 'master'),
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
      t.eq(tracks[busCls].masterFeed.from, 'bus-1', 'single master feed, straight from the bus')
      for trackKey, entry in pairs(tracks) do
        t.falsy(entry.synthNodes and next(entry.synthNodes), trackKey .. ': no CU minted')
      end
    end,
  },
  {
    name = 'two taps from one track: each wire keeps its own gain on its own send',
    run = function()
      local ns = {}
      local k, v
      k, v = source('s1', 'g1'); ns[k] = v
      k, v = fx('fa');           ns[k] = v
      k, v = fx('fb');           ns[k] = v
      k, v = bus('bus-1');       ns[k] = v
      local cx = DAG.compile(mk(ns, {
        audio('s1', 'fa'),
        audio('s1', 'fb'),
        audio('fa', 'bus-1', 0.5),
        audio('fb', 'bus-1', 0.25),
        audio('bus-1', 'master'),
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
    name = 'degenerate busses are inert: no class, no track, no stray wires',
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
        t.eq(cx:classOf()['bus-1'], '', name .. ': inert class')
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
}
