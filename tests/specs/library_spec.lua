-- Pin-tests for library.lua: the shared project/library/factory tier module.
-- Instantiated directly over a harness cm (phase 1 has no production caller).
-- One case per verb: names, get, localize, forkToProject, publish, revert,
-- modified, tidy, delete -- plus the synthetic floor's exemptions.

local t    = require('support')
local util = require('util')

local function mkLib(h)
  return util.instantiate('library', {
    cm = h.cm,
    synthetic = { swings = { identity = true }, tempers = { ['12EDO'] = true } },
  })
end

return {
  {
    name = 'names splits the three tiers and drops the synthetic floor',
    run = function(harness)
      local h = harness.mk{ config = {
        project = { swings = { mine   = { factors = {} } } },
        global  = { swings = { shared = { factors = {} } } },
      } }
      local L = mkLib(h)
      local n = L.names('swings')
      t.deepEq(n.project, { 'mine' },   'project lists only the project entry')
      t.deepEq(n.library, { 'shared' }, 'library lists only the global entry')
      t.deepEq(n.factory, { 'classic-55', 'classic-58', 'classic-62', 'classic-67' },
               'factory is the catalogue with the synthetic identity dropped')
    end,
  },
  {
    name = 'get resolves project over library over factory',
    run = function(harness)
      local h = harness.mk{ config = {
        project = { swings = { ['classic-58'] = { factors = { 'P' } } } },
        global  = { swings = { ['classic-62'] = { factors = { 'G' } } } },
      } }
      local L = mkLib(h)
      t.deepEq(L.get('swings', 'classic-58').factors, { 'P' }, 'project shadows factory')
      t.deepEq(L.get('swings', 'classic-62').factors, { 'G' }, 'library shadows factory')
      t.truthy(L.get('swings', 'classic-67'), 'falls through to the factory catalogue')
      t.eq(L.get('swings', 'nope'), nil, 'unknown name resolves to nil')
    end,
  },
  {
    name = 'localize copies a factory entry to project and is idempotent',
    run = function(harness)
      local h = harness.mk()
      local L = mkLib(h)
      t.eq(next(h.cm:getAt('project', 'swings') or {}), nil, 'project swings starts empty')
      L.localize('swings', 'classic-58')
      t.truthy(h.cm:getAt('project', 'swings')['classic-58'], 'factory entry now lives in project')
      h.cm:set('project', 'swings', { ['classic-58'] = { factors = { 'edited' } } })
      L.localize('swings', 'classic-58')
      t.deepEq(h.cm:getAt('project', 'swings')['classic-58'].factors, { 'edited' },
               'localize no-ops when a project copy already exists')
    end,
  },
  {
    name = 'localize skips synthetic names',
    run = function(harness)
      local h = harness.mk()
      local L = mkLib(h)
      L.localize('swings', 'identity')
      t.eq(next(h.cm:getAt('project', 'swings') or {}), nil, 'synthetic identity is never localized')
    end,
  },
  {
    name = 'forkToProject localizes then returns the project copy',
    run = function(harness)
      local h = harness.mk()
      local L = mkLib(h)
      local copy = L.forkToProject('swings', 'classic-58')
      t.truthy(copy, 'returns the forked copy')
      t.truthy(h.cm:getAt('project', 'swings')['classic-58'], 'and it now lives in project')
    end,
  },
  {
    name = 'publish copies the project entry to the library tier',
    run = function(harness)
      local h = harness.mk{ config = {
        project = { swings = { mine = { factors = { 'X' } } } },
      } }
      local L = mkLib(h)
      L.publish('swings', 'mine')
      t.deepEq(h.cm:getAt('global', 'swings')['mine'].factors, { 'X' }, 'project entry now in library')
    end,
  },
  {
    name = 'publish no-ops without a project copy',
    run = function(harness)
      local h = harness.mk()
      local L = mkLib(h)
      L.publish('swings', 'classic-58')
      t.eq(next(h.cm:getAt('global', 'swings') or {}), nil, 'nothing published when project is empty')
    end,
  },
  {
    name = 'revert overwrites the project copy from its source',
    run = function(harness)
      local h = harness.mk{ config = {
        project = { swings = { ['classic-58'] = { factors = { 'drift' } } } },
      } }
      local L = mkLib(h)
      L.revert('swings', 'classic-58')
      t.deepEq(h.cm:getAt('project', 'swings')['classic-58'], h.cm:defaultFor('swings')['classic-58'],
               'project drift discarded for the factory source')
    end,
  },
  {
    name = 'modified: false pristine, true divergent, false for a source-less entry',
    run = function(harness)
      local h = harness.mk{ config = {
        project = { swings = { mine = { factors = { 'only-here' } } } },
      } }
      local L = mkLib(h)
      L.localize('swings', 'classic-58')  -- pristine copy of the factory source
      t.falsy(L.modified('swings', 'classic-58'), 'a pristine project copy is not modified')
      h.cm:set('project', 'swings', {
        mine           = { factors = { 'only-here' } },
        ['classic-58'] = { factors = { 'changed' } },
      })
      t.truthy(L.modified('swings', 'classic-58'), 'a divergent project copy is modified')
      t.falsy(L.modified('swings', 'mine'), 'a project-only entry has no source, so never modified')
    end,
  },
  {
    name = 'tidy drops pristine unreferenced entries, keeps inUse and divergent ones',
    run = function(harness)
      local h = harness.mk()
      local L = mkLib(h)
      h.cm:set('project', 'swings', {
        ['classic-58'] = h.cm:defaultFor('swings')['classic-58'],   -- pristine
        ['classic-62'] = h.cm:defaultFor('swings')['classic-62'],   -- pristine, inUse
        ['classic-67'] = { factors = { 'divergent' } },             -- divergent
        mine           = { factors = { 'no-source' } },             -- source-less
      })
      local removed = L.tidy('swings', { ['classic-62'] = true })
      t.deepEq(removed, { 'classic-58' }, 'only the pristine, unreferenced entry is removed')
      local p = h.cm:getAt('project', 'swings')
      t.eq(p['classic-58'], nil, 'pristine unreferenced entry gone')
      t.truthy(p['classic-62'], 'inUse entry kept')
      t.truthy(p['classic-67'], 'divergent entry kept')
      t.truthy(p['mine'],       'source-less entry kept')
    end,
  },
  {
    name = 'delete removes from the named tier and refuses synthetic names',
    run = function(harness)
      local h = harness.mk{ config = {
        project = { swings = { mine = { factors = {} }, identity = { factors = { 'x' } } } },
        global  = { swings = { shared = { factors = {} } } },
      } }
      local L = mkLib(h)
      L.delete('swings', 'project', 'mine')
      t.eq(h.cm:getAt('project', 'swings')['mine'], nil, 'project entry removed')
      L.delete('swings', 'global', 'shared')
      t.eq(h.cm:getAt('global', 'swings')['shared'], nil, 'library entry removed')
      L.delete('swings', 'project', 'identity')
      t.truthy(h.cm:getAt('project', 'swings')['identity'], 'synthetic name is never deleted')
    end,
  },
}
