-- wm:insertFx is the splice-context pick of the fx picker (docs/wiringPage.md § The fx
-- picker): it adds the plugin at the triangle and splices it into the wire as one undo
-- step. A plugin that can't take the splice is removed again, so the graph stands as it
-- was; only an unprobed plugin can get that far, and its probe stays in the catalogue.
local t    = require('support')
local util = require('util')

-- VST3, so the format mark gives each a MIDI in and out (wm_fx_traits_spec).
local COMP  = { name = 'VST3: Comp (Acme)',  ident = '/Library/Audio/Plug-Ins/VST3/Comp.vst3',
                key = 'Comp.vst3',  io = { ins = 2, outs = 2 } }
local SYNTH = { name = 'VST3i: Synth (Acme)', ident = '/Library/Audio/Plug-Ins/VST3/Synth.vst3',
                key = 'Synth.vst3', io = { ins = 0, outs = 2 } }

local AUDIO_NEED = { audio = { ins = 1, outs = 1 } }

local function mkWm(harness)
  local h = harness.mk()
  h.reaper:setInstalledFx({ COMP, SYNTH })
  for _, fx in ipairs({ COMP, SYNTH }) do h.reaper:setFxIO(fx.ident, fx.io) end
  h.ds:assign('fxCatalogue', { n = 0, entries = {} })
  local rm = util.instantiate('routingManager', { ds = h.ds })
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
  wm:load()
  return h, wm
end

local function pick(fx) return { name = fx.name, ident = fx.ident } end

-- An fx node seeded directly, with no REAPER instance behind its fxId.
local function fxNode(id, ins, outs, midiIns, midiOuts)
  return { kind = 'fx', fxId = id, fxIdent = 'VST:F', fxDisplay = 'F', pos = { x = 0, y = 0 },
           ports = { audio = { ins = ins, outs = outs },
                     midi  = { ins = midiIns, outs = midiOuts } } }
end

local function edgeIndex(wm, from, to, type)
  for i, e in ipairs(wm:graph().edges) do
    if e.from == from and e.to == to and e.type == type then return i end
  end
end

-- s --type--> f, s a source seeded directly (no REAPER track) and f out to master;
-- the audio wire carries gain 0.5. Returns the wire's index.
local function seedWire(wm, type)
  wm:mutate(function(g)
    g.nodes.s = { kind = 'source', trackId = 's', pos = { x = 0, y = 0 },
                  ports = { audio = { ins = 0, outs = 1 }, midi = { ins = 0, outs = 1 } } }
    if type == 'audio' then
      g.nodes.f = fxNode('f', 1, 1, 0, 0)
      util.add(g.edges, { type = 'audio', from = 's', to = 'f', ops = { gain = 0.5 } })
    else
      g.nodes.f = fxNode('f', 0, 1, 1, 0)
      util.add(g.edges, { type = 'midi', from = 's', to = 'f' })
    end
    util.add(g.edges, { type = 'audio', from = 'f', to = 'master' })
  end)
  local idx = edgeIndex(wm, 's', 'f', type)
  t.truthy(idx, 'precondition: the ' .. type .. ' wire is seeded')
  return idx
end

-- The one edge of `type` into and out of `id`.
local function legsAt(wm, id, type)
  local into, outOf
  for _, e in ipairs(wm:graph().edges) do
    if e.type == type and e.to   == id then into  = e end
    if e.type == type and e.from == id then outOf = e end
  end
  return into, outOf
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
    name = 'audio insert: the node lands at pos, the old wire feeds it with its ops, a bare leg leaves',
    run = function(harness)
      local _, wm = mkWm(harness)
      local idx    = seedWire(wm, 'audio')
      local before = #wm:graph().edges
      local id = wm:insertFx(idx, pick(COMP), { x = 30, y = 40 })
      t.truthy(id, 'insert lands')
      local g = wm:graph()
      t.deepEq(g.nodes[id].pos, { x = 30, y = 40 })
      local into, outOf = legsAt(wm, id, 'audio')
      t.eq(into.from, 's', 'the old wire feeds the node')
      t.deepEq(into.ops, { gain = 0.5 }, 'the wire\'s ops ride the input side')
      t.eq(outOf.to, 'f', 'the new leg goes where the wire went')
      t.eq(outOf.ops, nil, 'the new leg carries no ops')
      t.eq(#g.edges, before + 1, 'nothing else is added')
    end,
  },
  {
    name = 'MIDI insert of an instrument: bare legs, no source spawned, its audio still to master',
    run = function(harness)
      local _, wm = mkWm(harness)
      local idx   = seedWire(wm, 'midi')
      local nodes = count(wm:graph().nodes)
      local id = wm:insertFx(idx, pick(SYNTH), { x = 30, y = 40 })
      t.truthy(id, 'insert lands')
      local into, outOf = legsAt(wm, id, 'midi')
      t.eq(into.from, 's')
      t.eq(outOf.to, 'f')
      for _, leg in ipairs({ into, outOf }) do
        t.truthy(leg.fromPort == nil and leg.toPort == nil and leg.ops == nil, 'MIDI legs are bare')
      end
      t.eq(count(wm:graph().nodes), nodes + 1, 'no source node is spawned')
      t.truthy(edgeIndex(wm, id, 'master', 'audio'), 'the instrument keeps its wire to master')
    end,
  },
  {
    name = 'a plugin that can\'t take the splice leaves the graph as it was, and the probe stays',
    run = function(harness)
      local _, wm = mkWm(harness)
      local idx = seedWire(wm, 'audio')
      t.truthy(holdsKey(wm:fxPickerSource(AUDIO_NEED).rows, SYNTH.key),
               'precondition: unprobed, the synth is offered for an audio splice')
      local graph = wm:graph()
      local id, err = wm:insertFx(idx, pick(SYNTH), { x = 30, y = 40 })
      t.eq(id, nil)
      t.eq(err and err.code, 'not_spliceable')
      t.deepEq(wm:graph(), graph, 'the graph stands as before')
      t.falsy(holdsKey(wm:fxPickerSource(AUDIO_NEED).rows, SYNTH.key),
              'its recorded ports now keep it out of the audio splice')
    end,
  },
  {
    name = 'an insert is one undo step under the insert label, landed or rolled back',
    run = function(harness)
      local h, wm = mkWm(harness)
      local idx    = seedWire(wm, 'audio')
      local labels = collectLabels(h)
      t.truthy(wm:insertFx(idx, pick(COMP), { x = 30, y = 40 }), 'precondition: insert lands')
      t.deepEq(labels, { 'wiring: insert Comp' })

      local h2, wm2 = mkWm(harness)
      local idx2    = seedWire(wm2, 'audio')
      local labels2 = collectLabels(h2)
      t.eq(wm2:insertFx(idx2, pick(SYNTH), { x = 30, y = 40 }), nil, 'precondition: refused')
      t.eq(#labels2, 1, 'the rollback shares the one block')
    end,
  },
  {
    name = 'no such edge: refused before anything is instantiated',
    run = function(harness)
      local h, wm = mkWm(harness)
      local idx = seedWire(wm, 'audio')
      local n   = h.ds:get('fxCatalogue').n
      local id, err = wm:insertFx(idx + 99, pick(COMP), { x = 30, y = 40 })
      t.eq(id, nil)
      t.eq(err and err.code, 'no_edge')
      t.eq(h.ds:get('fxCatalogue').n, n, 'no use recorded, so nothing instantiated')
      t.truthy(wm:insertFx(idx, pick(COMP), { x = 30, y = 40 }), 'precondition: a real insert lands')
      t.truthy(h.ds:get('fxCatalogue').n > n, 'precondition: an instantiation does bump n')
    end,
  },
}
