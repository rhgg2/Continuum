-- Pin-tests for the fx patch catalogue: `tv:saveFxPatch` stamps the caret host's
-- chain into the project tier of `fxPatches` -- verbatim, by copy, and without
-- costing a re-derivation. see design/note-macros-v2.md § The chain surface

local t = require('support')

-- Stage 2 carries bypass: a flag no realisation reads back out, so it is what
-- makes "the stored value is the bare fx list, verbatim" bite.
local chain = { { kind = 'arp',  period = { 1, 4 }, dir = 'up' },
                { kind = 'sine', period = { 1, 4 }, depth = 30, onset = 0, bypass = true } }

local function injectRegion(h, fx)
  h.ds:assign('fxRegions', { { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240, fx = fx } })
  h.tm:rebuild()
end

local function projectPatches(h) return h.cm:getAt('project', 'fxPatches') or {} end

return {
  {
    name = 'save stamps the host chain into the project tier, verbatim',
    run = function(harness)
      local h = harness.mk()
      injectRegion(h, chain)
      h.vm:saveFxPatch('fxr-1', 'wobble')
      t.deepEq(projectPatches(h).wobble, chain, 'the stored patch is the fx list as it stood')
    end,
  },

  {
    name = 'the catalogue holds a copy, not a live handle on the chain',
    run = function(harness)
      local h = harness.mk()
      injectRegion(h, chain)
      h.vm:saveFxPatch('fxr-1', 'wobble')
      h.vm:setFxField('fxr-1', 1, 'dir', 'down')
      t.eq(projectPatches(h).wobble[1].dir, 'up', 'editing the host afterwards leaves the patch alone')
    end,
  },

  {
    name = 'saving re-realises nothing',
    run = function(harness)
      local h = harness.mk()
      injectRegion(h, chain)
      local rebuilds = 0
      h.tm:subscribe('rebuild', function() rebuilds = rebuilds + 1 end)
      h.vm:saveFxPatch('fxr-1', 'wobble')
      t.eq(rebuilds, 0, 'the catalogue is no derivation input, so its write costs no rebuild')
    end,
  },

  {
    name = 'a host with no chain saves nothing',
    run = function(harness)
      local h = harness.mk()
      injectRegion(h, chain)
      h.vm:saveFxPatch('nope', 'ghost')
      t.eq(next(projectPatches(h)), nil, 'an unknown uuid authors no name')
    end,
  },
}
