-- One frame of key presses, filled before any drawing and drained by claims.
-- See docs/keyQueue.md.

--invariant: one keyQueue per coordinator; each fill replaces the last frame's entries
--shape: entry = { key: imguiKey, mods: modMask, repeated: bool }
--contract: take/takeAny remove what they return, so a claimed press is gone for every later reader
--contract: restore puts a taken entry back at the head, for a declining claimant to hand off
--contract: an owner named at the fill holds the frame; take/takeAny answer nil to others
--contract: held/mods read ImGui live, and answer the same whoever owns the queue
--contract: frameMods is the mask the fill stamped; a reader judges a chord by it, then takes at it
--contract: an unowned frame with an item active drops the keys a live text field consumes
--contract: Enter, Escape, Tab and any Ctrl/Super chord survive that drop, for the field's host

local ImGui = require 'imgui' '0.10'
local util  = require 'util'

local ctx = (...).ctx

-- The readers that take the whole keyboard for a frame. See docs/keyQueue.md § Ownership.
local OWNERS = { help = true, modal = true, picker = true, statusEdit = true }

-- The keys a live text field consumes: the printables, the two erasing keys, and the
-- caret's own. Enter, Escape and Tab belong to the field's host, so they are not here.
local FIELD_NAMES = {}
do
  local names = { 'Space', 'Backspace', 'Delete', 'Home', 'End',
                  'LeftArrow', 'RightArrow', 'UpArrow', 'DownArrow',
                  'Apostrophe', 'Comma', 'Minus', 'Period', 'Slash', 'Semicolon', 'Equal',
                  'LeftBracket', 'Backslash', 'RightBracket', 'GraveAccent',
                  'KeypadDecimal', 'KeypadDivide', 'KeypadMultiply', 'KeypadSubtract',
                  'KeypadAdd', 'KeypadEqual' }
  for i = 0, 25 do util.add(names, string.char(65 + i)) end
  for i = 0, 9  do util.add(names, tostring(i)); util.add(names, 'Keypad' .. i) end
  for _, name in ipairs(names) do FIELD_NAMES['Key_' .. name] = true end
end

-- A chord under either of these is a command, and reaches the queue past a live field.
local CHORD_MODS = ImGui.Mod_Ctrl | ImGui.Mod_Super

-- KEYS: every key constant the shim carries, ascending, minus the mouse keys and modifiers.
-- Modifiers are state riding every entry as a mask; FIELD is the field's share, by value.
local KEYS, FIELD = {}, {}
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
      if FIELD_NAMES[name] then FIELD[value] = true end
    end
  end
  table.sort(KEYS)
end

local entries, owner, frameMask = {}, nil, 0

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

---------- PUBLIC

function keyQueue:fill(ownerNow)
  entries, owner = {}, checked(ownerNow)
  local mods = ImGui.GetKeyMods(ctx)
  frameMask   = mods
  -- An owner takes the whole keyboard, a field it hosts included. Otherwise an active item
  -- is a live field, and the fill never asks after the keys it consumes.
  local field = owner == nil and (mods & CHORD_MODS) == 0 and ImGui.IsAnyItemActive(ctx)
  for _, key in ipairs(KEYS) do
    -- Press-or-repeat first: only a key that answered pays the call that separates the two.
    if not (field and FIELD[key]) and ImGui.IsKeyPressed(ctx, key, true) then
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

-- A reader claiming before it acts hands the press back this way when it decides not to.
function keyQueue:restore(entry) table.insert(entries, 1, entry) end

function keyQueue:held(key)  return ImGui.IsKeyDown(ctx, key) end
function keyQueue:mods()     return ImGui.GetKeyMods(ctx)     end
function keyQueue:frameMods() return frameMask                end

return keyQueue
