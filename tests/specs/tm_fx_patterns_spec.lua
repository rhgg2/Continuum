-- P2 of design/fx-patterns.md: an fxPatterns library edit arrives as dataChanged and re-realises
-- every consumer via a full rebuild (v1 dirties all 16). Pins the fxPatterns arm in tm's handler,
-- and that the dormant guard still suppresses it. No consumer/editor exists yet -- that's P3.

local t = require('support')

local function countRebuilds(tm)
  local n = 0
  tm:subscribe('rebuild', function() n = n + 1 end)
  return function() return n end
end

return {
  {
    name = 'an fxPatterns edit fires a rebuild',
    run = function(harness)
      local h = harness.mk()
      local rebuilds = countRebuilds(h.tm)
      h.ds:assign('fxPatterns', { ost = { kind = 'notes', lengthPpq = 240 } })
      t.truthy(rebuilds() >= 1, 'library edit re-realises consumers via rebuild')
    end,
  },
  {
    name = 'a dormant tracker ignores fxPatterns edits',
    run = function(harness)
      local h = harness.mk()
      local rebuilds = countRebuilds(h.tm)
      h.tm:bindTake(nil)
      t.eq(rebuilds(), 0, 'bindTake(nil) itself fires no rebuild')
      h.ds:assign('fxPatterns', { ost = { kind = 'notes' } })
      t.eq(rebuilds(), 0, 'dormant tracker ignores the library edit')
    end,
  },
}
