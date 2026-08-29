-- One frame of key presses, filled before any drawing and drained by claims.
-- See docs/keyQueue.md.

--invariant: one keyQueue per coordinator; each fill replaces the last frame's entries
--shape: entry = { key: imguiKey, mods: modMask, repeated: bool }
--contract: take/takeAny remove what they return, so a claimed press is gone for every later reader
--contract: an owner named at the fill holds the frame; take/takeAny answer nil to others
--contract: held/mods read ImGui live, and answer the same whoever owns the queue

local ImGui = require 'imgui' '0.10'
local util  = require 'util'

local ctx = (...).ctx

-- The readers that take the whole keyboard for a frame. See docs/keyQueue.md § Ownership.
local OWNERS = { help = true, modal = true, picker = true, statusEdit = true }

-- Every key constant the shim carries, ascending, less the mouse keys and the modifier
-- keys -- a modifier is state, and rides on every entry as the mask.
local KEYS = {}
do
  local modifiers = {}
  for _, side in ipairs{ 'Left', 'Right' } do
    for _, mod in ipairs{ 'Ctrl', 'Shift', 'Alt', 'Super' } do
      modifiers['Key_' .. side .. mod] = true
    end
  end
  for name, value in pairs(ImGui) do
    if type(name) == 'string' and type(value) == 'number'
       and name:sub(1, 4) == 'Key_' and name:sub(1, 9) ~= 'Key_Mouse'
       and not modifiers[name] then
      util.add(KEYS, value)
    end
  end
  table.sort(KEYS)
end

local entries, owner = {}, nil

-- A name is one of the four owners or nobody; anything else is a typo, which would
-- otherwise read as a key that quietly does nothing.
local function checked(name)
  if name ~= nil and not OWNERS[name] then
    error('keyQueue: unknown owner ' .. tostring(name))
  end
  return name
end

local function claimable(claimant)
  return checked(claimant) == owner or owner == nil
end

local keyQueue = {}

----------- PUBLIC

function keyQueue:fill(ownerNow)
  entries, owner = {}, checked(ownerNow)
  local mods = ImGui.GetKeyMods(ctx)
  for _, key in ipairs(KEYS) do
    -- Press-or-repeat first: only a key that answered pays the call that separates the two.
    if ImGui.IsKeyPressed(ctx, key, true) then
      util.add(entries, { key      = key,
                          mods     = mods,
                          repeated = not ImGui.IsKeyPressed(ctx, key, false) })
    end
  end
end

function keyQueue:take(key, mods, claimant)
  if not claimable(claimant) then return nil end
  mods = mods or ImGui.Mod_None
  for i, entry in ipairs(entries) do
    if entry.key == key and entry.mods == mods then return table.remove(entries, i) end
  end
  return nil
end

function keyQueue:takeAny(claimant)
  if not claimable(claimant) then return nil end
  return table.remove(entries, 1)
end

function keyQueue:held(key) return ImGui.IsKeyDown(ctx, key) end
function keyQueue:mods()    return ImGui.GetKeyMods(ctx)     end

return keyQueue
