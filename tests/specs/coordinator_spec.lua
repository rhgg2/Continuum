-- Pin-tests for the coordinator's page-routing surface. Render (frame/run)
-- pulls in ImGui and is exercised manually in REAPER; these cover the pure
-- routing: diveToTake (arrange -> tracker) and returnToArrange.
--
-- coordinator requires ImGui at module scope; stub via package.preload
-- before the first require so the module loads in the pure-Lua harness.

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
  function p:renderToolbarBits() end
  function p:renderBody()        end
  function p:renderStatusBar()   end
  function p:reloadFromReaper()  end
  return p
end

local function lastCall(page)
  return page.calls[#page.calls]
end

local function newCoord(h, registrations)
  local gui = { ctx = {}, uiFont = {}, uiFontBold = {}, fontSize = { ui = 12 } }
  local coord = util.instantiate('coordinator', { cm = h.cm, cmgr = h.cmgr, gui = gui })
  for _, reg in ipairs(registrations) do coord:register(reg[1], reg[2]) end
  return coord
end

return {
  {
    name = 'diveToTake selects the item alone and binds it on the tracker page',
    run = function(harness)
      local h = harness.mk()
      h.reaper:setProjectTracks{ 'tr1' }
      local other = h.reaper:addItem('tr1', { take = 'mtX', isMidi = true, pos = 0, len = 1 })
      local item  = h.reaper:addItem('tr1', { take = 'mt1', isMidi = true, pos = 1, len = 1 })
      h.reaper.SetMediaItemSelected(other, true)   -- a stale selection to clear

      local tracker, arrange = fakePage(), fakePage()
      local coord = newCoord(h, { { 'arrange', arrange }, { 'tracker', tracker } })

      coord:diveToTake(item)

      t.eq(h.reaper.GetSelectedMediaItem(0, 0), item, 'dived item is the sole selection')
      t.eq(h.reaper.GetSelectedMediaItem(0, 1), nil,  'no other item left selected')
      local bind = lastCall(tracker)
      t.eq(bind[1], 'bind', 'tracker page was bound')
      t.eq(bind[2], 'mt1',  'tracker bound to the dived take')
    end,
  },

  {
    name = 'diveToTake on nil is a no-op',
    run = function(harness)
      local h = harness.mk()
      local tracker, arrange = fakePage(), fakePage()
      local coord = newCoord(h, { { 'arrange', arrange }, { 'tracker', tracker } })
      local arrangeCallsBefore = #arrange.calls

      coord:diveToTake(nil)

      t.eq(#arrange.calls, arrangeCallsBefore, 'no page churn')
      t.eq(#tracker.calls, 0, 'tracker never touched')
    end,
  },
}
