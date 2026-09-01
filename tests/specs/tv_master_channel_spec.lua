-- Channel 0 is the master channel: an fx-only strip left of channel 1, always carrying at
-- least one column, so a global region is always addressable. The strip is view-built; the
-- regions on it run on every MIDI channel. see docs/trackerView.md § Addressing a chain
local t    = require('support')
local util = require('util')

local sine30 = { { kind = 'sine', period = { 1, 4 }, depth = 30, onset = 0 } }
local arpUp  = { { kind = 'arp', period = { 1, 4 }, dir = 'up' } }   -- discrete: derives onsets, parks the original

-- Global regions are ordinary stored regions at chan 0; each entry overrides the defaults,
-- and the uuid is positional ('fxr-1', 'fxr-2', ...), as tv_fx_region_spec does for channels.
local function injectGlobals(h, list)
  local regions = {}
  for i, over in ipairs(list) do
    local region = { uuid = 'fxr-' .. i, chan = 0, ppq = 0, endppq = 240, fx = sine30 }
    for k, v in pairs(over) do region[k] = v end
    util.add(regions, region)
  end
  h.ds:assign('fxRegions', regions)
  h.tm:rebuild()
end

-- The grid index of a channel's column of one type: lane 1 for a note column, cc number for a cc.
local function colIdx(h, chan, type, cc)
  for i, col in ipairs(h.vm.grid.cols) do
    if col.midiChan == chan and col.type == type
       and (type ~= 'note' or (col.lane or 1) == 1)
       and (type ~= 'cc' or col.cc == cc) then return i end
  end
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

      t.falsy(h.tm:freezeEligible('fxr-1'), 'a global region is no host to freeze')
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
                  { { uuid = 'fxr-1', chan = 3, ppq = 0, endppq = 240, fx = sine30 } })
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

  ----- What the wire hears

  {
    -- The head snapshot expands a global region into one host per channel in use, so a chain
    -- authored on the strip sounds on each of them and nowhere else.
    -- see docs/trackerManager.md § Channel & column model
    name = 'a global region runs its chain on every MIDI channel in use',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      for _, chan in ipairs{ 3, 11 } do
        h.tm:addEvent{ evType = 'note', ppq = 0, endppq = 240, chan = chan, pitch = 60,
                       vel = 100, detune = 0, delay = 0, lane = 1 }
      end
      h.tm:flush()
      injectGlobals(h, { {} })

      local chans = {}
      for _, c in ipairs(h.fm:dump().ccs) do chans[c.chan] = true end
      local reached = util.keys(chans)
      table.sort(reached)
      t.deepEq(reached, { 3, 11 }, 'the sine seats a pb curve on the channels carrying notes')
      t.falsy(chans[0], 'and channel 0 carries no wire of its own')
    end,
  },

  ----- What the strip shows

  {
    -- A global region is no host of its own, so its realisation is the union of the ones it
    -- expanded into, and a ghost lands on the channel of the host that emitted it.
    -- see docs/trackerManager.md § Realisation by host
    name = 'the caret on a global badge ghosts the chain on every channel it reaches',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      for _, chan in ipairs{ 3, 11 } do
        h.tm:addEvent{ evType = 'note', ppq = 0, endppq = 240, chan = chan, pitch = 60,
                       vel = 100, detune = 0, delay = 0, lane = 1 }
      end
      h.tm:flush()
      injectGlobals(h, { { fx = arpUp } })

      h.ec:setPos(0, colIdx(h, 0, 'fx'), 1)
      local overlay = h.vm:ghostOverlay()
      t.truthy(overlay, 'the badge under the caret has a realisation of its own to show')

      local suppressed = {}
      for cell in pairs(overlay.hidden) do suppressed[cell.chan] = true end
      for _, chan in ipairs{ 3, 11 } do
        local ghosts = overlay.notes[colIdx(h, chan, 'note')] or {}
        local pitches = {}
        for row = 0, 4 do util.add(pitches, ghosts[row] and ghosts[row].pitch or false) end
        t.deepEq(pitches, { 60, 60, 60, 60, false },
          'channel ' .. chan .. ' carries four ghosts, on the rows its own host derived')
        t.truthy(suppressed[chan], 'and the original the chain parked there is hidden under them')
      end
    end,
  },

  ----- Explode: the expansion, persisted

  {
    -- Freeze refuses on the strip, so the fx-convert chord means explode there: the stored global
    -- region gives way to the ordinary ones its expansion was already running.
    -- see docs/trackerView.md § Addressing a chain
    name = 'the fx-convert chord on a global badge explodes it onto the channels in use',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      for _, chan in ipairs{ 3, 11 } do
        h.tm:addEvent{ evType = 'note', ppq = 0, endppq = 240, chan = chan, pitch = 60,
                       vel = 100, detune = 0, delay = 0, lane = 1 }
      end
      h.tm:flush()
      injectGlobals(h, { {} })
      t.truthy(h.vm:explodeEligible('fxr-1'), 'a global chain reaching two channels is eligible')

      -- util.atomic reads reaper.Undo_BeginBlock at call time, so a stub installed after the wrap
      -- still counts. Outermost blocks only: the conversion's inner ones collapse into the verb's.
      local depth, blocks = 0, 0
      local realBegin, realEnd = h.reaper.Undo_BeginBlock, h.reaper.Undo_EndBlock
      h.reaper.Undo_BeginBlock = function()
        if depth == 0 then blocks = blocks + 1 end
        depth = depth + 1
      end
      h.reaper.Undo_EndBlock = function() depth = depth - 1 end

      h.ec:setPos(0, colIdx(h, 0, 'fx'), 1)
      h.cmgr:invoke('freezeFxRegion')
      h.reaper.Undo_BeginBlock, h.reaper.Undo_EndBlock = realBegin, realEnd
      t.eq(blocks, 1, 'the explode opens exactly one undo block')

      local chans = {}
      for _, r in ipairs(h.ds:get('fxRegions') or {}) do util.add(chans, r.chan) end
      table.sort(chans)
      t.deepEq(chans, { 3, 11 }, 'one stored region per channel reached, and none on channel 0')

      local strip = colsOn(h, 0)
      t.eq(#strip, 1,          'the strip keeps its column')
      t.falsy(strip[1].cells[0], 'with no badge left on it')

      local wire = {}
      for _, c in ipairs(h.fm:dump().ccs) do wire[c.chan] = true end
      local reached = util.keys(wire)
      table.sort(reached)
      t.deepEq(reached, { 3, 11 }, 'and the chain sounds where it sounded before')
    end,
  },

  {
    -- All or nothing: a chain reaching nothing would explode into no region at all, and the chain
    -- would go with it. The decline comes before the atomic wrap, so no empty undo entry is labelled.
    name = 'a global chain reaching no channel declines, opening no undo block',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      injectGlobals(h, { {} })   -- an empty document puts no channel in use
      t.falsy(h.vm:explodeEligible('fxr-1'), 'so there is nothing to expand into')

      local depth, blocks = 0, 0
      local realBegin, realEnd = h.reaper.Undo_BeginBlock, h.reaper.Undo_EndBlock
      h.reaper.Undo_BeginBlock = function()
        if depth == 0 then blocks = blocks + 1 end
        depth = depth + 1
      end
      h.reaper.Undo_EndBlock = function() depth = depth - 1 end

      h.ec:setPos(0, colIdx(h, 0, 'fx'), 1)
      h.cmgr:invoke('freezeFxRegion')
      h.reaper.Undo_BeginBlock, h.reaper.Undo_EndBlock = realBegin, realEnd

      t.eq(blocks, 0, 'neither arm runs, and no block opens')
      local stored = h.ds:get('fxRegions') or {}
      t.eq(#stored, 1,        'the region stands')
      t.eq(stored[1].chan, 0, 'on the master channel, chain and all')
    end,
  },

  {
    -- The arms are exclusive: a region on a channel of its own has nothing to expand into, and the
    -- chord means freeze there, as it did before explode existed.
    name = 'explode refuses off the master strip, where the chord freezes instead',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      h.tm:addEvent{ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                     vel = 100, detune = 0, delay = 0, lane = 1 }
      h.tm:flush()
      h.ds:assign('fxRegions',
                  { { uuid = 'fxr-1', chan = 1, ppq = 0, endppq = 240, fx = arpUp } })
      h.tm:rebuild()
      t.falsy(h.vm:explodeEligible('fxr-1'), 'a region on a channel of its own is no global')

      h.ec:setPos(0, colIdx(h, 1, 'fx'), 1)
      h.cmgr:invoke('freezeFxRegion')

      t.eq(#(h.ds:get('fxRegions') or {}), 0, 'the chord froze it: the region is gone')
      local authored = 0
      for _, e in ipairs(h.tm:getChannel(1).onTake.notes[1].events) do
        if not e.derived then authored = authored + 1 end
      end
      t.truthy(authored > 1, 'and the arp output stands as authored notes')
    end,
  },

  {
    -- The union's claimed targets are the chain's, and the sampling asks for one channel at a time:
    -- every channel reached lights the column it carries. see docs/trackerManager.md § Realisation by host
    name = 'a global chain lights its curve on the target column of each channel it reaches',
    run = function(harness)
      local h = harness.mk{ data = { extraColumns = { [3]  = { notes = 1, pb = true },
                                                     [11] = { notes = 1, pb = true } } } }
      h.vm:setGridSize(80, 40)
      for _, chan in ipairs{ 3, 11 } do
        h.tm:addEvent{ evType = 'note', ppq = 0, endppq = 240, chan = chan, pitch = 60,
                       vel = 100, detune = 0, delay = 0, lane = 1 }
      end
      h.tm:flush()
      injectGlobals(h, { { fx = sine30 } })

      h.ec:setPos(0, colIdx(h, 0, 'fx'), 1)
      local values = (h.vm:ghostOverlay() or {}).values
      t.truthy(values, 'the badge under the caret has a curve to show')
      for _, chan in ipairs{ 3, 11 } do
        local pbIdx = colIdx(h, chan, 'pb')
        t.truthy(pbIdx, 'fixture check: channel ' .. chan .. ' carries a pb column of its own')
        local rows = {}
        for row = 0, 6 do if (values[pbIdx] or {})[row] then util.add(rows, row) end end
        t.deepEq(rows, { 0, 1, 2, 3 }, 'the curve lights channel ' .. chan .. ' over the region\'s window')
        t.eq(values[colIdx(h, chan, 'note')], nil, 'and the note column beside it takes no values')
      end
    end,
  },

}
