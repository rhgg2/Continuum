-- 3c.3a.0: ext_midi_bus JSFX refusal.
-- Pure parser tests + the wm:addFxNode boundary that gates them.
local t    = require('support')
local util = require('util')

local function mkWm(harness)
  local h  = harness.mk()
  local rm = util.instantiate('routingManager', { ds = h.ds })
  local wm = util.instantiate('wiringManager', { cm = h.cm, rm = rm })
  wm:load()
  return h, wm
 end

-- Test override of wm:readJSFXContent: maps ident → desc string. Production
-- reads from REAPER's Effects dir; tests bypass io.
local function seedJsfx(wm, byIdent)
  wm.readJSFXContent = function(_, ident) return byIdent[ident] end
end

local function parser()
  return util.instantiate('wiringManager', { cm = require('harness').mk().cm })
           .parseJSFXBusAware
end

local function traitsParser()
  return util.instantiate('wiringManager', { cm = require('harness').mk().cm })
           .parseJSFXMidiTraits
end

return {
  -- ---- Parser unit tests
  {
    name = 'parser: ext_midi_bus = 1 matches',
    run = function()
      t.eq(parser()('ext_midi_bus = 1\n'), true)
    end,
  },
  {
    name = 'parser: ext_midi_bus=1 (no spaces) matches',
    run = function()
      t.eq(parser()('ext_midi_bus=1\n'), true)
    end,
  },
  {
    name = 'parser: ext_midi_bus = 1; (trailing semicolon) matches',
    run = function()
      t.eq(parser()('ext_midi_bus = 1;\n'), true)
    end,
  },
  {
    name = 'parser: //ext_midi_bus = 1 (commented) does not match',
    run = function()
      t.eq(parser()('//ext_midi_bus = 1\n'),   false)
      t.eq(parser()('// ext_midi_bus = 1\n'),  false)
      t.eq(parser()('  // ext_midi_bus=1\n'),  false)
    end,
  },
  {
    name = 'parser: ext_midi_bus = 0 does not match',
    run = function()
      t.eq(parser()('ext_midi_bus = 0\n'), false)
    end,
  },
  {
    name = 'parser: ext_midi_bus = 10 does not match (frontier on the digit)',
    run = function()
      t.eq(parser()('ext_midi_bus = 10\n'), false)
    end,
  },
  {
    name = 'parser: empty + nil content do not match',
    run = function()
      t.eq(parser()(''),  false)
      t.eq(parser()(nil), false)
    end,
  },
  {
    name = 'parser: finds declaration buried in a multi-line desc',
    run = function()
      local content = [[
desc:Thing
in_pin:left
out_pin:left
ext_midi_bus = 1
@sample
spl0 *= 1;
]]
      t.eq(parser()(content), true)
    end,
  },
  {
    name = 'parser: file with no ext_midi_bus declaration does not match',
    run = function()
      local content = [[
desc:Plain
in_pin:left
out_pin:left
@sample
spl0 *= 1;
]]
      t.eq(parser()(content), false)
    end,
  },

  -- ---- wm:addFxNode boundary
  {
    name = 'addFxNode refuses an ext_midi_bus JSFX, no REAPER state touched',
    run = function(harness)
      local _, wm = mkWm(harness)
      seedJsfx(wm, { ['JS:Foreign Bus'] = 'desc:Foreign\next_midi_bus = 1\n' })
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
      local _, wm = mkWm(harness)
      seedJsfx(wm, { ['JS:Plain'] = 'desc:Plain\n@sample\nspl0 *= 1;\n' })
      reaper:setFxIO('JS:Plain', { ins = 2, outs = 2 })
      local id = wm:addFxNode(0, 0, { name = 'Plain', ident = 'JS:Plain' })
      t.truthy(id, 'node id returned')
      t.eq(wm:graph().nodes[id].busAware, false, 'busAware stamped false')
    end,
  },
  {
    name = 'addFxNode does not probe non-JSFX idents (no readJSFXContent call)',
    run = function(harness)
      local _, wm = mkWm(harness)
      local probed = false
      wm.readJSFXContent = function() probed = true; return nil end
      reaper:setFxIO('VST3:Comp', { ins = 2, outs = 2 })
      local id = wm:addFxNode(0, 0, { name = 'Comp', ident = 'VST3:Comp' })
      t.truthy(id)
      t.eq(probed, false, 'VST ident bypassed the JSFX probe')
      t.eq(wm:graph().nodes[id].busAware, false)
    end,
  },
  {
    name = 'addFxNode accepts JSFX whose desc file is missing (read returns nil)',
    run = function(harness)
      local _, wm = mkWm(harness)
      wm.readJSFXContent = function() return nil end
      reaper:setFxIO('JS:NoFile', { ins = 2, outs = 2 })
      local id, err = wm:addFxNode(0, 0, { name = 'NoFile', ident = 'JS:NoFile' })
      t.truthy(id, 'missing desc treated as non-bus-aware (accept)')
      t.eq(err, nil)
    end,
  },

  -- ---- midi traits scan (midirecv/midisend → ports.midi)
  {
    name = 'traits: midirecv/midisend detection, comments stripped, nil assumes both',
    run = function()
      local p = traitsParser()
      t.deepEq(p('desc:x\n@sample\nspl0 *= 1;\n'),
               { busAware=false, recv=false, send=false })
      t.deepEq(p('desc:x\n@block\nwhile (midirecv(o,a,b)) ( midisend(o,a,b); );\n'),
               { busAware=false, recv=true, send=true })
      t.deepEq(p('desc:x\n@block\n// midirecv(o,a,b)\nx = 1; // midisend too\n'),
               { busAware=false, recv=false, send=false })
      t.deepEq(p('desc:x\n@block\nmidisyx(o, ptr, len);\n'),
               { busAware=false, recv=false, send=true })
      t.deepEq(p('ext_midi_bus = 1\n@block\nmidirecv(o,a,b);\n'),
               { busAware=true, recv=true, send=false })
      t.deepEq(p(nil), { busAware=false, recv=true, send=true })
    end,
  },
  {
    name = 'addFxNode stamps ports.midi from the scan',
    run = function(harness)
      local _, wm = mkWm(harness)
      seedJsfx(wm, {
        ['JS:AudioOnly'] = 'desc:g\n@sample\nspl0 *= 1;\n',
        ['JS:MidiFx']    = 'desc:m\n@block\nwhile (midirecv(o,a,b)) ( midisend(o,a,b); );\n',
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
      local _, wm = mkWm(harness)
      seedJsfx(wm, { ['JS:Noise'] = 'desc:n\n@sample\nspl0 = rand(1);\n' })
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
      local _, wm = mkWm(harness)
      seedJsfx(wm, { ['JS:Synth'] = 'desc:s\n@block\nmidirecv(o,a,b);\n' })
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
