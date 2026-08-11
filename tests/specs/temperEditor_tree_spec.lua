-- Pin-test for temperEditor's library tree. The built-in EDO catalogue is a
-- seed source (cm:defaultFor); seedIfEmpty stocks the library tier from it, so
-- the descriptor surfaces the catalogue under the Library folder (no Factory
-- section). Selecting a library row must preview (not raise) so the first edit
-- can fork to project. Instantiated over a harness cm with a lib service.

-- temperEditor requires ImGui at module scope; stub imgui via package.preload
-- before the first require so it loads in the pure-Lua harness. Recipe lifted
-- from libpicker_badge_spec.
local t = require('support')

local fakeImGui = setmetatable({ Mod_None = 0 }, {
  __index = function(tbl, k) local n = rawget(tbl, '##n') or 0; n = n + 1
    rawset(tbl, '##n', n); rawset(tbl, k, n); return n end,
})
package.preload['imgui'] = function()
  return function(_) return fakeImGui end
end
for _, m in ipairs({ 'imgui', 'temperEditor' }) do package.loaded[m] = nil end
_G.reaper.ImGui_GetBuiltinPath = function() return '/stub' end

local util   = require('util')
local tuning = require('tuning')

local function has(list, val)
  for _, v in ipairs(list or {}) do if v == val then return true end end
  return false
end

-- Returns the editor and the list of confirms its modalHost was asked to open,
-- so a case can assert a gesture landed silently.
local function mkEditor(h)
  local confirms = {}
  local lib = util.instantiate('library', {
    cm = h.cm,
    synthetic = { swings = { identity = true }, tempers = { ['12EDO'] = true } },
    libraryForm = { tempers = tuning.unrooted },   -- mirrors coordinator's wiring
  })
  lib.seedIfEmpty('tempers')   -- production seeds at startup; mirror it here
  local editor = util.instantiate('temperEditor', {
    cm = h.cm, chrome = {}, ctx = {}, gui = { fontSize = { ui = 12 } },
    modalHost = { registerKind = function() end,
                  openConfirm = function(_, opts) util.add(confirms, opts) end },
    lib = lib,
    facade = { get = function() return { tempersInUse = function() return {} end } end },
  })
  return editor, confirms
end

-- One 12EDO-shaped scale under a name of its own, in both tiers: the library
-- copy states no root, the project copy is placed at A4 = 415Hz.
local ROOT = { rootPitch = 69, rootDetune = -101.27, rootStep = 10, rootOctave = 4 }

local function scale(root)
  local pitches = {}
  for i = 1, 12 do pitches[i] = (i - 1) .. '\\12' end
  local temper = { name = 'Placed', periodPitch = '2/1', pitches = pitches, stepNames = {} }
  for k, v in pairs(root or {}) do temper[k] = v end
  return tuning.derive(temper)
end

-- A non-empty global tier makes seedIfEmpty a no-op; the catalogue plays no
-- part in these two cases.
local function placedInBothTiers(harness)
  return harness.mk{ config = {
    global  = { tempers = { Placed = scale() } },
    project = { tempers = { Placed = scale(ROOT) } },
  } }
end

return {
  {
    name = 'descriptor lists the seeded library catalogue and drops the synthetic floor',
    run = function(harness)
      local h = harness.mk{}
      local temperEditor = mkEditor(h)

      local desc = temperEditor:libraryDescriptor()

      t.truthy(has(desc.library, '19EDO'), 'library folder lists a seeded catalogue EDO')
      t.truthy(not has(desc.library, '12EDO'), 'synthetic 12EDO floor is excluded')
      t.eq(desc.factory, nil, 'no factory section in the descriptor')
    end,
  },
  {
    name = 'selecting a library row previews it without raising',
    run = function(harness)
      local h = harness.mk{}
      local temperEditor = mkEditor(h)

      temperEditor:libraryDescriptor().onSelect('global', '19EDO')
      local desc = temperEditor:libraryDescriptor()

      t.eq(desc.sel.tier, 'global', 'selection tier is the library')
      t.eq(desc.sel.name, '19EDO', 'selection name is the chosen row')
      t.truthy(not desc.dirty, 'a fresh library selection is not dirty')
    end,
  },
  {
    name = 'publishing a placed temper sends the library the scale without the root',
    run = function(harness)
      local h = placedInBothTiers(harness)
      local temperEditor, confirms = mkEditor(h)

      temperEditor:libraryDescriptor().onPublish('Placed')

      t.eq(#confirms, 0, 'a root-only difference is not an overwrite worth confirming')
      local published = h.cm:getAt('global', 'tempers').Placed
      t.eq(published.rootPitch, nil, 'the library copy states no root')
      t.eq(published.rootDetune, nil)
      t.eq(published.rootStep, nil)
      t.eq(published.rootOctave, nil)
      t.eq(published.rootCents, 0, 'its stamps are back at the default root')
      t.eq(published.octaveBase, -1)
      t.eq(published.pitches[10], '9\\12', 'the scale itself publishes unchanged')
    end,
  },
  {
    name = 'a root is not drift from the library scale, but a changed step is',
    run = function(harness)
      local h = placedInBothTiers(harness)
      local temperEditor = mkEditor(h)

      t.truthy(not temperEditor:libraryDescriptor().modified.Placed,
               'the project copy differs only in where the scale is placed')

      local drifted = scale(ROOT)
      drifted.pitches[10] = '905.0'
      h.cm:set('project', 'tempers', { Placed = tuning.derive(drifted) })

      t.truthy(temperEditor:libraryDescriptor().modified.Placed,
               'a step token that differs is drift')
    end,
  },
}
