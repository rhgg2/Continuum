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

local util = require('util')

local function has(list, val)
  for _, v in ipairs(list or {}) do if v == val then return true end end
  return false
end

local function mkEditor(h)
  local lib = util.instantiate('library', {
    cm = h.cm,
    synthetic = { swings = { identity = true }, tempers = { ['12EDO'] = true } },
  })
  lib.seedIfEmpty('tempers')   -- production seeds at startup; mirror it here
  return util.instantiate('temperEditor', {
    cm = h.cm, chrome = {}, ctx = {}, gui = { fontSize = { ui = 12 } },
    modalHost = { registerKind = function() end }, lib = lib,
    facade = { get = function() return { tempersInUse = function() return {} end } end },
  })
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
}
