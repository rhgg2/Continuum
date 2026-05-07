-- Pin-tests for samplePage's Page interface (bind / unbind / focusState).
-- Render methods pull in ImGui and are exercised manually in REAPER.
--
-- samplePage requires ImGui at module scope; stub via package.preload
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
require('sampleView')
require('samplePage')

local function newSv(h)
  return newSampleView(h.cm, function() end, function() end, function() end,
                       function() return {} end)
end

return {
  {
    name = "bind(track) clears the take and forwards the track to sv",
    run = function(harness)
      local h    = harness.mk()
      local sv   = newSv(h)
      local sp   = newSamplePage(sv, {}, h.cm, h.cmgr, nil, nil)
      local cleared = false
      h.cm.clearTake = function() cleared = true end
      sp:bind('trackZ')
      t.eq(cleared,        true,     "clearTake fired")
      t.eq(sv:getTrack(),  'trackZ', "sv received the track")
    end,
  },
  {
    name = "bind(nil) still clears the take but leaves sv's track unchanged",
    run = function(harness)
      local h  = harness.mk()
      local sv = newSv(h)
      sv:setTrack('keep')
      local sp = newSamplePage(sv, {}, h.cm, h.cmgr, nil, nil)
      local cleared = false
      h.cm.clearTake = function() cleared = true end
      sp:bind(nil)
      t.eq(cleared,       true,    "clearTake fired")
      t.eq(sv:getTrack(), 'keep',  "sv's track untouched on nil")
    end,
  },
  {
    name = "focusState before any render returns both bits false",
    run = function(harness)
      local h  = harness.mk()
      local sv = newSv(h)
      local sp = newSamplePage(sv, {}, h.cm, h.cmgr, nil, nil)
      local fs = sp:focusState()
      t.eq(fs.suppressKbd, false, "no suppression without a context")
      t.eq(fs.acceptCmds,  false, "no acceptance without a context")
    end,
  },
}
