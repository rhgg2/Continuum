-- 3c.3a.0: ext_midi_bus JSFX refusal.
-- Pure parser tests + the wm:addFxNode boundary that gates them.
local t    = require('support')
local util = require('util')

local function mkWm(harness)
  local h  = harness.mk()
  local wm = util.instantiate('wiringManager', { cm = h.cm })
  wm:load()
  return h, wm
 end

-- Test override of wm:readJsfxContent: maps ident → desc string. Production
-- reads from REAPER's Effects dir; tests bypass io.
local function seedJsfx(wm, byIdent)
  wm.readJsfxContent = function(_, ident) return byIdent[ident] end
end

local function parser()
  return util.instantiate('wiringManager', { cm = require('harness').mk().cm })
           .parseJsfxBusAware
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
      local h, wm = mkWm(harness)
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
      local h, wm = mkWm(harness)
      seedJsfx(wm, { ['JS:Plain'] = 'desc:Plain\n@sample\nspl0 *= 1;\n' })
      reaper:setFxIO('JS:Plain', { ins = 2, outs = 2 })
      local id = wm:addFxNode(0, 0, { name = 'Plain', ident = 'JS:Plain' })
      t.truthy(id, 'node id returned')
      t.eq(wm:graph().nodes[id].busAware, false, 'busAware stamped false')
    end,
  },
  {
    name = 'addFxNode does not probe non-JSFX idents (no readJsfxContent call)',
    run = function(harness)
      local h, wm = mkWm(harness)
      local probed = false
      wm.readJsfxContent = function() probed = true; return nil end
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
      local h, wm = mkWm(harness)
      wm.readJsfxContent = function() return nil end
      reaper:setFxIO('JS:NoFile', { ins = 2, outs = 2 })
      local id, err = wm:addFxNode(0, 0, { name = 'NoFile', ident = 'JS:NoFile' })
      t.truthy(id, 'missing desc treated as non-bus-aware (accept)')
      t.eq(err, nil)
    end,
  },
}
