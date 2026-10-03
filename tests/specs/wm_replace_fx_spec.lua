-- wm:replaceFx is the replace-context pick of the fx picker (docs/wiringPage.md § The fx
-- picker): the plugin takes the node's place and every wire on it, as one undo step. A
-- plugin too narrow for the wires is removed again, so the graph stands as it was; only an
-- unprobed plugin can get that far, and its probe stays in the catalogue.
local t    = require('support')
local util = require('util')

-- setFxIO counts pins; the graph and the need count pairs. VST3, so the format mark
-- gives each a MIDI in and out (wm_fx_traits_spec).
local COMP   = { name = 'VST3: Comp (Acme)',   ident = '/Library/Audio/Plug-Ins/VST3/Comp.vst3',
                 key = 'Comp.vst3',   io = { ins = 2, outs = 2 } }
local SYNTH  = { name = 'VST3i: Synth (Acme)', ident = '/Library/Audio/Plug-Ins/VST3/Synth.vst3',
                 key = 'Synth.vst3',  io = { ins = 0, outs = 4 } }
local MONO   = { name = 'VST3i: Mono (Acme)',  ident = '/Library/Audio/Plug-Ins/VST3/Mono.vst3',
                 key = 'Mono.vst3',   io = { ins = 0, outs = 2 } }
local PLUGINS = { COMP, SYNTH, MONO }

local function mkWm(harness)
  local h = harness.mk()
  h.reaper:setInstalledFx(PLUGINS)
  for _, fx in ipairs(PLUGINS) do h.reaper:setFxIO(fx.ident, fx.io) end
  h.ds:assign('fxCatalogue', { n = 0, entries = {} })
  local rm = util.instantiate('routingManager', { ds = h.ds })
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
  wm:load()
  return h, wm
end

local function pick(fx) return { name = fx.name, ident = fx.ident } end

-- An fx node seeded directly, with no REAPER instance behind its fxId.
local function fxNode(id, ins, outs, midiIns, midiOuts)
  return { kind = 'fx', fxId = id, fxIdent = 'VST:F', fxDisplay = 'F', pos = { x = 7, y = 9 },
           ports = { audio = { ins = ins, outs = outs },
                     midi  = { ins = midiIns, outs = midiOuts } } }
end

local function sourceNode(tagPos)
  return { kind = 'source', trackId = 's', pos = { x = 0, y = 0 }, tagPos = tagPos,
           ports = { audio = { ins = 0, outs = 1 }, midi = { ins = 0, outs = 1 } } }
end

-- s --midi--> f --audio(pair `outPair`, gain 0.5, primary)--> master. Both wires carry a
-- source-tag offset: s's on its MIDI wire, f's on its audio wire.
local function seedInstrument(wm, outPair)
  local ok, err = wm:mutate(function(g)
    g.nodes.s = sourceNode({ ['midi/f/1'] = { x = 3, y = 4 } })
    g.nodes.f = fxNode('f', 0, 2, 1, 0)
    g.nodes.f.tagPos = { ['audio/master/1'] = { x = 5, y = 6 } }
    util.add(g.edges, { type = 'midi', from = 's', to = 'f' })
    util.add(g.edges, { type = 'audio', from = 'f', fromPort = outPair, to = 'master', toPort = 1,
                        ops = { gain = 0.5 }, primary = true })
  end)
  t.truthy(ok, 'precondition: the instrument is seeded ' .. tostring(err and err.code))
end

-- s --audio(gain 0.5)--> f --audio--> master
local function seedEffect(wm)
  local ok = wm:mutate(function(g)
    g.nodes.s = sourceNode(nil)
    g.nodes.f = fxNode('f', 1, 1, 0, 0)
    util.add(g.edges, { type = 'audio', from = 's', to = 'f', ops = { gain = 0.5 } })
    util.add(g.edges, { type = 'audio', from = 'f', to = 'master' })
  end)
  t.truthy(ok, 'precondition: the effect is seeded')
end

local function edgesAt(wm, id)
  return util.filter(wm:graph().edges, function(e) return e.from == id or e.to == id end)
end

local function count(tbl)
  local n = 0
  for _ in pairs(tbl) do n = n + 1 end
  return n
end

local function holdsKey(rows, key)
  for _, row in ipairs(rows) do
    if row.key == key then return true end
  end
  return false
end

-- Outermost undo labels only; rm:transaction reads reaper at call time, so a stub
-- installed after the managers are built still counts.
local function collectLabels(h)
  t.truthy(reaper == h.reaper, 'precondition: the global reaper is the harness\'s')
  local depth, out = 0, {}
  h.reaper.Undo_BeginBlock = function() depth = depth + 1 end
  h.reaper.Undo_EndBlock2  = function(_, label)
    depth = depth - 1
    if depth == 0 then util.add(out, label) end
  end
  return out
end

return {
  {
    name = 'cover need: the highest pair wired on each side, and 1 for any MIDI wire',
    run = function(harness)
      local _, wm = mkWm(harness)
      seedInstrument(wm, 2)
      t.deepEq(wm:coverNeed('f'), { audio = { ins = 0, outs = 2 }, midi = { ins = 1, outs = 0 } })
      t.deepEq(wm:coverNeed('master'), { audio = { ins = 1, outs = 0 }, midi = { ins = 0, outs = 0 } })
    end,
  },
  {
    name = 'cover need: a lower pair wired after a higher one leaves the highest standing',
    run = function(harness)
      local _, wm = mkWm(harness)
      local ok, err = wm:mutate(function(g)
        g.nodes.s = sourceNode(nil)
        g.nodes.f = fxNode('f', 2, 2, 0, 0)
        util.add(g.edges, { type = 'audio', from = 's', to = 'f', toPort = 2 })
        util.add(g.edges, { type = 'audio', from = 's', to = 'f', toPort = 1 })
        util.add(g.edges, { type = 'audio', from = 'f', fromPort = 2, to = 'master' })
        util.add(g.edges, { type = 'audio', from = 'f', fromPort = 1, to = 'master' })
      end)
      t.truthy(ok, 'precondition: seeded ' .. tostring(err and err.code))
      t.deepEq(wm:coverNeed('f').audio, { ins = 2, outs = 2 })
    end,
  },
  {
    name = 'instrument for instrument: the source still feeds it, its audio wire keeps port, ops and flag',
    run = function(harness)
      local _, wm = mkWm(harness)
      seedInstrument(wm, 2)
      local nodes, edges = count(wm:graph().nodes), #wm:graph().edges
      local id = wm:replaceFx('f', pick(SYNTH))
      t.truthy(id, 'replace lands')
      local g = wm:graph()
      t.eq(g.nodes.f, nil, 'the old node is gone')
      t.deepEq(g.nodes[id].pos, { x = 7, y = 9 }, 'the plugin takes the node\'s position')
      t.eq(count(g.nodes), nodes, 'no source node is spawned')
      t.eq(#g.edges, edges, 'no wire is added or lost')
      t.deepEq(edgesAt(wm, id), {
        { type = 'midi', from = 's', to = id },
        { type = 'audio', from = id, fromPort = 2, to = 'master', toPort = 1,
          ops = { gain = 0.5 }, primary = true },
      })
      t.deepEq(g.nodes.s.tagPos, { ['midi/' .. id .. '/1'] = { x = 3, y = 4 } },
               'the source\'s tag follows its wire')
      t.deepEq(g.nodes[id].tagPos, { ['audio/master/1'] = { x = 5, y = 6 } },
               'the node\'s own tags come with it')
    end,
  },
  {
    name = 'an instrument on pair 1 to master: the plugin\'s own master wire gives way to the node\'s',
    run = function(harness)
      local _, wm = mkWm(harness)
      seedInstrument(wm, 1)
      local id, err = wm:replaceFx('f', pick(SYNTH))
      t.truthy(id, 'replace lands ' .. tostring(err and err.code))
      local toMaster = util.filter(edgesAt(wm, id), function(e) return e.to == 'master' end)
      t.eq(#toMaster, 1)
      t.deepEq(toMaster[1].ops, { gain = 0.5 }, 'the surviving wire is the node\'s')
    end,
  },
  {
    name = 'effect for effect: the wire in keeps its ops, the wire out its destination',
    run = function(harness)
      local _, wm = mkWm(harness)
      seedEffect(wm)
      local id = wm:replaceFx('f', pick(COMP))
      t.truthy(id, 'replace lands')
      t.deepEq(edgesAt(wm, id), {
        { type = 'audio', from = 's', to = id, ops = { gain = 0.5 } },
        { type = 'audio', from = id, to = 'master' },
      })
    end,
  },
  {
    name = 'a plugin too narrow for the wires leaves the graph as it was, and the probe stays',
    run = function(harness)
      local _, wm = mkWm(harness)
      seedInstrument(wm, 2)
      local need = wm:coverNeed('f')
      t.truthy(holdsKey(wm:fxPickerSource(need).rows, MONO.key),
               'precondition: unprobed, the one-pair synth is offered')
      local graph = wm:graph()
      local id, err = wm:replaceFx('f', pick(MONO))
      t.eq(id, nil)
      t.eq(err and err.code, 'audio_from_port_oob')
      t.deepEq(wm:graph(), graph, 'the graph stands as before')
      t.falsy(holdsKey(wm:fxPickerSource(need).rows, MONO.key),
              'its recorded ports now keep it out of the replace')
    end,
  },
  {
    name = 'a replace is one undo step under the replace label, landed or rolled back',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedInstrument(wm, 2)
      local labels = collectLabels(h)
      t.truthy(wm:replaceFx('f', pick(SYNTH)), 'precondition: replace lands')
      t.deepEq(labels, { 'wiring: replace F with Synth' })

      local h2, wm2 = mkWm(harness)
      seedInstrument(wm2, 2)
      local labels2 = collectLabels(h2)
      t.eq(wm2:replaceFx('f', pick(MONO)), nil, 'precondition: refused')
      t.eq(#labels2, 1, 'the rollback shares the one block')
    end,
  },
  {
    name = 'a node that is no fx: refused before anything is instantiated',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedInstrument(wm, 2)
      local n = h.ds:get('fxCatalogue').n
      for _, nodeId in ipairs({ 's', 'master', 'nowhere' }) do
        local id, err = wm:replaceFx(nodeId, pick(SYNTH))
        t.eq(id, nil)
        t.eq(err and err.code, 'not_fx', nodeId)
      end
      t.eq(h.ds:get('fxCatalogue').n, n, 'no use recorded, so nothing instantiated')
      t.truthy(wm:replaceFx('f', pick(SYNTH)), 'precondition: a real replace lands')
      t.truthy(h.ds:get('fxCatalogue').n > n, 'precondition: an instantiation does bump n')
    end,
  },
}
