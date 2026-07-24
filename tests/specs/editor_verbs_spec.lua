-- Verb descriptors on the swing/temper editors under the library model:
-- `publish` lifts a project copy into the shared library, `revert` discards
-- project drift back to its source, and `tidy` (swing only) drops pristine
-- unreferenced project copies. Instantiated over a harness cm/ds with a lib
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
      captured.last.callback()
      t.deepEq(h.cm:getAt('global', 'swings').shared, { factors = { 'B' } },
               'resolving the confirm lands the project copy')
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
      captured.last.callback()
      t.deepEq(h.cm:getAt('global', 'tempers').shared, { steps = { 'B' } },
               'resolving the confirm lands the project copy')
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
