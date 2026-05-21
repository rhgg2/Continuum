-- Pin-tests for arrangePage's Page interface (bind / unbind / focusState).
-- The arrange-scope cursor commands are 4-line closures over av:setCursor;
-- av's cursor mechanics are pinned in arrange_view_spec, and the closures
-- are inspectable in source. Render methods pull in ImGui and are
-- exercised manually in REAPER.
--
-- arrangePage requires ImGui at module scope; stub via package.preload
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

local function newArrangePage(cm, cmgr, chrome, gui)
  return util.instantiate('arrangePage',
    { cm = cm, cmgr = cmgr, chrome = chrome, gui = gui })
end

return {
  {
    name = 'bind / unbind are no-ops — arrange page never re-keys cm',
    run = function(harness)
      local h  = harness.mk()
      local _  = newArrangePage(h.cm, h.cmgr, nil, {})
      local calls = 0
      h.cm.setTrack   = function() calls = calls + 1 end
      h.cm.setContext = function() calls = calls + 1 end
      local ap = newArrangePage(h.cm, h.cmgr, nil, {})
      ap:bind(); ap:bind('ignored'); ap:unbind()
      t.eq(calls, 0, 'no cm re-key from bind/unbind')
    end,
  },

  {
    name = 'focusState before any render returns both bits false',
    run = function(harness)
      local h  = harness.mk()
      local ap = newArrangePage(h.cm, h.cmgr, nil, {})
      local fs = ap:focusState()
      t.eq(fs.suppressKbd, false, 'no suppression without a context')
      t.eq(fs.acceptCmds,  false, 'no acceptance without a context')
    end,
  },

  {
    name = 'arrange-scope is registered at module load (cursorRight invokable)',
    run = function(harness)
      local h = harness.mk()
      local _ = newArrangePage(h.cm, h.cmgr, nil, {})
      h.cmgr:push('arrange')
      local ok = pcall(function() h.cmgr:invoke('cursorRight') end)
      t.eq(ok, true, 'cursorRight is bound under the arrange scope')
    end,
  },

  {
    name = 'arrange-scope place commands are registered (drop0/dropA/dropZ invokable)',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:setProjectTracks{ 'tr1' }
      local _ = newArrangePage(h.cm, h.cmgr, nil, {})
      h.cmgr:push('arrange')
      for _, name in ipairs{ 'drop0', 'drop9', 'dropa', 'dropz', 'dropA', 'dropZ' } do
        local ok = pcall(function() h.cmgr:invoke(name) end)
        t.eq(ok, true, name .. ' is bound under the arrange scope')
      end
    end,
  },
}
