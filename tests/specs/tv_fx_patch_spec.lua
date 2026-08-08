-- Pin-tests for the fx patch catalogue: `tv:saveFxPatch` stamps the caret host's
-- chain into the tier it was handed -- verbatim, by copy, and without costing a
-- re-derivation; `tv:loadFxPatch` copies a named chain back out onto a host,
-- replacing what it held. Both name their tier rather than resolving one, a patch
-- being held by copy. see docs/trackerRender.md § FX chain

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
local function libraryPatches(h) return h.cm:getAt('global',  'fxPatches') or {} end

-- One stage, and a different one: loading this over `chain` is what makes
-- replace-not-append bite in both directions (fewer stages, other params).
local patch = { { kind = 'arp', period = { 1, 4 }, dir = 'down' } }

-- A region carrying `chain`, with the catalogue's two tiers seeded around it.
local function withCatalogue(harness, project, library)
  local h = harness.mk{ config = { project = { fxPatches = project },
                                   global  = { fxPatches = library } } }
  injectRegion(h, chain)
  return h
end

return {
  {
    name = 'save stamps the host chain into the tier it was given, verbatim',
    run = function(harness)
      local h = harness.mk()
      injectRegion(h, chain)
      h.vm:saveFxPatch('fxr-1', 'project', 'wobble')
      t.deepEq(projectPatches(h).wobble, chain, 'the stored patch is the fx list as it stood')
      t.eq(next(libraryPatches(h)), nil, 'and lands in that tier alone')
    end,
  },

  {
    name = 'save into the library tier writes the library tier, no project copy in the way',
    run = function(harness)
      local h = harness.mk()
      injectRegion(h, chain)
      h.vm:saveFxPatch('fxr-1', 'global', 'wobble')
      t.deepEq(libraryPatches(h).wobble, chain, 'the library carries the chain the host held')
      t.eq(next(projectPatches(h)), nil, 'without minting a project copy on the way through')
    end,
  },

  {
    name = 'the catalogue holds a copy, not a live handle on the chain',
    run = function(harness)
      local h = harness.mk()
      injectRegion(h, chain)
      h.vm:saveFxPatch('fxr-1', 'project', 'wobble')
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
      h.vm:saveFxPatch('fxr-1', 'project', 'wobble')
      t.eq(rebuilds, 0, 'the catalogue is no derivation input, so its write costs no rebuild')
    end,
  },

  {
    name = 'a host with no chain saves nothing',
    run = function(harness)
      local h = harness.mk()
      injectRegion(h, chain)
      h.vm:saveFxPatch('nope', 'project', 'ghost')
      t.eq(next(projectPatches(h)), nil, 'an unknown uuid authors no name')
    end,
  },

  ----- load: a named chain back out of the catalogue and onto a host

  {
    name = 'the load replaces the host chain rather than appending to it',
    run = function(harness)
      local h = withCatalogue(harness, { wobble = patch })
      h.vm:loadFxPatch('fxr-1', 'project', 'wobble')
      t.deepEq(h.vm:noteFx('fxr-1'), patch, 'a patch *is* the chain -- the two stages it replaced are gone')
    end,
  },

  {
    name = 'the host holds a copy, not a live handle on the catalogue',
    run = function(harness)
      local h = withCatalogue(harness, { wobble = patch })
      h.vm:loadFxPatch('fxr-1', 'project', 'wobble')
      h.vm:setFxField('fxr-1', 1, 'dir', 'up')
      t.eq(projectPatches(h).wobble[1].dir, 'down', 'editing the host afterwards leaves the stored patch standing')
    end,
  },

  {
    name = 'bypass rides the patch onto the host',
    run = function(harness)
      local h = withCatalogue(harness, { wobble = chain })
      injectRegion(h, patch)   -- the host stands bypass-free, so the flag can only arrive with the patch
      h.vm:loadFxPatch('fxr-1', 'project', 'wobble')
      t.eq(h.vm:noteFx('fxr-1')[2].bypass, true, 'a stage stored inert arrives inert')
    end,
  },

  {
    name = 'each tier\'s copy of a name loads on its own, neither shadowing the other',
    run = function(harness)
      local h = withCatalogue(harness, { wobble = patch }, { wobble = chain })
      h.vm:loadFxPatch('fxr-1', 'global', 'wobble')
      t.deepEq(h.vm:noteFx('fxr-1'), chain, 'the library body loads though a project copy holds the name')
      h.vm:loadFxPatch('fxr-1', 'project', 'wobble')
      t.deepEq(h.vm:noteFx('fxr-1'), patch, 'and the project body loads when that is the row picked')
    end,
  },

  {
    name = 'a name the named tier does not hold loads nothing',
    run = function(harness)
      local h = withCatalogue(harness, { wobble = patch }, { shelved = patch })
      h.vm:loadFxPatch('fxr-1', 'project', 'ghost')
      t.deepEq(h.vm:noteFx('fxr-1'), chain, "the host's chain stands untouched")
      h.vm:loadFxPatch('fxr-1', 'project', 'shelved')
      t.deepEq(h.vm:noteFx('fxr-1'), chain, 'and a name the *other* tier holds is no more resolvable')
    end,
  },

  ----- delete: the picker rows' own gesture over the tiered catalogue

  {
    name = 'deleting a project row leaves the library copy that shared the name standing',
    run = function(harness)
      local h = withCatalogue(harness, { wobble = chain }, { wobble = patch })
      h.vm:deleteFxPatch('project', 'wobble')
      t.eq(projectPatches(h).wobble, nil, 'the project copy is gone')
      t.deepEq(libraryPatches(h).wobble, patch, 'and the library copy is where it was')
    end,
  },

  {
    name = 'deleting a library row takes that copy and no other',
    run = function(harness)
      local h = withCatalogue(harness, { shelved = chain }, { shelved = patch })
      h.vm:deleteFxPatch('global', 'shelved')
      t.eq(libraryPatches(h).shelved, nil, 'the library copy is gone')
      t.deepEq(projectPatches(h).shelved, chain, 'the project copy of the same name stands')
    end,
  },

  {
    name = 'the catalogue verbs re-realise nothing',
    run = function(harness)
      local h = withCatalogue(harness, { wobble = patch }, { shelved = patch })
      local rebuilds = 0
      h.tm:subscribe('rebuild', function() rebuilds = rebuilds + 1 end)
      h.vm:saveFxPatch('fxr-1', 'global', 'wobble')
      h.vm:deleteFxPatch('project', 'wobble')
      h.vm:deleteFxPatch('global', 'shelved')
      t.eq(rebuilds, 0, 'the catalogue is no derivation input, so its writes cost no rebuild')
    end,
  },

  {
    name = 'the whole list lands in one write',
    run = function(harness)
      local h = withCatalogue(harness, { wobble = chain })
      injectRegion(h, patch)   -- one stage standing, two arriving: a per-stage load would rebuild twice
      local rebuilds = 0
      h.tm:subscribe('rebuild', function() rebuilds = rebuilds + 1 end)
      h.vm:loadFxPatch('fxr-1', 'project', 'wobble')
      t.eq(rebuilds, 1, 'one whole-list write, not a stage at a time')
    end,
  },
}
