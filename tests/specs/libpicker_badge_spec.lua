-- Pin-test for chrome.libPicker's modified badge: project rows whose entry has
-- diverged from its library/factory source carry a trailing bullet; pristine
-- project rows and `+`others rows stay bare. Instantiated over a harness cm
-- with a lib service (mirrors the coordinator wiring).

-- chrome requires ImGui + painter at module scope; stub imgui via package.preload
-- before the first require so it loads in the pure-Lua harness. Recipe lifted
-- from tracker_page_spec.
local t = require('support')

local fakeImGui = setmetatable({ Mod_None = 0,
  PushFont = function() end, PopFont = function() end,
  PushStyleColor = function() end, PopStyleColor = function() end }, {
  __index = function(tbl, k) local n = rawget(tbl, '##n') or 0; n = n + 1
    rawset(tbl, '##n', n); rawset(tbl, k, n); return n end,
})
package.preload['imgui'] = function()
  return function(_) return fakeImGui end
end
for _, m in ipairs({ 'imgui', 'painter', 'chrome' }) do package.loaded[m] = nil end
_G.reaper.ImGui_GetBuiltinPath = function() return '/stub' end

local util = require('util')

local BULLET = ' \xe2\x80\xa2'   -- space + U+2022, the modified marker

local function mkChrome(h)
  local lib = util.instantiate('library', {
    cm = h.cm,
    synthetic = { swings = { identity = true }, tempers = { ['12EDO'] = true } },
  })
  return util.instantiate('chrome', { cm = h.cm, ctx = {}, uiSize = 12, lib = lib })
end

local function itemByKey(items, key)
  for _, it in ipairs(items) do if it.key == key then return it end end
end

return {
  {
    name = 'libPicker badges the divergent project row, leaves the pristine one bare',
    run = function(harness)
      local h = harness.mk{ config = {
        project = { swings = {
          alpha = { factors = { 'a' } },   -- deep-equal to its library source
          beta  = { factors = { 'b' } },   -- diverges from its library source
        } },
        global = { swings = {
          alpha = { factors = { 'a' } },
          beta  = { factors = { 'DIFFERENT' } },
        } },
      } }
      local chrome = mkChrome(h)

      local items = chrome.libPicker('swings', nil)
      local pristine = itemByKey(items, 'alpha')
      local divergent = itemByKey(items, 'beta')

      t.truthy(pristine,  'pristine project row is listed')
      t.truthy(divergent, 'divergent project row is listed')
      t.eq(pristine.label, 'alpha', 'pristine project row keeps a bare label')
      t.eq(divergent.label, 'beta' .. BULLET, 'divergent project row carries the bullet')
    end,
  },
}
