-- Continuum's startup launcher: a tiny ReaScript instance started from
-- REAPER's __startup.lua. See docs/bridge.md § Spawning.

--invariant: launching is ALL it does — it never reads or writes project state
--invariant: marker deleted before the launch, so a failed start cannot re-fire every poll
--invariant: a marker older than STALE_S is discarded — a days-old request isn't an instruction now
--shape: spool/spawn.marker holds one integer, os.time() at the moment of the request

local POLL_FRAMES = 30    -- ~1s; the spawn path is human-paced, not frame-paced
local STALE_S     = 60

local here     = debug.getinfo(1, 'S').source:match('^@?(.*[/\\])') or './'
local spoolDir = here .. '.claude/mcp/reaper/spool'
local marker   = spoolDir .. '/spawn.marker'
local actionId = spoolDir .. '/action.id'

local function readAll(path)
  local f = io.open(path, 'r'); if not f then return nil end
  local s = f:read('*a'); f:close(); return s
end

-- The bridge records the named command id whenever Continuum runs with the spool
-- present; absent it, Continuum has never run in dev mode and there is nothing to start.
local function launch()
  local named = (readAll(actionId) or ''):match('%S+')
  if not named then return end
  local cmdId = reaper.NamedCommandLookup(named)
  if cmdId ~= 0 then reaper.Main_OnCommand(cmdId, 0) end
end

local countdown = 0
local function poll()
  countdown = countdown - 1
  if countdown <= 0 then
    countdown = POLL_FRAMES
    local stamp = readAll(marker)
    if stamp then
      os.remove(marker)
      if os.time() - (tonumber(stamp) or 0) <= STALE_S then launch() end
    end
  end
  reaper.defer(poll)
end

poll()
