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
require('sampleManager')
require('sampleView')
require('samplePage')

return {
  {
    name = "bind(track) re-keys cm to that track via the page's own sv",
    run = function(harness)
      local h  = harness.mk()
      local sp = newSamplePage(h.cm, h.cmgr, nil, {}, nil)
      local got = 'sentinel'
      h.cm.setTrack = function(_, t) got = t end
      sp:bind('trackZ')
      t.eq(got, 'trackZ', "page forwards the track to cm via sv:setTrack")
    end,
  },
  {
    name = "bind(nil) does not re-key cm",
    run = function(harness)
      local h  = harness.mk()
      local sp = newSamplePage(h.cm, h.cmgr, nil, {}, nil)
      local calls = 0
      h.cm.setTrack = function() calls = calls + 1 end
      sp:bind(nil)
      t.eq(calls, 0, "nil bind never reaches cm:setTrack")
    end,
  },
  {
    name = "focusState before any render returns both bits false",
    run = function(harness)
      local h  = harness.mk()
      local sp = newSamplePage(h.cm, h.cmgr, nil, {}, nil)
      local fs = sp:focusState()
      t.eq(fs.suppressKbd, false, "no suppression without a context")
      t.eq(fs.acceptCmds,  false, "no acceptance without a context")
    end,
  },
}
