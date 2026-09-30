-- ext_midi_bus JSFX refusal at the wm:addFxNode boundary, and the midi ports a
-- JSFX node takes from its parsed traits. The parse itself is pinned in
-- fxCatalogue_spec; JSFX sources reach it through the fake's Effects store.
local t    = require('support')
local util = require('util')

local function mkWm(harness)
  local h  = harness.mk()
  local rm = util.instantiate('routingManager', { ds = h.ds })
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
  wm:load()
  return h, wm
end

-- Seed JSFX sources by their Effects-relative path (the ident after 'JS:').
local function seedJsfx(h, byPath)
  for path, content in pairs(byPath) do h.reaper:setJsfx(path, content) end
end

-- The JSFX sources read from here on, as lookups of unseeded paths in the fake's Effects store.
local function watchJsfxReads(h)
  local reads = {}
  setmetatable(h.reaper._state.jsfx, { __index = function(_, path) util.add(reads, path) end })
  return reads
end

return {
  {
    name = 'addFxNode refuses an ext_midi_bus JSFX, no REAPER state touched',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedJsfx(h, { ['Foreign Bus'] = 'desc:Foreign\next_midi_bus = 1\n' })
      reaper:setFxIO('JS:Foreign Bus', { ins = 2, outs = 2 })
      local scratchCountBefore = reaper.TrackFX_GetCount(reaper.GetTrack(0, 0))
      local id, err = wm:addFxNode(0, 0, { name = 'Foreign', ident = 'JS:Foreign Bus' })
      t.eq(id, nil, 'no node id returned')
      t.eq(err.code,  'ext_midi_bus_user_fx')
      t.eq(err.ident, 'JS:Foreign Bus')
      t.eq(reaper.TrackFX_GetCount(reaper.GetTrack(0, 0)), scratchCountBefore,
           'scratch chain untouched (refused before instantiate)')
      t.eq(next(wm:graph().nodes, 'master'), nil, 'no fx node added to the user graph')
    end,
  },
  {
    name = 'addFxNode accepts a normal JSFX and stamps busAware=false',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedJsfx(h, { Plain = 'desc:Plain\n@sample\nspl0 *= 1;\n' })
      reaper:setFxIO('JS:Plain', { ins = 2, outs = 2 })
      local id = wm:addFxNode(0, 0, { name = 'Plain', ident = 'JS:Plain' })
      t.truthy(id, 'node id returned')
      t.eq(wm:graph().nodes[id].busAware, false, 'busAware stamped false')
    end,
  },
  {
    name = 'addFxNode opens no JSFX source for a VST ident',
    run = function(harness)
      local h, wm = mkWm(harness)
      reaper:setFxIO('JS:Probe',  { ins = 2, outs = 2 })
      reaper:setFxIO('VST3:Comp', { ins = 2, outs = 2 })
      local reads = watchJsfxReads(h)
      wm:addFxNode(0, 0, { name = 'Probe', ident = 'JS:Probe' })
      local jsReads = #reads
      t.truthy(jsReads > 0, 'precondition: the watch sees a JSFX\'s source read')
      local id = wm:addFxNode(0, 200, { name = 'Comp', ident = 'VST3:Comp' })
      t.truthy(id)
      t.eq(#reads, jsReads, 'no Effects/ read for the VST')
      t.eq(wm:graph().nodes[id].busAware, false)
    end,
  },
  {
    name = 'addFxNode accepts JSFX whose desc file is missing',
    run = function(harness)
      local _, wm = mkWm(harness)
      reaper:setFxIO('JS:NoFile', { ins = 2, outs = 2 })
      local id, err = wm:addFxNode(0, 0, { name = 'NoFile', ident = 'JS:NoFile' })
      t.truthy(id, 'missing desc treated as non-bus-aware (accept)')
      t.eq(err, nil)
    end,
  },
  {
    name = 'addFxNode stamps ports.midi from the scan',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedJsfx(h, {
        AudioOnly = 'desc:g\n@sample\nspl0 *= 1;\n',
        MidiFx    = 'desc:m\n@block\nwhile (midirecv(o,a,b)) ( midisend(o,a,b); );\n',
      })
      reaper:setFxIO('JS:AudioOnly', { ins = 2, outs = 2 })
      reaper:setFxIO('JS:MidiFx',    { ins = 2, outs = 2 })
      local a = wm:addFxNode(0, 0,   { name = 'A', ident = 'JS:AudioOnly' })
      local m = wm:addFxNode(0, 200, { name = 'M', ident = 'JS:MidiFx' })
      t.deepEq(wm:graph().nodes[a].ports.midi, { ins = 0, outs = 0 })
      t.deepEq(wm:graph().nodes[m].ports.midi, { ins = 1, outs = 1 })
    end,
  },
  {
    name = 'addFxNode: audio-only generator wires to master, no auto source',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedJsfx(h, { Noise = 'desc:n\n@sample\nspl0 = rand(1);\n' })
      reaper:setFxIO('JS:Noise', { ins = 0, outs = 2 })
      local id = wm:addFxNode(0, 0, { name = 'Noise', ident = 'JS:Noise' })
      t.truthy(id)
      local g = wm:graph()
      t.deepEq(g.edges, { { type = 'audio', from = id, fromPort = 1, to = 'master', toPort = 1 } },
               'deaf generator wires straight to master, no source/midi edge')
      for _, n in pairs(g.nodes) do
        t.truthy(n.kind ~= 'source', 'no auto source node for a deaf generator')
      end
    end,
  },
  {
    name = 'addFxNode: synth generator spawns source, wires midi-in + master-out',
    run = function(harness)
      local h, wm = mkWm(harness)
      seedJsfx(h, { Synth = 'desc:s\n@block\nmidirecv(o,a,b);\n' })
      reaper:setFxIO('JS:Synth', { ins = 0, outs = 2 })
      local id, sourceGuid = wm:addFxNode(0, 0, { name = 'Synth', ident = 'JS:Synth' })
      t.truthy(id,         'returns the fx-node id')
      t.truthy(sourceGuid, 'returns the spawned source guid')
      local g = wm:graph()
      t.eq(g.nodes[sourceGuid].kind, 'source', 'source node spawned')
      local hasMidi, hasMaster = false, false
      for _, e in ipairs(g.edges) do
        if e.type == 'midi'  and e.from == sourceGuid and e.to == id      then hasMidi   = true end
        if e.type == 'audio' and e.from == id        and e.to == 'master' then hasMaster = true end
      end
      t.truthy(hasMidi,   'source feeds the synth midi')
      t.truthy(hasMaster, 'synth wires straight to master')
    end,
  },
}
