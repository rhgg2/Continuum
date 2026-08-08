-- Pin-test for chrome.libPicker's modified badge: project rows whose entry has
-- diverged from its library source carry a trailing bullet; pristine
-- project rows and `+`others rows stay bare. Instantiated over a harness cm
-- with a lib service (mirrors the coordinator wiring). The later cases cover the
-- fields a row carries about its own provenance: `tier` and `groupLabel`.

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

      local items = chrome.libPicker{ key = 'swings' }
      local pristine = itemByKey(items, 'alpha')
      local divergent = itemByKey(items, 'beta')

      t.truthy(pristine,  'pristine project row is listed')
      t.truthy(divergent, 'divergent project row is listed')
      t.eq(pristine.label, 'alpha', 'pristine project row keeps a bare label')
      t.eq(divergent.label, 'beta' .. BULLET, 'divergent project row carries the bullet')

      local bare = chrome.libPicker{ key = 'swings', off = false }
      t.eq(itemByKey(bare, nil), nil, 'off = false drops the Off row')
      t.eq(#bare, #items - 1, 'and takes nothing else with it')
    end,
  },

  {
    name = 'each row carries the tier it was drawn from',
    run = function(harness)
      local h = harness.mk{ config = {
        project = { swings = {
          alpha = { factors = { 'a' } },          -- deep-equal to its library source
          beta  = { factors = { 'b' } },          -- diverges from its library source
          gamma = { factors = { 'g' } },          -- project-only: the library has nowhere to be shadowed
        } },
        global = { swings = {
          alpha   = { factors = { 'a' } },
          beta    = { factors = { 'DIFFERENT' } },
          shelved = { factors = { 's' } },        -- library-only: drawn as a `+` row
        } },
      } }
      local items = mkChrome(h).libPicker{ key = 'swings' }

      t.eq(itemByKey(items, 'alpha').tier,   'project', 'a project row names the project tier')
      t.eq(itemByKey(items, 'gamma').tier,   'project', 'and so does one the library never saw')
      t.eq(itemByKey(items, 'shelved').tier, 'global',  'a `+` row names the tier it was drawn from')
    end,
  },

  {
    name = 'the two tiers name themselves, and a seeded name names the library one too',
    run = function(harness)
      local h = harness.mk{ config = {
        project = { swings = { gamma   = { factors = { 'g' } } } },
        global  = { swings = { shelved = { factors = { 's' } } } },
      } }
      local items = mkChrome(h).libPicker{ key = 'swings' }

      t.eq(itemByKey(items, 'gamma').groupLabel,   'Project', 'the project group announces itself')
      t.eq(itemByKey(items, 'shelved').groupLabel, 'Library', 'and so does the group below it')
      t.eq(itemByKey(items, nil).groupLabel, nil, 'Off is no tier, and announces nothing')

      -- The factory catalogue is a seed source, not a resolution tier: a name it alone carries is
      -- one whose library row was never stocked or has been deleted, and it belongs to no third
      -- place the user could be shown.
      local seeded = itemByKey(items, 'classic-55')
      t.truthy(seeded, 'a seeded name the library tier lacks still reaches the merged view')
      t.eq(seeded.tier, 'global', 'and names the library tier, there being no other to name')
    end,
  },
}
