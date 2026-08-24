-- The palette's active tab. The derivation yields fx or parameters and
-- nothing else, so the map tab comes up only under an override; the
-- override holds it over an available chain and lapses on a caret move,
-- as it does for the other two tabs.

local t = require('support')

return {

  {
    name = 'the derivation never yields the map',
    run = function(harness)
      local h = harness.mk{}
      t.eq(h.vm:paletteTab('0,0', false), 'parameters')
      t.eq(h.vm:paletteTab('0,0', true),  'fx')
    end,
  },

  {
    name = 'an override holds the map up until the caret moves',
    run = function(harness)
      local h = harness.mk{}
      h.vm:overrideTab('map', '0,0')
      t.eq(h.vm:paletteTab('0,0', true), 'map', 'outranks an available chain')
      t.eq(h.vm:paletteTab('1,0', true), 'fx',  'the caret move lapses it')
      t.eq(h.vm:paletteTab('0,0', true), 'fx',  'and it stays lapsed')
    end,
  },

}
