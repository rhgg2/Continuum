-- Modal-hosted key dispatch: prefix capture + the keychain walk. Extracted from coordinator so the
-- fx-pattern mini tracker modal can drive the same walk against its own cmgr.

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'

local keyDispatch = {}

-- Capture digits and '/' into the prefix buffer; Esc cancels. Returns the entry
-- it claimed, or nil when no prefix-accumulating key fired this frame.
--contract: on fall-through the prefix is NOT finished
--contract: dispatchKeys calls finishPrefix only when a bound command is about to fire
--contract: so idle frames don't kill the buffer
--contract: digit keys count even with Ctrl/Super held, so the chord stays open while typing a count
--contract: Ctrl-N/Super-N command bindings are overridden during prefix mode
--contract: Shift/Alt still disqualify (Shift-digit emits a different char)
local function isDigitMods(mods)
  return (mods & ~(ImGui.Mod_Ctrl | ImGui.Mod_Super)) == 0
end

local function handlePrefixCapture(cmgr, keyQueue, claimant)
  if not cmgr:isPrefixActive() then return nil end
  local mods = keyQueue:frameMods()
  if isDigitMods(mods) then
    for d = 0, 9 do
      local digit = keyQueue:take(ImGui.Key_0 + d, mods, claimant)
      if digit then
        cmgr:appendPrefix(tostring(d))
        -- A digit is no menu letter, so it reads a preceding '/' as the rational's bar and
        -- dismisses the walk that slash opened.
        local dismiss = cmgr:dismissal()
        if dismiss then dismiss() end
        return digit
      end
    end
    local slash = keyQueue:take(ImGui.Key_Slash, mods, claimant)
    if slash then
      -- The slash is the bar and the menu key alike: it does both, and the next key says which.
      cmgr:appendPrefix('/')
      cmgr:invoke('openMenu')
      return slash
    end
  end
  local escape = keyQueue:take(ImGui.Key_Escape, mods, claimant)
  if escape then
    cmgr:cancelPrefix(); return escape
  end
  return nil
end

-- A scope may declare a letter sink (the lotus menu's walk); a bare letter goes to it, not
-- the keychain (Shift tolerated). Returns whether a letter went to the sink.
local function handleLetterCapture(cmgr, keyQueue, claimant)
  local capture = cmgr:letterCapture()
  if not capture then return nil end
  local mods = keyQueue:frameMods()
  if (mods & ~ImGui.Mod_Shift) ~= 0 then return nil end
  for i = 0, 25 do
    if keyQueue:take(ImGui.Key_A + i, mods, claimant) then
      capture(string.char(65 + i)); return true
    end
  end
  return nil
end

--contract: returns early (no dispatch) when not state.acceptCmds
--contract: an owned frame needs no gate, since every claim answers nil
--contract: state.pageSuppressed shrinks the walk to the root keymap only — body-region editors (swing, tuning) suppress page bindings without shadowing globals like playPause/quit
--contract: the walk claims the press before invoking; a command's reads see a queue without it
--contract: first-hit wins; false declines, and restores the press to the queue
--contract: while cmgr:isPrefixActive(), digits and '/' are captured (no dispatch); Esc cancels; any other key freezes the prefix and falls through to the keychain walk so commands can consumePrefix()
--contract: a captured '/' also opens the menu
--contract: a captured digit dismisses the top scope, resolving the slash as the bar
--contract: while captureLetter is declared, that sink gets bare/Shift letters, not the keychain
--contract: every claim is at frameMods, as state.claimant -- see docs/keyQueue.md
function keyDispatch.dispatchKeys(state, cmgr, keyQueue)
  if not state.acceptCmds then return end
  if handlePrefixCapture(cmgr, keyQueue, state.claimant) then return end
  if handleLetterCapture(cmgr, keyQueue, state.claimant) then return end
  local modsNow = keyQueue:frameMods()
  local keychain = state.pageSuppressed and { cmgr:rootKeymap() } or cmgr:keychain()
  for _, keymap in ipairs(keychain) do
    for command, keys in pairs(keymap) do
      for _, spec in ipairs(keys) do
        local key, mods = cmgr:keySpec(spec, ImGui)
        if mods == modsNow then
          local entry = keyQueue:take(key, mods, state.claimant)
          if entry then
            -- Freeze the prefix buffer immediately before invoke so
            -- pendingPrefix is set when invoke reads it as the first arg.
            if cmgr:isPrefixActive() and command ~= 'beginPrefix' then
              cmgr:finishPrefix()
            end
            if cmgr:invoke(command) == false then
              keyQueue:restore(entry)
            else
              return
            end
          end
        end
      end
    end
  end
end

return keyDispatch
