-- See docs/menu.md for the model.
-- The lotus menu: a typed path to every deliberate verb.

--invariant: the menu's scope is modal, so a walk key never reaches a page verb

local cmgr = (...).cmgr

-- Groups whose entries stay live while the menu walks: Transport because Continuum is
-- played while it is edited, Pages because travel to a page is not a menu letter.
local LIVE_GROUPS = { Transport = true, Pages = true }

local scope = cmgr:scope('menu')
scope.modal = true

local open = false
local path = {}

local menu = {}

-- Read off the stack before the menu's own scope goes on it. switchPage is the toolbar
-- switcher's own verb, which a click reaches and no live group declares.
local function livePassthrough()
  local pass = { switchPage = true }
  for _, entry in ipairs(cmgr:surface()) do
    if LIVE_GROUPS[entry.group] then pass[entry.name] = true end
  end
  return pass
end

----------- PUBLIC

function menu:isOpen() return open end

--contract: the segments walked so far, empty at the top level; the menu owns it and unwinds it
function menu:path() return path end

function menu:open()
  if open then return end
  scope.passthrough = livePassthrough()
  path, open = {}, true
  cmgr:push(scope)
end

function menu:close()
  if not open then return end
  path, open = {}, false
  cmgr:pop(scope)
end

cmgr:register('openMenu',   function() menu:open()  end)
scope:register('closeMenu', function() menu:close() end)

return menu
