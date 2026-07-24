-- P4 of design/fx-patterns.md: the copy shelf shares nothing live. The P2 fxPatterns dataChanged
-- arm (and its derivationInputs entry) are gone at the inline pivot -- a shelf edit re-realises no
-- consumer. Pins the negative so the arm can't creep back in.

local t = require('support')

return {
  {
    name = 'an fxPatterns shelf edit fires no rebuild',
    run = function(harness)
      local h = harness.mk()
      local n = 0
      h.tm:subscribe('rebuild', function() n = n + 1 end)
      h.ds:assign('fxPatterns', { ost = { kind = 'notes', lengthPpq = 240 } })
      t.eq(n, 0, 'shelf write triggers no host rebuild')
    end,
  },
}
