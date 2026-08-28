-- See docs/menu.md for the model.
-- The lotus menu: a typed path to every deliberate verb.

--invariant: the menu's scope is modal, so a walk key never reaches a page verb

local util = require 'util'

local cmgr = (...).cmgr

-- Groups whose entries stay live while the menu walks: Transport because Continuum is
-- played while it is edited, Pages because travel to a page is not a menu letter.
local LIVE_GROUPS = { Transport = true, Pages = true }

local scope = cmgr:scope('menu')
scope.modal = true

--shape: member = { letter, title, desc, node? , entry? }  -- a group carries its node, a leaf its entry

local open    = false
local path    = {}   -- the nodes descended into
local surface = {}   -- the entries the menu snapshotted as it opened

local menu = {}

-- switchPage is the toolbar switcher's own verb, which a click reaches and no live
-- group declares.
local function livePassthrough()
  local pass = { switchPage = true }
  for _, entry in ipairs(surface) do
    if LIVE_GROUPS[entry.group] then pass[entry.name] = true end
  end
  return pass
end

-- A group is worth a letter where it or a descendant holds a reachable entry, so a
-- level omits the groups whose members this page cannot reach.
local function occupied(node)
  for _, entry in ipairs(surface) do
    if entry.node == node then return true end
  end
  for _, child in ipairs(node.children) do
    if occupied(child) then return true end
  end
  return false
end

----------- PUBLIC

function menu:isOpen() return open end

--contract: the nodes descended into, empty at the top level; the menu owns it and unwinds it
function menu:path() return path end

--contract: the members of the node the path names — groups in tree order, then leaves by title
function menu:level()
  local node    = path[#path]
  local members = {}
  for _, child in ipairs(node and node.children or cmgr.tree) do
    if occupied(child) then
      util.add(members, { letter = child.letter, title = child.name,
                          desc   = child.desc,   node  = child })
    end
  end
  -- The surface unions two scopes, whose groups the manifest orders separately, so the
  -- leaves of one level read by title.
  local leaves = {}
  for _, entry in ipairs(surface) do
    if entry.path and entry.node == node then util.add(leaves, entry) end
  end
  table.sort(leaves, function(entryA, entryB) return entryA.title < entryB.title end)
  for _, entry in ipairs(leaves) do
    util.add(members, { letter = entry.letter, title = entry.title,
                        desc   = entry.label,  entry = entry })
  end
  return members
end

-- The surface is read before the menu's own scope goes on the stack: its modality would
-- otherwise hide everything the walk reaches.
function menu:open()
  if open then return end
  surface           = cmgr:surface()
  scope.passthrough = livePassthrough()
  path, open = {}, true
  cmgr:push(scope)
end

function menu:close()
  if not open then return end
  path, surface, open = {}, {}, false
  cmgr:pop(scope)
end

cmgr:register('openMenu',   function() menu:open()  end)
scope:register('closeMenu', function() menu:close() end)

return menu
