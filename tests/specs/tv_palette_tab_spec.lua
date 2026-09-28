-- The palette's active tab. The derivation yields fx or parameters and
-- nothing else, so the map tab comes up only in map mode, under an override
-- or under a pin. Map mode outranks everything while it stands; the override
-- holds the map over an available chain and lapses on a caret move, as it
-- does for the other two tabs. The pin, which leaving map mode by Enter
-- sets and by Esc drops, ranks under the override and over the derivation,
-- and it never lapses.
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
    name = 'map mode holds the map over an override, and leaving it restores the ranking',
    run = function(harness)
      local h = harness.mk{}
      h.vm:overrideTab('fx', '0,0')
      h.vm:enterMapMode()
      t.eq(h.vm:paletteTab('0,0', true), 'map', 'the mode outranks a standing override')
      h.vm:leaveMapMode(false)
      t.eq(h.vm:paletteTab('0,0', true), 'fx',  'which is still standing once it ends')
    end,
  },

  {
    name = 'a pin makes the map the default tab',
    run = function(harness)
      local h = harness.mk{}
      h.vm:enterMapMode()
      h.vm:leaveMapMode(true)
      t.eq(h.vm:paletteTab('0,0', true),  'map', 'over an available chain')
      t.eq(h.vm:paletteTab('1,0', false), 'map', 'and it survives a caret move')
      h.vm:enterMapMode()
      h.vm:leaveMapMode(false)
      t.eq(h.vm:paletteTab('1,0', true), 'fx', 'dropping the pin restores the derivation')
    end,
  },

  {
    name = 'an override outranks the pin, and lapses back to it',
    run = function(harness)
      local h = harness.mk{}
      h.vm:enterMapMode()
      h.vm:leaveMapMode(true)
      h.vm:overrideTab('fx', '0,0')
      t.eq(h.vm:paletteTab('0,0', true), 'fx',  'the override wins while it holds')
      t.eq(h.vm:paletteTab('1,0', true), 'map', 'the caret move lapses it back to the pin')
    end,
  },

}
