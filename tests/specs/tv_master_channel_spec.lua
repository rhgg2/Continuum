-- Channel 0 is the master channel: an fx-only strip left of channel 1, always carrying at
-- least one column, so a global region is always addressable. It is view-built and reaches
-- no wire. see docs/trackerView.md § Addressing a chain
local t    = require('support')
local util = require('util')

local sine30 = { { kind = 'sine', period = { 1, 4 }, depth = 30, onset = 0 } }

-- Global regions are ordinary stored regions at chan 0; each entry overrides the defaults,
-- and the uuid is positional ('fxr-1', 'fxr-2', ...), as tv_fx_region_spec does for channels.
local function injectGlobals(h, list)
  local regions = {}
  for i, over in ipairs(list) do
    local region = { uuid = 'fxr-' .. i, chan = 0, startppq = 0, endppq = 240, fx = sine30 }
    for k, v in pairs(over) do region[k] = v end
    util.add(regions, region)
  end
  h.ds:assign('fxRegions', regions)
  h.tm:rebuild()
end

local function colsOn(h, chan)
  local out = {}
  for _, col in ipairs(h.vm.grid.cols) do
    if col.midiChan == chan then util.add(out, col) end
  end
  return out
end

return {

  ----- The strip itself

  {
    name = 'an empty document opens with the master fx strip as column 1',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)

      local col = h.vm.grid.cols[1]
      t.eq(col.type,     'fx', 'column 1 is an fx column')
      t.eq(col.midiChan, 0,    'standing on the master channel')
      t.eq(#colsOn(h, 0), 1,   'one column, occupied or not')
      t.falsy(h.vm.grid.lane1Col[0], 'the master channel has no note lanes')

      local second = h.vm.grid.cols[2]
      t.eq(second.type, 'note', "channel 1's lane-1 note column follows it")
      t.eq(second.midiChan, 1, 'on channel 1')
      t.eq(#h.vm.grid.cols, 17, 'sixteen note columns behind the strip')
    end,
  },

  {
    name = 'the strip sits left of channel 1',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      local grid = h.vm.grid
      t.eq(grid.chanFirstCol[0], 1, 'the master channel is chan-keyed as any other')
      t.truthy(grid.chanLastCol[0] < grid.chanFirstCol[1],
               'and its last column stands before channel 1 starts')
    end,
  },

  ----- Global regions land there and nowhere else

  {
    name = 'a global region renders in the master strip and on no MIDI channel',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      injectGlobals(h, { {} })

      local col = colsOn(h, 0)[1]
      t.eq(col.cells[0] and col.cells[0].uuid, 'fxr-1', 'the badge cell carries the region uuid')
      t.eq(col.tails[1].stack[0].glyph, '~', "showing the chain's glyph")

      for _, other in ipairs(h.vm.grid.cols) do
        if other.midiChan ~= 0 then
          t.falsy(other.type == 'fx', 'no fx column materialises on a MIDI channel')
        end
      end
    end,
  },

  {
    name = 'overlapping global regions pack into sibling columns on channel 0',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      injectGlobals(h, { {}, {} })

      local cols = colsOn(h, 0)
      t.eq(#cols, 2, 'two overlapping regions take two fx columns')
      t.eq(cols[1].cells[0].uuid, 'fxr-1', 'storage order is lane order')
      t.eq(cols[2].cells[0].uuid, 'fxr-2', 'the second packs into the lane above')
      t.eq(cols[2].midiChan, 0, 'both stand on the master channel')
      t.truthy(h.vm.grid.chanLastCol[0] < h.vm.grid.chanFirstCol[1],
               'and the widened strip still sits left of channel 1')
    end,
  },

  ----- What the master channel refuses

  {
    name = 'hide refuses on the master strip',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)

      t.eq(h.vm.grid.cols[1].midiChan, 0, 'the caret column is the master strip')
      local before = #h.vm.grid.cols
      h.ec:setPos(0, 1, 1)
      h.vm:hideExtraCol()

      t.eq(#h.vm.grid.cols, before, 'the strip stands')
      t.eq(h.vm.grid.cols[1].midiChan, 0, 'and column 1 is still the master channel')
      t.falsy(next(h.ds:get('extraColumns') or {}), 'no extraColumns entry is written')
    end,
  },

  {
    name = 'add-column refuses on the master strip',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)

      t.eq(h.vm.grid.cols[1].midiChan, 0, 'the caret column is the master strip')
      local before = #h.vm.grid.cols
      h.ec:setPos(0, 1, 1)
      h.vm:addExtraCol('note')
      h.vm:addExtraCol('cc', 74)
      h.vm:addExtraCol('pb')

      t.falsy(next(h.ds:get('extraColumns') or {}), 'no extraColumns entry is written')
      t.eq(#h.vm.grid.cols, before, 'and no column arrives')
    end,
  },

  {
    name = 'mute and solo refuse on the master strip',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)

      h.vm:toggleChannelMute(0)
      h.vm:toggleChannelSolo(0)

      t.falsy(h.vm:isChannelMuted(0),  'the master channel does not mute')
      t.falsy(h.vm:isChannelSoloed(0), 'nor solo')
      t.falsy(h.ds:get('mutedChannels'),  'no mute set is written')
      t.falsy(h.ds:get('soloedChannels'), 'no solo set either')
      -- Solo mutes the channels it does not name, so a solo here would silence all sixteen.
      t.falsy(h.vm:isChannelEffectivelyMuted(3), 'and channel 3 stays audible')
    end,
  },

  {
    name = 'parameter automation refuses on the master strip',
    run = function(harness)
      local h = harness.mk()
      -- pa scans project tracks for bindings and project takes for used cc lanes.
      h.reaper._state.projectTracks = { 'take1/track' }
      h.reaper._state.projectItems = { { takes = { 'take1' } } }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(0, 1, 1)
      t.eq(h.vm.grid.cols[h.ec:col()].midiChan, 0, 'the caret column is the master strip')

      h.vm:setPaletteParam{ trackGuid = '{DST}', fxGuid = '{FX-1}', param = 3, label = 'Cutoff' }
      h.vm:automateParam()

      t.falsy(h.ds:get('paramAutomation'), 'no binding is written')
      t.falsy(h.vm:paramBinding(0, 119),   'and none stands at channel 0')
    end,
  },

  {
    name = 'freeze refuses a global region',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      injectGlobals(h, { {} })

      t.falsy(h.tm:freezeEligible('fxr-1'), 'a global region is no producer to freeze')
      t.falsy(h.tm:freezeRegion('fxr-1'),   'and the conversion refuses outright')

      local regions = h.ds:get('fxRegions') or {}
      t.eq(#regions, 1,      'the region stands')
      t.eq(regions[1].chan, 0, 'still on the master channel')
      t.eq(#h.fm:dump().notes, 0, 'with nothing frozen onto a channel')
    end,
  },

  {
    -- The 1-to-16 rebase rule pasteFxRegions already applies; channel 0 falls outside it.
    name = 'paste drops a region rebased onto the master channel',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      h.ds:assign('fxRegions',
                  { { uuid = 'fxr-1', chan = 3, startppq = 0, endppq = 240, fx = sine30 } })
      h.tm:rebuild()
      h.vm:rebuild()

      local src
      for i, col in ipairs(h.vm.grid.cols) do
        if col.midiChan == 3 and col.type == 'fx' then src = i end
      end
      h.ec:setPos(0, src, 1)
      h.ec:extendTo(3, src, 1)
      local clip = h.clipboard:collect()
      t.eq(#clip.fxRegions, 1, 'the region rides the clip')

      h.ec:selClear()
      h.ec:setPos(0, 1, 1)
      t.eq(h.vm.grid.cols[h.ec:col()].midiChan, 0, 'the caret column is the master strip')
      h.clipboard:pasteClip(clip)

      local regions = h.ds:get('fxRegions')
      t.eq(#regions, 1,        'nothing lands: the rebase falls outside 1 to 16')
      t.eq(regions[1].chan, 3, 'and the copied region stands where it was')
    end,
  },

  ----- What it permits

  {
    name = 'channel select stands, and a selection on the strip mints a global region',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      h.ec:setPos(0, 2, 1)
      h.ec:selectChannel(0)
      t.eq(h.ec:col(), 1, 'the banner click lands the caret on the strip')

      local uuid, minted = h.vm:fxHostForEdit()
      t.truthy(minted, 'the selection mints a fresh region')
      local region = (h.ds:get('fxRegions') or {})[1]
      t.eq(region.uuid, uuid, 'stored under the minted uuid')
      t.eq(region.chan, 0,    'on the master channel')
    end,
  },

  ----- Where the caret opens

  {
    name = 'the caret opens on channel 1 lane 1, not on the strip',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      h.ec:setPos(0, 1, 1)
      h.vm:rebuild(true)

      local col = h.vm.grid.cols[h.ec:col()]
      t.truthy(h.ec:col() > 1,   'the caret opens past the master strip')
      t.eq(col.type,     'note', 'a note column')
      t.eq(col.midiChan, 1,      'on channel 1')
      t.eq(col.lane,     1,      'lane 1')
    end,
  },

  {
    -- As at spawn: tv's load-time rebuild(true) runs before the pane reports a size, so
    -- the caret homes to column 2 with gridWidth still 0.
    name = 'the strip stands through the first rebuild, before the pane has a width',
    run = function(harness)
      local h = harness.mk()   -- no setGridSize
      t.eq(h.ec:col(), 2, 'the caret homed off the strip')
      t.eq(select(2, h.vm:scroll()), 1, 'and the scroll stayed home, with no width to say otherwise')
    end,
  },

  {
    name = 'a take swap brings the scroll home, so the strip stands left of the caret',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(12, 40)     -- narrow enough that the grid scrolls
      h.ec:setPos(0, #h.vm.grid.cols, 1)
      t.truthy(select(2, h.vm:scroll()) > 1, 'scrolled right, the strip off the left edge')

      h.vm:rebuild(true)
      t.eq(select(2, h.vm:scroll()), 1, 'the swap brings the scroll home')
      t.eq(h.vm.grid.cols[h.ec:col()].type, 'note', 'with the caret still on a note column')
    end,
  },

  ----- The wire hears nothing

  {
    name = 'a global region reaches no channel',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      injectGlobals(h, { {} })   -- tm drops chan-0 regions from the head snapshot

      local dump = h.fm:dump()
      t.eq(#dump.notes, 0, 'a global region derives no notes')
      t.eq(#dump.ccs,   0, 'and no cc or pb output on any channel')
    end,
  },

}
