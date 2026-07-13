-- Returns a `newMidiManager` function that builds a fresh real mm per call.
-- Bypasses util._stubs (where the harness installs its own mm factory) by
-- going straight through loadfile — resolving 'midiManager' via require
-- would loop back into that stub.
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
