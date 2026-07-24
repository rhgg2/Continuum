-- Pin-test for temperEditor's Factory tree section. Phase 2 killed cm seeding,
-- so the built-in EDO catalogue now lives only in schema defaults (cm:defaultFor
-- → lib.names().factory). The descriptor must surface it under a Factory folder,
-- and selecting a factory row must preview (not raise) so the first edit can fork
-- to project. Instantiated over a harness cm with a lib service.

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
  return util.instantiate('temperEditor', {
    cm = h.cm, chrome = {}, ctx = {}, gui = { fontSize = { ui = 12 } },
    modalHost = { registerKind = function() end }, lib = lib,
    facade = { get = function() return { tempersInUse = function() return {} end } end },
  })
end

return {
  {
    name = 'descriptor lists the factory EDO catalogue and drops the synthetic floor',
    run = function(harness)
      local h = harness.mk{}
      local temperEditor = mkEditor(h)

      local desc = temperEditor:libraryDescriptor()

      t.truthy(has(desc.factory, '19EDO'), 'factory folder lists a catalogue EDO')
      t.truthy(not has(desc.factory, '12EDO'), 'synthetic 12EDO floor is excluded')
    end,
  },
  {
    name = 'selecting a factory row previews it without raising',
    run = function(harness)
      local h = harness.mk{}
      local temperEditor = mkEditor(h)

      temperEditor:libraryDescriptor().onSelect('factory', '19EDO')
      local desc = temperEditor:libraryDescriptor()

      t.eq(desc.sel.tier, 'factory', 'selection tier is factory')
      t.eq(desc.sel.name, '19EDO', 'selection name is the chosen row')
      t.truthy(not desc.dirty, 'a fresh factory selection is not dirty')
    end,
  },
}
