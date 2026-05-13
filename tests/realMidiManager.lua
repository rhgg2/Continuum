-- Returns a `newMidiManager` function that builds a fresh real mm per call.
-- Bypasses util._stubs (which the harness sets to the fake) by going
-- straight through loadfile — these specs deliberately want the real
-- sidecar/dedup/reconcile pipeline.
return function()
  local path = assert(package.searchpath('midiManager', package.path))
  return function(take) return assert(loadfile(path))({ take = take }) end
end
