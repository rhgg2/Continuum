-- Pin-tests for the coordinator's page-routing surface: setActive scope-swap and returnToArrange.
-- Render (frame/run) pulls in ImGui and is exercised manually in REAPER.

-- coordinator requires ImGui at module scope; stub via package.preload before
-- the first require so the module loads in the pure-Lua harness.

local t = require('support')

local n = 0
local fakeImGui = setmetatable({ Mod_None = 0 }, {
  __index = function(tbl, k) n = n + 1; rawset(tbl, k, n); return n end,
})
package.preload['imgui'] = function()
  return function(_) return fakeImGui end
end

local util = require('util')

-- A page that records every bind / unbind so a test can read back what
-- the coordinator did to it. revealTake is recorded too (returnToArrange).
local function fakePage()
  local p = { calls = {} }
  function p:bind(...)           p.calls[#p.calls + 1] = { 'bind', ... } end
  function p:unbind()            p.calls[#p.calls + 1] = { 'unbind' } end
  function p:revealTake(take)    p.calls[#p.calls + 1] = { 'revealTake', take } end
  function p:toolbarSegments() return {} end
  function p:renderBody()        end
  function p:renderStatusBar()   end
  function p:reloadFromReaper()  end
  return p
end

local function lastCall(page)
  return page.calls[#page.calls]
end

-- see docs/coordinator.md § Test wiring for newCoord
local function newCoord(h, registrations)
  local gui = { ctx = {}, uiFont = {}, uiFontBold = {}, fontSize = { ui = 12 } }
  local coord = util.instantiate('coordinator', { cm = h.cm, cmgr = h.cmgr, gui = gui })
  for _, reg in ipairs(registrations) do
    local name, page = reg[1], reg[2]
    util._stubs[name] = function() return page end
    coord:register(name, name)
    util._stubs[name] = nil
  end
  return coord
end

return {
  {
    name = 'setActive swaps scope, unbinds the outgoing page, and binds the incoming tracker from the cursor',
    run = function(harness)
      local h = harness.mk()
      local tracker, arrange = fakePage(), fakePage()
      -- arrange registered first, so it boots active and was bound once.
      local coord = newCoord(h, { { 'arrange', arrange }, { 'tracker', tracker } })

      coord:setActive('tracker')

      t.eq(lastCall(arrange)[1], 'unbind', 'outgoing arrange page unbound')
      t.eq(lastCall(tracker)[1], 'bind', 'incoming tracker bound on activation')
      t.eq(lastCall(tracker)[2], nil, 'no-arg bind = follow the arrange cursor')
    end,
  },

  {
    name = 'returnToArrange unbinds the tracker and rebinds arrange (no reveal)',
    run = function(harness)
      local h = harness.mk()
      local tracker, arrange = fakePage(), fakePage()
      local coord = newCoord(h, { { 'arrange', arrange }, { 'tracker', tracker } })

      coord:setActive('tracker')
      coord:returnToArrange()

      t.eq(lastCall(tracker)[1], 'unbind', 'tracker unbound on the way out')
      t.eq(lastCall(arrange)[1], 'bind',   'arrange rebound — cursor never left, so no revealTake')
    end,
  },

  {
    name = 'returnToArrange is a no-op when the arrange page is not registered',
    run = function(harness)
      local h = harness.mk()
      local tracker = fakePage()
      local coord = newCoord(h, { { 'tracker', tracker } })
      local before = #tracker.calls

      coord:returnToArrange()

      t.eq(#tracker.calls, before, 'no page churn without an arrange page')
    end,
  },

  {
    name = 'coordinator constructs the reaper bridge with an env exposing coord and the page() debug resolver',
    run = function(harness)
      local h = harness.mk()
      local capturedEnv, capturedFacade
      util._stubs['bridge']  = function(deps) capturedEnv = deps.env; return { tick = function() end } end
      util._stubs['tracker'] = function(deps) capturedFacade = deps.facade; return fakePage() end
      local ok, err = pcall(function()
        local coord = util.instantiate('coordinator',
          { cm = h.cm, cmgr = h.cmgr, gui = { ctx = {}, uiFont = {}, uiFontBold = {}, fontSize = { ui = 12 } } })
        coord:register('tracker', 'tracker')
        capturedFacade.publishDebug('tracker', { tm = 'TM', mm = 'MM' })
        t.eq(capturedEnv.coord, coord, 'env.coord is the live coordinator')
        t.eq(capturedEnv.page('tracker').tm, 'TM', 'page() resolves the published debug stack')
      end)
      util._stubs['bridge']  = nil
      util._stubs['tracker'] = nil
      assert(ok, err)
    end,
  },
}
