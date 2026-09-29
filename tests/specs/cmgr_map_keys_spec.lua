-- Map mode's keys and the tracker's are one keyboard, seen with Alt up and with Alt down.
-- Each map key binds bare and under Alt, so a hand still holding Alt from Alt-M reaches the
-- same verb; outside the mode the Alt chord reaches the map verb's tracker twin, so one chord
-- means one thing in the mode and out of it. The keys the mode owns outright -- leaving it,
-- the menu -- have no twin, and their Alt chords are left free outside it. The twins are the
-- model's own pairing, as docs/trackerRender.md § Map mode names them.

local t        = require('support')
local util     = require('util')
local manifest = require('manifest')

-- map verb -> its tracker twin
local TWINS = {
  mapPrevInstance   = 'prevInstance',
  mapNextInstance   = 'nextInstance',
  mapPrevTrack      = 'prevTrack',
  mapNextTrack      = 'nextTrack',
  mapPrevTake       = 'prevTake',
  mapNextTake       = 'nextTake',
  mapPrevVariant    = 'prevVariant',
  mapNextVariant    = 'nextVariant',
  mapPrevFamily     = 'prevFamily',
  mapNextFamily     = 'nextFamily',
  mapDuplicate      = 'duplicateBelow',
  mapFork           = 'fork',
  mapNewTake        = 'newTakeBelow',
  mapTakeProperties = 'takeProperties',
  mapDeleteInstance = 'deleteInstance',
}
local MODE_OWN = { mapLeave = true, mapLeavePinned = true, mapOpenMenu = true }

local function entriesOf(scope)
  local out = {}
  for _, group in pairs(manifest[scope]) do
    for _, entry in ipairs(group) do out[entry.name] = entry end
  end
  return out
end

local function holds(keys, token)
  for _, key in ipairs(keys or {}) do if key == token then return true end end
  return false
end

-- Alt sits after Shift in token order (docs/commandManager.md § Binding tokens).
local function withAlt(token)
  local key = token:match('^Shift%+(.+)$')
  return key and ('Shift+Alt+' .. key) or ('Alt+' .. token)
end

local function bareKeys(entry)
  return util.filter(entry.keys or {}, function(key) return not key:find('Alt+', 1, true) end)
end

return {
  {
    name = 'every map verb is twinned to a tracker verb or is the mode\'s own',
    run = function()
      for name in pairs(entriesOf('map')) do
        t.truthy(TWINS[name] or MODE_OWN[name], name .. ' is neither twinned nor the mode\'s own')
      end
    end,
  },

  {
    name = 'every bare map key binds under Alt as well',
    run = function()
      local checked = 0
      for name, entry in pairs(entriesOf('map')) do
        for _, key in ipairs(bareKeys(entry)) do
          t.falsy(key:find('Ctrl+', 1, true) or key:find('Super+', 1, true),
                  name .. '\'s ' .. key .. ' carries a modifier Alt would sit beside')
          t.truthy(holds(entry.keys, withAlt(key)), name .. ' binds ' .. key .. ' but not ' .. withAlt(key))
          checked = checked + 1
        end
      end
      t.truthy(checked > 10, 'the map\'s keys were walked')
    end,
  },

  {
    name = 'outside the mode a map key\'s Alt chord is its twin\'s, and the mode\'s own are free',
    run = function()
      local map, tracker, global = entriesOf('map'), entriesOf('tracker'), entriesOf('global')
      local claims = {}
      for _, entries in ipairs({ tracker, global }) do
        for name, entry in pairs(entries) do
          for _, key in ipairs(entry.keys or {}) do util.bucket(claims, key, name) end
        end
      end

      local checked = 0
      for name, entry in pairs(map) do
        local twin = TWINS[name]
        for _, key in ipairs(bareKeys(entry)) do
          local chord = withAlt(key)
          t.deepEq(claims[chord], twin and { twin } or nil,
                   chord .. ' outside the mode should reach ' .. tostring(twin or 'nothing'))
          checked = checked + 1
        end
      end
      t.truthy(checked > 10, 'the map\'s keys were walked')
    end,
  },
}
