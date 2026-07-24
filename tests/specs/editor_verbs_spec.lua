-- Verb descriptors on the swing/temper editors under the library model:
-- `publish` lifts a project copy into the shared library, `revert` discards
-- project drift back to its source, `tidy` (swing only) drops pristine
-- unreferenced project copies, and `reloadFactory` re-imports the shipped
-- catalogue (silent adds, a confirm per divergent copy), and `importFactory`
-- re-imports one entry (silent when non-divergent, a confirm when it diverges).
-- Instantiated over a harness cm/ds with a lib
-- service; imgui stubbed via package.preload. Recipe lifted from
-- temperEditor_tree_spec.
local t = require('support')

local fakeImGui = setmetatable({ Mod_None = 0 }, {
  __index = function(tbl, k) local n = rawget(tbl, '##n') or 0; n = n + 1
    rawset(tbl, '##n', n); rawset(tbl, k, n); return n end,
})
package.preload['imgui'] = function()
  return function(_) return fakeImGui end
end

local util = require('util')

local function mkLib(h)
  return util.instantiate('library', {
    cm = h.cm,
    synthetic = { swings = { identity = true }, tempers = { ['12EDO'] = true } },
  })
end

-- Swing reaches the arrange/tracker services only for the reference scan and
-- default-slot resolution; a leaf on each covers the descriptor path.
local function facadeStub()
  return { get = function(name)
    if name == 'arrange' then
      return { takesUsing = function() return {} end, reswingAll = function() end }
    end
    if name == 'tracker' then
      return { cursorAnchor = function() return nil end, setSwingComposite = function() end }
    end
  end }
end

-- modalHost stub: no-op registerKind, plus capture the last openConfirm args so
-- the confirm-gated publish path is observable.
local function mkModalHost(captured)
  return {
    registerKind = function() end,
    openConfirm  = function(_, args) captured.last = args end,
  }
end

local function mkSwing(h)
  for _, m in ipairs({ 'imgui', 'swingEditor' }) do package.loaded[m] = nil end
  _G.reaper.ImGui_GetBuiltinPath = function() return '/stub' end
  local captured = {}
  local se = util.instantiate('swingEditor', {
    cm = h.cm, ds = h.ds, chrome = {}, ctx = {},
    gui = { fontSize = { ui = 12 } }, facade = facadeStub(),
    modalHost = mkModalHost(captured), lib = mkLib(h),
  })
  se:open()   -- establish state so libraryDescriptor's sel read is live
  return se, captured
end

local function mkTemper(h, inUse)
  for _, m in ipairs({ 'imgui', 'temperEditor' }) do package.loaded[m] = nil end
  _G.reaper.ImGui_GetBuiltinPath = function() return '/stub' end
  local captured = {}
  local te = util.instantiate('temperEditor', {
    cm = h.cm, chrome = {}, ctx = {}, gui = { fontSize = { ui = 12 } },
    modalHost = mkModalHost(captured), lib = mkLib(h),
    facade = { get = function(name)
      if name == 'arrange' then return { tempersInUse = function() return inUse or {} end } end
    end },
  })
  return te, captured
end

return {
  {
    name = 'swing onPublish lifts a project copy into the library tier',
    run = function(harness)
      local h = harness.mk{ config = {
        project = { swings = { mine = { factors = { 'M' } } } },
      } }
      local se, captured = mkSwing(h)

      se:libraryDescriptor().onPublish('mine')

      t.deepEq(h.cm:getAt('global', 'swings').mine, { factors = { 'M' } },
               'the project copy now lives in the library tier')
      t.eq(captured.last, nil, 'a fresh name publishes with no confirm')
    end,
  },
  {
    name = 'swing onPublish confirms before overwriting a divergent library copy',
    run = function(harness)
      local h = harness.mk{ config = {
        global  = { swings = { shared = { factors = { 'A' } } } },
        project = { swings = { shared = { factors = { 'B' } } } },
      } }
      local se, captured = mkSwing(h)

      se:libraryDescriptor().onPublish('shared')

      t.deepEq(h.cm:getAt('global', 'swings').shared, { factors = { 'A' } },
               'the library copy is untouched until the confirm resolves')
      t.truthy(captured.last, 'a confirm modal was raised')
      captured.last.callback(false)
      t.deepEq(h.cm:getAt('global', 'swings').shared, { factors = { 'A' } },
               'declining the confirm leaves the library copy')
      captured.last.callback(true)
      t.deepEq(h.cm:getAt('global', 'swings').shared, { factors = { 'B' } },
               'confirming lands the project copy')
    end,
  },
  {
    name = 'swing onReloadFactory imports absent names silently and confirms per divergent copy',
    run = function(harness)
      local h = harness.mk{ config = {
        global = { swings = {
          ['classic-58'] = { factors = { 'DRIFT' } },   -- diverges from factory -> confirms
          keep           = { factors = { 'K' } },       -- user entry -> left alone
        } },
      } }
      local se, captured = mkSwing(h)

      se:libraryDescriptor().onReloadFactory()

      local g = h.cm:getAt('global', 'swings')
      t.truthy(g['classic-55'], 'a factory name absent from the library is imported silently')
      t.truthy(g['keep'],       'a user library entry is left alone')
      t.deepEq(g['classic-58'].factors, { 'DRIFT' },
               'a divergent copy is untouched until its confirm resolves')
      t.truthy(captured.last, 'the divergent copy raises a confirm')
      captured.last.callback(false)
      t.deepEq(h.cm:getAt('global', 'swings')['classic-58'].factors, { 'DRIFT' },
               'declining keeps the library copy')
      captured.last.callback(true)
      t.deepEq(h.cm:getAt('global', 'swings')['classic-58'], h.cm:defaultFor('swings')['classic-58'],
               'confirming overwrites with the factory copy')
    end,
  },
  {
    name = 'swing onImportFactory imports a non-divergent copy silently and confirms on divergence',
    run = function(harness)
      local h = harness.mk{ config = {
        global = { swings = { ['classic-58'] = { factors = { 'DRIFT' } } } },   -- diverges from factory
      } }
      local se, captured = mkSwing(h)
      local factory = h.cm:defaultFor('swings')

      se:libraryDescriptor().onImportFactory('classic-55')   -- absent from library -> silent import
      t.deepEq(h.cm:getAt('global', 'swings')['classic-55'], factory['classic-55'],
               'an absent factory name imports silently')
      t.eq(captured.last, nil, 'no confirm for a non-divergent import')

      se:libraryDescriptor().onImportFactory('classic-55')   -- now identical -> still silent
      t.eq(captured.last, nil, 're-importing an identical copy stays silent')

      se:libraryDescriptor().onImportFactory('classic-58')   -- divergent -> confirm
      t.deepEq(h.cm:getAt('global', 'swings')['classic-58'].factors, { 'DRIFT' },
               'the divergent copy is untouched until the confirm resolves')
      t.truthy(captured.last, 'a divergent import raises a confirm')
      captured.last.callback(true)
      t.deepEq(h.cm:getAt('global', 'swings')['classic-58'], factory['classic-58'],
               'confirming overwrites with the factory copy')
    end,
  },
  {
    name = 'temper onImportFactory imports a non-divergent copy silently and confirms on divergence',
    run = function(harness)
      local h = harness.mk{ config = {
        global = { tempers = { ['31EDO'] = { steps = { 'DRIFT' } } } },   -- diverges from factory
      } }
      local te, captured = mkTemper(h)
      local factory = h.cm:defaultFor('tempers')

      te:libraryDescriptor().onImportFactory('19EDO')   -- absent from library -> silent import
      t.deepEq(h.cm:getAt('global', 'tempers')['19EDO'], factory['19EDO'],
               'an absent factory name imports silently')
      t.eq(captured.last, nil, 'no confirm for a non-divergent import')

      te:libraryDescriptor().onImportFactory('31EDO')   -- divergent -> confirm
      t.deepEq(h.cm:getAt('global', 'tempers')['31EDO'].steps, { 'DRIFT' },
               'the divergent copy is untouched until the confirm resolves')
      t.truthy(captured.last, 'a divergent import raises a confirm')
      captured.last.callback(true)
      t.deepEq(h.cm:getAt('global', 'tempers')['31EDO'], factory['31EDO'],
               'confirming overwrites with the factory copy')
    end,
  },
  {
    name = 'temper onPublish lifts a fresh project copy without confirming',
    run = function(harness)
      local h = harness.mk{ config = {
        project = { tempers = { mine = { steps = { 'M' } } } },
      } }
      local te, captured = mkTemper(h)

      te:libraryDescriptor().onPublish('mine')

      t.deepEq(h.cm:getAt('global', 'tempers').mine, { steps = { 'M' } },
               'the project copy now lives in the library tier')
      t.eq(captured.last, nil, 'a fresh name publishes with no confirm')
    end,
  },
  {
    name = 'temper onPublish confirms before overwriting a divergent library copy',
    run = function(harness)
      local h = harness.mk{ config = {
        global  = { tempers = { shared = { steps = { 'A' } } } },
        project = { tempers = { shared = { steps = { 'B' } } } },
      } }
      local te, captured = mkTemper(h)

      te:libraryDescriptor().onPublish('shared')

      t.deepEq(h.cm:getAt('global', 'tempers').shared, { steps = { 'A' } },
               'the library copy is untouched until the confirm resolves')
      t.truthy(captured.last, 'a confirm modal was raised')
      captured.last.callback(false)
      t.deepEq(h.cm:getAt('global', 'tempers').shared, { steps = { 'A' } },
               'declining the confirm leaves the library copy')
      captured.last.callback(true)
      t.deepEq(h.cm:getAt('global', 'tempers').shared, { steps = { 'B' } },
               'confirming lands the project copy')
    end,
  },
  {
    name = 'swing onRevert restores a divergent project copy from its source',
    run = function(harness)
      local h = harness.mk{ config = {
        global  = { swings = { shared = { factors = { 'A' } } } },
        project = { swings = { shared = { factors = { 'B' } } } },
      } }
      local se  = mkSwing(h)
      local lib = mkLib(h)
      t.truthy(lib.modified('swings', 'shared'), 'precondition: project drifts from source')

      se:libraryDescriptor().onRevert('shared')

      t.truthy(not lib.modified('swings', 'shared'), 'revert clears the drift')
    end,
  },
  {
    name = 'swing descriptor flags a divergent project row as modified',
    run = function(harness)
      local h = harness.mk{ config = {
        global  = { swings = { shared = { factors = { 'A' } }, same = { factors = { 'X' } } } },
        project = { swings = { shared = { factors = { 'B' } },   -- drift
                              same   = { factors = { 'X' } },   -- pristine shadow
                              mine   = { factors = { 'M' } } } } } } -- project-only
      local mod = mkSwing(h):libraryDescriptor().modified
      t.truthy(mod and mod.shared, 'a drifted shadow is flagged')
      t.truthy(not (mod and mod.same), 'a pristine shadow is not flagged')
      t.truthy(not (mod and mod.mine), 'a project-only row is not flagged')
    end,
  },
  {
    name = 'temper descriptor flags a divergent project row as modified',
    run = function(harness)
      local h = harness.mk{ config = {
        global  = { tempers = { shared = { steps = { 'A' } }, same = { steps = { 'X' } } } },
        project = { tempers = { shared = { steps = { 'B' } },   -- drift
                               same   = { steps = { 'X' } },   -- pristine shadow
                               mine   = { steps = { 'M' } } } } } } -- project-only
      local mod = mkTemper(h):libraryDescriptor().modified
      t.truthy(mod and mod.shared, 'a drifted shadow is flagged')
      t.truthy(not (mod and mod.same), 'a pristine shadow is not flagged')
      t.truthy(not (mod and mod.mine), 'a project-only row is not flagged')
    end,
  },
  {
    name = 'swing and temper descriptors both expose onTidy',
    run = function(harness)
      local h = harness.mk{}
      local se = mkSwing(h)
      local te = mkTemper(h)

      t.eq(type(se:libraryDescriptor().onTidy), 'function', 'swing supplies onTidy')
      t.eq(type(te:libraryDescriptor().onTidy), 'function', 'temper supplies onTidy')
    end,
  },
  {
    name = 'swing onTidy drops a pristine unreferenced copy, keeps a divergent one',
    run = function(harness)
      local h = harness.mk{ config = {
        global  = { swings = { keep = { factors = { 'S' } }, drop = { factors = { 'S' } } } },
        project = { swings = { keep = { factors = { 'DIFF' } }, drop = { factors = { 'S' } } } },
      } }
      local se = mkSwing(h)

      se:libraryDescriptor().onTidy()

      t.eq(h.cm:getAt('project', 'swings').drop, nil, 'pristine unreferenced copy is dropped')
      t.deepEq(h.cm:getAt('project', 'swings').keep, { factors = { 'DIFF' } },
               'divergent copy is kept')
    end,
  },
  {
    name = 'temper onTidy drops a pristine unreferenced copy, keeps a divergent one',
    run = function(harness)
      local h = harness.mk{ config = {
        global  = { tempers = { keep = { steps = { 'S' } }, drop = { steps = { 'S' } } } },
        project = { tempers = { keep = { steps = { 'DIFF' } }, drop = { steps = { 'S' } } } },
      } }
      local te = mkTemper(h)

      te:libraryDescriptor().onTidy()

      t.eq(h.cm:getAt('project', 'tempers').drop, nil, 'pristine unreferenced copy is dropped')
      t.deepEq(h.cm:getAt('project', 'tempers').keep, { steps = { 'DIFF' } },
               'divergent copy is kept')
    end,
  },
}
