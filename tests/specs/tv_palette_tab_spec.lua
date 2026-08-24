-- The palette's active tab. The derivation yields fx or parameters and
-- nothing else, so the map tab comes up only under an override or a pin;
-- the override holds it over an available chain and lapses on a caret
-- move, as it does for the other two tabs. The pin ranks between them:
-- under the override, over the derivation, and it never lapses.
-- A gesture's raise is an override with a command-serial anchor as well;
-- tracker_page_spec exercises it end to end.

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

  {
    name = 'a pin makes the map the default tab',
    run = function(harness)
      local h = harness.mk{}
      h.vm:setMapPinned(true)
      t.eq(h.vm:paletteTab('0,0', true),  'map', 'over an available chain')
      t.eq(h.vm:paletteTab('1,0', false), 'map', 'and it survives a caret move')
      h.vm:setMapPinned(false)
      t.eq(h.vm:paletteTab('1,0', true), 'fx', 'dropping the pin restores the derivation')
    end,
  },

  {
    name = 'an override outranks the pin, and lapses back to it',
    run = function(harness)
      local h = harness.mk{}
      h.vm:setMapPinned(true)
      h.vm:overrideTab('fx', '0,0')
      t.eq(h.vm:paletteTab('0,0', true), 'fx',  'the override wins while it holds')
      t.eq(h.vm:paletteTab('1,0', true), 'map', 'the caret move lapses it back to the pin')
    end,
  },

}
