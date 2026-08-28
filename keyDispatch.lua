-- Modal-hosted key dispatch: prefix capture + the keychain walk. Extracted from coordinator so the
-- fx-pattern mini tracker modal can drive the same walk against its own cmgr.

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'

local keyDispatch = {}

-- Capture digits and '/' into the prefix buffer; Esc cancels. Returns
-- 'consumed' if a prefix-accumulating key fired this frame; nil otherwise
-- (so the normal keychain walk proceeds). The prefix is NOT finished here
-- on fall-through: dispatchKeys calls finishPrefix only at the moment a
-- bound command is about to fire, so idle frames don't kill the buffer.
-- In prefix mode, digit keys count even with Ctrl/Super held: holding the
-- chord open while typing a count is a natural reach, and any Ctrl-N or
-- Super-N command binding is overridden for the duration of prefix mode.
-- Shift/Alt still disqualify (Shift-digit emits a different char).
local function isDigitMods(mods)
  return (mods & ~(ImGui.Mod_Ctrl | ImGui.Mod_Super)) == 0
end

local function handlePrefixCapture(cmgr, ctx)
  if not cmgr:isPrefixActive() then return nil end
  local mods = ImGui.GetKeyMods(ctx)
  for d = 0, 9 do
    if ImGui.IsKeyPressed(ctx, ImGui.Key_0 + d) and isDigitMods(mods) then
      cmgr:appendPrefix(tostring(d))
      -- A digit is no menu letter, so it reads a preceding '/' as the rational's bar and
      -- dismisses the walk that slash opened.
      local dismiss = cmgr:dismissal()
      if dismiss then dismiss() end
      return 'consumed'
    end
  end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Slash) and isDigitMods(mods) then
    -- The slash is the bar and the menu key alike: it does both, and the next key says which.
    cmgr:appendPrefix('/')
    cmgr:invoke('openMenu')
    return 'consumed'
  end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
    cmgr:cancelPrefix(); return 'consumed'
  end
  return nil
end

-- A scope may declare a letter sink (the lotus menu's walk); a bare letter goes to it, not
-- the keychain (Shift tolerated). Returns the key taken, since a leaf may close the sink first.
local function handleLetterCapture(cmgr, ctx)
  local capture = cmgr:letterCapture()
  if not capture then return nil end
  if (ImGui.GetKeyMods(ctx) & ~ImGui.Mod_Shift) ~= 0 then return nil end
  for i = 0, 25 do
    if ImGui.IsKeyPressed(ctx, ImGui.Key_A + i) then
      capture(string.char(65 + i)); return ImGui.Key_A + i
    end
  end
  return nil
end

--shape: dispatchResult = { consumed: bool, commandHeld: { [imguiKey]=true } } — commandHeld holds keys down AND command-bound for the live chord
--contract: returns early (no dispatch) when state.suppressKbd or not state.acceptCmds
--contract: state.pageSuppressed shrinks the walk to the root keymap only — body-region editors (swing, tuning) suppress page bindings without shadowing globals like playPause/quit
--contract: first-hit wins; false declines, releases the key, and lets the page char queue see it
--contract: while cmgr:isPrefixActive(), digits and '/' are captured (no dispatch); Esc cancels; any other key freezes the prefix and falls through to the keychain walk so commands can consumePrefix()
--contract: a captured '/' also opens the menu
--contract: a captured digit dismisses the top scope, resolving the slash as the bar
--contract: while captureLetter is declared, that sink gets bare/Shift letters, not the keychain
--contract: a captured letter comes back in commandHeld, so note entry re-reading the frame skips it
function keyDispatch.dispatchKeys(state, cmgr, ctx)
  if state.suppressKbd or not state.acceptCmds then
    return { consumed = false, commandHeld = {} }
  end
  local cap = handlePrefixCapture(cmgr, ctx)
  if cap == 'consumed' then
    return { consumed = true, commandHeld = {} }
  end
  local letterKey = handleLetterCapture(cmgr, ctx)
  if letterKey then
    return { consumed = true, commandHeld = { [letterKey] = true } }
  end
  local commandHeld = {}
  local modsNow = ImGui.GetKeyMods(ctx)
  local keychain = state.pageSuppressed and { cmgr:rootKeymap() } or cmgr:keychain()
  for _, keymap in ipairs(keychain) do
    for command, keys in pairs(keymap) do
      for _, spec in ipairs(keys) do
        local key, mods = cmgr:keySpec(spec, ImGui)
        if mods == modsNow then
          if ImGui.IsKeyDown(ctx, key) then
            commandHeld[key] = true
          end
          if ImGui.IsKeyPressed(ctx, key) then
            -- Freeze the prefix buffer immediately before invoke so
            -- pendingPrefix is set when invoke reads it as the first arg.
            if cmgr:isPrefixActive() and command ~= 'beginPrefix' then
              cmgr:finishPrefix()
            end
            if cmgr:invoke(command) == false then
              commandHeld[key] = nil
            else
              return { consumed = true, commandHeld = commandHeld }
            end
          end
        end
      end
    end
  end
  return { consumed = false, commandHeld = commandHeld }
end

return keyDispatch
