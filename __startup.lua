-- Continuum's dev launcher, started once per REAPER session.

-- Installed by symlinking this file to <REAPER resource>/Scripts/__startup.lua, the
-- name REAPER runs at launch.

-- That symlink must name this file in the main tree, not reach it through
-- Scripts/Continuum: that link is the one this file repairs.

-- continuum_launcher.lua watches Continuum's bridge spool for a spawn marker, so an
-- external tool can start Continuum when no instance is running.

-- Guarded on the file existing so a moved or deleted repo raises no dialog on every
-- REAPER start. See docs/bridge.md § Spawning.

-- Scripts/Continuum is a symlink that a session repoints to claim REAPER, restored to
-- the main tree on SessionEnd.

-- If a session's worktree is deleted before its SessionEnd hook can hand it back, the
-- link names nothing and Continuum stops starting. See docs/bridge.md § Claiming REAPER.

local scripts = reaper.GetResourcePath() .. '/Scripts'
local launcher = scripts .. '/Continuum/continuum_launcher.lua'

local function readable(path)
  local f = io.open(path, 'r')
  if f then f:close(); return true end
  return false
end

-- Reaching the launcher is the whole test, telling a broken link apart from an
-- uninstalled repo without reading the link itself.

-- Only a recorded tree that holds a launcher is worth repointing at; the quoting
-- assumes neither path contains an apostrophe, true for a home dir or repo checkout.
if not readable(launcher) then
  local home = io.open(scripts .. '/Continuum.home', 'r')
  if home then
    local tree = home:read('*l')
    home:close()
    if tree and readable(tree .. '/continuum_launcher.lua') then
      os.execute("ln -sfn '" .. tree .. "' '" .. scripts .. "/Continuum'")
    end
  end
end

if readable(launcher) then dofile(launcher) end
