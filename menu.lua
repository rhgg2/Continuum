-- See docs/menu.md for the model.
-- The lotus menu: a typed path to every deliberate verb.

--invariant: the menu's scope is modal, so a walk key never reaches a page verb
--invariant: a letter typed with the menu open goes to the scope's sink, before the keychain

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

--contract: the member the letter names
--contract: a group's letter descends
--contract: a leaf's letter closes the menu and invokes; unmatched is dropped
function menu:press(letter)
  local hit
  for _, member in ipairs(self:level()) do
    if member.letter == letter then hit = member end
  end
  if not hit then return end
  if hit.node then
    util.add(path, hit.node)
  else
    -- Close first, so the leaf's command is gated by the stack the menu was walked over
    -- rather than blocked by the menu's own modality.
    local name = hit.entry.name
    self:close()
    -- And freeze the prefix here, as the keychain walk does immediately before its invoke,
    -- so a prefix typed before the walk reaches the leaf.
    cmgr:finishPrefix()
    cmgr:invoke(name)
  end
end

--contract: pops one level, and closes the menu from the top
function menu:back()
  if #path == 0 then self:close() else path[#path] = nil end
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

-- Key dispatch offers a bare letter to the top scope's sink, so the walk takes its letters
-- before the keychain sees them. See docs/commandManager.md § Scope stack.
scope.captureLetter = function(letter) menu:press(letter) end
-- A prefix digit is the dismissal: it resolves a '/' typed into the buffer as the bar.
scope.dismiss       = function() menu:close() end

cmgr:register('openMenu',   function() menu:open()  end)
scope:register('menuBack',  function() menu:back()  end)

return menu
