-- Pin-tests for samplePage's Page interface (bind / unbind / focusState).
-- Render methods pull in ImGui and are exercised manually in REAPER.
--
-- samplePage requires ImGui at module scope; stub via package.preload
-- before the first require so the module loads in the pure-Lua harness.

local t = require('support')

local fakeImGui = t.imgui()
package.preload['imgui'] = function()
  return function(_) return fakeImGui end
end
_G.reaper.ImGui_GetBuiltinPath = function() return '/stub' end

local util = require('util')
local fakeFacade = {
  publish = function() end,
  get = function() return { currentTake = function() return nil end } end,
}
local function newSamplePage(cm, cmgr, chrome, gui, help)
  local keyQueue = util.instantiate('keyQueue', { ctx = gui and gui.ctx })
  help = help or util.instantiate('help',
    { ctx = gui and gui.ctx, chrome = chrome, cmgr = cmgr, keyQueue = keyQueue })
  return util.instantiate('samplePage',
    { cm = cm, cmgr = cmgr, chrome = chrome, gui = gui, help = help, facade = fakeFacade,
      keyQueue = keyQueue })
end

return {
  {
    -- The load-time check of docs/commandManager.md § Manifest, run against the
    -- page's own registrations: what the sample scope registers and what
    -- manifest.lua declares are the same set, and every entry has a label.
    name = 'the manifest declares every command the sample page registers',
    run = function(harness)
      local h = harness.mk()
      newSamplePage(h.cm, h.cmgr, nil, {})

      local manifest = require('manifest')
      t.truthy(manifest.sample, 'the sample scope declares a manifest')
      h.cmgr:installManifest({ sample = manifest.sample }, fakeImGui)

      local scope, declared = h.cmgr:scope('sample'), {}
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
    name = 'every group the sample page places is one some scope declares',
    run = function(harness)
      local h, placementsByPage = harness.mk(), {}
      local recorder = { registerPage = function(_, name, p) placementsByPage[name] = p end }
      newSamplePage(h.cm, h.cmgr, nil, {}, recorder)

      local declared = {}
      for _, groups in pairs(require('manifest')) do
        for groupName in pairs(groups) do declared[groupName] = true end
      end
      local placements = placementsByPage.sample
      t.truthy(placements and #placements > 0, 'the page registers its F1 placements')
      for _, placement in ipairs(placements) do
        t.truthy(declared[placement.group], placement.group .. ' is a declared group')
      end
    end,
  },

  {
    -- A bound command in no placed group is reachable only from memory; a keyless
    -- one has no chord to show, so it earns no row.
    name = 'every bound command on the sample page has a place on the cheat-sheet',
    run = function(harness)
      local h, placementsByPage = harness.mk(), {}
      local recorder = { registerPage = function(_, name, p) placementsByPage[name] = p end }
      newSamplePage(h.cm, h.cmgr, nil, {}, recorder)
      local manifest = require('manifest')

      local placed = {}
      for _, placement in ipairs(placementsByPage.sample) do placed[placement.group] = true end

      local missing = {}
      for _, scopeName in ipairs({ 'global', 'sample' }) do
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
    name = "setTrack(track) re-keys cm to that track via the page's own sv",
    run = function(harness)
      local h  = harness.mk()
      local sp = newSamplePage(h.cm, h.cmgr, nil, {})
      local got = 'sentinel'
      h.cm.setTrack = function(_, track) got = track end
      sp:setTrack('trackZ')
      t.eq(got, 'trackZ', "page forwards the track to cm via sv:setTrack")
    end,
  },
  {
    name = "setTrack(nil) does not re-key cm",
    run = function(harness)
      local h  = harness.mk()
      local sp = newSamplePage(h.cm, h.cmgr, nil, {})
      local calls = 0
      h.cm.setTrack = function() calls = calls + 1 end
      sp:setTrack(nil)
      t.eq(calls, 0, "nil setTrack never reaches cm:setTrack")
    end,
  },
  {
    name = "focusState before any render accepts no commands",
    run = function(harness)
      local h  = harness.mk()
      local sp = newSamplePage(h.cm, h.cmgr, nil, {}, nil)
      local fs = sp:focusState()
      t.eq(fs.acceptCmds, false, "no acceptance without a context")
    end,
  },
  {
    name = "bind re-keys cm to the page track on every activation, not just the first",
    run = function(harness)
      local h  = harness.mk()
      local sp = newSamplePage(h.cm, h.cmgr, nil, {})
      sp:setTrack('trackZ')                 -- first activation seeds the page's track
      local got = 'sentinel'
      h.cm.setTrack = function(_, track) got = track end
      sp:bind()                             -- re-activation: sv already remembers trackZ
      t.eq(got, 'trackZ', "bind re-asserts cm:setTrack even when sv already has a track")
    end,
  },
}
