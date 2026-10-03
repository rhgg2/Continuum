-- wm:branchFx is the branch-context pick of the fx picker (docs/wiringPage.md § The fx
-- picker): a fresh forward draft released on empty canvas adds the plugin at the release
-- point, wired from the draft's port into its first in of the draft's type, as one undo
-- step. A plugin that can't take the wire is removed again, so the graph stands as it
-- was; only an unprobed plugin can get that far, and its probe stays in the catalogue.
local t    = require('support')
local util = require('util')

-- VST3, so the format mark gives each a MIDI in and out (wm_fx_traits_spec).
local COMP  = { name = 'VST3: Comp (Acme)',  ident = '/Library/Audio/Plug-Ins/VST3/Comp.vst3',
                key = 'Comp.vst3',  io = { ins = 2, outs = 2 } }
local SYNTH = { name = 'VST3i: Synth (Acme)', ident = '/Library/Audio/Plug-Ins/VST3/Synth.vst3',
                key = 'Synth.vst3', io = { ins = 0, outs = 2 } }

-- The branch context's need for an audio draft.
local AUDIO_IN_NEED = { audio = { ins = 1 } }

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

-- s --audio--> f --audio--> master: s a source seeded directly (no REAPER track, audio and
-- MIDI out), f an fx with one audio in, two audio outs and a MIDI out.
local function seed(wm)
  wm:mutate(function(g)
    g.nodes.s = { kind = 'source', trackId = 's', pos = { x = 0, y = 0 },
                  ports = { audio = { ins = 0, outs = 1 }, midi = { ins = 0, outs = 1 } } }
    g.nodes.f = fxNode('f', 1, 2, 0, 1)
    util.add(g.edges, { type = 'audio', from = 's', to = 'f' })
    util.add(g.edges, { type = 'audio', from = 'f', to = 'master' })
  end)
  t.truthy(edgeIndex(wm, 's', 'f', 'audio') and edgeIndex(wm, 'f', 'master', 'audio'),
           'precondition: s -> f -> master is seeded')
end

-- Every edge into `id`.
local function edgesInto(wm, id)
  return util.filter(wm:graph().edges, function(e) return e.to == id end)
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
    name = 'audio branch: the node lands at pos, fed from the draft\'s pair into its first in',
    run = function(harness)
      local _, wm = mkWm(harness)
      seed(wm)
      local before = #wm:graph().edges
      local id = wm:branchFx({ id = 'f', port = 2, type = 'audio' }, pick(COMP), { x = 30, y = 40 })
      t.truthy(id, 'branch lands')
      local g = wm:graph()
      t.deepEq(g.nodes[id].pos, { x = 30, y = 40 })
      t.deepEq(edgesInto(wm, id),
               { { type = 'audio', from = 'f', fromPort = 2, to = id, toPort = 1 } },
               'one bare wire from the draft\'s pair into the first in')
      t.eq(edgeIndex(wm, id, 'master', 'audio'), nil, 'an effect gets no wire to master')
      t.eq(#g.edges, before + 1, 'nothing else is added')
    end,
  },
  {
    name = 'MIDI branch of an instrument from a source: a bare wire, no source spawned, its audio to master',
    run = function(harness)
      local _, wm = mkWm(harness)
      seed(wm)
      local nodes = count(wm:graph().nodes)
      local id = wm:branchFx({ id = 's', type = 'midi' }, pick(SYNTH), { x = 30, y = 40 })
      t.truthy(id, 'branch lands')
      t.deepEq(edgesInto(wm, id), { { type = 'midi', from = 's', to = id } }, 'one bare MIDI wire')
      t.eq(count(wm:graph().nodes), nodes + 1, 'no source node is spawned')
      t.truthy(edgeIndex(wm, id, 'master', 'audio'), 'the instrument keeps its wire to master')
    end,
  },
  {
    name = 'MIDI branch from an fx\'s MIDI out: a bare wire',
    run = function(harness)
      local _, wm = mkWm(harness)
      seed(wm)
      local id = wm:branchFx({ id = 'f', type = 'midi' }, pick(COMP), { x = 30, y = 40 })
      t.truthy(id, 'branch lands')
      t.deepEq(edgesInto(wm, id), { { type = 'midi', from = 'f', to = id } })
    end,
  },
  {
    name = 'a plugin that can\'t take the wire leaves the graph as it was, and the probe stays',
    run = function(harness)
      local _, wm = mkWm(harness)
      seed(wm)
      t.truthy(holdsKey(wm:fxPickerSource(AUDIO_IN_NEED).rows, SYNTH.key),
               'precondition: unprobed, the synth is offered for an audio branch')
      local graph = wm:graph()
      local id, err = wm:branchFx({ id = 'f', port = 1, type = 'audio' }, pick(SYNTH),
                                  { x = 30, y = 40 })
      t.eq(id, nil)
      t.eq(err and err.code, 'no_in_port', 'DAG.validate refuses the wire')
      t.deepEq(wm:graph(), graph, 'the graph stands as before')
      t.falsy(holdsKey(wm:fxPickerSource(AUDIO_IN_NEED).rows, SYNTH.key),
              'its recorded ports now keep it out of the audio branch')
    end,
  },
  {
    name = 'a branch is one undo step under the branch label, landed or rolled back',
    run = function(harness)
      local h, wm = mkWm(harness)
      seed(wm)
      local labels = collectLabels(h)
      t.truthy(wm:branchFx({ id = 'f', port = 1, type = 'audio' }, pick(COMP), { x = 30, y = 40 }),
               'precondition: branch lands')
      t.deepEq(labels, { 'wiring: branch Comp' })

      local h2, wm2 = mkWm(harness)
      seed(wm2)
      local labels2 = collectLabels(h2)
      t.eq(wm2:branchFx({ id = 'f', port = 1, type = 'audio' }, pick(SYNTH), { x = 30, y = 40 }),
           nil, 'precondition: refused')
      t.eq(#labels2, 1, 'the rollback shares the one block')
    end,
  },
  {
    name = 'no such node: refused before anything is instantiated',
    run = function(harness)
      local h, wm = mkWm(harness)
      seed(wm)
      local n = h.ds:get('fxCatalogue').n
      local id, err = wm:branchFx({ id = 'nope', type = 'midi' }, pick(COMP), { x = 30, y = 40 })
      t.eq(id, nil)
      t.eq(err and err.code, 'no_node')
      t.eq(err and err.id, 'nope')
      t.eq(h.ds:get('fxCatalogue').n, n, 'no use recorded, so nothing instantiated')
      t.truthy(wm:branchFx({ id = 'f', type = 'midi' }, pick(COMP), { x = 30, y = 40 }),
               'precondition: a real branch lands')
      t.truthy(h.ds:get('fxCatalogue').n > n, 'precondition: an instantiation does bump n')
    end,
  },
}
