-- Pin-tests for wiringPage's Page interface (bind / unbind / focusState).
-- Render methods pull in ImGui and are exercised manually in REAPER.
-- Persistence round-trips are pinned in wm_persistence_spec.
--
-- wiringPage requires ImGui at module scope; stub via package.preload
-- before the first require so the module loads in the pure-Lua harness.

local t = require('support')

local n = 0
local fakeImGui = setmetatable({ Mod_None = 0 }, {
  __index = function(tbl, k) n = n + 1; rawset(tbl, k, n); return n end,
})
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
local fakeFacade = { publish = function() end, get = function() return {} end }
local function newWiringPage(cm, ds, cmgr, chrome, gui)
  return util.instantiate('wiringPage',
    { cm = cm, ds = ds, cmgr = cmgr, chrome = chrome, gui = gui,
      modalHost = fakeModalHost, facade = fakeFacade })
end

return {
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
    name = 'focusState before any render returns both bits false',
    run = function(harness)
      local h  = harness.mk()
      local wp = newWiringPage(h.cm, h.ds, h.cmgr, nil, {})
      local fs = wp:focusState()
      t.eq(fs.suppressKbd, false, 'no suppression without a context')
      t.eq(fs.acceptCmds,  false, 'no acceptance without a context')
    end,
  },
}
