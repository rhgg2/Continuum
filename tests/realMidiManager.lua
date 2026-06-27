-- Returns a `newMidiManager` function that builds a fresh real mm per call.
-- Bypasses util._stubs (which the harness sets to the fake) by going
-- straight through loadfile — these specs deliberately want the real
-- sidecar/dedup/reconcile pipeline.
--
-- eventMeta is a real face over a real pextStore: all instances read/write the
-- one project ext-state on the live fakeReaper, so a second mm on the same take
-- (round-trip specs) sees the first's writes.
local util = require('util')
return function()
  local path = assert(package.searchpath('midiManager', package.path))
  return function(take)
    local eventMeta = util.instantiate('eventMeta', { ps = util.instantiate('pextStore') })
    return assert(loadfile(path))({ take = take, eventMeta = eventMeta })
  end
end
