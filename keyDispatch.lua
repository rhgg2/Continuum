-- Modal-hosted key dispatch: prefix capture + the keychain walk. Extracted from
-- coordinator so the fx-pattern mini tracker modal can drive the same walk
-- against its own cmgr. see design/fx-patterns.md § Input routing

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
      cmgr:appendPrefix(tostring(d)); return 'consumed'
    end
  end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Slash) and isDigitMods(mods) then
    cmgr:appendPrefix('/'); return 'consumed'
  end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
    cmgr:cancelPrefix(); return 'consumed'
  end
  return nil
end

--shape: dispatchResult = { consumed: bool, commandHeld: { [imguiKey]=true } } — commandHeld holds only keys that are command-bound AND down
--contract: returns early (no dispatch) when state.suppressKbd or not state.acceptCmds
--contract: state.pageSuppressed shrinks the walk to the root keymap only — body-region editors (swing, tuning) suppress page bindings without shadowing globals like playPause/quit
--contract: first-hit wins; false declines, releases the key, and lets the page char queue see it
--contract: while cmgr:isPrefixActive(), digits and '/' are captured (no dispatch); Esc cancels; any other key freezes the prefix and falls through to the keychain walk so commands can consumePrefix()
function keyDispatch.dispatchKeys(state, cmgr, ctx)
  if state.suppressKbd or not state.acceptCmds then
    return { consumed = false, commandHeld = {} }
  end
  local cap = handlePrefixCapture(cmgr, ctx)
  if cap == 'consumed' then
    return { consumed = true, commandHeld = {} }
  end
  local commandHeld = {}
  local keychain = state.pageSuppressed and { cmgr:rootKeymap() } or cmgr:keychain()
  for _, keymap in ipairs(keychain) do
    for command, keys in pairs(keymap) do
      for _, spec in ipairs(keys) do
        local key, mods = cmgr:keySpec(spec, ImGui)
        if ImGui.IsKeyDown(ctx, key) and mods == ImGui.Mod_None then
          commandHeld[key] = true
        end
        if ImGui.IsKeyPressed(ctx, key) and ImGui.GetKeyMods(ctx) == mods then
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
  return { consumed = false, commandHeld = commandHeld }
end

return keyDispatch
