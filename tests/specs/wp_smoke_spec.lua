-- Pin-tests for wiringPage's Page interface (bind / unbind / focusState).
-- Render methods pull in ImGui and are exercised manually in REAPER.
-- Persistence round-trips are pinned in wm_persistence_spec.
--
-- wiringPage requires ImGui at module scope; stub via package.preload
-- before the first require so the module loads in the pure-Lua harness.

local t = require('support')

local fakeImGui = t.imgui()
package.preload['imgui'] = function()
  return function(_) return fakeImGui end
end
_G.reaper.ImGui_GetBuiltinPath = function() return '/stub' end

local util = require('util')

local fakeModalHost = {
  open                = function() end,
  openPrompt          = function() end,
  openConfirm         = function() end,
  registerKind        = function() end,
  isOpen              = function() return false end,
  wasOpenAtFrameStart = function() return false end,
}
local fakeFacade = {
  publish      = function() end,
  publishDebug = function() end,
  get          = function() return {} end,
}
local function newWiringPage(cm, ds, cmgr, chrome, gui, help)
  local keyQueue = util.instantiate('keyQueue', { ctx = gui and gui.ctx })
  help = help or util.instantiate('help',
    { ctx = gui and gui.ctx, chrome = chrome, cmgr = cmgr, keyQueue = keyQueue })
  return util.instantiate('wiringPage',
    { cm = cm, ds = ds, cmgr = cmgr, chrome = chrome, gui = gui, help = help,
      modalHost = fakeModalHost, facade = fakeFacade })
end

return {
  {
    -- The load-time check of docs/commandManager.md § Manifest, run against the
    -- page's own registrations: what the wiring scope registers and what
    -- manifest.lua declares are the same set, and every entry has a label.
    name = 'the manifest declares every command the wiring page registers',
    run = function(harness)
      local h = harness.mk()
      newWiringPage(h.cm, h.ds, h.cmgr, nil, {})

      local manifest = require('manifest')
      t.truthy(manifest.wiring, 'the wiring scope declares a manifest')
      h.cmgr:installManifest({ wiring = manifest.wiring }, fakeImGui)

      local scope, declared = h.cmgr:scope('wiring'), {}
      for _, entries in pairs(scope.manifest) do
        for _, entry in ipairs(entries) do
          declared[entry.name] = true
          t.truthy(entry.label, entry.name .. ' carries a label')
        end
      end
      t.deepEq(scope.registered, declared, 'declarations and registrations correspond')
    end,
  },

  {
    -- A placement names a group and nothing else, so one no scope declares draws
    -- no box and says nothing about it.
    name = 'every group the wiring page places is one some scope declares',
    run = function(harness)
      local h, placementsByPage = harness.mk(), {}
      local recorder = { registerPage = function(_, name, p) placementsByPage[name] = p end }
      newWiringPage(h.cm, h.ds, h.cmgr, nil, {}, recorder)

      local declared = {}
      for _, groups in pairs(require('manifest')) do
        for groupName in pairs(groups) do declared[groupName] = true end
      end
      local placements = placementsByPage.wiring
      t.truthy(placements and #placements > 0, 'the page registers its F1 placements')
      for _, placement in ipairs(placements) do
        t.truthy(declared[placement.group], placement.group .. ' is a declared group')
      end
    end,
  },

  {
    -- A bound command in no placed group is reachable only from memory; a keyless
    -- one has no chord to show, so it earns no row.
    name = 'every bound command on the wiring page has a place on the cheat-sheet',
    run = function(harness)
      local h, placementsByPage = harness.mk(), {}
      local recorder = { registerPage = function(_, name, p) placementsByPage[name] = p end }
      newWiringPage(h.cm, h.ds, h.cmgr, nil, {}, recorder)
      local manifest = require('manifest')

      local placed = {}
      for _, placement in ipairs(placementsByPage.wiring) do placed[placement.group] = true end

      local missing = {}
      for _, scopeName in ipairs({ 'global', 'wiring' }) do
        for groupName, entries in pairs(manifest[scopeName]) do
          for _, entry in ipairs(entries) do
            if entry.keys and not placed[groupName] then util.add(missing, entry.name) end
          end
        end
      end
      t.deepEq(missing, {}, 'bound commands the cheat-sheet never shows')
    end,
  },

  {
    name = 'bind / unbind are no-ops — wiring page never re-keys cm',
    run = function(harness)
      local h  = harness.mk()
      local calls = 0
      h.cm.setTrack   = function() calls = calls + 1 end
      h.cm.setContext = function() calls = calls + 1 end
      local wp = newWiringPage(h.cm, h.ds, h.cmgr, nil, {})
      wp:bind(); wp:bind('ignored'); wp:unbind()
      t.eq(calls, 0, 'no cm re-key from bind/unbind')
    end,
  },

  {
    name = 'focusState before any render accepts no commands',
    run = function(harness)
      local h  = harness.mk()
      local wp = newWiringPage(h.cm, h.ds, h.cmgr, nil, {})
      local fs = wp:focusState()
      t.eq(fs.acceptCmds, false, 'no acceptance without a context')
    end,
  },
}
