-- Pin-tests for library.lua: the shared project/library tier module. The
-- factory catalogue (cm:defaultFor) is a seed source, not a resolution tier --
-- seedIfEmpty stocks an empty library, reloadPlan/importFactory re-import it.
-- Instantiated directly over a harness cm (no in-module production caller).
-- One case per verb, plus the synthetic floor's exemptions.

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
    name = 'names splits project and library, dropping the synthetic floor',
    run = function(harness)
      local h = harness.mk{ config = {
        project = { swings = { mine   = { factors = {} } } },
        global  = { swings = { shared = { factors = {} }, identity = { factors = {} } } },
      } }
      local L = mkLib(h)
      local n = L.names('swings')
      t.deepEq(n.project, { 'mine' },   'project lists only the project entry')
      t.deepEq(n.library, { 'shared' }, 'library drops the synthetic identity floor')
      t.eq(n.factory, nil, 'no factory tier in the listing')
    end,
  },
  {
    name = 'get resolves project over library',
    run = function(harness)
      local h = harness.mk{ config = {
        project = { swings = { p = { factors = { 'P' } } } },
        global  = { swings = { p = { factors = { 'G' } }, g = { factors = { 'G' } } } },
      } }
      local L = mkLib(h)
      t.deepEq(L.get('swings', 'p').factors, { 'P' }, 'project shadows library')
      t.deepEq(L.get('swings', 'g').factors, { 'G' }, 'library resolves when no project copy')
      t.eq(L.get('swings', 'nope'), nil, 'unknown name resolves to nil (no factory floor)')
    end,
  },
  {
    name = 'localize copies a resolvable entry to project and is idempotent',
    run = function(harness)
      local h = harness.mk()
      local L = mkLib(h)
      t.eq(next(h.cm:getAt('project', 'swings') or {}), nil, 'project swings starts empty')
      L.localize('swings', 'classic-58')   -- resolvable via the factory floor
      t.truthy(h.cm:getAt('project', 'swings')['classic-58'], 'entry now lives in project')
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
    name = 'save authors into project, leaving a same-named library copy standing',
    run = function(harness)
      local h = harness.mk{ config = {
        global = { swings = { shared = { factors = { 'G' } } } },
      } }
      local L = mkLib(h)
      L.save('swings', 'shared', { factors = { 'P' } })
      t.deepEq(h.cm:getAt('project', 'swings')['shared'].factors, { 'P' }, 'the project copy carries the saved value')
      t.deepEq(h.cm:getAt('global',  'swings')['shared'].factors, { 'G' }, 'the library copy it shadows still stands')
      L.save('swings', 'identity', { factors = { 'X' } })
      t.eq(h.cm:getAt('project', 'swings')['identity'], nil, 'a synthetic name never authors')
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
      L.publish('swings', 'anything')
      t.eq(next(h.cm:getAt('global', 'swings') or {}), nil, 'nothing published when project is empty')
    end,
  },
  {
    name = 'publishOverwrites is true only for a divergent library copy',
    run = function(harness)
      local h = harness.mk{ config = {
        project = { swings = {
          fresh = { factors = { 'F' } },   -- project-only, no library copy
          same  = { factors = { 'S' } },   -- identical library copy
          drift = { factors = { 'B' } },   -- divergent library copy
        } },
        global = { swings = {
          same  = { factors = { 'S' } },
          drift = { factors = { 'A' } },
        } },
      } }
      local L = mkLib(h)
      t.falsy(L.publishOverwrites('swings', 'fresh'), 'no library copy: nothing to overwrite')
      t.falsy(L.publishOverwrites('swings', 'same'),  'identical library copy: no overwrite')
      t.truthy(L.publishOverwrites('swings', 'drift'), 'divergent library copy: overwrite')
    end,
  },
  {
    name = 'revert overwrites the project copy from its library source',
    run = function(harness)
      local h = harness.mk{ config = {
        project = { swings = { shared = { factors = { 'drift' } } } },
        global  = { swings = { shared = { factors = { 'from-library' } } } },
      } }
      local L = mkLib(h)
      L.revert('swings', 'shared')
      t.deepEq(h.cm:getAt('project', 'swings')['shared'].factors, { 'from-library' },
               'project drift discarded for the library source')
    end,
  },
  {
    name = 'revert no-ops without a library source',
    run = function(harness)
      local h = harness.mk{ config = {
        project = { swings = { mine = { factors = { 'only-here' } } } },
      } }
      local L = mkLib(h)
      L.revert('swings', 'mine')
      t.deepEq(h.cm:getAt('project', 'swings')['mine'].factors, { 'only-here' },
               'a source-less project entry is left untouched')
    end,
  },
  {
    name = 'modified: false pristine, true divergent, false for a source-less entry',
    run = function(harness)
      local h = harness.mk{ config = {
        project = { swings = {
          mine   = { factors = { 'only-here' } },
          shared = { factors = { 'A' } },   -- pristine copy of the library source
        } },
        global = { swings = { shared = { factors = { 'A' } } } },
      } }
      local L = mkLib(h)
      t.falsy(L.modified('swings', 'shared'), 'a pristine project copy is not modified')
      h.cm:set('project', 'swings', {
        mine   = { factors = { 'only-here' } },
        shared = { factors = { 'changed' } },
      })
      t.truthy(L.modified('swings', 'shared'), 'a divergent project copy is modified')
      t.falsy(L.modified('swings', 'mine'), 'a project-only entry has no source, so never modified')
    end,
  },
  {
    name = 'tidy drops pristine unreferenced entries, keeps inUse and divergent ones',
    run = function(harness)
      local h = harness.mk{ config = {
        global = { swings = {
          a = { factors = { 'a' } },
          b = { factors = { 'b' } },
          c = { factors = { 'c' } },
        } },
      } }
      local L = mkLib(h)
      h.cm:set('project', 'swings', {
        a    = { factors = { 'a' } },          -- pristine, unreferenced
        b    = { factors = { 'b' } },          -- pristine, inUse
        c    = { factors = { 'DRIFT' } },      -- divergent
        mine = { factors = { 'no-source' } },  -- source-less
      })
      local removed = L.tidy('swings', { b = true })
      t.deepEq(removed, { 'a' }, 'only the pristine, unreferenced entry is removed')
      local p = h.cm:getAt('project', 'swings')
      t.eq(p['a'], nil, 'pristine unreferenced entry gone')
      t.truthy(p['b'],    'inUse entry kept')
      t.truthy(p['c'],    'divergent entry kept')
      t.truthy(p['mine'], 'source-less entry kept')
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
  {
    name = 'seedIfEmpty stocks an empty library from the factory catalogue, once',
    run = function(harness)
      local h = harness.mk()
      local L = mkLib(h)
      t.eq(next(h.cm:getAt('global', 'swings') or {}), nil, 'library starts empty')
      L.seedIfEmpty('swings')
      local g = h.cm:getAt('global', 'swings')
      t.truthy(g['classic-58'], 'factory catalogue seeded into the library')
      t.eq(g['identity'], nil, 'synthetic floor is not seeded')
      h.cm:set('global', 'swings', { only = { factors = { 'k' } } })
      L.seedIfEmpty('swings')
      local g2 = h.cm:getAt('global', 'swings')
      t.eq(g2['classic-58'], nil, 'no re-seed once the library holds anything')
      t.truthy(g2['only'], 'existing library entry untouched')
    end,
  },
  {
    name = 'reloadPlan splits absent factory names from divergent library copies',
    run = function(harness)
      local h   = harness.mk()
      local L   = mkLib(h)
      local fac = h.cm:defaultFor('swings')
      h.cm:set('global', 'swings', {
        ['classic-58'] = fac['classic-58'],          -- identical -> neither
        ['classic-62'] = { factors = { 'DRIFT' } },  -- divergent -> overwrite
        -- classic-55, classic-67 absent -> add
      })
      local plan = L.reloadPlan('swings')
      t.deepEq(plan.add, { 'classic-55', 'classic-67' }, 'absent factory names are additions')
      t.deepEq(plan.overwrite, { 'classic-62' }, 'divergent library copies are overwrites')
    end,
  },
  {
    name = 'importFactory copies one entry into the library, refusing synthetic',
    run = function(harness)
      local h = harness.mk()
      local L = mkLib(h)
      L.importFactory('swings', 'classic-58')
      t.deepEq(h.cm:getAt('global', 'swings')['classic-58'], h.cm:defaultFor('swings')['classic-58'],
               'factory entry imported into the library')
      L.importFactory('swings', 'identity')
      t.eq(h.cm:getAt('global', 'swings')['identity'], nil, 'synthetic name is never imported')
    end,
  },
}
